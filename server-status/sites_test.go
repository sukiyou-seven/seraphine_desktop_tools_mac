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
	item := site{ID: "example.com", Provider: "nginx", Domains: []string{"example.com"}, Kind: "static", Root: filepath.Join(root, "web/nginx/example.com"), Enabled: true}
	if _, err := sites.apply(item, false, true); err != nil {
		t.Fatal(err)
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
