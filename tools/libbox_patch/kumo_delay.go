package libbox

import (
	"context"
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
// (no TUN, no inbound), fetches testURL through it and returns the time it took in
// milliseconds: a "real delay" that includes the proxy handshake, unlike a bare TCP connect.
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

	client := &http.Client{
		Transport: &http.Transport{
			DisableKeepAlives: true,
			DialContext: func(ctx context.Context, network, address string) (net.Conn, error) {
				return outbound.DialContext(ctx, network, M.ParseSocksaddr(address))
			},
		},
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, testURL, nil)
	if err != nil {
		return 0, err
	}
	start := time.Now()
	response, err := client.Do(request)
	if err != nil {
		return 0, err
	}
	response.Body.Close()
	if response.StatusCode >= 500 {
		return 0, E.New("bad status ", response.Status)
	}
	return int32(time.Since(start).Milliseconds()), nil
}
