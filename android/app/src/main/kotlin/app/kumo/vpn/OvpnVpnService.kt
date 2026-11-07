package app.kumo.vpn

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageManager.NameNotFoundException
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.IpPrefix
import android.net.Network
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import java.io.File
import java.io.FileDescriptor
import java.net.InetAddress
import java.util.Locale

/**
 * A VPN connection with the OpenVPN program (shipped as libopenvpn.so and run from the native library
 * folder). OpenVPN does the protocol; this service gives it what a program cannot have on Android: the
 * tunnel (VpnService) and sockets that stay out of it. See [OvpnManagement].
 *
 * While this runs sing-box does not: the whole connection is OpenVPN's.
 */
class OvpnVpnService : VpnService(), OvpnManagement.Handler {
    companion object {
        const val ACTION_STOP = "app.kumo.vpn.OVPN_STOP"
        const val EXTRA_CONFIG_PATH = "config_path"
        const val EXTRA_USER = "user"
        const val EXTRA_PASSWORD = "password"
        const val EXTRA_KEY_PASSWORD = "key_password"
        const val EXTRA_NAME = "name"
        const val EXTRA_SHOW_SPEED = "show_speed"
        const val EXTRA_SHOW_VOLUME = "show_volume"
        const val EXTRA_SHOW_NAME = "show_name"
        const val EXTRA_KILL_SWITCH = "kill_switch"
        const val EXTRA_INCLUDE = "include"
        const val EXTRA_EXCLUDE = "exclude"
        private const val TAG = "OvpnVpnService"
        private const val CHANNEL_ID = "vpn"
        private const val NOTIFICATION_ID = 1

        // The address OpenVPN gives as the "gateway" of routes that must NOT go through the tunnel
        // (127.'d'.'g'.'w', see route.c of OpenVPN).
        private const val BYPASS_GATEWAY = "127.100.103.119"

        @Volatile private var live: OvpnVpnService? = null
    }

    private var process: java.lang.Process? = null
    private var management: OvpnManagement? = null
    private var tunFd: ParcelFileDescriptor? = null
    private var blockFd: ParcelFileDescriptor? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private var lastNetwork: Network? = null

    @Volatile private var stopping = false
    @Volatile private var failure: String? = null
    private val tail = ArrayDeque<String>()

    private var name = ""
    private var user: String? = null
    private var password: String? = null
    private var keyPassword: String? = null
    private var configPath = ""
    private var showSpeed = true
    private var showVolume = false
    private var showName = true
    private var killSwitch = false
    private var include: List<String> = emptyList()
    private var exclude: List<String> = emptyList()
    @Volatile private var speedText: String? = null
    private var lastBytes: Pair<Long, Long>? = null
    private var lastBytesAt = 0L

    // What OpenVPN has said about the tunnel since the last one was opened.
    private class Plan {
        var address4: Pair<String, Int>? = null
        var peer4: String? = null
        var address6: Pair<String, Int>? = null
        val routes4 = ArrayList<Pair<String, Int>>()
        val routes6 = ArrayList<Pair<String, Int>>()
        val excluded4 = ArrayList<Pair<String, Int>>()
        val dns = ArrayList<String>()
        var domain: String? = null
        var mtu = 1500
    }

    private var plan = Plan()

    override fun onCreate() {
        super.onCreate()
        live = this
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopConnection(null)
            return START_NOT_STICKY
        }
        val path = intent?.getStringExtra(EXTRA_CONFIG_PATH)
        // Every startForegroundService() must be answered by startForeground(), even when the request is ignored.
        runCatching { showForeground() }
        if (intent == null || path == null || process != null ||
            VpnBridge.status == VpnBridge.STARTING || VpnBridge.status == VpnBridge.STARTED
        ) {
            if (process == null) {
                stopForegroundAndSelf()
                IdleNotification.show(this)
            }
            return START_NOT_STICKY
        }
        configPath = path
        name = intent.getStringExtra(EXTRA_NAME) ?: ""
        user = intent.getStringExtra(EXTRA_USER)
        password = intent.getStringExtra(EXTRA_PASSWORD)
        keyPassword = intent.getStringExtra(EXTRA_KEY_PASSWORD)
        showSpeed = intent.getBooleanExtra(EXTRA_SHOW_SPEED, true)
        showVolume = intent.getBooleanExtra(EXTRA_SHOW_VOLUME, false)
        showName = intent.getBooleanExtra(EXTRA_SHOW_NAME, true)
        killSwitch = intent.getBooleanExtra(EXTRA_KILL_SWITCH, false)
        include = intent.getStringArrayListExtra(EXTRA_INCLUDE) ?: emptyList()
        exclude = intent.getStringArrayListExtra(EXTRA_EXCLUDE) ?: emptyList()
        stopping = false
        failure = null
        tail.clear()
        speedText = null
        lastBytes = null
        plan = Plan()
        VpnBridge.engine = "openvpn"
        VpnBridge.serverName = name
        VpnBridge.update(VpnBridge.STARTING)
        showForeground()
        Thread({ startProgram() }, "ovpn-start").start()
        return START_NOT_STICKY
    }

    // ---- the program -----------------------------------------------------------------

    private fun startProgram() {
        try {
            val exe = File(applicationInfo.nativeLibraryDir, "libopenvpn.so")
            require(exe.exists()) { "ovpn:nobinary" }
            val socketPath = File(filesDir, "ovpn/mgmt.sock").path
            val mgmt = OvpnManagement(socketPath, this)
            mgmt.listen()
            management = mgmt
            Thread({ mgmt.run() }, "ovpn-management").start()

            val p = ProcessBuilder(
                exe.path,
                "--config", configPath,
                "--management", socketPath, "unix",
                "--management-client",
                "--management-hold",
                "--management-query-passwords",
                "--verb", "3",
                "--tmp-dir", cacheDir.path,
            ).directory(filesDir).redirectErrorStream(true).start()
            process = p
            Thread({
                try {
                    p.inputStream.bufferedReader().forEachLine { remember(it) }
                } catch (_: Exception) {
                }
            }, "ovpn-output").start()
            Thread({
                val code = try {
                    p.waitFor()
                } catch (_: InterruptedException) {
                    return@Thread
                }
                if (process === p) onProcessExit(code)
            }, "ovpn-wait").start()
            watchNetwork()
            val me = p
            Handler(Looper.getMainLooper()).postDelayed({
                if (process === me && !stopping && VpnBridge.status == VpnBridge.STARTING) {
                    val lines = lastLines()
                    // The server answered but the secure handshake never ended: the usual sign of a network that cuts OpenVPN.
                    val handshake = lines.contains("TLS: Initial packet") && !lines.contains("Peer Connection Initiated")
                    fail(if (handshake) "ovpn:handshake" else "ovpn:timeout|$lines")
                }
            }, 60_000)
        } catch (e: Throwable) {
            Log.e(TAG, "start failed", e)
            fail(if (e.message?.startsWith("ovpn:") == true) e.message!! else "ovpn:exited|${e.message ?: e}")
        }
    }

    private fun remember(line: String) {
        Log.d("openvpn", line)
        synchronized(tail) {
            tail.addLast(line)
            while (tail.size > 12) tail.removeFirst()
        }
    }

    private fun lastLines(): String = synchronized(tail) { tail.joinToString("\n") }

    private fun onProcessExit(code: Int) {
        if (stopping) return
        val lines = lastLines()
        val reason = failure ?: when {
            lines.contains("TLS key negotiation failed") || lines.contains("TLS handshake failed") -> "ovpn:handshake"
            lines.contains("AUTH_FAILED") -> "ovpn:auth"
            else -> "ovpn:exited|$lines".ifEmpty { "ovpn:exited|exit code $code" }
        }
        fail(reason)
    }

    /** The connection ended on its own (not asked for by the user). */
    private fun fail(reason: String) {
        if (stopping) return
        stopping = true
        val wasUp = VpnBridge.status == VpnBridge.STARTED
        teardown()
        if (killSwitch && wasUp && engageBlock()) {
            // Stay up: the block holds until the user acts.
            VpnBridge.update(VpnBridge.ERROR, "$reason|blocked")
            return
        }
        VpnBridge.update(VpnBridge.ERROR, reason)
        stopForegroundAndSelf()
        IdleNotification.show(this)
    }

    private fun stopConnection(reason: String?) {
        val blocked = blockFd != null
        val active = blocked || (VpnBridge.engine == "openvpn" &&
            (VpnBridge.status == VpnBridge.STARTING || VpnBridge.status == VpnBridge.STARTED))
        if (!active) {
            // Nothing of this service runs; the other engine owns the state.
            stopForegroundAndSelf()
            return
        }
        if (stopping && !blocked) return
        stopping = true
        if (!blocked) VpnBridge.update(VpnBridge.STOPPING)
        Thread({
            teardown()
            runCatching { blockFd?.close() }
            blockFd = null
            stopForegroundAndSelf()
            VpnBridge.update(VpnBridge.STOPPED, reason)
            IdleNotification.show(this)
        }, "ovpn-stop").start()
    }

    private fun teardown() {
        runCatching { unwatchNetwork() }
        val p = process
        process = null
        runCatching { management?.send("signal SIGTERM") }
        if (p != null) {
            val ended = runCatching { p.waitFor(2, java.util.concurrent.TimeUnit.SECONDS) }.getOrDefault(false)
            if (!ended) runCatching { p.destroyForcibly() }
        }
        runCatching { management?.close() }
        management = null
        runCatching { tunFd?.close() }
        tunFd = null
        // The configuration holds the certificates: it is not kept.
        runCatching { File(configPath).delete() }
        plan = Plan()
    }

    /** Routes everything into a VPN that goes nowhere (the kill switch). */
    private fun engageBlock(): Boolean = try {
        blockFd = Builder().setSession("Kumo (blocked)")
            .addAddress("10.255.255.1", 32)
            .addRoute("0.0.0.0", 0)
            .addRoute("::", 0)
            .establish()
        blockFd != null
    } catch (e: Exception) {
        Log.w(TAG, "kill switch failed", e)
        false
    }

    // ---- the network -----------------------------------------------------------------

    private fun watchNetwork() {
        val cm = getSystemService(ConnectivityManager::class.java)
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                val before = lastNetwork
                lastNetwork = network
                // A new way out (Wi-Fi to mobile data ...): OpenVPN has to use it.
                if (before != null && before != network) management?.send("network-change")
            }

            override fun onLost(network: Network) {
                if (lastNetwork == network) lastNetwork = null
            }
        }
        networkCallback = callback
        runCatching { cm.registerDefaultNetworkCallback(callback) }
    }

    private fun unwatchNetwork() {
        val callback = networkCallback ?: return
        networkCallback = null
        runCatching { getSystemService(ConnectivityManager::class.java).unregisterNetworkCallback(callback) }
    }

    // ---- what OpenVPN says -----------------------------------------------------------

    override fun state(name: String, detail: String) {
        when (name) {
            "CONNECTED" -> {
                if (VpnBridge.status != VpnBridge.STARTED) {
                    VpnBridge.update(VpnBridge.STARTED)
                    refreshNotification()
                }
            }
            "RECONNECTING", "CONNECTING", "WAIT", "AUTH", "GET_CONFIG", "ASSIGN_IP", "ADD_ROUTES", "TCP_CONNECT", "RESOLVE" -> {
                if (name == "RECONNECTING" && VpnBridge.status == VpnBridge.STARTED) {
                    VpnBridge.update(VpnBridge.STARTING)
                    refreshNotification()
                }
            }
            "AUTH_FAILED" -> failure = "ovpn:auth"
            "EXITING" -> if (detail.contains("auth-failure") || detail.contains("AUTH")) failure = "ovpn:auth"
        }
    }

    override fun bytes(received: Long, sent: Long) {
        val now = System.currentTimeMillis()
        val before = lastBytes
        val dt = now - lastBytesAt
        lastBytes = received to sent
        lastBytesAt = now
        if (before == null || dt <= 0) return
        val down = (received - before.first).coerceAtLeast(0) * 1000 / dt
        val up = (sent - before.second).coerceAtLeast(0) * 1000 / dt
        VpnBridge.traffic(up, down, sent, received, name.ifEmpty { "OpenVPN" })
        if (!showSpeed && !showVolume) return
        val parts = ArrayList<String>()
        if (showSpeed) parts.add("↓ ${speed(down)}   ↑ ${speed(up)}")
        if (showVolume) parts.add("Σ ↓ ${size(received)}   ↑ ${size(sent)}")
        val text = parts.joinToString("  ·  ")
        val screenOn = getSystemService(PowerManager::class.java).isInteractive
        if (text == speedText || !screenOn) return
        speedText = text
        refreshNotification()
    }

    override fun log(text: String) = remember(text)

    override fun secret(what: String) {
        val m = management ?: return
        if (what == "Auth") {
            val u = user
            val p = password
            if (u == null || p == null) {
                failure = "ovpn:auth"
                m.sendSecret(what, "", "")
            } else {
                m.sendSecret(what, u, p)
            }
        } else {
            val k = keyPassword
            if (k == null) failure = "ovpn:auth"
            m.sendSecret(what, null, k ?: "")
        }
    }

    override fun authFailed() {
        failure = "ovpn:auth"
    }

    override fun fatal(message: String) {
        remember(message)
    }

    override fun closed() {
        // The program is gone or going: its exit is handled by the watcher.
    }

    override fun needOk(command: String, argument: String, received: List<FileDescriptor>): OvpnManagement.Answer {
        when (command) {
            "PROTECTFD" -> {
                for (fd in received) {
                    // The descriptor in this process is a copy of the program's socket: protecting it
                    // protects the socket.
                    val copy = ParcelFileDescriptor.dup(fd)
                    val ok = protect(copy.fd)
                    copy.close()
                    if (!ok) return OvpnManagement.Answer.CANCEL
                }
            }
            "IFCONFIG" -> {
                // local remote-or-netmask mtu topology
                val p = argument.split(' ')
                if (p.size >= 4) {
                    plan.mtu = p[2].toIntOrNull() ?: plan.mtu
                    if (p[3] == "subnet") {
                        plan.address4 = p[0] to prefixOf(p[1])
                    } else {
                        // net30 / p2p: the address is the only one of the interface, the peer is reached by a route
                        plan.address4 = p[0] to 32
                        plan.peer4 = p[1]
                    }
                }
            }
            "IFCONFIG6" -> {
                // addr/prefix mtu
                val p = argument.split(' ')
                val a = p[0].split('/')
                if (a.size == 2) plan.address6 = a[0] to (a[1].toIntOrNull() ?: 64)
            }
            "ROUTE" -> {
                // network netmask gateway [dev iface]
                val p = argument.split(' ')
                if (p.size >= 3) {
                    val route = p[0] to prefixOf(p[1])
                    if (p[2] == BYPASS_GATEWAY) plan.excluded4.add(route) else plan.routes4.add(route)
                }
            }
            "ROUTE6" -> {
                // network/prefix dev
                val a = argument.split(' ')[0].split('/')
                if (a.size == 2) plan.routes6.add(a[0] to (a[1].toIntOrNull() ?: 0))
            }
            "DNSSERVER", "DNS6SERVER" -> plan.dns.add(argument.trim())
            "DNSDOMAIN" -> plan.domain = argument.trim()
            "HTTPPROXY" -> {}
            "PERSIST_TUN_ACTION" -> return OvpnManagement.Answer("OPEN_BEFORE_CLOSE")
            "OPENTUN" -> return openTun()
        }
        return OvpnManagement.Answer.OK
    }

    private fun prefixOf(mask: String): Int {
        val bytes = InetAddress.getByName(mask).address
        var n = 0
        for (b in bytes) n += Integer.bitCount(b.toInt() and 0xff)
        return n
    }

    private fun openTun(): OvpnManagement.Answer {
        if (prepare(this) != null) {
            failure = "ovpn:permission"
            return OvpnManagement.Answer.CANCEL
        }
        val p = plan
        val builder = Builder().setSession(name.ifEmpty { "OpenVPN" }).setMtu(p.mtu)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) builder.setMetered(false)
        p.address4?.let { builder.addAddress(it.first, it.second) }
        p.address6?.let { builder.addAddress(it.first, it.second) }
        p.peer4?.let { builder.addRoute(it, 32) }
        var redirects = false
        for ((net, prefix) in p.routes4) {
            builder.addRoute(net, prefix)
            if (prefix <= 1) redirects = true
        }
        for ((net, prefix) in p.routes6) {
            builder.addRoute(net, prefix)
            if (prefix <= 1) redirects = true
        }
        // Android 13 can keep a route out of the tunnel; before it, a bypass route is not possible.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            for ((net, prefix) in p.excluded4) {
                runCatching { builder.excludeRoute(IpPrefix(InetAddress.getByName(net), prefix)) }
            }
        }
        // Everything goes through the tunnel but the server brings no IPv6: it is shut, so that nothing
        // leaves by the real network over it.
        if (redirects && p.address6 == null) {
            runCatching {
                builder.addAddress("fd00:1:fd00:1:fd00:1:fd00:1", 128)
                builder.addRoute("::", 0)
            }
        }
        val dns = if (p.dns.isEmpty() && redirects) listOf("1.1.1.1") else p.dns
        for (d in dns) runCatching { builder.addDnsServer(d) }
        p.domain?.let { builder.addSearchDomain(it) }
        var allow = false
        for (app in include) {
            try {
                builder.addAllowedApplication(app)
                allow = true
            } catch (_: NameNotFoundException) {
            }
        }
        if (!allow) {
            for (app in exclude) {
                try {
                    builder.addDisallowedApplication(app)
                } catch (_: NameNotFoundException) {
                }
            }
        }
        val old = tunFd
        val pfd = builder.establish()
        if (pfd == null) {
            failure = "ovpn:permission"
            return OvpnManagement.Answer.CANCEL
        }
        tunFd = pfd
        runCatching { old?.close() }
        plan = Plan()
        return OvpnManagement.Answer("ok", pfd.fileDescriptor)
    }

    // ---- notification ----------------------------------------------------------------

    private fun buildNotification(): android.app.Notification {
        val connecting = VpnBridge.status != VpnBridge.STARTED
        val title = if (showName) name.ifEmpty { "OpenVPN" } else "Kumo"
        val text = if (connecting) getString(R.string.notif_connecting) else speedText ?: ""
        val open = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java).setFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val stop = PendingIntent.getService(
            this, 11,
            Intent(this, OvpnVpnService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(R.drawable.ic_notification)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setContentIntent(open)
            .addAction(0, getString(R.string.notif_disconnect), stop)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }

    private fun showForeground() {
        IdleNotification.cancel(this)
        val nm = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, getString(R.string.notif_channel), NotificationManager.IMPORTANCE_LOW),
            )
        }
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SYSTEM_EXEMPTED)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun refreshNotification() {
        if (VpnBridge.status != VpnBridge.STARTED && VpnBridge.status != VpnBridge.STARTING) return
        getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, buildNotification())
    }

    private fun stopForegroundAndSelf() {
        runCatching { stopForeground(STOP_FOREGROUND_REMOVE) }
        stopSelf()
    }

    private fun speed(bytesPerSecond: Long): String = when {
        bytesPerSecond >= 1L shl 20 -> String.format(Locale.US, "%.1f MB/s", bytesPerSecond / 1048576.0)
        bytesPerSecond >= 1L shl 10 -> String.format(Locale.US, "%d KB/s", bytesPerSecond / 1024)
        else -> String.format(Locale.US, "%d B/s", bytesPerSecond)
    }

    private fun size(bytes: Long): String = when {
        bytes >= 1L shl 30 -> String.format(Locale.US, "%.2f GB", bytes / 1073741824.0)
        bytes >= 1L shl 20 -> String.format(Locale.US, "%.1f MB", bytes / 1048576.0)
        bytes >= 1L shl 10 -> String.format(Locale.US, "%d KB", bytes / 1024)
        else -> String.format(Locale.US, "%d B", bytes)
    }

    // ---- the system ------------------------------------------------------------------

    override fun onRevoke() {
        // Another VPN app, or the system, took the tunnel.
        stopConnection("revoked")
    }

    override fun onDestroy() {
        if (live === this) {
            live = null
            if (process != null) {
                stopping = true
                teardown()
            }
            if (VpnBridge.engine == "openvpn" && VpnBridge.status == VpnBridge.STARTED) VpnBridge.update(VpnBridge.STOPPED)
        }
        super.onDestroy()
    }
}
