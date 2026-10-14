package main

import (
	"bytes"
	"encoding/json"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
)

func TestReadAccountsParsesBothPasswdShapes(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "accounts")
	content := "# comment\n\nalice:x:1001:1001::/home/alice:/bin/sh\nbroken:x:notanumber:1\ngroup_a:x:2001:\n\nbob:x:1002:1002::/home/bob:/bin/sh\n"
	if err := os.WriteFile(path, []byte(content), 0644); err != nil {
		t.Fatal(err)
	}
	byID, byName, err := readAccounts(path)
	if err != nil {
		t.Fatal(err)
	}
	if len(byID) != 3 || byID[1001] != "alice" || byID[2001] != "group_a" || byName["bob"] != 1002 {
		t.Fatalf("unexpected parse result: %v %v", byID, byName)
	}
	if _, ok := byName["broken"]; ok {
		t.Fatal("非数字 ID 的行应被跳过")
	}
	if _, _, err := readAccounts(filepath.Join(dir, "missing")); err == nil {
		t.Fatal("缺少文件时应返回错误")
	}
}

func TestAccountNamesFallsBackToNumeric(t *testing.T) {
	if _, err := loadAccounts(); err != nil {
		t.Skipf("此环境没有可读的账户表：%v", err)
	}
	snapshot := accounts(false)
	if snapshot == nil {
		t.Skip("账户快照不可用")
	}
	name, group := snapshot.names(os.Getuid(), os.Getgid())
	if name == "" || group == "" {
		t.Fatalf("账户名不应为空：%q %q", name, group)
	}
	// 一个几乎不可能存在的 ID 直接回退成数字，而不是空字符串。
	name, group = snapshot.names(4294000000, 4294000001)
	if name != "4294000000" || group != "4294000001" {
		t.Fatalf("未知 ID 应回退为数字：%q %q", name, group)
	}
	var missing *accountSnapshot
	if name, group := missing.names(7, 9); name != "7" || group != "9" {
		t.Fatalf("没有快照时应回退为数字：%q %q", name, group)
	}
}

func TestResolveOwnershipAcceptsNamesAndIDs(t *testing.T) {
	if accounts(false) == nil {
		t.Skip("账户快照不可用")
	}
	self, selfGroup := selfAccountNames()
	if self == "" || selfGroup == "" {
		t.Skip("账户快照不可用")
	}
	uid, gid, err := resolveOwnership(self, "")
	if err != nil || uid != os.Getuid() || gid != -1 {
		t.Fatalf("按名称解析失败：%d %d %v", uid, gid, err)
	}
	if uid, gid, err = resolveOwnership("", selfGroup); err != nil || gid != os.Getgid() {
		t.Fatalf("按组名解析失败：%d %d %v", uid, gid, err)
	}
	uid, gid, err = resolveOwnership("0", "0")
	if err != nil || uid != 0 || gid != 0 {
		t.Fatalf("按数字解析失败：%d %d %v", uid, gid, err)
	}
	if _, _, err := resolveOwnership("sera-no-such-account-xyz", ""); err != errUnknownAccount {
		t.Fatalf("未知账户应返回 errUnknownAccount，得到 %v", err)
	}
	if _, _, err := resolveOwnership("", "sera-no-such-group-xyz"); err != errUnknownAccount {
		t.Fatalf("未知用户组应返回 errUnknownAccount，得到 %v", err)
	}
	if _, _, err := resolveOwnership(" ", " "); err != errInvalidFilePath {
		t.Fatalf("用户与用户组都为空时应返回 errInvalidFilePath，得到 %v", err)
	}
}

// selfAccountNames 返回测试进程自身的账户名与组名，供构造「按名称改属」的请求。
func selfAccountNames() (string, string) {
	snapshot := accounts(false)
	if snapshot == nil {
		return "", ""
	}
	return snapshot.names(os.Getuid(), os.Getgid())
}

func TestFileAPIChownAndOwnershipListing(t *testing.T) {
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, "work/tree/deep"), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "work/tree/deep/note.txt"), []byte("note"), 0644); err != nil {
		t.Fatal(err)
	}
	root, err := os.OpenRoot(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer root.Close()
	a := &api{token: "secret", files: &fileManager{root: root}}
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
	listing := request("GET", "/v1/files?path=%2Fwork", nil)
	var data fileListing
	if err := json.Unmarshal(listing.Body.Bytes(), &data); err != nil {
		t.Fatal(err)
	}
	if len(data.Entries) != 1 {
		t.Fatalf("unexpected listing: %+v", data)
	}
	entry := data.Entries[0]
	if entry.UID != os.Getuid() || entry.GID != os.Getgid() {
		t.Fatalf("列表未带出属主 ID：%+v", entry)
	}
	if entry.Owner == "" || entry.Group == "" {
		t.Fatalf("列表未带出属主名称：%+v", entry)
	}
	self, selfGroup := selfAccountNames()
	if entry.Owner != self {
		t.Fatalf("属主名称应为 %s，得到 %s", self, entry.Owner)
	}

	chown, _ := json.Marshal(fileCommand{Operation: "chown", Path: "/work/tree", Owner: self, Recursive: true})
	if got := request("POST", "/v1/files", chown).Code; got != 204 {
		t.Fatalf("递归改属返回 %d", got)
	}
	chown, _ = json.Marshal(fileCommand{Operation: "chown", Path: "/work/tree/deep/note.txt", Owner: self, Group: selfGroup})
	if got := request("POST", "/v1/files", chown).Code; got != 204 {
		t.Fatalf("单文件改属返回 %d", got)
	}
	if info, err := os.Stat(filepath.Join(dir, "work/tree/deep/note.txt")); err != nil {
		t.Fatalf("改属后文件不见了：%v", err)
	} else if stat, ok := info.Sys().(*syscall.Stat_t); ok && int(stat.Uid) != os.Getuid() {
		t.Fatalf("改属后属主不对：%d", stat.Uid)
	}

	unknown, _ := json.Marshal(fileCommand{Operation: "chown", Path: "/work/tree", Owner: "sera-no-such-account-xyz"})
	if got := request("POST", "/v1/files", unknown).Code; got != 422 {
		t.Fatalf("未知账户应返回 422，得到 %d", got)
	}
	empty, _ := json.Marshal(fileCommand{Operation: "chown", Path: "/work/tree", Owner: "", Group: ""})
	if got := request("POST", "/v1/files", empty).Code; got != 400 {
		t.Fatalf("用户与用户组都为空应返回 400，得到 %d", got)
	}
	protected, _ := json.Marshal(fileCommand{Operation: "chown", Path: "/etc", Owner: self, Recursive: true})
	if got := request("POST", "/v1/files", protected).Code; got != 400 {
		t.Fatalf("固定目录改属应返回 400，得到 %d", got)
	}
}

func TestFileAPIChownSkipsPanelMetadata(t *testing.T) {
	// 换到当前进程所属的另一个附加组，这样非 root 也能改属，从而观察递归过程
	// 到底改了哪些条目。
	groups, err := os.Getgroups()
	if err != nil {
		t.Skip(err)
	}
	target := -1
	for _, gid := range groups {
		if gid != os.Getgid() {
			target = gid
			break
		}
	}
	if target < 0 {
		t.Skip("当前进程没有可切换的附加组")
	}
	dir := t.TempDir()
	tree := filepath.Join(dir, "tree")
	if err := os.MkdirAll(filepath.Join(tree, "deep"), 0755); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"tree/deep/note.txt", "tree/.sera-project.json", "tree/.sera-account"} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte("x"), 0644); err != nil {
			t.Fatal(err)
		}
	}
	root, err := os.OpenRoot(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer root.Close()
	a := &api{token: "secret", files: &fileManager{root: root}}
	chown, _ := json.Marshal(fileCommand{Operation: "chown", Path: "/tree",
		Group: strconv.Itoa(target), Recursive: true})
	r := httptest.NewRequest("POST", "/v1/files", bytes.NewReader(chown))
	r.Header.Set("Authorization", "Bearer secret")
	w := httptest.NewRecorder()
	a.filesHandler(w, r)
	if w.Code != 204 {
		t.Fatalf("递归改组返回 %d", w.Code)
	}
	gidOf := func(name string) int {
		info, err := os.Lstat(filepath.Join(dir, name))
		if err != nil {
			t.Fatal(err)
		}
		stat, ok := info.Sys().(*syscall.Stat_t)
		if !ok {
			t.Fatal("无法读取属组")
		}
		return int(stat.Gid)
	}
	for _, name := range []string{"tree/deep", "tree/deep/note.txt"} {
		if got := gidOf(name); got != target {
			t.Errorf("%s 的属组应改为 %d，实际 %d", name, target, got)
		}
	}
	for _, name := range []string{"tree/.sera-project.json", "tree/.sera-account"} {
		if got := gidOf(name); got != os.Getgid() {
			t.Errorf("面板元数据 %s 不应被改属，实际属组 %d", name, got)
		}
	}
}

func TestFileAPIChownRejectsSymlink(t *testing.T) {
	dir := t.TempDir()
	outside := t.TempDir()
	if err := os.WriteFile(filepath.Join(outside, "target"), []byte("x"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(outside, "target"), filepath.Join(dir, "link")); err != nil {
		t.Fatal(err)
	}
	root, err := os.OpenRoot(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer root.Close()
	a := &api{token: "secret", files: &fileManager{root: root}}
	self, _ := selfAccountNames()
	chown, _ := json.Marshal(fileCommand{Operation: "chown", Path: "/link", Owner: self})
	r := httptest.NewRequest("POST", "/v1/files", bytes.NewReader(chown))
	r.Header.Set("Authorization", "Bearer secret")
	w := httptest.NewRecorder()
	a.filesHandler(w, r)
	if w.Code != 400 {
		t.Fatalf("软链接改属应返回 400，得到 %d", w.Code)
	}
}
