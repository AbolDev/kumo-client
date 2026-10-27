package app.kumo.vpn

import org.json.JSONArray
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Data used while the app's screen is closed. The Dart side counts the usage while it is alive;
 * when the user swipes the app away the VPN service goes on, and this counts instead. The numbers
 * wait in `usage_pending.json` until the app opens and adds them to its own statistics.
 */
object PendingUsage {
    private const val FILE = "usage_pending.json"
    private const val FLUSH_EVERY_MS = 30_000L

    private var lastUp = 0L
    private var lastDown = 0L
    private var lastTick = 0L
    private var lastFlush = 0L

    // day -> [down, up, seconds connected]; server name -> [down, up, seconds, last used (ms)]
    private val days = HashMap<String, LongArray>()
    private val servers = HashMap<String, LongArray>()

    private val dayFormat = SimpleDateFormat("yyyy-MM-dd", Locale.US)

    /** The app is open and counts by itself: only remember where the totals stand. */
    @Synchronized
    fun baseline(upTotal: Long, downTotal: Long) {
        lastUp = upTotal
        lastDown = downTotal
        lastTick = System.currentTimeMillis()
    }

    @Synchronized
    fun add(upTotal: Long, downTotal: Long, server: String) {
        val now = System.currentTimeMillis()
        var du = upTotal - lastUp
        var dd = downTotal - lastDown
        if (du < 0 || dd < 0) {
            du = upTotal
            dd = downTotal
        }
        // A long gap means the link was off: count at most three seconds, as the app does.
        val secs = if (lastTick == 0L) 1L else ((now - lastTick) / 1000).coerceIn(0L, 3L)
        lastUp = upTotal
        lastDown = downTotal
        lastTick = now
        val day = days.getOrPut(dayFormat.format(Date(now))) { LongArray(3) }
        day[0] += dd
        day[1] += du
        day[2] += secs
        val s = servers.getOrPut(server) { LongArray(4) }
        s[0] += dd
        s[1] += du
        s[2] += secs
        s[3] = now
        if (now - lastFlush >= FLUSH_EVERY_MS) flush()
    }

    /** The connection ended: write what is left and forget the totals. */
    @Synchronized
    fun reset() {
        flush()
        lastUp = 0
        lastDown = 0
        lastTick = 0
    }

    /** Hands the app everything counted while it was closed (and forgets it). Null when none. */
    @Synchronized
    fun take(): String? {
        flush()
        val dir = App.instance.filesDir
        val text = Store.read(dir, FILE)
        if (text != null) Store.delete(dir, FILE)
        return text
    }

    /** Adds what was counted to the pending file. */
    @Synchronized
    fun flush() {
        lastFlush = System.currentTimeMillis()
        if (days.isEmpty() && servers.isEmpty()) return
        val dir = App.instance.filesDir
        try {
            val saved = try {
                JSONObject(Store.read(dir, FILE) ?: "{}")
            } catch (_: Exception) {
                JSONObject()
            }
            val d = saved.optJSONObject("days") ?: JSONObject().also { saved.put("days", it) }
            val s = saved.optJSONObject("servers") ?: JSONObject().also { saved.put("servers", it) }
            for ((k, v) in days) merge(d, k, v, lastIndexIsTime = false)
            for ((k, v) in servers) merge(s, k, v, lastIndexIsTime = true)
            Store.write(dir, FILE, saved.toString())
            days.clear()
            servers.clear()
        } catch (_: Exception) {
            // kept in memory and tried again at the next flush
        }
    }

    private fun merge(into: JSONObject, key: String, add: LongArray, lastIndexIsTime: Boolean) {
        val old = into.optJSONArray(key)
        val out = JSONArray()
        for (i in add.indices) {
            val before = old?.optLong(i, 0L) ?: 0L
            // the "last used" time is replaced, the numbers are added up
            out.put(if (lastIndexIsTime && i == add.size - 1) maxOf(before, add[i]) else before + add[i])
        }
        into.put(key, out)
    }
}
