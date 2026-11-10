package app.kumo.vpn

import android.app.Activity
import android.appwidget.AppWidgetManager
import android.content.Intent
import android.content.res.Configuration
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.util.TypedValue
import android.view.Gravity
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView

/**
 * Opens when a widget is placed (on Android 12+ only if the user asks, from its long-press menu): one
 * choice, the look. Follow the phone, light, dark or see-through; each is shown as a small sample.
 */
class WidgetConfigActivity : Activity() {
    private var widgetId = AppWidgetManager.INVALID_APPWIDGET_ID
    private var theme = WidgetTheme.AUTO
    private val rows = ArrayList<Pair<LinearLayout, Int>>()

    private fun dp(v: Int) = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v.toFloat(), resources.displayMetrics).toInt()

    private val night: Boolean
        get() = (resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setResult(RESULT_CANCELED)
        widgetId = intent?.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, AppWidgetManager.INVALID_APPWIDGET_ID)
            ?: AppWidgetManager.INVALID_APPWIDGET_ID
        if (widgetId == AppWidgetManager.INVALID_APPWIDGET_ID) {
            finish()
            return
        }
        theme = WidgetTheme.load(this, widgetId)

        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(20), dp(20), dp(16))
        }
        column.addView(TextView(this).apply {
            text = getString(R.string.widget_cfg_title)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 20f)
            setTypeface(typeface, Typeface.BOLD)
            setPadding(0, 0, 0, dp(12))
        })
        val options = listOf(
            Triple(WidgetTheme.AUTO, R.string.widget_theme_auto, R.string.widget_theme_auto_desc),
            Triple(WidgetTheme.LIGHT, R.string.widget_theme_light, 0),
            Triple(WidgetTheme.DARK, R.string.widget_theme_dark, 0),
            Triple(WidgetTheme.CLEAR, R.string.widget_theme_clear, R.string.widget_theme_clear_desc),
        )
        for ((value, title, desc) in options) column.addView(row(value, title, desc))
        column.addView(Button(this).apply {
            text = getString(R.string.widget_cfg_done)
            isAllCaps = false
            setOnClickListener { save() }
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
                topMargin = dp(12)
            }
        })
        setContentView(ScrollView(this).apply { addView(column) })
        mark()
    }

    /** A sample of a look: the card with its power button, as the widget would show it disconnected. */
    private fun sample(value: Int): FrameLayout {
        val colors = when (value) {
            WidgetTheme.LIGHT -> WidgetColors.light(this)
            WidgetTheme.DARK, WidgetTheme.CLEAR -> WidgetColors.dark(this)
            else -> if (night) WidgetColors.dark(this) else WidgetColors.light(this)
        }
        val card = FrameLayout(this).apply {
            background = GradientDrawable().apply {
                cornerRadius = dp(14).toFloat()
                setColor(if (value == WidgetTheme.CLEAR) 0x73000000 else colors.offBg)
                setStroke(dp(1), 0x22000000)
            }
            layoutParams = LinearLayout.LayoutParams(dp(56), dp(40))
        }
        card.addView(android.view.View(this).apply {
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(colors.offBtn)
                setStroke(dp(2), colors.ring)
            }
            layoutParams = FrameLayout.LayoutParams(dp(24), dp(24), Gravity.CENTER)
        })
        return card
    }

    private fun row(value: Int, title: Int, desc: Int): LinearLayout {
        val r = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(10), dp(10), dp(10), dp(10))
            minimumHeight = dp(56)
            isClickable = true
            setOnClickListener {
                theme = value
                mark()
            }
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
                bottomMargin = dp(6)
            }
        }
        r.addView(sample(value))
        val texts = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(14), 0, 0, 0)
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }
        texts.addView(TextView(this).apply {
            text = getString(title)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
        })
        if (desc != 0) {
            texts.addView(TextView(this).apply {
                text = getString(desc)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
                alpha = 0.7f
            })
        }
        r.addView(texts)
        r.addView(TextView(this).apply {
            tag = "check"
            text = "✓"
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 18f)
            setPadding(dp(8), 0, 0, 0)
        })
        rows.add(Pair(r, value))
        return r
    }

    /** The chosen row is tinted and has its check mark. */
    private fun mark() {
        val accent = WidgetColors.light(this).ring
        for ((r, value) in rows) {
            val chosen = value == theme
            r.background = GradientDrawable().apply {
                cornerRadius = dp(16).toFloat()
                setColor(if (chosen) (accent and 0x00FFFFFF) or 0x22000000 else 0)
                setStroke(dp(1), if (chosen) accent else 0x1F000000)
            }
            r.findViewWithTag<TextView>("check").alpha = if (chosen) 1f else 0f
        }
    }

    private fun save() {
        WidgetTheme.save(this, widgetId, theme)
        KumoWidget.refreshOne(this, widgetId)
        setResult(RESULT_OK, Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widgetId))
        finish()
    }
}
