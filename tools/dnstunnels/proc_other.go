//go:build !linux

package main

import "os/exec"

// dieWithParent does nothing here: on Windows the programs of a connection are in one job that is closed with the app, and on a Mac
// Kumo stops them by name.
func dieWithParent(*exec.Cmd) {}