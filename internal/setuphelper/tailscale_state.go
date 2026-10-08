package setuphelper

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"
)

const tailscaleStateOwner = "herdr-mobile-relay-tailscale-v1"
const maxTailscaleState = 32768

// TailscaleSetupState records evidence, not permission to modify a resource.
// Callers must hold the top-level setup lock, re-inspect resources and verify
// their identities before acting. Credentials and whole Serve snapshots do not
// belong here. Immutable fields are fixed when preparation is approved.
type TailscaleSetupState struct {
	Schema            int    `json:"schema"`
	Owner             string `json:"owner"`
	Phase             string `json:"phase"`
	Hostname          string `json:"hostname"`
	HTTPSPort         int    `json:"https_port"`
	RelayPort         int    `json:"relay_port"`
	Environment       string `json:"environment"`
	Unit              string `json:"unit"`
	Socket            string `json:"socket"`
	Instance          string `json:"instance"`
	RecoveryDirectory string `json:"recovery_directory"`
	RouteOwnership    string `json:"route_ownership"`
	UnrelatedDigest   string `json:"unrelated_digest"`
}

func RunTailscaleState(args []string, input io.Reader, output io.Writer) error {
	// Shell orchestration passes validated data as argv rather than attempting
	// to escape paths into JSON. No credentials are arguments to this command.
	if len(args) == 12 && args[0] == "prepare" {
		https, err := tailscalePort(args[3])
		if err != nil {
			return err
		}
		local, err := tailscalePort(args[4])
		if err != nil {
			return err
		}
		return CreateTailscaleState(args[1], TailscaleSetupState{
			Schema: 1, Owner: tailscaleStateOwner, Phase: "prepared", Hostname: args[2], HTTPSPort: https, RelayPort: local,
			Environment: args[5], Unit: args[6], Socket: args[7], Instance: args[8], RecoveryDirectory: args[9], UnrelatedDigest: args[10], RouteOwnership: args[11],
		})
	}
	if len(args) == 5 && args[0] == "retry" {
		state, err := ReadTailscaleState(args[1])
		if err != nil {
			return err
		}
		if (state.Phase != "rolled-back" && state.Phase != "removed") || (args[4] != "absent" && args[4] != "adopted") {
			return errors.New("retry requires a confirmed rollback or teardown and a newly reviewed route")
		}
		previous := state
		state.Phase, state.RecoveryDirectory, state.UnrelatedDigest, state.RouteOwnership = "prepared", args[2], args[3], args[4]
		if err := state.validate(); err != nil {
			return err
		}
		return writeTailscaleState(args[1], state, &previous)
	}
	if len(args) == 2 && args[0] == "create" {
		state, err := decodeTailscaleState(input)
		if err != nil {
			return err
		}
		return CreateTailscaleState(args[1], state)
	}
	if len(args) == 3 && args[0] == "get" {
		state, err := ReadTailscaleState(args[1])
		if err != nil {
			return err
		}
		data, _ := json.Marshal(state)
		var fields map[string]json.RawMessage
		if err := json.Unmarshal(data, &fields); err != nil {
			return err
		}
		raw, ok := fields[args[2]]
		if !ok {
			return errors.New("unknown Tailscale state field")
		}
		var text string
		if json.Unmarshal(raw, &text) == nil {
			_, err = fmt.Fprintln(output, text)
		} else {
			_, err = fmt.Fprintln(output, string(raw))
		}
		return err
	}
	if (len(args) == 4 || len(args) == 5) && args[0] == "advance" {
		route := ""
		if len(args) == 5 {
			route = args[4]
		}
		return AdvanceTailscaleState(args[1], args[2], args[3], route)
	}
	return errors.New("usage: tailscale-state prepare FILE HOST HTTPS_PORT RELAY_PORT ENV UNIT SOCKET INSTANCE RECOVERY DIGEST OWNERSHIP | create FILE | get FILE FIELD | advance FILE EXPECTED_PHASE NEXT_PHASE [ROUTE_OWNERSHIP] | retry FILE RECOVERY DIGEST OWNERSHIP")
}

func CreateTailscaleState(path string, state TailscaleSetupState) error {
	if err := state.validate(); err != nil {
		return err
	}
	if state.Phase != "prepared" || (state.RouteOwnership != "absent" && state.RouteOwnership != "adopted") {
		return errors.New("Tailscale state must start prepared without claiming a newly created route")
	}
	return writeTailscaleState(path, state, nil)
}

func ReadTailscaleState(path string) (TailscaleSetupState, error) {
	empty := TailscaleSetupState{}
	if err := privateStateDirectory(path); err != nil {
		return empty, err
	}
	info, err := os.Lstat(path)
	if err != nil || !privateStateFile(info) {
		return empty, errors.New("Tailscale state must be an owned, private regular file with no links")
	}
	file, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	if err != nil {
		return empty, errors.New("cannot open private Tailscale state")
	}
	defer file.Close()
	opened, err := file.Stat()
	if err != nil || !privateStateFile(opened) || !os.SameFile(info, opened) {
		return empty, errors.New("Tailscale state changed while opening")
	}
	return decodeTailscaleState(file)
}

func AdvanceTailscaleState(path, expected, next, route string) error {
	state, err := ReadTailscaleState(path)
	if err != nil {
		return err
	}
	if state.Phase != expected {
		return errors.New("Tailscale state phase changed; inspect recovery before retrying")
	}
	allowed := map[string][]string{
		"prepared":         {"local-ready", "recovery"},
		"local-ready":      {"route-pending", "recovery"},
		"route-pending":    {"route-ready", "recovery"},
		"route-ready":      {"verified", "recovery"},
		"verified":         {"teardown-pending", "recovery"},
		"recovery":         {"teardown-pending", "rolled-back"},
		"teardown-pending": {"removed", "recovery"},
	}
	valid := false
	for _, candidate := range allowed[expected] {
		if candidate == next {
			valid = true
		}
	}
	if !valid {
		return errors.New("unsafe Tailscale setup phase transition")
	}
	old := state
	if route != "" && route != state.RouteOwnership {
		if expected != "route-pending" || next != "route-ready" || state.RouteOwnership != "absent" || route != "created" {
			return errors.New("Tailscale route ownership cannot be reassigned")
		}
		state.RouteOwnership = route
	}
	state.Phase = next
	if err := state.validate(); err != nil {
		return err
	}
	return writeTailscaleState(path, state, &old)
}

func decodeTailscaleState(input io.Reader) (TailscaleSetupState, error) {
	var state TailscaleSetupState
	data, err := io.ReadAll(io.LimitReader(input, maxTailscaleState+1))
	if err != nil || len(data) > maxTailscaleState {
		return state, errors.New("Tailscale state unreadable or too large")
	}
	// Reuse duplicate-key, nesting and trailing-data checks, but never echo
	// decoder diagnostics: corrupt state may contain untrusted private text.
	if _, err := tailscaleJSON(bytes.NewReader(data)); err != nil {
		return state, errors.New("invalid Tailscale state JSON")
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&state); err != nil {
		return TailscaleSetupState{}, errors.New("unsupported Tailscale state schema")
	}
	if err := state.validate(); err != nil {
		return TailscaleSetupState{}, err
	}
	return state, nil
}

func (s TailscaleSetupState) validate() error {
	if s.Schema != 1 || s.Owner != tailscaleStateOwner {
		return errors.New("unrecognized Tailscale state owner or schema")
	}
	if !tailscaleHostnameValid(s.Hostname) || s.HTTPSPort < 1 || s.HTTPSPort > 65535 || s.RelayPort < 1 || s.RelayPort > 65535 {
		return errors.New("invalid Tailscale state endpoint")
	}
	for _, path := range []string{s.Environment, s.Unit, s.Socket, s.RecoveryDirectory} {
		if !safeStatePath(path) {
			return errors.New("invalid path in Tailscale state")
		}
	}
	if filepath.Base(s.Unit) != "herdr-mobile-relay-tailscale.service" || filepath.Base(s.Environment) != "relay.env" {
		return errors.New("unrecognized Tailscale service identity")
	}
	if len(s.Instance) == 0 || len(s.Instance) > 128 || strings.IndexFunc(s.Instance, func(c rune) bool {
		return !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-' || c == '_' || c == '.')
	}) >= 0 {
		return errors.New("invalid relay instance in Tailscale state")
	}
	if len(s.UnrelatedDigest) != 64 || strings.IndexFunc(s.UnrelatedDigest, func(c rune) bool { return !(c >= 'a' && c <= 'f' || c >= '0' && c <= '9') }) >= 0 {
		return errors.New("invalid Serve fingerprint in Tailscale state")
	}
	switch s.RouteOwnership {
	case "absent", "created", "adopted":
	default:
		return errors.New("invalid Tailscale route ownership")
	}
	switch s.Phase {
	case "prepared", "local-ready", "route-pending":
		if s.RouteOwnership == "created" {
			return errors.New("Tailscale route creation is not yet verified")
		}
	case "route-ready", "verified":
		if s.RouteOwnership == "absent" {
			return errors.New("ready Tailscale state lacks route evidence")
		}
	case "recovery", "rolled-back", "teardown-pending", "removed":
	default:
		return errors.New("unknown Tailscale setup phase")
	}
	return nil
}

func safeStatePath(path string) bool {
	return filepath.IsAbs(path) && filepath.Clean(path) == path && strings.IndexFunc(path, func(c rune) bool { return c < 32 || c == 127 }) < 0
}

func privateStateFile(info os.FileInfo) bool {
	if info == nil || !info.Mode().IsRegular() || info.Mode().Perm() != 0o600 || info.Mode()&(os.ModeSetuid|os.ModeSetgid|os.ModeSticky) != 0 {
		return false
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	return ok && stat.Uid == uint32(os.Geteuid()) && stat.Nlink == 1
}

func privateStateDirectory(path string) error {
	if !safeStatePath(path) {
		return errors.New("Tailscale state path must be absolute and normalized")
	}
	dir := filepath.Dir(path)
	for current := dir; ; current = filepath.Dir(current) {
		info, err := os.Lstat(current)
		if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
			return errors.New("Tailscale state path contains an unsafe directory")
		}
		if current == dir {
			stat, ok := info.Sys().(*syscall.Stat_t)
			if !ok || stat.Uid != uint32(os.Geteuid()) || info.Mode().Perm() != 0o700 {
				return errors.New("Tailscale state directory must be owned and mode 0700")
			}
		}
		if filepath.Dir(current) == current {
			break
		}
	}
	return nil
}

// The top-level operation owns serialization across files, systemd and Serve.
// Atomic publication prevents partial JSON. The re-read detects stale callers;
// it is not a substitute for that operation lock or external resource checks.
func writeTailscaleState(path string, state TailscaleSetupState, previous *TailscaleSetupState) error {
	if err := privateStateDirectory(path); err != nil {
		return err
	}
	data, err := json.Marshal(state)
	if err != nil {
		return err
	}
	dir := filepath.Dir(path)
	file, err := os.CreateTemp(dir, ".tailscale-state-*")
	if err != nil {
		return errors.New("cannot stage private Tailscale state")
	}
	name := file.Name()
	defer os.Remove(name)
	defer file.Close()
	if _, err = file.Write(data); err != nil {
		return errors.New("cannot write Tailscale state")
	}
	if err = file.Sync(); err != nil {
		return errors.New("cannot sync Tailscale state")
	}
	if err = file.Close(); err != nil {
		return errors.New("cannot close staged Tailscale state")
	}
	if previous == nil {
		// Link is an atomic no-replace publication; rename alone would overwrite
		// an existing record created between the initial check and publication.
		if err = os.Link(name, path); err != nil {
			return errors.New("Tailscale state already exists or cannot be published")
		}
		if err = os.Remove(name); err != nil {
			return errors.New("Tailscale state published with incomplete temporary-file cleanup")
		}
	} else {
		current, err := ReadTailscaleState(path)
		if err != nil {
			return err
		}
		if current != *previous {
			return errors.New("Tailscale state changed before publication")
		}
		if err = os.Rename(name, path); err != nil {
			return errors.New("cannot publish updated Tailscale state")
		}
	}
	directory, err := os.Open(dir)
	if err != nil {
		return errors.New("Tailscale state published but directory cannot be synced")
	}
	defer directory.Close()
	if err = directory.Sync(); err != nil {
		return errors.New("Tailscale state published but directory sync failed")
	}
	return nil
}
