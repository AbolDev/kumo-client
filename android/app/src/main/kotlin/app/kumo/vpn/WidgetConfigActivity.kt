package app.kumo.vpn

import android.app.Activity
import android.app.WallpaperManager
import android.appwidget.AppWidgetManager
import android.content.Intent
import android.content.res.ColorStateList
import android.content.res.Configuration
import android.graphics.Typeface
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.util.TypedValue
import android.view.Gravity
import android.graphics.Outline
import android.view.View
import android.view.ViewOutlineProvider
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.RadioButton
import android.widget.ScrollView
import android.widget.SeekBar
import android.widget.TextView

/**
 * Opens when a widget is placed (on Android 12+ only if the user asks, from its long-press menu): the look of that
 * widget. A preview of the real widget at its real size sits on top (on the wallpaper when the phone lets the app
 * read it), under it the colour of the background (follow the phone, light, dark) and how opaque it is. The preview
 * follows every change; nothing is kept until Save.
 */
class WidgetConfigActivity : Activity() {
    private var widgetId = AppWidgetManager.INVALID_APPWIDGET_ID
    private var theme = WidgetTheme.AUTO
    private var opacity = 100

    /** The state the preview shows (the VPN's own now, or what the user picked). */
    private var shownState = WidgetState.OFF

    private lateinit var preview: FrameLayout
    private lateinit var stage: FrameLayout
    private lateinit var percent: TextView
    private val themeRows = ArrayList<Pair<RadioButton, Int>>()
    private val stateLabels = ArrayList<Pair<TextView, Int>>()

    private fun dp(v: Int) = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v.toFloat(), resources.displayMetrics).toInt()

    private val night: Boolean
        get() = (resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES
    private val ink get() = if (night) 0xFFFFFFFF.toInt() else 0xFF1B1B1F.toInt()
    private val inkSoft get() = if (night) 0xB3FFFFFF.toInt() else 0x991B1B1F.toInt()
    private val page get() = if (night) 0xFF0B0B0E.toInt() else 0xFFF2F2F5.toInt()
    private val panel get() = if (night) 0xFF1C1C21.toInt() else 0xFFFFFFFF.toInt()
    private val accent get() = WidgetColors.light(this).ring

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
        window.setBackgroundDrawable(ColorDrawable(page))
        window.statusBarColor = page
        if (night) lightStatusIcons()

        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(24), dp(20), dp(16))
        }
        column.addView(TextView(this).apply {
            text = getString(R.string.widget_cfg_title)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 24f)
            setTypeface(typeface, Typeface.BOLD)
            setTextColor(ink)
            setPadding(dp(4), 0, 0, dp(14))
        })
        preview = FrameLayout(this).apply {
            clipToOutline = true
            outlineProvider = object : ViewOutlineProvider() {
                override fun getOutline(view: View, outline: Outline) {
                    outline.setRoundRect(0, 0, view.width, view.height, dp(20).toFloat())
                }
            }
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(240))
        }
        preview.addView(
            ImageView(this).apply {
                scaleType = ImageView.ScaleType.CENTER_CROP
                setImageDrawable(backdrop())
            },
            FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT),
        )
        // The widget is drawn on this layer, which is cleared at each change; the backdrop under it stays.
        stage = FrameLayout(this)
        preview.addView(stage, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
        column.addView(preview)
        column.addView(stateRow())

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

        val bar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(dp(20), dp(8), dp(20), dp(12))
        }
        bar.addView(barButton(R.string.widget_cfg_cancel) { finish() })
        bar.addView(barButton(R.string.widget_cfg_save) { save() })

        val root = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        root.addView(ScrollView(this).apply {
            addView(column)
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f)
        })
        root.addView(bar)
        setContentView(root)
        markThemes()
        markStates()
        renderPreview()
    }

    /** The theme of the window is a light one: in the dark the icons of the status bar must be light. */
    @Suppress("DEPRECATION")
    private fun lightStatusIcons() {
        val flags = window.decorView.systemUiVisibility
        window.decorView.systemUiVisibility = flags and View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR.inv()
    }

    /** What the widget is drawn on in the preview: the wallpaper when the app may read it, else a plain gradient. */
    private fun backdrop(): android.graphics.drawable.Drawable {
        val wall = try {
            WallpaperManager.getInstance(this).drawable
        } catch (_: Throwable) {
            null
        }
        if (wall != null) return wall
        return GradientDrawable(GradientDrawable.Orientation.TL_BR, intArrayOf(0xFF16233F.toInt(), 0xFF0F5C6B.toInt(), 0xFF2B1D4A.toInt())).apply {
            cornerRadius = dp(20).toFloat()
        }
    }

    private fun sectionLabel(text: Int) = TextView(this).apply {
        this.text = getString(text)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
        setTextColor(inkSoft)
        setPadding(dp(8), dp(18), 0, dp(8))
    }

    private fun panelBox() = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(dp(8), dp(6), dp(8), dp(6))
        background = GradientDrawable().apply {
            cornerRadius = dp(22).toFloat()
            setColor(panel)
        }
    }

    /** "Preview as: Disconnected | Connected": the widget looks different in the two states. */
    private fun stateRow(): LinearLayout {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(8), dp(10), 0, 0)
        }
        row.addView(TextView(this).apply {
            text = getString(R.string.widget_cfg_state)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            setTextColor(inkSoft)
        })
        for ((value, label) in listOf(WidgetState.OFF to R.string.widget_cfg_off, WidgetState.ON to R.string.widget_cfg_on)) {
            val t = TextView(this).apply {
                text = getString(label)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
                setPadding(dp(14), dp(8), dp(14), dp(8))
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
            t.setTextColor(if (chosen) 0xFFFFFFFF.toInt() else ink)
            t.background = GradientDrawable().apply {
                cornerRadius = dp(18).toFloat()
                setColor(if (chosen) accent else 0)
            }
        }
    }

    private fun themeRow(value: Int, title: Int, desc: Int): LinearLayout {
        val r = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(12), dp(8), dp(12), dp(8))
            minimumHeight = dp(56)
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
            setPadding(dp(12), 0, 0, 0)
        }
        texts.addView(TextView(this).apply {
            text = getString(title)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 17f)
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

    private fun opacityBox(): LinearLayout {
        val box = panelBox()
        box.setPadding(dp(18), dp(14), dp(18), dp(14))
        val head = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        head.addView(TextView(this).apply {
            text = getString(R.string.widget_cfg_opacity)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
            setTextColor(ink)
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        })
        percent = TextView(this).apply {
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
            setTextColor(inkSoft)
            text = "$opacity%"
        }
        head.addView(percent)
        box.addView(head)
        // Eleven steps, 0 to 100 percent: the dots of the usual slider of the phone.
        box.addView(SeekBar(this).apply {
            max = 10
            progress = opacity / 10
            progressTintList = ColorStateList.valueOf(accent)
            thumbTintList = ColorStateList.valueOf(accent)
            setPadding(dp(4), dp(10), dp(4), dp(4))
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
        return box
    }

    private fun barButton(text: Int, onClick: () -> Unit) = TextView(this).apply {
        this.text = getString(text)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 18f)
        setTypeface(typeface, Typeface.BOLD)
        setTextColor(ink)
        gravity = Gravity.CENTER
        setPadding(0, dp(14), 0, dp(14))
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
        return Pair(w.coerceIn(40, screenWidth - 64), h.coerceIn(40, 220))
    }

    /** Draws the real widget in the look being set, at its real size, on the backdrop. */
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
