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
                    // Remembered so the device-startup receiver can repeat this connection.
                    File(filesDir, "last_start.json").writeText(
                        JSONObject()
                            .put("names", org.json.JSONArray(names))
                            .put("showSpeed", showSpeed)
                            .put("showVolume", showVolume)
                            .put("showName", showName)
                            .put("killSwitch", call.argument<Boolean>("killSwitch") ?: false)
                            .put("xrayPort", if (xrayConfig.isNullOrBlank()) 0 else (call.argument<Int>("xrayPort") ?: 0))
                            .toString(),
                    )
                    try {
                        ContextCompat.startForegroundService(this, intent)
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("start_failed", e.message, null)
                    }
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
                    startActivity(
                        Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:$packageName")),
                    )
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
                "status" -> result.success(mapOf("status" to VpnBridge.status, "error" to VpnBridge.lastError))
                // Tiny key/value store (a file per key in the app's private dir).
                "readFile" -> {
                    val f = File(filesDir, call.argument<String>("name")!!)
                    result.success(if (f.exists()) f.readText() else null)
                }
                "writeFile" -> {
                    File(filesDir, call.argument<String>("name")!!).writeText(call.argument<String>("content") ?: "")
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        EventChannel(messenger, "kumo/traffic").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    VpnBridge.trafficListener = { up, down, upTotal, downTotal ->
                        events.success(listOf(up, down, upTotal, downTotal))
                    }
                }

                override fun onCancel(arguments: Any?) {
                    VpnBridge.trafficListener = null
                }
            },
        )

        EventChannel(messenger, "kumo/status").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    VpnBridge.listener = { status, error -> events.success(mapOf("status" to status, "error" to error)) }
                    events.success(mapOf("status" to VpnBridge.status, "error" to VpnBridge.lastError))
                }

                override fun onCancel(arguments: Any?) {
                    VpnBridge.listener = null
                }
            },
        )
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
