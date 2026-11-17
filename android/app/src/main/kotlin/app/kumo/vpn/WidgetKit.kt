package app.kumo.vpn

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.appwidget.AppWidgetProviderInfo
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.os.SystemClock
import android.util.TypedValue
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
 * the power button tells the state (an outlined button while disconnected, a filled one in the accent colour while
 * it connects or disconnects, a green one while connected: [okBtn] is green in every look, wallpaper colours or not).
 */
class WidgetColors(
    val bg: Int, val text: Int, val sub: Int,
    val ring: Int, val offBtn: Int, val offIcon: Int,
    val onBtn: Int, val onIcon: Int,
    val chipBg: Int, val chipText: Int,
    val okBtn: Int, val okIcon: Int,
) {
    /** The same colours with the accent of the user (0: the ones of the look, the wallpaper or Kumo teal): the ring, the
     *  buttons and the chip change, the card and the texts stay. With [okFollowsAccent] the connected button takes the
     *  accent too, else it stays green. */
    fun styled(accent: Int, okFollowsAccent: Boolean, dark: Boolean): WidgetColors {
        val a = ACCENTS.getOrNull(accent - 1)?.let { if (dark) it.second else it.first }
        val strong = a?.get(0) ?: ring
        val onFg = a?.get(3) ?: onIcon
        return WidgetColors(
            bg, text, sub,
            strong, a?.get(1) ?: offBtn, a?.get(2) ?: offIcon,
            strong, onFg,
            a?.get(4) ?: chipBg, a?.get(5) ?: chipText,
            if (okFollowsAccent) strong else okBtn, if (okFollowsAccent) onFg else okIcon,
        )
    }

    companion object {
        private fun c(v: Long) = v.toInt()

        // The green of a connected widget: a deeper one on a light card, a brighter one on a dark card.
        private val GREEN_LIGHT = c(0xFF1E9E52) to c(0xFFFFFFFF)
        private val GREEN_DARK = c(0xFF4CCB7E) to c(0xFF06301A)

        /** Kumo's own teal, where the system gives no colours of its own (before Android 12). */
        val TEAL_LIGHT = WidgetColors(
            c(0xFFFFFFFF), c(0xFF1C1C1A), c(0xFF5F5E5A),
            c(0xFF1D9E75), c(0xFFE8F6F0), c(0xFF0F6E56),
            c(0xFF1D9E75), c(0xFFFFFFFF),
            c(0xFFE1F5EE), c(0xFF085041),
            GREEN_LIGHT.first, GREEN_LIGHT.second,
        )
        val TEAL_DARK = WidgetColors(
            c(0xFF1F2120), c(0xFFF1EFE8), c(0xFFB4B2A9),
            c(0xFF5DCAA5), c(0xFF2A3431), c(0xFF9FE1CB),
            c(0xFF5DCAA5), c(0xFF04342C),
            c(0xFF0B4A3C), c(0xFFC8EFE0),
            GREEN_DARK.first, GREEN_DARK.second,
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
                        GREEN_LIGHT.first, GREEN_LIGHT.second,
                    )
                } else {
                    WidgetColors(
                        s("system_neutral1_900"), s("system_neutral1_50"), s("system_neutral2_200"),
                        s("system_accent1_200"), s("system_neutral1_800"), s("system_accent1_200"),
                        s("system_accent1_200"), s("system_accent1_900"),
                        s("system_accent1_800"), s("system_accent1_100"),
                        GREEN_DARK.first, GREEN_DARK.second,
                    )
                }
            }.getOrNull()
        }

        // The accents the user can pick: for the light card and for the dark one, the strong colour (ring, filled button),
        // the soft one (the button while disconnected), its icon, the icon on the strong colour, the chip and its text.
        private fun pal(vararg v: Long) = IntArray(v.size) { c(v[it]) }

        const val ACCENT_COUNT = 5

        private val ACCENTS: List<Pair<IntArray, IntArray>> = listOf(
            // 1 blue
            pal(0xFF1A73E8, 0xFFE3EEFD, 0xFF0B4A9E, 0xFFFFFFFF, 0xFFD6E6FC, 0xFF0B3D82) to
                pal(0xFF8AB4F8, 0xFF26303F, 0xFFB6D0FA, 0xFF0B2A57, 0xFF173A6B, 0xFFD2E3FC),
            // 2 purple
            pal(0xFF7B3FE4, 0xFFEEE6FC, 0xFF4F2799, 0xFFFFFFFF, 0xFFE4D8FA, 0xFF3F1F7E) to
                pal(0xFFC3A6F7, 0xFF2E2840, 0xFFDCC9FA, 0xFF2D1363, 0xFF47267E, 0xFFEADDFD),
            // 3 orange
            pal(0xFFE8710A, 0xFFFDEBDB, 0xFF9A4A06, 0xFFFFFFFF, 0xFFFBDDC0, 0xFF7A3A05) to
                pal(0xFFFFB366, 0xFF3A2E22, 0xFFFFCFA3, 0xFF4A2300, 0xFF6B3A0C, 0xFFFFE0C2),
            // 4 red
            pal(0xFFD93025, 0xFFFCE4E2, 0xFF9C1F18, 0xFFFFFFFF, 0xFFFAD3D0, 0xFF7C1914) to
                pal(0xFFF28B82, 0xFF3D2827, 0xFFF9B4AE, 0xFF5C0F0A, 0xFF6B2420, 0xFFFAD2CF),
            // 5 green
            pal(0xFF1E9E52, 0xFFE3F5EA, 0xFF136B38, 0xFFFFFFFF, 0xFFD0F0DD, 0xFF0F5429) to
                pal(0xFF4CCB7E, 0xFF223329, 0xFF9DE3B9, 0xFF06301A, 0xFF14472B, 0xFFC5F0D6),
        )

        /** The strong colour of accent [accent] (1 to 5) on a light card, for the swatches of the settings. */
        fun swatch(accent: Int): Int = ACCENTS.getOrNull(accent - 1)?.first?.get(0) ?: TEAL_LIGHT.ring

        fun light(context: Context) = dynamic(context, false) ?: TEAL_LIGHT
        fun dark(context: Context) = dynamic(context, true) ?: TEAL_DARK
    }
}

/** A look of a widget: its colours ([WidgetTheme]), the opacity of its background (0 to 100), the roundness of its
 *  corners in dp ([radius], -1 while none was chosen: the widget keeps the corners it was drawn with) and how high its
 *  card stands in the room the launcher gives it ([height], 50 to 100 percent). [button] is the size of the power button
 *  and [font] the size of every text, each in percent of the size the layout was drawn with and each its own choice.
 *  With [state] the widget is drawn as in that state (the preview of the settings), else as in the one the VPN is in. */
class WidgetLook(
    val theme: Int, val opacity: Int, val state: Int? = null,
    val radius: Int = -1, val height: Int = 100,
    val button: Int = 100, val font: Int = 100,
    val side: Int = WidgetTheme.LEFT,
    /** The accent colour (0: the look own, 1 to 5 a colour to pick) and whether the connected button follows it (else green). */
    val accent: Int = 0, val okColor: Int = WidgetTheme.OK_GREEN,
    /** The shape of the power button, which texts and numbers are shown (the SHOW_ flags), the border of the card (0 to
     *  3 dp and its colour), the unit of the speeds (bits or bytes) and what a tap on the widget does. */
    val shape: Int = WidgetTheme.SHAPE_CIRCLE, val show: Int = WidgetTheme.SHOW_ALL,
    val border: Int = 0, val borderColor: Int = WidgetTheme.BORDER_ACCENT,
    val bits: Boolean = false, val tap: Int = WidgetTheme.TAP_OPEN,
)

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

    /** The roundness of the corners in dp, 0 to 40 (-1 when none was chosen). */
    fun radius(context: Context, id: Int): Int {
        val saved = prefs(context).getInt("radius_$id", -1)
        return if (saved in 0..MAX_RADIUS) saved else -1
    }

    /** How high the card stands in the room of the widget, [MIN_HEIGHT] to 100 percent (100 when none was chosen). */
    fun height(context: Context, id: Int): Int = prefs(context).getInt("height_$id", 100).coerceIn(MIN_HEIGHT, 100)

    /** Keeps the shape of the widget [id]: [radius] only when the user chose one (else the widget keeps its own). */
    fun saveShape(context: Context, id: Int, radius: Int?, height: Int) {
        val e = prefs(context).edit().putInt("height_$id", height.coerceIn(MIN_HEIGHT, 100))
        if (radius != null) e.putInt("radius_$id", radius.coerceIn(0, MAX_RADIUS))
        e.apply()
    }

    /** The size of the power button in percent, [MIN_BUTTON] to [MAX_BUTTON] (100 when none was chosen). */
    fun button(context: Context, id: Int): Int = prefs(context).getInt("button_$id", 100).coerceIn(MIN_BUTTON, MAX_BUTTON)

    /** The size of the texts in percent, [MIN_FONT] to [MAX_FONT] (100 when none was chosen). */
    fun font(context: Context, id: Int): Int = prefs(context).getInt("font_$id", 100).coerceIn(MIN_FONT, MAX_FONT)

    fun saveSizes(context: Context, id: Int, button: Int, font: Int) {
        prefs(context).edit()
            .putInt("button_$id", button.coerceIn(MIN_BUTTON, MAX_BUTTON))
            .putInt("font_$id", font.coerceIn(MIN_FONT, MAX_FONT))
            .apply()
    }

    /** The side the power button stands on, [LEFT] or [RIGHT] (left when none was chosen). */
    fun side(context: Context, id: Int): Int = if (prefs(context).getInt("side_$id", LEFT) == RIGHT) RIGHT else LEFT

    fun saveSide(context: Context, id: Int, side: Int) {
        prefs(context).edit().putInt("side_$id", if (side == RIGHT) RIGHT else LEFT).apply()
    }

    private fun num(context: Context, key: String, id: Int, default: Int, range: IntRange): Int =
        prefs(context).getInt("${key}_$id", default).coerceIn(range)

    /** Everything else of a look, as the settings keep it. */
    class Extras(
        val accent: Int, val okColor: Int, val shape: Int, val show: Int,
        val border: Int, val borderColor: Int, val bits: Boolean, val tap: Int,
    )

    fun extras(context: Context, id: Int) = Extras(
        num(context, "accent", id, 0, 0..WidgetColors.ACCENT_COUNT), num(context, "ok", id, OK_GREEN, OK_GREEN..OK_ACCENT),
        num(context, "shape", id, SHAPE_CIRCLE, SHAPE_CIRCLE..SHAPE_SQUARE), num(context, "show", id, SHOW_ALL, 0..SHOW_ALL),
        num(context, "border", id, 0, 0..MAX_BORDER), num(context, "bcolor", id, BORDER_ACCENT, BORDER_ACCENT..BORDER_NEUTRAL),
        num(context, "bits", id, 0, 0..1) == 1, num(context, "tap", id, TAP_OPEN, TAP_OPEN..TAP_TOGGLE),
    )

    fun saveExtras(context: Context, id: Int, x: Extras) {
        prefs(context).edit()
            .putInt("accent_$id", x.accent).putInt("ok_$id", x.okColor).putInt("shape_$id", x.shape)
            .putInt("show_$id", x.show).putInt("border_$id", x.border).putInt("bcolor_$id", x.borderColor)
            .putInt("bits_$id", if (x.bits) 1 else 0).putInt("tap_$id", x.tap)
            .apply()
    }

    /** The look kept for the widget [id]. */
    fun look(context: Context, id: Int): WidgetLook {
        val x = extras(context, id)
        return WidgetLook(
            load(context, id), opacity(context, id), null, radius(context, id), height(context, id),
            button(context, id), font(context, id), side(context, id),
            x.accent, x.okColor, x.shape, x.show, x.border, x.borderColor, x.bits, x.tap,
        )
    }

    fun forget(context: Context, id: Int) {
        // The keys of the older widgets go too.
        val e = prefs(context).edit().remove("theme_$id").remove("radius_$id").remove("height_$id")
            .remove("button_$id").remove("font_$id").remove("side_$id")
            .remove("accent_$id").remove("ok_$id").remove("shape_$id").remove("show_$id").remove("border_$id")
            .remove("bcolor_$id").remove("bits_$id").remove("tap_$id")
        for (k in listOf("color", "shape", "opacity", "size", "content")) e.remove("${k}_$id")
        e.apply()
    }

    const val MAX_RADIUS = 40
    const val MIN_HEIGHT = 50
    /** The side of the power button in the layouts that have it beside the texts. */
    const val LEFT = 0
    const val RIGHT = 1
    const val OK_GREEN = 0
    const val OK_ACCENT = 1
    const val SHAPE_CIRCLE = 0
    const val SHAPE_ROUNDED = 1
    const val SHAPE_SQUARE = 2

    /** What the texts of a widget may hold; each can be left out. */
    const val SHOW_SERVER = 1
    const val SHOW_SPEED = 2
    const val SHOW_PING = 4
    const val SHOW_TOTAL = 8
    const val SHOW_TIME = 16
    const val SHOW_ALL = 31
    const val BORDER_ACCENT = 0
    const val BORDER_NEUTRAL = 1
    const val MAX_BORDER = 3
    const val TAP_OPEN = 0
    const val TAP_TOGGLE = 1
    const val MIN_BUTTON = 70
    const val MAX_BUTTON = 140
    const val MIN_FONT = 70
    const val MAX_FONT = 150

    /** Whether the size of the power button can be changed: a view is resized from a RemoteViews on Android 12+ only. */
    val canSizeButton: Boolean get() = Build.VERSION.SDK_INT >= 31

    /** The last server used, shown while disconnected (and the delay the app measured for it). */
    fun lastServer(context: Context): String? = prefs(context).getString("last_server", null)

    fun rememberServer(context: Context, name: String?) {
        if (name.isNullOrBlank()) return
        if (lastServer(context) == name) return
        prefs(context).edit().putString("last_server", name).apply()
    }
}

/** The least of the width and the height the launcher gave (the one it did not give, 0, does not count). */
private fun roomOf(w: Int, h: Int): Int = listOf(w, h).filter { it > 0 }.minOrNull() ?: 0

private fun speed(bytesPerSecond: Long, bits: Boolean = false): String {
    if (bits) {
        val b = bytesPerSecond * 8
        return when {
            b >= 1_000_000 -> String.format(Locale.US, "%.1f Mb/s", b / 1_000_000.0)
            b >= 1_000 -> String.format(Locale.US, "%d Kb/s", b / 1_000)
            else -> String.format(Locale.US, "%d b/s", b)
        }
    }
    return when {
        bytesPerSecond >= 1L shl 20 -> String.format(Locale.US, "%.1f MB/s", bytesPerSecond / 1048576.0)
        bytesPerSecond >= 1L shl 10 -> String.format(Locale.US, "%d KB/s", bytesPerSecond / 1024)
        else -> String.format(Locale.US, "%d B/s", bytesPerSecond)
    }
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
class WidgetPainter(private val context: Context, private val v: RemoteViews, private val look: WidgetLook, private val state: Int) {
    private val on = state != WidgetState.OFF
    private val connected = state == WidgetState.ON
    private val radius = look.radius
    private val heightPercent = look.height.coerceIn(WidgetTheme.MIN_HEIGHT, 100)
    private val buttonPercent = look.button.coerceIn(WidgetTheme.MIN_BUTTON, WidgetTheme.MAX_BUTTON)
    private val fontPercent = look.font.coerceIn(WidgetTheme.MIN_FONT, WidgetTheme.MAX_FONT)
    private val right = look.side == WidgetTheme.RIGHT
    private val okAccent = look.okColor == WidgetTheme.OK_ACCENT
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
        val l = WidgetColors.light(context).styled(look.accent, okAccent, false)
        val d = WidgetColors.dark(context).styled(look.accent, okAccent, true)
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

    /**
     * The card: one colour in every state, as opaque as chosen, with the corners the user chose (the ones the layout
     * was drawn with when none was) and, when asked to be lower than the room it has, centred in it. [heightDp] is the
     * height the launcher gives the widget (0 when not known) and [minCardDp] the least the content of this layout
     * needs: the card never gets lower than that.
     */
    fun background(heightDp: Int = 0, minCardDp: Int = 0, cornerDp: Int = 20) {
        set(R.id.widget_bg, "setColorFilter") { it.bg }
        v.setInt(R.id.widget_bg, "setImageAlpha", opacity * 255 / 100)
        if (radius >= 0) v.setImageViewResource(R.id.widget_bg, radiusDrawable(radius))
        // The border follows the corners the card has (the user chose, else the layout drawn with [cornerDp]); written
        // every time, since a launcher may redraw the widget over what it showed before.
        val line = look.border.coerceIn(0, WidgetTheme.MAX_BORDER)
        if (line > 0) {
            v.setImageViewResource(R.id.widget_border, borderDrawable(if (radius >= 0) radius else cornerDp, line))
            set(R.id.widget_border, "setColorFilter") {
                if (look.borderColor == WidgetTheme.BORDER_NEUTRAL) (if (clear) WHITE_SOFT else it.sub) else it.ring
            }
            v.setViewVisibility(R.id.widget_border, View.VISIBLE)
        } else {
            v.setViewVisibility(R.id.widget_border, View.GONE)
        }
        // A bigger button or bigger texts need more room: the card never gets lower than they do. The padding is
        // always written (0 at full height), since a launcher may redraw the widget over what it showed before.
        val least = minCardDp + maxOf(0, buttonDp() - buttonBase) + maxOf(0, fontPercent - 100) * 26 / 100
        var inset = 0
        if (heightPercent < 100 && heightDp > least) {
            val card = maxOf(heightDp * heightPercent / 100, least)
            inset = ((heightDp - card) / 2f * context.resources.displayMetrics.density).toInt()
        }
        v.setViewPadding(R.id.widget_root, 0, inset, 0, inset)
    }

    /** For a layout that has the button beside its texts: the button stands on the side the user chose (the layouts are
     *  drawn left to right, and drawn right to left they mirror, the texts keeping their direction). Always written, since
     *  a launcher may redraw the widget over what it showed before. [buttonAtEnd] is for the layout that draws the button at
     *  the right: it is mirrored to put it on the left. */
    fun mirror(buttonAtEnd: Boolean = false) = v.setInt(
        R.id.widget_root, "setLayoutDirection",
        if (right != buttonAtEnd) View.LAYOUT_DIRECTION_RTL else View.LAYOUT_DIRECTION_LTR,
    )

    private var buttonBase = 0
    private var room = 0

    /** What the layout is drawn with: the size of its power button in dp and the room the widget has (the least of its
     *  width and height, 0 when not known), so a bigger button never grows out of it. Called before the rest. */
    fun frame(buttonDp: Int, roomDp: Int) {
        buttonBase = buttonDp
        room = roomDp
    }

    /** The size of the power button in dp: the layout's own, as the user chose it (Android 12+), kept inside the room. */
    private fun buttonDp(): Int {
        if (buttonBase == 0 || Build.VERSION.SDK_INT < 31) return buttonBase
        var size = buttonBase * buttonPercent / 100
        if (buttonPercent > 100 && room > 0) size = minOf(size, maxOf(room - 8, buttonBase))
        return size
    }

    /** Whether the texts of kind [flag] (a SHOW_ flag of [WidgetTheme]) are shown. */
    fun shows(flag: Int) = (look.show and flag) != 0

    /** The power button: outlined while disconnected, green while connected, filled in the accent colour between. */
    fun button() {
        val (fill, outline) = when (look.shape) {
            WidgetTheme.SHAPE_ROUNDED -> R.drawable.wg_sq_14 to R.drawable.wg_sq_ring_14
            WidgetTheme.SHAPE_SQUARE -> R.drawable.wg_sq_6 to R.drawable.wg_sq_ring_6
            else -> R.drawable.wg_circle to R.drawable.wg_ring
        }
        v.setImageViewResource(R.id.wg_btn_bg, fill)
        v.setImageViewResource(R.id.wg_ring, outline)
        set(R.id.wg_btn_bg, "setColorFilter") { if (connected) it.okBtn else if (on) it.onBtn else it.offBtn }
        set(R.id.wg_icon, "setColorFilter") { if (connected) it.okIcon else if (on) it.onIcon else it.offIcon }
        set(R.id.wg_ring, "setColorFilter") { it.ring }
        v.setViewVisibility(R.id.wg_ring, if (on) View.GONE else View.VISIBLE)
        if (buttonBase > 0 && Build.VERSION.SDK_INT >= 31) {
            val size = buttonDp().toFloat()
            v.setViewLayoutWidth(R.id.wg_button, size, TypedValue.COMPLEX_UNIT_DIP)
            v.setViewLayoutHeight(R.id.wg_button, size, TypedValue.COMPLEX_UNIT_DIP)
            // The icon is half of the button, as the layouts draw it.
            v.setViewLayoutWidth(R.id.wg_icon, size / 2, TypedValue.COMPLEX_UNIT_DIP)
            v.setViewLayoutHeight(R.id.wg_icon, size / 2, TypedValue.COMPLEX_UNIT_DIP)
        }
    }

    /** Sets the size of the texts as the user chose it: each pair is a view and the size in sp the layout draws it with. */
    fun fonts(vararg sizes: Pair<Int, Float>) {
        for ((id, sp) in sizes) v.setTextViewTextSize(id, TypedValue.COMPLEX_UNIT_SP, sp * fontPercent / 100f)
    }

    /** A text that must fit a slot of [slotDp] (the layout has no room to spare): as large as [maxSp] allows down to
     *  [minSp], then the size the user chose on top of it. */
    fun fit(id: Int, text: CharSequence, slotDp: Int, maxSp: Float, minSp: Float) {
        val sp = (slotDp / (maxOf(text.length, 1) * 0.62f)).coerceIn(minSp, maxSp)
        v.setTextViewTextSize(id, TypedValue.COMPLEX_UNIT_SP, sp * fontPercent / 100f)
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

        /** The borders: a row for each corner (a step of 4 dp, 0 to 40), a column for each line (1 to 3 dp). */
        val BORDERS = arrayOf(
            intArrayOf(R.drawable.wg_bd_0_1, R.drawable.wg_bd_0_2, R.drawable.wg_bd_0_3),
            intArrayOf(R.drawable.wg_bd_4_1, R.drawable.wg_bd_4_2, R.drawable.wg_bd_4_3),
            intArrayOf(R.drawable.wg_bd_8_1, R.drawable.wg_bd_8_2, R.drawable.wg_bd_8_3),
            intArrayOf(R.drawable.wg_bd_12_1, R.drawable.wg_bd_12_2, R.drawable.wg_bd_12_3),
            intArrayOf(R.drawable.wg_bd_16_1, R.drawable.wg_bd_16_2, R.drawable.wg_bd_16_3),
            intArrayOf(R.drawable.wg_bd_20_1, R.drawable.wg_bd_20_2, R.drawable.wg_bd_20_3),
            intArrayOf(R.drawable.wg_bd_24_1, R.drawable.wg_bd_24_2, R.drawable.wg_bd_24_3),
            intArrayOf(R.drawable.wg_bd_28_1, R.drawable.wg_bd_28_2, R.drawable.wg_bd_28_3),
            intArrayOf(R.drawable.wg_bd_32_1, R.drawable.wg_bd_32_2, R.drawable.wg_bd_32_3),
            intArrayOf(R.drawable.wg_bd_36_1, R.drawable.wg_bd_36_2, R.drawable.wg_bd_36_3),
            intArrayOf(R.drawable.wg_bd_40_1, R.drawable.wg_bd_40_2, R.drawable.wg_bd_40_3),
        )

        fun borderDrawable(cornerDp: Int, lineDp: Int): Int =
            BORDERS[cornerDp.coerceIn(0, WidgetTheme.MAX_RADIUS) / 4][lineDp.coerceIn(1, WidgetTheme.MAX_BORDER) - 1]

        /** The background with corners of [dp] (a step of 4, 0 to 40). */
        fun radiusDrawable(dp: Int): Int = when (dp.coerceIn(0, WidgetTheme.MAX_RADIUS) / 4) {
            0 -> R.drawable.wg_rad_0
            1 -> R.drawable.wg_rad_4
            2 -> R.drawable.wg_rad_8
            3 -> R.drawable.wg_rad_12
            4 -> R.drawable.wg_rad_16
            5 -> R.drawable.wg_rad_20
            6 -> R.drawable.wg_rad_24
            7 -> R.drawable.wg_rad_28
            8 -> R.drawable.wg_rad_32
            9 -> R.drawable.wg_rad_36
            else -> R.drawable.wg_rad_40
        }
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

        /** A tap on [viewId] does what the user chose: opens the app, or connects and disconnects. */
        fun tapOn(context: Context, v: RemoteViews, look: WidgetLook, viewId: Int) {
            if (look.tap == WidgetTheme.TAP_TOGGLE) toggleOn(context, v, viewId) else openOn(context, v, viewId)
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

        /** The delay of the server. The preview of the settings ([sample]) shows an example while there is none (the VPN
         *  is off there, yet the preview is asked to show the connected look), so the chip is seen as it will be. */
        fun pingText(sample: Boolean = false): String? =
            VpnBridge.ping?.takeIf { it > 0 }?.let { "$it ms" } ?: if (sample) "42 ms" else null

        // The preview of the settings and of the widget list ([sample]) shows example numbers while there are none yet.
        private fun idle() = WidgetFeed.down == 0L && WidgetFeed.up == 0L

        fun downText(sample: Boolean = false, bits: Boolean = false): String =
            "↓ ${if (sample && idle()) (if (bits) "9.6 Mb/s" else "1.2 MB/s") else speed(WidgetFeed.down, bits)}"

        fun upText(sample: Boolean = false, bits: Boolean = false): String =
            "↑ ${if (sample && idle()) (if (bits) "2.7 Mb/s" else "340 KB/s") else speed(WidgetFeed.up, bits)}"
        fun totalText(sample: Boolean = false): String =
            if (sample && idle() && WidgetFeed.downTotal + WidgetFeed.upTotal == 0L) "48.2 MB"
            else size(WidgetFeed.downTotal + WidgetFeed.upTotal)

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

        /**
         * Android 15 and later: the list of widgets shows the real widget, drawn by this code in its connected look with
         * your last server, at the size the widget has when first placed. (Before that it shows the layouts of
         * `wg_preview_*`, which look the same.) Done once for each version of the app and each language: the system
         * limits how often a preview may be set.
         */
        fun publishPreviews(context: Context) {
            if (Build.VERSION.SDK_INT < 35) return
            val prefs = context.getSharedPreferences("widgets", Context.MODE_PRIVATE)
            val stamp = "${context.packageManager.getPackageInfo(context.packageName, 0).lastUpdateTime}" +
                "/${Locale.getDefault().toLanguageTag()}"
            if (prefs.getString("preview_stamp", null) == stamp) return
            val manager = AppWidgetManager.getInstance(context)
            val look = WidgetLook(WidgetTheme.AUTO, 100, WidgetState.ON)
            // The widget, its width and height in dp when placed (the cells of the launcher's grid).
            val sizes = listOf(Triple(VpnWidget(), 180, 56), Triple(VpnWidgetIcon(), 56, 56), Triple(VpnWidgetStats(), 180, 180))
            for ((provider, w, h) in sizes) {
                val options = Bundle().apply {
                    putInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, w)
                    putInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, h)
                }
                val views = provider.build(context, AppWidgetManager.INVALID_APPWIDGET_ID, options, look)
                manager.setWidgetPreview(
                    ComponentName(context, provider::class.java), AppWidgetProviderInfo.WIDGET_CATEGORY_HOME_SCREEN, views,
                )
            }
            prefs.edit().putString("preview_stamp", stamp).apply()
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
 * button, the server and one line (the state, or the speeds when connected); from about two and a half cells the delay
 * is in that line too. What the line holds is the choice of the user (the server, the speeds, the delay).
 * Always drawn left to right.
 */
class VpnWidget : KumoWidget() {
    override fun build(context: Context, id: Int, options: Bundle?, custom: WidgetLook?): RemoteViews {
        val look = custom ?: WidgetTheme.look(context, id)
        val state = look.state ?: WidgetState.current()
        val sample = custom != null
        val w = widthDp(options)
        val layout = when {
            w in 1 until 100 -> R.layout.wg_bar_icon
            w >= 280 -> R.layout.wg_bar_wide
            else -> R.layout.wg_bar
        }
        val v = RemoteViews(context.packageName, layout)
        val p = WidgetPainter(context, v, look, state)
        p.frame(40, roomOf(w, heightDp(options)))
        p.background(heightDp(options), 48)
        p.button()
        if (layout != R.layout.wg_bar_icon) {
            p.fonts(R.id.wg_title to 13f, R.id.wg_sub to 11f)
            if (p.shows(WidgetTheme.SHOW_SERVER)) {
                p.show(R.id.wg_title)
                p.main(R.id.wg_title, serverName(context))
            } else {
                p.hide(R.id.wg_title)
            }
            val sub = if (state != WidgetState.ON) {
                stateText(context, state)
            } else {
                val parts = ArrayList<String>()
                if (p.shows(WidgetTheme.SHOW_SPEED)) {
                    // Room is short below two cells and a half: one speed is enough there.
                    parts += downText(sample, look.bits)
                    if (w !in 1 until 200) parts += upText(sample, look.bits)
                }
                // The delay stands in the same row from about 240 dp on (below it the row has no room for it).
                if (p.shows(WidgetTheme.SHOW_PING) && (w >= 240 || w == 0)) pingText(sample)?.let { parts += it }
                if (parts.isEmpty()) stateText(context, state) else parts.joinToString(" · ")
            }
            p.sub(R.id.wg_sub, sub)
            p.mirror()
        }
        // The delay is in the row of the speeds: the chip of this layout is not used.
        if (layout == R.layout.wg_bar_wide) p.chip(null)
        tapOn(context, v, look, R.id.widget_root)
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
        p.frame(if (layout == R.layout.wg_power_tall) 64 else 44, roomOf(w, h))
        p.background(h, if (layout == R.layout.wg_power_tall) 96 else 52, if (layout == R.layout.wg_power_tall) 24 else 20)
        p.button()
        if (layout == R.layout.wg_power_wide) p.mirror()
        if (layout != R.layout.wg_power) {
            p.fonts(R.id.wg_title to 13f)
            p.main(R.id.wg_title, stateText(context, state))
        }
        toggleOn(context, v, R.id.widget_root)
        return v
    }
}

/**
 * The status card (2×2 by default). One row high, it becomes a bar with the speeds (two cells wide: one speed and the
 * data used; three and more: both speeds, the data used and the time). Taller, it has the big button in the middle when
 * narrow, and the speeds with the button in the corner when wide. Always drawn left to right. Each of the server, the
 * speeds, the delay, the data used and the time can be left out by the user.
 */
class VpnWidgetStats : KumoWidget() {
    override fun build(context: Context, id: Int, options: Bundle?, custom: WidgetLook?): RemoteViews {
        val look = custom ?: WidgetTheme.look(context, id)
        val state = look.state ?: WidgetState.current()
        val on = state == WidgetState.ON
        val sample = custom != null
        val bits = look.bits
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
        p.frame(
            when (layout) {
                R.layout.wg_card_s -> 38
                R.layout.wg_card_tall -> 64
                else -> 44
            },
            roomOf(w, h),
        )
        p.background(
            h,
            when (layout) {
                R.layout.wg_card_s -> 46
                R.layout.wg_card_m -> 52
                R.layout.wg_card_tall -> 130
                else -> 100
            },
            if (layout == R.layout.wg_card_tall || layout == R.layout.wg_card_wide) 24 else 20,
        )
        p.button()
        if (layout == R.layout.wg_card_s || layout == R.layout.wg_card_m) p.mirror()
        if (layout == R.layout.wg_card_wide) p.mirror(buttonAtEnd = true)
        when (layout) {
            R.layout.wg_card_s -> p.fonts(R.id.wg_title to 13f, R.id.wg_down to 12f, R.id.wg_total to 11f)
            R.layout.wg_card_m -> p.fonts(
                R.id.wg_title to 13f, R.id.wg_down to 12f, R.id.wg_up to 12f, R.id.wg_total to 12f, R.id.wg_time to 11f,
            )
            R.layout.wg_card_tall -> p.fonts(
                R.id.wg_title to 13f, R.id.wg_sub to 11f, R.id.wg_total to 12f, R.id.wg_time to 11f,
            )
            else -> p.fonts(
                R.id.wg_title to 13f, R.id.wg_chip to 11f, R.id.wg_down to 17f, R.id.wg_up to 17f,
                R.id.wg_total to 11f, R.id.wg_time to 11f,
            )
        }
        val speeds = p.shows(WidgetTheme.SHOW_SPEED)
        val total = p.shows(WidgetTheme.SHOW_TOTAL)
        val time = p.shows(WidgetTheme.SHOW_TIME) && on
        if (p.shows(WidgetTheme.SHOW_SERVER)) {
            p.show(R.id.wg_title)
            p.main(R.id.wg_title, serverName(context))
        } else if (layout == R.layout.wg_card_wide) {
            p.keep(R.id.wg_title) // the delay beside it keeps its place at the end of the row
        } else {
            p.hide(R.id.wg_title)
        }
        // Disconnected: the state stands where the speed would be, and nothing of a session is shown.
        fun speedText() = if (on && speeds) downText(sample, bits) else stateText(context, state)
        fun showUp() = if (on && speeds) { p.show(R.id.wg_up); p.main(R.id.wg_up, upText(sample, bits)) } else p.hide(R.id.wg_up)
        fun showTotal(quiet: Boolean) {
            if (on && total) {
                p.show(R.id.wg_total)
                if (quiet) p.sub(R.id.wg_total, totalText(sample)) else p.main(R.id.wg_total, totalText(sample))
            } else {
                p.hide(R.id.wg_total)
            }
        }
        when (layout) {
            R.layout.wg_card_s -> {
                p.main(R.id.wg_down, speedText())
                showTotal(quiet = true)
            }
            R.layout.wg_card_m -> {
                p.main(R.id.wg_down, speedText())
                showUp()
                showTotal(quiet = false)
                session(p, v, time)
            }
            R.layout.wg_card_tall -> {
                // The button stands in the middle: the rows under it keep their room while disconnected (written
                // but not shown), so it does not move when the state changes. A row the user left out is gone.
                p.sub(R.id.wg_sub, stateText(context, state))
                p.main(R.id.wg_down, downText(sample, bits))
                p.main(R.id.wg_up, upText(sample, bits))
                p.main(R.id.wg_total, totalText(sample))
                // The two speeds share the width of the card (less its padding): each is as large as fits, 9 to 15 sp.
                val slot = ((if (w > 0) w else 150) - 28) / 2
                p.fit(R.id.wg_down, downText(sample, bits), slot, 15f, 9f)
                p.fit(R.id.wg_up, upText(sample, bits), slot, 15f, 9f)
                for (row in listOf(R.id.wg_down, R.id.wg_up)) if (!speeds) p.hide(row) else if (on) p.show(row) else p.keep(row)
                if (!total) p.hide(R.id.wg_total) else if (on) p.show(R.id.wg_total) else p.keep(R.id.wg_total)
                session(p, v, time)
            }
            else -> {
                p.chip(if (on && p.shows(WidgetTheme.SHOW_PING)) pingText(sample) else null)
                p.main(R.id.wg_down, speedText())
                showUp()
                showTotal(quiet = true)
                session(p, v, time)
            }
        }
        tapOn(context, v, look, R.id.widget_root)
        toggleOn(context, v, R.id.wg_button)
        return v
    }
}
