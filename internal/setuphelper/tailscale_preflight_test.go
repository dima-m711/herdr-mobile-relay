package setuphelper

import (
	"bytes"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"testing"
)

func TestTailscaleStaticEnvironment(t *testing.T) {
	for _, tc := range []struct {
		name, body string
		fail       bool
	}{
		{"generated", "# private config\nHERDR_RELAY_TOKEN='fixture-secret'\nexport HERDR_RELAY_HOST=127.0.0.1\nHERDR_GATEWAY_URL=\n", false},
		{"literal dollar", "HERDR_RELAY_TOKEN='literal-$-not-an-expansion'\n", false},
		{"assignment preceding command", "HERDR_RELAY_HOST= /tmp/must-not-run\n", true},
		{"assignment preceding quoted command", "HERDR_RELAY_HOST= 'id'\n", true},
		{"command substitution", "HERDR_RELAY_TOKEN=$(touch /must-not-run)\n", true},
		{"double quoted expansion", "HERDR_RELAY_TOKEN=\"$SECRET\"\n", true},
		{"backtick", "HERDR_RELAY_TOKEN=`id`\n", true},
		{"extra command", "HERDR_RELAY_TOKEN=value; echo private-secret\n", true},
		{"duplicate", "HERDR_RELAY_HOST=127.0.0.1\nHERDR_RELAY_HOST=0.0.0.0\n", true},
		{"shell configuration", "BASH_ENV=/tmp/malicious\n", true},
		{"lock substitution", "HERDR_RELAY_SETUP_LOCK_FD=0\n", true},
		{"binary substitution", "HERDR_RELAY_BIN=/tmp/foreign\n", true},
		{"unterminated quote", "HERDR_RELAY_TOKEN='private-secret\n", true},
		{"oversized", strings.Repeat(" ", 65537), true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "relay.env")
			if err := os.WriteFile(path, []byte(tc.body), 0o600); err != nil {
				t.Fatal(err)
			}
			values, err := ReadTailscaleEnvironment(path)
			if (err != nil) != tc.fail {
				t.Fatalf("unexpected result: %v", err)
			}
			if err != nil && strings.Contains(err.Error(), "private-secret") {
				t.Fatal("diagnostic leaked input")
			}
			if !tc.fail && values["HERDR_RELAY_TOKEN"] == "" {
				t.Fatal("token missing")
			}
		})
	}
}

func TestTailscaleManagedEnvironment(t *testing.T) {
	for _, unit := range []string{"herdr-mobile-relay-tailscale.service", "com.herdr-mobile-relay.tailscale.plist"} {
		t.Run(unit, func(t *testing.T) { testTailscaleManagedEnvironment(t, unit) })
	}
}

func testTailscaleManagedEnvironment(t *testing.T, unit string) {
	statePath, state := tailscaleStateFixture(t)
	state.Unit = filepath.Join(filepath.Dir(state.Unit), unit)
	if err := CreateTailscaleState(statePath, state); err != nil {
		t.Fatal(err)
	}
	root := filepath.Join(filepath.Dir(statePath), "releases")
	values := map[string]string{
		"HERDR_CONNECTION_MODE": "tailscale", "HERDR_RELAY_HOST": "127.0.0.1", "HERDR_TRANSPORT_FORCE_RELAY": "1", "HERDR_REACHABILITY_PORT_MAPPING": "0", "HERDR_RELAY_REARM_BOOTSTRAP": "0", "HERDR_GATEWAY_URL": "",
		"HERDR_RELAY_PORT": "8375", "HERDR_RELAY_PLUGIN_PORT": "8376", "HERDR_SOCKET_PATH": state.Socket, "HERDR_RELAY_INSTANCE_ID": state.Instance, "HERDR_RELAY_SERVICE_NAME": strings.TrimSuffix(filepath.Base(state.Unit), ".plist"), "HERDR_RELEASE_ROOT": root, "HERDR_WEB_ROOT": filepath.Join(root, "current", "web"), "HERDR_RELAY_TOKEN": strings.Repeat("a", 32),
	}
	write := func() {
		t.Helper()
		var body strings.Builder
		for k, v := range values {
			body.WriteString(k + "='" + v + "'\n")
		}
		if err := os.WriteFile(state.Environment, []byte(body.String()), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	check := func() error {
		return RunTailscalePreflight([]string{"managed-environment", state.Environment, statePath, root}, strings.NewReader(""), &bytes.Buffer{})
	}
	write()
	if err := check(); err != nil {
		t.Fatal(err)
	}
	for key, old := range values {
		values[key] = "foreign"
		write()
		if err := check(); err == nil {
			t.Fatalf("changed %s accepted", key)
		}
		values[key] = old
	}
	for _, key := range []string{"HERDR_RELAY_ENV", "HERDR_PLUGIN_CONFIG_DIR"} {
		values[key] = "/foreign"
		write()
		if err := check(); err == nil {
			t.Fatalf("custom %s accepted", key)
		}
		delete(values, key)
	}
}

func TestTailscaleEnvironmentRefusesUnsafeFiles(t *testing.T) {
	path := filepath.Join(t.TempDir(), "relay.env")
	if err := os.WriteFile(path, []byte("HERDR_CONNECTION_MODE=tailscale\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := ReadTailscaleEnvironment(path); err == nil {
		t.Fatal("nonprivate environment accepted")
	}
	if err := os.Chmod(path, 0o600); err != nil {
		t.Fatal(err)
	}
	alias := path + ".alias"
	if err := os.Symlink(path, alias); err != nil {
		t.Fatal(err)
	}
	if _, err := ReadTailscaleEnvironment(alias); err == nil {
		t.Fatal("symlink accepted")
	}
}

func TestTailscaleRunbookRecognition(t *testing.T) {
	dir := t.TempDir()
	unit, launcher := filepath.Join(dir, "unit"), filepath.Join(dir, "launcher")
	if err := os.WriteFile(unit, []byte(tailscaleRunbookUnit), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(launcher, []byte(tailscaleRunbookLauncher), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := RecognizeTailscaleRunbook(unit, launcher); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(launcher, []byte(tailscaleRunbookLauncher+"echo malicious\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := RecognizeTailscaleRunbook(unit, launcher); err == nil {
		t.Fatal("unknown launcher accepted")
	}
	if err := os.WriteFile(launcher, []byte(tailscaleRunbookLauncher), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(unit, []byte(tailscaleRunbookUnit+"ExecStartPost=/bin/false\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := RecognizeTailscaleRunbook(unit, launcher); err == nil {
		t.Fatal("unknown unit directive accepted")
	}
}

func TestTailscaleProbeSessionDoesNotPrintInventory(t *testing.T) {
	dir, err := os.MkdirTemp("", "ts-probe-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)
	socket := filepath.Join(dir, "herdr.sock")
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	done := make(chan error, 1)
	go func() {
		conn, err := listener.Accept()
		if err != nil {
			done <- err
			return
		}
		defer conn.Close()
		var request struct {
			ID     string `json:"id"`
			Method string `json:"method"`
		}
		if err = json.NewDecoder(conn).Decode(&request); err != nil {
			done <- err
			return
		}
		if request.Method != "agent.list" {
			done <- os.ErrInvalid
			return
		}
		done <- json.NewEncoder(conn).Encode(map[string]any{"id": request.ID, "result": map[string]any{"type": "agent_list", "agents": []any{map[string]any{"pane_id": "fixture", "name": "private inventory must not print", "agent": "claude"}}}})
	}()
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	var output bytes.Buffer
	if err := RunTailscalePreflight([]string{"session", executable, socket}, strings.NewReader(""), &output); err != nil {
		t.Fatal(err)
	}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	if output.Len() != 0 {
		t.Fatal("preflight printed inventory")
	}
	if err := RunTailscalePreflight([]string{"session", "/not-present", socket}, strings.NewReader(""), &output); err == nil {
		t.Fatal("missing executable accepted")
	}
}

func TestTailscalePortsOccupied(t *testing.T) {
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	port := listener.Addr().(*net.TCPAddr).Port
	if err := RunTailscalePreflight([]string{"ports", strconv.Itoa(port), "8376"}, strings.NewReader(""), &bytes.Buffer{}); err == nil {
		t.Fatal("occupied TCP port accepted")
	}
	for _, port := range []string{"0", "65536", "$(id)"} {
		if err := RunTailscalePreflight([]string{"ports", port, "8376"}, strings.NewReader(""), &bytes.Buffer{}); err == nil {
			t.Fatal("invalid port accepted")
		}
	}
}

func TestTailscaleListenerIdentity(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("Linux procfs listener verification")
	}
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	args := []string{"listener", strconv.Itoa(os.Getpid()), strconv.Itoa(listener.Addr().(*net.TCPAddr).Port), executable}
	if err := RunTailscalePreflight(args, strings.NewReader(""), &bytes.Buffer{}); err != nil {
		t.Fatal(err)
	}
	args[3] = "/wrong-executable"
	if err := RunTailscalePreflight(args, strings.NewReader(""), &bytes.Buffer{}); err == nil {
		t.Fatal("wrong executable accepted")
	}
	args = args[:3]
	args[1] = strconv.Itoa(os.Getppid())
	if err := RunTailscalePreflight(args, strings.NewReader(""), &bytes.Buffer{}); err == nil {
		t.Fatal("another process was credited with this listener")
	}
	args[1] = "-1"
	if err := RunTailscalePreflight(args, strings.NewReader(""), &bytes.Buffer{}); err == nil {
		t.Fatal("invalid PID accepted")
	}
}

func TestTailscaleNativeRecoveryRecord(t *testing.T) {
	dir, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	path, unit, env := filepath.Join(dir, "state"), filepath.Join(dir, "unit"), filepath.Join(dir, "relay.env")
	body := "definition=" + unit + "\nlegacy_definition=\nenvironment=" + env + "\nactive=true\nenabled=false\nlegacy_active=false\nlegacy_enabled=false\n"
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	var output bytes.Buffer
	if err := RunTailscalePreflight([]string{"native-record", path, unit, env}, strings.NewReader(""), &output); err != nil {
		t.Fatal(err)
	}
	if output.String() != "true\tfalse\n" {
		t.Fatal("incorrect recovery flags")
	}
	if err := RunTailscalePreflight([]string{"native-record", path, unit + "foreign", env}, strings.NewReader(""), &output); err == nil {
		t.Fatal("foreign definition accepted")
	}
	if err := os.WriteFile(path, []byte(body+"active=false\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := RunTailscalePreflight([]string{"native-record", path, unit, env}, strings.NewReader(""), &output); err == nil {
		t.Fatal("ambiguous recovery accepted")
	}
}

func TestTailscaleGatewayHealth(t *testing.T) {
	for _, input := range []string{`{}`, `{"gateway":{"enabled":true,"registered":false}}`, `{"gateway":{"enabled":false,"registered":true}}`, `{"gateway":{"enabled":null,"registered":false}}`} {
		if err := RunTailscalePreflight([]string{"gateway-disabled"}, strings.NewReader(input), &bytes.Buffer{}); err == nil {
			t.Fatal("unverified gateway accepted")
		}
	}
	if err := RunTailscalePreflight([]string{"gateway-disabled"}, strings.NewReader(`{"gateway":{"enabled":false,"registered":false}}`), &bytes.Buffer{}); err != nil {
		t.Fatal(err)
	}
}
