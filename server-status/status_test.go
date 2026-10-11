package main

import (
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestCPUDeltaExcludesGuestFields(t *testing.T) {
	before, err := parseCPU("cpu 100 0 50 800 20 0 0 0 30 0\n")
	if err != nil {
		t.Fatal(err)
	}
	after, err := parseCPU("cpu 130 0 60 850 20 0 0 0 40 0\n")
	if err != nil {
		t.Fatal(err)
	}
	if before.total != 970 || cpuUsage(before, after) != 44.4 {
		t.Fatalf("incorrect CPU calculation: before=%+v usage=%v", before, cpuUsage(before, after))
	}
}

func TestMemoryUsesAvailableNotFree(t *testing.T) {
	values, err := parseMeminfo("MemTotal: 1024 kB\nMemAvailable: 384 kB\nSwapTotal: 512 kB\nSwapFree: 128 kB\n")
	if err != nil {
		t.Fatal(err)
	}
	memory, swap, err := memoryMetrics(values)
	if err != nil {
		t.Fatal(err)
	}
	if memory.UsedBytes != 640*1024 || memory.UsagePercent != 62.5 || swap.UsedBytes != 384*1024 {
		t.Fatalf("incorrect memory calculation: %+v %+v", memory, swap)
	}
}

func TestMountsFilterVirtualAndDecodeSpaces(t *testing.T) {
	mounts := parseMounts("/dev/vda1 / ext4 rw 0 0\nproc /proc proc rw 0 0\n/dev/vdb1 /mnt/my\\040disk ext4 rw 0 0\n")
	if len(mounts) != 2 || mounts[0].path != "/" || mounts[1].path != "/mnt/my disk" {
		t.Fatalf("unexpected mounts: %+v", mounts)
	}
}

func TestStatusEndpointRequiresBearerAndOnlyReads(t *testing.T) {
	calls := 0
	a := &api{token: strings.Repeat("a", 64), limit: make(chan struct{}, 2), collect: func(time.Duration) (snapshot, error) {
		calls++
		return snapshot{SchemaVersion: 1, Timestamp: "2026-10-08T00:00:00Z", Disks: []diskStatus{}, Network: []networkStatus{}}, nil
	}}
	for _, tc := range []struct {
		method, authorization string
		want                  int
	}{
		{"GET", "", http.StatusUnauthorized},
		{"GET", strings.Repeat("a", 64), http.StatusUnauthorized},
		{"GET", "Bearer wrong", http.StatusUnauthorized},
		{"POST", "Bearer " + strings.Repeat("a", 64), http.StatusMethodNotAllowed},
		{"GET", "Bearer " + strings.Repeat("a", 64), http.StatusOK},
	} {
		r := httptest.NewRequest(tc.method, "/v1/status", nil)
		if tc.authorization != "" {
			r.Header.Set("Authorization", tc.authorization)
		}
		w := httptest.NewRecorder()
		a.status(w, r)
		if w.Code != tc.want {
			t.Fatalf("%s %q: got %d, want %d", tc.method, tc.authorization, w.Code, tc.want)
		}
		if tc.want == http.StatusOK {
			var data map[string]any
			if err := json.Unmarshal(w.Body.Bytes(), &data); err != nil {
				t.Fatal(err)
			}
			if data["schema_version"] != float64(1) {
				t.Fatalf("unexpected body: %s", w.Body.String())
			}
		}
	}
	if calls != 1 {
		t.Fatalf("collector called %d times", calls)
	}
}

func TestGeneratedCertificateAndTokenAreUsable(t *testing.T) {
	certPEM, keyPEM, fingerprint, err := createCertificate("127.0.0.1")
	if err != nil {
		t.Fatal(err)
	}
	block, _ := pem.Decode(certPEM)
	if block == nil {
		t.Fatal("certificate PEM missing")
	}
	certificate, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		t.Fatal(err)
	}
	if len(certificate.IPAddresses) != 1 || certificate.IPAddresses[0].String() != "127.0.0.1" {
		t.Fatalf("certificate does not cover requested IP: %+v", certificate.IPAddresses)
	}
	if certificate.Subject.CommonName == "" || !certificate.IsCA {
		t.Fatalf("self-signed certificate lacks trust anchor identity: %+v", certificate.Subject)
	}
	if len(keyPEM) == 0 {
		t.Fatal("private key PEM missing")
	}
	if _, err := tls.X509KeyPair(certPEM, keyPEM); err != nil {
		t.Fatalf("generated HTTPS certificate cannot be loaded: %v", err)
	}
	digest := sha256.Sum256(block.Bytes)
	if fingerprint != hex.EncodeToString(digest[:]) {
		t.Fatal("incorrect certificate fingerprint")
	}

	dir := t.TempDir()
	if err := initCommand([]string{"-host", "127.0.0.1", "-dir", dir}); err != nil {
		t.Fatal(err)
	}
	if err := initCommand([]string{"-host", "127.0.0.1", "-dir", dir}); err == nil {
		t.Fatal("init overwrote existing credentials")
	}
}

func TestCustomCertificateRequiresMatchingDomainAndKey(t *testing.T) {
	dir := t.TempDir()
	certPEM, keyPEM, _, err := createCertificate("status.example.com")
	if err != nil {
		t.Fatal(err)
	}
	certPath := filepath.Join(dir, "fullchain.pem")
	keyPath := filepath.Join(dir, "privkey.pem")
	if err := os.WriteFile(certPath, certPEM, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(keyPath, keyPEM, 0600); err != nil {
		t.Fatal(err)
	}
	if err := serveCommand([]string{"-cert-file", certPath}); err == nil || !strings.Contains(err.Error(), "must be set together") {
		t.Fatalf("expected certificate and key pair error, got %v", err)
	}
	if err := serveCommand([]string{"-cert-file", certPath, "-key-file", keyPath, "-domain", "wrong.example.com"}); err == nil || !strings.Contains(err.Error(), "does not match domain") {
		t.Fatalf("expected certificate domain mismatch, got %v", err)
	}
}
