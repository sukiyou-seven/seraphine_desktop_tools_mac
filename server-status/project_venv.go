package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

func (pm *projectManager) pythonBase(item project) string {
	return filepath.Join(pm.runtimeBase("python", item.RuntimeVersion), "bin", "python3")
}

func (pm *projectManager) venvReady(item project) bool {
	if item.Runtime != "python" || !item.UseVenv || !pm.runtimeReadyVersion("python", item.RuntimeVersion) {
		return false
	}
	dir := pm.venvDir(item.ID)
	info, err := os.Lstat(dir)
	if err != nil || !info.IsDir() {
		return false
	}
	marker, err := os.ReadFile(filepath.Join(dir, ".sera-python-base"))
	if err != nil || strings.TrimSpace(string(marker)) != pm.pythonBase(item) {
		return false
	}
	if info, err := os.Lstat(filepath.Join(dir, "pyvenv.cfg")); err != nil || !info.Mode().IsRegular() {
		return false
	}
	python, err := os.Stat(filepath.Join(dir, "bin", "python3"))
	return err == nil && python.Mode().IsRegular() && python.Mode().Perm()&0111 != 0
}

func (pm *projectManager) runAsProject(ctx context.Context, item project, binary string, args []string, log *os.File) error {
	uid, gid, err := pm.ensureUser()
	if err != nil {
		return err
	}
	cmd := exec.CommandContext(ctx, binary, args...)
	cmd.Dir = pm.projectDir(item.ID)
	cmd.Env = []string{
		"HOME=" + pm.dataDir(item.ID),
		"PATH=" + filepath.Dir(binary) + ":/usr/local/bin:/usr/bin:/bin",
		"PIP_CACHE_DIR=" + filepath.Join(pm.dataDir(item.ID), "pip-cache"),
		"PIP_DISABLE_PIP_VERSION_CHECK=1",
	}
	cmd.Stdout, cmd.Stderr = log, log
	setProjectCredential(cmd, uid, gid)
	return cmd.Run()
}

func (pm *projectManager) manageVenv(ctx context.Context, id, action string) error {
	if action != "create" && action != "install_requirements" {
		return errors.New("不支持此虚拟环境操作")
	}
	if !pm.software.beginServiceAction() {
		return errors.New("另一个软件操作正在进行")
	}
	defer pm.software.endServiceAction()
	pm.mu.Lock()
	defer pm.mu.Unlock()
	item, err := pm.read(id)
	if err != nil {
		return err
	}
	if item.Runtime != "python" || !item.UseVenv {
		return errors.New("项目未启用 Python 虚拟环境")
	}
	if !pm.runtimeReadyVersion("python", item.RuntimeVersion) {
		return errors.New("请先安装项目所选的 Python 版本")
	}
	if pm.state(ctx, item).ActiveState == "active" {
		return errors.New("请先停止项目，再修改虚拟环境")
	}
	if err := pm.prepareDirectories(id); err != nil {
		return err
	}
	if err := pm.workingDirectoryReady(item); err != nil {
		return err
	}
	log, err := os.OpenFile(pm.logPath(id), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0600)
	if err != nil {
		return err
	}
	defer log.Close()
	_, _ = fmt.Fprintf(log, "\n[%s] Python 虚拟环境：%s\n", time.Now().Format(time.RFC3339), action)
	work, cancel := context.WithTimeout(ctx, 10*time.Minute)
	defer cancel()
	if action == "install_requirements" {
		if !pm.venvReady(item) {
			return errors.New("请先创建与所选 Python 版本匹配的虚拟环境")
		}
		requirements := filepath.Join(item.Directory, "requirements.txt")
		info, err := os.Lstat(requirements)
		if err != nil || !info.Mode().IsRegular() {
			return errors.New("工程目录中缺少普通文件 requirements.txt")
		}
		err = pm.runAsProject(work, item, filepath.Join(pm.venvDir(id), "bin", "python3"),
			[]string{"-m", "pip", "install", "--no-input", "-r", requirements}, log)
		if err != nil {
			return fmt.Errorf("安装项目依赖失败：%w；请查看项目日志", err)
		}
		return nil
	}
	venv := pm.venvDir(id)
	if pm.venvReady(item) {
		return errors.New("虚拟环境已存在")
	}
	backup := ""
	if _, err := os.Lstat(venv); err == nil {
		backupDir := filepath.Join(pm.root, "backup", "projects", id)
		if err := os.MkdirAll(backupDir, 0700); err != nil {
			return err
		}
		backup = filepath.Join(backupDir, "venv-"+time.Now().Format("20060102-150405"))
		if err := os.Rename(venv, backup); err != nil {
			return err
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	complete := false
	defer func() {
		if !complete {
			_ = os.RemoveAll(venv)
			if backup != "" {
				_ = os.Rename(backup, venv)
			}
		}
	}()
	if err := pm.runAsProject(work, item, pm.pythonBase(item), []string{"-m", "venv", venv}, log); err != nil {
		return fmt.Errorf("创建虚拟环境失败：%w；请查看项目日志", err)
	}
	if err := atomicSiteWrite(filepath.Join(venv, ".sera-python-base"), []byte(pm.pythonBase(item)+"\n"), 0644); err != nil {
		return err
	}
	if !pm.venvReady(item) {
		return errors.New("虚拟环境创建后校验失败；请查看项目日志")
	}
	complete = true
	return nil
}
