package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime"
	"net/http"
	"os"
	pathpkg "path"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

const maxUploadBytes int64 = 2 << 30

var errInvalidFilePath = errors.New("invalid file path")
var errSymlinkPath = errors.New("symbolic links cannot be traversed")
var errProtectedPath = errors.New("protected directory cannot be changed")

type fileManager struct {
	root         *os.Root
	mu           sync.Mutex
	projectOwner func() (int, int, error)
}

// managedProjectID 从工程目录内的绝对路径取出所属项目标识。
func managedProjectID(path string) string {
	const prefix = "/www/seraphim/projects/"
	if !strings.HasPrefix(path, prefix) {
		return ""
	}
	parts := strings.SplitN(strings.TrimPrefix(path, prefix), "/", 2)
	if len(parts) != 2 || !projectIDPattern.MatchString(parts[0]) {
		return ""
	}
	return parts[0]
}

// owner 返回工程目录内新建内容应属的运行账户。面板把项目统一交给共享的 sera
// 运行，所以这里不再按项目区分解算；调用方仍需自行确认路径确属工程目录。
func (fm *fileManager) owner() (int, int, error) {
	if fm.projectOwner != nil {
		return fm.projectOwner()
	}
	return ensureSharedAccount()
}

type fileEntry struct {
	Name        string `json:"name"`
	Path        string `json:"path"`
	Kind        string `json:"kind"`
	Permissions string `json:"permissions"`
	Owner       string `json:"owner"`
	Group       string `json:"group"`
	UID         int    `json:"uid"`
	GID         int    `json:"gid"`
	SizeBytes   int64  `json:"size_bytes"`
	ModifiedAt  string `json:"modified_at"`
}

type fileListing struct {
	Path    string      `json:"path"`
	Parent  string      `json:"parent"`
	Entries []fileEntry `json:"entries"`
}

type fileCommand struct {
	Operation   string `json:"operation"`
	Path        string `json:"path"`
	Destination string `json:"destination"`
	Overwrite   bool   `json:"overwrite"`
	Permissions string `json:"permissions"`
	Owner       string `json:"owner"`
	Group       string `json:"group"`
	Recursive   bool   `json:"recursive"`
}

// API paths are absolute for the client. os.Root receives names relative to
// -files-root, which defaults to the server's entire filesystem.
func filePath(raw string) (string, string, error) {
	if raw == "" || raw[0] != '/' || strings.ContainsRune(raw, 0) {
		return "", "", errInvalidFilePath
	}
	for _, part := range strings.Split(raw, "/") {
		if part == ".." { // Do not silently change the path the user selected.
			return "", "", errInvalidFilePath
		}
	}
	clean := pathpkg.Clean(raw)
	name := strings.TrimPrefix(clean, "/")
	if name == "" {
		name = "."
	}
	return clean, name, nil
}

func protectedFilePath(path string) bool {
	if path == "/" || path == "/www/seraphim" {
		return true
	}
	switch path {
	case "/www/seraphim/server", "/www/seraphim/web", "/www/seraphim/projects", "/www/seraphim/download",
		"/www/seraphim/backup", "/www/seraphim/logs":
		return true
	}
	// A single operation must not erase an entire top-level system directory.
	switch path {
	case "/bin", "/boot", "/dev", "/etc", "/home", "/lib", "/lib64", "/opt",
		"/proc", "/root", "/run", "/sbin", "/srv", "/sys", "/tmp", "/usr",
		"/var", "/www":
		return true
	}
	return false
}

// Files under the managed website tree must be readable by the Web server
// worker. The API service runs with a restrictive umask, so creation modes
// alone are insufficient; callers must chmod newly created entries.
func publicWebPath(path string) bool {
	return strings.HasPrefix(path, "/www/seraphim/web/")
}

func (fm *fileManager) managedProjectPath(path string) bool {
	id := managedProjectID(path)
	if id == "" {
		return false
	}
	marker := "www/seraphim/projects/" + id + "/.sera-project.json"
	info, err := fm.root.Lstat(marker)
	return err == nil && info.Mode().IsRegular()
}

func (fm *fileManager) checkSymlinks(name string, includeFinal bool) error {
	if name == "." {
		return nil
	}
	parts := strings.Split(name, "/")
	end := len(parts)
	if !includeFinal {
		end--
	}
	for i := 0; i < end; i++ {
		info, err := fm.root.Lstat(strings.Join(parts[:i+1], "/"))
		if err != nil {
			return err
		}
		if info.Mode()&os.ModeSymlink != 0 {
			return errSymlinkPath
		}
	}
	return nil
}

func fileKind(info os.FileInfo) string {
	if info.IsDir() {
		return "directory"
	}
	if info.Mode().IsRegular() {
		return "file"
	}
	if info.Mode()&os.ModeSymlink != 0 {
		return "symlink"
	}
	return "other"
}

// entryOwnership 取出条目的属主。软链接取的是链接自身（Lstat）而不是目标。
func entryOwnership(info os.FileInfo) (int, int, bool) {
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return 0, 0, false
	}
	return int(stat.Uid), int(stat.Gid), true
}

func fileError(w http.ResponseWriter, err error) {
	code := http.StatusInternalServerError
	switch {
	case errors.Is(err, errInvalidFilePath), errors.Is(err, errSymlinkPath), errors.Is(err, errProtectedPath), errors.Is(err, syscall.ENOTDIR):
		code = http.StatusBadRequest
	case errors.Is(err, os.ErrNotExist):
		code = http.StatusNotFound
	case errors.Is(err, errUnknownAccount):
		code = http.StatusUnprocessableEntity
	case errors.Is(err, os.ErrPermission):
		code = http.StatusForbidden
	case errors.Is(err, os.ErrExist), errors.Is(err, syscall.ENOTEMPTY), errors.Is(err, syscall.EISDIR):
		code = http.StatusConflict
	}
	http.Error(w, http.StatusText(code), code)
}

func (a *api) filesHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	if !a.authorized(r) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	switch r.Method {
	case http.MethodGet:
		a.files.list(w, r)
	case http.MethodPost:
		a.files.command(w, r)
	case http.MethodDelete:
		a.files.delete(w, r)
	default:
		w.Header().Set("Allow", "GET, POST, DELETE")
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

func (a *api) fileContentHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	if !a.authorized(r) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	switch r.Method {
	case http.MethodGet:
		a.files.download(w, r)
	case http.MethodPut:
		a.files.upload(w, r)
	default:
		w.Header().Set("Allow", "GET, PUT")
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

func (fm *fileManager) list(w http.ResponseWriter, r *http.Request) {
	path, name, err := filePath(r.URL.Query().Get("path"))
	if err == nil {
		err = fm.checkSymlinks(name, true)
	}
	if err != nil {
		fileError(w, err)
		return
	}
	dir, err := fm.root.Open(name)
	if err != nil {
		fileError(w, err)
		return
	}
	defer dir.Close()
	infos, err := dir.ReadDir(-1)
	if err != nil {
		fileError(w, err)
		return
	}
	result := fileListing{Path: path, Parent: pathpkg.Dir(path), Entries: make([]fileEntry, 0, len(infos))}
	// 属主名称按一次快照解析，避免每个条目都去读 /etc/passwd。
	snapshot := accounts(false)
	for _, item := range infos {
		childPath := pathpkg.Join(path, item.Name())
		_, childName, err := filePath(childPath)
		if err != nil {
			continue
		}
		info, err := fm.root.Lstat(childName)
		if err != nil { // A file may disappear while listing.
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
		result.Entries = append(result.Entries, entry)
	}
	sort.Slice(result.Entries, func(i, j int) bool {
		left, right := result.Entries[i], result.Entries[j]
		if (left.Kind == "directory") != (right.Kind == "directory") {
			return left.Kind == "directory"
		}
		return strings.ToLower(left.Name) < strings.ToLower(right.Name)
	})
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	_ = json.NewEncoder(w).Encode(result)
}

func (fm *fileManager) command(w http.ResponseWriter, r *http.Request) {
	var command fileCommand
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 16<<10)).Decode(&command); err != nil {
		fileError(w, errInvalidFilePath)
		return
	}
	path, name, err := filePath(command.Path)
	if err != nil || path == "/" {
		fileError(w, errInvalidFilePath)
		return
	}
	fm.mu.Lock()
	defer fm.mu.Unlock()
	switch command.Operation {
	case "mkdir":
		if err := fm.checkSymlinks(name, false); err != nil {
			fileError(w, err)
			return
		}
		err = fm.root.Mkdir(name, 0755)
		if err == nil && !fm.managedProjectPath(path) {
			var directory *os.File
			directory, err = fm.root.Open(name)
			if err == nil {
				err = directory.Chmod(0755)
				_ = directory.Close()
			}
			if err != nil {
				_ = fm.root.Remove(name)
			}
		}
		if err == nil && fm.managedProjectPath(path) {
			var uid, gid int
			uid, gid, err = fm.owner()
			if err == nil {
				var directory *os.File
				directory, err = fm.root.Open(name)
				if err == nil {
					err = directory.Chown(uid, gid)
					if err == nil {
						err = directory.Chmod(0750)
					}
					_ = directory.Close()
				}
			}
			if err != nil {
				_ = fm.root.Remove(name)
			}
		}
	case "touch":
		if err := fm.checkSymlinks(name, false); err != nil {
			fileError(w, err)
			return
		}
		file, openErr := fm.root.OpenFile(name, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
		if openErr == nil {
			if !fm.managedProjectPath(path) {
				err = file.Chmod(0644)
			}
			if closeErr := file.Close(); err == nil {
				err = closeErr
			}
			if err != nil {
				_ = fm.root.Remove(name)
			}
		} else {
			err = openErr
		}
	case "chmod":
		if protectedFilePath(path) || len(command.Permissions) < 3 || len(command.Permissions) > 4 {
			fileError(w, errInvalidFilePath)
			return
		}
		mode, parseErr := strconv.ParseUint(command.Permissions, 8, 16)
		if parseErr != nil || mode > 0777 {
			fileError(w, errInvalidFilePath)
			return
		}
		if err := fm.checkSymlinks(name, true); err != nil {
			fileError(w, err)
			return
		}
		var file *os.File
		file, err = fm.root.OpenFile(name, os.O_RDONLY|syscall.O_NOFOLLOW, 0)
		if err == nil {
			var info os.FileInfo
			info, err = file.Stat()
			if err == nil && !info.IsDir() && !info.Mode().IsRegular() {
				err = errInvalidFilePath
			}
			if err == nil {
				err = file.Chmod(os.FileMode(mode))
			}
			_ = file.Close()
		}
	case "chown":
		if protectedFilePath(path) {
			fileError(w, errProtectedPath)
			return
		}
		if err := fm.checkSymlinks(name, true); err != nil {
			fileError(w, err)
			return
		}
		info, statErr := fm.root.Lstat(name)
		if statErr != nil {
			fileError(w, statErr)
			return
		}
		if info.Mode()&os.ModeSymlink != 0 || (!info.IsDir() && !info.Mode().IsRegular()) {
			fileError(w, errInvalidFilePath)
			return
		}
		var uid, gid int
		uid, gid, err = resolveOwnership(command.Owner, command.Group)
		if err != nil {
			fileError(w, err)
			return
		}
		if command.Recursive && info.IsDir() {
			err = fm.chownWithin(name, uid, gid)
		} else {
			err = fm.chownEntry(name, uid, gid, false)
		}
	case "rename":
		if protectedFilePath(path) {
			fileError(w, errProtectedPath)
			return
		}
		destination, target, pathErr := filePath(command.Destination)
		if pathErr != nil || destination == "/" || protectedFilePath(destination) {
			fileError(w, errInvalidFilePath)
			return
		}
		if err := fm.checkSymlinks(name, false); err != nil {
			fileError(w, err)
			return
		}
		if err := fm.checkSymlinks(target, false); err != nil {
			fileError(w, err)
			return
		}
		if path == destination {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		sourceInfo, statErr := fm.root.Lstat(name)
		if statErr != nil {
			fileError(w, statErr)
			return
		}
		if targetInfo, statErr := fm.root.Lstat(target); statErr == nil {
			if !command.Overwrite || !sourceInfo.Mode().IsRegular() || !targetInfo.Mode().IsRegular() {
				fileError(w, os.ErrExist)
				return
			}
		} else if !errors.Is(statErr, os.ErrNotExist) {
			fileError(w, statErr)
			return
		}
		err = fm.root.Rename(name, target)
	default:
		fileError(w, errInvalidFilePath)
		return
	}
	if err != nil {
		fileError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// chownEntry 把单个条目改属。uid 或 gid 为 -1 表示保持原值。
//
// skipMetadata 为真时跳过面板自己的元数据文件（工程标记与账户标记）：它们记录
// 项目归属，交给业务账户后项目进程就能改写自己的身份配置。
func (fm *fileManager) chownEntry(name string, uid, gid int, skipMetadata bool) error {
	if skipMetadata && isPanelMetadata(pathpkg.Base(name)) {
		return nil
	}
	info, err := fm.root.Lstat(name)
	if err != nil {
		return err
	}
	// 不跟随也不修改软链接本身，避免把目录树之外的目标改掉。
	if info.Mode()&os.ModeSymlink != 0 {
		return nil
	}
	if stat, ok := info.Sys().(*syscall.Stat_t); ok {
		if (uid < 0 || int(stat.Uid) == uid) && (gid < 0 || int(stat.Gid) == gid) {
			return nil // 已经是目标归属，省掉一次系统调用。
		}
	}
	return fm.root.Chown(name, uid, gid)
}

// chownWithin 递归改属 name 及其全部子项。顶层条目是用户显式选中的，不做任何跳过。
func (fm *fileManager) chownWithin(name string, uid, gid int) error {
	if err := fm.chownEntry(name, uid, gid, false); err != nil {
		return err
	}
	return fm.chownSubtree(name, uid, gid)
}

// chownSubtree 改属目录下的内容，始终留在文件 API 的根目录内。
func (fm *fileManager) chownSubtree(name string, uid, gid int) error {
	info, err := fm.root.Lstat(name)
	if err != nil || !info.IsDir() {
		return err
	}
	directory, err := fm.root.Open(name)
	if err != nil {
		return err
	}
	entries, err := directory.ReadDir(-1)
	_ = directory.Close()
	if err != nil {
		return err
	}
	for _, entry := range entries {
		childInfo, err := entry.Info()
		if err != nil {
			return err
		}
		if childInfo.Mode()&os.ModeSymlink != 0 {
			continue
		}
		child := pathpkg.Join(name, entry.Name())
		if err := fm.chownEntry(child, uid, gid, true); err != nil {
			return err
		}
		if childInfo.IsDir() {
			if err := fm.chownSubtree(child, uid, gid); err != nil {
				return err
			}
		}
	}
	return nil
}

// isPanelMetadata 判断是否为面板自己维护的元数据文件。
func isPanelMetadata(name string) bool {
	return name == ".sera-project.json" || name == projectAccountMarker
}

func (fm *fileManager) delete(w http.ResponseWriter, r *http.Request) {
	path, name, err := filePath(r.URL.Query().Get("path"))
	if err != nil || protectedFilePath(path) {
		fileError(w, errProtectedPath)
		return
	}
	fm.mu.Lock()
	defer fm.mu.Unlock()
	if err := fm.checkSymlinks(name, false); err != nil {
		fileError(w, err)
		return
	}
	if r.URL.Query().Get("recursive") == "true" {
		_, err = fm.root.Lstat(name)
		if err == nil {
			err = fm.root.RemoveAll(name)
		}
	} else {
		err = fm.root.Remove(name)
	}
	if err != nil {
		fileError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (fm *fileManager) download(w http.ResponseWriter, r *http.Request) {
	path, name, err := filePath(r.URL.Query().Get("path"))
	if err == nil {
		err = fm.checkSymlinks(name, true)
	}
	if err != nil {
		fileError(w, err)
		return
	}
	info, err := fm.root.Lstat(name)
	if err != nil {
		fileError(w, err)
		return
	}
	if !info.Mode().IsRegular() {
		fileError(w, errInvalidFilePath)
		return
	}
	file, err := fm.root.Open(name)
	if err != nil {
		fileError(w, err)
		return
	}
	defer file.Close()
	w.Header().Set("Content-Disposition", mime.FormatMediaType("attachment", map[string]string{"filename": pathpkg.Base(path)}))
	http.ServeContent(w, r, pathpkg.Base(path), info.ModTime(), file)
}

func (fm *fileManager) upload(w http.ResponseWriter, r *http.Request) {
	path, name, err := filePath(r.URL.Query().Get("path"))
	if err != nil || path == "/" {
		fileError(w, errInvalidFilePath)
		return
	}
	if r.ContentLength > maxUploadBytes {
		http.Error(w, "upload exceeds 2 GiB", http.StatusRequestEntityTooLarge)
		return
	}
	fm.mu.Lock()
	defer fm.mu.Unlock()
	if err := fm.checkSymlinks(name, false); err != nil {
		fileError(w, err)
		return
	}
	var existingInfo os.FileInfo
	if info, err := fm.root.Lstat(name); err == nil {
		if !info.Mode().IsRegular() || r.URL.Query().Get("overwrite") != "true" {
			fileError(w, os.ErrExist)
			return
		}
		existingInfo = info
	} else if !errors.Is(err, os.ErrNotExist) {
		fileError(w, err)
		return
	}
	temporary := pathpkg.Join(pathpkg.Dir(name), fmt.Sprintf(".sera-upload-%d", time.Now().UnixNano()))
	file, err := fm.root.OpenFile(temporary, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		fileError(w, err)
		return
	}
	defer fm.root.Remove(temporary)
	written, copyErr := io.Copy(file, io.LimitReader(r.Body, maxUploadBytes+1))
	if copyErr == nil {
		mode := os.FileMode(0644)
		if fm.managedProjectPath(path) {
			mode = 0600
		} else if existingInfo != nil && !publicWebPath(path) {
			mode = existingInfo.Mode().Perm()
		}
		copyErr = file.Chmod(mode)
	}
	if copyErr == nil && fm.managedProjectPath(path) {
		uid, gid, ownerErr := fm.owner()
		if ownerErr == nil {
			ownerErr = file.Chown(uid, gid)
		}
		copyErr = ownerErr
	} else if copyErr == nil && existingInfo != nil {
		if owner, ok := existingInfo.Sys().(*syscall.Stat_t); ok {
			copyErr = file.Chown(int(owner.Uid), int(owner.Gid))
		}
	}
	if copyErr == nil {
		copyErr = file.Sync()
	}
	if closeErr := file.Close(); copyErr == nil {
		copyErr = closeErr
	}
	if written > maxUploadBytes {
		http.Error(w, "upload exceeds 2 GiB", http.StatusRequestEntityTooLarge)
		return
	}
	if copyErr != nil {
		fileError(w, copyErr)
		return
	}
	if err := fm.root.Rename(temporary, name); err != nil {
		fileError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
