package main

import (
	"context"
	"encoding/json"
	"errors"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func databaseTestAPI(t *testing.T) (*api, *[]string) {
	t.Helper()
	root := t.TempDir()
	software := newSoftwareManager(root)
	software.systemctl = func(_ context.Context, args ...string) ([]byte, error) {
		if args[0] == "is-active" {
			return []byte("active\n"), nil
		}
		return []byte("disabled\n"), nil
	}
	for _, id := range []string{"mysql", "mariadb", "postgresql"} {
		dir := filepath.Join(root, "server", id)
		if err := os.MkdirAll(dir, 0755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, ".sera-installed"), []byte("test"), 0644); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(root, "server/mysql/initial-root-password"), []byte("initial-secret\n"), 0600); err != nil {
		t.Fatal(err)
	}
	dm := newDatabaseManager(root, software)
	queries := []string{}
	dm.run = func(_ context.Context, engine, query, database, password string) (string, error) {
		queries = append(queries, engine+":"+database+":"+query)
		switch {
		case strings.Contains(query, "SELECT 1 FROM mysql.user"):
			// 只有 takenuser 视作已存在。
			if strings.Contains(query, "'takenuser'") {
				return "1\n", nil
			}
			return "", nil
		case strings.Contains(query, "SELECT 1 FROM pg_roles"):
			if strings.Contains(query, "'takenuser'") {
				return "1\n", nil
			}
			return "", nil
		case strings.Contains(query, "SHOW DATABASES"):
			return "information_schema\nappdb\n", nil
		case strings.Contains(query, "FROM mysql.user"):
			return "root\tlocalhost\nappuser\tlocalhost\n", nil
		case strings.Contains(query, "FROM pg_database"):
			return "postgres\nappdb\n", nil
		case strings.Contains(query, "FROM pg_roles"):
			return "seraphim-postgres\nappuser\n", nil
		default:
			return "", nil
		}
	}
	return &api{token: "secret", software: software, databases: dm}, &queries
}

func TestDatabasePasswordsPersistAndMatchAPI(t *testing.T) {
	a, _ := databaseTestAPI(t)
	created := databaseRequest(a, "POST", "/v1/databases/mysql/users", `{"name":"webuser"}`, true)
	if created.Code != 201 {
		t.Fatalf("create: %d %s", created.Code, created.Body.String())
	}
	var first databasePasswordResponse
	if err := json.Unmarshal(created.Body.Bytes(), &first); err != nil {
		t.Fatal(err)
	}
	revealed := databaseRequest(a, "GET", "/v1/databases/mysql/users/webuser:password", "", true)
	if revealed.Code != 200 || !strings.Contains(revealed.Body.String(), first.Password) {
		t.Fatalf("reveal: %d %s", revealed.Code, revealed.Body.String())
	}
	path, _ := a.databases.userSecretPath("mysql", "webuser")
	if info, err := os.Stat(path); err != nil || info.Mode().Perm() != 0600 {
		t.Fatalf("secret mode: %v %v", info, err)
	}
	reset := databaseRequest(a, "POST", "/v1/databases/mysql/users/webuser:reset", "", true)
	var second databasePasswordResponse
	if err := json.Unmarshal(reset.Body.Bytes(), &second); err != nil {
		t.Fatal(err)
	}
	if second.Password == first.Password {
		t.Fatal("reset reused password")
	}
	if got := databaseRequest(a, "GET", "/v1/databases/mysql/users/webuser:password", "", true); !strings.Contains(got.Body.String(), second.Password) {
		t.Fatalf("reset not persisted: %s", got.Body.String())
	}
	changed := databaseRequest(a, "POST", "/v1/databases/mysql/credential/change", `{"current_password":"initial-secret","new_password":"chosen-password-123"}`, true)
	if changed.Code != 204 {
		t.Fatalf("change: %d %s", changed.Code, changed.Body.String())
	}
	if got := databaseRequest(a, "GET", "/v1/databases/mysql/credential", "", true); !strings.Contains(got.Body.String(), "chosen-password-123") {
		t.Fatalf("admin reveal: %s", got.Body.String())
	}
	if got := databaseRequest(a, "DELETE", "/v1/databases/mysql/users/webuser", "", true); got.Code != 204 {
		t.Fatalf("delete: %d", got.Code)
	}
	if got := databaseRequest(a, "GET", "/v1/databases/mysql/users/webuser:password", "", true); got.Code != 404 {
		t.Fatalf("deleted secret revealed: %d", got.Code)
	}
}

func TestCreateDatabaseWithUserGrantAndRollback(t *testing.T) {
	a, queries := databaseTestAPI(t)
	created := databaseRequest(a, "POST", "/v1/databases/mysql/databases", `{"name":"shopdb","user":"shopuser"}`, true)
	if created.Code != 201 {
		t.Fatalf("create with user: %d %s", created.Code, created.Body.String())
	}
	var result databaseCreateResponse
	if err := json.Unmarshal(created.Body.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	if result.Database != "shopdb" || result.User != "shopuser" || result.Level != "readwrite" || len(result.Password) != 48 {
		t.Fatalf("unexpected response: %+v", result)
	}
	if got := databaseRequest(a, "GET", "/v1/databases/mysql/users/shopuser:password", "", true); !strings.Contains(got.Body.String(), result.Password) {
		t.Fatalf("generated password not persisted: %s", got.Body.String())
	}
	joined := strings.Join(*queries, "\n")
	for _, expected := range []string{"CREATE DATABASE `shopdb`", "CREATE USER 'shopuser'@'localhost' IDENTIFIED BY",
		"GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, INDEX, DROP, REFERENCES, TRIGGER, CREATE VIEW, SHOW VIEW, CREATE TEMPORARY TABLES, LOCK TABLES ON `shopdb`.* TO 'shopuser'@'localhost'"} {
		if !strings.Contains(joined, expected) {
			t.Fatalf("missing %q in queries: %s", expected, joined)
		}
	}
	// 只给库名时保持旧行为：不建用户、不返回密码。
	plain := databaseRequest(a, "POST", "/v1/databases/mysql/databases", `{"name":"plaindb"}`, true)
	if plain.Code != 201 || plain.Body.Len() != 0 {
		t.Fatalf("plain create: %d %s", plain.Code, plain.Body.String())
	}
	// 用户名非法应在建库前挡下。
	before := len(*queries)
	if got := databaseRequest(a, "POST", "/v1/databases/mysql/databases", `{"name":"blockeddb","user":"bad user"}`, true).Code; got != 400 {
		t.Fatalf("invalid user accepted: %d", got)
	}
	if len(*queries) != before {
		t.Fatalf("invalid user still ran queries: %+v", (*queries)[before:])
	}
	// 系统用户同样挡在建库之前。
	before = len(*queries)
	if got := databaseRequest(a, "POST", "/v1/databases/mysql/databases", `{"name":"blockeddb","user":"root"}`, true).Code; got != 409 {
		t.Fatalf("protected user accepted: %d", got)
	}
	if len(*queries) != before {
		t.Fatalf("protected user still ran queries: %+v", (*queries)[before:])
	}
}

func TestCreateDatabaseWithUserRollsBackOnUserFailure(t *testing.T) {
	a, queries := databaseTestAPI(t)
	base := a.databases.run
	a.databases.run = func(ctx context.Context, engine, query, database, password string) (string, error) {
		if strings.HasPrefix(query, "CREATE USER") {
			return "", errors.New("create user failed")
		}
		return base(ctx, engine, query, database, password)
	}
	response := databaseRequest(a, "POST", "/v1/databases/mysql/databases", `{"name":"rollbackdb","user":"rolluser"}`, true)
	if response.Code != 409 {
		t.Fatalf("expected conflict, got %d %s", response.Code, response.Body.String())
	}
	joined := strings.Join(*queries, "\n")
	if !strings.Contains(joined, "DROP DATABASE `rollbackdb`") {
		t.Fatalf("database not rolled back: %s", joined)
	}
	// 账户没建成，就不该去 DROP 它（DROP USER 只会打到别人的账户上）。
	if strings.Contains(joined, "DROP USER") {
		t.Fatalf("rolled back a user that was never created: %s", joined)
	}
}

func TestCreateDatabaseWithUserRejectsTakenAccount(t *testing.T) {
	a, queries := databaseTestAPI(t)
	response := databaseRequest(a, "POST", "/v1/databases/mysql/databases", `{"name":"taken_db","user":"takenuser"}`, true)
	if response.Code != 409 {
		t.Fatalf("taken account accepted: %d %s", response.Code, response.Body.String())
	}
	joined := strings.Join(*queries, "\n")
	if strings.Contains(joined, "CREATE DATABASE") || strings.Contains(joined, "DROP USER") {
		t.Fatalf("taken account path touched existing objects: %s", joined)
	}
}

func TestPostgresLocalAccessMigrationAndRollback(t *testing.T) {
	a, _ := databaseTestAPI(t)
	dir := filepath.Join(a.databases.root, "server/postgresql/data")
	if err := os.MkdirAll(dir, 0700); err != nil {
		t.Fatal(err)
	}
	config := []byte("listen_addresses = ''\n")
	hba := []byte("local all all peer\nhost all all 127.0.0.1/32 reject\n")
	if err := os.WriteFile(a.databases.postgresConfigPath(), config, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(a.databases.postgresHBAPath(), hba, 0600); err != nil {
		t.Fatal(err)
	}
	response := databaseRequest(a, "POST", "/v1/databases/postgresql/local-access", "", true)
	if response.Code != 204 {
		t.Fatalf("migration: %d %s", response.Code, response.Body.String())
	}
	if !a.databases.postgresLocalAccess() {
		t.Fatal("local password access unavailable")
	}
	info, err := os.Stat(a.databases.postgresHBAPath())
	if err != nil || info.Mode().Perm() != 0600 {
		t.Fatalf("HBA mode: %v %v", info, err)
	}
	if got := databaseRequest(a, "POST", "/v1/databases/postgresql/local-access", "", true).Code; got != 204 {
		t.Fatalf("idempotent migration: %d", got)
	}
	if err := os.WriteFile(a.databases.postgresConfigPath(), config, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(a.databases.postgresHBAPath(), hba, 0600); err != nil {
		t.Fatal(err)
	}
	a.software.systemctl = func(_ context.Context, args ...string) ([]byte, error) {
		if args[0] == "is-active" {
			return []byte("active\n"), nil
		}
		if args[0] == "restart" {
			return []byte("failed"), errors.New("restart failed")
		}
		return nil, nil
	}
	failed := databaseRequest(a, "POST", "/v1/databases/postgresql/local-access", "", true)
	if failed.Code != 409 {
		t.Fatalf("failed restart accepted: %d", failed.Code)
	}
	currentConfig, _ := os.ReadFile(a.databases.postgresConfigPath())
	currentHBA, _ := os.ReadFile(a.databases.postgresHBAPath())
	if string(currentConfig) != string(config) || string(currentHBA) != string(hba) {
		t.Fatal("PostgreSQL configuration not restored after restart failure")
	}
}

func databaseRequest(a *api, method, path, body string, authorized bool) *httptest.ResponseRecorder {
	r := httptest.NewRequest(method, path, strings.NewReader(body))
	if authorized {
		r.Header.Set("Authorization", "Bearer secret")
	}
	w := httptest.NewRecorder()
	a.databasesHandler(w, r)
	return w
}

func TestDatabaseAPIValidationAndActions(t *testing.T) {
	a, queries := databaseTestAPI(t)
	if got := databaseRequest(a, "GET", "/v1/databases", "", false).Code; got != 401 {
		t.Fatalf("unauthorized: %d", got)
	}
	listing := databaseRequest(a, "GET", "/v1/databases", "", true)
	var instances struct {
		Items []databaseInstance `json:"items"`
	}
	if err := json.Unmarshal(listing.Body.Bytes(), &instances); err != nil {
		t.Fatal(err)
	}
	if len(instances.Items) != 7 || !instances.Items[0].Running {
		t.Fatalf("instances: %+v", instances)
	}
	if got := databaseRequest(a, "GET", "/v1/databases/mongodb/catalog", "", true).Code; got != 404 {
		t.Fatalf("mongodb catalog: %d", got)
	}
	catalog := databaseRequest(a, "GET", "/v1/databases/mariadb/catalog", "", true)
	var data databaseCatalogView
	if err := json.Unmarshal(catalog.Body.Bytes(), &data); err != nil {
		t.Fatal(err)
	}
	if len(data.Databases) != 2 || len(data.Users) != 2 {
		t.Fatalf("catalog: %+v", data)
	}
	if got := databaseRequest(a, "POST", "/v1/databases/mariadb/databases", `{"name":"bad;DROP"}`, true).Code; got != 400 {
		t.Fatalf("SQL injection name: %d", got)
	}
	if got := databaseRequest(a, "DELETE", "/v1/databases/mysql/databases/mysql", "", true).Code; got != 409 {
		t.Fatalf("system database deletion: %d", got)
	}
	if got := databaseRequest(a, "DELETE", "/v1/databases/postgresql/users/postgres", "", true).Code; got != 409 {
		t.Fatalf("system role deletion: %d", got)
	}
	if got := databaseRequest(a, "POST", "/v1/databases/mysql/databases", `{"name":"appdb"}`, true).Code; got != 201 {
		t.Fatalf("create database: %d", got)
	}
	created := databaseRequest(a, "POST", "/v1/databases/postgresql/users", `{"name":"appuser"}`, true)
	var secret databasePasswordResponse
	if created.Code != 201 || json.Unmarshal(created.Body.Bytes(), &secret) != nil || len(secret.Password) != 48 {
		t.Fatalf("create user: %d %s", created.Code, created.Body.String())
	}
	grant := databaseRequest(a, "POST", "/v1/databases/postgresql/grants", `{"database":"appdb","user":"appuser","level":"readwrite"}`, true)
	if grant.Code != 204 {
		t.Fatalf("grant: %d %s", grant.Code, grant.Body.String())
	}
	if got := databaseRequest(a, "DELETE", "/v1/databases/postgresql/grants", `{"database":"appdb","user":"appuser"}`, true).Code; got != 204 {
		t.Fatalf("revoke: %d", got)
	}
	joined := strings.Join(*queries, "\n")
	for _, expected := range []string{"CREATE DATABASE `appdb`", "CREATE ROLE \"appuser\"", "GRANT CONNECT ON DATABASE \"appdb\"", "REVOKE ALL PRIVILEGES ON DATABASE \"appdb\""} {
		if !strings.Contains(joined, expected) {
			t.Fatalf("missing %q in queries: %s", expected, joined)
		}
	}
}

func TestMySQLBootstrapCredentialIsProtected(t *testing.T) {
	a, _ := databaseTestAPI(t)
	response := databaseRequest(a, "POST", "/v1/databases/mysql/bootstrap", "", true)
	var secret databasePasswordResponse
	if response.Code != 200 || json.Unmarshal(response.Body.Bytes(), &secret) != nil || len(secret.Password) != 48 {
		t.Fatalf("bootstrap: %d %s", response.Code, response.Body.String())
	}
	info, err := os.Stat(a.databases.adminPath())
	if err != nil || info.Mode().Perm() != 0600 {
		t.Fatalf("credential mode: %v %v", info, err)
	}
	if got := databaseRequest(a, "POST", "/v1/databases/mysql/bootstrap", "", true).Code; got != 409 {
		t.Fatalf("repeated bootstrap: %d", got)
	}
}

func TestMySQLPendingPasswordRecoveryAndWhitespace(t *testing.T) {
	a, queries := databaseTestAPI(t)
	pending := "a pass with trailing space "
	if err := os.WriteFile(a.databases.pendingAdminPath(), []byte(pending+"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	response := databaseRequest(a, "POST", "/v1/databases/mysql/bootstrap", "", true)
	var secret databasePasswordResponse
	if response.Code != 200 || json.Unmarshal(response.Body.Bytes(), &secret) != nil || secret.Password != pending {
		t.Fatalf("pending recovery: %d %s", response.Code, response.Body.String())
	}
	stored, err := a.databases.mysqlPassword()
	if err != nil || stored != pending {
		t.Fatalf("stored password: %q %v", stored, err)
	}
	if len(*queries) != 1 || !strings.Contains((*queries)[0], "SELECT 1") {
		t.Fatalf("unexpected recovery query: %+v", *queries)
	}
}
