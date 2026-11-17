package app.kumo.vpn

import android.app.Activity
import android.appwidget.AppWidgetManager
import android.content.Intent
import android.content.res.ColorStateList
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Bundle
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.WindowInsets
import android.view.WindowManager
import android.widget.CheckBox
import android.widget.FrameLayout
import android.widget.HorizontalScrollView
import android.widget.LinearLayout
import android.widget.RadioButton
import android.widget.ScrollView
import android.widget.SeekBar
import android.widget.TextView

/**
 * Opens when a widget is placed (on Android 12+ only if the user asks, from its long-press menu): the look of that
 * widget. The top of the screen shows the phone's own wallpaper (the window lets it through) with the real widget on
 * it at its real size; a sheet under it holds the colour of the background (follow the phone, light, dark) and how
 * opaque it is. The preview follows every change; nothing is kept until Save.
 */
class WidgetConfigActivity : Activity() {
    private var widgetId = AppWidgetManager.INVALID_APPWIDGET_ID
    private var theme = WidgetTheme.AUTO
    private var opacity = 100

    /** The corners in dp. A widget that never had them chosen starts at the usual 20 and keeps the corners it was drawn
     *  with until the slider is moved ([radiusChosen]). */
    private var radius = 20
    private var radiusChosen = false

    /** How high the card stands in the room of the widget, in percent. */
    private var height = 100

    /** The size of the power button and the size of the texts, each in percent and each its own. */
    private var button = 100
    private var font = 100

    /** The side of the power button in the layouts that have it beside the texts. */
    private var side = WidgetTheme.LEFT

    /** The accent colour (0: the look own), whether the connected button follows it, the shape of the button, what the
     *  widget shows, its border, the unit of the speeds and what a tap does. */
    private var accentPick = 0
    private var okColor = WidgetTheme.OK_GREEN
    private var shape = WidgetTheme.SHAPE_CIRCLE
    private var show = WidgetTheme.SHOW_ALL
    private var border = 0
    private var borderColor = WidgetTheme.BORDER_ACCENT
    private var bits = false
    private var tap = WidgetTheme.TAP_OPEN

    private lateinit var column: LinearLayout

    /** The state the preview shows (the VPN's own now, or what the user picked). */
    private var shownState = WidgetState.OFF

    private lateinit var stage: FrameLayout
    private val themeRows = ArrayList<Pair<RadioButton, Int>>()
    private val stateLabels = ArrayList<Pair<TextView, Int>>()

    private fun dp(v: Int) = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v.toFloat(), resources.displayMetrics).toInt()

    private val night: Boolean
        get() = (resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES
    private val ink get() = if (night) 0xFFF2F2F5.toInt() else 0xFF1B1B1F.toInt()
    private val inkSoft get() = if (night) 0xA6FFFFFF.toInt() else 0x8C1B1B1F.toInt()
    private val page get() = if (night) 0xFF121214.toInt() else 0xFFF4F4F7.toInt()
    private val panel get() = if (night) 0xFF1E1E22.toInt() else 0xFFFFFFFF.toInt()
    private val accent get() = (if (night) WidgetColors.dark(this) else WidgetColors.light(this)).ring
    private val onAccent get() = if (night) 0xFF101012.toInt() else 0xFFFFFFFF.toInt()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setResult(RESULT_CANCELED)
        widgetId = intent?.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, AppWidgetManager.INVALID_APPWIDGET_ID)
            ?: AppWidgetManager.INVALID_APPWIDGET_ID
        if (widgetId == AppWidgetManager.INVALID_APPWIDGET_ID) {
            finish()
            return
        }
        val saved = WidgetTheme.load(this, widgetId)
        opacity = WidgetTheme.opacity(this, widgetId)
        height = WidgetTheme.height(this, widgetId)
        button = WidgetTheme.button(this, widgetId)
        font = WidgetTheme.font(this, widgetId)
        side = WidgetTheme.side(this, widgetId)
        WidgetTheme.extras(this, widgetId).let {
            accentPick = it.accent
            okColor = it.okColor
            shape = it.shape
            show = it.show
            border = it.border
            borderColor = it.borderColor
            bits = it.bits
            tap = it.tap
        }
        WidgetTheme.radius(this, widgetId).let {
            if (it >= 0) {
                radius = it
                radiusChosen = true
            }
        }
        // The see-through look of the first versions is now dark colours with a lower opacity.
        theme = if (saved == WidgetTheme.CLEAR) WidgetTheme.DARK else saved
        shownState = if (WidgetState.current() == WidgetState.OFF) WidgetState.OFF else WidgetState.ON

        // The wallpaper of the phone is drawn behind the window (no permission is needed for that), and the
        // window is see-through above the sheet: the widget is previewed on the real home screen.
        window.addFlags(WindowManager.LayoutParams.FLAG_SHOW_WALLPAPER)
        window.setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
        window.statusBarColor = Color.TRANSPARENT
        window.navigationBarColor = Color.TRANSPARENT
        edgeToEdge()

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            // A light shade over the wallpaper so the title and the switch read on any picture.
            background = GradientDrawable(GradientDrawable.Orientation.TOP_BOTTOM, intArrayOf(0x59000000, 0x14000000))
        }
        root.addView(TextView(this).apply {
            text = getString(R.string.widget_cfg_title)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 24f)
            setTypeface(typeface, Typeface.BOLD)
            setTextColor(Color.WHITE)
            setShadowLayer(dp(4).toFloat(), 0f, dp(1).toFloat(), 0x99000000.toInt())
            setPadding(dp(24), dp(20), dp(24), 0)
        })
        // The widget is drawn on this layer, which is cleared at each change.
        stage = FrameLayout(this)
        root.addView(stage, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(230)))
        root.addView(stateRow(), LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT,
        ).apply {
            gravity = Gravity.CENTER_HORIZONTAL
            bottomMargin = dp(18)
        })

        val sheet = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            background = GradientDrawable().apply {
                val r = dp(28).toFloat()
                cornerRadii = floatArrayOf(r, r, r, r, 0f, 0f, 0f, 0f)
                setColor(page)
            }
        }
        column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16), dp(8), dp(16), dp(8))
        }
        fillColumn()

        sheet.addView(ScrollView(this).apply {
            addView(column)
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f)
        })
        val bar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(dp(16), dp(8), dp(16), dp(14))
        }
        bar.addView(barButton(R.string.widget_cfg_cancel, filled = false) { finish() })
        bar.addView(View(this), LinearLayout.LayoutParams(dp(12), 1))
        bar.addView(barButton(R.string.widget_cfg_save, filled = true) { save() })
        sheet.addView(bar)
        root.addView(sheet, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f))

        // The page runs under the status bar (the wallpaper shows there) and the sheet under the navigation bar:
        // the title and the buttons are kept clear of them.
        root.setOnApplyWindowInsetsListener { view, insets ->
            val (top, bottom) = barsOf(insets)
            view.setPadding(0, top, 0, 0)
            sheet.setPadding(0, 0, 0, bottom)
            insets
        }
        setContentView(root)
        markThemes()
        markStates()
        renderPreview()
    }

    /** Draws the page under both bars (as Android 15 does anyway). The top of the screen is the wallpaper, so the
     *  icons of the status bar are light; those of the navigation bar follow the sheet. */
    @Suppress("DEPRECATION")
    private fun edgeToEdge() {
        if (Build.VERSION.SDK_INT >= 30) window.setDecorFitsSystemWindows(false)
        var flags = window.decorView.systemUiVisibility or
            View.SYSTEM_UI_FLAG_LAYOUT_STABLE or
            View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or
            View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
        flags = flags and View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR.inv()
        if (Build.VERSION.SDK_INT >= 26) {
            flags = if (night) flags and View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR.inv() else flags or View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR
        }
        window.decorView.systemUiVisibility = flags
        if (Build.VERSION.SDK_INT >= 29) window.isNavigationBarContrastEnforced = false
    }

    /** The heights of the status bar and of the navigation bar, in pixels. */
    @Suppress("DEPRECATION")
    private fun barsOf(insets: WindowInsets): Pair<Int, Int> {
        if (Build.VERSION.SDK_INT >= 30) {
            val bars = insets.getInsets(WindowInsets.Type.systemBars())
            return Pair(bars.top, bars.bottom)
        }
        return Pair(insets.systemWindowInsetTop, insets.systemWindowInsetBottom)
    }

    private fun sectionLabel(text: Int) = TextView(this).apply {
        this.text = getString(text)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
        setTypeface(typeface, Typeface.BOLD)
        setTextColor(accent)
        setPadding(dp(8), dp(18), 0, dp(8))
    }

    private fun panelBox() = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(dp(6), dp(6), dp(6), dp(6))
        background = GradientDrawable().apply {
            cornerRadius = dp(20).toFloat()
            setColor(panel)
        }
    }

    /** "Disconnected | Connected": a switch on a dark glass over the wallpaper, for the state of the preview. */
    private fun stateRow(): LinearLayout {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(4), dp(4), dp(4), dp(4))
            background = GradientDrawable().apply {
                cornerRadius = dp(22).toFloat()
                setColor(0x73000000)
            }
        }
        for ((value, label) in listOf(WidgetState.OFF to R.string.widget_cfg_off, WidgetState.ON to R.string.widget_cfg_on)) {
            val t = TextView(this).apply {
                text = getString(label)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
                setTypeface(typeface, Typeface.BOLD)
                gravity = Gravity.CENTER
                minWidth = dp(110)
                setPadding(dp(16), dp(9), dp(16), dp(9))
                setOnClickListener {
                    shownState = value
                    markStates()
                    renderPreview()
                }
            }
            row.addView(t)
            stateLabels.add(Pair(t, value))
        }
        return row
    }

    private fun markStates() {
        for ((t, value) in stateLabels) {
            val chosen = value == shownState
            t.setTextColor(if (chosen) 0xFF1B1B1F.toInt() else Color.WHITE)
            t.background = GradientDrawable().apply {
                cornerRadius = dp(18).toFloat()
                setColor(if (chosen) Color.WHITE else Color.TRANSPARENT)
            }
        }
    }

    private fun themeRow(value: Int, title: Int, desc: Int): LinearLayout {
        val r = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(10), dp(8), dp(12), dp(8))
            minimumHeight = dp(54)
            isClickable = true
            setOnClickListener { chooseTheme(value) }
        }
        val radio = RadioButton(this).apply {
            buttonTintList = ColorStateList.valueOf(accent)
            isClickable = false
        }
        r.addView(radio)
        val texts = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(8), 0, 0, 0)
        }
        texts.addView(TextView(this).apply {
            text = getString(title)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
            setTextColor(ink)
        })
        if (desc != 0) {
            texts.addView(TextView(this).apply {
                text = getString(desc)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
                setTextColor(inkSoft)
            })
        }
        r.addView(texts)
        themeRows.add(Pair(radio, value))
        return r
    }

    private fun chooseTheme(value: Int) {
        theme = value
        markThemes()
        renderPreview()
    }

    private fun markThemes() {
        for ((radio, value) in themeRows) radio.isChecked = value == theme
    }

    /**
     * A slider with its value beside it, in a box: [steps] + 1 positions, the value of position `i` being
     * `from + i * step`; [onValue] hears every change (the first call is not one: nothing is sent while the box is built).
     */
    private fun sliderBox(
        from: Int, step: Int, steps: Int, value: Int, unit: String,
        onValue: (Int) -> Unit,
    ): LinearLayout {
        val box = panelBox()
        box.setPadding(dp(12), dp(14), dp(18), dp(14))
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        val shown = TextView(this).apply {
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
            setTypeface(typeface, Typeface.BOLD)
            setTextColor(ink)
            gravity = Gravity.END
            minWidth = dp(56)
            text = "$value$unit"
        }
        row.addView(SeekBar(this).apply {
            max = steps
            progress = ((value - from) / step).coerceIn(0, steps)
            progressTintList = ColorStateList.valueOf(accent)
            thumbTintList = ColorStateList.valueOf(accent)
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
                override fun onProgressChanged(bar: SeekBar?, position: Int, fromUser: Boolean) {
                    val v = from + position * step
                    shown.text = "$v$unit"
                    if (fromUser) onValue(v)
                }

                override fun onStartTrackingTouch(bar: SeekBar?) {}

                override fun onStopTrackingTouch(bar: SeekBar?) {}
            })
        })
        row.addView(shown)
        box.addView(row)
        return box
    }

    /** The sections of the sheet, one after the other (again after a preset changed the values). */
    private fun fillColumn() {
        column.addView(sectionLabel(R.string.widget_cfg_presets))
        column.addView(presetBar())
        column.addView(sectionLabel(R.string.widget_cfg_bg))
        val colours = panelBox()
        val options = listOf(
            Triple(WidgetTheme.AUTO, R.string.widget_theme_auto, R.string.widget_theme_auto_desc),
            Triple(WidgetTheme.LIGHT, R.string.widget_theme_light, 0),
            Triple(WidgetTheme.DARK, R.string.widget_theme_dark, 0),
        )
        for ((value, title, desc) in options) colours.addView(themeRow(value, title, desc))
        column.addView(colours)
        column.addView(sectionLabel(R.string.widget_cfg_opacity))
        column.addView(opacityBox())
        column.addView(sectionLabel(R.string.widget_cfg_radius))
        column.addView(radiusBox())
        column.addView(sectionLabel(R.string.widget_cfg_height))
        column.addView(heightBox())
        column.addView(sectionLabel(R.string.widget_cfg_border))
        column.addView(borderBox())
        column.addView(sectionLabel(R.string.widget_cfg_border_color))
        column.addView(choiceBox(
            listOf(WidgetTheme.BORDER_ACCENT to R.string.widget_border_accent, WidgetTheme.BORDER_NEUTRAL to R.string.widget_border_neutral),
            { borderColor },
        ) { borderColor = it })
        column.addView(sectionLabel(R.string.widget_cfg_accent))
        column.addView(accentBox())
        column.addView(sectionLabel(R.string.widget_cfg_ok))
        column.addView(choiceBox(
            listOf(WidgetTheme.OK_GREEN to R.string.widget_ok_green, WidgetTheme.OK_ACCENT to R.string.widget_ok_accent),
            { okColor },
        ) { okColor = it })
        column.addView(sectionLabel(R.string.widget_cfg_shape))
        column.addView(choiceBox(
            listOf(
                WidgetTheme.SHAPE_CIRCLE to R.string.widget_shape_circle,
                WidgetTheme.SHAPE_ROUNDED to R.string.widget_shape_rounded,
                WidgetTheme.SHAPE_SQUARE to R.string.widget_shape_square,
            ),
            { shape },
        ) { shape = it })
        // A view is resized from a widget on Android 12+ only: older phones keep the size of the button.
        if (WidgetTheme.canSizeButton) {
            column.addView(sectionLabel(R.string.widget_cfg_button))
            column.addView(buttonBox())
        }
        column.addView(sectionLabel(R.string.widget_cfg_side))
        column.addView(choiceBox(
            listOf(WidgetTheme.LEFT to R.string.widget_side_left, WidgetTheme.RIGHT to R.string.widget_side_right),
            { side },
        ) { side = it })
        column.addView(sectionLabel(R.string.widget_cfg_font))
        column.addView(fontBox())
        column.addView(sectionLabel(R.string.widget_cfg_show))
        column.addView(showBox())
        column.addView(sectionLabel(R.string.widget_cfg_unit))
        column.addView(choiceBox(
            listOf(0 to R.string.widget_unit_bytes, 1 to R.string.widget_unit_bits),
            { if (bits) 1 else 0 },
        ) { bits = it == 1 })
        column.addView(sectionLabel(R.string.widget_cfg_tap))
        column.addView(choiceBox(
            listOf(WidgetTheme.TAP_OPEN to R.string.widget_tap_open, WidgetTheme.TAP_TOGGLE to R.string.widget_tap_toggle),
            { tap },
        ) { tap = it })
    }

    /** A preset sets the whole look at once (not the side of the button, the unit or the tap): the colours, the corners,
     *  the border, the shape, the sizes and what is shown. */
    private class Preset(val name: Int, val action: (WidgetConfigActivity) -> Unit)

    private val presets = listOf(
        Preset(R.string.widget_preset_default) {
            it.setLook(WidgetTheme.AUTO, 100, -1, 100, 100, 100, 0, WidgetTheme.OK_GREEN, WidgetTheme.SHAPE_CIRCLE, WidgetTheme.SHOW_ALL, 0, WidgetTheme.BORDER_ACCENT)
        },
        Preset(R.string.widget_preset_minimal) {
            it.setLook(
                WidgetTheme.AUTO, 100, 12, 100, 90, 100, 0, WidgetTheme.OK_ACCENT, WidgetTheme.SHAPE_ROUNDED,
                WidgetTheme.SHOW_SERVER or WidgetTheme.SHOW_SPEED, 0, WidgetTheme.BORDER_ACCENT,
            )
        },
        Preset(R.string.widget_preset_glass) {
            it.setLook(WidgetTheme.DARK, 40, 32, 100, 100, 100, 0, WidgetTheme.OK_GREEN, WidgetTheme.SHAPE_CIRCLE, WidgetTheme.SHOW_ALL, 1, WidgetTheme.BORDER_NEUTRAL)
        },
        Preset(R.string.widget_preset_bold) {
            it.setLook(WidgetTheme.AUTO, 100, 36, 100, 120, 110, 1, WidgetTheme.OK_ACCENT, WidgetTheme.SHAPE_CIRCLE, WidgetTheme.SHOW_ALL, 0, WidgetTheme.BORDER_ACCENT)
        },
        Preset(R.string.widget_preset_night) {
            it.setLook(WidgetTheme.DARK, 90, 20, 100, 100, 100, 2, WidgetTheme.OK_ACCENT, WidgetTheme.SHAPE_ROUNDED, WidgetTheme.SHOW_ALL, 1, WidgetTheme.BORDER_ACCENT)
        },
        Preset(R.string.widget_preset_sharp) {
            it.setLook(WidgetTheme.AUTO, 100, 0, 100, 100, 100, 3, WidgetTheme.OK_GREEN, WidgetTheme.SHAPE_SQUARE, WidgetTheme.SHOW_ALL, 2, WidgetTheme.BORDER_ACCENT)
        },
    )

    /** [corners] -1: the corners the widget was drawn with. */
    private fun setLook(
        theme: Int, opacity: Int, corners: Int, height: Int, button: Int, font: Int, accent: Int, ok: Int,
        shape: Int, show: Int, border: Int, borderColor: Int,
    ) {
        this.theme = theme
        this.opacity = opacity
        radiusChosen = corners >= 0
        if (corners >= 0) radius = corners
        this.height = height
        this.button = button
        this.font = font
        accentPick = accent
        okColor = ok
        this.shape = shape
        this.show = show
        this.border = border
        this.borderColor = borderColor
    }

    private fun applyPreset(p: Preset) {
        p.action(this)
        // The controls are built from the values: build them again, where the user was.
        column.removeAllViews()
        themeRows.clear()
        fillColumn()
        markThemes()
        renderPreview()
    }

    /** The presets as chips in a row that scrolls. */
    private fun presetBar() = HorizontalScrollView(this).apply {
        isHorizontalScrollBarEnabled = false
        val row = LinearLayout(this@WidgetConfigActivity).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(dp(4), 0, dp(4), 0)
        }
        for (p in presets) {
            row.addView(TextView(this@WidgetConfigActivity).apply {
                text = getString(p.name)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
                setTypeface(typeface, Typeface.BOLD)
                setTextColor(accent)
                setPadding(dp(16), dp(9), dp(16), dp(9))
                background = GradientDrawable().apply {
                    cornerRadius = dp(20).toFloat()
                    setStroke(dp(1), accent)
                }
                isClickable = true
                setOnClickListener { applyPreset(p) }
                layoutParams = LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT,
                ).apply { marginEnd = dp(8) }
            })
        }
        addView(row)
    }

    /** Rows with a radio button each, one chosen: [current] tells which is, [onPick] hears a change. */
    private fun choiceBox(options: List<Pair<Int, Int>>, current: () -> Int, onPick: (Int) -> Unit): LinearLayout {
        val box = panelBox()
        val rows = ArrayList<Pair<RadioButton, Int>>()
        fun mark() {
            for ((radio, value) in rows) radio.isChecked = value == current()
        }
        for ((value, title) in options) {
            val row = LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                setPadding(dp(10), dp(8), dp(12), dp(8))
                minimumHeight = dp(48)
                isClickable = true
                setOnClickListener {
                    onPick(value)
                    mark()
                    renderPreview()
                }
            }
            val radio = RadioButton(this).apply {
                buttonTintList = ColorStateList.valueOf(accent)
                isClickable = false
            }
            row.addView(radio)
            row.addView(TextView(this).apply {
                text = getString(title)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
                setTextColor(ink)
                setPadding(dp(8), 0, 0, 0)
            })
            box.addView(row)
            rows.add(Pair(radio, value))
        }
        mark()
        return box
    }

    /** The accent colours as discs: the first is the look own colour (the wallpaper, or Kumo teal). */
    private fun accentBox(): LinearLayout {
        val box = panelBox()
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            setPadding(dp(4), dp(8), dp(4), dp(8))
        }
        val discs = ArrayList<Pair<View, Int>>()
        fun mark() {
            for ((disc, value) in discs) {
                (disc.background as GradientDrawable).apply {
                    if (value == accentPick) setStroke(dp(3), ink) else setStroke(dp(1), inkSoft)
                }
            }
        }
        for (value in 0..WidgetColors.ACCENT_COUNT) {
            val disc = View(this).apply {
                background = GradientDrawable().apply {
                    setShape(GradientDrawable.OVAL)
                    setColor(if (value == 0) WidgetColors.light(this@WidgetConfigActivity).ring else WidgetColors.swatch(value))
                }
                isClickable = true
                setOnClickListener {
                    accentPick = value
                    mark()
                    renderPreview()
                }
                layoutParams = LinearLayout.LayoutParams(dp(40), dp(40)).apply {
                    marginStart = dp(6)
                    marginEnd = dp(6)
                }
            }
            row.addView(disc)
            discs.add(Pair(disc, value))
        }
        mark()
        box.addView(row)
        return box
    }

    /** What the widget shows: a switch for each of the server, the speeds, the delay, the data and the time. */
    private fun showBox(): LinearLayout {
        val box = panelBox()
        val items = listOf(
            WidgetTheme.SHOW_SERVER to R.string.widget_show_server,
            WidgetTheme.SHOW_SPEED to R.string.widget_show_speed,
            WidgetTheme.SHOW_PING to R.string.widget_show_ping,
            WidgetTheme.SHOW_TOTAL to R.string.widget_show_total,
            WidgetTheme.SHOW_TIME to R.string.widget_show_time,
        )
        for ((flag, title) in items) {
            box.addView(CheckBox(this).apply {
                text = getString(title)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
                setTextColor(ink)
                buttonTintList = ColorStateList.valueOf(accent)
                minimumHeight = dp(48)
                setPadding(dp(10), dp(4), dp(12), dp(4))
                isChecked = (show and flag) != 0
                setOnCheckedChangeListener { _, on ->
                    show = if (on) show or flag else show and flag.inv()
                    renderPreview()
                }
            })
        }
        return box
    }

    /** The slider of the border: 0 (none) to 3 dp. */
    private fun borderBox() = sliderBox(0, 1, WidgetTheme.MAX_BORDER, border, " dp") {
        border = it
        renderPreview()
    }
    /** The slider of the opacity: eleven steps, 0 to 100 percent. */
    private fun opacityBox() = sliderBox(0, 10, 10, opacity, "%") {
        opacity = it
        renderPreview()
    }

    /** The slider of the corners: eleven steps, 0 to 40 dp. */
    private fun radiusBox() = sliderBox(0, 4, 10, radius, " dp") {
        radius = it
        radiusChosen = true
        renderPreview()
    }

    /** The slider of the height of the card in its room: six steps, 50 to 100 percent. */
    private fun heightBox() = sliderBox(WidgetTheme.MIN_HEIGHT, 10, 5, height, "%") {
        height = it
        renderPreview()
    }

    /** The slider of the power button: eight steps, 70 to 140 percent. */
    private fun buttonBox() = sliderBox(WidgetTheme.MIN_BUTTON, 10, 7, button, "%") {
        button = it
        renderPreview()
    }

    /** The slider of the texts: nine steps, 70 to 150 percent. */
    private fun fontBox() = sliderBox(WidgetTheme.MIN_FONT, 10, 8, font, "%") {
        font = it
        renderPreview()
    }

    private fun barButton(text: Int, filled: Boolean, onClick: () -> Unit) = TextView(this).apply {
        this.text = getString(text)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
        setTypeface(typeface, Typeface.BOLD)
        setTextColor(if (filled) onAccent else accent)
        gravity = Gravity.CENTER
        setPadding(0, dp(14), 0, dp(14))
        background = GradientDrawable().apply {
            cornerRadius = dp(26).toFloat()
            if (filled) setColor(accent) else {
                setColor(Color.TRANSPARENT)
                setStroke(dp(1), accent)
            }
        }
        setOnClickListener { onClick() }
        layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
    }

    /** The size the launcher gave the widget, in dp (what it was placed at), kept inside the preview. */
    private fun widgetSizeDp(): Pair<Int, Int> {
        val manager = AppWidgetManager.getInstance(this)
        val options = manager.getAppWidgetOptions(widgetId)
        val density = resources.displayMetrics.density
        val info = manager.getAppWidgetInfo(widgetId)
        var w = options?.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH) ?: 0
        var h = options?.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT) ?: 0
        if (w <= 0 && info != null) w = (info.minWidth / density).toInt()
        if (h <= 0 && info != null) h = (info.minHeight / density).toInt()
        val screenWidth = (resources.displayMetrics.widthPixels / density).toInt()
        return Pair(w.coerceIn(40, screenWidth - 32), h.coerceIn(40, 210))
    }

    /** Draws the real widget in the look being set, at its real size, on the wallpaper. */
    private fun renderPreview() {
        stage.removeAllViews()
        try {
            val views = KumoWidget.preview(
                this, widgetId,
                WidgetLook(theme, opacity, shownState, if (radiusChosen) radius else -1, height, button, font, side,
                    accentPick, okColor, shape, show, border, borderColor, bits, tap,
                ),
            ) ?: return
            val (w, h) = widgetSizeDp()
            val widget = views.apply(this, stage)
            stage.addView(widget, FrameLayout.LayoutParams(dp(w), dp(h), Gravity.CENTER))
            // A tap on the preview must not connect or disconnect for real.
            stage.addView(View(this).apply { isClickable = true })
        } catch (_: Exception) {
            // The preview is only a help: the settings still work without it.
        }
    }

    private fun save() {
        WidgetTheme.save(this, widgetId, theme)
        WidgetTheme.saveOpacity(this, widgetId, opacity)
        WidgetTheme.saveShape(this, widgetId, if (radiusChosen) radius else null, height)
        WidgetTheme.saveSizes(this, widgetId, button, font)
        WidgetTheme.saveSide(this, widgetId, side)
        WidgetTheme.saveExtras(this, widgetId, WidgetTheme.Extras(accentPick, okColor, shape, show, border, borderColor, bits, tap))
        KumoWidget.refreshOne(this, widgetId)
        setResult(RESULT_OK, Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widgetId))
        finish()
    }
}
