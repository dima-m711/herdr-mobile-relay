package setuphelper

func verifyTailscaleListener(pid, port, executable string) error {
	return verifyLinuxTailscaleListener(pid, port, executable)
}
