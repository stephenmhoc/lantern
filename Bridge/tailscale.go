package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// Tailscale join keys. The serving Mac holds a Tailscale OAuth client (scope `auth_keys`, allowed
// to tag `tag:lantern`); when a device pairs, the bridge mints it a one-time, pre-authorized auth
// key for that tag, so the device joins the tailnet on its own and reaches this Mac away from home.
// Without a client, pairing works the same and the device is told it's home network only.
//
// The client is kept in `tailscale.json` in the bridge's folder (0600, like the certificate's key).
const (
	tailscaleTag       = "tag:lantern"
	tailscaleKeyExpiry = 15 * time.Minute // long enough to join right after pairing, and no longer
)

type tailscaleClient struct {
	ClientID     string `json:"client_id"`
	ClientSecret string `json:"client_secret"`
}

// What a pair response says about the tailnet.
type tailnetOffer struct {
	// "ok" (a key to join with), "not_configured" (home network only) or "failed" (the same, and why).
	Status  string    `json:"status"`
	Message string    `json:"message,omitempty"`
	AuthKey string    `json:"auth_key,omitempty"`
	Expires time.Time `json:"expires,omitzero"`
	Tags    []string  `json:"tags,omitempty"`
	// This Mac on the tailnet: its MagicDNS name, its addresses, and the bridge there.
	Host    string   `json:"host,omitempty"`
	IPs     []string `json:"ips,omitempty"`
	Address string   `json:"address,omitempty"` // host:port
}

type tailscale struct {
	path string
	api  string // https://api.tailscale.com, or a stand-in (LANTERN_TAILSCALE_API)

	mu         sync.Mutex
	client     *tailscaleClient
	lastError  string
	lastMinted time.Time
	http       *http.Client
}

func loadTailscale(dir string) (*tailscale, error) {
	t := &tailscale{path: filepath.Join(dir, "tailscale.json"), api: "https://api.tailscale.com", http: &http.Client{Timeout: 15 * time.Second}}
	if api := os.Getenv("LANTERN_TAILSCALE_API"); api != "" {
		t.api = strings.TrimRight(api, "/")
	}
	data, err := os.ReadFile(t.path)
	if errors.Is(err, os.ErrNotExist) {
		return t, nil
	}
	if err != nil {
		return nil, err
	}
	var c tailscaleClient
	if err := json.Unmarshal(data, &c); err != nil {
		return nil, fmt.Errorf("tailscale.json: %w", err)
	}
	if c.ClientID != "" && c.ClientSecret != "" {
		t.client = &c
	}
	return t, nil
}

// set checks the client against Tailscale (it must get a token) and keeps it.
func (t *tailscale) set(ctx context.Context, c tailscaleClient) error {
	c.ClientID, c.ClientSecret = strings.TrimSpace(c.ClientID), strings.TrimSpace(c.ClientSecret)
	if c.ClientID == "" || c.ClientSecret == "" {
		return errors.New("Both the OAuth client's ID and its secret are needed.")
	}
	if _, err := t.token(ctx, c); err != nil {
		return err
	}
	data, _ := json.MarshalIndent(c, "", "  ")
	if err := writePrivate(t.path, data); err != nil {
		return err
	}
	t.mu.Lock()
	t.client, t.lastError = &c, ""
	t.mu.Unlock()
	return nil
}

func (t *tailscale) clear() error {
	t.mu.Lock()
	t.client, t.lastError = nil, ""
	t.mu.Unlock()
	if err := os.Remove(t.path); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return nil
}

// What the admin API says: never the secret.
type tailscaleStatus struct {
	Configured bool      `json:"configured"`
	ClientID   string    `json:"client_id,omitempty"`
	Tag        string    `json:"tag"`
	LastError  string    `json:"last_error,omitempty"`
	LastMinted time.Time `json:"last_minted,omitzero"`
	Host       string    `json:"host,omitempty"` // this Mac's MagicDNS name, when it's on a tailnet
	IPs        []string  `json:"ips,omitempty"`
}

func (t *tailscale) status() tailscaleStatus {
	self := tailnetSelf()
	t.mu.Lock()
	defer t.mu.Unlock()
	s := tailscaleStatus{Configured: t.client != nil, Tag: tailscaleTag, LastError: t.lastError, LastMinted: t.lastMinted, Host: self.host, IPs: self.ips}
	if t.client != nil {
		s.ClientID = t.client.ClientID
	}
	return s
}

// offer is the tailnet part of a pair response: a fresh key when a client is set up and this Mac
// is on a tailnet to join. A failure here never fails the pairing.
func (t *tailscale) offer(ctx context.Context, deviceName string, port int) tailnetOffer {
	t.mu.Lock()
	c := t.client
	t.mu.Unlock()
	if c == nil {
		return tailnetOffer{Status: "not_configured", Message: "Tailscale isn't set up on the Mac: this device reaches it on the home network only."}
	}
	self := tailnetSelf()
	if self.host == "" && len(self.ips) == 0 {
		return t.failed("The Mac isn't on its tailnet now: this device reaches it on the home network only.")
	}
	key, expires, err := t.mint(ctx, *c, deviceName)
	if err != nil {
		return t.failed("Tailscale didn't give this device a key (" + err.Error() + "): it reaches the Mac on the home network only.")
	}
	t.mu.Lock()
	t.lastMinted, t.lastError = time.Now(), ""
	t.mu.Unlock()
	o := tailnetOffer{Status: "ok", AuthKey: key, Expires: expires, Tags: []string{tailscaleTag}, Host: self.host, IPs: self.ips}
	if h := self.host; h != "" {
		o.Address = net.JoinHostPort(h, fmt.Sprint(port))
	} else {
		o.Address = net.JoinHostPort(self.ips[0], fmt.Sprint(port))
	}
	return o
}

func (t *tailscale) failed(message string) tailnetOffer {
	t.mu.Lock()
	t.lastError = message
	t.mu.Unlock()
	return tailnetOffer{Status: "failed", Message: message}
}

// token trades the OAuth client for an access token (client credentials).
func (t *tailscale) token(ctx context.Context, c tailscaleClient) (string, error) {
	form := url.Values{"client_id": {c.ClientID}, "client_secret": {c.ClientSecret}, "grant_type": {"client_credentials"}}
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, t.api+"/api/v2/oauth/token", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	var out struct {
		AccessToken string `json:"access_token"`
	}
	if err := t.do(req, &out); err != nil {
		return "", fmt.Errorf("Tailscale turned the OAuth client down: %w", err)
	}
	if out.AccessToken == "" {
		return "", errors.New("Tailscale gave no access token")
	}
	return out.AccessToken, nil
}

// mint makes a one-time, pre-authorized, non-ephemeral auth key tagged for Lantern.
func (t *tailscale) mint(ctx context.Context, c tailscaleClient, deviceName string) (string, time.Time, error) {
	token, err := t.token(ctx, c)
	if err != nil {
		return "", time.Time{}, err
	}
	var body struct {
		Capabilities struct {
			Devices struct {
				Create struct {
					Reusable      bool     `json:"reusable"`
					Ephemeral     bool     `json:"ephemeral"`
					Preauthorized bool     `json:"preauthorized"`
					Tags          []string `json:"tags"`
				} `json:"create"`
			} `json:"devices"`
		} `json:"capabilities"`
		ExpirySeconds int    `json:"expirySeconds"`
		Description   string `json:"description"`
	}
	create := &body.Capabilities.Devices.Create
	create.Preauthorized, create.Tags = true, []string{tailscaleTag}
	body.ExpirySeconds = int(tailscaleKeyExpiry.Seconds())
	body.Description = keyDescription(deviceName)
	data, _ := json.Marshal(body)
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, t.api+"/api/v2/tailnet/-/keys", strings.NewReader(string(data)))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+token)
	var out struct {
		Key     string    `json:"key"`
		Expires time.Time `json:"expires"`
	}
	if err := t.do(req, &out); err != nil {
		return "", time.Time{}, err
	}
	if out.Key == "" {
		return "", time.Time{}, errors.New("no key in Tailscale's answer")
	}
	if out.Expires.IsZero() {
		out.Expires = time.Now().Add(tailscaleKeyExpiry)
	}
	return out.Key, out.Expires, nil
}

// keyDescription names the key in Tailscale's admin console: letters, digits, spaces and dashes,
// at most 50 characters.
func keyDescription(device string) string {
	var sb strings.Builder
	for _, r := range "Lantern " + device {
		if r < 128 && (r == ' ' || r == '-' || r >= '0' && r <= '9' || r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z') {
			sb.WriteRune(r)
		}
	}
	s := strings.TrimSpace(sb.String())
	if len(s) > 50 {
		s = s[:50]
	}
	return s
}

func (t *tailscale) do(req *http.Request, into any) error {
	resp, err := t.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode/100 != 2 {
		var e struct {
			Message string `json:"message"`
			Error   string `json:"error"`
		}
		_ = json.Unmarshal(data, &e)
		msg := e.Message
		if msg == "" {
			msg = e.Error
		}
		if msg == "" {
			msg = http.StatusText(resp.StatusCode)
		}
		return fmt.Errorf("HTTP %d: %s", resp.StatusCode, msg)
	}
	return json.Unmarshal(data, into)
}

type tailnetIdentity struct {
	host string
	ips  []string
}

// tailnetSelf is this Mac on its tailnet (MagicDNS name and addresses), from the Tailscale app or
// CLI; empty without Tailscale. LANTERN_TAILNET_HOST stands in for it (checks on a Mac without it).
func tailnetSelf() tailnetIdentity {
	if h := os.Getenv("LANTERN_TAILNET_HOST"); h != "" {
		return tailnetIdentity{host: h}
	}
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
			BackendState string `json:"BackendState"`
			Self         struct {
				DNSName      string   `json:"DNSName"`
				TailscaleIPs []string `json:"TailscaleIPs"`
			} `json:"Self"`
		}
		if json.Unmarshal(out, &status) != nil || status.BackendState != "Running" {
			continue
		}
		var ips []string
		for _, ip := range status.Self.TailscaleIPs {
			if !strings.Contains(ip, ":") { // IPv4 first and only: what Lantern dials
				ips = append(ips, ip)
			}
		}
		return tailnetIdentity{host: strings.TrimSuffix(status.Self.DNSName, "."), ips: ips}
	}
	return tailnetIdentity{}
}
