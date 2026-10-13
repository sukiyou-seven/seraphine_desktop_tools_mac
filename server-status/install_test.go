package main

import (
	"crypto/tls"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

func TestReplaceInstalledBinaryKeepsBackupAndRollsBack(t *testing.T) {
	root := t.TempDir()
	binary := filepath.Join(root, "sera")
	source := filepath.Join(root, "incoming")
	backupDir := filepath.Join(root, "backup")
	for path, contents := range map[string]string{binary: "old", source: "new"} {
		if err := os.WriteFile(path, []byte(contents), 0755); err != nil {
			t.Fatal(err)
		}
	}
	backup, err := replaceInstalledBinary(source, binary, backupDir, func() error { return nil })
	if err != nil {
		t.Fatal(err)
	}
	if data, err := os.ReadFile(binary); err != nil || string(data) != "new" {
		t.Fatalf("new binary: %q %v", data, err)
	}
	if data, err := os.ReadFile(backup); err != nil || string(data) != "old" {
		t.Fatalf("backup: %q %v", data, err)
	}
	if err := os.WriteFile(source, []byte("third"), 0755); err != nil {
		t.Fatal(err)
	}
	attempts := 0
	_, err = replaceInstalledBinary(source, binary, backupDir, func() error {
		attempts++
		if attempts == 1 {
			return errors.New("service failed")
		}
		return nil
	})
	if err == nil || attempts != 2 {
		t.Fatalf("rollback not checked: %v, attempts=%d", err, attempts)
	}
	if data, err := os.ReadFile(binary); err != nil || string(data) != "new" {
		t.Fatalf("rollback changed live binary: %q %v", data, err)
	}
}

func TestValidateInstallHost(t *testing.T) {
	for _, host := range []string{"192.168.0.103", "server.example.com", "localhost"} {
		if err := validateInstallHost(host); err != nil {
			t.Errorf("%q: %v", host, err)
		}
	}
	for _, host := range []string{"", "example.com:27520", "a/b", "-bad.example", "bad..example", "a;id"} {
		if err := validateInstallHost(host); err == nil {
			t.Errorf("accepted invalid host %q", host)
		}
	}
}

func TestCertificateFileFingerprint(t *testing.T) {
	cert, _, expected, err := createCertificate("127.0.0.1")
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "server.crt")
	if err := os.WriteFile(path, cert, 0600); err != nil {
		t.Fatal(err)
	}
	actual, err := certificateFileFingerprint(path)
	if err != nil || actual != expected {
		t.Fatalf("fingerprint: %s, want %s: %v", actual, expected, err)
	}
}

func TestVerifyInstalledAPI(t *testing.T) {
	certPEM, keyPEM, _, err := createCertificate("127.0.0.1")
	if err != nil {
		t.Fatal(err)
	}
	pair, err := tls.X509KeyPair(certPEM, keyPEM)
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/status" || r.Header.Get("Authorization") != "Bearer test-token" {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		w.WriteHeader(http.StatusOK)
	}))
	server.TLS = &tls.Config{Certificates: []tls.Certificate{pair}}
	server.StartTLS()
	defer server.Close()
	path := filepath.Join(t.TempDir(), "server.crt")
	if err := os.WriteFile(path, certPEM, 0600); err != nil {
		t.Fatal(err)
	}
	if err := verifyInstalledAPI("127.0.0.1", path, "test-token", server.URL+"/v1/status"); err != nil {
		t.Fatal(err)
	}
}
