package main

import (
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func setup(t *testing.T) (proxy *httptest.Server, tokenFile string, got *http.Header) {
	t.Helper()
	var h http.Header
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h = r.Header.Clone()
		io.WriteString(w, "ok:"+r.URL.Path)
	}))
	t.Cleanup(up.Close)
	u, _ := url.Parse(up.URL)
	tokenFile = filepath.Join(t.TempDir(), "token")
	proxy = httptest.NewServer(newHandler(u, tokenFile))
	t.Cleanup(proxy.Close)
	return proxy, tokenFile, &h
}

func TestInjectsTokenAndReplacesClientAuth(t *testing.T) {
	p, tf, h := setup(t)
	os.WriteFile(tf, []byte("tok-v1\n"), 0o600)

	req, _ := http.NewRequest("POST", p.URL+"/v1/chat/completions", strings.NewReader("{}"))
	req.Header.Set("Authorization", "Bearer placeholder")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	b, _ := io.ReadAll(resp.Body)
	if string(b) != "ok:/v1/chat/completions" {
		t.Fatalf("body = %q", b)
	}
	if got := h.Get("Authorization"); got != "Bearer tok-v1" {
		t.Fatalf("Authorization = %q", got)
	}
}

func TestPicksUpRotatedToken(t *testing.T) {
	p, tf, h := setup(t)
	os.WriteFile(tf, []byte("tok-v1"), 0o600)
	http.Get(p.URL + "/x")
	os.WriteFile(tf, []byte("tok-v2"), 0o600)
	http.Get(p.URL + "/x")
	if got := h.Get("Authorization"); got != "Bearer tok-v2" {
		t.Fatalf("Authorization = %q, want rotated token", got)
	}
}

func TestMissingTokenFailsClosed(t *testing.T) {
	p, _, h := setup(t)
	resp, err := http.Get(p.URL + "/x")
	if err != nil {
		t.Fatal(err)
	}
	if resp.StatusCode != http.StatusBadGateway {
		t.Fatalf("status = %d, want 502", resp.StatusCode)
	}
	if len(*h) != 0 {
		t.Fatal("request must not reach upstream without a token")
	}
}

func TestHealthz(t *testing.T) {
	p, tf, _ := setup(t)
	resp, _ := http.Get(p.URL + "/healthz")
	if resp.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("no token: status = %d", resp.StatusCode)
	}
	os.WriteFile(tf, []byte("t"), 0o600)
	resp, _ = http.Get(p.URL + "/healthz")
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("with token: status = %d", resp.StatusCode)
	}
}
