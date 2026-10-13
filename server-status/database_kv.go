package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

type keyValueUser struct {
	Name    string `json:"name"`
	Enabled bool   `json:"enabled"`
	Level   string `json:"level"`
}

type keyValueACLView struct {
	Persistent bool           `json:"persistent"`
	Users      []keyValueUser `json:"users"`
}

func keyValueEngine(engine string) bool { return engine == "redis" || engine == "valkey" }

func (dm *databaseManager) keyValueConfigPath(engine string) string {
	if engine == "redis" {
		return filepath.Join(dm.root, "server/redis/etc/redis.conf")
	}
	return filepath.Join(dm.root, "server/valkey/valkey.conf")
}

func (dm *databaseManager) keyValueACLPath(engine string) string {
	return filepath.Join(dm.root, "server", engine, "data/users.acl")
}

func (dm *databaseManager) keyValueAdminPath(engine string) string {
	return filepath.Join(dm.root, "server", engine, "sera-admin-password")
}

func (dm *databaseManager) keyValuePersistent(engine string) bool {
	data, err := os.ReadFile(dm.keyValueConfigPath(engine))
	if err != nil {
		return false
	}
	path := dm.keyValueACLPath(engine)
	for _, line := range strings.Split(string(data), "\n") {
		fields := strings.Fields(strings.TrimSpace(line))
		if len(fields) == 2 && fields[0] == "aclfile" && fields[1] == path {
			return true
		}
	}
	return false
}

func (dm *databaseManager) keyValueReady(ctx context.Context, engine string) error {
	if !keyValueEngine(engine) {
		return errors.New("不支持此数据库")
	}
	spec, _ := findSoftware(engine)
	item := dm.software.item(ctx, spec)
	if item.State != "installed" {
		return errors.New("请先在软件商店安装数据库")
	}
	if item.ServiceState != "active" {
		return errors.New("请先启动数据库服务")
	}
	return nil
}

func (dm *databaseManager) runKeyValueCLI(ctx context.Context, engine string, args []string, input, password string) (string, error) {
	if !keyValueEngine(engine) {
		return "", errors.New("不支持此数据库")
	}
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	binary := filepath.Join(dm.root, "server", engine, "bin", engine+"-cli")
	port := "6379"
	if engine == "valkey" {
		port = "6380"
	}
	argv := []string{"-h", "127.0.0.1", "-p", port, "--raw"}
	if input != "" {
		argv = append(argv, "-x")
	}
	argv = append(argv, args...)
	command := exec.CommandContext(ctx, binary, argv...)
	if password != "" {
		command.Env = append(os.Environ(), "REDISCLI_AUTH="+password)
	}
	if input != "" {
		command.Stdin = strings.NewReader(input)
	}
	output := &databaseOutput{}
	command.Stdout, command.Stderr = output, output
	err := command.Run()
	result := strings.TrimSpace(string(output.data))
	if err != nil || strings.HasPrefix(result, "ERR ") || strings.HasPrefix(result, "NOAUTH ") || strings.HasPrefix(result, "NOPERM ") || strings.HasPrefix(result, "WRONGPASS ") {
		if len(result) > 1200 {
			result = result[:1200]
		}
		if result == "" {
			result = "Redis/Valkey 命令失败"
		}
		return "", errors.New(result)
	}
	return result, nil
}

func (dm *databaseManager) keyValueQuery(ctx context.Context, engine string, args []string, input string) (string, error) {
	password := ""
	if saved, err := readDatabasePassword(dm.keyValueAdminPath(engine)); err == nil {
		password = saved
	} else if !errors.Is(err, os.ErrNotExist) {
		return "", err
	}
	return dm.kvRun(ctx, engine, args, input, password)
}

func (dm *databaseManager) keyValueSaveACL(ctx context.Context, engine string) error {
	if err := dm.keyValueSecureDataDir(engine); err != nil {
		return err
	}
	if _, err := dm.keyValueQuery(ctx, engine, []string{"ACL", "SAVE"}, ""); err != nil {
		return err
	}
	// Valkey's ACL SAVE may recreate the file with a permissive mode. Restrict the
	// resulting inode directly and refuse symlinks, even for older service units.
	fd, err := syscall.Open(dm.keyValueACLPath(engine), syscall.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return err
	}
	defer syscall.Close(fd)
	var info syscall.Stat_t
	if err := syscall.Fstat(fd, &info); err != nil {
		return err
	}
	if info.Mode&syscall.S_IFMT != syscall.S_IFREG {
		return errors.New("ACL 文件不是普通文件")
	}
	return syscall.Fchmod(fd, 0600)
}

func (dm *databaseManager) keyValueSecureDataDir(engine string) error {
	path := filepath.Join(dm.root, "server", engine, "data")
	info, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if !info.IsDir() {
		return errors.New("数据库数据目录不是普通目录")
	}
	return os.Chmod(path, 0700)
}

func parseKeyValueACL(output string) ([]keyValueUser, map[string]string) {
	users := []keyValueUser{}
	rules := map[string]string{}
	for _, line := range strings.Split(output, "\n") {
		fields := strings.Fields(line)
		if len(fields) < 3 || fields[0] != "user" {
			continue
		}
		name := fields[1]
		if len(name) > 256 {
			continue
		}
		user := keyValueUser{Name: name, Level: "custom"}
		for _, flag := range fields[2:] {
			switch flag {
			case "on":
				user.Enabled = true
			case "+@read":
				if user.Level == "custom" {
					user.Level = "read"
				}
			case "+@write":
				user.Level = "readwrite"
			case "+@all":
				user.Level = "admin"
			}
		}
		users = append(users, user)
		rules[name] = line
	}
	return users, rules
}

func (dm *databaseManager) keyValueACL(ctx context.Context, engine string) (keyValueACLView, map[string]string, error) {
	output, err := dm.keyValueQuery(ctx, engine, []string{"ACL", "LIST"}, "")
	if err != nil {
		return keyValueACLView{}, nil, err
	}
	users, rules := parseKeyValueACL(output)
	return keyValueACLView{Persistent: dm.keyValuePersistent(engine), Users: users}, rules, nil
}

func (dm *databaseManager) keyValueSetAdminCredential(ctx context.Context, engine, password string) error {
	if len(password) < 8 || len(password) > 512 || strings.ContainsAny(password, "\r\n\x00") {
		return errors.New("管理员密码须为 8 至 512 字符")
	}
	if _, err := dm.kvRun(ctx, engine, []string{"ACL", "LIST"}, "", password); err != nil {
		return err
	}
	return atomicSiteWrite(dm.keyValueAdminPath(engine), []byte(password+"\n"), 0600)
}

func writeKeyValueACLFile(path, value string) error {
	dir, err := os.Stat(filepath.Dir(path))
	if err != nil {
		return err
	}
	owner, ok := dir.Sys().(*syscall.Stat_t)
	if !ok || !dir.IsDir() {
		return errors.New("无法读取数据库数据目录所有者")
	}
	file, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	remove := true
	defer func() {
		if remove {
			_ = os.Remove(path)
		}
	}()
	if err := file.Chown(int(owner.Uid), int(owner.Gid)); err != nil {
		_ = file.Close()
		return err
	}
	if _, err := file.WriteString(value); err != nil {
		_ = file.Close()
		return err
	}
	if err := file.Sync(); err != nil {
		_ = file.Close()
		return err
	}
	if err := file.Close(); err != nil {
		return err
	}
	remove = false
	return nil
}

func (dm *databaseManager) keyValueEnableACL(ctx context.Context, engine string) error {
	if dm.keyValuePersistent(engine) {
		return nil
	}
	configPath := dm.keyValueConfigPath(engine)
	config, info, err := databaseConfigSnapshot(configPath)
	if err != nil {
		return err
	}
	for _, line := range strings.Split(string(config), "\n") {
		fields := strings.Fields(strings.TrimSpace(line))
		if len(fields) == 0 || strings.HasPrefix(fields[0], "#") {
			continue
		}
		if fields[0] == "aclfile" || fields[0] == "requirepass" || fields[0] == "user" {
			return errors.New("已存在自定义认证配置，请先手动核对")
		}
	}
	rawRules, err := dm.keyValueQuery(ctx, engine, []string{"ACL", "LIST"}, "")
	if err != nil {
		return err
	}
	if len(rawRules) >= 250<<10 {
		return errors.New("ACL 账户列表过大，拒绝不完整迁移")
	}
	lines := strings.Split(rawRules, "\n")
	if len(lines) == 0 {
		return errors.New("无法读取默认账户")
	}
	for _, line := range lines {
		if !strings.HasPrefix(line, "user ") {
			return errors.New("ACL 账户列表格式无效")
		}
	}
	aclPath := dm.keyValueACLPath(engine)
	if err := dm.keyValueSecureDataDir(engine); err != nil {
		return err
	}
	if err := writeKeyValueACLFile(aclPath, strings.Join(lines, "\n")+"\n"); err != nil {
		return err
	}
	changed := false
	defer func() {
		if !changed {
			return
		}
		_ = writeDatabaseConfig(configPath, config, info)
		rollback, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		_, _ = dm.software.systemctl(rollback, "restart", "sera-"+engine+".service")
		cancel()
		_ = os.Remove(aclPath)
	}()
	changed = true
	newConfig := append(append([]byte{}, config...), []byte("\n# Seraphim ACL persistence\naclfile "+aclPath+"\n")...)
	if err := writeDatabaseConfig(configPath, newConfig, info); err != nil {
		return err
	}
	restart, cancel := context.WithTimeout(ctx, 30*time.Second)
	output, err := dm.software.systemctl(restart, "restart", "sera-"+engine+".service")
	cancel()
	if err != nil {
		return fmt.Errorf("数据库重启失败：%s", strings.TrimSpace(string(output)))
	}
	readyCtx, readyCancel := context.WithTimeout(ctx, 8*time.Second)
	defer readyCancel()
	for {
		if _, err := dm.keyValueQuery(readyCtx, engine, []string{"ACL", "LIST"}, ""); err == nil {
			break
		} else if readyCtx.Err() != nil {
			return fmt.Errorf("数据库重启后未就绪：%w", err)
		}
		select {
		case <-time.After(150 * time.Millisecond):
		case <-readyCtx.Done():
			return errors.New("数据库重启后未就绪")
		}
	}
	if err := dm.keyValueSaveACL(ctx, engine); err != nil {
		return fmt.Errorf("ACL 持久化失败：%w", err)
	}
	changed = false
	return nil
}

func keyValueLevelArguments(level string) ([]string, error) {
	switch level {
	case "read":
		return []string{"+@read", "+@connection", "-@dangerous"}, nil
	case "readwrite":
		return []string{"+@read", "+@write", "+@connection", "-@dangerous"}, nil
	default:
		return nil, errors.New("权限须为只读或读写")
	}
}

func (dm *databaseManager) keyValueRestoreUser(ctx context.Context, engine, name, rule string) {
	fields := strings.Fields(rule)
	if len(fields) < 3 || fields[0] != "user" || fields[1] != name {
		return
	}
	_, _ = dm.keyValueQuery(ctx, engine, append([]string{"ACL", "SETUSER", name, "reset"}, fields[2:]...), "")
	_ = dm.keyValueSaveACL(ctx, engine)
}

func (dm *databaseManager) keyValueCreateUser(ctx context.Context, engine, name, level string) (string, error) {
	if protectedDatabaseUser(name) || name == "default" {
		return "", errors.New("用户名无效或属于系统账户")
	}
	permissions, err := keyValueLevelArguments(level)
	if err != nil {
		return "", err
	}
	view, rules, err := dm.keyValueACL(ctx, engine)
	if err != nil {
		return "", err
	}
	if !view.Persistent {
		return "", errors.New("请先启用 ACL 持久化")
	}
	if _, exists := rules[name]; exists {
		return "", errors.New("账户已存在")
	}
	password, err := generateDatabasePassword()
	if err != nil {
		return "", err
	}
	args := append([]string{"ACL", "SETUSER", name, "reset", "on", "~*", "&*"}, permissions...)
	if _, err := dm.keyValueQuery(ctx, engine, args, ">"+password); err != nil {
		return "", err
	}
	if err := dm.keyValueSaveACL(ctx, engine); err != nil {
		rollback, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		_, _ = dm.keyValueQuery(rollback, engine, []string{"ACL", "DELUSER", name}, "")
		cancel()
		return "", err
	}
	if err := dm.saveUserSecret(engine, name, password); err != nil {
		return password, fmt.Errorf("ACL 账户已创建，但保存密码失败：%w", err)
	}
	return password, nil
}

func (dm *databaseManager) keyValueDeleteUser(ctx context.Context, engine, name string) error {
	if protectedDatabaseUser(name) || name == "default" {
		return errors.New("不可删除系统账户")
	}
	view, rules, err := dm.keyValueACL(ctx, engine)
	if err != nil {
		return err
	}
	if !view.Persistent {
		return errors.New("请先启用 ACL 持久化")
	}
	rule, exists := rules[name]
	if !exists {
		return os.ErrNotExist
	}
	if _, err := dm.keyValueQuery(ctx, engine, []string{"ACL", "DELUSER", name}, ""); err != nil {
		return err
	}
	if err := dm.keyValueSaveACL(ctx, engine); err != nil {
		rollback, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		dm.keyValueRestoreUser(rollback, engine, name, rule)
		cancel()
		return err
	}
	dm.deleteUserSecret(engine, name)
	return nil
}

func (dm *databaseManager) keyValueResetUser(ctx context.Context, engine, name string) (string, error) {
	if protectedDatabaseUser(name) || name == "default" {
		return "", errors.New("不可重置系统账户")
	}
	view, rules, err := dm.keyValueACL(ctx, engine)
	if err != nil {
		return "", err
	}
	if !view.Persistent {
		return "", errors.New("请先启用 ACL 持久化")
	}
	rule, exists := rules[name]
	if !exists {
		return "", os.ErrNotExist
	}
	password, err := generateDatabasePassword()
	if err != nil {
		return "", err
	}
	if _, err := dm.keyValueQuery(ctx, engine, []string{"ACL", "SETUSER", name, "resetpass"}, ">"+password); err != nil {
		return "", err
	}
	if err := dm.keyValueSaveACL(ctx, engine); err != nil {
		rollback, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		dm.keyValueRestoreUser(rollback, engine, name, rule)
		cancel()
		return "", err
	}
	if err := dm.saveUserSecret(engine, name, password); err != nil {
		return password, fmt.Errorf("ACL 密码已更改，但保存密码失败：%w", err)
	}
	return password, nil
}

func (dm *databaseManager) keyValueUpdateUser(ctx context.Context, engine, name, level string, enabled bool) error {
	if protectedDatabaseUser(name) || name == "default" {
		return errors.New("不可修改系统账户")
	}
	permissions, err := keyValueLevelArguments(level)
	if err != nil {
		return err
	}
	view, rules, err := dm.keyValueACL(ctx, engine)
	if err != nil {
		return err
	}
	if !view.Persistent {
		return errors.New("请先启用 ACL 持久化")
	}
	rule, exists := rules[name]
	if !exists {
		return os.ErrNotExist
	}
	flag := "off"
	if enabled {
		flag = "on"
	}
	args := append([]string{"ACL", "SETUSER", name, flag, "-@all"}, permissions...)
	if _, err := dm.keyValueQuery(ctx, engine, args, ""); err != nil {
		return err
	}
	if err := dm.keyValueSaveACL(ctx, engine); err != nil {
		rollback, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		dm.keyValueRestoreUser(rollback, engine, name, rule)
		cancel()
		return err
	}
	return nil
}

func (a *api) keyValueDatabaseHandler(w http.ResponseWriter, r *http.Request, parts []string) {
	if !a.software.beginServiceAction() {
		http.Error(w, "另一个软件操作正在进行", http.StatusConflict)
		return
	}
	defer a.software.endServiceAction()
	a.databases.mu.Lock()
	defer a.databases.mu.Unlock()
	engine := parts[0]
	if r.Method == http.MethodGet && len(parts) == 4 && parts[1] == "acl" && parts[2] == "users" && strings.HasSuffix(parts[3], ":password") {
		name := strings.TrimSuffix(parts[3], ":password")
		password, err := a.databases.userSecret(engine, name)
		if err != nil {
			http.Error(w, "没有已保存的密码", http.StatusNotFound)
			return
		}
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		_ = json.NewEncoder(w).Encode(databasePasswordResponse{User: name, Password: password})
		return
	}
	if r.Method == http.MethodGet && len(parts) == 3 && parts[1] == "acl" && parts[2] == "credential" {
		password, err := readDatabasePassword(a.databases.keyValueAdminPath(engine))
		if err != nil {
			http.Error(w, "没有已保存的密码", http.StatusNotFound)
			return
		}
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		_ = json.NewEncoder(w).Encode(databasePasswordResponse{User: "default", Password: password})
		return
	}
	if err := a.databases.keyValueReady(r.Context(), engine); err != nil {
		http.Error(w, err.Error(), http.StatusConflict)
		return
	}
	fail := func(err error) {
		if errors.Is(err, os.ErrNotExist) {
			http.Error(w, "账户不存在", http.StatusNotFound)
		} else {
			http.Error(w, err.Error(), http.StatusConflict)
		}
	}
	decode := func(target any) error { return json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(target) }
	switch {
	case len(parts) == 2 && parts[1] == "acl" && r.Method == http.MethodGet:
		view, _, err := a.databases.keyValueACL(r.Context(), engine)
		if err != nil {
			fail(err)
			return
		}
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		_ = json.NewEncoder(w).Encode(view)
	case len(parts) == 3 && parts[1] == "acl" && parts[2] == "enable" && r.Method == http.MethodPost:
		if err := a.databases.keyValueEnableACL(r.Context(), engine); err != nil {
			fail(err)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	case len(parts) == 3 && parts[1] == "acl" && parts[2] == "credential" && r.Method == http.MethodPost:
		var input struct {
			Password string `json:"password"`
		}
		if err := decode(&input); err != nil {
			http.Error(w, "密码参数无效", 400)
			return
		}
		if err := a.databases.keyValueSetAdminCredential(r.Context(), engine, input.Password); err != nil {
			fail(err)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	case len(parts) == 3 && parts[1] == "acl" && parts[2] == "users" && r.Method == http.MethodPost:
		var input struct {
			Name  string `json:"name"`
			Level string `json:"level"`
		}
		if err := decode(&input); err != nil {
			http.Error(w, "账户参数无效", 400)
			return
		}
		password, err := a.databases.keyValueCreateUser(r.Context(), engine, input.Name, input.Level)
		if err != nil {
			fail(err)
			return
		}
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		w.WriteHeader(http.StatusCreated)
		_ = json.NewEncoder(w).Encode(databasePasswordResponse{User: input.Name, Password: password})
	case len(parts) == 4 && parts[1] == "acl" && parts[2] == "users" && r.Method == http.MethodDelete:
		if err := a.databases.keyValueDeleteUser(r.Context(), engine, parts[3]); err != nil {
			fail(err)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	case len(parts) == 4 && parts[1] == "acl" && parts[2] == "users" && strings.HasSuffix(parts[3], ":reset") && r.Method == http.MethodPost:
		name := strings.TrimSuffix(parts[3], ":reset")
		password, err := a.databases.keyValueResetUser(r.Context(), engine, name)
		if err != nil {
			fail(err)
			return
		}
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		_ = json.NewEncoder(w).Encode(databasePasswordResponse{User: name, Password: password})
	case len(parts) == 4 && parts[1] == "acl" && parts[2] == "users" && r.Method == http.MethodPut:
		var input struct {
			Level   string `json:"level"`
			Enabled bool   `json:"enabled"`
		}
		if err := decode(&input); err != nil {
			http.Error(w, "权限参数无效", 400)
			return
		}
		if err := a.databases.keyValueUpdateUser(r.Context(), engine, parts[3], input.Level, input.Enabled); err != nil {
			fail(err)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	default:
		http.NotFound(w, r)
	}
}
