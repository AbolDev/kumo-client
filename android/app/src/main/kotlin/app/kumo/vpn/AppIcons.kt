package app.kumo.vpn

import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager

/**
 * The launcher icon the user picked in Settings. Each icon is an activity-alias of [KumoActivity]
 * in the manifest, and only the chosen one is enabled. The default one is named `.MainActivity`,
 * the name the app's launcher entry had before, so icons already on a home screen keep working.
 */
object AppIcons {
    const val DEFAULT = "teal"

    private val ids = listOf(
        "teal", "teal_light", "teal_solid", "teal_blue", "mint", "teal_night",
        "blue", "sunset", "emerald", "vivid", "navy", "gold", "classic",
    )

    private fun component(context: Context, id: String): ComponentName {
        val pkg = KumoActivity::class.java.name.substringBeforeLast('.')
        val name = if (id == DEFAULT) "$pkg.MainActivity" else "$pkg.Icon_$id"
        return ComponentName(context, name)
    }

    private fun enabled(context: Context, id: String): Boolean =
        when (context.packageManager.getComponentEnabledSetting(component(context, id))) {
            PackageManager.COMPONENT_ENABLED_STATE_ENABLED -> true
            PackageManager.COMPONENT_ENABLED_STATE_DEFAULT -> id == DEFAULT
            else -> false
        }

    fun current(context: Context): String = ids.firstOrNull { enabled(context, it) } ?: DEFAULT

    /** Shows [id] in the launcher. Only the entries whose state changes are touched. */
    fun apply(context: Context, id: String) {
        val want = if (id in ids) id else DEFAULT
        val pm = context.packageManager
        // The new entry first, so there is never a moment without any.
        if (!enabled(context, want)) {
            pm.setComponentEnabledSetting(
                component(context, want),
                PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
                PackageManager.DONT_KILL_APP,
            )
        }
        for (other in ids) {
            if (other != want && enabled(context, other)) {
                pm.setComponentEnabledSetting(
                    component(context, other),
                    PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                    PackageManager.DONT_KILL_APP,
                )
            }
        }
    }
}
