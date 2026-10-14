//go:build linux

package main

import (
	"os"
	"strconv"
	"strings"
)

// systemUptimeSeconds 返回开机至今的秒数。systemd 只给单调时钟时间戳，
// 减掉开机时长才能换算成「这个服务已经跑了多久」。读不到就返回 false，
// 调用方会跳过运行时长而不是报错。
func systemUptimeSeconds() (float64, bool) {
	data, err := os.ReadFile("/proc/uptime")
	if err != nil {
		return 0, false
	}
	fields := strings.Fields(string(data))
	if len(fields) == 0 {
		return 0, false
	}
	seconds, err := strconv.ParseFloat(fields[0], 64)
	if err != nil || seconds <= 0 {
		return 0, false
	}
	return seconds, true
}
