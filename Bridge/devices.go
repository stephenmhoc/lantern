package main

import (
	"crypto/hmac"
	"crypto/pbkdf2"
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

// A pairing offer: a one-time code, carried by the QR code, that a device trades for its token.
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
	typed   *typedCode
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

// newOffer makes a QR code's one-time code, good for one device for the next few minutes.
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

// pair trades a QR code's one-time code for a new device and its token. The code is used up.
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
	return s.addLocked(name)
}

func (s *deviceStore) addLocked(name string) (device, string, error) {
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

// A code to type instead of scanning: 8 characters from an alphabet without look-alikes (no 0/O,
// 1/I/L, U), shown as ABCD-EFGH. One at a time; a new one replaces it. Good for one device, ten
// minutes and a few wrong tries; then it's gone and the Mac shows a new one.
//
// The code never crosses the network. Both sides derive a key from it and the bridge's
// certificate fingerprint and prove they hold it (README: "Pairing with a typed code"), so a
// device that found an impostor by Bonjour learns it's the wrong Mac, and the impostor learns
// nothing it could crack in ten minutes.
type typedCode struct {
	code     string // normalized: 8 characters, no dash
	key      []byte
	expires  time.Time
	failures int
}

const (
	codeAlphabet   = "ABCDEFGHJKMNPQRSTVWXYZ23456789"
	codeLength     = 8
	codeTries      = 5
	codeIterations = 100_000
)

var (
	errNoCode       = errors.New("There's no pairing code showing on the Mac now: show one and type it again.")
	errCodeTooMany  = errors.New("Too many wrong codes: show a new one on the Mac.")
	errCodeMismatch = errors.New("That code doesn't match the one on the Mac.")
)

// normalizeCode is what's hashed: upper case, letters and digits only ("abcd-efgh" → "ABCDEFGH").
func normalizeCode(code string) string {
	var sb strings.Builder
	for _, r := range strings.ToUpper(code) {
		if r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' {
			sb.WriteRune(r)
		}
	}
	return sb.String()
}

// codeKey is PBKDF2-HMAC-SHA256(code, "lantern-pair-code-v1:" + fingerprint, 100 000, 32 bytes):
// slow on purpose, so each guess costs what the device's one honest try does.
func codeKey(code, fingerprint string) []byte {
	key, err := pbkdf2.Key(sha256.New, normalizeCode(code), []byte("lantern-pair-code-v1:"+strings.ToLower(fingerprint)), codeIterations, 32)
	if err != nil {
		panic(err)
	}
	return key
}

func codeMAC(key []byte, message string) string {
	m := hmac.New(sha256.New, key)
	m.Write([]byte(message))
	return hex.EncodeToString(m.Sum(nil))
}

// newCode makes the code to type, replacing any before it.
func (s *deviceStore) newCode(fingerprint string) (string, time.Time) {
	var sb strings.Builder
	for sb.Len() < codeLength {
		b := make([]byte, 1)
		if _, err := rand.Read(b); err != nil {
			panic(err)
		}
		if int(b[0]) < 256-256%len(codeAlphabet) { // no lean toward the first characters
			sb.WriteByte(codeAlphabet[int(b[0])%len(codeAlphabet)])
		}
	}
	code := sb.String()
	t := &typedCode{code: code, key: codeKey(code, fingerprint), expires: time.Now().Add(offerLifetime)}
	s.mu.Lock()
	s.typed = t
	s.mu.Unlock()
	return showCode(code), t.expires
}

// showCode groups a code for reading: ABCD-EFGH.
func showCode(code string) string { return code[:4] + "-" + code[4:] }

// currentCode is the code showing now, if any.
func (s *deviceStore) currentCode() (string, time.Time, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.typed == nil || time.Now().After(s.typed.expires) {
		return "", time.Time{}, false
	}
	return showCode(s.typed.code), s.typed.expires, true
}

func (s *deviceStore) clearCode() {
	s.mu.Lock()
	s.typed = nil
	s.mu.Unlock()
}

// pairWithCode checks a device's proof of the typed code, HMAC-SHA256(key, "lantern device " +
// nonce), and if it holds adds the device and returns the bridge's own proof, which binds the
// token to this exchange: HMAC-SHA256(key, "lantern bridge " + nonce + " " + token).
func (s *deviceStore) pairWithCode(nonce, proof, name string) (device, string, string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	t := s.typed
	if t == nil || time.Now().After(t.expires) {
		s.typed = nil
		return device{}, "", "", errNoCode
	}
	if len(nonce) < 32 || len(nonce) > 128 || !hmac.Equal([]byte(codeMAC(t.key, "lantern device "+nonce)), []byte(strings.ToLower(proof))) {
		t.failures++
		if t.failures >= codeTries {
			s.typed = nil
			return device{}, "", "", errCodeTooMany
		}
		return device{}, "", "", errCodeMismatch
	}
	s.typed = nil
	d, token, err := s.addLocked(name)
	if err != nil {
		return device{}, "", "", err
	}
	return d, token, codeMAC(t.key, "lantern bridge "+nonce+" "+token), nil
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
