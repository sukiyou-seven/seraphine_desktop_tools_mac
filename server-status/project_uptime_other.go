//go:build !linux

package main

// 非 Linux 上没有 /proc/uptime，运行时长一栏留空即可。
func systemUptimeSeconds() (float64, bool) { return 0, false }
