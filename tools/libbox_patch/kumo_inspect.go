package libbox

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	box "github.com/sagernet/sing-box"
	E "github.com/sagernet/sing/common/exceptions"
	M "github.com/sagernet/sing/common/metadata"
)

// Inspect is Kumo's addition to libbox, beside MeasureDelay (copied in by the workflow like it).
//
// It starts a throw-away sing-box instance that holds only the outbound tagged "proxy" and fetches each address
// of requestsJSON (a JSON list of {"url": "..."}) through it, at the same time, with nothing sent but a plain GET.
// For every address it answers (a JSON list in the same order) what came: whether it came, the status, how long
// it took, the first 4 KB of the page and, for an https address, whether the certificate the server was shown
// is valid for the name under the roots of the system and who issued it. A bad certificate does not stop the
// request (nothing private is sent, and the page is what is looked at); it is reported. Whether it comes from the
// server or from the network is decided by the app, which asks the same of the network without the server.
func Inspect(configContent string, requestsJSON string, timeoutMs int32) (result string, err error) {
	kumoGuard(&err, func() error {
		var workErr error
		result, workErr = inspect(configContent, requestsJSON, timeoutMs)
		return workErr
	})
	return
}

func inspect(configContent string, requestsJSON string, timeoutMs int32) (string, error) {
	var requests []struct {
		URL string `json:"url"`
	}
	if err := json.Unmarshal([]byte(requestsJSON), &requests); err != nil {
		return "", err
	}
	ctx := baseContext(nil)
	options, err := parseConfig(ctx, configContent)
	if err != nil {
		return "", err
	}
	ctx, cancel := context.WithTimeout(ctx, time.Duration(timeoutMs)*time.Millisecond)
	defer cancel()

	instance, err := box.New(box.Options{Context: ctx, Options: options})
	if err != nil {
		return "", err
	}
	defer instance.Close()
	if err = instance.Start(); err != nil {
		return "", err
	}
	outbound, loaded := instance.Outbound().Outbound("proxy")
	if !loaded {
		return "", E.New("outbound proxy not found")
	}
	dial := func(ctx context.Context, network, address string) (net.Conn, error) {
		return outbound.DialContext(ctx, network, M.ParseSocksaddr(address))
	}

	roots, _ := x509.SystemCertPool()
	results := make([]inspectResult, len(requests))
	var wg sync.WaitGroup
	for i := range requests {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			defer func() {
				if r := recover(); r != nil {
					results[i] = inspectResult{URL: requests[i].URL, Err: fmt.Sprint("panic: ", r)}
				}
			}()
			results[i] =inspectOne(ctx, dial, roots, requests[i].URL)
		}(i)
	}
	wg.Wait()
	data, err := json.Marshal(results)
	if err != nil {
		return "", err
	}
	return string(data), nil
}

type inspectResult struct {
	URL      string `json:"url"`
	OK       bool   `json:"ok"`
	Status   int    `json:"status"`
	Ms       int    `json:"ms"`
	Err      string `json:"err,omitempty"`
	TLS      bool   `json:"tls"`
	Verified *bool  `json:"verified,omitempty"`
	Issuer   string `json:"issuer,omitempty"`
	Size     int    `json:"size"`
	Body     string `json:"body,omitempty"`
}

func inspectOne(ctx context.Context, dial func(context.Context, string, string) (net.Conn, error), roots *x509.CertPool, target string) inspectResult {
	result := inspectResult{URL: target, TLS: strings.HasPrefix(target, "https://")}
	var mu sync.Mutex
	checked := false
	verified := false
	issuer := ""
	transport := &http.Transport{
		DisableKeepAlives: true,
		DialContext:       dial,
		TLSClientConfig: &tls.Config{
			// The certificate is judged below, so that a page with a bad one can still be read and reported.
			InsecureSkipVerify: true,
			VerifyConnection: func(state tls.ConnectionState) error {
				if len(state.PeerCertificates) == 0 {
					return nil
				}
				leaf := state.PeerCertificates[0]
				name := leaf.Issuer.CommonName
				if len(leaf.Issuer.Organization) > 0 {
					name = leaf.Issuer.Organization[0]
				}
				ok := false
				if roots != nil {
					intermediates := x509.NewCertPool()
					for _, c := range state.PeerCertificates[1:] {
						intermediates.AddCert(c)
					}
					_, err := leaf.Verify(x509.VerifyOptions{DNSName: state.ServerName, Roots: roots, Intermediates: intermediates})
					ok = err == nil
				}
				mu.Lock()
				checked = roots != nil
				verified = ok
				issuer = name
				mu.Unlock()
				return nil
			},
		},
	}
	defer transport.CloseIdleConnections()
	client := &http.Client{
		Transport:     transport,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
	requestCtx, cancel := context.WithTimeout(ctx, 12*time.Second)
	defer cancel()
	request, err := http.NewRequestWithContext(requestCtx, http.MethodGet, target, nil)
	if err != nil {
		result.Err = err.Error()
		return result
	}
	request.Header.Set("User-Agent", "Mozilla/5.0 (compatible; Kumo)")
	start := time.Now()
	response, err := client.Do(request)
	if err != nil {
		result.Err = err.Error()
		return result
	}
	defer response.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(response.Body, 4096))
	result.OK = true
	result.Status = response.StatusCode
	result.Ms = int(time.Since(start).Milliseconds())
	result.Size = len(body)
	result.Body = string(body)
	mu.Lock()
	if checked {
		v := verified
		result.Verified = &v
	}
	result.Issuer = issuer
	mu.Unlock()
	return result
}
