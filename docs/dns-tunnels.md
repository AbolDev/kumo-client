# DNS tunnels and SSH tunnels in Kumo

Kumo carries these servers with its own program, `kumo-dns` (the source is in `tools/dnstunnels`), which it starts like Xray and
which opens a local SOCKS5 port (with a login of Kumo's own, so no other program on the computer can use it):

| scheme | tunnel | made from |
|---|---|---|
| `dnstt://` | DNSTT: DNS over KCP and Noise | the wire format of the original DNSTT, as VayDNS speaks it in its compatibility mode |
| `vaydns://` | VayDNS: DNSTT with a configurable wire format | [net2share/vaydns](https://github.com/net2share/vaydns) (CC0) |
| `noizdns://` | NoizDNS: DNSTT with cover traffic and a stealth encoding | [anonvector/noizdns](https://github.com/anonvector/noizdns) (AGPL-3.0) |
| `soar://` | Soar: all the resolvers at once, with discovery of more | [getlantern/soar](https://github.com/getlantern/soar) (Apache-2.0) |
| `ssh://…?transport=` | SSH over TLS, WebSocket or an HTTP proxy, or with a payload | `golang.org/x/crypto/ssh` |

## The links

These are Kumo's own links. There is no standard for the links of DNS tunnels, so Kumo's follow the shape the other links have
(`vless://`, `trojan://`): the scheme names the protocol, the user part holds the key of the server, the host is the domain of
the tunnel, the query holds the rest, and the fragment is the name.

```
dnstt://PUBLIC_KEY@t.example.com?resolver=udp://1.1.1.1:53&resolver=https://dns.google/dns-query#Name
```

Everything in a query is URL-encoded (`udp%3A%2F%2F1.1.1.1%3A53`).

### The keys every DNS tunnel has

| part | meaning |
|---|---|
| `PUBLIC_KEY@` | the public key of the tunnel server: 64 hex digits for DNSTT, VayDNS and NoizDNS; an Ed25519 key (hex or base64url) for Soar |
| host | the domain the tunnel server is the authority of (`t.example.com`) |
| `resolver=` | a recursive resolver, as many as you want (`resolver=` is repeated): `1.1.1.1` or `udp://1.1.1.1:53` (UDP), `tcp://1.1.1.1:53`, `tls://1.1.1.1:853` (DoT), `https://dns.google/dns-query` (DoH). DNSTT and VayDNS use the first one, NoizDNS and Soar all |
| `utls=` | the TLS fingerprint of DoH and DoT (`Chrome_120`, …); empty is a mix |
| `socks_user=`, `socks_pass=` | what the server forwards to is a SOCKS5 server that wants a login |
| `ssh=1`, `ssh_user=`, `ssh_pass=`, `ssh_key=`, `ssh_hostkey=` | what the server forwards to is an SSH server, and Kumo logs in to it and goes out through it. `ssh_key` is a private key, in base64; `ssh_hostkey` is the fingerprint (`SHA256:…`) the server's key must have |

### What belongs to one protocol

| protocol | keys |
|---|---|
| VayDNS | `record=` (`txt`, `null`, `cname`, `a`, `aaaa`, `mx`, `ns`, `srv`, `caa`), `qname=` (the longest name), `rps=` (queries a second), `clientid=` |
| NoizDNS | `stealth=1` (labels of random lengths), `authoritative=1`, `payload_size=` |
| Soar | `discovery=IR` (find more resolvers; the country picks the lists of its own), `tcp=` (`auto`, `on`, `only`, `off`), `safe_qname=`, `candidate=` (more resolvers to try). A Soar server dials the sites itself, so it has no `socks_*` and no `ssh_*` |

### SSH over a transport of its own

An `ssh://` link as before (`ssh://user:pass@host:port#name`, carried by sing-box) becomes one that kumo-dns carries when it names
a transport or a payload:

```
ssh://user:pass@host:443?transport=ws&ws_path=/ssh&ws_tls=1&ws_host=cdn.example.com#Name
```

| `transport=` | keys |
|---|---|
| `tls` | `sni=` the name in the TLS hello |
| `ws` | `ws_path=`, `ws_tls=1` (wss), `ws_host=` (the Host header and the name in the TLS hello), `sni=` |
| `http` | `proxy=host:port` of the HTTP proxy the connection is made through, `proxy_host=` the Host of the CONNECT request |
| any | `payload=` base64 of bytes sent before the SSH handshake; `ssh_key=` and `ssh_hostkey=` as above |

## Links of other apps

Kumo reads the links other apps make for these tunnels and turns each into the Kumo link of the same server (above): that is the link
Kumo shows and shares afterwards. Kumo never writes the formats below. When a link names no resolver (the spec of `dnst://` has no
field for one), Kumo uses `1.1.1.1` and `8.8.8.8` (UDP), as Hiddify's "auto" does.

| format | from | what is read |
|---|---|---|
| `slipnet://` | SlipNet and its server scripts, SlipGate, dnstt-kit, SlipStreamGUI | DNSTT, NoizDNS, VayDNS, Slipstream, Soar, SSH, with SSH over TLS, WebSocket, an HTTP proxy or a payload (SlipNet's fields 0 to 83). `slipnet-enc://` and `slipnet-bundle-enc://` (locked and encrypted exports) are refused |
| `rovunet://`, `veyra://` | Rovunet | the same record as `slipnet://` |
| `dnst://` | the net2share spec, dnstm and dnstc, Hiddify, Throne, Rawline | both forms: `dnst://domain/transport/backend?params#tag`, and base64url of JSON (with dnstm's `v` and `key`). Transports `dnstt`, `vaydns` (with `dnstt-compat` it is DNSTT), `slipstream`; backends `socks` and `ssh`. `resolver=` / `resolvers=` as an extension |
| `dnstm://` | older dnstc | the same JSON |
| `dnstt://`, `vaydns://`, `noizdns://`, `slipstream://` with `pubkey=` | Hiddify, Ghajar VPN | the key in `pubkey`, `resolver` as a list (with `dot://` and `https://`), Ghajar's `transport=udp\|dot\|doh`, `doh=`, `upstream=socks\|ssh` and the login in the user part. Hiddify's `dnstt://` is VayDNS unless `dnstt-compat` is true |
| `SLIPSTREAM://domain:53?dns=ip,ip#name` | Slipstreamplus | the resolvers in `dns=`, a login in the user part |
| `slipstream://` + base64url JSON | slipstream-client-android | domain, name and the SOCKS login |
| `soar://domain?pk=KEY&resolvers=..&country=ir` | Hiddify | also `soar://KEY@domain?resolvers=..` |
| `soar://` + base64url JSON (`whitedns.profile`) | WhiteDNS, Rawline, Throne | domain, `public_key`, resolvers, `soarSettings` (discovery, country, transport, safeQName) |
| `soar://profile?domains=..&key=..`, `soar://locked?data=..` | soar-tunnel | the first domain and the key; the resolvers are found by Soar |
| `velta://tunnel?v=1&zone=..&key=..` | Velta Tunnel | a Soar server |
| `dns://` + base64 JSON (`ps`, `addr`, `ns`, `pubkey`, `user`, `pass`) | the generators of NetMod profiles (dnstt-kit) | DNSTT, with SSH when there is a login. (Not NetMod's own word: the format is as the generator writes it) |
| `vless://…?type=kcp&fm=…` | Xray's XDNS | an ordinary VLESS link with a final mask: Xray carries it |

Refused, because Kumo has no tunnel for it: MasterDNS and its forks (`masterdns://`, `stormdns://`, `cottendns://`, `masterdnsvpn://`),
Shadowsocks or a custom backend behind a tunnel (`dnst://…/shadowsocks`, and `ss://…?plugin=slipstream`), ZedSecure's `zedsecure://`,
Zanoza's `zanoza://`, TUNA's `tuna://`, WhiteZia's `stormbundle://`.

Not found (no share link exists, or its format could not be read): HTTP Custom, HTTP Injector, HA Tunnel, NPV Tunnel and DarkTunnel
(encrypted files only), NetMod's own `.nm` files, DMVPN's `sn://dnstt?` (a Kryo serialisation), MasterDNS-Android-Client's `MDVPN3:`.

## What is not here

Slipstream (QUIC over DNS) is a program of Rust with C libraries (picoquic, OpenSSL), and is not built into kumo-dns.
