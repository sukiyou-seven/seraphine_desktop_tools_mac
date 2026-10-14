package main

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
)

// API 访问用的 key 与面板客户端连服务器用的凭据刻意分开，是两把：
//
//   - `config/token`：安装时生成，面板客户端连服务器用的就是它，存在客户端那边；
//   - `config/api-key`：这一份，给脚本和 AI 客户端用，可以在「API 设置」页重置。
//
// 分开的意义是「能单独作废」：脚本或 AI 客户端那边泄露了就把这一把换掉，
// 已经连上的面板不受影响；反过来重装面板也不会打断正在跑的自动化。
//
// key 只由服务端生成，任何接口都不接受外部传入的 key——页面上没有填写框，
// 请求体里的 key 一律忽略。用户能做的只有「换一把」，不能指定成什么。

const apiKeyFileName = "api-key"

// apiKeyBytes 与安装时的 token 取同一个形状：32 字节随机数，hex 之后 64 个字符。
const apiKeyBytes = 32

type apiKeyStore struct {
	path string

	mu    sync.Mutex
	value string
}

func newAPIKeyStore(dir string) *apiKeyStore {
	return &apiKeyStore{path: filepath.Join(dir, apiKeyFileName)}
}

// current 返回当前这把 key；文件不存在时生成一把。
//
// 懒生成是为了让已经装好的服务器升级上来就有 key，不必重装一遍。
func (s *apiKeyStore) current() (string, error) {
	if s == nil {
		return "", errors.New("API key 存储不可用")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.value != "" {
		return s.value, nil
	}
	body, err := os.ReadFile(s.path)
	switch {
	case err == nil:
		key := strings.TrimSpace(string(body))
		if !validAPIKey(key) {
			// 不悄悄换一把：那会让正在用它的脚本全部突然失效，而真正的原因
			// （文件被改坏）反而被掩盖掉。让调用方看见错误，人来决定。
			return "", fmt.Errorf("%s 内容不是 32 字节 hex；确认无误后删除该文件可重新生成", s.path)
		}
		s.value = key
		return key, nil
	case os.IsNotExist(err):
		return s.write()
	default:
		return "", err
	}
}

// reset 生成全新的一把并立刻落盘；从此旧的 key 不再被接受。
func (s *apiKeyStore) reset() (string, error) {
	if s == nil {
		return "", errors.New("API key 存储不可用")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.write()
}

// write 生成并原子写入一把新 key（调用方持锁）。
//
// 先写临时文件再 rename：中途出错不会留下半截 key，也不会让正在读的请求
// 看到空文件。面板单元带 UMask=0077，这里仍然显式 chmod，别指望 umask。
func (s *apiKeyStore) write() (string, error) {
	raw := make([]byte, apiKeyBytes)
	if _, err := rand.Read(raw); err != nil {
		return "", err
	}
	key := hex.EncodeToString(raw)
	dir := filepath.Dir(s.path)
	if err := os.MkdirAll(dir, 0700); err != nil {
		return "", err
	}
	temp, err := os.CreateTemp(dir, ".api-key-*")
	if err != nil {
		return "", err
	}
	name := temp.Name()
	cleanup := func() {
		_ = temp.Close()
		_ = os.Remove(name)
	}
	if _, err := temp.WriteString(key + "\n"); err != nil {
		cleanup()
		return "", err
	}
	if err := temp.Chmod(0600); err != nil {
		cleanup()
		return "", err
	}
	if err := temp.Close(); err != nil {
		_ = os.Remove(name)
		return "", err
	}
	if err := os.Rename(name, s.path); err != nil {
		_ = os.Remove(name)
		return "", err
	}
	s.value = key
	return key, nil
}

// matches 常量时间比较，避免有人靠响应时间把 key 一位一位试出来。
func (s *apiKeyStore) matches(provided string) bool {
	if s == nil || provided == "" {
		return false
	}
	key, err := s.current()
	if err != nil || key == "" {
		return false
	}
	return len(provided) == len(key) && subtle.ConstantTimeCompare([]byte(provided), []byte(key)) == 1
}

func validAPIKey(key string) bool {
	if len(key) != apiKeyBytes*2 {
		return false
	}
	decoded, err := hex.DecodeString(key)
	return err == nil && len(decoded) == apiKeyBytes
}
