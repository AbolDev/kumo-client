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

// MeasureSpeed is Kumo's addition to libbox, beside MeasureDelay (copied in by tools/build_libbox.ps1 and the
// workflow).
//
// It starts a throw-away sing-box instance that holds only the outbound tagged "proxy" and measures how fast
// data goes through it, in Mbit/s. With upload false it downloads testURL and counts what arrives from the
// first byte until the end or the timeout; with upload true it sends size bytes to testURL and counts the time
// from the first byte sent until the server has answered. timeoutMs is for the whole, set-up included; when it
// runs out in the middle of an upload, the speed is that of what was sent until then (a slow line still gets
// its number instead of nothing).
func MeasureSpeed(configContent string, testURL string, upload bool, size int32, timeoutMs int32) (float64, error) {
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
		DisableKeepAlives: true,
		DialContext: func(ctx context.Context, network, address string) (net.Conn, error) {
			return outbound.DialContext(ctx, network, M.ParseSocksaddr(address))
		},
	}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport}

	if upload {
		body := &zeroReader{left: int64(size)}
		request, err := http.NewRequestWithContext(ctx, http.MethodPost, testURL, body)
		if err != nil {
			return 0, err
		}
		request.ContentLength = int64(size)
		request.Header.Set("Content-Type", "application/octet-stream")
		response, err := client.Do(request)
		if err != nil {
			// Out of time half-way: what went out so far tells the speed (at least 64 KB of it, or it is noise).
			if ctx.Err() != nil && body.sent >= 64*1024 && !body.first.IsZero() {
				seconds := time.Since(body.first).Seconds()
				if seconds < 0.05 {
					seconds = 0.05
				}
				return float64(body.sent) * 8 / seconds / 1e6, nil
			}
			return 0, err
		}
		_, _ = io.Copy(io.Discard, response.Body)
		response.Body.Close()
		if response.StatusCode >= 400 {
			return 0, E.New("bad status ", response.Status)
		}
		seconds := time.Since(body.first).Seconds()
		if body.first.IsZero() || seconds < 0.05 {
			seconds = 0.05
		}
		return float64(size) * 8 / seconds / 1e6, nil
	}

	request, err := http.NewRequestWithContext(ctx, http.MethodGet, testURL, nil)
	if err != nil {
		return 0, err
	}
	response, err := client.Do(request)
	if err != nil {
		return 0, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return 0, E.New("bad status ", response.Status)
	}
	var total int64
	var first time.Time
	buffer := make([]byte, 64*1024)
	for {
		n, err := response.Body.Read(buffer)
		if n > 0 {
			if first.IsZero() {
				first = time.Now()
			}
			total += int64(n)
		}
		if err != nil {
			break
		}
	}
	if first.IsZero() || total == 0 {
		return 0, E.New("nothing came")
	}
	seconds := time.Since(first).Seconds()
	if seconds < 0.05 {
		seconds = 0.05
	}
	return float64(total) * 8 / seconds / 1e6, nil
}

// zeroReader gives left bytes of zeros: the body of an upload. It keeps how much was taken and when the first
// of it was, for the speed of an upload that runs out of time.
type zeroReader struct {
	left  int64
	sent  int64
	first time.Time
}

func (z *zeroReader) Read(p []byte) (int, error) {
	if z.left <= 0 {
		return 0, io.EOF
	}
	if z.first.IsZero() {
		z.first = time.Now()
	}
	if int64(len(p)) > z.left {
		p = p[:z.left]
	}
	for i := range p {
		p[i] = 0
	}
	z.left -= int64(len(p))
	z.sent += int64(len(p))
	return len(p), nil
}
