package main

import (
	"fmt"
	"os"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const schemaVersion = 1

type hostStatus struct {
	Hostname      string `json:"hostname"`
	OS            string `json:"os"`
	Kernel        string `json:"kernel"`
	Architecture  string `json:"architecture"`
	UptimeSeconds uint64 `json:"uptime_seconds"`
}

type cpuStatus struct {
	UsagePercent float64 `json:"usage_percent"`
	LogicalCores int     `json:"logical_cores"`
	Load1m       float64 `json:"load_1m"`
	Load5m       float64 `json:"load_5m"`
	Load15m      float64 `json:"load_15m"`
}

type memoryStatus struct {
	TotalBytes     uint64  `json:"total_bytes"`
	AvailableBytes uint64  `json:"available_bytes"`
	UsedBytes      uint64  `json:"used_bytes"`
	UsagePercent   float64 `json:"usage_percent"`
}

type swapStatus struct {
	TotalBytes   uint64  `json:"total_bytes"`
	UsedBytes    uint64  `json:"used_bytes"`
	UsagePercent float64 `json:"usage_percent"`
}

type diskStatus struct {
	Device         string  `json:"device"`
	Mountpoint     string  `json:"mountpoint"`
	Filesystem     string  `json:"filesystem"`
	TotalBytes     uint64  `json:"total_bytes"`
	AvailableBytes uint64  `json:"available_bytes"`
	UsedBytes      uint64  `json:"used_bytes"`
	UsagePercent   float64 `json:"usage_percent"`
}

type networkStatus struct {
	Name             string `json:"name"`
	RXBytes          uint64 `json:"rx_bytes"`
	TXBytes          uint64 `json:"tx_bytes"`
	RXBytesPerSecond uint64 `json:"rx_bytes_per_second"`
	TXBytesPerSecond uint64 `json:"tx_bytes_per_second"`
}

type snapshot struct {
	SchemaVersion int             `json:"schema_version"`
	Timestamp     string          `json:"timestamp"`
	Host          hostStatus      `json:"host"`
	CPU           cpuStatus       `json:"cpu"`
	Memory        memoryStatus    `json:"memory"`
	Swap          swapStatus      `json:"swap"`
	Disks         []diskStatus    `json:"disks"`
	Network       []networkStatus `json:"network"`
}

type cpuTimes struct{ total, idle uint64 }
type netCounters struct{ rx, tx uint64 }

func read(path string) (string, error) {
	data, err := os.ReadFile(path)
	return string(data), err
}

func percent(used, total uint64) float64 {
	if total == 0 {
		return 0
	}
	return float64(uint64(float64(used)/float64(total)*1000+0.5)) / 10
}

func parseCPU(text string) (cpuTimes, error) {
	fields := strings.Fields(strings.SplitN(text, "\n", 2)[0])
	if len(fields) < 5 || fields[0] != "cpu" {
		return cpuTimes{}, fmt.Errorf("invalid /proc/stat CPU line")
	}
	var result cpuTimes
	for i, field := range fields[1:] {
		if i >= 8 { // Linux guest fields are already included in user/nice.
			break
		}
		value, err := strconv.ParseUint(field, 10, 64)
		if err != nil {
			return cpuTimes{}, err
		}
		result.total += value
		if i == 3 || i == 4 {
			result.idle += value
		}
	}
	return result, nil
}

func cpuUsage(before, after cpuTimes) float64 {
	if after.total <= before.total || after.idle < before.idle {
		return 0
	}
	total := after.total - before.total
	idle := after.idle - before.idle
	if idle > total {
		return 0
	}
	return percent(total-idle, total)
}

func parseMeminfo(text string) (map[string]uint64, error) {
	values := make(map[string]uint64)
	for _, line := range strings.Split(text, "\n") {
		key, raw, found := strings.Cut(line, ":")
		if !found {
			continue
		}
		fields := strings.Fields(raw)
		if len(fields) == 0 {
			continue
		}
		value, err := strconv.ParseUint(fields[0], 10, 64)
		if err != nil {
			return nil, err
		}
		if len(fields) > 1 && fields[1] == "kB" {
			value *= 1024
		}
		values[key] = value
	}
	return values, nil
}

func memoryMetrics(values map[string]uint64) (memoryStatus, swapStatus, error) {
	total, okTotal := values["MemTotal"]
	available, okAvailable := values["MemAvailable"]
	if !okTotal || !okAvailable || total == 0 {
		return memoryStatus{}, swapStatus{}, fmt.Errorf("missing memory values")
	}
	if available > total {
		available = total
	}
	used := total - available
	swapTotal := values["SwapTotal"]
	swapFree := values["SwapFree"]
	if swapFree > swapTotal {
		swapFree = swapTotal
	}
	swapUsed := swapTotal - swapFree
	return memoryStatus{total, available, used, percent(used, total)},
		swapStatus{swapTotal, swapUsed, percent(swapUsed, swapTotal)}, nil
}

func parseNetwork(text string) (map[string]netCounters, error) {
	result := make(map[string]netCounters)
	for _, line := range strings.Split(text, "\n") {
		name, raw, found := strings.Cut(line, ":")
		if !found {
			continue
		}
		name = strings.TrimSpace(name)
		if name == "lo" {
			continue
		}
		fields := strings.Fields(raw)
		if len(fields) < 16 {
			return nil, fmt.Errorf("invalid network counters for %s", name)
		}
		rx, err := strconv.ParseUint(fields[0], 10, 64)
		if err != nil {
			return nil, err
		}
		tx, err := strconv.ParseUint(fields[8], 10, 64)
		if err != nil {
			return nil, err
		}
		result[name] = netCounters{rx, tx}
	}
	return result, nil
}

var pseudoFS = map[string]bool{
	"autofs": true, "bpf": true, "cgroup": true, "cgroup2": true,
	"configfs": true, "debugfs": true, "devpts": true, "devtmpfs": true,
	"efivarfs": true, "fusectl": true, "hugetlbfs": true, "mqueue": true,
	"nsfs": true, "proc": true, "pstore": true, "ramfs": true,
	"securityfs": true, "squashfs": true, "sysfs": true, "tmpfs": true,
	"tracefs": true,
}

type mount struct{ device, path, fs string }

func parseMounts(text string) []mount {
	var result []mount
	seen := make(map[string]bool)
	replacer := strings.NewReplacer(`\040`, " ", `\011`, "\t", `\012`, "\n", `\134`, `\`)
	for _, line := range strings.Split(text, "\n") {
		fields := strings.Fields(line)
		if len(fields) < 3 {
			continue
		}
		device, path, fs := replacer.Replace(fields[0]), replacer.Replace(fields[1]), fields[2]
		if seen[path] || (pseudoFS[fs] && path != "/") {
			continue
		}
		seen[path] = true
		result = append(result, mount{device, path, fs})
	}
	sort.Slice(result, func(i, j int) bool {
		if result[i].path == "/" && result[j].path != "/" {
			return true
		}
		if result[j].path == "/" {
			return false
		}
		return result[i].path < result[j].path
	})
	return result
}

func diskMetrics(text string) []diskStatus {
	result := make([]diskStatus, 0)
	seenDevice := make(map[string]bool)
	for _, mount := range parseMounts(text) {
		// Bind mounts such as /var/tmp can refer to the same block device as /.
		if strings.HasPrefix(mount.device, "/dev/") && seenDevice[mount.device] {
			continue
		}
		var stats syscall.Statfs_t
		if err := syscall.Statfs(mount.path, &stats); err != nil {
			continue // A mount can disappear between reading and statfs.
		}
		total := stats.Blocks * uint64(stats.Bsize)
		if total == 0 {
			continue
		}
		free := stats.Bfree * uint64(stats.Bsize)
		available := stats.Bavail * uint64(stats.Bsize)
		if free > total {
			free = total
		}
		if available > total {
			available = total
		}
		used := total - free
		result = append(result, diskStatus{mount.device, mount.path, mount.fs,
			total, available, used, percent(used, total)})
		if strings.HasPrefix(mount.device, "/dev/") {
			seenDevice[mount.device] = true
		}
	}
	return result
}

func osName(text string) string {
	for _, line := range strings.Split(text, "\n") {
		if strings.HasPrefix(line, "PRETTY_NAME=") {
			return strings.Trim(strings.TrimPrefix(line, "PRETTY_NAME="), `"`)
		}
	}
	return "Linux"
}

func collect(interval time.Duration) (snapshot, error) {
	var result snapshot
	result.SchemaVersion = schemaVersion
	result.Disks = []diskStatus{}
	result.Network = []networkStatus{}
	beforeCPUText, err := read("/proc/stat")
	if err != nil {
		return result, err
	}
	beforeCPU, err := parseCPU(beforeCPUText)
	if err != nil {
		return result, err
	}
	beforeNetText, err := read("/proc/net/dev")
	if err != nil {
		return result, err
	}
	beforeNet, err := parseNetwork(beforeNetText)
	if err != nil {
		return result, err
	}
	start := time.Now()
	time.Sleep(interval)
	elapsed := time.Since(start).Seconds()
	afterCPUText, err := read("/proc/stat")
	if err != nil {
		return result, err
	}
	afterCPU, err := parseCPU(afterCPUText)
	if err != nil {
		return result, err
	}
	afterNetText, err := read("/proc/net/dev")
	if err != nil {
		return result, err
	}
	afterNet, err := parseNetwork(afterNetText)
	if err != nil {
		return result, err
	}
	memText, err := read("/proc/meminfo")
	if err != nil {
		return result, err
	}
	memValues, err := parseMeminfo(memText)
	if err != nil {
		return result, err
	}
	result.Memory, result.Swap, err = memoryMetrics(memValues)
	if err != nil {
		return result, err
	}
	loadText, err := read("/proc/loadavg")
	if err != nil {
		return result, err
	}
	loadFields := strings.Fields(loadText)
	if len(loadFields) < 3 {
		return result, fmt.Errorf("invalid /proc/loadavg")
	}
	load1, err := strconv.ParseFloat(loadFields[0], 64)
	if err != nil {
		return result, err
	}
	load5, err := strconv.ParseFloat(loadFields[1], 64)
	if err != nil {
		return result, err
	}
	load15, err := strconv.ParseFloat(loadFields[2], 64)
	if err != nil {
		return result, err
	}
	uptimeText, err := read("/proc/uptime")
	if err != nil {
		return result, err
	}
	uptimeFields := strings.Fields(uptimeText)
	if len(uptimeFields) == 0 {
		return result, fmt.Errorf("invalid /proc/uptime")
	}
	uptime, err := strconv.ParseFloat(uptimeFields[0], 64)
	if err != nil {
		return result, err
	}
	osText, err := read("/etc/os-release")
	if err != nil {
		return result, err
	}
	kernelText, err := read("/proc/sys/kernel/osrelease")
	if err != nil {
		return result, err
	}
	mountText, err := read("/proc/self/mounts")
	if err != nil {
		return result, err
	}
	hostname, err := os.Hostname()
	if err != nil {
		return result, err
	}
	result.Timestamp = time.Now().UTC().Format(time.RFC3339)
	result.Host = hostStatus{hostname, osName(osText), strings.TrimSpace(kernelText), runtime.GOARCH, uint64(uptime)}
	result.CPU = cpuStatus{cpuUsage(beforeCPU, afterCPU), runtime.NumCPU(), load1, load5, load15}
	result.Disks = diskMetrics(mountText)
	for name, now := range afterNet {
		previous, ok := beforeNet[name]
		if !ok {
			previous = now
		}
		rxRate, txRate := uint64(0), uint64(0)
		if elapsed > 0 {
			if now.rx >= previous.rx {
				rxRate = uint64(float64(now.rx-previous.rx)/elapsed + 0.5)
			}
			if now.tx >= previous.tx {
				txRate = uint64(float64(now.tx-previous.tx)/elapsed + 0.5)
			}
		}
		result.Network = append(result.Network, networkStatus{name, now.rx, now.tx, rxRate, txRate})
	}
	sort.Slice(result.Network, func(i, j int) bool { return result.Network[i].Name < result.Network[j].Name })
	return result, nil
}
