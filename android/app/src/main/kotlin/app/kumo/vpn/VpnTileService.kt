package app.kumo.vpn

import android.app.PendingIntent
import android.content.Intent
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService

/** Quick Settings tile: one tap connects with the last settings or disconnects. */
class VpnTileService : TileService() {
    private val observer: (String, String?) -> Unit = { _, _ -> refresh() }

    override fun onStartListening() {
        VpnBridge.observers.add(observer)
        refresh()
    }

    override fun onStopListening() {
        VpnBridge.observers.remove(observer)
    }

    override fun onClick() {
        val done = try {
            VpnControl.toggle(this)
        } catch (_: Exception) {
            false
        }
        if (!done) openApp()
    }

    private fun openApp() {
        val intent = Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (android.os.Build.VERSION.SDK_INT >= 34) {
            startActivityAndCollapse(PendingIntent.getActivity(this, 0, intent, PendingIntent.FLAG_IMMUTABLE))
        } else {
            @Suppress("DEPRECATION")
            startActivityAndCollapse(intent)
        }
    }

    private fun refresh() {
        val tile = qsTile ?: return
        tile.state = when (VpnBridge.status) {
            VpnBridge.STARTED -> Tile.STATE_ACTIVE
            VpnBridge.STARTING -> Tile.STATE_ACTIVE
            else -> Tile.STATE_INACTIVE
        }
        tile.label = "Kumo"
        tile.updateTile()
    }
}