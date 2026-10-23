// Package pseudonym is a Traefik middleware that replaces the client's address, before anything behind the gateway
// sees it, with HMAC(key, host, the client's /32 or /64) written into a reserved range of the same family. The key is
// random, never leaves the process's memory and is replaced at every multiple of the period since the Unix epoch, so
// no stored copy of it can trace a pseudonym back.
package pseudonym

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"fmt"
	"net/http"
	"net/netip"
	"strings"
	"sync"
	"time"
)

// Config holds the ranges pseudonyms are written into and how long a key lives.
type Config struct {
	IPv4   string `json:"ipv4,omitempty"`
	IPv6   string `json:"ipv6,omitempty"`
	Period string `json:"period,omitempty"`
}

// CreateConfig returns an empty configuration: every value must be given.
func CreateConfig() *Config {
	return &Config{}
}

type pseudonym struct {
	next   http.Handler
	v4, v6 netip.Prefix
	period int64
}

// Headers in which a client could name an address of its own choosing, compared in lower case with '_' and '.' as '-'.
var forged = map[string]bool{
	"forwarded": true, "forwarded-for": true, "x-forwarded": true, "x-forwarded-for": true, "x-real-ip": true,
	"x-original-forwarded-for": true, "true-client-ip": true, "client-ip": true, "x-client-ip": true,
	"x-cluster-client-ip": true, "cf-connecting-ip": true, "cf-pseudo-ipv4": true, "fastly-client-ip": true,
	"x-proxyuser-ip": true, "x-envoy-external-address": true, "x-originating-ip": true, "x-remote-ip": true,
	"x-remote-addr": true, "proxy-client-ip": true, "wl-proxy-client-ip": true, "x-appengine-user-ip": true,
	"http-client-ip": true, "http-x-forwarded-for": true,
}

var spelling = strings.NewReplacer("_", "-", ".", "-")

// One key per process, shared by every router's instance.
var (
	mu    sync.Mutex
	epoch int64 = -1
	key   []byte
	hosts map[string][]byte
)

// Wildcard hosts could otherwise grow the cache without bound within a period.
const maxHosts = 4096

// New checks the configuration; an error leaves every route that uses the middleware unserved.
func New(_ context.Context, next http.Handler, c *Config, _ string) (http.Handler, error) {
	v4, err := netip.ParsePrefix(c.IPv4)
	if err != nil || !v4.Addr().Is4() || v4.Bits() > 8 {
		return nil, fmt.Errorf("ipv4: want an IPv4 prefix no longer than /8, got %q", c.IPv4)
	}
	v6, err := netip.ParsePrefix(c.IPv6)
	if err != nil || !v6.Addr().Is6() || v6.Addr().Is4In6() || v6.Bits() > 48 {
		return nil, fmt.Errorf("ipv6: want an IPv6 prefix no longer than /48, got %q", c.IPv6)
	}
	period, err := time.ParseDuration(c.Period)
	if err != nil || period < time.Hour {
		return nil, fmt.Errorf("period: want a duration of at least 1h, got %q", c.Period)
	}
	return &pseudonym{next: next, v4: v4.Masked(), v6: v6.Masked(), period: int64(period / time.Second)}, nil
}

func hostKey(host string, now int64, period int64) []byte {
	mu.Lock()
	defer mu.Unlock()
	if e := now / period; e != epoch || key == nil {
		next := make([]byte, 32)
		// Since Go 1.24 this never returns an error; the process stops instead.
		_, _ = rand.Read(next)
		// One assignment each: yaegi v0.16.1 leaves key nil after `key, epoch, hosts = ...`.
		key = next
		epoch = e
		hosts = map[string][]byte{}
	}
	if k, ok := hosts[host]; ok {
		return k
	}
	m := hmac.New(sha256.New, key)
	m.Write([]byte(host))
	k := m.Sum(nil)
	if len(hosts) < maxHosts {
		hosts[host] = k
	}
	return k
}

// Host names differ in case, port and a trailing dot without naming another site.
func canonical(host string) string {
	if i := strings.LastIndexByte(host, ':'); i >= 0 && !strings.HasSuffix(host, "]") {
		host = host[:i]
	}
	return strings.TrimSuffix(strings.ToLower(host), ".")
}

// fill keeps the prefix's bits and takes the rest from h.
func fill(prefix netip.Prefix, h []byte) netip.Addr {
	b := prefix.Addr().AsSlice()
	n := prefix.Bits()
	for i := range b {
		var keep byte
		if r := n - 8*i; r >= 8 {
			keep = 0xff
		} else if r > 0 {
			keep = ^byte(0xff >> r)
		}
		b[i] = b[i]&keep | h[i]&^keep
	}
	a, _ := netip.AddrFromSlice(b)
	return a
}

func (p *pseudonym) ServeHTTP(w http.ResponseWriter, req *http.Request) {
	source, err := netip.ParseAddrPort(req.RemoteAddr)
	if err != nil {
		// Never pass on a request whose source can't be replaced.
		http.Error(w, http.StatusText(http.StatusBadRequest), http.StatusBadRequest)
		return
	}
	a := source.Addr().Unmap().WithZone("")
	m := hmac.New(sha256.New, hostKey(canonical(req.Host), time.Now().Unix(), p.period))
	prefix := p.v4
	if a.Is4() {
		b := a.As4()
		m.Write([]byte{4})
		m.Write(b[:])
	} else {
		b := a.As16()
		m.Write([]byte{6})
		m.Write(b[:8])
		prefix = p.v6
	}
	out := fill(prefix, m.Sum(nil))
	for name := range req.Header {
		if forged[spelling.Replace(strings.ToLower(name))] {
			delete(req.Header, name)
		}
	}
	req.Header.Set("X-Real-Ip", out.String())
	// Traefik's proxy appends this to X-Forwarded-For, which holds nothing else by now.
	req.RemoteAddr = netip.AddrPortFrom(out, 0).String()
	p.next.ServeHTTP(w, req)
}
