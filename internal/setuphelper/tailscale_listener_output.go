package setuphelper

import (
	"bytes"
	"encoding/binary"
	"errors"
	"strconv"
	"strings"
)

// Match the mapped executable vnode too: resolving an argv path through
// `current` alone could mistake the old running binary for a newly activated one.
func verifyDarwinExecutableFileOutput(data []byte, pid, uid int, path string, device, inode uint64) error {
	invalid := errors.New("process executable vnode differs from the selected release")
	if len(data) == 0 || len(data) > 1<<20 {
		return invalid
	}
	process, found := false, false
	for _, line := range strings.Split(strings.TrimSuffix(string(data), "\n"), "\n") {
		if line == "" {
			continue
		}
		values := map[byte]string{}
		for _, field := range strings.Split(strings.TrimSuffix(line, "\x00"), "\x00") {
			if len(field) < 2 {
				return invalid
			}
			if _, exists := values[field[0]]; exists {
				return invalid
			}
			values[field[0]] = field[1:]
		}
		if strings.HasPrefix(line, "p") {
			if process || values['p'] != strconv.Itoa(pid) || values['u'] != strconv.Itoa(uid) {
				return invalid
			}
			process = true
		} else {
			if !process || values['f'] != "txt" {
				return invalid
			}
			if values['n'] != path {
				continue
			}
			dev, err := strconv.ParseUint(values['D'], 0, 64)
			if err != nil {
				return invalid
			}
			ino, err := strconv.ParseUint(values['i'], 10, 64)
			if err != nil {
				return invalid
			}
			if values['t'] != "REG" || dev != device || ino != inode {
				return invalid
			}
			found = true
		}
	}
	if !found {
		return invalid
	}
	return nil
}

func darwinExecutableOutput(data []byte) (string, error) {
	if len(data) < 6 || len(data) > 1<<20 || binary.LittleEndian.Uint32(data[:4]) == 0 {
		return "", errors.New("invalid process arguments")
	}
	end := bytes.IndexByte(data[4:], 0)
	if end < 1 {
		return "", errors.New("missing process executable")
	}
	path := string(data[4 : 4+end])
	if !safeStatePath(path) {
		return "", errors.New("invalid process executable")
	}
	return path, nil
}

// lsof's NUL field format keeps spaces in names unambiguous. Require the exact
// process owner and reject any unexpected process or non-loopback listener.
func verifyDarwinListenerOutput(data []byte, pid, uid, port int) error {
	invalid := errors.New("selected process does not own the expected private listener")
	if len(data) == 0 || len(data) > 1<<20 {
		return invalid
	}
	process, owner, found := false, false, false
	for _, line := range strings.Split(strings.TrimSuffix(string(data), "\n"), "\n") {
		if line == "" {
			continue
		}
		fields := strings.Split(strings.TrimSuffix(line, "\x00"), "\x00")
		if strings.HasPrefix(line, "p") {
			if process {
				return invalid
			}
			values := map[byte]string{}
			for _, field := range fields {
				if len(field) < 2 {
					return invalid
				}
				if _, ok := values[field[0]]; ok {
					return invalid
				}
				values[field[0]] = field[1:]
			}
			process = values['p'] == strconv.Itoa(pid)
			owner = values['u'] == strconv.Itoa(uid)
			if !process || !owner {
				return invalid
			}
		} else {
			if !process || !owner || !strings.HasPrefix(line, "f") {
				return invalid
			}
			values := map[byte]string{}
			for _, field := range fields {
				if len(field) < 2 {
					return invalid
				}
				if field[0] == 'T' && !strings.HasPrefix(field, "TST=") {
					continue
				}
				if _, ok := values[field[0]]; ok {
					return invalid
				}
				values[field[0]] = field[1:]
			}
			if values['t'] != "IPv4" || values['P'] != "TCP" || values['n'] != "127.0.0.1:"+strconv.Itoa(port) || values['T'] != "ST=LISTEN" {
				return invalid
			}
			found = true
		}
	}
	if !found {
		return invalid
	}
	return nil
}
