package main

import (
	"context"
	"errors"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestFirewallParsers(t *testing.T) {
	rules := parseFirewalldPorts([]byte("22/tcp 80/tcp 53/udp 1-10/tcp bad"))
	if len(rules) != 3 || rules[2].Port != 53 {
		t.Fatalf("firewalld: %+v", rules)
	}
	ufw := parseUFWPorts([]byte("Status: active\n22/tcp ALLOW Anywhere\n22/tcp (v6) ALLOW Anywhere (v6)\n8080/udp ALLOW 192.168.0.0/24\n"))
	if len(ufw) != 2 || ufw[0].Source != "Anywhere" {
		t.Fatalf("ufw: %+v", ufw)
	}
}

func TestFirewallChangesAndProtectedPorts(t *testing.T) {
	var calls []string
	ports := "22/tcp 27520/tcp"
	fm := &firewallManager{run: func(_ context.Context, name string, args ...string) ([]byte, error) {
		call := name + " " + strings.Join(args, " ")
		calls = append(calls, call)
		switch call {
		case "firewall-cmd --state":
			return []byte("running\n"), nil
		case "firewall-cmd --get-active-zones":
			return []byte("public\n  interfaces: eth0\n"), nil
		case "firewall-cmd --zone=public --list-ports":
			return []byte(ports), nil
		default:
			return []byte("success"), nil
		}
	}}
	if err := fm.change(context.Background(), firewallCommand{Action: "remove", Port: 27520, Protocol: "tcp"}); err == nil {
		t.Fatal("management port was removed")
	}
	if err := fm.change(context.Background(), firewallCommand{Action: "add", Port: 8080, Protocol: "tcp"}); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(strings.Join(calls, "\n"), "--permanent --zone=public --add-port=8080/tcp") {
		t.Fatalf("missing persistent rule: %v", calls)
	}
	ports += " 8080/tcp"
	if err := fm.change(context.Background(), firewallCommand{Action: "remove", Port: 8080, Protocol: "tcp"}); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(strings.Join(calls, "\n"), "--remove-port=8080/tcp") {
		t.Fatalf("missing removal: %v", calls)
	}
}

func TestFirewallAPIRequiresTokenAndValidatedRule(t *testing.T) {
	a := &api{token: "secret", firewall: &firewallManager{run: func(_ context.Context, name string, args ...string) ([]byte, error) {
		if name == "firewall-cmd" {
			return nil, errors.New("missing")
		}
		return []byte("Status: inactive"), nil
	}}}
	request := func(method, token, body string) int {
		r := httptest.NewRequest(method, "/v1/firewall", strings.NewReader(body))
		r.Header.Set("Authorization", token)
		w := httptest.NewRecorder()
		a.firewallHandler(w, r)
		return w.Code
	}
	if got := request("GET", "", ""); got != 401 {
		t.Fatalf("unauthorized: %d", got)
	}
	if got := request("POST", "Bearer secret", `{"action":"add","port":70000,"protocol":"tcp"}`); got != 400 {
		t.Fatalf("invalid port: %d", got)
	}
	if got := request("GET", "Bearer secret", ""); got != 200 {
		t.Fatalf("list without backend: %d", got)
	}
}
