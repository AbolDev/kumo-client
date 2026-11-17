package app.kumo.vpn

import android.app.Activity
import android.app.Dialog
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Shader
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.GradientDrawable
import android.text.Editable
import android.text.InputFilter
import android.text.InputType
import android.text.TextWatcher
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.Window
import android.view.WindowManager
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.SeekBar
import android.widget.TextView

/** The colours the picker is drawn with, taken from the page it opens over (so that it is dark when the page is). */
class PickerTheme(val surface: Int, val ink: Int, val inkSoft: Int, val accent: Int, val onAccent: Int, val chip: Int)

/**
 * A colour picker in two tabs: swatches (a grid of colours and greys) and a spectrum (the hue across, the saturation down,
 * and a slider for how bright). Under them the colour as a hex code and as red, green and blue, the colours used last, and
 * the buttons. [start] is the colour now (0: automatic); [onPick] hears the colour chosen, or 0 for "automatic".
 */
class ColourPickerDialog(
    private val activity: Activity,
    private val theme: PickerTheme,
    private val start: Int,
    private val onPick: (Int) -> Unit,
) {
    private var hue = 0f
    private var sat = 0f
    private var value = 1f

    /** Whether the user chose a colour here (else Done keeps the colour it was opened with). */
    private var touched = false
    private val tmp = FloatArray(3)

    private fun dp(v: Int) = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v.toFloat(), activity.resources.displayMetrics).toInt()

    private fun rgb() = Color.HSVToColor(floatArrayOf(hue, sat, value)) or 0xFF000000.toInt()

    private fun prefs() = activity.getSharedPreferences("widgets", Context.MODE_PRIVATE)

    private fun recent(): List<Int> =
        (prefs().getString("recent_colours", "") ?: "").split(',').mapNotNull { it.toIntOrNull(16)?.or(0xFF000000.toInt()) }.take(6)

    private fun remember(colour: Int) {
        val list = listOf(colour and 0xFFFFFF) + recent().map { it and 0xFFFFFF }.filter { it != (colour and 0xFFFFFF) }
        prefs().edit().putString("recent_colours", list.take(6).joinToString(",") { String.format("%06X", it) }).apply()
    }

    /** A cell of a row that spreads its width: the view in it keeps a size of its own, so that a disc is a disc. */
    private fun cell(inner: View, size: Int, height: Int): FrameLayout = FrameLayout(activity).apply {
        addView(inner, FrameLayout.LayoutParams(dp(size), dp(size), Gravity.CENTER))
        layoutParams = LinearLayout.LayoutParams(0, dp(height), 1f)
    }

    private fun discBackground(colour: Int, outline: Boolean) = GradientDrawable().apply {
        setShape(GradientDrawable.OVAL)
        if (colour == 0) {
            setColor(Color.TRANSPARENT)
            setStroke(dp(1), theme.inkSoft)
        } else {
            setColor(colour)
            setStroke(dp(1), if (outline) theme.ink else theme.inkSoft)
        }
    }

    fun show() {
        val dialog = Dialog(activity)
        dialog.requestWindowFeature(Window.FEATURE_NO_TITLE)

        val root = LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(18), dp(16), dp(18), dp(8))
            background = GradientDrawable().apply {
                cornerRadius = dp(28).toFloat()
                setColor(theme.surface)
            }
        }

        if (start != 0) {
            Color.colorToHSV(start, tmp)
            hue = tmp[0]
            sat = tmp[1]
            value = tmp[2]
        }

        // The views that show the colour: each is told when it changes.
        lateinit var grid: SwatchGrid
        lateinit var spectrum: SpectrumView
        lateinit var slider: SeekBar
        lateinit var percent: TextView
        lateinit var hex: EditText
        lateinit var red: EditText
        lateinit var green: EditText
        lateinit var blue: EditText
        lateinit var preview: PreviewView
        var updating = false

        fun paintSlider() {
            val full = Color.HSVToColor(floatArrayOf(hue, sat, 1f))
            slider.progressDrawable = GradientDrawable(GradientDrawable.Orientation.LEFT_RIGHT, intArrayOf(Color.BLACK, full)).apply {
                cornerRadius = dp(14).toFloat()
                setSize(-1, dp(28))
            }
        }

        /** Shows the colour in every view (except the one the user is typing in, [keep]). */
        fun sync(keep: EditText? = null) {
            updating = true
            val c = rgb()
            grid.selected = c
            spectrum.hue = hue
            spectrum.sat = sat
            spectrum.value = value
            slider.progress = (value * 100).toInt()
            percent.text = "${(value * 100).toInt()}%"
            paintSlider()
            if (keep !== hex) hex.setText(String.format("#%06X", c and 0xFFFFFF))
            if (keep !== red) red.setText(((c shr 16) and 0xFF).toString())
            if (keep !== green) green.setText(((c shr 8) and 0xFF).toString())
            if (keep !== blue) blue.setText((c and 0xFF).toString())
            preview.now = c
            updating = false
        }

        fun choose(colour: Int, keep: EditText? = null) {
            Color.colorToHSV(colour, tmp)
            hue = tmp[0]
            sat = tmp[1]
            value = tmp[2]
            touched = true
            sync(keep)
        }

        // ---- the tabs
        val tabs = LinearLayout(activity).apply { orientation = LinearLayout.HORIZONTAL }
        val tabNames = listOf(R.string.widget_pick_swatches, R.string.widget_pick_spectrum)
        val tabViews = ArrayList<TextView>()
        val body = FrameLayout(activity)
        grid = SwatchGrid(activity, dp(10).toFloat()) { choose(it) }
        spectrum = SpectrumView(activity, dp(10).toFloat(), dp(14).toFloat()) { h, s ->
            hue = h
            sat = s
            touched = true
            sync()
        }
        val spectrumBox = LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            addView(spectrum, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(240)))
        }
        slider = SeekBar(activity).apply {
            max = 100
            splitTrack = false
            background = null
            setPadding(dp(14), 0, dp(14), 0)
            thumb = GradientDrawable().apply {
                setShape(GradientDrawable.OVAL)
                setColor(Color.WHITE)
                setStroke(dp(2), 0x66000000)
                setSize(dp(30), dp(30))
            }
            thumbOffset = dp(14)
            layoutParams = LinearLayout.LayoutParams(0, dp(40), 1f)
            setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
                override fun onProgressChanged(bar: SeekBar?, progress: Int, fromUser: Boolean) {
                    if (!fromUser) return
                    value = progress / 100f
                    touched = true
                    sync()
                }

                override fun onStartTrackingTouch(bar: SeekBar?) {}

                override fun onStopTrackingTouch(bar: SeekBar?) {}
            })
        }
        percent = TextView(activity).apply {
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
            setTextColor(theme.ink)
            gravity = Gravity.END or Gravity.CENTER_VERTICAL
            minWidth = dp(52)
        }
        val sliderRow = LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            addView(slider)
            addView(percent)
        }
        spectrumBox.addView(sliderRow, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(52)).apply { topMargin = dp(10) })
        body.addView(grid, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, dp(300)))
        body.addView(spectrumBox, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.WRAP_CONTENT))

        fun showTab(i: Int) {
            grid.visibility = if (i == 0) View.VISIBLE else View.GONE
            spectrumBox.visibility = if (i == 1) View.VISIBLE else View.GONE
            for ((n, t) in tabViews.withIndex()) {
                t.setTextColor(if (n == i) theme.ink else theme.inkSoft)
                t.background = GradientDrawable().apply {
                    cornerRadius = dp(26).toFloat()
                    setColor(if (n == i) theme.chip else Color.TRANSPARENT)
                }
            }
        }
        for ((i, name) in tabNames.withIndex()) {
            val t = TextView(activity).apply {
                text = activity.getString(name)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 18f)
                setTypeface(typeface, android.graphics.Typeface.BOLD)
                gravity = Gravity.CENTER
                setPadding(0, dp(12), 0, dp(12))
                isClickable = true
                setOnClickListener { showTab(i) }
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            }
            tabViews.add(t)
            tabs.addView(t)
        }
        root.addView(tabs)
        root.addView(body, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(14) })

        // ---- the colour as numbers
        fun field(width: Int, numeric: Boolean, max: Int): EditText = EditText(activity).apply {
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 17f)
            setTextColor(theme.ink)
            gravity = Gravity.CENTER
            isSingleLine = true
            background = null
            setPadding(0, dp(2), 0, dp(2))
            inputType = if (numeric) InputType.TYPE_CLASS_NUMBER else InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_CAP_CHARACTERS
            filters = arrayOf(InputFilter.LengthFilter(max))
            layoutParams = LinearLayout.LayoutParams(dp(width), LinearLayout.LayoutParams.WRAP_CONTENT)
        }
        hex = field(86, false, 7)
        red = field(46, true, 3)
        green = field(46, true, 3)
        blue = field(46, true, 3)
        preview = PreviewView(activity, dp(12).toFloat(), theme.inkSoft)
        preview.before = start
        fun labelled(label: Int, edit: EditText): LinearLayout = LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            addView(TextView(activity).apply {
                text = activity.getString(label)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
                setTextColor(theme.inkSoft)
                gravity = Gravity.CENTER
            })
            addView(edit)
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { marginStart = dp(10) }
        }
        val numbers = LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            addView(preview, LinearLayout.LayoutParams(dp(60), dp(48)))
            addView(labelled(R.string.widget_pick_hex, hex))
            addView(labelled(R.string.widget_pick_red, red))
            addView(labelled(R.string.widget_pick_green, green))
            addView(labelled(R.string.widget_pick_blue, blue))
        }
        root.addView(numbers, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(16) })

        fun watch(edit: EditText, apply: (String) -> Unit) = edit.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}

            override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}

            override fun afterTextChanged(s: Editable?) {
                if (!updating) apply(s.toString().trim())
            }
        })
        watch(hex) { t ->
            val code = t.removePrefix("#")
            if (code.length == 6) code.toIntOrNull(16)?.let { choose(it or 0xFF000000.toInt(), hex) }
        }
        val channels = listOf(red, green, blue)
        for (e in channels) {
            watch(e) {
                val r = red.text.toString().toIntOrNull()
                val g = green.text.toString().toIntOrNull()
                val b = blue.text.toString().toIntOrNull()
                if (r != null && g != null && b != null && r in 0..255 && g in 0..255 && b in 0..255) choose(Color.rgb(r, g, b), e)
            }
        }

        // ---- the colours used last
        root.addView(TextView(activity).apply {
            text = activity.getString(R.string.widget_pick_recent)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
            setTextColor(theme.inkSoft)
        }, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(16) })
        val used = recent()
        val usedRow = LinearLayout(activity).apply { orientation = LinearLayout.HORIZONTAL }
        for (i in 0 until 6) {
            val colour = used.getOrNull(i) ?: 0
            val disc = View(activity).apply {
                background = discBackground(colour, false)
                if (colour != 0) setOnClickListener { choose(colour) }
            }
            usedRow.addView(cell(disc, 40, 52))
        }
        root.addView(usedRow, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(6) })

        // ---- the buttons
        fun button(text: String, bold: Boolean, onClick: () -> Unit) = TextView(activity).apply {
            this.text = text
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 17f)
            if (bold) setTypeface(typeface, android.graphics.Typeface.BOLD)
            setTextColor(if (bold) theme.accent else theme.ink)
            gravity = Gravity.CENTER
            setPadding(0, dp(16), 0, dp(14))
            isClickable = true
            setOnClickListener { onClick() }
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }
        val buttons = LinearLayout(activity).apply { orientation = LinearLayout.HORIZONTAL }
        buttons.addView(button(activity.getString(R.string.widget_pick_auto), false) {
            dialog.dismiss()
            onPick(0)
        })
        buttons.addView(button(activity.getString(android.R.string.cancel), false) { dialog.dismiss() })
        buttons.addView(button(activity.getString(R.string.widget_pick_done), true) {
            dialog.dismiss()
            if (touched) {
                val chosen = rgb()
                remember(chosen)
                onPick(chosen)
            } else {
                onPick(start)
            }
        })
        root.addView(buttons, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(8) })

        showTab(0)
        sync()
        // The colour it was opened with is not "chosen" until the user touches something.
        touched = false

        dialog.setContentView(ScrollView(activity).apply {
            isVerticalScrollBarEnabled = false
            addView(root)
        })
        dialog.window?.apply {
            setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
            val width = (activity.resources.displayMetrics.widthPixels * 0.94f).toInt().coerceAtMost(dp(440))
            setLayout(width, WindowManager.LayoutParams.WRAP_CONTENT)
            setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE)
        }
        dialog.show()
    }
}

/** The grid of swatches: the first column greys, the others colours, from pale at the top to dark at the bottom. */
private class SwatchGrid(context: Context, private val radius: Float, private val onPick: (Int) -> Unit) : View(context) {
    private val cols = 11
    private val rows = 10
    private val colours = Array(rows) { r -> IntArray(cols) { c -> colourOf(r, c) } }
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val ring = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = 4f * context.resources.displayMetrics.density
    }
    private val clip = Path()

    var selected = 0
        set(v) {
            field = v
            invalidate()
        }

    private fun colourOf(r: Int, c: Int): Int {
        if (c == 0) return Color.HSVToColor(floatArrayOf(0f, 0f, 1f - r / (rows - 1f)))
        val hues = floatArrayOf(0f, 30f, 60f, 120f, 150f, 180f, 210f, 240f, 270f, 310f)
        val (s, v) = when (r) {
            0 -> 0.30f to 1f
            1 -> 0.50f to 1f
            2 -> 0.70f to 1f
            3 -> 0.85f to 1f
            4, 5 -> 1f to 1f
            6 -> 1f to 0.85f
            7 -> 1f to 0.70f
            8 -> 1f to 0.50f
            else -> 1f to 0.30f
        }
        return Color.HSVToColor(floatArrayOf(hues[c - 1], s, v))
    }

    override fun onDraw(canvas: Canvas) {
        val w = width.toFloat()
        val h = height.toFloat()
        clip.reset()
        clip.addRoundRect(0f, 0f, w, h, radius, radius, Path.Direction.CW)
        canvas.save()
        canvas.clipPath(clip)
        val cw = w / cols
        val ch = h / rows
        var hit: Pair<Int, Int>? = null
        for (r in 0 until rows) {
            for (c in 0 until cols) {
                paint.color = colours[r][c]
                canvas.drawRect(c * cw, r * ch, (c + 1) * cw + 1f, (r + 1) * ch + 1f, paint)
                if ((colours[r][c] and 0xFFFFFF) == (selected and 0xFFFFFF)) hit = r to c
            }
        }
        canvas.restore()
        hit?.let { (r, c) ->
            ring.color = if (WidgetColors.luminance(colours[r][c]) > 0.5f) Color.BLACK else Color.WHITE
            canvas.drawRect(c * cw + 2f, r * ch + 2f, (c + 1) * cw - 2f, (r + 1) * ch - 2f, ring)
        }
    }

    override fun onTouchEvent(e: MotionEvent): Boolean {
        if (e.actionMasked == MotionEvent.ACTION_DOWN || e.actionMasked == MotionEvent.ACTION_MOVE) {
            parent?.requestDisallowInterceptTouchEvent(true)
            val c = (e.x / (width.toFloat() / cols)).toInt().coerceIn(0, cols - 1)
            val r = (e.y / (height.toFloat() / rows)).toInt().coerceIn(0, rows - 1)
            onPick(colours[r][c])
            return true
        }
        return true
    }
}

/** The spectrum: the hue across, the saturation down (white at the top); darker when the brightness is lower. */
private class SpectrumView(
    context: Context, private val radius: Float, private val handleRadius: Float, private val onChange: (Float, Float) -> Unit,
) : View(context) {
    var hue = 0f
        set(v) {
            field = v
            invalidate()
        }
    var sat = 0f
        set(v) {
            field = v
            invalidate()
        }
    var value = 1f
        set(v) {
            field = v
            invalidate()
        }
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val handle = Paint(Paint.ANTI_ALIAS_FLAG)
    private val edge = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = 2f * context.resources.displayMetrics.density
        color = 0x55000000
    }
    private val clip = Path()
    private var hueShader: Shader? = null
    private var whiteShader: Shader? = null

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        val hues = intArrayOf(
            0xFFFF0000.toInt(), 0xFFFFFF00.toInt(), 0xFF00FF00.toInt(), 0xFF00FFFF.toInt(),
            0xFF0000FF.toInt(), 0xFFFF00FF.toInt(), 0xFFFF0000.toInt(),
        )
        hueShader = LinearGradient(0f, 0f, w.toFloat(), 0f, hues, null, Shader.TileMode.CLAMP)
        whiteShader = LinearGradient(0f, 0f, 0f, h.toFloat(), 0xFFFFFFFF.toInt(), 0x00FFFFFF, Shader.TileMode.CLAMP)
    }

    override fun onDraw(canvas: Canvas) {
        val w = width.toFloat()
        val h = height.toFloat()
        clip.reset()
        clip.addRoundRect(0f, 0f, w, h, radius, radius, Path.Direction.CW)
        canvas.save()
        canvas.clipPath(clip)
        paint.shader = hueShader
        canvas.drawRect(0f, 0f, w, h, paint)
        paint.shader = whiteShader
        canvas.drawRect(0f, 0f, w, h, paint)
        paint.shader = null
        paint.color = Color.argb(((1f - value) * 255).toInt().coerceIn(0, 255), 0, 0, 0)
        canvas.drawRect(0f, 0f, w, h, paint)
        canvas.restore()
        val x = (hue / 360f * w).coerceIn(handleRadius, w - handleRadius)
        val y = (sat * h).coerceIn(handleRadius, h - handleRadius)
        handle.color = Color.WHITE
        canvas.drawCircle(x, y, handleRadius, handle)
        canvas.drawCircle(x, y, handleRadius, edge)
    }

    override fun onTouchEvent(e: MotionEvent): Boolean {
        if (e.actionMasked == MotionEvent.ACTION_DOWN || e.actionMasked == MotionEvent.ACTION_MOVE) {
            parent?.requestDisallowInterceptTouchEvent(true)
            val h = (e.x / width * 360f).coerceIn(0f, 359.9f)
            val s = (e.y / height).coerceIn(0f, 1f)
            onChange(h, s)
        }
        return true
    }
}

/** The colour it was opened with (left) beside the colour now (right), in one rounded box. */
private class PreviewView(context: Context, private val radius: Float, private val line: Int) : View(context) {
    var before = 0
        set(v) {
            field = v
            invalidate()
        }
    var now = 0
        set(v) {
            field = v
            invalidate()
        }
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val outline = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = 1.5f * context.resources.displayMetrics.density
        color = line
    }
    private val clip = Path()

    override fun onDraw(canvas: Canvas) {
        val w = width.toFloat()
        val h = height.toFloat()
        clip.reset()
        clip.addRoundRect(0f, 0f, w, h, radius, radius, Path.Direction.CW)
        canvas.save()
        canvas.clipPath(clip)
        paint.color = if (before != 0) before else Color.TRANSPARENT
        canvas.drawRect(0f, 0f, w / 2, h, paint)
        paint.color = now
        canvas.drawRect(w / 2, 0f, w, h, paint)
        canvas.restore()
        canvas.drawRoundRect(1f, 1f, w - 1f, h - 1f, radius, radius, outline)
        canvas.drawLine(w / 2, 0f, w / 2, h, outline)
    }
}
