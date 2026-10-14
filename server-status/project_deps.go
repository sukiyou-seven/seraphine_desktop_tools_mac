package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// projectDependency 描述一个项目的依赖安装方式与当前状态。
//
// 「启动就报 ModuleNotFoundError / Cannot find module」几乎总是依赖没装。面板以前
// 只认 Python 的 requirements.txt 和 Node 的 package.json：Python 项目改用
// pyproject.toml / setup.py 声明依赖时会被当成「没有依赖清单」，用户只能自己上
// 服务器敲命令。
//
// Level/Hint/Action 与启动自检共用一套说法，「项目依赖」那条自检直接照着渲染，
// 免得两处各写一遍、慢慢长歪。
type projectDependency struct {
	Manifest  string `json:"manifest,omitempty"`
	Present   bool   `json:"present"`
	Installed bool   `json:"installed"`
	Command   string `json:"command,omitempty"`
	Level     string `json:"level,omitempty"`
	Detail    string `json:"detail,omitempty"`
	Hint      string `json:"hint,omitempty"`
	Action    string `json:"action,omitempty"`
}

// dependencyStep 是一条安装命令。
type dependencyStep struct {
	exec  string   // 直接执行的绝对路径（可能尚不存在）
	args  []string // 完整参数
	label string   // 展示给人看的命令
}

// dependencyPlan 是一个运行环境下「某一类依赖清单」对应的安装配方。
type dependencyPlan struct {
	manifest string           // 用来判断「项目里到底有没有这份清单」的文件名
	related  []string         // 参与指纹的锁文件等；清单或锁文件一变就重新提示安装
	steps    []dependencyStep // 按顺序尝试，前一条失败才试下一条
	// check 进一步判断这份清单在当前工程里能不能用，不能用时给出原因。
	// nil 表示只要清单文件在就能用。原因会同时出现在启动自检和安装报错里。
	check func() (bool, string)
}

// command 是这条配方对外的代表命令，用于提示与按钮文案。
func (plan dependencyPlan) command() string {
	if len(plan.steps) == 0 {
		return ""
	}
	return plan.steps[0].label
}

func regularFile(path string) bool {
	info, err := os.Lstat(path)
	return err == nil && info.Mode().IsRegular()
}

// executableFile 判断可执行文件存在且可执行。这里必须用 os.Stat 跟随软链接：
// 虚拟环境里的 python3 / gunicorn，以及 Node 官方包里的 npm，全都是软链接。
func executableFile(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.Mode().IsRegular() && info.Mode().Perm()&0111 != 0
}

// toolPath 在候选位置里挑第一个可执行的，都找不到时返回空串。
//
// 只看运行环境自己的 bin 目录，不去翻 PATH：面板装的 Node/Python 都在自己的目录里，
// 走 PATH 反而可能挑到这台机器上另外装的那一份。
func toolPath(candidates ...string) string {
	for _, candidate := range candidates {
		if executableFile(candidate) {
			return candidate
		}
	}
	return ""
}

// dependencyToolName 给「找不到 XX」这类提示用：优先报可执行文件名，说不出来就退回命令名。
func dependencyToolName(step dependencyStep) string {
	if step.exec != "" {
		return filepath.Base(step.exec)
	}
	if fields := strings.Fields(step.label); len(fields) > 0 {
		return fields[0]
	}
	return "依赖安装命令"
}

// pythonManifestNames 是 Python 工程可能用到的依赖清单，顺序与下面的方案一致。
// 「一个都没找到」和「没开虚拟环境所以不装」两种情况都要照它报出找过哪些文件。
var pythonManifestNames = []string{"requirements.txt", "pyproject.toml", "setup.py"}

// existingManifests 挑出工程目录里真实存在的清单文件，按传入顺序返回。
func existingManifests(directory string, names ...string) []string {
	found := []string{}
	for _, name := range names {
		if regularFile(filepath.Join(directory, name)) {
			found = append(found, name)
		}
	}
	return found
}

// dependencyPlans 列出这个项目可以用到的依赖清单方案，按优先级排列。
//
// 返回空表示这个运行环境没有「在服务器上装依赖」这一步：Java 的入口是打好的 jar、
// .NET 的入口是发布好的 dll、Deno 运行时自己拉依赖。
//
// 这里刻意**不**看有没有虚拟环境：依赖清单本身与虚拟环境无关，面板得先认得出
// 工程里摆的是 requirements.txt 还是 pyproject.toml。装不装是调用方的决定——
// 没有虚拟环境时依赖只能装进共享的 Python，会牵连所有项目，所以那两个入口会拒绝。
func (pm *projectManager) dependencyPlans(item project) []dependencyPlan {
	directory := item.Directory
	venvBin := filepath.Join(pm.venvDir(item.ID), "bin")
	runtimeBin := filepath.Join(pm.runtimeBase(item.Runtime, item.RuntimeVersion), "bin")
	switch item.Runtime {
	case "python":
		python := filepath.Join(venvBin, "python3")
		pipInstall := func(targets ...string) []string {
			return append([]string{"-m", "pip", "install", "--no-input", "--disable-pip-version-check"}, targets...)
		}
		plans := []dependencyPlan{{
			manifest: "requirements.txt",
			steps: []dependencyStep{{
				exec:  python,
				args:  pipInstall("-r", filepath.Join(directory, "requirements.txt")),
				label: "pip install -r requirements.txt",
			}},
		}}

		// pyproject.toml：PEP 621 / uv / Hatch / PDM / Poetry 的项目都用它声明依赖，
		// pip 自己就能按 PEP 517 把项目连同依赖装进虚拟环境。
		pyproject := filepath.Join(directory, "pyproject.toml")
		declared, declaresProject := readPyproject(pyproject)
		steps := []dependencyStep{{exec: python, args: pipInstall(directory), label: "pip install ."}}
		if len(declared) > 0 {
			// 第二条命令：工程是扁平布局（几个 .py 直接放在根目录）时 setuptools 的
			// 自动发现会找不到包、构建直接失败，但 [project] 里声明的依赖本身很明确，
			// 这时只装依赖就够了。两条都写进日志，用户看得见面板做了什么。
			steps = append(steps, dependencyStep{
				exec:  python,
				args:  pipInstall(declared...),
				label: "pip install " + strings.Join(declared, " "),
			})
		}
		plans = append(plans, dependencyPlan{
			manifest: "pyproject.toml",
			related:  []string{"uv.lock", "poetry.lock", "pdm.lock", "setup.cfg"},
			steps:    steps,
			check: func() (bool, string) {
				if declaresProject {
					return true, ""
				}
				return false, "pyproject.toml 里没有声明可安装的项目（缺 [project] 或 [build-system]），面板没法照它装依赖；可以补一份 requirements.txt"
			},
		})

		// 老一点的工程只有 setup.py；pip 认得它（会自己拉 setuptools 当构建后端）。
		plans = append(plans, dependencyPlan{
			manifest: "setup.py",
			steps: []dependencyStep{{
				exec:  python,
				args:  pipInstall(directory),
				label: "pip install .",
			}},
		})
		return plans
	case "node":
		lock := func(name string) string { return filepath.Join(directory, name) }
		pnpm := toolPath(filepath.Join(runtimeBin, "pnpm"))
		yarn := toolPath(filepath.Join(runtimeBin, "yarn"))
		// 锁文件决定包管理器：pnpm / yarn 工程用 npm 装出来的是另一套 node_modules
		// （hoist 规则不一样），跑起来常常是「Cannot find module」。装了对应工具就按
		// 它自己的锁文件装，没装就退回 npm，但要把这件事说清楚。
		plans := []dependencyPlan{
			{
				manifest: "package.json",
				related:  []string{"pnpm-lock.yaml", "pnpm-workspace.yaml"},
				steps:    []dependencyStep{{exec: pnpm, args: []string{"install"}, label: "pnpm install"}},
				check: func() (bool, string) {
					if !regularFile(lock("pnpm-lock.yaml")) {
						return false, ""
					}
					if pnpm != "" {
						return true, ""
					}
					return false, "工程里有 pnpm-lock.yaml，但运行环境里没有 pnpm，面板会用 npm 安装（node_modules 布局不一样）"
				},
			},
			{
				manifest: "package.json",
				related:  []string{"yarn.lock"},
				steps:    []dependencyStep{{exec: yarn, args: []string{"install"}, label: "yarn install"}},
				check: func() (bool, string) {
					if !regularFile(lock("yarn.lock")) {
						return false, ""
					}
					if yarn != "" {
						return true, ""
					}
					return false, "工程里有 yarn.lock，但运行环境里没有 yarn，面板会用 npm 安装（node_modules 布局不一样）"
				},
			},
		}
		npmArgs := []string{"install", "--no-fund", "--no-audit"}
		if regularFile(lock("package-lock.json")) || regularFile(lock("npm-shrinkwrap.json")) {
			npmArgs = []string{"ci", "--no-fund", "--no-audit"}
		}
		plans = append(plans, dependencyPlan{
			manifest: "package.json",
			related:  []string{"package-lock.json", "npm-shrinkwrap.json"},
			steps:    []dependencyStep{{exec: filepath.Join(runtimeBin, "npm"), args: npmArgs, label: "npm " + npmArgs[0]}},
		})
		return plans
	case "bun":
		return []dependencyPlan{{
			manifest: "package.json",
			related:  []string{"bun.lockb", "bun.lock"},
			steps:    []dependencyStep{{exec: filepath.Join(runtimeBin, "bun"), args: []string{"install"}, label: "bun install"}},
		}}
	case "go":
		return []dependencyPlan{{
			manifest: "go.mod",
			related:  []string{"go.sum"},
			steps:    []dependencyStep{{exec: filepath.Join(runtimeBin, "go"), args: []string{"mod", "download"}, label: "go mod download"}},
		}}
	case "ruby":
		return []dependencyPlan{{
			manifest: "Gemfile",
			related:  []string{"Gemfile.lock"},
			steps:    []dependencyStep{{exec: filepath.Join(runtimeBin, "bundle"), args: []string{"install"}, label: "bundle install"}},
		}}
	}
	return nil
}

// dependencySelection 是一次「挑依赖清单」的结果。
type dependencySelection struct {
	plans []dependencyPlan
	// plan 是最终选中的方案；一个都没选中时，是被挡住的那一个（用来说明卡在哪一步）。
	plan dependencyPlan
	// notes 是「清单在、面板却没用它」的说明，按遇到的顺序排列。
	notes []string
	// found 为 false 表示没有可以照着安装的清单。
	found bool
}

// selectDependency 按优先级挑出实际要用的方案。
//
// 只往后看一眼不算：前面的方案「文件在但用不了」时，原因要记下来——既可能是
// 用户看到的问题本身（pyproject.toml 没声明项目），也可能是要顺带解释的取舍
// （工程用 pnpm，但运行环境里没有 pnpm，面板改用 npm）。
func (pm *projectManager) selectDependency(item project) dependencySelection {
	selection := dependencySelection{plans: pm.dependencyPlans(item)}
	blocked := false
	for _, plan := range selection.plans {
		if !regularFile(filepath.Join(item.Directory, plan.manifest)) {
			continue
		}
		if plan.check == nil {
			selection.plan, selection.found = plan, true
			return selection
		}
		if usable, reason := plan.check(); usable {
			selection.plan, selection.found = plan, true
			return selection
		} else if reason != "" {
			selection.notes = append(selection.notes, reason)
		}
		if !blocked {
			selection.plan, blocked = plan, true
		}
	}
	return selection
}

// dependencyManifests 列出这组方案认得的清单文件名（去重），
// 用来在「一个都没找到」时说清楚面板到底找过什么。
func dependencyManifests(plans []dependencyPlan) []string {
	names := []string{}
	for _, plan := range plans {
		known := false
		for _, name := range names {
			if name == plan.manifest {
				known = true
				break
			}
		}
		if !known {
			names = append(names, plan.manifest)
		}
	}
	return names
}

// joinNotes 把几句说明接成一句，空串丢掉。
func joinNotes(notes ...string) string {
	kept := make([]string, 0, len(notes))
	for _, note := range notes {
		if note = strings.TrimSpace(note); note != "" {
			kept = append(kept, note)
		}
	}
	return strings.Join(kept, "；")
}

// readPyproject 读一次 pyproject.toml，返回它声明的依赖，以及它是不是一个可安装的项目。
//
// 读不到、太大、解析不出来时都返回空：面板宁可说「没法照它装」，也不去猜用户想装什么。
func readPyproject(path string) (dependencies []string, declaresProject bool) {
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() || info.Size() > 1<<20 {
		return nil, false
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, false
	}
	return pyprojectRequirements(data), pyprojectDeclaresProject(data)
}

// pyprojectDeclaresProject 判断 pyproject.toml 里有没有「可安装项目」的声明。
//
// 只放了 [tool.black] / [tool.ruff] 这类配置的 pyproject.toml 很常见，对它执行
// pip install . 只会得到一句「does not appear to be a Python project」，
// 不如提前说清楚。
func pyprojectDeclaresProject(data []byte) bool {
	for _, section := range pyprojectSections(data) {
		switch section {
		case "project", "build-system", "tool.poetry":
			return true
		}
	}
	return false
}

// pyprojectSections 列出 TOML 里出现过的段名。只做「行首 [xxx]」这种最朴素的识别，
// 判断有没有 [project] / [build-system] 足够了。
func pyprojectSections(data []byte) []string {
	sections := []string{}
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if !strings.HasPrefix(line, "[") {
			continue
		}
		if end := strings.IndexByte(line, ']'); end > 1 {
			sections = append(sections, strings.TrimSpace(line[1:end]))
		}
	}
	return sections
}

// pyprojectRequirements 从 pyproject.toml 的 [project] 段里取出依赖声明。
//
// 只认 PEP 621 的标准写法（dependencies = ["fastapi>=0.110", ...]）：取出来的就是
// PEP 508 字符串，可以原样交给 pip。用 Poetry 的 ^ / ~ 约束、或者依赖由构建后端
// 动态生成（dynamic = ["dependencies"]）时一律返回空——那些写法翻译过来未必等价，
// 宁可让用户自己补一份 requirements.txt，也不要装出另一套版本。
func pyprojectRequirements(data []byte) []string {
	inProject, collecting := false, false
	buffer := ""
	for _, raw := range strings.Split(string(data), "\n") {
		line := strings.TrimSpace(stripTomlComment(raw))
		if line == "" {
			continue
		}
		if !collecting {
			if strings.HasPrefix(line, "[") {
				inProject = strings.HasPrefix(line, "[project]")
				continue
			}
			if !inProject {
				continue
			}
			key, value, ok := strings.Cut(line, "=")
			if !ok {
				continue
			}
			switch strings.TrimSpace(key) {
			case "dynamic":
				if strings.Contains(value, "dependencies") {
					return nil // 依赖由构建后端算出来，猜不得
				}
				continue
			case "dependencies":
				buffer, collecting = value, true
			default:
				continue
			}
		} else {
			buffer += " " + line
		}
		// 数组写在一行或跨多行都可能，以 ] 结尾的行才算读完。依赖里的 extras 会带
		// uvicorn[standard] 这种中括号，所以不能只看有没有出现过 ]。
		if !strings.HasSuffix(line, "]") {
			continue
		}
		if values, ok := tomlStringList(buffer); ok {
			return values
		}
		return nil
	}
	return nil
}

// stripTomlComment 去掉 TOML 行尾注释；# 出现在字符串里时不算注释。
func stripTomlComment(line string) string {
	quote := byte(0)
	for index := 0; index < len(line); index++ {
		char := line[index]
		switch {
		case quote != 0:
			if char == '\\' && quote == '"' {
				index++
			} else if char == quote {
				quote = 0
			}
		case char == '"' || char == '\'':
			quote = char
		case char == '#':
			return line[:index]
		}
	}
	return line
}

// tomlStringList 从一个 TOML 字符串数组里取出各个字符串。
// 遇到看不懂的元素（不是字符串、或者像 -r other.txt 这样的命令行参数）就整体放弃。
func tomlStringList(text string) ([]string, bool) {
	open := strings.IndexByte(text, '[')
	close := strings.LastIndexByte(text, ']')
	if open < 0 || close < open {
		return nil, false
	}
	body := text[open+1 : close]
	values := []string{}
	for index := 0; index < len(body); {
		switch char := body[index]; {
		case char == ' ' || char == '\t' || char == '\n' || char == ',':
			index++
		case char == '"' || char == '\'':
			end := index + 1
			for end < len(body) {
				if char == '"' && body[end] == '\\' {
					end += 2
					continue
				}
				if body[end] == char {
					break
				}
				end++
			}
			if end >= len(body) {
				return nil, false
			}
			value := body[index+1 : end]
			value = strings.TrimSpace(strings.ReplaceAll(strings.ReplaceAll(value, `\"`, `"`), `\\`, `\`))
			if value == "" || strings.HasPrefix(value, "-") {
				return nil, false
			}
			values = append(values, value)
			index = end + 1
		default:
			return nil, false
		}
	}
	return values, true
}

// dependencyFingerprint 把清单与锁文件的大小、修改时间揉成一个指纹。
// 文件没动过就不必重装；动过了就提示重新安装——比只判断目录存在可靠得多。
func (pm *projectManager) dependencyFingerprint(item project, plan dependencyPlan) string {
	hash := sha256.New()
	names := append([]string{plan.manifest}, plan.related...)
	found := false
	for _, name := range names {
		info, err := os.Lstat(filepath.Join(item.Directory, name))
		if err != nil || !info.Mode().IsRegular() {
			continue
		}
		found = true
		fmt.Fprintf(hash, "%s\x00%d\x00%d\n", name, info.Size(), info.ModTime().UnixNano())
	}
	if !found {
		return ""
	}
	return hex.EncodeToString(hash.Sum(nil))
}

func (pm *projectManager) depsMarker(id string) string {
	return filepath.Join(pm.dataDir(id), ".sera-deps")
}

// dependency 汇总依赖清单是否存在、以及是否已经按当前清单装过。
//
// 这里连 Level/Hint/Action 一起算好：「项目依赖」那条自检、详情页的依赖卡片、
// 安装按钮文案全都来自这一份结论。
func (pm *projectManager) dependency(item project) projectDependency {
	selection := pm.selectDependency(item)
	if len(selection.plans) == 0 {
		return projectDependency{Level: checkOK, Detail: "该运行环境不需要在服务器上安装依赖"}
	}
	names := dependencyManifests(selection.plans)
	if item.Runtime == "python" && !item.UseVenv {
		// 依赖清单照常认，但面板不替它装：没有虚拟环境时依赖只能进共享的 Python，
		// 会牵连所有项目。这里要把「工程里摆的是哪份清单」一起说出来，否则面板
		// 表现得像压根不认识 Python 的依赖文件。
		result := projectDependency{Level: checkWarn, Action: "edit",
			Detail: "项目没有启用虚拟环境，面板不会把依赖装进共享的 Python",
			Hint:   "需要第三方包时，编辑项目并勾选「使用虚拟环境」"}
		if present := existingManifests(item.Directory, names...); len(present) > 0 {
			result.Manifest = present[0]
			result.Detail = "工程里有 " + strings.Join(present, "、") +
				"；项目没有启用虚拟环境，面板不会把依赖装进共享的 Python"
		}
		return result
	}
	result := projectDependency{
		Manifest: selection.plans[0].manifest,
		Command:  selection.plans[0].command(),
		Level:    checkWarn,
		Detail:   "工程目录里没有依赖清单（" + strings.Join(names, "、") + "）",
	}
	if !selection.found {
		if len(selection.notes) == 0 {
			result.Hint = "只用标准库或内置模块时可以忽略这一条"
			return result
		}
		// 清单文件在，但面板照它装不了：说清楚卡在哪，而不是假装没有清单。
		return projectDependency{Manifest: selection.plan.manifest, Level: checkWarn,
			Command: selection.plan.command(), Detail: joinNotes(selection.notes...)}
	}
	plan := selection.plan
	result.Manifest, result.Command = plan.manifest, plan.command()
	result.Present = true
	fingerprint := pm.dependencyFingerprint(item, plan)
	if fingerprint == "" {
		result.Detail = plan.manifest + " 不可读"
		return result
	}
	stored, err := os.ReadFile(pm.depsMarker(item.ID))
	switch current := strings.TrimSpace(string(stored)); {
	case err == nil && current == fingerprint:
		result.Installed = true
		result.Level = checkOK
		result.Detail = "已按当前 " + plan.manifest + " 安装"
	case err == nil && current != "":
		result.Detail = plan.manifest + " 已改动，建议重新安装"
		result.Hint = "点「安装依赖」执行 " + plan.command()
		result.Action = "deps"
	default:
		result.Detail = "尚未通过面板安装"
		result.Hint = "点「安装依赖」执行 " + plan.command()
		result.Action = "deps"
	}
	if len(selection.notes) > 0 {
		// 清单装好了，但工程里还摆着另一套锁文件时也要说一句，
		// 否则用户会以为面板看漏了。
		result.Hint = joinNotes(append(selection.notes, result.Hint)...)
	}
	return result
}

// installDependencies 按运行环境安装项目依赖，输出写进项目日志。
//
// 要求项目处于停止状态：一边跑一边改 node_modules / site-packages 很容易装出
// 半成品，重启后报一堆看不懂的错。
func (pm *projectManager) installDependencies(ctx context.Context, id string) error {
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
	if pm.state(ctx, item).ActiveState == "active" {
		return errors.New("请先停止项目，再安装依赖")
	}
	return pm.installDependenciesLocked(ctx, item)
}

// installDependenciesLocked 是安装主体；调用方必须已经持有 pm.mu
// （虚拟环境那套接口也复用它，免得两份实现慢慢长歪）。
func (pm *projectManager) installDependenciesLocked(ctx context.Context, item project) error {
	// 依赖清单的识别不看虚拟环境，安装这一步必须看：把依赖装进共享的 Python
	// 会牵连这台机器上所有 Python 项目。
	if item.Runtime == "python" && !item.UseVenv {
		return errors.New("项目没有启用虚拟环境；面板不会把依赖装进共享的 Python，请先编辑项目并勾选「使用虚拟环境」")
	}
	selection := pm.selectDependency(item)
	if len(selection.plans) == 0 {
		return errors.New("该运行环境不需要安装依赖")
	}
	if !selection.found {
		if len(selection.notes) > 0 {
			return errors.New(joinNotes(selection.notes...))
		}
		return fmt.Errorf("工程目录里没有依赖清单（%s）", strings.Join(dependencyManifests(selection.plans), "、"))
	}
	plan := selection.plan
	if item.Runtime == "python" && !pm.venvReady(item) {
		return errors.New("请先创建与所选 Python 版本匹配的虚拟环境")
	}
	if err := pm.prepareDirectories(item.ID); err != nil {
		return err
	}
	if err := pm.workingDirectoryReady(item); err != nil {
		return err
	}
	log, err := os.OpenFile(pm.logPath(item.ID), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0600)
	if err != nil {
		return err
	}
	defer log.Close()
	work, cancel := context.WithTimeout(ctx, 15*time.Minute)
	defer cancel()
	if err := pm.runDependencySteps(work, item, plan, log); err != nil {
		return fmt.Errorf("安装依赖失败：%w；请查看项目日志", err)
	}
	fingerprint := pm.dependencyFingerprint(item, plan)
	if fingerprint == "" {
		return errors.New("安装完成后无法读取依赖清单")
	}
	if err := os.WriteFile(pm.depsMarker(item.ID), []byte(fingerprint+"\n"), 0600); err != nil {
		return err
	}
	// 依赖清单里常锁着 web 框架的版本，装完可能把启动器依赖的包换掉
	// （例如把 uvicorn 降级，uvicorn-worker 立刻 import 不动）。
	// 依赖确实装好了，只是启动器要重装一次，得说清楚。
	if !pm.pythonServerReady(item) {
		return fmt.Errorf("依赖已安装，但 %s 已不可用（依赖清单里的版本覆盖了它依赖的包）；请再点一次「安装 %s」",
			pythonServerLabel(item.PythonServer), pythonServerLabel(item.PythonServer))
	}
	return nil
}

// runDependencySteps 依次执行安装命令，前一条失败才试下一条。
// 每一条都写进项目日志，用户能看见面板到底做了什么。
func (pm *projectManager) runDependencySteps(ctx context.Context, item project, plan dependencyPlan, log *os.File) error {
	if len(plan.steps) == 0 {
		return errors.New("没有可用的依赖安装命令")
	}
	var failure error
	for index, step := range plan.steps {
		if index > 0 {
			_, _ = fmt.Fprintf(log, "\n[%s] 上一条命令没有成功，接着试：%s\n", time.Now().Format(time.RFC3339), step.label)
		}
		_, _ = fmt.Fprintf(log, "[%s] 安装依赖：%s\n", time.Now().Format(time.RFC3339), step.label)
		if !executableFile(step.exec) {
			failure = fmt.Errorf("找不到 %s，请先安装运行环境或对应的包管理器", dependencyToolName(step))
			_, _ = fmt.Fprintf(log, "%v\n", failure)
			continue
		}
		if err := pm.runAsProject(ctx, item, step.exec, step.args, log); err != nil {
			failure = fmt.Errorf("%s 失败：%w", step.label, err)
			continue
		}
		return nil
	}
	return failure
}

// projectDirectoryEmpty 供自检判断工程目录里是不是什么都还没有。
func projectDirectoryEmpty(path string) bool {
	entries, err := os.ReadDir(path)
	return err == nil && len(entries) == 0
}
