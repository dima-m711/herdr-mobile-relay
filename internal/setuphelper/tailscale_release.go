package setuphelper

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
)

// Release recovery is private data, never shell code. Both pointers must name
// physical direct children of this installation's releases directory.
func ReadTailscaleReleaseRecovery(directory, root string) (string, string, error) {
	if !safeStatePath(root) || !safeStatePath(directory) {
		return "", "", errors.New("invalid release recovery paths")
	}
	paths := make([]string, 0, 2)
	for _, name := range []string{"previous-release", "candidate-release"} {
		data, err := readTailscaleOwnedFile(filepath.Join(directory, name), 4096, true)
		if err != nil {
			return "", "", err
		}
		path := strings.TrimSuffix(string(data), "\n")
		if !safeStatePath(path) || filepath.Dir(path) != filepath.Join(root, "releases") {
			return "", "", errors.New("release recovery escapes the managed installation")
		}
		physical, err := filepath.EvalSymlinks(path)
		if err != nil || physical != path {
			return "", "", errors.New("release recovery target is missing or redirected")
		}
		info, err := os.Stat(path)
		if err != nil || !info.IsDir() {
			return "", "", errors.New("release recovery target is not a directory")
		}
		paths = append(paths, path)
	}
	return paths[0], paths[1], nil
}
