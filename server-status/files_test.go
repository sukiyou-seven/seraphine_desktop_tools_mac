package main

import (
	"bytes"
	"encoding/json"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
)

func TestFileAPIAuthAndOperations(t *testing.T) {
	dir := t.TempDir()
	root, err := os.OpenRoot(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer root.Close()
	if err := root.Mkdir("work", 0700); err != nil {
		t.Fatal(err)
	}
	a := &api{token: strings.Repeat("a", 64), files: &fileManager{root: root}}
	request := func(method, target string, body []byte, authorized bool) *httptest.ResponseRecorder {
		t.Helper()
		r := httptest.NewRequest(method, target, bytes.NewReader(body))
		if authorized {
			r.Header.Set("Authorization", "Bearer "+a.token)
		}
		w := httptest.NewRecorder()
		if strings.HasPrefix(target, "/v1/files/content") {
			a.fileContentHandler(w, r)
		} else {
			a.filesHandler(w, r)
		}
		return w
	}
	if got := request("GET", "/v1/files?path=%2Fwork", nil, false).Code; got != 401 {
		t.Fatalf("unauthorized file API returned %d", got)
	}
	if got := request("PUT", "/v1/files/content?path=%2Fwork%2Fa.txt", []byte("first"), true).Code; got != 204 {
		t.Fatalf("upload returned %d", got)
	}
	touch, _ := json.Marshal(fileCommand{Operation: "touch", Path: "/work/empty.txt"})
	if got := request("POST", "/v1/files", touch, true).Code; got != 204 {
		t.Fatalf("new empty file returned %d", got)
	}
	if got := request("PUT", "/v1/files/content?path=%2Fwork%2Fa.txt", []byte("second"), true).Code; got != 409 {
		t.Fatalf("upload without overwrite returned %d", got)
	}
	if got := request("PUT", "/v1/files/content?path=%2Fwork%2Fa.txt&overwrite=true", []byte("second"), true).Code; got != 204 {
		t.Fatalf("upload overwrite returned %d", got)
	}
	listing := request("GET", "/v1/files?path=%2Fwork", nil, true)
	var data fileListing
	if err := json.Unmarshal(listing.Body.Bytes(), &data); err != nil {
		t.Fatal(err)
	}
	if listing.Code != 200 || len(data.Entries) != 2 || data.Entries[0].Name != "a.txt" || data.Entries[0].Kind != "file" {
		t.Fatalf("unexpected listing: %d %+v", listing.Code, data)
	}
	if data.Entries[0].Permissions != "0644" {
		t.Fatalf("listing permissions: %+v", data.Entries[0])
	}
	chmod, _ := json.Marshal(fileCommand{Operation: "chmod", Path: "/work/a.txt", Permissions: "0755"})
	if got := request("POST", "/v1/files", chmod, true).Code; got != 204 {
		t.Fatalf("chmod returned %d", got)
	}
	info, err := os.Stat(filepath.Join(dir, "work/a.txt"))
	if err != nil || info.Mode().Perm() != 0755 {
		t.Fatalf("chmod mode: %v %v", info, err)
	}
	badMode, _ := json.Marshal(fileCommand{Operation: "chmod", Path: "/work/a.txt", Permissions: "4755"})
	if got := request("POST", "/v1/files", badMode, true).Code; got != 400 {
		t.Fatalf("unsafe chmod returned %d", got)
	}
	if got := request("GET", "/v1/files/content?path=%2Fwork%2Fa.txt", nil, true); got.Code != 200 || got.Body.String() != "second" {
		t.Fatalf("download returned %d %q", got.Code, got.Body.String())
	}
	rename, _ := json.Marshal(fileCommand{Operation: "rename", Path: "/work/a.txt", Destination: "/work/b.txt"})
	if got := request("POST", "/v1/files", rename, true).Code; got != 204 {
		t.Fatalf("rename returned %d", got)
	}
	mkdir, _ := json.Marshal(fileCommand{Operation: "mkdir", Path: "/work/sub"})
	if got := request("POST", "/v1/files", mkdir, true).Code; got != 204 {
		t.Fatalf("mkdir returned %d", got)
	}
	if got := request("PUT", "/v1/files/content?path=%2Fwork%2Fsub%2Fc.txt", []byte("c"), true).Code; got != 204 {
		t.Fatalf("nested upload returned %d", got)
	}
	if got := request("PUT", "/v1/files/content?path=%2Fwork%2Fb.txt&overwrite=true", []byte("third"), true).Code; got != 204 {
		t.Fatalf("overwrite executable returned %d", got)
	}
	info, err = os.Stat(filepath.Join(dir, "work/b.txt"))
	if err != nil || info.Mode().Perm() != 0755 {
		t.Fatalf("overwrite mode: %v %v", info, err)
	}
	if got := request("DELETE", "/v1/files?path=%2Fwork%2Fsub", nil, true).Code; got != 409 {
		t.Fatalf("non-recursive delete returned %d", got)
	}
	if got := request("DELETE", "/v1/files?path=%2Fwork%2Fsub&recursive=true", nil, true).Code; got != 204 {
		t.Fatalf("recursive delete returned %d", got)
	}
	if got := request("DELETE", "/v1/files?path=%2Fwork%2Fb.txt", nil, true).Code; got != 204 {
		t.Fatalf("file delete returned %d", got)
	}
}

func TestWebsiteUploadsRemainReadableWithServiceUmask(t *testing.T) {
	dir := t.TempDir()
	website := filepath.Join(dir, "www/seraphim/web/nginx/example.com")
	if err := os.MkdirAll(website, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(dir, "work"), 0755); err != nil {
		t.Fatal(err)
	}
	root, err := os.OpenRoot(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer root.Close()
	previousUmask := syscall.Umask(0077)
	defer syscall.Umask(previousUmask)
	a := &api{token: "secret", files: &fileManager{root: root}}
	request := func(method, target string, body []byte) int {
		r := httptest.NewRequest(method, target, bytes.NewReader(body))
		r.Header.Set("Authorization", "Bearer secret")
		w := httptest.NewRecorder()
		if strings.HasPrefix(target, "/v1/files/content") {
			a.fileContentHandler(w, r)
		} else {
			a.filesHandler(w, r)
		}
		return w.Code
	}
	assets, _ := json.Marshal(fileCommand{Operation: "mkdir", Path: "/www/seraphim/web/nginx/example.com/assets"})
	if code := request("POST", "/v1/files", assets); code != 204 {
		t.Fatalf("mkdir: %d", code)
	}
	indexPath := "/v1/files/content?path=%2Fwww%2Fseraphim%2Fweb%2Fnginx%2Fexample.com%2Findex.html"
	if code := request("PUT", indexPath, []byte("hello")); code != 204 {
		t.Fatalf("upload: %d", code)
	}
	if code := request("PUT", indexPath+"&overwrite=true", []byte("updated")); code != 204 {
		t.Fatalf("overwrite: %d", code)
	}
	robots, _ := json.Marshal(fileCommand{Operation: "touch", Path: "/www/seraphim/web/nginx/example.com/robots.txt"})
	if code := request("POST", "/v1/files", robots); code != 204 {
		t.Fatalf("touch: %d", code)
	}
	for name, want := range map[string]os.FileMode{
		"assets": 0755, "index.html": 0644, "robots.txt": 0644,
	} {
		info, err := os.Stat(filepath.Join(website, name))
		if err != nil || info.Mode().Perm() != want {
			t.Errorf("%s mode: %v, %v; want %o", name, info, err, want)
		}
	}
	workDir, _ := json.Marshal(fileCommand{Operation: "mkdir", Path: "/work/sub"})
	if code := request("POST", "/v1/files", workDir); code != 204 {
		t.Fatalf("ordinary mkdir: %d", code)
	}
	if code := request("PUT", "/v1/files/content?path=%2Fwork%2Fsub%2Fnote.txt", []byte("note")); code != 204 {
		t.Fatalf("ordinary upload: %d", code)
	}
	for name, want := range map[string]os.FileMode{"sub": 0755, "sub/note.txt": 0644} {
		info, err := os.Stat(filepath.Join(dir, "work", name))
		if err != nil || info.Mode().Perm() != want {
			t.Errorf("ordinary %s mode: %v, %v; want %o", name, info, err, want)
		}
	}
}

func TestFileAPIRejectsTraversalAndProtectedPaths(t *testing.T) {
	dir := t.TempDir()
	root, err := os.OpenRoot(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer root.Close()
	if err := root.Mkdir("work", 0700); err != nil {
		t.Fatal(err)
	}
	outside := t.TempDir()
	if err := os.WriteFile(filepath.Join(outside, "secret"), []byte("secret"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(dir, "work", "link")); err != nil {
		t.Fatal(err)
	}
	a := &api{token: strings.Repeat("b", 64), files: &fileManager{root: root}}
	for _, target := range []string{
		"/v1/files?path=%2Fwork%2F..%2F..%2Fsecret",
		"/v1/files?path=%2Fwork%2Flink",
		"/v1/files/content?path=%2Fwork%2Flink%2Fsecret",
	} {
		r := httptest.NewRequest("GET", target, nil)
		r.Header.Set("Authorization", "Bearer "+a.token)
		w := httptest.NewRecorder()
		if strings.HasPrefix(target, "/v1/files/content") {
			a.fileContentHandler(w, r)
		} else {
			a.filesHandler(w, r)
		}
		if w.Code != 400 {
			t.Fatalf("unsafe path %q returned %d", target, w.Code)
		}
	}
	chmodSymlink, _ := json.Marshal(fileCommand{Operation: "chmod", Path: "/work/link", Permissions: "0777"})
	r := httptest.NewRequest("POST", "/v1/files", bytes.NewReader(chmodSymlink))
	r.Header.Set("Authorization", "Bearer "+a.token)
	w := httptest.NewRecorder()
	a.filesHandler(w, r)
	if w.Code != 400 {
		t.Fatalf("symlink chmod returned %d", w.Code)
	}
	r = httptest.NewRequest("DELETE", "/v1/files?path=%2F", nil)
	r.Header.Set("Authorization", "Bearer "+a.token)
	w = httptest.NewRecorder()
	a.filesHandler(w, r)
	if w.Code != 400 {
		t.Fatalf("root delete returned %d", w.Code)
	}
	// Ensure the test actually exercised a symlink to an outside file.
	if content, err := os.ReadFile(filepath.Join(outside, "secret")); err != nil || string(content) != "secret" {
		t.Fatal("outside file unexpectedly changed")
	}
}

func TestManagedProjectFileUploadPermissions(t *testing.T) {
	dir := t.TempDir()
	projectDir := filepath.Join(dir, "www/seraphim/projects/demo")
	if err := os.MkdirAll(projectDir, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(projectDir, ".sera-project.json"), []byte("{}"), 0644); err != nil {
		t.Fatal(err)
	}
	root, err := os.OpenRoot(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer root.Close()
	a := &api{token: "secret", files: &fileManager{root: root,
		projectOwner: func() (int, int, error) { return os.Getuid(), os.Getgid(), nil }}}
	request := func(method, target string, body []byte) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, target, bytes.NewReader(body))
		r.Header.Set("Authorization", "Bearer secret")
		w := httptest.NewRecorder()
		if strings.HasPrefix(target, "/v1/files/content") {
			a.fileContentHandler(w, r)
		} else {
			a.filesHandler(w, r)
		}
		return w
	}
	mkdir, _ := json.Marshal(fileCommand{Operation: "mkdir", Path: "/www/seraphim/projects/demo/src"})
	if got := request("POST", "/v1/files", mkdir).Code; got != 204 {
		t.Fatalf("mkdir: %d", got)
	}
	data := []byte("print('hello')\n")
	if got := request("PUT", "/v1/files/content?path=%2Fwww%2Fseraphim%2Fprojects%2Fdemo%2Fsrc%2Fmain.py", data).Code; got != 204 {
		t.Fatalf("upload: %d", got)
	}
	info, err := os.Stat(filepath.Join(projectDir, "src"))
	if err != nil || info.Mode().Perm() != 0750 {
		t.Fatalf("directory mode: %v %v", info, err)
	}
	info, err = os.Stat(filepath.Join(projectDir, "src/main.py"))
	if err != nil || info.Mode().Perm() != 0600 {
		t.Fatalf("file mode: %v %v", info, err)
	}
	if content, err := os.ReadFile(filepath.Join(projectDir, "src/main.py")); err != nil || !bytes.Equal(content, data) {
		t.Fatalf("content: %q %v", content, err)
	}
}
