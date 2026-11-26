package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// A backend speaking the OpenAI API: one chat model, and a completion streamed in pieces that
// says which model it was asked for.
func fakeBackend(t *testing.T) *httptest.Server {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/models":
			fmt.Fprint(w, `{"object":"list","data":[{"id":"tiny:1b","object":"model"}]}`)
		case "/v1/chat/completions":
			if r.Header.Get("Authorization") != "" {
				http.Error(w, "the device's token reached the backend", http.StatusBadRequest)
				return
			}
			var body struct{ Model string }
			_ = json.NewDecoder(r.Body).Decode(&body)
			w.Header().Set("Content-Type", "text/event-stream")
			for _, piece := range []string{"asked ", body.Model} {
				fmt.Fprintf(w, "data: {\"choices\":[{\"delta\":{\"content\":%q}}]}\n\n", piece)
				w.(http.Flusher).Flush()
			}
			fmt.Fprint(w, "data: [DONE]\n\n")
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(srv.Close)
	return srv
}

type harness struct {
	b      *bridge
	url    string
	client *http.Client // trusts only the bridge's certificate, as Lantern does
}

func newHarness(t *testing.T) *harness {
	dir := t.TempDir()
	fake := fakeBackend(t)
	cfg := settings{Name: "Test Mac", Backends: []backend{{ID: "fake", Name: "Fake", URL: fake.URL}}}
	data, _ := json.Marshal(cfg)
	if err := os.WriteFile(filepath.Join(dir, "settings.json"), data, 0o600); err != nil {
		t.Fatal(err)
	}
	b, err := openBridge(dir)
	if err != nil {
		t.Fatal(err)
	}
	b.backends.refresh(context.Background())
	s := &server{b: b, backends: b.backends, devices: b.devices}
	srv := httptest.NewUnstartedServer(s.handler())
	srv.TLS = &tls.Config{MinVersion: tls.VersionTLS13, Certificates: []tls.Certificate{b.identity.cert}}
	srv.StartTLS()
	t.Cleanup(srv.Close)
	pin := b.identity.fingerprint
	client := &http.Client{Transport: &http.Transport{TLSClientConfig: &tls.Config{
		InsecureSkipVerify: true, // replaced by the pin below
		VerifyPeerCertificate: func(raw [][]byte, _ [][]*x509.Certificate) error {
			sum := sha256.Sum256(raw[0])
			if hex.EncodeToString(sum[:]) != pin {
				return errors.New("not the paired certificate")
			}
			return nil
		},
	}}}
	return &harness{b: b, url: srv.URL, client: client}
}

func (h *harness) do(t *testing.T, method, path, token string, body any) (*http.Response, string) {
	t.Helper()
	var reader io.Reader
	if body != nil {
		data, _ := json.Marshal(body)
		reader = bytes.NewReader(data)
	}
	req, _ := http.NewRequest(method, h.url+path, reader)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := h.client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(resp.Body)
	return resp, string(data)
}

func (h *harness) pairDevice(t *testing.T, name string) string {
	t.Helper()
	link, _ := url.Parse(h.b.pairingLink(h.b.devices.newOffer()))
	if link.Query().Get("fp") != h.b.identity.fingerprint {
		t.Fatalf("the link's fingerprint isn't the certificate's: %s", link)
	}
	resp, body := h.do(t, "POST", "/lantern/v1/pair", "", map[string]string{"code": link.Query().Get("code"), "device": name})
	if resp.StatusCode != 200 {
		t.Fatalf("pairing: %d %s", resp.StatusCode, body)
	}
	var paired struct{ Token, Name string }
	_ = json.Unmarshal([]byte(body), &paired)
	if paired.Token == "" || paired.Name != "Test Mac" {
		t.Fatalf("pairing answered %s", body)
	}
	return paired.Token
}

func TestUnpairedIsTurnedAway(t *testing.T) {
	h := newHarness(t)
	for _, token := range []string{"", "made-up"} {
		if resp, _ := h.do(t, "GET", "/v1/models", token, nil); resp.StatusCode != 401 {
			t.Errorf("token %q: %d, want 401", token, resp.StatusCode)
		}
	}
	if resp, _ := h.do(t, "POST", "/lantern/v1/pair", "", map[string]string{"code": "guess", "device": "x"}); resp.StatusCode != 403 {
		t.Errorf("a guessed code: %d, want 403", resp.StatusCode)
	}
}

func TestPairingCodeIsOneTime(t *testing.T) {
	h := newHarness(t)
	o := h.b.devices.newOffer()
	first, _ := h.do(t, "POST", "/lantern/v1/pair", "", map[string]string{"code": o.code, "device": "A"})
	second, _ := h.do(t, "POST", "/lantern/v1/pair", "", map[string]string{"code": o.code, "device": "B"})
	if first.StatusCode != 200 || second.StatusCode != 403 {
		t.Fatalf("first %d, second %d: want 200 then 403", first.StatusCode, second.StatusCode)
	}
}

func TestModelsAndStreamedCompletion(t *testing.T) {
	h := newHarness(t)
	token := h.pairDevice(t, "iPhone")
	resp, body := h.do(t, "GET", "/v1/models", token, nil)
	if resp.StatusCode != 200 || !strings.Contains(body, `"id":"tiny:1b"`) || !strings.Contains(body, `"backend":"fake"`) {
		t.Fatalf("models: %d %s", resp.StatusCode, body)
	}
	req, _ := http.NewRequest("POST", h.url+"/v1/chat/completions", strings.NewReader(`{"model":"tiny:1b","stream":true,"messages":[]}`))
	req.Header.Set("Authorization", "Bearer "+token)
	stream, err := h.client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer stream.Body.Close()
	var text strings.Builder
	scanner := bufio.NewScanner(stream.Body)
	for scanner.Scan() {
		line, ok := strings.CutPrefix(scanner.Text(), "data: ")
		if !ok || line == "[DONE]" {
			continue
		}
		var chunk struct {
			Choices []struct{ Delta struct{ Content string } }
		}
		_ = json.Unmarshal([]byte(line), &chunk)
		text.WriteString(chunk.Choices[0].Delta.Content)
	}
	if stream.StatusCode != 200 || text.String() != "asked tiny:1b" {
		t.Fatalf("completion: %d %q", stream.StatusCode, text.String())
	}
	if resp, body := h.do(t, "POST", "/v1/chat/completions", token, map[string]string{"model": "nope"}); resp.StatusCode != 404 {
		t.Errorf("an unknown model: %d %s", resp.StatusCode, body)
	}
}

func TestRevokedDeviceIsTurnedAway(t *testing.T) {
	h := newHarness(t)
	phone, pad := h.pairDevice(t, "iPhone"), h.pairDevice(t, "iPad")
	devices := h.b.devices.list()
	if len(devices) != 2 || devices[0].TokenHash != "" {
		t.Fatalf("devices: %+v", devices)
	}
	if err := h.b.devices.revoke(devices[0].ID); err != nil {
		t.Fatal(err)
	}
	if resp, _ := h.do(t, "GET", "/v1/models", phone, nil); resp.StatusCode != 401 {
		t.Errorf("revoked: %d, want 401", resp.StatusCode)
	}
	if resp, _ := h.do(t, "GET", "/v1/models", pad, nil); resp.StatusCode != 200 {
		t.Errorf("the other device: %d, want 200", resp.StatusCode)
	}
	// Devices are kept across restarts, by their token's hash only.
	again, err := loadDevices(filepath.Join(h.b.dir, "devices.json"))
	if err != nil || len(again.devices) != 1 {
		t.Fatalf("reloaded: %v %+v", err, again.devices)
	}
	data, _ := os.ReadFile(filepath.Join(h.b.dir, "devices.json"))
	if strings.Contains(string(data), pad) {
		t.Error("a token is stored in the clear")
	}
}

func TestAnotherCertificateIsRefused(t *testing.T) {
	h := newHarness(t)
	other, err := loadIdentity(t.TempDir(), "Impostor")
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewUnstartedServer(http.NotFoundHandler())
	srv.TLS = &tls.Config{Certificates: []tls.Certificate{other.cert}}
	srv.StartTLS()
	defer srv.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	req, _ := http.NewRequestWithContext(ctx, "GET", srv.URL+"/v1/models", nil)
	if _, err := h.client.Do(req); err == nil {
		t.Fatal("a client pinned to the bridge connected to another certificate")
	}
}
