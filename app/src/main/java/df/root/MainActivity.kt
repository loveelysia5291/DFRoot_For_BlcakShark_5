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
 * The deploy itself still runs through [ExploitRunner]; this class hosts the
 * Compose UI. Both kernel 4.19 non-GKI and 5.10+ go through the same KernelSU
 * pipe; there is a single KSU backend and one UI.
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
    private var selectedSuManager by mutableStateOf<String?>(null)
    private var suManagerList by mutableStateOf<List<SuManagerItem>>(emptyList())
    private var managerStatus by mutableStateOf(ExploitRunner.MGR_OK)
    private var managerVersion by mutableStateOf("")
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
                    managerAvailable = managerAvailable,
                    selectedSuManager = selectedSuManager,
                    suManagerList = suManagerList,
                    managerStatus = managerStatus,
                    managerVersion = managerVersion,
                    output = output,
                ),
                onLaunchRoot = { startRoot() },
                onOpenManager = { ExploitRunner.openManager(this, this) },
                onSelectSuManager = { pkg -> onSelectSuManager(pkg) },
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
        val pm = packageManager
        val prefs = createDeviceProtectedStorageContext()
            .getSharedPreferences(ExploitRunner.PREFS_NAME, Context.MODE_PRIVATE)

        if (ExploitRunner.isKernel419()) {
            // 4.19 only accepts the official manager. Do not filter by the
            // legacy hasKsud native-lib probe: the manager may keep libksud.so
            // inside the APK when extractNativeLibs=false.
            val canonical = ExploitRunner.canonicalManager()
            val list = mutableListOf<SuManagerItem>()
            if (isInstalled(pm, canonical)) {
                val label = pm.getApplicationLabel(
                    pm.getApplicationInfo(canonical, 0)).toString()
                list.add(SuManagerItem(canonical, label))
            }
            suManagerList = list
            if (list.isNotEmpty()) {
                selectedSuManager = canonical
                prefs.edit().putString(ExploitRunner.PREF_SU_MANAGER, canonical).apply()
            } else {
                selectedSuManager = null
                prefs.edit().remove(ExploitRunner.PREF_SU_MANAGER).apply()
            }
            return
        }

        val list = mutableListOf<SuManagerItem>()
        for (ai in pm.getInstalledApplications(0)) {
            if ((ai.flags and ApplicationInfo.FLAG_SYSTEM) != 0) continue
            if (!ExploitRunner.hasKsud(ai)) continue
            val label = pm.getApplicationLabel(ai).toString()
            list.add(SuManagerItem(packageName = ai.packageName, label = label))
        }
        list.sortBy { it.label.lowercase() }
        suManagerList = list

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

    private fun isInstalled(pm: android.content.pm.PackageManager, pkg: String): Boolean {
        return try {
            pm.getApplicationInfo(pkg, 0); true
        } catch (e: android.content.pm.PackageManager.NameNotFoundException) {
            false
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
        if (selectedSuManager == null) {
            Toast.makeText(this, "請先選擇 KernelSU 管理器", Toast.LENGTH_SHORT).show()
            return
        }
        if (ExploitRunner.isKernel419()) {
            val mc = ExploitRunner.checkManager(this)
            if (mc.status == ExploitRunner.MGR_MISSING) {
                Toast.makeText(this, "請先安裝官方 KernelSU 管理器", Toast.LENGTH_LONG).show()
                return
            }
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
            val msg = when (rc) {
                0 -> "DFRoot：成功"
                1 -> "DFRoot：失敗 — 部署失敗（請查看紀錄）"
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
        hooked = File("/proc/dfroot_su").exists()
        rooted = ExploitRunner.isDeployedThisBoot()
        managerAvailable = selectedSuManager != null || ExploitRunner.managerPackage() != null

        // Version gate only applies to the 4.19 non-GKI build; GKI keeps its
        // own manager selection flow untouched.
        val mc = if (ExploitRunner.isKernel419()) ExploitRunner.checkManager(this) else null
        managerStatus = mc?.status ?: ExploitRunner.MGR_OK
        managerVersion = if (mc != null && mc.versionName != null) {
            "${mc.versionName} (${mc.versionCode})"
        } else ""
        // A successful deploy survives until the next boot, so the bar must not
        // fall back to 0% when the app is reopened.
        if (rooted) progress = 1f
        if (running || keepStatus) return
        status = when {
            hooked -> "Hook 運作中（部署進行中）"
            rooted -> "KernelSU 已啟用，無需再次執行"
            else -> "KernelSU ${ExploitRunner.displayVersion(this)}｜核心：" +
                System.getProperty("os.version", "?")
        }
    }

    private companion object {
        private const val TAG = "dfroot"
    }
}
