package setuphelper

import (
	"encoding/binary"
	"strings"
	"testing"
)

func TestDarwinListenerOutput(t *testing.T) {
	good := "p123\x00u501\x00\nf9\x00tIPv4\x00PTCP\x00n127.0.0.1:8375\x00TST=LISTEN\x00\n"
	for _, tc := range []struct {
		output string
		valid  bool
	}{
		{good, true}, {"", false},
		{"p123\x00u502\x00\nf9\x00tIPv4\x00PTCP\x00n127.0.0.1:8375\x00TST=LISTEN\x00\n", false},
		{"p124\x00u501\x00\nf9\x00tIPv4\x00PTCP\x00n127.0.0.1:8375\x00TST=LISTEN\x00\n", false},
		{"p123\x00u501\x00\nf9\x00tIPv4\x00PTCP\x00n*:8375\x00TST=LISTEN\x00\n", false},
		{"p123\x00u501\x00\nf9\x00tIPv4\x00PTCP\x00n127.0.0.1:8376\x00TST=LISTEN\x00\n", false},
		{good + "p124\x00u501\x00\n", false},
	} {
		if err := verifyDarwinListenerOutput([]byte(tc.output), 123, 501, 8375); (err == nil) != tc.valid {
			t.Fatalf("valid=%v: %v", tc.valid, err)
		}
	}
}

func TestDarwinExecutableVnode(t *testing.T) {
	good := "p123\x00u501\x00\nftxt\x00tREG\x00D0x10\x00i1234\x00n/Users/example/relay\x00\n"
	if err := verifyDarwinExecutableFileOutput([]byte(good), 123, 501, "/Users/example/relay", 16, 1234); err != nil {
		t.Fatal(err)
	}
	for _, bad := range []string{"", strings.Replace(good, "i1234", "i5678", 1), strings.Replace(good, "D0x10", "D0x11", 1), strings.Replace(good, "u501", "u502", 1), strings.Replace(good, "n/Users/example/relay", "n/Users/example/old", 1), strings.Replace(good, "ftxt", "f9", 1)} {
		if verifyDarwinExecutableFileOutput([]byte(bad), 123, 501, "/Users/example/relay", 16, 1234) == nil {
			t.Fatal("foreign or old executable vnode accepted")
		}
	}
}

func TestDarwinExecutableOutput(t *testing.T) {
	data := make([]byte, 4)
	binary.LittleEndian.PutUint32(data, 2)
	data = append(data, []byte("/Users/example/relay\x00\x00relay\x00serve\x00")...)
	if path, err := darwinExecutableOutput(data); err != nil || path != "/Users/example/relay" {
		t.Fatalf("%q %v", path, err)
	}
	for _, bad := range [][]byte{nil, {1, 0, 0, 0}, {0, 0, 0, 0, '/', 'x', 0}, {1, 0, 0, 0, 'x', 0}} {
		if _, err := darwinExecutableOutput(bad); err == nil {
			t.Fatal("malformed executable accepted")
		}
	}
}
