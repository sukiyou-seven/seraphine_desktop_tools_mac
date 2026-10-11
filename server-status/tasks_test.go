package main

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func testTask(id string) scheduledTask {
	return scheduledTask{ID: id, Name: "备份", Frequency: "daily", Time: "03:15", Weekday: "Mon",
		Executable: "/bin/echo", Arguments: []string{"hello", "world"}, Directory: "/tmp", Enabled: true}
}

func TestTaskCalendarAndValidation(t *testing.T) {
	task := testTask("nightly")
	if got, err := taskCalendar(task); err != nil || got != "*-*-* 03:15:00" {
		t.Fatalf("daily: %q %v", got, err)
	}
	task.Frequency, task.Time, task.Weekday = "weekly", "21:30", "Fri"
	if got, err := taskCalendar(task); err != nil || got != "Fri *-*-* 21:30:00" {
		t.Fatalf("weekly: %q %v", got, err)
	}
	task.Frequency, task.Time = "hourly", "05"
	if got, err := taskCalendar(task); err != nil || got != "*-*-* *:05:00" {
		t.Fatalf("hourly: %q %v", got, err)
	}
	for _, bad := range []scheduledTask{
		func() scheduledTask { v := task; v.ID = "../escape"; return v }(),
		func() scheduledTask { v := task; v.Executable = "echo"; return v }(),
		func() scheduledTask { v := task; v.Arguments = []string{"a\x00b"}; return v }(),
		func() scheduledTask { v := task; v.Time = "*"; return v }(),
	} {
		if validateTask(bad) == nil {
			t.Fatalf("accepted invalid task: %+v", bad)
		}
	}
}

func TestTaskLifecycleAndDirectExecution(t *testing.T) {
	root := t.TempDir()
	tm := newTaskManager(root)
	tm.unitDir = filepath.Join(root, "units")
	if err := os.MkdirAll(tm.unitDir, 0700); err != nil {
		t.Fatal(err)
	}
	var calls [][]string
	tm.systemctl = func(_ context.Context, args ...string) ([]byte, error) {
		calls = append(calls, append([]string(nil), args...))
		return nil, nil
	}
	task := testTask("nightly")
	if err := tm.save(context.Background(), task, true); err != nil {
		t.Fatal(err)
	}
	if len(calls) != 2 || strings.Join(calls[1], " ") != "enable --now sera-task-nightly.timer" {
		t.Fatalf("systemctl calls: %v", calls)
	}
	service, timer := tm.unitPaths(task.ID)
	unit, err := os.ReadFile(service)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(unit), "hello") || !strings.Contains(string(unit), "task-run -root /www/seraphim -id nightly") {
		t.Fatalf("unsafe service unit: %s", unit)
	}
	if data, err := os.ReadFile(timer); err != nil || !strings.Contains(string(data), "OnCalendar=*-*-* 03:15:00") {
		t.Fatalf("timer: %s %v", data, err)
	}
	if err := taskRunCommand([]string{"-root", root, "-id", "nightly"}); err != nil {
		t.Fatal(err)
	}
	items, err := tm.list()
	if err != nil || len(items) != 1 || items[0].LastResult != "成功" {
		t.Fatalf("list: %+v %v", items, err)
	}
	log, err := os.ReadFile(tm.logPath("nightly"))
	if err != nil || !strings.Contains(string(log), "hello world") {
		t.Fatalf("log: %s %v", log, err)
	}
	task.Enabled = false
	if err := tm.save(context.Background(), task, false); err != nil {
		t.Fatal(err)
	}
	if err := taskRunCommand([]string{"-root", root, "-id", "nightly"}); err == nil {
		t.Fatal("disabled task ran")
	}
	if err := tm.delete(context.Background(), "nightly"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(tm.taskPath("nightly")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("task file remains: %v", err)
	}
}

func TestTaskAPIAuthenticationAndRollback(t *testing.T) {
	root := t.TempDir()
	tm := newTaskManager(root)
	tm.unitDir = filepath.Join(root, "units")
	if err := os.MkdirAll(tm.unitDir, 0700); err != nil {
		t.Fatal(err)
	}
	tm.systemctl = func(_ context.Context, args ...string) ([]byte, error) {
		if len(args) > 0 && args[0] == "enable" {
			return []byte("failed"), errors.New("failed")
		}
		return nil, nil
	}
	a := &api{token: "secret", tasks: tm}
	task := testTask("nightly")
	data, _ := json.Marshal(task)
	request := func(method, path, bearer, body string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, path, strings.NewReader(body))
		r.Header.Set("Authorization", bearer)
		w := httptest.NewRecorder()
		a.tasksHandler(w, r)
		return w
	}
	if got := request("GET", "/v1/tasks", "", "").Code; got != 401 {
		t.Fatalf("unauthenticated list: %d", got)
	}
	if got := request("POST", "/v1/tasks", "Bearer secret", string(data)).Code; got != 409 {
		t.Fatalf("failed install: %d", got)
	}
	if _, err := os.Stat(tm.taskPath("nightly")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("failed install left JSON: %v", err)
	}
	if got := request("GET", "/v1/tasks", "Bearer secret", "").Code; got != http.StatusOK {
		t.Fatalf("list: %d", got)
	}
}
