package setuphelper

import (
	"bufio"
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/0cv/herdr-mobile-relay/internal/deviceauth"
	"github.com/0cv/herdr-mobile-relay/internal/transport"
)

func TestPrivateAppOrigin(t *testing.T) {
	for _, raw := range []string{"https://app.tailtest.ts.net:8443", "app.tailtest.ts.net/", "https://APP.TAILTEST.TS.NET:8443"} {
		got, err := NormalizeTailscaleOrigin(raw)
		if err != nil || !strings.HasPrefix(got, "https://app.tailtest.ts.net") {
			t.Fatalf("private origin: %q %v", got, err)
		}
	}
	for _, raw := range []string{"https://public.example", "https://ts.net", "https://evilts.net", "http://app.tailtest.ts.net", "https://app.tailtest.ts.net/path", "https://user:password@app.tailtest.ts.net", "https://app.tailtest.ts.net?", "https://app.tailtest.ts.net#", "https://app.tailtest.ts.net:0", "https://app.tailtest.ts.net\\bad", "https://app.tailtest.ts.net\n"} {
		if _, err := NormalizeTailscaleOrigin(raw); err == nil {
			t.Fatalf("accepted unsafe origin %q", raw)
		}
	}
}

func TestPrivateAppMetadata(t *testing.T) {
	for _, input := range []string{`{"version":"0.21.3","assets":1}`, `{"version":"0.22.0","assets":2,"script":"/builds/app.js"}`} {
		if err := ValidatePrivateAppMetadata(strings.NewReader(input)); err != nil {
			t.Fatal(err)
		}
	}
	for _, input := range []string{`<html>not this app</html>`, `{}`, `{"version":"v","assets":0}`, `{"version":"v","assets":1,"Assets":2}`, `{"version":"bad\nvalue","assets":1}`, `{"version":"v","assets":"1"}`} {
		if err := ValidatePrivateAppMetadata(strings.NewReader(input)); err == nil {
			t.Fatal("invalid app metadata accepted")
		}
	}
}

func TestPrivateBootstrapAcknowledgment(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "devices.json")
	now := time.Now().UTC()
	key := strings.Repeat("k", 32)
	write := func(inv map[string]any) {
		t.Helper()
		data, err := json.Marshal(map[string]any{"schema_version": 1, "invitation": inv, "credentials": []any{}})
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, data, 0600); err != nil {
			t.Fatal(err)
		}
	}
	fresh := func() map[string]any {
		return map[string]any{"invitation_id": "bootstrap", "version": 1, "secret": base64.RawURLEncoding.EncodeToString([]byte(key)), "role": "controller", "expires_at": now.Add(10 * time.Minute), "failed_attempts": 0}
	}
	write(fresh())
	expiry, err := privateBootstrapExpiry(path, key)
	if err != nil || !expiry.Equal(now.Add(10*time.Minute)) {
		t.Fatalf("fresh acknowledgment: %v", err)
	}
	if err := confirmPrivateBootstrap(path, key, expiry, now); err == nil {
		t.Fatal("unchanged old invitation acknowledged")
	}
	if err := confirmPrivateBootstrap(path, key, time.Time{}, now); err != nil {
		t.Fatal(err)
	}
	for _, change := range []map[string]any{{"secret": "foreign"}, {"role": "reader"}, {"invitation_id": "other"}, {"version": 2}, {"pending_credential_id": "already-used"}, {"failed_attempts": 1}, {"expires_at": now.Add(-time.Minute)}} {
		inv := fresh()
		for k, v := range change {
			inv[k] = v
		}
		write(inv)
		if err := confirmPrivateBootstrap(path, key, time.Time{}, now); err == nil {
			t.Fatalf("accepted invalid acknowledgment: %v", change)
		}
	}
	write(fresh())
	if err := os.Chmod(path, 0644); err != nil {
		t.Fatal(err)
	}
	if _, err := privateBootstrapExpiry(path, key); err == nil {
		t.Fatal("public device state accepted")
	}
	if err := os.Chmod(path, 0600); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(dir, "link.json")
	if err := os.Symlink(path, link); err != nil {
		t.Fatal(err)
	}
	if _, err := privateBootstrapExpiry(link, key); err == nil {
		t.Fatal("symlink state accepted")
	}
	if err := os.WriteFile(path, []byte(`{"schema_version":1,"invitation":null,"invitation":null}`), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := privateBootstrapExpiry(path, key); err == nil {
		t.Fatal("ambiguous state accepted")
	}
}

// A disposable same-executable listener exercises PID/socket verification and
// SIGUSR1 persistence without ever starting Herdr or contacting a live relay.
func TestPrivateArmProcess(t *testing.T) {
	if os.Getenv("HERDR_TEST_PRIVATE_ARM_CHILD") != "1" {
		return
	}
	key := strings.Repeat("k", 32)
	store, err := deviceauth.Open(filepath.Join(os.Getenv("HERDR_TEST_PRIVATE_ARM_DIR"), "device-auth"))
	if err != nil {
		t.Fatal(err)
	}
	if err := store.EnsureBootstrapInvitation([]byte(key), "fixture", "en"); err != nil {
		t.Fatal(err)
	}
	first, err := store.CompleteE2EEAuth(context.Background(), transport.E2EEAuthSelector{Kind: transport.E2EEAuthInvitation, ID: "bootstrap", Version: 1}, true)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.CompleteE2EEAuth(context.Background(), transport.E2EEAuthSelector{Kind: transport.E2EEAuthCredential, ID: first.Identity.CredentialID, Version: first.Identity.CredentialVersion, Locale: first.Identity.Locale}, true); err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGUSR1)
	defer signal.Stop(signals)
	fmt.Println(listener.Addr().(*net.TCPAddr).Port)
	select {
	case <-signals:
		if err := store.ArmBootstrapInvitation([]byte(key), "fixture", "en"); err != nil {
			t.Fatal(err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("no signal")
	}
	time.Sleep(10 * time.Second) // parent owns termination; keep the listener alive
}

func TestPrivateArmAcknowledgesPersistedSignal(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("Linux listener ownership")
	}
	if os.Getenv("HERDR_TEST_PRIVATE_ARM_CHILD") == "1" {
		return
	}
	dir := t.TempDir()
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	command := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestPrivateArmProcess$")
	command.Env = append(os.Environ(), "HERDR_TEST_PRIVATE_ARM_CHILD=1", "HERDR_TEST_PRIVATE_ARM_DIR="+dir)
	output, err := command.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { _ = command.Process.Kill(); _ = command.Wait() }()
	line, err := bufio.NewReader(output).ReadString('\n')
	if err != nil {
		t.Fatal(err)
	}
	port := strings.TrimSpace(line)
	env := filepath.Join(dir, "relay.env")
	key := strings.Repeat("k", 32)
	values := map[string]string{"HERDR_RELAY_TOKEN": key, "HERDR_RELAY_PORT": port}
	statePath := filepath.Join(dir, "device-auth", "devices.json")
	before, err := os.ReadFile(statePath)
	if err != nil {
		t.Fatal(err)
	}
	var beforeState, afterState struct {
		Credentials json.RawMessage `json:"credentials"`
	}
	if err := json.Unmarshal(before, &beforeState); err != nil {
		t.Fatal(err)
	}
	if err := armPrivateInvitation(env, strconv.Itoa(command.Process.Pid), values); err != nil {
		t.Fatal(err)
	}
	expiry, err := privateBootstrapExpiry(filepath.Join(dir, "device-auth", "devices.json"), key)
	if err != nil || expiry.Before(time.Now().Add(9*time.Minute)) {
		t.Fatalf("missing persisted acknowledgment: %v", err)
	}
	after, err := os.ReadFile(statePath)
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(after, &afterState); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(beforeState.Credentials, afterState.Credentials) || string(afterState.Credentials) == "[]" {
		t.Fatal("pairing credentials changed during invitation arming")
	}
	if err := armPrivateInvitation(env, strconv.Itoa(command.Process.Pid), map[string]string{"HERDR_RELAY_TOKEN": key, "HERDR_RELAY_PORT": "1"}); err == nil {
		t.Fatal("unrelated listener accepted")
	}
}

func TestPrivatePairingRefusesNonterminalOutput(t *testing.T) {
	var output bytes.Buffer
	err := RunTailscalePairing([]string{"show", "/must-not-read", "123", "https://app.tailtest.ts.net", "https://relay.tailtest.ts.net", "label", "80"}, &output)
	if err == nil || output.Len() != 0 {
		t.Fatal("private invitation could enter redirected output")
	}
}
