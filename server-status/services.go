package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os/exec"
	"strings"
	"sync"
	"time"
)

type serviceManager struct {
	run func(context.Context, ...string) ([]byte, error)
	mu  sync.Mutex
}

type serviceEntry struct {
	Name        string `json:"name"`
	Description string `json:"description"`
	ActiveState string `json:"active_state"`
	SubState    string `json:"sub_state"`
	UnitState   string `json:"unit_state"`
}

type serviceCommand struct {
	Name   string `json:"name"`
	Action string `json:"action"`
}

func runSystemctl(ctx context.Context, args ...string) ([]byte, error) {
	return exec.CommandContext(ctx, "systemctl", args...).CombinedOutput()
}

func validServiceName(name string) bool {
	if len(name) < len("a.service") || len(name) > 256 || !strings.HasSuffix(name, ".service") {
		return false
	}
	for i, char := range name {
		if i == 0 && (char < 'A' || char > 'Z') && (char < 'a' || char > 'z') && (char < '0' || char > '9') {
			return false
		}
		if (char >= 'A' && char <= 'Z') || (char >= 'a' && char <= 'z') ||
			(char >= '0' && char <= '9') || strings.ContainsRune("_.@:-", char) {
			continue
		}
		return false
	}
	return true
}

func protectedService(name string) bool {
	return name == "server-status.service" || name == "sera.service"
}

var firewallServices = []string{
	"firewalld.service", "ufw.service", "nftables.service", "iptables.service",
}

func preferredFirewall(entries map[string]*serviceEntry) []serviceEntry {
	for _, name := range firewallServices {
		if entry := entries[name]; entry != nil && entry.UnitState != "" && entry.ActiveState == "active" {
			return []serviceEntry{*entry}
		}
	}
	for _, name := range firewallServices {
		if entry := entries[name]; entry != nil && entry.UnitState != "" {
			return []serviceEntry{*entry}
		}
	}
	return []serviceEntry{}
}

func parseUnitFiles(output []byte, entries map[string]*serviceEntry) {
	for _, line := range strings.Split(string(output), "\n") {
		fields := strings.Fields(line)
		if len(fields) < 2 || !validServiceName(fields[0]) {
			continue
		}
		entry := entries[fields[0]]
		if entry == nil {
			entry = &serviceEntry{Name: fields[0], ActiveState: "inactive", SubState: "dead"}
			entries[fields[0]] = entry
		}
		entry.UnitState = fields[1]
	}
}

func parseUnits(output []byte, entries map[string]*serviceEntry) {
	for _, line := range strings.Split(string(output), "\n") {
		fields := strings.Fields(line)
		if len(fields) > 0 && fields[0] == "●" {
			fields = fields[1:]
		}
		if len(fields) < 4 || !validServiceName(fields[0]) {
			continue
		}
		entry := entries[fields[0]]
		if entry == nil {
			entry = &serviceEntry{Name: fields[0]}
			entries[fields[0]] = entry
		}
		entry.ActiveState = fields[2]
		entry.SubState = fields[3]
		if len(fields) > 4 {
			entry.Description = strings.Join(fields[4:], " ")
		}
	}
}

func (sm *serviceManager) list(ctx context.Context) ([]serviceEntry, error) {
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	files, err := sm.run(ctx, "list-unit-files", "--type=service", "--all", "--no-legend", "--no-pager", "--plain")
	if err != nil {
		return nil, fmt.Errorf("list unit files: %w", err)
	}
	units, err := sm.run(ctx, "list-units", "--all", "--type=service", "--no-legend", "--no-pager", "--plain")
	if err != nil {
		return nil, fmt.Errorf("list units: %w", err)
	}
	entries := make(map[string]*serviceEntry)
	parseUnitFiles(files, entries)
	parseUnits(units, entries)
	return preferredFirewall(entries), nil
}

func (a *api) servicesHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	if !a.authorized(r) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	switch r.Method {
	case http.MethodGet:
		services, err := a.services.list(r.Context())
		if err != nil {
			http.Error(w, "service list unavailable", http.StatusServiceUnavailable)
			return
		}
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		_ = json.NewEncoder(w).Encode(struct {
			Services []serviceEntry `json:"services"`
		}{services})
	case http.MethodPost:
		var command serviceCommand
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&command); err != nil {
			http.Error(w, "invalid or protected service action", http.StatusBadRequest)
			return
		}
		if err := a.applyServiceAction(r.Context(), command.Name, command.Action); err != nil {
			code := http.StatusConflict
			if errors.Is(err, errUnmanagedService) {
				code = http.StatusBadRequest
			}
			http.Error(w, err.Error(), code)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	default:
		w.Header().Set("Allow", "GET, POST")
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

// errUnmanagedService 表示这个服务不在面板的管理范围内。客户端与 MCP 都靠它
// 区分「参数不对」和「systemctl 执行失败」。
var errUnmanagedService = errors.New("service is not managed")

// applyServiceAction 执行一次服务操作。HTTP 接口和 MCP 工具都走这里：
// 校验、可见范围、超时、错误裁剪只有一份实现，两边的行为才不会分叉。
func (a *api) applyServiceAction(ctx context.Context, name, action string) error {
	if !validServiceName(name) || protectedService(name) || !validServiceAction(action) {
		return fmt.Errorf("invalid or protected service action: %w", errUnmanagedService)
	}
	visible, err := a.services.list(ctx)
	if err != nil {
		return errors.New("service list unavailable")
	}
	managed := false
	for _, entry := range visible {
		if entry.Name == name {
			managed = true
			break
		}
	}
	if !managed {
		return fmt.Errorf("面板不管这个服务：%s: %w", name, errUnmanagedService)
	}
	a.services.mu.Lock()
	defer a.services.mu.Unlock()
	ctx, cancel := context.WithTimeout(ctx, 90*time.Second)
	defer cancel()
	output, err := a.services.run(ctx, action, name)
	if err != nil {
		message := strings.TrimSpace(string(output))
		if message == "" {
			message = "systemctl action failed"
		}
		if len(message) > 1000 {
			message = message[:1000]
		}
		return errors.New(message)
	}
	return nil
}

func validServiceAction(action string) bool {
	switch action {
	case "start", "stop", "restart", "enable", "disable":
		return true
	default:
		return false
	}
}
