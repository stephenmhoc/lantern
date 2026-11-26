// lantern-bridge connects Lantern on an iPhone or iPad to the model on this Mac, served by Splash
// (which it starts, keeps running and stops), on the home network or over Tailscale, encrypted
// from the device to the Mac: TLS with the bridge's own certificate, which devices pin when they
// pair, and a token of each device's own. Splash itself only listens on this Mac.
//
//	lantern-bridge serve                 run it (the Mac app or a login agent keeps it running)
//	lantern-bridge pair [--link]         show a QR code for pairing a device (or just print the link)
//	lantern-bridge pair --code           show a code to type on the device instead
//	lantern-bridge status                Splash, the drafter, the tailnet and who's paired
//	lantern-bridge revoke <id>           unpair a device
//	lantern-bridge tailscale set <id>    keep a Tailscale OAuth client (its secret from stdin)
//	lantern-bridge tailscale clear       forget it
//
// Its folder (identity, devices, settings, admin socket, Splash's log) is
// ~/Library/Application Support/Lantern/Bridge, or LANTERN_BRIDGE_DIR. For development,
// LANTERN_BRIDGE_PORT sets the port and LANTERN_BRIDGE_UPSTREAM (http://127.0.0.1:8000) uses a
// Splash already running instead of starting one.
package main

import (
	"bufio"
	"bytes"
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
	args := append(os.Args[1:], "", "")
	var err error
	switch args[0] {
	case "serve", "":
		err = serve(dir)
	case "pair":
		switch args[1] {
		case "--code":
			err = pairCode(dir)
		default:
			err = pair(dir, args[1] == "--link")
		}
	case "status":
		err = printStatus(dir)
	case "revoke":
		if args[1] == "" {
			err = fmt.Errorf("usage: lantern-bridge revoke <device id>")
		} else {
			err = admin(dir, http.MethodDelete, "/devices/"+args[1], nil, nil)
		}
	case "tailscale":
		err = tailscaleCommand(dir, args[1], args[2])
	case "version":
		fmt.Println(version)
	default:
		err = fmt.Errorf("usage: lantern-bridge [serve | pair [--link|--code] | status | revoke <id> | tailscale set <client id>|clear | version]")
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
	// The port first: until it's this bridge's, nothing else (Splash, the admin socket) starts.
	ln, err := claimPort(b.port())
	if err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	restartSplash := make(chan struct{}, 1)
	splashDone := make(chan struct{})
	go func() {
		defer close(splashDone)
		b.splash.run(ctx, restartSplash)
	}()
	go b.advertise(ctx)
	go func() {
		if err := b.serveAdmin(ctx, restartSplash); err != nil {
			log.Printf("admin socket: %v", err)
		}
	}()
	log.Printf("lantern-bridge %s on :%d, certificate %s, Splash at %s", version, b.port(), b.identity.fingerprint, b.splash.url)
	err = (&server{b: b}).serve(ctx, ln)
	stop()
	<-splashDone // Splash stops with the bridge
	return err
}

func admin(dir, method, path string, body, into any) error {
	var reader io.Reader
	if body != nil {
		data, _ := json.Marshal(body)
		reader = bytes.NewReader(data)
	}
	req, _ := http.NewRequest(method, "http://bridge"+path, reader)
	resp, err := adminClient(dir).Do(req)
	if err != nil {
		return fmt.Errorf("the bridge isn't running (%v)", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		var e struct {
			Error struct{ Message string } `json:"error"`
		}
		data, _ := io.ReadAll(resp.Body)
		if json.Unmarshal(data, &e) == nil && e.Error.Message != "" {
			return fmt.Errorf("%s", e.Error.Message)
		}
		return fmt.Errorf("HTTP %d: %s", resp.StatusCode, strings.TrimSpace(string(data)))
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
	if err := admin(dir, http.MethodPost, "/pairing", nil, &offer); err != nil {
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

func pairCode(dir string) error {
	var c struct {
		Code    string    `json:"code"`
		Expires time.Time `json:"expires"`
	}
	if err := admin(dir, http.MethodPost, "/pairing/code", nil, &c); err != nil {
		return err
	}
	fmt.Printf("%s\nType it in Lantern on the device (on the same network). Good for one device until %s.\n",
		c.Code, c.Expires.Local().Format("3:04 PM"))
	return nil
}

func tailscaleCommand(dir, verb, id string) error {
	switch verb {
	case "set":
		if id == "" {
			return fmt.Errorf("usage: lantern-bridge tailscale set <client id>   (the secret on stdin)")
		}
		fmt.Fprint(os.Stderr, "OAuth client secret: ")
		secret, _ := bufio.NewReader(os.Stdin).ReadString('\n')
		var st tailscaleStatus
		if err := admin(dir, http.MethodPut, "/tailscale", tailscaleClient{ClientID: id, ClientSecret: strings.TrimSpace(secret)}, &st); err != nil {
			return err
		}
		fmt.Println("Tailscale: devices that pair get a key to join the tailnet as " + st.Tag + ".")
		return nil
	case "clear":
		return admin(dir, http.MethodDelete, "/tailscale", nil, nil)
	default:
		return fmt.Errorf("usage: lantern-bridge tailscale set <client id> | clear")
	}
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
	if err := admin(dir, http.MethodGet, "/status", nil, &s); err != nil {
		return err
	}
	fmt.Printf("%s: lantern-bridge %s on port %d\ncertificate %s\n", s.Name, s.Version, s.Port, s.Fingerprint)
	fmt.Printf("addresses: %s\n", strings.Join(s.Addresses, ", "))
	sp := s.Splash
	fmt.Printf("splash %s %s at %s (%s)", sp.Version, sp.State, sp.URL, sp.Model)
	if sp.Message != "" {
		fmt.Printf(": %s", sp.Message)
	}
	fmt.Println()
	if d := sp.Drafter; d != nil {
		fmt.Printf("drafter: %d of %d drafted tokens accepted (%.0f%%)", d.Accepted, d.Drafted, d.AcceptRate*100)
		if d.TokensPerStep > 0 {
			fmt.Printf(", %.2f tokens per step", d.TokensPerStep)
		}
		fmt.Printf(", %.0f tokens/s, %s\n", d.TokensPerSec, d.At.Local().Format(time.TimeOnly))
	}
	for _, m := range s.Models {
		fmt.Printf("model %s vision=%v tools=%v thinking=%v efforts=%s\n", m.ID, m.Lantern.Vision, m.Lantern.Tools, m.Lantern.Thinking, strings.Join(m.Lantern.Efforts, ","))
	}
	ts := s.Tailscale
	if ts.Configured {
		fmt.Printf("tailscale: OAuth client %s, keys tagged %s", ts.ClientID, ts.Tag)
		if ts.LastError != "" {
			fmt.Printf(" (last: %s)", ts.LastError)
		}
		fmt.Println()
	} else {
		fmt.Println("tailscale: not set up (devices pair for the home network only)")
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
