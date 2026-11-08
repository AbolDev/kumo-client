package app.kumo.vpn

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle

/**
 * What another app handed to Kumo (a link of a server or subscription, shared text, or a file):
 * kept here until the app's Dart side asks for it ("takeExternal"). Nothing is added without the
 * user's answer to the question the app shows first.
 */
object ExternalInbox {
    private const val MAX_CHARS = 1_000_000

    @Volatile
    var pending: String? = null

    /** The text that was handed over, and that is no longer pending afterwards. */
    fun take(): String? {
        val text = pending
        pending = null
        return text
    }

    /** The text inside [intent], or null when it holds nothing Kumo can use. */
    fun read(context: Context, intent: Intent): String? {
        return try {
            when (intent.action) {
                Intent.ACTION_SEND -> {
                    intent.getStringExtra(Intent.EXTRA_TEXT)?.take(MAX_CHARS)
                        ?: intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)?.let { readUri(context, it) }
                }
                Intent.ACTION_VIEW -> {
                    val uri = intent.data ?: return null
                    if (uri.scheme == "content" || uri.scheme == "file") readUri(context, uri) else uri.toString().take(MAX_CHARS)
                }
                else -> null
            }?.takeIf { it.isNotBlank() }
        } catch (_: Exception) {
            null
        }
    }

    private fun readUri(context: Context, uri: Uri): String? {
        context.contentResolver.openInputStream(uri)?.use { input ->
            val buffer = ByteArray(MAX_CHARS + 1)
            var n = 0
            while (n < buffer.size) {
                val r = input.read(buffer, n, buffer.size - n)
                if (r < 0) break
                n += r
            }
            if (n > MAX_CHARS) return null // far bigger than any list of servers
            return String(buffer, 0, n, Charsets.UTF_8)
        }
        return null
    }
}

/**
 * Receives the links and files other apps open with Kumo. It has no screen: it keeps what it was
 * given and brings the app forward (in the app's own task, never inside the other app's), where the
 * user is asked before anything is added.
 */
class ExternalOpenActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        ExternalInbox.read(this, intent)?.let { ExternalInbox.pending = it }
        startActivity(
            Intent(this, KumoActivity::class.java).addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP,
            ),
        )
        finish()
    }
}
