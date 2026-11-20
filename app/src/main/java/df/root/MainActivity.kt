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
import java.util.concurrent.Executor
import java.util.concurrent.Executors

/**
 * Compose + MIUIX host for DFRoot with KernelSU.
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
                onOpenManager = { ExploitRunner.openManager(this, this) },
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
                0 -> "DFRoot: 成功"
                1 -> "DFRoot: ksud 非零退出，請查看日誌"
                2 -> "DFRoot: 失敗，請檢查日誌"
                else -> "DFRoot: 失敗，檔案修補錯誤"
            }
            mMain.post {
                Toast.makeText(this, msg, Toast.LENGTH_LONG).show()
                status = msg
                if (rc == 0) {
                    progress = 1f
                    rooted = true
                    managerAvailable = true
                } else {
                    rooted = false
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "exploit exception", e)
            report("\n例外: $e\n")
            mMain.post {
                status = "DFRoot: 失敗: ${e.message}"
                rooted = false
            }
        } finally {
            mMain.post {
                running = false
                updateRunButton(keepStatus = true)
            }
        }
    }

    private fun updateRunButton(keepStatus: Boolean = false) {
        hooked = ExploitRunner.isHooked()
        rooted = ExploitRunner.isDeployedThisBoot()
        managerAvailable = ExploitRunner.findSuManager(this) != null

        if (rooted) progress = 1f
        if (running || keepStatus) return
        status = when {
            hooked -> "Hook 已生效，核心模組已載入"
            rooted -> "KernelSU 已就緒，無需重複執行"
            else -> "KernelSU ${ExploitRunner.displayVersion(this)} · 核心 " +
                System.getProperty("os.version", "?")
        }
    }

    /* ----------------------------------------------------------- save log -- */

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
            ) ?: throw IllegalStateException("MediaStore 無法建立檔案 URI")
            contentResolver.openOutputStream(uri)?.use { os ->
                os.write(body.toByteArray(Charsets.UTF_8))
            }
            Toast.makeText(this, "已儲存至 Download/$name", Toast.LENGTH_LONG).show()
        } catch (e: Exception) {
            Toast.makeText(this, "儲存失敗: $e", Toast.LENGTH_LONG).show()
        }
    }

    private companion object {
        private const val TAG = "dfroot"
    }
}
