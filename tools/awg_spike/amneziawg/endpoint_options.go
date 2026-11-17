package amneziawg

import (
	"context"
	"fmt"
	"net/netip"
	"strings"
	"time"

	"github.com/sagernet/sing-tun"
	"github.com/sagernet/sing/common/logger"
	M "github.com/sagernet/sing/common/metadata"
	N "github.com/sagernet/sing/common/network"
)

type EndpointOptions struct {
	Context      context.Context
	Logger       logger.ContextLogger
	System       bool
	Handler      tun.Handler
	UDPTimeout   time.Duration
	ICMPTimeout  time.Duration
	Dialer       N.Dialer
	CreateDialer func(interfaceName string) N.Dialer
	Name         string
	MTU          uint32
	Address      []netip.Prefix
	PrivateKey   string
	ListenPort   uint16
	ResolvePeer  func(domain string) (netip.Addr, error)
	Peers        []PeerOptions
	Workers      int
	AWG          AWGOptions
}

// AWGOptions are the obfuscation parameters of an AmneziaWG server, as its configuration names them. Empty or zero
// means the parameter is not used (a header is a number, or a range "low-high"; an I packet is the text of its chain).
type AWGOptions struct {
	Jc, Jmin, Jmax   uint32
	S1, S2, S3, S4   uint16
	H1, H2, H3, H4   string
	I1, I2, I3, I4, I5 string
}

// ipcLines are the lines of the UAPI configuration of the device that carry the parameters.
func (o AWGOptions) ipcLines() string {
	var b strings.Builder
	add := func(key string, value any) { fmt.Fprintf(&b, "\n%s=%v", key, value) }
	if o.Jc != 0 {
		add("jc", o.Jc)
		add("jmin", o.Jmin)
		add("jmax", o.Jmax)
	}
	for i, s := range []uint16{o.S1, o.S2, o.S3, o.S4} {
		if s != 0 {
			add(fmt.Sprintf("s%d", i+1), s)
		}
	}
	for i, h := range []string{o.H1, o.H2, o.H3, o.H4} {
		if h != "" {
			add(fmt.Sprintf("h%d", i+1), h)
		}
	}
	for i, p := range []string{o.I1, o.I2, o.I3, o.I4, o.I5} {
		if p != "" {
			add(fmt.Sprintf("i%d", i+1), p)
		}
	}
	return b.String()
}

type PeerOptions struct {
	Endpoint                    M.Socksaddr
	PublicKey                   string
	PreSharedKey                string
	AllowedIPs                  []netip.Prefix
	PersistentKeepaliveInterval uint16
}
