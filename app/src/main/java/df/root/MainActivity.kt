package df.root

import android.content.Context
import android.content.pm.ApplicationInfo
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
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
 * The deploy itself still runs through [ExploitRunner]; this
 * class hosts the Compose UI that supports Magisk on kernel 4.19
 * and official KernelSU on kernel 5.10+.
 */
class MainActivity : ComponentActivity(), IReporter, IProgress {

    private val mMain = Handler(Looper.getMainLooper())
    private val mExec: Executor = Executors.newSingleThreadExecutor()

    private val pickApkLauncher = registerForActivityResult(ActivityResultContracts.GetContent()) { uri ->
        uri?.let { handleImportApk(it) }
    }

    private fun handleImportApk(uri: android.net.Uri) {
        mExec.execute {
            try {
                val deCtx = createDeviceProtectedStorageContext()
                deCtx.cacheDir.mkdirs()
                val tempApk = File(deCtx.cacheDir, "temp_import.apk")
                contentResolver.openInputStream(uri)?.use { input ->
                    java.io.FileOutputStream(tempApk).use { output ->
                        input.copyTo(output)
                    }
                }
                val pkg = ExploitRunner.importManagerApk(deCtx, tempApk, this)
                tempApk.delete()
                mMain.post {
                    Toast.makeText(this, "成功導入 Magisk APK ($pkg)", Toast.LENGTH_LONG).show()
                    updateRunButton()
                }
            } catch (e: Exception) {
                Log.e(TAG, "import APK failed", e)
                report("\n導入失敗：$e\n")
                mMain.post {
                    Toast.makeText(this, "導入失敗: ${e.message}", Toast.LENGTH_LONG).show()
                }
            }
        }
    }

    /* ------------------------------------------------------------- state --- */

    private var status by mutableStateOf("")
    private var progress by mutableFloatStateOf(0f)
    private var running by mutableStateOf(false)
    private var rooted by mutableStateOf(false)
    private var hooked by mutableStateOf(false)
    private var managerAvailable by mutableStateOf(false)
    private var selectedSuManager by mutableStateOf<String?>(null)
    private var suManagerList by mutableStateOf<List<SuManagerItem>>(emptyList())
    private var output by mutableStateOf("")
    private val logBuilder = StringBuilder()

    /* ----------------------------------------------------------- lifecycle -- */

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        refreshSuManagers()
        updateRunButton()

        setContent {
            DfRootApp(
                state = DfRootUiState(
                    status = status,
                    progress = progress,
                    running = running,
                    rooted = rooted,
                    hooked = hooked,
                    isKernel419 = ExploitRunner.isKernel419(),
                    managerAvailable = managerAvailable,
                    selectedSuManager = selectedSuManager,
                    suManagerList = suManagerList,
                    output = output,
                ),
                onLaunchRoot = { startRoot() },
                onOpenManager = { ExploitRunner.openManager(this, this) },
                onUpgradeMagisk = {
                    getSharedPreferences(ExploitRunner.PREFS_NAME, MODE_PRIVATE)
                        .edit()
                        .putBoolean(ExploitRunner.PREF_UPGRADE_MAGISK, true)
                        .apply()
                    startRoot()
                },
                onImportMagisk = {
                    pickApkLauncher.launch("application/vnd.android.package-archive")
                },
                onSelectSuManager = { pkg -> onSelectSuManager(pkg) },
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
        if (!running) {
            refreshSuManagers()
            updateRunButton()
        }
    }

    private fun refreshSuManagers() {
        if (ExploitRunner.isKernel419()) return
        val pm = packageManager
        val list = mutableListOf<SuManagerItem>()
        for (ai in pm.getInstalledApplications(0)) {
            if ((ai.flags and ApplicationInfo.FLAG_SYSTEM) != 0) continue
            if (!ExploitRunner.hasKsud(ai)) continue
            val label = pm.getApplicationLabel(ai).toString()
            list.add(SuManagerItem(packageName = ai.packageName, label = label))
        }
        list.sortBy { it.label.lowercase() }
        suManagerList = list

        val prefs = createDeviceProtectedStorageContext()
            .getSharedPreferences(ExploitRunner.PREFS_NAME, Context.MODE_PRIVATE)
        val saved = prefs.getString(ExploitRunner.PREF_SU_MANAGER, null)
        val found = list.any { it.packageName == saved }
        if (found) {
            selectedSuManager = saved
        } else if (list.isNotEmpty()) {
            selectedSuManager = list[0].packageName
            prefs.edit().putString(ExploitRunner.PREF_SU_MANAGER, selectedSuManager).apply()
        } else {
            selectedSuManager = null
            if (saved != null) {
                prefs.edit().remove(ExploitRunner.PREF_SU_MANAGER).apply()
            }
        }
    }

    private fun onSelectSuManager(pkg: String) {
        selectedSuManager = pkg
        createDeviceProtectedStorageContext()
            .getSharedPreferences(ExploitRunner.PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(ExploitRunner.PREF_SU_MANAGER, pkg)
            .apply()
        updateRunButton()
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
        if (!ExploitRunner.isKernel419() && selectedSuManager == null) {
            Toast.makeText(this, "請先選擇 KernelSU 管理器", Toast.LENGTH_SHORT).show()
            return
        }
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
            val is419 = ExploitRunner.isKernel419()
            val msg = when (rc) {
                0 -> "DFRoot：成功"
                1 -> if (is419) "DFRoot：失敗 — daemon／部署失敗（請查看紀錄）" else "DFRoot：失敗 — ksud 非零退出"
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
                } else {
                    rooted = false
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "exploit exception", e)
            report("\n例外：$e\n")
            mMain.post {
                status = "DFRoot：失敗 — 例外：${e.message}"
                rooted = false
            }
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
        val is419 = ExploitRunner.isKernel419()
        hooked = File("/proc/dfroot_su").exists()
        rooted = ExploitRunner.isDeployedThisBoot()
        managerAvailable = if (is419) {
            ExploitRunner.managerPackage() != null
        } else {
            selectedSuManager != null
        }
        // A successful deploy survives until the next boot, so the bar must not
        // fall back to 0% when the app is reopened.
        if (rooted) progress = 1f
        if (running || keepStatus) return
        status = when {
            hooked -> "Hook 運作中（部署進行中）"
            rooted -> if (is419) "Magisk su 已啟用，無需再次執行" else "KernelSU 已啟用，無需再次執行"
            is419 -> "Magisk ${ExploitRunner.displayVersion(this)}｜核心：" +
                System.getProperty("os.version", "?")
            else -> "KernelSU｜核心：" + System.getProperty("os.version", "?")
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
