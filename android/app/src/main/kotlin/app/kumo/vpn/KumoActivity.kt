package app.kumo.vpn

import android.app.Activity
import android.app.ActivityManager
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat
import android.net.Uri
import android.net.VpnService
import android.os.PowerManager
import android.provider.Settings
import org.json.JSONObject
import android.os.Build
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import io.nekohasekai.libbox.Libbox
import java.io.File
import java.util.concurrent.Executors

class KumoActivity : FlutterActivity() {
    private companion object {
        const val REQUEST_VPN = 1001
        const val REQUEST_NOTIFICATIONS = 1002
    }

    private var pendingPrepare: MethodChannel.Result? = null
    private var control: MethodChannel? = null

    /** A link or file was handed to the app while it was running: the Dart side is told to ask for it. */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (ExternalInbox.pending != null) control?.invokeMethod("external", null)
    }

    /** The system says it is a television, or it has the TV launcher and no touch screen (a box). */
    private fun isTelevision(): Boolean {
        val mode = getSystemService(android.app.UiModeManager::class.java)?.currentModeType
        if (mode == android.content.res.Configuration.UI_MODE_TYPE_TELEVISION) return true
        val pm = packageManager
        return pm.hasSystemFeature("android.software.leanback") && !pm.hasSystemFeature("android.hardware.touchscreen")
    }

    // Each delay test starts its own core, so only a few run at once.
    private val delayPool = Executors.newFixedThreadPool(12)

    /** The error the last delay test ended with (what the core said), for the diagnosis of a failing server. */
    @Volatile
    private var lastDelayError: String? = null

    override fun onResume() {
        super.onResume()
        applyTaskLook()
    }

    /**
     * The name and icon of the app's card in the list of recent apps: those of the disguise when one is on
     * (`disguise_name.txt`, written by the "taskLook" call), Kumo's own otherwise.
     */
    private fun applyTaskLook() {
        try {
            val named = File(filesDir, "disguise_name.txt")
            val name = if (named.exists()) named.readText().trim() else ""
            if (name.isEmpty()) {
                setTaskDescription(ActivityManager.TaskDescription())
                return
            }
            val file = File(filesDir, "disguise_icon.png")
            var bitmap: Bitmap? = if (file.exists()) BitmapFactory.decodeFile(file.path) else null
            if (bitmap == null) {
                val shown = AppIcons.currentComponent(this)?.let { packageManager.getActivityIcon(it) }
                if (shown != null) {
                    bitmap = Bitmap.createBitmap(96, 96, Bitmap.Config.ARGB_8888)
                    shown.setBounds(0, 0, 96, 96)
                    shown.draw(Canvas(bitmap))
                }
            }
            @Suppress("DEPRECATION")
            setTaskDescription(ActivityManager.TaskDescription(name, bitmap))
        } catch (_: Exception) {
        }
    }

    override fun onDestroy() {
        // Without this the 12 test threads outlive the screen and pile up each time it is rebuilt.
        if (isFinishing) delayPool.shutdownNow()
        super.onDestroy()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        control = MethodChannel(messenger, "kumo/control")
        control!!.setMethodCallHandler { call, result ->
            when (call.method) {
                // The link or file another app handed over, once (null when there is none).
                "takeExternal" -> result.success(ExternalInbox.take())
                // Asks for the system VPN consent dialog (and notification permission on 13+).
                "prepare" -> prepare(result)
                "start" -> {
                    val config = call.argument<String>("config")
                    if (config.isNullOrBlank()) {
                        result.error("bad_args", "config is empty", null)
                        return@setMethodCallHandler
                    }
                    val file = File(filesDir, "active_config.json")
                    file.writeText(config)
                    val names = call.argument<List<String>>("names") ?: emptyList()
                    val showSpeed = call.argument<Boolean>("showSpeed") ?: true
                    val showVolume = call.argument<Boolean>("showVolume") ?: false
                    val showName = call.argument<Boolean>("showName") ?: true
                    val intent = Intent(this, BoxVpnService::class.java)
                        .putExtra(BoxVpnService.EXTRA_CONFIG_PATH, file.path)
                        .putStringArrayListExtra(BoxVpnService.EXTRA_SERVER_NAMES, ArrayList(names))
                        .putExtra(BoxVpnService.EXTRA_SHOW_SPEED, showSpeed)
                        .putExtra(BoxVpnService.EXTRA_SHOW_VOLUME, showVolume)
                        .putExtra(BoxVpnService.EXTRA_SHOW_NAME, showName)
                        .putExtra(BoxVpnService.EXTRA_KILL_SWITCH, call.argument<Boolean>("killSwitch") ?: false)
                    val xrayConfig = call.argument<String>("xrayConfig")
                    if (!xrayConfig.isNullOrBlank()) {
                        val xrayFile = File(filesDir, "xray_config.json")
                        xrayFile.writeText(xrayConfig)
                        intent.putExtra(BoxVpnService.EXTRA_XRAY_CONFIG_PATH, xrayFile.path)
                            .putExtra(BoxVpnService.EXTRA_XRAY_PORT, call.argument<Int>("xrayPort") ?: 0)
                    }
                    // The configuration of the proxy kept running after the tunnel stops (none: off).
                    val standbyConfig = call.argument<String>("standbyConfig")
                    val standby = writeStandby(
                        standbyConfig, call.argument<String>("standbyXrayConfig"),
                        call.argument<Int>("xrayPort") ?: 0, call.argument<Int>("proxyPort") ?: 0,
                    )
                    standby?.let { intent.putExtras(it) }
                    // Remembered so the device-startup receiver can repeat this connection.
                    File(filesDir, "last_start.json").writeText(
                        JSONObject()
                            .put("names", org.json.JSONArray(names))
                            .put("showSpeed", showSpeed)
                            .put("showVolume", showVolume)
                            .put("showName", showName)
                            .put("killSwitch", call.argument<Boolean>("killSwitch") ?: false)
                            .put("xrayPort", if (xrayConfig.isNullOrBlank()) 0 else (call.argument<Int>("xrayPort") ?: 0))
                            .put("standby", standby != null)
                            .put("proxyPort", call.argument<Int>("proxyPort") ?: 0)
                            .toString(),
                    )
                    try {
                        ContextCompat.startForegroundService(this, intent)
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("start_failed", e.message, null)
                    }
                }
                // Only the local proxy, no tunnel (the "keep the proxy running" setting).
                "startStandby" -> {
                    val extras = writeStandby(
                        call.argument<String>("config"), call.argument<String>("xrayConfig"),
                        call.argument<Int>("xrayPort") ?: 0, call.argument<Int>("proxyPort") ?: 0,
                    )
                    if (extras == null) {
                        result.error("bad_args", "config is empty", null)
                        return@setMethodCallHandler
                    }
                    try {
                        ContextCompat.startForegroundService(
                            this,
                            Intent(this, BoxVpnService::class.java).setAction(BoxVpnService.ACTION_PROXY).putExtras(extras),
                        )
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                "stopStandby" -> {
                    try {
                        startService(Intent(this, BoxVpnService::class.java).setAction(BoxVpnService.ACTION_STOP_PROXY))
                    } catch (_: Exception) {
                    }
                    result.success(null)
                }
                // Real delay: fetch a URL through a throw-away sing-box instance holding one outbound.
                "delay" -> {
                    val config = call.argument<String>("config") ?: ""
                    val url = call.argument<String>("url") ?: ""
                    val timeout = call.argument<Int>("timeout") ?: 8000
                    delayPool.execute {
                        // -2 = skipped because the tunnel is being started or stopped.
                        var ms = -2
                        if (VpnBridge.enterDelay()) {
                            ms = try {
                                App.ensureLibbox()
                                Libbox.measureDelay(config, url, timeout)
                            } catch (e: Throwable) {
                                lastDelayError = e.message
                                -1
                            } finally {
                                VpnBridge.exitDelay()
                            }
                        }
                        runOnUiThread { result.success(ms) }
                    }
                }
                // What comes back through a server from some well-known addresses (Kumo's Inspect in libbox): the
                // safety check of a server. Null when skipped because the tunnel is being started or stopped.
                "inspect" -> {
                    val config = call.argument<String>("config") ?: ""
                    val requests = call.argument<String>("requests") ?: "[]"
                    val timeout = call.argument<Int>("timeout") ?: 25000
                    delayPool.execute {
                        var answer: String? = null
                        if (VpnBridge.enterDelay()) {
                            answer = try {
                                App.ensureLibbox()
                                Libbox.inspect(config, requests, timeout)
                            } catch (_: Throwable) {
                                ""
                            } finally {
                                VpnBridge.exitDelay()
                            }
                        }
                        runOnUiThread { result.success(answer) }
                    }
                }
                // How fast data goes through a server (Kumo's MeasureSpeed in libbox): a download or an upload.
                "speed" -> {
                    val config = call.argument<String>("config") ?: ""
                    val url = call.argument<String>("url") ?: ""
                    val upload = call.argument<Boolean>("upload") ?: false
                    val size = call.argument<Int>("size") ?: 4000000
                    val timeout = call.argument<Int>("timeout") ?: 30000
                    delayPool.execute {
                        // -2 = skipped because the tunnel is being started or stopped.
                        var mbps = -2.0
                        if (VpnBridge.enterDelay()) {
                            mbps = try {
                                App.ensureLibbox()
                                Libbox.measureSpeed(config, url, upload, size, timeout)
                            } catch (_: Throwable) {
                                -1.0
                            } finally {
                                VpnBridge.exitDelay()
                            }
                        }
                        runOnUiThread { result.success(mbps) }
                    }
                }
                // A JSON rule-set written as a binary one (Kumo's CompileRuleSet in libbox), off the main thread.
                "compileRuleSet" -> {
                    val source = call.argument<String>("source") ?: ""
                    val output = call.argument<String>("output") ?: ""
                    Thread({
                        val ok = try {
                            App.ensureLibbox()
                            Libbox.compileRuleSet(source, output)
                            true
                        } catch (_: Throwable) {
                            false
                        }
                        runOnUiThread { result.success(ok) }
                    }, "compile-rule-set").start()
                }
                // Where the Xray program is (it is shipped as libxray.so in the native library directory).
                "xrayPath" -> result.success(java.io.File(applicationInfo.nativeLibraryDir, "libxray.so").path)
                // The "not connected" notification: shown (or removed) right away when the switch changes.
                "widgetInfo" -> {
                    // The server picked in the app (shown while disconnected) and the delay through the connection.
                    WidgetTheme.rememberServer(this, call.argument<String>("name"))
                    VpnBridge.ping = call.argument<Int>("ping")
                    runCatching { KumoWidget.refreshAll(this) }
                    result.success(null)
                }
                "idleNotification" -> {
                    if (call.argument<Boolean>("enabled") == true) {
                        IdleNotification.show(this, force = true)
                    } else {
                        IdleNotification.cancel(this)
                    }
                    result.success(null)
                }
                // Warns about a subscription that is nearly out of data or time (once per level).
                "usageCheck" -> {
                    Thread {
                        UsageAlerts.check(
                            this,
                            call.argument<String>("id") ?: "",
                            call.argument<String>("name") ?: "Subscription",
                            (call.argument<Number>("used") ?: 0).toLong(),
                            (call.argument<Number>("total") ?: 0).toLong(),
                            (call.argument<Number>("expire") ?: 0).toLong(),
                        )
                    }.start()
                    result.success(null)
                }
                "scheduleSubUpdates" -> {
                    if (call.argument<Boolean>("enabled") == true) SubUpdateJob.schedule(this) else SubUpdateJob.cancel(this)
                    result.success(null)
                }
                "setAppIcon" -> {
                    AppIcons.apply(this, call.argument<String>("id") ?: AppIcons.DEFAULT)
                    result.success(null)
                }
                // What the card of the app in the list of recent apps shows: the name and icon of the disguise
                // (the name is in the settings file; the icon is kept here, or taken from the entry that shows).
                "taskLook" -> {
                    val icon = call.argument<ByteArray>("icon")
                    val name = call.argument<String>("name") ?: ""
                    try {
                        val file = File(filesDir, "disguise_icon.png")
                        if (icon != null && icon.isNotEmpty()) file.writeBytes(icon) else file.delete()
                        val named = File(filesDir, "disguise_name.txt")
                        if (name.isNotEmpty()) named.writeText(name) else named.delete()
                    } catch (_: Exception) {
                    }
                    applyTaskLook()
                    result.success(null)
                }
                // A shortcut on the home screen with a name and an icon the user chose (the system asks to place it).
                "pinShortcut" -> {
                    val label = call.argument<String>("label") ?: ""
                    val png = call.argument<ByteArray>("icon")
                    val ok = try {
                        if (!ShortcutManagerCompat.isRequestPinShortcutSupported(this)) {
                            false
                        } else {
                            val target = Intent(this, KumoActivity::class.java).setAction(Intent.ACTION_MAIN)
                            val builder = ShortcutInfoCompat.Builder(this, "kumo-look-${System.currentTimeMillis()}")
                                .setShortLabel(label.ifBlank { "Kumo" })
                                .setIntent(target)
                            val bitmap = png?.let { BitmapFactory.decodeByteArray(it, 0, it.size) }
                            if (bitmap != null) builder.setIcon(IconCompat.createWithBitmap(bitmap))
                            ShortcutManagerCompat.requestPinShortcut(this, builder.build(), null)
                        }
                    } catch (_: Exception) {
                        false
                    }
                    result.success(ok)
                }
                // Erases everything the app keeps (see Wipe.kt) and ends the app; [keep] is the settings that stay.
                "wipe" -> {
                    val keep = try {
                        JSONObject(call.argument<String>("keep") ?: "{}")
                    } catch (_: Exception) {
                        JSONObject()
                    }
                    Thread {
                        Wipe.run(this, keep)
                        runOnUiThread {
                            result.success(true)
                            Wipe.end(this)
                        }
                    }.start()
                }
                "batteryUnrestricted" ->
                    result.success(getSystemService(PowerManager::class.java).isIgnoringBatteryOptimizations(packageName))
                "requestBatteryExemption" -> {
                    // The app does not declare the permission that opens the direct "allow" dialog,
                    // so the list of battery settings is shown, where Kumo is set to "Don't optimize".
                    try {
                        startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
                    } catch (_: Exception) {
                        startActivity(
                            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName")),
                        )
                    }
                    result.success(null)
                }
                // A connection with the OpenVPN program (see OvpnVpnService). The configuration is written for
                // the run only and removed when it ends; the login goes with the request, not to disk.
                "startOpenVpn" -> {
                    val config = call.argument<String>("config")
                    if (config.isNullOrBlank()) {
                        result.error("bad_args", "config is empty", null)
                        return@setMethodCallHandler
                    }
                    val dir = File(filesDir, "ovpn").apply { mkdirs() }
                    val file = File(dir, "run.ovpn")
                    file.writeText(config)
                    runCatching { android.system.Os.chmod(file.path, 384) }
                    val name = call.argument<String>("name") ?: ""
                    val showSpeed = call.argument<Boolean>("showSpeed") ?: true
                    val showVolume = call.argument<Boolean>("showVolume") ?: false
                    val showName = call.argument<Boolean>("showName") ?: true
                    val killSwitch = call.argument<Boolean>("killSwitch") ?: false
                    val intent = Intent(this, OvpnVpnService::class.java)
                        .putExtra(OvpnVpnService.EXTRA_CONFIG_PATH, file.path)
                        .putExtra(OvpnVpnService.EXTRA_NAME, name)
                        .putExtra(OvpnVpnService.EXTRA_USER, call.argument<String>("username"))
                        .putExtra(OvpnVpnService.EXTRA_PASSWORD, call.argument<String>("password"))
                        .putExtra(OvpnVpnService.EXTRA_KEY_PASSWORD, call.argument<String>("keyPassword"))
                        .putExtra(OvpnVpnService.EXTRA_SHOW_SPEED, showSpeed)
                        .putExtra(OvpnVpnService.EXTRA_SHOW_VOLUME, showVolume)
                        .putExtra(OvpnVpnService.EXTRA_SHOW_NAME, showName)
                        .putExtra(OvpnVpnService.EXTRA_KILL_SWITCH, killSwitch)
                        .putStringArrayListExtra(OvpnVpnService.EXTRA_INCLUDE, ArrayList(call.argument<List<String>>("include") ?: emptyList()))
                        .putStringArrayListExtra(OvpnVpnService.EXTRA_EXCLUDE, ArrayList(call.argument<List<String>>("exclude") ?: emptyList()))
                    // Not repeated by the tile, the widget or the device-startup receiver (see VpnControl).
                    File(filesDir, "last_start.json").writeText(JSONObject().put("engine", "openvpn").toString())
                    try {
                        ContextCompat.startForegroundService(this, intent)
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("start_failed", e.message, null)
                    }
                }
                "stop" -> {
                    try {
                        val service = if (VpnBridge.engine == "openvpn") OvpnVpnService::class.java else BoxVpnService::class.java
                        val action = if (VpnBridge.engine == "openvpn") OvpnVpnService.ACTION_STOP else BoxVpnService.ACTION_STOP
                        startService(Intent(this, service).setAction(action))
                    } catch (_: Exception) {
                        // The app is not allowed to start the service right now; nothing is running.
                    }
                    result.success(null)
                }
                // Apps that can be picked for per-app routing.
                "apps" -> Thread {
                    val pm = packageManager
                    val launcher = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
                    val list = pm.queryIntentActivities(launcher, 0)
                        .map { mapOf("id" to it.activityInfo.packageName, "label" to it.loadLabel(pm).toString()) }
                        .filter { it["id"] != packageName }
                        .distinctBy { it["id"] }
                        .sortedBy { it["label"]!!.lowercase() }
                    runOnUiThread { result.success(list) }
                }.start()
                // The launcher icon of one app as PNG bytes (drawn small: it is only a list thumbnail).
                "appIcon" -> {
                    val id = call.argument<String>("id") ?: ""
                    Thread {
                        val png = try {
                            val drawable = packageManager.getApplicationIcon(id)
                            val size = 96
                            val bitmap = android.graphics.Bitmap.createBitmap(size, size, android.graphics.Bitmap.Config.ARGB_8888)
                            val canvas = android.graphics.Canvas(bitmap)
                            drawable.setBounds(0, 0, size, size)
                            drawable.draw(canvas)
                            val out = java.io.ByteArrayOutputStream()
                            bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, out)
                            out.toByteArray()
                        } catch (_: Exception) {
                            null
                        }
                        runOnUiThread { result.success(png) }
                    }.start()
                }
                // Opens a link in whatever app handles it (tg:// proxy links open Telegram).
                "openUrl" -> {
                    val ok = try {
                        startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(call.argument<String>("url") ?: "")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                        true
                    } catch (_: Exception) {
                        false
                    }
                    result.success(ok)
                }
                // CPU types this phone can run, best first (used to pick the matching update).
                "abis" -> result.success(Build.SUPPORTED_ABIS.toList())
                // A television (a box or a set with Android TV, Google TV, Fire TV): it is used with a remote.
                "isTv" -> result.success(isTelevision())
                // For the anonymous usage ping: the id Android keeps for this phone and app signing
                // key (it is hashed before it leaves the app), and the Android version.
                "androidId" -> result.success(
                    try {
                        Settings.Secure.getString(contentResolver, Settings.Secure.ANDROID_ID)
                    } catch (_: Exception) {
                        null
                    },
                )
                // The facts the usage ping lists about the phone. Raw: the app picks and checks them.
                "deviceInfo" -> {
                    fun prop(name: String): String? = try {
                        val p = ProcessBuilder("getprop", name).redirectErrorStream(true).start()
                        val v = p.inputStream.bufferedReader().readText().trim()
                        p.waitFor()
                        v.ifEmpty { null }
                    } catch (_: Exception) {
                        null
                    }
                    result.success(
                        mapOf(
                            "brand" to Build.MANUFACTURER,
                            "model" to Build.MODEL,
                            "abi" to Build.SUPPORTED_ABIS.firstOrNull(),
                            "tz" to java.util.TimeZone.getDefault().id,
                            "oneui" to prop("ro.build.version.oneui"),
                            "miui" to prop("ro.miui.ui.version.name"),
                            "mios" to prop("ro.mi.os.version.name"),
                            "oplus" to prop("ro.build.version.oplusrom"),
                        ),
                    )
                }
                "osRelease" -> result.success("${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})")
                // Whether Kumo may install apps, and the system screen where the user allows it.
                "canInstall" -> result.success(
                    Build.VERSION.SDK_INT < Build.VERSION_CODES.O || packageManager.canRequestPackageInstalls(),
                )
                "allowInstall" -> {
                    try {
                        startActivity(
                            Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName"))
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                        )
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                // Opens the system installer for a downloaded update.
                "installApk" -> {
                    try {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !packageManager.canRequestPackageInstalls()) {
                            startActivity(
                                Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName"))
                                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                            )
                            result.success("permission")
                        } else {
                            val uri = androidx.core.content.FileProvider.getUriForFile(
                                this, "$packageName.fileprovider", File(call.argument<String>("path") ?: ""),
                            )
                            startActivity(
                                Intent(Intent.ACTION_VIEW)
                                    .setDataAndType(uri, "application/vnd.android.package-archive")
                                    .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK),
                            )
                            result.success("ok")
                        }
                    } catch (e: Exception) {
                        result.success("failed")
                    }
                }
                "filesDir" -> result.success(filesDir.path)
                "vpnSettings" -> {
                    startActivity(Intent(Settings.ACTION_VPN_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    result.success(null)
                }
                "status" -> result.success(mapOf("status" to VpnBridge.status, "error" to VpnBridge.lastError, "standby" to VpnBridge.standby))
                // Tiny key/value store (a file per key in the app's private dir).
                "readFile" -> {
                    result.success(Store.read(filesDir, call.argument<String>("name")!!))
                }
                "writeFile" -> {
                    Store.write(filesDir, call.argument<String>("name")!!, call.argument<String>("content") ?: "")
                    result.success(null)
                }
                "moveAside" -> {
                    Store.moveAside(filesDir, call.argument<String>("name")!!)
                    result.success(null)
                }
                // What the core wrote when it ended the app the last time (a Go panic or a fatal error): the end of
                // its error output, or null when there is none. The output of the run before this one is kept by
                // libbox as stderr.log.old; before libbox is set up in this run it is still stderr.log.
                "coreCrash" -> {
                    val text = runCatching {
                        val core = File(filesDir, "core")
                        listOf(File(core, "stderr.log.old"), File(core, "stderr.log"))
                            .filter { it.exists() && it.length() > 0 }
                            .map { it.readText() }
                            .firstOrNull { "goroutine " in it && ("panic" in it || "fatal error" in it || "signal " in it) }
                            ?.take(12000)
                    }.getOrNull()
                    result.success(text)
                }
                "lastDelayError" -> result.success(lastDelayError)
                "takeCoreLog" -> result.success(VpnBridge.takeCoreLog())
                "clearCoreCrash" -> {
                    runCatching {
                        val core = File(filesDir, "core")
                        File(core, "stderr.log.old").delete()
                        // The file of this run stays open by the core: it is emptied, not deleted, and only when
                        // it is the one that holds a trace.
                        File(core, "stderr.log").takeIf { it.exists() && "goroutine " in it.readText() }?.writeText("")
                    }
                    result.success(null)
                }
                "deleteFile" -> {
                    Store.delete(filesDir, call.argument<String>("name")!!)
                    result.success(null)
                }
                "takeUsage" -> result.success(PendingUsage.take())
                else -> result.notImplemented()
            }
        }

        EventChannel(messenger, "kumo/traffic").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    VpnBridge.trafficListener = { up, down, upTotal, downTotal ->
                        events.success(listOf(up, down, upTotal, downTotal))
                    }
                    // What was counted while the screen was closed is saved for the app to read.
                    Thread { PendingUsage.flush() }.start()
                }

                override fun onCancel(arguments: Any?) {
                    VpnBridge.trafficListener = null
                }
            },
        )

        EventChannel(messenger, "kumo/status").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    VpnBridge.listener = { status, error ->
                        events.success(mapOf("status" to status, "error" to error, "standby" to VpnBridge.standby))
                    }
                    events.success(mapOf("status" to VpnBridge.status, "error" to VpnBridge.lastError, "standby" to VpnBridge.standby))
                }

                override fun onCancel(arguments: Any?) {
                    VpnBridge.listener = null
                }
            },
        )
    }

    /** Saves the configuration of the proxy-only mode and returns the extras that name it (null when empty). */
    private fun writeStandby(config: String?, xrayConfig: String?, xrayPort: Int, proxyPort: Int): android.os.Bundle? {
        if (config.isNullOrBlank()) return null
        val file = File(filesDir, "standby_config.json")
        file.writeText(config)
        val extras = android.os.Bundle()
        extras.putString(BoxVpnService.EXTRA_STANDBY_PATH, file.path)
        extras.putInt(BoxVpnService.EXTRA_PROXY_PORT, proxyPort)
        if (!xrayConfig.isNullOrBlank() && xrayPort > 0) {
            val x = File(filesDir, "standby_xray.json")
            x.writeText(xrayConfig)
            extras.putString(BoxVpnService.EXTRA_STANDBY_XRAY_PATH, x.path)
            extras.putInt(BoxVpnService.EXTRA_STANDBY_XRAY_PORT, xrayPort)
        }
        return extras
    }

    private fun prepare(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) !=
            android.content.pm.PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), REQUEST_NOTIFICATIONS)
        }
        val intent = VpnService.prepare(this)
        if (intent == null) {
            result.success(true)
            return
        }
        pendingPrepare?.success(false)
        pendingPrepare = result
        @Suppress("DEPRECATION")
        startActivityForResult(intent, REQUEST_VPN)
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == REQUEST_VPN) {
            pendingPrepare?.success(resultCode == Activity.RESULT_OK)
            pendingPrepare = null
            return
        }
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
    }
}
