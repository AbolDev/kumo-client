package amneziawg

import (
	"context"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"io"
	"net/netip"
	"testing"
	"time"

	amnConn "github.com/amnezia-vpn/amneziawg-go/v3/conn"
	amnDevice "github.com/amnezia-vpn/amneziawg-go/v3/device"
	"github.com/amnezia-vpn/amneziawg-go/v3/tun/netstack"
	"github.com/sagernet/sing-box/log"
	M "github.com/sagernet/sing/common/metadata"
	N "github.com/sagernet/sing/common/network"
	"github.com/sagernet/sing/service/pause"
)

// startServerAt is startServer with the addresses chosen: the server answers on [serverAddr] inside the tunnel (an echo
// on TCP 8080) and lets the client [clientAddr] (a prefix) in.
func startServerAt(t *testing.T, port int, serverAddr, clientAddr string, serverPrivate, clientPublic []byte, awg string) {
	t.Helper()
	tunDevice, tnet, err := netstack.CreateNetTUN([]netip.Addr{netip.MustParseAddr(serverAddr)}, nil, 1280)
	if err != nil {
		t.Fatal(err)
	}
	dev := amnDevice.NewDevice(tunDevice, amnConn.NewDefaultBind(), amnDevice.NewLogger(amnDevice.LogLevelError, "server: "))
	uapi := fmt.Sprintf("private_key=%s\nlisten_port=%d%s\npublic_key=%s\nallowed_ip=%s\n",
		hex.EncodeToString(serverPrivate), port, awg, hex.EncodeToString(clientPublic), clientAddr)
	if err := dev.IpcSet(uapi); err != nil {
		t.Fatalf("server config: %v", err)
	}
	if err := dev.Up(); err != nil {
		t.Fatal(err)
	}
	listener, err := tnet.ListenTCPAddrPort(netip.AddrPortFrom(netip.MustParseAddr(serverAddr), 8080))
	if err != nil {
		t.Fatal(err)
	}
	go func() {
		for {
			c, err := listener.Accept()
			if err != nil {
				return
			}
			go func() {
				defer c.Close()
				io.Copy(c, c)
			}()
		}
	}()
	t.Cleanup(func() {
		listener.Close()
		dev.Close()
	})
}

func startClient(t *testing.T, opts EndpointOptions) *Endpoint {
	t.Helper()
	ctx := pause.WithDefaultManager(context.Background())
	opts.Context = ctx
	opts.Logger = log.NewNOPFactory().Logger()
	opts.Dialer = N.SystemDialer
	if opts.MTU == 0 {
		opts.MTU = 1280
	}
	endpoint, err := NewEndpoint(opts)
	if err != nil {
		t.Fatalf("new endpoint: %v", err)
	}
	if err := endpoint.Start(false); err != nil {
		t.Fatalf("start: %v", err)
	}
	t.Cleanup(func() { endpoint.Close() })
	return endpoint
}

// echoTo sends a line to [host]:8080 through the tunnel of [endpoint] and expects it back.
func echoTo(endpoint *Endpoint, host string, wait time.Duration) error {
	ctx, cancel := context.WithTimeout(context.Background(), wait)
	defer cancel()
	c, err := endpoint.DialContext(ctx, "tcp", M.ParseSocksaddrHostPort(host, 8080))
	if err != nil {
		return fmt.Errorf("dial %s: %w", host, err)
	}
	defer c.Close()
	c.SetDeadline(time.Now().Add(wait))
	const line = "hello through amneziawg\n"
	if _, err := c.Write([]byte(line)); err != nil {
		return fmt.Errorf("write: %w", err)
	}
	got := make([]byte, len(line))
	if _, err := io.ReadFull(c, got); err != nil {
		return fmt.Errorf("read: %w", err)
	}
	if string(got) != line {
		return fmt.Errorf("echo is %q", got)
	}
	return nil
}

func b64(b []byte) string { return base64.StdEncoding.EncodeToString(b) }

const awg1Server = "\njc=4\njmin=40\njmax=70\ns1=15\ns2=23\nh1=1234567891\nh2=1234567892\nh3=1234567893\nh4=1234567894"

var awg1Client = AWGOptions{
	Jc: 4, Jmin: 40, Jmax: 70, S1: 15, S2: 23,
	H1: "1234567891", H2: "1234567892", H3: "1234567893", H4: "1234567894",
}

func singlePeer(port int, serverPublic []byte, allowed string, awg AWGOptions, addresses ...string) EndpointOptions {
	var prefixes []netip.Prefix
	for _, a := range addresses {
		prefixes = append(prefixes, netip.MustParsePrefix(a))
	}
	return EndpointOptions{
		Address: prefixes,
		Peers: []PeerOptions{{
			Endpoint:                    M.ParseSocksaddrHostPort("127.0.0.1", uint16(port)),
			PublicKey:                   b64(serverPublic),
			AllowedIPs:                  []netip.Prefix{netip.MustParsePrefix(allowed)},
			PersistentKeepaliveInterval: 2,
		}},
		AWG: awg,
	}
}

// I1..I5: the signature packets that the client sends before each handshake, in the tags of amneziawg-go.
func TestAmneziaWGSignaturePackets(t *testing.T) {
	serverPrivate, serverPublic := newKey(t)
	clientPrivate, clientPublic := newKey(t)
	startServerAt(t, 51841, "10.9.0.1", "10.9.0.2/32", serverPrivate, clientPublic, awg1Server)
	awg := awg1Client
	awg.I1 = "<b 0xc0ffee><t><r 16>"
	awg.I2 = "<rd 8><rc 4>"
	awg.I3 = "<b 0x1234abcd><r 24>"
	opts := singlePeer(51841, serverPublic, "10.9.0.0/24", awg, "10.9.0.2/32")
	opts.PrivateKey = b64(clientPrivate)
	if err := echoTo(startClient(t, opts), "10.9.0.1", 12*time.Second); err != nil {
		t.Fatal(err)
	}
}

// AmneziaWG 3: random trailers on both sides (the paddings S1..S4 set), the cookies of the client off.
func TestAmneziaWG3Flags(t *testing.T) {
	serverPrivate, serverPublic := newKey(t)
	clientPrivate, clientPublic := newKey(t)
	server := awg1Server + "\ns3=17\ns4=11\nrandom_trailers=true"
	startServerAt(t, 51842, "10.9.0.1", "10.9.0.2/32", serverPrivate, clientPublic, server)
	awg := awg1Client
	awg.S3, awg.S4 = 17, 11
	awg.RandomTrailers = true
	awg.DisableCookies = true
	opts := singlePeer(51842, serverPublic, "10.9.0.0/24", awg, "10.9.0.2/32")
	opts.PrivateKey = b64(clientPrivate)
	if err := echoTo(startClient(t, opts), "10.9.0.1", 12*time.Second); err != nil {
		t.Fatal(err)
	}
}

// Two peers: the bind is not the one of a single server (a socket that is not connected, both servers reached on it).
func TestTwoPeers(t *testing.T) {
	serverPrivateA, serverPublicA := newKey(t)
	serverPrivateB, serverPublicB := newKey(t)
	clientPrivate, clientPublic := newKey(t)
	startServerAt(t, 51843, "10.9.0.1", "10.9.0.2/32", serverPrivateA, clientPublic, awg1Server)
	startServerAt(t, 51844, "10.10.0.1", "10.9.0.2/32", serverPrivateB, clientPublic, awg1Server)
	opts := EndpointOptions{
		PrivateKey: b64(clientPrivate),
		Address:    []netip.Prefix{netip.MustParsePrefix("10.9.0.2/32")},
		Peers: []PeerOptions{
			{Endpoint: M.ParseSocksaddrHostPort("127.0.0.1", 51843), PublicKey: b64(serverPublicA), AllowedIPs: []netip.Prefix{netip.MustParsePrefix("10.9.0.0/24")}, PersistentKeepaliveInterval: 2},
			{Endpoint: M.ParseSocksaddrHostPort("127.0.0.1", 51844), PublicKey: b64(serverPublicB), AllowedIPs: []netip.Prefix{netip.MustParsePrefix("10.10.0.0/24")}, PersistentKeepaliveInterval: 2},
		},
		AWG: awg1Client,
	}
	client := startClient(t, opts)
	if err := echoTo(client, "10.9.0.1", 12*time.Second); err != nil {
		t.Fatalf("first server: %v", err)
	}
	if err := echoTo(client, "10.10.0.1", 12*time.Second); err != nil {
		t.Fatalf("second server: %v", err)
	}
}

// IPv6 inside the tunnel (the addresses of the tunnel are IPv6), the packets of the tunnel over IPv4.
func TestIPv6Inside(t *testing.T) {
	serverPrivate, serverPublic := newKey(t)
	clientPrivate, clientPublic := newKey(t)
	startServerAt(t, 51845, "fd00:9::1", "fd00:9::2/128", serverPrivate, clientPublic, awg1Server)
	opts := singlePeer(51845, serverPublic, "fd00:9::/64", awg1Client, "fd00:9::2/128")
	opts.PrivateKey = b64(clientPrivate)
	if err := echoTo(startClient(t, opts), "fd00:9::1", 12*time.Second); err != nil {
		t.Fatal(err)
	}
}

// IPv6 outside: the packets of the tunnel go to the server over IPv6 (::1).
func TestIPv6Outside(t *testing.T) {
	serverPrivate, serverPublic := newKey(t)
	clientPrivate, clientPublic := newKey(t)
	startServerAt(t, 51846, "10.9.0.1", "10.9.0.2/32", serverPrivate, clientPublic, awg1Server)
	opts := singlePeer(51846, serverPublic, "10.9.0.0/24", awg1Client, "10.9.0.2/32")
	opts.PrivateKey = b64(clientPrivate)
	opts.Peers[0].Endpoint = M.ParseSocksaddrHostPort("::1", 51846)
	if err := echoTo(startClient(t, opts), "10.9.0.1", 12*time.Second); err != nil {
		t.Fatal(err)
	}
}