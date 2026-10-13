package main

import (
	"context"
	"encoding/json"
	"errors"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestSitesLifecycleAcrossProviders(t *testing.T) {
	root := t.TempDir()
	software := newSoftwareManager(root)
	sites := newSiteManager(root, software)
	for _, provider := range siteProviders {
		base := sites.basePath(provider.ID)
		if err := os.MkdirAll(filepath.Dir(base), 0755); err != nil {
			t.Fatal(err)
		}
		config := "http {\n}\n"
		if provider.ID == "apache" {
			config = "ServerRoot \"/tmp\"\n"
		}
		if err := os.WriteFile(base, []byte(config), 0644); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(root, "server", provider.ID, ".sera-installed"), []byte("test"), 0644); err != nil {
			t.Fatal(err)
		}
	}
	sites.test = func(context.Context, string) error { return nil }
	sites.isRunning = func(context.Context, string) bool { return true }
	sites.reload = func(context.Context, string) error { return nil }
	a := &api{token: "secret", software: software, sites: sites}
	request := func(method, path, body string, authorized bool) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, path, strings.NewReader(body))
		if authorized {
			r.Header.Set("Authorization", "Bearer secret")
		}
		w := httptest.NewRecorder()
		a.sitesHandler(w, r)
		return w
	}
	if got := request("GET", "/v1/sites", "", false).Code; got != 401 {
		t.Fatalf("unauthorized: %d", got)
	}
	for _, provider := range siteProviders {
		domain := provider.ID + ".example.com"
		body := `{"provider":"` + provider.ID + `","domains":["` + domain + `"],"kind":"static","enabled":true}`
		response := request("POST", "/v1/sites", body, true)
		if response.Code != 201 {
			t.Fatalf("%s create: %d %s", provider.ID, response.Code, response.Body.String())
		}
		var item site
		if err := json.Unmarshal(response.Body.Bytes(), &item); err != nil {
			t.Fatal(err)
		}
		if item.ID != domain || item.Root != filepath.Join(root, "web", provider.ID, domain) {
			t.Fatalf("item: %+v", item)
		}
		if err := os.WriteFile(filepath.Join(item.Root, "index.html"), []byte("keep"), 0644); err != nil {
			t.Fatal(err)
		}
		conf, err := os.ReadFile(sites.confPath(provider.ID, domain))
		if err != nil || !strings.Contains(string(conf), domain) {
			t.Fatalf("config: %s %v", conf, err)
		}
		base, _ := os.ReadFile(sites.basePath(provider.ID))
		if !strings.Contains(string(base), filepath.Join(root, "sites", provider.ID, "*.conf")) {
			t.Fatalf("include missing: %s", base)
		}
		update := request("PUT", "/v1/sites/"+provider.ID+"/"+domain, `{"domains":["`+domain+`"],"kind":"proxy","upstream":"http://127.0.0.1:3000","enabled":true}`, true)
		if update.Code != 204 {
			t.Fatalf("%s update: %d %s", provider.ID, update.Code, update.Body.String())
		}
		conf, _ = os.ReadFile(sites.confPath(provider.ID, domain))
		if !strings.Contains(string(conf), "127.0.0.1:3000") {
			t.Fatalf("proxy missing: %s", conf)
		}
		if got := request("POST", "/v1/sites", body, true).Code; got != 409 {
			t.Fatalf("duplicate accepted: %d", got)
		}
		disable := request("PUT", "/v1/sites/"+provider.ID+"/"+domain, `{"domains":["`+domain+`"],"kind":"static","enabled":false}`, true)
		if disable.Code != 204 {
			t.Fatalf("disable: %d %s", disable.Code, disable.Body.String())
		}
		if _, err := os.Stat(sites.confPath(provider.ID, domain)); !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("disabled config remains: %v", err)
		}
		if got := request("DELETE", "/v1/sites/"+provider.ID+"/"+domain, "", true).Code; got != 204 {
			t.Fatalf("delete: %d", got)
		}
		if data, err := os.ReadFile(filepath.Join(item.Root, "index.html")); err != nil || string(data) != "keep" {
			t.Fatalf("content lost: %s %v", data, err)
		}
	}
	for _, domain := range []string{"bad;name.com", "../evil", "with space.com"} {
		body := `{"provider":"nginx","domains":["` + domain + `"],"kind":"static","enabled":true}`
		if got := request("POST", "/v1/sites", body, true).Code; got != 400 {
			t.Fatalf("invalid domain %q: %d", domain, got)
		}
	}
	listing := request("GET", "/v1/sites", "", true)
	var result siteListing
	if err := json.Unmarshal(listing.Body.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	if len(result.Items) != 0 || len(result.Providers) != 3 {
		t.Fatalf("listing: %+v", result)
	}
}

func TestSitesRollbackAndSymlink(t *testing.T) {
	root := t.TempDir()
	software := newSoftwareManager(root)
	sites := newSiteManager(root, software)
	base := sites.basePath("nginx")
	if err := os.MkdirAll(filepath.Dir(base), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(base, []byte("http {\n}\n"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "server/nginx/.sera-installed"), []byte("test"), 0644); err != nil {
		t.Fatal(err)
	}
	sites.test = func(context.Context, string) error { return nil }
	sites.isRunning = func(context.Context, string) bool { return false }
	starts := 0
	sites.start = func(context.Context, string) error { starts++; return nil }
	item := site{ID: "example.com", Provider: "nginx", Domains: []string{"example.com"}, Kind: "static", Root: filepath.Join(root, "web/nginx/example.com"), Enabled: true}
	if _, err := sites.apply(item, false, true); err != nil {
		t.Fatal(err)
	}
	if starts != 1 {
		t.Fatalf("enabled website did not start Nginx: %d", starts)
	}
	before, _ := os.ReadFile(sites.confPath("nginx", item.ID))
	sites.test = func(context.Context, string) error { return errors.New("syntax rejected") }
	item.Domains = []string{"changed.example.com"}
	if _, err := sites.apply(item, false, false); err == nil {
		t.Fatal("invalid config accepted")
	}
	after, _ := os.ReadFile(sites.confPath("nginx", item.ID))
	if string(after) != string(before) {
		t.Fatal("config not rolled back")
	}
	saved, err := sites.read("nginx", item.ID)
	if err != nil || saved.Domains[0] != "example.com" {
		t.Fatalf("metadata not rolled back: %+v %v", saved, err)
	}
	link := filepath.Join(root, "web/nginx/linked.example.com")
	if err := os.Symlink(t.TempDir(), link); err != nil {
		t.Fatal(err)
	}
	item.ID = "linked.example.com"
	item.Domains = []string{item.ID}
	item.Root = link
	if _, err := sites.apply(item, false, true); err == nil {
		t.Fatal("symlink root accepted")
	}
}

func TestPHPSitesUseInstalledFPMAndStaticSitesHidePHPSource(t *testing.T) {
	root := t.TempDir()
	sites := newSiteManager(root, newSoftwareManager(root))
	for _, provider := range siteProviders {
		base := sites.basePath(provider.ID)
		if err := os.MkdirAll(filepath.Dir(base), 0755); err != nil {
			t.Fatal(err)
		}
		config := "http {\n}\n"
		if provider.ID == "apache" {
			config = "ServerRoot \"/tmp\"\n"
		}
		if err := os.WriteFile(base, []byte(config), 0644); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(root, "server", provider.ID, ".sera-installed"), []byte("test"), 0644); err != nil {
			t.Fatal(err)
		}
	}
	legacy := filepath.Join(root, "server/php")
	if err := os.MkdirAll(legacy, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(legacy, ".sera-installed"), []byte("8.4.26\n"), 0644); err != nil {
		t.Fatal(err)
	}
	versioned := filepath.Join(legacy, "versions/8.3.35")
	if err := os.MkdirAll(versioned, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(versioned, ".sera-installed"), []byte("8.3.35\n"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(versioned, "run"), 0700); err != nil {
		t.Fatal(err)
	}
	if got := sites.phpVersions(); len(got) != 2 || got[0] != "8.4.26" || got[1] != "8.3.35" {
		t.Fatalf("versions: %v", got)
	}
	started := []string{}
	running := map[string]bool{}
	sites.phpReady = func(string) bool { return true }
	sites.software.systemctl = func(_ context.Context, args ...string) ([]byte, error) {
		if args[0] == "is-active" {
			if running[args[1]] {
				return []byte("active"), nil
			}
			return []byte("inactive"), errors.New("inactive")
		}
		started = append(started, args[1])
		running[args[1]] = true
		return nil, nil
	}
	if err := sites.ensurePHP(context.Background(), "8.4.26"); err != nil {
		t.Fatal(err)
	}
	if err := sites.ensurePHP(context.Background(), "8.3.35"); err != nil {
		t.Fatal(err)
	}
	if len(started) != 2 || started[0] != "sera-php.service" || started[1] != "sera-php-8.3.35.service" {
		t.Fatalf("unexpected FPM services: %v", started)
	}
	if info, err := os.Stat(filepath.Join(versioned, "run")); err != nil || info.Mode().Perm() != 0750 {
		t.Fatalf("versioned socket directory must be accessible to web group: %v %v", info, err)
	}
	if _, err := sites.normalize(site{Provider: "nginx", Domains: []string{"x.example.com"}, Kind: "php", PHPVersion: "8.2.1"}); err == nil {
		t.Fatal("uninstalled PHP accepted")
	}
	for _, provider := range siteProviders {
		base := site{ID: provider.ID + ".example.com", Provider: provider.ID, Domains: []string{provider.ID + ".example.com"}, Root: filepath.Join(root, "web", provider.ID, provider.ID+".example.com"), Enabled: true}
		static := base
		static.Kind = "static"
		staticConfig := string(siteConfig(static, provider.Port, ""))
		if !strings.Contains(staticConfig, "\\.php$") || !strings.Contains(staticConfig, "denied") && !strings.Contains(staticConfig, "return 404") {
			t.Fatalf("%s can expose PHP source: %s", provider.ID, staticConfig)
		}
		php := base
		php.Kind, php.PHPVersion = "php", "8.4.26"
		legacyTarget, err := sites.phpTarget(php.PHPVersion)
		if err != nil {
			t.Fatal(err)
		}
		config := string(siteConfig(php, provider.Port, legacyTarget))
		if !strings.Contains(config, "127.0.0.1:9000") || !strings.Contains(config, "index.php") {
			t.Fatalf("%s PHP handler missing: %s", provider.ID, config)
		}
		php.PHPVersion = "8.3.35"
		versionTarget, err := sites.phpTarget(php.PHPVersion)
		if err != nil || !strings.HasPrefix(versionTarget, "unix:") {
			t.Fatalf("version target: %q %v", versionTarget, err)
		}
		config = string(siteConfig(php, provider.Port, versionTarget))
		if !strings.Contains(config, "php-fpm.sock") {
			t.Fatalf("%s versioned handler missing: %s", provider.ID, config)
		}
	}
	base := "ServerRoot \"/tmp\"\nGroup seraphim-apache\nIncludeOptional " + filepath.Join(root, "sites/apache/*.conf") + "\n"
	config, err := siteInclude(base, "apache", root, true)
	if err != nil || !strings.Contains(string(config), "LoadModule proxy_fcgi_module modules/mod_proxy_fcgi.so") || !strings.Contains(string(config), "Group seraphim-web") {
		t.Fatalf("Apache proxy_fcgi missing: %s %v", config, err)
	}
	for _, provider := range []string{"nginx", "openresty"} {
		config, err := siteInclude("http {\n    include "+filepath.Join(root, "sites", provider, "*.conf")+";\n}\n", provider, root, true)
		if err != nil || !strings.HasPrefix(string(config), "user seraphim-web;\n") {
			t.Fatalf("%s web worker cannot access PHP socket: %s %v", provider, config, err)
		}
	}
}
