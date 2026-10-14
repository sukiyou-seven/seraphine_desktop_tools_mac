package main

import (
	"context"
	"net"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// unitStatus 是一次 `systemctl show` 的结果。
//
// 列表与详情都用它。原来的做法是 is-active + is-enabled 两次调用，只够回答
// 「在不在跑」；而项目真正的麻烦几乎都发生在「在跑但没工作」和「起了又崩」，
// 那需要 PID、子状态、重启次数、退出码和 systemd 的结论（Result）。
type unitStatus struct {
	ActiveState   string `json:"active_state"`
	SubState      string `json:"sub_state,omitempty"`
	UnitFileState string `json:"unit_file_state,omitempty"`
	Result        string `json:"result,omitempty"`
	MainPID       int    `json:"main_pid,omitempty"`
	ExitStatus    int    `json:"exit_status,omitempty"`
	Restarts      int    `json:"restarts,omitempty"`
	MemoryBytes   int64  `json:"memory_bytes,omitempty"`
	UptimeSeconds int64  `json:"uptime_seconds,omitempty"`

	activeSinceMicros int64
}

// unitShowProperties 是一次探测要取的属性；顺序无关。
const unitShowProperties = "ActiveState,SubState,UnitFileState,Result,MainPID,ExecMainStatus," +
	"NRestarts,MemoryCurrent,ActiveEnterTimestampMonotonic"

func parseUnitShow(output string) unitStatus {
	var status unitStatus
	for _, line := range strings.Split(output, "\n") {
		key, value, ok := strings.Cut(strings.TrimSpace(line), "=")
		if !ok {
			continue
		}
		value = strings.TrimSpace(value)
		switch key {
		case "ActiveState":
			status.ActiveState = value
		case "SubState":
			status.SubState = value
		case "UnitFileState":
			status.UnitFileState = value
		case "Result":
			status.Result = value
		case "MainPID":
			status.MainPID = nonNegativeInt(value)
		case "ExecMainStatus":
			status.ExitStatus = nonNegativeInt(value)
		case "NRestarts":
			status.Restarts = nonNegativeInt(value)
		case "MemoryCurrent":
			// systemd 拿不到时写 [not set] 或 infinity，别当成 0 报出去。
			if size, err := strconv.ParseInt(value, 10, 64); err == nil && size > 0 {
				status.MemoryBytes = size
			}
		case "ActiveEnterTimestampMonotonic":
			if micros, err := strconv.ParseInt(value, 10, 64); err == nil && micros > 0 {
				status.activeSinceMicros = micros
			}
		}
	}
	if status.activeSinceMicros > 0 {
		if uptime, ok := systemUptimeSeconds(); ok {
			if seconds := int64(uptime - float64(status.activeSinceMicros)/1e6); seconds > 0 {
				status.UptimeSeconds = seconds
			}
		}
	}
	return status
}

func nonNegativeInt(value string) int {
	number, err := strconv.Atoi(value)
	if err != nil || number < 0 {
		return 0
	}
	return number
}

// 单元不存在时 systemctl show 依然会输出 ActiveState=inactive，只是退出码非零；
// 只有完全拿不到输出才算真的读不到，那时状态记作 unknown。
func (pm *projectManager) unitStatus(ctx context.Context, id string) unitStatus {
	statusCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	output, err := pm.systemctl(statusCtx, "show", pm.unitName(id), "--no-pager", "-p", unitShowProperties)
	if err != nil && len(output) == 0 {
		return unitStatus{ActiveState: "unknown"}
	}
	status := parseUnitShow(string(output))
	if status.ActiveState == "" {
		status.ActiveState = "unknown"
	}
	return status
}

// journal 取单元最近几行日志。项目进程还没真正跑起来就退出时（例如 ExecStart
// 里的路径不对），项目自己的日志文件是空的，原因只在 journal 里。
func (pm *projectManager) journal(ctx context.Context, id string) string {
	if pm.journalRun == nil {
		return ""
	}
	journalCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	output, err := pm.journalRun(journalCtx, "-u", pm.unitName(id), "-n", "40", "--no-pager", "-o", "cat")
	if err != nil && len(output) == 0 {
		return ""
	}
	return strings.TrimSpace(string(output))
}

func runJournalctl(ctx context.Context, args ...string) ([]byte, error) {
	return exec.CommandContext(ctx, "journalctl", args...).CombinedOutput()
}

// portFree 试着绑一下端口再放开：能绑上就是空的。
// 只在项目没在运行时才有意义——项目自己占着自己的端口是正常的。
func portFree(port int) bool {
	if port < 1 || port > 65535 {
		return false
	}
	listener, err := net.Listen("tcp", "127.0.0.1:"+strconv.Itoa(port))
	if err != nil {
		return false
	}
	_ = listener.Close()
	return true
}

// portListening 判断有没有进程在这个端口上接受连接。
// 「进程在跑但端口没监听」是启动阶段最常见的假成功，单看 systemd 看不出来。
func portListening(port int) bool {
	if port < 1 || port > 65535 {
		return false
	}
	conn, err := net.DialTimeout("tcp", "127.0.0.1:"+strconv.Itoa(port), 300*time.Millisecond)
	if err != nil {
		return false
	}
	_ = conn.Close()
	return true
}

// homeBoundDirectory 报告目录是否落在 systemd 的 ProtectHome 会挡住的范围里。
// 工程目录若在家目录下，单元里就不能再用 ProtectHome=yes，否则进程连自己的
// 代码都读不到，会以「权限不足」的形式莫名其妙地起不来。
func homeBoundDirectory(path string) bool {
	cleaned := filepath.Clean(path)
	for _, prefix := range []string{"/home", "/root", "/run/user"} {
		if cleaned == prefix || strings.HasPrefix(cleaned, prefix+string(filepath.Separator)) {
			return true
		}
	}
	return false
}

// readableAddress 把监听地址显示成人能读的形式，用于自检与提示。
func readableAddress(port int) string { return "127.0.0.1:" + strconv.Itoa(port) }
