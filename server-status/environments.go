package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

type cappedEnvironmentOutput struct {
	mu   sync.Mutex
	data []byte
}

func (output *cappedEnvironmentOutput) Write(value []byte) (int, error) {
	output.mu.Lock()
	defer output.mu.Unlock()
	if len(output.data) < 4096 {
		remaining := 4096 - len(output.data)
		if len(value) < remaining {
			remaining = len(value)
		}
		output.data = append(output.data, value[:remaining]...)
	}
	return len(value), nil
}

type environmentToolSpec struct {
	name         string
	relativePath string
	args         []string
}

type environmentSpec struct {
	id    string
	tools []environmentToolSpec
}

var environmentCatalog = []environmentSpec{
	{id: "python", tools: []environmentToolSpec{{"Python", "bin/python3", []string{"--version"}}, {"pip", "bin/pip3", []string{"--version"}}}},
	{id: "go", tools: []environmentToolSpec{{"Go", "bin/go", []string{"version"}}}},
	{id: "node", tools: []environmentToolSpec{{"Node.js", "bin/node", []string{"--version"}}, {"npm", "bin/npm", []string{"--version"}}}},
	{id: "openjdk", tools: []environmentToolSpec{{"Java", "bin/java", []string{"--version"}}, {"javac", "bin/javac", []string{"--version"}}}},
	{id: "dotnet", tools: []environmentToolSpec{{".NET SDK", "dotnet", []string{"--version"}}}},
	{id: "ruby", tools: []environmentToolSpec{{"Ruby", "bin/ruby", []string{"--version"}}, {"gem", "bin/gem", []string{"--version"}}}},
	{id: "bun", tools: []environmentToolSpec{{"Bun", "bin/bun", []string{"--version"}}}},
	{id: "deno", tools: []environmentToolSpec{{"Deno", "bin/deno", []string{"--version"}}}},
	{id: "php", tools: []environmentToolSpec{{"PHP", "bin/php", []string{"--version"}}, {"PHP-FPM", "sbin/php-fpm", []string{"--version"}}}},
}

type environmentTool struct {
	Name      string `json:"name"`
	Path      string `json:"path"`
	Available bool   `json:"available"`
	Version   string `json:"version"`
	Error     string `json:"error"`
}

type environmentItem struct {
	ID                string                    `json:"id"`
	Name              string                    `json:"name"`
	CatalogVersion    string                    `json:"catalog_version"`
	InstalledVersion  string                    `json:"installed_version"`
	AvailableVersions []string                  `json:"available_versions"`
	State             string                    `json:"state"`
	Message           string                    `json:"message"`
	InstallPath       string                    `json:"install_path"`
	Supported         bool                      `json:"supported"`
	ServiceState      string                    `json:"service_state"`
	Tools             []environmentTool         `json:"tools"`
	Installations     []environmentInstallation `json:"installations"`
}

type environmentManager struct {
	software *softwareManager
	run      func(context.Context, string, []string) (string, error)
}

func newEnvironmentManager(software *softwareManager) *environmentManager {
	return &environmentManager{software: software, run: func(ctx context.Context, path string, args []string) (string, error) {
		command := exec.CommandContext(ctx, path, args...)
		command.Env = append(os.Environ(), "PATH="+filepath.Dir(path)+string(os.PathListSeparator)+os.Getenv("PATH"))
		if strings.Contains(path, "/server/dotnet/") {
			command.Env = append(command.Env, "DOTNET_CLI_HOME="+filepath.Dir(path), "DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1")
		}
		output := &cappedEnvironmentOutput{}
		command.Stdout, command.Stderr = output, output
		err := command.Run()
		text := strings.TrimSpace(string(output.data))
		return text, err
	}}
}

func findEnvironment(id string) (environmentSpec, bool) {
	for _, spec := range environmentCatalog {
		if spec.id == id {
			return spec, true
		}
	}
	return environmentSpec{}, false
}

func (em *environmentManager) item(ctx context.Context, spec environmentSpec, check bool) environmentItem {
	softwareSpec, _ := findSoftware(spec.id)
	installed := em.software.item(ctx, softwareSpec)
	item := environmentItem{
		ID: spec.id, Name: installed.Name, CatalogVersion: softwareSpec.version,
		AvailableVersions: []string{},
		State:             installed.State, Message: installed.Message, InstallPath: installed.InstallPath,
		Supported: installed.Supported, ServiceState: installed.ServiceState, Tools: []environmentTool{},
	}
	if installed.State == "installed" {
		item.InstalledVersion = installed.Version
	}
	item.Installations = em.installations(spec)
	if len(item.Installations) > 0 && item.State != "installing" && item.State != "uninstalling" {
		item.State = "installed"
	}
	canonicalPrefix := ""
	if info, err := os.Lstat(item.InstallPath); err == nil && info.IsDir() {
		canonicalPrefix, _ = filepath.EvalSymlinks(item.InstallPath)
	}
	for _, toolSpec := range spec.tools {
		path := filepath.Join(item.InstallPath, toolSpec.relativePath)
		tool := environmentTool{Name: toolSpec.name, Path: path}
		if item.State == "installed" {
			resolved, err := filepath.EvalSymlinks(path)
			if err == nil && canonicalPrefix != "" &&
				(resolved == canonicalPrefix || strings.HasPrefix(resolved, canonicalPrefix+string(os.PathSeparator))) {
				if info, statErr := os.Stat(resolved); statErr == nil && info.Mode().IsRegular() && info.Mode().Perm()&0111 != 0 {
					tool.Available = true
				}
			}
			if check {
				if !tool.Available {
					tool.Error = "可执行文件不存在或不在安装目录内"
				} else {
					timeout, cancel := context.WithTimeout(ctx, 8*time.Second)
					output, runErr := em.run(timeout, path, toolSpec.args)
					cancel()
					if runErr != nil {
						tool.Error = fmt.Sprintf("版本检查失败：%v", runErr)
					} else {
						lines := strings.Split(strings.TrimSpace(output), "\n")
						if len(lines) > 0 {
							tool.Version = strings.TrimSpace(lines[0])
						}
					}
				}
			}
		}
		item.Tools = append(item.Tools, tool)
	}
	return item
}

func (a *api) environmentsHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	if !a.authorized(r) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	if r.URL.Path == "/v1/environments" {
		if r.Method != http.MethodGet {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		items := make([]environmentItem, 0, len(environmentCatalog))
		for _, spec := range environmentCatalog {
			items = append(items, a.environments.item(r.Context(), spec, false))
		}
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		_ = json.NewEncoder(w).Encode(struct {
			Items []environmentItem `json:"items"`
		}{items})
		return
	}
	parts := strings.Split(strings.TrimPrefix(r.URL.Path, "/v1/environments/"), "/")
	if len(parts) < 2 {
		http.NotFound(w, r)
		return
	}
	spec, ok := findEnvironment(parts[0])
	if !ok {
		http.NotFound(w, r)
		return
	}
	if !(len(parts) == 2 && parts[1] == "check" && r.Method == http.MethodPost) {
		a.environmentVersionHandler(w, r, parts, spec)
		return
	}
	if !a.software.beginServiceAction() {
		http.Error(w, "another software operation is running", http.StatusConflict)
		return
	}
	defer a.software.endServiceAction()
	item := a.environments.item(r.Context(), spec, true)
	if item.State != "installed" {
		http.Error(w, "environment is not installed", http.StatusConflict)
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	_ = json.NewEncoder(w).Encode(item)
}
