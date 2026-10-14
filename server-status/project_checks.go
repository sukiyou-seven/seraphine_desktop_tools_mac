package main

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// projectCheck 是一条启动前自检。
//
// 面板以前只会把「启动失败」四个字丢出来，用户只能自己上服务器看日志。现在把
// 失败点、原因和建议动作一起摊开，并且尽量给出可直接点的修复入口。
type projectCheck struct {
	ID     string `json:"id"`
	Label  string `json:"label"`
	Level  string `json:"level"` // ok | warning | error
	Detail string `json:"detail,omitempty"`
	Hint   string `json:"hint,omitempty"`
	Action string `json:"action,omitempty"` // 建议的面板动作：runtime/venv/server/deps/edit/files/log
}

const (
	checkOK    = "ok"
	checkWarn  = "warning"
	checkError = "error"
)

func runtimeLabel(runtime projectRuntime, version string) string {
	if version == "" {
		return runtime.Name
	}
	return runtime.Name + " " + version
}

func pythonServerLabel(name string) string {
	switch name {
	case "gunicorn":
		return "Gunicorn"
	case "uwsgi":
		return "uWSGI"
	case "uvicorn":
		return "Uvicorn"
	}
	return name
}

// workerClass 把缺省值补齐，供展示与判断使用。
func workerClass(item project) string {
	if item.PythonServer != "gunicorn" {
		return ""
	}
	if item.PythonWorker != "" {
		return item.PythonWorker
	}
	if item.PythonThreads > 1 {
		return "gthread"
	}
	return "sync"
}

// checks 汇总启动前需要满足的条件。顺序即用户排查的顺序。
func (pm *projectManager) checks(ctx context.Context, item project, status unitStatus) []projectCheck {
	result := []projectCheck{}
	runtime, _ := projectRuntimeByID(item.Runtime)

	// 「上次没起来」排在最前面：用户点启动没反应时，这是唯一有用的信息。
	if status.ActiveState == "failed" || status.SubState == "auto-restart" {
		detail := failureSummary(status)
		if status.Restarts > 0 {
			detail += "，已重启 " + strconv.Itoa(status.Restarts) + " 次"
		}
		result = append(result, projectCheck{ID: "failed", Label: "最近一次启动", Level: checkError,
			Detail: detail, Hint: "看日志与系统日志定位原因；再次启动时会自动清除失败计数", Action: "log"})
	}

	switch {
	case item.Runtime == "dotnet" && selfContainedDotnet(item):
		// 自包含发布（dotnet publish --self-contained）把运行时一起打进了工程目录，
		// 系统里装没装 dotnet 都无所谓——这一条不能再拿「运行环境未安装」去吓人。
		result = append(result, projectCheck{ID: "runtime", Label: "运行环境", Level: checkOK,
			Detail: "自包含发布，使用工程自带的 .NET 运行时"})
	case pm.runtimeReadyVersion(item.Runtime, item.RuntimeVersion):
		result = append(result, projectCheck{ID: "runtime", Label: "运行环境", Level: checkOK,
			Detail: runtimeLabel(runtime, item.RuntimeVersion) + " 已安装"})
	default:
		hint := "在「环境管理」里安装 " + runtime.Name + "，再编辑项目选择该版本"
		if item.RuntimeVersion == "" {
			hint = "项目还没有选定运行环境版本，编辑项目时选择已安装的版本"
		}
		if item.Runtime == "dotnet" {
			hint += "；自包含发布（--self-contained）的工程也可以直接运行，无需安装"
		}
		result = append(result, projectCheck{ID: "runtime", Label: "运行环境", Level: checkError,
			Detail: runtimeLabel(runtime, item.RuntimeVersion) + " 未安装", Hint: hint, Action: "edit"})
	}

	if err := pm.workingDirectoryReady(item); err != nil {
		result = append(result, projectCheck{ID: "directory", Label: "工程目录", Level: checkError,
			Detail: err.Error(), Hint: "在文件管理中创建该目录，或改用默认目录", Action: "files"})
	} else if projectDirectoryEmpty(item.Directory) {
		result = append(result, projectCheck{ID: "directory", Label: "工程目录", Level: checkWarn,
			Detail: item.Directory + " 还是空的", Hint: "先把项目文件上传到工程目录", Action: "files"})
	} else {
		result = append(result, projectCheck{ID: "directory", Label: "工程目录", Level: checkOK, Detail: item.Directory})
	}

	if err := pm.entryReady(item); err != nil {
		result = append(result, projectCheck{ID: "entry", Label: "入口文件", Level: checkError,
			Detail: err.Error(), Hint: "把入口文件上传到工程目录，或修改入口路径", Action: "files"})
	} else {
		result = append(result, projectCheck{ID: "entry", Label: "入口文件", Level: checkOK, Detail: item.Entry})
	}

	if item.Runtime == "python" && item.UseVenv {
		if pm.venvReady(item) {
			result = append(result, projectCheck{ID: "venv", Label: "Python 虚拟环境", Level: checkOK,
				Detail: pm.venvDir(item.ID)})
		} else {
			result = append(result, projectCheck{ID: "venv", Label: "Python 虚拟环境", Level: checkError,
				Detail: "尚未创建，或不是用当前选定的 Python 版本创建的",
				Hint:   "点「创建虚拟环境」", Action: "venv"})
		}
	}

	if item.Runtime == "python" && item.PythonServer != "" && item.PythonServer != "direct" {
		server := pythonServerLabel(item.PythonServer)
		if pm.pythonServerReady(item) {
			result = append(result, projectCheck{ID: "server", Label: "Python 启动器", Level: checkOK,
				Detail: server + " 已装进项目虚拟环境"})
		} else {
			result = append(result, projectCheck{ID: "server", Label: "Python 启动器", Level: checkError,
				Detail: server + " 还没装进项目虚拟环境", Hint: "点「安装 " + server + "」", Action: "server"})
		}
	}

	// 依赖那一行说什么、要不要给按钮，全由 dependency() 一处算好，
	// 免得自检和详情页的依赖卡片各说各的。
	dependency := pm.dependency(item)
	result = append(result, projectCheck{ID: "deps", Label: "项目依赖", Level: dependency.Level,
		Detail: dependency.Detail, Hint: dependency.Hint, Action: dependency.Action})

	if item.Port > 0 {
		result = append(result, pm.portCheck(item, status))
	} else if item.Runtime == "python" && item.PythonServer != "" && item.PythonServer != "direct" {
		result = append(result, projectCheck{ID: "port", Label: "监听端口", Level: checkError,
			Detail: "Python 启动器需要监听端口", Hint: "编辑项目填写端口", Action: "edit"})
	}

	result = append(result, pm.variableCheck(item))

	if framework := pm.applicationCheck(item); framework != nil {
		result = append(result, *framework)
	}
	return result
}

// variableCheck 说明这个项目跟面板那份共用变量是什么关系。
//
// 面板不替项目决定：默认就不加载，代码想用可以直接读共用文件。真的打开了加载
// 却「没生效」，几乎都是项目自己填了同名变量把它覆盖了——这条要一并说清楚。
func (pm *projectManager) variableCheck(item project) projectCheck {
	if !item.inheritsGlobalEnv() {
		return projectCheck{ID: "variables", Label: "面板环境变量", Level: checkOK,
			Detail: "未加载面板的共用变量（默认不加载），项目只用自己填的环境变量",
			Hint:   "需要共用值时勾上「加载面板环境变量」；代码也可以直接读 " + pm.sharedEnvPath(),
			Action: "edit"}
	}
	inherited := pm.inheritedVariables(item)
	if len(inherited) == 0 {
		return projectCheck{ID: "variables", Label: "面板环境变量", Level: checkWarn,
			Detail: "项目已开启加载，但「环境变量管理」里还没有定义任何变量",
			Hint:   "在「环境变量管理」里加几条，例如 PROJECT_RUNTIME=dev", Action: "variables"}
	}
	names := make([]string, 0, len(inherited))
	overridden := make([]string, 0, len(inherited))
	for _, variable := range inherited {
		names = append(names, variable.Name)
		if _, ok := item.Env[variable.Name]; ok {
			overridden = append(overridden, variable.Name)
		}
	}
	detail := "已加载 " + strconv.Itoa(len(names)) + " 项：" + summarizeNames(names)
	check := projectCheck{ID: "variables", Label: "面板环境变量", Level: checkOK, Detail: detail, Action: "variables"}
	if len(overridden) > 0 {
		check.Hint = "其中 " + strings.Join(overridden, "、") + " 被项目自己的变量覆盖"
	} else {
		check.Hint = "改值请在「环境变量管理」里改，这里只是读到它"
	}
	return check
}

// summarizeNames 只列出前几个名字，自检清单是给人扫一眼的，不是变量表本身。
func summarizeNames(names []string) string {
	const limit = 6
	if len(names) <= limit {
		return strings.Join(names, "、")
	}
	return strings.Join(names[:limit], "、") + " 等"
}

func (pm *projectManager) portCheck(item project, status unitStatus) projectCheck {
	address := readableAddress(item.Port)
	running := status.ActiveState == "active"
	listening := portListening(item.Port)
	switch {
	case running && listening:
		return projectCheck{ID: "port", Label: "监听端口", Level: checkOK, Detail: address + " 已在监听"}
	case running && !listening:
		return projectCheck{ID: "port", Label: "监听端口", Level: checkError,
			Detail: "进程在运行，但 " + address + " 上没有接受连接",
			Hint:   "服务多半没起来就崩了，看日志确认它监听在哪", Action: "log"}
	case !running && listening:
		return projectCheck{ID: "port", Label: "监听端口", Level: checkError,
			Detail: address + " 已被其他进程占用", Hint: "换一个端口，或点「选择空闲端口」", Action: "edit"}
	default:
		return projectCheck{ID: "port", Label: "监听端口", Level: checkOK, Detail: address + " 空闲"}
	}
}

var asgiMarkers = []string{"fastapi", "starlette", "litestar", "import quart", "from quart", "uvicorn"}
var wsgiMarkers = []string{"from flask", "import flask", "django", "from bottle", "import bottle", "falcon", "wsgiref"}

func containsAny(content string, markers []string) bool {
	for _, marker := range markers {
		if strings.Contains(content, marker) {
			return true
		}
	}
	return false
}

// applicationCheck 用入口文件的 import 猜 WSGI/ASGI，看和所选启动器对不对得上。
//
// FastAPI（ASGI）配 Gunicorn 的 sync worker（WSGI）是「进程起来了、端口也监听着、
// 但每个请求都 500」的经典组合，日志里只有一坨 TypeError，很难联想到 worker class。
func (pm *projectManager) applicationCheck(item project) *projectCheck {
	if item.Runtime != "python" || item.PythonServer == "" || item.PythonServer == "direct" {
		return nil
	}
	entry := filepath.Join(item.Directory, item.Entry)
	info, err := os.Lstat(entry)
	if err != nil || !info.Mode().IsRegular() || info.Size() > 1<<20 {
		return nil
	}
	data, err := os.ReadFile(entry)
	if err != nil {
		return nil
	}
	content := strings.ToLower(string(data))
	asgi, wsgi := containsAny(content, asgiMarkers), containsAny(content, wsgiMarkers)
	if asgi == wsgi { // 两个都命中或都没命中时不硬下结论
		return nil
	}
	if asgi {
		switch {
		case item.PythonServer == "gunicorn" && workerClass(item) != "uvicorn":
			return &projectCheck{ID: "framework", Label: "应用与启动方式", Level: checkWarn,
				Detail: "入口看起来是 ASGI 应用（FastAPI/Starlette），但 Gunicorn 用的是 " +
					workerClass(item) + " worker（WSGI），请求会直接报 500",
				Hint: "把 Worker class 改成 uvicorn_worker.UvicornWorker，或把启动方式改成 Uvicorn", Action: "edit"}
		case item.PythonServer == "uwsgi":
			return &projectCheck{ID: "framework", Label: "应用与启动方式", Level: checkWarn,
				Detail: "入口看起来是 ASGI 应用（FastAPI/Starlette），uWSGI 只支持 WSGI",
				Hint:   "改用 Uvicorn，或 Gunicorn + uvicorn worker", Action: "edit"}
		}
		return nil
	}
	if item.PythonServer == "uvicorn" {
		return &projectCheck{ID: "framework", Label: "应用与启动方式", Level: checkWarn,
			Detail: "入口看起来是 WSGI 应用（Flask/Django），Uvicorn 只支持 ASGI",
			Hint:   "改用 Gunicorn（sync 或 gthread），或用 uWSGI", Action: "edit"}
	}
	return nil
}

// failureSummary 把 systemd 的结论翻译成一句人话。
func failureSummary(status unitStatus) string {
	reason := resultLabel(status.Result)
	if status.ExitStatus > 0 {
		return "进程以退出码 " + strconv.Itoa(status.ExitStatus) + " 结束（" + reason + "）"
	}
	return reason
}

func resultLabel(result string) string {
	switch result {
	case "exit-code":
		return "启动后立即退出"
	case "signal":
		return "被信号终止"
	case "timeout":
		return "启动超时"
	case "start-limit-hit":
		return "连续失败次数过多，systemd 已放弃重启"
	case "success":
		return "上一次正常退出"
	case "":
		return "原因未知"
	}
	return result
}

// startFailure 把 systemctl 的裸错误翻译成人人看得懂的一句话。
//
// systemctl 只回一句「Job for X failed because the control process exited with error
// code」，用户完全不知道发生了什么。这里补上 systemd 记录的真实结果，并指向能看到
// 自检和系统日志的地方。
func (pm *projectManager) startFailure(ctx context.Context, id, action string, cause error) error {
	label := map[string]string{"start": "启动", "restart": "重启", "enable": "设置开机自启"}[action]
	if label == "" {
		return cause
	}
	status := pm.unitStatus(ctx, id)
	if status.Result == "" || status.Result == "success" {
		return cause
	}
	return fmt.Errorf("%s失败：%s；项目「详情」里有启动自检和系统日志", label, failureSummary(status))
}

// projectDetail 是详情接口的返回：项目快照 + 单元状态 + 自检 + 依赖 + 日志。
type projectDetail struct {
	Project    project           `json:"project"`
	Status     unitStatus        `json:"status"`
	Checks     []projectCheck    `json:"checks"`
	Dependency projectDependency `json:"dependency"`
	// Variables 是这个项目实际继承到的全局变量，按名称排序。
	Variables []globalVariable `json:"global_variables,omitempty"`
	Log       string           `json:"log"`
	Journal   string           `json:"journal,omitempty"`
}

// 出现这些情况时把 journal 也带上：单元根本没起来，项目自己的日志文件会是空的。
func unitNeedsJournal(status unitStatus) bool {
	return status.ActiveState == "failed" ||
		status.SubState == "auto-restart" ||
		(status.Result != "" && status.Result != "success")
}

func (pm *projectManager) detail(ctx context.Context, id string) (projectDetail, error) {
	item, err := pm.read(id)
	if err != nil {
		return projectDetail{}, err
	}
	status := pm.unitStatus(ctx, id)
	result := projectDetail{
		Project:    pm.applyStatus(item, status),
		Status:     status,
		Checks:     pm.checks(ctx, item, status),
		Dependency: pm.dependency(item),
		Variables:  pm.inheritedVariables(item),
		Log:        tail(pm.logPath(id), 64<<10),
	}
	if unitNeedsJournal(status) {
		result.Journal = pm.journal(ctx, id)
	}
	return result, nil
}

// freePorts 从 after 之后找几个既没被占用、也没有分配给其他项目的端口。
func (pm *projectManager) freePorts(ctx context.Context, after, count int) ([]int, error) {
	if after < 1024 {
		after = 1024
	}
	if after > 65535 {
		return []int{}, nil
	}
	if count < 1 || count > 20 {
		count = 5
	}
	listing, err := pm.list(ctx)
	if err != nil {
		return nil, err
	}
	assigned := map[int]bool{}
	for _, item := range listing.Items {
		if item.Port > 0 {
			assigned[item.Port] = true
		}
	}
	result := []int{}
	for port := after + 1; port <= 65535 && len(result) < count; port++ {
		if assigned[port] || !portFree(port) {
			continue
		}
		result = append(result, port)
	}
	return result, nil
}

// clearLog 清空项目日志。用截断而不是删除，systemd 手里的追加描述符仍然有效。
func (pm *projectManager) clearLog(id string) error {
	pm.mu.Lock()
	defer pm.mu.Unlock()
	if _, err := pm.read(id); err != nil {
		return err
	}
	if err := os.Truncate(pm.logPath(id), 0); err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}

// portUsage 供列表使用：项目没在跑却占着别人的端口时标记出来。
func portUsage(item project, status unitStatus) bool {
	if item.Port < 1 || status.ActiveState == "active" {
		return false
	}
	return !portFree(item.Port)
}
