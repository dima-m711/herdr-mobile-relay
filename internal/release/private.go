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
	for _, helper := range tailscaleHelpers {
		if !validSHA256(manifest.Files[helper]) {
			return false
		}
	}
	return true
}

func ValidateTailscaleRelease(manifest Manifest) error {
	if manifest.Repository != Repository {
		return errors.New("private updates require a release owned by the configured fork")
	}
	if manifest.Target != "linux/amd64" && manifest.Target != "linux/arm64" {
		return errors.New("private setup requires a supported Linux release")
	}
	if manifest.TailscaleSetup != TailscaleSetupVersion || !hasTailscaleHelpers(manifest) {
		return errors.New("release lacks the managed Tailscale setup, lifecycle or update contract")
	}
	return nil
}
