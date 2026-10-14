package main

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func variableRequest(a *api, method, body string, authorized bool) *httptest.ResponseRecorder {
	r := httptest.NewRequest(method, "/v1/variables", strings.NewReader(body))
	if authorized {
		r.Header.Set("Authorization", "Bearer secret")
	}
	w := httptest.NewRecorder()
	a.variablesHandler(w, r)
	return w
}

// variableManagerForTest 桩掉共用文件的属组：测试机上没有 sera 组，也不该在单测
// 里 useradd / chown。
func variableManagerForTest(root string) *globalVariableManager {
	manager := newGlobalVariableManager(root)
	manager.own = func(string) error { return nil }
	return manager
}

func TestGlobalVariableValidation(t *testing.T) {
	cases := []struct {
		label string
		input []globalVariable
		want  string
	}{
		{"空名", []globalVariable{{Name: "   "}}, "不能为空"},
		{"数字开头", []globalVariable{{Name: "2FAST"}}, "不合法"},
		{"带横线", []globalVariable{{Name: "DEMO-MODE"}}, "不合法"},
		{"保留名会被面板按项目分配", []globalVariable{{Name: "PATH", Value: "/tmp"}}, "面板按项目分配"},
		{"端口同理", []globalVariable{{Name: "port", Value: "3000"}}, "面板按项目分配"},
		{"重复", []globalVariable{{Name: "DUPE"}, {Name: "DUPE"}}, "重复"},
		{"值不能带换行", []globalVariable{{Name: "TOKEN", Value: "a\nb"}}, "换行"},
	}
	for _, item := range cases {
		if _, err := normalizeGlobalVariables(item.input); err == nil || !strings.Contains(err.Error(), item.want) {
			t.Fatalf("%s: got %v, want 含 %q", item.label, err, item.want)
		}
	}
	// 空表是合法的：用户就是把变量全删了。
	if variables, err := normalizeGlobalVariables(nil); err != nil || variables != nil {
		t.Fatalf("empty table: %v %v", variables, err)
	}
	// 输出按名称排序，两端展示顺序才稳定。
	variables, err := normalizeGlobalVariables([]globalVariable{{Name: "ZZZ", Value: "1"}, {Name: "AAA", Value: "2"}})
	if err != nil {
		t.Fatal(err)
	}
	if variables[0].Name != "AAA" || variables[1].Name != "ZZZ" {
		t.Fatalf("not sorted: %v", variables)
	}
}

func TestGlobalVariablesPersistAndReload(t *testing.T) {
	root := t.TempDir()
	manager := variableManagerForTest(root)
	if _, err := manager.replace([]globalVariable{
		{Name: "PROJECT_RUNTIME", Value: "dev"},
		{Name: "API_BASE", Value: "https://example.test"},
	}); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(manager.path())
	if err != nil {
		t.Fatal(err)
	}
	// 变量里可能放 token，所以变量表本身只能给 root 读。
	if info.Mode().Perm() != 0600 {
		t.Fatalf("variables file mode = %v", info.Mode().Perm())
	}
	// 共用文件是另一条取用路径：面板只管写，谁读、读哪几个由使用方决定。
	shared, err := os.ReadFile(manager.sharedFilePath())
	if err != nil {
		t.Fatal(err)
	}
	text := string(shared)
	if !strings.Contains(text, "API_BASE=https://example.test\n") || !strings.Contains(text, "PROJECT_RUNTIME=dev\n") {
		t.Fatalf("共用文件内容不对：\n%s", text)
	}
	// 首行要告诉读取方怎么用，否则这个文件没人敢读。
	if !strings.Contains(text, ". "+manager.sharedFilePath()) {
		t.Fatalf("共用文件没写明用法：\n%s", text)
	}
	// 项目进程都以 sera 运行，给组读就够，别的本地用户读不到。
	sharedInfo, err := os.Stat(manager.sharedFilePath())
	if err != nil {
		t.Fatal(err)
	}
	if sharedInfo.Mode().Perm() != 0640 {
		t.Fatalf("shared file mode = %v", sharedInfo.Mode().Perm())
	}
	restarted := variableManagerForTest(root)
	list := restarted.list()
	if len(list) != 2 || list[0].Name != "API_BASE" || list[1].Value != "dev" {
		t.Fatalf("reload: %v", list)
	}
	pairs := restarted.pairs()
	if len(pairs) != 2 || pairs[0] != "API_BASE=https://example.test" {
		t.Fatalf("pairs: %v", pairs)
	}
	if restarted.updatedAt() == "" {
		t.Fatal("updated_at 应该记下来")
	}
	if _, err := restarted.replace(nil); err != nil {
		t.Fatal(err)
	}
	if len(variableManagerForTest(root).lookup()) != 0 {
		t.Fatal("清空后应该一个都不剩")
	}
	// 清空也要落到共用文件上：留着旧值，代码读到的就是已经不存在的变量。
	if body, err := os.ReadFile(manager.sharedFilePath()); err != nil || strings.Contains(string(body), "API_BASE") {
		t.Fatalf("清空后共用文件里还有旧值：%v %s", err, body)
	}
}

func TestSharedEnvFileQuotesAwkwardValues(t *testing.T) {
	manager := variableManagerForTest(t.TempDir())
	if _, err := manager.replace([]globalVariable{
		{Name: "PLAIN", Value: "dev"},
		{Name: "WITH_SPACE", Value: "a b"},
		{Name: "SHELLY", Value: "$HOME"},
	}); err != nil {
		t.Fatal(err)
	}
	body := string(manager.sharedFileBody())
	// 日常值原样写出最好读，需要保护的才加引号——这个文件同时要给 shell 和代码读。
	for _, want := range []string{"PLAIN=dev\n", "WITH_SPACE=\"a b\"\n", "SHELLY=\"\\$HOME\"\n"} {
		if !strings.Contains(body, want) {
			t.Fatalf("缺 %q：\n%s", want, body)
		}
	}
	if _, err := manager.replace([]globalVariable{{Name: "EMPTY", Value: ""}}); err != nil {
		t.Fatal(err)
	}
	// 空值要写出来，否则「设成空」和「没设过」在文件里分不出来。
	if body := string(manager.sharedFileBody()); !strings.Contains(body, "EMPTY=\"\"\n") {
		t.Fatalf("空值没写出来：\n%s", body)
	}
}

func TestProjectUnitMergesGlobalVariables(t *testing.T) {
	_, pm := projectTestAPI(t)
	if _, err := pm.variables.replace([]globalVariable{
		{Name: "DEMO_MODE", Value: "dev"},
		{Name: "SHARED", Value: "global"},
	}); err != nil {
		t.Fatal(err)
	}
	// 默认不加载：面板不替项目决定，没勾上就一个字节都不写。
	plain, err := pm.normalize(project{ID: "demo", Name: "Demo", Runtime: "node", Entry: "index.js"})
	if err != nil {
		t.Fatal(err)
	}
	if plain.inheritsGlobalEnv() || plain.UseGlobalEnv == nil || *plain.UseGlobalEnv {
		t.Fatal("没勾上时不该加载面板变量，并应被 normalize 补成显式的 false")
	}
	if unit := string(pm.unit(plain)); strings.Contains(unit, "DEMO_MODE") {
		t.Fatalf("没勾上却出现面板变量：\n%s", unit)
	}

	item, err := pm.normalize(project{ID: "demo", Name: "Demo", Runtime: "node", Entry: "index.js",
		UseGlobalEnv: boolPointer(true), Env: map[string]string{"SHARED": "local"}})
	if err != nil {
		t.Fatal(err)
	}
	unit := string(pm.unit(item))
	if !strings.Contains(unit, `Environment="DEMO_MODE=dev"`) {
		t.Fatalf("面板变量没写进单元：\n%s", unit)
	}
	// 项目自己的同名变量优先：越具体越优先，否则没法单个项目覆盖。
	if !strings.Contains(unit, `Environment="SHARED=local"`) || strings.Contains(unit, `Environment="SHARED=global"`) {
		t.Fatalf("项目变量没有覆盖面板变量：\n%s", unit)
	}
	off, err := pm.normalize(project{ID: "demo", Name: "Demo", Runtime: "node", Entry: "index.js",
		UseGlobalEnv: boolPointer(false)})
	if err != nil {
		t.Fatal(err)
	}
	if closed := string(pm.unit(off)); strings.Contains(closed, "DEMO_MODE") {
		t.Fatalf("取消加载后不该再出现面板变量：\n%s", closed)
	}
}

func TestApplyGlobalVariablesRewritesUnits(t *testing.T) {
	a, pm := projectTestAPI(t)
	create := func(body string) {
		t.Helper()
		if got := projectRequest(a, "POST", "/v1/projects", body, true).Code; got != 201 {
			t.Fatalf("create %s: %d", body, got)
		}
	}
	create(`{"id":"demo","name":"Demo","runtime":"python","entry":"main.py","port":3000,"use_global_env":true}`)
	create(`{"id":"plain","name":"Plain","runtime":"python","entry":"main.py","port":3001,"use_global_env":false}`)

	applied, err := pm.applyGlobalVariables(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(applied) != 0 {
		t.Fatalf("没有变量时不该动任何单元：%v", applied)
	}
	if _, err := pm.variables.replace([]globalVariable{{Name: "DEMO_MODE", Value: "dev"}}); err != nil {
		t.Fatal(err)
	}
	applied, err = pm.applyGlobalVariables(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(applied) != 1 || applied[0] != "Demo" {
		t.Fatalf("只应同步勾了加载的项目：%v", applied)
	}
	demo, err := os.ReadFile(pm.unitPath("demo"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(demo), `Environment="DEMO_MODE=dev"`) {
		t.Fatalf("demo 单元里没有面板变量：\n%s", demo)
	}
	plain, err := os.ReadFile(pm.unitPath("plain"))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(plain), "DEMO_MODE") {
		t.Fatalf("没勾加载的项目不该被改写：\n%s", plain)
	}
	// 内容没变就不该反复重写（否则每次保存都会重启所有项目）。
	applied, err = pm.applyGlobalVariables(context.Background())
	if err != nil || len(applied) != 0 {
		t.Fatalf("重复同步应当是空操作：%v %v", applied, err)
	}
}

func TestApplyGlobalVariablesRestartsRunningProjects(t *testing.T) {
	a, pm := projectTestAPI(t)
	if got := projectRequest(a, "POST", "/v1/projects",
		`{"id":"demo","name":"Demo","runtime":"python","entry":"main.py","port":3000,"use_global_env":true}`, true).Code; got != 201 {
		t.Fatalf("create: %d", got)
	}
	var calls []string
	pm.systemctl = func(_ context.Context, args ...string) ([]byte, error) {
		calls = append(calls, strings.Join(args, " "))
		if args[0] == "show" {
			return []byte("ActiveState=active\nSubState=running\nUnitFileState=enabled\nResult=success\n" +
				"MainPID=42\nExecMainStatus=0\nNRestarts=0\nMemoryCurrent=1024\n" +
				"ActiveEnterTimestampMonotonic=1\n"), nil
		}
		return nil, nil
	}
	if _, err := pm.variables.replace([]globalVariable{{Name: "DEMO_MODE", Value: "prod"}}); err != nil {
		t.Fatal(err)
	}
	applied, err := pm.applyGlobalVariables(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(applied) != 1 {
		t.Fatalf("applied: %v", applied)
	}
	joined := strings.Join(calls, "\n")
	if !strings.Contains(joined, "daemon-reload") {
		t.Fatalf("改完单元必须 daemon-reload：\n%s", joined)
	}
	// 运行中的项目不重启就还是旧变量，用户会以为没生效。
	if !strings.Contains(joined, "restart sera-project-demo.service") {
		t.Fatalf("运行中的项目应当重启：\n%s", joined)
	}
}

func TestVariablesAPIAuthenticationAndErrors(t *testing.T) {
	a, pm := projectTestAPI(t)
	if got := variableRequest(a, http.MethodGet, "", false).Code; got != http.StatusUnauthorized {
		t.Fatalf("unauthenticated: %d", got)
	}
	empty := variableRequest(a, http.MethodGet, "", true)
	if empty.Code != http.StatusOK || !strings.Contains(empty.Body.String(), `"variables":[]`) {
		t.Fatalf("GET: %d %s", empty.Code, empty.Body.String())
	}
	if got := variableRequest(a, http.MethodDelete, "", true).Code; got != http.StatusMethodNotAllowed {
		t.Fatalf("DELETE: %d", got)
	}
	bad := variableRequest(a, http.MethodPut, `{"variables":[{"name":"PORT","value":"1"}]}`, true)
	if bad.Code != http.StatusConflict || !strings.Contains(bad.Body.String(), "面板按项目分配") {
		t.Fatalf("PUT 保留名: %d %s", bad.Code, bad.Body.String())
	}
	// 校验没过就不该落盘，否则用户下次打开面板会看到一份自己没保存过的变量表。
	if _, err := os.Stat(pm.variables.path()); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("被拒绝的保存不该留下文件：%v", err)
	}
	ok := variableRequest(a, http.MethodPut, `{"variables":[{"name":"PROJECT_RUNTIME","value":"dev"}]}`, true)
	if ok.Code != http.StatusOK {
		t.Fatalf("PUT: %d %s", ok.Code, ok.Body.String())
	}
	var payload struct {
		Variables []globalVariable `json:"variables"`
		Applied   []string         `json:"applied"`
		UpdatedAt string           `json:"updated_at"`
	}
	if err := json.Unmarshal(ok.Body.Bytes(), &payload); err != nil {
		t.Fatal(err)
	}
	if len(payload.Variables) != 1 || payload.Variables[0].Name != "PROJECT_RUNTIME" || payload.UpdatedAt == "" {
		t.Fatalf("PUT payload: %v", payload)
	}
	// 没有项目时 applied 必须是空数组而不是 null，客户端才不用处理两种形状。
	if payload.Applied == nil {
		t.Fatal("applied 应当是空数组")
	}
}

func TestScheduledTaskInheritsGlobalVariables(t *testing.T) {
	root := t.TempDir()
	if _, err := variableManagerForTest(root).replace([]globalVariable{
		{Name: "PROJECT_RUNTIME", Value: "dev"},
	}); err != nil {
		t.Fatal(err)
	}
	work := t.TempDir()
	script := filepath.Join(work, "run.sh")
	if err := os.WriteFile(script, []byte("#!/bin/sh\nprintf '%s' \"$PROJECT_RUNTIME\" > out.txt\n"), 0755); err != nil {
		t.Fatal(err)
	}
	manager := newTaskManager(root)
	if err := os.MkdirAll(manager.taskDir(), 0700); err != nil {
		t.Fatal(err)
	}
	task := scheduledTask{ID: "probe", Name: "probe", Frequency: "daily", Time: "00:00",
		Executable: script, Directory: work, Enabled: true}
	body, _ := json.Marshal(task)
	if err := os.WriteFile(manager.taskPath(task.ID), body, 0600); err != nil {
		t.Fatal(err)
	}
	if err := taskRunCommand([]string{"-root", root, "-id", task.ID}); err != nil {
		t.Fatal(err)
	}
	out, err := os.ReadFile(filepath.Join(work, "out.txt"))
	if err != nil {
		t.Fatal(err)
	}
	// 脚本和常驻服务看到的必须是同一个值，否则「全局」就名不副实了。
	if string(out) != "dev" {
		t.Fatalf("计划任务没拿到全局变量：%q", out)
	}
}
