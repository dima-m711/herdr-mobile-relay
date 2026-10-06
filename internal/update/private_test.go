package update

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/0cv/herdr-mobile-relay/internal/setuphelper"
)

func privateJobFixture(t *testing.T) Job {
	t.Helper()
	dir := t.TempDir()
	if err := os.Chmod(dir, 0700); err != nil {
		t.Fatal(err)
	}
	herdr := filepath.Join(dir, "herdr")
	if err := os.WriteFile(herdr, []byte("#!/bin/sh\nexit 0\n"), 0700); err != nil {
		t.Fatal(err)
	}
	env := filepath.Join(dir, "relay.env")
	root := filepath.Join(dir, "releases")
	instance := strings.Repeat("a", 32)
	text := fmt.Sprintf("HERDR_CONNECTION_MODE=tailscale\nHERDR_RELAY_SERVICE_NAME=%s\nHERDR_RELEASE_ROOT=%q\nHERDR_BIN=%q\nHERDR_RELAY_INSTANCE_ID=%s\n", setuphelper.TailscaleServiceName(runtime.GOOS), root, herdr, instance)
	if err := os.WriteFile(env, []byte(text), 0600); err != nil {
		t.Fatal(err)
	}
	state := setuphelper.TailscaleSetupState{Schema: 1, Owner: "herdr-mobile-relay-tailscale-v1", Phase: "verified", Hostname: "fixture.tailtest.ts.net", HTTPSPort: 8443, RelayPort: 8375, Environment: env, Unit: filepath.Join(dir, setuphelper.TailscaleServiceFile(runtime.GOOS)), Socket: filepath.Join(dir, "herdr.sock"), Instance: instance, RecoveryDirectory: filepath.Join(dir, "recovery"), RouteOwnership: "adopted", UnrelatedDigest: strings.Repeat("a", 64)}
	data, err := json.Marshal(state)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "tailscale-setup.json"), data, 0600); err != nil {
		t.Fatal(err)
	}
	return Job{ConnectionMode: "tailscale", Environment: env, ReleaseRoot: root, HerdrBin: herdr, TargetVersion: "9.9.9", TargetRevision: strings.Repeat("b", 40), StatePath: filepath.Join(dir, "update-state.json"), HealthURL: "http://127.0.0.1:8375/healthz"}
}

func TestPrivateUpdateJobPolicy(t *testing.T) {
	job := privateJobFixture(t)
	if err := validateJob(job); err != nil {
		t.Fatal(err)
	}
	for _, change := range []func(*Job){
		func(j *Job) { j.DeployAppFirst = true; j.ExpectedAppOrigin = "https://public.example.test" },
		func(j *Job) { j.ConnectionMode = ""; j.Environment = "" },
		func(j *Job) { j.HealthURL = "http://127.0.0.1:8376/healthz" },
		func(j *Job) { j.Environment = filepath.Join(filepath.Dir(j.Environment), "foreign.env") },
		func(j *Job) { j.ReleaseRoot = filepath.Join(j.ReleaseRoot, "foreign") },
	} {
		candidate := job
		change(&candidate)
		if err := validateJob(candidate); err == nil {
			t.Fatal("unsafe private update job accepted")
		}
	}
}

func TestPrivateWorkerRejectsLegacyCandidateBeforeInstall(t *testing.T) {
	job := privateJobFixture(t)
	path := filepath.Join(filepath.Dir(job.StatePath), "job.json")
	if err := writeJSONAtomic(path, job); err != nil {
		t.Fatal(err)
	}
	worker := Worker{
		Prepare: func(context.Context, Job) (stagedRelease, error) { return stagedRelease{Root: t.TempDir()}, nil },
		Install: func(context.Context, Job) error { t.Fatal("incompatible candidate reached install"); return nil },
		Deploy: func(context.Context, Job, stagedRelease) error {
			t.Fatal("private update reached app deployment")
			return nil
		},
	}
	if err := worker.Run(context.Background(), path); err == nil {
		t.Fatal("legacy bundle accepted")
	}
}

func TestPrivatePluginInvocationPinsContext(t *testing.T) {
	job := privateJobFixture(t)
	record := filepath.Join(filepath.Dir(job.StatePath), "invocation")
	script := fmt.Sprintf("#!/bin/sh\nprintf '%%s\\n' \"$HERDR_RELAY_ENV\" \"$HERDR_PLUGIN_CONFIG_DIR\" \"$HERDR_RELEASE_ROOT\" \"$HERDR_CONNECTION_MODE\" \"$HERDR_RELAY_SERVICE_NAME\" \"$HERDR_RELEASE_REPOSITORY\" \"$HERDR_UPDATE_EXPECTED_REVISION\" > %q\n", record)
	if err := os.WriteFile(job.HerdrBin, []byte(script), 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("HERDR_RELAY_ENV", "/foreign/env")
	t.Setenv("HERDR_RELAY_SERVICE_NAME", "foreign.service")
	if err := installPlugin(context.Background(), job); err != nil {
		t.Fatal(err)
	}
	result, err := os.ReadFile(record)
	if err != nil {
		t.Fatal(err)
	}
	want := strings.Join([]string{job.Environment, filepath.Dir(job.Environment), job.ReleaseRoot, "tailscale", setuphelper.TailscaleServiceName(runtime.GOOS), "dima-m711/herdr-mobile-relay", job.TargetRevision, ""}, "\n")
	if string(result) != want {
		t.Fatal("private plugin context was not pinned")
	}
}

func TestPrivateManagerRefusesAppFirstBeforeScheduling(t *testing.T) {
	manager := NewManager(t.TempDir(), t.TempDir(), "/unavailable", "1.2.3", strings.Repeat("a", 40), "http://127.0.0.1:8375/healthz", "tailscale")
	if _, _, err := manager.Schedule(context.Background(), "9.9.9", strings.Repeat("b", 40), true, "https://public.example.test"); err == nil || !strings.Contains(err.Error(), "Cloudflare") {
		t.Fatal("private manager permitted app-first deployment")
	}
}
