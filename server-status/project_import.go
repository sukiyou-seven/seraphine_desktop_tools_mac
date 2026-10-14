package main

import (
	"archive/tar"
	"archive/zip"
	"bytes"
	"compress/gzip"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	pathpkg "path"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

// 导入的几道闸。压缩包本身有上限，解压后的总量也有限制——只卡压缩包大小挡不住
// zip bomb，一个几十 KB 的 gzip 能铺满磁盘。
const (
	maxImportArchiveBytes = 1 << 30
	maxImportTotalBytes   = 4 << 30
	maxImportEntries      = 20000
	maxImportFileBytes    = 512 << 20
)

// projectImportFile 是散装上传的一个文件（AI 直接给内容时走这条路）。
type projectImportFile struct {
	Path    string `json:"path"`
	Content string `json:"content"`
	// Mode 是八进制权限，比如 "0755"。留空时按脚本 / 普通文件自动判断。
	Mode string `json:"mode,omitempty"`
}

// projectImport 描述一次导入：上传什么、建成什么样的项目。
type projectImport struct {
	ID      string `json:"id"`
	Name    string `json:"name"`
	Runtime string `json:"runtime"`
	Entry   string `json:"entry"`
	Port    int    `json:"port"`
	// Start 为真时导入完顺手启动，省掉一次往返——自动化里最常用的一步。
	Start bool `json:"start"`
	// Overwrite 允许覆盖已有工程目录里的内容（不覆盖项目配置）。
	Overwrite bool `json:"overwrite"`
	// UseVenv / Env 等直接写进项目配置，和 POST /v1/projects 的字段一致。
	UseVenv      bool              `json:"use_venv"`
	PythonServer string            `json:"python_server,omitempty"`
	Env          map[string]string `json:"env,omitempty"`
	EnvFile      bool              `json:"env_file,omitempty"`
	UseGlobalEnv *bool             `json:"use_global_env,omitempty"`
	Directory    string            `json:"directory,omitempty"`

	// Archive 是压缩包内容（zip / tar.gz / tar，按魔数识别）。
	Archive []byte `json:"-"`
	// ArchiveBase64 让 MCP 这类只能传 JSON 的调用方也能带压缩包。
	ArchiveBase64 string `json:"archive_base64,omitempty"`
	// Files 是散装文件，和压缩包二选一。
	Files []projectImportFile `json:"files,omitempty"`
}

// projectImportResult 是导入结果。字段都留着，客户端要拿它说明白做了什么。
type projectImportResult struct {
	Project  project  `json:"project"`
	Files    int      `json:"files"`
	Bytes    int64    `json:"bytes"`
	Skipped  []string `json:"skipped,omitempty"`
	Started  bool     `json:"started"`
	StartLog string   `json:"start_error,omitempty"`
}

func (spec projectImport) pattern() []byte {
	if len(spec.Archive) > 0 {
		return spec.Archive
	}
	if spec.ArchiveBase64 != "" {
		decoded, err := base64.StdEncoding.DecodeString(strings.TrimSpace(spec.ArchiveBase64))
		if err == nil {
			return decoded
		}
	}
	return nil
}

// importProject 把一份内容放成工程目录，然后按同样的规则建项目。
//
// 顺序是刻意的：内容先落地，再走 pm.save —— 这样「入口文件存不存在」「运行环境
// 装没装」这些检查用的是项目正常保存时那一套，导入不会绕开它们。
func (pm *projectManager) importProject(ctx context.Context, spec projectImport, archive []byte) (projectImportResult, error) {
	result := projectImportResult{}
	item := project{
		ID: spec.ID, Name: spec.Name, Runtime: spec.Runtime, Entry: spec.Entry,
		Port: spec.Port, UseVenv: spec.UseVenv, PythonServer: spec.PythonServer,
		Env: spec.Env, EnvFile: spec.EnvFile, UseGlobalEnv: spec.UseGlobalEnv,
		Directory: spec.Directory,
	}
	if item.Name == "" {
		item.Name = item.ID
	}
	if item.Directory == "" {
		item.Directory = pm.projectDir(item.ID)
	}
	// 先让 normalize 把 id / runtime / entry / port 全部校验一遍，别等解压完
	// 才发现参数不对——解压可能要好一会儿。
	normalized, err := pm.normalize(item)
	if err != nil {
		return result, err
	}
	item = normalized
	if item.Directory != pm.projectDir(item.ID) {
		// 导入的落点是工程目录；指向别处就不该走这条路。
		return result, errors.New("导入只在工程目录内进行，不能指定其他目录")
	}

	payload := archive
	if len(payload) == 0 {
		payload = spec.pattern()
	}
	if len(spec.Files) == 0 && len(payload) == 0 {
		return result, errors.New("导入内容为空：请提供压缩包或 files 列表")
	}
	if len(payload) > maxImportArchiveBytes {
		return result, fmt.Errorf("压缩包超过 %d MiB", maxImportArchiveBytes>>20)
	}

	target := pm.projectDir(item.ID)
	if info, err := os.Lstat(target); err == nil {
		if !info.IsDir() {
			return result, errors.New("工程目录位置上已经有一个同名文件，请先在文件管理里处理")
		}
		if !spec.Overwrite {
			entries, err := os.ReadDir(target)
			if err != nil {
				return result, err
			}
			for _, entry := range entries {
				// data/ 是面板给项目放虚拟环境和缓存的地方，不算「已有内容」。
				if entry.Name() != "data" {
					return result, errors.New("工程目录里已经有文件了；确实要覆盖请在请求里带 overwrite=true")
				}
			}
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return result, err
	}

	if err := os.MkdirAll(filepath.Join(pm.root, "projects"), 0755); err != nil {
		return result, err
	}
	staging, err := os.MkdirTemp(filepath.Join(pm.root, "projects"), ".sera-import-")
	if err != nil {
		return result, err
	}
	defer os.RemoveAll(staging)

	switch {
	case len(spec.Files) > 0:
		result.Files, result.Bytes, result.Skipped, err = writeImportFiles(staging, spec.Files)
	case len(payload) > 0:
		result.Files, result.Bytes, result.Skipped, err = extractArchive(payload, staging)
	}
	if err != nil {
		return result, err
	}
	if result.Files == 0 {
		return result, errors.New("压缩包里没有可用的文件")
	}

	content, err := importContentRoot(staging)
	if err != nil {
		return result, err
	}
	// 目标目录已存在时先腾位置：Rename 不能覆盖非空目录。
	if _, err := os.Lstat(target); err == nil {
		if err := os.RemoveAll(target); err != nil {
			return result, err
		}
	}
	if err := os.Rename(content, target); err != nil {
		return result, err
	}

	saved, err := pm.save(ctx, item, true)
	if err != nil {
		return result, err
	}
	result.Project = saved
	if !spec.Start {
		return result, nil
	}
	if err := pm.action(ctx, item.ID, "start"); err != nil {
		// 导入本身是成功的，启动失败不该让整个请求变成失败——把原因带回去，
		// 客户端和 AI 才有机会去看自检。
		result.StartLog = err.Error()
		return result, nil
	}
	result.Started = true
	result.Project = pm.state(ctx, item)
	return result, nil
}

// importContentRoot 决定哪一层是工程内容的根。
//
// 从 GitHub 拉的压缩包都会多包一层 `<repo>-main/`，直接把那一层当工程根才对；
// 若里面混着别的东西（README、多个目录）就说明它本来就是内容根，不能剥。
func importContentRoot(staging string) (string, error) {
	entries, err := os.ReadDir(staging)
	if err != nil {
		return "", err
	}
	if len(entries) == 1 && entries[0].IsDir() {
		return filepath.Join(staging, entries[0].Name()), nil
	}
	return staging, nil
}

// writeImportFiles 把散装文件写进暂存目录。
func writeImportFiles(staging string, files []projectImportFile) (int, int64, []string, error) {
	var count int
	var total int64
	var skipped []string
	for _, file := range files {
		name, ok := archiveEntryName(file.Path)
		if !ok {
			skipped = append(skipped, file.Path)
			continue
		}
		body := []byte(file.Content)
		if int64(len(body)) > maxImportFileBytes {
			return count, total, skipped, fmt.Errorf("文件 %s 超过 %d MiB", file.Path, maxImportFileBytes>>20)
		}
		total += int64(len(body))
		if total > maxImportTotalBytes {
			return count, total, skipped, errors.New("导入内容超过总量上限")
		}
		destination := filepath.Join(staging, name)
		if err := os.MkdirAll(filepath.Dir(destination), 0755); err != nil {
			return count, total, skipped, err
		}
		mode := os.FileMode(0644)
		if file.Mode != "" {
			parsed, err := parseImportMode(file.Mode)
			if err != nil {
				return count, total, skipped, fmt.Errorf("文件 %s 的权限 %q 无效", file.Path, file.Mode)
			}
			mode = parsed
		} else if isLikelyScript(name) {
			mode = 0755
		}
		if err := os.WriteFile(destination, body, mode); err != nil {
			return count, total, skipped, err
		}
		// 面板单元是 UMask=0077，WriteFile 给的权限位会被削掉，显式补一次。
		if err := os.Chmod(destination, mode); err != nil {
			return count, total, skipped, err
		}
		count++
	}
	return count, total, skipped, nil
}

func parseImportMode(raw string) (os.FileMode, error) {
	value := strings.TrimPrefix(strings.TrimSpace(raw), "0o")
	if len(value) < 3 || len(value) > 4 {
		return 0, errors.New("invalid mode")
	}
	var mode os.FileMode
	if _, err := fmt.Sscanf(value, "%o", &mode); err != nil {
		return 0, err
	}
	if mode > 0777 {
		return 0, errors.New("invalid mode")
	}
	return mode, nil
}

// isLikelyScript 给散装上传的脚本默认带上可执行位：AI 上传一个 start.sh，
// 用户点启动却发现「权限不够」会很难解释。
func isLikelyScript(name string) bool {
	base := pathpkg.Base(name)
	if strings.HasSuffix(base, ".sh") || strings.HasSuffix(base, ".bash") {
		return true
	}
	if !strings.Contains(base, ".") && base != "" {
		return true
	}
	return false
}

// archiveEntryName 把压缩包里的名字清洗成一个安全的相对路径。
func archiveEntryName(raw string) (string, bool) {
	name := strings.ReplaceAll(raw, "\\", "/")
	cleaned := pathpkg.Clean(name)
	if cleaned == "." || cleaned == "" || cleaned == ".." ||
		strings.HasPrefix(cleaned, "../") || pathpkg.IsAbs(cleaned) ||
		strings.ContainsRune(cleaned, 0) {
		return "", false
	}
	// 系统生成的垃圾条目，留着只会污染工程目录。
	if strings.HasPrefix(cleaned, "__MACOSX/") || pathpkg.Base(cleaned) == ".DS_Store" {
		return "", false
	}
	for _, part := range strings.Split(cleaned, "/") {
		if part == ".." {
			return "", false
		}
	}
	return cleaned, true
}

// extractArchive 按魔数识别格式后解压。返回文件数、字节数与被跳过的条目。
func extractArchive(payload []byte, destination string) (int, int64, []string, error) {
	switch {
	case len(payload) >= 4 && payload[0] == 'P' && payload[1] == 'K':
		return extractZip(payload, destination)
	case len(payload) >= 2 && payload[0] == 0x1f && payload[1] == 0x8b:
		reader, err := gzip.NewReader(bytes.NewReader(payload))
		if err != nil {
			return 0, 0, nil, err
		}
		defer reader.Close()
		return extractTar(reader, destination)
	default:
		// 没压缩的 tar 也能收（tar.gz 才是常态，但没必要为此报错）。
		return extractTar(bytes.NewReader(payload), destination)
	}
}

func extractZip(payload []byte, destination string) (int, int64, []string, error) {
	archive, err := zip.NewReader(bytes.NewReader(payload), int64(len(payload)))
	if err != nil {
		return 0, 0, nil, fmt.Errorf("压缩包无法读取：%w", err)
	}
	if len(archive.File) > maxImportEntries {
		return 0, 0, nil, errors.New("压缩包里的文件太多")
	}
	var count int
	var total int64
	var skipped []string
	for _, entry := range archive.File {
		name, ok := archiveEntryName(entry.Name)
		if !ok {
			skipped = append(skipped, entry.Name)
			continue
		}
		mode := entry.Mode()
		if mode&os.ModeSymlink != 0 {
			skipped = append(skipped, entry.Name)
			continue
		}
		target := filepath.Join(destination, name)
		if entry.FileInfo().IsDir() || strings.HasSuffix(entry.Name, "/") {
			if err := os.MkdirAll(target, 0755); err != nil {
				return count, total, skipped, err
			}
			continue
		}
		if int64(entry.UncompressedSize64) > maxImportFileBytes {
			return count, total, skipped, fmt.Errorf("压缩包里的 %s 过大", entry.Name)
		}
		if total+int64(entry.UncompressedSize64) > maxImportTotalBytes {
			return count, total, skipped, errors.New("解压后体积超过上限")
		}
		source, err := entry.Open()
		if err != nil {
			return count, total, skipped, err
		}
		written, err := writeArchiveFile(target, source, mode)
		_ = source.Close()
		if err != nil {
			return count, total, skipped, err
		}
		total += written
		count++
	}
	return count, total, skipped, nil
}

func extractTar(reader io.Reader, destination string) (int, int64, []string, error) {
	archive := tar.NewReader(reader)
	var count int
	var total int64
	var skipped []string
	for {
		header, err := archive.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return count, total, skipped, fmt.Errorf("压缩包无法读取：%w", err)
		}
		name, ok := archiveEntryName(header.Name)
		if !ok {
			skipped = append(skipped, header.Name)
			continue
		}
		target := filepath.Join(destination, name)
		switch header.Typeflag {
		case tar.TypeDir:
			if count+len(skipped) > maxImportEntries {
				return count, total, skipped, errors.New("压缩包里的文件太多")
			}
			if err := os.MkdirAll(target, 0755); err != nil {
				return count, total, skipped, err
			}
		case tar.TypeReg:
			if header.Size > maxImportFileBytes {
				return count, total, skipped, fmt.Errorf("压缩包里的 %s 过大", header.Name)
			}
			if total+header.Size > maxImportTotalBytes {
				return count, total, skipped, errors.New("解压后体积超过上限")
			}
			written, err := writeArchiveFile(target, archive, os.FileMode(header.Mode))
			if err != nil {
				return count, total, skipped, err
			}
			total += written
			count++
		default:
			// 软链接、硬链接、设备文件一律不进工程目录：解压出来的链接可以被用来
			// 指向目录树之外，工程本身也不需要它们。
			skipped = append(skipped, header.Name)
		}
		if count > maxImportEntries {
			return count, total, skipped, errors.New("压缩包里的文件太多")
		}
	}
	return count, total, skipped, nil
}

// writeArchiveFile 落一个文件，并保证写入量不超过它声称的大小。
func writeArchiveFile(target string, source io.Reader, mode os.FileMode) (int64, error) {
	permission := os.FileMode(0644)
	if mode.Perm() != 0 {
		permission = mode.Perm()
	}
	if err := os.MkdirAll(filepath.Dir(target), 0755); err != nil {
		return 0, err
	}
	file, err := os.OpenFile(target, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, permission)
	if err != nil {
		return 0, err
	}
	defer file.Close()
	written, err := io.Copy(file, io.LimitReader(source, maxImportFileBytes+1))
	if err != nil {
		return written, err
	}
	if written > maxImportFileBytes {
		return written, errors.New("解压出的单个文件超过上限")
	}
	if err := file.Chmod(permission); err != nil {
		return written, err
	}
	return written, nil
}

// importHandler 处理 POST /v1/projects/import。
//
// 两种传法：整个 body 是压缩包（curl --data-binary @x.tar.gz），
// 或者 body 是 JSON（带 archive_base64 或 files）。用 Content-Type 区分。
func (a *api) importHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if a.projects == nil {
		http.Error(w, "projects unavailable", http.StatusServiceUnavailable)
		return
	}
	query := r.URL.Query()
	spec := projectImport{
		ID:           query.Get("id"),
		Name:         query.Get("name"),
		Runtime:      query.Get("runtime"),
		Entry:        query.Get("entry"),
		Overwrite:    query.Get("overwrite") == "true",
		Start:        query.Get("start") == "true",
		UseVenv:      query.Get("use_venv") == "true",
		PythonServer: query.Get("python_server"),
		EnvFile:      query.Get("env_file") == "true",
	}
	if raw := query.Get("port"); raw != "" {
		value, err := strconv.Atoi(raw)
		if err != nil || value < 0 || value > 65535 {
			http.Error(w, "端口须在 0 至 65535 之间", http.StatusBadRequest)
			return
		}
		spec.Port = value
	}
	var archive []byte
	if strings.Contains(r.Header.Get("Content-Type"), "application/json") {
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 512<<20)).Decode(&spec); err != nil {
			http.Error(w, "导入参数无效", http.StatusBadRequest)
			return
		}
	} else {
		limited := http.MaxBytesReader(w, r.Body, maxImportArchiveBytes+1)
		body, err := io.ReadAll(limited)
		if err != nil {
			http.Error(w, "读取上传内容失败，或压缩包超过上限", http.StatusRequestEntityTooLarge)
			return
		}
		archive = body
	}
	if spec.Port == 0 {
		if ports, err := a.projects.freePorts(r.Context(), 0, 1); err == nil && len(ports) > 0 {
			spec.Port = ports[0]
		}
	}
	// 解压 + 建项目可能跑一会儿（依赖还是另一步），给足超时。
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Minute)
	defer cancel()
	result, err := a.projects.importProject(ctx, spec, archive)
	if err != nil {
		http.Error(w, err.Error(), http.StatusConflict)
		return
	}
	sort.Strings(result.Skipped)
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(http.StatusCreated)
	_ = json.NewEncoder(w).Encode(result)
}
