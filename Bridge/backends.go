package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"sort"
	"strings"
	"sync"
	"time"
)

// A local model server the bridge passes requests to. Every one speaks the OpenAI API
// (`/v1/models`, `/v1/chat/completions`); some say more about their models in their own API,
// which the bridge reads for what each model can do.
type backend struct {
	ID   string `json:"id"`   // "ollama", "lmstudio", "openai-8080"
	Name string `json:"name"` // "Ollama", "LM Studio"
	URL  string `json:"url"`  // "http://127.0.0.1:11434"
}

// The servers looked for on this Mac, at their default ports. Others can be added in settings.
var knownBackends = []backend{
	{ID: "ollama", Name: "Ollama", URL: "http://127.0.0.1:11434"},
	{ID: "lmstudio", Name: "LM Studio", URL: "http://127.0.0.1:1234"},
	{ID: "llamacpp", Name: "llama.cpp", URL: "http://127.0.0.1:8080"},
	{ID: "vllm", Name: "vLLM", URL: "http://127.0.0.1:8000"},
	{ID: "jan", Name: "Jan", URL: "http://127.0.0.1:1337"},
}

// A model as clients see it: the OpenAI fields, and Lantern's own about it.
type model struct {
	ID      string    `json:"id"`
	Object  string    `json:"object"`
	OwnedBy string    `json:"owned_by"`
	Lantern modelInfo `json:"lantern"`
}

type modelInfo struct {
	Backend     string `json:"backend"`      // the backend's ID
	BackendName string `json:"backend_name"` // "Ollama"
	Name        string `json:"name"`         // the backend's own name for it
	Vision      bool   `json:"vision"`
	Tools       bool   `json:"tools"`
	Thinking    bool   `json:"thinking"`
	Context     int    `json:"context_length,omitempty"` // the most it can take; the server may use less
	Size        int64  `json:"size,omitempty"`           // bytes on disk
}

type backends struct {
	mu      sync.RWMutex
	extra   []backend // from settings
	found   []backend // answering at the last look
	models  []model
	byID    map[string]model
	details map[string]modelInfo // backend/name → what it can do, kept between looks
	client  *http.Client
}

func newBackends(extra []backend) *backends {
	return &backends{extra: extra, byID: map[string]model{}, details: map[string]modelInfo{}, client: &http.Client{Timeout: 3 * time.Second}}
}

// watch looks for backends and their models now and every few seconds, so a server started
// later or a model pulled shows up on its own.
func (b *backends) watch(ctx context.Context, every time.Duration) {
	b.refresh(ctx)
	ticker := time.NewTicker(every)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			b.refresh(ctx)
		}
	}
}

func (b *backends) refresh(ctx context.Context) {
	candidates := append(append([]backend(nil), knownBackends...), b.extra...)
	type result struct {
		backend backend
		models  []model
	}
	results := make([]result, len(candidates))
	var wg sync.WaitGroup
	for i, c := range candidates {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if ms, ok := b.list(ctx, c); ok {
				results[i] = result{c, ms}
			}
		}()
	}
	wg.Wait()

	var found []backend
	var all []model
	byID := map[string]model{}
	for _, r := range results {
		if r.backend.ID == "" {
			continue
		}
		found = append(found, r.backend)
		for _, m := range r.models {
			// The same name on two backends: the second is "<backend>/<name>".
			if _, taken := byID[m.ID]; taken {
				m.ID = r.backend.ID + "/" + m.ID
			}
			byID[m.ID] = m
			all = append(all, m)
		}
	}
	sort.SliceStable(all, func(i, j int) bool { return all[i].ID < all[j].ID })
	b.mu.Lock()
	changed := len(found) != len(b.found)
	b.found, b.models, b.byID = found, all, byID
	b.mu.Unlock()
	if changed {
		names := make([]string, len(found))
		for i, f := range found {
			names[i] = f.Name
		}
		log.Printf("backends: %s (%d models)", strings.Join(names, ", "), len(all))
	}
}

// list asks a backend for its models, with what each can do where the backend says.
func (b *backends) list(ctx context.Context, be backend) ([]model, bool) {
	var listing struct {
		Data []struct {
			ID string `json:"id"`
		} `json:"data"`
	}
	if err := b.getJSON(ctx, be.URL+"/v1/models", &listing); err != nil {
		return nil, false
	}
	var out []model
	for _, d := range listing.Data {
		info, ok := b.describe(ctx, be, d.ID)
		if !ok {
			continue // not a chat model (an embedding model)
		}
		out = append(out, model{ID: d.ID, Object: "model", OwnedBy: be.Name, Lantern: info})
	}
	return out, true
}

func (b *backends) describe(ctx context.Context, be backend, name string) (modelInfo, bool) {
	key := be.ID + "/" + name
	b.mu.RLock()
	cached, known := b.details[key]
	b.mu.RUnlock()
	if known {
		return cached, cached.Name != ""
	}
	info := modelInfo{Backend: be.ID, BackendName: be.Name, Name: name}
	chat := true
	switch be.ID {
	case "ollama":
		chat = b.describeOllama(ctx, be, &info)
	case "lmstudio":
		chat = b.describeLMStudio(ctx, be, &info)
	default:
		info.Tools = true // most OpenAI-compatible servers take tools; a model that can't ignores them
	}
	if !chat {
		info.Name = "" // remembered as not a chat model
	}
	b.mu.Lock()
	b.details[key] = info
	b.mu.Unlock()
	return info, chat
}

// Ollama's `/api/show` lists capabilities ("completion", "vision", "tools", "thinking") and
// the model's context length; `/api/tags` its size.
func (b *backends) describeOllama(ctx context.Context, be backend, info *modelInfo) bool {
	var show struct {
		Capabilities []string                   `json:"capabilities"`
		ModelInfo    map[string]json.RawMessage `json:"model_info"`
	}
	if err := b.postJSON(ctx, be.URL+"/api/show", map[string]string{"model": info.Name}, &show); err != nil {
		return true
	}
	chat := len(show.Capabilities) == 0
	for _, c := range show.Capabilities {
		switch c {
		case "completion":
			chat = true
		case "vision":
			info.Vision = true
		case "tools":
			info.Tools = true
		case "thinking":
			info.Thinking = true
		}
	}
	for k, v := range show.ModelInfo {
		if strings.HasSuffix(k, ".context_length") {
			_ = json.Unmarshal(v, &info.Context)
		}
	}
	var tags struct {
		Models []struct {
			Name string `json:"name"`
			Size int64  `json:"size"`
		} `json:"models"`
	}
	if b.getJSON(ctx, be.URL+"/api/tags", &tags) == nil {
		for _, m := range tags.Models {
			if m.Name == info.Name {
				info.Size = m.Size
			}
		}
	}
	return chat
}

// LM Studio's `/api/v0/models` has each model's type ("llm", "vlm", "embeddings"),
// capabilities ("tool_use") and context length.
func (b *backends) describeLMStudio(ctx context.Context, be backend, info *modelInfo) bool {
	var listing struct {
		Data []struct {
			ID           string   `json:"id"`
			Type         string   `json:"type"`
			Capabilities []string `json:"capabilities"`
			MaxContext   int      `json:"max_context_length"`
		} `json:"data"`
	}
	if err := b.getJSON(ctx, be.URL+"/api/v0/models", &listing); err != nil {
		return true
	}
	for _, m := range listing.Data {
		if m.ID != info.Name {
			continue
		}
		if m.Type == "embeddings" {
			return false
		}
		info.Vision = m.Type == "vlm"
		info.Context = m.MaxContext
		for _, c := range m.Capabilities {
			if c == "tool_use" {
				info.Tools = true
			}
		}
	}
	return true
}

func (b *backends) snapshot() ([]backend, []model) {
	b.mu.RLock()
	defer b.mu.RUnlock()
	return append([]backend(nil), b.found...), append([]model(nil), b.models...)
}

// route finds the backend for a model a client named, and the backend's own name for it.
func (b *backends) route(id string) (backend, string, bool) {
	b.mu.RLock()
	m, ok := b.byID[id]
	found := b.found
	b.mu.RUnlock()
	if !ok {
		return backend{}, "", false
	}
	for _, be := range found {
		if be.ID == m.Lantern.Backend {
			return be, m.Lantern.Name, true
		}
	}
	return backend{}, "", false
}

// warm loads a model ahead of a question. Only Ollama has a way to do it without generating:
// an empty chat, with how long to keep the model (-1: for good). Others load on the first request.
func (b *backends) warm(ctx context.Context, id string, keepAlive any) error {
	be, name, ok := b.route(id)
	if !ok {
		return fmt.Errorf("no model %q", id)
	}
	if be.ID != "ollama" {
		return nil
	}
	body := map[string]any{"model": name, "messages": []any{}}
	if keepAlive != nil {
		body["keep_alive"] = keepAlive
	}
	client := &http.Client{Timeout: 5 * time.Minute} // a big model takes a while to load
	return postJSONWith(ctx, client, be.URL+"/api/chat", body, nil)
}

// loaded says whether Ollama has a model in memory now (`/api/ps`). Other backends, and an
// Ollama that doesn't answer, count as loaded: there is nothing to do about them.
func (b *backends) loaded(ctx context.Context, id string) bool {
	be, name, ok := b.route(id)
	if !ok || be.ID != "ollama" {
		return true
	}
	var ps struct {
		Models []struct {
			Name string `json:"name"`
		} `json:"models"`
	}
	if err := b.getJSON(ctx, be.URL+"/api/ps", &ps); err != nil {
		return true
	}
	for _, m := range ps.Models {
		if m.Name == name {
			return true
		}
	}
	return false
}

func (b *backends) getJSON(ctx context.Context, url string, into any) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	resp, err := b.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("%s: HTTP %d", url, resp.StatusCode)
	}
	return json.NewDecoder(resp.Body).Decode(into)
}

func (b *backends) postJSON(ctx context.Context, url string, body, into any) error {
	return postJSONWith(ctx, b.client, url, body, into)
}

func postJSONWith(ctx context.Context, client *http.Client, url string, body, into any) error {
	data, err := json.Marshal(body)
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(data))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("%s: HTTP %d", url, resp.StatusCode)
	}
	if into == nil {
		return nil
	}
	return json.NewDecoder(resp.Body).Decode(into)
}
