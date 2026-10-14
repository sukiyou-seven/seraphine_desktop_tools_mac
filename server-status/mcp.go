package main

import (
	"context"
	_ "embed"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	pathpkg "path"
	"sort"
	"strconv"
	"strings"
	"time"
)

// mcpBridgeScript 是给只支持 stdio 的 AI 客户端用的桥脚本。它随服务端一起
// 分发，客户端从 /v1/mcp/script 取，不必再去仓库里找。
//
//go:embed mcp_bridge.py
var mcpBridgeScript string

// mcpProtocolVersion 是面板支持的 MCP 协议版本。客户端报的版本我们照抄回去：
// 握手时回一个客户端没提过的版本，有些客户端会直接断开。
const mcpProtocolVersion = "2025-06-18"

type mcpRequest struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params,omitempty"`
}

type mcpError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
	Data    string `json:"data,omitempty"`
}

type mcpResponse struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"`
	Result  any             `json:"result,omitempty"`
	Error   *mcpError       `json:"error,omitempty"`
}

type mcpTool struct {
	Name        string
	Description string
	InputSchema map[string]any
	call        func(ctx context.Context, a *api, args map[string]any) (any, error)
}

// mcpToolSummary 给「API 设置」页面用：只说有哪些工具，不带 schema。
type mcpToolSummary struct {
	Name        string `json:"name"`
	Description string `json:"description"`
}

func mcpToolSummaries() []mcpToolSummary {
	tools := mcpTools()
	result := make([]mcpToolSummary, 0, len(tools))
	for _, tool := range tools {
		result = append(result, mcpToolSummary{Name: tool.Name, Description: tool.Description})
	}
	return result
}

func schema(properties map[string]any, required ...string) map[string]any {
	result := map[string]any{"type": "object", "properties": properties}
	if properties == nil {
		result["properties"] = map[string]any{}
	}
	if len(required) > 0 {
		result["required"] = required
	}
	return result
}

func text(value string) map[string]any { return map[string]any{"type": "string", "description": value} }

func mcpTools() []mcpTool {
	return []mcpTool{
		{
			Name:        "get_server_status",
			Description: "读取服务器实时状态：主机信息、CPU 使用率与负载、内存与交换空间、磁盘占用、网卡速率。",
			InputSchema: schema(nil),
			call: func(ctx context.Context, a *api, _ map[string]any) (any, error) {
				if a.collect == nil {
					return nil, errors.New("状态采集不可用")
				}
				select {
				case a.limit <- struct{}{}:
					defer func() { <-a.limit }()
				case <-ctx.Done():
					return nil, ctx.Err()
				}
				return a.collect(300 * time.Millisecond)
			},
		},
		{
			Name:        "list_projects",
			Description: "列出所有托管项目，含运行状态（active_state/sub_state/result/main_pid/restarts）、端口占用与依赖清单结论。",
			InputSchema: schema(nil),
			call: func(ctx context.Context, a *api, _ map[string]any) (any, error) {
				return a.projects.list(ctx)
			},
		},
		{
			Name:        "get_project",
			Description: "读取单个项目的详情：启动自检清单（每条带原因与建议动作）、依赖结论、日志尾部与 systemd 日志。项目启动不了时先看这里。",
			InputSchema: schema(map[string]any{"id": text("项目标识")}, "id"),
			call: func(ctx context.Context, a *api, args map[string]any) (any, error) {
				id := mcpString(args, "id")
				if id == "" {
					return nil, errors.New("缺少 id")
				}
				return a.projects.detail(ctx, id)
			},
		},
		{
			Name:        "create_project",
			Description: "创建项目。字段与 POST /v1/projects 一致：id、name、runtime（python/node/go/openjdk/dotnet/ruby/bun/deno）、entry、port、directory、use_venv、python_server 等。工程目录不会自动创建内容，配 import_project 一起用。",
			InputSchema: schema(map[string]any{
				"id": text("项目标识：小写字母、数字、连字符"), "name": text("显示名"),
				"runtime": text("运行环境 id"), "entry": text("入口文件（相对工程目录）"),
				"port": text("监听端口，0 表示不需要"), "directory": text("工程目录，默认 /www/seraphim/projects/<id>"),
				"use_venv": text("Python 项目是否使用虚拟环境"), "env": text("环境变量对象，如 {\"MODE\":\"prod\"}"),
				"env_file":       text("是否加载工程目录下的 .env"),
				"use_global_env": text("是否加载面板「环境变量管理」里的公用变量"),
			}, "id", "runtime", "entry"),
			call: func(ctx context.Context, a *api, args map[string]any) (any, error) {
				item, err := decodeArgs[project](args)
				if err != nil {
					return nil, err
				}
				return a.projects.save(ctx, item, true)
			},
		},
		{
			Name:        "update_project",
			Description: "修改项目配置。只传要改的字段，其余保持原样。",
			InputSchema: schema(map[string]any{"id": text("项目标识")}, "id"),
			call: func(ctx context.Context, a *api, args map[string]any) (any, error) {
				id := mcpString(args, "id")
				if id == "" {
					return nil, errors.New("缺少 id")
				}
				existing, err := a.projects.read(id)
				if err != nil {
					return nil, err
				}
				merged, err := mergeArgs(existing, args)
				if err != nil {
					return nil, err
				}
				return a.projects.save(ctx, merged, false)
			},
		},
		{
			Name:        "delete_project",
			Description: "删除项目配置。默认保留工程目录里的文件；确认要连文件一起删时传 delete_files=true，这一步不可恢复。",
			InputSchema: schema(map[string]any{
				"id": text("项目标识"), "delete_files": text("true 表示连工程目录一起删除"),
			}, "id"),
			call: func(ctx context.Context, a *api, args map[string]any) (any, error) {
				id := mcpString(args, "id")
				if id == "" {
					return nil, errors.New("缺少 id")
				}
				if err := a.projects.remove(ctx, id); err != nil {
					return nil, err
				}
				removed := false
				if mcpBool(args, "delete_files") {
					directory := a.projects.projectDir(id)
					if err := os.RemoveAll(directory); err != nil {
						return nil, fmt.Errorf("项目配置已删除，但工程目录删除失败：%w", err)
					}
					_ = os.Remove(a.projects.logPath(id))
					removed = true
				}
				return map[string]any{"deleted": id, "files_removed": removed}, nil
			},
		},
		{
			Name:        "project_action",
			Description: "启停项目：action 取 start、stop 或 restart。失败时返回的是真实原因（退出码、连续失败次数），不是 systemd 那句没有信息量的原文。",
			InputSchema: schema(map[string]any{
				"id": text("项目标识"), "action": text("start / stop / restart"),
			}, "id", "action"),
			call: func(ctx context.Context, a *api, args map[string]any) (any, error) {
				id, action := mcpString(args, "id"), mcpString(args, "action")
				if id == "" || action == "" {
					return nil, errors.New("缺少 id 或 action")
				}
				if err := a.projects.action(ctx, id, action); err != nil {
					return nil, err
				}
				detail, err := a.projects.detail(ctx, id)
				if err != nil {
					return map[string]any{"action": action, "ok": true}, nil
				}
				return map[string]any{"action": action, "ok": true, "status": detail.Status, "checks": detail.Checks}, nil
			},
		},
		{
			Name:        "install_project_dependencies",
			Description: "按工程目录里的依赖清单安装依赖（Python 的 requirements.txt / pyproject.toml / setup.py，Node 按锁文件选 pnpm / yarn / npm，等等）。同步执行，可能要几分钟；要求项目处于停止状态。",
			InputSchema: schema(map[string]any{"id": text("项目标识")}, "id"),
			call: func(ctx context.Context, a *api, args map[string]any) (any, error) {
				id := mcpString(args, "id")
				if id == "" {
					return nil, errors.New("缺少 id")
				}
				installCtx, cancel := context.WithTimeout(ctx, 16*time.Minute)
				defer cancel()
				if err := a.projects.installDependencies(installCtx, id); err != nil {
					return nil, err
				}
				return a.projects.dependency(a.projects.mustRead(id)), nil
			},
		},
		{
			Name:        "get_project_log",
			Description: "读取项目日志尾部（最多 64 KiB）。",
			InputSchema: schema(map[string]any{"id": text("项目标识")}, "id"),
			call: func(ctx context.Context, a *api, args map[string]any) (any, error) {
				id := mcpString(args, "id")
				if id == "" {
					return nil, errors.New("缺少 id")
				}
				if _, err := a.projects.read(id); err != nil {
					return nil, err
				}
				return map[string]any{"log": tail(a.projects.logPath(id), 64<<10)}, nil
			},
		},
		{
			Name:        "import_project",
			Description: "一步把内容放上服务器并建好项目：既可以给 files（每个文件带 path 与 content，适合直接生成代码），也可以给 archive_base64（zip / tar.gz）。传 start=true 会在导入后立刻启动。",
			InputSchema: schema(map[string]any{
				"id": text("项目标识"), "runtime": text("运行环境 id"), "entry": text("入口文件"),
				"name": text("显示名"), "port": text("监听端口"), "start": text("导入后是否立刻启动"),
				"overwrite": text("工程目录已有文件时是否覆盖"),
				"files": map[string]any{"type": "array", "description": "文件列表",
					"items": map[string]any{"type": "object", "properties": map[string]any{
						"path": text("相对路径"), "content": text("文件内容"), "mode": text("八进制权限，如 0755"),
					}, "required": []string{"path", "content"}}},
				"archive_base64": text("压缩包内容的 base64（zip 或 tar.gz）"),
				"use_venv":       text("Python 项目是否使用虚拟环境"),
				"env":            text("环境变量对象"),
			}, "id", "runtime", "entry"),
			call: func(ctx context.Context, a *api, args map[string]any) (any, error) {
				spec, err := decodeArgs[projectImport](args)
				if err != nil {
					return nil, err
				}
				return a.projects.importProject(ctx, spec, nil)
			},
		},
		{
			Name:        "list_files",
			Description: "列出服务器上的目录内容（默认根目录），返回名称、类型、权限、属主、大小与修改时间。",
			InputSchema: schema(map[string]any{"path": text("绝对路径，默认 /")}),
			call: func(ctx context.Context, a *api, args map[string]any) (any, error) {
				path := mcpString(args, "path")
				if path == "" {
					path = "/"
				}
				return a.mcpListFiles(path)
			},
		},
		{
			Name:        "read_file",
			Description: "读取服务器上的文本文件（最多 1 MiB）。二进制文件不适合用这个工具。",
			InputSchema: schema(map[string]any{"path": text("绝对路径")}, "path"),
			call: func(ctx context.Context, a *api, args map[string]any) (any, error) {
				content, err := a.mcpReadFile(mcpString(args, "path"))
				if err != nil {
					return nil, err
				}
				return map[string]any{"path": mcpString(args, "path"), "content": content}, nil
			},
		},
		{
			Name:        "write_file",
			Description: "写入服务器上的文本文件，父目录不存在会自动创建。写入工程目录内的文件时会顺带把属主与权限交给共享运行账户，项目进程读得到。",
			InputSchema: schema(map[string]any{
				"path": text("绝对路径"), "content": text("文件内容"), "mode": text("八进制权限，如 0644；留空按 0644"),
			}, "path", "content"),
			call: func(ctx context.Context, a *api, args map[string]any) (any, error) {
				path := mcpString(args, "path")
				if path == "" {
					return nil, errors.New("缺少 path")
				}
				if err := a.mcpWriteFile(path, mcpText(args, "content"), mcpString(args, "mode")); err != nil {
					return nil, err
				}
				return map[string]any{"path": path, "written": true}, nil
			},
		},
		{
			Name:        "list_sites",
			Description: "列出网站：域名、类型（静态 / PHP 等）、运行环境版本、启用状态与站点目录。",
			InputSchema: schema(nil),
			call: func(ctx context.Context, a *api, _ map[string]any) (any, error) {
				return a.sites.list()
			},
		},
		{
			Name:        "get_variables",
			Description: "读取面板「环境变量管理」里的公用变量表，以及导出的共用文件路径。",
			InputSchema: schema(nil),
			call: func(ctx context.Context, a *api, _ map[string]any) (any, error) {
				if a.variables == nil {
					return nil, errors.New("变量表不可用")
				}
				return map[string]any{"variables": a.variables.list(),
					"file": a.variables.sharedFilePath(), "updated_at": a.variables.updatedAt()}, nil
			},
		},
		{
			Name:        "set_variables",
			Description: "整表替换公用变量（只传 name 与 value，未列出的会被删掉）。想让项目用上，还要在项目配置里打开 use_global_env，或让代码直接读共用文件。",
			InputSchema: schema(map[string]any{
				"variables": map[string]any{"type": "array", "items": map[string]any{
					"type": "object", "properties": map[string]any{
						"name": text("变量名"), "value": text("变量值"),
					}, "required": []string{"name", "value"}}},
			}, "variables"),
			call: func(ctx context.Context, a *api, args map[string]any) (any, error) {
				if a.variables == nil {
					return nil, errors.New("变量表不可用")
				}
				raw, err := json.Marshal(args["variables"])
				if err != nil {
					return nil, err
				}
				var variables []globalVariable
				if err := json.Unmarshal(raw, &variables); err != nil {
					return nil, errors.New("variables 须为 {name, value} 数组")
				}
				saved, err := a.variables.replace(variables)
				if err != nil {
					return nil, err
				}
				applied, err := a.projects.applyGlobalVariables(ctx)
				if err != nil {
					return map[string]any{"variables": saved, "applied": []string{}, "warning": err.Error()}, nil
				}
				return map[string]any{"variables": saved, "applied": applied, "file": a.variables.sharedFilePath()}, nil
			},
		},
		{
			Name:        "list_tasks",
			Description: "列出计划任务：频率、执行命令、启用状态与上次执行结果。",
			InputSchema: schema(nil),
			call: func(ctx context.Context, a *api, _ map[string]any) (any, error) {
				items, err := a.tasks.list()
				if err != nil {
					return nil, err
				}
				return map[string]any{"items": items}, nil
			},
		},
		{
			Name:        "run_task",
			Description: "立即触发一次计划任务（不等到下一个周期）。执行是异步的，结果要去任务日志里看。",
			InputSchema: schema(map[string]any{"id": text("任务标识")}, "id"),
			call: func(ctx context.Context, a *api, args map[string]any) (any, error) {
				id := mcpString(args, "id")
				if id == "" {
					return nil, errors.New("缺少 id")
				}
				if _, err := a.tasks.read(id); err != nil {
					return nil, err
				}
				actionCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
				defer cancel()
				if _, err := a.tasks.systemctl(actionCtx, "start", "--no-block", taskUnitName(id)+".service"); err != nil {
					return nil, err
				}
				return map[string]any{"triggered": id}, nil
			},
		},
		{
			Name:        "list_services",
			Description: "列出面板托管的服务（防火墙）当前状态。",
			InputSchema: schema(nil),
			call: func(ctx context.Context, a *api, _ map[string]any) (any, error) {
				services, err := a.services.list(ctx)
				if err != nil {
					return nil, err
				}
				return map[string]any{"services": services}, nil
			},
		},
		{
			Name:        "service_action",
			Description: "对面板托管的服务执行 start / stop / restart / enable / disable。",
			InputSchema: schema(map[string]any{
				"name": text("服务名，例如 ufw.service"), "action": text("start / stop / restart / enable / disable"),
			}, "name", "action"),
			call: func(ctx context.Context, a *api, args map[string]any) (any, error) {
				name, action := mcpString(args, "name"), mcpString(args, "action")
				if name == "" || action == "" {
					return nil, errors.New("缺少 name 或 action")
				}
				if err := a.applyServiceAction(ctx, name, action); err != nil {
					return nil, err
				}
				return map[string]any{"name": name, "action": action, "ok": true}, nil
			},
		},
	}
}

// mcpHandler 是 MCP 端点。无状态：每个请求自带全部上下文，服务端不记会话，
// 所以 HTTP 与 stdio 桥两条路走的是同一份代码。
func (a *api) mcpHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	if !a.authorized(r) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	if r.Method == http.MethodGet {
		// 有些客户端会先 GET 探一下。明确告诉它这个端点不接受 GET。
		w.Header().Set("Allow", "POST")
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	var request mcpRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 32<<20)).Decode(&request); err != nil {
		writeMCP(w, mcpResponse{JSONRPC: "2.0", ID: json.RawMessage("null"),
			Error: &mcpError{Code: -32700, Message: "请求不是合法的 JSON-RPC 消息"}})
		return
	}
	response, reply := a.handleMCP(r.Context(), request)
	if !reply {
		// 通知不需要回复。按规范回 202 更省事，客户端不会把它当成响应去解析。
		w.WriteHeader(http.StatusAccepted)
		return
	}
	writeMCP(w, response)
}

func writeMCP(w http.ResponseWriter, response mcpResponse) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	_ = json.NewEncoder(w).Encode(response)
}

// handleMCP 分发一个 JSON-RPC 消息。第二个返回值表示「要不要回」——通知不回。
func (a *api) handleMCP(ctx context.Context, request mcpRequest) (mcpResponse, bool) {
	reply := len(request.ID) > 0 && string(request.ID) != "null"
	response := mcpResponse{JSONRPC: "2.0", ID: request.ID}
	if !reply {
		response.ID = json.RawMessage("null")
	}
	fail := func(code int, message string) (mcpResponse, bool) {
		response.Error = &mcpError{Code: code, Message: message}
		return response, reply
	}
	switch request.Method {
	case "initialize":
		var params struct {
			ProtocolVersion string `json:"protocolVersion"`
		}
		_ = json.Unmarshal(request.Params, &params)
		version := params.ProtocolVersion
		if version == "" {
			version = mcpProtocolVersion
		}
		response.Result = map[string]any{
			"protocolVersion": version,
			"capabilities":    map[string]any{"tools": map[string]any{"listChanged": false}},
			"serverInfo":      map[string]any{"name": "seraphim", "version": "1"},
			"instructions": "这是 Seraphim 面板的服务器管理端点。先用 list_projects 看有哪些项目；" +
				"项目起不来时用 get_project 读启动自检，那里会写明卡在哪一步。" +
				"要新建服务时用 import_project 一次把文件放上去并建好项目，再配 project_action 启动。",
		}
		return response, reply
	case "ping":
		response.Result = map[string]any{}
		return response, reply
	case "tools/list":
		tools := mcpTools()
		list := make([]map[string]any, 0, len(tools))
		for _, tool := range tools {
			list = append(list, map[string]any{
				"name": tool.Name, "description": tool.Description, "inputSchema": tool.InputSchema,
			})
		}
		response.Result = map[string]any{"tools": list}
		return response, reply
	case "tools/call":
		var params struct {
			Name      string         `json:"name"`
			Arguments map[string]any `json:"arguments"`
		}
		if err := json.Unmarshal(request.Params, &params); err != nil {
			return fail(-32602, "tools/call 参数无效")
		}
		var found *mcpTool
		for _, tool := range mcpTools() {
			if tool.Name == params.Name {
				candidate := tool
				found = &candidate
				break
			}
		}
		if found == nil {
			return fail(-32602, fmt.Sprintf("没有名为 %s 的工具", params.Name))
		}
		if params.Arguments == nil {
			params.Arguments = map[string]any{}
		}
		value, err := found.call(ctx, a, params.Arguments)
		if err != nil {
			return mcpToolResult(response, fmt.Sprintf("执行失败：%s", err.Error()), true)
		}
		body, err := json.MarshalIndent(value, "", "  ")
		if err != nil {
			return mcpToolResult(response, fmt.Sprintf("%v", value), false)
		}
		return mcpToolResult(response, string(body), false)
	default:
		return fail(-32601, fmt.Sprintf("不支持的方法 %s", request.Method))
	}
}

// mcpToolResult 按 MCP 规范包一层 content。工具执行出错不算协议错误：结果里
// 带 isError，AI 才能看到原因并自己决定下一步。
func mcpToolResult(response mcpResponse, text string, failed bool) (mcpResponse, bool) {
	result := map[string]any{"content": []map[string]any{{"type": "text", "text": text}}}
	if failed {
		result["isError"] = true
	}
	response.Result = result
	return response, true
}

func mcpString(args map[string]any, key string) string {
	value, ok := args[key]
	if !ok || value == nil {
		return ""
	}
	switch typed := value.(type) {
	case string:
		return strings.TrimSpace(typed)
	case float64:
		if typed == float64(int64(typed)) {
			return strconv.FormatInt(int64(typed), 10)
		}
		return strconv.FormatFloat(typed, 'f', -1, 64)
	case bool:
		return strconv.FormatBool(typed)
	case json.Number:
		return typed.String()
	}
	return ""
}

func mcpBool(args map[string]any, key string) bool {
	switch typed := args[key].(type) {
	case bool:
		return typed
	case string:
		return typed == "true" || typed == "1"
	case float64:
		return typed != 0
	}
	return false
}

// mcpText 与 mcpString 只差一件事：不 trim。文件内容的首尾空白就是内容本身，
// 顺手 trim 掉会让写进去的代码少一个换行——这种错误在审查里几乎看不出来。
func mcpText(args map[string]any, key string) string {
	value, ok := args[key]
	if !ok || value == nil {
		return ""
	}
	if typed, ok := value.(string); ok {
		return typed
	}
	return mcpString(args, key)
}

// decodeArgs 把工具参数直接塞进目标结构：字段名与 HTTP 接口一致，AI 看一份
// 文档就够，两边也不会因为字段名不同而打架。
func decodeArgs[T any](args map[string]any) (T, error) {
	var result T
	body, err := json.Marshal(args)
	if err != nil {
		return result, err
	}
	decoder := json.NewDecoder(strings.NewReader(string(body)))
	// 数字在 JSON 里是浮点，端口这类整数字段要能接住 8080.0 这种形状。
	decoder.UseNumber()
	if err := decoder.Decode(&result); err != nil {
		return result, fmt.Errorf("参数无法解析：%w", err)
	}
	return result, nil
}

// mergeArgs 把补丁盖在已有配置上。先 marshal 再合并，是为了走一遍字段名，
// 免得 AI 用中文键名或大小写不一致的键名悄悄改不动东西。
func mergeArgs[T any](existing T, patch map[string]any) (T, error) {
	body, err := json.Marshal(existing)
	if err != nil {
		return existing, err
	}
	var fields map[string]any
	if err := json.Unmarshal(body, &fields); err != nil {
		return existing, err
	}
	for key, value := range patch {
		if key == "" || value == nil {
			continue
		}
		fields[key] = value
	}
	return decodeArgs[T](fields)
}

// mustRead 读一个已经确认存在的项目，读不到就返回零值——调用方只是拿它渲染
// 一句结论，不值得为此再抛一个错误。
func (pm *projectManager) mustRead(id string) project {
	pm.mu.Lock()
	item, err := pm.read(id)
	pm.mu.Unlock()
	if err != nil {
		return project{ID: id}
	}
	return item
}

// mcpListFiles 复用文件接口的路径校验与排序规则，但不需要 http.Request。
func (a *api) mcpListFiles(path string) (any, error) {
	if a.files == nil {
		return nil, errors.New("文件接口不可用")
	}
	clean, name, err := filePath(path)
	if err != nil {
		return nil, err
	}
	if err := a.files.checkSymlinks(name, true); err != nil {
		return nil, err
	}
	directory, err := a.files.root.Open(name)
	if err != nil {
		return nil, err
	}
	defer directory.Close()
	entries, err := directory.ReadDir(-1)
	if err != nil {
		return nil, err
	}
	listing := fileListing{Path: clean, Parent: pathpkg.Dir(clean), Entries: make([]fileEntry, 0, len(entries))}
	snapshot := accounts(false)
	for _, item := range entries {
		childPath := pathpkg.Join(clean, item.Name())
		_, childName, err := filePath(childPath)
		if err != nil {
			continue
		}
		info, err := a.files.root.Lstat(childName)
		if err != nil {
			continue
		}
		entry := fileEntry{
			Name: item.Name(), Path: childPath, Kind: fileKind(info),
			Permissions: fmt.Sprintf("%04o", info.Mode().Perm()),
			SizeBytes:   info.Size(), ModifiedAt: info.ModTime().UTC().Format(time.RFC3339),
		}
		if uid, gid, ok := entryOwnership(info); ok {
			entry.UID, entry.GID = uid, gid
			entry.Owner, entry.Group = snapshot.names(uid, gid)
		}
		listing.Entries = append(listing.Entries, entry)
	}
	sort.Slice(listing.Entries, func(i, j int) bool {
		left, right := listing.Entries[i], listing.Entries[j]
		if (left.Kind == "directory") != (right.Kind == "directory") {
			return left.Kind == "directory"
		}
		return strings.ToLower(left.Name) < strings.ToLower(right.Name)
	})
	return listing, nil
}

const maxMCPReadBytes = 1 << 20

func (a *api) mcpReadFile(path string) (string, error) {
	if a.files == nil {
		return "", errors.New("文件接口不可用")
	}
	_, name, err := filePath(path)
	if err != nil {
		return "", err
	}
	if err := a.files.checkSymlinks(name, true); err != nil {
		return "", err
	}
	info, err := a.files.root.Lstat(name)
	if err != nil {
		return "", err
	}
	if !info.Mode().IsRegular() {
		return "", errors.New("只能读取普通文件")
	}
	if info.Size() > maxMCPReadBytes {
		return "", fmt.Errorf("文件超过 %d KiB，请改用文件管理或分段读取", maxMCPReadBytes>>10)
	}
	file, err := a.files.root.Open(name)
	if err != nil {
		return "", err
	}
	defer file.Close()
	body, err := io.ReadAll(io.LimitReader(file, maxMCPReadBytes+1))
	if err != nil {
		return "", err
	}
	if len(body) > maxMCPReadBytes {
		return "", fmt.Errorf("文件超过 %d KiB，请改用文件管理或分段读取", maxMCPReadBytes>>10)
	}
	return string(body), nil
}

// mcpWriteFile 写文件。工程目录内的写入要顺带把属主交给共享运行账户：
// 面板是 root，落下来的文件默认归 root，项目进程读不到就是「配置明明改了却不生效」。
func (a *api) mcpWriteFile(path, content, mode string) error {
	if a.files == nil {
		return errors.New("文件接口不可用")
	}
	clean, name, err := filePath(path)
	if err != nil {
		return err
	}
	if clean == "/" {
		return errInvalidFilePath
	}
	permission := os.FileMode(0644)
	if mode != "" {
		parsed, err := parseImportMode(mode)
		if err != nil {
			return fmt.Errorf("权限 %q 无效", mode)
		}
		permission = parsed
	}
	a.files.mu.Lock()
	defer a.files.mu.Unlock()
	// 先建父目录再查软链接：新路径的中间层本来就不存在，反过来的话
	// 「写一个新目录下的文件」会被自己的检查挡住。
	if err := a.files.mkdirAll(pathpkg.Dir(name)); err != nil {
		return err
	}
	if err := a.files.checkSymlinks(name, false); err != nil {
		return err
	}
	managedProject := a.files.managedProjectsTree(clean)
	file, err := a.files.root.OpenFile(name, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, permission)
	if err != nil {
		return err
	}
	_, writeErr := file.WriteString(content)
	if writeErr == nil {
		if managedProject {
			permission = 0600
		}
		writeErr = file.Chmod(permission)
	}
	if writeErr == nil && managedProject {
		uid, gid, ownerErr := a.files.owner()
		if ownerErr == nil {
			ownerErr = file.Chown(uid, gid)
		}
		writeErr = ownerErr
	}
	if closeErr := file.Close(); writeErr == nil {
		writeErr = closeErr
	}
	return writeErr
}

// mkdirAll 在文件接口的根目录内逐级建目录。os.Root 只有单级 Mkdir，
// 直接传 "a/b/c" 会因为父目录不存在而失败。
func (fm *fileManager) mkdirAll(name string) error {
	if name == "" || name == "." {
		return nil
	}
	parts := strings.Split(name, "/")
	for index := range parts {
		current := strings.Join(parts[:index+1], "/")
		if current == "" {
			continue
		}
		info, err := fm.root.Lstat(current)
		if err == nil {
			if !info.IsDir() {
				return errInvalidFilePath
			}
			continue
		}
		if !errors.Is(err, os.ErrNotExist) {
			return err
		}
		if err := fm.root.Mkdir(current, 0755); err != nil {
			return err
		}
	}
	return nil
}
