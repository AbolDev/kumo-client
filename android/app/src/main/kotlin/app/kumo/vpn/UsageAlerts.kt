package app.kumo.vpn

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import java.util.Locale

/**
 * Tells the user when a subscription is nearly out of data or about to expire. It is called with
 * the numbers the provider reported, both from the app and from the background update job, and
 * remembers what it has already said so each warning comes once. Settings > Subscriptions
 * switches it off.
 */
object UsageAlerts {
    private const val CHANNEL_ID = "alerts"
    private const val DAY_MS = 24L * 60 * 60 * 1000

    fun enabled(context: Context): Boolean =
        VpnControl.readJson(context, "settings.json")?.optBoolean("usageAlerts", true) != false

    private fun size(bytes: Long): String = when {
        bytes >= 1L shl 30 -> String.format(Locale.US, "%.2f GB", bytes / 1073741824.0)
        bytes >= 1L shl 20 -> String.format(Locale.US, "%.1f MB", bytes / 1048576.0)
        else -> String.format(Locale.US, "%d KB", bytes / 1024)
    }

    /** 0 fine, 1 low (10% or less left), 2 used up. */
    fun dataLevel(used: Long, total: Long): Int {
        if (total <= 0) return 0
        val left = total - used
        return when {
            left <= 0 -> 2
            left * 10 <= total -> 1
            else -> 0
        }
    }

    /** 0 fine, 1 within three days, 2 today, 3 expired. */
    fun expiryLevel(expireSeconds: Long, now: Long = System.currentTimeMillis()): Int {
        if (expireSeconds <= 0) return 0
        val left = expireSeconds * 1000 - now
        return when {
            left <= 0 -> 3
            left < DAY_MS -> 2
            left <= 3 * DAY_MS -> 1
            else -> 0
        }
    }

    fun check(context: Context, id: String, name: String, used: Long, total: Long, expireSeconds: Long) {
        if (!enabled(context)) return
        val prefs = context.getSharedPreferences("usage_alerts", Context.MODE_PRIVATE)
        val data = dataLevel(used, total)
        val expiry = expiryLevel(expireSeconds)
        val seen = prefs.getString(id, "00") ?: "00"
        val seenData = seen.getOrNull(0)?.digitToIntOrNull() ?: 0
        val seenExpiry = seen.getOrNull(1)?.digitToIntOrNull() ?: 0
        // Remembered even when nothing is said: a renewed subscription starts from zero again.
        prefs.edit().putString(id, "$data$expiry").apply()
        if (data > seenData) {
            notify(
                context, id.hashCode() * 2,
                if (data == 2) context.getString(R.string.alert_data_out, name)
                else context.getString(R.string.alert_data_low, name, size((total - used).coerceAtLeast(0))),
            )
        }
        if (expiry > seenExpiry) {
            val days = ((expireSeconds * 1000 - System.currentTimeMillis()) / DAY_MS + 1).toInt().coerceAtLeast(1)
            notify(
                context, id.hashCode() * 2 + 1,
                when (expiry) {
                    3 -> context.getString(R.string.alert_expired, name)
                    2 -> context.getString(R.string.alert_exp_today, name)
                    else -> context.getString(R.string.alert_exp_soon, name, days)
                },
            )
        }
    }

    private fun notify(context: Context, notificationId: Int, text: String) {
        runCatching {
            val nm = context.getSystemService(NotificationManager::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                nm.createNotificationChannel(
                    NotificationChannel(CHANNEL_ID, context.getString(R.string.alert_channel), NotificationManager.IMPORTANCE_DEFAULT),
                )
            }
            val open = PendingIntent.getActivity(
                context, 0,
                Intent(context, MainActivity::class.java).setFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT),
                PendingIntent.FLAG_IMMUTABLE,
            )
            nm.notify(
                notificationId,
                NotificationCompat.Builder(context, CHANNEL_ID)
                    .setContentTitle("Kumo")
                    .setContentText(text)
                    .setStyle(NotificationCompat.BigTextStyle().bigText(text))
                    .setSmallIcon(R.drawable.ic_notification)
                    .setAutoCancel(true)
                    .setContentIntent(open)
                    .build(),
            )
        }
    }
}
