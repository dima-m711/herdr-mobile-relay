package setuphelper

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func tailscaleStateFixture(t *testing.T) (string, TailscaleSetupState) {
	t.Helper()
	dir, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	return filepath.Join(dir, "tailscale-setup.json"), TailscaleSetupState{
		Schema: 1, Owner: "herdr-mobile-relay-tailscale-v1", Phase: "prepared",
		Hostname: "mini.tailtest.ts.net", HTTPSPort: 8443, RelayPort: 8375,
		Environment: filepath.Join(dir, "relay.env"), Unit: filepath.Join(dir, "herdr-mobile-relay-tailscale.service"),
		Socket: filepath.Join(dir, "herdr.sock"), Instance: "fixture-instance",
		RecoveryDirectory: filepath.Join(dir, "recovery"), RouteOwnership: "absent",
		UnrelatedDigest: strings.Repeat("a", 64),
	}
}

func TestTailscaleStateLifecycle(t *testing.T) {
	path, state := tailscaleStateFixture(t)
	if err := CreateTailscaleState(path, state); err != nil {
		t.Fatal(err)
	}
	info, _ := os.Stat(path)
	if info.Mode().Perm() != 0o600 {
		t.Fatal("state is not private")
	}
	if err := CreateTailscaleState(path, state); err == nil {
		t.Fatal("existing state overwritten")
	}
	for _, step := range []struct{ from, to, route string }{
		{"prepared", "local-ready", ""}, {"local-ready", "route-pending", ""},
		{"route-pending", "route-ready", "created"}, {"route-ready", "verified", ""},
		{"verified", "teardown-pending", ""}, {"teardown-pending", "removed", ""},
	} {
		if err := AdvanceTailscaleState(path, step.from, step.to, step.route); err != nil {
			t.Fatal(err)
		}
	}
	got, err := ReadTailscaleState(path)
	if err != nil || got.Phase != "removed" || got.RouteOwnership != "created" {
		t.Fatalf("state=%+v, err=%v", got, err)
	}
	if got.Instance != state.Instance || got.Environment != state.Environment || got.UnrelatedDigest != state.UnrelatedDigest {
		t.Fatal("immutable identity changed")
	}
	if err := AdvanceTailscaleState(path, "removed", "prepared", ""); err == nil {
		t.Fatal("removed state reset implicitly")
	}
}

func TestTailscaleStateConcurrentCreate(t *testing.T) {
	path, state := tailscaleStateFixture(t)
	results := make(chan error, 2)
	for _, instance := range []string{"first", "second"} {
		candidate := state
		candidate.Instance = instance
		go func() { results <- CreateTailscaleState(path, candidate) }()
	}
	successes := 0
	for range 2 {
		if <-results == nil {
			successes++
		}
	}
	if successes != 1 {
		t.Fatalf("successful publications = %d, want one", successes)
	}
	got, err := ReadTailscaleState(path)
	if err != nil || (got.Instance != "first" && got.Instance != "second") {
		t.Fatalf("state = %+v, err = %v", got, err)
	}
	entries, err := os.ReadDir(filepath.Dir(path))
	if err != nil || len(entries) != 1 {
		t.Fatal("temporary state files were not cleaned up")
	}
}

func TestTailscaleStateRefusesUnsafeUpdates(t *testing.T) {
	for _, tc := range []struct{ name, from, to, route string }{
		{"stale phase", "local-ready", "route-pending", ""},
		{"skipped verification", "prepared", "verified", ""},
		{"premature ownership", "prepared", "local-ready", "created"},
		{"unknown phase", "prepared", "unknown", ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			path, state := tailscaleStateFixture(t)
			if err := CreateTailscaleState(path, state); err != nil {
				t.Fatal(err)
			}
			before, _ := os.ReadFile(path)
			if err := AdvanceTailscaleState(path, tc.from, tc.to, tc.route); err == nil {
				t.Fatal("unsafe update accepted")
			}
			after, _ := os.ReadFile(path)
			if !bytes.Equal(before, after) {
				t.Fatal("refusal mutated state")
			}
		})
	}
}

func TestTailscaleStateAdoptionAndRecovery(t *testing.T) {
	path, state := tailscaleStateFixture(t)
	state.RouteOwnership = "adopted"
	if err := CreateTailscaleState(path, state); err != nil {
		t.Fatal(err)
	}
	for _, step := range [][2]string{{"prepared", "local-ready"}, {"local-ready", "route-pending"}} {
		if err := AdvanceTailscaleState(path, step[0], step[1], ""); err != nil {
			t.Fatal(err)
		}
	}
	if err := AdvanceTailscaleState(path, "route-pending", "route-ready", "created"); err == nil {
		t.Fatal("adopted route was claimed as created")
	}
	if err := AdvanceTailscaleState(path, "route-pending", "recovery", ""); err != nil {
		t.Fatal(err)
	}
	if err := AdvanceTailscaleState(path, "recovery", "verified", ""); err == nil {
		t.Fatal("uncertain recovery auto-verified")
	}
	got, err := ReadTailscaleState(path)
	if err != nil || got.RouteOwnership != "adopted" {
		t.Fatal("adoption lost during recovery")
	}
}

func TestTailscaleStateRejectsUnsafeStorage(t *testing.T) {
	for _, kind := range []string{"mode", "symlink", "hardlink", "parent-mode", "parent-symlink", "unknown-field", "duplicate-field", "oversized"} {
		t.Run(kind, func(t *testing.T) {
			path, state := tailscaleStateFixture(t)
			if err := CreateTailscaleState(path, state); err != nil {
				t.Fatal(err)
			}
			switch kind {
			case "mode":
				if err := os.Chmod(path, 0o644); err != nil {
					t.Fatal(err)
				}
			case "symlink":
				if err := os.Rename(path, path+".real"); err != nil {
					t.Fatal(err)
				}
				if err := os.Symlink(path+".real", path); err != nil {
					t.Fatal(err)
				}
			case "hardlink":
				if err := os.Link(path, path+".alias"); err != nil {
					t.Fatal(err)
				}
			case "parent-mode":
				if err := os.Chmod(filepath.Dir(path), 0o755); err != nil {
					t.Fatal(err)
				}
			case "parent-symlink":
				alias := filepath.Join(t.TempDir(), "alias")
				if err := os.Symlink(filepath.Dir(path), alias); err != nil {
					t.Fatal(err)
				}
				path = filepath.Join(alias, filepath.Base(path))
			case "unknown-field", "duplicate-field", "oversized":
				raw, _ := os.ReadFile(path)
				if kind == "unknown-field" {
					raw = append(raw[:len(raw)-1], []byte(`,"private-secret":"must-not-echo"}`)...)
				}
				if kind == "duplicate-field" {
					raw = append(raw[:len(raw)-1], []byte(`,"schema":1}`)...)
				}
				if kind == "oversized" {
					raw = []byte(strings.Repeat(" ", 32769))
				}
				if err := os.WriteFile(path, raw, 0o600); err != nil {
					t.Fatal(err)
				}
			}
			_, err := ReadTailscaleState(path)
			if err == nil {
				t.Fatal("unsafe state accepted")
			}
			if strings.Contains(err.Error(), "must-not-echo") {
				t.Fatal("diagnostic leaked untrusted data")
			}
			if err := AdvanceTailscaleState(path, "prepared", "local-ready", ""); err == nil {
				t.Fatal("unsafe state replaced")
			}
		})
	}
}

func TestTailscaleStateValidatesIdentity(t *testing.T) {
	for _, mutate := range []func(*TailscaleSetupState){
		func(s *TailscaleSetupState) { s.Schema = 2 }, func(s *TailscaleSetupState) { s.Owner = "foreign" },
		func(s *TailscaleSetupState) { s.Hostname = "example.com" }, func(s *TailscaleSetupState) { s.HTTPSPort = 0 },
		func(s *TailscaleSetupState) { s.Socket = "relative" }, func(s *TailscaleSetupState) { s.Environment = "/tmp/x\nmalicious" },
		func(s *TailscaleSetupState) { s.Instance = "" }, func(s *TailscaleSetupState) { s.UnrelatedDigest = "invalid" },
		func(s *TailscaleSetupState) { s.Phase = "verified" }, func(s *TailscaleSetupState) { s.RouteOwnership = "created" },
	} {
		path, state := tailscaleStateFixture(t)
		mutate(&state)
		if err := CreateTailscaleState(path, state); err == nil {
			t.Fatal("invalid initial state accepted")
		}
		if _, err := os.Lstat(path); !os.IsNotExist(err) {
			t.Fatal("invalid state left a file")
		}
	}
}

func TestPrepareTailscaleStateArguments(t *testing.T) {
	path, state := tailscaleStateFixture(t)
	args := []string{"prepare", path, state.Hostname, "8443", "8375", state.Environment, state.Unit, state.Socket, state.Instance, state.RecoveryDirectory, state.UnrelatedDigest, state.RouteOwnership}
	if err := RunTailscaleState(args, strings.NewReader(""), &bytes.Buffer{}); err != nil {
		t.Fatal(err)
	}
	got, err := ReadTailscaleState(path)
	if err != nil || got != state {
		t.Fatalf("state = %+v, err = %v", got, err)
	}
}

func TestRunTailscaleState(t *testing.T) {
	path, state := tailscaleStateFixture(t)
	input, _ := json.Marshal(state)
	var output bytes.Buffer
	if err := RunTailscaleState([]string{"create", path}, bytes.NewReader(input), &output); err != nil {
		t.Fatal(err)
	}
	if output.Len() != 0 {
		t.Fatal("create must not echo state")
	}
	if err := RunTailscaleState([]string{"get", path, "hostname"}, strings.NewReader(""), &output); err != nil {
		t.Fatal(err)
	}
	if output.String() != "mini.tailtest.ts.net\n" {
		t.Fatal("wrong selected field")
	}
	if err := RunTailscaleState([]string{"advance", path, "prepared", "local-ready"}, strings.NewReader(""), &output); err != nil {
		t.Fatal(err)
	}
	for _, args := range [][]string{nil, {"get", path, "secret"}, {"advance", path, "local-ready", "verified"}} {
		if err := RunTailscaleState(args, strings.NewReader(""), &output); err == nil {
			t.Fatal("invalid operation accepted")
		}
	}
}
