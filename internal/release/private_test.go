package release

import (
	"os"
	"path/filepath"
	"testing"
)

func TestPrivateReleaseContractRequiresCompleteForkBundle(t *testing.T) {
	root := testRelease(t)
	legacy, err := Build(root, "1.2.3", "fixture", "linux/amd64")
	if err != nil {
		t.Fatal(err)
	}
	if legacy.Repository != Repository || legacy.TailscaleSetup != 0 {
		t.Fatal("incorrect release authority or implicit private capability")
	}
	if err := ValidateTailscaleRelease(legacy); err == nil {
		t.Fatal("legacy bundle accepted for private cutover")
	}
	if _, err := Verify(root, "linux/amd64"); err != nil {
		t.Fatal("legacy verification changed", err)
	}
	for _, helper := range tailscaleHelpers {
		if err := os.WriteFile(filepath.Join(root, filepath.FromSlash(helper)), []byte("#!/bin/sh\n"), 0755); err != nil {
			t.Fatal(err)
		}
	}
	manifest, err := Build(root, "1.2.3", "fixture", "linux/amd64")
	if err != nil {
		t.Fatal(err)
	}
	if err := ValidateTailscaleRelease(manifest); err != nil {
		t.Fatal(err)
	}
	if _, err := Verify(root, "linux/amd64"); err != nil {
		t.Fatal(err)
	}
	for _, mutate := range []func(*Manifest){
		func(m *Manifest) { m.Repository = "0cv/herdr-mobile-relay" },
		func(m *Manifest) { m.TailscaleSetup = 2 },
		func(m *Manifest) { m.Target = "darwin/arm64" },
		func(m *Manifest) { m.Files["relay/tailscale-update.sh"] = "" },
	} {
		candidate, err := Load(root)
		if err != nil {
			t.Fatal(err)
		}
		mutate(&candidate)
		if err := ValidateTailscaleRelease(candidate); err == nil {
			t.Fatal("incompatible private bundle accepted")
		}
	}
	if err := os.Remove(filepath.Join(root, "relay", "tailscale-update.sh")); err != nil {
		t.Fatal(err)
	}
	// A missing advertised helper fails normal offline verification too.
	if _, err := Verify(root, "linux/amd64"); err == nil {
		t.Fatal("missing advertised helper accepted")
	}
}
