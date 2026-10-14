package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"os/user"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// globalVariable 是「环境变量管理」里的一条，比如 PROJECT_RUNTIME=dev。
//
// 面板只负责保管这一份值，**谁来读、读哪几个由使用方自己决定**，面板不替项目
// 做决定。目前有两条取用路径：
//
//   - 项目在配置里勾上「加载面板环境变量」，值由 systemd 写进进程环境；
//   - 变量表同时导出成 server/env 这个共用文件，脚本 . 一下、代码直接读都行，
//     项目一个字都不用改。
//
// 计划任务执行命令时也会带上同一份值。以后新增消费方（网站、配置模板）复用
// 同一份数据即可，用户改一处，引用的地方下次生效就是新值。
type globalVariable struct {
	Name  string `json:"name"`
	Value string `json:"value"`
}

type globalVariableFile struct {
	Variables []globalVariable `json:"variables"`
	Updated   string           `json:"updated_at,omitempty"`
}

// maxGlobalVariables 是一份给多个项目共用的值表，比单个项目的上限宽松些。
const maxGlobalVariables = 128

// sharedFileName 是变量表导出的共用文件。放在 server/ 下，和变量表本身同级。
const sharedFileName = "env"

type globalVariableManager struct {
	root  string
	mu    sync.RWMutex
	cache []globalVariable
	// updated 记录最后一次写入时间，只有展示价值。
	updated string
	// own 把导出文件交给共享账户所属的组（项目进程、php-fpm 都以 sera 运行）。
	// 测试里会桩掉：本机没有 sera 组，也不该在单测里 useradd / chown。
	own func(string) error
}

func newGlobalVariableManager(root string) *globalVariableManager {
	manager := &globalVariableManager{root: root, own: ownForSharedGroup}
	manager.load()
	return manager
}

// ownForSharedGroup 让 sera 组能读这份文件，其他本地用户读不到——值里可能有 token。
func ownForSharedGroup(path string) error {
	gid, err := sharedGroupID()
	if err != nil {
		return err
	}
	return os.Chown(path, 0, gid)
}

// sharedGroupID 拿到 sera 组的 gid；组还不存在就顺手建一个（刚装完面板、还没
// 建过项目或网站时会走到这一步）。
func sharedGroupID() (int, error) {
	if group, err := user.LookupGroup(sharedAccount); err == nil {
		if gid, err := strconv.Atoi(group.Gid); err == nil {
			return gid, nil
		}
	}
	_, gid, err := ensureSharedAccount()
	if err != nil {
		return 0, err
	}
	if gid <= 0 {
		return 0, fmt.Errorf("拿不到 %s 组的 gid", sharedAccount)
	}
	return gid, nil
}

// path 放在 server/ 下，和计划任务元数据同级：都是「服务端自己管的东西」，
// 由面板以 root 身份读写。
func (vm *globalVariableManager) path() string {
	return filepath.Join(vm.root, "server", "variables.json")
}

// sharedFilePath 是导出给使用方读的那份文件。
func (vm *globalVariableManager) sharedFilePath() string {
	return filepath.Join(vm.root, "server", sharedFileName)
}

func (vm *globalVariableManager) load() {
	vm.mu.Lock()
	defer vm.mu.Unlock()
	data, err := os.ReadFile(vm.path())
	if err != nil {
		vm.cache, vm.updated = nil, ""
		return
	}
	var payload globalVariableFile
	if err := json.Unmarshal(data, &payload); err != nil {
		// 文件写坏了就当没有：面板不该因为一份变量表起不来。
		vm.cache, vm.updated = nil, ""
		return
	}
	variables, err := normalizeGlobalVariables(payload.Variables)
	if err != nil {
		vm.cache, vm.updated = nil, ""
		return
	}
	vm.cache, vm.updated = variables, payload.Updated
}

// list 返回一份拷贝，调用方随便改都影响不到内部状态。
func (vm *globalVariableManager) list() []globalVariable {
	vm.mu.RLock()
	defer vm.mu.RUnlock()
	result := make([]globalVariable, len(vm.cache))
	copy(result, vm.cache)
	return result
}

func (vm *globalVariableManager) updatedAt() string {
	vm.mu.RLock()
	defer vm.mu.RUnlock()
	return vm.updated
}

// lookup 返回变量名到值的映射，供单元文件与子进程环境使用。
func (vm *globalVariableManager) lookup() map[string]string {
	vm.mu.RLock()
	defer vm.mu.RUnlock()
	if len(vm.cache) == 0 {
		return nil
	}
	result := make(map[string]string, len(vm.cache))
	for _, item := range vm.cache {
		result[item.Name] = item.Value
	}
	return result
}

// pairs 返回 NAME=VALUE 列表，用来拼子进程的 cmd.Env。
func (vm *globalVariableManager) pairs() []string {
	vm.mu.RLock()
	defer vm.mu.RUnlock()
	result := make([]string, 0, len(vm.cache))
	for _, item := range vm.cache {
		result = append(result, item.Name+"="+item.Value)
	}
	return result
}

// replace 校验并整表替换，随后把变量导出成共用文件。
// 返回规范化后的列表（按名称排序，输出才稳定）。
func (vm *globalVariableManager) replace(input []globalVariable) ([]globalVariable, error) {
	variables, err := normalizeGlobalVariables(input)
	if err != nil {
		return nil, err
	}
	payload := globalVariableFile{Variables: variables, Updated: time.Now().UTC().Format(time.RFC3339)}
	body, err := json.MarshalIndent(payload, "", "  ")
	if err != nil {
		return nil, err
	}
	if err := atomicSiteWrite(vm.path(), append(body, '\n'), 0600); err != nil {
		return nil, err
	}
	vm.mu.Lock()
	vm.cache, vm.updated = payload.Variables, payload.Updated
	vm.mu.Unlock()
	// 共用文件是另一条取用路径，不同步的话「代码自己读文件」会读到上一次的值。
	if err := vm.syncSharedFile(); err != nil {
		return nil, fmt.Errorf("变量已保存，但共用文件 %s 写入失败：%w", vm.sharedFilePath(), err)
	}
	return variables, nil
}

// syncSharedFile 把当前变量写成 shell / dotenv 都能读的共用文件。
//
// 权限给 sera 组读、不给其他人：值里可能有 token，而项目进程、php-fpm 都以
// sera 运行，够用了。返回值里的错误值得让调用方知道——文件读不到，用户会以为
// 变量根本没生效。
func (vm *globalVariableManager) syncSharedFile() error {
	path := vm.sharedFilePath()
	if err := atomicSiteWrite(path, vm.sharedFileBody(), 0640); err != nil {
		return err
	}
	// 面板单元是 UMask=0077，写文件时容易落成 0600，这里再显式确认一次。
	if err := os.Chmod(path, 0640); err != nil {
		return err
	}
	if vm.own == nil {
		return nil
	}
	return vm.own(path)
}

// sharedFileBody 生成文件内容。用 .env 风格：shell 里 . 一下就能用，任何语言
// 逐行 split 也能读，# 开头当注释。
func (vm *globalVariableManager) sharedFileBody() []byte {
	vm.mu.RLock()
	variables := make([]globalVariable, len(vm.cache))
	copy(variables, vm.cache)
	updated := vm.updated
	vm.mu.RUnlock()

	var body strings.Builder
	body.WriteString("# 由 Seraphim 面板「环境变量管理」生成，请勿手工编辑，下次保存会覆盖。\n")
	body.WriteString("# 用法（shell）：. " + vm.sharedFilePath() + "\n")
	body.WriteString("# 用法（代码）：直接读本文件，每行 KEY=VALUE，# 开头是注释。\n")
	if updated != "" {
		body.WriteString("# 最后更新：" + updated + "\n")
	}
	if len(variables) == 0 {
		body.WriteString("# 当前没有定义任何变量。\n")
		return []byte(body.String())
	}
	body.WriteString("\n")
	for _, item := range variables {
		body.WriteString(item.Name + "=" + envFileValue(item.Value) + "\n")
	}
	return []byte(body.String())
}

// envFileValue 只在必要时加引号：dev、URL、token 这类日常值原样写出最好读。
func envFileValue(value string) string {
	if value != "" && !strings.ContainsAny(value, " \t\"'`$\\#&;|<>(){}*?[]!~") {
		return value
	}
	replacer := strings.NewReplacer(`\`, `\\`, `"`, `\"`, "`", "\\`", "$", `\$`)
	return `"` + replacer.Replace(value) + `"`
}

// normalizeGlobalVariables 复用项目管理里那套名称与取值规则：两边最终都会写进
// systemd 的 Environment=，规则不一致会出现「这边能存、那边报错」。
func normalizeGlobalVariables(input []globalVariable) ([]globalVariable, error) {
	if len(input) == 0 {
		return nil, nil
	}
	if len(input) > maxGlobalVariables {
		return nil, fmt.Errorf("全局变量最多 %d 个", maxGlobalVariables)
	}
	seen := make(map[string]bool, len(input))
	result := make([]globalVariable, 0, len(input))
	for _, item := range input {
		name := strings.TrimSpace(item.Name)
		if name == "" {
			return nil, errors.New("变量名不能为空")
		}
		if !environmentNamePattern.MatchString(name) {
			return nil, fmt.Errorf("变量名 %s 不合法：只能用字母、数字和下划线，且不能以数字开头", name)
		}
		if seen[name] {
			return nil, fmt.Errorf("变量 %s 重复了", name)
		}
		if reservedEnvironmentNames[strings.ToUpper(name)] {
			return nil, fmt.Errorf("变量 %s 由面板按项目分配，不能在这里定义（端口、虚拟环境这类请留在项目配置里）", name)
		}
		value := item.Value
		if len(value) > maxEnvironmentValue || strings.ContainsAny(value, "\r\n\x00") {
			return nil, fmt.Errorf("变量 %s 的值不能超过 %d 字节，也不能包含换行", name, maxEnvironmentValue)
		}
		seen[name] = true
		result = append(result, globalVariable{Name: name, Value: value})
	}
	sort.Slice(result, func(i, j int) bool { return result[i].Name < result[j].Name })
	return result, nil
}

func (a *api) variablesHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	if !a.authorized(r) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	if a.variables == nil {
		http.Error(w, "variables unavailable", http.StatusServiceUnavailable)
		return
	}
	switch r.Method {
	case http.MethodGet:
		variables := a.variables.list()
		if variables == nil {
			variables = []globalVariable{}
		}
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		_ = json.NewEncoder(w).Encode(struct {
			Variables []globalVariable `json:"variables"`
			UpdatedAt string           `json:"updated_at,omitempty"`
			// File 是导出的共用文件：不想改项目配置的，代码直接读它就行。
			File string `json:"file"`
			// 告诉客户端这份值目前会被谁取用，用户才知道改完要等什么生效。
			Consumers []string `json:"consumers"`
		}{variables, a.variables.updatedAt(), a.variables.sharedFilePath(),
			[]string{"勾选了「加载面板环境变量」的项目", "计划任务", "直接读 " + a.variables.sharedFilePath() + " 的脚本或代码"}})
	case http.MethodPut:
		var payload struct {
			Variables []globalVariable `json:"variables"`
		}
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 128<<10)).Decode(&payload); err != nil {
			http.Error(w, "变量表格式无效", http.StatusBadRequest)
			return
		}
		saved, err := a.variables.replace(payload.Variables)
		if err != nil {
			http.Error(w, err.Error(), http.StatusConflict)
			return
		}
		// 变量改了但项目单元还写着旧值，用户会以为没生效，所以立刻同步一次。
		// 只有勾了加载的项目会被动到，其余项目的单元一个字节都不变。
		applied, err := a.projects.applyGlobalVariables(r.Context())
		if err != nil {
			http.Error(w, fmt.Sprintf("变量已保存，但同步到项目失败：%s", err.Error()), http.StatusConflict)
			return
		}
		if saved == nil {
			saved = []globalVariable{}
		}
		if applied == nil {
			applied = []string{}
		}
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		_ = json.NewEncoder(w).Encode(struct {
			Variables []globalVariable `json:"variables"`
			Applied   []string         `json:"applied"`
			UpdatedAt string           `json:"updated_at,omitempty"`
			File      string           `json:"file"`
		}{saved, applied, a.variables.updatedAt(), a.variables.sharedFilePath()})
	default:
		w.Header().Set("Allow", "GET, PUT")
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}
