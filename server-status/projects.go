package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
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
	"syscall"
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
	PythonWorker   string `json:"python_worker,omitempty"`
	PythonCallable string `json:"python_callable,omitempty"`
	PythonWorkers  int    `json:"python_workers,omitempty"`
	PythonThreads  int    `json:"python_threads,omitempty"`
	ServerReady    bool   `json:"server_ready"`
	Entry          string `json:"entry"`
	Port           int    `json:"port"`
	Directory      string `json:"directory"`
	// Env 是用户自定义的环境变量，EnvFile 表示额外加载工程目录下的 .env。
	// 项目要连数据库、要用 token，却只能把密钥写死在代码里，这条以前是缺的。
	Env     map[string]string `json:"env,omitempty"`
	EnvFile bool              `json:"env_file,omitempty"`
	// UseGlobalEnv 表示是否把「环境变量管理」里的值加载进这个项目的进程环境。
	// 默认**不加载**：那份值是面板统一保管的，项目读不读、读哪几个由项目和代码
	// 自己决定，面板不替它做决定。不想动项目配置的，代码可以直接读共用文件
	// server/env。用指针是为了区分「老配置里没写」和「用户明确勾上」。
	UseGlobalEnv *bool `json:"use_global_env,omitempty"`

	// 以下字段都是运行时状态，每次读取时重新算，不写回元数据。
	ActiveState   string `json:"active_state"`
	SubState      string `json:"sub_state,omitempty"`
	UnitFileState string `json:"unit_file_state,omitempty"`
	Result        string `json:"result,omitempty"`
	MainPID       int    `json:"main_pid,omitempty"`
	ExitStatus    int    `json:"exit_status,omitempty"`
	Restarts      int    `json:"restarts,omitempty"`
	MemoryBytes   int64  `json:"memory_bytes,omitempty"`
	UptimeSeconds int64  `json:"uptime_seconds,omitempty"`
	PortBusy      bool   `json:"port_busy,omitempty"`
	Enabled       bool   `json:"enabled"`
	RuntimeReady  bool   `json:"runtime_ready"`
	VenvReady     bool   `json:"venv_ready"`
	// Dependency 只在列表接口里带上：项目卡片上要能一眼看出面板认的是哪份依赖
	// 清单、装过没有，不必先点进详情。详情接口另有一份更完整的结论。
	Dependency *projectDependency `json:"dependency,omitempty"`
}

type projectListing struct {
	Items    []project        `json:"items"`
	Runtimes []projectRuntime `json:"runtimes"`
}

type projectManager struct {
	root       string
	unitDir    string
	software   *softwareManager
	variables  *globalVariableManager
	mu         sync.Mutex
	systemctl  func(context.Context, ...string) ([]byte, error)
	journalRun func(context.Context, ...string) ([]byte, error)
	ensureUser func() (int, int, error)
}

// inheritsGlobalEnv 只认显式勾上的项目：面板不替项目决定要不要读那份共用变量。
func (item project) inheritsGlobalEnv() bool {
	return item.UseGlobalEnv != nil && *item.UseGlobalEnv
}

func boolPointer(value bool) *bool { return &value }

var projectIDPattern = regexp.MustCompile(`^[a-z][a-z0-9-]{0,47}$`)
var projectEntryPattern = regexp.MustCompile(`^[A-Za-z0-9._/-]{1,240}$`)
var pythonIdentifierPattern = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)
var environmentNamePattern = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]{0,63}$`)

// reservedProjectIDs 留给接口路径用，否则 /v1/projects/ports 会和同名项目撞车。
var reservedProjectIDs = map[string]bool{"ports": true}

const (
	maxProjectEnvironment = 64
	maxEnvironmentValue   = 4096
)

// 这些变量由单元文件自己写，用户再填一遍只会互相打架。
var reservedEnvironmentNames = map[string]bool{
	"PATH": true, "HOME": true, "USER": true, "LOGNAME": true, "SHELL": true, "PWD": true,
	"PORT": true, "VIRTUAL_ENV": true, "PYTHONNOUSERSITE": true, "PYTHONDONTWRITEBYTECODE": true,
	"PYTHONUNBUFFERED": true, "GOCACHE": true, "GOPATH": true, "GOMODCACHE": true,
	"DOTNET_CLI_HOME": true, "BUN_INSTALL_CACHE_DIR": true, "DENO_DIR": true,
}

func normalizeEnvironment(input map[string]string) (map[string]string, error) {
	if len(input) == 0 {
		return nil, nil
	}
	if len(input) > maxProjectEnvironment {
		return nil, fmt.Errorf("环境变量最多 %d 个", maxProjectEnvironment)
	}
	result := make(map[string]string, len(input))
	for name, value := range input {
		name = strings.TrimSpace(name)
		if name == "" {
			return nil, errors.New("环境变量名不能为空")
		}
		if !environmentNamePattern.MatchString(name) {
			return nil, fmt.Errorf("环境变量名 %s 不合法：只能用字母、数字和下划线，且不能以数字开头", name)
		}
		if reservedEnvironmentNames[strings.ToUpper(name)] {
			return nil, fmt.Errorf("环境变量 %s 由面板管理，不能覆盖（端口请用端口字段）", name)
		}
		if len(value) > maxEnvironmentValue || strings.ContainsAny(value, "\r\n\x00") {
			return nil, fmt.Errorf("环境变量 %s 的值不能超过 %d 字节，也不能包含换行", name, maxEnvironmentValue)
		}
		result[name] = value
	}
	return result, nil
}

func pythonModule(entry string) (string, error) {
	name := strings.TrimSuffix(entry, ".py")
	parts := strings.Split(name, "/")
	if len(parts) > 1 && parts[len(parts)-1] == "__init__" {
		parts = parts[:len(parts)-1]
	}
	for _, part := range parts {
		if !pythonIdentifierPattern.MatchString(part) {
			return "", errors.New("Python 入口路径每一层都须是有效的 Python 模块名")
		}
	}
	return strings.Join(parts, "."), nil
}

func newProjectManager(root string, software *softwareManager, variables *globalVariableManager) *projectManager {
	if variables == nil {
		variables = newGlobalVariableManager(root)
	}
	return &projectManager{root: root, unitDir: "/etc/systemd/system", software: software, variables: variables,
		systemctl: runSystemctl, journalRun: runJournalctl, ensureUser: ensureSharedAccount}
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
	// 依赖结论是现算的运行时信息，不该跟着配置落盘（客户端把它发回来也不行）。
	item.Dependency = nil
	item.ID = strings.TrimSpace(item.ID)
	item.Name = strings.TrimSpace(item.Name)
	item.Entry = strings.TrimSpace(item.Entry)
	if !projectIDPattern.MatchString(item.ID) {
		return project{}, errors.New("项目标识只允许小写字母、数字和连字符，须以字母开头，最多 48 字符")
	}
	if reservedProjectIDs[item.ID] {
		return project{}, fmt.Errorf("项目标识 %s 由面板保留，请换一个", item.ID)
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
		if item.PythonServer != "direct" && item.PythonServer != "gunicorn" && item.PythonServer != "uwsgi" && item.PythonServer != "uvicorn" {
			return project{}, errors.New("不支持此 Python 启动方式")
		}
		if item.PythonServer == "gunicorn" {
			if item.PythonWorker == "" {
				item.PythonWorker = "sync"
				if item.PythonThreads > 1 {
					item.PythonWorker = "gthread"
				}
			}
			if item.PythonWorker != "sync" && item.PythonWorker != "gthread" && item.PythonWorker != "uvicorn" {
				return project{}, errors.New("不支持此 Gunicorn worker class")
			}
		} else if item.PythonWorker != "" {
			return project{}, errors.New("只有 Gunicorn 可以配置 worker class")
		}
		if item.PythonServer != "direct" {
			if !item.UseVenv {
				return project{}, errors.New("Python 启动器需要启用项目虚拟环境")
			}
			if item.Port < 1 {
				return project{}, errors.New("Python 服务须配置监听端口")
			}
			if _, err := pythonModule(item.Entry); err != nil {
				return project{}, err
			}
			if item.PythonCallable == "" {
				item.PythonCallable = "app"
			}
			if !pythonIdentifierPattern.MatchString(item.PythonCallable) {
				return project{}, errors.New("Python callable 须为有效的 Python 标识符")
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
	} else if item.PythonServer != "" || item.PythonWorker != "" || item.PythonCallable != "" || item.PythonWorkers != 0 || item.PythonThreads != 0 {
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
	env, err := normalizeEnvironment(item.Env)
	if err != nil {
		return project{}, err
	}
	item.Env = env
	if item.UseGlobalEnv == nil {
		// 补成显式的 false，客户端和自检都不用再猜「没写」是什么意思。
		item.UseGlobalEnv = boolPointer(false)
	}
	for _, field := range []*string{&item.ActiveState, &item.SubState, &item.UnitFileState, &item.Result} {
		*field = ""
	}
	item.Enabled = false
	item.RuntimeReady = false
	item.VenvReady = false
	item.ServerReady = false
	item.MainPID = 0
	item.ExitStatus = 0
	item.Restarts = 0
	item.MemoryBytes = 0
	item.UptimeSeconds = 0
	item.PortBusy = false
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

// 服务账户名上限 32 字节（内核与 PAM 的历史限制），名称一律以小写字母或下划线开头。
const maxAccountName = 32

var accountNamePattern = regexp.MustCompile(`^[a-z_][a-z0-9_-]{0,31}$`)

// sharedAccount 是面板唯一的业务运行账户。
//
// 面板主程序以 root 运行，只做必须特权的事：管 systemd、绑端口、写 /etc。
// 其余一切——运行项目进程、运行 PHP-FPM、读写网站与项目目录——都交给 sera。
// 所以服务器上不存在「每个项目一个账户、每个网站一个账户」的账户爆炸，
// 权限模型只有两层：root 与 sera。
//
// 代价是项目之间、网站之间彼此可读写：共用一个身份就没有隔离可言。这是
// 有意选择——换来的是排错时不必再猜某个目录归谁所有。
const sharedAccount = "sera"

// ensureSharedAccount 创建或复用 sera 账户，返回 uid/gid。
func ensureSharedAccount() (int, int, error) {
	return ensureServiceAccount(sharedAccount)
}

func nologinShell() string {
	for _, candidate := range []string{"/usr/sbin/nologin", "/sbin/nologin"} {
		if _, err := os.Stat(candidate); err == nil {
			return candidate
		}
	}
	return "/bin/false"
}

// ensureServiceAccount 创建或复用不可登录的系统账户，返回 uid/gid。
// 账户与同名用户组一起创建，单元文件里的 User= 与 Group= 都用这个名字。
func ensureServiceAccount(name string) (int, int, error) {
	if !accountNamePattern.MatchString(name) {
		return 0, 0, fmt.Errorf("运行账户名不合法：%s", name)
	}
	if _, err := user.Lookup(name); err != nil {
		shell := nologinShell()
		if output, groupErr := exec.Command("groupadd", "--system", name).CombinedOutput(); groupErr != nil {
			if _, lookupErr := user.LookupGroup(name); lookupErr != nil {
				return 0, 0, fmt.Errorf("创建运行账户组 %s 失败：%v: %s", name, groupErr, strings.TrimSpace(string(output)))
			}
		}
		if output, addErr := exec.Command("useradd", "--system", "--no-create-home", "--gid", name, "--shell", shell, name).CombinedOutput(); addErr != nil {
			return 0, 0, fmt.Errorf("创建运行账户 %s 失败：%v: %s", name, addErr, strings.TrimSpace(string(output)))
		}
	}
	account, err := user.Lookup(name)
	if err != nil {
		return 0, 0, fmt.Errorf("无法读取运行账户 %s：%w", name, err)
	}
	uid, uidErr := strconv.Atoi(account.Uid)
	group, groupErr := user.LookupGroupId(account.Gid)
	if uidErr != nil || groupErr != nil {
		return 0, 0, fmt.Errorf("无法读取运行账户 %s", name)
	}
	gid, err := strconv.Atoi(group.Gid)
	return uid, gid, err
}

// chownTree 把目录树整体改属，已经是目标归属的条目直接跳过。
// 不跟随软链接，避免把工程目录之外的目标改掉；元数据文件保持 root 所有，
// 否则项目进程就能改写自己的配置。
func chownTree(root string, uid, gid int) error {
	return filepath.WalkDir(root, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.Type()&os.ModeSymlink != 0 {
			return nil
		}
		switch entry.Name() {
		case ".sera-project.json", projectAccountMarker:
			return nil
		}
		info, infoErr := entry.Info()
		if infoErr != nil {
			return infoErr
		}
		if stat, ok := info.Sys().(*syscall.Stat_t); ok && int(stat.Uid) == uid && int(stat.Gid) == gid {
			return nil
		}
		return os.Lchown(path, uid, gid)
	})
}

// projectAccountMarker 记录工程目录当前已迁移到的运行账户。账户名变化时
// （例如从早期每项目一个专属账户迁回共享的 sera）需要把目录整体改属。
const projectAccountMarker = ".sera-account"

func (pm *projectManager) prepareDirectories(id string) error {
	for _, path := range []string{pm.root, filepath.Join(pm.root, "projects"), pm.projectDir(id)} {
		if err := noSymlinkDirectory(path, 0755); err != nil {
			return err
		}
	}
	// The API service has a restrictive umask. Project processes still need to
	// traverse this root-owned directory to reach their own project directory.
	if err := os.Chmod(filepath.Join(pm.root, "projects"), 0755); err != nil {
		return err
	}
	uid, gid, err := pm.ensureUser()
	if err != nil {
		return err
	}
	dir := pm.projectDir(id)
	// 工程目录归共享业务账户所有。0750 挡不住同账户的其他项目（它们本就是同一个
	// 身份），但能挡住数据库、中间件这些各自独立的软件账户。
	if err := os.Chown(dir, uid, gid); err != nil {
		return err
	}
	if err := os.Chmod(dir, 0750); err != nil {
		return err
	}
	account := sharedAccount
	marker := filepath.Join(dir, projectAccountMarker)
	if current, readErr := os.ReadFile(marker); readErr != nil || strings.TrimSpace(string(current)) != account {
		if err := chownTree(dir, uid, gid); err != nil {
			return err
		}
		if err := os.WriteFile(marker, []byte(account+"\n"), 0644); err != nil {
			return err
		}
	}
	data := filepath.Join(dir, "data")
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
			worker := item.PythonWorker
			if worker == "" {
				worker = "sync"
				if item.PythonThreads > 1 {
					worker = "gthread"
				}
			}
			if worker == "uvicorn" {
				worker = "uvicorn_worker.UvicornWorker"
			}
			args = []string{binary, "--bind", address, "--workers", strconv.Itoa(item.PythonWorkers), "--worker-class", worker}
			if worker == "gthread" {
				args = append(args, "--threads", strconv.Itoa(item.PythonThreads))
			}
			args = append(args, module+":"+item.PythonCallable)
		} else if item.PythonServer == "uvicorn" {
			args = []string{binary, module + ":" + item.PythonCallable, "--host", "127.0.0.1", "--port", strconv.Itoa(item.Port), "--workers", strconv.Itoa(item.PythonWorkers)}
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
	account := sharedAccount
	fmt.Fprintf(&body, "[Unit]\nDescription=Seraphim project %s\nAfter=network-online.target\nWants=network-online.target\n", item.ID)
	// 应用反复起不来时 systemd 会一直重启，面板上永远显示「运行中」，用户看不到
	// 任何问题。限次之后单元会落进 failed，才谈得上「启动失败」和真正的原因。
	fmt.Fprintf(&body, "StartLimitIntervalSec=60\nStartLimitBurst=5\n\n[Service]\n")
	fmt.Fprintf(&body, "Type=simple\nUser=%s\nGroup=%s\nWorkingDirectory=%s\nExecStart=%s\n", account, account, strings.ReplaceAll(base, "%", "%%"), strings.Join(quoted, " "))
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
		// 不缓冲才不会出现「日志里什么都没有，但服务确实在跑」。
		fmt.Fprintf(&body, "Environment=PYTHONDONTWRITEBYTECODE=1\nEnvironment=PYTHONUNBUFFERED=1\n")
	case "go":
		fmt.Fprintf(&body, "Environment=%s\nEnvironment=%s\n", systemdQuoted("GOCACHE="+filepath.Join(data, "go-build")), systemdQuoted("GOPATH="+filepath.Join(data, "go")))
	case "dotnet":
		fmt.Fprintf(&body, "Environment=%s\nEnvironment=DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1\n", systemdQuoted("DOTNET_CLI_HOME="+data))
	case "bun":
		fmt.Fprintf(&body, "Environment=%s\n", systemdQuoted("BUN_INSTALL_CACHE_DIR="+filepath.Join(data, "bun-cache")))
	case "deno":
		fmt.Fprintf(&body, "Environment=%s\n", systemdQuoted("DENO_DIR="+filepath.Join(data, "deno")))
	}
	// 自定义环境变量排在面板内置变量之后；重名的已在 normalize 里挡掉。
	effective := pm.effectiveEnvironment(item)
	names := make([]string, 0, len(effective))
	for name := range effective {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		fmt.Fprintf(&body, "Environment=%s\n", systemdQuoted(name+"="+effective[name]))
	}
	if item.EnvFile {
		fmt.Fprintf(&body, "EnvironmentFile=-%s\n", systemdPath(filepath.Join(base, ".env")))
	}
	fmt.Fprintf(&body, "Restart=on-failure\nRestartSec=3\nTimeoutStopSec=15\nNoNewPrivileges=yes\nProtectSystem=strict\n")
	if homeBoundDirectory(base) || homeBoundDirectory(data) {
		// 工程目录在家目录下时，ProtectHome=yes 会让进程连自己的代码都读不到。
		fmt.Fprintf(&body, "ProtectHome=no\n")
	} else {
		fmt.Fprintf(&body, "ProtectHome=yes\n")
	}
	// 工程目录本身也要可写：上传目录、缓存、sqlite 文件经常就放在代码旁边。
	// ReadWritePaths 只放开挂载命名空间，并不会给出进程本来没有的权限。
	writable := []string{systemdPath(base)}
	if data != base {
		writable = append(writable, systemdPath(data))
	}
	fmt.Fprintf(&body, "ReadWritePaths=%s\n", strings.Join(writable, " "))
	fmt.Fprintf(&body, "PrivateTmp=yes\n")
	fmt.Fprintf(&body, "StandardOutput=append:%s\nStandardError=inherit\n\n[Install]\nWantedBy=multi-user.target\n", pm.logPath(item.ID))
	return []byte(body.String())
}

// systemdPath 处理路径值：百分号在 systemd 里是说明符前缀，必须转义。
func systemdPath(value string) string {
	return strings.ReplaceAll(value, "%", "%%")
}

// sharedEnvPath 是「环境变量管理」导出的共用文件路径。自检里要能把路径直接报
// 出来，用户才知道「代码自己读」该读哪儿。
func (pm *projectManager) sharedEnvPath() string {
	if pm.variables == nil {
		return filepath.Join(pm.root, "server", sharedFileName)
	}
	return pm.variables.sharedFilePath()
}

// effectiveEnvironment 返回项目进程最终拿到的可变环境：只有勾了「加载面板环境
// 变量」的项目才会把那份共用值打底，然后被项目自己的同名变量覆盖——越具体越
// 优先。面板内置的 PATH/PORT/VIRTUAL_ENV 不在这里，它们由 unit() 单独写，
// 两层都覆盖不到。
func (pm *projectManager) effectiveEnvironment(item project) map[string]string {
	if len(item.Env) == 0 && !item.inheritsGlobalEnv() {
		return nil
	}
	result := map[string]string{}
	if item.inheritsGlobalEnv() && pm.variables != nil {
		for name, value := range pm.variables.lookup() {
			result[name] = value
		}
	}
	for name, value := range item.Env {
		result[name] = value
	}
	if len(result) == 0 {
		return nil
	}
	return result
}

// inheritedVariables 返回该项目实际加载到的面板变量，供详情页回答「这个值从哪来」。
func (pm *projectManager) inheritedVariables(item project) []globalVariable {
	if !item.inheritsGlobalEnv() || pm.variables == nil {
		return nil
	}
	return pm.variables.list()
}

// applyGlobalVariables 把「环境变量管理」里的值同步进所有勾了加载的项目单元。
//
// 变量本身存在一份 JSON 里，但项目真正读到的是 systemd 单元里的 Environment=；
// 不同步的话，用户改完变量、面板上一切正常，进程看到的还是旧值。
// 内容没变的单元不重写，免得为了几个变量把所有项目都重启一遍。
func (pm *projectManager) applyGlobalVariables(ctx context.Context) ([]string, error) {
	if !pm.software.beginServiceAction() {
		return nil, errors.New("另一个软件操作正在进行")
	}
	defer pm.software.endServiceAction()
	pm.mu.Lock()
	defer pm.mu.Unlock()
	entries, err := os.ReadDir(filepath.Join(pm.root, "projects"))
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		return nil, err
	}
	var updated []string
	var restarts []string
	for _, entry := range entries {
		id := entry.Name()
		if !entry.IsDir() || !projectIDPattern.MatchString(id) {
			continue
		}
		item, err := pm.read(id)
		if err != nil || !item.inheritsGlobalEnv() {
			continue
		}
		path := pm.unitPath(id)
		next := pm.unit(item)
		if current, err := os.ReadFile(path); err == nil && string(current) == string(next) {
			continue
		}
		if err := atomicSiteWrite(path, next, 0644); err != nil {
			return nil, err
		}
		updated = append(updated, item.Name)
		if pm.state(ctx, item).ActiveState == "active" {
			restarts = append(restarts, id)
		}
	}
	if len(updated) == 0 {
		return nil, nil
	}
	if err := pm.systemd(ctx, "daemon-reload"); err != nil {
		return nil, err
	}
	for _, id := range restarts {
		// 单个项目重启失败不该让整次保存回滚：单元已经写好，下次启动就是新值。
		_ = pm.systemd(ctx, "restart", pm.unitName(id))
	}
	return updated, nil
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

// applyStatus 把单元状态并进项目快照。state 与 detail 共用，避免重复调用 systemctl。
func (pm *projectManager) applyStatus(item project, status unitStatus) project {
	item.ActiveState = status.ActiveState
	item.SubState = status.SubState
	item.UnitFileState = status.UnitFileState
	item.Result = status.Result
	item.MainPID = status.MainPID
	item.ExitStatus = status.ExitStatus
	item.Restarts = status.Restarts
	item.MemoryBytes = status.MemoryBytes
	item.UptimeSeconds = status.UptimeSeconds
	item.Enabled = status.UnitFileState == "enabled"
	item.PortBusy = portUsage(item, status)
	return item
}

func (pm *projectManager) state(ctx context.Context, item project) project {
	item.RuntimeReady = pm.runtimeReadyVersion(item.Runtime, item.RuntimeVersion)
	item.VenvReady = pm.venvReady(item)
	item.ServerReady = pm.pythonServerReady(item)
	return pm.applyStatus(item, pm.unitStatus(ctx, item.ID))
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
		item = pm.state(ctx, item)
		dependency := pm.dependency(item)
		item.Dependency = &dependency
		result.Items = append(result.Items, item)
	}
	sort.Slice(result.Items, func(i, j int) bool { return result.Items[i].ID < result.Items[j].ID })
	return result, nil
}

func (pm *projectManager) systemd(ctx context.Context, args ...string) error {
	timeout, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	output, err := pm.systemctl(timeout, args...)
	if err != nil {
		// systemctl 出错时不一定往标准输出/错误写东西（例如单元名拼错、systemd
		// 拒绝受理）。output 为空就退回错误本身的文字，别把原因丢成空字符串。
		detail := strings.TrimSpace(string(output))
		if detail == "" {
			detail = err.Error()
		}
		return fmt.Errorf("systemctl %s 失败：%s", strings.Join(args, " "), detail)
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

// reconcileUnitAccount 让单元文件里的运行账户与当前结论保持一致。
// 早期版本所有项目共用一个 sera-project 账户，后来改成一项目一账户；现在两者
// 统一为共享的 sera。若不同步改写单元，服务会带着旧账户启动，而工程目录已经
// 改属到 sera，于是读不到自己的数据目录，直接以 203/EXEC 崩溃重启。
func (pm *projectManager) reconcileUnitAccount(ctx context.Context, item project) error {
	path := pm.unitPath(item.ID)
	current, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	account := sharedAccount
	if strings.Contains(string(current), "User="+account+"\n") {
		return nil
	}
	wasRunning := pm.state(ctx, item).ActiveState == "active"
	if err := atomicSiteWrite(path, pm.unit(item), 0644); err != nil {
		return err
	}
	if err := pm.systemd(context.Background(), "daemon-reload"); err != nil {
		return err
	}
	if wasRunning {
		if err := pm.systemd(context.Background(), "restart", pm.unitName(item.ID)); err != nil {
			return err
		}
	}
	return nil
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
		if err := pm.reconcileUnitAccount(ctx, item); err != nil {
			return err
		}
		if err := pm.workingDirectoryReady(item); err != nil {
			return err
		}
		if err := pm.entryReady(item); err != nil {
			return err
		}
		// 撞到 StartLimitBurst 之后 systemd 会直接拒绝启动（「Start request
		// repeated too quickly」），用户在面板上按多少次都没用。既然是人手动点的
		// 启动，就先清掉失败计数，让这次尝试真的执行。
		if action != "enable" && pm.unitStatus(ctx, id).ActiveState == "failed" {
			_ = pm.systemd(ctx, "reset-failed", pm.unitName(id))
		}
	}
	if err := pm.systemd(ctx, action, pm.unitName(id)); err != nil {
		return pm.startFailure(ctx, id, action, err)
	}
	return nil
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
	// /v1/projects/ports 排在项目 id 之前：它是一个固定路径，不是某个项目。
	if r.URL.Path == "/v1/projects/ports" {
		if r.Method != http.MethodGet {
			w.Header().Set("Allow", "GET")
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		after, _ := strconv.Atoi(r.URL.Query().Get("after"))
		ports, err := a.projects.freePorts(r.Context(), after, 5)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		_ = json.NewEncoder(w).Encode(map[string][]int{"ports": ports})
		return
	}
	// /v1/projects/import 同样排在项目 id 之前：它是一个动作，不是项目。
	if r.URL.Path == "/v1/projects/import" {
		a.importHandler(w, r)
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
	case "deps":
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		// 读一遍项目以便在安装前先回一句话，但真正的安装是同步跑完的，
		// 客户端把超时放宽到 16 分钟（见 ServerProjectAPI）。
		if err := a.projects.installDependencies(r.Context(), id); err != nil {
			http.Error(w, err.Error(), http.StatusConflict)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	case "status":
		if r.Method != http.MethodGet {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		detail, err := a.projects.detail(r.Context(), id)
		if err != nil {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		_ = json.NewEncoder(w).Encode(detail)
	case "log":
		switch r.Method {
		case http.MethodGet:
			a.projects.mu.Lock()
			_, err := a.projects.read(id)
			a.projects.mu.Unlock()
			if err != nil {
				http.NotFound(w, r)
				return
			}
			w.Header().Set("Content-Type", "text/plain; charset=utf-8")
			_, _ = w.Write([]byte(tail(a.projects.logPath(id), 64<<10)))
		case http.MethodDelete:
			if err := a.projects.clearLog(id); err != nil {
				http.Error(w, err.Error(), http.StatusConflict)
				return
			}
			w.WriteHeader(http.StatusNoContent)
		default:
			w.Header().Set("Allow", "GET, DELETE")
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		}
	default:
		http.NotFound(w, r)
	}
}
