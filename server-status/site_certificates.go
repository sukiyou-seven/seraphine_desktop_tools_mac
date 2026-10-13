package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

func (sm *siteManager) deployCertificate(provider, id, certificate, privateKey string) error {
	if len(certificate) == 0 || len(privateKey) == 0 || len(certificate) > 192<<10 || len(privateKey) > 64<<10 {
		return errors.New("证书或私钥大小无效")
	}
	pair, err := tls.X509KeyPair([]byte(certificate), []byte(privateKey))
	if err != nil {
		return fmt.Errorf("证书与私钥不匹配：%w", err)
	}
	leaf, err := x509.ParseCertificate(pair.Certificate[0])
	if err != nil {
		return err
	}
	if block, _ := pem.Decode([]byte(certificate)); block == nil {
		return errors.New("证书 PEM 无效")
	}
	if !time.Now().Before(leaf.NotAfter) || time.Now().Before(leaf.NotBefore.Add(-5*time.Minute)) {
		return errors.New("证书尚未生效或已过期")
	}
	if !sm.software.beginServiceAction() {
		return errors.New("另一个软件操作正在进行")
	}
	defer sm.software.endServiceAction()
	sm.mu.Lock()
	defer sm.mu.Unlock()
	item, err := sm.read(provider, id)
	if err != nil {
		return err
	}
	if !item.Enabled {
		return errors.New("请先启用网站")
	}
	for _, domain := range item.Domains {
		if err := leaf.VerifyHostname(domain); err != nil {
			return fmt.Errorf("证书未覆盖网站域名 %s", domain)
		}
	}
	for _, other := range siteProviders {
		if other.ID == provider {
			continue
		}
		files, err := os.ReadDir(sm.siteDir(other.ID))
		if err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
		for _, file := range files {
			if !strings.HasSuffix(file.Name(), ".json") {
				continue
			}
			site, err := sm.read(other.ID, strings.TrimSuffix(file.Name(), ".json"))
			if err != nil {
				return err
			}
			if site.TLS && site.Enabled {
				return fmt.Errorf("443 端口已由 %s 网站占用", other.Name)
			}
		}
	}
	certPath, keyPath := siteCertificatePaths(item)
	paths := []string{certPath, keyPath, sm.metaPath(provider, id), sm.confPath(provider, id), sm.basePath(provider)}
	snapshots := make([]siteSnapshot, 0, len(paths))
	for _, path := range paths {
		old, err := snapshotSite(path)
		if err != nil {
			return err
		}
		snapshots = append(snapshots, old)
	}
	if !snapshots[3].exists || !snapshots[4].exists {
		return errors.New("网站配置缺失")
	}
	if err := os.MkdirAll(filepath.Dir(certPath), 0700); err != nil {
		return err
	}
	changed := true
	defer func() {
		if changed {
			restoreSites(snapshots)
		}
	}()
	if err := atomicSiteWrite(certPath, []byte(certificate), 0600); err != nil {
		return err
	}
	if err := atomicSiteWrite(keyPath, []byte(privateKey), 0600); err != nil {
		return err
	}
	item.TLS = true
	metadata, _ := json.MarshalIndent(item, "", "  ")
	if err := atomicSiteWrite(paths[2], append(metadata, '\n'), 0644); err != nil {
		return err
	}
	port := 80
	for _, candidate := range siteProviders {
		if candidate.ID == provider {
			port = candidate.Port
		}
	}
	phpTarget := ""
	if item.Kind == "php" {
		phpTarget, err = sm.phpTarget(item.PHPVersion)
		if err != nil {
			return err
		}
	}
	if err := atomicSiteWrite(paths[3], siteConfig(item, port, phpTarget), 0644); err != nil {
		return err
	}
	if err := atomicSiteWrite(paths[4], []byte(siteTLSBase(string(snapshots[4].data), provider, true)), snapshots[4].mode); err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
	defer cancel()
	if err := sm.test(ctx, provider); err != nil {
		return err
	}
	if sm.isRunning(ctx, provider) {
		if err := sm.reload(ctx, provider); err != nil {
			return err
		}
	} else if err := sm.start(ctx, provider); err != nil {
		return err
	}
	changed = false
	return nil
}
