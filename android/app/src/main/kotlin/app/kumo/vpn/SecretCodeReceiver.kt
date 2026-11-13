package app.kumo.vpn

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * What the dialler hands over when the user dials `*#*#<code>#*#*` (a way Android keeps for apps).
 *
 * 5866: opens Kumo. For the user who hid its icon (Settings > Disguise) and has lost the shortcut they made.
 * 7263: erases the app's data, only when the user turned that on (`panicCode` in the settings file, off by default).
 *       A code that anybody could dial must not erase anything of a user who did not ask for it.
 */
class SecretCodeReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.data?.host) {
            "5866" -> context.startActivity(
                Intent(context, KumoActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
            "7263" -> {
                if (VpnControl.readJson(context, "settings.json")?.optBoolean("panicCode", false) != true) return
                val pending = goAsync()
                Thread {
                    try {
                        Wipe.run(context)
                    } finally {
                        pending.finish()
                        Wipe.end(null)
                    }
                }.start()
            }
        }
    }
}
