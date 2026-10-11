package main

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestEnvironmentCatalogAndFixedToolChecks(t *testing.T) {
	root := t.TempDir()
	software := newSoftwareManager(root)
	software.supported = func(string) bool { return true }
	em := newEnvironmentManager(software)
	calls := []string{}
	em.run = func(_ context.Context, path string, args []string) (string, error) {
		calls = append(calls, path+" "+strings.Join(args, " "))
		return "Python 3.14.8\n", nil
	}
	for _, id := range []string{"python", "go"} {
		prefix := software.prefix(id)
		if err := os.MkdirAll(filepath.Join(prefix, "bin"), 0755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(prefix, ".sera-installed"), []byte("test"), 0644); err != nil {
			t.Fatal(err)
		}
	}
	python := filepath.Join(software.prefix("python"), "bin/python3")
	if err := os.WriteFile(python, []byte("test"), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("python3", filepath.Join(software.prefix("python"), "bin/pip3")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(t.TempDir(), filepath.Join(software.prefix("go"), "bin/go")); err != nil {
		t.Fatal(err)
	}
	a := &api{token: "secret", software: software, environments: em}
	request := func(method, path, token string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(method, path, nil)
		if token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
		}
		w := httptest.NewRecorder()
		a.environmentsHandler(w, req)
		return w
	}
	if got := request("GET", "/v1/environments", "").Code; got != 401 {
		t.Fatalf("unauthorized catalog: %d", got)
	}
	listing := request("GET", "/v1/environments", "secret")
	var catalog struct {
		Items []environmentItem `json:"items"`
	}
	if err := json.Unmarshal(listing.Body.Bytes(), &catalog); err != nil {
		t.Fatal(err)
	}
	if len(catalog.Items) != 9 || catalog.Items[0].ID != "python" || catalog.Items[0].State != "installed" {
		t.Fatalf("catalog: %+v", catalog.Items)
	}
	if len(catalog.Items[0].AvailableVersions) != 0 {
		t.Fatalf("environment listing must not embed release versions: %+v", catalog.Items[0])
	}
	if got := request("POST", "/v1/environments/python/check", "secret"); got.Code != 200 {
		t.Fatalf("python check: %d %s", got.Code, got.Body.String())
	} else {
		var item environmentItem
		if err := json.Unmarshal(got.Body.Bytes(), &item); err != nil {
			t.Fatal(err)
		}
		if len(item.Tools) != 2 || item.Tools[0].Version != "Python 3.14.8" || !item.Tools[1].Available {
			t.Fatalf("python tools: %+v", item.Tools)
		}
	}
	if len(calls) != 2 || !strings.HasPrefix(calls[0], python+" --version") {
		t.Fatalf("unapproved command: %v", calls)
	}
	goCheck := request("POST", "/v1/environments/go/check", "secret")
	if goCheck.Code != 200 || !strings.Contains(goCheck.Body.String(), "可执行文件不存在") {
		t.Fatalf("symlink escape accepted: %d %s", goCheck.Code, goCheck.Body.String())
	}
	if len(calls) != 2 {
		t.Fatalf("escaped tool executed: %v", calls)
	}
	if got := request("POST", "/v1/environments/docker/check", "secret").Code; got != 404 {
		t.Fatalf("unknown environment: %d", got)
	}
	if got := request("POST", "/v1/environments/node/check", "secret").Code; got != 409 {
		t.Fatalf("uninstalled environment: %d", got)
	}
}
