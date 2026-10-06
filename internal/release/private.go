package release

import "errors"

// TailscaleSetupVersion covers the setup/state/launcher contract, not a new
// wire transport. Old bundles remain valid for legacy use, but cannot replace
// a managed private installation merely because WebSocket versions overlap.
const TailscaleSetupVersion = 1

var tailscaleHelpers = []string{
	"install.sh",
	"relay/common.sh", "relay/native-install-transaction.sh",
	"relay/tailscale-common.sh", "relay/tailscale-transaction.sh",
	"relay/tailscale-service.sh", "relay/tailscale-control.sh",
	"relay/tailscale-setup.sh", "relay/tailscale-teardown.sh",
	"relay/tailscale-switch.sh", "relay/tailscale-pair.sh", "relay/tailscale-update.sh",
}

func hasTailscaleHelpers(manifest Manifest) bool {
	if (manifest.Target == "darwin/amd64" || manifest.Target == "darwin/arm64") && !validSHA256(manifest.Files["relay/tailscale-darwin.sh"]) {
		return false
	}
	for _, helper := range tailscaleHelpers {
		if !validSHA256(manifest.Files[helper]) {
			return false
		}
	}
	return true
}

func tailscaleTarget(target string) bool {
	return target == "linux/amd64" || target == "linux/arm64" || target == "darwin/amd64" || target == "darwin/arm64"
}

func ValidateTailscaleRelease(manifest Manifest) error {
	if manifest.Repository != Repository {
		return errors.New("private updates require a release owned by the configured fork")
	}
	if !tailscaleTarget(manifest.Target) {
		return errors.New("private setup requires a supported Linux or macOS release")
	}
	if manifest.TailscaleSetup != TailscaleSetupVersion || !hasTailscaleHelpers(manifest) {
		return errors.New("release lacks the managed Tailscale setup, lifecycle or update contract")
	}
	return nil
}
