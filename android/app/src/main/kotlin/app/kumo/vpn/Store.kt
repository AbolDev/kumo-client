package app.kumo.vpn

import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.io.IOException

/**
 * The app's small files (servers, settings, usage). A file is saved whole or not at all: the new
 * text goes to `<name>.tmp`, is flushed to the disk, and is then moved over the old file, so a kill
 * or a power cut in the middle cannot leave half a file. The last good copy of a JSON file stays as
 * `<name>.bak`.
 */
object Store {
    fun read(dir: File, name: String): String? {
        val f = File(dir, name)
        return if (f.exists()) f.readText() else null
    }

    @Synchronized
    fun write(dir: File, name: String, content: String) {
        val f = File(dir, name)
        f.parentFile?.mkdirs()
        val tmp = File(dir, "$name.tmp")
        FileOutputStream(tmp).use {
            it.write(content.toByteArray(Charsets.UTF_8))
            it.fd.sync()
        }
        if (name.endsWith(".json") && f.exists()) {
            try {
                JSONObject(f.readText())
                f.copyTo(File(dir, "$name.bak"), overwrite = true)
            } catch (_: Exception) {
                // the file in place is already damaged: the older .bak is the one worth keeping
            }
        }
        if (!tmp.renameTo(f)) {
            f.delete()
            if (!tmp.renameTo(f)) throw IOException("could not replace ${f.path}")
        }
    }

    /** Renames a damaged file to `<name>.broken` so a fresh one can be written without losing it. */
    @Synchronized
    fun moveAside(dir: File, name: String) {
        val f = File(dir, name)
        if (!f.exists()) return
        val target = File(dir, "$name.broken")
        target.delete()
        f.renameTo(target)
    }

    @Synchronized
    fun delete(dir: File, name: String) {
        File(dir, name).delete()
    }
}
