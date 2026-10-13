package main

import (
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	_ "embed"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

//go:embed server-status.service
var installServiceUnit []byte

type installResult struct {
	Endpoint    string `json:"endpoint"`
	Token       string `json:"token"`
	Fingerprint string `json:"fingerprint"`
}

func validateInstallHost(host string) error {
	if host == "" || len(host) > 253 {
		return errors.New("-host must be a DNS name or IP address without a port")
	}
	if net.ParseIP(host) != nil {
		return nil
	}
	for _, label := range strings.Split(host, ".") {
		if len(label) == 0 || len(label) > 63 || label[0] == '-' || label[len(label)-1] == '-' {
			return errors.New("-host must be a DNS name or IP address without a port")
		}
		for _, ch := range label {
			if !(ch >= 'a' && ch <= 'z' || ch >= 'A' && ch <= 'Z' || ch >= '0' && ch <= '9' || ch == '-') {
				return errors.New("-host must be a DNS name or IP address without a port")
			}
		}
	}
	return nil
}

func installCommand(args []string) error {
	flags := flag.NewFlagSet("install", flag.ContinueOnError)
	host := flags.String("host", "", "DNS name or IP address used by the client")
	jsonOutput := flags.Bool("json", false, "print connection details as JSON")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return errors.New("unexpected install arguments")
	}
	if err := validateInstallHost(*host); err != nil {
		return err
	}
	if ip := net.ParseIP(*host); ip != nil && ip.To4() == nil {
		return errors.New("install currently requires an IPv4 address or DNS name")
	}
	if runtime.GOOS != "linux" {
		return errors.New("install requires Linux")
	}
	if os.Geteuid() != 0 {
		return errors.New("install requires root; run with sudo")
	}
	if _, err := os.Stat("/run/systemd/system"); err != nil {
		return errors.New("install requires a running systemd system")
	}
	if _, err := exec.LookPath("systemctl"); err != nil {
		return errors.New("systemctl is unavailable")
	}
	const base = "/www/seraphim"
	binary := filepath.Join(base, "server/sera")
	unit := "/etc/systemd/system/server-status.service"
	config := filepath.Join(base, "server/config")
	if info, err := os.Lstat(binary); err == nil {
		if !info.Mode().IsRegular() {
			return errors.New("现有服务端程序不是普通文件，无法覆盖安装")
		}
		return upgradeInstallation(*host, *jsonOutput, binary, unit, config)
	} else if !os.IsNotExist(err) {
		return err
	}
	if err := exec.Command("systemctl", "cat", "server-status").Run(); err == nil {
		return errors.New("检测到服务单元但没有服务端程序，请先修复不完整的安装")
	}
	for _, path := range []string{binary, unit, filepath.Join(config, "server.crt"), filepath.Join(config, "server.key"), filepath.Join(config, "token")} {
		if _, err := os.Lstat(path); err == nil {
			return fmt.Errorf("%s already exists; refusing to replace an installation", path)
		} else if !os.IsNotExist(err) {
			return err
		}
	}
	for _, item := range []struct {
		path string
		mode os.FileMode
	}{
		{"/www", 0755}, {base, 0755}, {filepath.Join(base, "server"), 0755},
		{filepath.Join(base, "web"), 0755}, {filepath.Join(base, "sites"), 0755},
		{filepath.Join(base, "projects"), 0755}, {filepath.Join(base, "download"), 0755},
		{filepath.Join(base, "backup"), 0700}, {filepath.Join(base, "logs"), 0750},
		{filepath.Join(base, "tmp"), 0700}, {config, 0700},
	} {
		if err := os.MkdirAll(item.path, item.mode); err != nil {
			return err
		}
	}

	source, err := os.Executable()
	if err != nil {
		return err
	}
	in, err := os.Open(source)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.OpenFile(binary, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0755)
	if err != nil {
		return err
	}
	_, copyErr := io.Copy(out, in)
	closeErr := out.Close()
	if copyErr != nil || closeErr != nil {
		_ = os.Remove(binary)
		if copyErr != nil {
			return copyErr
		}
		return closeErr
	}
	installed := false
	defer func() {
		if installed {
			return
		}
		_ = exec.Command("systemctl", "disable", "--now", "server-status").Run()
		_ = os.Remove(unit)
		_ = os.Remove(binary)
		for _, name := range []string{"server.crt", "server.key", "token"} {
			_ = os.Remove(filepath.Join(config, name))
		}
		_ = exec.Command("systemctl", "daemon-reload").Run()
	}()
	fingerprint, token, err := initializeCredentials(*host, config)
	if err != nil {
		return err
	}
	if err := os.WriteFile(unit, installServiceUnit, 0644); err != nil {
		return err
	}
	if output, err := exec.Command("systemctl", "daemon-reload").CombinedOutput(); err != nil {
		return fmt.Errorf("systemctl daemon-reload: %w: %s", err, strings.TrimSpace(string(output)))
	}
	if output, err := exec.Command("systemctl", "enable", "--now", "server-status").CombinedOutput(); err != nil {
		return fmt.Errorf("systemctl enable: %w: %s", err, strings.TrimSpace(string(output)))
	}
	if output, err := exec.Command("systemctl", "is-active", "--quiet", "server-status").CombinedOutput(); err != nil {
		return fmt.Errorf("server-status did not start: %w: %s", err, strings.TrimSpace(string(output)))
	}
	if err := verifyInstalledAPI(*host, filepath.Join(config, "server.crt"), token, "https://127.0.0.1:27520/v1/status"); err != nil {
		return fmt.Errorf("server-status HTTPS check failed: %w", err)
	}
	installed = true
	result := installResult{Endpoint: "https://" + *host + ":27520", Token: token, Fingerprint: fingerprint}
	if *jsonOutput {
		return json.NewEncoder(os.Stdout).Encode(result)
	}
	fmt.Printf("Installed server-status.\nHTTPS address: %s\nAPI token: %s\nCertificate SHA-256: %s\n", result.Endpoint, result.Token, result.Fingerprint)
	return nil
}

func upgradeInstallation(host string, jsonOutput bool, binary, unit, config string) error {
	for _, path := range []string{unit, filepath.Join(config, "server.crt"), filepath.Join(config, "server.key"), filepath.Join(config, "token")} {
		info, err := os.Lstat(path)
		if err != nil || !info.Mode().IsRegular() {
			return fmt.Errorf("现有安装不完整或存在软链接：%s", path)
		}
	}
	if err := exec.Command("systemctl", "cat", "server-status").Run(); err != nil {
		return errors.New("现有 server-status 服务单元不可用，无法覆盖安装")
	}
	unitBytes, err := os.ReadFile(unit)
	if err != nil || !strings.Contains(string(unitBytes), "ExecStart="+binary+" ") {
		return errors.New("现有服务单元没有使用固定的 sera 程序路径，无法自动覆盖安装")
	}
	tokenBytes, err := os.ReadFile(filepath.Join(config, "token"))
	if err != nil {
		return err
	}
	token := strings.TrimSpace(string(tokenBytes))
	decoded, err := hex.DecodeString(token)
	if err != nil || len(decoded) != 32 {
		return errors.New("现有 API 令牌无效，已取消覆盖安装")
	}
	fingerprint, err := runningCertificateFingerprint()
	if err != nil {
		fingerprint, err = certificateFileFingerprint(filepath.Join(config, "server.crt"))
		if err != nil {
			return err
		}
	}
	source, err := os.Executable()
	if err != nil {
		return err
	}
	restartAndVerify := func() error {
		if output, err := exec.Command("systemctl", "restart", "server-status").CombinedOutput(); err != nil {
			return fmt.Errorf("systemctl restart: %w: %s", err, strings.TrimSpace(string(output)))
		}
		if output, err := exec.Command("systemctl", "is-active", "--quiet", "server-status").CombinedOutput(); err != nil {
			return fmt.Errorf("server-status 未运行：%w: %s", err, strings.TrimSpace(string(output)))
		}
		return verifyUpgradeAPI(token, fingerprint)
	}
	backup, err := replaceInstalledBinary(source, binary, filepath.Join(filepath.Dir(filepath.Dir(binary)), "backup", "server"), restartAndVerify)
	if err != nil {
		return err
	}
	result := installResult{Endpoint: "https://" + host + ":27520", Token: token, Fingerprint: fingerprint}
	if jsonOutput {
		return json.NewEncoder(os.Stdout).Encode(result)
	}
	fmt.Printf("Upgraded server-status. Previous binary: %s\nHTTPS address: %s\nAPI token: %s\nCertificate SHA-256: %s\n", backup, result.Endpoint, result.Token, result.Fingerprint)
	return nil
}

func certificateFileFingerprint(path string) (string, error) {
	contents, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	block, _ := pem.Decode(contents)
	if block == nil || block.Type != "CERTIFICATE" {
		return "", errors.New("现有证书无效")
	}
	if _, err := x509.ParseCertificate(block.Bytes); err != nil {
		return "", err
	}
	digest := sha256.Sum256(block.Bytes)
	return hex.EncodeToString(digest[:]), nil
}

func runningCertificateFingerprint() (string, error) {
	conn, err := tls.DialWithDialer(&net.Dialer{Timeout: 2 * time.Second}, "tcp", "127.0.0.1:27520", &tls.Config{InsecureSkipVerify: true})
	if err != nil {
		return "", err
	}
	defer conn.Close()
	certs := conn.ConnectionState().PeerCertificates
	if len(certs) == 0 {
		return "", errors.New("现有服务未提供 TLS 证书")
	}
	digest := sha256.Sum256(certs[0].Raw)
	return hex.EncodeToString(digest[:]), nil
}

func verifyUpgradeAPI(token, fingerprint string) error {
	client := &http.Client{Transport: &http.Transport{TLSClientConfig: &tls.Config{
		InsecureSkipVerify: true,
		VerifyPeerCertificate: func(rawCerts [][]byte, _ [][]*x509.Certificate) error {
			if len(rawCerts) == 0 {
				return errors.New("服务端未提供 TLS 证书")
			}
			digest := sha256.Sum256(rawCerts[0])
			if hex.EncodeToString(digest[:]) != fingerprint {
				return errors.New("覆盖安装后 TLS 证书已变化")
			}
			return nil
		},
	}}, Timeout: 2 * time.Second}
	defer client.CloseIdleConnections()
	var lastErr error
	for attempt := 0; attempt < 12; attempt++ {
		request, _ := http.NewRequest(http.MethodGet, "https://127.0.0.1:27520/v1/status", nil)
		request.Header.Set("Authorization", "Bearer "+token)
		response, err := client.Do(request)
		if err == nil {
			_ = response.Body.Close()
			if response.StatusCode == http.StatusOK {
				return nil
			}
			lastErr = fmt.Errorf("HTTP %d", response.StatusCode)
		} else {
			lastErr = err
		}
		time.Sleep(500 * time.Millisecond)
	}
	return fmt.Errorf("覆盖安装后 HTTPS 检查失败：%w", lastErr)
}

func replaceInstalledBinary(source, binary, backupDir string, verify func() error) (string, error) {
	in, err := os.Open(source)
	if err != nil {
		return "", err
	}
	defer in.Close()
	temporary, err := os.CreateTemp(filepath.Dir(binary), ".sera-upgrade-*")
	if err != nil {
		return "", err
	}
	defer os.Remove(temporary.Name())
	if _, err := io.Copy(temporary, in); err != nil {
		_ = temporary.Close()
		return "", err
	}
	if err := temporary.Chmod(0755); err != nil {
		_ = temporary.Close()
		return "", err
	}
	if err := temporary.Sync(); err != nil {
		_ = temporary.Close()
		return "", err
	}
	if err := temporary.Close(); err != nil {
		return "", err
	}
	if err := os.MkdirAll(backupDir, 0700); err != nil {
		return "", err
	}
	backup := filepath.Join(backupDir, fmt.Sprintf("sera-%d", time.Now().UnixNano()))
	if err := os.Link(binary, backup); err != nil {
		return "", fmt.Errorf("无法备份现有服务端：%w", err)
	}
	if err := os.Rename(temporary.Name(), binary); err != nil {
		_ = os.Remove(backup)
		return "", err
	}
	if err := verify(); err != nil {
		if restoreErr := os.Rename(backup, binary); restoreErr != nil {
			return "", fmt.Errorf("升级检查失败：%v；恢复旧程序失败：%w", err, restoreErr)
		}
		if restartErr := verify(); restartErr != nil {
			return "", fmt.Errorf("升级检查失败：%v；旧程序恢复后检查失败：%w", err, restartErr)
		}
		return "", fmt.Errorf("升级检查失败，已恢复旧程序：%w", err)
	}
	return backup, nil
}

func verifyInstalledAPI(host, certificatePath, token, endpoint string) error {
	pemBytes, err := os.ReadFile(certificatePath)
	if err != nil {
		return err
	}
	roots := x509.NewCertPool()
	if !roots.AppendCertsFromPEM(pemBytes) {
		return errors.New("cannot load installed certificate")
	}
	client := &http.Client{Transport: &http.Transport{TLSClientConfig: &tls.Config{
		RootCAs: roots, ServerName: host,
	}}, Timeout: 2 * time.Second}
	defer client.CloseIdleConnections()
	var lastErr error
	for attempt := 0; attempt < 12; attempt++ {
		request, err := http.NewRequest(http.MethodGet, endpoint, nil)
		if err != nil {
			return err
		}
		request.Header.Set("Authorization", "Bearer "+token)
		response, err := client.Do(request)
		if err == nil {
			_ = response.Body.Close()
			if response.StatusCode == http.StatusOK {
				return nil
			}
			lastErr = fmt.Errorf("HTTP %d", response.StatusCode)
		} else {
			lastErr = err
		}
		time.Sleep(500 * time.Millisecond)
	}
	return lastErr
}
