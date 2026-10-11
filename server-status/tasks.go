package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"
)

// Tasks execute a program directly. Neither the client nor the daemon sends a shell command.
type scheduledTask struct {
	ID         string   `json:"id"`
	Name       string   `json:"name"`
	Frequency  string   `json:"frequency"`
	Time       string   `json:"time"`
	Weekday    string   `json:"weekday"`
	Executable string   `json:"executable"`
	Arguments  []string `json:"arguments"`
	Directory  string   `json:"directory"`
	Enabled    bool     `json:"enabled"`
	LastRun    string   `json:"last_run,omitempty"`
	LastResult string   `json:"last_result,omitempty"`
}

type taskManager struct {
	root      string
	unitDir   string
	systemctl func(context.Context, ...string) ([]byte, error)
	mu        sync.Mutex
}

var taskIDPattern = regexp.MustCompile(`^[a-z][a-z0-9-]{0,47}$`)
var taskTimePattern = regexp.MustCompile(`^([01][0-9]|2[0-3]):[0-5][0-9]$`)
var taskMinutePattern = regexp.MustCompile(`^[0-5][0-9]$`)
var taskWeekdays = map[string]bool{"Mon": true, "Tue": true, "Wed": true, "Thu": true, "Fri": true, "Sat": true, "Sun": true}

func newTaskManager(root string) *taskManager {
	return &taskManager{root: root, unitDir: "/etc/systemd/system", systemctl: runSystemctl}
}

func (tm *taskManager) taskDir() string           { return filepath.Join(tm.root, "server", "tasks") }
func (tm *taskManager) taskPath(id string) string { return filepath.Join(tm.taskDir(), id+".json") }
func (tm *taskManager) logPath(id string) string {
	return filepath.Join(tm.root, "logs", "tasks", id+".log")
}
func taskUnitName(id string) string { return "sera-task-" + id }

func taskCalendar(task scheduledTask) (string, error) {
	switch task.Frequency {
	case "hourly":
		if !taskMinutePattern.MatchString(task.Time) {
			return "", errors.New("invalid hourly minute")
		}
		return "*-*-* *:" + task.Time + ":00", nil
	case "daily":
		if !taskTimePattern.MatchString(task.Time) {
			return "", errors.New("invalid daily time")
		}
		return "*-*-* " + task.Time + ":00", nil
	case "weekly":
		if !taskTimePattern.MatchString(task.Time) || !taskWeekdays[task.Weekday] {
			return "", errors.New("invalid weekly schedule")
		}
		return task.Weekday + " *-*-* " + task.Time + ":00", nil
	default:
		return "", errors.New("invalid frequency")
	}
}

func validateTask(task scheduledTask) error {
	if !taskIDPattern.MatchString(task.ID) || len(task.Name) == 0 || len(task.Name) > 100 || strings.ContainsAny(task.Name, "\r\n\x00") {
		return errors.New("invalid task ID or name")
	}
	if _, err := taskCalendar(task); err != nil {
		return err
	}
	if !filepath.IsAbs(task.Executable) || !filepath.IsAbs(task.Directory) || strings.ContainsRune(task.Executable, 0) || strings.ContainsRune(task.Directory, 0) || len(task.Executable) > 1024 || len(task.Directory) > 1024 {
		return errors.New("executable and working directory must be absolute paths")
	}
	if len(task.Arguments) > 64 {
		return errors.New("too many arguments")
	}
	for _, arg := range task.Arguments {
		if len(arg) > 4096 || strings.ContainsRune(arg, 0) {
			return errors.New("invalid argument")
		}
	}
	return nil
}

func (tm *taskManager) read(id string) (scheduledTask, error) {
	if !taskIDPattern.MatchString(id) {
		return scheduledTask{}, os.ErrNotExist
	}
	data, err := os.ReadFile(tm.taskPath(id))
	if err != nil {
		return scheduledTask{}, err
	}
	var task scheduledTask
	if err = json.Unmarshal(data, &task); err != nil {
		return scheduledTask{}, err
	}
	if task.ID != id || validateTask(task) != nil {
		return scheduledTask{}, errors.New("corrupt task configuration")
	}
	return task, nil
}

func (tm *taskManager) list() ([]scheduledTask, error) {
	tm.mu.Lock()
	defer tm.mu.Unlock()
	entries, err := os.ReadDir(tm.taskDir())
	if errors.Is(err, os.ErrNotExist) {
		return []scheduledTask{}, nil
	}
	if err != nil {
		return nil, err
	}
	items := make([]scheduledTask, 0, len(entries))
	for _, entry := range entries {
		if !entry.Type().IsRegular() || !strings.HasSuffix(entry.Name(), ".json") || strings.HasSuffix(entry.Name(), ".last.json") {
			continue
		}
		id := strings.TrimSuffix(entry.Name(), ".json")
		task, err := tm.read(id)
		if err != nil {
			return nil, err
		}
		if data, err := os.ReadFile(filepath.Join(tm.taskDir(), id+".last.json")); err == nil {
			var result struct {
				LastRun    string `json:"last_run"`
				LastResult string `json:"last_result"`
			}
			if json.Unmarshal(data, &result) == nil {
				task.LastRun, task.LastResult = result.LastRun, result.LastResult
			}
		}
		items = append(items, task)
	}
	sort.Slice(items, func(i, j int) bool { return items[i].ID < items[j].ID })
	return items, nil
}

func (tm *taskManager) unitPaths(id string) (string, string) {
	base := taskUnitName(id)
	return filepath.Join(tm.unitDir, base+".service"), filepath.Join(tm.unitDir, base+".timer")
}

func (tm *taskManager) writeUnits(task scheduledTask) error {
	calendar, _ := taskCalendar(task)
	servicePath, timerPath := tm.unitPaths(task.ID)
	// The task ID is validated; all user supplied program details stay in the JSON file.
	service := "[Unit]\nDescription=Seraphim scheduled task " + task.ID + "\n[Service]\nType=oneshot\nUMask=0077\nNoNewPrivileges=yes\nTimeoutStartSec=24h\nExecStart=/www/seraphim/server/sera task-run -root /www/seraphim -id " + task.ID + "\n"
	timer := "[Unit]\nDescription=Seraphim timer " + task.ID + "\n[Timer]\nOnCalendar=" + calendar + "\nPersistent=true\nUnit=" + taskUnitName(task.ID) + ".service\n[Install]\nWantedBy=timers.target\n"
	if err := atomicSiteWrite(servicePath, []byte(service), 0644); err != nil {
		return err
	}
	return atomicSiteWrite(timerPath, []byte(timer), 0644)
}

func (tm *taskManager) apply(ctx context.Context, task scheduledTask) error {
	if err := tm.writeUnits(task); err != nil {
		return err
	}
	if out, err := tm.systemctl(ctx, "daemon-reload"); err != nil {
		return fmt.Errorf("daemon-reload: %s: %w", strings.TrimSpace(string(out)), err)
	}
	unit := taskUnitName(task.ID) + ".timer"
	action := []string{"disable", "--now", unit}
	if task.Enabled {
		action = []string{"enable", "--now", unit}
	}
	if out, err := tm.systemctl(ctx, action...); err != nil {
		return fmt.Errorf("timer action: %s: %w", strings.TrimSpace(string(out)), err)
	}
	return nil
}

func (tm *taskManager) save(ctx context.Context, task scheduledTask, create bool) error {
	if err := validateTask(task); err != nil {
		return err
	}
	tm.mu.Lock()
	defer tm.mu.Unlock()
	if err := os.MkdirAll(tm.taskDir(), 0700); err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Join(tm.root, "logs", "tasks"), 0700); err != nil {
		return err
	}
	path := tm.taskPath(task.ID)
	old, oldErr := os.ReadFile(path)
	if create && oldErr == nil {
		return os.ErrExist
	}
	if !create && errors.Is(oldErr, os.ErrNotExist) {
		return os.ErrNotExist
	}
	if oldErr != nil && !errors.Is(oldErr, os.ErrNotExist) {
		return oldErr
	}
	task.LastRun, task.LastResult = "", ""
	data, err := json.Marshal(task)
	if err != nil {
		return err
	}
	if err := atomicSiteWrite(path, data, 0600); err != nil {
		return err
	}
	if err := tm.apply(ctx, task); err != nil {
		rollback, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		if oldErr == nil {
			_ = atomicSiteWrite(path, old, 0600)
			var previous scheduledTask
			if json.Unmarshal(old, &previous) == nil {
				_ = tm.apply(rollback, previous)
			}
		} else {
			_, _ = tm.systemctl(rollback, "disable", "--now", taskUnitName(task.ID)+".timer")
			_ = os.Remove(path)
			service, timer := tm.unitPaths(task.ID)
			_ = os.Remove(service)
			_ = os.Remove(timer)
			_, _ = tm.systemctl(rollback, "daemon-reload")
		}
		return err
	}
	return nil
}

func (tm *taskManager) delete(ctx context.Context, id string) error {
	tm.mu.Lock()
	defer tm.mu.Unlock()
	if _, err := tm.read(id); err != nil {
		return err
	}
	unit := taskUnitName(id) + ".timer"
	if out, err := tm.systemctl(ctx, "disable", "--now", unit); err != nil {
		return fmt.Errorf("disable timer: %s: %w", strings.TrimSpace(string(out)), err)
	}
	service, timer := tm.unitPaths(id)
	for _, path := range []string{service, timer, tm.taskPath(id), filepath.Join(tm.taskDir(), id+".last.json")} {
		if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
	}
	_, err := tm.systemctl(ctx, "daemon-reload")
	return err
}

func taskRunCommand(args []string) error {
	flags := flag.NewFlagSet("task-run", flag.ContinueOnError)
	root := flags.String("root", "/www/seraphim", "Seraphim root")
	id := flags.String("id", "", "task ID")
	if err := flags.Parse(args); err != nil {
		return err
	}
	tm := newTaskManager(*root)
	task, err := tm.read(*id)
	if err != nil {
		return err
	}
	if !task.Enabled {
		return errors.New("task is disabled")
	}
	if info, err := os.Stat(task.Executable); err != nil || !info.Mode().IsRegular() || info.Mode()&0111 == 0 {
		return errors.New("task executable not available")
	}
	if info, err := os.Stat(task.Directory); err != nil || !info.IsDir() {
		return errors.New("task working directory not available")
	}
	if err := os.MkdirAll(filepath.Dir(tm.logPath(*id)), 0700); err != nil {
		return err
	}
	logFile, err := os.OpenFile(tm.logPath(*id), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0600)
	if err != nil {
		return err
	}
	defer logFile.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 24*time.Hour)
	defer cancel()
	cmd := exec.CommandContext(ctx, task.Executable, task.Arguments...)
	cmd.Dir = task.Directory
	cmd.Stdout, cmd.Stderr = logFile, logFile
	start := time.Now().UTC()
	_, _ = fmt.Fprintf(logFile, "\n[%s] start %s\n", start.Format(time.RFC3339), task.ID)
	err = cmd.Run()
	result := "成功"
	if err != nil {
		result = "失败：" + err.Error()
	}
	_, _ = fmt.Fprintf(logFile, "[%s] %s\n", time.Now().UTC().Format(time.RFC3339), result)
	status, _ := json.Marshal(struct {
		LastRun    string `json:"last_run"`
		LastResult string `json:"last_result"`
	}{start.Format(time.RFC3339), result})
	if writeErr := atomicSiteWrite(filepath.Join(tm.taskDir(), task.ID+".last.json"), status, 0600); writeErr != nil && err == nil {
		err = writeErr
	}
	return err
}

func (a *api) tasksHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	if !a.authorized(r) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	if a.tasks == nil {
		http.Error(w, "tasks unavailable", http.StatusServiceUnavailable)
		return
	}
	id := strings.TrimPrefix(r.URL.Path, "/v1/tasks/")
	if r.URL.Path == "/v1/tasks" {
		switch r.Method {
		case http.MethodGet:
			items, err := a.tasks.list()
			if err != nil {
				http.Error(w, "task list unavailable", 503)
				return
			}
			w.Header().Set("Content-Type", "application/json; charset=utf-8")
			_ = json.NewEncoder(w).Encode(struct {
				Items []scheduledTask `json:"items"`
			}{items})
		case http.MethodPost:
			var task scheduledTask
			if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 32<<10)).Decode(&task); err != nil {
				http.Error(w, "invalid task", 400)
				return
			}
			ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
			defer cancel()
			if err := a.tasks.save(ctx, task, true); err != nil {
				taskError(w, err)
				return
			}
			w.WriteHeader(http.StatusCreated)
		default:
			w.Header().Set("Allow", "GET, POST")
			http.Error(w, "method not allowed", 405)
		}
		return
	}
	if !taskIDPattern.MatchString(id) {
		http.Error(w, "invalid task ID", 400)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
	defer cancel()
	switch r.Method {
	case http.MethodPut:
		var task scheduledTask
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 32<<10)).Decode(&task); err != nil || task.ID != id {
			http.Error(w, "invalid task", 400)
			return
		}
		if err := a.tasks.save(ctx, task, false); err != nil {
			taskError(w, err)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	case http.MethodDelete:
		if err := a.tasks.delete(ctx, id); err != nil {
			taskError(w, err)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	case http.MethodGet:
		if r.URL.Query().Get("view") != "log" {
			http.Error(w, "invalid view", 400)
			return
		}
		if _, err := a.tasks.read(id); err != nil {
			taskError(w, err)
			return
		}
		file, err := os.Open(a.tasks.logPath(id))
		if errors.Is(err, os.ErrNotExist) {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		if err != nil {
			http.Error(w, "log unavailable", 503)
			return
		}
		defer file.Close()
		info, err := file.Stat()
		if err != nil {
			http.Error(w, "log unavailable", 503)
			return
		}
		if info.Size() > 64<<10 {
			_, _ = file.Seek(-(64 << 10), io.SeekEnd)
		}
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = io.Copy(w, io.LimitReader(file, 64<<10))
	default:
		w.Header().Set("Allow", "GET, PUT, DELETE")
		http.Error(w, "method not allowed", 405)
	}
}

func taskError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, os.ErrNotExist):
		http.Error(w, "task not found", 404)
	case errors.Is(err, os.ErrExist):
		http.Error(w, "task already exists", 409)
	default:
		http.Error(w, err.Error(), 409)
	}
}
