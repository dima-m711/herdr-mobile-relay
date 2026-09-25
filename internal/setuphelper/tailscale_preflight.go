package setuphelper

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/0cv/herdr-mobile-relay/internal/herdr"
)

// RunTailscalePreflight performs bounded, non-mutating checks. It never prints
// Herdr inventory or underlying daemon diagnostics, nor executes a runbook.
func RunTailscalePreflight(args []string, input io.Reader, output io.Writer) error {
	if len(args) == 0 {
		return errors.New("missing Tailscale preflight operation")
	}
	switch args[0] {
	case "environment":
		if len(args) != 2 && len(args) != 3 {
			break
		}
		values, err := ReadTailscaleEnvironment(args[1])
		if err != nil {
			return err
		}
		if len(args) == 3 {
			_, err = fmt.Fprintln(output, values[args[2]])
		}
		return err
	case "managed-environment":
		if len(args) != 4 {
			break
		}
		state, err := ReadTailscaleState(args[2])
		if err != nil {
			return err
		}
		if state.Environment != args[1] || !safeStatePath(args[3]) {
			return errors.New("managed environment identity differs from setup state")
		}
		values, err := ReadTailscaleEnvironment(args[1])
		if err != nil {
			return err
		}
		for key, expected := range map[string]string{
			"HERDR_CONNECTION_MODE": "tailscale", "HERDR_RELAY_HOST": "127.0.0.1", "HERDR_TRANSPORT_FORCE_RELAY": "1", "HERDR_REACHABILITY_PORT_MAPPING": "0", "HERDR_RELAY_REARM_BOOTSTRAP": "0", "HERDR_GATEWAY_URL": "",
			"HERDR_RELAY_PORT": strconv.Itoa(state.RelayPort), "HERDR_SOCKET_PATH": state.Socket, "HERDR_RELAY_INSTANCE_ID": state.Instance, "HERDR_RELAY_SERVICE_NAME": filepath.Base(state.Unit), "HERDR_RELEASE_ROOT": args[3], "HERDR_WEB_ROOT": filepath.Join(args[3], "current", "web"),
		} {
			if value, exists := values[key]; !exists || value != expected {
				return errors.New("configuration no longer matches managed Tailscale policy and identity")
			}
		}
		if len(values["HERDR_RELAY_TOKEN"]) != 32 {
			return errors.New("invalid managed relay key")
		}
		if _, err := tailscalePort(values["HERDR_RELAY_PLUGIN_PORT"]); err != nil {
			return err
		}
		for key, expected := range map[string]string{"HERDR_RELAY_ENV": state.Environment, "HERDR_PLUGIN_CONFIG_DIR": filepath.Dir(state.Environment)} {
			if value := values[key]; value != "" && value != expected {
				return errors.New("custom managed configuration paths require review")
			}
		}
		return nil
	case "native-record":
		if len(args) != 4 {
			break
		}
		if err := privateStateDirectory(args[1]); err != nil {
			return err
		}
		data, err := readTailscaleOwnedFile(args[1], 16384, true)
		if err != nil {
			return err
		}
		fields := map[string]string{}
		for _, line := range strings.Split(strings.TrimSuffix(string(data), "\n"), "\n") {
			key, value, ok := strings.Cut(line, "=")
			if _, duplicate := fields[key]; !ok || duplicate {
				return errors.New("invalid native recovery record")
			}
			fields[key] = value
		}
		_, hasLegacy := fields["legacy_definition"]
		if !hasLegacy || !safeStatePath(args[2]) || !safeStatePath(args[3]) || len(fields) != 7 || fields["definition"] != args[2] || fields["environment"] != args[3] || fields["legacy_definition"] != "" || fields["legacy_active"] != "false" || fields["legacy_enabled"] != "false" || (fields["active"] != "true" && fields["active"] != "false") || (fields["enabled"] != "true" && fields["enabled"] != "false") {
			return errors.New("native recovery does not belong to this Tailscale service")
		}
		_, err = fmt.Fprintf(output, "%s\t%s\n", fields["active"], fields["enabled"])
		return err
	case "runbook":
		if len(args) != 3 {
			break
		}
		return RecognizeTailscaleRunbook(args[1], args[2])
	case "session":
		if len(args) != 3 {
			break
		}
		return probeTailscaleSession(args[1], args[2])
	case "ports":
		if len(args) != 3 {
			break
		}
		tcpPort, err := tailscalePort(args[1])
		if err != nil {
			return err
		}
		udpPort, err := tailscalePort(args[2])
		if err != nil {
			return err
		}
		listener, err := net.Listen("tcp4", fmt.Sprintf("127.0.0.1:%d", tcpPort))
		if err != nil {
			return errors.New("selected relay TCP port is unavailable")
		}
		defer listener.Close()
		packet, err := net.ListenPacket("udp4", fmt.Sprintf("127.0.0.1:%d", udpPort))
		if err != nil {
			return errors.New("selected relay UDP port is unavailable")
		}
		defer packet.Close()
		return nil
	case "listener":
		if len(args) != 3 && len(args) != 4 {
			break
		}
		executable := ""
		if len(args) == 4 {
			executable = args[3]
		}
		return verifyTailscaleListener(args[1], args[2], executable)
	case "gateway-disabled":
		if len(args) != 1 {
			break
		}
		data, err := tailscaleJSON(input)
		if err != nil {
			return err
		}
		var health struct {
			Gateway *struct {
				Enabled    *bool
				Registered *bool
			}
		}
		if json.Unmarshal(data, &health) != nil || health.Gateway == nil || health.Gateway.Enabled == nil || health.Gateway.Registered == nil || *health.Gateway.Enabled || *health.Gateway.Registered {
			return errors.New("relay gateway is active or its disabled state cannot be verified")
		}
		return nil
	}
	return errors.New("usage: tailscale-preflight environment FILE [KEY] | managed-environment FILE STATE RELEASE_ROOT | native-record FILE UNIT ENV | runbook UNIT LAUNCHER | session EXECUTABLE SOCKET | ports TCP UDP | listener PID PORT [EXECUTABLE] | gateway-disabled")
}

// Verify the unit's actual process owns the loopback listening socket. Merely
// finding the port in /proc/PID/net/tcp is insufficient: it lists the whole
// network namespace, so correlate its inode with the selected process's FDs.
func verifyTailscaleListener(rawPID, rawPort, executable string) error {
	pid, err := strconv.Atoi(rawPID)
	if runtime.GOOS != "linux" || err != nil || pid <= 0 || strconv.Itoa(pid) != rawPID {
		return errors.New("invalid Linux relay process identity")
	}
	port, err := tailscalePort(rawPort)
	if err != nil {
		return err
	}
	proc := "/proc/" + rawPID
	info, err := os.Stat(proc)
	if err != nil {
		return errors.New("relay service process is unavailable")
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || stat.Uid != uint32(os.Geteuid()) {
		return errors.New("relay service process belongs to another user")
	}
	if executable != "" {
		expected, err := filepath.EvalSymlinks(executable)
		if err != nil {
			return errors.New("expected relay executable is unavailable")
		}
		actual, err := os.Readlink(proc + "/exe")
		if err != nil || actual != expected {
			return errors.New("service is not running the selected relay executable")
		}
	}
	fds, err := os.ReadDir(proc + "/fd")
	if err != nil || len(fds) > 16384 {
		return errors.New("cannot inspect relay service descriptors")
	}
	inodes := map[string]bool{}
	for _, fd := range fds {
		target, err := os.Readlink(proc + "/fd/" + fd.Name())
		if err == nil && strings.HasPrefix(target, "socket:[") && strings.HasSuffix(target, "]") {
			inodes[strings.TrimSuffix(strings.TrimPrefix(target, "socket:["), "]")] = true
		}
	}
	file, err := os.Open(proc + "/net/tcp")
	if err != nil {
		return errors.New("cannot inspect relay TCP listener")
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, (1<<20)+1))
	if err != nil || len(data) > 1<<20 {
		return errors.New("relay listener inventory unreadable or too large")
	}
	address := fmt.Sprintf("0100007F:%04X", port)
	for _, line := range strings.Split(string(data), "\n") {
		fields := strings.Fields(line)
		if len(fields) > 9 && fields[1] == address && fields[3] == "0A" && inodes[fields[9]] {
			return nil
		}
	}
	return errors.New("selected service process does not own the expected loopback listener")
}

func tailscalePort(raw string) (int, error) {
	port, err := strconv.Atoi(raw)
	if err != nil || port < 1 || port > 65535 || strconv.Itoa(port) != raw {
		return 0, errors.New("invalid Tailscale setup port")
	}
	return port, nil
}

func probeTailscaleSession(executable, socket string) error {
	if !safeStatePath(executable) || !safeStatePath(socket) {
		return errors.New("Herdr executable and socket must be absolute normalized paths")
	}
	info, err := os.Stat(executable)
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0o111 == 0 {
		return errors.New("selected Herdr executable is unavailable")
	}
	info, err = os.Lstat(socket)
	if err != nil || info.Mode()&os.ModeSocket == 0 {
		return errors.New("selected Herdr socket is unavailable")
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || stat.Uid != uint32(os.Geteuid()) {
		return errors.New("selected Herdr socket belongs to another user")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if _, err := herdr.NewClient(executable, socket).GetInventory(ctx); err != nil {
		return errors.New("selected Herdr session did not provide a compatible inventory; start Herdr or resolve its protocol mismatch")
	}
	return nil
}

// ReadTailscaleEnvironment accepts generated static assignments, not arbitrary
// shell programs. Validate before any shell sourcing during adoption. Values
// are returned as data; diagnostics never include the credential-bearing input.
func ReadTailscaleEnvironment(path string) (map[string]string, error) {
	data, err := readTailscaleOwnedFile(path, 65536, true)
	if err != nil {
		return nil, err
	}
	values := map[string]string{}
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		line = strings.TrimPrefix(line, "export ")
		key, value, ok := strings.Cut(line, "=")
		if !ok || !staticEnvironmentKey(key) {
			return nil, errors.New("relay environment contains unsupported shell syntax or settings; review it before adoption")
		}
		if _, exists := values[key]; exists {
			return nil, errors.New("relay environment contains duplicate assignments")
		}
		// Whitespace after '=' ends an empty shell assignment; the following
		// word is a command, not its value. Never normalize that into data.
		if strings.TrimSpace(value) != value {
			return nil, errors.New("relay environment contains a command after an assignment")
		}
		if len(value) > 0 && (value[0] == '\'' || value[0] == '"') {
			quote := value[0]
			if len(value) < 2 || value[len(value)-1] != quote {
				return nil, errors.New("relay environment contains an unterminated value")
			}
			value = value[1 : len(value)-1]
			if strings.ContainsRune(value, rune(quote)) || (quote == '"' && strings.ContainsAny(value, "$`\\")) {
				return nil, errors.New("relay environment must contain literal values, not shell expansions")
			}
		} else if strings.IndexFunc(value, func(c rune) bool {
			return !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || strings.ContainsRune("_./:@%+,=-", c))
		}) >= 0 {
			return nil, errors.New("relay environment must contain static assignments only")
		}
		if strings.IndexFunc(value, func(c rune) bool { return c < 32 || c == 127 }) >= 0 {
			return nil, errors.New("relay environment contains control characters")
		}
		values[key] = value
	}
	return values, nil
}

func staticEnvironmentKey(key string) bool {
	if key == "HERDR_RELAY_SETUP_LOCK_FD" || key == "HERDR_RELAY_BIN" {
		return false
	}
	if !strings.HasPrefix(key, "HERDR_") && key != "GH_TOKEN" && key != "GITHUB_TOKEN" && key != "CLOUDFLARED_CONFIG" {
		return false
	}
	return strings.IndexFunc(key, func(c rune) bool { return !(c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_') }) < 0
}

func readTailscaleOwnedFile(path string, limit int, private bool) ([]byte, error) {
	info, err := os.Lstat(path)
	valid := func(info os.FileInfo) bool {
		if info == nil || !info.Mode().IsRegular() || info.Mode().Perm()&0o022 != 0 {
			return false
		}
		stat, ok := info.Sys().(*syscall.Stat_t)
		return ok && stat.Uid == uint32(os.Geteuid()) && stat.Nlink == 1 && (!private || privateStateFile(info))
	}
	if err != nil || !valid(info) {
		return nil, errors.New("setup input must be an owned regular file with safe permissions and no links")
	}
	file, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	if err != nil {
		return nil, errors.New("cannot read owned setup input")
	}
	defer file.Close()
	opened, err := file.Stat()
	if err != nil || !valid(opened) || !os.SameFile(info, opened) {
		return nil, errors.New("setup input changed while opening")
	}
	data, err := io.ReadAll(io.LimitReader(file, int64(limit+1)))
	if err != nil || len(data) > limit {
		return nil, errors.New("setup input unreadable or too large")
	}
	return data, nil
}

func RecognizeTailscaleRunbook(unit, launcher string) error {
	if unit == launcher {
		return errors.New("runbook unit and launcher must be distinct files")
	}
	for path, expected := range map[string]string{unit: tailscaleRunbookUnit, launcher: tailscaleRunbookLauncher} {
		data, err := readTailscaleOwnedFile(path, 16384, false)
		if err != nil {
			return err
		}
		if !bytes.Equal(data, []byte(expected)) {
			return errors.New("unrecognized Tailscale runbook definition; manual migration review required")
		}
	}
	return nil
}

// Exact templates from the approved Linux/Tailscale runbook (v0.21.3).
// A sentinel or matching ExecStart alone is not sufficient ownership proof.
const tailscaleRunbookUnit = `[Unit]
Description=Herdr Mobile Relay (private access through Tailscale Serve)

[Service]
Type=simple
ExecStart=/bin/bash "%h/.config/herdr/plugins/config/herdr-mobile-relay.events/start-tailscale-relay.sh"
Environment="HERDR_RELAY_ENV=%h/.config/herdr/plugins/config/herdr-mobile-relay.events/relay.env"
Restart=on-failure
RestartSec=5
UMask=0077

[Install]
WantedBy=default.target
`

const tailscaleRunbookLauncher = `#!/bin/bash
set -euo pipefail

export PATH="$HOME/.local/bin:/usr/local/bin:/home/linuxbrew/.linuxbrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export HERDR_RELAY_ENV="$HOME/.config/herdr/plugins/config/herdr-mobile-relay.events/relay.env"
unset HERDR_SESSION HERDR_CLIENT_SOCKET_PATH

set -a
source "$HERDR_RELAY_ENV"
set +a

: "${HERDR_RELAY_TOKEN:?Missing relay key}"
: "${HERDR_RELEASE_ROOT:?Missing release path}"
: "${HERDR_SOCKET_PATH:?Missing Herdr socket selection}"

if [ "${#HERDR_RELAY_TOKEN}" -ne 32 ] || [ -n "${HERDR_GATEWAY_URL:-}" ]; then
  echo "Expected a 32-byte relay key and no external gateway. Check relay.env." >&2
  exit 1
fi

export HERDR_RELAY_HOST=127.0.0.1
export HERDR_GATEWAY_URL=
export HERDR_REACHABILITY_PORT_MAPPING=0
export HERDR_TRANSPORT_FORCE_RELAY=1
export HERDR_RELAY_REARM_BOOTSTRAP=0

exec "$HERDR_RELEASE_ROOT/current/herdr-mobile-relay" serve
`
