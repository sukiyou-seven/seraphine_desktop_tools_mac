package main

import (
	"crypto/tls"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

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
