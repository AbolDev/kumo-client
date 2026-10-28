package app.kumo.vpn

import android.app.Activity
import android.content.Intent
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

class MainActivity : FlutterActivity() {
    private companion object {
        const val REQUEST_VPN = 1001
        const val REQUEST_NOTIFICATIONS = 1002
    }

    private var pendingPrepare: MethodChannel.Result? = null

    // Each delay test starts its own core, so only a few run at once.
    private val delayPool = Executors.newFixedThreadPool(12)

    override fun onDestroy() {
        // Without this the 12 test threads outlive the screen and pile up each time it is rebuilt.
        if (isFinishing) delayPool.shutdownNow()
        super.onDestroy()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        MethodChannel(messenger, "kumo/control").setMethodCallHandler { call, result ->
            when (call.method) {
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
                            } catch (_: Throwable) {
                                -1
                            } finally {
                                VpnBridge.exitDelay()
                            }
                        }
                        runOnUiThread { result.success(ms) }
                    }
                }
                // Where the Xray program is (it is shipped as libxray.so in the native library directory).
                "xrayPath" -> result.success(java.io.File(applicationInfo.nativeLibraryDir, "libxray.so").path)
                // The "not connected" notification: shown (or removed) right away when the switch changes.
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
                "stop" -> {
                    try {
                        startService(Intent(this, BoxVpnService::class.java).setAction(BoxVpnService.ACTION_STOP))
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
