package main

import (
	"context"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"sync"
	"sync/atomic"
	"testing"
)

// TestProxyTransportReusesConnections checks that 8 concurrent clients of
// one host keep their connections: after a warm-up round, further rounds
// must not dial again. With Go's default of 2 idle connections per host,
// 6 of every 8 requests used to dial a new connection.
func TestProxyTransportReusesConnections(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		io.WriteString(w, "ok")
	}))
	defer srv.Close()

	var dials atomic.Int64
	var d net.Dialer
	tr := newProxyTransport(func(ctx context.Context, network, addr string) (net.Conn, error) {
		dials.Add(1)
		return d.DialContext(ctx, network, addr)
	})
	defer tr.CloseIdleConnections()

	const workers = 8
	round := func() {
		var wg sync.WaitGroup
		start := make(chan struct{})
		for i := 0; i < workers; i++ {
			wg.Add(1)
			go func(i int) {
				defer wg.Done()
				<-start
				req, _ := http.NewRequest("GET", fmt.Sprintf("%s/?i=%d", srv.URL, i), nil)
				resp, err := tr.RoundTrip(req)
				if err != nil {
					t.Error(err)
					return
				}
				io.Copy(io.Discard, resp.Body)
				resp.Body.Close()
			}(i)
		}
		close(start)
		wg.Wait()
	}
	round()
	warm := dials.Load()
	if warm > workers {
		t.Fatalf("warm-up dialled %d connections for %d workers", warm, workers)
	}
	for i := 0; i < 10; i++ {
		round()
	}
	if extra := dials.Load() - warm; extra != 0 {
		t.Fatalf("%d new connections after warm-up (want 0): idle pool per host too small", extra)
	}
	if tr.MaxIdleConnsPerHost < workers {
		t.Fatalf("MaxIdleConnsPerHost %d < %d workers", tr.MaxIdleConnsPerHost, workers)
	}
}
