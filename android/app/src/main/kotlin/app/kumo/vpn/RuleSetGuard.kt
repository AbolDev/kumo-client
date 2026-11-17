package app.kumo.vpn

import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * A rule list (a `.srs` file of the ad blocker or of a country) that the configuration names but that is not on the
 * disk any more makes the core refuse to start at all ("initialize router: parse rule-set[0]: open ...srs: no such
 * file or directory"). The configuration of a connection the tile, the widget or the boot starts is the one saved by
 * the last connection, so a list that was deleted since (the cache cleaned by the user or the system, a list replaced
 * by an update) is found missing only here. The configuration is then started without that list, and without the
 * rules that name it, instead of not starting: the app brings the lists back the next time it is open.
 */
object RuleSetGuard {
    private const val TAG = "RuleSetGuard"

    /** Keys of a rule that say what to do and not what to match: a rule left with only these matches everything. */
    private val actionKeys = setOf(
        "action", "outbound", "server", "rcode", "method", "no_drop", "strategy", "disable_cache", "rewrite_ttl",
        "client_subnet", "invert", "sniffer", "timeout", "override_address", "override_port", "network_strategy",
        "fallback_delay", "udp_disable_domain_unmapping", "udp_connect", "mode", "type",
    )

    /** [content] (a sing-box configuration) without the local rule lists whose file is gone, and without the rules that
     *  only needed them. The same text when none is missing (or when it cannot be read: the core says what is wrong). */
    fun withoutMissing(content: String, exists: (String) -> Boolean = { File(it).exists() }): String {
        return try {
            val root = JSONObject(content)
            val route = root.optJSONObject("route") ?: return content
            val sets = route.optJSONArray("rule_set") ?: return content
            val gone = HashSet<String>()
            val kept = JSONArray()
            for (i in 0 until sets.length()) {
                val set = sets.optJSONObject(i)
                val path = set?.optString("path").orEmpty()
                if (set != null && set.optString("type") == "local" && path.isNotEmpty() && !exists(path)) {
                    gone.add(set.optString("tag"))
                    Log.w(TAG, "the rule list ${set.optString("tag")} is not on the disk: starting without it ($path)")
                } else {
                    kept.put(sets.get(i))
                }
            }
            if (gone.isEmpty()) return content
            route.put("rule_set", kept)
            route.optJSONArray("rules")?.let { route.put("rules", prune(it, gone)) }
            root.optJSONObject("dns")?.let { dns -> dns.optJSONArray("rules")?.let { dns.put("rules", prune(it, gone)) } }
            root.toString()
        } catch (e: Exception) {
            content
        }
    }

    /** [rules] without the names in [gone]; a rule that named only those (and has nothing else to match) is dropped. */
    private fun prune(rules: JSONArray, gone: Set<String>): JSONArray {
        val out = JSONArray()
        for (i in 0 until rules.length()) {
            val rule = rules.optJSONObject(i)
            if (rule == null) {
                out.put(rules.get(i))
                continue
            }
            var named = false
            val tags = rule.opt("rule_set")
            if (tags is JSONArray) {
                val left = JSONArray()
                for (j in 0 until tags.length()) {
                    if (tags.optString(j) in gone) named = true else left.put(tags.get(j))
                }
                if (named) {
                    if (left.length() == 0) rule.remove("rule_set") else rule.put("rule_set", left)
                }
            } else if (tags is String && tags in gone) {
                named = true
                rule.remove("rule_set")
            }
            // A rule made of other rules: the same inside it (one that has none left is dropped below).
            val inner = rule.optJSONArray("rules")
            if (inner != null) {
                val after = prune(inner, gone)
                if (after.length() != inner.length()) {
                    named = true
                    rule.put("rules", after)
                }
            }
            val nested = rule.optJSONArray("rules")
            val leftOver = rule.keys().asSequence().filter { it !in actionKeys && it != "rules" }.toList()
            val hollow = named && leftOver.isEmpty() && (nested == null || nested.length() == 0)
            if (!hollow) out.put(rule)
        }
        return out
    }
}
