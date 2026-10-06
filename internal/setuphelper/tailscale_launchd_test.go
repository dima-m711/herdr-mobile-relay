package setuphelper

import (
	"fmt"
	"os"
	"strings"
	"testing"
)

func TestPrivateLaunchdSnapshot(t *testing.T) {
	t.Setenv("HOME", "/Users/test user")
	root := "/Users/test user/.local/share/herdr-mobile-relay/current"
	env := "/Users/test user/.config/herdr/plugins/config/herdr-mobile-relay.events/relay.env"
	unit := "/Users/test user/Library/LaunchAgents/com.herdr-mobile-relay.tailscale.plist"
	label := "com.herdr-mobile-relay.tailscale"
	good := fmt.Sprintf("gui/%d/%s = {\n\tpath = %s\n\tprogram = /bin/bash\n\tworking directory = %s\n\targuments = {\n\t\t/bin/bash\n\t\t%s/relay/tailscale-service.sh\n\t}\n\tenvironment = {\n\t\tHERDR_RELAY_ENV => %s\n\t\tPATH => /Users/test user/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin\n\t\tXPC_SERVICE_NAME => %s\n\t}\n\tpid = 123\n}\n", os.Getuid(), label, unit, root, root, env, label)
	if err := verifyLaunchdJob(good, unit, root, env, label); err != nil {
		t.Fatal(err)
	}
	for _, bad := range []string{
		"", strings.Replace(good, "program = /bin/bash", "program = /bin/sh", 1),
		strings.Replace(good, "\tpath = ", "\tpath = /other", 1),
		strings.Replace(good, "HERDR_RELAY_ENV => ", "HERDR_RELAY_ENV => /other", 1),
		strings.Replace(good, "XPC_SERVICE_NAME => ", "HERDR_GATEWAY_URL => ", 1),
		strings.Replace(good, "\targuments = {", "\targuments = {\n\t\t--extra", 1),
		strings.Replace(good, "\tpid = 123", "\tpath = duplicate\n\tpid = 123", 1),
	} {
		if verifyLaunchdJob(bad, unit, root, env, label) == nil {
			t.Fatal("drifted cached job accepted")
		}
	}
	if pid, err := launchdField(good, "pid"); err != nil || pid != "123" {
		t.Fatalf("PID: %q %v", pid, err)
	}
	if _, err := launchdField(good+"\tpid = 456\n", "pid"); err == nil {
		t.Fatal("duplicate PID accepted")
	}
}

func TestPrivateLaunchdJobList(t *testing.T) {
	for _, tc := range []struct {
		data string
		want bool
	}{
		{"PID\tStatus\tLabel\n", false},
		{"PID\tStatus\tLabel\n123\t0\tcom.private\n", true},
		{"PID\tStatus\tLabel\n-\t1\tcom.private\n", true},
		{"PID\tStatus\tLabel\n123\t0\tcom.other\n", false},
	} {
		got, err := launchdLoaded(tc.data, "com.private")
		if err != nil || got != tc.want {
			t.Fatalf("%v %v", got, err)
		}
	}
	for _, data := range []string{"", "unavailable\n", "PID\tStatus\tLabel\nmalformed\n", "PID\tStatus\tLabel\n123\t0\tcom.private\n456\t0\tcom.private\n"} {
		if _, err := launchdLoaded(data, "com.private"); err == nil {
			t.Fatal("ambiguous job list accepted")
		}
	}
}

func TestPrivateLaunchdDisabled(t *testing.T) {
	for _, tc := range []struct{ input, want string }{
		{"disabled services = {\n}\n", "false"},
		{"disabled services = {\n\t\"com.example\" => true\n}\n", "false"},
		{"disabled services = {\n\t\"com.private\" => true\n}\n", "true"},
		{"disabled services = {\n\t\"com.private\" => false\n}\n", "false"},
	} {
		value, err := launchdDisabled(tc.input, "com.private")
		if err != nil || value != tc.want {
			t.Fatalf("%q %v", value, err)
		}
	}
	for _, bad := range []string{"", "garbage", "disabled services = {\n\t\"com.private\" => maybe\n}\n", "disabled services = {\n\t\"com.private\" => true\n\t\"com.private\" => false\n}\n"} {
		if _, err := launchdDisabled(bad, "com.private"); err == nil {
			t.Fatal("malformed disabled snapshot accepted")
		}
	}
}
