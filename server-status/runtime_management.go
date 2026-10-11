package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

type environmentInstallation struct {
	Version      string            `json:"version"`
	Path         string            `json:"path"`
	Legacy       bool              `json:"legacy"`
	ServiceState string            `json:"service_state"`
	Tools        []environmentTool `json:"tools"`
}

type environmentVersionsResponse struct {
	Versions []string `json:"versions"`
	Source   string   `json:"source"`
}

func (em *environmentManager) versionPrefix(id, version string) string {
	return filepath.Join(em.software.prefix(id), "versions", version)
}

func (em *environmentManager) installations(spec environmentSpec) []environmentInstallation {
	out := []environmentInstallation{}
	legacy := em.software.prefix(spec.id)
	if marker, err := os.Lstat(filepath.Join(legacy, ".sera-installed")); err == nil && marker.Mode().IsRegular() {
		if data, err := os.ReadFile(filepath.Join(legacy, ".sera-installed")); err == nil {
			version := strings.TrimSpace(string(data))
			if versionPattern.MatchString(version) {
				out = append(out, em.installation(spec, version, legacy, true))
			}
		}
	}
	entries, err := os.ReadDir(filepath.Join(legacy, "versions"))
	if err != nil {
		return out
	}
	for _, entry := range entries {
		version := entry.Name()
		if !versionPattern.MatchString(version) || !entry.IsDir() {
			continue
		}
		prefix := em.versionPrefix(spec.id, version)
		marker, err := os.Lstat(filepath.Join(prefix, ".sera-installed"))
		if err != nil || !marker.Mode().IsRegular() {
			continue
		}
		data, err := os.ReadFile(filepath.Join(prefix, ".sera-installed"))
		if err != nil || strings.TrimSpace(string(data)) != version {
			continue
		}
		out = append(out, em.installation(spec, version, prefix, false))
	}
	return out
}

func (em *environmentManager) installation(spec environmentSpec, version, prefix string, legacy bool) environmentInstallation {
	tools := make([]environmentTool, 0, len(spec.tools))
	canonical, e := filepath.EvalSymlinks(prefix)
	if e != nil {
		canonical = ""
	}
	for _, t := range spec.tools {
		p := filepath.Join(prefix, t.relativePath)
		tool := environmentTool{Name: t.name, Path: p}
		resolved, e := filepath.EvalSymlinks(p)
		if e == nil && canonical != "" && (resolved == canonical || strings.HasPrefix(resolved, canonical+string(os.PathSeparator))) {
			if info, e := os.Stat(resolved); e == nil && info.Mode().IsRegular() && info.Mode().Perm()&0111 != 0 {
				tool.Available = true
			}
		}
		tools = append(tools, tool)
	}
	state := ""
	if spec.id == "php" && !legacy {
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		output, _ := em.software.systemctl(ctx, "is-active", "sera-php-"+version+".service")
		cancel()
		state = strings.TrimSpace(string(output))
	}
	return environmentInstallation{version, prefix, legacy, state, tools}
}

func (em *environmentManager) checkInstallation(ctx context.Context, spec environmentSpec, version string) (environmentInstallation, error) {
	for _, installed := range em.installations(spec) {
		if installed.Version == version {
			for i := range installed.Tools {
				t := &installed.Tools[i]
				if !t.Available {
					t.Error = "可执行文件不存在或不在安装目录内"
					continue
				}
				toolSpec := spec.tools[i]
				checkCtx, cancel := context.WithTimeout(ctx, 8*time.Second)
				output, err := em.run(checkCtx, t.Path, toolSpec.args)
				cancel()
				if err != nil {
					t.Error = fmt.Sprintf("版本检查失败：%v", err)
				} else {
					t.Version = strings.Split(strings.TrimSpace(output), "\n")[0]
				}
			}
			return installed, nil
		}
	}
	return environmentInstallation{}, os.ErrNotExist
}

func runRuntimeInstaller(ctx context.Context, id string, r runtimeRelease, prefix string, output io.Writer) error {
	common, err := installerScripts.ReadFile("installers/common.sh")
	if err != nil {
		return err
	}
	script, err := installerScripts.ReadFile("installers/runtime-version.sh")
	if err != nil {
		return err
	}
	command := exec.CommandContext(ctx, "/bin/sh", "-c", string(common)+"\n"+string(script))
	command.Env = append(os.Environ(), "SERA_RUNTIME_ID="+id, "SERA_SELECTED_VERSION="+r.Version, "SERA_INSTALL_PREFIX="+prefix, "SERA_ASSET_URL="+r.URL, "SERA_ASSET_FILE="+r.File, "SERA_ASSET_SHA256="+r.SHA256, "SERA_ASSET_SHA512="+r.SHA512)
	command.Stdout = output
	command.Stderr = output
	return command.Run()
}

func (em *environmentManager) startInstall(id string, r runtimeRelease) error {
	prefix := em.versionPrefix(id, r.Version)
	em.software.mu.Lock()
	defer em.software.mu.Unlock()
	if em.software.busy {
		return errors.New("已有软件操作正在执行")
	}
	if _, err := os.Lstat(prefix); err == nil {
		return errors.New("该版本安装目录已存在")
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	em.software.busy = true
	em.software.jobs[id] = &installJob{operation: "install", state: "installing", message: "正在安装 " + r.Version}
	go func() {
		logPath := em.software.logPath(id)
		result := "failed"
		message := "安装失败，请查看日志"
		if err := os.MkdirAll(filepath.Dir(logPath), 0750); err == nil {
			if logFile, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0600); err == nil {
				ctx, cancel := context.WithTimeout(context.Background(), 180*time.Minute)
				err = runRuntimeInstaller(ctx, id, r, prefix, logFile)
				cancel()
				_ = logFile.Close()
				if err == nil {
					if _, e := os.Stat(filepath.Join(prefix, ".sera-installed")); e == nil {
						result = "installed"
						message = "安装完成"
					}
				} else {
					message = "安装失败：" + err.Error()
				}
			}
		}
		em.software.mu.Lock()
		em.software.jobs[id] = &installJob{operation: "install", state: result, message: message}
		em.software.busy = false
		em.software.mu.Unlock()
	}()
	return nil
}

func (em *environmentManager) uninstallVersion(id, version, mode string) error {
	if mode != "backup" && mode != "purge" {
		return errors.New("无效卸载方式")
	}
	spec, ok := findEnvironment(id)
	if !ok {
		return os.ErrNotExist
	}
	prefix := em.versionPrefix(id, version)
	found := false
	for _, v := range em.installations(spec) {
		if v.Version == version && !v.Legacy {
			found = true
			break
		}
	}
	if !found {
		return os.ErrNotExist
	}
	em.software.mu.Lock()
	defer em.software.mu.Unlock()
	if em.software.busy {
		return errors.New("已有软件操作正在执行")
	}
	em.software.busy = true
	em.software.jobs[id] = &installJob{operation: "uninstall", state: "uninstalling", message: "正在卸载 " + version}
	go func() {
		result := "failed"
		message := "卸载失败"
		logPath := em.software.logPath(id)
		if f, e := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0600); e == nil {
			if id == "php" {
				unit := "sera-php-" + version + ".service"
				ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
				_, e = em.software.systemctl(ctx, "stop", unit)
				if e == nil {
					_, e = em.software.systemctl(ctx, "disable", unit)
				}
				cancel()
				if e != nil {
					message = "停止 PHP-FPM 失败：" + e.Error()
				}
			}
			if e == nil {
				if mode == "backup" {
					parent := filepath.Join(em.software.root, "backup", "environments")
					e = os.MkdirAll(parent, 0700)
					if e == nil {
						var backup string
						backup, e = os.MkdirTemp(parent, id+"-"+version+"-")
						if e == nil {
							e = moveInstallation(context.Background(), prefix, filepath.Join(backup, "install"), f)
							if e == nil {
								message = "已备份到 " + filepath.Join(backup, "install")
							}
						}
					}
				} else {
					e = os.RemoveAll(prefix)
					if e == nil {
						message = "卸载完成"
					}
				}
			}
			if e == nil && id == "php" {
				e = os.Remove(filepath.Join(em.software.unitDir, "sera-php-"+version+".service"))
				if e == nil {
					ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
					_, e = em.software.systemctl(ctx, "daemon-reload")
					cancel()
				}
			}
			if e == nil {
				result = "not_installed"
			} else {
				message = "卸载失败：" + e.Error()
			}
			_, _ = fmt.Fprintln(f, message)
			_ = f.Close()
		}
		em.software.mu.Lock()
		em.software.jobs[id] = &installJob{operation: "uninstall", state: result, message: message}
		em.software.busy = false
		em.software.mu.Unlock()
	}()
	return nil
}

func (a *api) environmentVersionHandler(w http.ResponseWriter, r *http.Request, parts []string, spec environmentSpec) {
	write := func(v any) {
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		_ = json.NewEncoder(w).Encode(v)
	}
	if len(parts) == 2 && parts[1] == "versions" && r.Method == http.MethodGet {
		ctx, cancel := context.WithTimeout(r.Context(), 50*time.Second)
		defer cancel()
		releases, err := runtimeReleases(ctx, spec.id)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadGateway)
			return
		}
		versions := make([]string, 0, len(releases))
		for _, release := range releases {
			versions = append(versions, release.Version)
		}
		write(environmentVersionsResponse{versions, "upstream"})
		return
	}
	if len(parts) == 2 && parts[1] == "install" && r.Method == http.MethodPost {
		var body struct {
			Version string `json:"version"`
		}
		if json.NewDecoder(io.LimitReader(r.Body, 4096)).Decode(&body) != nil || !versionPattern.MatchString(body.Version) {
			http.Error(w, "无效版本", 400)
			return
		}
		if !a.software.supported(spec.id) {
			http.Error(w, "当前系统不支持安装", 409)
			return
		}
		ctx, cancel := context.WithTimeout(r.Context(), 50*time.Second)
		defer cancel()
		releases, err := runtimeReleases(ctx, spec.id)
		if err != nil {
			http.Error(w, err.Error(), 502)
			return
		}
		for _, release := range releases {
			if release.Version == body.Version {
				if err := a.environments.startInstall(spec.id, release); err != nil {
					http.Error(w, err.Error(), 409)
					return
				}
				w.WriteHeader(202)
				return
			}
		}
		http.Error(w, "所选版本不在当前发布源中", 400)
		return
	}
	if len(parts) == 4 && parts[1] == "versions" && versionPattern.MatchString(parts[2]) {
		switch parts[3] {
		case "check":
			if r.Method == http.MethodPost {
				installed, err := a.environments.checkInstallation(r.Context(), spec, parts[2])
				if err != nil {
					http.Error(w, "该版本未安装", 404)
					return
				}
				write(installed)
				return
			}
		case "uninstall":
			if r.Method == http.MethodPost {
				var body struct {
					Mode string `json:"mode"`
				}
				if json.NewDecoder(io.LimitReader(r.Body, 4096)).Decode(&body) != nil {
					http.Error(w, "无效请求", 400)
					return
				}
				if err := a.environments.uninstallVersion(spec.id, parts[2], body.Mode); err != nil {
					http.Error(w, err.Error(), 409)
					return
				}
				w.WriteHeader(202)
				return
			}
		case "service":
			if r.Method == http.MethodPost && spec.id == "php" {
				var body struct {
					Action string `json:"action"`
				}
				if json.NewDecoder(io.LimitReader(r.Body, 4096)).Decode(&body) != nil || !validServiceAction(body.Action) {
					http.Error(w, "无效服务操作", 400)
					return
				}
				if _, err := a.environments.checkInstallation(r.Context(), spec, parts[2]); err != nil {
					http.Error(w, "版本未安装", 404)
					return
				}
				if !a.software.beginServiceAction() {
					http.Error(w, "已有软件操作正在执行", 409)
					return
				}
				defer a.software.endServiceAction()
				ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
				defer cancel()
				output, err := a.software.systemctl(ctx, body.Action, "sera-php-"+parts[2]+".service")
				if err != nil {
					http.Error(w, string(output), 500)
					return
				}
				w.WriteHeader(204)
				return
			}
		}
	}
	http.NotFound(w, r)
}
