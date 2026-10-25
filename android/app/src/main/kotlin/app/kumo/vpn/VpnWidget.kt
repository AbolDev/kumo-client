package app.kumo.vpn

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews

/** Home-screen widget with one button that connects or disconnects. */
class VpnWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        ids.forEach { manager.updateAppWidget(it, views(context)) }
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        if (intent.action != ACTION_TOGGLE) return
        val done = try {
            VpnControl.toggle(context)
        } catch (_: Exception) {
            false
        }
        if (!done) {
            context.startActivity(Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }
    }

    companion object {
        const val ACTION_TOGGLE = "app.kumo.vpn.WIDGET_TOGGLE"

        private fun views(context: Context): RemoteViews {
            val on = VpnControl.isOn
            return RemoteViews(context.packageName, R.layout.widget_vpn).apply {
                setTextViewText(R.id.widget_state, context.getString(if (on) R.string.widget_on else R.string.widget_off))
                setOnClickPendingIntent(
                    R.id.widget_root,
                    PendingIntent.getBroadcast(
                        context, 0,
                        Intent(context, VpnWidget::class.java).setAction(ACTION_TOGGLE),
                        PendingIntent.FLAG_IMMUTABLE,
                    ),
                )
            }
        }

        /** Redraws every placed widget (called when the connection state changes). */
        fun refresh(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(ComponentName(context, VpnWidget::class.java))
            ids.forEach { manager.updateAppWidget(it, views(context)) }
        }
    }
}