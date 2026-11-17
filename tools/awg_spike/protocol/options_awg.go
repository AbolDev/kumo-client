package protocol

import awg "kumo.local/awgspike/amneziawg"

// AWG is the obfuscation parameters of the options, as the transport takes them.
func (o AmneziaWGEndpointOptions) AWG() awg.AWGOptions {
	return awg.AWGOptions{
		Jc: o.Jc, Jmin: o.Jmin, Jmax: o.Jmax,
		S1: o.S1, S2: o.S2, S3: o.S3, S4: o.S4,
		H1: o.H1, H2: o.H2, H3: o.H3, H4: o.H4,
		I1: o.I1, I2: o.I2, I3: o.I3, I4: o.I4, I5: o.I5,
		RandomTrailers: o.RandomTrailers, DisableCookies: o.DisableCookies,
		HeaderProtectionKey: o.HeaderProtectionKey, ContentPaddingAddition: o.ContentPaddingAddition,
		RekeyAfterTime: o.RekeyAfterTime, RekeyTimeout: o.RekeyTimeout, RejectAfterTime: o.RejectAfterTime,
		KeepaliveTimeout: o.KeepaliveTimeout, MaxHandshakeAttempts: o.MaxHandshakeAttempts,
	}
}