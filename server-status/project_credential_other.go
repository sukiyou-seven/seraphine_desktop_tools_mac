//go:build !linux

package main

import "os/exec"

func setProjectCredential(_ *exec.Cmd, _, _ int) {}
