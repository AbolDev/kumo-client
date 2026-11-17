package protocol

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
	box "github.com/sagernet/sing-box"
	"github.com/sagernet/sing-box/include"
	"github.com/sagernet/sing-box/option"
	sjson "github.com/sagernet/sing/common/json"
	"golang.org/x/crypto/curve25519"
	"golang.org/x/net/proxy"
)

// The whole way: a configuration of sing-box with an endpoint of type "amneziawg" (read by sing-box from JSON), a SOCKS
// inbound routed to it, and an unchanged amneziawg-go server behind it.

func key(t *testing.T) (private, public []byte) {
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

func freePort(t *testing.T) int {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port
}

func TestSingBoxEndToEnd(t *testing.T) {
	serverPrivate, serverPublic := key(t)
	clientPrivate, clientPublic := key(t)
	const udpPort = 51861

	// the server: the reference implementation, an echo inside the tunnel
	tunDevice, tnet, err := netstack.CreateNetTUN([]netip.Addr{netip.MustParseAddr("10.9.0.1")}, nil, 1280)
	if err != nil {
		t.Fatal(err)
	}
	dev := amnDevice.NewDevice(tunDevice, amnConn.NewDefaultBind(), amnDevice.NewLogger(amnDevice.LogLevelError, "server: "))
	uapi := fmt.Sprintf("private_key=%s\nlisten_port=%d\njc=4\njmin=40\njmax=70\ns1=15\ns2=23\nh1=1234567891\nh2=1234567892\nh3=1234567893\nh4=1234567894\npublic_key=%s\nallowed_ip=10.9.0.2/32\n",
		hex.EncodeToString(serverPrivate), udpPort, hex.EncodeToString(clientPublic))
	if err := dev.IpcSet(uapi); err != nil {
		t.Fatal(err)
	}
	if err := dev.Up(); err != nil {
		t.Fatal(err)
	}
	listener, err := tnet.ListenTCPAddrPort(netip.MustParseAddrPort("10.9.0.1:8080"))
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

	// sing-box: the registries of the build with ours added
	endpoints := include.EndpointRegistry()
	RegisterEndpoint(endpoints)
	ctx := box.Context(context.Background(), include.InboundRegistry(), include.OutboundRegistry(), endpoints, include.DNSTransportRegistry(), include.ServiceRegistry())
	socksPort := freePort(t)
	config := fmt.Sprintf(`{
  "log": {"level": "error"},
  "inbounds": [{"type": "socks", "tag": "in", "listen": "127.0.0.1", "listen_port": %d}],
  "endpoints": [{
    "type": "amneziawg", "tag": "awg", "mtu": 1280,
    "address": ["10.9.0.2/32"],
    "private_key": "%s",
    "peers": [{"address": "127.0.0.1", "port": %d, "public_key": "%s", "allowed_ips": ["10.9.0.0/24"], "persistent_keepalive_interval": 2}],
    "jc": 4, "jmin": 40, "jmax": 70, "s1": 15, "s2": 23,
    "h1": "1234567891", "h2": "1234567892", "h3": "1234567893", "h4": "1234567894"
  }],
  "route": {"final": "awg"}
}`, socksPort, base64.StdEncoding.EncodeToString(clientPrivate), udpPort, base64.StdEncoding.EncodeToString(serverPublic))
	options, err := sjson.UnmarshalExtendedContext[option.Options](ctx, []byte(config))
	if err != nil {
		t.Fatalf("read the configuration: %v", err)
	}
	instance, err := box.New(box.Options{Context: ctx, Options: options})
	if err != nil {
		t.Fatalf("new box: %v", err)
	}
	if err := instance.Start(); err != nil {
		t.Fatalf("start box: %v", err)
	}
	t.Cleanup(func() { instance.Close() })

	// a program that uses the proxy
	dialer, err := proxy.SOCKS5("tcp", fmt.Sprintf("127.0.0.1:%d", socksPort), nil, proxy.Direct)
	if err != nil {
		t.Fatal(err)
	}
	type result struct {
		conn net.Conn
		err  error
	}
	done := make(chan result, 1)
	go func() {
		c, err := dialer.Dial("tcp", "10.9.0.1:8080")
		done <- result{c, err}
	}()
	var c net.Conn
	select {
	case r := <-done:
		if r.err != nil {
			t.Fatalf("through the proxy: %v", r.err)
		}
		c = r.conn
	case <-time.After(15 * time.Second):
		t.Fatal("no connection through the proxy in 15 seconds")
	}
	defer c.Close()
	c.SetDeadline(time.Now().Add(10 * time.Second))
	const line = "hello through sing-box and amneziawg\n"
	if _, err := c.Write([]byte(line)); err != nil {
		t.Fatal(err)
	}
	got := make([]byte, len(line))
	if _, err := io.ReadFull(c, got); err != nil {
		t.Fatal(err)
	}
	if string(got) != line {
		t.Fatalf("echo is %q", got)
	}
}