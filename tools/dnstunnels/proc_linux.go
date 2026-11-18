//go:build linux

package main

import (
	"os/exec"
	"syscall"
)

// dieWithParent has the kernel kill [cmd] when this program is gone, so that the helper of a tunnel never outlives it (on a phone
// this program is killed, not asked to stop).
func dieWithParent(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Pdeathsig: syscall.SIGKILL}
}