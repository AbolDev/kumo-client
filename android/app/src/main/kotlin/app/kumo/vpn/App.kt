package app.kumo.vpn

import android.app.ActivityManager
import android.app.Application
import android.content.Context
import android.net.ConnectivityManager
import android.os.Build
import androidx.core.content.getSystemService
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.SetupOptions
import java.io.File
import java.util.Locale

class App : Application() {
    override fun attachBaseContext(base: Context?) {
        super.attachBaseContext(base)
        instance = this
    }

    override fun onCreate() {
        super.onCreate()
        // Keeps the last crash in files/crash.log so it can be inspected without adb.
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, error ->
            runCatching {
                File(filesDir, "crash.log").writeText(
                    "${java.util.Date()} ${thread.name}\n${android.util.Log.getStackTraceString(error)}",
                )
            }
            previous?.uncaughtException(thread, error)
        }
    }

    companion object {
        lateinit var instance: App
        val connectivity by lazy { instance.getSystemService<ConnectivityManager>()!! }
        val packageMgr by lazy { instance.packageManager }

        private var libboxReady = false

        /** libbox must be configured once per process before the first CommandServer. */
        @Synchronized
        fun ensureLibbox() {
            if (libboxReady) return
            val base = instance.filesDir.also { it.mkdirs() }
            val working = (instance.getExternalFilesDir(null) ?: instance.filesDir).also { it.mkdirs() }
            val temp = instance.cacheDir.also { it.mkdirs() }
            Libbox.setLocale(Locale.getDefault().toLanguageTag().replace("-", "_"))
            Libbox.setup(
                SetupOptions().also {
                    it.basePath = base.path
                    it.workingPath = working.path
                    it.tempPath = temp.path
                    // golang/go#68760: needed on Android 9+ (and 7.x)
                    it.fixAndroidStack = Build.VERSION.SDK_INT >= Build.VERSION_CODES.P ||
                        Build.VERSION.SDK_INT in Build.VERSION_CODES.N..Build.VERSION_CODES.N_MR1
                    it.logMaxLines = 100 // the core's log is not shown anywhere
                    it.debug = false
                },
            )
            Libbox.redirectStderr(File(working, "stderr.log").path)
            // On phones short of memory the core collects garbage much more often (more CPU,
            // far less RAM); elsewhere the default keeps the CPU and battery cost low.
            val am = instance.getSystemService<ActivityManager>()!!
            val mem = ActivityManager.MemoryInfo().also { am.getMemoryInfo(it) }
            Libbox.setMemoryLimit(am.isLowRamDevice || mem.totalMem < 3L * 1024 * 1024 * 1024)
            libboxReady = true
        }
    }
}
