package setuphelper

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"

	"github.com/0cv/herdr-mobile-relay/internal/readiness"
)

// runbookReadiness adapts upstream's identity-free /readyz together with its
// identity-bearing /healthz. The caller must recognize the original runbook and
// bind both loopback observations to its unchanged PID/executable/listener.
// Managed readiness remains strict; partial/new readiness is never downgraded.
func runbookReadiness(input io.Reader, output io.Writer, expected readiness.Expected) error {
	data, err := io.ReadAll(io.LimitReader(input, 128*1024+1))
	if err != nil || len(data) > 128*1024 {
		return errors.New("runbook readiness evidence is unavailable or oversized")
	}
	data, err = tailscaleJSON(bytes.NewReader(data))
	if err != nil {
		return err
	}
	var evidence map[string]json.RawMessage
	if json.Unmarshal(data, &evidence) != nil || len(evidence) != 2 {
		return errors.New("expected runbook ready and health evidence")
	}
	var ready, health map[string]any
	if json.Unmarshal(evidence["ready"], &ready) != nil || json.Unmarshal(evidence["health"], &health) != nil {
		return errors.New("invalid runbook readiness evidence")
	}
	inventory, _ := ready["inventory"].(map[string]any)
	if len(ready) != 2 || ready["status"] != "ready" || inventory["state"] != "ready" {
		return errors.New("runbook readiness is not the ready upstream response")
	}
	if health["status"] != "ok" || health["readiness"] != "ready" {
		return errors.New("runbook health is not ready")
	}
	if err := RunTailscalePreflight([]string{"gateway-disabled"}, bytes.NewReader(evidence["health"]), io.Discard); err != nil {
		return err
	}
	// Store only the canonical readiness receipt. This keeps recovery records
	// strictly verifiable and pins subsequent rollback to the observed release.
	receipt := map[string]any{"status": "ready", "inventory": health["inventory"], "protocol": health["protocol"]}
	for _, key := range []string{"instance", "release_version", "revision", "bundle_hash"} {
		receipt[key] = health[key]
	}
	encoded, err := json.Marshal(receipt)
	if err != nil {
		return errors.New("invalid runbook identity evidence")
	}
	if err := readiness.Verify(bytes.NewReader(encoded), expected); err != nil {
		return err
	}
	_, err = output.Write(append(encoded, '\n'))
	return err
}
