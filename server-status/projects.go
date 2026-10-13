package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

type projectRuntime struct {
	ID              string   `json:"id"`
	Name            string   `json:"name"`
	Installed       bool     `json:"installed"`
	Versions        []string `json:"versions"`
	LegacyInstalled bool     `json:"legacy_installed"`
	Binary          string   `json:"-"`
	Subcommand      []string `json:"-"`
}

var projectRuntimes = []projectRuntime{
	{ID: "python", Name: "Python", Binary: "bin/python3"},
	{ID: "node", Name: "Node.js", Binary: "bin/node"},
	{ID: "go", Name: "Go", Binary: "bin/go", Subcommand: []string{"run"}},
	{ID: "openjdk", Name: "Java", Binary: "bin/java", Subcommand: []string{"-jar"}},
	{ID: "dotnet", Name: ".NET", Binary: "dotnet"},
	{ID: "ruby", Name: "Ruby", Binary: "bin/ruby"},
	{ID: "bun", Name: "Bun", Binary: "bin/bun", Subcommand: []string{"run"}},
	{ID: "deno", Name: "Deno", Binary: "bin/deno", Subcommand: []string{"run", "--allow-net", "--allow-env"}},
}

type project struct {
	ID             string `json:"id"`
	Name           string `json:"name"`
	Runtime        string `json:"runtime"`
	RuntimeVersion string `json:"runtime_version,omitempty"`
	UseVenv        bool   `json:"use_venv,omitempty"`
	PythonServer   string `json:"python_server,omitempty"`
	PythonCallable string `json:"python_callable,omitempty"`
	PythonWorkers  int    `json:"python_workers,omitempty"`
	PythonThreads  int    `json:"python_threads,omitempty"`
	ServerReady    bool   `json:"server_ready"`
	Entry          string `json:"entry"`
	Port           int    `json:"port"`
	Directory      string `json:"directory"`
	ActiveState    string `json:"active_state"`
	Enabled        bool   `json:"enabled"`
	RuntimeReady   bool   `json:"runtime_ready"`
	VenvReady      bool   `json:"venv_ready"`
}

type projectListing struct {
	Items    []project        `json:"items"`
	Runtimes []projectRuntime `json:"runtimes"`
}

type projectManager struct {
	root       string
	unitDir    string
	software   *softwareManager
	mu         sync.Mutex
	systemctl  func(context.Context, ...string) ([]byte, error)
	ensureUser func() (int, int, error)
}

var projectIDPattern = regexp.MustCompile(`^[a-z][a-z0-9-]{0,47}$`)
var projectEntryPattern = regexp.MustCompile(`^[A-Za-z0-9._/-]{1,240}$`)
var pythonIdentifierPattern = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)

func pythonModule(entry string) (string, error) {
	name := strings.TrimSuffix(entry, ".py")
	parts := strings.Split(name, "/")
	if len(parts) > 1 && parts[len(parts)-1] == "__init__" {
		parts = parts[:len(parts)-1]
	}
	for _, part := range parts {
		if !pythonIdentifierPattern.MatchString(part) {
			return "", errors.New("WSGI 入口路径每一层都须是有效的 Python 模块名")
		}
	}
	return strings.Join(parts, "."), nil
}

func newProjectManager(root string, software *softwareManager) *projectManager {
	return &projectManager{root: root, unitDir: "/etc/systemd/system", software: software,
		systemctl: runSystemctl, ensureUser: ensureProjectUser}
}

func projectRuntimeByID(id string) (projectRuntime, bool) {
	for _, item := range projectRuntimes {
		if item.ID == id {
			return item, true
		}
	}
	return projectRuntime{}, false
}

func validProjectEntry(runtimeID, entry string) bool {
	if !projectEntryPattern.MatchString(entry) || filepath.IsAbs(entry) {
		return false
	}
	for _, part := range strings.Split(entry, "/") {
		if part == "" || part == ".." {
			return false
		}
	}
	if entry == "." {
		return runtimeID == "go"
	}
	ext := strings.ToLower(filepath.Ext(entry))
	switch runtimeID {
	case "python":
		return ext == ".py"
	case "node":
		return ext == ".js" || ext == ".mjs" || ext == ".cjs"
	case "go":
		return ext == ".go"
	case "openjdk":
		return ext == ".jar"
	case "dotnet":
		return ext == ".dll"
	case "ruby":
		return ext == ".rb"
	case "bun", "deno":
		return ext == ".js" || ext == ".mjs" || ext == ".ts" || ext == ".tsx"
	}
	return false
}

func (pm *projectManager) normalize(item project) (project, error) {
	item.ID = strings.TrimSpace(item.ID)
	item.Name = strings.TrimSpace(item.Name)
	item.Entry = strings.TrimSpace(item.Entry)
	if !projectIDPattern.MatchString(item.ID) {
		return project{}, errors.New("项目标识只允许小写字母、数字和连字符，须以字母开头，最多 48 字符")
	}
	if item.Name == "" || len(item.Name) > 80 || strings.ContainsAny(item.Name, "\r\n\x00") {
		return project{}, errors.New("项目名称须为 1 至 80 字符且不能包含换行")
	}
	if _, ok := projectRuntimeByID(item.Runtime); !ok {
		return project{}, errors.New("不支持此运行环境")
	}
	if item.RuntimeVersion != "" && !versionPattern.MatchString(item.RuntimeVersion) {
		return project{}, errors.New("无效运行环境版本")
	}
	if item.UseVenv && item.Runtime != "python" {
		return project{}, errors.New("仅 Python 项目可以使用虚拟环境")
	}
	if item.Runtime == "python" {
		if item.PythonServer == "" {
			item.PythonServer = "direct" // Existing projects keep their previous behavior.
		}
		if item.PythonServer != "direct" && item.PythonServer != "gunicorn" && item.PythonServer != "uwsgi" {
			return project{}, errors.New("Python 启动方式只能是直接运行、Gunicorn 或 uWSGI")
		}
		if item.PythonServer != "direct" {
			if !item.UseVenv {
				return project{}, errors.New("Gunicorn 和 uWSGI 需要启用项目虚拟环境")
			}
			if item.Port < 1 {
				return project{}, errors.New("WSGI 项目须配置监听端口")
			}
			if _, err := pythonModule(item.Entry); err != nil {
				return project{}, err
			}
			if item.PythonCallable == "" {
				item.PythonCallable = "app"
			}
			if !pythonIdentifierPattern.MatchString(item.PythonCallable) {
				return project{}, errors.New("WSGI callable 须为有效的 Python 标识符")
			}
			if item.PythonWorkers == 0 {
				item.PythonWorkers = 2
			}
			if item.PythonThreads == 0 {
				item.PythonThreads = 1
			}
			if item.PythonWorkers < 1 || item.PythonWorkers > 32 || item.PythonThreads < 1 || item.PythonThreads > 64 {
				return project{}, errors.New("进程数须为 1–32，线程数须为 1–64")
			}
		}
	} else if item.PythonServer != "" || item.PythonCallable != "" || item.PythonWorkers != 0 || item.PythonThreads != 0 {
		return project{}, errors.New("Python 启动配置只能用于 Python 项目")
	}
	if !validProjectEntry(item.Runtime, item.Entry) {
		return project{}, errors.New("入口须为项目目录内对应类型的相对文件路径；Go 也可使用 .")
	}
	if item.Port < 0 || item.Port > 65535 {
		return project{}, errors.New("端口须在 0 至 65535 之间")
	}
	if item.Directory == "" {
		item.Directory = pm.projectDir(item.ID)
	} else {
		if !filepath.IsAbs(item.Directory) || len(item.Directory) > 1024 ||
			strings.ContainsAny(item.Directory, "\r\n\x00") {
			return project{}, errors.New("工程目录须为服务器上的绝对路径")
		}
		item.Directory = filepath.Clean(item.Directory)
		if item.Directory == "/" {
			return project{}, errors.New("不能将服务器根目录作为工程目录")
		}
	}
	item.ActiveState = ""
	item.Enabled = false
	item.RuntimeReady = false
	item.VenvReady = false
	item.ServerReady = false
	return item, nil
}

func (pm *projectManager) projectDir(id string) string { return filepath.Join(pm.root, "projects", id) }
func (pm *projectManager) dataDir(id string) string    { return filepath.Join(pm.projectDir(id), "data") }
func (pm *projectManager) venvDir(id string) string    { return filepath.Join(pm.dataDir(id), "venv") }
func (pm *projectManager) metaPath(id string) string {
	return filepath.Join(pm.projectDir(id), ".sera-project.json")
}
func (pm *projectManager) unitName(id string) string { return "sera-project-" + id + ".service" }
func (pm *projectManager) unitPath(id string) string {
	return filepath.Join(pm.unitDir, pm.unitName(id))
}
func (pm *projectManager) logPath(id string) string {
	return filepath.Join(pm.root, "logs", "projects", id+".log")
}

func noSymlinkDirectory(path string, mode os.FileMode) error {
	if err := os.Mkdir(path, mode); err != nil && !errors.Is(err, os.ErrExist) {
		return err
	}
	info, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if !info.IsDir() {
		return fmt.Errorf("目录不能是软链接或文件：%s", path)
	}
	return nil
}

func ensureProjectUser() (int, int, error) {
	account, err := user.Lookup("sera-project")
	if err != nil {
		shell := "/bin/false"
		for _, candidate := range []string{"/usr/sbin/nologin", "/sbin/nologin"} {
			if _, statErr := os.Stat(candidate); statErr == nil {
				shell = candidate
				break
			}
		}
		output, addErr := exec.Command("useradd", "-r", "-M", "-s", shell, "sera-project").CombinedOutput()
		if addErr != nil {
			return 0, 0, fmt.Errorf("创建项目运行账户失败：%v: %s", addErr, strings.TrimSpace(string(output)))
		}
		account, err = user.Lookup("sera-project")
	}
	if err != nil {
		return 0, 0, err
	}
	uid, uidErr := strconv.Atoi(account.Uid)
	group, groupErr := user.LookupGroupId(account.Gid)
	if uidErr != nil || groupErr != nil {
		return 0, 0, errors.New("无法读取项目运行账户")
	}
	gid, err := strconv.Atoi(group.Gid)
	return uid, gid, err
}

func (pm *projectManager) prepareDirectories(id string) error {
	for _, path := range []string{pm.root, filepath.Join(pm.root, "projects"), pm.projectDir(id)} {
		if err := noSymlinkDirectory(path, 0755); err != nil {
			return err
		}
	}
	for _, path := range []string{filepath.Join(pm.root, "projects"), pm.projectDir(id)} {
		// The API service has a restrictive umask. Project processes still need
		// to traverse these two root-owned directories to read uploaded code.
		if err := os.Chmod(path, 0755); err != nil {
			return err
		}
	}
	uid, gid, err := pm.ensureUser()
	if err != nil {
		return err
	}
	data := filepath.Join(pm.projectDir(id), "data")
	if err := noSymlinkDirectory(data, 0750); err != nil {
		return err
	}
	if err := os.Chown(data, uid, gid); err != nil {
		return err
	}
	if err := os.Chmod(data, 0750); err != nil {
		return err
	}
	for _, path := range []string{filepath.Join(pm.root, "logs"), filepath.Join(pm.root, "logs", "projects")} {
		if err := noSymlinkDirectory(path, 0755); err != nil {
			return err
		}
	}
	return nil
}

func (pm *projectManager) workingDirectoryReady(item project) error {
	if item.Directory == pm.projectDir(item.ID) {
		return nil
	}
	info, err := os.Lstat(item.Directory)
	if errors.Is(err, os.ErrNotExist) {
		return errors.New("工程目录不存在，请先在文件管理中创建")
	}
	if err != nil {
		return err
	}
	if !info.IsDir() {
		return errors.New("工程目录不能是文件或软链接")
	}
	return nil
}

func (pm *projectManager) runtimeReady(id string) bool {
	if pm.runtimeReadyVersion(id, "") {
		return true
	}
	base := filepath.Join(pm.root, "server", id, "versions")
	entries, err := os.ReadDir(base)
	if err != nil {
		return false
	}
	for _, entry := range entries {
		if entry.IsDir() && versionPattern.MatchString(entry.Name()) && pm.runtimeReadyVersion(id, entry.Name()) {
			return true
		}
	}
	return false
}

func (pm *projectManager) runtimeBase(id, version string) string {
	base := filepath.Join(pm.root, "server", id)
	if version != "" {
		return filepath.Join(base, "versions", version)
	}
	return base
}

func (pm *projectManager) runtimeReadyVersion(id, version string) bool {
	runtime, ok := projectRuntimeByID(id)
	if !ok {
		return false
	}
	base := pm.runtimeBase(id, version)
	if info, err := os.Lstat(filepath.Join(base, ".sera-installed")); err != nil || !info.Mode().IsRegular() {
		return false
	}
	path := filepath.Join(base, runtime.Binary)
	resolvedBase, errBase := filepath.EvalSymlinks(base)
	resolved, err := filepath.EvalSymlinks(path)
	if errBase != nil || err != nil || !strings.HasPrefix(resolved, resolvedBase+string(os.PathSeparator)) {
		return false
	}
	info, err := os.Stat(resolved)
	return err == nil && info.Mode().IsRegular() && info.Mode().Perm()&0111 != 0
}

func (pm *projectManager) entryReady(item project) error {
	base := item.Directory
	baseInfo, statErr := os.Lstat(base)
	if statErr != nil || !baseInfo.IsDir() {
		return errors.New("项目目录不能是软链接或文件")
	}
	resolvedBase, err := filepath.EvalSymlinks(base)
	if err != nil {
		return err
	}
	resolved, err := filepath.EvalSymlinks(filepath.Join(base, item.Entry))
	if err != nil {
		return fmt.Errorf("入口文件不存在：%w", err)
	}
	if item.Entry == "." {
		if resolved != resolvedBase {
			return errors.New("Go 项目目录无效")
		}
		return nil
	}
	if !strings.HasPrefix(resolved, resolvedBase+string(os.PathSeparator)) {
		return errors.New("入口文件不能通过软链接指向项目目录外")
	}
	info, err := os.Stat(resolved)
	if err != nil || !info.Mode().IsRegular() {
		return errors.New("入口须为普通文件")
	}
	return nil
}

func systemdQuoted(value string) string {
	value = strings.ReplaceAll(value, "\\", "\\\\")
	value = strings.ReplaceAll(value, "\"", "\\\"")
	value = strings.ReplaceAll(value, "%", "%%")
	return "\"" + value + "\""
}

func (pm *projectManager) unit(item project) []byte {
	runtime, _ := projectRuntimeByID(item.Runtime)
	base := item.Directory
	data := pm.dataDir(item.ID)
	runtimeBase := pm.runtimeBase(item.Runtime, item.RuntimeVersion)
	binary := filepath.Join(runtimeBase, runtime.Binary)
	if item.Runtime == "python" && item.UseVenv {
		binary = filepath.Join(pm.venvDir(item.ID), "bin", "python3")
	}
	entry := filepath.Join(base, item.Entry)
	args := append([]string{binary}, runtime.Subcommand...)
	if item.Runtime == "python" && item.PythonServer != "" && item.PythonServer != "direct" {
		module, _ := pythonModule(item.Entry)
		binary = filepath.Join(pm.venvDir(item.ID), "bin", item.PythonServer)
		address := "127.0.0.1:" + strconv.Itoa(item.Port)
		if item.PythonServer == "gunicorn" {
			args = []string{binary, "--bind", address, "--workers", strconv.Itoa(item.PythonWorkers), "--threads", strconv.Itoa(item.PythonThreads), module + ":" + item.PythonCallable}
		} else {
			args = []string{binary, "--master", "--http-socket", address, "--processes", strconv.Itoa(item.PythonWorkers), "--threads", strconv.Itoa(item.PythonThreads), "--module", module, "--callable", item.PythonCallable, "--need-app", "--die-on-term"}
		}
	}
	if item.Runtime == "deno" {
		args = append(args, "--allow-read="+base, "--allow-write="+data)
	}
	if item.Runtime != "python" || item.PythonServer == "" || item.PythonServer == "direct" {
		args = append(args, entry)
	}
	quoted := make([]string, len(args))
	for index, arg := range args {
		quoted[index] = systemdQuoted(arg)
	}
	var body strings.Builder
	fmt.Fprintf(&body, "[Unit]\nDescription=Seraphim project %s\nAfter=network-online.target\nWants=network-online.target\n\n[Service]\n", item.ID)
	fmt.Fprintf(&body, "Type=simple\nUser=sera-project\nWorkingDirectory=%s\nExecStart=%s\n", strings.ReplaceAll(base, "%", "%%"), strings.Join(quoted, " "))
	fmt.Fprintf(&body, "Environment=%s\n", systemdQuoted("HOME="+data))
	pathBin := filepath.Join(runtimeBase, "bin")
	if item.Runtime == "python" && item.UseVenv {
		pathBin = filepath.Join(pm.venvDir(item.ID), "bin")
		fmt.Fprintf(&body, "Environment=%s\nEnvironment=PYTHONNOUSERSITE=1\n", systemdQuoted("VIRTUAL_ENV="+pm.venvDir(item.ID)))
	}
	fmt.Fprintf(&body, "Environment=%s\n", systemdQuoted("PATH="+pathBin+":/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin"))
	if item.Port > 0 {
		fmt.Fprintf(&body, "Environment=PORT=%d\n", item.Port)
	}
	switch item.Runtime {
	case "python":
		fmt.Fprintf(&body, "Environment=PYTHONDONTWRITEBYTECODE=1\n")
	case "go":
		fmt.Fprintf(&body, "Environment=%s\nEnvironment=%s\n", systemdQuoted("GOCACHE="+filepath.Join(data, "go-build")), systemdQuoted("GOPATH="+filepath.Join(data, "go")))
	case "dotnet":
		fmt.Fprintf(&body, "Environment=%s\nEnvironment=DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1\n", systemdQuoted("DOTNET_CLI_HOME="+data))
	case "bun":
		fmt.Fprintf(&body, "Environment=%s\n", systemdQuoted("BUN_INSTALL_CACHE_DIR="+filepath.Join(data, "bun-cache")))
	case "deno":
		fmt.Fprintf(&body, "Environment=%s\n", systemdQuoted("DENO_DIR="+filepath.Join(data, "deno")))
	}
	fmt.Fprintf(&body, "Restart=on-failure\nRestartSec=3\nNoNewPrivileges=yes\nProtectHome=yes\nProtectSystem=strict\nReadWritePaths=%s\nPrivateTmp=yes\n", data)
	fmt.Fprintf(&body, "StandardOutput=append:%s\nStandardError=inherit\n\n[Install]\nWantedBy=multi-user.target\n", pm.logPath(item.ID))
	return []byte(body.String())
}

func (pm *projectManager) read(id string) (project, error) {
	data, err := os.ReadFile(pm.metaPath(id))
	if err != nil {
		return project{}, err
	}
	var item project
	if err := json.Unmarshal(data, &item); err != nil {
		return project{}, err
	}
	item, err = pm.normalize(item)
	if err != nil || item.ID != id {
		return project{}, errors.New("项目配置已损坏")
	}
	return item, nil
}

func (pm *projectManager) state(ctx context.Context, item project) project {
	item.RuntimeReady = pm.runtimeReadyVersion(item.Runtime, item.RuntimeVersion)
	item.VenvReady = pm.venvReady(item)
	item.ServerReady = pm.pythonServerReady(item)
	statusCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	if output, err := pm.systemctl(statusCtx, "is-active", pm.unitName(item.ID)); err == nil || len(output) > 0 {
		item.ActiveState = strings.TrimSpace(string(output))
	}
	if output, err := pm.systemctl(statusCtx, "is-enabled", pm.unitName(item.ID)); err == nil {
		item.Enabled = strings.TrimSpace(string(output)) == "enabled"
	}
	if item.ActiveState == "" {
		item.ActiveState = "unknown"
	}
	return item
}

func (pm *projectManager) list(ctx context.Context) (projectListing, error) {
	pm.mu.Lock()
	defer pm.mu.Unlock()
	result := projectListing{Items: []project{}, Runtimes: append([]projectRuntime{}, projectRuntimes...)}
	for index := range result.Runtimes {
		id := result.Runtimes[index].ID
		result.Runtimes[index].LegacyInstalled = pm.runtimeReadyVersion(id, "")
		result.Runtimes[index].Versions = []string{}
		entries, _ := os.ReadDir(filepath.Join(pm.root, "server", id, "versions"))
		for _, entry := range entries {
			if entry.IsDir() && versionPattern.MatchString(entry.Name()) && pm.runtimeReadyVersion(id, entry.Name()) {
				result.Runtimes[index].Versions = append(result.Runtimes[index].Versions, entry.Name())
			}
		}
		sort.Slice(result.Runtimes[index].Versions, func(a, b int) bool {
			return compareVersion(result.Runtimes[index].Versions[a], result.Runtimes[index].Versions[b]) > 0
		})
		result.Runtimes[index].Installed = result.Runtimes[index].LegacyInstalled || len(result.Runtimes[index].Versions) > 0
	}
	files, err := os.ReadDir(filepath.Join(pm.root, "projects"))
	if errors.Is(err, os.ErrNotExist) {
		return result, nil
	}
	if err != nil {
		return result, err
	}
	for _, file := range files {
		if !file.IsDir() || !projectIDPattern.MatchString(file.Name()) {
			continue
		}
		if _, err := os.Lstat(pm.metaPath(file.Name())); errors.Is(err, os.ErrNotExist) {
			continue
		}
		item, err := pm.read(file.Name())
		if err != nil {
			return projectListing{}, err
		}
		result.Items = append(result.Items, pm.state(ctx, item))
	}
	sort.Slice(result.Items, func(i, j int) bool { return result.Items[i].ID < result.Items[j].ID })
	return result, nil
}

func (pm *projectManager) systemd(ctx context.Context, args ...string) error {
	timeout, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	output, err := pm.systemctl(timeout, args...)
	if err != nil {
		return fmt.Errorf("systemctl %s 失败：%s", strings.Join(args, " "), strings.TrimSpace(string(output)))
	}
	return nil
}

func (pm *projectManager) save(ctx context.Context, item project, creating bool) (project, error) {
	if !pm.software.beginServiceAction() {
		return project{}, errors.New("另一个软件操作正在进行")
	}
	defer pm.software.endServiceAction()
	pm.mu.Lock()
	defer pm.mu.Unlock()
	item, err := pm.normalize(item)
	if err != nil {
		return project{}, err
	}
	if creating {
		if _, err := os.Lstat(pm.metaPath(item.ID)); err == nil {
			return project{}, errors.New("项目已存在")
		} else if !errors.Is(err, os.ErrNotExist) {
			return project{}, err
		}
	} else if _, err := pm.read(item.ID); err != nil {
		return project{}, err
	}
	old, _ := pm.read(item.ID)
	wasRunning := false
	if !creating {
		wasRunning = pm.state(ctx, old).ActiveState == "active"
	}
	if wasRunning && !pm.runtimeReadyVersion(item.Runtime, item.RuntimeVersion) {
		return project{}, errors.New("正在运行的项目不能切换到未安装的运行环境")
	}
	if wasRunning && item.UseVenv && !pm.venvReady(item) {
		return project{}, errors.New("请先为项目创建与所选 Python 版本匹配的虚拟环境")
	}
	if wasRunning && !pm.pythonServerReady(item) {
		return project{}, errors.New("请先在项目虚拟环境中安装所选 Python 启动器")
	}
	if err := pm.prepareDirectories(item.ID); err != nil {
		return project{}, err
	}
	if err := pm.workingDirectoryReady(item); err != nil {
		return project{}, err
	}
	unitPath := pm.unitPath(item.ID)
	metaPath := pm.metaPath(item.ID)
	oldUnit, err := snapshotSite(unitPath)
	if err != nil {
		return project{}, err
	}
	oldMeta, err := snapshotSite(metaPath)
	if err != nil {
		return project{}, err
	}
	metadata, _ := json.MarshalIndent(item, "", "  ")
	if err := atomicSiteWrite(metaPath, append(metadata, '\n'), 0644); err != nil {
		return project{}, err
	}
	changed := true
	defer func() {
		if changed {
			restoreSites([]siteSnapshot{oldMeta, oldUnit})
			_ = pm.systemd(context.Background(), "daemon-reload")
			if wasRunning {
				_ = pm.systemd(context.Background(), "restart", pm.unitName(item.ID))
			}
		}
	}()
	if err := atomicSiteWrite(unitPath, pm.unit(item), 0644); err != nil {
		return project{}, err
	}
	if err := pm.systemd(ctx, "daemon-reload"); err != nil {
		return project{}, err
	}
	if wasRunning {
		if err := pm.entryReady(item); err != nil {
			return project{}, err
		}
		if err := pm.systemd(ctx, "restart", pm.unitName(item.ID)); err != nil {
			return project{}, err
		}
	}
	changed = false
	return pm.state(ctx, item), nil
}

func (pm *projectManager) action(ctx context.Context, id, action string) error {
	if !validServiceAction(action) {
		return errors.New("不支持此项目操作")
	}
	if !pm.software.beginServiceAction() {
		return errors.New("另一个软件操作正在进行")
	}
	defer pm.software.endServiceAction()
	pm.mu.Lock()
	defer pm.mu.Unlock()
	item, err := pm.read(id)
	if err != nil {
		return err
	}
	if action == "start" || action == "restart" || action == "enable" {
		if !pm.runtimeReadyVersion(item.Runtime, item.RuntimeVersion) {
			return errors.New("项目运行环境未安装")
		}
		if item.UseVenv && !pm.venvReady(item) {
			return errors.New("请先为项目创建与所选 Python 版本匹配的虚拟环境")
		}
		if !pm.pythonServerReady(item) {
			return errors.New("请先在项目虚拟环境中安装所选 Python 启动器")
		}
		if err := pm.prepareDirectories(id); err != nil {
			return err
		}
		if err := pm.workingDirectoryReady(item); err != nil {
			return err
		}
		if err := pm.entryReady(item); err != nil {
			return err
		}
	}
	return pm.systemd(ctx, action, pm.unitName(id))
}

func (pm *projectManager) remove(ctx context.Context, id string) error {
	if !pm.software.beginServiceAction() {
		return errors.New("另一个软件操作正在进行")
	}
	defer pm.software.endServiceAction()
	pm.mu.Lock()
	defer pm.mu.Unlock()
	item, err := pm.read(id)
	if err != nil {
		return err
	}
	state := pm.state(ctx, item)
	if state.ActiveState == "active" || state.ActiveState == "activating" {
		if err := pm.systemd(ctx, "stop", pm.unitName(id)); err != nil {
			return err
		}
	}
	if state.Enabled {
		if err := pm.systemd(ctx, "disable", pm.unitName(id)); err != nil {
			return err
		}
	}
	oldUnit, err := snapshotSite(pm.unitPath(id))
	if err != nil {
		return err
	}
	if err := os.Remove(pm.unitPath(id)); err != nil {
		return err
	}
	if err := pm.systemd(ctx, "daemon-reload"); err != nil {
		restoreSites([]siteSnapshot{oldUnit})
		_ = pm.systemd(context.Background(), "daemon-reload")
		return err
	}
	if err := os.Remove(pm.metaPath(id)); err != nil {
		restoreSites([]siteSnapshot{oldUnit})
		_ = pm.systemd(context.Background(), "daemon-reload")
		return err
	}
	return nil
}

func (a *api) projectsHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	if !a.authorized(r) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	if r.URL.Path == "/v1/projects" {
		switch r.Method {
		case http.MethodGet:
			listing, err := a.projects.list(r.Context())
			if err != nil {
				http.Error(w, err.Error(), http.StatusInternalServerError)
				return
			}
			w.Header().Set("Content-Type", "application/json; charset=utf-8")
			_ = json.NewEncoder(w).Encode(listing)
		case http.MethodPost:
			var item project
			if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 8<<10)).Decode(&item); err != nil {
				http.Error(w, "项目配置无效", http.StatusBadRequest)
				return
			}
			created, err := a.projects.save(r.Context(), item, true)
			if err != nil {
				http.Error(w, err.Error(), http.StatusConflict)
				return
			}
			w.Header().Set("Content-Type", "application/json; charset=utf-8")
			w.WriteHeader(http.StatusCreated)
			_ = json.NewEncoder(w).Encode(created)
		default:
			w.Header().Set("Allow", "GET, POST")
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		}
		return
	}
	parts := strings.Split(strings.TrimPrefix(r.URL.Path, "/v1/projects/"), "/")
	if len(parts) < 1 || len(parts) > 2 || !projectIDPattern.MatchString(parts[0]) {
		http.NotFound(w, r)
		return
	}
	id := parts[0]
	if len(parts) == 1 {
		switch r.Method {
		case http.MethodPut:
			var item project
			if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 8<<10)).Decode(&item); err != nil {
				http.Error(w, "项目配置无效", http.StatusBadRequest)
				return
			}
			item.ID = id
			if _, err := a.projects.save(r.Context(), item, false); err != nil {
				http.Error(w, err.Error(), http.StatusConflict)
				return
			}
			w.WriteHeader(http.StatusNoContent)
		case http.MethodDelete:
			if err := a.projects.remove(r.Context(), id); err != nil {
				http.Error(w, err.Error(), http.StatusConflict)
				return
			}
			w.WriteHeader(http.StatusNoContent)
		default:
			w.Header().Set("Allow", "PUT, DELETE")
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		}
		return
	}
	switch parts[1] {
	case "action":
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		var command struct {
			Action string `json:"action"`
		}
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1024)).Decode(&command); err != nil {
			http.Error(w, "项目操作无效", http.StatusBadRequest)
			return
		}
		if err := a.projects.action(r.Context(), id, command.Action); err != nil {
			http.Error(w, err.Error(), http.StatusConflict)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	case "venv":
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		var command struct {
			Action string `json:"action"`
		}
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1024)).Decode(&command); err != nil {
			http.Error(w, "虚拟环境操作无效", http.StatusBadRequest)
			return
		}
		if err := a.projects.manageVenv(r.Context(), id, command.Action); err != nil {
			http.Error(w, err.Error(), http.StatusConflict)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	case "log":
		if r.Method != http.MethodGet {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		a.projects.mu.Lock()
		_, err := a.projects.read(id)
		a.projects.mu.Unlock()
		if err != nil {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = w.Write([]byte(tail(a.projects.logPath(id), 64<<10)))
	default:
		http.NotFound(w, r)
	}
}
