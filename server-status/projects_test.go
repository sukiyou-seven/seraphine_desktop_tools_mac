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

func projectTestAPI(t *testing.T) (*api, *projectManager) {
	t.Helper()
	root := t.TempDir()
	software := newSoftwareManager(root)
	pm := newProjectManager(root, software)
	pm.unitDir = t.TempDir()
	pm.ensureUser = func() (int, int, error) { return os.Getuid(), os.Getgid(), nil }
	pm.systemctl = func(_ context.Context, args ...string) ([]byte, error) {
		switch args[0] {
		case "is-active":
			return []byte("inactive\n"), nil
		case "is-enabled":
			return []byte("disabled\n"), nil
		default:
			return nil, nil
		}
	}
	for _, runtime := range projectRuntimes {
		prefix := filepath.Join(root, "server", runtime.ID)
		binary := filepath.Join(prefix, runtime.Binary)
		if err := os.MkdirAll(filepath.Dir(binary), 0755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(binary, []byte("#!/bin/sh\nexit 0\n"), 0755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(prefix, ".sera-installed"), []byte("test"), 0644); err != nil {
			t.Fatal(err)
		}
	}
	return &api{token: "secret", software: software, projects: pm}, pm
}

func projectRequest(a *api, method, path, body string, authorized bool) *httptest.ResponseRecorder {
	r := httptest.NewRequest(method, path, strings.NewReader(body))
	if authorized {
		r.Header.Set("Authorization", "Bearer secret")
	}
	w := httptest.NewRecorder()
	a.projectsHandler(w, r)
	return w
}

func TestProjectsLifecycleAndIsolation(t *testing.T) {
	a, pm := projectTestAPI(t)
	if got := projectRequest(a, "GET", "/v1/projects", "", false).Code; got != 401 {
		t.Fatalf("unauthorized: %d", got)
	}
	listing := projectRequest(a, "GET", "/v1/projects", "", true)
	var initial projectListing
	if err := json.Unmarshal(listing.Body.Bytes(), &initial); err != nil {
		t.Fatal(err)
	}
	if len(initial.Runtimes) != 8 || len(initial.Items) != 0 {
		t.Fatalf("initial listing: %+v", initial)
	}
	for _, runtime := range initial.Runtimes {
		if !runtime.Installed {
			t.Fatalf("%s missing", runtime.ID)
		}
	}

	created := projectRequest(a, "POST", "/v1/projects", `{"id":"demo","name":"Demo","runtime":"python","entry":"main.py","port":3000}`, true)
	if created.Code != 201 {
		t.Fatalf("create: %d %s", created.Code, created.Body.String())
	}
	for _, path := range []string{filepath.Join(pm.root, "projects"), pm.projectDir("demo")} {
		info, err := os.Stat(path)
		if err != nil || info.Mode().Perm() != 0755 {
			t.Fatalf("project path not traversable: %s %v %v", path, info, err)
		}
	}
	unit, err := os.ReadFile(pm.unitPath("demo"))
	if err != nil {
		t.Fatal(err)
	}
	for _, expected := range []string{"User=sera-project", "ProtectSystem=strict", "ReadWritePaths=", "Environment=PORT=3000", "bin/python3", "StandardOutput=append:"} {
		if !strings.Contains(string(unit), expected) {
			t.Fatalf("unit missing %q: %s", expected, unit)
		}
	}
	if got := projectRequest(a, "POST", "/v1/projects/demo/action", `{"action":"start"}`, true).Code; got != 409 {
		t.Fatalf("missing entry started: %d", got)
	}
	entry := filepath.Join(pm.projectDir("demo"), "main.py")
	if err := os.WriteFile(entry, []byte("print('test')\n"), 0644); err != nil {
		t.Fatal(err)
	}
	started := projectRequest(a, "POST", "/v1/projects/demo/action", `{"action":"start"}`, true)
	if started.Code != 204 {
		t.Fatalf("start: %d %s", started.Code, started.Body.String())
	}
	if got := projectRequest(a, "POST", "/v1/projects/demo/action", `{"action":"shell"}`, true).Code; got != 409 {
		t.Fatalf("invalid action: %d", got)
	}
	if err := os.WriteFile(pm.logPath("demo"), []byte("hello project\n"), 0644); err != nil {
		t.Fatal(err)
	}
	log := projectRequest(a, "GET", "/v1/projects/demo/log", "", true)
	if log.Code != 200 || !strings.Contains(log.Body.String(), "hello project") {
		t.Fatalf("log: %d %s", log.Code, log.Body.String())
	}
	updated := projectRequest(a, "PUT", "/v1/projects/demo", `{"name":"Changed","runtime":"node","entry":"index.js","port":4100}`, true)
	if updated.Code != 204 {
		t.Fatalf("update: %d %s", updated.Code, updated.Body.String())
	}
	if got := projectRequest(a, "DELETE", "/v1/projects/demo", "", true).Code; got != 204 {
		t.Fatalf("delete: %d", got)
	}
	if _, err := os.Stat(entry); err != nil {
		t.Fatalf("project file removed: %v", err)
	}
	if _, err := os.Stat(pm.metaPath("demo")); !os.IsNotExist(err) {
		t.Fatalf("metadata remains: %v", err)
	}
	if _, err := os.Stat(pm.unitPath("demo")); !os.IsNotExist(err) {
		t.Fatalf("unit remains: %v", err)
	}
}

func TestPythonASGIUnitsAndWorkerValidation(t *testing.T) {
	_, pm := projectTestAPI(t)
	base := project{ID: "asgi", Name: "ASGI", Runtime: "python", UseVenv: true,
		Entry: "service/main.py", Port: 8123, PythonCallable: "app", PythonWorkers: 2}
	for _, test := range []struct{ server, worker, command string }{
		{"uvicorn", "", `"service.main:app" "--host" "127.0.0.1" "--port" "8123" "--workers" "2"`},
		{"gunicorn", "uvicorn", `"--worker-class" "uvicorn_worker.UvicornWorker" "service.main:app"`},
		{"gunicorn", "gthread", `"--worker-class" "gthread" "--threads" "1" "service.main:app"`},
	} {
		item := base
		item.PythonServer, item.PythonWorker = test.server, test.worker
		item, err := pm.normalize(item)
		if err != nil {
			t.Fatal(err)
		}
		if !strings.Contains(string(pm.unit(item)), test.command) {
			t.Fatalf("%s/%s missing %q", test.server, test.worker, test.command)
		}
	}
	invalid := base
	invalid.PythonServer, invalid.PythonWorker = "uvicorn", "gthread"
	if _, err := pm.normalize(invalid); err == nil {
		t.Fatal("accepted worker class for Uvicorn")
	}
	legacy := base
	legacy.PythonServer, legacy.PythonThreads = "gunicorn", 3
	legacy, err := pm.normalize(legacy)
	if err != nil || legacy.PythonWorker != "gthread" {
		t.Fatalf("legacy threads lost: %+v %v", legacy, err)
	}
}

func TestProjectsRejectTraversalAndSymlinkEscape(t *testing.T) {
	a, pm := projectTestAPI(t)
	for _, body := range []string{
		`{"id":"../bad","name":"Bad","runtime":"python","entry":"main.py"}`,
		`{"id":"bad","name":"Bad","runtime":"python","entry":"../main.py"}`,
		`{"id":"bad","name":"Bad","runtime":"python","entry":"/tmp/main.py"}`,
		`{"id":"bad","name":"Bad","runtime":"python","entry":"main.py\nExecStart=/bin/sh"}`,
		`{"id":"bad","name":"Bad","runtime":"shell","entry":"main.sh"}`,
	} {
		if got := projectRequest(a, "POST", "/v1/projects", body, true).Code; got != 409 {
			t.Fatalf("accepted %s: %d", body, got)
		}
	}
	create := projectRequest(a, "POST", "/v1/projects", `{"id":"link","name":"Link","runtime":"python","entry":"main.py"}`, true)
	if create.Code != 201 {
		t.Fatalf("create: %d %s", create.Code, create.Body.String())
	}
	outside := filepath.Join(t.TempDir(), "main.py")
	if err := os.WriteFile(outside, []byte("test"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(pm.projectDir("link"), "main.py")); err != nil {
		t.Fatal(err)
	}
	if got := projectRequest(a, "POST", "/v1/projects/link/action", `{"action":"start"}`, true).Code; got != 409 {
		t.Fatalf("symlink escape started: %d", got)
	}
	if err := os.Remove(filepath.Join(pm.projectDir("link"), "main.py")); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(pm.projectDir("link"), "main.py"), []byte("test"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(filepath.Join(pm.projectDir("link"), "data")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(t.TempDir(), filepath.Join(pm.projectDir("link"), "data")); err != nil {
		t.Fatal(err)
	}
	if got := projectRequest(a, "POST", "/v1/projects/link/action", `{"action":"start"}`, true).Code; got != 409 {
		t.Fatalf("data symlink started: %d", got)
	}
	if got := projectRequest(a, "GET", "/v1/projects/link/other", "", true).Code; got != 404 {
		t.Fatalf("unknown route: %d", got)
	}
}

func TestProjectCanBePreparedBeforeRuntimeInstallation(t *testing.T) {
	a, pm := projectTestAPI(t)
	legacy := filepath.Join(pm.root, "server", "python", ".sera-installed")
	if err := os.Remove(legacy); err != nil {
		t.Fatal(err)
	}
	created := projectRequest(a, "POST", "/v1/projects", `{"id":"future","name":"Future","runtime":"python","entry":"main.py","port":0}`, true)
	if created.Code != 201 {
		t.Fatalf("create before installation: %d %s", created.Code, created.Body.String())
	}
	var draft project
	if err := json.Unmarshal(created.Body.Bytes(), &draft); err != nil || draft.RuntimeReady {
		t.Fatalf("draft runtime state: %+v %v", draft, err)
	}
	if got := projectRequest(a, "POST", "/v1/projects/future/action", `{"action":"start"}`, true).Code; got != 409 {
		t.Fatalf("draft started without runtime: %d", got)
	}
	base := filepath.Join(pm.root, "server", "python", "versions", "3.13.16")
	if err := os.MkdirAll(filepath.Join(base, "bin"), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(base, ".sera-installed"), []byte("3.13.16"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(base, "bin", "python3"), []byte("#!/bin/sh\n"), 0755); err != nil {
		t.Fatal(err)
	}
	updated := projectRequest(a, "PUT", "/v1/projects/future", `{"name":"Future","runtime":"python","runtime_version":"3.13.16","entry":"main.py","port":0}`, true)
	if updated.Code != 204 {
		t.Fatalf("select installed version: %d %s", updated.Code, updated.Body.String())
	}
	listing := projectRequest(a, "GET", "/v1/projects", "", true)
	var result projectListing
	if err := json.Unmarshal(listing.Body.Bytes(), &result); err != nil || len(result.Items) != 1 ||
		result.Items[0].RuntimeVersion != "3.13.16" || !result.Items[0].RuntimeReady {
		t.Fatalf("ready project listing: %+v %v", result, err)
	}
}

func TestProjectUsesChosenServerDirectory(t *testing.T) {
	a, pm := projectTestAPI(t)
	codeDir := t.TempDir()
	payload, err := json.Marshal(project{ID: "outside", Name: "Existing code", Runtime: "python",
		Entry: "main.py", Directory: codeDir, UseVenv: true})
	if err != nil {
		t.Fatal(err)
	}
	created := projectRequest(a, "POST", "/v1/projects", string(payload), true)
	if created.Code != 201 {
		t.Fatalf("create with chosen directory: %d %s", created.Code, created.Body.String())
	}
	var item project
	if err := json.Unmarshal(created.Body.Bytes(), &item); err != nil || item.Directory != codeDir || !item.UseVenv || item.VenvReady {
		t.Fatalf("chosen directory or venv state: %+v %v", item, err)
	}
	unit, err := os.ReadFile(pm.unitPath("outside"))
	if err != nil {
		t.Fatal(err)
	}
	for _, expected := range []string{"WorkingDirectory=" + codeDir, codeDir + "/main.py", pm.venvDir("outside") + "/bin/python3"} {
		if !strings.Contains(string(unit), expected) {
			t.Fatalf("unit missing %q: %s", expected, unit)
		}
	}
	if got := projectRequest(a, "POST", "/v1/projects/outside/action", `{"action":"start"}`, true).Code; got != 409 {
		t.Fatalf("started without virtualenv: %d", got)
	}
}

func TestPythonWSGIServersValidateAndGenerateUnits(t *testing.T) {
	a, pm := projectTestAPI(t)
	for _, body := range []string{
		`{"id":"bad","name":"Bad","runtime":"python","entry":"main.py","port":8080,"python_server":"gunicorn"}`,
		`{"id":"bad","name":"Bad","runtime":"python","entry":"main.py","use_venv":true,"python_server":"gunicorn"}`,
		`{"id":"bad","name":"Bad","runtime":"python","entry":"bad-name.py","port":8080,"use_venv":true,"python_server":"gunicorn"}`,
		`{"id":"bad","name":"Bad","runtime":"python","entry":"main.py","port":8080,"use_venv":true,"python_server":"gunicorn","python_callable":"app;touch /tmp/bad"}`,
		`{"id":"bad","name":"Bad","runtime":"python","entry":"main.py","port":8080,"use_venv":true,"python_server":"uwsgi","python_workers":33}`,
	} {
		if got := projectRequest(a, "POST", "/v1/projects", body, true).Code; got != 409 {
			t.Fatalf("accepted invalid WSGI configuration %s: %d", body, got)
		}
	}
	created := projectRequest(a, "POST", "/v1/projects", `{"id":"web","name":"Web","runtime":"python","entry":"site/app.py","port":8080,"use_venv":true,"python_server":"gunicorn","python_worker":"gthread","python_callable":"application","python_workers":3,"python_threads":2}`, true)
	if created.Code != 201 {
		t.Fatalf("create Gunicorn project: %d %s", created.Code, created.Body.String())
	}
	unit, err := os.ReadFile(pm.unitPath("web"))
	if err != nil {
		t.Fatal(err)
	}
	for _, expected := range []string{"/data/venv/bin/gunicorn", "\"--bind\" \"127.0.0.1:8080\"", "\"--workers\" \"3\"", "\"--worker-class\" \"gthread\"", "\"--threads\" \"2\"", "\"site.app:application\""} {
		if !strings.Contains(string(unit), expected) {
			t.Fatalf("Gunicorn unit missing %q: %s", expected, unit)
		}
	}
	entry := filepath.Join(pm.projectDir("web"), "site", "app.py")
	if err := os.MkdirAll(filepath.Dir(entry), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(entry, []byte("application = None\n"), 0644); err != nil {
		t.Fatal(err)
	}
	if got := projectRequest(a, "POST", "/v1/projects/web/action", `{"action":"start"}`, true).Code; got != 409 {
		t.Fatalf("started without virtual environment: %d", got)
	}
	venv := pm.venvDir("web")
	if err := os.MkdirAll(filepath.Join(venv, "bin"), 0755); err != nil {
		t.Fatal(err)
	}
	for path, data := range map[string]string{
		filepath.Join(venv, ".sera-python-base"): pm.pythonBase(project{Runtime: "python"}) + "\n",
		filepath.Join(venv, "pyvenv.cfg"):        "home = test\n",
		filepath.Join(venv, "bin", "python3"):    "#!/bin/sh\n",
	} {
		if err := os.WriteFile(path, []byte(data), 0755); err != nil {
			t.Fatal(err)
		}
	}
	if got := projectRequest(a, "POST", "/v1/projects/web/action", `{"action":"start"}`, true).Code; got != 409 {
		t.Fatalf("started without Gunicorn: %d", got)
	}
	if err := os.WriteFile(filepath.Join(venv, "bin", "gunicorn"), []byte("#!/bin/sh\n"), 0755); err != nil {
		t.Fatal(err)
	}
	if got := projectRequest(a, "POST", "/v1/projects/web/action", `{"action":"start"}`, true).Code; got != 204 {
		t.Fatalf("Gunicorn start: %d", got)
	}
	updated := projectRequest(a, "PUT", "/v1/projects/web", `{"name":"Web","runtime":"python","entry":"site/app.py","port":8081,"use_venv":true,"python_server":"uwsgi","python_callable":"application","python_workers":2,"python_threads":1}`, true)
	if updated.Code != 204 {
		t.Fatalf("switch to uWSGI: %d %s", updated.Code, updated.Body.String())
	}
	unit, err = os.ReadFile(pm.unitPath("web"))
	if err != nil {
		t.Fatal(err)
	}
	for _, expected := range []string{"/data/venv/bin/uwsgi", "\"--http-socket\" \"127.0.0.1:8081\"", "\"--module\" \"site.app\"", "\"--callable\" \"application\""} {
		if !strings.Contains(string(unit), expected) {
			t.Fatalf("uWSGI unit missing %q: %s", expected, unit)
		}
	}
}
