package setuphelper

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"

	"github.com/0cv/herdr-mobile-relay/internal/readiness"
)

// Preserve the real upstream 0.21.3 response split, not the newer /readyz shape
// that previously made the shell adoption/rollback fixtures falsely pass.
const upstreamReady = `{"status":"ready","inventory":{"state":"ready","stale":false,"error_code":"","last_attempt_at":1,"last_success_at":1}}`
const upstreamHealth = `{"status":"ok","readiness":"ready","inventory":{"state":"ready"},"instance":"runbook-instance","release_version":"0.21.3","revision":"old-revision","bundle_hash":"old-web-hash","protocol":3,"gateway":{"enabled":false,"registered":false}}`

func TestRunbookReadiness(t *testing.T) {
	expected := readiness.Expected{Instance: "runbook-instance", Version: "0.21.3", Revision: "old-revision", WebHash: "old-web-hash"}
	if err := readiness.Verify(strings.NewReader(upstreamReady), expected); err == nil {
		t.Fatal("normal readiness must not accept identity-free upstream evidence")
	}
	for _, tt := range []struct {
		name, ready, health string
		valid               bool
	}{
		{"upstream", upstreamReady, upstreamHealth, true},
		{"not-ready", strings.Replace(upstreamReady, `"status":"ready"`, `"status":"unavailable"`, 1), upstreamHealth, false},
		{"inventory-error", strings.Replace(upstreamReady, `"state":"ready"`, `"state":"error"`, 1), upstreamHealth, false},
		{"null-inventory", `{"status":"ready","inventory":null}`, upstreamHealth, false},
		{"partial-identity", `{"status":"ready","inventory":{"state":"ready"},"instance":"foreign"}`, upstreamHealth, false},
		{"wrong-ready-protocol", `{"status":"ready","inventory":{"state":"ready"},"protocol":99}`, upstreamHealth, false},
		{"duplicate-ready", `{"status":"ready","status":"unavailable","inventory":{"state":"ready"}}`, upstreamHealth, false},
		{"case-alias", `{"status":"ready","STATUS":"ready","inventory":{"state":"ready"}}`, upstreamHealth, false},
		{"health-degraded", upstreamReady, strings.Replace(upstreamHealth, `"readiness":"ready"`, `"readiness":"degraded"`, 1), false},
		{"health-inventory-error", upstreamReady, strings.Replace(upstreamHealth, `"state":"ready"`, `"state":"error"`, 1), false},
		{"health-not-ok", upstreamReady, strings.Replace(upstreamHealth, `"status":"ok"`, `"status":"ready"`, 1), false},
		{"wrong-instance", upstreamReady, strings.ReplaceAll(upstreamHealth, "runbook-instance", "foreign"), false},
		{"wrong-version", upstreamReady, strings.ReplaceAll(upstreamHealth, "0.21.3", "0.21.4"), false},
		{"wrong-revision", upstreamReady, strings.ReplaceAll(upstreamHealth, "old-revision", "foreign"), false},
		{"wrong-web", upstreamReady, strings.ReplaceAll(upstreamHealth, "old-web-hash", "foreign"), false},
		{"missing-instance", upstreamReady, strings.ReplaceAll(upstreamHealth, `"instance":"runbook-instance",`, ""), false},
		{"missing-protocol", upstreamReady, strings.ReplaceAll(upstreamHealth, `"protocol":3,`, ""), false},
		{"wrong-protocol", upstreamReady, strings.ReplaceAll(upstreamHealth, `"protocol":3`, `"protocol":99`), false},
		{"gateway-enabled", upstreamReady, strings.ReplaceAll(upstreamHealth, `"enabled":false`, `"enabled":true`), false},
		{"gateway-registered", upstreamReady, strings.ReplaceAll(upstreamHealth, `"registered":false`, `"registered":true`), false},
		{"null-health", upstreamReady, "null", false},
	} {
		t.Run(tt.name, func(t *testing.T) {
			var out bytes.Buffer
			err := RunTailscalePreflight([]string{"runbook-readiness", expected.Instance, expected.Version, expected.Revision, expected.WebHash}, strings.NewReader(`{"ready":`+tt.ready+`,"health":`+tt.health+`}`), &out)
			if (err == nil) != tt.valid {
				t.Fatalf("valid=%v, error=%v", tt.valid, err)
			}
			if !tt.valid {
				if out.Len() != 0 {
					t.Fatal("failed evidence produced a receipt")
				}
				return
			}
			if err := readiness.Verify(bytes.NewReader(out.Bytes()), expected); err != nil {
				t.Fatalf("receipt is not strictly verifiable: %v", err)
			}
			var receipt map[string]any
			if err := json.Unmarshal(out.Bytes(), &receipt); err != nil || len(receipt) != 7 {
				t.Fatal("receipt did not retain only canonical readiness fields")
			}
		})
	}
}

func TestRunbookReadinessEnvelopeBounds(t *testing.T) {
	valid := `{"ready":` + upstreamReady + `,"health":` + upstreamHealth + `}`
	for _, input := range []string{
		valid + `{}`,
		strings.Repeat(" ", 128*1024) + valid,
		`{"ready":` + upstreamReady + `,"health":` + upstreamHealth + `,"health":null}`,
		`{"ready":` + upstreamReady + `,"health":` + upstreamHealth + `,"extra":true}`,
		`{"ready":null,"health":null}`,
	} {
		var out bytes.Buffer
		if err := RunTailscalePreflight([]string{"runbook-readiness", "runbook-instance", "", "", ""}, strings.NewReader(input), &out); err == nil || out.Len() != 0 {
			t.Fatal("invalid envelope accepted")
		}
	}
}
