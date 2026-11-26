package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"slices"
	"strings"
	"time"
)

// The bridge's HTTPS API, for paired devices:
//
//	POST /lantern/v1/pair         {code, device} → {device_id, token, name}   (no token needed)
//	GET  /lantern/v1/info         the bridge's name, version and backends
//	GET  /v1/models               every backend's chat models, with `lantern` details
//	POST /v1/chat/completions     passed to the model's backend, streamed back as it comes
//	POST /lantern/v1/warm         {model}: load it ahead of a question
//
// Everything but pairing needs `Authorization: Bearer <token>`.
type server struct {
	b        *bridge
	backends *backends
	devices  *deviceStore
}

type ctxKey int

const deviceKey ctxKey = 0

func (s *server) handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /lantern/v1/pair", s.pair)
	mux.Handle("GET /lantern/v1/info", s.authed(s.info))
	mux.Handle("GET /v1/models", s.authed(s.models))
	mux.Handle("POST /v1/chat/completions", s.authed(s.complete))
	mux.Handle("POST /lantern/v1/warm", s.authed(s.warm))
	return mux
}

func (s *server) listen(ctx context.Context, addr string) error {
	srv := &http.Server{
		Addr:    addr,
		Handler: s.handler(),
		TLSConfig: &tls.Config{
			MinVersion:   tls.VersionTLS13,
			Certificates: []tls.Certificate{s.b.identity.cert},
		},
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       2 * time.Minute,
		ErrorLog:          log.New(io.Discard, "", 0), // TLS handshakes from scanners aren't news
	}
	go func() {
		<-ctx.Done()
		shutdown, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		_ = srv.Shutdown(shutdown)
	}()
	err := srv.ListenAndServeTLS("", "")
	if errors.Is(err, http.ErrServerClosed) {
		return nil
	}
	return err
}

// An error as the OpenAI API words them, so any client reads it.
func apiError(w http.ResponseWriter, status int, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]any{"error": map[string]string{"message": message}})
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(v)
}

func (s *server) authed(next http.HandlerFunc) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		token, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
		d, found := s.devices.authenticate(strings.TrimSpace(token))
		if !ok || !found {
			apiError(w, http.StatusUnauthorized, "This device isn't paired with "+s.b.name()+". Pair it from Lantern on the Mac.")
			return
		}
		next(w, r.WithContext(context.WithValue(r.Context(), deviceKey, d)))
	})
}

func (s *server) pair(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Code   string `json:"code"`
		Device string `json:"device"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 4096)).Decode(&body); err != nil {
		apiError(w, http.StatusBadRequest, "The pairing request couldn't be read.")
		return
	}
	d, token, err := s.devices.pair(body.Code, body.Device)
	if errors.Is(err, errBadCode) {
		time.Sleep(500 * time.Millisecond) // nothing to gain from guessing quickly
		apiError(w, http.StatusForbidden, err.Error())
		return
	}
	if err != nil {
		apiError(w, http.StatusInternalServerError, err.Error())
		return
	}
	log.Printf("paired %q (%s)", d.Name, d.ID)
	s.b.changed()
	writeJSON(w, map[string]string{"device_id": d.ID, "token": token, "name": s.b.name()})
}

func (s *server) info(w http.ResponseWriter, r *http.Request) {
	found, _ := s.backends.snapshot()
	writeJSON(w, map[string]any{"name": s.b.name(), "version": version, "backends": found})
}

func (s *server) models(w http.ResponseWriter, r *http.Request) {
	_, models := s.backends.snapshot()
	if models == nil {
		models = []model{}
	}
	writeJSON(w, map[string]any{"object": "list", "data": models})
}

func (s *server) warm(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Model string `json:"model"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 4096)).Decode(&body); err != nil || body.Model == "" {
		apiError(w, http.StatusBadRequest, "Say which model to load.")
		return
	}
	// The caller doesn't wait for a big model to load.
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
		defer cancel()
		if err := s.backends.warm(ctx, body.Model, s.b.keepAlive(body.Model)); err != nil {
			log.Printf("warming %s: %v", body.Model, err)
		}
	}()
	w.WriteHeader(http.StatusAccepted)
}

// complete passes a chat completion to its model's backend under the backend's own name for the
// model, and streams the answer back as it comes. A client that goes away cancels the request,
// which stops the backend generating.
func (s *server) complete(w http.ResponseWriter, r *http.Request) {
	data, err := io.ReadAll(io.LimitReader(r.Body, 128<<20)) // images make big requests
	if err != nil {
		apiError(w, http.StatusBadRequest, "The request couldn't be read.")
		return
	}
	var request map[string]json.RawMessage
	if err := json.Unmarshal(data, &request); err != nil {
		apiError(w, http.StatusBadRequest, "The request isn't JSON.")
		return
	}
	var id string
	_ = json.Unmarshal(request["model"], &id)
	be, name, ok := s.backends.route(id)
	if !ok {
		apiError(w, http.StatusNotFound, "There's no model "+id+" on "+s.b.name()+" now.")
		return
	}
	request["model"], _ = json.Marshal(name)
	data, _ = json.Marshal(request)

	target, _ := url.Parse(be.URL)
	proxy := &httputil.ReverseProxy{
		Rewrite: func(p *httputil.ProxyRequest) {
			p.SetURL(target)
			p.Out.Header.Del("Authorization") // the device's token stays with the bridge
			p.Out.Body = io.NopCloser(bytes.NewReader(data))
			p.Out.ContentLength = int64(len(data))
		},
		FlushInterval: -1, // each token as it comes
		ErrorHandler: func(w http.ResponseWriter, r *http.Request, err error) {
			if r.Context().Err() == nil {
				apiError(w, http.StatusBadGateway, be.Name+" on "+s.b.name()+" didn't answer.")
			}
		},
	}
	proxy.ServeHTTP(w, r)

	// A request through Ollama's OpenAI API sets how long the model stays loaded back to the
	// server's default: a model kept loaded for good is told so again.
	if be.ID == "ollama" && s.b.keepAlive(id) != nil {
		go func() {
			ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
			defer cancel()
			_ = s.backends.warm(ctx, id, -1)
		}()
	}
}

// keepAlive is how long Ollama keeps a model after a request: -1 (for good) for the models the
// settings keep loaded, else the server's own default (nil).
func (b *bridge) keepAlive(id string) any {
	if slices.Contains(b.settings().KeepLoaded, id) {
		return -1
	}
	return nil
}
