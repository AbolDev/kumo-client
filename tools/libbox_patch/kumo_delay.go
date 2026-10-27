package libbox

import (
	"context"
	"io"
	"net"
	"net/http"
	"time"

	box "github.com/sagernet/sing-box"
	E "github.com/sagernet/sing/common/exceptions"
	M "github.com/sagernet/sing/common/metadata"
)

// MeasureDelay is Kumo's addition to libbox (copied in by tools/build_libbox.ps1).
//
// It starts a throw-away sing-box instance that holds only the outbound tagged "proxy"
// (no TUN, no inbound) and fetches testURL through it twice over one kept-alive connection. The
// first request opens everything on the way (TCP, TLS or WebSocket to the server, and from the
// server to the page); the time of the second one is returned in milliseconds: the round trip that
// traffic through the server then sees, which other clients (v2rayN) call the real delay. Timing the
// first request counts all of the set-up and came out about three times as high.
func MeasureDelay(configContent string, testURL string, timeoutMs int32) (int32, error) {
	ctx := baseContext(nil)
	options, err := parseConfig(ctx, configContent)
	if err != nil {
		return 0, err
	}
	ctx, cancel := context.WithTimeout(ctx, time.Duration(timeoutMs)*time.Millisecond)
	defer cancel()

	instance, err := box.New(box.Options{Context: ctx, Options: options})
	if err != nil {
		return 0, err
	}
	defer instance.Close()
	if err = instance.Start(); err != nil {
		return 0, err
	}
	outbound, loaded := instance.Outbound().Outbound("proxy")
	if !loaded {
		return 0, E.New("outbound proxy not found")
	}

	transport := &http.Transport{
		MaxIdleConns:        1,
		MaxIdleConnsPerHost: 1,
		DialContext: func(ctx context.Context, network, address string) (net.Conn, error) {
			return outbound.DialContext(ctx, network, M.ParseSocksaddr(address))
		},
	}
	defer transport.CloseIdleConnections()
	client := &http.Client{
		Transport:     transport,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
	fetch := func() (int32, error) {
		request, err := http.NewRequestWithContext(ctx, http.MethodGet, testURL, nil)
		if err != nil {
			return 0, err
		}
		start := time.Now()
		response, err := client.Do(request)
		if err != nil {
			return 0, err
		}
		// read the body to its end so the connection can be used again
		_, _ = io.Copy(io.Discard, response.Body)
		response.Body.Close()
		if response.StatusCode >= 500 {
			return 0, E.New("bad status ", response.Status)
		}
		return int32(time.Since(start).Milliseconds()), nil
	}

	first, err := fetch()
	if err != nil {
		return 0, err
	}
	second, err := fetch()
	if err != nil {
		return first, nil
	}
	return second, nil
}
