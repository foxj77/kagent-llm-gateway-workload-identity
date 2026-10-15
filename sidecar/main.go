// llm-token-proxy is a tiny sidecar reverse proxy that authenticates requests to the
// llm-gateway with the pod's projected ServiceAccount token.
//
// The token file is re-read on every request because the kubelet rotates it in place, so no
// credential is ever held in memory longer than a request. Any Authorization header sent by
// the client (e.g. a placeholder API key) is replaced.
package main

import (
	"errors"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"strings"
	"time"
)

func env(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

// readToken returns the trimmed contents of the projected token file.
func readToken(path string) (string, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	t := strings.TrimSpace(string(b))
	if t == "" {
		return "", errors.New("token file is empty")
	}
	return t, nil
}

func newHandler(upstream *url.URL, tokenFile string) http.Handler {
	proxy := &httputil.ReverseProxy{
		Rewrite: func(r *httputil.ProxyRequest) {
			r.SetURL(upstream)
			r.Out.Host = upstream.Host
			// Dropped client-supplied credentials; the token is set in the handler below.
			r.Out.Header.Del("Authorization")
			if t, ok := r.In.Context().Value(tokenKey{}).(string); ok {
				r.Out.Header.Set("Authorization", "Bearer "+t)
			}
		},
		// Flush immediately so SSE / streaming chat completions are not buffered.
		FlushInterval: -1,
		ErrorHandler: func(w http.ResponseWriter, r *http.Request, err error) {
			log.Printf("upstream error: %s %s: %v", r.Method, r.URL.Path, err)
			http.Error(w, "llm-token-proxy: upstream error", http.StatusBadGateway)
		},
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		if _, err := readToken(tokenFile); err != nil {
			http.Error(w, "token unavailable", http.StatusServiceUnavailable)
			return
		}
		w.WriteHeader(http.StatusOK)
	})
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		t, err := readToken(tokenFile)
		if err != nil {
			log.Printf("cannot read token: %v", err)
			http.Error(w, "llm-token-proxy: token unavailable", http.StatusBadGateway)
			return
		}
		proxy.ServeHTTP(w, r.WithContext(withToken(r.Context(), t)))
	})
	return mux
}

func main() {
	listen := env("LISTEN_ADDR", "127.0.0.1:8081")
	tokenFile := env("TOKEN_FILE", "/var/run/secrets/llm-gateway/token")
	upstreamRaw := env("UPSTREAM_URL", "http://llm-gateway.llm-gateway.svc.cluster.local:80")

	upstream, err := url.Parse(upstreamRaw)
	if err != nil || upstream.Scheme == "" || upstream.Host == "" {
		log.Fatalf("invalid UPSTREAM_URL %q", upstreamRaw)
	}

	srv := &http.Server{
		Addr:              listen,
		Handler:           newHandler(upstream, tokenFile),
		ReadHeaderTimeout: 10 * time.Second,
	}
	log.Printf("llm-token-proxy listening on %s -> %s (token: %s)", listen, upstream, tokenFile)
	log.Fatal(srv.ListenAndServe())
}
