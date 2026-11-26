package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"time"
)

// The admin API, for the Mac app and the command line: HTTP over a Unix socket in the bridge's
// folder, which only this user can open. Nothing here is reachable from the network.
//
//	GET    /status                 name, port, fingerprint, addresses, splash (with the drafter),
//	                               models, devices, tailscale, pairing_code (expiry only)
//	POST   /pairing                a QR code's link → {link, expires}
//	POST   /pairing/code           a new code to type, replacing any → {code: "ABCD-EFGH", expires}
//	GET    /pairing/code           the code showing now → {code, expires}, or 404
//	DELETE /pairing/code           stop showing it
//	GET    /tailscale              {configured, client_id, tag, last_error, last_minted, host, ips}
//	PUT    /tailscale              {client_id, client_secret}: checked with Tailscale, then kept
//	DELETE /tailscale              forget the OAuth client
//	POST   /splash/restart         try starting Splash again now (after an update, or giving up)
//	DELETE /devices/{id}           unpair a device
//	POST   /devices/{id}/name      {name}
//	PUT    /name                   {name}
func socketPath(dir string) string { return filepath.Join(dir, "admin.sock") }

// shortSocketPath is the socket's path as given to the system: relative to the working folder when
// the full path is longer than a Unix socket's address can hold (104 bytes on macOS).
func shortSocketPath(dir string) string {
	full := socketPath(dir)
	if len(full) < 100 {
		return full
	}
	if wd, err := os.Getwd(); err == nil {
		if rel, err := filepath.Rel(wd, full); err == nil && len(rel) < 100 {
			return rel
		}
	}
	return full
}

func (b *bridge) serveAdmin(ctx context.Context, restartSplash chan<- struct{}) error {
	path := socketPath(b.dir)
	_ = os.Remove(path)
	listener, err := net.Listen("unix", shortSocketPath(b.dir))
	if err != nil {
		return err
	}
	_ = os.Chmod(path, 0o600)
	mux := http.NewServeMux()
	mux.HandleFunc("GET /status", func(w http.ResponseWriter, r *http.Request) { writeJSON(w, b.status(r.Context())) })
	mux.HandleFunc("POST /pairing", func(w http.ResponseWriter, r *http.Request) {
		o := b.devices.newOffer()
		writeJSON(w, map[string]any{"link": b.pairingLink(o), "expires": o.expires})
	})
	mux.HandleFunc("POST /pairing/code", func(w http.ResponseWriter, r *http.Request) {
		code, expires := b.devices.newCode(b.identity.fingerprint)
		writeJSON(w, map[string]any{"code": code, "expires": expires})
	})
	mux.HandleFunc("GET /pairing/code", func(w http.ResponseWriter, r *http.Request) {
		code, expires, ok := b.devices.currentCode()
		if !ok {
			apiError(w, http.StatusNotFound, "No code is showing.")
			return
		}
		writeJSON(w, map[string]any{"code": code, "expires": expires})
	})
	mux.HandleFunc("DELETE /pairing/code", func(w http.ResponseWriter, r *http.Request) {
		b.devices.clearCode()
		w.WriteHeader(http.StatusNoContent)
	})
	mux.HandleFunc("GET /tailscale", func(w http.ResponseWriter, r *http.Request) { writeJSON(w, b.tailscale.status()) })
	mux.HandleFunc("PUT /tailscale", func(w http.ResponseWriter, r *http.Request) {
		var c tailscaleClient
		if err := json.NewDecoder(io.LimitReader(r.Body, 4096)).Decode(&c); err != nil {
			apiError(w, http.StatusBadRequest, "Send {client_id, client_secret}.")
			return
		}
		ctx, cancel := context.WithTimeout(r.Context(), 20*time.Second)
		defer cancel()
		if err := b.tailscale.set(ctx, c); err != nil {
			apiError(w, http.StatusBadRequest, err.Error())
			return
		}
		writeJSON(w, b.tailscale.status())
	})
	mux.HandleFunc("DELETE /tailscale", func(w http.ResponseWriter, r *http.Request) {
		if err := b.tailscale.clear(); err != nil {
			apiError(w, http.StatusInternalServerError, err.Error())
			return
		}
		w.WriteHeader(http.StatusNoContent)
	})
	mux.HandleFunc("POST /splash/restart", func(w http.ResponseWriter, r *http.Request) {
		select {
		case restartSplash <- struct{}{}:
		default:
		}
		w.WriteHeader(http.StatusAccepted)
	})
	mux.HandleFunc("DELETE /devices/{id}", func(w http.ResponseWriter, r *http.Request) {
		if err := b.devices.revoke(r.PathValue("id")); err != nil {
			apiError(w, http.StatusNotFound, err.Error())
			return
		}
		w.WriteHeader(http.StatusNoContent)
	})
	mux.HandleFunc("POST /devices/{id}/name", func(w http.ResponseWriter, r *http.Request) {
		var body struct{ Name string }
		_ = json.NewDecoder(io.LimitReader(r.Body, 4096)).Decode(&body)
		if err := b.devices.rename(r.PathValue("id"), body.Name); err != nil {
			apiError(w, http.StatusNotFound, err.Error())
			return
		}
		w.WriteHeader(http.StatusNoContent)
	})
	mux.HandleFunc("PUT /name", func(w http.ResponseWriter, r *http.Request) {
		var body struct{ Name string }
		_ = json.NewDecoder(io.LimitReader(r.Body, 4096)).Decode(&body)
		if err := b.update(func(s *settings) { s.Name = body.Name }); err != nil {
			apiError(w, http.StatusInternalServerError, err.Error())
			return
		}
		w.WriteHeader(http.StatusNoContent)
	})
	srv := &http.Server{Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	go func() {
		<-ctx.Done()
		_ = srv.Close()
		_ = os.Remove(path)
	}()
	if err := srv.Serve(listener); !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	return nil
}

type status struct {
	Name        string          `json:"name"`
	Version     string          `json:"version"`
	Port        int             `json:"port"`
	Fingerprint string          `json:"fingerprint"`
	Addresses   []string        `json:"addresses"`
	Splash      splashStatus    `json:"splash"`
	Models      []model         `json:"models"`
	Devices     []device        `json:"devices"`
	Tailscale   tailscaleStatus `json:"tailscale"`
	// When the code to type stops working, while one shows (the code itself: GET /pairing/code).
	PairingCodeExpires *time.Time `json:"pairing_code_expires,omitempty"`
}

func (b *bridge) status(ctx context.Context) status {
	s := status{
		Name: b.name(), Version: version, Port: b.port(), Fingerprint: b.identity.fingerprint,
		Addresses: nonNil(b.addresses()), Splash: b.splash.snapshot(), Models: []model{},
		Devices: nonNil(b.devices.list()), Tailscale: b.tailscale.status(),
	}
	if s.Splash.State == splashReady {
		ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
		defer cancel()
		if models, err := (&server{b: b}).upstreamModels(ctx); err == nil {
			s.Models = models
		}
	}
	if _, expires, ok := b.devices.currentCode(); ok {
		s.PairingCodeExpires = &expires
	}
	return s
}

func nonNil[T any](s []T) []T {
	if s == nil {
		return []T{}
	}
	return s
}

// adminClient talks to a running bridge's admin socket.
func adminClient(dir string) *http.Client {
	return &http.Client{
		Timeout: 30 * time.Second,
		Transport: &http.Transport{DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, "unix", shortSocketPath(dir))
		}},
	}
}
