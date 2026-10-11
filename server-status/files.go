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

func (fm *fileManager) owner() (int, int, error) {
	if fm.projectOwner != nil {
		return fm.projectOwner()
	}
	return ensureProjectUser()
}

type fileEntry struct {
	Name        string `json:"name"`
	Path        string `json:"path"`
	Kind        string `json:"kind"`
	Permissions string `json:"permissions"`
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
	const prefix = "/www/seraphim/projects/"
	if !strings.HasPrefix(path, prefix) {
		return false
	}
	rest := strings.TrimPrefix(path, prefix)
	parts := strings.SplitN(rest, "/", 2)
	if len(parts) != 2 || !projectIDPattern.MatchString(parts[0]) {
		return false
	}
	marker := "www/seraphim/projects/" + parts[0] + "/.sera-project.json"
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

func fileError(w http.ResponseWriter, err error) {
	code := http.StatusInternalServerError
	switch {
	case errors.Is(err, errInvalidFilePath), errors.Is(err, errSymlinkPath), errors.Is(err, errProtectedPath), errors.Is(err, syscall.ENOTDIR):
		code = http.StatusBadRequest
	case errors.Is(err, os.ErrNotExist):
		code = http.StatusNotFound
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
		result.Entries = append(result.Entries, fileEntry{
			Name: item.Name(), Path: childPath, Kind: fileKind(info),
			Permissions: fmt.Sprintf("%04o", info.Mode().Perm()),
			SizeBytes:   info.Size(), ModifiedAt: info.ModTime().UTC().Format(time.RFC3339),
		})
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
