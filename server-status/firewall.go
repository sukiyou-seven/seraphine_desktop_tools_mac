package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os/exec"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

type firewallPort struct {
	Port     int    `json:"port"`
	Protocol string `json:"protocol"`
	Source   string `json:"source"`
}

type firewallSnapshot struct {
	Backend string         `json:"backend"`
	Zone    string         `json:"zone"`
	Rules   []firewallPort `json:"rules"`
}

type firewallCommand struct {
	Action   string `json:"action"`
	Port     int    `json:"port"`
	Protocol string `json:"protocol"`
}

type firewallManager struct {
	run func(context.Context, string, ...string) ([]byte, error)
	mu  sync.Mutex
}

func newFirewallManager() *firewallManager { return &firewallManager{run: firewallRun} }

func firewallRun(ctx context.Context, name string, args ...string) ([]byte, error) {
	return exec.CommandContext(ctx, name, args...).CombinedOutput()
}

var firewallZonePattern = regexp.MustCompile(`^[A-Za-z][A-Za-z0-9_-]{0,63}$`)

func validFirewallPort(port int, protocol string) bool {
	return port >= 1 && port <= 65535 && (protocol == "tcp" || protocol == "udp")
}

func parseFirewalldPorts(output []byte) []firewallPort {
	rules := []firewallPort{}
	for _, item := range strings.Fields(string(output)) {
		parts := strings.Split(item, "/")
		if len(parts) != 2 {
			continue
		}
		port, err := strconv.Atoi(parts[0])
		if err == nil && validFirewallPort(port, parts[1]) {
			rules = append(rules, firewallPort{Port: port, Protocol: parts[1], Source: "firewalld"})
		}
	}
	return rules
}

var ufwRulePattern = regexp.MustCompile(`^\s*([0-9]{1,5})/(tcp|udp)\s+ALLOW\s+(.+?)\s*$`)

func parseUFWPorts(output []byte) []firewallPort {
	rules := []firewallPort{}
	seen := map[string]bool{}
	for _, line := range strings.Split(string(output), "\n") {
		match := ufwRulePattern.FindStringSubmatch(line)
		if len(match) != 4 {
			continue
		}
		port, err := strconv.Atoi(match[1])
		if err != nil || !validFirewallPort(port, match[2]) {
			continue
		}
		source := strings.TrimSpace(match[3])
		// UFW's IPv6 mirror is the same rule. Display it once.
		if strings.HasSuffix(source, "(v6)") {
			source = strings.TrimSpace(strings.TrimSuffix(source, "(v6)"))
		}
		key := fmt.Sprintf("%d/%s/%s", port, match[2], source)
		if seen[key] {
			continue
		}
		seen[key] = true
		rules = append(rules, firewallPort{Port: port, Protocol: match[2], Source: source})
	}
	return rules
}

func (fm *firewallManager) list(ctx context.Context) (firewallSnapshot, error) {
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	if _, err := fm.run(ctx, "firewall-cmd", "--state"); err == nil {
		activeOutput, activeErr := fm.run(ctx, "firewall-cmd", "--get-active-zones")
		zone := ""
		if activeErr == nil {
			for _, line := range strings.Split(string(activeOutput), "\n") {
				if line != "" && !strings.HasPrefix(line, " ") && !strings.HasPrefix(line, "\t") {
					zone = strings.TrimSpace(line)
					break
				}
			}
		}
		if zone == "" {
			zoneOutput, err := fm.run(ctx, "firewall-cmd", "--get-default-zone")
			if err != nil {
				return firewallSnapshot{}, fmt.Errorf("get firewalld zone: %w", err)
			}
			zone = strings.TrimSpace(string(zoneOutput))
		}
		if !firewallZonePattern.MatchString(zone) {
			return firewallSnapshot{}, fmt.Errorf("invalid firewalld zone")
		}
		output, err := fm.run(ctx, "firewall-cmd", "--zone="+zone, "--list-ports")
		if err != nil {
			return firewallSnapshot{}, fmt.Errorf("list firewalld ports: %w", err)
		}
		return firewallSnapshot{Backend: "firewalld", Zone: zone, Rules: parseFirewalldPorts(output)}, nil
	}
	output, err := fm.run(ctx, "ufw", "status")
	if err == nil && strings.Contains(string(output), "Status: active") {
		return firewallSnapshot{Backend: "ufw", Rules: parseUFWPorts(output)}, nil
	}
	return firewallSnapshot{Backend: "none", Rules: []firewallPort{}}, nil
}

func (fm *firewallManager) change(ctx context.Context, command firewallCommand) error {
	if (command.Action != "add" && command.Action != "remove") || !validFirewallPort(command.Port, command.Protocol) {
		return fmt.Errorf("invalid firewall rule")
	}
	if command.Action == "remove" && (command.Port == 22 || command.Port == 27520) {
		return fmt.Errorf("management ports 22 and 27520 are protected")
	}
	fm.mu.Lock()
	defer fm.mu.Unlock()
	ctx, cancel := context.WithTimeout(ctx, 35*time.Second)
	defer cancel()
	current, err := fm.list(ctx)
	if err != nil {
		return err
	}
	if current.Backend == "none" {
		return fmt.Errorf("no active supported firewall")
	}
	found := false
	for _, rule := range current.Rules {
		if rule.Port == command.Port && rule.Protocol == command.Protocol {
			if current.Backend == "firewalld" || rule.Source == "Anywhere" || rule.Source == "Anywhere (v6)" {
				found = true
			}
		}
	}
	if command.Action == "add" && found {
		return fmt.Errorf("rule already exists")
	}
	if command.Action == "remove" && !found {
		return fmt.Errorf("rule not found or not globally allowed")
	}
	portSpec := fmt.Sprintf("%d/%s", command.Port, command.Protocol)
	if current.Backend == "firewalld" {
		verb := "--add-port=" + portSpec
		undo := "--remove-port=" + portSpec
		if command.Action == "remove" {
			verb, undo = undo, verb
		}
		if out, err := fm.run(ctx, "firewall-cmd", "--zone="+current.Zone, verb); err != nil {
			return fmt.Errorf("firewalld: %s: %w", strings.TrimSpace(string(out)), err)
		}
		if out, err := fm.run(ctx, "firewall-cmd", "--permanent", "--zone="+current.Zone, verb); err != nil {
			rollback, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			_, _ = fm.run(rollback, "firewall-cmd", "--zone="+current.Zone, undo)
			cancel()
			return fmt.Errorf("firewalld persistent rule: %s: %w", strings.TrimSpace(string(out)), err)
		}
		return nil
	}
	args := []string{"allow", portSpec}
	if command.Action == "remove" {
		args = []string{"--force", "delete", "allow", portSpec}
	}
	if out, err := fm.run(ctx, "ufw", args...); err != nil {
		return fmt.Errorf("ufw: %s: %w", strings.TrimSpace(string(out)), err)
	}
	return nil
}

func (a *api) firewallHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	if !a.authorized(r) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	if a.firewall == nil {
		http.Error(w, "firewall unavailable", 503)
		return
	}
	switch r.Method {
	case http.MethodGet:
		state, err := a.firewall.list(r.Context())
		if err != nil {
			http.Error(w, "firewall unavailable", 503)
			return
		}
		sort.Slice(state.Rules, func(i, j int) bool {
			if state.Rules[i].Port != state.Rules[j].Port {
				return state.Rules[i].Port < state.Rules[j].Port
			}
			return state.Rules[i].Protocol < state.Rules[j].Protocol
		})
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		_ = json.NewEncoder(w).Encode(state)
	case http.MethodPost:
		var command firewallCommand
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 2048)).Decode(&command); err != nil {
			http.Error(w, "invalid firewall rule", 400)
			return
		}
		if (command.Action != "add" && command.Action != "remove") || !validFirewallPort(command.Port, command.Protocol) {
			http.Error(w, "invalid firewall rule", 400)
			return
		}
		if err := a.firewall.change(r.Context(), command); err != nil {
			http.Error(w, err.Error(), 409)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	default:
		w.Header().Set("Allow", "GET, POST")
		http.Error(w, "method not allowed", 405)
	}
}
