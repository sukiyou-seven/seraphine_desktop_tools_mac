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

func TestDeploySiteCertificateAndRollback(t *testing.T) {
	for _, provider := range []string{"nginx", "apache", "openresty"} {
		t.Run(provider, func(t *testing.T) {
			root := t.TempDir()
			software := newSoftwareManager(root)
			sm := newSiteManager(root, software)
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
