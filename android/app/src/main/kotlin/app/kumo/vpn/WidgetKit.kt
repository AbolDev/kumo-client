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
import android.text.SpannableString
import android.text.Spanned
import android.text.style.StyleSpan
import android.text.style.TypefaceSpan
import android.graphics.Typeface
import android.view.Gravity
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
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

    /** The same colours with an accent of the user composed ([accent], any colour): the soft and the deep colours are made
     *  from it, lighter on a light card and darker on a dark one. */
    fun withAccent(accent: Int, okFollowsAccent: Boolean, dark: Boolean): WidgetColors {
        val white = 0xFFFFFFFF.toInt()
        val black = 0xFF000000.toInt()
        val onFg = if (luminance(accent) > 0.6f) 0xFF1C1C1A.toInt() else white
        return WidgetColors(
            bg, text, sub,
            accent, if (dark) mix(accent, black, 0.75f) else mix(accent, white, 0.88f),
            if (dark) mix(accent, white, 0.30f) else mix(accent, black, 0.35f),
            accent, onFg,
            if (dark) mix(accent, black, 0.65f) else mix(accent, white, 0.80f),
            if (dark) mix(accent, white, 0.75f) else mix(accent, black, 0.45f),
            if (okFollowsAccent) accent else okBtn, if (okFollowsAccent) onFg else okIcon,
        )
    }

    /** The same colours on a card of [card] (any colour): the texts are dark on a light card, light on a dark one. */
    fun withCard(card: Int): WidgetColors {
        val lightCard = luminance(card) > 0.55f
        return WidgetColors(
            card or 0xFF000000.toInt(),
            if (lightCard) 0xFF1C1C1A.toInt() else 0xFFF1EFE8.toInt(),
            if (lightCard) 0xFF5F5E5A.toInt() else 0xFFB4B2A9.toInt(),
            ring, offBtn, offIcon, onBtn, onIcon, chipBg, chipText, okBtn, okIcon,
        )
    }

    companion object {
        private fun c(v: Long) = v.toInt()

        /** How light [color] is, 0 (black) to 1 (white). */
        fun luminance(color: Int): Float =
            (0.299f * ((color shr 16) and 0xFF) + 0.587f * ((color shr 8) and 0xFF) + 0.114f * (color and 0xFF)) / 255f

        /** [a] with [part] (0 to 1) of [b] mixed in, opaque. */
        fun mix(a: Int, b: Int, part: Float): Int {
            fun ch(shift: Int) = (((a shr shift) and 0xFF) * (1 - part) + ((b shr shift) and 0xFF) * part).toInt().coerceIn(0, 255)
            return (0xFF shl 24) or (ch(16) shl 16) or (ch(8) shl 8) or ch(0)
        }

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

/**
 * A look of a widget, everything the user can choose for it. [theme] the colours ([WidgetTheme]), [opacity] of the
 * background (0 to 100), [radius] of its corners in dp (-1 while none was chosen: the widget keeps the corners it was
 * drawn with), [height] of the card in the room the launcher gives it (50 to 100 percent), [button] and [font] the size
 * of the power button and of every text (percent of what the layout was drawn with, each its own choice), [side] of the
 * power button. [accent] one of the accent colours (0: the look own) and [customAccent] one the user composed (0: none,
 * wins over [accent]); [okColor] whether the connected button is green or the accent; [customCard] a colour of the card
 * of the user's own (0: the one of the look); [stateColor] a colour of the button for each state (off, connecting, on;
 * 0: the look own). [shape] and [icon] of the power button. [show] which texts are shown (the SHOW_ flags), [info] an
 * extra of the server (its protocol, the flag of its name), [title] a text instead of the name of the server and
 * [stateLabel] one for each state (empty: the usual). [weight], [family] and [align] of the texts, [bits] the unit of the
 * speeds, [lang] the language of the words on the widget ("" follows the app), [border] 0 to 3 dp and its [borderColor], [depth] of the card (a shadow), [spacing] inside it and [tap] what a
 * tap does. With [state] the widget is drawn as in that state (the preview of the settings), else as in the one the VPN
 * is in; it is not a part of what is kept.
 */
class WidgetLook(
    var theme: Int = WidgetTheme.AUTO, var opacity: Int = 100, var state: Int? = null,
    var radius: Int = -1, var height: Int = 100,
    var button: Int = 100, var font: Int = 100,
    var side: Int = WidgetTheme.LEFT,
    var accent: Int = 0, var okColor: Int = WidgetTheme.OK_GREEN,
    var shape: Int = WidgetTheme.SHAPE_CIRCLE, var show: Int = WidgetTheme.SHOW_ALL,
    var border: Int = 0, var borderColor: Int = WidgetTheme.BORDER_ACCENT,
    var bits: Boolean = false, var tap: Int = WidgetTheme.TAP_OPEN,
    var customAccent: Int = 0, var customCard: Int = 0,
    var stateColor: IntArray = IntArray(3), var title: String = "",
    var stateLabel: Array<String> = arrayOf("", "", ""),
    var icon: Int = 0, var weight: Int = WidgetTheme.WEIGHT_BOLD, var family: Int = 0,
    var depth: Int = 0, var info: Int = WidgetTheme.INFO_NONE,
    var align: Int = WidgetTheme.ALIGN_START, var spacing: Int = WidgetTheme.SPACING_NORMAL,
    var lang: String = "",
) {
    fun copy() = WidgetLook(
        theme, opacity, state, radius, height, button, font, side, accent, okColor, shape, show, border, borderColor,
        bits, tap, customAccent, customCard, stateColor.copyOf(), title, stateLabel.copyOf(), icon, weight, family,
        depth, info, align, spacing, lang,
    )

    /** What is kept of the look, as text. */
    fun toJson(): String = JSONObject().apply {
        put("theme", theme).put("opacity", opacity).put("radius", radius).put("height", height)
        put("button", button).put("font", font).put("side", side).put("accent", accent).put("ok", okColor)
        put("shape", shape).put("show", show).put("border", border).put("bcolor", borderColor)
        put("bits", bits).put("tap", tap).put("cacc", customAccent).put("ccard", customCard)
        put("sc", JSONArray(stateColor.toList())).put("title", title).put("sl", JSONArray(stateLabel.toList()))
        put("icon", icon).put("weight", weight).put("family", family).put("depth", depth)
        put("info", info).put("align", align).put("spacing", spacing).put("lang", lang)
    }.toString()

    companion object {
        /** The look kept as [text] (null when it is not one). A value out of its range falls back to the usual. */
        fun fromJson(text: String): WidgetLook? = runCatching {
            val j = JSONObject(text)
            fun n(key: String, default: Int, range: IntRange) = j.optInt(key, default).let { if (it in range) it else default }
            WidgetLook(
                theme = n("theme", WidgetTheme.AUTO, 0..WidgetTheme.CLEAR), opacity = n("opacity", 100, 0..100),
                radius = n("radius", -1, -1..WidgetTheme.MAX_RADIUS), height = n("height", 100, WidgetTheme.MIN_HEIGHT..100),
                button = n("button", 100, WidgetTheme.MIN_BUTTON..WidgetTheme.MAX_BUTTON),
                font = n("font", 100, WidgetTheme.MIN_FONT..WidgetTheme.MAX_FONT),
                side = n("side", WidgetTheme.LEFT, 0..1), accent = n("accent", 0, 0..WidgetColors.ACCENT_COUNT),
                okColor = n("ok", WidgetTheme.OK_GREEN, 0..1), shape = n("shape", WidgetTheme.SHAPE_CIRCLE, 0..2),
                show = n("show", WidgetTheme.SHOW_ALL, 0..WidgetTheme.SHOW_ALL), border = n("border", 0, 0..WidgetTheme.MAX_BORDER),
                borderColor = n("bcolor", WidgetTheme.BORDER_ACCENT, 0..1), bits = j.optBoolean("bits", false),
                tap = n("tap", WidgetTheme.TAP_OPEN, 0..1), customAccent = j.optInt("cacc", 0), customCard = j.optInt("ccard", 0),
                stateColor = IntArray(3) { j.optJSONArray("sc")?.optInt(it, 0) ?: 0 },
                title = j.optString("title", "").take(WidgetTheme.MAX_TEXT),
                stateLabel = Array(3) { (j.optJSONArray("sl")?.optString(it, "") ?: "").take(WidgetTheme.MAX_TEXT) },
                icon = n("icon", 0, 0..WidgetTheme.ICON_COUNT - 1), weight = n("weight", WidgetTheme.WEIGHT_BOLD, 0..1),
                family = n("family", 0, 0..WidgetTheme.FAMILY_COUNT - 1), depth = n("depth", 0, 0..2),
                info = n("info", WidgetTheme.INFO_NONE, 0..2), align = n("align", WidgetTheme.ALIGN_START, 0..2),
                spacing = n("spacing", WidgetTheme.SPACING_NORMAL, 0..2),
                lang = j.optString("lang", "").let { if (it in WidgetLang.CODES) it else "" },
            )
        }.getOrNull()
    }
}

/**
 * The looks of the placed widgets, chosen in [WidgetConfigActivity] and kept per widget id (as text, see
 * [WidgetLook.toJson]), and the looks the user saved with a name to put on other widgets.
 */
object WidgetTheme {
    const val AUTO = 0
    const val LIGHT = 1
    const val DARK = 2

    /** The see-through look of the first versions: the dark colours with white texts over the wallpaper.
     *  Not offered any more (the opacity does it); a widget that has it keeps it. */
    const val CLEAR = 3

    private fun prefs(context: Context) = context.getSharedPreferences("widgets", Context.MODE_PRIVATE)

    /** The look kept for the widget [id]; one placed with an older version has its older settings read. */
    fun look(context: Context, id: Int): WidgetLook {
        prefs(context).getString("look_$id", null)?.let { text -> WidgetLook.fromJson(text)?.let { return it } }
        return legacy(context, id)
    }

    fun saveLook(context: Context, id: Int, look: WidgetLook) {
        prefs(context).edit().putString("look_$id", look.toJson()).apply()
    }

    /** The settings of the versions that kept each value on its own. */
    private fun legacy(context: Context, id: Int): WidgetLook {
        val p = prefs(context)
        fun n(key: String, default: Int, range: IntRange) = p.getInt("${key}_$id", default).coerceIn(range)
        val theme = n("theme", AUTO, AUTO..CLEAR)
        val saved = p.getInt("opacity_$id", -1)
        val radius = p.getInt("radius_$id", -1)
        return WidgetLook(
            theme = theme, opacity = if (saved in 0..100) saved else if (theme == CLEAR) 45 else 100,
            radius = if (radius in 0..MAX_RADIUS) radius else -1, height = n("height", 100, MIN_HEIGHT..100),
            button = n("button", 100, MIN_BUTTON..MAX_BUTTON), font = n("font", 100, MIN_FONT..MAX_FONT),
            side = if (p.getInt("side_$id", LEFT) == RIGHT) RIGHT else LEFT,
            accent = n("accent", 0, 0..WidgetColors.ACCENT_COUNT), okColor = n("ok", OK_GREEN, OK_GREEN..OK_ACCENT),
            shape = n("shape", SHAPE_CIRCLE, SHAPE_CIRCLE..SHAPE_SQUARE), show = n("show", SHOW_ALL, 0..SHOW_ALL),
            border = n("border", 0, 0..MAX_BORDER), borderColor = n("bcolor", BORDER_ACCENT, BORDER_ACCENT..BORDER_NEUTRAL),
            bits = n("bits", 0, 0..1) == 1, tap = n("tap", TAP_OPEN, TAP_OPEN..TAP_TOGGLE),
        )
    }

    fun forget(context: Context, id: Int) {
        val e = prefs(context).edit().remove("look_$id")
        // The keys of the older versions go too.
        for (k in listOf(
            "theme", "radius", "height", "button", "font", "side", "accent", "ok", "shape", "show", "border", "bcolor",
            "bits", "tap", "color", "opacity", "size", "content",
        )) e.remove("${k}_$id")
        e.apply()
    }

    /** The ids of every placed widget of Kumo. */
    fun placedIds(context: Context): IntArray {
        val manager = AppWidgetManager.getInstance(context)
        return listOf(VpnWidget::class.java, VpnWidgetIcon::class.java, VpnWidgetStats::class.java)
            .flatMap { manager.getAppWidgetIds(ComponentName(context, it)).toList() }
            .toIntArray()
    }

    /** Puts [look] on every placed widget; the number of the widgets it was put on. */
    fun applyToAll(context: Context, look: WidgetLook): Int {
        val ids = placedIds(context)
        for (id in ids) saveLook(context, id, look.copy().also { it.state = null })
        return ids.size
    }

    /** The looks the user saved, each with its name. */
    class Saved(val name: String, val look: WidgetLook)

    fun savedLooks(context: Context): List<Saved> = runCatching {
        val a = JSONArray(prefs(context).getString("saved_looks", "[]"))
        (0 until a.length()).mapNotNull {
            val o = a.optJSONObject(it) ?: return@mapNotNull null
            val look = WidgetLook.fromJson(o.optString("look")) ?: return@mapNotNull null
            Saved(o.optString("name").take(MAX_TEXT), look)
        }
    }.getOrDefault(emptyList())

    private fun writeSaved(context: Context, list: List<Saved>) {
        val a = JSONArray()
        for (s in list) a.put(JSONObject().put("name", s.name).put("look", s.look.toJson()))
        prefs(context).edit().putString("saved_looks", a.toString()).apply()
    }

    /** Saves [look] under [name]; a look of that name is replaced. */
    fun saveNamed(context: Context, name: String, look: WidgetLook) {
        val kept = savedLooks(context).filter { it.name != name }
        writeSaved(context, kept + Saved(name, look.copy().also { it.state = null }))
    }

    fun deleteNamed(context: Context, name: String) = writeSaved(context, savedLooks(context).filter { it.name != name })

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
    const val WEIGHT_BOLD = 0
    const val WEIGHT_REGULAR = 1

    /** The families of the texts: the phone's own, serif, monospace, condensed, light. */
    const val FAMILY_COUNT = 5
    const val ICON_COUNT = 5
    const val DEPTH_FLAT = 0
    const val INFO_NONE = 0
    const val INFO_PROTOCOL = 1
    const val INFO_FLAG = 2
    const val ALIGN_START = 0
    const val ALIGN_CENTER = 1
    const val ALIGN_END = 2
    const val SPACING_COMPACT = 0
    const val SPACING_NORMAL = 1
    const val SPACING_ROOMY = 2

    /** The longest text the user can write (the name of the widget, of a look, of a state). */
    const val MAX_TEXT = 24

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

/**
 * The language of the words a widget writes. The app has its own language (the setting of the app, or the phone when
 * it follows it), and each widget can have another: its look keeps the code ("" follows the app).
 */
object WidgetLang {
    /** The codes of the languages of the app, as the app keeps them. */
    val CODES = listOf("en", "fa", "ru", "vi", "zh", "zh-TW", "ar")

    /** Each language written in itself. */
    val NAMES = mapOf(
        "en" to "English", "zh" to "中文简体", "zh-TW" to "中文繁體", "vi" to "Tiếng Việt",
        "ru" to "Русский", "fa" to "فارسی", "ar" to "عربي",
    )

    private var stamp = ""
    private var cached: String? = null

    /** The language the user chose in the app (null while the app follows the phone). Read again only when the settings
     *  file changed: the widgets ask at every redraw. */
    fun appCode(context: Context): String? {
        val file = File(context.filesDir, "settings.json")
        val now = "${file.lastModified()}:${file.length()}"
        if (now == stamp) return cached
        val j = VpnControl.readJson(context, "settings.json")
        cached = if (j == null || j.isNull("language")) null else j.optString("language").takeIf { it in CODES }
        stamp = now
        return cached
    }

    /** [context] with the resources of the language [code] (as it is when null: the phone). */
    fun localized(context: Context, code: String?): Context {
        if (code == null) return context
        val locale = if (code == "zh-TW") Locale("zh", "TW") else Locale(code)
        val conf = Configuration(context.resources.configuration)
        conf.setLocale(locale)
        return context.createConfigurationContext(conf)
    }

    /** The resources for the words of the widget of [look]: its language, else the one of the app. */
    fun forLook(context: Context, look: WidgetLook?): Context =
        localized(context, look?.lang?.takeIf { it.isNotEmpty() } ?: appCode(context))
}

/** What the widgets say of the server besides its name: the protocol of the configuration, the flag of the name. */
object WidgetInfo {
    private var key = ""
    private var cached: String? = null

    // Outbounds that are not the server itself.
    private val OTHER = setOf("direct", "block", "dns", "selector", "urltest", "socks", "mixed", "http", "freedom", "blackhole")

    /** The protocol of the server in use, from the configuration the service runs (null when it is not known). */
    fun protocol(context: Context): String? {
        for (name in listOf("active_config.json", "xray_config.json")) {
            val f = File(context.filesDir, name)
            if (!f.isFile) continue
            val now = "$name:${f.lastModified()}:${f.length()}"
            if (now == key) {
                if (cached != null) return cached
                continue
            }
            val found = runCatching { parse(f.readText()) }.getOrNull()
            if (found != null) {
                key = now
                cached = found
                return found
            }
        }
        return null
    }

    private fun parse(text: String): String? {
        val outbounds = JSONObject(text).optJSONArray("outbounds") ?: return null
        for (i in 0 until outbounds.length()) {
            val o = outbounds.optJSONObject(i) ?: continue
            val type = o.optString("type", o.optString("protocol", "")).lowercase()
            if (type.isEmpty() || type in OTHER) continue
            val reality = o.optJSONObject("tls")?.optJSONObject("reality")?.optBoolean("enabled", false) == true ||
                o.optJSONObject("streamSettings")?.optString("security") == "reality"
            return type.uppercase() + if (reality) " Reality" else ""
        }
        return null
    }

    /** The flag in the name of the server (two regional indicators, as the names of the servers are often written). */
    fun flag(name: String): String? {
        var i = 0
        while (i < name.length) {
            val a = name.codePointAt(i)
            val next = i + Character.charCount(a)
            if (a in 0x1F1E6..0x1F1FF && next < name.length) {
                val b = name.codePointAt(next)
                if (b in 0x1F1E6..0x1F1FF) return String(Character.toChars(a)) + String(Character.toChars(b))
            }
            i = next
        }
        return null
    }

    /** The extra line of [look] for the server [name]: null when the look wants none or it is not known. */
    fun text(context: Context, look: WidgetLook, name: String, sample: Boolean): String? = when (look.info) {
        WidgetTheme.INFO_PROTOCOL -> protocol(context) ?: if (sample) "VLESS" else null
        WidgetTheme.INFO_FLAG -> flag(name) ?: if (sample) "🇩\uDDEA" else null
        else -> null
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

    // The size of the texts as drawn: the one chosen, less when the room the widget has is too low for it.
    private var fontEff = fontPercent
    private var rtl = false
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

    /** The colours of the look for the light phone or the dark one: its accent (one of the five, or the user own), its card. */
    private fun colorsFor(dark: Boolean): WidgetColors {
        var c = if (dark) WidgetColors.dark(context) else WidgetColors.light(context)
        c = if (look.customAccent != 0) c.withAccent(look.customAccent, okAccent, dark) else c.styled(look.accent, okAccent, dark)
        if (look.customCard != 0) c = c.withCard(look.customCard)
        return c
    }

    init {
        val l = colorsFor(false)
        val d = colorsFor(true)
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
        if (heightDp > 0 && least > heightDp && fontPercent > 100) fontEff = maxOf(100, fontPercent * heightDp / least)
        var inset = 0
        if (heightPercent < 100 && heightDp > least) {
            val card = maxOf(heightDp * heightPercent / 100, least)
            inset = ((heightDp - card) / 2f * context.resources.displayMetrics.density).toInt()
        }
        v.setViewPadding(R.id.widget_root, 0, inset, 0, inset)
        // The depth: a shadow of the card, a sliver under it. The card, its border and the shadow are lifted together.
        val density = context.resources.displayMetrics.density
        val lift = when (look.depth) { 1 -> 2; 2 -> 4; else -> 0 }
        val liftPx = (lift * density).toInt()
        if (lift > 0) {
            v.setImageViewResource(R.id.widget_shadow, radiusDrawable(if (radius >= 0) radius else cornerDp))
            v.setInt(R.id.widget_shadow, "setColorFilter", 0x40000000)
            v.setInt(R.id.widget_shadow, "setImageAlpha", opacity * 255 / 100)
            v.setViewPadding(R.id.widget_shadow, 0, liftPx, 0, 0)
            v.setViewVisibility(R.id.widget_shadow, View.VISIBLE)
        } else {
            v.setViewVisibility(R.id.widget_shadow, View.GONE)
        }
        v.setViewPadding(R.id.widget_bg, 0, 0, 0, liftPx)
        v.setViewPadding(R.id.widget_border, 0, 0, 0, liftPx)
    }

    /** The room inside the card: the paddings the layout was drawn with (dp, the start and the end of its row), made
     *  tighter or wider as the user chose. Called after [mirror]. */
    fun pad(startDp: Int, endDp: Int, topDp: Int, bottomDp: Int) {
        val d = context.resources.displayMetrics.density * when (look.spacing) {
            WidgetTheme.SPACING_COMPACT -> 0.6f
            WidgetTheme.SPACING_ROOMY -> 1.4f
            else -> 1f
        }
        val left = if (rtl) endDp else startDp
        val right = if (rtl) startDp else endDp
        v.setViewPadding(R.id.widget_content, (left * d).toInt(), (topDp * d).toInt(), (right * d).toInt(), (bottomDp * d).toInt())
    }

    /** The alignment the user chose for these texts (written every time, the layouts draw them at the start). */
    fun align(vararg ids: Int) {
        val g = when (look.align) {
            WidgetTheme.ALIGN_CENTER -> Gravity.CENTER_HORIZONTAL or Gravity.TOP
            WidgetTheme.ALIGN_END -> Gravity.END or Gravity.TOP
            else -> Gravity.START or Gravity.TOP
        }
        for (id in ids) v.setInt(id, "setGravity", g)
    }

    /** For a layout that has the button beside its texts: the button stands on the side the user chose (the layouts are
     *  drawn left to right, and drawn right to left they mirror, the texts keeping their direction). Always written, since
     *  a launcher may redraw the widget over what it showed before. [buttonAtEnd] is for the layout that draws the button at
     *  the right: it is mirrored to put it on the left. */
    fun mirror(buttonAtEnd: Boolean = false) {
        rtl = right != buttonAtEnd
        v.setInt(R.id.widget_root, "setLayoutDirection", if (rtl) View.LAYOUT_DIRECTION_RTL else View.LAYOUT_DIRECTION_LTR)
    }

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
        v.setContentDescription(R.id.wg_icon, WidgetLang.forLook(context, look).getString(R.string.widget_toggle))
        v.setImageViewResource(R.id.wg_btn_bg, fill)
        v.setImageViewResource(R.id.wg_ring, outline)
        v.setImageViewResource(
            R.id.wg_icon,
            when (look.icon) {
                1 -> R.drawable.ic_shield
                2 -> R.drawable.ic_lock
                3 -> R.drawable.ic_bolt
                4 -> R.drawable.ic_notification
                else -> R.drawable.ic_power
            },
        )
        val own = look.stateColor.getOrElse(if (state == WidgetState.ON) 2 else if (state == WidgetState.OFF) 0 else 1) { 0 }
        if (own != 0) {
            // A colour the user gave this state: the same on a light and a dark phone. Disconnected, the button is an
            // outline in it; otherwise it is filled with it.
            if (!on) {
                v.setInt(R.id.wg_btn_bg, "setColorFilter", (own and 0x00FFFFFF) or 0x26000000)
                v.setInt(R.id.wg_icon, "setColorFilter", own)
            } else {
                v.setInt(R.id.wg_btn_bg, "setColorFilter", own)
                v.setInt(R.id.wg_icon, "setColorFilter", if (WidgetColors.luminance(own) > 0.6f) 0xFF1C1C1A.toInt() else 0xFFFFFFFF.toInt())
            }
            v.setInt(R.id.wg_ring, "setColorFilter", own)
        } else {
            set(R.id.wg_btn_bg, "setColorFilter") { if (connected) it.okBtn else if (on) it.onBtn else it.offBtn }
            set(R.id.wg_icon, "setColorFilter") { if (connected) it.okIcon else if (on) it.onIcon else it.offIcon }
            set(R.id.wg_ring, "setColorFilter") { it.ring }
        }
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
        for ((id, sp) in sizes) v.setTextViewTextSize(id, TypedValue.COMPLEX_UNIT_SP, sp * fontEff / 100f)
    }

    /** A text that must fit a slot of [slotDp] (the layout has no room to spare): as large as [maxSp] allows down to
     *  [minSp], then the size the user chose on top of it. */
    fun fit(id: Int, text: CharSequence, slotDp: Int, maxSp: Float, minSp: Float) {
        val sp = (slotDp / (maxOf(text.length, 1) * 0.62f)).coerceIn(minSp, maxSp)
        v.setTextViewTextSize(id, TypedValue.COMPLEX_UNIT_SP, sp * fontEff / 100f)
    }

    private val families = arrayOf(null, "serif", "monospace", "sans-serif-condensed", "sans-serif-light")

    /** [text] in the weight and the family the user chose (the layouts draw plain texts: it is all in the text). */
    private fun styled(text: CharSequence, bold: Boolean): CharSequence {
        if (text.isEmpty()) return text
        val s = SpannableString(text)
        s.setSpan(StyleSpan(if (bold) Typeface.BOLD else Typeface.NORMAL), 0, s.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        families.getOrNull(look.family)?.let { s.setSpan(TypefaceSpan(it), 0, s.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE) }
        return s
    }

    /** A main text (the name, the speeds). */
    fun main(id: Int, text: CharSequence) {
        v.setTextViewText(id, styled(text, look.weight == WidgetTheme.WEIGHT_BOLD))
        set(id, "setTextColor") { if (clear) WHITE else it.text }
    }

    /** A quieter text under it. */
    fun sub(id: Int, text: CharSequence) {
        v.setTextViewText(id, styled(text, false))
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

        /** The words for [state]: the ones the user wrote for it in [look], else the usual. */
        fun stateText(context: Context, state: Int, look: WidgetLook? = null): String {
            val own = look?.stateLabel?.getOrNull(if (state == WidgetState.ON) 2 else if (state == WidgetState.OFF) 0 else 1)
            if (!own.isNullOrBlank()) return own
            return WidgetLang.forLook(context, look).getString(
                when (state) {
                    WidgetState.ON -> R.string.widget_on
                    WidgetState.CONNECTING -> R.string.widget_connecting
                    WidgetState.STOPPING -> R.string.widget_disconnecting
                    else -> R.string.widget_off
                },
            )
        }

        /** The title of a widget: the text the user wrote, else the server. */
        fun titleText(context: Context, look: WidgetLook): String = look.title.takeIf { it.isNotBlank() } ?: serverName(context)

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
        fun preview(context: Context, id: Int, look: WidgetLook, widthDp: Int = 0, heightDp: Int = 0): RemoteViews? {
            val manager = AppWidgetManager.getInstance(context)
            val info = manager.getAppWidgetInfo(id) ?: return null
            val provider = kinds.map { it() }.firstOrNull { it::class.java.name == info.provider.className } ?: return null
            // A size of the preview other than the real one: the widget is laid out as if the launcher had given it.
            val options = if (widthDp > 0 && heightDp > 0) {
                Bundle().apply {
                    putInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, widthDp)
                    putInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, heightDp)
                }
            } else {
                manager.getAppWidgetOptions(id)
            }
            return provider.build(context, id, options, look)
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
                p.main(R.id.wg_title, titleText(context, look))
            } else {
                p.hide(R.id.wg_title)
            }
            val sub = if (state != WidgetState.ON) {
                stateText(context, state, look)
            } else {
                val parts = ArrayList<String>()
                if (p.shows(WidgetTheme.SHOW_SPEED)) {
                    // Room is short below two cells and a half: one speed is enough there.
                    parts += downText(sample, look.bits)
                    if (w !in 1 until 200) parts += upText(sample, look.bits)
                }
                // The delay stands in the same row from about 240 dp on (below it the row has no room for it).
                if (p.shows(WidgetTheme.SHOW_PING) && (w >= 240 || w == 0)) pingText(sample)?.let { parts += it }
                if (w >= 240 || w == 0) WidgetInfo.text(context, look, serverName(context), sample)?.let { parts += it }
                if (parts.isEmpty()) stateText(context, state, look) else parts.joinToString(" · ")
            }
            p.sub(R.id.wg_sub, sub)
            p.mirror()
            p.pad(8, 12, 0, 0)
            p.align(R.id.wg_title, R.id.wg_sub)
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
        if (layout == R.layout.wg_power_wide) {
            p.mirror()
            p.pad(10, 14, 0, 0)
        }
        if (layout == R.layout.wg_power_tall) p.pad(12, 12, 12, 12)
        if (layout != R.layout.wg_power) {
            p.fonts(R.id.wg_title to 13f)
            p.main(R.id.wg_title, stateText(context, state, look))
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
            R.layout.wg_card_s -> { p.pad(8, 10, 0, 0); p.align(R.id.wg_title, R.id.wg_down) }
            R.layout.wg_card_m -> { p.pad(8, 14, 0, 0); p.align(R.id.wg_title, R.id.wg_down, R.id.wg_up) }
            R.layout.wg_card_tall -> { p.pad(14, 14, 14, 14); p.align(R.id.wg_title, R.id.wg_sub) }
            else -> { p.pad(14, 14, 12, 12); p.align(R.id.wg_title, R.id.wg_down, R.id.wg_up) }
        }
        // What the server is, besides its name (the protocol, the flag): in the quiet line of the layout.
        val infoLine = if (on) WidgetInfo.text(context, look, serverName(context), sample) else null
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
            p.main(R.id.wg_title, titleText(context, look))
        } else if (layout == R.layout.wg_card_wide) {
            p.keep(R.id.wg_title) // the delay beside it keeps its place at the end of the row
        } else {
            p.hide(R.id.wg_title)
        }
        // Disconnected: the state stands where the speed would be, and nothing of a session is shown.
        fun speedText() = if (on && speeds) downText(sample, bits) else stateText(context, state, look)
        fun showUp() = if (on && speeds) { p.show(R.id.wg_up); p.main(R.id.wg_up, upText(sample, bits)) } else p.hide(R.id.wg_up)
        fun showTotal(quiet: Boolean) {
            val line = listOfNotNull(if (total) totalText(sample) else null, infoLine).joinToString(" · ")
            if (on && line.isNotEmpty()) {
                p.show(R.id.wg_total)
                if (quiet) p.sub(R.id.wg_total, line) else p.main(R.id.wg_total, line)
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
                p.sub(R.id.wg_sub, listOfNotNull(stateText(context, state, look), infoLine).joinToString(" · "))
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
