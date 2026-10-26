package app.kumo.vpn

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** After the phone starts: brings back the background update job and, if wanted, the last connection. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return
        val settings = VpnControl.readJson(context, "settings.json")
        if (settings?.optBoolean("autoUpdateSubs", true) != false) SubUpdateJob.schedule(context)
        if (settings?.optBoolean("autoConnect", false) != true) {
            IdleNotification.show(context)
            return
        }
        // Without the system's VPN consent there is nothing the app can do on its own.
        if (!VpnControl.startLast(context)) IdleNotification.show(context)
    }
}