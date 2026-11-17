package amneziawg

import (
	"context"
	"net/netip"
	"time"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-tun"
	E "github.com/sagernet/sing/common/exceptions"
	"github.com/sagernet/sing/common/logger"
	N "github.com/sagernet/sing/common/network"
	"github.com/amnezia-vpn/amneziawg-go/v3/device"
	wgTun "github.com/amnezia-vpn/amneziawg-go/v3/tun"
)

type Device interface {
	wgTun.Device
	N.Dialer
	Start() error
	SetDevice(device *device.Device)
	Inet4Address() netip.Addr
	Inet6Address() netip.Addr
}

type DeviceOptions struct {
	Context        context.Context
	Logger         logger.ContextLogger
	System         bool
	Handler        tun.Handler
	UDPTimeout     time.Duration
	ICMPTimeout    time.Duration
	CreateDialer   func(interfaceName string) N.Dialer
	Name           string
	MTU            uint32
	Address        []netip.Prefix
	AllowedAddress []netip.Prefix
}

func NewDevice(options DeviceOptions) (Device, error) {
	if options.System {
		return nil, E.New("a system TUN device is not supported for AmneziaWG (the netstack device is used)")
	}
	return newStackDevice(options)
}

type NatDevice interface {
	Device
	CreateDestination(metadata adapter.InboundContext, routeContext tun.DirectRouteContext, timeout time.Duration) (tun.DirectRouteDestination, error)
}
