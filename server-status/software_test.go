package main

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestSoftwareAPIInstallAndService(t *testing.T) {
	root := t.TempDir()
	sm := newSoftwareManager(root)
	sm.supported = func(string) bool { return true }
	started := make(chan struct{})
	release := make(chan struct{})
	sm.run = func(_ context.Context, id, version string, output io.Writer) error {
		_, _ = io.WriteString(output, "SERA_STAGE:测试安装中\n")
		close(started)
		<-release
		prefix := sm.prefix(id)
		if err := os.MkdirAll(prefix, 0755); err != nil {
			return err
		}
		return os.WriteFile(filepath.Join(prefix, ".sera-installed"), []byte("test"), 0600)
	}
	var serviceAction []string
	sm.systemctl = func(_ context.Context, args ...string) ([]byte, error) {
		if args[0] == "is-active" {
			return []byte("active\n"), nil
		}
		if args[0] == "is-enabled" {
			return []byte("enabled\n"), nil
		}
		serviceAction = args
		return nil, nil
	}
	a := &api{token: "secret", software: sm}
	request := func(method, path, body, token string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, path, strings.NewReader(body))
		if token != "" {
			r.Header.Set("Authorization", "Bearer "+token)
		}
		w := httptest.NewRecorder()
		a.softwareHandler(w, r)
		return w
	}
	if got := request("GET", "/v1/software", "", "").Code; got != 401 {
		t.Fatalf("unauthorized catalog accepted: %d", got)
	}
	listing := request("GET", "/v1/software", "", "secret")
	if listing.Code != 200 || !strings.Contains(listing.Body.String(), `"id":"nginx"`) ||
		!strings.Contains(listing.Body.String(), `"id":"mysql"`) ||
		!strings.Contains(listing.Body.String(), `"id":"redis"`) ||
		!strings.Contains(listing.Body.String(), `"id":"php"`) {
		t.Fatalf("catalog unavailable: %d %s", listing.Code, listing.Body.String())
	}
	if got := request("POST", "/v1/software/other/install", "", "secret").Code; got != 404 {
		t.Fatalf("unknown package accepted: %d", got)
	}
	if got := request("POST", "/v1/software/node/service", `{"action":"start"}`, "secret").Code; got != http.StatusConflict {
		t.Fatalf("runtime service accepted: %d", got)
	}
	var catalog struct {
		Items []softwareItem `json:"items"`
	}
	if err := json.Unmarshal(listing.Body.Bytes(), &catalog); err != nil {
		t.Fatal(err)
	}
	if len(catalog.Items) != 35 || !catalog.Items[0].InstallAvailable || !catalog.Items[1].InstallAvailable || catalog.Items[1].Category != "Web 服务" {
		t.Fatalf("catalog availability mismatch: %+v", catalog.Items)
	}
	if got := request("POST", "/v1/software/nginx/install", "", "secret").Code; got != 202 {
		t.Fatalf("install not accepted: %d", got)
	}
	<-started
	if got := request("POST", "/v1/software/mysql/install", "", "secret").Code; got != 202 {
		t.Fatalf("parallel installation not queued: %d", got)
	}
	if got := request("POST", "/v1/software/mysql/cancel", "", "secret").Code; got != 204 {
		t.Fatalf("queued cancellation: %d", got)
	}
	installing := request("GET", "/v1/software", "", "secret")
	if !strings.Contains(installing.Body.String(), `"state":"installing"`) ||
		!strings.Contains(installing.Body.String(), "测试安装中") {
		t.Fatalf("install progress unavailable: %s", installing.Body.String())
	}
	close(release)
	deadline := time.Now().Add(2 * time.Second)
	for {
		sm.mu.Lock()
		busy := sm.busy
		sm.mu.Unlock()
		if !busy {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("installation did not finish")
		}
		time.Sleep(time.Millisecond)
	}
	installed := request("GET", "/v1/software", "", "secret")
	var decoded struct {
		Items []softwareItem `json:"items"`
	}
	if err := json.Unmarshal(installed.Body.Bytes(), &decoded); err != nil {
		t.Fatal(err)
	}
	if len(decoded.Items) != len(softwareCatalog) || decoded.Items[0].State != "installed" || decoded.Items[0].ServiceState != "active" {
		t.Fatalf("installed status mismatch: %+v", decoded.Items)
	}
	if got := request("POST", "/v1/software/nginx/service", `{"action":"shell"}`, "secret").Code; got != 400 {
		t.Fatalf("arbitrary service action accepted: %d", got)
	}
	if got := request("POST", "/v1/software/nginx/service", `{"action":"restart"}`, "secret").Code; got != 204 {
		t.Fatalf("service action failed: %d", got)
	}
	if len(serviceAction) != 2 || serviceAction[0] != "restart" || serviceAction[1] != "sera-nginx.service" {
		t.Fatalf("unexpected service command: %v", serviceAction)
	}
	log := request("GET", "/v1/software/nginx/log", "", "secret")
	if log.Code != http.StatusOK || !strings.Contains(log.Body.String(), "测试安装中") {
		t.Fatalf("install log unavailable: %d %s", log.Code, log.Body.String())
	}
}

func TestSoftwareQueueAndCancelRunningJob(t *testing.T) {
	sm := newSoftwareManager(t.TempDir())
	sm.supported = func(string) bool { return true }
	started := make(chan struct{})
	sm.run = func(ctx context.Context, id, version string, output io.Writer) error {
		if id == "nginx" {
			close(started)
			<-ctx.Done()
			return ctx.Err()
		}
		prefix := sm.prefix(id)
		if err := os.MkdirAll(prefix, 0755); err != nil {
			return err
		}
		return os.WriteFile(filepath.Join(prefix, ".sera-installed"), []byte(version), 0600)
	}
	if err := sm.install("nginx", ""); err != nil {
		t.Fatal(err)
	}
	<-started
	if err := sm.install("mysql", ""); err != nil {
		t.Fatal(err)
	}
	if got := sm.jobs["mysql"].state; got != "queued" {
		t.Fatalf("not queued: %s", got)
	}
	if err := sm.cancelJob("nginx"); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		sm.mu.Lock()
		first, second := sm.jobs["nginx"].state, sm.jobs["mysql"].state
		sm.mu.Unlock()
		if first == "cancelled" && second == "installed" {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("queued job did not run after cancellation")
}

func TestSoftwareStoreDefaultRuntimeVersion(t *testing.T) {
	sm := newSoftwareManager(t.TempDir())
	sm.supported = func(string) bool { return true }
	selected := make(chan string, 1)
	sm.run = func(_ context.Context, id, version string, _ io.Writer) error {
		selected <- id + ":" + version
		prefix := sm.prefix(id)
		if err := os.MkdirAll(prefix, 0755); err != nil {
			return err
		}
		return os.WriteFile(filepath.Join(prefix, ".sera-installed"), []byte(version+"\n"), 0600)
	}
	a := &api{token: "secret", software: sm}
	request := func(body string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(http.MethodPost, "/v1/software/node/install", strings.NewReader(body))
		r.Header.Set("Authorization", "Bearer secret")
		w := httptest.NewRecorder()
		a.softwareHandler(w, r)
		return w
	}
	if got := request(`{"version":"22.23.3; rm -rf /"}`).Code; got != http.StatusBadRequest {
		t.Fatalf("unapproved version accepted: %d", got)
	}
	if got := request(`{"version":"22.23.3"}`).Code; got != http.StatusBadRequest {
		t.Fatalf("software store accepted non-default version: %d", got)
	}
	if got := request(`{"version":"24.21.0"}`).Code; got != http.StatusAccepted {
		t.Fatalf("software store default rejected: %d", got)
	}
	select {
	case got := <-selected:
		if got != "node:24.21.0" {
			t.Fatalf("wrong installer version: %s", got)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("installer was not started")
	}
	waitSoftwareIdle(t, sm)
	spec, _ := findSoftware("node")
	if got := sm.item(context.Background(), spec).Version; got != "24.21.0" {
		t.Fatalf("installed version was not reported: %s", got)
	}
}

func TestSoftwareUninstallBackupAndPurge(t *testing.T) {
	root := t.TempDir()
	sm := newSoftwareManager(root)
	sm.unitDir = filepath.Join(root, "units")
	sm.supported = func(string) bool { return true }
	if err := os.MkdirAll(sm.unitDir, 0755); err != nil {
		t.Fatal(err)
	}
	createInstalled := func() {
		t.Helper()
		prefix := sm.prefix("nginx")
		if err := os.MkdirAll(filepath.Join(prefix, "data"), 0755); err != nil {
			t.Fatal(err)
		}
		for name, content := range map[string]string{
			".sera-installed": "1", "data/important.txt": "keep me",
		} {
			if err := os.WriteFile(filepath.Join(prefix, name), []byte(content), 0600); err != nil {
				t.Fatal(err)
			}
		}
		if err := os.WriteFile(filepath.Join(sm.unitDir, "sera-nginx.service"), []byte("[Unit]\n"), 0644); err != nil {
			t.Fatal(err)
		}
	}
	createInstalled()
	var actions []string
	started := make(chan struct{})
	release := make(chan struct{})
	sm.systemctl = func(_ context.Context, args ...string) ([]byte, error) {
		actions = append(actions, strings.Join(args, " "))
		if args[0] == "stop" && len(actions) == 1 {
			close(started)
			<-release
		}
		return nil, nil
	}
	a := &api{token: "secret", software: sm}
	request := func(path, body, token string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(http.MethodPost, path, strings.NewReader(body))
		if token != "" {
			r.Header.Set("Authorization", "Bearer "+token)
		}
		w := httptest.NewRecorder()
		a.softwareHandler(w, r)
		return w
	}
	path := "/v1/software/nginx/uninstall"
	if got := request(path, `{"mode":"backup"}`, "").Code; got != http.StatusUnauthorized {
		t.Fatalf("unauthorized uninstall accepted: %d", got)
	}
	if got := request(path, `{"mode":"other"}`, "secret").Code; got != http.StatusBadRequest {
		t.Fatalf("invalid mode accepted: %d", got)
	}
	if got := request(path, `{"mode":"backup"}`, "secret").Code; got != http.StatusAccepted {
		t.Fatalf("backup uninstall rejected: %d", got)
	}
	<-started
	if got := sm.item(context.Background(), softwareCatalog[0]); got.State != "uninstalling" {
		t.Fatalf("uninstall progress missing: %+v", got)
	}
	if got := request("/v1/software/mysql/install", "", "secret").Code; got != http.StatusAccepted {
		t.Fatalf("parallel install not queued: %d", got)
	}
	if got := request("/v1/software/mysql/cancel", "", "secret").Code; got != http.StatusNoContent {
		t.Fatalf("queued cancellation: %d", got)
	}
	if got := request("/v1/software/nginx/service", `{"action":"start"}`, "secret").Code; got != http.StatusConflict {
		t.Fatalf("service action during uninstall accepted: %d", got)
	}
	close(release)
	waitSoftwareIdle(t, sm)
	if got := strings.Join(actions, ","); got != "stop sera-nginx.service,disable sera-nginx.service,daemon-reload" {
		t.Fatalf("unexpected systemd actions: %s", got)
	}
	if _, err := os.Stat(sm.prefix("nginx")); !os.IsNotExist(err) {
		t.Fatalf("installation remained after backup: %v", err)
	}
	if _, err := os.Stat(filepath.Join(sm.unitDir, "sera-nginx.service")); !os.IsNotExist(err) {
		t.Fatalf("service unit remained after backup: %v", err)
	}
	backups, err := os.ReadDir(filepath.Join(root, "backup", "software"))
	if err != nil || len(backups) != 1 {
		t.Fatalf("backup directory missing: %v %+v", err, backups)
	}
	backupPath := filepath.Join(root, "backup", "software", backups[0].Name(), "install")
	content, err := os.ReadFile(filepath.Join(backupPath, "data", "important.txt"))
	if err != nil || string(content) != "keep me" {
		t.Fatalf("data not preserved: %v %q", err, content)
	}
	if got := sm.item(context.Background(), softwareCatalog[0]); got.State != "not_installed" || !strings.Contains(got.Message, backupPath) {
		t.Fatalf("backup result missing: %+v", got)
	}

	createInstalled()
	if got := request(path, `{"mode":"purge"}`, "secret").Code; got != http.StatusAccepted {
		t.Fatalf("purge uninstall rejected: %d", got)
	}
	waitSoftwareIdle(t, sm)
	if _, err := os.Stat(sm.prefix("nginx")); !os.IsNotExist(err) {
		t.Fatalf("installation remained after purge: %v", err)
	}
	backupsAfter, err := os.ReadDir(filepath.Join(root, "backup", "software"))
	if err != nil || len(backupsAfter) != 1 {
		t.Fatalf("purge created a backup: %v %+v", err, backupsAfter)
	}
}

func TestSoftwareUninstallRejectsSymlink(t *testing.T) {
	root := t.TempDir()
	sm := newSoftwareManager(root)
	target := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "server"), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(target, ".sera-installed"), []byte("1"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, sm.prefix("nginx")); err != nil {
		t.Fatal(err)
	}
	if err := sm.uninstall("nginx", "purge"); err == nil {
		t.Fatal("symlink installation accepted")
	}
	if _, err := os.Stat(filepath.Join(target, ".sera-installed")); err != nil {
		t.Fatalf("symlink target was changed: %v", err)
	}
}

func waitSoftwareIdle(t *testing.T, sm *softwareManager) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for {
		sm.mu.Lock()
		busy := sm.busy
		sm.mu.Unlock()
		if !busy {
			return
		}
		if time.Now().After(deadline) {
			t.Fatal("software operation did not finish")
		}
		time.Sleep(time.Millisecond)
	}
}

func TestEverySoftwareHasAnInstaller(t *testing.T) {
	common, err := installerScripts.ReadFile("installers/common.sh")
	if err != nil {
		t.Fatal(err)
	}
	seen := make(map[string]bool)
	for _, spec := range softwareCatalog {
		if seen[spec.id] || !spec.installable || spec.version == "" {
			t.Fatalf("incomplete catalog entry: %+v", spec)
		}
		seen[spec.id] = true
		script, err := installerScripts.ReadFile("installers/" + spec.id + ".sh")
		if err != nil {
			t.Fatalf("%s installer missing: %v", spec.id, err)
		}
		command := exec.Command("sh", "-n")
		command.Stdin = strings.NewReader(string(common) + "\n" + string(script))
		if output, err := command.CombinedOutput(); err != nil {
			t.Fatalf("%s installer syntax: %s: %v", spec.id, output, err)
		}
	}
}

func TestSoftwareSupportedOnPackageFamilies(t *testing.T) {
	for _, tc := range []struct {
		id, os, arch              string
		packages, systemctl, want bool
	}{
		{"nginx", "linux", "amd64", true, true, true},
		{"nginx", "linux", "arm64", true, true, true},
		{"nginx", "linux", "amd64", false, true, false},
		{"nginx", "linux", "amd64", true, false, false},
		{"mysql", "linux", "amd64", true, true, true},
		{"mysql", "linux", "arm64", true, true, false},
		{"grafana", "linux", "amd64", false, true, true},
		{"nginx", "darwin", "amd64", true, true, false},
	} {
		got := softwareSupported(tc.id, tc.os, tc.arch, tc.packages, tc.systemctl)
		if got != tc.want {
			t.Errorf("%s %s/%s packages=%v systemctl=%v: got %v, want %v", tc.id, tc.os, tc.arch, tc.packages, tc.systemctl, got, tc.want)
		}
	}
}

func TestInstalledRuntimeDoesNotQuerySystemd(t *testing.T) {
	sm := newSoftwareManager(t.TempDir())
	sm.supported = func(string) bool { return true }
	sm.systemctl = func(context.Context, ...string) ([]byte, error) {
		t.Fatal("runtime must not query systemd")
		return nil, nil
	}
	for _, id := range []string{"node", "go"} {
		prefix := sm.prefix(id)
		if err := os.MkdirAll(prefix, 0755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(prefix, ".sera-installed"), []byte("test"), 0600); err != nil {
			t.Fatal(err)
		}
		spec, ok := findSoftware(id)
		if !ok {
			t.Fatalf("missing %s catalog entry", id)
		}
		item := sm.item(context.Background(), spec)
		if item.State != "installed" || item.ServiceAvailable || !item.InstallAvailable {
			t.Fatalf("unexpected %s runtime item: %+v", id, item)
		}
	}
}
