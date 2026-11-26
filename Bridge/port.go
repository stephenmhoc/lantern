package main

import (
	"errors"
	"fmt"
	"log"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// claimPort listens on the bridge's port. Another lantern-bridge already on it is an older one
// (Lantern for Mac before 2.0 ran its bridge as a child of the app, which outlives it; an update
// leaves the old binary running): it's asked to stop, and the port is tried again for a few
// seconds. Its folder, certificate and devices are this bridge's, so paired devices carry on.
// Anything else on the port is an error that names it.
func claimPort(port int) (net.Listener, error) {
	addr := fmt.Sprintf(":%d", port)
	ln, err := net.Listen("tcp", addr)
	if err == nil || !errors.Is(err, syscall.EADDRINUSE) {
		return ln, err
	}
	for _, pid := range listeners(port) {
		name := processName(pid)
		if name != "lantern-bridge" {
			return nil, fmt.Errorf("port %d is in use by %s (pid %d)", port, name, pid)
		}
		log.Printf("stopping the older lantern-bridge on :%d (pid %d)", port, pid)
		_ = syscall.Kill(pid, syscall.SIGTERM)
	}
	deadline := time.Now().Add(8 * time.Second)
	for {
		if ln, err = net.Listen("tcp", addr); err == nil || time.Now().After(deadline) {
			return ln, err
		}
		time.Sleep(250 * time.Millisecond)
	}
}

// listeners are the processes listening on a TCP port, other than this one (lsof).
func listeners(port int) []int {
	out, _ := exec.Command("/usr/sbin/lsof", "-nP", "-t", fmt.Sprintf("-iTCP:%d", port), "-sTCP:LISTEN").Output()
	var pids []int
	for _, field := range strings.Fields(string(out)) {
		if pid, err := strconv.Atoi(field); err == nil && pid != os.Getpid() {
			pids = append(pids, pid)
		}
	}
	return pids
}

// processName is a process's executable name ("lantern-bridge").
func processName(pid int) string {
	out, err := exec.Command("/bin/ps", "-o", "comm=", "-p", strconv.Itoa(pid)).Output()
	if err != nil {
		return "an unknown process"
	}
	return filepath.Base(strings.TrimSpace(string(out)))
}
