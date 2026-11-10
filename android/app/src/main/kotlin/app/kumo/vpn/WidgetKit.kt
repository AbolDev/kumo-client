package app.kumo.vpn

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.os.SystemClock
import android.view.View
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
 * The colours of a widget in one look (light or dark): the card and its texts while disconnected and
 * while connected, the power button, and the small chip.
 */
class WidgetColors(
    val offBg: Int, val offText: Int, val offSub: Int,
    val ring: Int, val offBtn: Int, val offIcon: Int,
    val onBg: Int, val onText: Int, val onSub: Int,
    val onBtn: Int, val onIcon: Int,
    val chipOffBg: Int, val chipOffText: Int, val chipOnBg: Int, val chipOnText: Int,
) {
    companion object {
        private fun c(v: Long) = v.toInt()

        /** Kumo's own teal, where the system gives no colours of its own (before Android 12). */
        val TEAL_LIGHT = WidgetColors(
            c(0xFFFFFFFF), c(0xFF2C2C2A), c(0xFF5F5E5A),
            c(0xFF1D9E75), c(0xFFE1F5EE), c(0xFF0F6E56),
            c(0xFF0F6E56), c(0xFFFFFFFF), c(0xFF9FE1CB),
            c(0xFFE1F5EE), c(0xFF085041),
            c(0xFFEDECE6), c(0xFF444441), c(0xFF1D9E75), c(0xFFE1F5EE),
        )
        val TEAL_DARK = WidgetColors(
            c(0xFF2F2F2D), c(0xFFF1EFE8), c(0xFFB4B2A9),
            c(0xFF5DCAA5), c(0xFF04342C), c(0xFF9FE1CB),
            c(0xFF9FE1CB), c(0xFF04342C), c(0xFF085041),
            c(0xFF085041), c(0xFFE1F5EE),
            c(0xFF444441), c(0xFFD3D1C7), c(0xFF5DCAA5), c(0xFF04342C),
        )

        /** Android 12 and later: the colours of the wallpaper (Material You). */
        fun dynamic(context: Context, dark: Boolean): WidgetColors? {
            if (Build.VERSION.SDK_INT < 31) return null
            return runCatching {
                fun r(id: Int) = context.getColor(id)
                val a = android.R.color::class.java
                fun s(name: String) = r(a.getField(name).getInt(null))
                if (!dark) {
                    WidgetColors(
                        s("system_neutral1_10"), s("system_neutral1_900"), s("system_neutral2_700"),
                        s("system_accent1_600"), s("system_accent1_100"), s("system_accent1_700"),
                        s("system_accent1_600"), s("system_accent1_0"), s("system_accent1_100"),
                        s("system_accent1_100"), s("system_accent1_800"),
                        s("system_neutral2_100"), s("system_neutral2_800"), s("system_accent1_400"), s("system_accent1_0"),
                    )
                } else {
                    WidgetColors(
                        s("system_neutral1_800"), s("system_neutral1_50"), s("system_neutral2_200"),
                        s("system_accent1_300"), s("system_accent1_800"), s("system_accent1_100"),
                        s("system_accent1_200"), s("system_accent1_900"), s("system_accent1_700"),
                        s("system_accent1_700"), s("system_accent1_50"),
                        s("system_neutral2_700"), s("system_neutral2_100"), s("system_accent1_300"), s("system_accent1_900"),
                    )
                }
            }.getOrNull()
        }

        fun light(context: Context) = dynamic(context, false) ?: TEAL_LIGHT
        fun dark(context: Context) = dynamic(context, true) ?: TEAL_DARK
    }
}

/**
 * The look of one placed widget, chosen in [WidgetConfigActivity] and kept per widget id: follow the
 * phone (light or dark, with the wallpaper's colours on Android 12+), always light, always dark, or see-through.
 */
object WidgetTheme {
    const val AUTO = 0
    const val LIGHT = 1
    const val DARK = 2
    const val CLEAR = 3

    private fun prefs(context: Context) = context.getSharedPreferences("widgets", Context.MODE_PRIVATE)

    fun load(context: Context, id: Int): Int = prefs(context).getInt("theme_$id", AUTO).coerceIn(AUTO, CLEAR)

    fun save(context: Context, id: Int, theme: Int) {
        prefs(context).edit().putInt("theme_$id", theme).apply()
    }

    fun forget(context: Context, id: Int) {
        // The keys of the older widgets go too.
        val e = prefs(context).edit().remove("theme_$id")
        for (k in listOf("color", "shape", "opacity", "size", "content")) e.remove("${k}_$id")
        e.apply()
    }

    /** The last server used, shown while disconnected (and the delay the app measured for it). */
    fun lastServer(context: Context): String? = prefs(context).getString("last_server", null)

    fun rememberServer(context: Context, name: String?) {
        if (name.isNullOrBlank()) return
        if (lastServer(context) == name) return
        prefs(context).edit().putString("last_server", name).apply()
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

/** The latest live numbers; the widgets redraw from them every few seconds. */
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
        runCatching { KumoWidget.refreshLive(context) }
    }
}

/**
 * Paints one widget: the colours of its look and state, with light and dark both given on Android 12+
 * so the launcher switches them itself when the phone does.
 */
class WidgetPainter(private val context: Context, private val v: RemoteViews, theme: Int, private val state: Int) {
    private val on = state != WidgetState.OFF
    private val nightNow = (context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) ==
        Configuration.UI_MODE_NIGHT_YES
    private val clear = theme == WidgetTheme.CLEAR

    // The light and the dark colours: the same when the look is fixed.
    private val light: WidgetColors
    private val dark: WidgetColors

    init {
        val l = WidgetColors.light(context)
        val d = WidgetColors.dark(context)
        when (theme) {
            WidgetTheme.LIGHT -> { light = l; dark = l }
            WidgetTheme.DARK, WidgetTheme.CLEAR -> { light = d; dark = d }
            else -> { light = l; dark = d }
        }
    }

    private fun set(id: Int, method: String, pick: (WidgetColors) -> Int) {
        val a = pick(light)
        val b = pick(dark)
        if (Build.VERSION.SDK_INT >= 31 && a != b) {
            v.setColorInt(id, method, a, b)
        } else {
            v.setInt(id, method, if (nightNow) b else a)
        }
    }

    fun background() {
        set(R.id.widget_bg, "setColorFilter") { if (on) it.onBg else it.offBg }
        // See-through: the wallpaper shows through the card (less while connected, so the state reads).
        v.setInt(R.id.widget_bg, "setImageAlpha", if (!clear) 255 else if (on) 210 else 110)
    }

    fun button() {
        set(R.id.wg_btn_bg, "setColorFilter") { if (on) it.onBtn else it.offBtn }
        set(R.id.wg_icon, "setColorFilter") { if (on) it.onIcon else it.offIcon }
        set(R.id.wg_ring, "setColorFilter") { it.ring }
        v.setViewVisibility(R.id.wg_ring, if (on) View.GONE else View.VISIBLE)
    }

    /** A main text (the name, the speeds). */
    fun main(id: Int, text: CharSequence) {
        v.setTextViewText(id, text)
        set(id, "setTextColor") { if (clear) WHITE else if (on) it.onText else it.offText }
    }

    /** A quieter text under it. */
    fun sub(id: Int, text: CharSequence) {
        v.setTextViewText(id, text)
        set(id, "setTextColor") { if (clear) WHITE_SOFT else if (on) it.onSub else it.offSub }
    }

    /** The quiet colour alone, for a view that writes its own text (the clock of the session). */
    fun subColor(id: Int) = set(id, "setTextColor") { if (clear) WHITE_SOFT else if (on) it.onSub else it.offSub }

    fun chip(text: CharSequence?) {
        if (text.isNullOrEmpty()) {
            v.setViewVisibility(R.id.wg_chip_box, View.GONE)
            return
        }
        v.setViewVisibility(R.id.wg_chip_box, View.VISIBLE)
        v.setTextViewText(R.id.wg_chip, text)
        set(R.id.wg_chip_bg, "setColorFilter") { if (on) it.chipOnBg else it.chipOffBg }
        set(R.id.wg_chip, "setTextColor") { if (on) it.chipOnText else it.chipOffText }
    }

    fun hide(id: Int) = v.setViewVisibility(id, View.GONE)

    fun show(id: Int) = v.setViewVisibility(id, View.VISIBLE)

    private companion object {
        const val WHITE = 0xFFFFFFFF.toInt()
        const val WHITE_SOFT = 0xD9FFFFFF.toInt()
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
        ids.forEach { WidgetTheme.forget(context, it) }
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        if (intent.action != ACTION_TOGGLE) return
        val done = try {
            VpnControl.toggle(context)
        } catch (_: Exception) {
            false
        }
        if (!done) openApp(context)
    }

    /** The width the launcher gives the widget, in dp (the narrower of its two orientations). */
    protected fun widthDp(options: Bundle?): Int = options?.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH) ?: 0

    companion object {
        const val ACTION_TOGGLE = "app.kumo.vpn.WIDGET_TOGGLE"

        private val kinds: List<() -> KumoWidget> = listOf({ VpnWidget() }, { VpnWidgetIcon() }, { VpnWidgetStats() })

        private fun openApp(context: Context) {
            context.startActivity(Intent(context, KumoActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }

        /** A tap on [viewId] connects or disconnects. */
        fun toggleOn(context: Context, v: RemoteViews, viewId: Int) {
            v.setOnClickPendingIntent(
                viewId,
                PendingIntent.getBroadcast(
                    context, 0,
                    Intent(context, VpnWidget::class.java).setAction(ACTION_TOGGLE),
                    PendingIntent.FLAG_IMMUTABLE,
                ),
            )
        }

        /** A tap on [viewId] opens the app. */
        fun openOn(context: Context, v: RemoteViews, viewId: Int) {
            v.setOnClickPendingIntent(
                viewId,
                PendingIntent.getActivity(
                    context, 1,
                    Intent(context, KumoActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                    PendingIntent.FLAG_IMMUTABLE,
                ),
            )
        }

        fun stateText(context: Context, state: Int): String = context.getString(
            when (state) {
                WidgetState.ON -> R.string.widget_on
                WidgetState.CONNECTING -> R.string.widget_connecting
                WidgetState.STOPPING -> R.string.widget_disconnecting
                else -> R.string.widget_off
            },
        )

        /** The server shown: the one in use, else the last one used, else the app's name. */
        fun serverName(context: Context): String {
            val now = VpnBridge.serverName
            if (!now.isNullOrBlank()) {
                WidgetTheme.rememberServer(context, now)
                return now
            }
            return WidgetTheme.lastServer(context) ?: "Kumo"
        }

        fun pingText(): String? = VpnBridge.ping?.takeIf { it > 0 }?.let { "$it ms" }

        fun downText(): String = "↓ ${speed(WidgetFeed.down)}"
        fun upText(): String = "↑ ${speed(WidgetFeed.up)}"
        fun totalText(): String = size(WidgetFeed.downTotal + WidgetFeed.upTotal)

        private fun redraw(context: Context, providers: List<KumoWidget>) {
            val manager = AppWidgetManager.getInstance(context)
            for (provider in providers) {
                val ids = manager.getAppWidgetIds(ComponentName(context, provider::class.java))
                ids.forEach { manager.updateAppWidget(it, provider.build(context, it, manager.getAppWidgetOptions(it))) }
            }
        }

        /** Redraws every placed widget (the state, the server, the look changed). */
        fun refreshAll(context: Context) = redraw(context, kinds.map { it() })

        /** Redraws the widgets that show live numbers. */
        fun refreshLive(context: Context) = redraw(context, listOf(VpnWidget(), VpnWidgetStats()))

        fun refreshOne(context: Context, id: Int) {
            val manager = AppWidgetManager.getInstance(context)
            val info = manager.getAppWidgetInfo(id) ?: return
            val provider = kinds.map { it() }.firstOrNull { it::class.java.name == info.provider.className } ?: return
            manager.updateAppWidget(id, provider.build(context, id, manager.getAppWidgetOptions(id)))
        }
    }
}

/** The quick bar (2×1 by default): the power button, the server and its state; wider, the speed and the delay. */
class VpnWidget : KumoWidget() {
    override fun build(context: Context, id: Int, options: Bundle?): RemoteViews {
        val state = WidgetState.current()
        val wide = widthDp(options) >= 170
        val v = RemoteViews(context.packageName, if (wide) R.layout.wg_bar_wide else R.layout.wg_bar)
        val p = WidgetPainter(context, v, WidgetTheme.load(context, id), state)
        p.background()
        p.button()
        p.main(R.id.wg_title, serverName(context))
        val sub = if (state == WidgetState.ON) {
            if (wide) "${downText()} · ${upText()}" else stateText(context, state)
        } else {
            stateText(context, state)
        }
        p.sub(R.id.wg_sub, sub)
        if (wide) p.chip(pingText())
        openOn(context, v, R.id.widget_root)
        toggleOn(context, v, R.id.wg_button)
        return v
    }
}

/** The power button (1×1 by default); wider, the state beside it. A tap anywhere connects or disconnects. */
class VpnWidgetIcon : KumoWidget() {
    override fun build(context: Context, id: Int, options: Bundle?): RemoteViews {
        val state = WidgetState.current()
        val wide = widthDp(options) >= 100
        val v = RemoteViews(context.packageName, if (wide) R.layout.wg_power_wide else R.layout.wg_power)
        val p = WidgetPainter(context, v, WidgetTheme.load(context, id), state)
        p.background()
        p.button()
        if (wide) p.main(R.id.wg_title, stateText(context, state))
        toggleOn(context, v, R.id.widget_root)
        return v
    }
}

/** The status card (2×2 by default): server, delay, live speeds and the data of the session; wider, the full card. */
class VpnWidgetStats : KumoWidget() {
    override fun build(context: Context, id: Int, options: Bundle?): RemoteViews {
        val state = WidgetState.current()
        val wide = widthDp(options) >= 170
        val v = RemoteViews(context.packageName, if (wide) R.layout.wg_card_wide else R.layout.wg_card)
        val p = WidgetPainter(context, v, WidgetTheme.load(context, id), state)
        p.background()
        p.button()
        val on = state == WidgetState.ON
        if (wide) {
            p.main(R.id.wg_brand, "Kumo")
            p.chip(stateText(context, state))
            p.sub(R.id.wg_title, listOfNotNull(serverName(context), pingText()).joinToString(" · "))
        } else {
            p.main(R.id.wg_title, serverName(context))
            val ping = pingText()
            if (ping == null) p.hide(R.id.wg_ping) else { p.show(R.id.wg_ping); p.sub(R.id.wg_ping, ping) }
        }
        if (on) {
            p.main(R.id.wg_down, downText())
            p.show(R.id.wg_up)
            if (wide) p.main(R.id.wg_up, upText()) else p.sub(R.id.wg_up, upText())
            p.show(R.id.wg_total)
            p.sub(R.id.wg_total, totalText())
        } else {
            // Disconnected: the state where the speed would be, and nothing of a session.
            p.main(R.id.wg_down, stateText(context, state))
            p.hide(R.id.wg_up)
            p.hide(R.id.wg_total)
        }
        if (wide) {
            if (on && VpnBridge.startedAt > 0) {
                p.show(R.id.wg_time)
                v.setChronometer(R.id.wg_time, VpnBridge.startedAt, null, true)
                p.subColor(R.id.wg_time)
            } else {
                v.setChronometer(R.id.wg_time, SystemClock.elapsedRealtime(), null, false)
                p.hide(R.id.wg_time)
            }
        }
        openOn(context, v, R.id.widget_root)
        toggleOn(context, v, R.id.wg_button)
        return v
    }
}
