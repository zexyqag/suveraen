package pseudonym

import (
	"bytes"
	"context"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"testing"
)

func seen(t *testing.T, c *Config, host, remote string, headers map[string]string) *http.Request {
	t.Helper()
	var got *http.Request
	h, err := New(context.Background(), http.HandlerFunc(func(_ http.ResponseWriter, r *http.Request) { got = r }), c, "test")
	if err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest(http.MethodGet, "https://"+host+"/", nil)
	req.RemoteAddr = remote
	for k, v := range headers {
		req.Header[k] = []string{v}
	}
	h.ServeHTTP(httptest.NewRecorder(), req)
	if got == nil {
		t.Fatalf("%s from %s was not passed on", host, remote)
	}
	return got
}

func config() *Config {
	return &Config{IPv4: "240.0.0.0/4", IPv6: "3fff::/20", Period: "24h"}
}

func addr(t *testing.T, r *http.Request) netip.Addr {
	t.Helper()
	ap, err := netip.ParseAddrPort(r.RemoteAddr)
	if err != nil {
		t.Fatal(err)
	}
	if r.Header.Get("X-Real-Ip") != ap.Addr().String() {
		t.Fatalf("X-Real-Ip %q, RemoteAddr %q", r.Header.Get("X-Real-Ip"), r.RemoteAddr)
	}
	return ap.Addr()
}

func TestStableWithinHostAndPeriod(t *testing.T) {
	a := addr(t, seen(t, config(), "a.example", "198.51.100.7:1000", nil))
	if b := addr(t, seen(t, config(), "A.Example.:443", "198.51.100.7:2000", nil)); a != b {
		t.Fatalf("same client and host: %s, %s", a, b)
	}
	if !netip.MustParsePrefix("240.0.0.0/4").Contains(a) {
		t.Fatalf("%s outside the IPv4 range", a)
	}
	if b := addr(t, seen(t, config(), "b.example", "198.51.100.7:1000", nil)); a == b {
		t.Fatalf("two hosts share %s", a)
	}
	if b := addr(t, seen(t, config(), "a.example", "198.51.100.8:1000", nil)); a == b {
		t.Fatalf("two clients share %s", a)
	}
	if b := addr(t, seen(t, config(), "a.example", "[::ffff:198.51.100.7]:1000", nil)); a != b {
		t.Fatalf("mapped IPv4 differs: %s, %s", a, b)
	}
}

func TestIPv6ByPrefix(t *testing.T) {
	a := addr(t, seen(t, config(), "a.example", "[2001:db8:1:2:3:4:5:6]:1000", nil))
	if !netip.MustParsePrefix("3fff::/20").Contains(a) {
		t.Fatalf("%s outside the IPv6 range", a)
	}
	if b := addr(t, seen(t, config(), "a.example", "[2001:db8:1:2:ffff::1]:1000", nil)); a != b {
		t.Fatalf("same /64: %s, %s", a, b)
	}
	if b := addr(t, seen(t, config(), "a.example", "[2001:db8:1:3::1]:1000", nil)); a == b {
		t.Fatalf("two /64s share %s", a)
	}
}

func TestRotation(t *testing.T) {
	before := hostKey("a.example", 86400*10+86399, 86400)
	first := key
	if len(first) != 32 || bytes.Equal(first, make([]byte, 32)) {
		t.Fatalf("key %x", first)
	}
	if same := hostKey("a.example", 86400*10, 86400); string(same) != string(before) || &key[0] != &first[0] {
		t.Fatal("key changed within a period")
	}
	if after := hostKey("a.example", 86400*11, 86400); string(after) == string(before) {
		t.Fatal("key kept past its period")
	}
}

func TestClientHeadersRemoved(t *testing.T) {
	r := seen(t, config(), "a.example", "198.51.100.7:1000", map[string]string{
		"X-Forwarded-For": "192.0.2.1", "X-Real-Ip": "192.0.2.1", "Forwarded": "for=192.0.2.1",
		"X_forwarded_for": "192.0.2.1", "X.Real.Ip": "192.0.2.1", "True-Client-Ip": "192.0.2.1",
		"Cf-Connecting-Ip": "192.0.2.1", "X-ORIGINAL-FORWARDED-FOR": "192.0.2.1", "X-Client-Ip": "192.0.2.1",
		"X-Cluster-Client-Ip": "192.0.2.1", "Fastly-Client-Ip": "192.0.2.1", "X-Proxyuser-Ip": "192.0.2.1",
		"X-Envoy-External-Address": "192.0.2.1", "Client-Ip": "192.0.2.1", "X-Forwarded": "192.0.2.1",
		"Forwarded-For": "192.0.2.1", "X-Originating-Ip": "192.0.2.1", "X-Remote-Ip": "192.0.2.1",
		"X-Remote-Addr": "192.0.2.1", "Proxy-Client-Ip": "192.0.2.1", "Wl-Proxy-Client-Ip": "192.0.2.1",
		"X-Appengine-User-Ip": "192.0.2.1", "Cf-Pseudo-Ipv4": "192.0.2.1", "HTTP_CLIENT_IP": "192.0.2.1",
		"HTTP_X_FORWARDED_FOR": "192.0.2.1", "Accept": "text/html",
	})
	for name, values := range r.Header {
		for _, v := range values {
			if v == "192.0.2.1" || v == "for=192.0.2.1" {
				t.Fatalf("%s: %s kept", name, v)
			}
		}
	}
	if r.Header.Get("Accept") != "text/html" {
		t.Fatal("other headers changed")
	}
}

func TestRefusals(t *testing.T) {
	for _, c := range []*Config{
		{},
		{IPv4: "240.0.0.0/24", IPv6: "3fff::/20", Period: "24h"},
		{IPv4: "3fff::/20", IPv6: "3fff::/20", Period: "24h"},
		{IPv4: "240.0.0.0/4", IPv6: "3fff::/64", Period: "24h"},
		{IPv4: "240.0.0.0/4", IPv6: "::ffff:0:0/16", Period: "24h"},
		{IPv4: "240.0.0.0/4", IPv6: "3fff::/20", Period: "1m"},
	} {
		if _, err := New(context.Background(), http.NotFoundHandler(), c, "test"); err == nil {
			t.Fatalf("%+v accepted", c)
		}
	}
	h, _ := New(context.Background(), http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
		t.Fatal("passed on")
	}), config(), "test")
	req := httptest.NewRequest(http.MethodGet, "https://a.example/", nil)
	req.RemoteAddr = "@"
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusBadRequest {
		t.Fatal(rec.Code)
	}
}
