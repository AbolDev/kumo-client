package amneziawg

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"io"
	"net"
	"net/netip"
	"testing"
	"time"

	amnConn "github.com/amnezia-vpn/amneziawg-go/v3/conn"
	amnDevice "github.com/amnezia-vpn/amneziawg-go/v3/device"
	"github.com/amnezia-vpn/amneziawg-go/v3/tun/netstack"
	"github.com/sagernet/sing-box/log"
	M "github.com/sagernet/sing/common/metadata"
	N "github.com/sagernet/sing/common/network"
	"github.com/sagernet/sing/service"
	"github.com/sagernet/sing/service/pause"
	"golang.org/x/crypto/curve25519"
)

// The glue of this package (the client, from sing-box) against an unchanged amneziawg-go server: the server is the
// reference implementation, in the same process, with a netstack behind it that echoes what a TCP connection sends.

func newKey(t *testing.T) (private, public []byte) {
	t.Helper()
	private = make([]byte, 32)
	if _, err := rand.Read(private); err != nil {
		t.Fatal(err)
	}
	private[0] &= 248
	private[31] = (private[31] & 127) | 64
	public, err := curve25519.X25519(private, curve25519.Basepoint)
	if err != nil {
		t.Fatal(err)
	}
	return private, public
}

// startServer runs the reference server on 127.0.0.1:port with the UAPI lines [awg] of its obfuscation parameters (each
// starts with a new line). It echoes TCP on 10.9.0.1:8080 inside the tunnel.
func startServer(t *testing.T, port int, serverPrivate, clientPublic []byte, awg string) {
	t.Helper()
	tunDevice, tnet, err := netstack.CreateNetTUN([]netip.Addr{netip.MustParseAddr("10.9.0.1")}, nil, 1280)
	if err != nil {
		t.Fatal(err)
	}
	dev := amnDevice.NewDevice(tunDevice, amnConn.NewDefaultBind(), amnDevice.NewLogger(amnDevice.LogLevelError, "server: "))
	uapi := fmt.Sprintf("private_key=%s\nlisten_port=%d%s\npublic_key=%s\nallowed_ip=10.9.0.2/32\n",
		hex.EncodeToString(serverPrivate), port, awg, hex.EncodeToString(clientPublic))
	if err := dev.IpcSet(uapi); err != nil {
		t.Fatalf("server config: %v", err)
	}
	if err := dev.Up(); err != nil {
		t.Fatal(err)
	}
	listener, err := tnet.ListenTCP(&net.TCPAddr{Port: 8080})
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

// echoThroughClient starts the client (the glue) with [awg] and sends a line through the tunnel.
func echoThroughClient(t *testing.T, port int, clientPrivate, serverPublic []byte, awg AWGOptions, wait time.Duration) error {
	t.Helper()
	base := context.Background()
	ctx := service.ContextWith[pause.Manager](base, pause.NewDefaultManager(base))
	endpoint, err := NewEndpoint(EndpointOptions{
		Context: ctx,
		Logger:  log.NewNOPFactory().Logger(),
		Dialer:  N.SystemDialer,
		Address: []netip.Prefix{netip.MustParsePrefix("10.9.0.2/32")},
		MTU:     1280,
		PrivateKey: base64.StdEncoding.EncodeToString(clientPrivate),
		Peers: []PeerOptions{{
			Endpoint:                    M.ParseSocksaddrHostPort("127.0.0.1", uint16(port)),
			PublicKey:                   base64.StdEncoding.EncodeToString(serverPublic),
			AllowedIPs:                  []netip.Prefix{netip.MustParsePrefix("10.9.0.0/24")},
			PersistentKeepaliveInterval: 2,
		}},
		AWG: awg,
	})
	if err != nil {
		return fmt.Errorf("new endpoint: %w", err)
	}
	if err := endpoint.Start(false); err != nil {
		return fmt.Errorf("start: %w", err)
	}
	defer endpoint.Close()
	dialCtx, cancel := context.WithTimeout(ctx, wait)
	defer cancel()
	c, err := endpoint.DialContext(dialCtx, "tcp", M.ParseSocksaddrHostPort("10.9.0.1", 8080))
	if err != nil {
		return fmt.Errorf("dial through the tunnel: %w", err)
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

func run(t *testing.T, port int, server string, client AWGOptions) error {
	t.Helper()
	serverPrivate, serverPublic := newKey(t)
	clientPrivate, clientPublic := newKey(t)
	startServer(t, port, serverPrivate, clientPublic, server)
	return echoThroughClient(t, port, clientPrivate, serverPublic, client, 12*time.Second)
}

// Plain WireGuard: the glue must still work as an ordinary WireGuard client (no parameters on either side).
func TestPlainWireGuard(t *testing.T) {
	if err := run(t, 51831, "", AWGOptions{}); err != nil {
		t.Fatal(err)
	}
}

// AmneziaWG 1.x: junk packets, padding of the first two messages, four fixed message types.
func TestAmneziaWG1(t *testing.T) {
	server := "\njc=4\njmin=40\njmax=70\ns1=15\ns2=23\nh1=1234567891\nh2=1234567892\nh3=1234567893\nh4=1234567894"
	client := AWGOptions{
		Jc: 4, Jmin: 40, Jmax: 70, S1: 15, S2: 23,
		H1: "1234567891", H2: "1234567892", H3: "1234567893", H4: "1234567894",
	}
	if err := run(t, 51832, server, client); err != nil {
		t.Fatal(err)
	}
}

// AmneziaWG 2.0: padding of all four messages and the message types as ranges.
func TestAmneziaWG2Ranges(t *testing.T) {
	server := "\njc=5\njmin=30\njmax=80\ns1=17\ns2=29\ns3=19\ns4=11" +
		"\nh1=1000000-1000999\nh2=2000000-2000999\nh3=3000000-3000999\nh4=4000000-4000999"
	client := AWGOptions{
		Jc: 5, Jmin: 30, Jmax: 80, S1: 17, S2: 29, S3: 19, S4: 11,
		H1: "1000000-1000999", H2: "2000000-2000999", H3: "3000000-3000999", H4: "4000000-4000999",
	}
	if err := run(t, 51833, server, client); err != nil {
		t.Fatal(err)
	}
}

// The control: an AmneziaWG server and a client without the parameters must NOT connect. A test that cannot fail
// proves nothing.
func TestMismatchDoesNotConnect(t *testing.T) {
	serverPrivate, serverPublic := newKey(t)
	clientPrivate, clientPublic := newKey(t)
	startServer(t, 51834, serverPrivate, clientPublic, "\njc=4\njmin=40\njmax=70\ns1=15\ns2=23\nh1=1234567891\nh2=1234567892\nh3=1234567893\nh4=1234567894")
	err := echoThroughClient(t, 51834, clientPrivate, serverPublic, AWGOptions{}, 5*time.Second)
	if err == nil {
		t.Fatal("a client without the parameters connected to an AmneziaWG server")
	}
	t.Logf("as expected: %v", err)
}
