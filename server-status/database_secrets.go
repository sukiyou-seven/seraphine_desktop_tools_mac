package main

import (
	"errors"
	"os"
	"path/filepath"
)

func (dm *databaseManager) userSecretPath(engine, name string) (string, error) {
	if !databaseUserPattern.MatchString(name) || protectedDatabaseUser(name) {
		return "", errors.New("用户名无效")
	}
	if engine != "mysql" && engine != "mariadb" && engine != "postgresql" && engine != "redis" && engine != "valkey" {
		return "", errors.New("数据库类型无效")
	}
	return filepath.Join(dm.root, "server", ".sera-credentials", engine, name), nil
}

func (dm *databaseManager) saveUserSecret(engine, name, password string) error {
	path, err := dm.userSecretPath(engine, name)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	return atomicSiteWrite(path, []byte(password+"\n"), 0600)
}

func (dm *databaseManager) userSecret(engine, name string) (string, error) {
	path, err := dm.userSecretPath(engine, name)
	if err != nil {
		return "", err
	}
	return readDatabasePassword(path)
}

func (dm *databaseManager) deleteUserSecret(engine, name string) {
	path, err := dm.userSecretPath(engine, name)
	if err == nil {
		_ = os.Remove(path)
	}
}
