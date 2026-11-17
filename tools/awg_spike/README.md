# AmneziaWG glue: a trial

Not part of the app. The question: can the WireGuard code of sing-box 1.13.21 (`transport/wireguard`) run on the
reference `amneziawg-go` (module `github.com/amnezia-vpn/amneziawg-go/v3`) in place of `sagernet/wireguard-go`, so that
AmneziaWG servers are reached with the unchanged reference protocol code?

`amneziawg/` is a copy of `transport/wireguard` (sing-box v1.13.21, GPL-3.0-or-later) changed for it:

- imports of `conn`, `device` and `tun` are the ones of amneziawg-go;
- `device.NewDevice(tun, bind, logger)` (no context, no workers);
- `Bind.Send(bufs, ep)` without the offset, and no `SetReservedForEndpoint`;
- **the reserved bytes are gone**: sing-box's `ClientBind` writes zeros (or WARP's reserved bytes) into bytes 1 to 3 of
  every packet it sends and clears them in every packet it receives. In AmneziaWG those bytes are a part of the
  message type (`H1`..`H4`), so they must not be touched;
- no system TUN device (`device_system*.go` left out: they use `Device.InputPacket` and `tun.ErrTooManySegments`, which
  only sagernet's fork has) and no `StdNetBind` (it needs sagernet's control function);
- `AWGOptions`: the obfuscation parameters, written as UAPI lines of the device.

`amneziawg/interop_test.go` starts an unchanged `amneziawg-go` server in the process (netstack, echo on TCP) and connects
the glue to it: plain WireGuard, AmneziaWG 1.x, AmneziaWG 2.0 with ranges, and a control that must not connect.

Run by `.github/workflows/awg-spike.yml` on pushes to `spike/awg-*`.
