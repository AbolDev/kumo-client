package app.kumo.vpn

import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.ComponentName
import android.content.Context
import android.net.Uri
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import javax.net.ssl.HostnameVerifier
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManager
import javax.net.ssl.X509TrustManager

/**
 * Downloads the saved subscriptions in the background and leaves each answer in
 * files/subcache/<id>.json. The app picks those files up the next time it starts. It wakes up every
 * hour and downloads only the subscriptions whose own update interval has passed.
 */
class SubUpdateJob : JobService() {
    companion object {
        private const val JOB_ID = 4711
        private const val PERIOD_MS = 60 * 60 * 1000L
        private const val MAX_BODY = 16 * 1024 * 1024

        fun schedule(context: Context) {
            val scheduler = context.getSystemService(JobScheduler::class.java)
            val info = JobInfo.Builder(JOB_ID, ComponentName(context, SubUpdateJob::class.java))
                .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)
                .setRequiresBatteryNotLow(true)
                .setPeriodic(PERIOD_MS)
                .setPersisted(true)
                .build()
            scheduler.schedule(info)
        }

        fun cancel(context: Context) {
            context.getSystemService(JobScheduler::class.java).cancel(JOB_ID)
        }
    }

    @Volatile private var stopped = false

    override fun onStartJob(params: JobParameters): Boolean {
        stopped = false
        Thread {
            try {
                updateAll()
            } finally {
                jobFinished(params, false)
            }
        }.start()
        return true
    }

    override fun onStopJob(params: JobParameters): Boolean {
        stopped = true
        return true
    }

    private fun updateAll() {
        val subs = try {
            JSONObject(File(filesDir, "servers.json").readText()).optJSONArray("subs")
        } catch (_: Exception) {
            null
        } ?: return
        val insecure = try {
            // "subInsecure": downloads accept a certificate that does not check out (off by default;
            // the older "allowInsecure" key was on for everybody and is no longer read)
            JSONObject(File(filesDir, "settings.json").readText()).optBoolean("subInsecure", false)
        } catch (_: Exception) {
            false
        }
        val dir = File(filesDir, "subcache").apply { mkdirs() }
        for (i in 0 until subs.length()) {
            if (stopped) return
            val sub = subs.getJSONObject(i)
            val url = sub.optString("url")
            val id = sub.optString("id")
            if (url.isBlank() || id.isBlank()) continue
            // Each subscription has its own interval (hours), saved by the app next to it.
            val hours = sub.optLong("interval", 6L).coerceIn(1L, 24L * 30L)
            val cache = File(dir, "$id.json")
            val last = maxOf(sub.optLong("updatedAt", 0L), if (cache.exists()) cache.lastModified() else 0L)
            if (System.currentTimeMillis() - last < hours * 60 * 60 * 1000L - 60_000L) continue
            try {
                // What the user set for this subscription (the app has already checked it).
                val agent = sub.optString("userAgent").trim().replace(Regex("[\\u0000-\\u001f\\u007f]"), " ").ifBlank { "Mozilla/5.0" }
                val extra = LinkedHashMap<String, String>()
                sub.optJSONObject("headers")?.let { h ->
                    h.keys().forEach { k -> h.optString(k).takeIf { v -> v.isNotBlank() }?.let { v -> extra[k] = v } }
                }
                val answer = download(url, insecure, agent, extra)
                Store.write(filesDir, "subcache/$id.json", answer.toString())
                Store.delete(filesDir, "subcache/$id.error")
                // The numbers the provider reported: warn if the data or the time is running out.
                val values = HashMap<String, Long>()
                answer.optString("userinfo").split(';').forEach {
                    val kv = it.split('=')
                    if (kv.size == 2) kv[1].trim().toDoubleOrNull()?.let { n -> values[kv[0].trim().lowercase()] = n.toLong() }
                }
                if (values.isNotEmpty()) {
                    UsageAlerts.check(
                        this, id, sub.optString("name").ifBlank { Uri.parse(url).host ?: "Subscription" },
                        (values["upload"] ?: 0L) + (values["download"] ?: 0L),
                        values["total"] ?: 0L,
                        values["expire"] ?: 0L,
                    )
                }
            } catch (e: javax.net.ssl.SSLException) {
                // The certificate did not check out: the app tells the user the next time it opens.
                runCatching { Store.write(filesDir, "subcache/$id.error", "certificate") }
            } catch (_: Exception) {
                // try again at the next run
            }
        }
    }

    /** The answer as text, [MAX_BODY] bytes at most: an address that answers with a huge file (or one that
     *  never ends) must not fill the memory of the app, which ended it with an OutOfMemoryError. */
    private fun readCapped(stream: java.io.InputStream): String {
        val out = java.io.ByteArrayOutputStream()
        val buffer = ByteArray(64 * 1024)
        stream.use { s ->
            while (true) {
                val n = s.read(buffer)
                if (n < 0) break
                require(out.size() + n <= MAX_BODY) { "The subscription is too large" }
                out.write(buffer, 0, n)
            }
        }
        return out.toString("UTF-8")
    }

    private fun download(url: String, insecure: Boolean, agent: String, extra: Map<String, String>): JSONObject {
        var target = URL(url)
        var conn = target.openConnection() as HttpURLConnection
        try {
            // With headers of the user's own (a key, a token) a redirect is followed here: the headers
            // go only to the host the subscription is on, never on to another address.
            val own = target.host
            var hops = 0
            while (true) {
                conn.connectTimeout = 10_000
                conn.readTimeout = 20_000
                conn.setRequestProperty("User-Agent", agent)
                conn.setRequestProperty("Accept", "application/json, text/plain, */*")
                if (extra.isNotEmpty()) {
                    conn.instanceFollowRedirects = false
                    if (target.host == own) extra.forEach { (k, v) -> conn.setRequestProperty(k, v) }
                }
                if (insecure) trustAnyCertificate(conn)
                val code = conn.responseCode
                if (extra.isEmpty() || code !in 300..399) break
                val location = conn.getHeaderField("Location") ?: break
                require(++hops <= 5) { "Too many redirects" }
                val next = URL(target, location)
                require(!(target.protocol == "https" && next.protocol != "https")) { "Redirected to an unencrypted address" }
                conn.disconnect()
                target = next
                conn = target.openConnection() as HttpURLConnection
            }
            require(conn.responseCode == 200) { "HTTP ${conn.responseCode}" }
            val body = readCapped(conn.inputStream)
            return JSONObject()
                .put("time", System.currentTimeMillis())
                .put("body", body)
                .put("profileTitle", conn.getHeaderField("profile-title"))
                .put("disposition", conn.getHeaderField("content-disposition"))
                .put("userinfo", conn.getHeaderField("subscription-userinfo"))
                .put("interval", conn.getHeaderField("profile-update-interval"))
                .put("routing", conn.getHeaderField("routing"))
                .put("routingEnable", conn.getHeaderField("routing-enable"))
                .put("supportUrl", conn.getHeaderField("support-url"))
                .put("webPage", conn.getHeaderField("profile-web-page-url"))
                .put("announce", conn.getHeaderField("announce"))
        } finally {
            conn.disconnect()
        }
    }

    /** A download that accepts a certificate that does not check out (only when the user allowed it). */
    private fun trustAnyCertificate(conn: HttpURLConnection) {
        if (conn is HttpsURLConnection) {
            val trustAll = arrayOf<TrustManager>(object : X509TrustManager {
                override fun checkClientTrusted(chain: Array<out java.security.cert.X509Certificate>?, authType: String?) {}
                override fun checkServerTrusted(chain: Array<out java.security.cert.X509Certificate>?, authType: String?) {}
                override fun getAcceptedIssuers(): Array<java.security.cert.X509Certificate> = emptyArray()
            })
            conn.sslSocketFactory = SSLContext.getInstance("TLS").apply { init(null, trustAll, null) }.socketFactory
            conn.hostnameVerifier = HostnameVerifier { _, _ -> true }
        }
    }
}