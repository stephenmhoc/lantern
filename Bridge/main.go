// lantern-bridge connects Lantern on an iPhone or iPad to the models on this Mac (Ollama,
// LM Studio, llama.cpp, vLLM, Jan…), on the home network or over Tailscale, encrypted from the
// device to the Mac: TLS with the bridge's own certificate, which devices pin when they pair,
// and a token of each device's own. The backends themselves then only need to listen on this Mac.
//
//	lantern-bridge serve          run it (the Mac app or a login agent keeps it running)
//	lantern-bridge pair [--link]  show a QR code for pairing a device (or just print the link)
//	lantern-bridge status         what it serves and who's paired
//	lantern-bridge revoke <id>    unpair a device
//
// Its folder (identity, devices, settings, admin socket) is ~/Library/Application Support/Lantern/Bridge,
// or LANTERN_BRIDGE_DIR.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"rsc.io/qr"
)

func main() {
	dir := os.Getenv("LANTERN_BRIDGE_DIR")
	if dir == "" {
		home, _ := os.UserHomeDir()
		dir = filepath.Join(home, "Library", "Application Support", "Lantern", "Bridge")
	}
	command := "serve"
	if len(os.Args) > 1 {
		command = os.Args[1]
	}
	var err error
	switch command {
	case "serve":
		err = serve(dir)
	case "pair":
		err = pair(dir, len(os.Args) > 2 && os.Args[2] == "--link")
	case "status":
		err = printStatus(dir)
	case "revoke":
		if len(os.Args) < 3 {
			err = fmt.Errorf("usage: lantern-bridge revoke <device id>")
		} else {
			err = admin(dir, http.MethodDelete, "/devices/"+os.Args[2], nil)
		}
	case "version":
		fmt.Println(version)
	default:
		err = fmt.Errorf("usage: lantern-bridge [serve|pair [--link]|status|revoke <id>|version]")
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func serve(dir string) error {
	b, err := openBridge(dir)
	if err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	go b.backends.watch(ctx, 10*time.Second)
	go b.advertise(ctx)
	go func() {
		if err := b.serveAdmin(ctx); err != nil {
			log.Printf("admin socket: %v", err)
		}
	}()
	// Models kept loaded for good are loaded now, not on the first question, and again whenever
	// they aren't (the model server restarted, or something unloaded them).
	go func() {
		time.Sleep(3 * time.Second) // the first look at the backends
		ticker := time.NewTicker(30 * time.Second)
		defer ticker.Stop()
		for {
			for _, m := range b.settings().KeepLoaded {
				if b.backends.loaded(ctx, m) {
					continue
				}
				log.Printf("loading %s, kept loaded", m)
				if err := b.backends.warm(ctx, m, -1); err != nil {
					log.Printf("loading %s: %v", m, err)
				}
			}
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
			}
		}
	}()
	log.Printf("lantern-bridge %s on :%d, certificate %s", version, b.port(), b.identity.fingerprint)
	s := &server{b: b, backends: b.backends, devices: b.devices}
	return s.listen(ctx, fmt.Sprintf(":%d", b.port()))
}

func admin(dir, method, path string, into any) error {
	req, _ := http.NewRequest(method, "http://bridge"+path, nil)
	resp, err := adminClient(dir).Do(req)
	if err != nil {
		return fmt.Errorf("the bridge isn't running (%v)", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		body, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("HTTP %d: %s", resp.StatusCode, strings.TrimSpace(string(body)))
	}
	if into != nil {
		return json.NewDecoder(resp.Body).Decode(into)
	}
	return nil
}

func pair(dir string, linkOnly bool) error {
	var offer struct {
		Link    string    `json:"link"`
		Expires time.Time `json:"expires"`
	}
	if err := admin(dir, http.MethodPost, "/pairing", &offer); err != nil {
		return err
	}
	if linkOnly {
		fmt.Println(offer.Link)
		return nil
	}
	code, err := qr.Encode(offer.Link, qr.M)
	if err != nil {
		return err
	}
	printQR(code)
	fmt.Printf("Scan with the iPhone's camera and open in Lantern. Good for one device until %s.\n",
		offer.Expires.Local().Format("3:04 PM"))
	return nil
}

// printQR draws the code in the terminal, two rows of modules to a line, with a quiet zone.
func printQR(code *qr.Code) {
	const quiet = 2
	dark := func(x, y int) bool {
		return x >= 0 && y >= 0 && x < code.Size && y < code.Size && code.Black(x, y)
	}
	var sb strings.Builder
	for y := -quiet; y < code.Size+quiet; y += 2 {
		for x := -quiet; x < code.Size+quiet; x++ {
			top, bottom := dark(x, y), dark(x, y+1)
			// Light modules are drawn, dark ones left as the (dark) terminal background, inverted
			// so the code reads dark-on-light whatever the terminal's colours.
			switch {
			case !top && !bottom:
				sb.WriteString("█")
			case !top && bottom:
				sb.WriteString("▀")
			case top && !bottom:
				sb.WriteString("▄")
			default:
				sb.WriteString(" ")
			}
		}
		sb.WriteString("\n")
	}
	fmt.Print(sb.String())
}

func printStatus(dir string) error {
	var s status
	if err := admin(dir, http.MethodGet, "/status", &s); err != nil {
		return err
	}
	fmt.Printf("%s: lantern-bridge %s on port %d\ncertificate %s\n", s.Name, s.Version, s.Port, s.Fingerprint)
	fmt.Printf("addresses: %s\n", strings.Join(s.Addresses, ", "))
	for _, be := range s.Backends {
		fmt.Printf("backend %s at %s\n", be.Name, be.URL)
	}
	for _, m := range s.Models {
		var can []string
		for name, on := range map[string]bool{"vision": m.Lantern.Vision, "tools": m.Lantern.Tools, "thinking": m.Lantern.Thinking} {
			if on {
				can = append(can, name)
			}
		}
		fmt.Printf("model %s (%s) %s\n", m.ID, m.OwnedBy, strings.Join(can, " "))
	}
	for _, d := range s.Devices {
		seen := "never"
		if !d.LastSeen.IsZero() {
			seen = d.LastSeen.Local().Format(time.DateTime)
		}
		fmt.Printf("device %s %q paired %s, last seen %s\n", d.ID, d.Name, d.Paired.Local().Format(time.DateOnly), seen)
	}
	return nil
}
