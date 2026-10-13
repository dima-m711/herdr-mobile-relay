package setuphelper

import (
	"os"
	"path/filepath"
	"testing"
)

func TestReleaseRecoveryIsDataBoundToManagedRoot(t *testing.T) {
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	recovery := filepath.Join(root, "recovery")
	if err := os.Mkdir(recovery, 0700); err != nil {
		t.Fatal(err)
	}
	previous := filepath.Join(root, "releases", "old")
	candidate := filepath.Join(root, "releases", "new")
	for _, dir := range []string{previous, candidate} {
		if err := os.MkdirAll(dir, 0700); err != nil {
			t.Fatal(err)
		}
	}
	before := filepath.Join(recovery, "previous-release")
	after := filepath.Join(recovery, "candidate-release")
	if err := os.WriteFile(before, []byte(previous+"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(after, []byte(candidate+"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	old, next, err := ReadTailscaleReleaseRecovery(recovery, root)
	if err != nil || old != previous || next != candidate {
		t.Fatal("valid release recovery rejected", err)
	}
	for _, invalid := range []string{root, previous + "\nextra", filepath.Join(root, "releases", "..", "foreign"), "$(touch /tmp/must-not-run)"} {
		if err := os.WriteFile(before, []byte(invalid), 0600); err != nil {
			t.Fatal(err)
		}
		if _, _, err := ReadTailscaleReleaseRecovery(recovery, root); err == nil {
			t.Fatal("invalid release recovery accepted")
		}
	}
	if err := os.WriteFile(before, []byte(previous+"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(before, 0644); err != nil {
		t.Fatal(err)
	}
	if _, _, err := ReadTailscaleReleaseRecovery(recovery, root); err == nil {
		t.Fatal("public recovery metadata accepted")
	}
	if err := os.Chmod(before, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(candidate); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(previous, candidate); err != nil {
		t.Fatal(err)
	}
	if _, _, err := ReadTailscaleReleaseRecovery(recovery, root); err == nil {
		t.Fatal("redirected release accepted")
	}
}
