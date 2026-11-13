package app.kumo.vpn

import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import org.json.JSONObject
import java.io.File

/**
 * Erases what the app keeps: the servers and subscriptions, the settings, the usage numbers, the logs, the saved
 * connections, the caches. What stays is only what keeps the app looking as the user disguised it (the icon, the
 * name of its card in the list of recent apps, whether the dialled code erases), so that an erase does not make the
 * app show itself as Kumo.
 *
 * Nothing here asks: the app asks (see Settings > Disguise and erase), and [SecretCodeReceiver] only erases when the
 * user turned that on.
 */
object Wipe {
    /** The settings that stay through an erase. */
    private val kept = listOf("appIcon", "disguiseName", "panicCode", "language", "theme")

    /** What stays, read from the settings file as it is now. */
    fun keptSettings(context: Context): JSONObject {
        val old = VpnControl.readJson(context, "settings.json")
        val out = JSONObject()
        if (old != null) for (key in kept) if (old.has(key)) out.put(key, old.get(key))
        return out
    }

    /** Stops what runs, deletes everything and writes [keep] as the new settings. Does not end the process. */
    fun run(context: Context, keep: JSONObject = keptSettings(context)) {
        val app = context.applicationContext
        // Nothing may go on running with the files that are about to go.
        runCatching { if (VpnControl.isOn) VpnControl.stop(app) }
        runCatching {
            app.startService(Intent(app, BoxVpnService::class.java).setAction(BoxVpnService.ACTION_STOP_PROXY))
        }
        runCatching { app.getSystemService(NotificationManager::class.java).cancelAll() }
        runCatching { SubUpdateJob.cancel(app) }
        // The name and icon of the disguise are kept: the card of the app in the recent apps shows them, and an
        // erase must not make it show Kumo.
        val look = runCatching { File(app.filesDir, "disguise_icon.png").takeIf { it.exists() }?.readBytes() }.getOrNull()
        val lookName = runCatching { File(app.filesDir, "disguise_name.txt").takeIf { it.exists() }?.readText() }.getOrNull()
        app.filesDir.listFiles()?.forEach { runCatching { it.deleteRecursively() } }
        app.cacheDir.listFiles()?.forEach { runCatching { it.deleteRecursively() } }
        runCatching { app.codeCacheDir.listFiles()?.forEach { it.deleteRecursively() } }
        for (name in listOf("usage_alerts", "widgets")) {
            runCatching { app.getSharedPreferences(name, Context.MODE_PRIVATE).edit().clear().commit() }
        }
        runCatching { File(app.filesDir, "settings.json").writeText(keep.toString()) }
        if (look != null) runCatching { File(app.filesDir, "disguise_icon.png").writeBytes(look) }
        if (lookName != null) runCatching { File(app.filesDir, "disguise_name.txt").writeText(lookName) }
    }

    /** Ends the app after an erase: its window, its card in the recent apps, and its process (nothing of it may
     *  write a file back). */
    fun end(activity: android.app.Activity?) {
        activity?.finishAndRemoveTask()
        Handler(Looper.getMainLooper()).postDelayed({ android.os.Process.killProcess(android.os.Process.myPid()) }, 400)
    }
}
