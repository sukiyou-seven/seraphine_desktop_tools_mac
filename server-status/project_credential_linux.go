//go:build linux

package main

import (
	"os/exec"
	"syscall"
)

func setProjectCredential(cmd *exec.Cmd, uid, gid int) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Credential: &syscall.Credential{Uid: uint32(uid), Gid: uint32(gid)}}
}
