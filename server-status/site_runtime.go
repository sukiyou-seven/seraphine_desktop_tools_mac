package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
	"time"
)

// 网站的运行身份
//
// 面板主程序以 root 运行，只做必须特权的事：绑 80/443、管 systemd、写 /etc。
// 网站与项目的内容进程统一交给共享的 sera 账户（见 projects.go 的 sharedAccount）：
//
//   - 站点目录归 sera 所有、权限 0750，PHP 也以 sera 运行，所以它终于能在自己的
//     目录里写文件、建上传目录（旧实现里站点目录归 root，WordPress 装不了插件、
//     上传目录建不出来）；
//   - Web 服务的工作进程同样是 sera（nginx/openresty 的 user 指令、Apache 的
//     User/Group），因此天然读得到站点内容、也连得上 PHP-FPM 的 Unix socket；
//   - 数据库、中间件这些各有独立账户的软件仍然进不来——它们既不是属主，也不在
//     sera 组里。
//
// 装好之后服务器上只有两种身份：root 与 sera。找一个文件为什么读不到时，不必
// 再逐个猜某个网站、某个项目用的是哪个账户。

// prepareSiteRoot 让站点目录归共享业务账户所有，权限 0750。
// 目录里已有的文件和子目录同样改属，否则面板上传过的文件仍是 root 所有，站点里
// 的 PHP 反而改不动。整树已对齐时直接返回，避免每次保存网站都遍历一遍站点文件。
func (sm *siteManager) prepareSiteRoot(item site) error {
	info, err := os.Lstat(item.Root)
	if err != nil || !info.IsDir() {
		return fmt.Errorf("站点目录无效：%s", item.Root)
	}
	uid, gid, err := sm.ensureUser()
	if err != nil {
		return err
	}
	aligned := false
	if stat, ok := info.Sys().(*syscall.Stat_t); ok && int(stat.Uid) == uid && int(stat.Gid) == gid {
		aligned, err = siteTreeOwnedBy(item.Root, uid, gid)
		if err != nil {
			return err
		}
	}
	if err := os.Chown(item.Root, uid, gid); err != nil {
		return err
	}
	if err := os.Chmod(item.Root, 0750); err != nil {
		return err
	}
	if aligned {
		return nil
	}
	return chownTree(item.Root, uid, gid)
}

// siteTreeOwnedBy 判断站点目录的一级内容是否都已属于目标账户。
func siteTreeOwnedBy(root string, uid, gid int) (bool, error) {
	entries, err := os.ReadDir(root)
	if err != nil {
		return false, err
	}
	for _, entry := range entries {
		info, err := entry.Info()
		if err != nil {
			return false, err
		}
		if stat, ok := info.Sys().(*syscall.Stat_t); !ok || int(stat.Uid) != uid || int(stat.Gid) != gid {
			return false, nil
		}
	}
	return true, nil
}

// phpPrefix 返回该 PHP 版本实际安装的前缀，新版布局优先。
func (sm *siteManager) phpPrefix(version string) (string, error) {
	if !versionPattern.MatchString(version) {
		return "", errors.New("请选择已安装的 PHP 版本")
	}
	for _, prefix := range []string{
		filepath.Join(sm.root, "server", "php", "versions", version),
		filepath.Join(sm.root, "server", "php"),
	} {
		if directory, err := os.Lstat(prefix); err != nil || !directory.IsDir() {
			continue
		}
		marker, err := os.Lstat(filepath.Join(prefix, ".sera-installed"))
		if err != nil || !marker.Mode().IsRegular() {
			continue
		}
		if data, err := os.ReadFile(filepath.Join(prefix, ".sera-installed")); err == nil && strings.TrimSpace(string(data)) == version {
			return prefix, nil
		}
	}
	return "", fmt.Errorf("PHP %s 尚未安装，请先在环境管理安装", version)
}

// phpTarget 返回该版本 FPM 的监听地址。
// 默认版本沿用安装脚本写死的 TCP 端口，版本化安装用各自前缀下的 Unix socket。
func (sm *siteManager) phpTarget(version string) (string, error) {
	prefix, err := sm.phpPrefix(version)
	if err != nil {
		return "", err
	}
	if prefix == filepath.Join(sm.root, "server", "php") {
		return "127.0.0.1:9000", nil
	}
	return "unix:" + filepath.Join(prefix, "run", "php-fpm.sock"), nil
}

// phpUnitName 返回该版本对应的 FPM 服务单元名。
func (sm *siteManager) phpUnitName(version string) string {
	if prefix, err := sm.phpPrefix(version); err == nil && prefix != filepath.Join(sm.root, "server", "php") {
		return "sera-php-" + version + ".service"
	}
	return "sera-php.service"
}

// phpLogDirectory 返回该版本 FPM 的日志目录，与安装脚本建立的位置一致。
func phpLogDirectory(root, prefix string) string {
	if prefix == filepath.Join(root, "server", "php") {
		return filepath.Join(root, "logs", "php")
	}
	return filepath.Join(root, "logs", "php-"+filepath.Base(prefix))
}

// phpAccountDirective 匹配需要改写为共享账户的指令行：池配置里的 user/group/
// listen.owner/listen.group，以及单元里的 User=/Group=。
var phpAccountDirective = regexp.MustCompile(`(?m)^(\s*(?:user|group|listen\.owner|listen\.group)\s*=\s*|(?:User|Group)=)seraphim-web\s*$`)

// legacyPHPAccount 是早期安装把 PHP-FPM 交给的账户。它读不到（更写不了）站点目录。
const legacyPHPAccount = "seraphim-web"

// reconcilePHPRuntime 把 FPM 的运行账户校正为共享账户。
//
// 升级前 FPM 以 seraphim-web 运行，站点目录归 root，于是 PHP 只能读、不能写。
// 现在站点目录改归 sera，如果 FPM 仍带旧身份启动，连读都读不到——所以单元与池
// 配置必须一起改写，run 目录与日志目录的属主也要跟着走。
func (sm *siteManager) reconcilePHPRuntime(ctx context.Context, prefix, unitName string) error {
	updated := false
	for _, path := range []string{
		filepath.Join(sm.unitDir, unitName),
		filepath.Join(prefix, "etc", "php-fpm.conf"),
	} {
		data, err := os.ReadFile(path)
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			return err
		}
		if !strings.Contains(string(data), legacyPHPAccount) {
			continue
		}
		next := phpAccountDirective.ReplaceAllString(string(data), "${1}"+sharedAccount)
		if next == string(data) {
			continue
		}
		if err := atomicSiteWrite(path, []byte(next), 0644); err != nil {
			return err
		}
		updated = true
	}
	uid, gid, err := sm.ensureUser()
	if err != nil {
		return err
	}
	// socket 目录与日志目录都得归共享账户：FPM 以它运行，要往里写 pid、socket
	// 与日志。socket 目录同时保留组可进入（0750），Web 服务才够得着 socket。
	for _, directory := range []string{filepath.Join(prefix, "run"), phpLogDirectory(sm.root, prefix)} {
		info, err := os.Lstat(directory)
		if err != nil || !info.IsDir() {
			continue
		}
		if stat, ok := info.Sys().(*syscall.Stat_t); ok && int(stat.Uid) == uid && int(stat.Gid) == gid {
			continue
		}
		if err := chownTree(directory, uid, gid); err != nil {
			return err
		}
		if err := os.Chmod(directory, 0750); err != nil {
			return err
		}
		updated = true
	}
	if !updated {
		return nil
	}
	if _, err := sm.software.systemctl(ctx, "daemon-reload"); err != nil {
		return fmt.Errorf("systemctl daemon-reload: %w", err)
	}
	// 运行中的实例不会重读池配置与单元，换过账户就必须重启一次。
	if output, err := sm.software.systemctl(ctx, "restart", unitName); err != nil {
		return fmt.Errorf("重启 PHP 服务失败：%s", strings.TrimSpace(string(output)))
	}
	return nil
}

// phpPrefixes 返回所有已安装 PHP 版本的前缀，用于清理旧的站点专属配置。
func (sm *siteManager) phpPrefixes() []string {
	prefixes := []string{filepath.Join(sm.root, "server", "php")}
	for _, version := range sm.phpVersions() {
		prefixes = append(prefixes, filepath.Join(sm.root, "server", "php", "versions", version))
	}
	return prefixes
}

// removeLegacySiteFPM 清理上一版遗留的「每个网站一个 PHP-FPM 实例」。
//
// 那套做法已被共享账户取代：现在所有网站共用一个版本的 FPM，运行时不再有站点
// 专属单元。但旧安装留下的单元会一直跑着占资源，而且排错时看到两套互相矛盾的
// PHP 服务。这里按单元名把它们停掉、删掉，并顺手收走配套的池配置与运行目录。
func (sm *siteManager) removeLegacySiteFPM(ctx context.Context) {
	entries, err := os.ReadDir(sm.unitDir)
	if err != nil {
		return
	}
	removed := false
	for _, entry := range entries {
		name := entry.Name()
		if !strings.HasPrefix(name, "sera-php-site-") || !strings.HasSuffix(name, ".service") {
			continue
		}
		_, _ = sm.software.systemctl(ctx, "disable", "--now", name)
		if err := os.Remove(filepath.Join(sm.unitDir, name)); err == nil {
			removed = true
		}
	}
	if !removed {
		return
	}
	for _, prefix := range sm.phpPrefixes() {
		_ = os.RemoveAll(filepath.Join(prefix, "etc", "sites"))
	}
	_ = os.RemoveAll(filepath.Join(sm.root, "run", "sites"))
	_, _ = sm.software.systemctl(ctx, "daemon-reload")
}

// ensurePHP 启动该版本对应的 FPM 服务，等它就绪。
func (sm *siteManager) ensurePHP(ctx context.Context, version string) error {
	sm.removeLegacySiteFPM(ctx)
	target, err := sm.phpTarget(version)
	if err != nil {
		return err
	}
	prefix, err := sm.phpPrefix(version)
	if err != nil {
		return err
	}
	unitName := sm.phpUnitName(version)
	if strings.HasPrefix(target, "unix:") {
		// socket 目录通常由安装脚本建好；缺失时补上，否则 FPM 报配置错误启动失败。
		socketDir := filepath.Dir(strings.TrimPrefix(target, "unix:"))
		if err := os.MkdirAll(socketDir, 0750); err != nil {
			return err
		}
	}
	if err := sm.reconcilePHPRuntime(ctx, prefix, unitName); err != nil {
		return err
	}
	if output, err := sm.software.systemctl(ctx, "is-active", unitName); err != nil || strings.TrimSpace(string(output)) != "active" {
		if output, err = sm.software.systemctl(ctx, "start", unitName); err != nil {
			return fmt.Errorf("启动 PHP 服务失败：%s", strings.TrimSpace(string(output)))
		}
	}
	deadline := time.Now().Add(8 * time.Second)
	for time.Now().Before(deadline) && ctx.Err() == nil {
		output, err := sm.software.systemctl(ctx, "is-active", unitName)
		if err == nil && strings.TrimSpace(string(output)) == "active" && sm.phpReady(target) {
			return nil
		}
		time.Sleep(150 * time.Millisecond)
	}
	return fmt.Errorf("PHP %s 服务未就绪，请检查 %s", version, phpLogDirectory(sm.root, prefix))
}
