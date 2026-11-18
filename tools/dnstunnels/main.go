// kumo-dns: the program that carries the DNS tunnels (DNSTT, VayDNS, NoizDNS, Soar) and the SSH tunnels for Kumo.
//
// Kumo starts it the way it starts Xray, `kumo-dns run -c config.json`, and sends what a server is to carry to the local SOCKS5
// port it opens (see docs/dns-tunnels.md for the configuration and the links that make it). Whatever the tunnel is, the port is
// a SOCKS5 one (CONNECT), with a login of Kumo's own when one is given, so no other program on the computer can use it.
package main

import (
	"bufio"
	"context"
	"crypto/ed25519"
	"crypto/tls"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/coder/websocket"
	soar "github.com/getlantern/soar"
	vay "github.com/net2share/vaydns/client"
	"github.com/net2share/vaydns/turbotunnel"
	"golang.org/x/crypto/ssh"
	noiz "noizdns/mobile"
)

type sshConfig struct {
	Host      string `json:"host"`
	Port      int    `json:"port"`
	User      string `json:"user"`
	Pass      string `json:"pass"`
	Key       string `json:"key"`        // a private key (PEM)
	HostKey   string `json:"host_key"`   // the fingerprint of the server's key (SHA256:...), empty = not checked
	Transport string `json:"transport"`  // tcp (default), tls, ws, http
	SNI       string `json:"sni"`        // tls, and ws over TLS
	WSPath    string `json:"ws_path"`    // ws
	WSHost    string `json:"ws_host"`    // ws: the Host header (and the name asked for in the TLS hello)
	WSTLS     bool   `json:"ws_tls"`     // ws over TLS (wss)
	ProxyHost string `json:"proxy_host"` // http: the HTTP proxy the connection is made through (CONNECT)
	ProxyPort int    `json:"proxy_port"`
	ProxyAs   string `json:"proxy_as"`   // http: the Host of the CONNECT request
	Payload   string `json:"payload"`    // base64: bytes sent before the SSH handshake
}

type config struct {
	Mode   string `json:"mode"` // dnstt, vaydns, noizdns, slipstream, soar or ssh
	Listen string `json:"listen"`
	User   string `json:"user"` // the login of the local SOCKS5 port
	Pass   string `json:"pass"`

	Domain    string   `json:"domain"`
	PubKey    string   `json:"pubkey"`
	Resolvers []string `json:"resolvers"` // udp://h:p (or h:p), tcp://h:p, tls://h:p, https://host/path

	// VayDNS (and DNSTT, which it speaks in its compatibility mode)
	Record   string  `json:"record"`    // txt, null, cname, a, aaaa, mx, ns, srv, caa
	MaxQname int     `json:"max_qname"` // 0 = the default of the mode
	RPS      float64 `json:"rps"`
	ClientID int     `json:"client_id"`
	UTLS     string  `json:"utls"`

	// NoizDNS
	Stealth       bool `json:"stealth"`
	Authoritative bool `json:"authoritative"`
	MaxPayload    int  `json:"max_payload"`

	// Slipstream (QUIC over DNS, run as a program of its own): the resolvers are UDP "host:port", the authoritative ones are
	// resolvers the user runs himself, the certificate (PEM) pins the server's, the congestion control is bbr or dcubic.
	AuthResolvers []string `json:"auth_resolvers"`
	Cert          string   `json:"cert"`
	CC            string   `json:"cc"`
	SlipstreamBin string   `json:"slipstream_bin"` // where the program is, when it is not next to this one

	// Soar
	Discovery  bool     `json:"discovery"`
	Country    string   `json:"country"`
	TCPMode    string   `json:"tcp_mode"`
	SafeQName  int      `json:"safe_qname"`
	Candidates []string `json:"candidates"`

	// What is at the far end of a DNS tunnel (not Soar, whose server dials the sites itself): a SOCKS5 server (with this login, if it
	// has one), or an SSH server.
	SocksUser string     `json:"socks_user"`
	SocksPass string     `json:"socks_pass"`
	SSH       *sshConfig `json:"ssh"`
}

// On Android Go's resolver cannot read the phone's DNS settings (there is no /etc/resolv.conf): the names this program looks up
// (a DoH or DoT resolver, an SSH server) are asked of a public resolver. The program is outside the VPN, so the question does not
// go into the tunnel; it is asked in plain DNS, and only for the names of the tunnel's own servers.
func init() {
	if runtime.GOOS == "android" {
		net.DefaultResolver = &net.Resolver{PreferGo: true, Dial: func(ctx context.Context, network, _ string) (net.Conn, error) {
			return (&net.Dialer{Timeout: 5 * time.Second}).DialContext(ctx, network, "8.8.8.8:53")
		}}
	}
}

func logf(format string, a ...any) { fmt.Fprintf(os.Stderr, "kumo-dns: "+format+"\n", a...) }
func fatal(format string, a ...any) {
	logf(format, a...)
	os.Exit(1)
}

func main() {
	if len(os.Args) != 4 || os.Args[1] != "run" || os.Args[2] != "-c" {
		fmt.Fprintln(os.Stderr, "usage: kumo-dns run -c config.json")
		os.Exit(2)
	}
	data, err := os.ReadFile(os.Args[3])
	if err != nil {
		fatal("%v", err)
	}
	var c config
	if err := json.Unmarshal(data, &c); err != nil {
		fatal("the configuration is not valid: %v", err)
	}
	if c.Listen == "" {
		fatal("no listen address")
	}
	dial, closeAll, err := start(&c)
	if err != nil {
		fatal("%v", err)
	}
	ln, err := net.Listen("tcp", c.Listen)
	if err != nil {
		fatal("%v", err)
	}
	logf("%s tunnel ready, SOCKS5 on %s", c.Mode, c.Listen)
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			go serveSocks(conn, c.User, c.Pass, dial)
		}
	}()
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)
	<-stop
	_ = ln.Close()
	closeAll()
}

type dialFunc func(ctx context.Context, addr string) (net.Conn, error)

// start runs the tunnel the mode names and returns how to open a connection to an address through it.
func start(c *config) (dialFunc, func(), error) {
	switch c.Mode {
	case "soar":
		dial, closeFn, err := startSoar(c)
		if err != nil || c.SSH == nil {
			return dial, closeFn, err
		}
		// Soar with SSH: the Soar server dials the SSH server itself, and the SSH session is made over that stream.
		sshDial, closeSSH := sshDialer(c.SSH, func(ctx context.Context) (net.Conn, error) {
			port := c.SSH.Port
			if port == 0 {
				port = 22
			}
			conn, err := dial(ctx, net.JoinHostPort(c.SSH.Host, strconv.Itoa(port)))
			if err != nil {
				return nil, err
			}
			return sendPayload(conn, c.SSH)
		})
		return sshDial, func() { closeSSH(); closeFn() }, nil
	case "ssh":
		d, closeFn := sshDialer(c.SSH, func(ctx context.Context) (net.Conn, error) { return dialSSHBase(ctx, c.SSH) })
		return d, closeFn, nil
	case "dnstt", "vaydns", "noizdns", "slipstream":
		local, stopTunnel, err := startDNS(c)
		if err != nil {
			return nil, nil, err
		}
		if c.SSH != nil {
			d, closeFn := sshDialer(c.SSH, func(ctx context.Context) (net.Conn, error) {
				return dialWithPayload(ctx, c.SSH, (&net.Dialer{Timeout: 15 * time.Second}).DialContext, local)
			})
			return d, func() { closeFn(); stopTunnel() }, nil
		}
		return func(ctx context.Context, addr string) (net.Conn, error) {
			conn, err := (&net.Dialer{Timeout: 15 * time.Second}).DialContext(ctx, "tcp", local)
			if err != nil {
				return nil, err
			}
			if err := socks5Connect(conn, c.SocksUser, c.SocksPass, addr); err != nil {
				_ = conn.Close()
				return nil, err
			}
			return conn, nil
		}, stopTunnel, nil
	}
	return nil, nil, fmt.Errorf("unknown tunnel %q (dnstt, vaydns, noizdns, soar or ssh)", c.Mode)
}

// ---------------------------------------------------------------- the DNS tunnels

func freeLocalAddr() (string, error) {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return "", err
	}
	defer l.Close()
	return l.Addr().String(), nil
}

// resolverOf splits "udp://h:p", "h:p", "tcp://h:p", "tls://h:p" and "https://..." into a kind and an address.
func resolverOf(r string) (kind, addr string) {
	r = strings.TrimSpace(r)
	for _, p := range []string{"udp", "tcp", "tls", "https"} {
		if strings.HasPrefix(r, p+"://") {
			if p == "https" {
				return p, r
			}
			return p, strings.TrimPrefix(r, p+"://")
		}
	}
	if _, _, err := net.SplitHostPort(r); err != nil {
		r = net.JoinHostPort(r, "53")
	}
	return "udp", r
}

// startDNS runs DNSTT, VayDNS or NoizDNS on a local TCP port (127.0.0.1) that leads to what the tunnel server forwards to.
func startDNS(c *config) (string, func(), error) {
	if c.Mode == "slipstream" {
		return startSlipstream(c)
	}
	if c.Domain == "" || c.PubKey == "" || len(c.Resolvers) == 0 {
		return "", nil, errors.New("a DNS tunnel needs a domain, a public key and a resolver")
	}
	local, err := freeLocalAddr()
	if err != nil {
		return "", nil, err
	}
	switch c.Mode {
	case "noizdns":
		// One address, or several separated by commas: the client keeps the health of each and uses the ones that answer.
		addrs := make([]string, 0, len(c.Resolvers))
		for _, r := range c.Resolvers {
			kind, a := resolverOf(r)
			switch kind {
			case "udp":
				addrs = append(addrs, a)
			default:
				addrs = append(addrs, kind+"://"+strings.TrimPrefix(a, kind+"://"))
			}
		}
		n, err := noiz.NewClient(strings.Join(addrs, ","), c.Domain, c.PubKey, local)
		if err != nil {
			return "", nil, err
		}
		n.SetNoizMode(true)
		n.SetStealthMode(c.Stealth)
		n.SetAuthoritativeMode(c.Authoritative)
		if c.MaxPayload > 0 {
			n.SetMaxPayload(c.MaxPayload)
		}
		if c.UTLS != "" {
			n.SetUTLSFingerprint(c.UTLS)
		}
		if err := n.Start(); err != nil {
			return "", nil, err
		}
		return local, n.Stop, nil
	default: // dnstt (the wire format of the original, which VayDNS speaks too) and vaydns
		kind, addr := resolverOf(c.Resolvers[0])
		var rt vay.ResolverType
		switch kind {
		case "udp":
			rt = vay.ResolverTypeUDP
		case "tls":
			rt = vay.ResolverTypeDOT
		case "https":
			rt = vay.ResolverTypeDOH
		default:
			return "", nil, errors.New("DNSTT and VayDNS take a UDP, DoT or DoH resolver (NoizDNS also takes TCP)")
		}
		dist := c.UTLS
		if dist == "" {
			dist = "4*random,3*Firefox_120,1*Firefox_105,3*Chrome_120,1*Chrome_102,1*iOS_14,1*iOS_13"
		}
		hello, err := vay.SampleUTLSDistribution(dist)
		if err != nil {
			return "", nil, fmt.Errorf("utls: %w", err)
		}
		resolver, err := vay.NewResolver(rt, addr)
		if err != nil {
			return "", nil, fmt.Errorf("resolver: %w", err)
		}
		resolver.UTLSClientHelloID = hello
		resolver.UDPWorkers = vay.DefaultUDPWorkers
		resolver.UDPTimeout = vay.DefaultUDPResponseTimeout
		ts, err := vay.NewTunnelServer(c.Domain, c.PubKey)
		if err != nil {
			return "", nil, err
		}
		compat := c.Mode == "dnstt"
		ts.DnsttCompat = compat
		ts.ClientIDSize = 2
		if c.ClientID > 0 {
			ts.ClientIDSize = c.ClientID
		}
		ts.MaxQnameLen = 101
		if compat {
			ts.MaxQnameLen = 253
		}
		if c.MaxQname > 0 {
			ts.MaxQnameLen = c.MaxQname
		}
		ts.RPS = c.RPS
		ts.RecordType = "txt"
		if c.Record != "" && !compat {
			ts.RecordType = c.Record
		}
		tunnel, err := vay.NewTunnel(resolver, ts)
		if err != nil {
			return "", nil, err
		}
		tunnel.IdleTimeout = vay.DefaultIdleTimeout
		tunnel.KeepAlive = vay.DefaultKeepAlive
		if compat {
			tunnel.IdleTimeout = vay.DnsttIdleTimeout
			tunnel.KeepAlive = vay.DnsttKeepAlive
		}
		tunnel.OpenStreamTimeout = vay.DefaultOpenStreamTimeout
		tunnel.MaxStreams = vay.DefaultMaxStreams
		tunnel.ReconnectMinDelay = vay.DefaultReconnectDelay
		tunnel.ReconnectMaxDelay = vay.DefaultReconnectMaxDelay
		tunnel.SessionCheckInterval = vay.DefaultSessionCheckInterval
		tunnel.PacketQueueSize = turbotunnel.QueueSize
		tunnel.KCPWindowSize = turbotunnel.QueueSize / 2
		tunnel.QueueOverflowMode = turbotunnel.DefaultQueueOverflowMode
		go func() {
			if err := tunnel.ListenAndServe(local); err != nil {
				logf("%v", err)
			}
		}()
		return local, func() { _ = tunnel.Close() }, nil
	}
}

func startSoar(c *config) (dialFunc, func(), error) {
	if c.Domain == "" || c.PubKey == "" {
		return nil, nil, errors.New("Soar needs a domain and a public key")
	}
	key, err := decodeKey(c.PubKey)
	if err != nil {
		return nil, nil, err
	}
	resolvers := make([]string, 0, len(c.Resolvers))
	for _, r := range c.Resolvers {
		_, a := resolverOf(r)
		resolvers = append(resolvers, a)
	}
	tcp := c.TCPMode
	if tcp == "" {
		tcp = "auto"
	}
	client, err := soar.NewClient(soar.Config{
		Zone:      strings.TrimSuffix(c.Domain, "."),
		ServerKey: key,
		Resolvers: resolvers,
		Discovery: soar.Discovery{Enabled: c.Discovery, Country: c.Country, Candidates: c.Candidates},
		SafeQName: c.SafeQName,
		TCP:       tcp,
	})
	if err != nil {
		return nil, nil, err
	}
	return func(ctx context.Context, addr string) (net.Conn, error) { return client.DialContext(ctx, "tcp", addr) },
		func() { _ = client.Close() }, nil
}

// decodeKey reads an Ed25519 public key given in hex or base64 (any alphabet).
func decodeKey(s string) (ed25519.PublicKey, error) {
	s = strings.TrimSpace(s)
	if len(s) == 2*ed25519.PublicKeySize {
		if b, err := hex.DecodeString(s); err == nil {
			return b, nil
		}
	}
	for _, enc := range []*base64.Encoding{base64.StdEncoding, base64.RawStdEncoding, base64.URLEncoding, base64.RawURLEncoding} {
		if b, err := enc.DecodeString(s); err == nil && len(b) == ed25519.PublicKeySize {
			return b, nil
		}
	}
	return nil, errors.New("the public key is not an Ed25519 one (32 bytes in hex or base64)")
}

// ---------------------------------------------------------------- SSH

// dialSSHBase opens the connection the SSH handshake goes over, by the transport the configuration names.
func dialSSHBase(ctx context.Context, s *sshConfig) (net.Conn, error) {
	if s == nil || s.Host == "" {
		return nil, errors.New("no SSH server")
	}
	port := s.Port
	if port == 0 {
		port = 22
	}
	target := net.JoinHostPort(s.Host, strconv.Itoa(port))
	d := &net.Dialer{Timeout: 15 * time.Second}
	switch s.Transport {
	case "ws":
		return dialWS(ctx, s, target, d)
	case "http":
		proxy := net.JoinHostPort(s.ProxyHost, strconv.Itoa(s.ProxyPort))
		conn, err := d.DialContext(ctx, "tcp", proxy)
		if err != nil {
			return nil, err
		}
		host := s.ProxyAs
		if host == "" {
			host = target
		}
		fmt.Fprintf(conn, "CONNECT %s HTTP/1.1\r\nHost: %s\r\n\r\n", target, host)
		resp, err := http.ReadResponse(bufio.NewReader(conn), nil)
		if err != nil || resp.StatusCode/100 != 2 {
			_ = conn.Close()
			return nil, fmt.Errorf("the proxy refused the CONNECT (%v)", err)
		}
		return sendPayload(conn, s)
	case "tls":
		raw, err := d.DialContext(ctx, "tcp", target)
		if err != nil {
			return nil, err
		}
		name := s.SNI
		if name == "" {
			name = s.Host
		}
		t := tls.Client(raw, &tls.Config{ServerName: name, InsecureSkipVerify: true}) //nolint:gosec // the SSH key is what is checked
		if err := t.HandshakeContext(ctx); err != nil {
			_ = raw.Close()
			return nil, err
		}
		return sendPayload(t, s)
	}
	return dialWithPayload(ctx, s, d.DialContext, target)
}

func dialWithPayload(ctx context.Context, s *sshConfig, dial func(context.Context, string, string) (net.Conn, error), target string) (net.Conn, error) {
	conn, err := dial(ctx, "tcp", target)
	if err != nil {
		return nil, err
	}
	return sendPayload(conn, s)
}

func sendPayload(conn net.Conn, s *sshConfig) (net.Conn, error) {
	if s.Payload != "" {
		b, err := base64.StdEncoding.DecodeString(s.Payload)
		if err != nil {
			_ = conn.Close()
			return nil, errors.New("the payload is not base64")
		}
		if _, err := conn.Write(b); err != nil {
			_ = conn.Close()
			return nil, err
		}
	}
	return conn, nil
}

func dialWS(ctx context.Context, s *sshConfig, target string, d *net.Dialer) (net.Conn, error) {
	scheme := "ws"
	if s.WSTLS {
		scheme = "wss"
	}
	host := s.WSHost
	if host == "" {
		host = target
	}
	path := s.WSPath
	if path == "" {
		path = "/"
	}
	name := s.SNI
	if name == "" {
		h, _, err := net.SplitHostPort(host)
		if err != nil {
			h = host
		}
		name = h
	}
	// The Host header and the name in the hello are the ones asked for; the connection goes to the address of the server.
	client := &http.Client{Transport: &http.Transport{
		DialContext:     func(ctx context.Context, network, _ string) (net.Conn, error) { return d.DialContext(ctx, network, target) },
		TLSClientConfig: &tls.Config{ServerName: name, InsecureSkipVerify: true}, //nolint:gosec // the SSH key is what is checked
	}}
	ws, _, err := websocket.Dial(ctx, scheme+"://"+host+path, &websocket.DialOptions{HTTPClient: client})
	if err != nil {
		return nil, err
	}
	ws.SetReadLimit(1 << 24)
	conn := websocket.NetConn(context.Background(), ws, websocket.MessageBinary)
	return sendPayload(conn, s)
}

// sshDialer opens connections to addresses through an SSH session made over [base], and makes the session again when it is gone.
func sshDialer(s *sshConfig, base func(context.Context) (net.Conn, error)) (dialFunc, func()) {
	var mu sync.Mutex
	var cur *ssh.Client
	get := func(ctx context.Context) (*ssh.Client, error) {
		mu.Lock()
		defer mu.Unlock()
		if cur != nil {
			return cur, nil
		}
		auths := []ssh.AuthMethod{}
		if s.Key != "" {
			signer, err := ssh.ParsePrivateKey([]byte(s.Key))
			if err != nil {
				return nil, fmt.Errorf("the SSH key: %w", err)
			}
			auths = append(auths, ssh.PublicKeys(signer))
		}
		if s.Pass != "" {
			auths = append(auths, ssh.Password(s.Pass), ssh.KeyboardInteractive(func(_, _ string, qs []string, _ []bool) ([]string, error) {
				a := make([]string, len(qs))
				for i := range a {
					a[i] = s.Pass
				}
				return a, nil
			}))
		}
		raw, err := base(ctx)
		if err != nil {
			return nil, err
		}
		cb := ssh.InsecureIgnoreHostKey() //nolint:gosec // replaced below when a fingerprint is given
		if s.HostKey != "" {
			cb = func(_ string, _ net.Addr, key ssh.PublicKey) error {
				if got := ssh.FingerprintSHA256(key); got != s.HostKey {
					return fmt.Errorf("the SSH server's key is %s, not %s", got, s.HostKey)
				}
				return nil
			}
		}
		_ = raw.SetDeadline(time.Now().Add(30 * time.Second))
		cc, chans, reqs, err := ssh.NewClientConn(raw, net.JoinHostPort(s.Host, strconv.Itoa(max(s.Port, 22))),
			&ssh.ClientConfig{User: s.User, Auth: auths, HostKeyCallback: cb, Timeout: 30 * time.Second})
		if err != nil {
			_ = raw.Close()
			return nil, err
		}
		_ = raw.SetDeadline(time.Time{})
		client := ssh.NewClient(cc, chans, reqs)
		cur = client
		go func() {
			_ = client.Wait()
			mu.Lock()
			if cur == client {
				cur = nil
			}
			mu.Unlock()
		}()
		go func() { // a quiet session is kept alive
			for {
				time.Sleep(20 * time.Second)
				mu.Lock()
				alive := cur == client
				mu.Unlock()
				if !alive {
					return
				}
				if _, _, err := client.SendRequest("keepalive@openssh.com", true, nil); err != nil {
					_ = client.Close()
					return
				}
			}
		}()
		return client, nil
	}
	return func(ctx context.Context, addr string) (net.Conn, error) {
			client, err := get(ctx)
			if err != nil {
				return nil, err
			}
			return client.Dial("tcp", addr)
		}, func() {
			mu.Lock()
			defer mu.Unlock()
			if cur != nil {
				_ = cur.Close()
			}
		}
}

// ---------------------------------------------------------------- SOCKS5

// socks5Connect asks the SOCKS5 server on [conn] (the far end of a tunnel) to connect to [addr].
func socks5Connect(conn net.Conn, user, pass, addr string) error {
	_ = conn.SetDeadline(time.Now().Add(30 * time.Second))
	defer conn.SetDeadline(time.Time{}) //nolint:errcheck
	methods := []byte{0}
	if user != "" {
		methods = []byte{0, 2}
	}
	if _, err := conn.Write(append([]byte{5, byte(len(methods))}, methods...)); err != nil {
		return err
	}
	reply := make([]byte, 2)
	if _, err := io.ReadFull(conn, reply); err != nil {
		return err
	}
	switch {
	case reply[0] != 5 || reply[1] == 0xff:
		return errors.New("the far end is not a SOCKS5 server that takes our login")
	case reply[1] == 2:
		req := append([]byte{1, byte(len(user))}, user...)
		req = append(append(req, byte(len(pass))), pass...)
		if _, err := conn.Write(req); err != nil {
			return err
		}
		if _, err := io.ReadFull(conn, reply); err != nil || reply[1] != 0 {
			return errors.New("the SOCKS5 server refused the login")
		}
	}
	host, portText, err := net.SplitHostPort(addr)
	if err != nil {
		return err
	}
	port, _ := strconv.Atoi(portText)
	req := []byte{5, 1, 0}
	if ip := net.ParseIP(host); ip != nil && ip.To4() != nil {
		req = append(append(req, 1), ip.To4()...)
	} else if ip != nil {
		req = append(append(req, 4), ip.To16()...)
	} else {
		req = append(append(req, 3, byte(len(host))), host...)
	}
	req = append(req, byte(port>>8), byte(port))
	if _, err := conn.Write(req); err != nil {
		return err
	}
	head := make([]byte, 4)
	if _, err := io.ReadFull(conn, head); err != nil {
		return err
	}
	if head[1] != 0 {
		return fmt.Errorf("the SOCKS5 server answered %d", head[1])
	}
	skip := 0
	switch head[3] {
	case 1:
		skip = 4 + 2
	case 4:
		skip = 16 + 2
	case 3:
		l := make([]byte, 1)
		if _, err := io.ReadFull(conn, l); err != nil {
			return err
		}
		skip = int(l[0]) + 2
	}
	_, err = io.CopyN(io.Discard, conn, int64(skip))
	return err
}

// serveSocks answers a SOCKS5 client on [c] (CONNECT only) and carries what it sends through [dial].
func serveSocks(c net.Conn, user, pass string, dial dialFunc) {
	defer c.Close()
	_ = c.SetDeadline(time.Now().Add(30 * time.Second))
	head := make([]byte, 2)
	if _, err := io.ReadFull(c, head); err != nil || head[0] != 5 {
		return
	}
	methods := make([]byte, head[1])
	if _, err := io.ReadFull(c, methods); err != nil {
		return
	}
	want := byte(0)
	if user != "" {
		want = 2
	}
	ok := false
	for _, m := range methods {
		if m == want {
			ok = true
		}
	}
	if !ok {
		_, _ = c.Write([]byte{5, 0xff})
		return
	}
	_, _ = c.Write([]byte{5, want})
	if want == 2 {
		v := make([]byte, 2)
		if _, err := io.ReadFull(c, v); err != nil || v[0] != 1 {
			return
		}
		u := make([]byte, v[1])
		if _, err := io.ReadFull(c, u); err != nil {
			return
		}
		pl := make([]byte, 1)
		if _, err := io.ReadFull(c, pl); err != nil {
			return
		}
		p := make([]byte, pl[0])
		if _, err := io.ReadFull(c, p); err != nil {
			return
		}
		if string(u) != user || string(p) != pass {
			_, _ = c.Write([]byte{1, 1})
			return
		}
		_, _ = c.Write([]byte{1, 0})
	}
	req := make([]byte, 4)
	if _, err := io.ReadFull(c, req); err != nil || req[0] != 5 {
		return
	}
	var host string
	switch req[3] {
	case 1:
		b := make([]byte, 4)
		if _, err := io.ReadFull(c, b); err != nil {
			return
		}
		host = net.IP(b).String()
	case 4:
		b := make([]byte, 16)
		if _, err := io.ReadFull(c, b); err != nil {
			return
		}
		host = net.IP(b).String()
	case 3:
		l := make([]byte, 1)
		if _, err := io.ReadFull(c, l); err != nil {
			return
		}
		b := make([]byte, l[0])
		if _, err := io.ReadFull(c, b); err != nil {
			return
		}
		host = string(b)
	default:
		return
	}
	pb := make([]byte, 2)
	if _, err := io.ReadFull(c, pb); err != nil {
		return
	}
	if req[1] == 3 { // UDP ASSOCIATE: for the DNS queries of the core (see serveUDP)
		serveUDP(c, dial)
		return
	}
	if req[1] != 1 { // otherwise only CONNECT
		_, _ = c.Write([]byte{5, 7, 0, 1, 0, 0, 0, 0, 0, 0})
		return
	}
	_ = c.SetDeadline(time.Time{})
	ctx, cancel := context.WithTimeout(context.Background(), 40*time.Second)
	up, err := dial(ctx, net.JoinHostPort(host, strconv.Itoa(int(pb[0])<<8|int(pb[1]))))
	cancel()
	if err != nil {
		logf("%s: %v", host, err)
		_, _ = c.Write([]byte{5, 4, 0, 1, 0, 0, 0, 0, 0, 0})
		return
	}
	defer up.Close()
	_, _ = c.Write([]byte{5, 0, 0, 1, 0, 0, 0, 0, 0, 0})
	done := make(chan struct{}, 2)
	go func() { _, _ = io.Copy(up, c); done <- struct{}{} }()
	go func() { _, _ = io.Copy(c, up); done <- struct{}{} }()
	<-done
}

// startSlipstream runs the client of Slipstream (a program of its own, Rust) on a local TCP port that leads to what the tunnel
// server forwards to, and stops it when this program stops.
func startSlipstream(c *config) (string, func(), error) {
	if c.Domain == "" || (len(c.Resolvers) == 0 && len(c.AuthResolvers) == 0) {
		return "", nil, errors.New("Slipstream needs a domain and a resolver")
	}
	bin := c.SlipstreamBin
	if bin == "" {
		self, err := os.Executable()
		if err != nil {
			return "", nil, err
		}
		dir := filepath.Dir(self)
		for _, name := range []string{"kumo-slipstream", "kumo-slipstream.exe", "libslipstream.so"} {
			if _, err := os.Stat(filepath.Join(dir, name)); err == nil {
				bin = filepath.Join(dir, name)
				break
			}
		}
	}
	if bin == "" {
		return "", nil, errors.New("the program of Slipstream is not next to kumo-dns")
	}
	local, err := freeLocalAddr()
	if err != nil {
		return "", nil, err
	}
	host, port, _ := net.SplitHostPort(local)
	args := []string{"--domain", c.Domain, "--tcp-listen-host", host, "--tcp-listen-port", port}
	for _, r := range c.Resolvers {
		kind, a := resolverOf(r)
		if kind != "udp" {
			return "", nil, errors.New("Slipstream takes UDP resolvers (ip:port)")
		}
		args = append(args, "--resolver", a)
	}
	for _, r := range c.AuthResolvers {
		_, a := resolverOf(r)
		args = append(args, "--authoritative", a)
	}
	if c.CC == "bbr" || c.CC == "dcubic" {
		args = append(args, "--congestion-control", c.CC)
	}
	certFile := ""
	if c.Cert != "" {
		f, err := os.CreateTemp("", "kumo-slipstream-*.pem")
		if err != nil {
			return "", nil, err
		}
		certFile = f.Name()
		_, _ = f.WriteString(c.Cert)
		_ = f.Close()
		args = append(args, "--cert", certFile)
	}
	cmd := exec.Command(bin, args...)
	cmd.Stdout = os.Stderr
	cmd.Stderr = os.Stderr
	dieWithParent(cmd)
	if err := cmd.Start(); err != nil {
		return "", nil, err
	}
	go func() {
		err := cmd.Wait()
		logf("slipstream stopped: %v", err)
	}()
	return local, func() {
		_ = cmd.Process.Kill()
		if certFile != "" {
			_ = os.Remove(certFile)
		}
	}, nil
}

// serveUDP answers UDP ASSOCIATE: the tunnels carry streams, not datagrams, so the one kind of datagram kept is a DNS query (to port
// 53): it is sent to the resolver it was meant for as DNS over TCP through the tunnel, and over HTTPS (DoH, to the same address)
// when the server of the tunnel allows no port 53. Everything else is dropped. The socket lives as long as the TCP connection of
// the association does.
func serveUDP(c net.Conn, dial dialFunc) {
	pc, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		_, _ = c.Write([]byte{5, 1, 0, 1, 0, 0, 0, 0, 0, 0})
		return
	}
	defer pc.Close()
	addr := pc.LocalAddr().(*net.UDPAddr)
	reply := append([]byte{5, 0, 0, 1}, addr.IP.To4()...)
	reply = append(reply, byte(addr.Port>>8), byte(addr.Port))
	if _, err := c.Write(reply); err != nil {
		return
	}
	_ = c.SetDeadline(time.Time{})
	go func() {
		_, _ = io.Copy(io.Discard, c)
		_ = pc.Close()
	}()
	buf := make([]byte, 65535)
	for {
		n, from, err := pc.ReadFrom(buf)
		if err != nil {
			return
		}
		pkt := append([]byte(nil), buf[:n]...)
		go answerDatagram(pc, from, pkt, dial)
	}
}

func answerDatagram(pc net.PacketConn, from net.Addr, pkt []byte, dial dialFunc) {
	// RSV(2) FRAG(1) ATYP ADDR PORT DATA
	if len(pkt) < 10 || pkt[0] != 0 || pkt[1] != 0 || pkt[2] != 0 {
		return
	}
	var host string
	var rest []byte
	switch pkt[3] {
	case 1:
		host, rest = net.IP(pkt[4:8]).String(), pkt[8:]
	case 4:
		if len(pkt) < 22 {
			return
		}
		host, rest = net.IP(pkt[4:20]).String(), pkt[20:]
	case 3:
		l := int(pkt[4])
		if len(pkt) < 5+l+2 {
			return
		}
		host, rest = string(pkt[5:5+l]), pkt[5+l:]
	default:
		return
	}
	if len(rest) < 3 || int(rest[0])<<8|int(rest[1]) != 53 {
		return
	}
	query := rest[2:]
	head := pkt[:len(pkt)-len(query)]
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	answer, err := dnsThroughTunnel(ctx, dial, host, query)
	if err != nil {
		logf("DNS %s: %v", host, err)
		return
	}
	_, _ = pc.WriteTo(append(append([]byte(nil), head...), answer...), from)
}

// dnsThroughTunnel asks the resolver [host] the DNS message [query] through the tunnel: over TCP on port 53, else DoH on port 443.
func dnsThroughTunnel(ctx context.Context, dial dialFunc, host string, query []byte) ([]byte, error) {
	if conn, err := dial(ctx, net.JoinHostPort(host, "53")); err == nil {
		defer conn.Close()
		_ = conn.SetDeadline(time.Now().Add(10 * time.Second))
		if _, err := conn.Write(append([]byte{byte(len(query) >> 8), byte(len(query))}, query...)); err == nil {
			head := make([]byte, 2)
			if _, err := io.ReadFull(conn, head); err == nil {
				answer := make([]byte, int(head[0])<<8|int(head[1]))
				if _, err := io.ReadFull(conn, answer); err == nil {
					return answer, nil
				}
			}
		}
	}
	client := &http.Client{
		Timeout: 10 * time.Second,
		Transport: &http.Transport{
			DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
				return dial(ctx, net.JoinHostPort(host, "443"))
			},
			TLSClientConfig: &tls.Config{ServerName: host, InsecureSkipVerify: true}, //nolint:gosec // an address, no name to check; the answer is only a DNS message
		},
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, "https://"+host+"/dns-query", strings.NewReader(string(query)))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/dns-message")
	req.Header.Set("Accept", "application/dns-message")
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("DoH answered %d", resp.StatusCode)
	}
	return io.ReadAll(io.LimitReader(resp.Body, 65535))
}