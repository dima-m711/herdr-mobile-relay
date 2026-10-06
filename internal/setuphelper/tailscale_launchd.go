package setuphelper

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

func launchdField(data, field string) (string, error) {
	matches := regexp.MustCompile(`(?m)^\t`+regexp.QuoteMeta(field)+` = ([^\r\n]+)$`).FindAllStringSubmatch(data, -1)
	if len(matches) != 1 {
		return "", errors.New("unrecognized launchd job field")
	}
	return matches[0][1], nil
}

func launchdBlock(data, field string) ([]string, error) {
	matches := regexp.MustCompile(`(?m)^\t`+regexp.QuoteMeta(field)+` = \{\n((?:\t\t[^\r\n]*\n)*)\t\}$`).FindAllStringSubmatch(data, -1)
	if len(matches) != 1 {
		return nil, errors.New("unrecognized launchd job block")
	}
	var lines []string
	for _, line := range strings.Split(strings.TrimSuffix(matches[0][1], "\n"), "\n") {
		lines = append(lines, strings.TrimPrefix(line, "\t\t"))
	}
	return lines, nil
}

func verifyLaunchdJob(data, unit, release, env, label string) error {
	invalid := errors.New("loaded launchd job differs from the managed private definition")
	header := fmt.Sprintf("gui/%d/%s = {\n", os.Getuid(), label)
	if !strings.HasPrefix(data, header) || !strings.HasSuffix(strings.TrimSpace(data), "}") {
		return invalid
	}
	for field, expected := range map[string]string{"path": unit, "program": "/bin/bash", "working directory": release} {
		actual, err := launchdField(data, field)
		if err != nil || actual != expected {
			return invalid
		}
	}
	args, err := launchdBlock(data, "arguments")
	if err != nil || len(args) != 2 || args[0] != "/bin/bash" || args[1] != filepath.Join(release, "relay", "tailscale-service.sh") {
		return invalid
	}
	lines, err := launchdBlock(data, "environment")
	if err != nil {
		return invalid
	}
	values := map[string]string{}
	for _, line := range lines {
		key, value, ok := strings.Cut(line, " => ")
		if !ok {
			return invalid
		}
		if _, exists := values[key]; exists {
			return invalid
		}
		values[key] = value
	}
	expected := map[string]string{"HERDR_RELAY_ENV": env, "PATH": os.Getenv("HOME") + "/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", "XPC_SERVICE_NAME": label}
	for key, value := range values {
		if want, known := expected[key]; !known || want != value {
			return invalid
		}
	}
	for _, key := range []string{"HERDR_RELAY_ENV", "PATH"} {
		if values[key] != expected[key] {
			return invalid
		}
	}
	return nil
}

func launchdDisabled(data, label string) (string, error) {
	if !strings.HasPrefix(data, "disabled services = {\n") || !strings.HasSuffix(strings.TrimSpace(data), "}") {
		return "", errors.New("unrecognized launchd disabled services")
	}
	result := "false"
	found := false
	for _, line := range strings.Split(data, "\n")[1:] {
		line = strings.TrimSpace(line)
		if line == "}" || line == "" {
			continue
		}
		key, value, ok := strings.Cut(line, " => ")
		if !ok || len(key) < 2 || key[0] != '"' || key[len(key)-1] != '"' || (value != "true" && value != "false") {
			return "", errors.New("invalid launchd disabled entry")
		}
		if key[1:len(key)-1] == label {
			if found {
				return "", errors.New("duplicate launchd disabled entry")
			}
			result = value
			found = true
		}
	}
	return result, nil
}

func launchdLoaded(data, label string) (bool, error) {
	lines := strings.Split(strings.TrimSuffix(data, "\n"), "\n")
	if len(lines) == 0 || strings.Join(strings.Fields(lines[0]), " ") != "PID Status Label" {
		return false, errors.New("unrecognized launchd job list")
	}
	found := false
	for _, line := range lines[1:] {
		fields := strings.SplitN(line, "\t", 3)
		if len(fields) != 3 || fields[2] == "" {
			return false, errors.New("invalid launchd job row")
		}
		if fields[0] != "-" {
			if pid, err := strconv.Atoi(fields[0]); err != nil || pid <= 1 {
				return false, errors.New("invalid launchd job PID")
			}
		}
		if _, err := strconv.Atoi(fields[1]); err != nil {
			return false, errors.New("invalid launchd job status")
		}
		if fields[2] == label {
			if found {
				return false, errors.New("duplicate launchd job")
			}
			found = true
		}
	}
	return found, nil
}

func runTailscaleLaunchd(args []string, input io.Reader, output io.Writer) error {
	data, err := io.ReadAll(io.LimitReader(input, (1<<20)+1))
	if err != nil || len(data) > 1<<20 {
		return errors.New("unreadable or oversized launchd snapshot")
	}
	switch args[0] {
	case "launchd-loaded":
		if len(args) == 2 {
			value, err := launchdLoaded(string(data), args[1])
			if err != nil {
				return err
			}
			_, err = fmt.Fprintln(output, value)
			return err
		}
	case "launchd-verify":
		if len(args) == 5 {
			return verifyLaunchdJob(string(data), args[1], args[2], args[3], args[4])
		}
	case "launchd-pid":
		if len(args) == 1 {
			value, err := launchdField(string(data), "pid")
			if err != nil {
				return err
			}
			pid, err := strconv.Atoi(value)
			if err != nil || pid <= 1 || strconv.Itoa(pid) != value {
				return errors.New("private launchd job has no valid PID")
			}
			_, err = fmt.Fprintln(output, value)
			return err
		}
	case "launchd-disabled":
		if len(args) == 2 {
			value, err := launchdDisabled(string(data), args[1])
			if err != nil {
				return err
			}
			_, err = fmt.Fprintln(output, value)
			return err
		}
	}
	return errors.New("invalid launchd snapshot operation")
}
