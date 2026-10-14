package main

import (
	"context"
	"encoding/json"
	"errors"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
	"testing"
)

// stubSiteRuntime 让测试不必真的创建系统账户，也不必碰 systemd：
// 站点与项目的运行身份是共享账户，这里把它指向当前进程即可。
func stubSiteRuntime(sites *siteManager) {
	sites.ensureUser = func() (int, int, error) { return os.Getuid(), os.Getgid(), nil }
}

func TestSitesLifecycleAcrossProviders(t *testing.T) {
	root := t.TempDir()
	software := newSoftwareManager(root)
	sites := newSiteManager(root, software)
	stubSiteRuntime(sites)
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
	stubSiteRuntime(sites)
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
	// 面板服务单元里写着 UMask=0077；这里复现同一个 umask，任何"依赖 umask 恰好
	// 是 0022"的写法都会在这个测试里暴露出来。
	previousUmask := syscall.Umask(0077)
	defer syscall.Umask(previousUmask)
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
	if got := sites.phpVersions(); len(got) != 2 || got[0] != "8.4.26" || got[1] != "8.3.35" {
		t.Fatalf("versions: %v", got)
	}
	sites.unitDir = t.TempDir()
	stubSiteRuntime(sites)
	sites.phpReady = func(string) bool { return true }
	active := false
	calls := []string{}
	sites.software.systemctl = func(_ context.Context, args ...string) ([]byte, error) {
		calls = append(calls, strings.Join(args, " "))
		switch args[0] {
		case "is-active":
			if active {
				return []byte("active"), nil
			}
			return []byte("inactive"), errors.New("inactive")
		case "start":
			active = true
		}
		return nil, nil
	}
	item := site{ID: "php.example.com", Provider: "nginx", Domains: []string{"php.example.com"}, Kind: "php",
		PHPVersion: "8.3.35", Root: filepath.Join(root, "web/nginx/php.example.com"), Enabled: true}
	if err := os.MkdirAll(item.Root, 0755); err != nil {
		t.Fatal(err)
	}
	if err := sites.prepareSiteRoot(item); err != nil {
		t.Fatal(err)
	}
	// 站点目录归共享运行账户所有。PHP 以同一身份运行，才是属主、才写得进自己的
	// 目录——旧实现里目录归 root，WordPress 装不了插件、上传目录也建不出来。
	rootInfo, err := os.Stat(item.Root)
	if err != nil || rootInfo.Mode().Perm() != 0750 {
		t.Fatalf("站点目录权限：%v %v", rootInfo, err)
	}
	if stat, ok := rootInfo.Sys().(*syscall.Stat_t); !ok || int(stat.Uid) != os.Getuid() || int(stat.Gid) != os.Getgid() {
		t.Fatalf("站点目录必须归共享运行账户：%v", rootInfo)
	}
	// 换 PHP 版本就是换 FPM 监听目标：版本化安装用各自前缀下的 socket，
	// 默认安装沿用安装脚本写死的 TCP 端口（老安装的兼容路径）。
	versionedTarget, err := sites.phpTarget("8.3.35")
	if err != nil || versionedTarget != "unix:"+filepath.Join(versioned, "run/php-fpm.sock") {
		t.Fatalf("版本化 PHP 目标：%q %v", versionedTarget, err)
	}
	if legacyTarget, err := sites.phpTarget("8.4.26"); err != nil || legacyTarget != "127.0.0.1:9000" {
		t.Fatalf("默认 PHP 目标：%q %v", legacyTarget, err)
	}
	if _, err := sites.phpTarget("8.2.1"); err == nil {
		t.Fatal("未安装的 PHP 版本必须被拒绝")
	}
	if err := sites.ensurePHP(context.Background(), "8.3.35"); err != nil {
		t.Fatal(err)
	}
	// 该版本自己的单元必须被拉起来，而不是面板再给每个网站建一个实例。
	for _, wanted := range []string{"is-active sera-php-8.3.35.service", "start sera-php-8.3.35.service"} {
		found := false
		for _, call := range calls {
			if call == wanted {
				found = true
			}
		}
		if !found {
			t.Fatalf("缺少 systemctl 调用 %q：%v", wanted, calls)
		}
	}
	if _, err := sites.normalize(site{Provider: "nginx", Domains: []string{"x.example.com"}, Kind: "php", PHPVersion: "8.2.1"}); err == nil {
		t.Fatal("uninstalled PHP accepted")
	}
	for _, provider := range siteProviders {
		base := site{ID: provider.ID + ".example.com", Provider: provider.ID, Domains: []string{provider.ID + ".example.com"}, Root: filepath.Join(root, "web", provider.ID, provider.ID+".example.com"), Enabled: true}
		static := base
		static.Kind = "static"
		staticConfig := string(siteConfig(static, provider.Port, ""))
		// .php 规则必须真的能命中：写成 \\.php$ 是「一个反斜杠 + 任意字符」，
		// PHP 源码会被当纯文本吐出来，静态站点的源码保护也一起失效。
		if strings.Contains(staticConfig, `\\.php$`) {
			t.Fatalf("%s escapes the php regex twice: %s", provider.ID, staticConfig)
		}
		if !strings.Contains(staticConfig, `\.php$`) {
			t.Fatalf("%s does not guard .php requests: %s", provider.ID, staticConfig)
		}
		if provider.ID == "apache" {
			if !strings.Contains(staticConfig, `<FilesMatch "\.php$">`) || !strings.Contains(staticConfig, "Require all denied") {
				t.Fatalf("%s can expose PHP source: %s", provider.ID, staticConfig)
			}
		} else if !strings.Contains(staticConfig, `location ~ \.php$`) || !strings.Contains(staticConfig, "return 404") {
			t.Fatalf("%s can expose PHP source: %s", provider.ID, staticConfig)
		}
		php := base
		php.Kind, php.PHPVersion = "php", "8.3.35"
		config := string(siteConfig(php, provider.Port, versionedTarget))
		if !strings.Contains(config, "php-fpm.sock") || !strings.Contains(config, "index.php") {
			t.Fatalf("%s PHP handler missing: %s", provider.ID, config)
		}
		if strings.Contains(config, `\\.php$`) || !strings.Contains(config, `\.php$`) {
			t.Fatalf("%s PHP handler regex is broken: %s", provider.ID, config)
		}
		if provider.ID == "apache" {
			if !strings.Contains(config, `<FilesMatch "\.php$">`) || !strings.Contains(config, `SetHandler "proxy:unix:`) {
				t.Fatalf("%s PHP handler is not wired to the site socket: %s", provider.ID, config)
			}
		} else if !strings.Contains(config, `location ~ \.php$`) || !strings.Contains(config, "fastcgi_pass unix:") {
			t.Fatalf("%s PHP handler is not wired to the site socket: %s", provider.ID, config)
		}
	}
	base := "ServerRoot \"/tmp\"\nUser seraphim-apache\nGroup seraphim-apache\nIncludeOptional " + filepath.Join(root, "sites/apache/*.conf") + "\n"
	config, err := siteInclude(base, "apache", root, true)
	if err != nil || !strings.Contains(string(config), "LoadModule proxy_fcgi_module modules/mod_proxy_fcgi.so") {
		t.Fatalf("Apache proxy_fcgi missing: %s %v", config, err)
	}
	// Apache 的 worker 必须也是共享账户，才读得到归 sera 所有的站点目录。
	if !strings.Contains(string(config), "User "+sharedAccount+"\n") || !strings.Contains(string(config), "Group "+sharedAccount+"\n") ||
		strings.Contains(string(config), "seraphim-apache") {
		t.Fatalf("Apache worker is not on the shared account: %s", config)
	}
	// 官方 httpd.conf 里 #LoadModule proxy_fcgi_module 是被注释的示例行；
	// 用 Contains 判断「已加载」会被它骗过，fcgi 处理器就永远不会被加载。
	commented := "ServerRoot \"/tmp\"\n#LoadModule proxy_module modules/mod_proxy.so\n#LoadModule proxy_http_module modules/mod_proxy_http.so\n#LoadModule proxy_fcgi_module modules/mod_proxy_fcgi.so\n"
	config, err = siteInclude(commented, "apache", root, true)
	if err != nil {
		t.Fatal(err)
	}
	for _, module := range []string{"proxy_module", "proxy_http_module", "proxy_fcgi_module"} {
		if !regexp.MustCompile(`(?m)^LoadModule ` + module + ` `).MatchString(string(config)) {
			t.Fatalf("commented %s suppressed the real LoadModule: %s", module, config)
		}
	}
	// 静态网站不需要 fcgi，但 proxy 仍然是反向代理站点所必需的。
	staticInclude, err := siteInclude(commented, "apache", root, false)
	if err != nil {
		t.Fatal(err)
	}
	if regexp.MustCompile(`(?m)^LoadModule proxy_fcgi_module `).MatchString(string(staticInclude)) {
		t.Fatalf("static site pulled in mod_proxy_fcgi: %s", staticInclude)
	}
	for _, provider := range []string{"nginx", "openresty"} {
		// 静态与 PHP 站点都要写 user 指令：worker 用系统默认账户时连站点目录都进不去。
		for _, php := range []bool{true, false} {
			config, err := siteInclude("http {\n    include "+filepath.Join(root, "sites", provider, "*.conf")+";\n}\n", provider, root, php)
			if err != nil || !strings.HasPrefix(string(config), "user "+sharedAccount+";\n") {
				t.Fatalf("%s web worker cannot reach the site root: %s %v", provider, config, err)
			}
		}
		// 已有的 user 指令要被改写，而不是再追加一行。
		config, err := siteInclude("user www-data;\nhttp {\n    include "+filepath.Join(root, "sites", provider, "*.conf")+";\n}\n", provider, root, true)
		if err != nil || strings.Contains(string(config), "www-data") || !strings.Contains(string(config), "user "+sharedAccount+";") {
			t.Fatalf("%s kept a stale worker account: %s %v", provider, config, err)
		}
	}
}

func TestLegacySiteFPMUnitsAreRemoved(t *testing.T) {
	root := t.TempDir()
	sites := newSiteManager(root, newSoftwareManager(root))
	stubSiteRuntime(sites)
	sites.unitDir = t.TempDir()
	unit := filepath.Join(sites.unitDir, "sera-php-site-old_example_com.service")
	if err := os.WriteFile(unit, []byte("[Unit]\n"), 0644); err != nil {
		t.Fatal(err)
	}
	pool := filepath.Join(root, "server", "php", "etc", "sites")
	if err := os.MkdirAll(pool, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(pool, "site-old_example_com.conf"), []byte("[www]\n"), 0640); err != nil {
		t.Fatal(err)
	}
	run := filepath.Join(root, "run", "sites", "site-old_example_com")
	if err := os.MkdirAll(run, 0750); err != nil {
		t.Fatal(err)
	}
	calls := []string{}
	sites.software.systemctl = func(_ context.Context, args ...string) ([]byte, error) {
		calls = append(calls, strings.Join(args, " "))
		return nil, nil
	}
	sites.removeLegacySiteFPM(context.Background())
	for _, path := range []string{unit, pool, run} {
		if _, err := os.Stat(path); !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("上一版遗留的站点 FPM 残留未被清掉：%s %v", path, err)
		}
	}
	wanted := "disable --now sera-php-site-old_example_com.service"
	found := false
	for _, call := range calls {
		if call == wanted {
			found = true
		}
	}
	if !found {
		t.Fatalf("缺少停用调用：%v", calls)
	}
	// 没有遗留时保持安静：不该无谓地碰 systemd。
	calls = nil
	sites.removeLegacySiteFPM(context.Background())
	if len(calls) != 0 {
		t.Fatalf("没有遗留单元时不应调用 systemctl：%v", calls)
	}
}

func TestPHPSiteApplySharesOneRuntimeAccount(t *testing.T) {
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
	prefix := filepath.Join(root, "server/php/versions/8.4.26")
	if err := os.MkdirAll(prefix, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(prefix, ".sera-installed"), []byte("8.4.26"), 0644); err != nil {
		t.Fatal(err)
	}
	sites.unitDir = t.TempDir()
	stubSiteRuntime(sites)
	sites.phpReady = func(target string) bool { return strings.HasPrefix(target, "unix:") }
	sites.test = func(context.Context, string) error { return nil }
	sites.isRunning = func(context.Context, string) bool { return true }
	reloads := 0
	sites.reload = func(context.Context, string) error { reloads++; return nil }
	sites.software.systemctl = func(context.Context, ...string) ([]byte, error) { return []byte("active"), nil }

	item := site{ID: "shop.example.com", Provider: "nginx", Domains: []string{"shop.example.com"}, Kind: "php",
		PHPVersion: "8.4.26", Root: filepath.Join(root, "web/nginx/shop.example.com"), Enabled: true}
	applied, err := sites.apply(item, false, true)
	if err != nil {
		t.Fatal(err)
	}
	if reloads != 1 {
		t.Fatalf("first save: reload=%d", reloads)
	}
	// 站点目录归共享运行账户，PHP 才是属主、才写得进去。
	rootInfo, err := os.Stat(applied.Root)
	if err != nil || rootInfo.Mode().Perm() != 0750 {
		t.Fatalf("site root permissions: %v %v", rootInfo, err)
	}
	if stat, ok := rootInfo.Sys().(*syscall.Stat_t); !ok || int(stat.Uid) != os.Getuid() || int(stat.Gid) != os.Getgid() {
		t.Fatalf("site root must belong to the shared runtime account: %v", rootInfo)
	}
	// vhost 指向该版本共享 FPM 的 socket，而不是每个网站一个实例。
	conf, err := os.ReadFile(sites.confPath("nginx", item.ID))
	if err != nil || !strings.Contains(string(conf), filepath.Join("versions", "8.4.26", "run", "php-fpm.sock")) {
		t.Fatalf("vhost does not use the versioned FPM socket: %s %v", conf, err)
	}
	// 元数据里不再有「每个网站一个账户」的字段：账户是全局那一层概念。
	if stored, err := sites.read("nginx", item.ID); err != nil || stored.Kind != "php" || stored.PHPVersion != "8.4.26" {
		t.Fatalf("stored metadata: %+v %v", stored, err)
	}

	// 再次保存只重载，不影响其他站点。
	if _, err := sites.apply(applied, false, false); err != nil {
		t.Fatal(err)
	}
	if reloads != 2 {
		t.Fatalf("second save: reload=%d", reloads)
	}

	// 改成静态站点：站点目录保留，仍然归共享账户，不产生任何遗留单元。
	static := applied
	static.Kind, static.PHPVersion = "static", ""
	if _, err := sites.apply(static, false, false); err != nil {
		t.Fatal(err)
	}
	stored, err := sites.read("nginx", item.ID)
	if err != nil || stored.Kind != "static" {
		t.Fatalf("metadata after downgrade: %+v %v", stored, err)
	}
	if entries, err := os.ReadDir(sites.unitDir); err != nil || len(entries) != 0 {
		t.Fatalf("面板不应为网站建立 FPM 单元：%v %v", entries, err)
	}
	if info, err := os.Stat(applied.Root); err != nil || !info.IsDir() {
		t.Fatalf("site content lost: %v %v", info, err)
	}
}
