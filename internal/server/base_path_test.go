package server

import (
	"bytes"
	"encoding/hex"
	"net/http"
	"net/http/httptest"
	"regexp"
	"strings"
	"testing"

	"github.com/telegramdesktop/tproxy-server/internal/config"
	"github.com/telegramdesktop/tproxy-server/internal/frame"
)

const testBasePath = "kecjyr5ti4qtvquhyva43e5h24"

// siteMarker appears in both the operator index and its 404 document, so a
// response carrying it came from the public site rather than from the relay.
const siteMarker = "Operator Site"

func newBasePathServer(t *testing.T, backend string) (*Server, string) {
	t.Helper()
	secret, _ := hex.DecodeString("000102030405060708090a0b0c0d0e0f")
	application, _ := newConfiguredTestServer(t, backend, func(value *config.Config) {
		value.BasePath = testBasePath
		value.Profiles[0].Capability = config.DeriveCapability(testHost, testBasePath, secret)
	})
	capability := config.CapabilityString(
		config.DeriveCapability(testHost, testBasePath, secret))
	return application, capability
}

// A client typing an alias hostname derives a different capability, so the relay
// must accept the alias for the Host check and render that alias into the bridge
// page. Otherwise the WebView would fetch from the origin name while the page was
// loaded from the alias, breaking same-origin.
func TestAliasHostnameServesItsOwnBridge(t *testing.T) {
	backend := startEchoBackend(t)
	const alias = "edge.example.com"
	secret, _ := hex.DecodeString("000102030405060708090a0b0c0d0e0f")
	application, _ := newConfiguredTestServer(t, backend, func(value *config.Config) {
		value.BasePath = testBasePath
		value.AliasHostnames = []string{alias}
		value.Profiles[0].Capability = config.DeriveCapability(testHost, testBasePath, secret)
		value.Profiles[0].Capabilities = [][32]byte{
			config.DeriveCapability(testHost, testBasePath, secret),
			config.DeriveCapability(alias, testBasePath, secret),
		}
	})
	defer application.Shutdown()
	hosted := httptest.NewServer(application.Handler())
	defer hosted.Close()

	aliasCapability := config.CapabilityString(
		config.DeriveCapability(alias, testBasePath, secret))
	aliasRequest := request(t, http.MethodGet,
		hosted.URL+"/"+testBasePath+"/?bridge="+aliasCapability, nil, "")
	aliasRequest.Host = alias
	response := perform(t, hosted.Client(), aliasRequest)
	body := readResponse(t, response)
	if response.StatusCode != http.StatusOK || !bytes.Contains(body, []byte("tproxy-init")) {
		t.Fatalf("bridge under the alias failed: status %d", response.StatusCode)
	}
	if !bytes.Contains(body, []byte(`relayBase="https://`+alias+`/`+testBasePath+`/"`)) {
		t.Fatal("bridge did not render the alias as its relay origin")
	}
	if csp := response.Header.Get("Content-Security-Policy"); !strings.Contains(csp, "wss://"+alias) {
		t.Fatalf("bridge CSP did not name the alias: %s", csp)
	}

	// The primary capability still works under the primary name.
	primaryCapability := config.CapabilityString(
		config.DeriveCapability(testHost, testBasePath, secret))
	primary := request(t, http.MethodGet,
		hosted.URL+"/"+testBasePath+"/?bridge="+primaryCapability, nil, "")
	primaryResponse := perform(t, hosted.Client(), primary)
	primaryBody := readResponse(t, primaryResponse)
	if primaryResponse.StatusCode != http.StatusOK ||
		!bytes.Contains(primaryBody, []byte(`relayBase="https://`+testHost+`/`+testBasePath+`/"`)) {
		t.Fatal("primary hostname bridge regressed")
	}

	// A capability is a credential, not a host-scoped grant: one minted for the
	// primary name also opens the bridge under an alias. That is intentional and
	// harmless, because both names reach this same relay and the capability is
	// already the secret. The bridge still renders the name the request used, so
	// the WebView stays same-origin.
	crossRequest := request(t, http.MethodGet,
		hosted.URL+"/"+testBasePath+"/?bridge="+primaryCapability, nil, "")
	crossRequest.Host = alias
	crossResponse := perform(t, hosted.Client(), crossRequest)
	crossBody := readResponse(t, crossResponse)
	if crossResponse.StatusCode != http.StatusOK ||
		!bytes.Contains(crossBody, []byte(`relayBase="https://`+alias+`/`+testBasePath+`/"`)) {
		t.Fatal("a capability did not open the bridge under a configured alias")
	}

	// An unconfigured hostname stays a local 404 for authenticated traffic.
	unknown := request(t, http.MethodGet,
		hosted.URL+"/"+testBasePath+"/?bridge="+aliasCapability, nil, "")
	unknown.Host = "evil.example"
	unknownResponse := perform(t, hosted.Client(), unknown)
	_ = readResponse(t, unknownResponse)
	if unknownResponse.StatusCode != http.StatusNotFound {
		t.Fatalf("unconfigured host was accepted: status %d", unknownResponse.StatusCode)
	}
}

func TestBasePathCarrierRoundTrip(t *testing.T) {
	backend := startEchoBackend(t)
	application, capability := newBasePathServer(t, backend)
	defer application.Shutdown()
	hosted := httptest.NewServer(application.Handler())
	defer hosted.Close()
	prefix := hosted.URL + "/" + testBasePath

	bridgeResponse := perform(t, hosted.Client(), request(
		t,
		http.MethodGet,
		prefix+"/?bridge="+capability,
		nil,
		""))
	bridgeBody := readResponse(t, bridgeResponse)
	if bridgeResponse.StatusCode != http.StatusOK ||
		!bytes.Contains(bridgeBody, []byte("tproxy-init")) {
		t.Fatalf("bridge under the base path failed: status %d", bridgeResponse.StatusCode)
	}
	base := []byte(`relayBase="https://` + testHost + "/" + testBasePath + `/"`)
	if !bytes.Contains(bridgeBody, base) {
		t.Fatal("bridge page did not resolve its carrier endpoints against the base path")
	}
	match := regexp.MustCompile(`bootstrap="([A-Za-z0-9_-]{43})"`).FindSubmatch(bridgeBody)
	if len(match) != 2 {
		t.Fatal("could not locate embedded bootstrap token")
	}
	bootstrap := string(match[1])

	hello := frame.Encode(frame.Hello, 0, []byte{1})
	created := perform(t, hosted.Client(), apiRequest(
		t,
		http.MethodPost,
		prefix+"/api/v1/session",
		bootstrap,
		hello))
	welcome := readResponse(t, created)
	if created.StatusCode != http.StatusOK ||
		!bytes.Equal(welcome, frame.Encode(frame.Welcome, 0, nil)) {
		t.Fatalf("session creation under the base path failed: status %d", created.StatusCode)
	}
	sessionToken := created.Header.Get("X-Session-Token")
	if sessionToken == "" {
		t.Fatal("missing session token")
	}

	streamID := uint32(17)
	payload := []byte("prefixed round trip")
	uplink := append(
		frame.Encode(frame.Open, streamID, nil),
		frame.Encode(frame.Data, streamID, payload)...)
	upRequest := apiRequest(t, http.MethodPost, prefix+"/api/v1/up", sessionToken, uplink)
	upRequest.Header.Set("X-Up-Seq", "1")
	up := perform(t, hosted.Client(), upRequest)
	_ = readResponse(t, up)
	if up.StatusCode != http.StatusNoContent || up.Header.Get("X-Up-Ack") != "1" {
		t.Fatalf("uplink under the base path failed: status %d", up.StatusCode)
	}
	pollForData(t, hosted.Client(), prefix, sessionToken, "0", map[uint32][]byte{
		streamID: payload,
	})

	closed := perform(t, hosted.Client(), apiRequest(
		t,
		http.MethodDelete,
		prefix+"/api/v1/session",
		sessionToken,
		nil))
	_ = readResponse(t, closed)
	if closed.StatusCode != http.StatusNoContent {
		t.Fatalf("session close under the base path failed: status %d", closed.StatusCode)
	}
}

// Everything outside the configured prefix belongs to the site, and a
// capability minted for the root or for another prefix authenticates nothing.
func TestBasePathLeavesOtherPathsToTheSite(t *testing.T) {
	backend := startEchoBackend(t)
	application, capability := newBasePathServer(t, backend)
	defer application.Shutdown()
	hosted := httptest.NewServer(application.Handler())
	defer hosted.Close()

	secret, _ := hex.DecodeString("000102030405060708090a0b0c0d0e0f")
	rootCapability := config.CapabilityString(
		config.DeriveCapability(testHost, "", secret))
	otherCapability := config.CapabilityString(
		config.DeriveCapability(testHost, "other-prefix", secret))

	public := map[string]string{
		"site root":                      "/",
		"root carrier path":              "/api/v1/session",
		"carrier path inside the prefix": "/" + testBasePath + "/api/v1/session",
		"unknown path inside the prefix": "/" + testBasePath + "/whatever",
		"root capability at the prefix":  "/" + testBasePath + "/?bridge=" + rootCapability,
		"other prefix capability":        "/" + testBasePath + "/?bridge=" + otherCapability,
	}
	for name, target := range public {
		response := perform(t, hosted.Client(), request(t, http.MethodGet, hosted.URL+target, nil, ""))
		body := readResponse(t, response)
		if !bytes.Contains(body, []byte(siteMarker)) {
			t.Fatalf("%s did not reach the public site: status %d, body %q", name, response.StatusCode, body)
		}
	}

	// An authentic capability is never handed to the site, wherever it appears,
	// and only the exact bridge URL under the base path serves the bridge.
	local := map[string]string{
		"bridge at the root":            "/?bridge=" + capability,
		"prefix without trailing slash": "/" + testBasePath + "?bridge=" + capability,
		"capability on a deeper path":   "/" + testBasePath + "/nested/?bridge=" + capability,
	}
	for name, target := range local {
		response := perform(t, hosted.Client(), request(t, http.MethodGet, hosted.URL+target, nil, ""))
		body := readResponse(t, response)
		if response.StatusCode != http.StatusNotFound || bytes.Contains(body, []byte(siteMarker)) {
			t.Fatalf("%s was not answered locally: status %d, body %q", name, response.StatusCode, body)
		}
	}
}

// A request inside the prefix that proves no secret is not merely delegated: it
// must reach the site application with the prefix still on the path. Stripping
// it would serve the whole site a second time under the prefix, and answering
// it from the relay instead would make in-prefix probes distinguishable from
// every other unknown path the site answers.
func TestBasePathDelegatesWithTheOriginalPath(t *testing.T) {
	backend := startEchoBackend(t)
	seen := make(chan string, 8)
	site := httptest.NewServer(http.HandlerFunc(
		func(w http.ResponseWriter, r *http.Request) {
			seen <- r.URL.RequestURI()
			w.WriteHeader(http.StatusNotFound)
			_, _ = w.Write([]byte(siteMarker))
		}))
	defer site.Close()
	secret, _ := hex.DecodeString("000102030405060708090a0b0c0d0e0f")
	application, _ := newConfiguredTestServer(t, backend, func(value *config.Config) {
		value.BasePath = testBasePath
		value.PublicDir = ""
		value.PublicUpstream = site.URL
		value.Profiles[0].Capability =
			config.DeriveCapability(testHost, testBasePath, secret)
	})
	defer application.Shutdown()
	hosted := httptest.NewServer(application.Handler())
	defer hosted.Close()

	for _, target := range []string{
		"/" + testBasePath + "/",
		"/" + testBasePath + "/whatever?q=1",
		"/" + testBasePath + "/api/v1/session",
		"/" + testBasePath,
		"/api/v1/ws",
		"/" + testBasePath + "//api/v1/up",
	} {
		response := perform(t, hosted.Client(), request(t, http.MethodGet, hosted.URL+target, nil, ""))
		body := readResponse(t, response)
		if response.StatusCode != http.StatusNotFound ||
			!bytes.Contains(body, []byte(siteMarker)) {
			t.Fatalf("%s did not reach the site: status %d", target, response.StatusCode)
		}
		select {
		case got := <-seen:
			if got != target {
				t.Fatalf("the site received %q for %q", got, target)
			}
		default:
			t.Fatalf("the site never received %q", target)
		}
	}
}
