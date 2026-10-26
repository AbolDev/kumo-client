package app.kumo.vpn

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager.NameNotFoundException
import android.content.pm.ServiceInfo
import android.net.NetworkCapabilities
import android.net.ProxyInfo
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.os.PowerManager
import android.os.Process
import android.system.OsConstants
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import io.nekohasekai.libbox.CommandClient
import io.nekohasekai.libbox.CommandClientHandler
import io.nekohasekai.libbox.CommandClientOptions
import io.nekohasekai.libbox.CommandServer
import io.nekohasekai.libbox.CommandServerHandler
import io.nekohasekai.libbox.ConnectionEvents
import io.nekohasekai.libbox.ConnectionOwner
import io.nekohasekai.libbox.InterfaceUpdateListener
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.LocalDNSTransport
import io.nekohasekai.libbox.LogIterator
import io.nekohasekai.libbox.NetworkInterfaceIterator
import io.nekohasekai.libbox.Notification
import io.nekohasekai.libbox.OutboundGroupIterator
import io.nekohasekai.libbox.OverrideOptions
import io.nekohasekai.libbox.PlatformInterface
import io.nekohasekai.libbox.RoutePrefix
import io.nekohasekai.libbox.StatusMessage
import io.nekohasekai.libbox.StringIterator
import io.nekohasekai.libbox.SystemProxyStatus
import io.nekohasekai.libbox.TunOptions
import io.nekohasekai.libbox.WIFIState
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.net.Socket
import java.net.Inet6Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.InterfaceAddress
import java.net.NetworkInterface
import java.security.KeyStore
import java.util.Locale
import io.nekohasekai.libbox.NetworkInterface as LibboxNetworkInterface

/**
 * VpnService hosting the sing-box core (libbox). The platform glue follows the official
 * SagerNet/sing-box-for-android app (GPL-3.0), reduced to what a plain connect/disconnect needs.
 */
class BoxVpnService : VpnService(), PlatformInterface, CommandServerHandler {
    companion object {
        const val ACTION_STOP = "app.kumo.vpn.STOP"
        const val ACTION_RESTART = "app.kumo.vpn.RESTART"
        const val ACTION_CONNECT = "app.kumo.vpn.CONNECT"
        const val EXTRA_CONFIG_PATH = "config_path"
        const val EXTRA_SERVER_NAMES = "server_names"
        const val EXTRA_XRAY_CONFIG_PATH = "xray_config_path"
        const val EXTRA_XRAY_PORT = "xray_port"
        const val EXTRA_SHOW_SPEED = "show_speed"
        const val EXTRA_SHOW_VOLUME = "show_volume"
        const val EXTRA_SHOW_NAME = "show_name"
        const val EXTRA_KILL_SWITCH = "kill_switch"
        private const val TAG = "BoxVpnService"
        private const val CHANNEL_ID = "vpn"
        private const val NOTIFICATION_ID = 1

        // Tags used by the generated sing-box config (see singbox_config.dart):
        // a single server is "proxy", otherwise "proxy" is a urltest group over "server-<i>".
        private const val GROUP_TAG = "proxy"
        private const val SERVER_TAG_PREFIX = "server-"

        // Starting, stopping and restarting never overlap, not even between an old service
        // instance that is still shutting down and the new one that replaces it.
        private val lifecycle = Mutex()

        // The instance that owns the process-wide VPN state.
        @Volatile private var live: BoxVpnService? = null
    }

    // An exception nobody catches inside a coroutine would take the whole app down.
    private val scope = CoroutineScope(
        SupervisorJob() + Dispatchers.IO +
            CoroutineExceptionHandler { _, e -> Log.e(TAG, "background task failed", e) },
    )
    private var commandServer: CommandServer? = null
    @Volatile private var commandClient: CommandClient? = null
    private var tunFd: ParcelFileDescriptor? = null
    private var configPath: String? = null

    // XHTTP servers run in a separate Xray process that sing-box reaches over local SOCKS.
    private var xrayConfigPath: String? = null
    private var xrayPort = 0
    @Volatile private var xrayProcess: java.lang.Process? = null
    @Volatile private var xrayStopping = false

    // What the notification shows.
    private var serverNames: List<String> = emptyList()
    @Volatile private var currentName: String? = null
    @Volatile private var speedText: String? = null
    @Volatile private var showSpeed = true
    @Volatile private var showVolume = false
    @Volatile private var showName = true

    // Kill switch: after an unexpected stop this empty VPN swallows all traffic.
    private var killSwitch = false
    private var blockFd: ParcelFileDescriptor? = null

    // Why the next stop happens, when it was not the user's own doing.
    @Volatile private var stopReason: String? = null

    override fun onCreate() {
        super.onCreate()
        live = this
    }

    override fun onStartCommand(startIntent: Intent?, flags: Int, startId: Int): Int {
        when (startIntent?.action) {
            ACTION_STOP -> {
                stopVpn()
                return START_NOT_STICKY
            }
            ACTION_RESTART -> {
                restartVpn()
                return START_NOT_STICKY
            }
        }
        // The Connect button of the "not connected" notification repeats the last connection.
        val intent = if (startIntent?.action == ACTION_CONNECT) {
            runCatching { showForeground() }
            VpnControl.lastStartIntent(this) ?: run {
                stopForegroundAndSelf()
                IdleNotification.show(this)
                return START_NOT_STICKY
            }
        } else {
            startIntent
        }
        val path = intent?.getStringExtra(EXTRA_CONFIG_PATH)
        // Every startForegroundService() must be answered by startForeground(), even when the
        // request is ignored, or Android kills the app for it.
        if (intent != null && path != null) runCatching { showForeground() }
        if (path == null || VpnBridge.status == VpnBridge.STARTING || VpnBridge.status == VpnBridge.STARTED ||
            VpnBridge.status == VpnBridge.STOPPING
        ) {
            if (VpnBridge.status == VpnBridge.STOPPED || VpnBridge.status == VpnBridge.ERROR) {
                stopForegroundAndSelf()
                IdleNotification.show(this)
            }
            return START_NOT_STICKY
        }
        configPath = path
        xrayConfigPath = intent.getStringExtra(EXTRA_XRAY_CONFIG_PATH)
        xrayPort = intent.getIntExtra(EXTRA_XRAY_PORT, 0)
        showSpeed = intent.getBooleanExtra(EXTRA_SHOW_SPEED, true)
        showVolume = intent.getBooleanExtra(EXTRA_SHOW_VOLUME, false)
        showName = intent.getBooleanExtra(EXTRA_SHOW_NAME, true)
        killSwitch = intent.getBooleanExtra(EXTRA_KILL_SWITCH, false)
        serverNames = intent?.getStringArrayListExtra(EXTRA_SERVER_NAMES) ?: emptyList()
        currentName = if (serverNames.size == 1) serverNames[0] else null
        speedText = null
        VpnBridge.update(VpnBridge.STARTING)
        showForeground()
        scope.launch { lifecycle.withLock { startVpn(path) } }
        return START_NOT_STICKY
    }

    // ---- notification ----------------------------------------------------------

    private fun buildNotification(): android.app.Notification {
        val connecting = VpnBridge.status != VpnBridge.STARTED
        val title = if (showName) (currentName ?: getString(R.string.notif_auto)) else "Kumo"
        val text = if (connecting) getString(R.string.notif_connecting) else speedText ?: ""

        val open = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java).setFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT),
            PendingIntent.FLAG_IMMUTABLE,
        )
        fun action(requestCode: Int, name: String) = PendingIntent.getService(
            this, requestCode,
            Intent(this, BoxVpnService::class.java).setAction(name),
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
            .addAction(0, getString(R.string.notif_disconnect), action(1, ACTION_STOP))
            .addAction(0, getString(R.string.notif_restart), action(2, ACTION_RESTART))
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
        // A late stats callback must not bring the notification back after the VPN was stopped.
        if (VpnBridge.status != VpnBridge.STARTED && VpnBridge.status != VpnBridge.STARTING) return
        getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, buildNotification())
    }

    private fun formatSpeed(bytesPerSecond: Long): String = when {
        bytesPerSecond >= 1L shl 20 -> String.format(Locale.US, "%.1f MB/s", bytesPerSecond / 1048576.0)
        bytesPerSecond >= 1L shl 10 -> String.format(Locale.US, "%d KB/s", bytesPerSecond / 1024)
        else -> String.format(Locale.US, "%d B/s", bytesPerSecond)
    }

    private fun formatSize(bytes: Long): String = when {
        bytes >= 1L shl 30 -> String.format(Locale.US, "%.2f GB", bytes / 1073741824.0)
        bytes >= 1L shl 20 -> String.format(Locale.US, "%.1f MB", bytes / 1048576.0)
        bytes >= 1L shl 10 -> String.format(Locale.US, "%d KB", bytes / 1024)
        else -> String.format(Locale.US, "%d B", bytes)
    }

    /** Maps a sing-box outbound tag back to the name of the server it was built from. */
    private fun nameForTag(tag: String): String? = when {
        tag == GROUP_TAG -> serverNames.firstOrNull()
        tag.startsWith(SERVER_TAG_PREFIX) -> tag.removePrefix(SERVER_TAG_PREFIX).toIntOrNull()?.let { serverNames.getOrNull(it) }
        else -> null
    }

    /** Live speed and the server picked by the automatic group, read from the core's command server. */
    private inner class StatsHandler : CommandClientHandler {
        override fun connected() {}

        override fun disconnected(message: String?) {}

        override fun setDefaultLogLevel(level: Int) {}

        override fun clearLogs() {}

        override fun writeLogs(messageList: LogIterator?) {}

        override fun writeStatus(message: StatusMessage) {
            if (!message.trafficAvailable) return
            VpnBridge.serverName = currentName ?: getString(R.string.notif_auto)
            VpnBridge.traffic(message.uplink, message.downlink, message.uplinkTotal, message.downlinkTotal)
            if (!showSpeed && !showVolume) return
            val parts = ArrayList<String>()
            if (showSpeed) parts.add("↓ ${formatSpeed(message.downlink)}   ↑ ${formatSpeed(message.uplink)}")
            if (showVolume) parts.add("Σ ↓ ${formatSize(message.downlinkTotal)}   ↑ ${formatSize(message.uplinkTotal)}")
            val text = parts.joinToString("  ·  ")
            // With the screen off nobody reads the notification: redrawing it every second only
            // wakes the phone's UI process, which adds up to heat and battery use.
            val screenOn = getSystemService(PowerManager::class.java).isInteractive
            if (text == speedText || !screenOn) return
            speedText = text
            refreshNotification()
        }

        override fun writeGroups(message: OutboundGroupIterator?) {
            if (message == null) return
            while (message.hasNext()) {
                val group = message.next()
                if (group.tag == GROUP_TAG && group.type == "urltest") {
                    val name = nameForTag(group.selected)
                    if (name != null && name != currentName) {
                        currentName = name
                        refreshNotification()
                    }
                }
            }
        }

        override fun initializeClashMode(modeList: StringIterator, currentMode: String) {}

        override fun updateClashMode(newMode: String) {}

        override fun writeConnectionEvents(events: ConnectionEvents?) {}
    }

    @Synchronized
    private fun startStatsClient() {
        if (commandClient != null) return
        val options = CommandClientOptions()
        options.addCommand(Libbox.CommandStatus)
        options.addCommand(Libbox.CommandGroup)
        options.statusInterval = 1_000_000_000L // 1 second, in nanoseconds
        val client = CommandClient(StatsHandler(), options)
        try {
            client.connect()
            commandClient = client
        } catch (e: Exception) {
            // The notification still works, it just won't show live speed.
            Log.w(TAG, "stats client failed", e)
        }
    }

    @Synchronized
    private fun stopStatsClient() {
        runCatching { commandClient?.disconnect() }
        commandClient = null
    }

    // ---- lifecycle -----------------------------------------------------------------

    /** Runs with [lifecycle] held. A stop that arrived while this was queued wins. */
    private suspend fun startVpn(path: String) {
        if (VpnBridge.status != VpnBridge.STARTING) return
        VpnBridge.closeGate()
        try {
            App.ensureLibbox()
            val content = File(path).readText()
            require(content.isNotBlank()) { "empty configuration" }
            xrayConfigPath?.let { startXray(it) }
            DefaultNetworkMonitor.start()
            val server = CommandServer(this, this)
            server.start()
            commandServer = server
            server.startOrReloadService(content, OverrideOptions())
            if (VpnBridge.status != VpnBridge.STARTING) return // stopped meanwhile: its teardown follows
            VpnBridge.update(VpnBridge.STARTED)
            refreshNotification()
            startStatsClient()
        } catch (e: Throwable) {
            Log.e(TAG, "start failed", e)
            teardown()
            VpnBridge.update(VpnBridge.ERROR, e.message ?: e.toString())
            stopForegroundAndSelf()
            IdleNotification.show(this)
        } finally {
            VpnBridge.openGate()
        }
    }

    /** Runs with [lifecycle] held. */
    private suspend fun shutDown() {
        VpnBridge.closeGate()
        try {
            teardown()
        } finally {
            VpnBridge.openGate()
        }
    }

    private fun stopVpn() {
        if (VpnBridge.status == VpnBridge.STOPPED || VpnBridge.status == VpnBridge.STOPPING) {
            if (VpnBridge.status == VpnBridge.STOPPED) stopForegroundAndSelf()
            return
        }
        VpnBridge.update(VpnBridge.STOPPING)
        scope.launch {
            lifecycle.withLock { shutDown() }
            // The service is released first: a new connection requested the moment the status
            // turns "stopped" must find a service that is already going away, not this one.
            stopForegroundAndSelf()
            // "revoked" tells the app that another VPN app or the system ended the connection.
            VpnBridge.update(VpnBridge.STOPPED, stopReason)
            stopReason = null
            IdleNotification.show(this@BoxVpnService)
        }
    }

    /** Reconnects with the same configuration (the automatic group picks a server again). */
    private fun restartVpn() {
        val path = configPath ?: return
        if (VpnBridge.status != VpnBridge.STARTED) return
        VpnBridge.update(VpnBridge.STARTING)
        speedText = null
        if (serverNames.size != 1) currentName = null
        refreshNotification()
        scope.launch {
            lifecycle.withLock {
                shutDown()
                startVpn(path)
            }
        }
    }

    // ---- Xray (XHTTP) -------------------------------------------------------------

    /**
     * Starts the Xray executable (shipped as libxray.so so Android extracts it into the native
     * library directory) with a local SOCKS inbound. While it runs this app is kept out of the
     * VPN (see openTun), so Xray reaches the server directly and does not loop into the tunnel.
     */
    private fun startXray(configFile: String) {
        val exe = File(applicationInfo.nativeLibraryDir, "libxray.so")
        require(exe.exists()) { "xray binary is missing" }

        // Go's resolver cannot read Android's DNS settings, so the server name is resolved here.
        val config = JSONObject(File(configFile).readText())
        val settings = config.getJSONArray("outbounds").getJSONObject(0).getJSONObject("settings")
        fun resolve(host: String): String = InetAddress.getByName(host).hostAddress ?: host
        val target = (settings.optJSONArray("vnext") ?: settings.optJSONArray("servers"))?.getJSONObject(0)
        if (target != null) {
            // vless / vmess / trojan / shadowsocks / socks
            target.put("address", resolve(target.getString("address")))
        } else if (settings.has("address") && settings.has("port")) {
            // hysteria
            settings.put("address", resolve(settings.getString("address")))
        }
        // WireGuard: the peers hold "host:port"
        val peers = settings.optJSONArray("peers")
        for (i in 0 until (peers?.length() ?: 0)) {
            val peer = peers!!.getJSONObject(i)
            val endpoint = peer.optString("endpoint")
            val colon = endpoint.lastIndexOf(':')
            if (colon > 0 && !endpoint.startsWith("[")) {
                peer.put("endpoint", resolve(endpoint.substring(0, colon)) + endpoint.substring(colon))
            }
        }
        // A loopback relay (plain VLESS) carries the real server address on its inbound.
        val inbounds = config.optJSONArray("inbounds")
        for (i in 0 until (inbounds?.length() ?: 0)) {
            val inbound = inbounds!!.getJSONObject(i)
            if (inbound.optString("protocol") == "dokodemo-door") {
                val s = inbound.getJSONObject("settings")
                s.put("address", InetAddress.getByName(s.getString("address")).hostAddress)
            }
        }
        File(configFile).writeText(config.toString())

        xrayStopping = false
        val process = ProcessBuilder(exe.path, "run", "-c", configFile)
            .directory(filesDir)
            .redirectErrorStream(true)
            .start()
        xrayProcess = process
        val output = StringBuffer()
        Thread {
            // Destroying the process closes this stream; that must not crash the app.
            try {
                process.inputStream.bufferedReader().forEachLine {
                    Log.d("xray", it)
                    if (output.length < 2000) output.append(it).append('\n')
                }
            } catch (_: Exception) {
            }
        }.start()
        Thread {
            try {
                process.waitFor()
            } catch (_: InterruptedException) {
                return@Thread
            }
            if (!xrayStopping && xrayProcess === process) {
                Log.e(TAG, "xray exited unexpectedly")
                scope.launch {
                    lifecycle.withLock {
                        // Only if this process is still the one in use (not replaced or stopped).
                        if (xrayProcess !== process || xrayStopping) return@withLock
                        shutDown()
                        if (killSwitch && engageBlock()) {
                            // Stay up so the block holds until the user acts.
                            VpnBridge.update(VpnBridge.ERROR, "xray stopped unexpectedly: internet blocked (kill switch)")
                        } else {
                            VpnBridge.update(VpnBridge.ERROR, "xray stopped unexpectedly")
                            stopForegroundAndSelf()
                            IdleNotification.show(this@BoxVpnService)
                        }
                    }
                }
            }
        }.start()

        // Wait until the SOCKS port accepts connections.
        val deadline = System.currentTimeMillis() + 8000
        while (System.currentTimeMillis() < deadline) {
            if (!process.isAlive) {
                throw IllegalStateException("xray failed to start: ${output.toString().trim()}")
            }
            try {
                Socket().use { it.connect(InetSocketAddress("127.0.0.1", xrayPort), 200) }
                return
            } catch (_: IOException) {
                Thread.sleep(100)
            }
        }
        throw IllegalStateException("xray did not start listening")
    }

    private fun stopXray() {
        xrayStopping = true
        xrayProcess?.destroy()
        xrayProcess = null
    }

    /** Routes everything into a VPN that goes nowhere. */
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

    private suspend fun teardown() {
        runCatching { blockFd?.close() }
        blockFd = null
        stopStatsClient()
        // Xray is the core's upstream: stopping it first makes the core's open connections fail at
        // once instead of waiting for them to end, which is what closing the service waits for.
        runCatching { stopXray() }
        // The core owns the tun descriptor while it runs: let it shut down first, and only
        // then release our handle, otherwise it can read from a descriptor that is already gone.
        runCatching { commandServer?.closeService() }
        runCatching { tunFd?.close() }
        tunFd = null
        runCatching { DefaultNetworkMonitor.stop() }
        runCatching { commandServer?.close() }
        commandServer = null
    }

    private fun stopForegroundAndSelf() {
        runCatching { stopForeground(STOP_FOREGROUND_REMOVE) }
        stopSelf()
    }

    override fun onRevoke() {
        stopReason = "revoked"
        stopVpn()
    }

    override fun onDestroy() {
        // A newer instance may already own the state; only the current one reports it.
        if (live === this) {
            live = null
            if (VpnBridge.status == VpnBridge.STARTED) VpnBridge.update(VpnBridge.STOPPED)
        }
        super.onDestroy()
    }

    // ---- CommandServerHandler -------------------------------------------------

    override fun serviceStop() {
        runCatching { commandServer?.closeService() }
        runCatching { tunFd?.close() }
        tunFd = null
    }

    override fun serviceReload() {
        val path = configPath ?: return
        commandServer?.startOrReloadService(File(path).readText(), OverrideOptions())
    }

    override fun getSystemProxyStatus(): SystemProxyStatus = SystemProxyStatus()

    override fun setSystemProxyEnabled(isEnabled: Boolean) {
        serviceReload()
    }

    override fun writeDebugMessage(message: String?) {
        Log.d("sing-box", message ?: "")
    }

    // ---- PlatformInterface ----------------------------------------------------

    override fun usePlatformAutoDetectInterfaceControl(): Boolean = true

    override fun autoDetectInterfaceControl(fd: Int) {
        protect(fd)
    }

    override fun openTun(options: TunOptions): Int {
        if (prepare(this) != null) error("android: missing vpn permission")

        val builder = Builder().setSession("sing-box").setMtu(options.mtu)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) builder.setMetered(false)

        val inet4 = options.inet4Address
        while (inet4.hasNext()) inet4.next().let { builder.addAddress(it.address(), it.prefix()) }
        val inet6 = options.inet6Address
        while (inet6.hasNext()) inet6.next().let { builder.addAddress(it.address(), it.prefix()) }

        var hasInclude = false
        if (options.autoRoute) {
            builder.addDnsServer(options.dnsServerAddress.value)

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                val r4 = options.inet4RouteAddress
                if (r4.hasNext()) {
                    while (r4.hasNext()) builder.addRoute(r4.next().toIpPrefix())
                } else if (options.inet4Address.hasNext()) {
                    builder.addRoute("0.0.0.0", 0)
                }
                val r6 = options.inet6RouteAddress
                if (r6.hasNext()) {
                    while (r6.hasNext()) builder.addRoute(r6.next().toIpPrefix())
                } else if (options.inet6Address.hasNext()) {
                    builder.addRoute("::", 0)
                }
                val x4 = options.inet4RouteExcludeAddress
                while (x4.hasNext()) builder.excludeRoute(x4.next().toIpPrefix())
                val x6 = options.inet6RouteExcludeAddress
                while (x6.hasNext()) builder.excludeRoute(x6.next().toIpPrefix())
            } else {
                val r4 = options.inet4RouteRange
                while (r4.hasNext()) r4.next().let { builder.addRoute(it.address(), it.prefix()) }
                val r6 = options.inet6RouteRange
                while (r6.hasNext()) r6.next().let { builder.addRoute(it.address(), it.prefix()) }
            }

            val include = options.includePackage
            while (include.hasNext()) {
                try {
                    hasInclude = true
                    builder.addAllowedApplication(include.next())
                } catch (_: NameNotFoundException) {
                }
            }
            val exclude = options.excludePackage
            while (exclude.hasNext()) {
                try {
                    builder.addDisallowedApplication(exclude.next())
                } catch (_: NameNotFoundException) {
                }
            }
            // Xray runs inside this app: keep its own traffic out of the tunnel.
            // (An allow-list already keeps this app out, and the two kinds cannot be mixed.)
            if (xrayProcess != null && !hasInclude) builder.addDisallowedApplication(packageName)
        }

        if (options.isHTTPProxyEnabled && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            builder.setHttpProxy(
                ProxyInfo.buildDirectProxy(
                    options.httpProxyServer,
                    options.httpProxyServerPort,
                    options.httpProxyBypassDomain.toList(),
                ),
            )
        }

        val pfd = builder.establish() ?: error("android: the application is not prepared or is revoked")
        tunFd = pfd
        return pfd.fd
    }

    override fun useProcFS(): Boolean = Build.VERSION.SDK_INT < Build.VERSION_CODES.Q

    override fun findConnectionOwner(
        ipProtocol: Int,
        sourceAddress: String,
        sourcePort: Int,
        destinationAddress: String,
        destinationPort: Int,
    ): ConnectionOwner {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) error("android: connection owner needs Android 10+")
        val uid = App.connectivity.getConnectionOwnerUid(
            ipProtocol,
            InetSocketAddress(sourceAddress, sourcePort),
            InetSocketAddress(destinationAddress, destinationPort),
        )
        if (uid == Process.INVALID_UID) error("android: connection owner not found")
        val packages = App.packageMgr.getPackagesForUid(uid)
        return ConnectionOwner().also {
            it.userId = uid
            it.userName = packages?.firstOrNull() ?: ""
            it.setAndroidPackageNames(StringArray((packages?.toList() ?: emptyList()).iterator()))
        }
    }

    override fun startDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        DefaultNetworkMonitor.setListener(listener)
    }

    override fun closeDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        DefaultNetworkMonitor.setListener(null)
    }

    override fun getInterfaces(): NetworkInterfaceIterator {
        val networks = App.connectivity.allNetworks
        val javaInterfaces = NetworkInterface.getNetworkInterfaces().toList()
        val result = mutableListOf<LibboxNetworkInterface>()
        for (network in networks) {
            val link = App.connectivity.getLinkProperties(network) ?: continue
            val caps = App.connectivity.getNetworkCapabilities(network) ?: continue
            val javaIf = javaInterfaces.find { it.name == link.interfaceName } ?: continue
            val box = LibboxNetworkInterface()
            box.name = link.interfaceName
            box.dnsServer = StringArray(link.dnsServers.mapNotNull { it.hostAddress }.iterator())
            box.type = when {
                caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> Libbox.InterfaceTypeWIFI
                caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> Libbox.InterfaceTypeCellular
                caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> Libbox.InterfaceTypeEthernet
                else -> Libbox.InterfaceTypeOther
            }
            box.index = javaIf.index
            runCatching { box.mtu = javaIf.mtu }
            box.addresses = StringArray(javaIf.interfaceAddresses.map { it.toPrefix() }.iterator())
            var flags = 0
            if (caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) {
                flags = OsConstants.IFF_UP or OsConstants.IFF_RUNNING
            }
            if (javaIf.isLoopback) flags = flags or OsConstants.IFF_LOOPBACK
            if (javaIf.isPointToPoint) flags = flags or OsConstants.IFF_POINTOPOINT
            if (javaIf.supportsMulticast()) flags = flags or OsConstants.IFF_MULTICAST
            box.flags = flags
            box.metered = !caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
            result.add(box)
        }
        return InterfaceArray(result.iterator())
    }

    override fun underNetworkExtension(): Boolean = false

    override fun includeAllNetworks(): Boolean = false

    override fun clearDNSCache() {}

    // The name of the Wi-Fi network, for the rule "stay off on these networks". Android only gives
    // it out with the location permission (and the location switch on).
    @Suppress("DEPRECATION")
    override fun readWIFIState(): WIFIState? {
        return try {
            val info = applicationContext.getSystemService(android.net.wifi.WifiManager::class.java)
                ?.connectionInfo ?: return null
            val ssid = info.ssid?.trim('"') ?: return null
            if (ssid.isEmpty() || ssid == "<unknown ssid>") null else WIFIState(ssid, info.bssid ?: "")
        } catch (_: Exception) {
            null
        }
    }

    override fun localDNSTransport(): LocalDNSTransport = LocalResolver

    @OptIn(kotlin.io.encoding.ExperimentalEncodingApi::class)
    override fun systemCertificates(): StringIterator {
        val certs = mutableListOf<String>()
        val keyStore = KeyStore.getInstance("AndroidCAStore")
        keyStore.load(null, null)
        val aliases = keyStore.aliases()
        while (aliases.hasMoreElements()) {
            val cert = keyStore.getCertificate(aliases.nextElement())
            certs.add(
                "-----BEGIN CERTIFICATE-----\n" +
                    kotlin.io.encoding.Base64.encode(cert.encoded) +
                    "\n-----END CERTIFICATE-----",
            )
        }
        return StringArray(certs.iterator())
    }

    override fun sendNotification(notification: Notification) {}

    // ---- helpers ----------------------------------------------------------------

    private class InterfaceArray(private val it: Iterator<LibboxNetworkInterface>) : NetworkInterfaceIterator {
        override fun hasNext(): Boolean = it.hasNext()
        override fun next(): LibboxNetworkInterface = it.next()
    }

    class StringArray(private val it: Iterator<String>) : StringIterator {
        override fun len(): Int = 0 // not used by the core
        override fun hasNext(): Boolean = it.hasNext()
        override fun next(): String = it.next()
    }

    private fun StringIterator.toList(): List<String> = buildList {
        while (hasNext()) add(next())
    }

    private fun RoutePrefix.toIpPrefix() = android.net.IpPrefix(InetAddress.getByName(address()), prefix())

    private fun InterfaceAddress.toPrefix(): String = if (address is Inet6Address) {
        "${Inet6Address.getByAddress(address.address).hostAddress}/$networkPrefixLength"
    } else {
        "${address.hostAddress}/$networkPrefixLength"
    }
}
