package main

import (
	"context"
	"embed"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"syscall"
	"time"
)

//go:embed installers/*.sh
var installerScripts embed.FS

type softwareSpec struct {
	id          string
	name        string
	version     string
	description string
	category    string
	unit        string
	installable bool
}

var softwareCatalog = []softwareSpec{
	{id: "nginx", name: "Nginx", version: "1.30.5", description: "Web 服务器与反向代理", category: "Web 服务", unit: "sera-nginx.service", installable: true},
	{id: "apache", name: "Apache HTTP Server", version: "2.4.69", description: "模块化 Web 服务器", category: "Web 服务", unit: "sera-apache.service", installable: true},
	{id: "openresty", name: "OpenResty", version: "1.31.1.1", description: "基于 Nginx 与 Lua 的 Web 平台", category: "Web 服务", unit: "sera-openresty.service", installable: true},
	{id: "caddy", name: "Caddy", version: "2.11.7", description: "自动 HTTPS 的 Web 服务器", category: "Web 服务", unit: "sera-caddy.service", installable: true},
	{id: "traefik", name: "Traefik", version: "3.7.14", description: "面向容器的反向代理", category: "Web 服务", unit: "sera-traefik.service", installable: true},
	{id: "mysql", name: "MySQL", version: "8.4.11", description: "关系数据库，默认只监听本机", category: "数据库", unit: "sera-mysql.service", installable: true},
	{id: "mariadb", name: "MariaDB", version: "11.8.9", description: "兼容 MySQL 的关系数据库", category: "数据库", unit: "sera-mariadb.service", installable: true},
	{id: "postgresql", name: "PostgreSQL", version: "18.6", description: "开源关系数据库", category: "数据库", unit: "sera-postgresql.service", installable: true},
	{id: "mongodb", name: "MongoDB", version: "8.2.12", description: "文档数据库", category: "数据库", unit: "sera-mongodb.service", installable: true},
	{id: "sqlite", name: "SQLite", version: "3.53.4", description: "嵌入式 SQL 数据库", category: "数据库", installable: true},
	{id: "redis", name: "Redis", version: "8.4.7", description: "键值数据库，默认只监听本机", category: "缓存与消息", unit: "sera-redis.service", installable: true},
	{id: "valkey", name: "Valkey", version: "9.1.2", description: "兼容 Redis 协议的键值数据库", category: "缓存与消息", unit: "sera-valkey.service", installable: true},
	{id: "memcached", name: "Memcached", version: "1.6.45", description: "分布式内存缓存", category: "缓存与消息", unit: "sera-memcached.service", installable: true},
	{id: "rabbitmq", name: "RabbitMQ", version: "4.3.6", description: "消息队列", category: "缓存与消息", unit: "sera-rabbitmq.service", installable: true},
	{id: "kafka", name: "Apache Kafka", version: "4.2.1", description: "事件流平台", category: "缓存与消息", unit: "sera-kafka.service", installable: true},
	{id: "php", name: "PHP-FPM", version: "8.4.26", description: "PHP 网站运行环境，默认只监听本机", category: "运行环境", unit: "sera-php.service", installable: true},
	{id: "node", name: "Node.js", version: "24.21.0", description: "JavaScript 运行环境与 npm", category: "运行环境", installable: true},
	{id: "python", name: "Python", version: "3.14.8", description: "Python 运行环境", category: "运行环境", installable: true},
	{id: "go", name: "Go", version: "1.27.1", description: "Go 编译与运行环境", category: "运行环境", installable: true},
	{id: "openjdk", name: "OpenJDK", version: "25.0.4.1", description: "Java 运行环境", category: "运行环境", installable: true},
	{id: "dotnet", name: ".NET", version: "10.0.401", description: ".NET 运行环境", category: "运行环境", installable: true},
	{id: "ruby", name: "Ruby", version: "4.0.7", description: "Ruby 运行环境", category: "运行环境", installable: true},
	{id: "bun", name: "Bun", version: "1.4.2", description: "JavaScript 运行环境与工具链", category: "运行环境", installable: true},
	{id: "deno", name: "Deno", version: "2.9.7", description: "JavaScript 与 TypeScript 运行环境", category: "运行环境", installable: true},
	{id: "docker", name: "Docker Engine", version: "29.8.2", description: "容器运行环境", category: "容器与工具", unit: "sera-docker.service", installable: true},
	{id: "podman", name: "Podman", version: "6.1.3", description: "容器运行环境", category: "容器与工具", installable: true},
	{id: "git", name: "Git", version: "2.52.0", description: "版本控制工具", category: "容器与工具", installable: true},
	{id: "pureftpd", name: "Pure-FTPd", version: "1.0.54", description: "FTP 文件传输服务", category: "容器与工具", unit: "sera-pureftpd.service", installable: true},
	{id: "vsftpd", name: "vsftpd", version: "3.0.5", description: "FTP 文件传输服务", category: "容器与工具", unit: "sera-vsftpd.service", installable: true},
	{id: "minio", name: "MinIO", version: "2025-10-15", description: "兼容 S3 的对象存储", category: "容器与工具", unit: "sera-minio.service", installable: true},
	{id: "prometheus", name: "Prometheus", version: "3.15.0", description: "指标采集与监控", category: "监控与搜索", unit: "sera-prometheus.service", installable: true},
	{id: "grafana", name: "Grafana", version: "13.2.3", description: "监控仪表盘", category: "监控与搜索", unit: "sera-grafana.service", installable: true},
	{id: "loki", name: "Loki", version: "3.7.8", description: "日志聚合服务", category: "监控与搜索", unit: "sera-loki.service", installable: true},
	{id: "elasticsearch", name: "Elasticsearch", version: "9.5.5", description: "全文检索与分析", category: "监控与搜索", unit: "sera-elasticsearch.service", installable: true},
	{id: "opensearch", name: "OpenSearch", version: "3.9.0", description: "全文检索与分析", category: "监控与搜索", unit: "sera-opensearch.service", installable: true},
}

type softwareItem struct {
	ID               string `json:"id"`
	Name             string `json:"name"`
	Version          string `json:"version"`
	Description      string `json:"description"`
	Category         string `json:"category"`
	InstallAvailable bool   `json:"install_available"`
	ServiceAvailable bool   `json:"service_available"`
	InstallPath      string `json:"install_path"`
	LogPath          string `json:"log_path"`
	CredentialPath   string `json:"credential_path"`
	State            string `json:"state"`
	Message          string `json:"message"`
	ServiceState     string `json:"service_state"`
	Enabled          bool   `json:"enabled"`
	Supported        bool   `json:"supported"`
}

type installJob struct {
	operation string
	state     string
	message   string
}

type softwareManager struct {
	root      string
	unitDir   string
	mu        sync.Mutex
	jobs      map[string]*installJob
	busy      bool
	run       func(context.Context, string, string, io.Writer) error
	systemctl func(context.Context, ...string) ([]byte, error)
	supported func(string) bool
}

func newSoftwareManager(root string) *softwareManager {
	return &softwareManager{root: root, unitDir: "/etc/systemd/system", jobs: make(map[string]*installJob),
		run: runInstaller, systemctl: runSystemctl,
		supported: func(id string) bool {
			_, aptErr := exec.LookPath("apt-get")
			_, dnfErr := exec.LookPath("dnf")
			_, systemctlErr := exec.LookPath("systemctl")
			systemdDir, systemdErr := os.Stat("/run/systemd/system")
			return softwareSupported(id, runtime.GOOS, runtime.GOARCH,
				aptErr == nil || dnfErr == nil,
				systemctlErr == nil && systemdErr == nil && systemdDir.IsDir())
		}}
}

func softwareSupported(id, goos, goarch string, hasPackages, hasSystemctl bool) bool {
	if goos != "linux" || (goarch != "amd64" && goarch != "arm64") || !hasSystemctl {
		return false
	}
	switch id {
	case "mysql", "mariadb", "mongodb", "docker", "grafana", "elasticsearch", "opensearch":
		if goarch != "amd64" {
			return false
		}
	}
	switch id {
	case "nginx", "redis", "php", "mysql", "mariadb", "mongodb", "apache", "openresty", "postgresql", "sqlite", "valkey", "memcached", "rabbitmq", "python", "ruby", "git", "pureftpd", "vsftpd", "podman", "dotnet", "bun", "deno", "loki", "docker":
		return hasPackages
	default:
		return true
	}
}

func runInstaller(ctx context.Context, id, version string, output io.Writer) error {
	script, err := installerScripts.ReadFile("installers/" + id + ".sh")
	if err != nil {
		return err
	}
	common, err := installerScripts.ReadFile("installers/common.sh")
	if err != nil {
		return err
	}
	command := exec.CommandContext(ctx, "/bin/sh", "-c", string(common)+"\n"+string(script))
	command.Env = append(os.Environ(), "SERA_SELECTED_VERSION="+version)
	command.Stdout = output
	command.Stderr = output
	return command.Run()
}

func findSoftware(id string) (softwareSpec, bool) {
	for _, spec := range softwareCatalog {
		if spec.id == id {
			return spec, true
		}
	}
	return softwareSpec{}, false
}

func (sm *softwareManager) prefix(id string) string {
	return filepath.Join(sm.root, "server", id)
}

func (sm *softwareManager) logPath(id string) string {
	return filepath.Join(sm.root, "logs", "software-"+id+".log")
}

func (sm *softwareManager) unitPath(spec softwareSpec) string {
	return filepath.Join(sm.unitDir, spec.unit)
}

func tail(path string, maximum int64) string {
	file, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return ""
	}
	if info.Size() > maximum {
		_, _ = file.Seek(-maximum, io.SeekEnd)
	}
	data, _ := io.ReadAll(io.LimitReader(file, maximum))
	return string(data)
}

func latestStage(log, fallback string) string {
	for _, line := range slicesReverse(strings.Split(tail(log, 1<<20), "\n")) {
		if stage, ok := strings.CutPrefix(line, "SERA_STAGE:"); ok {
			return strings.TrimSpace(stage)
		}
	}
	return fallback
}

func slicesReverse(input []string) []string {
	for left, right := 0, len(input)-1; left < right; left, right = left+1, right-1 {
		input[left], input[right] = input[right], input[left]
	}
	return input
}

func (sm *softwareManager) item(ctx context.Context, spec softwareSpec) softwareItem {
	prefix := sm.prefix(spec.id)
	item := softwareItem{
		ID: spec.id, Name: spec.name, Version: spec.version, Description: spec.description,
		Category: spec.category, InstallAvailable: spec.installable, ServiceAvailable: spec.unit != "",
		InstallPath: prefix, LogPath: sm.logPath(spec.id), State: "not_installed",
		ServiceState: "inactive", Supported: sm.supported(spec.id),
	}
	if spec.id == "mysql" || spec.id == "minio" {
		item.CredentialPath = filepath.Join(prefix, "initial-root-password")
	} else if spec.id == "grafana" {
		item.CredentialPath = filepath.Join(prefix, "initial-admin-password")
	}
	if !spec.installable {
		return item
	}
	sm.mu.Lock()
	job := sm.jobs[spec.id]
	if job != nil {
		item.State, item.Message = job.state, job.message
	}
	sm.mu.Unlock()
	if job != nil && (job.state == "installing" || job.state == "uninstalling") {
		fallback := "准备安装"
		if job.state == "uninstalling" {
			fallback = "准备卸载"
		}
		item.Message = latestStage(item.LogPath, fallback)
		return item
	}
	if _, err := os.Stat(filepath.Join(prefix, ".sera-installed")); err == nil {
		item.State = "installed"
		if marker, openErr := os.Open(filepath.Join(prefix, ".sera-installed")); openErr == nil {
			version, readErr := io.ReadAll(io.LimitReader(marker, 64))
			_ = marker.Close()
			if readErr == nil {
				if actual := strings.TrimSpace(string(version)); actual != "" && len(actual) < 64 {
					item.Version = actual
				}
			}
		}
		if spec.unit != "" {
			statusCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
			defer cancel()
			if output, _ := sm.systemctl(statusCtx, "is-active", spec.unit); len(output) > 0 {
				item.ServiceState = strings.TrimSpace(string(output))
			}
			if output, _ := sm.systemctl(statusCtx, "is-enabled", spec.unit); strings.TrimSpace(string(output)) == "enabled" {
				item.Enabled = true
			}
		}
	} else if _, err := os.Stat(prefix); err == nil {
		if _, ok := findEnvironment(spec.id); ok {
			count := 0
			entries, _ := os.ReadDir(filepath.Join(prefix, "versions"))
			for _, entry := range entries {
				if entry.IsDir() && versionPattern.MatchString(entry.Name()) {
					marker, e := os.Lstat(filepath.Join(prefix, "versions", entry.Name(), ".sera-installed"))
					if e == nil && marker.Mode().IsRegular() {
						count++
					}
				}
			}
			if count > 0 {
				item.State = "multiple_versions"
				item.Version = ""
				item.Message = fmt.Sprintf("已安装 %d 个版本，请在环境管理中维护", count)
				return item
			}
		}
		item.State = "needs_attention"
		item.Message = "安装目录已存在，请检查后再试"
	} else if item.State == "failed" && job != nil {
		item.Message = job.message
	}
	return item
}

func installVersion(spec softwareSpec, requested string) (string, error) {
	if requested == "" {
		return spec.version, nil
	}
	if requested == spec.version {
		return requested, nil
	}
	return "", errors.New("unsupported software version")
}

func (sm *softwareManager) install(id, requestedVersion string) error {
	spec, ok := findSoftware(id)
	if !ok {
		return os.ErrNotExist
	}
	if !spec.installable {
		return errors.New("installer not available yet")
	}
	if !sm.supported(id) {
		return errors.New("unsupported platform")
	}
	version, err := installVersion(spec, requestedVersion)
	if err != nil {
		return err
	}
	sm.mu.Lock()
	defer sm.mu.Unlock()
	if sm.busy {
		return errors.New("another installation is running")
	}
	if _, err := os.Stat(sm.prefix(id)); err == nil {
		return errors.New("installation directory already exists")
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if spec.unit != "" {
		if _, err := os.Stat(sm.unitPath(spec)); err == nil {
			return errors.New("service unit already exists")
		} else if !errors.Is(err, os.ErrNotExist) {
			return err
		}
	}
	sm.busy = true
	sm.jobs[id] = &installJob{operation: "install", state: "installing", message: "准备安装 " + version}
	go sm.installInBackground(id, version)
	return nil
}

func (sm *softwareManager) installInBackground(id, version string) {
	logPath := sm.logPath(id)
	result := "failed"
	message := "安装失败，请查看安装日志"
	if err := os.MkdirAll(filepath.Dir(logPath), 0750); err == nil {
		if logFile, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0600); err == nil {
			ctx, cancel := context.WithTimeout(context.Background(), 180*time.Minute)
			err = sm.run(ctx, id, version, logFile)
			cancel()
			_ = logFile.Close()
			if err == nil {
				if _, statErr := os.Stat(filepath.Join(sm.prefix(id), ".sera-installed")); statErr == nil {
					result, message = "installed", "安装完成"
				} else {
					log.Printf("software %s installer returned without install marker", id)
				}
			} else {
				log.Printf("software %s installation failed: %v", id, err)
			}
		}
	}
	sm.mu.Lock()
	sm.jobs[id] = &installJob{operation: "install", state: result, message: message}
	sm.busy = false
	sm.mu.Unlock()
}

func (sm *softwareManager) installedPrefix(id string) (string, error) {
	prefix := sm.prefix(id)
	info, err := os.Lstat(prefix)
	if errors.Is(err, os.ErrNotExist) {
		return "", errors.New("software is not installed")
	}
	if err != nil {
		return "", err
	}
	if !info.IsDir() {
		return "", errors.New("installation path is not a directory")
	}
	marker, err := os.Lstat(filepath.Join(prefix, ".sera-installed"))
	if errors.Is(err, os.ErrNotExist) {
		return "", errors.New("installation marker is missing")
	}
	if err != nil {
		return "", err
	}
	if !marker.Mode().IsRegular() {
		return "", errors.New("installation marker is not a regular file")
	}
	return prefix, nil
}

func (sm *softwareManager) uninstall(id, mode string) error {
	spec, ok := findSoftware(id)
	if !ok {
		return os.ErrNotExist
	}
	if mode != "backup" && mode != "purge" {
		return errors.New("invalid uninstall mode")
	}
	sm.mu.Lock()
	defer sm.mu.Unlock()
	if sm.busy {
		return errors.New("another software operation is running")
	}
	if _, err := sm.installedPrefix(id); err != nil {
		return err
	}
	if spec.unit != "" {
		info, err := os.Lstat(sm.unitPath(spec))
		if err != nil {
			return fmt.Errorf("service unit is unavailable: %w", err)
		}
		if !info.Mode().IsRegular() {
			return errors.New("service unit is not a regular file")
		}
	}
	sm.busy = true
	sm.jobs[id] = &installJob{operation: "uninstall", state: "uninstalling", message: "准备卸载"}
	go sm.uninstallInBackground(id, mode)
	return nil
}

func (sm *softwareManager) systemdAction(ctx context.Context, output io.Writer, action, unit string) error {
	actionCtx, cancel := context.WithTimeout(ctx, 90*time.Second)
	defer cancel()
	args := []string{action}
	if unit != "" {
		args = append(args, unit)
	}
	message, err := sm.systemctl(actionCtx, args...)
	if len(message) > 0 {
		_, _ = output.Write(message)
	}
	if err != nil {
		return fmt.Errorf("systemctl %s %s: %w: %s", action, unit, err, strings.TrimSpace(string(message)))
	}
	return nil
}

func moveInstallation(ctx context.Context, source, destination string, output io.Writer) error {
	if err := os.Rename(source, destination); err == nil {
		return nil
	} else if !errors.Is(err, syscall.EXDEV) {
		return err
	}
	command := exec.CommandContext(ctx, "cp", "-a", "--", source, destination)
	command.Stdout = output
	command.Stderr = output
	if err := command.Run(); err != nil {
		return fmt.Errorf("copy installation to backup: %w", err)
	}
	return os.RemoveAll(source)
}

func (sm *softwareManager) uninstallNow(ctx context.Context, id, mode string, output io.Writer) (backupPath string, resultErr error) {
	spec, _ := findSoftware(id)
	prefix, err := sm.installedPrefix(id)
	if err != nil {
		return "", err
	}
	if spec.unit != "" {
		_, _ = fmt.Fprintln(output, "SERA_STAGE:停止并禁用服务")
		if err := sm.systemdAction(ctx, output, "stop", spec.unit); err != nil {
			return "", err
		}
		if err := sm.systemdAction(ctx, output, "disable", spec.unit); err != nil {
			return "", err
		}
	}
	// A legacy runtime may contain newer independent installs beneath versions/.
	// Move that directory aside before removing the legacy tree, then put it back.
	if _, runtime := findEnvironment(id); runtime {
		versions := filepath.Join(prefix, "versions")
		if info, statErr := os.Lstat(versions); statErr == nil {
			if !info.IsDir() {
				return "", errors.New("运行环境版本目录不是普通目录")
			}
			holder, makeErr := os.MkdirTemp(filepath.Dir(prefix), ".sera-"+id+"-versions-")
			if makeErr != nil {
				return "", makeErr
			}
			staged := filepath.Join(holder, "versions")
			if moveErr := os.Rename(versions, staged); moveErr != nil {
				_ = os.Remove(holder)
				return "", moveErr
			}
			defer func() {
				if info, e := os.Lstat(prefix); errors.Is(e, os.ErrNotExist) {
					e = os.Mkdir(prefix, 0755)
					if e != nil {
						resultErr = errors.Join(resultErr, e)
						return
					}
				} else if e != nil || !info.IsDir() {
					resultErr = errors.Join(resultErr, errors.New("无法恢复多版本目录：安装目录不是普通目录"))
					return
				}
				if e := os.Rename(staged, versions); e != nil {
					resultErr = errors.Join(resultErr, fmt.Errorf("恢复多版本目录失败，保留在 %s: %w", staged, e))
					return
				}
				_ = os.Remove(holder)
			}()
		} else if !errors.Is(statErr, os.ErrNotExist) {
			return "", statErr
		}
	}
	if mode == "backup" {
		_, _ = fmt.Fprintln(output, "SERA_STAGE:备份安装目录")
		parent := filepath.Join(sm.root, "backup", "software")
		if err := os.MkdirAll(parent, 0700); err != nil {
			return "", err
		}
		backupDir, err := os.MkdirTemp(parent, id+"-")
		if err != nil {
			return "", err
		}
		backupPath = filepath.Join(backupDir, "install")
		if err := moveInstallation(ctx, prefix, backupPath, output); err != nil {
			return "", fmt.Errorf("backup at %s is incomplete: %w", backupPath, err)
		}
		_, _ = fmt.Fprintf(output, "备份路径：%s\n", backupPath)
	} else {
		_, _ = fmt.Fprintln(output, "SERA_STAGE:删除安装目录和数据")
		if err := os.RemoveAll(prefix); err != nil {
			return "", err
		}
	}
	if spec.unit != "" {
		_, _ = fmt.Fprintln(output, "SERA_STAGE:移除服务单元")
		if err := os.Remove(sm.unitPath(spec)); err != nil {
			return backupPath, err
		}
		if err := sm.systemdAction(ctx, output, "daemon-reload", ""); err != nil {
			return backupPath, err
		}
	}
	_, _ = fmt.Fprintln(output, "SERA_STAGE:卸载完成")
	return backupPath, nil
}

func (sm *softwareManager) uninstallInBackground(id, mode string) {
	result := "needs_attention"
	message := "卸载失败，请查看操作日志"
	logPath := sm.logPath(id)
	if err := os.MkdirAll(filepath.Dir(logPath), 0750); err == nil {
		if logFile, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0600); err == nil {
			_, _ = fmt.Fprintln(logFile, "SERA_STAGE:准备卸载")
			ctx, cancel := context.WithTimeout(context.Background(), 180*time.Minute)
			backupPath, runErr := sm.uninstallNow(ctx, id, mode, logFile)
			cancel()
			if runErr == nil {
				result = "not_installed"
				message = "卸载完成"
				if backupPath != "" {
					message += "，备份位于 " + backupPath
				}
			} else {
				message = "卸载失败：" + runErr.Error()
				_, _ = fmt.Fprintln(logFile, message)
				log.Printf("software %s uninstall failed: %v", id, runErr)
			}
			_ = logFile.Close()
		}
	}
	sm.mu.Lock()
	sm.jobs[id] = &installJob{operation: "uninstall", state: result, message: message}
	sm.busy = false
	sm.mu.Unlock()
}

func (sm *softwareManager) beginServiceAction() bool {
	sm.mu.Lock()
	defer sm.mu.Unlock()
	if sm.busy {
		return false
	}
	sm.busy = true
	return true
}

func (sm *softwareManager) endServiceAction() {
	sm.mu.Lock()
	sm.busy = false
	sm.mu.Unlock()
}

func (a *api) softwareHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	if !a.authorized(r) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	if r.URL.Path == "/v1/software" {
		if r.Method != http.MethodGet {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		items := make([]softwareItem, 0, len(softwareCatalog))
		for _, spec := range softwareCatalog {
			items = append(items, a.software.item(r.Context(), spec))
		}
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		_ = json.NewEncoder(w).Encode(struct {
			Items []softwareItem `json:"items"`
		}{items})
		return
	}
	parts := strings.Split(strings.TrimPrefix(r.URL.Path, "/v1/software/"), "/")
	if len(parts) != 2 {
		http.NotFound(w, r)
		return
	}
	spec, ok := findSoftware(parts[0])
	if !ok {
		http.NotFound(w, r)
		return
	}
	if parts[1] == "log" && r.Method == http.MethodGet {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = io.WriteString(w, tail(a.software.logPath(spec.id), 16<<10))
		return
	}
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	switch parts[1] {
	case "install":
		var command struct {
			Version string `json:"version"`
		}
		if r.ContentLength > 0 {
			if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&command); err != nil {
				http.Error(w, "invalid install payload", http.StatusBadRequest)
				return
			}
		}
		if _, err := installVersion(spec, command.Version); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		if err := a.software.install(spec.id, command.Version); err != nil {
			http.Error(w, err.Error(), http.StatusConflict)
			return
		}
		w.WriteHeader(http.StatusAccepted)
	case "uninstall":
		var command struct {
			Mode string `json:"mode"`
		}
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&command); err != nil ||
			(command.Mode != "backup" && command.Mode != "purge") {
			http.Error(w, "mode must be backup or purge", http.StatusBadRequest)
			return
		}
		if err := a.software.uninstall(spec.id, command.Mode); err != nil {
			http.Error(w, err.Error(), http.StatusConflict)
			return
		}
		w.WriteHeader(http.StatusAccepted)
	case "service":
		if !spec.installable || spec.unit == "" {
			http.Error(w, "service is not available", http.StatusConflict)
			return
		}
		var command struct {
			Action string `json:"action"`
		}
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&command); err != nil || !validServiceAction(command.Action) {
			http.Error(w, "invalid service action", http.StatusBadRequest)
			return
		}
		if _, err := os.Stat(filepath.Join(a.software.prefix(spec.id), ".sera-installed")); err != nil {
			http.Error(w, "software is not installed", http.StatusConflict)
			return
		}
		if !a.software.beginServiceAction() {
			http.Error(w, "another software operation is running", http.StatusConflict)
			return
		}
		defer a.software.endServiceAction()
		ctx, cancel := context.WithTimeout(r.Context(), 90*time.Second)
		defer cancel()
		output, err := a.software.systemctl(ctx, command.Action, spec.unit)
		if err != nil {
			message := strings.TrimSpace(string(output))
			if message == "" {
				message = fmt.Sprintf("%s failed", command.Action)
			}
			http.Error(w, message, http.StatusConflict)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	default:
		http.NotFound(w, r)
	}
}
