package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"flag"
	"fmt"
	"log"
	"math/big"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: sera init|install|serve [options]")
		os.Exit(2)
	}
	var err error
	switch os.Args[1] {
	case "init":
		err = initCommand(os.Args[2:])
	case "serve":
		err = serveCommand(os.Args[2:])
	case "install":
		err = installCommand(os.Args[2:])
	case "task-run":
		err = taskRunCommand(os.Args[2:])
	default:
		err = fmt.Errorf("unknown command %q", os.Args[1])
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func initCommand(args []string) error {
	flags := flag.NewFlagSet("init", flag.ContinueOnError)
	host := flags.String("host", "", "server DNS name or IP address used by the client")
	dir := flags.String("dir", "./server-status-config", "directory for certificate, key, and token")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if err := validateInstallHost(*host); err != nil {
		return err
	}
	fingerprint, token, err := initializeCredentials(*host, *dir)
	if err != nil {
		return err
	}
	fmt.Printf("certificate SHA-256: %s\nAPI token: %s\n", fingerprint, token)
	return nil
}

func initializeCredentials(host, dir string) (string, string, error) {
	if err := os.MkdirAll(dir, 0700); err != nil {
		return "", "", err
	}
	if err := os.Chmod(dir, 0700); err != nil {
		return "", "", err
	}
	for _, name := range []string{"server.crt", "server.key", "token"} {
		if _, err := os.Stat(filepath.Join(dir, name)); err == nil {
			return "", "", fmt.Errorf("%s already exists; refusing to overwrite credentials", name)
		} else if !os.IsNotExist(err) {
			return "", "", err
		}
	}
	certPEM, keyPEM, fingerprint, err := createCertificate(host)
	if err != nil {
		return "", "", err
	}
	tokenBytes := make([]byte, 32)
	if _, err := rand.Read(tokenBytes); err != nil {
		return "", "", err
	}
	token := hex.EncodeToString(tokenBytes)
	files := []struct {
		name     string
		contents []byte
	}{
		{"server.crt", certPEM}, {"server.key", keyPEM}, {"token", []byte(token + "\n")},
	}
	created := []string{}
	for _, file := range files {
		path := filepath.Join(dir, file.name)
		out, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
		opened := err == nil
		if err == nil {
			_, err = out.Write(file.contents)
			if closeErr := out.Close(); err == nil {
				err = closeErr
			}
		}
		if err != nil {
			for _, path := range created {
				_ = os.Remove(path)
			}
			if opened {
				_ = os.Remove(path)
			}
			return "", "", err
		}
		created = append(created, path)
	}
	return fingerprint, token, nil
}

func createCertificate(host string) ([]byte, []byte, string, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, nil, "", err
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return nil, nil, "", err
	}
	now := time.Now()
	template := x509.Certificate{
		SerialNumber:          serial,
		Subject:               pkix.Name{CommonName: host, Organization: []string{"Seraphim"}},
		NotBefore:             now.Add(-5 * time.Minute),
		NotAfter:              now.Add(365 * 24 * time.Hour),
		KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
		IsCA:                  true,
		MaxPathLenZero:        true,
	}
	if ip := net.ParseIP(host); ip != nil {
		template.IPAddresses = []net.IP{ip}
	} else {
		template.DNSNames = []string{host}
	}
	der, err := x509.CreateCertificate(rand.Reader, &template, &template, &key.PublicKey, key)
	if err != nil {
		return nil, nil, "", err
	}
	privateDER, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		return nil, nil, "", err
	}
	fingerprint := sha256.Sum256(der)
	return pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}),
		pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: privateDER}),
		hex.EncodeToString(fingerprint[:]), nil
}

type api struct {
	// token 是面板客户端连服务器用的凭据（安装时生成，存在于客户端那边）。
	token string
	// apiKeys 是给脚本和 AI 客户端用的另一把，可以在面板上重置。
	apiKeys      *apiKeyStore
	collect      func(time.Duration) (snapshot, error)
	limit        chan struct{}
	files        *fileManager
	services     *serviceManager
	software     *softwareManager
	sites        *siteManager
	environments *environmentManager
	projects     *projectManager
	variables    *globalVariableManager
	databases    *databaseManager
	tasks        *taskManager
	firewall     *firewallManager
}

// authorized 认两把钥匙：面板客户端用的 token，和给脚本 / AI 用的 API key。
//
// 权限相同，区别只在「能不能单独作废」——重置 API key 不会把已经连上的面板
// 踢下线，重装面板也不会打断正在跑的自动化。
func (a *api) authorized(r *http.Request) bool {
	provided, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	if !ok {
		return false
	}
	if len(provided) == len(a.token) &&
		subtle.ConstantTimeCompare([]byte(provided), []byte(a.token)) == 1 {
		return true
	}
	return a.apiKeys.matches(provided)
}

func (a *api) status(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", "GET")
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !a.authorized(r) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	select {
	case a.limit <- struct{}{}:
		defer func() { <-a.limit }()
	case <-r.Context().Done():
		return
	}
	status, err := a.collect(300 * time.Millisecond)
	if err != nil {
		log.Printf("status collection failed: %v", err)
		http.Error(w, "status unavailable", http.StatusServiceUnavailable)
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	if err := json.NewEncoder(w).Encode(status); err != nil {
		log.Printf("status response failed: %v", err)
	}
}

func serveCommand(args []string) error {
	flags := flag.NewFlagSet("serve", flag.ContinueOnError)
	listen := flags.String("listen", "127.0.0.1:27520", "HTTPS listen address")
	dir := flags.String("dir", "./server-status-config", "directory created by init")
	certFile := flags.String("cert-file", "", "TLS certificate or fullchain PEM (optional override)")
	keyFile := flags.String("key-file", "", "TLS private key PEM (optional override)")
	domain := flags.String("domain", "", "expected DNS name in the TLS certificate (optional)")
	filesRoot := flags.String("files-root", "/", "root directory exposed by the file API")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if _, _, err := net.SplitHostPort(*listen); err != nil {
		return err
	}
	if (*certFile == "") != (*keyFile == "") {
		return errors.New("-cert-file and -key-file must be set together")
	}
	if *certFile == "" {
		*certFile = filepath.Join(*dir, "server.crt")
		*keyFile = filepath.Join(*dir, "server.key")
	}
	certificate, err := tls.LoadX509KeyPair(*certFile, *keyFile)
	if err != nil {
		return fmt.Errorf("load TLS certificate: %w", err)
	}
	if *domain != "" {
		leaf, err := x509.ParseCertificate(certificate.Certificate[0])
		if err != nil {
			return fmt.Errorf("parse TLS certificate: %w", err)
		}
		if err := leaf.VerifyHostname(*domain); err != nil {
			return fmt.Errorf("TLS certificate does not match domain %q: %w", *domain, err)
		}
	}
	tokenBytes, err := os.ReadFile(filepath.Join(*dir, "token"))
	if err != nil {
		return err
	}
	token := strings.TrimSpace(string(tokenBytes))
	if decoded, err := hex.DecodeString(token); err != nil || len(decoded) != 32 {
		return errors.New("token file must contain a 32-byte hex token")
	}
	root, err := os.OpenRoot(*filesRoot)
	if err != nil {
		return fmt.Errorf("open file API root: %w", err)
	}
	defer root.Close()
	handler := http.NewServeMux()
	software := newSoftwareManager("/www/seraphim")
	// 变量表由项目与计划任务共用，所以在这里建一份实例再分发下去。
	variables := newGlobalVariableManager("/www/seraphim")
	// 共用文件被手工删掉时，不必等到下一次保存才恢复。失败不影响启动。
	_ = variables.syncSharedFile()
	a := &api{token: token, collect: collect, limit: make(chan struct{}, 2), files: &fileManager{root: root}, services: &serviceManager{run: runSystemctl}, software: software, sites: newSiteManager("/www/seraphim", software), environments: newEnvironmentManager(software), projects: newProjectManager("/www/seraphim", software, variables), variables: variables, databases: newDatabaseManager("/www/seraphim", software), tasks: newTaskManager("/www/seraphim"), firewall: newFirewallManager()}
	// 给脚本 / AI 用的那把 key 单独放一个文件，和上面这把互不影响。
	// 启动时就准备好，配置目录里能直接看见；失败也不拦启动，面板照样能用。
	a.apiKeys = newAPIKeyStore(*dir)
	if _, err := a.apiKeys.current(); err != nil {
		log.Printf("API key unavailable: %v", err)
	}
	handler.HandleFunc("/v1/status", a.status)
	handler.HandleFunc("/v1/api", a.apiHandler)
	handler.HandleFunc("/v1/api/key", a.apiKeyHandler)
	handler.HandleFunc("/v1/mcp", a.mcpHandler)
	handler.HandleFunc("/v1/mcp/script", a.mcpScriptHandler)
	handler.HandleFunc("/v1/files", a.filesHandler)
	handler.HandleFunc("/v1/files/content", a.fileContentHandler)
	handler.HandleFunc("/v1/services", a.servicesHandler)
	handler.HandleFunc("/v1/software", a.softwareHandler)
	handler.HandleFunc("/v1/software/", a.softwareHandler)
	handler.HandleFunc("/v1/sites", a.sitesHandler)
	handler.HandleFunc("/v1/sites/", a.sitesHandler)
	handler.HandleFunc("/v1/environments", a.environmentsHandler)
	handler.HandleFunc("/v1/environments/", a.environmentsHandler)
	handler.HandleFunc("/v1/projects", a.projectsHandler)
	handler.HandleFunc("/v1/projects/", a.projectsHandler)
	handler.HandleFunc("/v1/variables", a.variablesHandler)
	handler.HandleFunc("/v1/databases", a.databasesHandler)
	handler.HandleFunc("/v1/databases/", a.databasesHandler)
	handler.HandleFunc("/v1/tasks", a.tasksHandler)
	handler.HandleFunc("/v1/tasks/", a.tasksHandler)
	handler.HandleFunc("/v1/firewall", a.firewallHandler)
	server := &http.Server{
		Addr: *listen, Handler: handler,
		ReadHeaderTimeout: 5 * time.Second,
		// File transfers stream to disk and may take longer than status requests.
		ReadTimeout:    0,
		WriteTimeout:   0,
		IdleTimeout:    30 * time.Second,
		MaxHeaderBytes: 8 << 10,
	}
	log.Printf("serving HTTPS API at %s; file root %s", *listen, *filesRoot)
	return server.ListenAndServeTLS(*certFile, *keyFile)
}
