package main

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"sort"
	"strings"
	"sync"
	"time"
)

// A device paired with this bridge. Each has its own token, so one can be removed without the
// others pairing again. Only the token's hash is kept.
type device struct {
	ID        string    `json:"id"`
	Name      string    `json:"name"`
	TokenHash string    `json:"tokenHash"`
	Paired    time.Time `json:"paired"`
	LastSeen  time.Time `json:"lastSeen,omitempty"`
}

// A pairing offer: a one-time code, shown in the QR code, that a device trades for its token.
// It's good for one device and a few minutes.
type offer struct {
	code    string
	expires time.Time
}

const offerLifetime = 10 * time.Minute

var (
	errBadCode   = errors.New("that pairing code isn't valid: show a new one on the Mac")
	errNoDevices = errors.New("no such device")
)

type deviceStore struct {
	path    string
	mu      sync.Mutex
	devices []device
	offers  []offer
	// Last-seen times are saved at most once a minute, not on every request.
	lastSave time.Time
}

func loadDevices(path string) (*deviceStore, error) {
	s := &deviceStore{path: path}
	data, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return s, nil
	}
	if err != nil {
		return nil, err
	}
	if err := json.Unmarshal(data, &s.devices); err != nil {
		return nil, err
	}
	return s, nil
}

func (s *deviceStore) saveLocked() error {
	data, err := json.MarshalIndent(s.devices, "", "  ")
	if err != nil {
		return err
	}
	s.lastSave = time.Now()
	return writePrivate(s.path, data)
}

func randomString(bytes int) string {
	b := make([]byte, bytes)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return base64.RawURLEncoding.EncodeToString(b)
}

func hashToken(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}

// newOffer makes a pairing code good for one device for the next few minutes.
func (s *deviceStore) newOffer() offer {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.dropExpiredLocked()
	o := offer{code: randomString(18), expires: time.Now().Add(offerLifetime)}
	s.offers = append(s.offers, o)
	return o
}

func (s *deviceStore) dropExpiredLocked() {
	now := time.Now()
	kept := s.offers[:0]
	for _, o := range s.offers {
		if now.Before(o.expires) {
			kept = append(kept, o)
		}
	}
	s.offers = kept
}

// pair trades a pairing code for a new device and its token. The code is used up.
func (s *deviceStore) pair(code, name string) (device, string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.dropExpiredLocked()
	found := -1
	for i, o := range s.offers {
		if subtle.ConstantTimeCompare([]byte(o.code), []byte(code)) == 1 {
			found = i
		}
	}
	if found < 0 {
		return device{}, "", errBadCode
	}
	s.offers = append(s.offers[:found], s.offers[found+1:]...)
	name = strings.TrimSpace(name)
	if name == "" {
		name = "Device"
	}
	if len(name) > 80 {
		name = name[:80]
	}
	token := randomString(32)
	d := device{ID: randomString(9), Name: name, TokenHash: hashToken(token), Paired: time.Now()}
	s.devices = append(s.devices, d)
	if err := s.saveLocked(); err != nil {
		return device{}, "", err
	}
	return d, token, nil
}

// authenticate returns the device a token belongs to. Tokens are compared by their hash, so the
// lookup takes the same time whatever the token's first characters.
func (s *deviceStore) authenticate(token string) (device, bool) {
	if token == "" {
		return device{}, false
	}
	hash := hashToken(token)
	s.mu.Lock()
	defer s.mu.Unlock()
	for i := range s.devices {
		if subtle.ConstantTimeCompare([]byte(s.devices[i].TokenHash), []byte(hash)) == 1 {
			s.devices[i].LastSeen = time.Now()
			if time.Since(s.lastSave) > time.Minute {
				_ = s.saveLocked()
			}
			return s.devices[i], true
		}
	}
	return device{}, false
}

func (s *deviceStore) list() []device {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := append([]device(nil), s.devices...)
	sort.Slice(out, func(i, j int) bool { return out[i].Paired.Before(out[j].Paired) })
	for i := range out {
		out[i].TokenHash = ""
	}
	return out
}

func (s *deviceStore) revoke(id string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	for i, d := range s.devices {
		if d.ID == id {
			s.devices = append(s.devices[:i], s.devices[i+1:]...)
			return s.saveLocked()
		}
	}
	return errNoDevices
}

func (s *deviceStore) rename(id, name string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	for i, d := range s.devices {
		if d.ID == id {
			s.devices[i].Name = strings.TrimSpace(name)
			return s.saveLocked()
		}
	}
	return errNoDevices
}
