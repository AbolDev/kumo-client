# AmneziaWG in libbox

An endpoint of type `amneziawg` for sing-box: the WireGuard code of sing-box 1.13 (`transport/wireguard`,
GPL-3.0-or-later) on the reference `github.com/amnezia-vpn/amneziawg-go/v3` (MIT) instead of `sagernet/wireguard-go`, so that
AmneziaWG servers are reached with the unchanged reference protocol code.

- `amneziawg/transport/`: the copy of `transport/wireguard`, changed for amneziawg-go (its `NewDevice`, `Send` without an
  offset, its own `conn`, `device` and `tun` types; no system TUN device; the bytes 1 to 3 of a packet are left alone,
  since they are a part of the message type that AmneziaWG sets).
- `amneziawg/protocol/`: the endpoint for sing-box (a copy of `protocol/wireguard`) and its options: the options of a
  WireGuard endpoint with `jc`, `jmin`, `jmax`, `s1`..`s4`, `h1`..`h4`, `i1`..`i5` and the options of AmneziaWG 3.
- `apply_amneziawg.sh`: copies both into a sing-box tree, registers the type in `include/registry.go` and adds the module.

It was tried in the `archive/awg-spike` tag (the old `spike/awg-glue` branch; `tools/awg_spike`) against a server of amneziawg-go in the same process and a
program of it with a TUN device of the kernel: WireGuard, AmneziaWG 1.x, 2.0 (ranges), the signature packets, two peers,
IPv6, and as an endpoint of sing-box read from JSON.

Only the Android build (libbox) has it. The cores of the computers are the official sing-box releases, which have no such
endpoint.