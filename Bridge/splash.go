package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

// Splash serves the model: one `splash serve` the bridge starts with it, keeps running and stops
// with it. Everything the bridge asks of it is here.
const (
	splashModel       = "unsloth/Inkling-2-Mini-GGUF:UD-Q4_K_M"
	splashDraft       = "incoai/Inkling-2-Mini-DFlash2"
	splashMinVersion  = "1.7.3"
	defaultSplashPort = 11480
)

// splashArgs are the one place Splash's launch arguments live. The model stays resident (no idle
// release), only this Mac can reach it, and there's no chat page: devices come through the bridge.
func splashArgs(port int) []string {
	return []string{"serve",
		"--model", splashModel,
		"--draft-model", splashDraft,
		"--host", "127.0.0.1",
		"--port", strconv.Itoa(port),
		"--idle-release", "off",
		"--no-webui",
	}
}

// Splash's exit status when it gives up (a model it can't fetch, not enough memory): retrying at
// once won't help, so the bridge waits longest before trying again.
const splashGaveUp = 69

type splashState string

const (
	splashStarting splashState = "starting"
	splashReady    splashState = "ready"
	splashFailed   splashState = "failed"
)

// What the admin API says about Splash.
type splashStatus struct {
	State    splashState   `json:"state"`
	Message  string        `json:"message,omitempty"` // why it failed, or what it's doing
	Version  string        `json:"version,omitempty"`
	URL      string        `json:"url"`
	Model    string        `json:"model"`
	Adopted  bool          `json:"adopted"` // a server the bridge didn't start (LANTERN_BRIDGE_UPSTREAM)
	Restarts int           `json:"restarts"`
	Since    time.Time     `json:"since"`
	Drafter  *drafterStats `json:"drafter,omitempty"`
}

// The drafter's work on the last reply, from the stream's final chunk (`timings`, and
// `metrics.speculation` when Splash reports it).
type drafterStats struct {
	Drafted       int       `json:"draft_n"`
	Accepted      int       `json:"draft_n_accepted"`
	AcceptRate    float64   `json:"accept_rate"`
	Cycles        int       `json:"cycles,omitempty"`
	TokensPerStep float64   `json:"tokens_per_step,omitempty"`
	TokensPerSec  float64   `json:"tokens_per_second,omitempty"`
	At            time.Time `json:"at"`
}

type splash struct {
	url     string // http://127.0.0.1:<port>
	port    int
	adopted bool
	dir     string // the bridge's folder: splash.pid and splash.log

	mu     sync.Mutex
	status splashStatus
	client *http.Client
}

func newSplash(dir string, port int, upstream string) *splash {
	s := &splash{dir: dir, port: port, url: fmt.Sprintf("http://127.0.0.1:%d", port), client: &http.Client{Timeout: 3 * time.Second}}
	if upstream != "" {
		s.url, s.adopted = strings.TrimRight(upstream, "/"), true
	}
	s.status = splashStatus{State: splashStarting, URL: s.url, Model: splashModel, Adopted: s.adopted, Since: time.Now()}
	return s
}

func (s *splash) snapshot() splashStatus {
	s.mu.Lock()
	defer s.mu.Unlock()
	st := s.status
	if st.Drafter != nil {
		d := *st.Drafter
		st.Drafter = &d
	}
	return st
}

func (s *splash) set(state splashState, message string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.status.State != state || s.status.Message != message {
		log.Printf("splash: %s %s", state, message)
		s.status.Since = time.Now()
	}
	s.status.State, s.status.Message = state, message
}

func (s *splash) ready() (bool, string) {
	st := s.snapshot()
	switch st.State {
	case splashReady:
		return true, ""
	case splashFailed:
		return false, st.Message
	default:
		return false, "The model is starting."
	}
}

// run keeps Splash serving until ctx ends, then stops it. An adopted server is only watched.
func (s *splash) run(ctx context.Context, restartNow <-chan struct{}) {
	if s.adopted {
		s.watchAdopted(ctx)
		return
	}
	backoff := 2 * time.Second
	for ctx.Err() == nil {
		bin, version, err := findSplash()
		s.mu.Lock()
		s.status.Version = version
		s.mu.Unlock()
		if err != nil {
			s.set(splashFailed, err.Error())
			backoff = time.Minute // installing or updating it takes a while
		} else {
			started := time.Now()
			code, message := s.serveOnce(ctx, bin)
			if ctx.Err() != nil {
				return
			}
			if time.Since(started) > 5*time.Minute {
				backoff = 2 * time.Second // it ran fine for a while: this is a new problem
			}
			if code == splashGaveUp {
				backoff = 5 * time.Minute
			}
			s.set(splashFailed, message)
			s.mu.Lock()
			s.status.Restarts++
			s.mu.Unlock()
		}
		select {
		case <-ctx.Done():
			return
		case <-restartNow:
			backoff = 2 * time.Second
		case <-time.After(backoff):
			backoff = min(backoff*2, 5*time.Minute)
		}
	}
}

// serveOnce runs one `splash serve` until it exits or ctx ends, and says why it stopped.
func (s *splash) serveOnce(ctx context.Context, bin string) (int, string) {
	s.killLeftover()
	s.set(splashStarting, "")
	logFile, err := os.OpenFile(filepath.Join(s.dir, "splash.log"), os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		return 1, err.Error()
	}
	defer logFile.Close()
	tail := &lastLines{max: 30}
	cmd := exec.Command(bin, splashArgs(s.port)...)
	cmd.Stdout = io.MultiWriter(logFile, tail)
	cmd.Stderr = cmd.Stdout
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true} // its workers stop with it
	if err := cmd.Start(); err != nil {
		return 1, "Splash didn't start: " + err.Error()
	}
	pidPath := filepath.Join(s.dir, "splash.pid")
	_ = writePrivate(pidPath, []byte(strconv.Itoa(cmd.Process.Pid)))
	defer os.Remove(pidPath)
	log.Printf("splash: started %s %s (pid %d)", bin, strings.Join(splashArgs(s.port), " "), cmd.Process.Pid)

	exited := make(chan error, 1)
	go func() { exited <- cmd.Wait() }()
	ready := time.NewTicker(time.Second)
	defer ready.Stop()
	for {
		select {
		case err := <-exited:
			code := cmd.ProcessState.ExitCode()
			message := tail.reason()
			if message == "" && err != nil {
				message = err.Error()
			}
			if message == "" {
				message = fmt.Sprintf("Splash stopped (exit %d).", code)
			}
			return code, message
		case <-ready.C:
			if st := s.snapshot(); st.State != splashReady && s.probe(ctx) {
				s.set(splashReady, "")
			}
		case <-ctx.Done():
			// As Ctrl+C would; then for good if it hasn't stopped in time.
			_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGINT)
			select {
			case <-exited:
			case <-time.After(15 * time.Second):
				_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
				<-exited
			}
			s.set(splashStarting, "stopped")
			return 0, ""
		}
	}
}

// killLeftover stops a Splash a bridge that died without stopping left behind, which would
// otherwise hold the port.
func (s *splash) killLeftover() {
	data, err := os.ReadFile(filepath.Join(s.dir, "splash.pid"))
	if err != nil {
		return
	}
	pid, _ := strconv.Atoi(strings.TrimSpace(string(data)))
	if pid <= 1 {
		return
	}
	out, _ := exec.Command("/bin/ps", "-o", "command=", "-p", strconv.Itoa(pid)).Output()
	if !strings.Contains(string(out), "splash") || !strings.Contains(string(out), "--port "+strconv.Itoa(s.port)) {
		return
	}
	log.Printf("splash: stopping one left running (pid %d)", pid)
	_ = syscall.Kill(-pid, syscall.SIGINT)
	_ = syscall.Kill(pid, syscall.SIGINT)
	for range 30 {
		if syscall.Kill(pid, 0) != nil {
			return
		}
		time.Sleep(500 * time.Millisecond)
	}
	_ = syscall.Kill(-pid, syscall.SIGKILL)
	_ = syscall.Kill(pid, syscall.SIGKILL)
}

func (s *splash) watchAdopted(ctx context.Context) {
	if out, err := exec.Command("/bin/sh", "-c", "command -v splash").Output(); err == nil {
		if _, v, err := findSplashAt(strings.TrimSpace(string(out))); err == nil {
			s.mu.Lock()
			s.status.Version = v
			s.mu.Unlock()
		}
	}
	for ctx.Err() == nil {
		if s.probe(ctx) {
			s.set(splashReady, "")
		} else {
			s.set(splashFailed, "Splash isn't answering at "+s.url+".")
		}
		select {
		case <-ctx.Done():
		case <-time.After(5 * time.Second):
		}
	}
}

func (s *splash) probe(ctx context.Context) bool {
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, s.url+"/ready", nil)
	resp, err := s.client.Do(req)
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	var body struct{ Status string }
	_ = json.NewDecoder(io.LimitReader(resp.Body, 4096)).Decode(&body)
	return resp.StatusCode == http.StatusOK && body.Status == "ready"
}

// noteTimings keeps the drafter's numbers from a reply's final chunk.
func (s *splash) noteTimings(chunk []byte) {
	var c struct {
		Timings *struct {
			DraftN          int     `json:"draft_n"`
			DraftAccepted   int     `json:"draft_n_accepted"`
			PredictedPerSec float64 `json:"predicted_per_second"`
		} `json:"timings"`
		Metrics *struct {
			Speculation *struct {
				Drafted  int `json:"drafted_tokens"`
				Accepted int `json:"accepted_draft_tokens"`
				Cycles   int `json:"cycles"`
			} `json:"speculation"`
		} `json:"metrics"`
	}
	if json.Unmarshal(chunk, &c) != nil {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	d := s.status.Drafter
	if d == nil || time.Since(d.At) > time.Minute {
		d = &drafterStats{}
	}
	if t := c.Timings; t != nil {
		*d = drafterStats{Drafted: t.DraftN, Accepted: t.DraftAccepted, TokensPerSec: t.PredictedPerSec}
	}
	if c.Metrics != nil && c.Metrics.Speculation != nil {
		sp := c.Metrics.Speculation
		if c.Timings == nil {
			d.Drafted, d.Accepted = sp.Drafted, sp.Accepted
		}
		d.Cycles = sp.Cycles
		if sp.Cycles > 0 {
			d.TokensPerStep = float64(sp.Accepted+sp.Cycles) / float64(sp.Cycles) // each step: what it accepted, then the model's own token
		}
	}
	if d.Drafted > 0 {
		d.AcceptRate = float64(d.Accepted) / float64(d.Drafted)
	}
	d.At = time.Now()
	s.status.Drafter = d
}

// findSplash finds `splash` on the PATH or where Homebrew puts it, new enough.
func findSplash() (string, string, error) {
	dirs := append(filepath.SplitList(os.Getenv("PATH")), "/opt/homebrew/bin", "/usr/local/bin")
	var tooOld error
	var oldVersion string
	for _, dir := range dirs {
		path := filepath.Join(dir, "splash")
		if info, err := os.Stat(path); err != nil || info.IsDir() {
			continue
		}
		bin, v, err := findSplashAt(path)
		if err == nil {
			return bin, v, nil
		}
		tooOld, oldVersion = err, v
	}
	if tooOld != nil {
		return "", oldVersion, tooOld
	}
	return "", "", errors.New("Splash isn't installed: brew install incoai/tap/splash")
}

func findSplashAt(path string) (string, string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, path, "--version").CombinedOutput()
	if err != nil {
		return "", "", fmt.Errorf("Splash at %s didn't run: %v", path, err)
	}
	v := strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(string(out)), "Splash"))
	if !versionAtLeast(v, splashMinVersion) {
		return "", v, fmt.Errorf("Splash %s is too old (%s or later needed). Update Splash: brew upgrade splash", v, splashMinVersion)
	}
	return path, v, nil
}

func versionAtLeast(v, want string) bool {
	a, b := strings.Split(v, "."), strings.Split(want, ".")
	for i := range b {
		var x, y int
		if i < len(a) {
			x, _ = strconv.Atoi(strings.TrimLeftFunc(a[i], func(r rune) bool { return r < '0' || r > '9' }))
		}
		y, _ = strconv.Atoi(b[i])
		if x != y {
			return x > y
		}
	}
	return true
}

// lastLines keeps the end of Splash's output, to say why it stopped.
type lastLines struct {
	mu      sync.Mutex
	max     int
	lines   []string
	partial string
}

func (l *lastLines) Write(p []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	text := l.partial + string(p)
	l.partial = ""
	sc := bufio.NewScanner(strings.NewReader(text))
	sc.Buffer(make([]byte, 0, 64<<10), 1<<20)
	complete := strings.HasSuffix(text, "\n")
	var got []string
	for sc.Scan() {
		got = append(got, sc.Text())
	}
	if !complete && len(got) > 0 {
		l.partial, got = got[len(got)-1], got[:len(got)-1]
	}
	for _, line := range got {
		if line = strings.TrimSpace(line); line != "" {
			l.lines = append(l.lines, line)
		}
	}
	if len(l.lines) > l.max {
		l.lines = l.lines[len(l.lines)-l.max:]
	}
	return len(p), nil
}

// reason is Splash's last `error:` line, or else its last line.
func (l *lastLines) reason() string {
	l.mu.Lock()
	defer l.mu.Unlock()
	lines := l.lines
	if l.partial != "" {
		lines = append(lines, l.partial)
	}
	for i := len(lines) - 1; i >= 0; i-- {
		if rest, ok := strings.CutPrefix(lines[i], "error:"); ok {
			return "Splash: " + strings.TrimSpace(rest)
		}
	}
	if len(lines) > 0 {
		return "Splash: " + lines[len(lines)-1]
	}
	return ""
}
