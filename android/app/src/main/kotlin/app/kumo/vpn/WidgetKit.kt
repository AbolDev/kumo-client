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
 * The colours of a widget in one look (light or dark). The card and its texts are the same in every state: only
 * the power button tells the state (an outlined button while disconnected, a filled one while connected).
 */
class WidgetColors(
    val bg: Int, val text: Int, val sub: Int,
    val ring: Int, val offBtn: Int, val offIcon: Int,
    val onBtn: Int, val onIcon: Int,
    val chipBg: Int, val chipText: Int,
) {
    companion object {
        private fun c(v: Long) = v.toInt()

        /** Kumo's own teal, where the system gives no colours of its own (before Android 12). */
        val TEAL_LIGHT = WidgetColors(
            c(0xFFFFFFFF), c(0xFF1C1C1A), c(0xFF5F5E5A),
            c(0xFF1D9E75), c(0xFFE8F6F0), c(0xFF0F6E56),
            c(0xFF1D9E75), c(0xFFFFFFFF),
            c(0xFFE1F5EE), c(0xFF085041),
        )
        val TEAL_DARK = WidgetColors(
            c(0xFF1F2120), c(0xFFF1EFE8), c(0xFFB4B2A9),
            c(0xFF5DCAA5), c(0xFF2A3431), c(0xFF9FE1CB),
            c(0xFF5DCAA5), c(0xFF04342C),
            c(0xFF0B4A3C), c(0xFFC8EFE0),
        )

        /** Android 12 and later: the colours of the wallpaper (Material You), on a neutral card. */
        fun dynamic(context: Context, dark: Boolean): WidgetColors? {
            if (Build.VERSION.SDK_INT < 31) return null
            return runCatching {
                val a = android.R.color::class.java
                fun s(name: String) = context.getColor(a.getField(name).getInt(null))
                if (!dark) {
                    WidgetColors(
                        s("system_neutral1_10"), s("system_neutral1_900"), s("system_neutral2_600"),
                        s("system_accent1_600"), s("system_accent1_50"), s("system_accent1_600"),
                        s("system_accent1_600"), s("system_accent1_0"),
                        s("system_accent1_100"), s("system_accent1_800"),
                    )
                } else {
                    WidgetColors(
                        s("system_neutral1_900"), s("system_neutral1_50"), s("system_neutral2_200"),
                        s("system_accent1_200"), s("system_neutral1_800"), s("system_accent1_200"),
                        s("system_accent1_200"), s("system_accent1_900"),
                        s("system_accent1_800"), s("system_accent1_100"),
                    )
                }
            }.getOrNull()
        }

        fun light(context: Context) = dynamic(context, false) ?: TEAL_LIGHT
        fun dark(context: Context) = dynamic(context, true) ?: TEAL_DARK
    }
}

/** A look of a widget: its colours ([WidgetTheme]) and the opacity of its background (0 to 100). With [state]
 *  the widget is drawn as in that state (the preview of the settings), else as in the one the VPN is in. */
class WidgetLook(val theme: Int, val opacity: Int, val state: Int? = null)

/**
 * The look of one placed widget, chosen in [WidgetConfigActivity] and kept per widget id: follow the
 * phone (light or dark, with the wallpaper's colours on Android 12+), always light or always dark, and how
 * opaque the background is.
 */
object WidgetTheme {
    const val AUTO = 0
    const val LIGHT = 1
    const val DARK = 2

    /** The see-through look of the first versions: the dark colours with white texts over the wallpaper.
     *  Not offered any more (the opacity does it); a widget that has it keeps it. */
    const val CLEAR = 3

    private fun prefs(context: Context) = context.getSharedPreferences("widgets", Context.MODE_PRIVATE)

    fun load(context: Context, id: Int): Int = prefs(context).getInt("theme_$id", AUTO).coerceIn(AUTO, CLEAR)

    fun save(context: Context, id: Int, theme: Int) {
        prefs(context).edit().putInt("theme_$id", theme).apply()
    }

    /** How opaque the background of the widget is, 0 to 100 (100 when none was chosen; 45 for the old see-through look). */
    fun opacity(context: Context, id: Int): Int {
        val saved = prefs(context).getInt("opacity_$id", -1)
        if (saved in 0..100) return saved
        return if (load(context, id) == CLEAR) 45 else 100
    }

    fun saveOpacity(context: Context, id: Int, opacity: Int) {
        prefs(context).edit().putInt("opacity_$id", opacity.coerceIn(0, 100)).apply()
    }

    /** The look kept for the widget [id]. */
    fun look(context: Context, id: Int) = WidgetLook(load(context, id), opacity(context, id))

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
class WidgetPainter(private val context: Context, private val v: RemoteViews, look: WidgetLook, private val state: Int) {
    private val on = state != WidgetState.OFF
    private val nightNow = (context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) ==
        Configuration.UI_MODE_NIGHT_YES
    private val theme = look.theme
    private val opacity = look.opacity.coerceIn(0, 100)

    // Below half the opacity the card hardly shows and the texts stand on the wallpaper: white, as the
    // launcher writes the names of the apps.
    private val clear = opacity < 50

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

    /** The card: one colour in every state, as opaque as chosen. */
    fun background() {
        set(R.id.widget_bg, "setColorFilter") { it.bg }
        v.setInt(R.id.widget_bg, "setImageAlpha", opacity * 255 / 100)
    }

    /** The power button: outlined while disconnected, filled while connected (or connecting). */
    fun button() {
        set(R.id.wg_btn_bg, "setColorFilter") { if (on) it.onBtn else it.offBtn }
        set(R.id.wg_icon, "setColorFilter") { if (on) it.onIcon else it.offIcon }
        set(R.id.wg_ring, "setColorFilter") { it.ring }
        v.setViewVisibility(R.id.wg_ring, if (on) View.GONE else View.VISIBLE)
    }

    /** A main text (the name, the speeds). */
    fun main(id: Int, text: CharSequence) {
        v.setTextViewText(id, text)
        set(id, "setTextColor") { if (clear) WHITE else it.text }
    }

    /** A quieter text under it. */
    fun sub(id: Int, text: CharSequence) {
        v.setTextViewText(id, text)
        subColor(id)
    }

    /** The quiet colour alone, for a view that writes its own text (the clock of the session). */
    fun subColor(id: Int) = set(id, "setTextColor") { if (clear) WHITE_SOFT else it.sub }

    fun chip(text: CharSequence?) {
        if (text.isNullOrEmpty()) {
            v.setViewVisibility(R.id.wg_chip_box, View.GONE)
            return
        }
        v.setViewVisibility(R.id.wg_chip_box, View.VISIBLE)
        v.setTextViewText(R.id.wg_chip, text)
        set(R.id.wg_chip_bg, "setColorFilter") { it.chipBg }
        set(R.id.wg_chip, "setTextColor") { it.chipText }
    }

    fun hide(id: Int) = v.setViewVisibility(id, View.GONE)

    /** Hidden but keeping its room, so nothing around it moves when the state changes. */
    fun keep(id: Int) = v.setViewVisibility(id, View.INVISIBLE)

    fun show(id: Int) = v.setViewVisibility(id, View.VISIBLE)

    private companion object {
        const val WHITE = 0xFFFFFFFF.toInt()
        const val WHITE_SOFT = 0xD9FFFFFF.toInt()
    }
}

/** Shared by the three widget kinds. */
abstract class KumoWidget : AppWidgetProvider() {
    /** The widget as it is drawn now. With [custom] it is drawn in that look instead of the saved one (the preview). */
    abstract fun build(context: Context, id: Int, options: Bundle?, custom: WidgetLook? = null): RemoteViews

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

    /** The width the launcher gives the widget, in dp (the narrower of its two orientations). 0 when not known. */
    protected fun widthDp(options: Bundle?): Int = options?.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH) ?: 0

    /** The height the launcher gives the widget, in dp (the lower of its two orientations). 0 when not known. */
    protected fun heightDp(options: Bundle?): Int = options?.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT) ?: 0

    /** The time of the session in the corner of the card (a clock that the system keeps ticking), while connected. */
    protected fun session(p: WidgetPainter, v: RemoteViews, on: Boolean) {
        if (on && VpnBridge.startedAt > 0) {
            p.show(R.id.wg_time)
            v.setChronometer(R.id.wg_time, VpnBridge.startedAt, null, true)
            p.subColor(R.id.wg_time)
        } else {
            v.setChronometer(R.id.wg_time, SystemClock.elapsedRealtime(), null, false)
            p.hide(R.id.wg_time)
        }
    }

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

        /** The widget [id] drawn in [look] at the size the launcher gave it, for the preview of the settings (null when it is gone). */
        fun preview(context: Context, id: Int, look: WidgetLook): RemoteViews? {
            val manager = AppWidgetManager.getInstance(context)
            val info = manager.getAppWidgetInfo(id) ?: return null
            val provider = kinds.map { it() }.firstOrNull { it::class.java.name == info.provider.className } ?: return null
            return provider.build(context, id, manager.getAppWidgetOptions(id), look)
        }

        fun refreshOne(context: Context, id: Int) {
            val manager = AppWidgetManager.getInstance(context)
            val info = manager.getAppWidgetInfo(id) ?: return
            val provider = kinds.map { it() }.firstOrNull { it::class.java.name == info.provider.className } ?: return
            manager.updateAppWidget(id, provider.build(context, id, manager.getAppWidgetOptions(id)))
        }
    }
}

/**
 * The quick bar (2×1 by default). It follows its width: about one cell, only the power button; up to four cells, the
 * button, the server and one line (the state, or the speeds when connected); four cells and more, the delay too.
 * Always drawn left to right.
 */
class VpnWidget : KumoWidget() {
    override fun build(context: Context, id: Int, options: Bundle?, custom: WidgetLook?): RemoteViews {
        val look = custom ?: WidgetTheme.look(context, id)
        val state = look.state ?: WidgetState.current()
        val w = widthDp(options)
        val layout = when {
            w in 1 until 100 -> R.layout.wg_bar_icon
            w >= 280 -> R.layout.wg_bar_wide
            else -> R.layout.wg_bar
        }
        val v = RemoteViews(context.packageName, layout)
        val p = WidgetPainter(context, v, look, state)
        p.background()
        p.button()
        if (layout != R.layout.wg_bar_icon) {
            p.main(R.id.wg_title, serverName(context))
            // Room is short below two cells and a half: one speed is enough there.
            val sub = when {
                state != WidgetState.ON -> stateText(context, state)
                w in 1 until 200 -> downText()
                else -> "${downText()} · ${upText()}"
            }
            p.sub(R.id.wg_sub, sub)
        }
        if (layout == R.layout.wg_bar_wide) p.chip(if (state == WidgetState.ON) pingText() else null)
        openOn(context, v, R.id.widget_root)
        toggleOn(context, v, R.id.wg_button)
        return v
    }
}

/**
 * The power button (1×1 by default). Wide and one row high, the state beside it; more than one row high and narrow, a
 * bigger button with the state under it. A tap anywhere connects or disconnects. Always drawn left to right.
 */
class VpnWidgetIcon : KumoWidget() {
    override fun build(context: Context, id: Int, options: Bundle?, custom: WidgetLook?): RemoteViews {
        val look = custom ?: WidgetTheme.look(context, id)
        val state = look.state ?: WidgetState.current()
        val w = widthDp(options)
        val h = heightDp(options)
        val layout = when {
            h >= 130 && w < 200 -> R.layout.wg_power_tall
            w >= 130 && h < 130 -> R.layout.wg_power_wide
            else -> R.layout.wg_power
        }
        val v = RemoteViews(context.packageName, layout)
        val p = WidgetPainter(context, v, look, state)
        p.background()
        p.button()
        if (layout != R.layout.wg_power) p.main(R.id.wg_title, stateText(context, state))
        toggleOn(context, v, R.id.widget_root)
        return v
    }
}

/**
 * The status card (2×2 by default). One row high, it becomes a bar with the speeds (two cells wide: one speed and the
 * data used; three and more: both speeds, the data used and the time). Taller, it has the big button in the middle when
 * narrow, and the speeds with the button in the corner when wide. Always drawn left to right.
 */
class VpnWidgetStats : KumoWidget() {
    override fun build(context: Context, id: Int, options: Bundle?, custom: WidgetLook?): RemoteViews {
        val look = custom ?: WidgetTheme.look(context, id)
        val state = look.state ?: WidgetState.current()
        val on = state == WidgetState.ON
        val w = widthDp(options)
        val h = heightDp(options)
        val strip = h in 1 until 100
        val layout = when {
            strip && w < 200 -> R.layout.wg_card_s
            strip -> R.layout.wg_card_m
            w < 200 -> R.layout.wg_card_tall
            else -> R.layout.wg_card_wide
        }
        val v = RemoteViews(context.packageName, layout)
        val p = WidgetPainter(context, v, look, state)
        p.background()
        p.button()
        p.main(R.id.wg_title, serverName(context))
        // Disconnected: the state stands where the speed would be, and nothing of a session is shown.
        fun showUp(text: String) = if (on) { p.show(R.id.wg_up); p.main(R.id.wg_up, text) } else p.hide(R.id.wg_up)
        when (layout) {
            R.layout.wg_card_s -> {
                p.main(R.id.wg_down, if (on) downText() else stateText(context, state))
                if (on) { p.show(R.id.wg_total); p.sub(R.id.wg_total, totalText()) } else p.hide(R.id.wg_total)
            }
            R.layout.wg_card_m -> {
                p.main(R.id.wg_down, if (on) downText() else stateText(context, state))
                showUp(upText())
                if (on) { p.show(R.id.wg_total); p.main(R.id.wg_total, totalText()) } else p.hide(R.id.wg_total)
                session(p, v, on)
            }
            R.layout.wg_card_tall -> {
                // The button stands in the middle: the rows under it keep their room while disconnected (written
                // but not shown), so it does not move when the state changes.
                p.sub(R.id.wg_sub, stateText(context, state))
                p.main(R.id.wg_down, downText())
                p.main(R.id.wg_up, upText())
                p.main(R.id.wg_total, totalText())
                for (row in listOf(R.id.wg_down, R.id.wg_up, R.id.wg_total)) if (on) p.show(row) else p.keep(row)
                session(p, v, on)
            }
            else -> {
                p.chip(if (on) pingText() else null)
                p.main(R.id.wg_down, if (on) downText() else stateText(context, state))
                showUp(upText())
                if (on) { p.show(R.id.wg_total); p.sub(R.id.wg_total, totalText()) } else p.hide(R.id.wg_total)
                session(p, v, on)
            }
        }
        openOn(context, v, R.id.widget_root)
        toggleOn(context, v, R.id.wg_button)
        return v
    }
}
