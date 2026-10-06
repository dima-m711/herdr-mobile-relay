package setuphelper

import (
	"bytes"
	"os"
	"path/filepath"
	"strconv"
	"testing"
)

func TestTailscalePlatformFiles(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "a file")
	if err := os.WriteFile(path, []byte("abc"), 0600); err != nil {
		t.Fatal(err)
	}
	var output bytes.Buffer
	if err := RunTailscalePlatform([]string{"hash", path}, &output); err != nil {
		t.Fatal(err)
	}
	if output.String() != "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad\n" {
		t.Fatal("unexpected hash")
	}
	link := filepath.Join(dir, "link")
	if err := os.Symlink(path, link); err != nil {
		t.Fatal(err)
	}
	output.Reset()
	if err := RunTailscalePlatform([]string{"realpath", link}, &output); err != nil {
		t.Fatal(err)
	}
	if output.String() != path+"\n" {
		t.Fatal("wrong canonical path")
	}
	if err := RunTailscalePlatform([]string{"realpath", filepath.Join(dir, "missing")}, &output); err == nil {
		t.Fatal("missing path accepted")
	}
	if err := RunTailscalePlatform([]string{"sync", path}, &output); err != nil {
		t.Fatal(err)
	}
}

func TestTailscalePlatformLockIdentity(t *testing.T) {
	dir := t.TempDir()
	if err := os.Chmod(dir, 0700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, ".setup.lock")
	file, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	args := []string{"lock-fd", strconv.Itoa(int(file.Fd())), path}
	if err := RunTailscalePlatform(args, &bytes.Buffer{}); err != nil {
		t.Fatal(err)
	}
	other, err := os.OpenFile(path, os.O_RDWR, 0600)
	if err != nil {
		t.Fatal(err)
	}
	defer other.Close()
	if err := RunTailscalePlatform([]string{"lock-fd", strconv.Itoa(int(other.Fd())), path}, &bytes.Buffer{}); err == nil {
		t.Fatal("competing lock accepted")
	}
	if err := os.Rename(path, path+".old"); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, nil, 0600); err != nil {
		t.Fatal(err)
	}
	if err := RunTailscalePlatform(args, &bytes.Buffer{}); err == nil {
		t.Fatal("replaced lock accepted")
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(path+".old", path); err != nil {
		t.Fatal(err)
	}
	if err := RunTailscalePlatform(args, &bytes.Buffer{}); err == nil {
		t.Fatal("linked lock accepted")
	}
}
