package setuphelper

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"strconv"
	"strings"
)

const maxTailscaleJSON = 1 << 20

// RunTailscaleInspection is a read-only, stdin-based interface for shell
// orchestration. The tab-separated result contains validated values only; it
// is data to read, never shell source to eval.
func RunTailscaleInspection(args []string, input io.Reader, output io.Writer) error {
	if len(args) == 1 && args[0] == "hostname" {
		host, err := TailscaleHostname(input)
		if err != nil {
			return err
		}
		_, err = fmt.Fprintln(output, host)
		return err
	}
	if len(args) == 4 && args[0] == "serve" {
		port, err := strconv.Atoi(args[2])
		if err != nil {
			return errors.New("invalid Tailscale HTTPS port")
		}
		localPort, err := strconv.Atoi(args[3])
		if err != nil {
			return errors.New("invalid relay port")
		}
		result, err := InspectTailscaleServe(input, args[1], port, localPort)
		if err != nil {
			return err
		}
		_, err = fmt.Fprintf(output, "%s\t%s\t%s\t%s\n", result.State, result.Origin, result.Target, result.UnrelatedDigest)
		return err
	}
	return errors.New("usage: tailscale-inspect hostname | serve HOST HTTPS_PORT RELAY_PORT")
}

// TailscaleHostname reads only the current machine's identity. It never returns
// the peer inventory or echoes untrusted daemon output in an error.
func TailscaleHostname(r io.Reader) (string, error) {
	data, err := tailscaleJSON(r)
	if err != nil {
		return "", err
	}
	var status struct {
		BackendState string
		Self         *struct{ DNSName string }
	}
	if json.Unmarshal(data, &status) != nil || status.BackendState != "Running" || status.Self == nil {
		return "", errors.New("Tailscale must be connected with a current machine identity")
	}
	host := strings.TrimSuffix(strings.ToLower(status.Self.DNSName), ".")
	if !tailscaleHostnameValid(host) {
		return "", errors.New("Tailscale did not report a valid ts.net hostname")
	}
	return host, nil
}

func tailscaleHostnameValid(host string) bool {
	if len(host) > 253 || !strings.HasSuffix(host, ".ts.net") {
		return false
	}
	labels := strings.Split(host, ".")
	if len(labels) < 4 {
		return false
	}
	for _, label := range labels {
		if len(label) == 0 || len(label) > 63 || label[0] == '-' || label[len(label)-1] == '-' {
			return false
		}
		for _, c := range label {
			if (c < 'a' || c > 'z') && (c < '0' || c > '9') && c != '-' {
				return false
			}
		}
	}
	return true
}

// This is the device ServeConfig shape in tailscale/ipn/serve.go (v1.102.3).
// Unknown fields fail closed: ignoring a future forwarding option could cause
// us to adopt or delete somebody else's endpoint. No Tailscale SDK is needed.
type tailscaleServeConfig struct {
	TCP         map[string]*tailscaleTCP         `json:",omitempty"`
	Web         map[string]*tailscaleWeb         `json:",omitempty"`
	AllowFunnel map[string]bool                  `json:",omitempty"`
	Foreground  map[string]*tailscaleServeConfig `json:",omitempty"`
	Services    map[string]json.RawMessage       `json:",omitempty"`
}
type tailscaleTCP struct {
	HTTPS         bool   `json:",omitempty"`
	HTTP          bool   `json:",omitempty"`
	TCPForward    string `json:",omitempty"`
	TerminateTLS  string `json:",omitempty"`
	ProxyProtocol int    `json:",omitempty"`
}
type tailscaleWeb struct{ Handlers map[string]*tailscaleHandler }
type tailscaleHandler struct {
	Path          string   `json:",omitempty"`
	Proxy         string   `json:",omitempty"`
	Text          string   `json:",omitempty"`
	AcceptAppCaps []string `json:",omitempty"`
	Redirect      string   `json:",omitempty"`
}

// TailscaleServeInspection contains no credentials or unrelated route details.
// UnrelatedDigest detects changes outside the selected endpoint; it is not a
// transaction token, and must never be used to overwrite a whole Serve config.
type TailscaleServeInspection struct {
	State           string
	Origin          string
	Target          string
	UnrelatedDigest string
}

func InspectTailscaleServe(r io.Reader, host string, port, relayPort int) (TailscaleServeInspection, error) {
	result := TailscaleServeInspection{}
	if !tailscaleHostnameValid(host) || port < 1 || port > 65535 || relayPort < 1 || relayPort > 65535 {
		return result, errors.New("invalid Tailscale endpoint arguments")
	}
	data, err := tailscaleJSON(r)
	if err != nil {
		return result, err
	}
	// Null security fields otherwise silently decode to false/empty values.
	// Serve omits unused fields; an explicit null is ambiguous, not ownership.
	tokens := json.NewDecoder(bytes.NewReader(data))
	for {
		token, err := tokens.Token()
		if err == io.EOF {
			break
		}
		if err != nil || token == nil {
			return result, errors.New("ambiguous null in Tailscale Serve configuration")
		}
	}
	var cfg tailscaleServeConfig
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&cfg) != nil {
		return result, errors.New("unsupported Tailscale Serve configuration")
	}
	if err := validateServeShape(&cfg, false); err != nil {
		return result, err
	}
	portKey := strconv.Itoa(port)
	endpoint := net.JoinHostPort(host, portKey)
	target := "http://127.0.0.1:" + strconv.Itoa(relayPort)
	for _, foreground := range cfg.Foreground {
		if ownsServePort(foreground, portKey) {
			return result, errors.New("selected Tailscale port belongs to a foreground session")
		}
	}
	if cfg.AllowFunnel[endpoint] {
		return result, errors.New("selected Tailscale endpoint permits public Funnel traffic")
	}
	for key := range cfg.Web {
		_, keyPort, _ := net.SplitHostPort(key)
		if keyPort == portKey && key != endpoint {
			return result, errors.New("selected Tailscale port has a different hostname")
		}
	}
	for key, allowed := range cfg.AllowFunnel {
		_, keyPort, _ := net.SplitHostPort(key)
		if allowed && keyPort == portKey {
			return result, errors.New("selected Tailscale port permits public Funnel traffic")
		}
	}
	tcp, hasTCP := cfg.TCP[portKey]
	web, hasWeb := cfg.Web[endpoint]
	result.State = "absent"
	if hasTCP || hasWeb {
		if !hasTCP || !hasWeb || !tcp.HTTPS || tcp.HTTP || tcp.TCPForward != "" || tcp.TerminateTLS != "" || tcp.ProxyProtocol != 0 || len(web.Handlers) != 1 {
			return TailscaleServeInspection{}, errors.New("selected Tailscale port has conflicting handlers")
		}
		handler := web.Handlers["/"]
		if handler == nil || handler.Proxy != target || handler.Path != "" || handler.Text != "" || handler.Redirect != "" || len(handler.AcceptAppCaps) != 0 {
			return TailscaleServeInspection{}, errors.New("selected Tailscale endpoint is not the expected loopback proxy")
		}
		result.State = "matching"
	}
	delete(cfg.TCP, portKey)
	delete(cfg.Web, endpoint)
	delete(cfg.AllowFunnel, endpoint)
	unrelated, err := json.Marshal(cfg)
	if err != nil {
		return TailscaleServeInspection{}, errors.New("cannot fingerprint Tailscale Serve configuration")
	}
	digest := sha256.Sum256(unrelated)
	result.UnrelatedDigest = hex.EncodeToString(digest[:])
	result.Origin = "https://" + endpoint
	result.Target = target
	return result, nil
}

func validateServeShape(cfg *tailscaleServeConfig, foreground bool) error {
	if cfg == nil || (foreground && len(cfg.Foreground) != 0) {
		return errors.New("unsupported foreground Serve configuration")
	}
	if len(cfg.Services) != 0 {
		return errors.New("Tailscale virtual Services require manual configuration review")
	}
	for port, handler := range cfg.TCP {
		n, err := strconv.Atoi(port)
		if err != nil || n < 1 || n > 65535 || strconv.Itoa(n) != port || handler == nil {
			return errors.New("invalid Tailscale TCP handler")
		}
	}
	for endpoint, web := range cfg.Web {
		if !serveEndpointValid(endpoint) || web == nil {
			return errors.New("invalid Tailscale Web handler")
		}
		for mount, handler := range web.Handlers {
			if !strings.HasPrefix(mount, "/") || handler == nil {
				return errors.New("invalid Tailscale mount handler")
			}
		}
	}
	for endpoint := range cfg.AllowFunnel {
		if !serveEndpointValid(endpoint) {
			return errors.New("invalid Tailscale Funnel endpoint")
		}
	}
	for _, child := range cfg.Foreground {
		if err := validateServeShape(child, true); err != nil {
			return err
		}
	}
	return nil
}

func serveEndpointValid(endpoint string) bool {
	host, port, err := net.SplitHostPort(endpoint)
	if err != nil || !tailscaleHostnameValid(host) {
		return false
	}
	n, err := strconv.Atoi(port)
	return err == nil && n > 0 && n <= 65535 && strconv.Itoa(n) == port
}

func ownsServePort(cfg *tailscaleServeConfig, port string) bool {
	if _, ok := cfg.TCP[port]; ok {
		return true
	}
	for endpoint := range cfg.Web {
		_, candidate, _ := net.SplitHostPort(endpoint)
		if candidate == port {
			return true
		}
	}
	for endpoint, allowed := range cfg.AllowFunnel {
		_, candidate, _ := net.SplitHostPort(endpoint)
		if candidate == port && allowed {
			return true
		}
	}
	return false
}

func tailscaleJSON(r io.Reader) ([]byte, error) {
	data, err := io.ReadAll(io.LimitReader(r, maxTailscaleJSON+1))
	if err != nil || len(data) > maxTailscaleJSON {
		return nil, errors.New("Tailscale JSON unreadable or too large")
	}
	if len(bytes.TrimSpace(data)) == 0 || bytes.TrimSpace(data)[0] != '{' {
		return nil, errors.New("Tailscale JSON must be an object")
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	// Detect duplicate keys (including aliases accepted by encoding/json), not
	// just syntax errors, before decoding security-sensitive fields.
	if err := uniqueJSONValue(decoder, 0); err != nil {
		return nil, errors.New("invalid or ambiguous Tailscale JSON")
	}
	if _, err := decoder.Token(); err != io.EOF {
		return nil, errors.New("unexpected trailing Tailscale JSON")
	}
	return data, nil
}

func uniqueJSONValue(decoder *json.Decoder, depth int) error {
	if depth > 64 {
		return errors.New("JSON nesting limit")
	}
	token, err := decoder.Token()
	if err != nil {
		return err
	}
	delimiter, ok := token.(json.Delim)
	if !ok {
		return nil
	}
	switch delimiter {
	case '{':
		seen := map[string]bool{}
		for decoder.More() {
			key, err := decoder.Token()
			if err != nil {
				return err
			}
			name, ok := key.(string)
			if !ok {
				return errors.New("invalid object key")
			}
			name = strings.ToLower(name)
			if seen[name] {
				return errors.New("duplicate object key")
			}
			seen[name] = true
			if err := uniqueJSONValue(decoder, depth+1); err != nil {
				return err
			}
		}
	case '[':
		for decoder.More() {
			if err := uniqueJSONValue(decoder, depth+1); err != nil {
				return err
			}
		}
	default:
		return errors.New("unexpected delimiter")
	}
	_, err = decoder.Token()
	return err
}
