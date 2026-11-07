package app.kumo.vpn

import android.net.LocalServerSocket
import android.net.LocalSocket
import android.net.LocalSocketAddress
import android.system.Os
import android.util.Log
import java.io.File
import java.io.FileDescriptor
import java.io.IOException

/**
 * The control channel to the OpenVPN program: a UNIX socket in the app's own folder that OpenVPN connects
 * to (`--management <path> unix --management-client`). OpenVPN for Android's way of using it is part of
 * OpenVPN itself (doc/android.txt of OpenVPN): the program does not open the tunnel, it asks this side to
 * ("NEED-OK" questions: IFCONFIG, ROUTE, DNSSERVER, OPENTUN ...) and hands over the sockets it wants kept
 * out of the tunnel (PROTECTFD) as file descriptors sent over this socket.
 */
class OvpnManagement(private val path: String, private val handler: Handler) {
    /** What the program says or asks. All calls come from the reading thread. */
    interface Handler {
        fun state(name: String, detail: String)
        fun bytes(received: Long, sent: Long)
        fun log(text: String)

        /** A secret is asked for: "Auth" (user name and password) or "Private Key" (its passphrase). */
        fun secret(what: String)
        fun authFailed()
        fun fatal(message: String)

        /** A question that wants "ok" (and, for OPENTUN, the descriptor of the tunnel). */
        fun needOk(command: String, argument: String, received: List<FileDescriptor>): Answer

        /** The program closed the channel. */
        fun closed()
    }

    class Answer(val text: String, val send: FileDescriptor? = null) {
        companion object {
            val OK = Answer("ok")
            val CANCEL = Answer("cancel")
        }
    }

    private var server: LocalServerSocket? = null
    private var bound: LocalSocket? = null
    @Volatile private var client: LocalSocket? = null
    @Volatile private var done = false
    private val writeLock = Any()

    /** Opens the socket the program will connect to. */
    fun listen() {
        File(path).delete()
        val socket = LocalSocket()
        socket.bind(LocalSocketAddress(path, LocalSocketAddress.Namespace.FILESYSTEM))
        bound = socket
        server = LocalServerSocket(socket.fileDescriptor)
        runCatching { Os.chmod(path, 384) } // 0600
    }

    /** Waits for the program and reads until it goes. Runs on its own thread. */
    fun run() {
        try {
            val accepted = server?.accept() ?: return
            client = accepted
            // The program asks for the things it needs once these are on.
            send("state on")
            send("bytecount 1")
            read(accepted)
        } catch (e: IOException) {
            if (!done) Log.w(TAG, "management channel ended", e)
        } finally {
            if (!done) handler.closed()
        }
    }

    private fun read(socket: LocalSocket) {
        val input = socket.inputStream
        val buffer = ByteArray(4096)
        val line = StringBuilder()
        var fds = ArrayList<FileDescriptor>()
        while (!done) {
            val n = input.read(buffer)
            if (n < 0) return
            // The descriptors that came with this read belong to the question in it.
            socket.ancillaryFileDescriptors?.let { fds.addAll(it) }
            for (i in 0 until n) {
                val c = buffer[i].toInt().toChar()
                if (c == '\n') {
                    val text = line.toString().trimEnd('\r')
                    line.setLength(0)
                    val used = handle(text, fds)
                    if (used) fds = ArrayList()
                } else {
                    line.append(c)
                }
            }
            // Descriptors nobody used are closed, so they do not pile up.
            if (fds.isNotEmpty() && line.isEmpty()) {
                fds.forEach { runCatching { Os.close(it) } }
                fds = ArrayList()
            }
        }
    }

    /** Returns true when the line took the descriptors. */
    private fun handle(text: String, fds: List<FileDescriptor>): Boolean {
        if (!text.startsWith(">")) return false
        val colon = text.indexOf(':')
        if (colon < 0) return false
        val kind = text.substring(1, colon)
        val rest = text.substring(colon + 1)
        when (kind) {
            "HOLD" -> send("hold release")
            "STATE" -> {
                // time,NAME,description,local ip,remote ip,...
                val parts = rest.split(',')
                if (parts.size >= 2) handler.state(parts[1], parts.getOrElse(2) { "" })
            }
            "BYTECOUNT" -> {
                val p = rest.split(',')
                if (p.size == 2) handler.bytes(p[0].toLongOrNull() ?: 0, p[1].toLongOrNull() ?: 0)
            }
            "LOG" -> handler.log(rest.substringAfter(',').substringAfter(',')) // time,flags,text
            "FATAL" -> handler.fatal(rest)
            "PASSWORD" -> {
                val m = Regex("^Need '(.+?)' (?:username/password|password)").find(rest)
                when {
                    m != null -> handler.secret(m.groupValues[1])
                    rest.startsWith("Verification Failed") -> handler.authFailed()
                }
            }
            "NEED-OK" -> {
                val m = Regex("^Need '(.+?)' confirmation MSG:(.*)$").find(rest) ?: return false
                val command = m.groupValues[1]
                val answer = try {
                    handler.needOk(command, m.groupValues[2], fds)
                } catch (e: Exception) {
                    Log.w(TAG, "$command failed", e)
                    Answer.CANCEL
                }
                // The descriptor of a PROTECTFD was only needed to be protected.
                if (command == "PROTECTFD") fds.forEach { runCatching { Os.close(it) } }
                reply(command, answer)
                return true
            }
        }
        return false
    }

    private fun reply(command: String, answer: Answer) {
        val socket = client ?: return
        synchronized(writeLock) {
            try {
                if (answer.send != null) socket.setFileDescriptorsForSend(arrayOf(answer.send))
                socket.outputStream.write("needok '$command' ${answer.text}\n".toByteArray())
                socket.outputStream.flush()
            } catch (e: IOException) {
                Log.w(TAG, "reply failed", e)
            } finally {
                socket.setFileDescriptorsForSend(null)
            }
        }
    }

    /** One command line to the program. */
    fun send(command: String) {
        val socket = client ?: return
        synchronized(writeLock) {
            try {
                socket.outputStream.write((command + "\n").toByteArray())
                socket.outputStream.flush()
            } catch (e: IOException) {
                Log.w(TAG, "send failed", e)
            }
        }
    }

    /** The user name and password (or the passphrase of the key) for [what]. */
    fun sendSecret(what: String, user: String?, password: String) {
        fun quote(s: String) = "\"" + s.replace("\\", "\\\\").replace("\"", "\\\"") + "\""
        if (user != null) send("username ${quote(what)} ${quote(user)}")
        send("password ${quote(what)} ${quote(password)}")
    }

    fun close() {
        done = true
        runCatching { client?.close() }
        runCatching { server?.close() }
        runCatching { bound?.close() }
        File(path).delete()
    }

    private companion object {
        const val TAG = "OvpnManagement"
    }
}
