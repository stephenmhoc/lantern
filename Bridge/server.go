package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net"
	"net/http"
	"strings"
	"time"
)

// The bridge's HTTPS API, for paired devices (README has the details):
//
//	POST /lantern/v1/pair         {code, device}: the QR code's one-time code → token   (no token needed)
//	POST /lantern/v1/pair-code    {nonce, proof, device}: a typed code, proved → token    (no token needed)
//	GET  /lantern/v1/info         the bridge's name and version, and Splash's state
//	GET  /v1/models               Splash's model, with `lantern` details
//	POST /v1/chat/completions     passed to Splash, streamed back as it comes
//
// Everything but pairing needs `Authorization: Bearer <token>`.
type server struct {
	b *bridge
}

func (s *server) handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /lantern/v1/pair", s.pair)
	mux.HandleFunc("POST /lantern/v1/pair-code", s.pairCode)
	mux.Handle("GET /lantern/v1/info", s.authed(s.info))
	mux.Handle("GET /v1/models", s.authed(s.models))
	mux.Handle("POST /v1/chat/completions", s.authed(s.complete))
	return mux
}

func (s *server) serve(ctx context.Context, ln net.Listener) error {
	srv := &http.Server{
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
	err := srv.ServeTLS(ln, "", "")
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
		_, found := s.b.devices.authenticate(strings.TrimSpace(token))
		if !ok || !found {
			apiError(w, http.StatusUnauthorized, "This device isn't paired with "+s.b.name()+". Pair it from Lantern on the Mac.")
			return
		}
		next(w, r)
	})
}

// A pairing's answer, by QR code or typed code.
type paired struct {
	DeviceID  string       `json:"device_id"`
	Token     string       `json:"token"`
	Name      string       `json:"name"`
	Proof     string       `json:"proof,omitempty"` // typed code only
	Addresses []string     `json:"addresses"`
	Tailnet   tailnetOffer `json:"tailnet"`
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
	d, token, err := s.b.devices.pair(body.Code, body.Device)
	if errors.Is(err, errBadCode) {
		time.Sleep(500 * time.Millisecond) // nothing to gain from guessing quickly
		apiError(w, http.StatusForbidden, err.Error())
		return
	}
	if err != nil {
		apiError(w, http.StatusInternalServerError, err.Error())
		return
	}
	s.finishPairing(w, r, d, paired{DeviceID: d.ID, Token: token})
}

func (s *server) pairCode(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Nonce  string `json:"nonce"`
		Proof  string `json:"proof"`
		Device string `json:"device"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 4096)).Decode(&body); err != nil {
		apiError(w, http.StatusBadRequest, "The pairing request couldn't be read.")
		return
	}
	d, token, proof, err := s.b.devices.pairWithCode(body.Nonce, body.Proof, body.Device)
	switch {
	case errors.Is(err, errCodeMismatch), errors.Is(err, errNoCode):
		time.Sleep(500 * time.Millisecond)
		apiError(w, http.StatusForbidden, err.Error())
		return
	case errors.Is(err, errCodeTooMany):
		time.Sleep(500 * time.Millisecond)
		apiError(w, http.StatusTooManyRequests, err.Error())
		return
	case err != nil:
		apiError(w, http.StatusInternalServerError, err.Error())
		return
	}
	s.finishPairing(w, r, d, paired{DeviceID: d.ID, Token: token, Proof: proof})
}

// finishPairing adds what every pairing answer carries: the Mac's name and addresses, and a key
// to join its tailnet when it has one to give.
func (s *server) finishPairing(w http.ResponseWriter, r *http.Request, d device, p paired) {
	log.Printf("paired %q (%s)", d.Name, d.ID)
	ctx, cancel := context.WithTimeout(r.Context(), 20*time.Second)
	defer cancel()
	p.Name = s.b.name()
	p.Addresses = s.b.addresses()
	p.Tailnet = s.b.tailscale.offer(ctx, d.Name, s.b.port())
	if p.Tailnet.Status != "ok" {
		log.Printf("tailnet for %q: %s", d.Name, p.Tailnet.Message)
	}
	writeJSON(w, p)
}

func (s *server) info(w http.ResponseWriter, r *http.Request) {
	st := s.b.splash.snapshot()
	writeJSON(w, map[string]any{
		"name": s.b.name(), "version": version,
		// Lantern before 2.0 reads the servers behind the bridge here.
		"backends": []map[string]string{{"id": "splash", "name": "Splash"}},
		"splash":   map[string]any{"state": st.State, "message": st.Message, "version": st.Version},
	})
}

// A model as devices see it: the OpenAI fields, and Lantern's own about it.
type model struct {
	ID      string    `json:"id"`
	Object  string    `json:"object"`
	OwnedBy string    `json:"owned_by"`
	Lantern modelInfo `json:"lantern"`
}

type modelInfo struct {
	Backend       string   `json:"backend"`      // "splash"
	BackendName   string   `json:"backend_name"` // "Splash"
	Name          string   `json:"name"`
	Vision        bool     `json:"vision"`
	Tools         bool     `json:"tools"`
	Thinking      bool     `json:"thinking"`
	Context       int      `json:"context_length,omitempty"`
	Efforts       []string `json:"reasoning_efforts,omitempty"` // minimal … xhigh; "none" is taken too
	DefaultEffort string   `json:"default_reasoning_effort,omitempty"`
}

// upstreamModels asks Splash for its models, as devices see them.
func (s *server) upstreamModels(ctx context.Context) ([]model, error) {
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, s.b.splash.url+"/v1/models", nil)
	resp, err := s.b.splash.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	var listing struct {
		Data []struct {
			ID        string `json:"id"`
			Context   int    `json:"context_length"`
			Vision    bool   `json:"vision"`
			Reasoning *struct {
				Thinks  bool     `json:"thinks"`
				Efforts []string `json:"efforts"`
				Default string   `json:"default"`
			} `json:"reasoning"`
		} `json:"data"`
	}
	if resp.StatusCode != http.StatusOK {
		return nil, errors.New(resp.Status)
	}
	if err := json.NewDecoder(resp.Body).Decode(&listing); err != nil {
		return nil, err
	}
	out := []model{}
	for _, m := range listing.Data {
		info := modelInfo{Backend: "splash", BackendName: "Splash", Name: m.ID, Vision: m.Vision, Tools: true, Context: m.Context}
		if r := m.Reasoning; r != nil {
			info.Thinking, info.Efforts, info.DefaultEffort = r.Thinks, r.Efforts, r.Default
		}
		out = append(out, model{ID: m.ID, Object: "model", OwnedBy: "splash", Lantern: info})
	}
	return out, nil
}

func (s *server) models(w http.ResponseWriter, r *http.Request) {
	if ok, why := s.b.splash.ready(); !ok {
		apiError(w, http.StatusServiceUnavailable, why)
		return
	}
	models, err := s.upstreamModels(r.Context())
	if err != nil {
		apiError(w, http.StatusBadGateway, "Splash on "+s.b.name()+" didn't answer.")
		return
	}
	writeJSON(w, map[string]any{"object": "list", "data": models})
}

// complete passes a chat completion to Splash and streams the answer back as it comes, keeping
// the drafter's numbers from the last chunk. A client that goes away cancels the request, which
// stops Splash generating.
func (s *server) complete(w http.ResponseWriter, r *http.Request) {
	if ok, why := s.b.splash.ready(); !ok {
		apiError(w, http.StatusServiceUnavailable, why)
		return
	}
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
	// "none" is what Lantern asks for with thinking off. Splash takes it, but Inkling thinks
	// anyway, and longer than at its least effort: minimal.
	var effort string
	if json.Unmarshal(request["reasoning_effort"], &effort) == nil && effort == "none" {
		request["reasoning_effort"], _ = json.Marshal("minimal")
		data, _ = json.Marshal(request)
	}

	req, _ := http.NewRequestWithContext(r.Context(), http.MethodPost, s.b.splash.url+"/v1/chat/completions", bytes.NewReader(data))
	req.Header.Set("Content-Type", "application/json")
	if a := r.Header.Get("Accept"); a != "" {
		req.Header.Set("Accept", a)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		if r.Context().Err() == nil {
			apiError(w, http.StatusBadGateway, "Splash on "+s.b.name()+" didn't answer.")
		}
		return
	}
	defer resp.Body.Close()
	for _, h := range []string{"Content-Type", "Cache-Control"} {
		if v := resp.Header.Get(h); v != "" {
			w.Header().Set(h, v)
		}
	}
	w.WriteHeader(resp.StatusCode)
	flusher, _ := w.(http.Flusher)

	// Line by line, flushed at each event's end: an event is a `data:` line and a blank one.
	reader := bufio.NewReaderSize(resp.Body, 64<<10)
	for {
		line, err := reader.ReadBytes('\n')
		if len(line) > 0 {
			if _, werr := w.Write(line); werr != nil {
				return
			}
			if payload, ok := bytes.CutPrefix(line, []byte("data: ")); ok && hasDrafterNumbers(payload) {
				s.b.splash.noteTimings(payload)
			} else if !ok && resp.StatusCode == http.StatusOK && hasDrafterNumbers(line) {
				s.b.splash.noteTimings(line) // a reply that wasn't streamed
			}
			if flusher != nil && (len(bytes.TrimSpace(line)) == 0 || !bytes.HasPrefix(line, []byte("data: "))) {
				flusher.Flush()
			}
		}
		if err != nil {
			if flusher != nil {
				flusher.Flush()
			}
			return
		}
	}
}

// hasDrafterNumbers spots the chunks worth decoding: `timings` (draft_n…) and `metrics.speculation`.
func hasDrafterNumbers(chunk []byte) bool {
	return bytes.Contains(chunk, []byte(`"draft_n"`)) || bytes.Contains(chunk, []byte(`"speculation"`))
}
