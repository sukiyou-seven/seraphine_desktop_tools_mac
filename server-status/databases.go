package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"
)

type databaseInstance struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	Version     string `json:"version"`
	Installed   bool   `json:"installed"`
	Running     bool   `json:"running"`
	Port        int    `json:"port"`
	ManageUsers bool   `json:"manage_users"`
	AuthState   string `json:"auth_state"`
}

type databaseUser struct {
	Name string `json:"name"`
	Host string `json:"host"`
}

type databaseCatalogView struct {
	Databases []string       `json:"databases"`
	Users     []databaseUser `json:"users"`
}

type databasePasswordResponse struct {
	User     string `json:"user"`
	Password string `json:"password"`
}

type databaseManager struct {
	root     string
	software *softwareManager
	mu       sync.Mutex
	run      func(context.Context, string, string, string, string) (string, error)
	kvRun    func(context.Context, string, []string, string, string) (string, error)
}

var databaseNamePattern = regexp.MustCompile(`^[A-Za-z][A-Za-z0-9_]{0,62}$`)
var databaseUserPattern = regexp.MustCompile(`^[A-Za-z][A-Za-z0-9_]{0,31}$`)

var databaseSpecs = []struct {
	id, name string
	port     int
	manage   bool
}{
	{"mysql", "MySQL", 3306, true},
	{"mariadb", "MariaDB", 3307, true},
	{"postgresql", "PostgreSQL", 5432, true},
	{"mongodb", "MongoDB", 27018, false},
	{"redis", "Redis", 6379, false},
	{"valkey", "Valkey", 6380, false},
	{"sqlite", "SQLite", 0, false},
}

func newDatabaseManager(root string, software *softwareManager) *databaseManager {
	manager := &databaseManager{root: root, software: software}
	manager.run = manager.runCommand
	manager.kvRun = manager.runKeyValueCLI
	return manager
}

func (dm *databaseManager) adminPath() string {
	return filepath.Join(dm.root, "server/mysql/sera-admin-password")
}
func (dm *databaseManager) pendingAdminPath() string {
	return filepath.Join(dm.root, "server/mysql/sera-admin-password.pending")
}
func (dm *databaseManager) initialPath() string {
	return filepath.Join(dm.root, "server/mysql/initial-root-password")
}

const postgresLocalAccessMarker = "# Seraphim local password access"

func (dm *databaseManager) postgresConfigPath() string {
	return filepath.Join(dm.root, "server/postgresql/data/postgresql.conf")
}
func (dm *databaseManager) postgresHBAPath() string {
	return filepath.Join(dm.root, "server/postgresql/data/pg_hba.conf")
}

func (dm *databaseManager) postgresLocalAccess() bool {
	hba, err := os.ReadFile(dm.postgresHBAPath())
	if err != nil {
		return false
	}
	config, err := os.ReadFile(dm.postgresConfigPath())
	return err == nil && strings.Contains(string(hba), postgresLocalAccessMarker) &&
		strings.Contains(string(config), "listen_addresses = '127.0.0.1'")
}

func readDatabasePassword(path string) (string, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return "", err
	}
	if !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 || info.Size() > 1024 {
		return "", errors.New("管理员密码文件权限或类型无效")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	password := strings.TrimSuffix(string(data), "\n")
	password = strings.TrimSuffix(password, "\r")
	if password == "" {
		return "", errors.New("管理员密码文件为空")
	}
	return password, nil
}

func (dm *databaseManager) mysqlPassword() (string, error) {
	password, err := readDatabasePassword(dm.adminPath())
	if errors.Is(err, os.ErrNotExist) {
		password, err = readDatabasePassword(dm.pendingAdminPath())
	}
	if errors.Is(err, os.ErrNotExist) {
		return readDatabasePassword(dm.initialPath())
	}
	return password, err
}

type databaseOutput struct{ data []byte }

func (output *databaseOutput) Write(data []byte) (int, error) {
	if len(output.data) < 256<<10 {
		limit := 256<<10 - len(output.data)
		if len(data) < limit {
			limit = len(data)
		}
		output.data = append(output.data, data[:limit]...)
	}
	return len(data), nil
}

func (dm *databaseManager) runCommand(ctx context.Context, engine, query, database, password string) (string, error) {
	timeout, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	var command *exec.Cmd
	switch engine {
	case "mysql", "mariadb":
		prefix := filepath.Join(dm.root, "server", engine)
		binary := filepath.Join(prefix, "bin", "mysql")
		if engine == "mariadb" {
			binary = filepath.Join(prefix, "bin", "mariadb")
		}
		args := []string{"--no-defaults", "--protocol=SOCKET", "--socket=" + filepath.Join(prefix, "run", engine+".sock"),
			"--user=root", "--connect-timeout=5", "--batch", "--skip-column-names", "--raw"}
		if engine == "mysql" {
			args[2] = "--socket=" + filepath.Join(prefix, "run/mysql.sock")
			args = append(args, "--connect-expired-password")
		}
		if database != "" {
			args = append(args, "--database="+database)
		}
		args = append(args, "--execute", query)
		command = exec.CommandContext(timeout, binary, args...)
		if password != "" {
			command.Env = append(os.Environ(), "MYSQL_PWD="+password)
		}
	case "postgresql":
		if database == "" {
			database = "postgres"
		}
		binary := filepath.Join(dm.root, "server/postgresql/bin/psql")
		command = exec.CommandContext(timeout, "runuser", "-u", "seraphim-postgres", "--", binary,
			"-X", "-A", "-t", "-F", "\t", "-v", "ON_ERROR_STOP=1", "-h", filepath.Join(dm.root, "server/postgresql/run"),
			"-d", database, "-c", query)
	default:
		return "", errors.New("不支持此数据库")
	}
	output := &databaseOutput{}
	command.Stdout, command.Stderr = output, output
	err := command.Run()
	result := strings.TrimSpace(string(output.data))
	if err != nil {
		if strings.Contains(result, "ERROR 1820") {
			return "", errors.New("MySQL 初始管理员密码已过期，请先初始化管理密码")
		}
		if len(result) > 1200 {
			result = result[:1200]
		}
		return "", fmt.Errorf("数据库操作失败：%s", result)
	}
	return result, nil
}

func databaseSpecByID(id string) (databaseInstance, bool) {
	for _, spec := range databaseSpecs {
		if spec.id == id {
			return databaseInstance{ID: id, Name: spec.name, Port: spec.port, ManageUsers: spec.manage}, true
		}
	}
	return databaseInstance{}, false
}

func (dm *databaseManager) instances(ctx context.Context) []databaseInstance {
	items := make([]databaseInstance, 0, len(databaseSpecs))
	for _, spec := range databaseSpecs {
		item, _ := databaseSpecByID(spec.id)
		softwareSpec, _ := findSoftware(spec.id)
		softwareItem := dm.software.item(ctx, softwareSpec)
		item.Version, item.Installed = softwareItem.Version, softwareItem.State == "installed"
		item.Running = item.Installed && (softwareItem.ServiceState == "active" || spec.id == "sqlite")
		if spec.id == "mysql" && item.Installed {
			if _, err := readDatabasePassword(dm.adminPath()); err == nil {
				item.AuthState = "configured"
			} else {
				item.AuthState = "initial"
			}
		}
		if spec.id == "postgresql" && item.Installed {
			if dm.postgresLocalAccess() {
				item.AuthState = "local_password"
			} else {
				item.AuthState = "peer_only"
			}
		}
		items = append(items, item)
	}
	return items
}

func protectedDatabaseName(engine, name string) bool {
	if !databaseNamePattern.MatchString(name) {
		return true
	}
	switch engine {
	case "mysql", "mariadb":
		for _, system := range []string{"mysql", "information_schema", "performance_schema", "sys"} {
			if strings.EqualFold(name, system) {
				return true
			}
		}
	case "postgresql":
		for _, system := range []string{"postgres", "template0", "template1"} {
			if strings.EqualFold(name, system) {
				return true
			}
		}
	}
	return false
}

func protectedDatabaseUser(name string) bool {
	if !databaseUserPattern.MatchString(name) {
		return true
	}
	for _, system := range []string{"root", "postgres", "seraphim_postgres", "mysql", "mysql_sys", "mysql_session", "mysql_innodb_cluster_metadata"} {
		if strings.EqualFold(name, system) {
			return true
		}
	}
	return strings.HasPrefix(strings.ToLower(name), "pg_")
}

func quoteDatabaseIdentifier(engine, name string) string {
	if engine == "postgresql" {
		return `"` + name + `"`
	}
	return "`" + name + "`"
}
func quoteDatabaseUser(engine, name string) string {
	if engine == "postgresql" {
		return quoteDatabaseIdentifier(engine, name)
	}
	return "'" + name + "'@'localhost'"
}

func (dm *databaseManager) ready(ctx context.Context, engine string) error {
	instance, ok := databaseSpecByID(engine)
	if !ok || !instance.ManageUsers {
		return errors.New("此数据库暂不提供建库和用户管理")
	}
	softwareSpec, _ := findSoftware(engine)
	item := dm.software.item(ctx, softwareSpec)
	if item.State != "installed" {
		return errors.New("请先在软件商店安装数据库")
	}
	if item.ServiceState != "active" {
		return errors.New("请先启动数据库服务")
	}
	return nil
}

func (dm *databaseManager) query(ctx context.Context, engine, sql, database string) (string, error) {
	password := ""
	if engine == "mysql" {
		var err error
		password, err = dm.mysqlPassword()
		if err != nil {
			return "", fmt.Errorf("无法读取 MySQL 管理员密码：%w", err)
		}
	}
	return dm.run(ctx, engine, sql, database, password)
}

func parseDatabaseLines(output string) []string {
	items := []string{}
	for _, line := range strings.Split(output, "\n") {
		line = strings.TrimSpace(line)
		if line != "" {
			items = append(items, line)
		}
	}
	sort.Strings(items)
	return items
}

func (dm *databaseManager) catalog(ctx context.Context, engine string) (databaseCatalogView, error) {
	if err := dm.ready(ctx, engine); err != nil {
		return databaseCatalogView{}, err
	}
	var databaseSQL, usersSQL string
	if engine == "postgresql" {
		databaseSQL = "SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY datname"
		usersSQL = "SELECT rolname FROM pg_roles WHERE rolcanlogin AND rolname NOT LIKE 'pg_%' ORDER BY rolname"
	} else {
		databaseSQL = "SHOW DATABASES"
		usersSQL = "SELECT User, Host FROM mysql.user ORDER BY User, Host"
	}
	databaseOutput, err := dm.query(ctx, engine, databaseSQL, "")
	if err != nil {
		return databaseCatalogView{}, err
	}
	userOutput, err := dm.query(ctx, engine, usersSQL, "")
	if err != nil {
		return databaseCatalogView{}, err
	}
	result := databaseCatalogView{Databases: parseDatabaseLines(databaseOutput), Users: []databaseUser{}}
	for _, line := range parseDatabaseLines(userOutput) {
		parts := strings.SplitN(line, "\t", 2)
		user := databaseUser{Name: parts[0]}
		if len(parts) == 2 {
			user.Host = parts[1]
		}
		result.Users = append(result.Users, user)
	}
	return result, nil
}

func generateDatabasePassword() (string, error) {
	data := make([]byte, 24)
	if _, err := rand.Read(data); err != nil {
		return "", err
	}
	return hex.EncodeToString(data), nil
}

func (dm *databaseManager) createDatabase(ctx context.Context, engine, name string) error {
	if protectedDatabaseName(engine, name) {
		return errors.New("数据库名称无效或属于系统数据库")
	}
	identifier := quoteDatabaseIdentifier(engine, name)
	query := "CREATE DATABASE " + identifier
	if engine == "mysql" || engine == "mariadb" {
		query += " CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci"
	}
	_, err := dm.query(ctx, engine, query, "")
	if err != nil {
		return err
	}
	if engine == "postgresql" {
		if _, err := dm.query(ctx, engine, "REVOKE ALL PRIVILEGES ON DATABASE "+identifier+" FROM PUBLIC", ""); err != nil {
			_, _ = dm.query(context.Background(), engine, "DROP DATABASE "+identifier, "")
			return err
		}
	}
	return nil
}

func (dm *databaseManager) deleteDatabase(ctx context.Context, engine, name string) error {
	if protectedDatabaseName(engine, name) {
		return errors.New("数据库名称无效或属于系统数据库")
	}
	_, err := dm.query(ctx, engine, "DROP DATABASE "+quoteDatabaseIdentifier(engine, name), "")
	return err
}

func (dm *databaseManager) createUser(ctx context.Context, engine, name string) (string, error) {
	if protectedDatabaseUser(name) {
		return "", errors.New("用户名无效或属于系统账户")
	}
	password, err := generateDatabasePassword()
	if err != nil {
		return "", err
	}
	var sql string
	if engine == "postgresql" {
		sql = "CREATE ROLE " + quoteDatabaseUser(engine, name) + " LOGIN PASSWORD '" + password + "'"
	} else {
		sql = "CREATE USER " + quoteDatabaseUser(engine, name) + " IDENTIFIED BY '" + password + "'"
	}
	_, err = dm.query(ctx, engine, sql, "")
	return password, err
}

func (dm *databaseManager) deleteUser(ctx context.Context, engine, name string) error {
	if protectedDatabaseUser(name) {
		return errors.New("用户名无效或属于系统账户")
	}
	var sql string
	if engine == "postgresql" {
		sql = "DROP ROLE " + quoteDatabaseUser(engine, name)
	} else {
		sql = "DROP USER " + quoteDatabaseUser(engine, name)
	}
	_, err := dm.query(ctx, engine, sql, "")
	return err
}

func (dm *databaseManager) resetUserPassword(ctx context.Context, engine, name string) (string, error) {
	if protectedDatabaseUser(name) {
		return "", errors.New("用户名无效或属于系统账户")
	}
	password, err := generateDatabasePassword()
	if err != nil {
		return "", err
	}
	var sql string
	if engine == "postgresql" {
		sql = "ALTER ROLE " + quoteDatabaseUser(engine, name) + " WITH PASSWORD '" + password + "'"
	} else {
		sql = "ALTER USER " + quoteDatabaseUser(engine, name) + " IDENTIFIED BY '" + password + "'"
	}
	_, err = dm.query(ctx, engine, sql, "")
	return password, err
}

func (dm *databaseManager) grant(ctx context.Context, engine, database, username, level string, revoke bool) error {
	if protectedDatabaseName(engine, database) || protectedDatabaseUser(username) {
		return errors.New("数据库或用户名无效")
	}
	if !revoke && level != "read" && level != "readwrite" {
		return errors.New("权限须为只读或读写")
	}
	name := quoteDatabaseIdentifier(engine, database)
	account := quoteDatabaseUser(engine, username)
	if engine == "postgresql" {
		if revoke {
			for _, sql := range []string{
				"REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public FROM " + account,
				"REVOKE ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public FROM " + account,
				"REVOKE ALL PRIVILEGES ON SCHEMA public FROM " + account,
			} {
				if _, err := dm.query(ctx, engine, sql, database); err != nil {
					return err
				}
			}
			_, err := dm.query(ctx, engine, "REVOKE ALL PRIVILEGES ON DATABASE "+name+" FROM "+account, "")
			return err
		}
		if _, err := dm.query(ctx, engine, "GRANT CONNECT ON DATABASE "+name+" TO "+account, ""); err != nil {
			return err
		}
		statements := []string{"GRANT USAGE ON SCHEMA public TO " + account, "GRANT SELECT ON ALL TABLES IN SCHEMA public TO " + account}
		if level == "readwrite" {
			statements = append(statements, "GRANT CREATE ON SCHEMA public TO "+account,
				"GRANT INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO "+account,
				"GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA public TO "+account)
		}
		for _, sql := range statements {
			if _, err := dm.query(ctx, engine, sql, database); err != nil {
				return err
			}
		}
		return nil
	}
	if revoke {
		_, err := dm.query(ctx, engine, "REVOKE ALL PRIVILEGES ON "+name+".* FROM "+account, "")
		return err
	}
	privileges := "SELECT"
	if level == "readwrite" {
		privileges = "SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, INDEX, DROP"
	}
	_, err := dm.query(ctx, engine, "GRANT "+privileges+" ON "+name+".* TO "+account, "")
	return err
}

func (dm *databaseManager) bootstrapMySQL(ctx context.Context) (string, error) {
	if _, err := readDatabasePassword(dm.adminPath()); err == nil {
		return "", errors.New("MySQL 管理密码已配置")
	} else if !errors.Is(err, os.ErrNotExist) {
		return "", err
	}
	if pending, err := readDatabasePassword(dm.pendingAdminPath()); err == nil {
		if _, verifyErr := dm.run(ctx, "mysql", "SELECT 1", "", pending); verifyErr == nil {
			if renameErr := os.Rename(dm.pendingAdminPath(), dm.adminPath()); renameErr != nil {
				return "", renameErr
			}
			return pending, nil
		}
		if removeErr := os.Remove(dm.pendingAdminPath()); removeErr != nil {
			return "", removeErr
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return "", err
	}
	initial, err := readDatabasePassword(dm.initialPath())
	if err != nil {
		return "", fmt.Errorf("初始密码不可用：%w", err)
	}
	password, err := generateDatabasePassword()
	if err != nil {
		return "", err
	}
	pending, err := os.OpenFile(dm.pendingAdminPath(), os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return "", err
	}
	if _, err := pending.WriteString(password + "\n"); err != nil {
		_ = pending.Close()
		_ = os.Remove(dm.pendingAdminPath())
		return "", err
	}
	if err := pending.Sync(); err != nil {
		_ = pending.Close()
		_ = os.Remove(dm.pendingAdminPath())
		return "", err
	}
	if err := pending.Close(); err != nil {
		_ = os.Remove(dm.pendingAdminPath())
		return "", err
	}
	if _, err := dm.run(ctx, "mysql", "ALTER USER 'root'@'localhost' IDENTIFIED BY '"+password+"'", "", initial); err != nil {
		_ = os.Remove(dm.pendingAdminPath())
		return "", err
	}
	if err := os.Rename(dm.pendingAdminPath(), dm.adminPath()); err != nil {
		return "", fmt.Errorf("密码已更改，待完成的管理密码保存在受限文件中：%w", err)
	}
	return password, nil
}

func (dm *databaseManager) setMySQLCredential(ctx context.Context, password string) error {
	if len(password) < 8 || len(password) > 512 || strings.ContainsAny(password, "\r\n\x00") {
		return errors.New("管理员密码须为 8 至 512 字符")
	}
	if _, err := dm.run(ctx, "mysql", "SELECT 1", "", password); err != nil {
		return err
	}
	return atomicSiteWrite(dm.adminPath(), []byte(password+"\n"), 0600)
}

func databaseConfigSnapshot(path string) ([]byte, os.FileInfo, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return nil, nil, err
	}
	if !info.Mode().IsRegular() || info.Size() > 1<<20 {
		return nil, nil, errors.New("PostgreSQL 配置文件类型或大小无效")
	}
	data, err := os.ReadFile(path)
	return data, info, err
}

func writeDatabaseConfig(path string, data []byte, original os.FileInfo) error {
	temp, err := os.CreateTemp(filepath.Dir(path), ".sera-postgresql-*")
	if err != nil {
		return err
	}
	defer os.Remove(temp.Name())
	if _, err := temp.Write(data); err != nil {
		_ = temp.Close()
		return err
	}
	if err := temp.Chmod(original.Mode().Perm()); err != nil {
		_ = temp.Close()
		return err
	}
	owner, ok := original.Sys().(*syscall.Stat_t)
	if !ok {
		_ = temp.Close()
		return errors.New("无法读取 PostgreSQL 配置文件所有者")
	}
	if err := temp.Chown(int(owner.Uid), int(owner.Gid)); err != nil {
		_ = temp.Close()
		return err
	}
	if err := temp.Sync(); err != nil {
		_ = temp.Close()
		return err
	}
	if err := temp.Close(); err != nil {
		return err
	}
	return os.Rename(temp.Name(), path)
}

func (dm *databaseManager) enablePostgresLocalAccess(ctx context.Context) error {
	if dm.postgresLocalAccess() {
		return nil
	}
	config, configInfo, err := databaseConfigSnapshot(dm.postgresConfigPath())
	if err != nil {
		return err
	}
	hba, hbaInfo, err := databaseConfigSnapshot(dm.postgresHBAPath())
	if err != nil {
		return err
	}
	if strings.Contains(string(hba), postgresLocalAccessMarker) {
		return errors.New("PostgreSQL 本机认证配置不完整，请先检查文件")
	}
	newHBA := []byte(postgresLocalAccessMarker + "\n" +
		"local all seraphim-postgres peer\n" +
		"local all all scram-sha-256\n" +
		"host all all 127.0.0.1/32 scram-sha-256\n" +
		"host all all ::1/128 scram-sha-256\n\n" + string(hba))
	newConfig := append(append([]byte{}, config...), []byte("\n# Seraphim loopback connections\nlisten_addresses = '127.0.0.1'\npassword_encryption = 'scram-sha-256'\n")...)
	if err := writeDatabaseConfig(dm.postgresHBAPath(), newHBA, hbaInfo); err != nil {
		return err
	}
	changed := true
	defer func() {
		if changed {
			_ = writeDatabaseConfig(dm.postgresHBAPath(), hba, hbaInfo)
			_ = writeDatabaseConfig(dm.postgresConfigPath(), config, configInfo)
			rollbackCtx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
			defer cancel()
			_, _ = dm.software.systemctl(rollbackCtx, "restart", "sera-postgresql.service")
		}
	}()
	if err := writeDatabaseConfig(dm.postgresConfigPath(), newConfig, configInfo); err != nil {
		return err
	}
	timeout, cancel := context.WithTimeout(ctx, 45*time.Second)
	defer cancel()
	output, err := dm.software.systemctl(timeout, "restart", "sera-postgresql.service")
	if err != nil {
		return fmt.Errorf("PostgreSQL 重启失败：%s", strings.TrimSpace(string(output)))
	}
	changed = false
	return nil
}

func (a *api) databasesHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	if !a.authorized(r) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	if r.URL.Path == "/v1/databases" {
		if r.Method != http.MethodGet {
			w.Header().Set("Allow", "GET")
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		_ = json.NewEncoder(w).Encode(struct {
			Items []databaseInstance `json:"items"`
		}{a.databases.instances(r.Context())})
		return
	}
	parts := strings.Split(strings.TrimPrefix(r.URL.Path, "/v1/databases/"), "/")
	if len(parts) < 2 {
		http.NotFound(w, r)
		return
	}
	engine := parts[0]
	if keyValueEngine(engine) {
		a.keyValueDatabaseHandler(w, r, parts)
		return
	}
	if len(parts) > 3 {
		http.NotFound(w, r)
		return
	}
	instance, ok := databaseSpecByID(engine)
	if !ok || !instance.ManageUsers {
		http.NotFound(w, r)
		return
	}
	if !a.software.beginServiceAction() {
		http.Error(w, "另一个软件操作正在进行", http.StatusConflict)
		return
	}
	defer a.software.endServiceAction()
	a.databases.mu.Lock()
	defer a.databases.mu.Unlock()
	if err := a.databases.ready(r.Context(), engine); err != nil {
		http.Error(w, err.Error(), http.StatusConflict)
		return
	}
	fail := func(err error) { http.Error(w, err.Error(), http.StatusConflict) }
	decodeName := func() (string, error) {
		var input struct {
			Name string `json:"name"`
		}
		err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&input)
		if err != nil || !databaseNamePattern.MatchString(input.Name) {
			return "", errors.New("名称无效")
		}
		return input.Name, nil
	}
	switch {
	case len(parts) == 2 && parts[1] == "catalog" && r.Method == http.MethodGet:
		catalog, err := a.databases.catalog(r.Context(), engine)
		if err != nil {
			fail(err)
			return
		}
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		_ = json.NewEncoder(w).Encode(catalog)
	case len(parts) == 2 && parts[1] == "databases" && r.Method == http.MethodPost:
		name, err := decodeName()
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		if err := a.databases.createDatabase(r.Context(), engine, name); err != nil {
			fail(err)
			return
		}
		w.WriteHeader(http.StatusCreated)
	case len(parts) == 3 && parts[1] == "databases" && r.Method == http.MethodDelete:
		if err := a.databases.deleteDatabase(r.Context(), engine, parts[2]); err != nil {
			fail(err)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	case len(parts) == 2 && parts[1] == "users" && r.Method == http.MethodPost:
		name, err := decodeName()
		if err != nil || !databaseUserPattern.MatchString(name) {
			http.Error(w, "用户名无效", http.StatusBadRequest)
			return
		}
		password, err := a.databases.createUser(r.Context(), engine, name)
		if err != nil {
			fail(err)
			return
		}
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		w.WriteHeader(http.StatusCreated)
		_ = json.NewEncoder(w).Encode(databasePasswordResponse{User: name, Password: password})
	case len(parts) == 3 && parts[1] == "users" && r.Method == http.MethodDelete:
		if err := a.databases.deleteUser(r.Context(), engine, parts[2]); err != nil {
			fail(err)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	case len(parts) == 3 && parts[1] == "users" && r.Method == http.MethodPost && strings.HasSuffix(parts[2], ":reset"):
		name := strings.TrimSuffix(parts[2], ":reset")
		password, err := a.databases.resetUserPassword(r.Context(), engine, name)
		if err != nil {
			fail(err)
			return
		}
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		_ = json.NewEncoder(w).Encode(databasePasswordResponse{User: name, Password: password})
	case len(parts) == 2 && parts[1] == "grants" && (r.Method == http.MethodPost || r.Method == http.MethodDelete):
		var input struct {
			Database string `json:"database"`
			User     string `json:"user"`
			Level    string `json:"level"`
		}
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&input); err != nil {
			http.Error(w, "授权参数无效", http.StatusBadRequest)
			return
		}
		if err := a.databases.grant(r.Context(), engine, input.Database, input.User, input.Level, r.Method == http.MethodDelete); err != nil {
			fail(err)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	case len(parts) == 2 && parts[1] == "bootstrap" && engine == "mysql" && r.Method == http.MethodPost:
		password, err := a.databases.bootstrapMySQL(r.Context())
		if err != nil {
			fail(err)
			return
		}
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		_ = json.NewEncoder(w).Encode(databasePasswordResponse{User: "root", Password: password})
	case len(parts) == 2 && parts[1] == "credential" && engine == "mysql" && r.Method == http.MethodPost:
		var input struct {
			Password string `json:"password"`
		}
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&input); err != nil {
			http.Error(w, "密码参数无效", http.StatusBadRequest)
			return
		}
		if err := a.databases.setMySQLCredential(r.Context(), input.Password); err != nil {
			fail(err)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	case len(parts) == 2 && parts[1] == "local-access" && engine == "postgresql" && r.Method == http.MethodPost:
		if err := a.databases.enablePostgresLocalAccess(r.Context()); err != nil {
			fail(err)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	default:
		http.NotFound(w, r)
	}
}
