package main

import (
	"archive/tar"
	"archive/zip"
	"bytes"
	"compress/gzip"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// tarGz 拼一个压缩包，用来验证「上传整包就能建项目」这条路。
func tarGz(t *testing.T, files map[string]string) []byte {
	t.Helper()
	var buffer bytes.Buffer
	writer := gzip.NewWriter(&buffer)
	tarWriter := tar.NewWriter(writer)
	for name, body := range files {
		if err := tarWriter.WriteHeader(&tar.Header{
			Name: name, Mode: 0644, Size: int64(len(body)), Typeflag: tar.TypeReg,
		}); err != nil {
			t.Fatal(err)
		}
		if _, err := tarWriter.Write([]byte(body)); err != nil {
			t.Fatal(err)
		}
	}
	if err := tarWriter.Close(); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	return buffer.Bytes()
}

func zipArchive(t *testing.T, files map[string]string) []byte {
	t.Helper()
	var buffer bytes.Buffer
	writer := zip.NewWriter(&buffer)
	for name, body := range files {
		entry, err := writer.Create(name)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := entry.Write([]byte(body)); err != nil {
			t.Fatal(err)
		}
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	return buffer.Bytes()
}

// withAPIKey 给测试用的 api 挂上一把独立存储的 API key。
//
// 生产里这两把钥匙分别在 config/token 和 config/api-key 里；测试只关心
// 「不是同一把、各有各的生命周期」，所以这里给一个干净的临时目录。
func withAPIKey(t *testing.T, a *api) *apiKeyStore {
	t.Helper()
	store := newAPIKeyStore(t.TempDir())
	a.apiKeys = store
	return store
}

func TestAPIHandlerPublishesEndpointsAndKey(t *testing.T) {
	a, _ := projectTestAPI(t)
	withAPIKey(t, a)
	request := httptest.NewRequest(http.MethodGet, "/v1/api", nil)
	request.Host = "192.168.0.103:27520"
	request.Header.Set("Authorization", "Bearer secret")
	recorder := httptest.NewRecorder()
	a.apiHandler(recorder, request)
	if recorder.Code != http.StatusOK {
		t.Fatalf("状态码 %d", recorder.Code)
	}
	var payload struct {
		Endpoint string `json:"endpoint"`
		Key      string `json:"key"`
		Header   string `json:"header"`
		Sections []struct {
			Name      string `json:"name"`
			Endpoints []struct {
				Method, Path, Summary string
			} `json:"endpoints"`
		} `json:"sections"`
		MCP struct {
			URL     string `json:"url"`
			Script  string `json:"script"`
			Headers map[string]string
			Tools   []mcpToolSummary `json:"tools"`
		} `json:"mcp"`
	}
	if err := json.Unmarshal(recorder.Body.Bytes(), &payload); err != nil {
		t.Fatal(err)
	}
	// 页面上要能直接复制的三样：地址、key、MCP 配置。
	if payload.Endpoint != "https://192.168.0.103:27520" {
		t.Fatalf("地址不对：%s", payload.Endpoint)
	}
	if !validAPIKey(payload.Key) {
		t.Fatalf("key 形状不对：%q", payload.Key)
	}
	// 这一页给的是「给脚本和 AI 用的另一把」，不能就是面板客户端连服务器那把。
	if payload.Key == "secret" {
		t.Fatal("API key 与面板凭据是同一把")
	}
	if payload.Header != "Authorization: Bearer "+payload.Key {
		t.Fatalf("请求头不对：%s", payload.Header)
	}
	// 面板凭据不该以任何形式出现在这份响应里。
	body := recorder.Body.String()
	if strings.Contains(body, "Bearer secret") || strings.Contains(body, `"token"`) {
		t.Fatal("响应里带出了面板凭据")
	}
	if payload.MCP.URL != "https://192.168.0.103:27520/v1/mcp" ||
		payload.MCP.Headers["Authorization"] != "Bearer "+payload.Key {
		t.Fatalf("MCP 配置不对：%+v", payload.MCP)
	}
	if len(payload.MCP.Tools) < 10 {
		t.Fatalf("工具清单太短：%d", len(payload.MCP.Tools))
	}
	// 接口列表必须包含这次新加的几项，否则用户照抄不到上传、重置与 MCP。
	paths := map[string]bool{}
	for _, section := range payload.Sections {
		for _, endpoint := range section.Endpoints {
			paths[endpoint.Method+" "+endpoint.Path] = true
		}
	}
	for _, want := range []string{"POST /v1/projects/import", "POST /v1/mcp", "GET /v1/mcp/script",
		"POST /v1/projects/{id}/action", "PUT /v1/variables", "POST /v1/api/key"} {
		if !paths[want] {
			t.Fatalf("接口列表缺 %s：%v", want, paths)
		}
	}
}

// API key 与面板凭据分开的第一层：文件独立、内容独立、重启后还是同一把。
func TestAPIKeyLivesInItsOwnFile(t *testing.T) {
	dir := t.TempDir()
	store := newAPIKeyStore(dir)
	key, err := store.current()
	if err != nil {
		t.Fatal(err)
	}
	if !validAPIKey(key) {
		t.Fatalf("key 形状不对：%q", key)
	}
	info, err := os.Stat(filepath.Join(dir, apiKeyFileName))
	if err != nil {
		t.Fatal(err)
	}
	// 同目录里还有面板凭据，权限得一样紧。
	if info.Mode().Perm() != 0600 {
		t.Fatalf("key 文件权限是 %v", info.Mode().Perm())
	}
	// 面板凭据叫 token，这把叫 api-key，不许互相顶掉。
	if apiKeyFileName == "token" {
		t.Fatal("API key 复用了面板凭据的文件名")
	}
	// 第二次取还是同一把；换一个 store 实例（相当于重启进程）也是同一把。
	again, err := store.current()
	if err != nil || again != key {
		t.Fatalf("重复取变了：%q / %q", key, again)
	}
	if restarted, err := newAPIKeyStore(dir).current(); err != nil || restarted != key {
		t.Fatalf("重启后不是同一把：%q / %q", key, restarted)
	}
}

func TestAPIKeyOpensTheAPI(t *testing.T) {
	a, _ := projectTestAPI(t)
	store := withAPIKey(t, a)
	key, err := store.current()
	if err != nil {
		t.Fatal(err)
	}
	// 脚本拿这把 key 调接口要能过，MCP 也一样。
	for _, path := range []string{"/v1/api", "/v1/mcp/script"} {
		request := httptest.NewRequest(http.MethodGet, path, nil)
		request.Header.Set("Authorization", "Bearer "+key)
		recorder := httptest.NewRecorder()
		if path == "/v1/api" {
			a.apiHandler(recorder, request)
		} else {
			a.mcpScriptHandler(recorder, request)
		}
		if recorder.Code != http.StatusOK {
			t.Fatalf("%s 没认这把 key：%d", path, recorder.Code)
		}
	}
	// 别的东西照旧进不来。
	request := httptest.NewRequest(http.MethodGet, "/v1/api", nil)
	request.Header.Set("Authorization", "Bearer "+key[:len(key)-1])
	recorder := httptest.NewRecorder()
	a.apiHandler(recorder, request)
	if recorder.Code != http.StatusUnauthorized {
		t.Fatalf("错一位的 key 没挡住：%d", recorder.Code)
	}
}

// 重置：换成新的一把，旧的立刻作废，而面板客户端用的是另一把凭据，不会掉线。
func TestAPIKeyResetReplacesTheOldOne(t *testing.T) {
	a, _ := projectTestAPI(t)
	store := withAPIKey(t, a)
	old, err := store.current()
	if err != nil {
		t.Fatal(err)
	}
	fresh := resetKey(t, a, http.MethodPost, "/v1/api/key", "secret")
	if fresh == old {
		t.Fatal("重置后还是同一把")
	}
	if !validAPIKey(fresh) {
		t.Fatalf("新 key 形状不对：%q", fresh)
	}
	// 盘上也得是新的一把，否则重启又变回去。
	onDisk, err := os.ReadFile(store.path)
	if err != nil {
		t.Fatal(err)
	}
	if strings.TrimSpace(string(onDisk)) != fresh {
		t.Fatalf("盘上还是旧的：%q", string(onDisk))
	}
	if status := apiKeyStatus(t, a, old); status != http.StatusUnauthorized {
		t.Fatalf("旧 key 还能用：%d", status)
	}
	if status := apiKeyStatus(t, a, fresh); status != http.StatusOK {
		t.Fatalf("新 key 用不了：%d", status)
	}
	// 面板凭据不受影响——这正是「分开」的意义。
	if status := apiKeyStatus(t, a, "secret"); status != http.StatusOK {
		t.Fatalf("重置把面板凭据也作废了：%d", status)
	}
	// 拿新 key 自己再重置一次也是允许的：权限相同，只是能各自作废。
	second := resetKey(t, a, http.MethodPost, "/v1/api/key", fresh)
	if second == fresh || !validAPIKey(second) {
		t.Fatalf("用 API key 重置没生效：%q", second)
	}
}

// key 只能由服务端生成：请求体里塞什么都不算数。
func TestAPIKeyCannotBeChosenByTheCaller(t *testing.T) {
	a, _ := projectTestAPI(t)
	store := withAPIKey(t, a)
	if _, err := store.current(); err != nil {
		t.Fatal(err)
	}
	for _, body := range []string{`{"key":"123456"}`, `{"token":"123456"}`, `123456`} {
		request := httptest.NewRequest(http.MethodPost, "/v1/api/key", strings.NewReader(body))
		request.Header.Set("Authorization", "Bearer secret")
		request.Header.Set("Content-Type", "application/json")
		recorder := httptest.NewRecorder()
		a.apiKeyHandler(recorder, request)
		if recorder.Code != http.StatusOK {
			t.Fatalf("重置失败：%d", recorder.Code)
		}
		var payload struct {
			Key string `json:"key"`
		}
		if err := json.Unmarshal(recorder.Body.Bytes(), &payload); err != nil {
			t.Fatal(err)
		}
		if payload.Key == "123456" || !validAPIKey(payload.Key) {
			t.Fatalf("请求体里的值被当成了 key：%q", payload.Key)
		}
	}
	onDisk, err := os.ReadFile(store.path)
	if err != nil {
		t.Fatal(err)
	}
	if strings.TrimSpace(string(onDisk)) == "123456" {
		t.Fatal("自填的值落到了盘上")
	}
}

func TestAPIKeyResetRequiresAuthorizationAndPost(t *testing.T) {
	a, _ := projectTestAPI(t)
	store := withAPIKey(t, a)
	old, err := store.current()
	if err != nil {
		t.Fatal(err)
	}
	anonymous := httptest.NewRequest(http.MethodPost, "/v1/api/key", nil)
	recorder := httptest.NewRecorder()
	a.apiKeyHandler(recorder, anonymous)
	if recorder.Code != http.StatusUnauthorized {
		t.Fatalf("没挡未授权：%d", recorder.Code)
	}
	// GET 顺手改状态是不行的，页面上也该是明确的动作。
	get := httptest.NewRequest(http.MethodGet, "/v1/api/key", nil)
	get.Header.Set("Authorization", "Bearer secret")
	recorder = httptest.NewRecorder()
	a.apiKeyHandler(recorder, get)
	if recorder.Code != http.StatusMethodNotAllowed || recorder.Header().Get("Allow") != "POST" {
		t.Fatalf("GET 没被挡：%d / %s", recorder.Code, recorder.Header().Get("Allow"))
	}
	// 两条拒绝都不该把 key 换掉。
	if now, err := store.current(); err != nil || now != old {
		t.Fatalf("被拒的请求改动了 key：%q", now)
	}
}

// 文件被改坏时报错，而不是悄悄换一把——后者会让正在跑的脚本全部失效，
// 还看不出原因。
func TestAPIKeyDamageIsReportedInsteadOfRotated(t *testing.T) {
	a, _ := projectTestAPI(t)
	store := withAPIKey(t, a)
	if _, err := store.current(); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(store.path, []byte("not-a-key\n"), 0600); err != nil {
		t.Fatal(err)
	}
	broken := newAPIKeyStore(filepath.Dir(store.path))
	a.apiKeys = broken
	request := httptest.NewRequest(http.MethodGet, "/v1/api", nil)
	request.Header.Set("Authorization", "Bearer secret")
	recorder := httptest.NewRecorder()
	a.apiHandler(recorder, request)
	if recorder.Code != http.StatusInternalServerError {
		t.Fatalf("坏文件没有报错：%d", recorder.Code)
	}
	body, err := os.ReadFile(broken.path)
	if err != nil {
		t.Fatal(err)
	}
	if strings.TrimSpace(string(body)) != "not-a-key" {
		t.Fatalf("坏文件被覆盖了：%q", string(body))
	}
	// 面板本身照常能用，不能因为这一把坏了就整体不可用。
	script := httptest.NewRequest(http.MethodGet, "/v1/mcp/script", nil)
	script.Header.Set("Authorization", "Bearer secret")
	recorder = httptest.NewRecorder()
	a.mcpScriptHandler(recorder, script)
	if recorder.Code != http.StatusOK {
		t.Fatalf("面板凭据被牵连：%d", recorder.Code)
	}
}

func TestAPIKeyStoreWithoutStorage(t *testing.T) {
	var store *apiKeyStore
	if store.matches("anything") {
		t.Fatal("空存储不该认任何 key")
	}
	if _, err := store.current(); err == nil {
		t.Fatal("空存储应当报错而不是崩")
	}
	if _, err := store.reset(); err == nil {
		t.Fatal("空存储重置应当报错而不是崩")
	}
}

// apiKeyStatus 用给定的凭据问一次接口，返回状态码。
func apiKeyStatus(t *testing.T, a *api, credential string) int {
	t.Helper()
	request := httptest.NewRequest(http.MethodGet, "/v1/api", nil)
	request.Header.Set("Authorization", "Bearer "+credential)
	recorder := httptest.NewRecorder()
	a.apiHandler(recorder, request)
	return recorder.Code
}

// resetKey 走一次重置接口，返回新的 key。
func resetKey(t *testing.T, a *api, method, path, credential string) string {
	t.Helper()
	request := httptest.NewRequest(method, path, nil)
	request.Header.Set("Authorization", "Bearer "+credential)
	recorder := httptest.NewRecorder()
	a.apiKeyHandler(recorder, request)
	if recorder.Code != http.StatusOK {
		t.Fatalf("重置失败：%d %s", recorder.Code, recorder.Body.String())
	}
	var payload struct {
		Key string `json:"key"`
	}
	if err := json.Unmarshal(recorder.Body.Bytes(), &payload); err != nil {
		t.Fatal(err)
	}
	return payload.Key
}

func TestAPIAccessRequiresAuthorization(t *testing.T) {
	a, _ := projectTestAPI(t)
	for _, path := range []string{"/v1/api", "/v1/mcp", "/v1/mcp/script"} {
		request := httptest.NewRequest(http.MethodGet, path, nil)
		recorder := httptest.NewRecorder()
		switch path {
		case "/v1/api":
			a.apiHandler(recorder, request)
		case "/v1/mcp/script":
			a.mcpScriptHandler(recorder, request)
		default:
			a.mcpHandler(recorder, request)
		}
		if recorder.Code != http.StatusUnauthorized {
			t.Fatalf("%s 没挡未授权访问：%d", path, recorder.Code)
		}
	}
}

func TestMCPScriptDownloadsTheBridge(t *testing.T) {
	a, _ := projectTestAPI(t)
	request := httptest.NewRequest(http.MethodGet, "/v1/mcp/script", nil)
	request.Header.Set("Authorization", "Bearer secret")
	recorder := httptest.NewRecorder()
	a.mcpScriptHandler(recorder, request)
	if recorder.Code != http.StatusOK {
		t.Fatalf("状态码 %d", recorder.Code)
	}
	body := recorder.Body.String()
	if !strings.Contains(body, "SERAPHIM_ENDPOINT") || !strings.Contains(body, "/v1/mcp") {
		t.Fatal("桥脚本内容不对")
	}
	// 客户端保存下来的文件名要能直接用。
	if !strings.Contains(recorder.Header().Get("Content-Disposition"), "seraphim-mcp.py") {
		t.Fatalf("下载文件名不对：%s", recorder.Header().Get("Content-Disposition"))
	}
}

func mcpCall(t *testing.T, a *api, method string, params any) mcpResponse {
	t.Helper()
	raw, err := json.Marshal(params)
	if err != nil {
		t.Fatal(err)
	}
	response, reply := a.handleMCP(context.Background(), mcpRequest{
		JSONRPC: "2.0", ID: json.RawMessage("1"), Method: method, Params: raw,
	})
	if !reply {
		t.Fatalf("%s 应该有响应", method)
	}
	return response
}

// mcpToolText 取出工具返回里的那段文本。
func mcpToolText(t *testing.T, response mcpResponse) string {
	t.Helper()
	if response.Error != nil {
		t.Fatalf("返回了协议错误：%+v", response.Error)
	}
	result, ok := response.Result.(map[string]any)
	if !ok {
		t.Fatalf("结果形状不对：%#v", response.Result)
	}
	content, ok := result["content"].([]map[string]any)
	if !ok || len(content) == 0 {
		t.Fatalf("结果里没有 content：%#v", result)
	}
	if result["isError"] == true {
		return "ERROR " + content[0]["text"].(string)
	}
	return content[0]["text"].(string)
}

func TestMCPHandshakeAndToolListing(t *testing.T) {
	a, _ := projectTestAPI(t)
	handshake := mcpCall(t, a, "initialize", map[string]any{"protocolVersion": "2025-06-18"})
	result, ok := handshake.Result.(map[string]any)
	if !ok || result["protocolVersion"] != "2025-06-18" {
		t.Fatalf("握手指令不对：%#v", handshake.Result)
	}
	// 客户端报的版本要照抄回去：回一个它没提过的版本，有的客户端会直接断开。
	older := mcpCall(t, a, "initialize", map[string]any{"protocolVersion": "2024-11-05"})
	if older.Result.(map[string]any)["protocolVersion"] != "2024-11-05" {
		t.Fatal("没有回显客户端报的协议版本")
	}

	listing := mcpCall(t, a, "tools/list", map[string]any{})
	tools, ok := listing.Result.(map[string]any)["tools"].([]map[string]any)
	if !ok || len(tools) < 10 {
		t.Fatalf("工具清单不对：%#v", listing.Result)
	}
	names := map[string]bool{}
	for _, tool := range tools {
		names[tool["name"].(string)] = true
		// 每个工具都要有 inputSchema，否则客户端渲染不出参数表单。
		if _, ok := tool["inputSchema"].(map[string]any); !ok {
			t.Fatalf("%v 缺少 inputSchema", tool["name"])
		}
	}
	for _, want := range []string{"list_projects", "import_project", "project_action",
		"install_project_dependencies", "write_file", "set_variables"} {
		if !names[want] {
			t.Fatalf("工具清单缺 %s", want)
		}
	}
}

func TestMCPUnknownMethodAndTool(t *testing.T) {
	a, _ := projectTestAPI(t)
	unknown := mcpCall(t, a, "tools/whatever", map[string]any{})
	if unknown.Error == nil || unknown.Error.Code != -32601 {
		t.Fatalf("未知方法没有按协议报错：%#v", unknown)
	}
	missing := mcpCall(t, a, "tools/call", map[string]any{"name": "no_such_tool"})
	if missing.Error == nil || missing.Error.Code != -32602 {
		t.Fatalf("未知工具没有报参数错误：%#v", missing)
	}
}

func TestMCPProjectToolsDriveTheProjectManager(t *testing.T) {
	a, pm := projectTestAPI(t)
	created := projectRequest(a, "POST", "/v1/projects",
		`{"id":"mcpdemo","name":"MCP Demo","runtime":"python","entry":"main.py","port":8080}`, true)
	if created.Code != http.StatusCreated {
		t.Fatalf("建项目失败：%d %s", created.Code, created.Body.String())
	}
	// 启动会检查入口文件，先把它放上去——这一步本来也是 AI 该做的。
	if err := os.WriteFile(filepath.Join(pm.projectDir("mcpdemo"), "main.py"), []byte("print(1)\n"), 0640); err != nil {
		t.Fatal(err)
	}

	text := mcpToolText(t, mcpCall(t, a, "tools/call", map[string]any{
		"name": "list_projects", "arguments": map[string]any{},
	}))
	if !strings.Contains(text, "mcpdemo") {
		t.Fatalf("列表里没有刚建的项目：%s", text)
	}

	// 只改一个字段，其余保持原样。
	updated := mcpToolText(t, mcpCall(t, a, "tools/call", map[string]any{
		"name": "update_project", "arguments": map[string]any{"id": "mcpdemo", "name": "改名了"},
	}))
	if !strings.Contains(updated, "改名了") {
		t.Fatalf("改名没生效：%s", updated)
	}
	item, err := pm.read("mcpdemo")
	if err != nil {
		t.Fatal(err)
	}
	if item.Name != "改名了" || item.Entry != "main.py" || item.Port != 8080 {
		t.Fatalf("update 把别的字段也动了：%+v", item)
	}

	// 启动：测试桩下 systemctl 一律成功，返回里要带回状态与自检。
	started := mcpToolText(t, mcpCall(t, a, "tools/call", map[string]any{
		"name": "project_action", "arguments": map[string]any{"id": "mcpdemo", "action": "start"},
	}))
	if !strings.Contains(started, "\"ok\": true") || !strings.Contains(started, "checks") {
		t.Fatalf("启动结果里没有状态与自检：%s", started)
	}

	// 删除：默认保留工程目录。
	directory := pm.projectDir("mcpdemo")
	if err := os.MkdirAll(directory, 0750); err != nil {
		t.Fatal(err)
	}
	deleted := mcpToolText(t, mcpCall(t, a, "tools/call", map[string]any{
		"name": "delete_project", "arguments": map[string]any{"id": "mcpdemo"},
	}))
	if !strings.Contains(deleted, "\"files_removed\": false") {
		t.Fatalf("默认不该删工程目录：%s", deleted)
	}
	if _, err := os.Stat(directory); err != nil {
		t.Fatal("工程目录被删掉了")
	}
}

func TestMCPVariablesRoundTrip(t *testing.T) {
	a, _ := projectTestAPI(t)
	text := mcpToolText(t, mcpCall(t, a, "tools/call", map[string]any{
		"name": "set_variables", "arguments": map[string]any{
			"variables": []map[string]any{{"name": "PROJECT_RUNTIME", "value": "prod"}},
		},
	}))
	if !strings.Contains(text, "PROJECT_RUNTIME") || !strings.Contains(text, "prod") {
		t.Fatalf("写入变量失败：%s", text)
	}
	readBack := mcpToolText(t, mcpCall(t, a, "tools/call", map[string]any{
		"name": "get_variables", "arguments": map[string]any{},
	}))
	if !strings.Contains(readBack, "PROJECT_RUNTIME") {
		t.Fatalf("读回变量失败：%s", readBack)
	}
	// 非法变量名要原样把原因带回来，AI 才知道怎么改。
	refused := mcpToolText(t, mcpCall(t, a, "tools/call", map[string]any{
		"name": "set_variables", "arguments": map[string]any{
			"variables": []map[string]any{{"name": "PORT", "value": "1"}},
		},
	}))
	if !strings.HasPrefix(refused, "ERROR") || !strings.Contains(refused, "PORT") {
		t.Fatalf("非法变量名的报错不对：%s", refused)
	}
}

func TestMCPMissingArgumentExplainsItself(t *testing.T) {
	a, _ := projectTestAPI(t)
	for _, tool := range []string{"get_project", "project_action", "write_file"} {
		text := mcpToolText(t, mcpCall(t, a, "tools/call", map[string]any{
			"name": tool, "arguments": map[string]any{},
		}))
		if !strings.HasPrefix(text, "ERROR") {
			t.Fatalf("%s 少了参数却当成成功：%s", tool, text)
		}
	}
}

func TestMCPFileToolsWriteAndReadBack(t *testing.T) {
	root := t.TempDir()
	opened, err := os.OpenRoot(root)
	if err != nil {
		t.Fatal(err)
	}
	defer opened.Close()
	a := &api{token: "secret", files: &fileManager{root: opened,
		projectOwner: func() (int, int, error) { return os.Getuid(), os.Getgid(), nil }}}

	written := mcpToolText(t, mcpCall(t, a, "tools/call", map[string]any{
		"name": "write_file", "arguments": map[string]any{
			"path": "/conf/app.conf", "content": "mode=prod\n",
		},
	}))
	if !strings.Contains(written, "\"written\": true") {
		t.Fatalf("写文件失败：%s", written)
	}
	if body, err := os.ReadFile(filepath.Join(root, "conf/app.conf")); err != nil || string(body) != "mode=prod\n" {
		t.Fatalf("文件内容不对：%q %v", body, err)
	}
	readBack := mcpToolText(t, mcpCall(t, a, "tools/call", map[string]any{
		"name": "read_file", "arguments": map[string]any{"path": "/conf/app.conf"},
	}))
	if !strings.Contains(readBack, "mode=prod") {
		t.Fatalf("读回失败：%s", readBack)
	}
	listed := mcpToolText(t, mcpCall(t, a, "tools/call", map[string]any{
		"name": "list_files", "arguments": map[string]any{"path": "/"},
	}))
	if !strings.Contains(listed, "conf") {
		t.Fatalf("列目录失败：%s", listed)
	}
	// 目录穿越必须挡住：MCP 是给 AI 用的，参数由模型生成，不能信。
	escaped := mcpToolText(t, mcpCall(t, a, "tools/call", map[string]any{
		"name": "write_file", "arguments": map[string]any{
			"path": "/../outside.txt", "content": "nope",
		},
	}))
	if !strings.HasPrefix(escaped, "ERROR") {
		t.Fatalf("目录穿越没被挡：%s", escaped)
	}
}

func TestMCPWriteFileInsideProjectHandsOwnershipToTheSharedAccount(t *testing.T) {
	root := t.TempDir()
	opened, err := os.OpenRoot(root)
	if err != nil {
		t.Fatal(err)
	}
	defer opened.Close()
	projectDir := filepath.Join(root, "www", "seraphim", "projects", "demo")
	if err := os.MkdirAll(projectDir, 0750); err != nil {
		t.Fatal(err)
	}
	// 工程标记文件在，才算「面板管的项目」。
	if err := os.WriteFile(filepath.Join(projectDir, ".sera-project.json"), []byte("{}"), 0644); err != nil {
		t.Fatal(err)
	}
	called := 0
	a := &api{token: "secret", files: &fileManager{root: opened,
		projectOwner: func() (int, int, error) { called++; return os.Getuid(), os.Getgid(), nil }}}
	mcpToolText(t, mcpCall(t, a, "tools/call", map[string]any{
		"name": "write_file", "arguments": map[string]any{
			"path": "/www/seraphim/projects/demo/index.py", "content": "print(1)\n",
		},
	}))
	if called == 0 {
		t.Fatal("工程目录内的写入没有交给共享运行账户")
	}
	info, err := os.Stat(filepath.Join(projectDir, "index.py"))
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0600 {
		t.Fatalf("工程目录内的文件权限不对：%04o", info.Mode().Perm())
	}
}

func TestImportHandlerAcceptsArchiveBody(t *testing.T) {
	a, pm := projectTestAPI(t)
	archive := tarGz(t, map[string]string{
		"demo-main/app.py":    "print('hi')\n",
		"demo-main/README.md": "# demo\n",
	})
	request := httptest.NewRequest(http.MethodPost,
		"/v1/projects/import?id=webtest&runtime=python&entry=app.py&port=8123",
		bytes.NewReader(archive))
	request.Header.Set("Authorization", "Bearer secret")
	recorder := httptest.NewRecorder()
	a.importHandler(recorder, request)
	if recorder.Code != http.StatusCreated {
		t.Fatalf("导入失败：%d %s", recorder.Code, recorder.Body.String())
	}
	var result projectImportResult
	if err := json.Unmarshal(recorder.Body.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	if result.Files != 2 || result.Project.ID != "webtest" || result.Project.Port != 8123 {
		t.Fatalf("导入结果不对：%+v", result)
	}
	// 从 GitHub 拉的包都多包一层目录，那一层要被剥掉，app.py 才在工程根上。
	if _, err := os.Stat(filepath.Join(pm.projectDir("webtest"), "app.py")); err != nil {
		t.Fatalf("单层目录没有被剥掉：%v", err)
	}
	if _, err := os.Stat(filepath.Join(pm.projectDir("webtest"), "demo-main")); err == nil {
		t.Fatal("多包的那一层还留在工程目录里")
	}
}

func TestImportAcceptsZipAndBareFiles(t *testing.T) {
	_, pm := projectTestAPI(t)
	result, err := pm.importProject(context.Background(), projectImport{
		ID: "zipdemo", Runtime: "python", Entry: "app.py", Port: 8124,
	}, zipArchive(t, map[string]string{"app.py": "print(1)\n"}))
	if err != nil {
		t.Fatal(err)
	}
	if result.Files != 1 {
		t.Fatalf("zip 导入的文件数不对：%d", result.Files)
	}

	// 没有压缩包、只给 files：AI 直接生成代码时走这条路。
	second, err := pm.importProject(context.Background(), projectImport{
		ID: "filesdemo", Runtime: "node", Entry: "index.js", Port: 8125,
		Files: []projectImportFile{
			{Path: "index.js", Content: "console.log(1)\n"},
			{Path: "start.sh", Content: "#!/bin/sh\nnode index.js\n"},
			{Path: "nested/lib/util.js", Content: "module.exports = 1\n"},
		},
	}, nil)
	if err != nil {
		t.Fatal(err)
	}
	if second.Files != 3 {
		t.Fatalf("散装文件数不对：%d", second.Files)
	}
	// 脚本自动带可执行位，否则「上传了启动脚本却跑不起来」很难解释。
	info, err := os.Stat(filepath.Join(pm.projectDir("filesdemo"), "start.sh"))
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm()&0111 == 0 {
		t.Fatalf("脚本没有可执行位：%04o", info.Mode().Perm())
	}
}

func TestImportRejectsPathTraversalAndSymlinks(t *testing.T) {
	_, pm := projectTestAPI(t)
	var buffer bytes.Buffer
	writer := gzip.NewWriter(&buffer)
	tarWriter := tar.NewWriter(writer)
	body := "nope"
	// 路径穿越 + 软链接：两个都不能落进工程目录。
	if err := tarWriter.WriteHeader(&tar.Header{Name: "../escape.txt", Mode: 0644,
		Size: int64(len(body)), Typeflag: tar.TypeReg}); err != nil {
		t.Fatal(err)
	}
	if _, err := tarWriter.Write([]byte(body)); err != nil {
		t.Fatal(err)
	}
	if err := tarWriter.WriteHeader(&tar.Header{Name: "link", Linkname: "/etc/passwd",
		Typeflag: tar.TypeSymlink}); err != nil {
		t.Fatal(err)
	}
	if err := tarWriter.WriteHeader(&tar.Header{Name: "ok.py", Mode: 0644,
		Size: int64(len(body)), Typeflag: tar.TypeReg}); err != nil {
		t.Fatal(err)
	}
	if _, err := tarWriter.Write([]byte(body)); err != nil {
		t.Fatal(err)
	}
	if err := tarWriter.Close(); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}

	result, err := pm.importProject(context.Background(), projectImport{
		ID: "safe", Runtime: "python", Entry: "ok.py", Port: 8126,
	}, buffer.Bytes())
	if err != nil {
		t.Fatal(err)
	}
	if result.Files != 1 {
		t.Fatalf("该跳过的没跳过：%+v", result)
	}
	if len(result.Skipped) != 2 {
		t.Fatalf("被跳过的条目没有记下来：%+v", result.Skipped)
	}
	if _, err := os.Stat(filepath.Join(pm.root, "escape.txt")); err == nil {
		t.Fatal("路径穿越写出了工程目录之外的文件")
	}
	if _, err := os.Lstat(filepath.Join(pm.projectDir("safe"), "link")); err == nil {
		t.Fatal("软链接落进了工程目录")
	}
}

func TestImportRefusesToOverwriteWithoutConsent(t *testing.T) {
	_, pm := projectTestAPI(t)
	spec := projectImport{ID: "again", Runtime: "python", Entry: "app.py", Port: 8127}
	if _, err := pm.importProject(context.Background(), spec, tarGz(t, map[string]string{"app.py": "a\n"})); err != nil {
		t.Fatal(err)
	}
	_, err := pm.importProject(context.Background(), spec, tarGz(t, map[string]string{"app.py": "b\n"}))
	if err == nil || !strings.Contains(err.Error(), "overwrite") {
		t.Fatalf("覆盖没有被拦住：%v", err)
	}
	spec.Overwrite = true
	if _, err := pm.importProject(context.Background(), spec, tarGz(t, map[string]string{"app.py": "c\n"})); err != nil {
		t.Fatal(err)
	}
	body, err := os.ReadFile(filepath.Join(pm.projectDir("again"), "app.py"))
	if err != nil || string(body) != "c\n" {
		t.Fatalf("覆盖没生效：%q %v", body, err)
	}
}

func TestImportValidatesBeforeExtracting(t *testing.T) {
	_, pm := projectTestAPI(t)
	// 参数不合法时不该在磁盘上留下任何东西。
	_, err := pm.importProject(context.Background(), projectImport{
		ID: "BadID", Runtime: "python", Entry: "app.py", Port: 8128,
	}, tarGz(t, map[string]string{"app.py": "a\n"}))
	if err == nil {
		t.Fatal("非法项目标识没有被拒绝")
	}
	entries, err := os.ReadDir(filepath.Join(pm.root, "projects"))
	if err == nil && len(entries) != 0 {
		t.Fatalf("参数不合法却建了目录：%v", entries)
	}
	// 空内容也要明说。
	if _, err := pm.importProject(context.Background(), projectImport{
		ID: "empty", Runtime: "python", Entry: "app.py", Port: 8129,
	}, nil); err == nil || !strings.Contains(err.Error(), "为空") {
		t.Fatalf("空内容没有报错：%v", err)
	}
}

func TestMCPImportToolBuildsAProjectFromFiles(t *testing.T) {
	a, pm := projectTestAPI(t)
	text := mcpToolText(t, mcpCall(t, a, "tools/call", map[string]any{
		"name": "import_project", "arguments": map[string]any{
			"id": "aidemo", "runtime": "python", "entry": "app.py", "port": 8130,
			"files": []map[string]any{{"path": "app.py", "content": "print('hi')\n"}},
		},
	}))
	if strings.HasPrefix(text, "ERROR") {
		t.Fatalf("导入失败：%s", text)
	}
	if _, err := os.Stat(filepath.Join(pm.projectDir("aidemo"), "app.py")); err != nil {
		t.Fatalf("文件没有落地：%v", err)
	}
	// port 传成字符串也应被接受：模型经常这么给。
	if !strings.Contains(text, "\"port\": 8130") {
		t.Fatalf("端口没有按数字解析：%s", text)
	}
}
