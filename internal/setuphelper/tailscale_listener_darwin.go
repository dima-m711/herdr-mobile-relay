package setuphelper

import (
	"bytes"
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

type listenerOutput struct{ bytes.Buffer }

func (b *listenerOutput) Write(p []byte) (int, error) {
	if b.Len()+len(p) > 1<<20 {
		return 0, errors.New("listener inventory exceeds limit")
	}
	return b.Buffer.Write(p)
}

func verifyTailscaleListener(rawPID, rawPort, executable string) error {
	pid, err := strconv.Atoi(rawPID)
	if err != nil || pid <= 1 || strconv.Itoa(pid) != rawPID {
		return errors.New("invalid macOS relay process identity")
	}
	port, err := tailscalePort(rawPort)
	if err != nil {
		return err
	}
	expected, err := filepath.EvalSymlinks(executable)
	if err != nil {
		return errors.New("expected relay executable unavailable")
	}
	verifyExecutable := func() error {
		data, err := unix.SysctlRaw("kern.procargs2", pid)
		if err != nil {
			return errors.New("cannot inspect relay executable")
		}
		actual, err := darwinExecutableOutput(data)
		if err != nil {
			return err
		}
		actual, err = filepath.EvalSymlinks(actual)
		if err != nil || actual != expected {
			return errors.New("service is not running the selected relay executable")
		}
		return nil
	}
	if err := verifyExecutable(); err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	inspect := func(args ...string) ([]byte, error) {
		command := exec.CommandContext(ctx, "/usr/sbin/lsof", args...)
		var output listenerOutput
		command.Stdout = &output
		command.WaitDelay = time.Second
		if command.Run() != nil {
			return nil, errors.New("cannot inspect private relay process")
		}
		return output.Bytes(), nil
	}
	info, err := os.Stat(expected)
	if err != nil {
		return err
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return errors.New("cannot inspect selected executable identity")
	}
	text, err := inspect("-nP", "-a", "-p", rawPID, "-d", "txt", "-F0puftDin")
	if err != nil {
		return err
	}
	if err := verifyDarwinExecutableFileOutput(text, pid, os.Geteuid(), expected, uint64(uint32(stat.Dev)), stat.Ino); err != nil {
		return err
	}
	output, err := inspect("-nP", "-a", "-p", rawPID, "-iTCP:"+rawPort, "-sTCP:LISTEN", "-F0puftnPT")
	if err != nil {
		return err
	}
	if err := verifyDarwinListenerOutput(output, pid, os.Geteuid(), port); err != nil {
		return err
	}
	return verifyExecutable()
}
