package app.kumo.vpn

import android.os.Handler
import android.os.Looper

/** Process-wide VPN state shared between the service and the Flutter channel. */
object VpnBridge {
    const val STOPPED = "stopped"
    const val STARTING = "starting"
    const val STARTED = "started"
    const val STOPPING = "stopping"
    const val ERROR = "error"

    @Volatile
    var status: String = STOPPED
        private set

    @Volatile
    var lastError: String? = null
        private set

    /** True while the service keeps only the local proxy running (no tunnel). */
    @Volatile
    var standby: Boolean = false
        private set

    fun setStandby(on: Boolean) {
        if (standby == on) return
        standby = on
        main.post { listener?.invoke(status, lastError) }
    }

    var listener: ((String, String?) -> Unit)? = null

    /** Extra listeners (the Quick Settings tile). */
    val observers = java.util.concurrent.CopyOnWriteArrayList<(String, String?) -> Unit>()

    /** Called every second while connected: speeds and totals in bytes. */
    var trafficListener: ((Long, Long, Long, Long) -> Unit)? = null

    private val main = Handler(Looper.getMainLooper())

    /** The server in use, for the widgets. */
    @Volatile
    var serverName: String? = null

    fun traffic(up: Long, down: Long, upTotal: Long, downTotal: Long, usageName: String) {
        WidgetFeed.onTraffic(up, down, upTotal, downTotal)
        if (trafficListener == null) {
            // The app's screen is closed: nobody counts the usage but us.
            PendingUsage.add(upTotal, downTotal, usageName)
            return
        }
        PendingUsage.baseline(upTotal, downTotal)
        main.post { trafficListener?.invoke(up, down, upTotal, downTotal) }
    }

    // Delay tests start their own cores. They must not overlap with the tunnel being
    // started or stopped, so those two close this gate and wait for running tests.
    private val gate = Object()
    private var runningDelays = 0
    private var closers = 0

    fun enterDelay(): Boolean = synchronized(gate) {
        if (closers > 0) false else { runningDelays++; true }
    }

    fun exitDelay() = synchronized(gate) {
        runningDelays--
        gate.notifyAll()
    }

    fun closeGate() = synchronized(gate) {
        closers++
        val end = System.currentTimeMillis() + 15_000
        while (runningDelays > 0) {
            val left = end - System.currentTimeMillis()
            if (left <= 0) break
            gate.wait(left)
        }
    }

    fun openGate() = synchronized(gate) { closers-- }

    fun update(newStatus: String, error: String? = null) {
        status = newStatus
        lastError = error
        if (newStatus == STOPPED || newStatus == ERROR) {
            PendingUsage.reset()
            WidgetFeed.reset()
            serverName = null
        }
        main.post {
            listener?.invoke(newStatus, error)
            observers.forEach { it(newStatus, error) }
            runCatching { KumoWidget.refreshAll(App.instance) }
        }
    }
}
