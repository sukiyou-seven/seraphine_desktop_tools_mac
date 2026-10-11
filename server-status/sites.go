package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

type site struct {
	ID       string   `json:"id"`
	Provider string   `json:"provider"`
	Domains  []string `json:"domains"`
	Kind     string   `json:"kind"`
	Upstream string   `json:"upstream"`
	Root     string   `json:"root"`
	Enabled  bool     `json:"enabled"`
}

type siteProvider struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	Port      int    `json:"port"`
	Installed bool   `json:"installed"`
	Running   bool   `json:"running"`
}

type siteListing struct {
	Items     []site         `json:"items"`
	Providers []siteProvider `json:"providers"`
}

type siteManager struct {
	root      string
	software  *softwareManager
	mu        sync.Mutex
	test      func(context.Context, string) error
	reload    func(context.Context, string) error
	isRunning func(context.Context, string) bool
}

var siteProviders = []siteProvider{
	{ID: "nginx", Name: "Nginx", Port: 80},
	{ID: "apache", Name: "Apache", Port: 8082},
	{ID: "openresty", Name: "OpenResty", Port: 8083},
}
var siteLabel = regexp.MustCompile(`^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$`)

func newSiteManager(root string, software *softwareManager) *siteManager {
	sm := &siteManager{root: root, software: software}
	sm.test = func(ctx context.Context, provider string) error {
		var binary, config string
		switch provider {
		case "nginx":
			binary, config = filepath.Join(root, "server/nginx/sbin/nginx"), filepath.Join(root, "server/nginx/conf/nginx.conf")
		case "openresty":
			binary, config = filepath.Join(root, "server/openresty/nginx/sbin/nginx"), filepath.Join(root, "server/openresty/nginx/conf/nginx.conf")
		case "apache":
			binary, config = filepath.Join(root, "server/apache/bin/httpd"), filepath.Join(root, "server/apache/conf/httpd.conf")
		}
		args := []string{"-t", "-c", config}
		if provider == "apache" {
			args = []string{"-t", "-f", config}
		}
		output, err := exec.CommandContext(ctx, binary, args...).CombinedOutput()
		if err != nil {
			return fmt.Errorf("%s 配置检查失败：%s", provider, strings.TrimSpace(string(output)))
		}
		return nil
	}
	sm.isRunning = func(ctx context.Context, provider string) bool {
		output, err := software.systemctl(ctx, "is-active", "sera-"+provider+".service")
		return err == nil && strings.TrimSpace(string(output)) == "active"
	}
	sm.reload = func(ctx context.Context, provider string) error {
		output, err := software.systemctl(ctx, "reload", "sera-"+provider+".service")
		if err != nil {
			return fmt.Errorf("%s 重载失败：%s", provider, strings.TrimSpace(string(output)))
		}
		return nil
	}
	return sm
}

func validSiteProvider(provider string) bool {
	for _, entry := range siteProviders {
		if entry.ID == provider {
			return true
		}
	}
	return false
}

func validSiteDomain(domain string) bool {
	if len(domain) == 0 || len(domain) > 253 || net.ParseIP(domain) != nil {
		return false
	}
	labels := strings.Split(domain, ".")
	for _, label := range labels {
		if !siteLabel.MatchString(label) {
			return false
		}
	}
	return true
}

func validateUpstream(raw string) error {
	target, err := url.Parse(raw)
	if err != nil || (target.Scheme != "http" && target.Scheme != "https") ||
		target.User != nil || target.Hostname() == "" || target.Path != "" && target.Path != "/" ||
		target.RawQuery != "" || target.Fragment != "" || target.Opaque != "" {
		return errors.New("反向代理地址须为 http://主机:端口 或 https://主机:端口")
	}
	host := target.Hostname()
	if net.ParseIP(host) == nil && !validSiteDomain(strings.ToLower(host)) {
		return errors.New("反向代理主机名无效")
	}
	if port := target.Port(); port != "" {
		n, err := strconv.Atoi(port)
		if err != nil || n < 1 || n > 65535 {
			return errors.New("反向代理端口无效")
		}
	}
	return nil
}

func (sm *siteManager) normalize(input site) (site, error) {
	if !validSiteProvider(input.Provider) {
		return site{}, errors.New("请选择 Nginx、Apache 或 OpenResty")
	}
	if len(input.Domains) == 0 || len(input.Domains) > 20 {
		return site{}, errors.New("请填写 1 至 20 个域名")
	}
	seen := map[string]bool{}
	domains := make([]string, 0, len(input.Domains))
	for _, value := range input.Domains {
		domain := strings.ToLower(strings.TrimSpace(value))
		if !validSiteDomain(domain) {
			return site{}, fmt.Errorf("域名无效：%q", value)
		}
		if !seen[domain] {
			seen[domain] = true
			domains = append(domains, domain)
		}
	}
	input.Domains = domains
	if input.Kind != "static" && input.Kind != "proxy" {
		return site{}, errors.New("网站类型须为静态站点或反向代理")
	}
	if input.Kind == "proxy" {
		if err := validateUpstream(input.Upstream); err != nil {
			return site{}, err
		}
		input.Upstream = strings.TrimSuffix(input.Upstream, "/")
	} else {
		input.Upstream = ""
	}
	return input, nil
}

func (sm *siteManager) siteDir(provider string) string {
	return filepath.Join(sm.root, "sites", provider)
}
func (sm *siteManager) metaPath(provider, id string) string {
	return filepath.Join(sm.siteDir(provider), id+".json")
}
func (sm *siteManager) confPath(provider, id string) string {
	return filepath.Join(sm.siteDir(provider), id+".conf")
}
func (sm *siteManager) basePath(provider string) string {
	switch provider {
	case "nginx":
		return filepath.Join(sm.root, "server/nginx/conf/nginx.conf")
	case "openresty":
		return filepath.Join(sm.root, "server/openresty/nginx/conf/nginx.conf")
	default:
		return filepath.Join(sm.root, "server/apache/conf/httpd.conf")
	}
}
func (sm *siteManager) installed(provider string) bool {
	_, err := os.Stat(filepath.Join(sm.root, "server", provider, ".sera-installed"))
	return err == nil
}

func (sm *siteManager) list() (siteListing, error) {
	sm.mu.Lock()
	defer sm.mu.Unlock()
	result := siteListing{Items: []site{}, Providers: []siteProvider{}}
	for _, entry := range siteProviders {
		entry.Installed = sm.installed(entry.ID)
		if entry.Installed {
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			entry.Running = sm.isRunning(ctx, entry.ID)
			cancel()
		}
		result.Providers = append(result.Providers, entry)
		files, err := os.ReadDir(sm.siteDir(entry.ID))
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			return siteListing{}, err
		}
		for _, file := range files {
			if !strings.HasSuffix(file.Name(), ".json") || !file.Type().IsRegular() {
				continue
			}
			data, err := os.ReadFile(filepath.Join(sm.siteDir(entry.ID), file.Name()))
			if err != nil {
				return siteListing{}, err
			}
			var item site
			if err := json.Unmarshal(data, &item); err != nil {
				return siteListing{}, err
			}
			result.Items = append(result.Items, item)
		}
	}
	sort.Slice(result.Items, func(i, j int) bool {
		if result.Items[i].Provider != result.Items[j].Provider {
			return result.Items[i].Provider < result.Items[j].Provider
		}
		return result.Items[i].ID < result.Items[j].ID
	})
	return result, nil
}

func (sm *siteManager) read(provider, id string) (site, error) {
	data, err := os.ReadFile(sm.metaPath(provider, id))
	if err != nil {
		return site{}, err
	}
	var item site
	if err := json.Unmarshal(data, &item); err != nil {
		return site{}, err
	}
	if item.ID != id || item.Provider != provider {
		return site{}, errors.New("网站配置已损坏")
	}
	return item, nil
}

func (sm *siteManager) checkDomainConflict(candidate site) error {
	files, err := os.ReadDir(sm.siteDir(candidate.Provider))
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	wanted := map[string]bool{}
	for _, domain := range candidate.Domains {
		wanted[domain] = true
	}
	for _, file := range files {
		if !strings.HasSuffix(file.Name(), ".json") || file.Name() == candidate.ID+".json" {
			continue
		}
		existing, err := sm.read(candidate.Provider, strings.TrimSuffix(file.Name(), ".json"))
		if err != nil {
			return err
		}
		for _, domain := range existing.Domains {
			if wanted[domain] {
				return fmt.Errorf("域名 %s 已绑定到同一 Web 服务的其他网站", domain)
			}
		}
	}
	return nil
}

func siteConfig(item site, port int) []byte {
	domains := strings.Join(item.Domains, " ")
	access := filepath.Join("/www/seraphim/logs", item.Provider+"-"+item.ID+"-access.log")
	problem := filepath.Join("/www/seraphim/logs", item.Provider+"-"+item.ID+"-error.log")
	if item.Provider == "apache" {
		var body strings.Builder
		fmt.Fprintf(&body, "<VirtualHost *:%d>\n    ServerName %s\n", port, item.Domains[0])
		for _, domain := range item.Domains[1:] {
			fmt.Fprintf(&body, "    ServerAlias %s\n", domain)
		}
		fmt.Fprintf(&body, "    ErrorLog %q\n    CustomLog %q combined\n", problem, access)
		if item.Kind == "static" {
			fmt.Fprintf(&body, "    DocumentRoot %q\n    <Directory %q>\n        Require all granted\n        Options FollowSymLinks\n        AllowOverride None\n    </Directory>\n", item.Root, item.Root)
		} else {
			fmt.Fprintf(&body, "    ProxyPreserveHost On\n    ProxyPass / %q\n    ProxyPassReverse / %q\n", item.Upstream+"/", item.Upstream+"/")
		}
		body.WriteString("</VirtualHost>\n")
		return []byte(body.String())
	}
	var body strings.Builder
	fmt.Fprintf(&body, "server {\n    listen %d;\n    server_name %s;\n", port, domains)
	fmt.Fprintf(&body, "    access_log %s;\n    error_log %s warn;\n", access, problem)
	if item.Kind == "static" {
		fmt.Fprintf(&body, "    root %s;\n    index index.html;\n    location / { try_files $uri $uri/ =404; }\n", item.Root)
	} else {
		fmt.Fprintf(&body, "    location / {\n        proxy_pass %s;\n        proxy_set_header Host $host;\n        proxy_set_header X-Real-IP $remote_addr;\n        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n        proxy_set_header X-Forwarded-Proto $scheme;\n    }\n", item.Upstream)
	}
	body.WriteString("}\n")
	return []byte(body.String())
}

func siteInclude(base, provider, root string) ([]byte, error) {
	pattern := filepath.Join(root, "sites", provider, "*.conf")
	if strings.Contains(base, pattern) {
		return []byte(base), nil
	}
	if provider == "apache" {
		// The bundled Apache build has these DSO modules. They are needed by proxy sites.
		extra := "\nLoadModule proxy_module modules/mod_proxy.so\nLoadModule proxy_http_module modules/mod_proxy_http.so\n"
		for _, name := range []string{"proxy_module", "proxy_http_module"} {
			for _, line := range strings.Split(base, "\n") {
				if strings.HasPrefix(strings.TrimSpace(line), "LoadModule "+name+" ") {
					extra = strings.Replace(extra, "LoadModule "+name+" modules/mod_"+strings.TrimSuffix(name, "_module")+".so\n", "", 1)
					break
				}
			}
		}
		return []byte(base + extra + "IncludeOptional " + pattern + "\n"), nil
	}
	trimmed := strings.TrimRight(base, " \t\r\n")
	if !strings.HasSuffix(trimmed, "}") || !strings.Contains(trimmed, "http {") {
		return nil, errors.New("未找到 Web 服务的 http 配置块，请先检查主配置")
	}
	pos := strings.LastIndex(trimmed, "}")
	return []byte(trimmed[:pos] + "    include " + pattern + ";\n" + trimmed[pos:] + "\n"), nil
}

func atomicSiteWrite(path string, data []byte, mode os.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		return err
	}
	temp, err := os.CreateTemp(filepath.Dir(path), ".sera-site-*")
	if err != nil {
		return err
	}
	defer os.Remove(temp.Name())
	if _, err := temp.Write(data); err != nil {
		temp.Close()
		return err
	}
	if err := temp.Chmod(mode); err != nil {
		temp.Close()
		return err
	}
	if err := temp.Close(); err != nil {
		return err
	}
	return os.Rename(temp.Name(), path)
}

func ensureSiteRoot(root, provider, id string) error {
	for _, directory := range []string{
		filepath.Join(root, "web"),
		filepath.Join(root, "web", provider),
		filepath.Join(root, "web", provider, id),
	} {
		info, err := os.Lstat(directory)
		if errors.Is(err, os.ErrNotExist) {
			if err := os.Mkdir(directory, 0755); err != nil {
				return err
			}
			info, err = os.Lstat(directory)
		}
		if err != nil {
			return err
		}
		if !info.IsDir() {
			return fmt.Errorf("网站目录不能是软链接或文件：%s", directory)
		}
		if err := os.Chmod(directory, info.Mode().Perm()|0755); err != nil {
			return err
		}
	}
	return nil
}

type siteSnapshot struct {
	path   string
	data   []byte
	exists bool
	mode   os.FileMode
}

func snapshotSite(path string) (siteSnapshot, error) {
	stat, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return siteSnapshot{path: path}, nil
	}
	if err != nil {
		return siteSnapshot{}, err
	}
	if !stat.Mode().IsRegular() {
		return siteSnapshot{}, fmt.Errorf("配置不是普通文件：%s", path)
	}
	data, err := os.ReadFile(path)
	return siteSnapshot{path: path, data: data, exists: true, mode: stat.Mode().Perm()}, err
}
func restoreSites(snapshots []siteSnapshot) {
	for _, previous := range snapshots {
		if previous.exists {
			_ = atomicSiteWrite(previous.path, previous.data, previous.mode)
		} else {
			_ = os.Remove(previous.path)
		}
	}
}

func (sm *siteManager) apply(input site, deleteSite, creating bool) (site, error) {
	if !sm.software.beginServiceAction() {
		return site{}, errors.New("另一个软件操作正在进行")
	}
	defer sm.software.endServiceAction()
	sm.mu.Lock()
	defer sm.mu.Unlock()
	if !validSiteProvider(input.Provider) || !validSiteDomain(input.ID) {
		return site{}, errors.New("网站标识无效")
	}
	installed := sm.installed(input.Provider)
	if !installed && !deleteSite {
		return site{}, errors.New("请先在软件商店安装对应 Web 服务")
	}
	if !installed && deleteSite {
		if _, err := snapshotSite(sm.metaPath(input.Provider, input.ID)); err != nil {
			return site{}, err
		}
		if err := os.Remove(sm.metaPath(input.Provider, input.ID)); err != nil {
			return site{}, err
		}
		if err := os.Remove(sm.confPath(input.Provider, input.ID)); err != nil && !errors.Is(err, os.ErrNotExist) {
			return site{}, err
		}
		return input, nil
	}
	if !deleteSite {
		var err error
		input, err = sm.normalize(input)
		if err != nil {
			return site{}, err
		}
		if input.Root != filepath.Join(sm.root, "web", input.Provider, input.ID) {
			return site{}, errors.New("网站目录必须位于 /www/seraphim/web 下")
		}
		if err := sm.checkDomainConflict(input); err != nil {
			return site{}, err
		}
	}
	basePath := sm.basePath(input.Provider)
	paths := []string{basePath, sm.metaPath(input.Provider, input.ID), sm.confPath(input.Provider, input.ID)}
	snapshots := make([]siteSnapshot, 0, len(paths))
	for _, path := range paths {
		old, err := snapshotSite(path)
		if err != nil {
			return site{}, err
		}
		snapshots = append(snapshots, old)
	}
	if creating && snapshots[1].exists {
		return site{}, errors.New("网站已存在")
	}
	if !creating && !snapshots[1].exists {
		return site{}, os.ErrNotExist
	}
	if !snapshots[0].exists {
		return site{}, errors.New("Web 服务主配置不存在")
	}
	if err := os.MkdirAll(sm.siteDir(input.Provider), 0755); err != nil {
		return site{}, err
	}
	changed := false
	defer func() {
		if changed {
			restoreSites(snapshots)
		}
	}()
	if deleteSite {
		if !snapshots[1].exists {
			return site{}, os.ErrNotExist
		}
		if err := os.Remove(paths[1]); err != nil {
			return site{}, err
		}
		changed = true
		if err := os.Remove(paths[2]); err != nil && !errors.Is(err, os.ErrNotExist) {
			return site{}, err
		}
	} else {
		if input.Kind == "static" {
			if err := ensureSiteRoot(sm.root, input.Provider, input.ID); err != nil {
				return site{}, err
			}
		}
		base, err := siteInclude(string(snapshots[0].data), input.Provider, sm.root)
		if err != nil {
			return site{}, err
		}
		changed = true
		if err := atomicSiteWrite(basePath, base, snapshots[0].mode); err != nil {
			return site{}, err
		}
		metadata, _ := json.MarshalIndent(input, "", "  ")
		if err := atomicSiteWrite(paths[1], append(metadata, '\n'), 0644); err != nil {
			return site{}, err
		}
		if input.Enabled {
			port := 80
			for _, provider := range siteProviders {
				if provider.ID == input.Provider {
					port = provider.Port
				}
			}
			if err := atomicSiteWrite(paths[2], siteConfig(input, port), 0644); err != nil {
				return site{}, err
			}
		} else if err := os.Remove(paths[2]); err != nil && !errors.Is(err, os.ErrNotExist) {
			return site{}, err
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	if err := sm.test(ctx, input.Provider); err != nil {
		return site{}, err
	}
	if sm.isRunning(ctx, input.Provider) {
		if err := sm.reload(ctx, input.Provider); err != nil {
			return site{}, err
		}
	}
	changed = false
	return input, nil
}

func (a *api) sitesHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	if !a.authorized(r) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	if r.URL.Path == "/v1/sites" {
		switch r.Method {
		case http.MethodGet:
			listing, err := a.sites.list()
			if err != nil {
				http.Error(w, err.Error(), http.StatusInternalServerError)
				return
			}
			w.Header().Set("Content-Type", "application/json; charset=utf-8")
			_ = json.NewEncoder(w).Encode(listing)
		case http.MethodPost:
			var input site
			if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 16<<10)).Decode(&input); err != nil {
				http.Error(w, "invalid website JSON", http.StatusBadRequest)
				return
			}
			input.ID = ""
			input, err := a.sites.normalize(input)
			if err != nil {
				http.Error(w, err.Error(), http.StatusBadRequest)
				return
			}
			input.ID = input.Domains[0]
			input.Root = filepath.Join(a.sites.root, "web", input.Provider, input.ID)
			if _, err := os.Stat(a.sites.metaPath(input.Provider, input.ID)); err == nil {
				http.Error(w, "website already exists", http.StatusConflict)
				return
			} else if !errors.Is(err, os.ErrNotExist) {
				http.Error(w, err.Error(), http.StatusConflict)
				return
			}
			item, err := a.sites.apply(input, false, true)
			if err != nil {
				http.Error(w, err.Error(), http.StatusConflict)
				return
			}
			w.Header().Set("Content-Type", "application/json; charset=utf-8")
			w.WriteHeader(http.StatusCreated)
			_ = json.NewEncoder(w).Encode(item)
		default:
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		}
		return
	}
	parts := strings.Split(strings.TrimPrefix(r.URL.Path, "/v1/sites/"), "/")
	if len(parts) != 2 || !validSiteProvider(parts[0]) || !validSiteDomain(parts[1]) {
		http.NotFound(w, r)
		return
	}
	provider, id := parts[0], parts[1]
	current, err := a.sites.read(provider, id)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	switch r.Method {
	case http.MethodPut:
		var input site
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 16<<10)).Decode(&input); err != nil {
			http.Error(w, "invalid website JSON", http.StatusBadRequest)
			return
		}
		input.ID, input.Provider, input.Root = current.ID, current.Provider, current.Root
		if _, err := a.sites.normalize(input); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		_, err := a.sites.apply(input, false, false)
		if err != nil {
			http.Error(w, err.Error(), http.StatusConflict)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	case http.MethodDelete:
		_, err := a.sites.apply(current, true, false)
		if err != nil {
			http.Error(w, err.Error(), http.StatusConflict)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}
