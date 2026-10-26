package app.kumo.vpn

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.os.Bundle
import android.os.PowerManager
import android.os.SystemClock
import android.util.TypedValue
import android.widget.RemoteViews
import java.util.Locale

/** Connection states as the widgets draw them. */
object WidgetState {
    const val OFF = 0
    const val CONNECTING = 1
    const val ON = 2
    const val STOPPING = 3

    fun current(): Int = when (VpnBridge.status) {
        VpnBridge.STARTED -> ON
        VpnBridge.STARTING -> CONNECTING
        VpnBridge.STOPPING -> STOPPING
        else -> OFF
    }
}

/**
 * What one placed widget looks like. It is chosen in [WidgetConfigActivity] and kept per widget
 * id, so every widget on the home screen can have its own colour, shape, opacity and text size.
 */
class WidgetStyle(
    /** 0 follows the connection state (green / orange / grey); otherwise an ARGB colour. */
    val color: Int = 0,
    /** 0 square, 1 rounded, 2 pill. */
    val shape: Int = 1,
    /** Index into [OPACITY]. */
    val opacity: Int = 3,
    /** 0 small, 1 medium, 2 large. */
    val textSize: Int = 1,
    /** Traffic widget: 0 speed, 1 total data, 2 both. */
    val content: Int = 2,
) {
    val alpha: Int get() = OPACITY[opacity.coerceIn(0, OPACITY.size - 1)] * 255 / 100

    val scale: Float get() = SIZES[textSize.coerceIn(0, SIZES.size - 1)]

    fun background(state: Int): Int {
        if (color != 0) return color
        return when (state) {
            WidgetState.ON -> 0xFF0E9F8E.toInt()
            WidgetState.OFF -> 0xFF546E7A.toInt()
            else -> 0xFFF59E0B.toInt()
        }
    }

    /** Dark text on light backgrounds, white on dark ones. A see-through widget sits on an unknown
     *  wallpaper, so it keeps white text with the shadow-free default. */
    fun textColor(state: Int): Int {
        val bg = background(state)
        val luminance = 0.299 * Color.red(bg) + 0.587 * Color.green(bg) + 0.114 * Color.blue(bg)
        return if (luminance > 170 && OPACITY[opacity.coerceIn(0, OPACITY.size - 1)] >= 60) 0xFF1B1B1B.toInt() else Color.WHITE
    }

    companion object {
        val PALETTE = intArrayOf(
            0xFF0E9F8E.toInt(), 0xFF1976D2.toInt(), 0xFF3F51B5.toInt(), 0xFF8E24AA.toInt(),
            0xFFD81B60.toInt(), 0xFFE53935.toInt(), 0xFFFB8C00.toInt(), 0xFFFFB300.toInt(),
            0xFF43A047.toInt(), 0xFF546E7A.toInt(), 0xFF212121.toInt(), 0xFFF5F5F5.toInt(),
        )
        val OPACITY = intArrayOf(40, 60, 80, 100)
        val SIZES = floatArrayOf(0.85f, 1f, 1.2f)

        private fun prefs(context: Context) = context.getSharedPreferences("widgets", Context.MODE_PRIVATE)

        fun load(context: Context, id: Int): WidgetStyle {
            val p = prefs(context)
            return WidgetStyle(
                color = p.getInt("color_$id", 0),
                shape = p.getInt("shape_$id", 1),
                opacity = p.getInt("opacity_$id", 3),
                textSize = p.getInt("size_$id", 1),
                content = p.getInt("content_$id", 2),
            )
        }

        fun save(context: Context, id: Int, s: WidgetStyle) {
            prefs(context).edit()
                .putInt("color_$id", s.color)
                .putInt("shape_$id", s.shape)
                .putInt("opacity_$id", s.opacity)
                .putInt("size_$id", s.textSize)
                .putInt("content_$id", s.content)
                .apply()
        }

        fun forget(context: Context, id: Int) {
            prefs(context).edit()
                .remove("color_$id").remove("shape_$id").remove("opacity_$id")
                .remove("size_$id").remove("content_$id")
                .apply()
        }
    }
}

private fun speed(bytesPerSecond: Long): String = when {
    bytesPerSecond >= 1L shl 20 -> String.format(Locale.US, "%.1f MB/s", bytesPerSecond / 1048576.0)
    bytesPerSecond >= 1L shl 10 -> String.format(Locale.US, "%d KB/s", bytesPerSecond / 1024)
    else -> String.format(Locale.US, "%d B/s", bytesPerSecond)
}

private fun size(bytes: Long): String = when {
    bytes >= 1L shl 30 -> String.format(Locale.US, "%.2f GB", bytes / 1073741824.0)
    bytes >= 1L shl 20 -> String.format(Locale.US, "%.1f MB", bytes / 1048576.0)
    bytes >= 1L shl 10 -> String.format(Locale.US, "%d KB", bytes / 1024)
    else -> String.format(Locale.US, "%d B", bytes)
}

/** The latest live numbers; the traffic widgets redraw from them every few seconds. */
object WidgetFeed {
    @Volatile var up = 0L
    @Volatile var down = 0L
    @Volatile var upTotal = 0L
    @Volatile var downTotal = 0L
    private var last = 0L

    fun reset() {
        up = 0; down = 0; upTotal = 0; downTotal = 0
    }

    /** Called every second by the service; the widgets are redrawn at most every 3 seconds and
     *  only while the screen is on, so they cost next to nothing. */
    fun onTraffic(up: Long, down: Long, upTotal: Long, downTotal: Long) {
        this.up = up
        this.down = down
        this.upTotal = upTotal
        this.downTotal = downTotal
        val now = SystemClock.elapsedRealtime()
        if (now - last < 2900) return
        val context = App.instance
        if (!context.getSystemService(PowerManager::class.java).isInteractive) return
        last = now
        runCatching { VpnWidgetStats.refreshStats(context) }
    }
}

/** Shared by the three widget kinds. */
abstract class KumoWidget : AppWidgetProvider() {
    abstract fun build(context: Context, id: Int, options: Bundle?): RemoteViews

    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        ids.forEach { manager.updateAppWidget(it, build(context, it, manager.getAppWidgetOptions(it))) }
    }

    override fun onAppWidgetOptionsChanged(context: Context, manager: AppWidgetManager, id: Int, newOptions: Bundle?) {
        manager.updateAppWidget(id, build(context, id, newOptions))
    }

    override fun onDeleted(context: Context, ids: IntArray) {
        ids.forEach { WidgetStyle.forget(context, it) }
    }

    companion object {
        const val ACTION_TOGGLE = "app.kumo.vpn.WIDGET_TOGGLE"

        private val kinds: List<() -> KumoWidget> = listOf({ VpnWidget() }, { VpnWidgetIcon() }, { VpnWidgetStats() })

        /** Paints the background, the icon and the tap action that every widget has. */
        fun paint(context: Context, v: RemoteViews, style: WidgetStyle, state: Int, withIcon: Boolean = true) {
            val shapes = intArrayOf(R.drawable.widget_shape_square, R.drawable.widget_shape_round, R.drawable.widget_shape_pill)
            v.setImageViewResource(R.id.widget_bg, shapes[style.shape.coerceIn(0, 2)])
            v.setInt(R.id.widget_bg, "setColorFilter", style.background(state))
            v.setInt(R.id.widget_bg, "setImageAlpha", style.alpha)
            if (withIcon) v.setInt(R.id.widget_icon, "setColorFilter", style.textColor(state))
            v.setOnClickPendingIntent(
                R.id.widget_root,
                PendingIntent.getBroadcast(
                    context, 0,
                    Intent(context, VpnWidget::class.java).setAction(ACTION_TOGGLE),
                    PendingIntent.FLAG_IMMUTABLE,
                ),
            )
        }

        fun text(v: RemoteViews, id: Int, value: String, color: Int, sp: Float, scale: Float, alpha: Int = 255) {
            v.setTextViewText(id, value)
            v.setTextColor(id, (color and 0x00FFFFFF) or (alpha shl 24))
            v.setTextViewTextSize(id, TypedValue.COMPLEX_UNIT_SP, sp * scale)
        }

        fun stateText(context: Context, state: Int): String = context.getString(
            when (state) {
                WidgetState.ON -> R.string.widget_on
                WidgetState.CONNECTING -> R.string.widget_connecting
                WidgetState.STOPPING -> R.string.widget_disconnecting
                else -> R.string.widget_off
            },
        )

        /** Redraws every placed widget (called when the connection state changes). */
        fun refreshAll(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            for (make in kinds) {
                val provider = make()
                val ids = manager.getAppWidgetIds(ComponentName(context, provider::class.java))
                ids.forEach { manager.updateAppWidget(it, provider.build(context, it, manager.getAppWidgetOptions(it))) }
            }
        }

        fun refreshOne(context: Context, id: Int) {
            val manager = AppWidgetManager.getInstance(context)
            val info = manager.getAppWidgetInfo(id) ?: return
            val provider = kinds.map { it() }.firstOrNull { it::class.java.name == info.provider.className } ?: return
            manager.updateAppWidget(id, provider.build(context, id, manager.getAppWidgetOptions(id)))
        }

        fun speedLine(): String = "↓ ${speed(WidgetFeed.down)}   ↑ ${speed(WidgetFeed.up)}"
        fun totalLine(): String = "Σ ↓ ${size(WidgetFeed.downTotal)}   ↑ ${size(WidgetFeed.upTotal)}"
        fun downLine(content: Int): String =
            if (content == 1) "↓ ${size(WidgetFeed.downTotal)}" else "↓ ${speed(WidgetFeed.down)}"
        fun upLine(content: Int): String =
            if (content == 1) "↑ ${size(WidgetFeed.upTotal)}" else "↑ ${speed(WidgetFeed.up)}"
    }
}

/** The classic widget: icon, name and state in one tappable bar. */
class VpnWidget : KumoWidget() {
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

    override fun build(context: Context, id: Int, options: Bundle?): RemoteViews {
        val style = WidgetStyle.load(context, id)
        val state = WidgetState.current()
        val v = RemoteViews(context.packageName, R.layout.widget_vpn)
        paint(context, v, style, state)
        val color = style.textColor(state)
        text(v, R.id.widget_title, "Kumo", color, 16f, style.scale)
        text(v, R.id.widget_state, stateText(context, state), color, 13f, style.scale, 204)
        return v
    }
}

/** A button the size of an icon: the colour tells the state, a tap connects or disconnects. */
class VpnWidgetIcon : KumoWidget() {
    override fun build(context: Context, id: Int, options: Bundle?): RemoteViews {
        val style = WidgetStyle.load(context, id)
        val state = WidgetState.current()
        val v = RemoteViews(context.packageName, R.layout.widget_icon)
        paint(context, v, style, state)
        return v
    }
}

/** Live speed and/or total data; shows more (the server name, both lines) as it is made bigger. */
class VpnWidgetStats : KumoWidget() {
    override fun build(context: Context, id: Int, options: Bundle?): RemoteViews {
        val style = WidgetStyle.load(context, id)
        val state = WidgetState.current()
        val heightDp = options?.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT) ?: 0
        val layout = when {
            heightDp >= 110 -> 3
            heightDp >= 72 -> 2
            else -> 1
        }
        val v = RemoteViews(
            context.packageName,
            when (layout) {
                3 -> R.layout.widget_stats_3
                2 -> R.layout.widget_stats_2
                else -> R.layout.widget_stats_1
            },
        )
        paint(context, v, style, state)
        val color = style.textColor(state)
        val s = style.scale
        val on = state == WidgetState.ON
        val content = style.content
        when (layout) {
            1 -> {
                val line = when {
                    !on -> stateText(context, state)
                    content == 1 -> totalLine()
                    else -> speedLine()
                }
                text(v, R.id.widget_l1, line, color, 14f, s)
            }
            2 -> {
                val (a, b) = lines(context, state, content)
                text(v, R.id.widget_l1, a, color, 15f, s)
                text(v, R.id.widget_l2, b, color, 12f, s, 204)
                v.setViewVisibility(R.id.widget_l2, if (b.isEmpty()) android.view.View.GONE else android.view.View.VISIBLE)
            }
            else -> {
                val name = if (on) (VpnBridge.serverName ?: "Kumo") else "Kumo"
                text(v, R.id.widget_title, name, color, 14f, s)
                text(v, R.id.widget_state, stateText(context, state), color, 11f, s, 204)
                val (a, b) = lines(context, state, content)
                text(v, R.id.widget_l1, a, color, 18f, s)
                text(v, R.id.widget_l2, b, color, 13f, s, 204)
                v.setViewVisibility(R.id.widget_l2, if (b.isEmpty()) android.view.View.GONE else android.view.View.VISIBLE)
            }
        }
        return v
    }

    /** Two lines for the medium and large sizes. */
    private fun lines(context: Context, state: Int, content: Int): Pair<String, String> {
        if (state != WidgetState.ON) return Pair(stateText(context, state), "")
        return when (content) {
            2 -> Pair(speedLine(), totalLine())
            else -> Pair(downLine(content), upLine(content))
        }
    }

    companion object {
        fun refreshStats(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            val provider = VpnWidgetStats()
            manager.getAppWidgetIds(ComponentName(context, VpnWidgetStats::class.java)).forEach {
                manager.updateAppWidget(it, provider.build(context, it, manager.getAppWidgetOptions(it)))
            }
        }
    }
}
