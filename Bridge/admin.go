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
	"slices"
	"time"
)

// The admin API, for the Mac app and the command line: HTTP over a Unix socket in the bridge's
// folder, which only this user can open. Nothing here is reachable from the network.
//
//	GET    /status                 name, port, fingerprint, addresses, backends, models, devices
//	POST   /pairing                a new one-time code → {link, expires}
//	DELETE /devices/{id}           unpair a device
//	POST   /devices/{id}/name      {name}
//	PUT    /keep-loaded            {model, keep}
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

func (b *bridge) serveAdmin(ctx context.Context) error {
	path := socketPath(b.dir)
	_ = os.Remove(path)
	listener, err := net.Listen("unix", shortSocketPath(b.dir))
	if err != nil {
		return err
	}
	_ = os.Chmod(path, 0o600)
	mux := http.NewServeMux()
	mux.HandleFunc("GET /status", func(w http.ResponseWriter, r *http.Request) { writeJSON(w, b.status()) })
	mux.HandleFunc("POST /pairing", func(w http.ResponseWriter, r *http.Request) {
		o := b.devices.newOffer()
		writeJSON(w, map[string]any{"link": b.pairingLink(o), "expires": o.expires})
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
	mux.HandleFunc("PUT /keep-loaded", func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Model string
			Keep  bool
		}
		_ = json.NewDecoder(io.LimitReader(r.Body, 4096)).Decode(&body)
		err := b.update(func(s *settings) {
			s.KeepLoaded = slices.DeleteFunc(s.KeepLoaded, func(m string) bool { return m == body.Model })
			if body.Keep {
				s.KeepLoaded = append(s.KeepLoaded, body.Model)
			}
		})
		if err != nil {
			apiError(w, http.StatusInternalServerError, err.Error())
			return
		}
		// Load it now (or let Ollama's default apply from now on).
		go func() {
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
			defer cancel()
			keep := any(nil)
			if body.Keep {
				keep = -1
			}
			_ = b.backends.warm(ctx, body.Model, keep)
		}()
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
	Name        string    `json:"name"`
	Version     string    `json:"version"`
	Port        int       `json:"port"`
	Fingerprint string    `json:"fingerprint"`
	Addresses   []string  `json:"addresses"`
	Backends    []backend `json:"backends"`
	Models      []model   `json:"models"`
	Devices     []device  `json:"devices"`
	KeepLoaded  []string  `json:"keepLoaded"`
}

func (b *bridge) status() status {
	found, models := b.backends.snapshot()
	return status{
		Name: b.name(), Version: version, Port: b.port(), Fingerprint: b.identity.fingerprint,
		Addresses: b.addresses(), Backends: nonNil(found), Models: nonNil(models), Devices: nonNil(b.devices.list()),
		KeepLoaded: nonNil(b.settings().KeepLoaded),
	}
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
		Timeout: 10 * time.Second,
		Transport: &http.Transport{DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, "unix", shortSocketPath(dir))
		}},
	}
}
