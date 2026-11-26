package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

const version = "0.1.0"

// What the bridge keeps in `settings.json`, edited by the Mac app (or by hand).
type settings struct {
	// The name devices see ("Mac Studio"); empty for the Mac's own.
	Name string `json:"name,omitempty"`
	Port int    `json:"port,omitempty"`
	// Ollama models kept loaded for good, not just for Ollama's keep-alive after each request.
	KeepLoaded []string `json:"keepLoaded,omitempty"`
	// Servers besides the ones looked for at their default ports.
	Backends []backend `json:"backends,omitempty"`
}

const defaultPort = 11443

type bridge struct {
	dir      string
	identity *identity
	devices  *deviceStore
	backends *backends

	mu  sync.Mutex
	cfg settings
}

func openBridge(dir string) (*bridge, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	_ = os.Chmod(dir, 0o700)
	b := &bridge{dir: dir}
	if data, err := os.ReadFile(filepath.Join(dir, "settings.json")); err == nil {
		if err := json.Unmarshal(data, &b.cfg); err != nil {
			return nil, fmt.Errorf("settings.json: %w", err)
		}
	}
	var err error
	if b.identity, err = loadIdentity(dir, b.name()); err != nil {
		return nil, err
	}
	if b.devices, err = loadDevices(filepath.Join(dir, "devices.json")); err != nil {
		return nil, err
	}
	b.backends = newBackends(b.cfg.Backends)
	return b, nil
}

func (b *bridge) settings() settings {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.cfg
}

func (b *bridge) update(change func(*settings)) error {
	b.mu.Lock()
	defer b.mu.Unlock()
	change(&b.cfg)
	data, err := json.MarshalIndent(b.cfg, "", "  ")
	if err != nil {
		return err
	}
	return writePrivate(filepath.Join(b.dir, "settings.json"), data)
}

func (b *bridge) port() int {
	if p := b.settings().Port; p > 0 {
		return p
	}
	return defaultPort
}

// name is what devices call this Mac: the settings' name, else the Mac's own ("Mac Studio").
func (b *bridge) name() string {
	if n := strings.TrimSpace(b.settings().Name); n != "" {
		return n
	}
	return computerName()
}

// changed is called when devices are paired or removed. The admin API is polled, so there is
// nothing to push yet.
func (b *bridge) changed() {}

func computerName() string {
	out, err := exec.Command("/usr/sbin/scutil", "--get", "ComputerName").Output()
	if name := strings.TrimSpace(string(out)); err == nil && name != "" {
		return name
	}
	host, _ := os.Hostname()
	return host
}

// addresses are where devices can reach the bridge, best first: the Mac's .local name (home
// network, internet or not), its MagicDNS name on the tailnet, then its IP addresses.
func (b *bridge) addresses() []string {
	port := fmt.Sprint(b.port())
	var out []string
	if out2, err := exec.Command("/usr/sbin/scutil", "--get", "LocalHostName").Output(); err == nil {
		if h := strings.TrimSpace(string(out2)); h != "" {
			out = append(out, net.JoinHostPort(h+".local", port))
		}
	}
	if name := tailnetName(); name != "" {
		out = append(out, net.JoinHostPort(name, port))
	}
	ifaces, _ := net.Interfaces()
	for _, iface := range ifaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}
		addrs, _ := iface.Addrs()
		for _, a := range addrs {
			ip, _, _ := net.ParseCIDR(a.String())
			if ip == nil || ip.To4() == nil || ip.IsLinkLocalUnicast() {
				continue
			}
			out = append(out, net.JoinHostPort(ip.String(), port))
		}
	}
	return out
}

// tailnetName is this Mac's MagicDNS name ("mac-studio.tail1234.ts.net"), or "" without Tailscale.
func tailnetName() string {
	for _, ts := range []string{"/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"} {
		if _, err := os.Stat(ts); err != nil {
			continue
		}
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		out, err := exec.CommandContext(ctx, ts, "status", "--json").Output()
		cancel()
		if err != nil {
			continue
		}
		var status struct {
			Self struct {
				DNSName string `json:"DNSName"`
			} `json:"Self"`
		}
		if json.Unmarshal(out, &status) == nil && status.Self.DNSName != "" {
			return strings.TrimSuffix(status.Self.DNSName, ".")
		}
	}
	return ""
}

// pairingLink is what the QR code holds: where the bridge is, the fingerprint of its certificate
// (which the device then trusts, and nothing else) and a one-time code for the device's token.
//
//	lantern://pair?v=1&name=Mac%20Studio&fp=<sha256 hex>&code=<one-time>&addr=<host:port>&addr=…
func (b *bridge) pairingLink(o offer) string {
	q := url.Values{}
	q.Set("v", "1")
	q.Set("name", b.name())
	q.Set("fp", b.identity.fingerprint)
	q.Set("code", o.code)
	for _, a := range b.addresses() {
		q.Add("addr", a)
	}
	return "lantern://pair?" + q.Encode()
}

// advertise registers the bridge over Bonjour (`_lantern._tcp`) for as long as ctx lasts, so
// Lantern finds it on the home network. The TXT record's fingerprint is for recognising a Mac
// already paired; trust comes only from pairing.
func (b *bridge) advertise(ctx context.Context) {
	for ctx.Err() == nil {
		cmd := exec.CommandContext(ctx, "/usr/bin/dns-sd", "-R", b.name(), "_lantern._tcp", "local", fmt.Sprint(b.port()),
			"v=1", "fp="+b.identity.fingerprint)
		if err := cmd.Run(); err != nil && ctx.Err() == nil {
			log.Printf("bonjour: %v", err)
		}
		select {
		case <-ctx.Done():
		case <-time.After(10 * time.Second):
		}
	}
}
