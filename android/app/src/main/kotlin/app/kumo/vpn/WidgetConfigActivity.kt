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
import android.widget.FrameLayout
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

    /** The state the preview shows (the VPN's own now, or what the user picked). */
    private var shownState = WidgetState.OFF

    private lateinit var stage: FrameLayout
    private lateinit var percent: TextView
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
        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16), dp(8), dp(16), dp(8))
        }
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

    /** The slider of the opacity with its value beside it. */
    private fun opacityBox(): LinearLayout {
        val box = panelBox()
        box.setPadding(dp(12), dp(14), dp(18), dp(14))
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        // Eleven steps, 0 to 100 percent.
        row.addView(SeekBar(this).apply {
            max = 10
            progress = opacity / 10
            progressTintList = ColorStateList.valueOf(accent)
            thumbTintList = ColorStateList.valueOf(accent)
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
                override fun onProgressChanged(bar: SeekBar?, value: Int, fromUser: Boolean) {
                    opacity = value * 10
                    percent.text = "$opacity%"
                    renderPreview()
                }

                override fun onStartTrackingTouch(bar: SeekBar?) {}

                override fun onStopTrackingTouch(bar: SeekBar?) {}
            })
        })
        percent = TextView(this).apply {
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
            setTypeface(typeface, Typeface.BOLD)
            setTextColor(ink)
            gravity = Gravity.END
            minWidth = dp(48)
            text = "$opacity%"
        }
        row.addView(percent)
        box.addView(row)
        return box
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
            val views = KumoWidget.preview(this, widgetId, WidgetLook(theme, opacity, shownState)) ?: return
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
        KumoWidget.refreshOne(this, widgetId)
        setResult(RESULT_OK, Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widgetId))
        finish()
    }
}
