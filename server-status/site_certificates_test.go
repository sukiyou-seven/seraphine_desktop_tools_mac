package main

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"math/big"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func testCertificate(t *testing.T, domain string) (string, string) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: domain}, DNSNames: []string{domain},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(24 * time.Hour), KeyUsage: x509.KeyUsageDigitalSignature}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	private, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	return string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})), string(pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: private}))
}

func TestSiteListingCarriesCertificateDetails(t *testing.T) {
	root := t.TempDir()
	sm := newSiteManager(root, newSoftwareManager(root))
	stubSiteRuntime(sm)
	base := sm.basePath("nginx")
	if err := os.MkdirAll(filepath.Dir(base), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(base, []byte("http {\n}\n"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "server", "nginx", ".sera-installed"), []byte("test"), 0644); err != nil {
		t.Fatal(err)
	}
	sm.test = func(context.Context, string) error { return nil }
	sm.isRunning = func(context.Context, string) bool { return true }
	sm.reload = func(context.Context, string) error { return nil }
	item := site{ID: "example.com", Provider: "nginx", Domains: []string{"example.com"}, Kind: "static", Enabled: true,
		Root: filepath.Join(root, "web", "nginx", "example.com")}
	if _, err := sm.apply(item, false, true); err != nil {
		t.Fatal(err)
	}
	listing, err := sm.list()
	if err != nil || len(listing.Items) != 1 {
		t.Fatalf("listing: %+v %v", listing, err)
	}
	// 还没部署证书时列表不该带任何证书字段。
	if got := listing.Items[0]; got.TLS || got.TLSExpiresAt != "" || len(got.TLSDomains) != 0 {
		t.Fatalf("未部署证书却带出了证书信息：%+v", got)
	}
	certificate, key := testCertificate(t, "example.com")
	if err := sm.deployCertificate("nginx", item.ID, certificate, key); err != nil {
		t.Fatal(err)
	}
	listing, err = sm.list()
	if err != nil {
		t.Fatal(err)
	}
	got := listing.Items[0]
	if !got.TLS || got.TLSExpiresAt == "" || len(got.TLSDomains) != 1 || got.TLSDomains[0] != "example.com" {
		t.Fatalf("列表没有带出证书信息：%+v", got)
	}
	if _, err := time.Parse(time.RFC3339, got.TLSExpiresAt); err != nil {
		t.Fatalf("到期时间格式不对：%q", got.TLSExpiresAt)
	}
	// 证书信息是列表现算的，不能落到网站元数据里，否则续期后会显示旧到期时间。
	metadata, err := os.ReadFile(sm.metaPath("nginx", item.ID))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(metadata), "tls_expires_at") || strings.Contains(string(metadata), "tls_domains") {
		t.Fatalf("证书信息被写进了网站元数据：%s", metadata)
	}
	// 证书文件损坏时列表照常返回，只是没有证书明细。
	certPath, _ := siteCertificatePaths(item)
	if err := os.WriteFile(certPath, []byte("not a certificate"), 0600); err != nil {
		t.Fatal(err)
	}
	listing, err = sm.list()
	if err != nil {
		t.Fatal(err)
	}
	if got := listing.Items[0]; !got.TLS || got.TLSExpiresAt != "" {
		t.Fatalf("坏证书不应让列表失败，也不该编造到期时间：%+v", got)
	}
}

// 证书文件不在了（手工清理或只恢复了一半的备份），再保存网站不应该卡死：
// 面板要把 tls 就地纠正成 false，让 vhost 回到只用 80 的状态。
func TestApplyRecoversFromMissingCertificate(t *testing.T) {
	root := t.TempDir()
	sm := newSiteManager(root, newSoftwareManager(root))
	stubSiteRuntime(sm)
	base := sm.basePath("nginx")
	if err := os.MkdirAll(filepath.Dir(base), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(base, []byte("http {\n}\n"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "server", "nginx", ".sera-installed"), []byte("test"), 0644); err != nil {
		t.Fatal(err)
	}
	sm.test = func(context.Context, string) error { return nil }
	sm.isRunning = func(context.Context, string) bool { return true }
	sm.reload = func(context.Context, string) error { return nil }
	item := site{ID: "example.com", Provider: "nginx", Domains: []string{"example.com"}, Kind: "static", Enabled: true,
		Root: filepath.Join(root, "web", "nginx", "example.com")}
	if _, err := sm.apply(item, false, true); err != nil {
		t.Fatal(err)
	}
	certificate, key := testCertificate(t, "example.com")
	if err := sm.deployCertificate("nginx", item.ID, certificate, key); err != nil {
		t.Fatal(err)
	}
	certPath, keyPath := siteCertificatePaths(item)
	if err := os.Remove(certPath); err != nil {
		t.Fatal(err)
	}
	defer os.Remove(keyPath)
	current, err := sm.read("nginx", item.ID)
	if err != nil || !current.TLS {
		t.Fatalf("前置状态不对：%+v %v", current, err)
	}
	if _, err := sm.apply(current, false, false); err != nil {
		t.Fatalf("证书缺失后保存网站被阻塞：%v", err)
	}
	stored, err := sm.read("nginx", item.ID)
	if err != nil {
		t.Fatal(err)
	}
	if stored.TLS {
		t.Fatalf("证书文件不存在时 tls 应被纠正为 false：%+v", stored)
	}
	conf, err := os.ReadFile(sm.confPath("nginx", item.ID))
	if err != nil || strings.Contains(string(conf), "443") {
		t.Fatalf("vhost 仍引用证书：%s %v", conf, err)
	}
}

func TestDeploySiteCertificateAndRollback(t *testing.T) {
	for _, provider := range []string{"nginx", "apache", "openresty"} {
		t.Run(provider, func(t *testing.T) {
			root := t.TempDir()
			software := newSoftwareManager(root)
			sm := newSiteManager(root, software)
			stubSiteRuntime(sm)
			base := sm.basePath(provider)
			if err := os.MkdirAll(filepath.Dir(base), 0755); err != nil {
				t.Fatal(err)
			}
			config := "http {\n}\n"
			if provider == "apache" {
				config = "ServerRoot \"/tmp\"\n"
			}
			if err := os.WriteFile(base, []byte(config), 0644); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(root, "server", provider, ".sera-installed"), []byte("test"), 0644); err != nil {
				t.Fatal(err)
			}
			sm.test = func(context.Context, string) error { return nil }
			sm.isRunning = func(context.Context, string) bool { return true }
			sm.reload = func(context.Context, string) error { return nil }
			item := site{ID: "example.com", Provider: provider, Domains: []string{"example.com"}, Kind: "static", Enabled: true,
				Root: filepath.Join(root, "web", provider, "example.com")}
			if _, err := sm.apply(item, false, true); err != nil {
				t.Fatal(err)
			}
			wrong, key := testCertificate(t, "wrong.example.com")
			if err := sm.deployCertificate(provider, item.ID, wrong, key); err == nil {
				t.Fatal("accepted wrong domain")
			}
			certificate, key := testCertificate(t, "example.com")
			if err := sm.deployCertificate(provider, item.ID, certificate, key); err != nil {
				t.Fatal(err)
			}
			certPath, keyPath := siteCertificatePaths(item)
			for _, path := range []string{certPath, keyPath} {
				if info, err := os.Stat(path); err != nil || info.Mode().Perm() != 0600 {
					t.Fatalf("certificate file: %s %v %v", path, info, err)
				}
			}
			conf, err := os.ReadFile(sm.confPath(provider, item.ID))
			if err != nil || !strings.Contains(string(conf), "443") || !strings.Contains(string(conf), keyPath) {
				t.Fatalf("HTTPS config: %s %v", conf, err)
			}
			stored, err := sm.read(provider, item.ID)
			if err != nil || !stored.TLS {
				t.Fatalf("TLS state: %+v %v", stored, err)
			}
			sm.reload = func(context.Context, string) error { return os.ErrPermission }
			if err := sm.deployCertificate(provider, item.ID, certificate, key); err == nil {
				t.Fatal("accepted reload failure")
			}
			after, _ := os.ReadFile(sm.confPath(provider, item.ID))
			if string(after) != string(conf) {
				t.Fatal("failed deployment changed config")
			}
			sm.reload = func(context.Context, string) error { return nil }
			if _, err := sm.apply(item, true, false); err != nil {
				t.Fatal(err)
			}
			if _, err := os.Stat(certPath); !os.IsNotExist(err) {
				t.Fatalf("deleted site retained certificate: %v", err)
			}
			if provider == "apache" {
				base, err := os.ReadFile(sm.basePath(provider))
				if err != nil || strings.Contains(string(base), "Listen 443") {
					t.Fatalf("Apache retained TLS listener: %s %v", base, err)
				}
			}
		})
	}
}
