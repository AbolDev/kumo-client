package protocol

import "github.com/sagernet/sing-box/option"

// TypeAmneziaWG is the type of the endpoint in a configuration of sing-box.
const TypeAmneziaWG = "amneziawg"

// AmneziaWGEndpointOptions are the options of a WireGuard endpoint with the obfuscation parameters of AmneziaWG beside
// them (the names of the configuration of AmneziaWG, in lower case). A `reserved` value of a peer is not used.
type AmneziaWGEndpointOptions struct {
	option.WireGuardEndpointOptions

	Jc   uint32 `json:"jc,omitempty"`
	Jmin uint32 `json:"jmin,omitempty"`
	Jmax uint32 `json:"jmax,omitempty"`
	S1   uint16 `json:"s1,omitempty"`
	S2   uint16 `json:"s2,omitempty"`
	S3   uint16 `json:"s3,omitempty"`
	S4   uint16 `json:"s4,omitempty"`
	H1   string `json:"h1,omitempty"`
	H2   string `json:"h2,omitempty"`
	H3   string `json:"h3,omitempty"`
	H4   string `json:"h4,omitempty"`
	I1   string `json:"i1,omitempty"`
	I2   string `json:"i2,omitempty"`
	I3   string `json:"i3,omitempty"`
	I4   string `json:"i4,omitempty"`
	I5   string `json:"i5,omitempty"`

	RandomTrailers         bool   `json:"random_trailers,omitempty"`
	DisableCookies         bool   `json:"disable_cookies,omitempty"`
	HeaderProtectionKey    string `json:"header_protection_key,omitempty"`
	ContentPaddingAddition string `json:"content_padding_addition,omitempty"`
	RekeyAfterTime         string `json:"rekey_after_time,omitempty"`
	RekeyTimeout           string `json:"rekey_timeout,omitempty"`
	RejectAfterTime        string `json:"reject_after_time,omitempty"`
	KeepaliveTimeout       string `json:"keepalive_timeout,omitempty"`
	MaxHandshakeAttempts   string `json:"max_handshake_attempts,omitempty"`
}