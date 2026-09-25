package setuphelper

import (
	"bytes"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

// NormalizeTailscaleOrigin narrows the existing app-origin contract. A valid
// name is not reachability or ownership evidence; callers verify HTTPS too.
func NormalizeTailscaleOrigin(raw string) (string, error) {
	if strings.ContainsAny(raw, "?#\\") || strings.IndexFunc(raw, func(r rune) bool { return r <= 32 || r == 127 }) >= 0 {
		return "", errors.New("private app origin must be an HTTPS ts.net origin without a path, credentials or fragment")
	}
	origin, err := NormalizeOrigin(raw, false)
	if err != nil {
		return "", errors.New("invalid private HTTPS app origin")
	}
	parsed, err := url.Parse(origin)
	if err != nil || !tailscaleHostnameValid(strings.ToLower(parsed.Hostname())) {
		return "", errors.New("private app origin must use a Tailscale DNS hostname")
	}
	parsed.Host = strings.ToLower(parsed.Host)
	return parsed.String(), nil
}

// This is app reachability/shape evidence, not phone authentication or proof
// that a remote app host ships the same version as the selected relay.
func ValidatePrivateAppMetadata(input io.Reader) error {
	data, err := tailscaleJSON(input)
	if err != nil {
		return errors.New("private app metadata is unavailable or malformed")
	}
	var app struct {
		Version string `json:"version"`
		Assets  int    `json:"assets"`
	}
	if json.Unmarshal(data, &app) != nil || len(app.Version) == 0 || len(app.Version) > 128 || app.Assets < 1 || strings.IndexFunc(app.Version, func(r rune) bool { return r < 33 || r == 127 }) >= 0 {
		return errors.New("private host did not return recognized phone app metadata")
	}
	return nil
}

type privateInvitation struct {
	ID       string    `json:"invitation_id"`
	Version  uint64    `json:"version"`
	Secret   string    `json:"secret"`
	Role     string    `json:"role"`
	Expires  time.Time `json:"expires_at"`
	Pending  string    `json:"pending_credential_id"`
	Attempts int       `json:"failed_attempts"`
}

func readPrivateInvitation(path string) (*privateInvitation, error) {
	data, err := readTailscaleOwnedFile(path, maxTailscaleJSON, true)
	if err != nil {
		return nil, err
	}
	data, err = tailscaleJSON(bytes.NewReader(data))
	if err != nil {
		return nil, errors.New("cannot verify private invitation state")
	}
	var state struct {
		Schema     int                `json:"schema_version"`
		Invitation *privateInvitation `json:"invitation"`
	}
	if json.Unmarshal(data, &state) != nil || state.Schema != 1 {
		return nil, errors.New("unsupported private invitation state")
	}
	return state.Invitation, nil
}

func privateBootstrapExpiry(path, key string) (time.Time, error) {
	inv, err := readPrivateInvitation(path)
	if err != nil {
		return time.Time{}, err
	}
	if inv == nil {
		return time.Time{}, nil
	}
	expected := base64.RawURLEncoding.EncodeToString([]byte(key))
	if len(key) != 32 || inv.ID != "bootstrap" || inv.Version != 1 || inv.Role != "controller" || inv.Pending != "" || inv.Attempts != 0 || subtle.ConstantTimeCompare([]byte(inv.Secret), []byte(expected)) != 1 {
		return time.Time{}, errors.New("no usable acknowledged bootstrap invitation")
	}
	return inv.Expires, nil
}

func confirmPrivateBootstrap(path, key string, previous, requested time.Time) error {
	expiry, err := privateBootstrapExpiry(path, key)
	if err != nil {
		return err
	}
	// The live store persists a ten-minute lifetime. Unchanged, consumed, stale,
	// foreign-key or implausibly long invitations never qualify as an ACK.
	if expiry.Equal(previous) || expiry.Before(requested.Add(10*time.Minute)) || expiry.After(time.Now().Add(10*time.Minute+time.Second)) {
		return errors.New("relay has not acknowledged the new invitation")
	}
	return nil
}

func armPrivateInvitation(envPath, rawPID string, values map[string]string) error {
	pid, err := strconv.Atoi(rawPID)
	if err != nil || pid <= 1 || runtime.GOOS != "linux" {
		return errors.New("invalid private relay process")
	}
	process, err := os.FindProcess(pid)
	if err != nil {
		return errors.New("private relay process is unavailable")
	}
	defer process.Release()
	executable, err := os.Executable()
	if err != nil {
		return err
	}
	if err := verifyTailscaleListener(rawPID, values["HERDR_RELAY_PORT"], executable); err != nil {
		return err
	}
	path := filepath.Join(filepath.Dir(envPath), "device-auth", "devices.json")
	before, err := readPrivateInvitation(path)
	if err != nil {
		return err
	}
	var previous time.Time
	if before != nil {
		previous = before.Expires
	}
	requested := time.Now().UTC()
	if err := process.Signal(syscall.SIGUSR1); err != nil {
		return errors.New("could not request private invitation")
	}
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if err := confirmPrivateBootstrap(path, values["HERDR_RELAY_TOKEN"], previous, requested); err == nil {
			return nil
		}
		time.Sleep(50 * time.Millisecond)
	}
	return errors.New("private invitation was not acknowledged; no QR was produced")
}

// RunTailscalePairing keeps secrets out of argv and child processes. Rendering
// reuses SetupFragment/TerminalQR, but only to the attached private terminal.
func RunTailscalePairing(args []string, output io.Writer) error {
	if len(args) == 1 && args[0] == "app" {
		return ValidatePrivateAppMetadata(os.Stdin)
	}
	if len(args) == 2 && args[0] == "origin" {
		origin, err := NormalizeTailscaleOrigin(args[1])
		if err != nil {
			return err
		}
		_, err = fmt.Fprintln(output, origin)
		return err
	}
	if len(args) != 7 || args[0] != "show" {
		return errors.New("usage: tailscale-pairing app | origin URL | show ENV PID APP_ORIGIN RELAY_ORIGIN LABEL COLUMNS")
	}
	if output != os.Stdout || runtime.GOOS != "linux" {
		return errors.New("private invitations require an attached Linux terminal")
	}
	if _, err := unix.IoctlGetWinsize(int(os.Stdin.Fd()), unix.TIOCGWINSZ); err != nil {
		return errors.New("private invitations require terminal input")
	}
	if _, err := unix.IoctlGetWinsize(int(os.Stdout.Fd()), unix.TIOCGWINSZ); err != nil {
		return errors.New("private invitations cannot be redirected")
	}
	app, err := NormalizeTailscaleOrigin(args[3])
	if err != nil {
		return err
	}
	relay, err := NormalizeTailscaleOrigin(args[4])
	if err != nil {
		return err
	}
	label := args[5]
	if len(label) > 128 || strings.IndexFunc(label, func(r rune) bool { return r < 32 || r == 127 }) >= 0 {
		return errors.New("invalid private relay label")
	}
	columns, err := strconv.Atoi(args[6])
	if err != nil || columns < 1 || columns > 10000 {
		return errors.New("invalid terminal width")
	}
	values, err := ReadTailscaleEnvironment(args[1])
	if err != nil {
		return err
	}
	if values["HERDR_CONNECTION_MODE"] != "tailscale" || len(values["HERDR_RELAY_TOKEN"]) != 32 {
		return errors.New("private pairing requires its original configured identity")
	}
	if err := armPrivateInvitation(args[1], args[2], values); err != nil {
		return err
	}
	link := app + "/#" + SetupFragment(values["HERDR_RELAY_TOKEN"], label, "wss://"+strings.TrimPrefix(relay, "https://"))
	qr, err := TerminalQR(link, columns)
	if err != nil {
		if _, err = fmt.Fprintln(output, "Terminal too narrow for this QR. Widen it and regenerate; the private link below is still usable."); err != nil {
			return err
		}
	} else if _, err = fmt.Fprintln(output, qr); err != nil {
		return err
	}
	_, err = fmt.Fprintf(output, "\n%s\n\nOne phone within ten minutes. Do not share this terminal or screenshots.\nPhone authentication is not confirmed until the phone shows this computer's inventory.\n", link)
	return err
}
