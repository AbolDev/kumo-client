package app.kumo.vpn

import android.app.Activity
import android.content.Intent
import android.os.Bundle

/**
 * What the shortcuts of the launcher icon (a long press) start: connect with the last settings, or disconnect.
 * It has no screen. When there is nothing to repeat (a first run) or the system's consent for the VPN is missing,
 * the app opens to do it.
 */
class ShortcutActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        when (intent?.action) {
            ACTION_DISCONNECT -> if (VpnControl.isOn) VpnControl.stop(this)
            ACTION_CONNECT -> if (!VpnControl.isOn) {
                val started = try {
                    VpnControl.startLast(this)
                } catch (_: Exception) {
                    false
                }
                if (!started) {
                    startActivity(
                        Intent(this, KumoActivity::class.java)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
                    )
                }
            }
        }
        finish()
    }

    companion object {
        const val ACTION_CONNECT = "app.kumo.vpn.SHORTCUT_CONNECT"
        const val ACTION_DISCONNECT = "app.kumo.vpn.SHORTCUT_DISCONNECT"
    }
}
