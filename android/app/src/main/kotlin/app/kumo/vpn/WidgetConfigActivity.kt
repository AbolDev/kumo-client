package app.kumo.vpn

import android.app.Activity
import android.appwidget.AppWidgetManager
import android.content.Intent
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView

/**
 * Opens when a widget is placed (and again from its long-press menu): colour, shape, opacity and
 * text size are picked here, with a preview. The choices are kept per widget.
 */
class WidgetConfigActivity : Activity() {
    private var widgetId = AppWidgetManager.INVALID_APPWIDGET_ID
    private lateinit var style: WidgetStyle
    private lateinit var preview: TextView
    private var color = 0
    private var shape = 1
    private var opacity = 3
    private var textSize = 1
    private var content = 2

    private fun dp(v: Int) = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v.toFloat(), resources.displayMetrics).toInt()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setResult(RESULT_CANCELED)
        widgetId = intent?.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, AppWidgetManager.INVALID_APPWIDGET_ID)
            ?: AppWidgetManager.INVALID_APPWIDGET_ID
        if (widgetId == AppWidgetManager.INVALID_APPWIDGET_ID) {
            finish()
            return
        }
        style = WidgetStyle.load(this, widgetId)
        color = style.color
        shape = style.shape
        opacity = style.opacity
        textSize = style.textSize
        content = style.content
        val isStats = AppWidgetManager.getInstance(this).getAppWidgetInfo(widgetId)
            ?.provider?.className == VpnWidgetStats::class.java.name

        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(20), dp(20), dp(24))
        }
        column.addView(TextView(this).apply {
            text = getString(R.string.widget_cfg_title)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 22f)
            setTypeface(typeface, android.graphics.Typeface.BOLD)
        })

        preview = TextView(this).apply {
            text = "Kumo"
            gravity = Gravity.CENTER
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 18f)
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(72)).apply {
                topMargin = dp(16)
                bottomMargin = dp(8)
            }
        }
        column.addView(preview)

        column.addView(label(R.string.widget_cfg_color))
        column.addView(colorRow())
        column.addView(label(R.string.widget_cfg_shape))
        column.addView(choices(listOf("▢", "▭", "⬭"), { shape }) { shape = it })
        column.addView(label(R.string.widget_cfg_opacity))
        column.addView(choices(WidgetStyle.OPACITY.map { "$it%" }, { opacity }) { opacity = it })
        column.addView(label(R.string.widget_cfg_size))
        column.addView(choices(listOf("S", "M", "L"), { textSize }) { textSize = it })
        if (isStats) {
            column.addView(label(R.string.widget_cfg_content))
            column.addView(
                choices(
                    listOf(getString(R.string.widget_cfg_speed), getString(R.string.widget_cfg_total), getString(R.string.widget_cfg_both)),
                    { content },
                ) { content = it },
            )
        }
        column.addView(Button(this).apply {
            text = getString(R.string.widget_cfg_done)
            setOnClickListener { save() }
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
                topMargin = dp(24)
            }
        })
        setContentView(ScrollView(this).apply { addView(column) })
        redraw()
    }

    private fun label(res: Int) = TextView(this).apply {
        text = getString(res)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
        setPadding(0, dp(16), 0, dp(6))
    }

    /** A row of buttons of which one is marked; [pick] is called with the index that was tapped. */
    private fun choices(labels: List<String>, current: () -> Int, pick: (Int) -> Unit): LinearLayout {
        val row = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        val buttons = ArrayList<Button>()
        fun mark() {
            buttons.forEachIndexed { i, b -> b.alpha = if (i == current()) 1f else 0.45f }
        }
        labels.forEachIndexed { i, caption ->
            val b = Button(this).apply {
                text = caption
                isAllCaps = false
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
                setOnClickListener {
                    pick(i)
                    mark()
                    redraw()
                }
            }
            buttons.add(b)
            row.addView(b)
        }
        mark()
        return row
    }

    /** "Auto" (follows the connection state) and the palette, as round swatches. */
    private fun colorRow(): LinearLayout {
        val wrap = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        val swatches = ArrayList<Pair<View, Int>>()
        fun mark() {
            swatches.forEach { (v, c) ->
                val ring = if (c == color) 3 else 0
                (v.background as GradientDrawable).setStroke(dp(ring), 0xFF000000.toInt())
            }
        }
        fun swatch(c: Int, caption: String?): View {
            val v = TextView(this).apply {
                gravity = Gravity.CENTER
                text = caption ?: ""
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
                setTextColor(Color.WHITE)
                background = GradientDrawable().apply {
                    shape = GradientDrawable.OVAL
                    setColor(if (c == 0) 0xFF0E9F8E.toInt() else c)
                }
                layoutParams = LinearLayout.LayoutParams(dp(40), dp(40)).apply { setMargins(dp(4), dp(4), dp(4), dp(4)) }
                setOnClickListener {
                    color = c
                    mark()
                    redraw()
                }
            }
            swatches.add(Pair(v, c))
            return v
        }
        val rowOne = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        val rowTwo = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        rowOne.addView(swatch(0, "A"))
        WidgetStyle.PALETTE.forEachIndexed { i, c ->
            (if (i < 6) rowOne else rowTwo).addView(swatch(c, null))
        }
        wrap.addView(rowOne)
        wrap.addView(rowTwo)
        wrap.addView(TextView(this).apply {
            text = "A = " + getString(R.string.widget_cfg_auto)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
            alpha = 0.6f
        })
        mark()
        return wrap
    }

    private fun current() = WidgetStyle(color, shape, opacity, textSize, content)

    private fun redraw() {
        val s = current()
        val radius = when (shape) {
            0 -> dp(6).toFloat()
            1 -> dp(20).toFloat()
            else -> dp(200).toFloat()
        }
        preview.background = GradientDrawable().apply {
            cornerRadius = radius
            setColor(s.background(WidgetState.ON))
            alpha = s.alpha
        }
        preview.setTextColor(s.textColor(WidgetState.ON))
        preview.setTextSize(TypedValue.COMPLEX_UNIT_SP, 18f * s.scale)
    }

    private fun save() {
        WidgetStyle.save(this, widgetId, current())
        KumoWidget.refreshOne(this, widgetId)
        setResult(RESULT_OK, Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widgetId))
        finish()
    }
}
