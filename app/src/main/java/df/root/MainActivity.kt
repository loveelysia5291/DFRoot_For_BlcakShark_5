package df.root

import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import java.io.File
import java.util.concurrent.Executor
import java.util.concurrent.Executors

/**
 * Compose + MIUIX host for DFRoot.
 *
 * The deploy itself still runs through [ExploitRunner] exactly as before; this
 * class only replaces the old single-button XML screen with a three-page
 * Compose UI (home / log / settings) that can be swiped.
 *
 * There is no longer any "import a Magisk APK" flow: the deploy reads the
 * installed manager's APK directly and extracts the binaries from it, so the
 * app only has to start the runner and show progress.
 */
class MainActivity : ComponentActivity(), IReporter, IProgress {

    private val mMain = Handler(Looper.getMainLooper())
    private val mExec: Executor = Executors.newSingleThreadExecutor()


    /* ------------------------------------------------------------- state --- */

    private var status by mutableStateOf("")
    private var progress by mutableFloatStateOf(0f)
    private var running by mutableStateOf(false)
    private var rooted by mutableStateOf(false)
    private var hooked by mutableStateOf(false)
    private var managerAvailable by mutableStateOf(false)
    private var output by mutableStateOf("")
    private val logBuilder = StringBuilder()

    /* ----------------------------------------------------------- lifecycle -- */

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        updateRunButton()

        setContent {
            DfRootApp(
                state = DfRootUiState(
                    status = status,
                    progress = progress,
                    running = running,
                    rooted = rooted,
                    hooked = hooked,
                    managerAvailable = managerAvailable,
                    output = output,
                ),
                onLaunchRoot = { startRoot() },
                onOpenMagisk = { ExploitRunner.openManager(this, this) },
                onUpgradeMagisk = {
                    // Only a confirmed "升級 Magisk 版本" may re-extract from the
                    // installed manager APK; ExploitRunner turns this into
                    // upgrade.request on the next run.
                    getSharedPreferences(ExploitRunner.PREFS_NAME, MODE_PRIVATE)
                        .edit()
                        .putBoolean(ExploitRunner.PREF_UPGRADE_MAGISK, true)
                        .apply()
                    startRoot()
                },
                onOpenRecords = { },
                onSaveLog = { saveLogToDownloads() },
                onClearLog = {
                    logBuilder.setLength(0)
                    output = ""
                },
            )
        }
    }

    override fun onResume() {
        super.onResume()
        // Re-read /proc and the deploy marker after the user returns from the
        // settings screen or the Magisk manager.
        if (!running) updateRunButton()
    }

    /* ------------------------------------------------------------ reporter -- */

    override fun report(msg: String) {
        Log.i(TAG, msg.trim())
        mMain.post {
            logBuilder.append(msg)
            output = logBuilder.toString()
        }
    }

    override fun progress(percent: Int) {
        val p = percent.coerceIn(0, 100)
        mMain.post {
            progress = p / 100f
            status = "執行中… $p%"
        }
    }

    /* ---------------------------------------------------------------- run -- */

    private fun startRoot() {
        // Single-flight guard: the runner must not be entered twice.
        if (running) return
        running = true
        progress = 0f
        logBuilder.setLength(0)
        output = ""
        status = "執行中… 0%"
        mExec.execute { runExploit() }
    }

    private fun runExploit() {
        try {
            val rc = ExploitRunner.run(createDeviceProtectedStorageContext(), this)
            val msg = when (rc) {
                0 -> "DFRoot：成功"
                1 -> "DFRoot：失敗 — daemon／部署失敗（請查看紀錄）"
                2 -> "DFRoot：失敗 — 請檢查 logcat 與 dmesg"
                else -> "DFRoot：失敗 — 檔案修補失敗"
            }
            mMain.post {
                Toast.makeText(this, msg, Toast.LENGTH_LONG).show()
                status = msg
                if (rc == 0) {
                    progress = 1f
                    rooted = true
                    managerAvailable = true
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "exploit exception", e)
            report("\n例外：$e\n")
        } finally {
            mMain.post {
                running = false
                // Keep the SUCCESS/error line on screen; onResume refreshes the
                // summary when the user comes back to the app.
                updateRunButton(keepStatus = true)
            }
        }
    }

    private fun updateRunButton(keepStatus: Boolean = false) {
        hooked = File("/proc/dfroot_su").exists()
        rooted = ExploitRunner.isDeployedThisBoot()
        managerAvailable = ExploitRunner.managerPackage() != null
        // A successful deploy survives until the next boot, so the bar must not
        // fall back to 0% when the app is reopened.
        if (rooted) progress = 1f
        if (running || keepStatus) return
        status = when {
            hooked -> "Hook 運作中（部署進行中）"
            rooted -> "Magisk su 已啟用，無需再次執行"
            else -> "Magisk ${ExploitRunner.displayVersion(this)}｜核心：" +
                System.getProperty("os.version", "?")
        }
    }

    /* ----------------------------------------------------------- save log -- */

    /**
     * Writes the on-screen run log to Download/ so it can be pulled without
     * root or adb. The deploy also copies its own log to
     * /data/local/tmp/dfroot-deploy.log (mode 644, readable by shell).
     */
    private fun saveLogToDownloads() {
        val body = output
        if (body.isEmpty()) {
            Toast.makeText(this, "尚無紀錄內容", Toast.LENGTH_SHORT).show()
            return
        }
        val name = "dfroot-log-" + System.currentTimeMillis() + ".txt"
        try {
            val cv = android.content.ContentValues().apply {
                put(android.provider.MediaStore.MediaColumns.DISPLAY_NAME, name)
                put(android.provider.MediaStore.MediaColumns.MIME_TYPE, "text/plain")
                put(
                    android.provider.MediaStore.MediaColumns.RELATIVE_PATH,
                    android.os.Environment.DIRECTORY_DOWNLOADS,
                )
            }
            val uri = contentResolver.insert(
                android.provider.MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                cv,
            ) ?: throw IllegalStateException("MediaStore 未回傳檔案 URI")
            contentResolver.openOutputStream(uri)?.use { os ->
                os.write(body.toByteArray(Charsets.UTF_8))
            }
            Toast.makeText(this, "已儲存到 Download/$name", Toast.LENGTH_LONG).show()
        } catch (e: Exception) {
            Toast.makeText(this, "儲存失敗：$e", Toast.LENGTH_LONG).show()
        }
    }

    private companion object {
        private const val TAG = "dfroot"
    }
}
