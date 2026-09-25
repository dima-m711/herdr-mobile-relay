package setuphelper

import (
	"bytes"
	"strings"
	"testing"
)

func TestTailscaleHostname(t *testing.T) {
	for _, tc := range []struct{ name, input, want string }{
		{"running", `{"BackendState":"Running","Self":{"DNSName":"minibox.tailtest.ts.net."},"Peer":{"ignored":"private inventory"}}`, "minibox.tailtest.ts.net"},
		{"logged out", `{"BackendState":"NeedsLogin","Self":{"DNSName":"minibox.tailtest.ts.net."}}`, ""},
		{"no self", `{"BackendState":"Running"}`, ""},
		{"empty hostname", `{"BackendState":"Running","Self":{"DNSName":""}}`, ""},
		{"wrong schema", `{"BackendState":true,"Self":[]}`, ""},
		{"wrong domain", `{"BackendState":"Running","Self":{"DNSName":"minibox.example.com"}}`, ""},
		{"shell injection", `{"BackendState":"Running","Self":{"DNSName":"$(id).tailtest.ts.net"}}`, ""},
		{"terminal escape", `{"BackendState":"Running","Self":{"DNSName":"mini\u001b.tailtest.ts.net"}}`, ""},
		{"null", `null`, ""},
		{"trailing object", `{} {}`, ""},
		{"oversized", strings.Repeat(" ", (1<<20)+1), ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, err := TailscaleHostname(strings.NewReader(tc.input))
			if tc.want == "" {
				if err == nil {
					t.Fatalf("expected refusal, got %q", got)
				}
				return
			}
			if err != nil || got != tc.want {
				t.Fatalf("got %q, %v; want %q", got, err, tc.want)
			}
		})
	}
}

const privateServe = `{"TCP":{"8443":{"HTTPS":true}},"Web":{"minibox.tailtest.ts.net:8443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8375"}}}}}`

func TestInspectTailscaleServe(t *testing.T) {
	for _, tc := range []struct{ name, input, want string }{
		{"empty", `{}`, "absent"},
		{"matching", privateServe, "matching"},
		{"explicit no funnel", strings.TrimSuffix(privateServe, "}") + `,"AllowFunnel":{"minibox.tailtest.ts.net:8443":false}}`, "matching"},
		{"funnel", strings.TrimSuffix(privateServe, "}") + `,"AllowFunnel":{"minibox.tailtest.ts.net:8443":true}}`, ""},
		{"unrelated funnel", strings.TrimSuffix(privateServe, "}") + `,"AllowFunnel":{"other.tailtest.ts.net:443":true}}`, "matching"},
		{"tcp forward", `{"TCP":{"8443":{"TCPForward":"127.0.0.1:1234"}}}`, ""},
		{"wrong proxy", strings.ReplaceAll(privateServe, ":8375", ":1234"), ""},
		{"other handler", strings.ReplaceAll(privateServe, `"Handlers":{`, `"Handlers":{"/extra":{"Text":"another app"},`), ""},
		{"other hostname same port", strings.ReplaceAll(privateServe, "minibox.", "other."), ""},
		{"foreground", `{"Foreground":{"session":` + privateServe + `}}`, ""},
		{"nested foreground", `{"Foreground":{"session":{"Foreground":{"nested":{}}}}}`, ""},
		{"unrelated foreground", `{"Foreground":{"session":{"TCP":{"443":{"HTTPS":true}}}}}`, "absent"},
		{"unknown schema", `{"NewServeSchema":{}}`, ""},
		{"virtual service review required", `{"Services":{"svc:other":{"Tun":true}}}`, ""},
		{"foreground funnel only", `{"Foreground":{"session":{"AllowFunnel":{"minibox.tailtest.ts.net:8443":true}}}}`, ""},
		{"oversized serve", strings.Repeat(" ", (1<<20)+1), ""},
		{"unknown handler", strings.ReplaceAll(privateServe, `"HTTPS":true`, `"HTTPS":true,"NewForward":true`), ""},
		{"null root", `null`, ""},
		{"null funnel", `{"AllowFunnel":{"minibox.tailtest.ts.net:8443":null}}`, ""},
		{"null handler", `{"TCP":{"8443":null}}`, ""},
		{"null web", `{"Web":{"minibox.tailtest.ts.net:8443":null}}`, ""},
		{"duplicate keys", `{"AllowFunnel":{"minibox.tailtest.ts.net:8443":true},"AllowFunnel":{}}`, ""},
		{"case aliases", `{"AllowFunnel":{"minibox.tailtest.ts.net:8443":true},"allowfunnel":{}}`, ""},
		{"malformed unrelated endpoint", `{"Web":{"oops":{}}}`, ""},
		{"trailing input", privateServe + ` {}`, ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, err := InspectTailscaleServe(strings.NewReader(tc.input), "minibox.tailtest.ts.net", 8443, 8375)
			if tc.want == "" {
				if err == nil {
					t.Fatalf("expected refusal, got %+v", got)
				}
				return
			}
			if err != nil || got.State != tc.want {
				t.Fatalf("got %+v, %v; want %s", got, err, tc.want)
			}
			if got.Origin != "https://minibox.tailtest.ts.net:8443" || got.Target != "http://127.0.0.1:8375" || len(got.UnrelatedDigest) != 64 {
				t.Fatalf("bad inspection: %+v", got)
			}
		})
	}
}

func TestTailscaleServeDigest(t *testing.T) {
	before := `{"TCP":{"443":{"HTTPS":true}},"Web":{"other.tailtest.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:9000"}}}}}`
	after := `{"TCP":{"443":{"HTTPS":true},"8443":{"HTTPS":true}},"Web":{"other.tailtest.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:9000"}}},"minibox.tailtest.ts.net:8443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8375"}}}}}`
	inspect := func(raw string) string {
		t.Helper()
		got, err := InspectTailscaleServe(strings.NewReader(raw), "minibox.tailtest.ts.net", 8443, 8375)
		if err != nil {
			t.Fatal(err)
		}
		return got.UnrelatedDigest
	}
	if inspect(before) != inspect(after) {
		t.Fatal("own endpoint changed unrelated digest")
	}
	if inspect(before) == inspect(strings.ReplaceAll(before, "9000", "9001")) {
		t.Fatal("other route change was hidden")
	}
}

func TestRunTailscaleInspection(t *testing.T) {
	for _, tc := range []struct {
		name        string
		args        []string
		input, want string
		fail        bool
	}{
		{"hostname", []string{"hostname"}, `{"BackendState":"Running","Self":{"DNSName":"mini.tailtest.ts.net."}}`, "mini.tailtest.ts.net\n", false},
		{"serve", []string{"serve", "minibox.tailtest.ts.net", "8443", "8375"}, privateServe, "matching\thttps://minibox.tailtest.ts.net:8443\thttp://127.0.0.1:8375\t", false},
		{"no arguments", nil, `{}`, "", true},
		{"extra arguments", []string{"hostname", "extra"}, `{}`, "", true},
		{"invalid port", []string{"serve", "minibox.tailtest.ts.net", "$(id)", "8375"}, privateServe, "", true},
		{"bad JSON", []string{"hostname"}, "private-secret-not-json", "", true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var output bytes.Buffer
			err := RunTailscaleInspection(tc.args, strings.NewReader(tc.input), &output)
			if (err != nil) != tc.fail {
				t.Fatalf("error = %v", err)
			}
			if tc.fail && output.Len() != 0 {
				t.Fatal("failed command emitted output")
			}
			if !tc.fail && !strings.HasPrefix(output.String(), tc.want) {
				t.Fatalf("unexpected output %q", output.String())
			}
			if err != nil && strings.Contains(err.Error(), "private-secret") {
				t.Fatal("error leaked input")
			}
		})
	}
}

func TestTailscaleServeArguments(t *testing.T) {
	for _, tc := range []struct {
		host        string
		port, local int
	}{
		{"$(id).tailtest.ts.net", 8443, 8375}, {"minibox.example.test", 8443, 8375},
		{"minibox.tailtest.ts.net", 0, 8375}, {"minibox.tailtest.ts.net", 8443, 65536},
	} {
		if _, err := InspectTailscaleServe(strings.NewReader(`{}`), tc.host, tc.port, tc.local); err == nil {
			t.Fatal("unsafe arguments accepted")
		}
	}
}
