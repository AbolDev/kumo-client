package app.kumo.vpn

import android.app.Activity
import android.app.AlertDialog
import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import android.content.res.ColorStateList
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Bundle
import android.text.Editable
import android.text.InputFilter
import android.text.InputType
import android.text.TextWatcher
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.WindowInsets
import android.view.WindowManager
import android.widget.CheckBox
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.HorizontalScrollView
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.SeekBar
import android.widget.TextView
import android.widget.Toast

/**
 * Opens when a widget is placed (on Android 12+ only if the user asks, from its long-press menu): the look of that
 * widget. The top of the screen shows the phone's own wallpaper (the window lets it through) with the real widget on
 * it, in the state and at the size picked there; a sheet under it holds the settings in tabs (the looks, the colours,
 * the card, the button, the texts, what is shown). The preview follows every change; nothing is kept until Save.
 */
class WidgetConfigActivity : Activity() {
    private var widgetId = AppWidgetManager.INVALID_APPWIDGET_ID

    /** Everything the user is choosing; [WidgetLook.state] is what the preview shows. */
    private lateinit var look: WidgetLook

    /** The size the preview is drawn at: 0 the size the widget was placed at, else one of [SIZES]. */
    private var sizeChoice = 0

    private var tab = 0

    private lateinit var stage: FrameLayout
    private lateinit var column: LinearLayout
    private lateinit var scroll: ScrollView
    private val stateLabels = ArrayList<Pair<TextView, Int>>()
    private val sizeLabels = ArrayList<Pair<TextView, Int>>()
    private val tabLabels = ArrayList<Pair<TextView, Int>>()

    private fun dp(v: Int) = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v.toFloat(), resources.displayMetrics).toInt()

    private val night: Boolean
        get() = (resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES
    private val ink get() = if (night) 0xFFF2F2F5.toInt() else 0xFF1B1B1F.toInt()
    private val inkSoft get() = if (night) 0xA6FFFFFF.toInt() else 0x8C1B1B1F.toInt()
    private val page get() = if (night) 0xFF121214.toInt() else 0xFFF4F4F7.toInt()
    private val panel get() = if (night) 0xFF1E1E22.toInt() else 0xFFFFFFFF.toInt()
    private val accent get() = (if (night) WidgetColors.dark(this) else WidgetColors.light(this)).ring
    private val onAccent get() = if (night) 0xFF101012.toInt() else 0xFFFFFFFF.toInt()

    /** This page is written in the language of the app (the widget has its own words, chosen on the Text tab). */
    override fun attachBaseContext(base: Context) {
        super.attachBaseContext(WidgetLang.localized(base, WidgetLang.appCode(base)))
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setResult(RESULT_CANCELED)
        widgetId = intent?.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, AppWidgetManager.INVALID_APPWIDGET_ID)
            ?: AppWidgetManager.INVALID_APPWIDGET_ID
        if (widgetId == AppWidgetManager.INVALID_APPWIDGET_ID) {
            finish()
            return
        }
        look = WidgetTheme.look(this, widgetId)
        // The see-through look of the first versions is now dark colours with a lower opacity.
        if (look.theme == WidgetTheme.CLEAR) look.theme = WidgetTheme.DARK
        look.state = if (WidgetState.current() == WidgetState.OFF) WidgetState.OFF else WidgetState.ON

        // The wallpaper of the phone is drawn behind the window (no permission is needed for that), and the
        // window is see-through above the sheet: the widget is previewed on the real home screen.
        window.addFlags(WindowManager.LayoutParams.FLAG_SHOW_WALLPAPER)
        window.setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
        window.statusBarColor = Color.TRANSPARENT
        window.navigationBarColor = Color.TRANSPARENT
        edgeToEdge()

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            // A light shade over the wallpaper so the title and the switches read on any picture.
            background = GradientDrawable(GradientDrawable.Orientation.TOP_BOTTOM, intArrayOf(0x59000000, 0x14000000))
        }
        root.addView(TextView(this).apply {
            text = getString(R.string.widget_cfg_title)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 22f)
            setTypeface(typeface, Typeface.BOLD)
            setTextColor(Color.WHITE)
            setShadowLayer(dp(4).toFloat(), 0f, dp(1).toFloat(), 0x99000000.toInt())
            setPadding(dp(24), dp(14), dp(24), 0)
        })
        // The widget is drawn on this layer, which is cleared at each change.
        stage = FrameLayout(this)
        root.addView(stage, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(190)))
        root.addView(glassRow(stateChips()), centered(bottom = 8))
        root.addView(glassRow(sizeChips()), centered(bottom = 12))

        val sheet = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            background = GradientDrawable().apply {
                val r = dp(28).toFloat()
                cornerRadii = floatArrayOf(r, r, r, r, 0f, 0f, 0f, 0f)
                setColor(page)
            }
        }
        sheet.addView(tabBar())
        column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16), 0, dp(16), dp(16))
        }
        scroll = ScrollView(this).apply {
            addView(column)
            isVerticalScrollBarEnabled = false
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f)
        }
        sheet.addView(scroll)
        val bar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(dp(16), dp(8), dp(16), dp(14))
        }
        bar.addView(barButton(R.string.widget_cfg_cancel, filled = false) { finish() })
        bar.addView(View(this), LinearLayout.LayoutParams(dp(12), 1))
        bar.addView(barButton(R.string.widget_cfg_save, filled = true) { save() })
        sheet.addView(bar)
        root.addView(sheet, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f))

        // The page runs under the status bar (the wallpaper shows there) and the sheet under the navigation bar (and
        // over the keyboard, when it is up): the title and the buttons are kept clear of them.
        root.setOnApplyWindowInsetsListener { view, insets ->
            val (top, bottom) = barsOf(insets)
            view.setPadding(0, top, 0, 0)
            sheet.setPadding(0, 0, 0, bottom)
            insets
        }
        setContentView(root)
        markStates()
        markSizes()
        showTab(0)
        renderPreview()
    }

    private fun centered(bottom: Int) = LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT,
    ).apply {
        gravity = Gravity.CENTER_HORIZONTAL
        bottomMargin = dp(bottom)
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
        // The keyboard pushes the sheet up (a text of the user is written in it).
        window.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE)
    }

    /** The heights of the status bar and of what is under the sheet (the navigation bar, or the keyboard), in pixels. */
    @Suppress("DEPRECATION")
    private fun barsOf(insets: WindowInsets): Pair<Int, Int> {
        if (Build.VERSION.SDK_INT >= 30) {
            val bars = insets.getInsets(WindowInsets.Type.systemBars())
            val keys = insets.getInsets(WindowInsets.Type.ime())
            return Pair(bars.top, maxOf(bars.bottom, keys.bottom))
        }
        return Pair(insets.systemWindowInsetTop, insets.systemWindowInsetBottom)
    }

    // ---- The top: the state and the size of the preview ------------------------------------------------------

    /** A dark glass over the wallpaper that holds a row of chips. */
    private fun glassRow(content: View) = LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        setPadding(dp(4), dp(4), dp(4), dp(4))
        background = GradientDrawable().apply {
            cornerRadius = dp(22).toFloat()
            setColor(0x73000000)
        }
        addView(content)
    }

    private fun glassChip(text: String, onClick: () -> Unit, minWidth: Int) = TextView(this).apply {
        this.text = text
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
        setTypeface(typeface, Typeface.BOLD)
        gravity = Gravity.CENTER
        this.minWidth = dp(minWidth)
        setPadding(dp(12), dp(7), dp(12), dp(7))
        setOnClickListener { onClick() }
    }

    /** "Disconnected | Connected": the state of the preview. */
    private fun stateChips(): LinearLayout {
        val row = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        for ((value, label) in listOf(WidgetState.OFF to R.string.widget_cfg_off, WidgetState.ON to R.string.widget_cfg_on)) {
            val t = glassChip(getString(label), {
                look.state = value
                markStates()
                renderPreview()
            }, 100)
            row.addView(t)
            stateLabels.add(Pair(t, value))
        }
        return row
    }

    private fun markStates() {
        for ((t, value) in stateLabels) {
            val chosen = value == look.state
            t.setTextColor(if (chosen) 0xFF1B1B1F.toInt() else Color.WHITE)
            t.background = GradientDrawable().apply {
                cornerRadius = dp(18).toFloat()
                setColor(if (chosen) Color.WHITE else Color.TRANSPARENT)
            }
        }
    }

    /** The size of the preview: the one the widget was placed at, or a cell count, to see how the look follows the size. */
    private fun sizeChips(): HorizontalScrollView {
        val row = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        val names = listOf(getString(R.string.widget_size_real)) + SIZES.drop(1).map { it.name }
        for ((i, name) in names.withIndex()) {
            val t = glassChip(name, {
                sizeChoice = i
                markSizes()
                renderPreview()
            }, 0)
            row.addView(t)
            sizeLabels.add(Pair(t, i))
        }
        return HorizontalScrollView(this).apply {
            isHorizontalScrollBarEnabled = false
            addView(row)
        }
    }

    private fun markSizes() {
        for ((t, value) in sizeLabels) {
            val chosen = value == sizeChoice
            t.setTextColor(if (chosen) 0xFF1B1B1F.toInt() else Color.WHITE)
            t.background = GradientDrawable().apply {
                cornerRadius = dp(18).toFloat()
                setColor(if (chosen) Color.WHITE else Color.TRANSPARENT)
            }
        }
    }

    // ---- The tabs ---------------------------------------------------------------------------------------------

    private val tabNames = listOf(
        R.string.widget_tab_looks, R.string.widget_tab_colours, R.string.widget_tab_card,
        R.string.widget_tab_button, R.string.widget_tab_text, R.string.widget_tab_content,
    )

    private fun tabBar(): HorizontalScrollView {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(dp(12), dp(14), dp(12), dp(10))
        }
        for ((i, name) in tabNames.withIndex()) {
            val t = TextView(this).apply {
                text = getString(name)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
                setTypeface(typeface, Typeface.BOLD)
                gravity = Gravity.CENTER
                setPadding(dp(16), dp(9), dp(16), dp(9))
                isClickable = true
                setOnClickListener { showTab(i) }
                layoutParams = LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT,
                ).apply { marginEnd = dp(8) }
            }
            row.addView(t)
            tabLabels.add(Pair(t, i))
        }
        return HorizontalScrollView(this).apply {
            isHorizontalScrollBarEnabled = false
            addView(row)
        }
    }

    private fun showTab(i: Int, keepScroll: Boolean = false) {
        tab = i
        for ((t, value) in tabLabels) {
            val chosen = value == tab
            t.setTextColor(if (chosen) onAccent else accent)
            t.background = GradientDrawable().apply {
                cornerRadius = dp(20).toFloat()
                if (chosen) setColor(accent) else {
                    setColor(Color.TRANSPARENT)
                    setStroke(dp(1), accent)
                }
            }
        }
        val y = scroll.scrollY
        column.removeAllViews()
        when (tab) {
            0 -> fillLooks()
            1 -> fillColours()
            2 -> fillCard()
            3 -> fillButton()
            4 -> fillText()
            else -> fillContent()
        }
        scroll.post { scroll.scrollTo(0, if (keepScroll) y else 0) }
    }

    /** The tab as it is, drawn again (a value was changed by something other than its own control). */
    private fun refreshTab() = showTab(tab, keepScroll = true)

    // ---- Tab: the looks -----------------------------------------------------------------------------------------

    private class Builtin(val name: Int, val make: () -> WidgetLook)

    private val builtins = listOf(
        Builtin(R.string.widget_preset_default) { WidgetLook() },
        Builtin(R.string.widget_preset_minimal) {
            WidgetLook(
                radius = 12, button = 90, okColor = WidgetTheme.OK_ACCENT, shape = WidgetTheme.SHAPE_ROUNDED,
                show = WidgetTheme.SHOW_SERVER or WidgetTheme.SHOW_SPEED, weight = WidgetTheme.WEIGHT_REGULAR,
            )
        },
        Builtin(R.string.widget_preset_glass) {
            WidgetLook(theme = WidgetTheme.DARK, opacity = 40, radius = 32, border = 1, borderColor = WidgetTheme.BORDER_NEUTRAL)
        },
        Builtin(R.string.widget_preset_bold) {
            WidgetLook(
                radius = 36, button = 120, font = 110, accent = 1, okColor = WidgetTheme.OK_ACCENT,
                spacing = WidgetTheme.SPACING_ROOMY,
            )
        },
        Builtin(R.string.widget_preset_night) {
            WidgetLook(
                theme = WidgetTheme.DARK, opacity = 90, radius = 20, accent = 2, okColor = WidgetTheme.OK_ACCENT,
                shape = WidgetTheme.SHAPE_ROUNDED, border = 1, depth = 1,
            )
        },
        Builtin(R.string.widget_preset_sharp) {
            WidgetLook(radius = 0, accent = 3, shape = WidgetTheme.SHAPE_SQUARE, border = 2, family = 2)
        },
        Builtin(R.string.widget_preset_floating) {
            WidgetLook(radius = 40, accent = 5, okColor = WidgetTheme.OK_ACCENT, depth = 2, spacing = WidgetTheme.SPACING_ROOMY)
        },
    )

    /** A ready-made look sets the look of the widget (colours, shape, sizes, what is shown): the words the user wrote, the
     *  side of the button, the unit and the tap stay as they are. */
    private fun useBuiltin(p: WidgetLook) {
        look.theme = p.theme
        look.opacity = p.opacity
        look.radius = p.radius
        look.height = p.height
        look.button = p.button
        look.font = p.font
        look.accent = p.accent
        look.customAccent = 0
        look.customCard = 0
        look.stateColor = IntArray(3)
        look.okColor = p.okColor
        look.shape = p.shape
        look.icon = p.icon
        look.show = p.show
        look.border = p.border
        look.borderColor = p.borderColor
        look.depth = p.depth
        look.weight = p.weight
        look.family = p.family
        look.spacing = p.spacing
    }

    /** A look the user saved replaces the whole look of the widget. */
    private fun useSaved(p: WidgetLook) {
        val state = look.state
        look = p.copy()
        look.state = state
    }

    private fun fillLooks() {
        column.addView(sectionLabel(R.string.widget_cfg_builtin))
        val chips = HorizontalScrollView(this).apply {
            isHorizontalScrollBarEnabled = false
            val row = LinearLayout(this@WidgetConfigActivity).apply { orientation = LinearLayout.HORIZONTAL }
            for (b in builtins) {
                row.addView(outlineChip(getString(b.name)) {
                    useBuiltin(b.make())
                    renderPreview()
                    toast(R.string.widget_preset_applied)
                })
            }
            addView(row)
        }
        column.addView(chips)

        column.addView(sectionLabel(R.string.widget_cfg_saved))
        val saved = WidgetTheme.savedLooks(this)
        val box = panelBox()
        if (saved.isEmpty()) {
            box.addView(TextView(this).apply {
                text = getString(R.string.widget_saved_empty)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
                setTextColor(inkSoft)
                setPadding(dp(12), dp(10), dp(12), dp(10))
            })
        }
        for (s in saved) {
            val row = LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                isClickable = true
                minimumHeight = dp(52)
                setPadding(dp(12), 0, dp(4), 0)
                setOnClickListener {
                    useSaved(s.look)
                    renderPreview()
                    toast(R.string.widget_preset_applied)
                }
            }
            row.addView(TextView(this).apply {
                text = s.name
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
                setTextColor(ink)
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            })
            row.addView(TextView(this).apply {
                text = getString(R.string.widget_saved_delete)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
                setTypeface(typeface, Typeface.BOLD)
                setTextColor(0xFFD93025.toInt())
                setPadding(dp(14), dp(14), dp(14), dp(14))
                setOnClickListener {
                    WidgetTheme.deleteNamed(this@WidgetConfigActivity, s.name)
                    refreshTab()
                }
            })
            box.addView(row)
        }
        column.addView(box)
        column.addView(actionButton(R.string.widget_saved_save, filled = false) { askName() })

        column.addView(sectionLabel(R.string.widget_cfg_all))
        column.addView(hint(R.string.widget_hint_all))
        column.addView(actionButton(R.string.widget_apply_all, filled = true) { askApplyAll() })
        column.addView(actionButton(R.string.widget_reset, filled = false) {
            val state = look.state
            look = WidgetLook()
            look.state = state
            renderPreview()
            refreshTab()
            toast(R.string.widget_preset_applied)
        })
    }

    private fun askName() {
        val input = dialogText(getString(R.string.widget_saved_name), "")
        AlertDialog.Builder(this)
            .setTitle(R.string.widget_saved_save)
            .setView(wrapDialog(input))
            .setPositiveButton(android.R.string.ok) { _, _ ->
                val name = input.text.toString().trim()
                if (name.isNotEmpty()) {
                    WidgetTheme.saveNamed(this, name, look)
                    toast(R.string.widget_saved_done)
                    refreshTab()
                }
            }
            .setNegativeButton(android.R.string.cancel, null)
            .show()
    }

    private fun askApplyAll() {
        val count = WidgetTheme.placedIds(this).size
        AlertDialog.Builder(this)
            .setMessage(getString(R.string.widget_apply_all_ask, count))
            .setPositiveButton(android.R.string.ok) { _, _ ->
                val done = WidgetTheme.applyToAll(this, look)
                KumoWidget.refreshAll(this)
                Toast.makeText(this, getString(R.string.widget_apply_all_done, done), Toast.LENGTH_SHORT).show()
            }
            .setNegativeButton(android.R.string.cancel, null)
            .show()
    }

    // ---- Tab: the colours ---------------------------------------------------------------------------------------

    private fun fillColours() {
        column.addView(sectionLabel(R.string.widget_cfg_bg))
        column.addView(segmented(
            listOf(
                WidgetTheme.AUTO to R.string.widget_theme_auto,
                WidgetTheme.LIGHT to R.string.widget_theme_light,
                WidgetTheme.DARK to R.string.widget_theme_dark,
            ),
            { look.theme },
        ) { look.theme = it })
        column.addView(hint(R.string.widget_theme_auto_desc))

        column.addView(sectionLabel(R.string.widget_cfg_opacity))
        column.addView(slider(0, 10, 10, look.opacity, "%", 100) { look.opacity = it })

        column.addView(sectionLabel(R.string.widget_cfg_card_colour))
        column.addView(colourRow(R.string.widget_card_auto, { look.customCard }) { look.customCard = it })

        column.addView(sectionLabel(R.string.widget_cfg_accent))
        column.addView(accentBox())

        column.addView(sectionLabel(R.string.widget_cfg_ok))
        column.addView(segmented(
            listOf(WidgetTheme.OK_GREEN to R.string.widget_ok_green, WidgetTheme.OK_ACCENT to R.string.widget_ok_accent),
            { look.okColor },
        ) { look.okColor = it })

        column.addView(sectionLabel(R.string.widget_cfg_state_colours))
        column.addView(hint(R.string.widget_hint_state_colours))
        val box = panelBox()
        val states = listOf(R.string.widget_cfg_off, R.string.widget_state_connecting, R.string.widget_cfg_on)
        for ((i, name) in states.withIndex()) {
            box.addView(colourRow(name, { look.stateColor[i] }, boxed = false) { look.stateColor[i] = it })
        }
        column.addView(box)
    }

    /** The accent colours as discs: the look own (the wallpaper, or Kumo teal), the five, and one of the user's own. */
    private fun accentBox(): LinearLayout {
        val box = panelBox()
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            setPadding(dp(2), dp(8), dp(2), dp(8))
        }
        val discs = ArrayList<Pair<View, Int>>()
        // The value of a disc: 0 the look own, 1 to 5 the colours, -1 the colour of the user.
        fun picked() = if (look.customAccent != 0) -1 else look.accent
        fun mark() {
            for ((disc, value) in discs) {
                (disc.background as GradientDrawable).setStroke(if (value == picked()) dp(3) else dp(1), if (value == picked()) ink else inkSoft)
            }
        }
        for (value in listOf(0, 1, 2, 3, 4, 5, -1)) {
            val own = value == -1
            val disc = TextView(this).apply {
                gravity = Gravity.CENTER
                text = if (own) "+" else ""
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 18f)
                setTextColor(Color.WHITE)
                background = GradientDrawable().apply {
                    setShape(GradientDrawable.OVAL)
                    setColor(
                        when {
                            own && look.customAccent != 0 -> look.customAccent
                            own -> 0xFF8E8E93.toInt()
                            value == 0 -> WidgetColors.light(this@WidgetConfigActivity).ring
                            else -> WidgetColors.swatch(value)
                        },
                    )
                }
                isClickable = true
                setOnClickListener {
                    if (own) {
                        pickColour(look.customAccent) { c ->
                            look.customAccent = c
                            if (c == 0) look.accent = 0
                            renderPreview()
                            refreshTab()
                        }
                    } else {
                        look.accent = value
                        look.customAccent = 0
                        mark()
                        renderPreview()
                    }
                }
                layoutParams = LinearLayout.LayoutParams(0, dp(38), 1f).apply {
                    marginStart = dp(3)
                    marginEnd = dp(3)
                }
            }
            row.addView(disc)
            discs.add(Pair(disc, value))
        }
        mark()
        box.addView(row)
        return box
    }

    /** A row that shows a colour (or "automatic" when it is 0) and opens the picker. */
    private fun colourRow(auto: Int, get: () -> Int, boxed: Boolean = true, set: (Int) -> Unit): LinearLayout {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            minimumHeight = dp(52)
            setPadding(dp(14), 0, dp(14), 0)
            isClickable = true
        }
        val name = TextView(this).apply {
            text = getString(auto)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
            setTextColor(ink)
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }
        val disc = View(this).apply {
            background = GradientDrawable().apply { setShape(GradientDrawable.OVAL) }
            layoutParams = LinearLayout.LayoutParams(dp(30), dp(30))
        }
        val value = TextView(this).apply {
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            setTextColor(inkSoft)
            setPadding(0, 0, dp(10), 0)
        }
        fun paint() {
            val c = get()
            (disc.background as GradientDrawable).apply {
                if (c == 0) {
                    setColor(Color.TRANSPARENT)
                    setStroke(dp(2), inkSoft)
                } else {
                    setColor(c)
                    setStroke(dp(1), inkSoft)
                }
            }
            value.text = if (c == 0) getString(R.string.widget_pick_auto) else String.format("#%06X", c and 0xFFFFFF)
        }
        row.addView(name)
        row.addView(value)
        row.addView(disc)
        paint()
        row.setOnClickListener {
            pickColour(get()) {
                set(it)
                paint()
                renderPreview()
            }
        }
        if (!boxed) return row
        return panelBox().also { it.addView(row) }
    }

    private val palette = intArrayOf(
        0xFFD93025.toInt(), 0xFFE8710A.toInt(), 0xFFF9AB00.toInt(), 0xFF1E9E52.toInt(), 0xFF00897B.toInt(), 0xFF00ACC1.toInt(),
        0xFF1A73E8.toInt(), 0xFF3F51B5.toInt(), 0xFF7B3FE4.toInt(), 0xFFC2185B.toInt(), 0xFF6D4C41.toInt(), 0xFF607D8B.toInt(),
        0xFFFFFFFF.toInt(), 0xFFF1EFE8.toInt(), 0xFFB0B0B5.toInt(), 0xFF6B6B70.toInt(), 0xFF2A2A2E.toInt(), 0xFF000000.toInt(),
    )

    /** A colour picker: a palette and a field for a hex code. "Automatic" gives 0 (the look own). */
    private fun pickColour(start: Int, onPick: (Int) -> Unit) {
        var chosen = start
        val hex = EditText(this).apply {
            hint = "#RRGGBB"
            setTextColor(0xFF1B1B1F.toInt())
            setHintTextColor(0x661B1B1F)
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_CAP_CHARACTERS
            filters = arrayOf(InputFilter.LengthFilter(7))
            isSingleLine = true
            if (start != 0) setText(String.format("#%06X", start and 0xFFFFFF))
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }
        val preview = View(this).apply {
            background = GradientDrawable().apply {
                setShape(GradientDrawable.OVAL)
                setStroke(dp(1), 0x661B1B1F)
                setColor(if (start != 0) start else Color.TRANSPARENT)
            }
            layoutParams = LinearLayout.LayoutParams(dp(34), dp(34)).apply { marginStart = dp(12) }
        }
        fun show(c: Int) {
            (preview.background as GradientDrawable).setColor(if (c != 0) c else Color.TRANSPARENT)
        }
        var typing = true
        hex.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}

            override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}

            override fun afterTextChanged(s: Editable?) {
                if (!typing) return
                val t = s.toString().trim().removePrefix("#")
                if (t.length == 6) t.toIntOrNull(16)?.let {
                    chosen = it or 0xFF000000.toInt()
                    show(chosen)
                }
            }
        })
        val content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(8), dp(20), 0)
        }
        for (rowColours in palette.toList().chunked(6)) {
            val row = LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                layoutParams = LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT,
                ).apply { bottomMargin = dp(8) }
            }
            for (c in rowColours) {
                row.addView(View(this).apply {
                    background = GradientDrawable().apply {
                        setShape(GradientDrawable.OVAL)
                        setColor(c)
                        setStroke(dp(1), 0x331B1B1F)
                    }
                    setOnClickListener {
                        chosen = c
                        typing = false
                        hex.setText(String.format("#%06X", c and 0xFFFFFF))
                        typing = true
                        show(c)
                    }
                    layoutParams = LinearLayout.LayoutParams(0, dp(40), 1f).apply {
                        marginStart = dp(3)
                        marginEnd = dp(3)
                    }
                })
            }
            content.addView(row)
        }
        val field = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        field.addView(hex)
        field.addView(preview)
        content.addView(field)
        AlertDialog.Builder(this)
            .setTitle(R.string.widget_pick_title)
            .setView(content)
            .setPositiveButton(android.R.string.ok) { _, _ -> onPick(if (chosen != 0) chosen or 0xFF000000.toInt() else 0) }
            .setNeutralButton(R.string.widget_pick_auto) { _, _ -> onPick(0) }
            .setNegativeButton(android.R.string.cancel, null)
            .show()
    }

    // ---- Tab: the card ------------------------------------------------------------------------------------------

    private fun fillCard() {
        column.addView(sectionLabel(R.string.widget_cfg_radius))
        column.addView(slider(0, 4, 10, if (look.radius >= 0) look.radius else 20, " dp", 20) { look.radius = it })

        column.addView(sectionLabel(R.string.widget_cfg_height))
        column.addView(slider(WidgetTheme.MIN_HEIGHT, 10, 5, look.height, "%", 100) { look.height = it })
        column.addView(hint(R.string.widget_hint_height))

        column.addView(sectionLabel(R.string.widget_cfg_border))
        column.addView(slider(0, 1, WidgetTheme.MAX_BORDER, look.border, " dp", 0) { look.border = it })
        column.addView(segmented(
            listOf(WidgetTheme.BORDER_ACCENT to R.string.widget_border_accent, WidgetTheme.BORDER_NEUTRAL to R.string.widget_border_neutral),
            { look.borderColor },
            topGap = 8,
        ) { look.borderColor = it })

        column.addView(sectionLabel(R.string.widget_cfg_depth))
        column.addView(segmented(
            listOf(0 to R.string.widget_depth_flat, 1 to R.string.widget_depth_raised, 2 to R.string.widget_depth_floating),
            { look.depth },
        ) { look.depth = it })

        column.addView(sectionLabel(R.string.widget_cfg_spacing))
        column.addView(segmented(
            listOf(
                WidgetTheme.SPACING_COMPACT to R.string.widget_spacing_compact,
                WidgetTheme.SPACING_NORMAL to R.string.widget_spacing_normal,
                WidgetTheme.SPACING_ROOMY to R.string.widget_spacing_roomy,
            ),
            { look.spacing },
        ) { look.spacing = it })
    }

    // ---- Tab: the button ----------------------------------------------------------------------------------------

    private fun fillButton() {
        column.addView(sectionLabel(R.string.widget_cfg_shape))
        column.addView(segmented(
            listOf(
                WidgetTheme.SHAPE_CIRCLE to R.string.widget_shape_circle,
                WidgetTheme.SHAPE_ROUNDED to R.string.widget_shape_rounded,
                WidgetTheme.SHAPE_SQUARE to R.string.widget_shape_square,
            ),
            { look.shape },
        ) { look.shape = it })

        column.addView(sectionLabel(R.string.widget_cfg_icon))
        column.addView(iconBox())

        if (WidgetTheme.canSizeButton) {
            column.addView(sectionLabel(R.string.widget_cfg_button))
            column.addView(slider(WidgetTheme.MIN_BUTTON, 10, 7, look.button, "%", 100) { look.button = it })
        } else {
            column.addView(sectionLabel(R.string.widget_cfg_button))
            column.addView(hint(R.string.widget_hint_button))
        }

        column.addView(sectionLabel(R.string.widget_cfg_side))
        column.addView(segmented(
            listOf(WidgetTheme.LEFT to R.string.widget_side_left, WidgetTheme.RIGHT to R.string.widget_side_right),
            { look.side },
        ) { look.side = it })
        column.addView(hint(R.string.widget_hint_side))
    }

    /** The icons of the button as tiles. */
    private fun iconBox(): LinearLayout {
        val box = panelBox()
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            setPadding(dp(2), dp(8), dp(2), dp(8))
        }
        val icons = listOf(R.drawable.ic_power, R.drawable.ic_shield, R.drawable.ic_lock, R.drawable.ic_bolt, R.drawable.ic_notification)
        val tiles = ArrayList<Pair<FrameLayout, Int>>()
        fun mark() {
            for ((tile, value) in tiles) {
                (tile.background as GradientDrawable).apply {
                    setColor(if (value == look.icon) accent else Color.TRANSPARENT)
                    setStroke(dp(1), if (value == look.icon) accent else inkSoft)
                }
                (tile.getChildAt(0) as ImageView).setColorFilter(if (value == look.icon) onAccent else ink)
            }
        }
        for ((i, res) in icons.withIndex()) {
            val tile = FrameLayout(this).apply {
                background = GradientDrawable().apply { cornerRadius = dp(14).toFloat() }
                isClickable = true
                setOnClickListener {
                    look.icon = i
                    mark()
                    renderPreview()
                }
                layoutParams = LinearLayout.LayoutParams(0, dp(52), 1f).apply {
                    marginStart = dp(3)
                    marginEnd = dp(3)
                }
            }
            tile.addView(ImageView(this).apply { setImageResource(res) }, FrameLayout.LayoutParams(dp(26), dp(26), Gravity.CENTER))
            row.addView(tile)
            tiles.add(Pair(tile, i))
        }
        mark()
        box.addView(row)
        return box
    }

    // ---- Tab: the texts -----------------------------------------------------------------------------------------

    private fun fillText() {
        column.addView(sectionLabel(R.string.widget_cfg_language))
        column.addView(languageRow())
        column.addView(hint(R.string.widget_hint_language))

        column.addView(sectionLabel(R.string.widget_cfg_font))
        column.addView(slider(WidgetTheme.MIN_FONT, 10, 8, look.font, "%", 100) { look.font = it })

        column.addView(sectionLabel(R.string.widget_cfg_weight))
        column.addView(segmented(
            listOf(WidgetTheme.WEIGHT_BOLD to R.string.widget_weight_bold, WidgetTheme.WEIGHT_REGULAR to R.string.widget_weight_regular),
            { look.weight },
        ) { look.weight = it })

        column.addView(sectionLabel(R.string.widget_cfg_family))
        column.addView(familyBox())

        column.addView(sectionLabel(R.string.widget_cfg_align))
        column.addView(segmented(
            listOf(
                WidgetTheme.ALIGN_START to R.string.widget_align_start,
                WidgetTheme.ALIGN_CENTER to R.string.widget_align_center,
                WidgetTheme.ALIGN_END to R.string.widget_align_end,
            ),
            { look.align },
        ) { look.align = it })

        column.addView(sectionLabel(R.string.widget_cfg_title_text))
        column.addView(hint(R.string.widget_hint_title))
        column.addView(textField(R.string.widget_title_hint, look.title) { look.title = it })

        column.addView(sectionLabel(R.string.widget_cfg_labels))
        column.addView(hint(R.string.widget_hint_labels))
        val states = listOf(R.string.widget_cfg_off, R.string.widget_state_connecting, R.string.widget_cfg_on)
        for ((i, name) in states.withIndex()) {
            column.addView(textField(name, look.stateLabel[i], topGap = if (i == 0) 0 else 8) { look.stateLabel[i] = it })
        }
    }

    /** The language of the words of the widget: a row that shows it and opens the list of the languages. */
    private fun languageRow(): LinearLayout {
        val codes = listOf("") + WidgetLang.CODES
        fun nameOf(code: String) = if (code.isEmpty()) getString(R.string.widget_lang_follow) else WidgetLang.NAMES[code] ?: code
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            minimumHeight = dp(52)
            setPadding(dp(14), 0, dp(14), 0)
            isClickable = true
        }
        val value = TextView(this).apply {
            text = nameOf(look.lang)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
            setTypeface(typeface, Typeface.BOLD)
            setTextColor(accent)
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }
        row.addView(value)
        row.addView(TextView(this).apply {
            text = "\u203A"
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 22f)
            setTextColor(inkSoft)
        })
        row.setOnClickListener {
            AlertDialog.Builder(this)
                .setTitle(R.string.widget_cfg_language)
                .setSingleChoiceItems(codes.map { nameOf(it) }.toTypedArray(), codes.indexOf(look.lang).coerceAtLeast(0)) { dialog, which ->
                    look.lang = codes[which]
                    value.text = nameOf(look.lang)
                    renderPreview()
                    dialog.dismiss()
                }
                .setNegativeButton(android.R.string.cancel, null)
                .show()
        }
        return panelBox().also { it.addView(row) }
    }

    /** The typefaces, each written in itself. */
    private fun familyBox(): HorizontalScrollView {
        val row = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        val names = listOf(
            R.string.widget_family_default, R.string.widget_family_serif, R.string.widget_family_mono,
            R.string.widget_family_condensed, R.string.widget_family_light,
        )
        val faces = listOf(null, "serif", "monospace", "sans-serif-condensed", "sans-serif-light")
        val chips = ArrayList<Pair<TextView, Int>>()
        fun mark() {
            for ((t, value) in chips) {
                val on = value == look.family
                t.setTextColor(if (on) onAccent else ink)
                t.background = GradientDrawable().apply {
                    cornerRadius = dp(16).toFloat()
                    if (on) setColor(accent) else {
                        setColor(panel)
                        setStroke(dp(1), inkSoft)
                    }
                }
            }
        }
        for ((i, name) in names.withIndex()) {
            val t = TextView(this).apply {
                text = getString(name)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
                typeface = Typeface.create(faces[i], Typeface.NORMAL)
                gravity = Gravity.CENTER
                setPadding(dp(16), dp(11), dp(16), dp(11))
                isClickable = true
                setOnClickListener {
                    look.family = i
                    mark()
                    renderPreview()
                }
                layoutParams = LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT,
                ).apply { marginEnd = dp(8) }
            }
            row.addView(t)
            chips.add(Pair(t, i))
        }
        mark()
        return HorizontalScrollView(this).apply {
            isHorizontalScrollBarEnabled = false
            addView(row)
        }
    }

    // ---- Tab: what is shown -------------------------------------------------------------------------------------

    private fun fillContent() {
        column.addView(sectionLabel(R.string.widget_cfg_show))
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
                isChecked = (look.show and flag) != 0
                setOnCheckedChangeListener { _, on ->
                    look.show = if (on) look.show or flag else look.show and flag.inv()
                    renderPreview()
                }
            })
        }
        column.addView(box)

        column.addView(sectionLabel(R.string.widget_cfg_info))
        column.addView(segmented(
            listOf(
                WidgetTheme.INFO_NONE to R.string.widget_info_none,
                WidgetTheme.INFO_PROTOCOL to R.string.widget_info_protocol,
                WidgetTheme.INFO_FLAG to R.string.widget_info_flag,
            ),
            { look.info },
        ) { look.info = it })
        column.addView(hint(R.string.widget_hint_info))

        column.addView(sectionLabel(R.string.widget_cfg_unit))
        column.addView(segmented(
            listOf(0 to R.string.widget_unit_bytes, 1 to R.string.widget_unit_bits),
            { if (look.bits) 1 else 0 },
        ) { look.bits = it == 1 })

        column.addView(sectionLabel(R.string.widget_cfg_tap))
        column.addView(segmented(
            listOf(WidgetTheme.TAP_OPEN to R.string.widget_tap_open, WidgetTheme.TAP_TOGGLE to R.string.widget_tap_toggle),
            { look.tap },
        ) { look.tap = it })
        column.addView(hint(R.string.widget_hint_tap))
    }

    // ---- Building blocks ----------------------------------------------------------------------------------------

    private fun toast(text: Int) = Toast.makeText(this, text, Toast.LENGTH_SHORT).show()

    private fun sectionLabel(text: Int) = TextView(this).apply {
        this.text = getString(text)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
        setTypeface(typeface, Typeface.BOLD)
        setTextColor(accent)
        setPadding(dp(8), dp(18), 0, dp(8))
    }

    private fun hint(text: Int) = TextView(this).apply {
        this.text = getString(text)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
        setTextColor(inkSoft)
        setPadding(dp(8), dp(6), dp(8), 0)
    }

    private fun panelBox() = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(dp(6), dp(6), dp(6), dp(6))
        background = GradientDrawable().apply {
            cornerRadius = dp(20).toFloat()
            setColor(panel)
        }
    }

    private fun outlineChip(text: String, onClick: () -> Unit) = TextView(this).apply {
        this.text = text
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
        setTypeface(typeface, Typeface.BOLD)
        setTextColor(accent)
        setPadding(dp(16), dp(10), dp(16), dp(10))
        background = GradientDrawable().apply {
            cornerRadius = dp(20).toFloat()
            setColor(panel)
            setStroke(dp(1), accent)
        }
        isClickable = true
        setOnClickListener { onClick() }
        layoutParams = LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT,
        ).apply { marginEnd = dp(8) }
    }

    private fun actionButton(text: Int, filled: Boolean, onClick: () -> Unit) = TextView(this).apply {
        this.text = getString(text)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
        setTypeface(typeface, Typeface.BOLD)
        setTextColor(if (filled) onAccent else accent)
        gravity = Gravity.CENTER
        setPadding(dp(16), dp(13), dp(16), dp(13))
        background = GradientDrawable().apply {
            cornerRadius = dp(24).toFloat()
            if (filled) setColor(accent) else {
                setColor(Color.TRANSPARENT)
                setStroke(dp(1), accent)
            }
        }
        isClickable = true
        setOnClickListener { onClick() }
        layoutParams = LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT,
        ).apply { topMargin = dp(10) }
    }

    /**
     * A row of pills in a box, one chosen: [current] tells which, [onPick] hears a change (the preview is drawn again after
     * it). Meant for two or three short names.
     */
    private fun segmented(
        options: List<Pair<Int, Int>>, current: () -> Int, topGap: Int = 0, onPick: (Int) -> Unit,
    ): LinearLayout {
        val box = panelBox()
        box.setPadding(dp(4), dp(4), dp(4), dp(4))
        val row = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        val pills = ArrayList<Pair<TextView, Int>>()
        fun mark() {
            for ((t, value) in pills) {
                val on = value == current()
                t.setTextColor(if (on) onAccent else ink)
                t.background = GradientDrawable().apply {
                    cornerRadius = dp(16).toFloat()
                    setColor(if (on) accent else Color.TRANSPARENT)
                }
            }
        }
        for ((value, title) in options) {
            val t = TextView(this).apply {
                text = getString(title)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
                setTypeface(typeface, Typeface.BOLD)
                gravity = Gravity.CENTER
                setPadding(dp(6), dp(12), dp(6), dp(12))
                isClickable = true
                setOnClickListener {
                    onPick(value)
                    mark()
                    renderPreview()
                }
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            }
            row.addView(t)
            pills.add(Pair(t, value))
        }
        mark()
        box.addView(row)
        if (topGap > 0) {
            // A gap above the box inside a column: the box is wrapped.
            return LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(0, dp(topGap), 0, 0)
                addView(box)
            }
        }
        return box
    }

    /**
     * A slider with its value beside it, in a box: [steps] + 1 positions, the value of position `i` being
     * `from + i * step`; [onValue] hears every change. A mark at the end puts it back to [default].
     */
    private fun slider(from: Int, step: Int, steps: Int, value: Int, unit: String, default: Int, onValue: (Int) -> Unit): LinearLayout {
        val box = panelBox()
        box.setPadding(dp(12), dp(10), dp(12), dp(10))
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
        val reset = TextView(this).apply {
            text = "↺"
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 20f)
            setTextColor(accent)
            gravity = Gravity.CENTER
            setPadding(dp(8), dp(4), dp(4), dp(4))
        }
        val bar = SeekBar(this).apply {
            max = steps
            progress = ((value - from) / step).coerceIn(0, steps)
            progressTintList = ColorStateList.valueOf(accent)
            thumbTintList = ColorStateList.valueOf(accent)
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }
        fun markReset(v: Int) {
            reset.alpha = if (v == default) 0.25f else 1f
        }
        markReset(value)
        bar.setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
            override fun onProgressChanged(b: SeekBar?, position: Int, fromUser: Boolean) {
                val v = from + position * step
                shown.text = "$v$unit"
                markReset(v)
                if (fromUser) {
                    onValue(v)
                    renderPreview()
                }
            }

            override fun onStartTrackingTouch(b: SeekBar?) {}

            override fun onStopTrackingTouch(b: SeekBar?) {}
        })
        reset.setOnClickListener {
            bar.progress = ((default - from) / step).coerceIn(0, steps)
            shown.text = "$default$unit"
            markReset(default)
            onValue(default)
            renderPreview()
        }
        row.addView(bar)
        row.addView(shown)
        row.addView(reset)
        box.addView(row)
        return box
    }

    /** A line of text of the user in a box. */
    private fun textField(hintRes: Int, value: String, topGap: Int = 0, onChange: (String) -> Unit): LinearLayout {
        val box = panelBox()
        box.setPadding(dp(12), dp(2), dp(12), dp(2))
        box.addView(EditText(this).apply {
            hint = getString(hintRes)
            setHintTextColor(inkSoft)
            setTextColor(ink)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
            isSingleLine = true
            background = null
            filters = arrayOf(InputFilter.LengthFilter(WidgetTheme.MAX_TEXT))
            setText(value)
            addTextChangedListener(object : TextWatcher {
                override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}

                override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}

                override fun afterTextChanged(s: Editable?) {
                    onChange(s.toString())
                    renderPreview()
                }
            })
        })
        return LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(0, dp(topGap), 0, 0)
            addView(box)
        }
    }

    /** A field of a dialog (the dialog is light whatever the phone is). */
    private fun dialogText(hintText: String, value: String) = EditText(this).apply {
        hint = hintText
        setTextColor(0xFF1B1B1F.toInt())
        setHintTextColor(0x661B1B1F)
        isSingleLine = true
        filters = arrayOf(InputFilter.LengthFilter(WidgetTheme.MAX_TEXT))
        setText(value)
    }

    private fun wrapDialog(view: View) = LinearLayout(this).apply {
        setPadding(dp(20), dp(8), dp(20), 0)
        addView(view, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT))
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

    // ---- The preview and the end --------------------------------------------------------------------------------

    /** A size to preview at: a name and the width and the height in dp. */
    private class SampleSize(val name: String, val w: Int, val h: Int)

    private companion object {
        /** The first is the size the widget was placed at (the others are cells of a typical grid). */
        val SIZES = listOf(
            SampleSize("", 0, 0),
            SampleSize("1×1", 60, 60),
            SampleSize("2×1", 180, 60),
            SampleSize("4×1", 320, 60),
            SampleSize("2×2", 180, 180),
            SampleSize("4×2", 320, 180),
        )
    }

    /** The size the launcher gave the widget, in dp (what it was placed at), kept inside the preview. */
    private fun widgetSizeDp(): Pair<Int, Int> {
        val density = resources.displayMetrics.density
        val screenWidth = (resources.displayMetrics.widthPixels / density).toInt()
        val sample = SIZES[sizeChoice]
        if (sample.w > 0) return Pair(sample.w.coerceAtMost(screenWidth - 32), sample.h.coerceAtMost(170))
        val manager = AppWidgetManager.getInstance(this)
        val options = manager.getAppWidgetOptions(widgetId)
        val info = manager.getAppWidgetInfo(widgetId)
        var w = options?.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH) ?: 0
        var h = options?.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT) ?: 0
        if (w <= 0 && info != null) w = (info.minWidth / density).toInt()
        if (h <= 0 && info != null) h = (info.minHeight / density).toInt()
        return Pair(w.coerceIn(40, screenWidth - 32), h.coerceIn(40, 170))
    }

    /** Draws the real widget in the look being set, at the size picked, on the wallpaper. */
    private fun renderPreview() {
        stage.removeAllViews()
        try {
            val (w, h) = widgetSizeDp()
            val sample = SIZES[sizeChoice]
            val views = KumoWidget.preview(this, widgetId, look, if (sample.w > 0) w else 0, if (sample.w > 0) h else 0) ?: return
            val widget = views.apply(this, stage)
            stage.addView(widget, FrameLayout.LayoutParams(dp(w), dp(h), Gravity.CENTER))
            // A tap on the preview must not connect or disconnect for real.
            stage.addView(View(this).apply { isClickable = true })
        } catch (_: Exception) {
            // The preview is only a help: the settings still work without it.
        }
    }

    private fun save() {
        WidgetTheme.saveLook(this, widgetId, look)
        KumoWidget.refreshOne(this, widgetId)
        setResult(RESULT_OK, Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widgetId))
        finish()
    }
}
