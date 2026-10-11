package main

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestServiceNamesAndActions(t *testing.T) {
	for _, name := range []string{"nginx.service", "httpd.service", "my-app@a.service"} {
		if !validServiceName(name) {
			t.Fatalf("valid service rejected: %q", name)
		}
	}
	for _, name := range []string{"", "-bad.service", "../bad.service", "nginx.service;id", "nginx.socket", "\n.service"} {
		if validServiceName(name) {
			t.Fatalf("invalid service accepted: %q", name)
		}
	}
	if validServiceAction("shell") || !validServiceAction("restart") || !protectedService("server-status.service") {
		t.Fatal("service action validation failed")
	}
}

func TestServiceListingAndActions(t *testing.T) {
	var commands [][]string
	runner := func(_ context.Context, args ...string) ([]byte, error) {
		commands = append(commands, args)
		switch args[0] {
		case "list-unit-files":
			return []byte("firewalld.service disabled disabled\nnftables.service enabled enabled\nnginx.service enabled enabled\n"), nil
		case "list-units":
			return []byte("firewalld.service loaded inactive dead firewalld\nnftables.service loaded inactive dead nftables\nnginx.service loaded active running NGINX web server\n"), nil
		case "restart":
			return nil, nil
		default:
			return nil, errors.New("unexpected command")
		}
	}
	a := &api{token: "secret", services: &serviceManager{run: runner}}
	request := func(method, body, token string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, "/v1/services", strings.NewReader(body))
		if token != "" {
			r.Header.Set("Authorization", "Bearer "+token)
		}
		w := httptest.NewRecorder()
		a.servicesHandler(w, r)
		return w
	}
	if got := request(http.MethodGet, "", "").Code; got != http.StatusUnauthorized {
		t.Fatalf("unauthorized listing: %d", got)
	}
	listing := request(http.MethodGet, "", "secret")
	if listing.Code != http.StatusOK || !strings.Contains(listing.Body.String(), `"name":"firewalld.service"`) ||
		!strings.Contains(listing.Body.String(), `"active_state":"inactive"`) ||
		strings.Contains(listing.Body.String(), `"name":"nftables.service"`) ||
		strings.Contains(listing.Body.String(), `"name":"nginx.service"`) {
		t.Fatalf("incorrect listing: %d %s", listing.Code, listing.Body.String())
	}
	before := len(commands)
	for _, body := range []string{
		`{"name":"../firewalld.service","action":"restart"}`,
		`{"name":"nginx.service","action":"sh"}`,
		`{"name":"server-status.service","action":"stop"}`,
	} {
		if got := request(http.MethodPost, body, "secret").Code; got != http.StatusBadRequest {
			t.Fatalf("invalid action accepted: %d", got)
		}
	}
	if len(commands) != before {
		t.Fatal("invalid action reached systemctl")
	}
	if got := request(http.MethodPost, `{"name":"nginx.service","action":"restart"}`, "secret").Code; got != http.StatusBadRequest {
		t.Fatalf("hidden service action accepted: %d", got)
	}
	if got := request(http.MethodPost, `{"name":"firewalld.service","action":"restart"}`, "secret").Code; got != http.StatusNoContent {
		t.Fatalf("valid action failed: %d", got)
	}
	last := commands[len(commands)-1]
	if len(last) != 2 || last[0] != "restart" || last[1] != "firewalld.service" {
		t.Fatalf("unexpected systemctl arguments: %v", last)
	}
}

func TestFirewallFallback(t *testing.T) {
	entries := map[string]*serviceEntry{
		"nftables.service": {Name: "nftables.service", UnitState: "enabled"},
		"nginx.service":    {Name: "nginx.service", UnitState: "enabled"},
	}
	selected := preferredFirewall(entries)
	if len(selected) != 1 || selected[0].Name != "nftables.service" {
		t.Fatalf("incorrect fallback: %v", selected)
	}
	entries["firewalld.service"] = &serviceEntry{Name: "firewalld.service", UnitState: "disabled", ActiveState: "inactive"}
	entries["nftables.service"].ActiveState = "active"
	selected = preferredFirewall(entries)
	if len(selected) != 1 || selected[0].Name != "nftables.service" {
		t.Fatalf("active firewall not preferred: %v", selected)
	}
}
