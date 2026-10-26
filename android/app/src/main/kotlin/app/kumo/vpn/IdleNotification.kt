package app.kumo.vpn

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat

/**
 * The notification that stays after a disconnect: it says the VPN is off and has a Connect
 * button. It is a plain notification (not the foreground one), so it outlives the service.
 * Settings > UI switches it off.
 */
object IdleNotification {
    private const val ID = 2
    private const val CHANNEL_ID = "vpn"

    fun enabled(context: Context): Boolean =
        VpnControl.readJson(context, "settings.json")?.optBoolean("idleNotification", true) != false

    /** [force] skips the settings check: the file may not have been written yet when the switch is flipped. */
    fun show(context: Context, force: Boolean = false) {
        if (!force && !enabled(context)) return
        if (VpnBridge.status != VpnBridge.STOPPED && VpnBridge.status != VpnBridge.ERROR) return
        runCatching {
            val nm = context.getSystemService(NotificationManager::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                nm.createNotificationChannel(
                    NotificationChannel(CHANNEL_ID, context.getString(R.string.notif_channel), NotificationManager.IMPORTANCE_LOW),
                )
            }
            val open = PendingIntent.getActivity(
                context, 0,
                Intent(context, MainActivity::class.java).setFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT),
                PendingIntent.FLAG_IMMUTABLE,
            )
            val connectIntent = Intent(context, BoxVpnService::class.java).setAction(BoxVpnService.ACTION_CONNECT)
            val connect = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                PendingIntent.getForegroundService(context, 3, connectIntent, PendingIntent.FLAG_IMMUTABLE)
            } else {
                PendingIntent.getService(context, 3, connectIntent, PendingIntent.FLAG_IMMUTABLE)
            }
            val notification = NotificationCompat.Builder(context, CHANNEL_ID)
                .setContentTitle("Kumo")
                .setContentText("🔴 " + context.getString(R.string.notif_idle))
                .setSmallIcon(R.drawable.ic_notification)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setShowWhen(false)
                .setContentIntent(open)
                .addAction(0, context.getString(R.string.notif_connect), connect)
                .setCategory(NotificationCompat.CATEGORY_SERVICE)
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .build()
            nm.notify(ID, notification)
        }
    }

    fun cancel(context: Context) {
        runCatching { context.getSystemService(NotificationManager::class.java).cancel(ID) }
    }
}
