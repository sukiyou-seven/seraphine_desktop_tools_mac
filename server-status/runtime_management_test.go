package main

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

func TestVersionedRuntimePathsAndProjects(t *testing.T) {
	root := t.TempDir()
	sm := newSoftwareManager(root)
	em := newEnvironmentManager(sm)
	pm := newProjectManager(root, sm)
	base := em.versionPrefix("python", "3.13.16")
	if err := os.MkdirAll(filepath.Join(base, "bin"), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(base, ".sera-installed"), []byte("3.13.16\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(base, "bin", "python3"), []byte("#!/bin/sh\n"), 0755); err != nil {
		t.Fatal(err)
	}
	spec, _ := findEnvironment("python")
	installed := em.installations(spec)
	if len(installed) != 1 || installed[0].Version != "3.13.16" || installed[0].Legacy || !installed[0].Tools[0].Available {
		t.Fatalf("versioned installation: %+v", installed)
	}
	if pm.runtimeReadyVersion("python", "") {
		t.Fatal("legacy runtime unexpectedly ready")
	}
	if !pm.runtimeReadyVersion("python", "3.13.16") {
		t.Fatal("versioned runtime unavailable")
	}
	item := project{ID: "example", Runtime: "python", RuntimeVersion: "3.13.16", Entry: "main.py"}
	unit := string(pm.unit(item))
	if !strings.Contains(unit, base+"/bin/python3") || !strings.Contains(unit, "PATH="+base+"/bin:") {
		t.Fatalf("project unit ignores selected runtime: %s", unit)
	}
}

func TestRuntimeVersionAPIRejectsUnlistedVersion(t *testing.T) {
	root := t.TempDir()
	sm := newSoftwareManager(root)
	sm.supported = func(string) bool { return true }
	em := newEnvironmentManager(sm)
	a := &api{token: "secret", software: sm, environments: em}
	key := "bun/" + runtime.GOARCH
	releaseCache.Lock()
	releaseCache.entries[key] = releaseCacheEntry{[]runtimeRelease{{Version: "1.4.3", URL: "https://example.org/bun.zip", SHA256: strings.Repeat("a", 64), File: "bun.zip"}}, time.Now().Add(time.Minute)}
	releaseCache.Unlock()
	defer func() { releaseCache.Lock(); delete(releaseCache.entries, key); releaseCache.Unlock() }()
	request := func(method, path, body, token string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, path, strings.NewReader(body))
		if token != "" {
			r.Header.Set("Authorization", "Bearer "+token)
		}
		w := httptest.NewRecorder()
		a.environmentsHandler(w, r)
		return w
	}
	if got := request(http.MethodGet, "/v1/environments/bun/versions", "", "").Code; got != 401 {
		t.Fatalf("unauthorized release listing: %d", got)
	}
	if got := request(http.MethodGet, "/v1/environments/bun/versions", "", "secret"); got.Code != 200 || !strings.Contains(got.Body.String(), "1.4.3") {
		t.Fatalf("release listing: %d %s", got.Code, got.Body.String())
	}
	if got := request(http.MethodPost, "/v1/environments/bun/install", `{"version":"1.4.2"}`, "secret").Code; got != 400 {
		t.Fatalf("unlisted version accepted: %d", got)
	}
	if got := request(http.MethodPost, "/v1/environments/bun/install", `{"version":"../../etc"}`, "secret").Code; got != 400 {
		t.Fatalf("invalid version accepted: %d", got)
	}
}

func TestLegacyUninstallPreservesVersionedRuntime(t *testing.T) {
	root := t.TempDir()
	sm := newSoftwareManager(root)
	prefix := sm.prefix("bun")
	versioned := filepath.Join(prefix, "versions", "1.4.3")
	if err := os.MkdirAll(versioned, 0755); err != nil {
		t.Fatal(err)
	}
	for name, content := range map[string]string{
		filepath.Join(prefix, ".sera-installed"):    "1.4.2\n",
		filepath.Join(versioned, ".sera-installed"): "1.4.3\n",
		filepath.Join(versioned, "important.txt"):   "preserve",
	} {
		if err := os.WriteFile(name, []byte(content), 0600); err != nil {
			t.Fatal(err)
		}
	}
	backup, err := sm.uninstallNow(context.Background(), "bun", "backup", io.Discard)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(backup, ".sera-installed")); err != nil {
		t.Fatalf("legacy backup missing: %v", err)
	}
	if got, err := os.ReadFile(filepath.Join(versioned, "important.txt")); err != nil || string(got) != "preserve" {
		t.Fatalf("versioned runtime lost: %v %q", err, got)
	}
	if _, err := os.Stat(filepath.Join(prefix, ".sera-installed")); !os.IsNotExist(err) {
		t.Fatalf("legacy runtime remained: %v", err)
	}
	if err := os.WriteFile(filepath.Join(prefix, ".sera-installed"), []byte("1.4.2\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := sm.uninstallNow(context.Background(), "bun", "purge", io.Discard); err != nil {
		t.Fatal(err)
	}
	if got, err := os.ReadFile(filepath.Join(versioned, "important.txt")); err != nil || string(got) != "preserve" {
		t.Fatalf("versioned runtime lost on purge: %v %q", err, got)
	}
}
