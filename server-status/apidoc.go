package main

import (
	"encoding/json"
	"io"
	"log"
	"net/http"
)

// 这一份是「API 设置」页面的数据来源：接口列表 + 一把给脚本和 AI 用的 key。
//
// 页面上这把 key 是独立的一把（config/api-key），不是面板客户端连服务器用的
// 那个凭据。分开是为了能单独作废：脚本泄露了就重置这一把，已经连上的面板
// 不受影响。
//
// key 只能由服务端生成，页面与接口都不接受用户填写的值；能做的只有「换一把」。

// endpointDoc 描述一条接口，串成给人和 AI 看的速查表。
type endpointDoc struct {
	Method  string `json:"method"`
	Path    string `json:"path"`
	Summary string `json:"summary"`
	Example string `json:"example,omitempty"`
}

type endpointSection struct {
	Name      string        `json:"name"`
	Endpoints []endpointDoc `json:"endpoints"`
}

// apiDocumentation 是接口速查表。它和实际路由必须一起改：这份表是「API 设置」
// 页面上让人照抄的东西，写错比不写更糟。
func apiDocumentation() []endpointSection {
	return []endpointSection{
		{Name: "接入", Endpoints: []endpointDoc{
			{Method: "GET", Path: "/v1/api", Summary: "本接口列表与当前的 API key"},
			{Method: "POST", Path: "/v1/api/key", Summary: "重置 API key：返回新的一把，旧的立刻失效",
				Example: `curl -k -X POST -H "Authorization: Bearer $API_KEY" \
  https://HOST:27520/v1/api/key`},
		}},
		{Name: "只读", Endpoints: []endpointDoc{
			{Method: "GET", Path: "/v1/status", Summary: "服务器实时状态（CPU、内存、磁盘、网络）"},
		}},
		{Name: "项目", Endpoints: []endpointDoc{
			{Method: "GET", Path: "/v1/projects", Summary: "项目列表（含运行态与依赖清单结论）"},
			{Method: "GET", Path: "/v1/projects/{id}/status", Summary: "项目详情：启动自检、依赖结论与日志"},
			{Method: "POST", Path: "/v1/projects", Summary: "创建项目",
				Example: `curl -k -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" \
  -d '{"id":"demo","name":"Demo","runtime":"python","entry":"app.py","port":8080,"use_venv":true}' \
  https://HOST:27520/v1/projects`},
			{Method: "PUT", Path: "/v1/projects/{id}", Summary: "修改项目配置（只传要改的字段）"},
			{Method: "DELETE", Path: "/v1/projects/{id}", Summary: "删除项目配置（工程目录会保留）"},
			{Method: "POST", Path: "/v1/projects/import", Summary: "上传压缩包并一步建好项目",
				Example: `# 把项目打包上传，落地即建好项目并启动
tar czf demo.tar.gz -C demo .
curl -k -H "Authorization: Bearer $API_KEY" --data-binary @demo.tar.gz \
  "https://HOST:27520/v1/projects/import?id=demo&runtime=python&entry=app.py&port=8080&start=true"`},
			{Method: "POST", Path: "/v1/projects/{id}/action", Summary: "启动 / 停止 / 重启",
				Example: `curl -k -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" \
  -d '{"action":"start"}' https://HOST:27520/v1/projects/demo/action`},
			{Method: "POST", Path: "/v1/projects/{id}/deps", Summary: "安装依赖（同步执行，可能要几分钟）"},
			{Method: "POST", Path: "/v1/projects/{id}/venv", Summary: "创建或删除虚拟环境（action: create / remove）"},
			{Method: "GET", Path: "/v1/projects/{id}/log", Summary: "读取项目日志（最后 64 KiB），DELETE 清空"},
			{Method: "GET", Path: "/v1/projects/ports", Summary: "推荐可用端口（?after=8000）"},
		}},
		{Name: "文件", Endpoints: []endpointDoc{
			{Method: "GET", Path: "/v1/files?path=/", Summary: "列目录"},
			{Method: "GET", Path: "/v1/files/content?path=/x", Summary: "下载文件"},
			{Method: "PUT", Path: "/v1/files/content?path=/x&overwrite=true", Summary: "上传文件（body 即内容）"},
		}},
		{Name: "网站与域名", Endpoints: []endpointDoc{
			{Method: "GET", Path: "/v1/sites", Summary: "网站列表"},
			{Method: "POST", Path: "/v1/sites", Summary: "新建网站"},
			{Method: "PUT", Path: "/v1/sites/{provider}/{id}", Summary: "修改网站"},
			{Method: "DELETE", Path: "/v1/sites/{provider}/{id}", Summary: "删除网站"},
		}},
		{Name: "运行环境与服务", Endpoints: []endpointDoc{
			{Method: "GET", Path: "/v1/environments", Summary: "八种运行环境的安装状态与可装版本"},
			{Method: "POST", Path: "/v1/environments/{runtime}/install", Summary: "安装运行环境"},
			{Method: "GET", Path: "/v1/services", Summary: "面板托管的服务状态"},
			{Method: "POST", Path: "/v1/services", Summary: "start / stop / restart / enable / disable"},
		}},
		{Name: "数据与安全", Endpoints: []endpointDoc{
			{Method: "GET", Path: "/v1/databases", Summary: "数据库列表"},
			{Method: "POST", Path: "/v1/databases", Summary: "新建数据库与账户"},
			{Method: "GET", Path: "/v1/variables", Summary: "面板公用环境变量表"},
			{Method: "PUT", Path: "/v1/variables", Summary: "整表替换公用变量",
				Example: `curl -k -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" \
  -d '{"variables":[{"name":"PROJECT_RUNTIME","value":"prod"}]}' \
  https://HOST:27520/v1/variables`},
			{Method: "GET", Path: "/v1/tasks", Summary: "计划任务列表，POST 新建，PUT/DELETE 改删"},
			{Method: "GET", Path: "/v1/firewall", Summary: "防火墙规则"},
		}},
		{Name: "给 AI 用", Endpoints: []endpointDoc{
			{Method: "POST", Path: "/v1/mcp", Summary: "MCP 端点（JSON-RPC 2.0）：AI 客户端可直接管理服务器"},
			{Method: "GET", Path: "/v1/mcp/script", Summary: "下载 stdio 桥脚本，供只支持 stdio 的 AI 客户端使用"},
		}},
	}
}

// apiDocument 拼出页面要的那份数据。请求头里的 host 决定展示的地址——面板
// 可能从内网地址、也可能从域名进来，写死一个反而误导。
func (a *api) apiDocument(r *http.Request) (map[string]any, error) {
	key, err := a.apiKeys.current()
	if err != nil {
		return nil, err
	}
	host := r.Host
	if host == "" {
		host = "127.0.0.1:27520"
	}
	base := "https://" + host
	return map[string]any{
		"version":  "1",
		"endpoint": base,
		"key":      key,
		"header":   "Authorization: Bearer " + key,
		"sections": apiDocumentation(),
		"mcp": map[string]any{
			"path":    "/v1/mcp",
			"url":     base + "/v1/mcp",
			"headers": map[string]string{"Authorization": "Bearer " + key},
			"script":  base + "/v1/mcp/script",
			"tools":   mcpToolSummaries(),
		},
	}, nil
}

// apiHandler 返回接入信息：接口列表、服务地址和给脚本 / AI 用的这把 key。
//
// 返回 key 的明文是有意的——用户在这个页面上要做的第一件事就是把 key 复制到
// 脚本或 AI 客户端里。请求已经过 Bearer 校验，能拿到这份响应的人本来就有
// 一把可用的钥匙。面板自己的凭据不在响应里，也不该出现。
func (a *api) apiHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	if !a.authorized(r) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", "GET")
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	document, err := a.apiDocument(r)
	if err != nil {
		log.Printf("api document failed: %v", err)
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	writeAPIDocument(w, document)
}

// apiKeyHandler 重置 API key（POST /v1/api/key）。
//
// 请求体一律不看：key 只能由服务端生成，谁都不许自己填一个进来——否则
// 「随手写个 123456」会直接变成生产上的凭据。旧的 key 在这一步之后立刻
// 失效，但面板客户端用的是另一把，不会因此掉线。
func (a *api) apiKeyHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	if !a.authorized(r) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if _, err := a.apiKeys.reset(); err != nil {
		log.Printf("api key reset failed: %v", err)
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	// 直接把新的完整接入信息发回去，客户端换一把 key 不用再请求一次。
	document, err := a.apiDocument(r)
	if err != nil {
		log.Printf("api document failed: %v", err)
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	writeAPIDocument(w, document)
}

func writeAPIDocument(w http.ResponseWriter, document map[string]any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	if err := json.NewEncoder(w).Encode(document); err != nil {
		log.Printf("api document response failed: %v", err)
	}
}

// mcpScriptHandler 直接把 stdio 桥脚本发出去，客户端不需要去仓库里找它。
func (a *api) mcpScriptHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	if !a.authorized(r) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", "GET")
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	w.Header().Set("Content-Type", "text/x-python; charset=utf-8")
	w.Header().Set("Content-Disposition", `attachment; filename="seraphim-mcp.py"`)
	_, _ = io.WriteString(w, mcpBridgeScript)
}
