package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestProjectStartClearsFailedState(t *testing.T) {
	a, pm := projectTestAPI(t)
	if got := projectRequest(a, "POST", "/v1/projects",
		`{"id":"crasher","name":"Crasher","runtime":"node","entry":"index.js"}`, true).Code; got != 201 {
		t.Fatalf("create: %d", got)
	}
	if err := os.WriteFile(filepath.Join(pm.projectDir("crasher"), "index.js"), []byte("x\n"), 0644); err != nil {
		t.Fatal(err)
	}
	var calls []string
	pm.systemctl = func(_ context.Context, args ...string) ([]byte, error) {
		calls = append(calls, strings.Join(args, " "))
		if args[0] == "show" {
			return []byte("ActiveState=failed\nSubState=failed\nUnitFileState=disabled\nResult=exit-code\n" +
				"ExecMainStatus=1\nNRestarts=5\n"), nil
		}
		return nil, nil
	}
	if got := projectRequest(a, "POST", "/v1/projects/crasher/action", `{"action":"start"}`, true).Code; got != 204 {
		t.Fatalf("start: %d", got)
	}
	joined := strings.Join(calls, "\n")
	// 撞过 StartLimitBurst 的单元会直接拒绝启动，必须先清掉失败计数，
	// 否则用户在面板上按启动多少次都不会生效。
	if !strings.Contains(joined, "reset-failed sera-project-crasher.service") {
		t.Fatalf("启动失败过的项目时应先清除失败计数：\n%s", joined)
	}
	if !strings.Contains(joined, "start sera-project-crasher.service") {
		t.Fatalf("没有真的发出启动命令：\n%s", joined)
	}
}

// 启动失败时不能把 systemd 的原话直接甩给用户：「Job for X failed because the control
// process exited with error code」等于什么都没说。要换成真实结果，并指向详情页。
func TestProjectStartFailureExplainsItself(t *testing.T) {
	a, pm := projectTestAPI(t)
	if got := projectRequest(a, "POST", "/v1/projects",
		`{"id":"crasher","name":"Crasher","runtime":"node","entry":"index.js"}`, true).Code; got != 201 {
		t.Fatalf("create: %d", got)
	}
	if err := os.WriteFile(filepath.Join(pm.projectDir("crasher"), "index.js"), []byte("x\n"), 0644); err != nil {
		t.Fatal(err)
	}
	pm.systemctl = func(_ context.Context, args ...string) ([]byte, error) {
		if args[0] == "show" {
			return []byte("ActiveState=activating\nSubState=auto-restart\nResult=exit-code\nExecMainStatus=1\nNRestarts=1\n"), nil
		}
		return nil, errors.New("Job for sera-project-crasher.service failed because the control process exited with error code")
	}
	recorder := projectRequest(a, "POST", "/v1/projects/crasher/action", `{"action":"start"}`, true)
	if recorder.Code != 409 {
		t.Fatalf("启动失败应报错：%d %s", recorder.Code, recorder.Body.String())
	}
	message := recorder.Body.String()
	if !strings.Contains(message, "启动失败") || !strings.Contains(message, "退出码 1") ||
		!strings.Contains(message, "详情") {
		t.Fatalf("启动失败没有翻成人话：%s", message)
	}
	if strings.Contains(message, "control process exited") {
		t.Fatalf("不该把 systemd 的原话直接抛给用户：%s", message)
	}
	// 单元上次是正常退出（例如刚被停掉）时不要硬编一个失败原因，照原样返回。
	pm.systemctl = func(_ context.Context, args ...string) ([]byte, error) {
		if args[0] == "show" {
			return []byte("ActiveState=inactive\nSubState=dead\nResult=success\n"), nil
		}
		return nil, errors.New("systemctl: 其他错误")
	}
	recorder = projectRequest(a, "POST", "/v1/projects/crasher/action", `{"action":"start"}`, true)
	if !strings.Contains(recorder.Body.String(), "systemctl: 其他错误") {
		t.Fatalf("拿不到失败原因时应保留原错误：%s", recorder.Body.String())
	}
}

func TestProjectChecksReportFailedUnit(t *testing.T) {
	_, pm := projectTestAPI(t)
	item := project{ID: "crasher", Name: "Crasher", Runtime: "node", Entry: "index.js", Directory: pm.projectDir("crasher")}
	checks := pm.checks(context.Background(), item,
		unitStatus{ActiveState: "failed", SubState: "failed", Result: "exit-code", ExitStatus: 1, Restarts: 5})
	failed := findCheck(checks, "failed")
	if failed == nil || failed.Level != checkError || !strings.Contains(failed.Detail, "退出码 1") ||
		!strings.Contains(failed.Detail, "已重启 5 次") {
		t.Fatalf("失败原因没有解释清楚：%+v", failed)
	}
	// 反复重启（进程起了又死）也要报出来，否则卡片上只会显示「运行中」。
	restarting := pm.checks(context.Background(), item,
		unitStatus{ActiveState: "activating", SubState: "auto-restart", Result: "exit-code", ExitStatus: 1})
	if findCheck(restarting, "failed") == nil {
		t.Fatalf("反复重启应被报出来：%+v", restarting)
	}
}

func TestExecutableFileFollowsSymlinks(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "python3.13")
	if err := os.WriteFile(target, []byte("#!/bin/sh\n"), 0755); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(dir, "python3")
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}
	// 虚拟环境里的 bin/python3（以及 Node 官方包里的 bin/npm）都是软链接，
	// 用 Lstat 判断会一律判成「不可执行」，依赖安装直接卡死在第一步。
	if !executableFile(link) {
		t.Fatal("软链接形式的解释器应被认可")
	}
	plain := filepath.Join(dir, "requirements.txt")
	if err := os.WriteFile(plain, []byte("flask\n"), 0644); err != nil {
		t.Fatal(err)
	}
	if executableFile(plain) {
		t.Fatal("不可执行文件不应被当成可执行")
	}
	if executableFile(filepath.Join(dir, "missing")) {
		t.Fatal("不存在的文件不应被当成可执行")
	}
}

func TestParseUnitShowReadsRuntimeState(t *testing.T) {
	status := parseUnitShow("ActiveState=active\nSubState=auto-restart\nUnitFileState=enabled\n" +
		"Result=exit-code\nMainPID=0\nExecMainStatus=203\nNRestarts=7\nMemoryCurrent=125358080\n")
	if status.ActiveState != "active" || status.SubState != "auto-restart" || status.UnitFileState != "enabled" {
		t.Fatalf("基本状态解析错误：%+v", status)
	}
	if status.Result != "exit-code" || status.ExitStatus != 203 || status.Restarts != 7 {
		t.Fatalf("失败信息解析错误：%+v", status)
	}
	if status.MemoryBytes != 125358080 {
		t.Fatalf("内存解析错误：%d", status.MemoryBytes)
	}
	// systemd 拿不到内存时写 [not set]，不能当成 0 字节报给用户。
	bare := parseUnitShow("ActiveState=inactive\nMemoryCurrent=[not set]\nMemoryCurrent=infinity\n")
	if bare.MemoryBytes != 0 {
		t.Fatalf("[not set] 应视作未知：%d", bare.MemoryBytes)
	}
}

func TestProjectUnitCarriesEnvironmentAndSandboxLimits(t *testing.T) {
	a, pm := projectTestAPI(t)
	payload, err := json.Marshal(project{ID: "web", Name: "Web", Runtime: "node", Entry: "index.js",
		Port: 4100, EnvFile: true,
		Env: map[string]string{"DATABASE_URL": "mysql://wechat_test", "ZONE": "cn-hangzhou"}})
	if err != nil {
		t.Fatal(err)
	}
	if got := projectRequest(a, "POST", "/v1/projects", string(payload), true).Code; got != 201 {
		t.Fatalf("create: %d", got)
	}
	unit, err := os.ReadFile(pm.unitPath("web"))
	if err != nil {
		t.Fatal(err)
	}
	text := string(unit)
	for _, expected := range []string{
		`Environment="DATABASE_URL=mysql://wechat_test"`,
		`Environment="ZONE=cn-hangzhou"`,
		"StartLimitIntervalSec=60\nStartLimitBurst=5\n",
		"TimeoutStopSec=15",
		// 工程目录自己也要可写，否则项目往代码旁边写上传文件/缓存会 EROFS。
		"ReadWritePaths=" + pm.projectDir("web") + " " + pm.dataDir("web"),
		"EnvironmentFile=-" + pm.projectDir("web") + "/.env",
	} {
		if !strings.Contains(text, expected) {
			t.Fatalf("单元缺少 %q：\n%s", expected, text)
		}
	}
	// 家目录下的工程目录必须被认出来：那里不能再开 ProtectHome=yes，
	// 否则进程连自己的代码都读不到。
	for _, path := range []string{"/home/deploy/app", "/root/app", "/run/user/1000/app"} {
		if !homeBoundDirectory(path) {
			t.Fatalf("%s 应被判定为家目录", path)
		}
	}
	for _, path := range []string{"/www/seraphim/projects/web", "/homework/app", "/srv/app"} {
		if homeBoundDirectory(path) {
			t.Fatalf("%s 不应被判定为家目录", path)
		}
	}
}

func TestProjectEnvironmentValidation(t *testing.T) {
	a, _ := projectTestAPI(t)
	for _, body := range []string{
		`{"id":"env","name":"Env","runtime":"node","entry":"index.js","env":{"PORT":"9999"}}`,
		`{"id":"env","name":"Env","runtime":"node","entry":"index.js","env":{"PATH":"/tmp"}}`,
		`{"id":"env","name":"Env","runtime":"node","entry":"index.js","env":{"1BAD":"x"}}`,
		`{"id":"env","name":"Env","runtime":"node","entry":"index.js","env":{"GOOD":"a\nb"}}`,
		`{"id":"ports","name":"Ports","runtime":"node","entry":"index.js"}`,
	} {
		if got := projectRequest(a, "POST", "/v1/projects", body, true).Code; got != 409 {
			t.Fatalf("环境变量/保留标识校验漏了：%s → %d", body, got)
		}
	}
}

func TestProjectChecksDetectFrameworkMismatchAndPortConflict(t *testing.T) {
	a, pm := projectTestAPI(t)
	created := projectRequest(a, "POST", "/v1/projects",
		`{"id":"api","name":"API","runtime":"python","runtime_version":"","entry":"main.py","port":8099,"use_venv":true,"python_server":"gunicorn"}`, true)
	if created.Code != 201 {
		t.Fatalf("create: %d %s", created.Code, created.Body.String())
	}
	entry := filepath.Join(pm.projectDir("api"), "main.py")
	if err := os.WriteFile(entry, []byte("from fastapi import FastAPI\napp = FastAPI()\n"), 0644); err != nil {
		t.Fatal(err)
	}
	item, err := pm.read("api")
	if err != nil {
		t.Fatal(err)
	}
	checks := pm.checks(context.Background(), item, unitStatus{ActiveState: "inactive"})
	if find := findCheck(checks, "framework"); find == nil || find.Level != checkWarn ||
		!strings.Contains(find.Detail, "ASGI") {
		t.Fatalf("没有认出 FastAPI + Gunicorn sync 的组合：%+v", checks)
	}

	// 换成 ASGI 正确的 worker 组合后不再告警。
	item.PythonWorker = "uvicorn"
	if again := findCheck(pm.checks(context.Background(), item, unitStatus{ActiveState: "inactive"}), "framework"); again != nil {
		t.Fatalf("配置正确时不应告警：%+v", again)
	}

	// 端口被别人占着时要报出来。
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	item.Port = listener.Addr().(*net.TCPAddr).Port
	port := findCheck(pm.checks(context.Background(), item, unitStatus{ActiveState: "inactive"}), "port")
	if port == nil || port.Level != checkError || !strings.Contains(port.Detail, "已被其他进程占用") {
		t.Fatalf("端口占用没被认出来：%+v", port)
	}

	// 详情接口会把自检、依赖与日志一起带出来。
	detail := projectRequest(a, "GET", "/v1/projects/api/status", "", true)
	if detail.Code != 200 {
		t.Fatalf("status: %d", detail.Code)
	}
	var parsed projectDetail
	if err := json.Unmarshal(detail.Body.Bytes(), &parsed); err != nil {
		t.Fatal(err)
	}
	if len(parsed.Checks) < 5 || findCheck(parsed.Checks, "runtime") == nil {
		t.Fatalf("详情自检不完整：%+v", parsed.Checks)
	}
	if parsed.Project.ID != "api" || parsed.Project.ActiveState != "inactive" {
		t.Fatalf("详情里的项目快照不对：%+v", parsed.Project)
	}
}

func findCheck(checks []projectCheck, id string) *projectCheck {
	for index := range checks {
		if checks[index].ID == id {
			return &checks[index]
		}
	}
	return nil
}

func TestProjectDependenciesInstallAndFingerprint(t *testing.T) {
	a, pm := projectTestAPI(t)
	created := projectRequest(a, "POST", "/v1/projects",
		`{"id":"js","name":"JS","runtime":"node","entry":"index.js"}`, true)
	if created.Code != 201 {
		t.Fatalf("create: %d %s", created.Code, created.Body.String())
	}
	item, err := pm.read("js")
	if err != nil {
		t.Fatal(err)
	}
	if dependency := pm.dependency(item); dependency.Manifest != "package.json" || dependency.Present {
		t.Fatalf("缺少 package.json 时不应认为依赖存在：%+v", dependency)
	}
	manifest := filepath.Join(item.Directory, "package.json")
	if err := os.WriteFile(manifest, []byte(`{"name":"js"}`), 0644); err != nil {
		t.Fatal(err)
	}
	if dependency := pm.dependency(item); !dependency.Present || dependency.Installed {
		t.Fatalf("有清单但没装过：%+v", dependency)
	}
	if got := projectRequest(a, "POST", "/v1/projects/js/deps", "", true).Code; got != 204 {
		t.Fatalf("安装依赖：%d", got)
	}
	// 假 npm 会在工程目录留下痕迹，说明工作目录确实是工程目录。
	if _, err := os.Stat(filepath.Join(item.Directory, "dependency-installed")); err != nil {
		t.Fatalf("依赖命令没有在工程目录里执行：%v", err)
	}
	if dependency := pm.dependency(item); !dependency.Installed {
		t.Fatalf("安装后应标记为已安装：%+v", dependency)
	}
	// 清单改动后必须重新提示安装。
	if err := os.WriteFile(manifest, []byte(`{"name":"js","dependencies":{"express":"^4"}}`), 0644); err != nil {
		t.Fatal(err)
	}
	if dependency := pm.dependency(item); dependency.Installed {
		t.Fatalf("清单改动后仍认为已安装：%+v", dependency)
	}
}

// pythonProjectWithVenv 造一个「已启用虚拟环境且看起来就绪」的 Python 项目。
// venvScript 会成为虚拟环境里的 bin/python3，用来观察面板到底执行了什么。
func pythonProjectWithVenv(t *testing.T, a *api, pm *projectManager, id, venvScript string) project {
	t.Helper()
	body := fmt.Sprintf(`{"id":%q,"name":"Py","runtime":"python","entry":"main.py","use_venv":true}`, id)
	created := projectRequest(a, "POST", "/v1/projects", body, true)
	if created.Code != 201 {
		t.Fatalf("create: %d %s", created.Code, created.Body.String())
	}
	item, err := pm.read(id)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(item.Directory, "main.py"), []byte("print('hi')\n"), 0644); err != nil {
		t.Fatal(err)
	}
	venv := pm.venvDir(id)
	if err := os.MkdirAll(filepath.Join(venv, "bin"), 0755); err != nil {
		t.Fatal(err)
	}
	for name, content := range map[string]string{
		"pyvenv.cfg":        "home = /usr\n",
		".sera-python-base": pm.pythonBase(item) + "\n",
	} {
		if err := os.WriteFile(filepath.Join(venv, name), []byte(content), 0644); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(venv, "bin", "python3"), []byte(venvScript), 0755); err != nil {
		t.Fatal(err)
	}
	if !pm.venvReady(item) {
		t.Fatal("测试用的虚拟环境没有就绪")
	}
	return item
}

// Python 项目不一定有 requirements.txt：pyproject.toml（PEP 621 的标准写法）
// 和 setup.py 都算依赖清单，面板要认得出、也要装得上。
func TestPythonProjectWithoutRequirementsUsesPyproject(t *testing.T) {
	a, pm := projectTestAPI(t)
	directory := pm.projectDir("pyapi")
	record := filepath.Join(t.TempDir(), "pip.log")
	// 假的解释器：先记录被调用的参数；pip install <工程目录>（构建项目本身）
	// 一律失败，模拟「扁平布局，setuptools 自动发现找不到包」的工程。
	script := "#!/bin/sh\n" +
		"echo \"$*\" >> " + record + "\n" +
		"for arg in \"$@\"; do\n" +
		"  if [ \"$arg\" = \"" + directory + "\" ]; then exit 1; fi\n" +
		"done\n" +
		"exit 0\n"
	item := pythonProjectWithVenv(t, a, pm, "pyapi", script)

	// 一个清单都没有时，要把面板找过的文件名都列出来。
	missing := pm.dependency(item)
	if missing.Present || missing.Level != checkWarn {
		t.Fatalf("没有清单时不应认为依赖存在：%+v", missing)
	}
	for _, name := range []string{"requirements.txt", "pyproject.toml", "setup.py"} {
		if !strings.Contains(missing.Detail, name) {
			t.Fatalf("没有清单时要说明找过 %s：%+v", name, missing)
		}
	}

	pyproject := filepath.Join(directory, "pyproject.toml")
	content := "[project]\nname = \"pyapi\"\nversion = \"0.1.0\"\ndependencies = [\n" +
		"  \"fastapi>=0.110\",\n  \"uvicorn[standard]\",\n]\n"
	if err := os.WriteFile(pyproject, []byte(content), 0644); err != nil {
		t.Fatal(err)
	}
	detected := pm.dependency(item)
	if !detected.Present || detected.Installed || detected.Manifest != "pyproject.toml" || detected.Command != "pip install ." {
		t.Fatalf("pyproject.toml 没有被认出来：%+v", detected)
	}
	check := findCheck(pm.checks(context.Background(), item, unitStatus{ActiveState: "inactive"}), "deps")
	if check == nil || check.Level != checkWarn || check.Action != "deps" || !strings.Contains(check.Hint, "pip install .") {
		t.Fatalf("自检没有给出依赖入口：%+v", check)
	}

	// 安装：第一条命令构建失败，面板要退一步，只装 pyproject.toml 里声明的依赖。
	installed := projectRequest(a, "POST", "/v1/projects/pyapi/deps", "", true)
	if installed.Code != 204 {
		t.Fatalf("安装依赖：%d %s", installed.Code, installed.Body.String())
	}
	log, err := os.ReadFile(record)
	if err != nil {
		t.Fatal(err)
	}
	calls := string(log)
	if !strings.Contains(calls, "--disable-pip-version-check "+directory) {
		t.Fatalf("没有先试 pip install .：%s", calls)
	}
	if !strings.Contains(calls, "fastapi>=0.110") || !strings.Contains(calls, "uvicorn[standard]") {
		t.Fatalf("构建失败后没有改为安装声明的依赖：%s", calls)
	}
	// 装好之后不能还挂着「没有清单」那句提示，否则用户以为还有问题。
	if after := pm.dependency(item); !after.Installed || after.Level != checkOK ||
		after.Hint != "" || after.Action != "" || !strings.Contains(after.Detail, "已按当前 pyproject.toml 安装") {
		t.Fatalf("装完应标记为已安装且不带多余提示：%+v", after)
	}
	// 清单改动后必须重新提示安装。
	if err := os.WriteFile(pyproject, []byte(content+"# 改一下\n"), 0644); err != nil {
		t.Fatal(err)
	}
	if changed := pm.dependency(item); changed.Installed {
		t.Fatalf("清单改动后仍认为已安装：%+v", changed)
	}
}

// 只放了工具配置的 pyproject.toml 很常见：不能假装能照它装依赖，也不能装作没有清单。
func TestPyprojectManifestParsing(t *testing.T) {
	multi := []byte("[project]\nname = \"a\"\ndependencies = [\n  \"fastapi>=0.110\",  # web 框架\n" +
		"  \"uvicorn[standard]\",\n]\n\n[tool.ruff]\nline-length = 100\n")
	if values := pyprojectRequirements(multi); len(values) != 2 ||
		values[0] != "fastapi>=0.110" || values[1] != "uvicorn[standard]" {
		t.Fatalf("多行 dependencies 解析错误：%v", values)
	}
	if !pyprojectDeclaresProject(multi) {
		t.Fatal("有 [project] 就算可安装的项目")
	}
	single := pyprojectRequirements([]byte("[project]\ndependencies = [\"flask\", 'requests[socks]']\n"))
	if len(single) != 2 || single[0] != "flask" || single[1] != "requests[socks]" {
		t.Fatalf("单行 dependencies 解析错误：%v", single)
	}
	toolOnly := []byte("[tool.black]\nline-length = 100\n")
	if pyprojectRequirements(toolOnly) != nil || pyprojectDeclaresProject(toolOnly) {
		t.Fatal("只有工具配置的 pyproject.toml 不能当成可安装的项目")
	}
	// Poetry 的 ^ 约束不是 PEP 508，翻译过来未必等价，宁可让用户补 requirements.txt。
	poetry := []byte("[tool.poetry]\nname = \"a\"\n[tool.poetry.dependencies]\nfastapi = \"^0.110\"\n")
	if pyprojectRequirements(poetry) != nil {
		t.Fatal("Poetry 的约束不该被原样交给 pip")
	}
	if !pyprojectDeclaresProject(poetry) {
		t.Fatal("有 [tool.poetry] 就算可安装的项目")
	}
	// 依赖由构建后端算出来时更不能猜。
	dynamic := []byte("[project]\nname = \"a\"\ndynamic = [\"dependencies\"]\n")
	if pyprojectRequirements(dynamic) != nil {
		t.Fatal("dynamic 依赖不该被猜出来")
	}
	// 看不懂的元素（命令行参数之类）整体放弃。
	if _, ok := tomlStringList(`["-r other.txt"]`); ok {
		t.Fatal("命令行参数混进依赖列表时应当整体放弃")
	}
}

// Python 项目没开虚拟环境时，面板不往共享的 Python 里装依赖——但要说清原因。
func TestPythonProjectWithoutVenvExplainsDependencyPath(t *testing.T) {
	a, pm := projectTestAPI(t)
	if got := projectRequest(a, "POST", "/v1/projects",
		`{"id":"plain","name":"Plain","runtime":"python","entry":"main.py"}`, true).Code; got != 201 {
		t.Fatalf("create: %d", got)
	}
	item, err := pm.read("plain")
	if err != nil {
		t.Fatal(err)
	}
	// 依赖清单的识别与虚拟环境无关：面板仍然要认得出工程里摆的是哪份清单，
	// 否则用户根本看不出面板支持 pyproject.toml / setup.py。
	if plans := pm.dependencyPlans(item); len(plans) != 3 {
		t.Fatalf("没开虚拟环境也要认得出 Python 的依赖清单：%+v", plans)
	}
	dependency := pm.dependency(item)
	if dependency.Manifest != "" || dependency.Level != checkWarn || dependency.Action != "edit" ||
		!strings.Contains(dependency.Detail, "虚拟环境") {
		t.Fatalf("没开虚拟环境时要说清原因：%+v", dependency)
	}
	// 工程里真有清单时，清单名要出现在结论里。
	if err := os.WriteFile(filepath.Join(item.Directory, "requirements.txt"), []byte("requests\n"), 0644); err != nil {
		t.Fatal(err)
	}
	if withManifest := pm.dependency(item); withManifest.Manifest != "requirements.txt" ||
		!strings.Contains(withManifest.Detail, "requirements.txt") {
		t.Fatalf("没开虚拟环境也要报出找到的清单：%+v", withManifest)
	}
	refused := projectRequest(a, "POST", "/v1/projects/plain/deps", "", true)
	if refused.Code != 409 || !strings.Contains(refused.Body.String(), "虚拟环境") {
		t.Fatalf("安装依赖的报错没有指向虚拟环境：%d %s", refused.Code, refused.Body.String())
	}
}

// 依赖清单的识别结果要出现在项目列表里：卡片上就该看得见面板认的是哪份清单，
// 而不是必须先点进详情。顺便盯住「运行时字段不落盘」这条。
func TestProjectListingCarriesDependency(t *testing.T) {
	a, pm := projectTestAPI(t)
	if got := projectRequest(a, "POST", "/v1/projects",
		`{"id":"pyapi","name":"PyApi","runtime":"python","entry":"main.py","use_venv":true}`, true).Code; got != 201 {
		t.Fatalf("create: %d", got)
	}
	item, err := pm.read("pyapi")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(item.Directory, "pyproject.toml"),
		[]byte("[project]\nname = \"pyapi\"\ndependencies = [\"flask\"]\n"), 0644); err != nil {
		t.Fatal(err)
	}
	listing, err := pm.list(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(listing.Items) != 1 || listing.Items[0].Dependency == nil {
		t.Fatalf("列表没有带上依赖结论：%+v", listing.Items)
	}
	if detected := listing.Items[0].Dependency; detected.Manifest != "pyproject.toml" ||
		detected.Command != "pip install ." || !detected.Present {
		t.Fatalf("列表里的依赖结论不对：%+v", detected)
	}
	// 列表快照是现算的，不能写回配置：客户端把字段发回来也不该落盘。
	body := `{"id":"pyapi","name":"PyApi","runtime":"python","entry":"main.py","use_venv":true,` +
		`"dependency":{"manifest":"requirements.txt","present":true}}`
	if got := projectRequest(a, "PUT", "/v1/projects/pyapi", body, true).Code; got != 204 {
		t.Fatalf("update: %d", got)
	}
	saved, err := os.ReadFile(pm.metaPath("pyapi"))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(saved), "dependency") {
		t.Fatalf("依赖结论不该写进项目配置：%s", saved)
	}
}

// 锁文件决定包管理器：pnpm / yarn 工程用 npm 装出来的是另一套 node_modules。
func TestNodeLockfileChoosesPackageManager(t *testing.T) {
	a, pm := projectTestAPI(t)
	if got := projectRequest(a, "POST", "/v1/projects",
		`{"id":"web","name":"Web","runtime":"node","entry":"index.js"}`, true).Code; got != 201 {
		t.Fatalf("create: %d", got)
	}
	item, err := pm.read("web")
	if err != nil {
		t.Fatal(err)
	}
	write := func(name, content string) {
		t.Helper()
		if err := os.WriteFile(filepath.Join(item.Directory, name), []byte(content), 0644); err != nil {
			t.Fatal(err)
		}
	}
	write("package.json", `{"name":"web"}`)
	write("pnpm-lock.yaml", "lockfileVersion: '9.0'\n")

	// 没装 pnpm：退回 npm，但要把这件事说清楚。
	fallback := pm.dependency(item)
	if fallback.Command != "npm install" || !strings.Contains(fallback.Hint, "没有 pnpm") {
		t.Fatalf("pnpm 缺席时应退回 npm 并说明：%+v", fallback)
	}

	// 运行环境里装了 pnpm 就按它自己的锁文件装。
	pnpm := filepath.Join(pm.root, "server", "node", "bin", "pnpm")
	if err := os.WriteFile(pnpm, []byte("#!/bin/sh\nexit 0\n"), 0755); err != nil {
		t.Fatal(err)
	}
	if withPnpm := pm.dependency(item); withPnpm.Command != "pnpm install" || strings.Contains(withPnpm.Hint, "没有 pnpm") {
		t.Fatalf("装了 pnpm 就该用 pnpm：%+v", withPnpm)
	}

	// 换回 npm 工程（有 package-lock.json）时用 ci。
	if err := os.Remove(filepath.Join(item.Directory, "pnpm-lock.yaml")); err != nil {
		t.Fatal(err)
	}
	write("package-lock.json", "{}")
	if npm := pm.dependency(item); npm.Command != "npm ci" {
		t.Fatalf("有 package-lock.json 时应当用 npm ci：%+v", npm)
	}
}

func TestProjectPortsStatusAndLogClearing(t *testing.T) {
	a, pm := projectTestAPI(t)
	if got := projectRequest(a, "GET", "/v1/projects/ports", "", true).Code; got != 200 {
		t.Fatalf("空闲端口接口：%d", got)
	}
	response := projectRequest(a, "GET", "/v1/projects/ports?after=3000", "", true)
	var payload struct {
		Ports []int `json:"ports"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &payload); err != nil {
		t.Fatal(err)
	}
	if len(payload.Ports) == 0 {
		t.Fatal("没有返回任何空闲端口")
	}
	for index := 1; index < len(payload.Ports); index++ {
		if payload.Ports[index] <= payload.Ports[index-1] {
			t.Fatalf("端口应递增：%v", payload.Ports)
		}
	}
	first := payload.Ports[0]
	if first <= 3000 || !portFree(first) {
		t.Fatalf("返回的端口 %d 不可用。", first)
	}

	if got := projectRequest(a, "POST", "/v1/projects", `{"id":"demo","name":"Demo","runtime":"node","entry":"index.js"}`, true).Code; got != 201 {
		t.Fatalf("create: %d", got)
	}
	if err := os.WriteFile(pm.logPath("demo"), []byte(strings.Repeat("x", 2048)), 0644); err != nil {
		t.Fatal(err)
	}
	if got := projectRequest(a, "DELETE", "/v1/projects/demo/log", "", true).Code; got != 204 {
		t.Fatalf("清空日志：%d", got)
	}
	if info, err := os.Stat(pm.logPath("demo")); err != nil || info.Size() != 0 {
		t.Fatalf("日志没有清空：%v %v", info, err)
	}
	if got := projectRequest(a, "PUT", "/v1/projects/demo/log", "", true).Code; got != 405 {
		t.Fatalf("日志接口应拒绝 PUT：%d", got)
	}
}

func TestFreePortsSkipsPortsAssignedToProjects(t *testing.T) {
	a, pm := projectTestAPI(t)
	if got := projectRequest(a, "POST", "/v1/projects",
		`{"id":"taken","name":"Taken","runtime":"node","entry":"index.js","port":31234}`, true).Code; got != 201 {
		t.Fatalf("create: %d", got)
	}
	ports, err := pm.freePorts(context.Background(), 31230, 3)
	if err != nil {
		t.Fatal(err)
	}
	for _, port := range ports {
		if port == 31234 {
			t.Fatalf("已分配给项目的端口不应再被推荐：%v", ports)
		}
	}
	if len(ports) == 0 {
		t.Fatal("没有推荐端口")
	}
}
