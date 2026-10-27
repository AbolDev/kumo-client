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
            JSONObject(File(filesDir, "settings.json").readText()).optBoolean("allowInsecure", true)
        } catch (_: Exception) {
            true
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
                val answer = download(url, insecure)
                File(dir, "$id.json").writeText(answer.toString())
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
            } catch (_: Exception) {
                // try again at the next run
            }
        }
    }

    private fun download(url: String, insecure: Boolean): JSONObject {
        val conn = URL(url).openConnection() as HttpURLConnection
        try {
            conn.connectTimeout = 10_000
            conn.readTimeout = 20_000
            conn.setRequestProperty("User-Agent", "Mozilla/5.0")
            conn.setRequestProperty("Accept", "application/json, text/plain, */*")
            if (insecure && conn is HttpsURLConnection) {
                val trustAll = arrayOf<TrustManager>(object : X509TrustManager {
                    override fun checkClientTrusted(chain: Array<out java.security.cert.X509Certificate>?, authType: String?) {}
                    override fun checkServerTrusted(chain: Array<out java.security.cert.X509Certificate>?, authType: String?) {}
                    override fun getAcceptedIssuers(): Array<java.security.cert.X509Certificate> = emptyArray()
                })
                conn.sslSocketFactory = SSLContext.getInstance("TLS").apply { init(null, trustAll, null) }.socketFactory
                conn.hostnameVerifier = HostnameVerifier { _, _ -> true }
            }
            require(conn.responseCode == 200) { "HTTP ${conn.responseCode}" }
            val body = conn.inputStream.bufferedReader().use { it.readText() }
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
}