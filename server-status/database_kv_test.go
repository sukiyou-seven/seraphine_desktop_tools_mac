package main

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestParseKeyValueACLOmitsSecrets(t *testing.T) {
	users, rules := parseKeyValueACL("user default on nopass ~* &* +@all\n" +
		"user reader on #passwordhash ~* &* -@all +@read +@connection -@dangerous\n" +
		"user writer off #anotherhash ~* &* -@all +@read +@write +@connection -@dangerous\n")
	if len(users) != 3 || users[1].Level != "read" || users[2].Level != "readwrite" || users[2].Enabled {
		t.Fatalf("parsed users: %+v", users)
	}
	data, _ := json.Marshal(users)
	if strings.Contains(string(data), "passwordhash") || !strings.Contains(rules["reader"], "passwordhash") {
		t.Fatal("password hashes leaked to API or lost before rollback")
	}
}

func TestKeyValueMigrationPreservesCustomUser(t *testing.T) {
	root := t.TempDir()
	config := filepath.Join(root, "server/redis/etc/redis.conf")
	dataDir := filepath.Join(root, "server/redis/data")
	if err := os.MkdirAll(filepath.Dir(config), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(dataDir, 0750); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(config, []byte("bind 127.0.0.1\nport 6379\n"), 0644); err != nil {
		t.Fatal(err)
	}
	software := newSoftwareManager(root)
	restarts := 0
	software.systemctl = func(_ context.Context, args ...string) ([]byte, error) {
		if args[0] == "restart" {
			restarts++
		}
		return nil, nil
	}
	dm := newDatabaseManager(root, software)
	raw := "user default on nopass ~* &* +@all\nuser unusual-name on #hash ~* &* +@read"
	dm.kvRun = func(_ context.Context, _ string, args []string, _, _ string) (string, error) {
		if strings.Join(args, " ") == "ACL LIST" {
			return raw, nil
		}
		return "OK", nil
	}
	if err := dm.keyValueEnableACL(context.Background(), "redis"); err != nil {
		t.Fatal(err)
	}
	contents, err := os.ReadFile(dm.keyValueACLPath("redis"))
	if err != nil || !strings.Contains(string(contents), "unusual-name") {
		t.Fatalf("custom account lost: %s %v", contents, err)
	}
	info, err := os.Stat(dm.keyValueACLPath("redis"))
	if err != nil || info.Mode().Perm() != 0600 {
		t.Fatalf("ACL file permissions: %v %v", info, err)
	}
	dirInfo, err := os.Stat(dataDir)
	if err != nil || dirInfo.Mode().Perm() != 0700 {
		t.Fatalf("data directory permissions: %v %v", dirInfo, err)
	}
	if restarts != 1 || !dm.keyValuePersistent("redis") {
		t.Fatalf("migration incomplete: restarts=%d", restarts)
	}
}

func TestKeyValueAPIValidationAndPasswordTransport(t *testing.T) {
	root := t.TempDir()
	software := newSoftwareManager(root)
	software.systemctl = func(_ context.Context, args ...string) ([]byte, error) {
		if args[0] == "is-active" {
			return []byte("active\n"), nil
		}
		return []byte("disabled\n"), nil
	}
	for _, engine := range []string{"redis", "valkey"} {
		dir := filepath.Join(root, "server", engine)
		if err := os.MkdirAll(dir, 0755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, ".sera-installed"), []byte("test\n"), 0644); err != nil {
			t.Fatal(err)
		}
		if err := os.MkdirAll(filepath.Join(dir, "data"), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, "data/users.acl"), []byte("user default on nopass ~* &* +@all\n"), 0644); err != nil {
			t.Fatal(err)
		}
		config := filepath.Join(dir, engine+".conf")
		if engine == "redis" {
			config = filepath.Join(dir, "etc/redis.conf")
			if err := os.MkdirAll(filepath.Dir(config), 0755); err != nil {
				t.Fatal(err)
			}
		}
		if err := os.WriteFile(config, []byte("aclfile "+filepath.Join(dir, "data/users.acl")+"\n"), 0644); err != nil {
			t.Fatal(err)
		}
	}
	dm := newDatabaseManager(root, software)
	users := "user default on nopass ~* &* +@all\n"
	var passwordInput string
	dm.kvRun = func(_ context.Context, engine string, args []string, input, password string) (string, error) {
		if engine != "redis" {
			t.Fatalf("unexpected engine: %s", engine)
		}
		for _, arg := range args {
			if strings.HasPrefix(arg, ">") {
				t.Fatal("password entered process arguments")
			}
		}
		switch strings.Join(args[:2], " ") {
		case "ACL LIST":
			return users, nil
		case "ACL SETUSER":
			passwordInput = input
			users += "user appuser on #hash ~* &* -@all +@read +@connection -@dangerous\n"
			return "OK", nil
		case "ACL SAVE":
			return "OK", nil
		default:
			t.Fatalf("unexpected command: %v", args)
			return "", nil
		}
	}
	a := &api{token: "secret", software: software, databases: dm}
	request := func(method, path, body, token string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, path, strings.NewReader(body))
		r.Header.Set("Authorization", token)
		w := httptest.NewRecorder()
		a.databasesHandler(w, r)
		return w
	}
	if got := request("GET", "/v1/databases/redis/acl", "", "").Code; got != 401 {
		t.Fatalf("unauthorized: %d", got)
	}
	if got := request("POST", "/v1/databases/redis/acl/users", `{"name":"a;DROP","level":"read"}`, "Bearer secret").Code; got != 409 {
		t.Fatalf("invalid user accepted: %d", got)
	}
	if got := request("DELETE", "/v1/databases/redis/acl/users/default", "", "Bearer secret").Code; got != 409 {
		t.Fatalf("default account deleted: %d", got)
	}
	created := request("POST", "/v1/databases/redis/acl/users", `{"name":"appuser","level":"read"}`, "Bearer secret")
	var secret databasePasswordResponse
	if created.Code != 201 || json.Unmarshal(created.Body.Bytes(), &secret) != nil || len(secret.Password) != 48 || passwordInput != ">"+secret.Password {
		t.Fatalf("create: %d %s", created.Code, created.Body.String())
	}
	aclInfo, err := os.Stat(filepath.Join(root, "server/redis/data/users.acl"))
	if err != nil || aclInfo.Mode().Perm() != 0600 {
		t.Fatalf("ACL file permissions: %v %v", aclInfo, err)
	}
	listed := request("GET", "/v1/databases/redis/acl", "", "Bearer secret")
	if listed.Code != 200 || strings.Contains(listed.Body.String(), "#hash") || !strings.Contains(listed.Body.String(), "appuser") {
		t.Fatalf("catalog: %d %s", listed.Code, listed.Body.String())
	}
}
