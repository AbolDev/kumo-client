package app.kumo.vpn

import android.content.Context
import android.content.Intent
import android.net.VpnService
import androidx.core.content.ContextCompat
import org.json.JSONObject
import java.io.File

/** Connect / disconnect without the app's window: used by the boot receiver, the tile and the widget. */
object VpnControl {
    /** Repeats the last connection. False when there is nothing to repeat or the system consent is missing. */
    fun startLast(context: Context): Boolean {
        if (VpnService.prepare(context) != null) return false
        val config = File(context.filesDir, "active_config.json")
        if (!config.exists()) return false

        val last = readJson(context, "last_start.json")
        val names = ArrayList<String>()
        last?.optJSONArray("names")?.let { for (i in 0 until it.length()) names.add(it.getString(i)) }
        val start = Intent(context, BoxVpnService::class.java)
            .putExtra(BoxVpnService.EXTRA_CONFIG_PATH, config.path)
            .putStringArrayListExtra(BoxVpnService.EXTRA_SERVER_NAMES, names)
            .putExtra(BoxVpnService.EXTRA_SHOW_SPEED, last?.optBoolean("showSpeed", true) ?: true)
            .putExtra(BoxVpnService.EXTRA_SHOW_VOLUME, last?.optBoolean("showVolume", false) ?: false)
            .putExtra(BoxVpnService.EXTRA_SHOW_NAME, last?.optBoolean("showName", true) ?: true)
            .putExtra(BoxVpnService.EXTRA_KILL_SWITCH, last?.optBoolean("killSwitch", false) ?: false)
        val xrayPort = last?.optInt("xrayPort", 0) ?: 0
        val xray = File(context.filesDir, "xray_config.json")
        if (xrayPort > 0 && xray.exists()) {
            start.putExtra(BoxVpnService.EXTRA_XRAY_CONFIG_PATH, xray.path)
                .putExtra(BoxVpnService.EXTRA_XRAY_PORT, xrayPort)
        }
        ContextCompat.startForegroundService(context, start)
        return true
    }

    fun stop(context: Context) {
        context.startService(Intent(context, BoxVpnService::class.java).setAction(BoxVpnService.ACTION_STOP))
    }

    val isOn: Boolean
        get() = VpnBridge.status == VpnBridge.STARTED || VpnBridge.status == VpnBridge.STARTING

    /** Returns false when the app has to be opened (first run, or the VPN consent is missing). */
    fun toggle(context: Context): Boolean {
        if (isOn) {
            stop(context)
            return true
        }
        return try {
            startLast(context)
        } catch (_: Exception) {
            false
        }
    }

    fun readJson(context: Context, name: String): JSONObject? = try {
        JSONObject(File(context.filesDir, name).readText())
    } catch (_: Exception) {
        null
    }
}