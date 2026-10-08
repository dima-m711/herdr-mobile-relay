package blackbox

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"testing"
	"time"

	"github.com/coder/websocket"
)

// Real encrypted WebSocket sessions against private-mode relay processes and
// distinct fake Herdr sockets. HTTPS/Serve and a physical phone remain human gates.
func TestPrivateRelaysRetainIndependentCredentialsAcrossRestart(t *testing.T) {
	const appOrigin = "https://app.fixture.ts.net:8443"
	type paired struct {
		env    *TestEnv
		id     string
		secret []byte
		pane   string
		state  string
	}
	hosts := make([]paired, 0, 2)
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	for i, key := range []string{relayKey, "fedcba9876543210fedcba9876543210"} {
		dir := t.TempDir()
		if err := os.Chmod(dir, 0700); err != nil {
			t.Fatal(err)
		}
		pane := fmt.Sprintf("private-pane-%d", i)
		scenario := fmt.Sprintf(`{"panes":[{"pane_id":%q,"terminal_id":"terminal","agent":"claude","name":"private","agent_status":"working","tab_id":"tab","workspace_id":"workspace","cwd":"/tmp","revision":1}]}`, pane)
		env := setupEnvWithScenario(t, scenario,
			"HERDR_CONNECTION_MODE=tailscale", "HERDR_RELAY_TOKEN="+key,
			"HERDR_GATEWAY_URL=", "HERDR_REACHABILITY_PORT_MAPPING=0", "HERDR_TRANSPORT_FORCE_RELAY=1", "HERDR_RELAY_REARM_BOOTSTRAP=0",
			"HERDR_RELAY_ENV="+filepath.Join(dir, "relay.env"),
			"HERDR_RELAY_INSTANCE_ID="+fmt.Sprintf("private-%d", i),
			"HERDR_PHONE_APP_URL="+appOrigin,
			// Authenticated cross-origin access must not depend on a tokenless-origin allowlist.
			"HERDR_ALLOWED_ORIGINS=https://different.fixture.ts.net",
		)
		state := filepath.Join(dir, "device-auth", "devices.json")
		if invitationPresent(t, state) {
			t.Fatal("private startup armed an invitation")
		}
		conn, response, err := websocket.Dial(ctx, env.wsURL, &websocket.DialOptions{HTTPHeader: http.Header{"Origin": {appOrigin}}})
		if conn != nil {
			conn.CloseNow()
		}
		if err == nil || response == nil || response.StatusCode != http.StatusBadRequest {
			t.Fatal("private relay accepted a plaintext client")
		}
		if err := env.relayCmd.Process.Signal(syscall.SIGUSR1); err != nil {
			t.Fatal(err)
		}
		deadline := time.Now().Add(5 * time.Second)
		for !invitationPresent(t, state) {
			if time.Now().After(deadline) {
				t.Fatal("private invitation was not acknowledged")
			}
			time.Sleep(20 * time.Millisecond)
		}
		p := privatePhone(t, ctx, env, appOrigin)
		p.handshakeAuth(ctx, "invitation", "bootstrap", []byte(key))
		finish := p.awaitMessage(ctx, "e2ee_server_finish")
		credentialID, ok := finish["credential_id"].(string)
		secret, err := base64.RawURLEncoding.DecodeString(fmt.Sprint(finish["credential_secret"]))
		if !ok || credentialID == "" || err != nil || len(secret) != 32 {
			t.Fatal("missing enrolled credential")
		}
		assertPrivateInventory(t, ctx, p, pane)
		p.conn.CloseNow()
		hosts = append(hosts, paired{env, credentialID, secret, pane, state})
	}
	if hosts[0].id == hosts[1].id || string(hosts[0].secret) == string(hosts[1].secret) {
		t.Fatal("independent relays shared credentials")
	}
	for _, host := range hosts {
		// Credential authentication commits enrollment and consumes bootstrap.
		p := privatePhone(t, ctx, host.env, appOrigin)
		p.handshakeAuth(ctx, "credential", host.id, host.secret)
		if p.awaitMessage(ctx, "e2ee_server_finish")["credential_id"] != host.id {
			t.Fatal("reopen replaced credential")
		}
		assertPrivateInventory(t, ctx, p, host.pane)
		p.conn.CloseNow()
		if invitationPresent(t, host.state) {
			t.Fatal("credential reconnect did not consume bootstrap")
		}
		restartPrivateRelay(t, host.env)
		if invitationPresent(t, host.state) {
			t.Fatal("private restart rearmed bootstrap")
		}
		p = privatePhone(t, ctx, host.env, appOrigin)
		p.handshakeAuth(ctx, "credential", host.id, host.secret)
		if p.awaitMessage(ctx, "e2ee_server_finish")["credential_id"] != host.id {
			t.Fatal("restart replaced credential")
		}
		assertPrivateInventory(t, ctx, p, host.pane)
		p.conn.CloseNow()
		request, err := http.NewRequestWithContext(ctx, http.MethodGet, host.env.httpBase+"/healthz", nil)
		if err != nil {
			t.Fatal(err)
		}
		response, err := http.DefaultClient.Do(request)
		if err != nil {
			t.Fatal(err)
		}
		var health struct {
			Gateway *struct {
				Enabled    *bool
				Registered *bool
			}
		}
		err = json.NewDecoder(response.Body).Decode(&health)
		response.Body.Close()
		if err != nil || health.Gateway == nil || health.Gateway.Enabled == nil || health.Gateway.Registered == nil || *health.Gateway.Enabled || *health.Gateway.Registered {
			t.Fatal("private relay activated a gateway")
		}
	}
}

func invitationPresent(t *testing.T, path string) bool {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var state struct {
		Invitation *json.RawMessage `json:"invitation"`
	}
	if err := json.Unmarshal(data, &state); err != nil {
		t.Fatal(err)
	}
	return state.Invitation != nil
}

func privatePhone(t *testing.T, ctx context.Context, env *TestEnv, origin string) *phone {
	t.Helper()
	conn, _, err := websocket.Dial(ctx, env.wsURL, &websocket.DialOptions{
		Subprotocols: []string{"herdr-e2ee-v2"}, HTTPHeader: http.Header{"Origin": {origin}},
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.CloseNow() })
	return &phone{t: t, conn: conn, direct: true}
}

func assertPrivateInventory(t *testing.T, ctx context.Context, p *phone, pane string) {
	t.Helper()
	message := p.awaitMessage(ctx, "agents")
	agents, ok := message["agents"].([]any)
	if !ok || len(agents) != 1 {
		t.Fatal("private relay exposed unexpected inventory")
	}
	if agents[0].(map[string]any)["pane_id"] != pane {
		t.Fatal("private relay selected another Herdr socket")
	}
}

func restartPrivateRelay(t *testing.T, env *TestEnv) {
	t.Helper()
	previous := env.relayCmd
	if err := previous.Process.Signal(os.Interrupt); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- previous.Wait() }()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		_ = previous.Process.Kill()
		<-done
		t.Fatal("private relay did not stop")
	}
	env.relayCmd = exec.Command(previous.Path, previous.Args[1:]...)
	env.relayCmd.Env = previous.Env
	env.relayCmd.Stdout, env.relayCmd.Stderr = previous.Stdout, previous.Stderr
	if err := env.relayCmd.Start(); err != nil {
		t.Fatal(err)
	}
	waitForStatus(t, env.httpBase, "/readyz", http.StatusOK)
}
