package setuphelper

import (
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"syscall"
	"time"
)

// TailscaleServiceName keeps updater handoffs bound to the current OS.
func TailscaleServiceName(goos string) string {
	if goos == "darwin" {
		return "com.herdr-mobile-relay.tailscale"
	}
	if goos == "linux" {
		return "herdr-mobile-relay-tailscale.service"
	}
	return ""
}

func TailscaleServiceFile(goos string) string {
	name := TailscaleServiceName(goos)
	if goos == "darwin" {
		return name + ".plist"
	}
	return name
}

// RunTailscalePlatform supplies small native operations missing from stock macOS.
// It does not interpret shell input, install tools, or alter network settings.
func RunTailscalePlatform(args []string, output io.Writer) error {
	if len(args) == 0 {
		return errors.New("missing platform operation")
	}
	switch args[0] {
	case "launchd-verify", "launchd-pid", "launchd-disabled", "launchd-loaded":
		return runTailscaleLaunchd(args, os.Stdin, output)
	case "realpath":
		if len(args) != 2 {
			break
		}
		path, err := filepath.EvalSymlinks(args[1])
		if err != nil {
			return err
		}
		path, err = filepath.Abs(path)
		if err != nil {
			return err
		}
		_, err = fmt.Fprintln(output, path)
		return err
	case "hash":
		if len(args) < 2 {
			break
		}
		for _, path := range args[1:] {
			file, err := os.Open(path)
			if err != nil {
				return err
			}
			hash := sha256.New()
			_, err = io.Copy(hash, file)
			closeErr := file.Close()
			if err != nil {
				return err
			}
			if closeErr != nil {
				return closeErr
			}
			if _, err := fmt.Fprintf(output, "%x\n", hash.Sum(nil)); err != nil {
				return err
			}
		}
		return nil
	case "sync":
		if len(args) != 2 {
			break
		}
		file, err := os.Open(args[1])
		if err != nil {
			return err
		}
		defer file.Close()
		return file.Sync()
	case "lock-fd", "check-fd":
		if len(args) != 3 {
			break
		}
		fd, err := strconv.Atoi(args[1])
		if err != nil || fd < 3 || fd > 1024 {
			return errors.New("invalid lock descriptor")
		}
		if err := verifyPrivateLockFD(fd, args[2]); err != nil {
			return err
		}
		if args[0] == "lock-fd" {
			if err := syscall.Flock(fd, syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
				return err
			}
			return verifyPrivateLockFD(fd, args[2])
		}
		return nil
	case "run":
		if len(args) < 3 {
			break
		}
		seconds, err := strconv.Atoi(args[1])
		if err != nil || seconds < 1 || seconds > 120 {
			return errors.New("invalid command deadline")
		}
		ctx, cancel := context.WithTimeout(context.Background(), time.Duration(seconds)*time.Second)
		defer cancel()
		command := exec.CommandContext(ctx, args[2], args[3:]...)
		command.Stdin, command.Stdout, command.Stderr = os.Stdin, output, os.Stderr
		command.WaitDelay = time.Second
		if err := command.Run(); err != nil {
			return errors.New("bounded platform command failed")
		}
		return nil
	}
	return errors.New("usage: tailscale-platform realpath PATH | hash FILE... | sync PATH | lock-fd FD PATH | check-fd FD PATH | run SECONDS COMMAND [ARGS...]")
}

func verifyPrivateLockFD(fd int, path string) error {
	if !safeStatePath(path) {
		return errors.New("invalid lock path")
	}
	parent, err := os.Lstat(filepath.Dir(path))
	if err != nil || !parent.IsDir() || parent.Mode().Perm()&0022 != 0 {
		return errors.New("unsafe lock directory")
	}
	owner, ok := parent.Sys().(*syscall.Stat_t)
	if !ok || owner.Uid != uint32(os.Geteuid()) {
		return errors.New("foreign lock directory")
	}
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm() != 0600 {
		return errors.New("unsafe lock file")
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	var actual syscall.Stat_t
	if !ok || stat.Uid != uint32(os.Geteuid()) || stat.Nlink != 1 || syscall.Fstat(fd, &actual) != nil || actual.Dev != stat.Dev || actual.Ino != stat.Ino || actual.Uid != uint32(os.Geteuid()) || actual.Nlink != 1 || actual.Mode&syscall.S_IFMT != syscall.S_IFREG || actual.Mode&07777 != 0600 {
		return errors.New("lock descriptor does not belong to the owned lock file")
	}
	return nil
}
