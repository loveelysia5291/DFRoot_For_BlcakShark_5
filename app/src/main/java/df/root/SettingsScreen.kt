package df.root

import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import top.yukonga.miuix.kmp.basic.BasicComponent
import top.yukonga.miuix.kmp.basic.Card
import top.yukonga.miuix.kmp.basic.HorizontalDivider
import top.yukonga.miuix.kmp.basic.Icon
import top.yukonga.miuix.kmp.basic.SmallTitle
import top.yukonga.miuix.kmp.basic.Switch
import top.yukonga.miuix.kmp.basic.Text
import top.yukonga.miuix.kmp.theme.MiuixTheme

/**
 * Compose/MIUIX replacement for the old SettingsActivity +
 * PreferenceFragment. It edits the same two device-protected preferences the
 * deploy script reads (`soft_reboot`, `disable_modules`) and the same
 * BootReceiver enabled state used by "Start at Boot".
 */
@Composable
fun SettingsScreen() {
    val context = LocalContext.current
    val prefs = remember(context) {
        context.createDeviceProtectedStorageContext()
            .getSharedPreferences(ExploitRunner.PREFS_NAME, Context.MODE_PRIVATE)
    }

    var bootStart by remember { mutableStateOf(isBootReceiverEnabled(context)) }
    var softReboot by remember {
        mutableStateOf(prefs.getBoolean(ExploitRunner.PREF_SOFT_REBOOT, false))
    }
    var disableModules by remember {
        mutableStateOf(prefs.getBoolean(ExploitRunner.PREF_DISABLE_MODULES, false))
    }
    // displayVersion() opens the installed manager APK; do not repeat that on
    // every switch toggle.
    val magiskVersion = remember { ExploitRunner.displayVersion(context) }
    val kernelVersion = remember { System.getProperty("os.version", "?") }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(bottom = 24.dp),
    ) {
        SmallTitle("部署")

        Card(modifier = Modifier.padding(horizontal = 16.dp)) {
            SettingSwitchRow(
                icon = DfIcons.Play,
                title = "開機自動執行",
                summary = "裝置開機後自動執行 DFRoot，不必手動開啟 App。",
                checked = bootStart,
            ) { checked ->
                bootStart = checked
                setBootReceiverEnabled(context, checked)
            }

            HorizontalDivider()

            SettingSwitchRow(
                icon = DfIcons.Refresh,
                title = "自動軟重啟（LSPosed）",
                summary = "開啟：部署後準備 LSPosed 並自動重新啟動 zygote。\n"
                    + "關閉：只準備 LSPosed 原則與管理器；請自行啟動 "
                    + "Zygisk Next／lspd，再重新啟動 zygote。",
                checked = softReboot,
            ) { checked ->
                softReboot = checked
                prefs.edit().putBoolean(ExploitRunner.PREF_SOFT_REBOOT, checked).apply()
            }

            HorizontalDivider()

            SettingSwitchRow(
                icon = DfIcons.Block,
                title = "停用所有模組（本次）",
                summary = "模組導致無法開機時開啟。下一次部署會停用所有 Magisk 模組，"
                    + "並在部署完成後自動恢復。",
                checked = disableModules,
            ) { checked ->
                disableModules = checked
                prefs.edit().putBoolean(ExploitRunner.PREF_DISABLE_MODULES, checked).apply()
            }
        }

        SmallTitle("關於")

        Card(modifier = Modifier.padding(horizontal = 16.dp)) {
            BasicComponent(
                title = "版本",
                summary = BuildConfig.VERSION_NAME,
            )
            HorizontalDivider()
            BasicComponent(
                title = "Magisk 版本",
                summary = magiskVersion,
            )
            HorizontalDivider()
            BasicComponent(
                title = "核心版本",
                summary = kernelVersion,
            )
            HorizontalDivider()
            BasicComponent(
                title = "注入方式",
                summary = "Magisk（LKM，kernel 4.19）",
            )
        }

        Text(
            text = "設定儲存在裝置保護儲存空間，開機階段可直接讀取。",
            style = MiuixTheme.textStyles.footnote2,
            color = MiuixTheme.colorScheme.onSurfaceVariantSummary,
            modifier = Modifier.padding(horizontal = 32.dp, vertical = 16.dp),
        )
    }
}

@Composable
private fun SettingSwitchRow(
    icon: ImageVector,
    title: String,
    summary: String,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
) {
    BasicComponent(
        title = title,
        summary = summary,
        modifier = Modifier.toggleable(
            value = checked,
            onValueChange = onCheckedChange,
            role = Role.Switch,
        ),
        startAction = {
            Icon(
                imageVector = icon,
                contentDescription = null,
                modifier = Modifier.size(24.dp),
                tint = MiuixTheme.colorScheme.primary,
            )
        },
        endActions = {
            // The whole row toggles; the switch itself stays non-interactive so
            // a tap cannot fire both handlers.
            Switch(checked = checked, onCheckedChange = null)
        },
    )
}

private fun isBootReceiverEnabled(context: Context): Boolean {
    val component = ComponentName(context, BootReceiver::class.java)
    return context.packageManager.getComponentEnabledSetting(component) ==
        PackageManager.COMPONENT_ENABLED_STATE_ENABLED
}

private fun setBootReceiverEnabled(context: Context, enabled: Boolean) {
    val component = ComponentName(context, BootReceiver::class.java)
    context.packageManager.setComponentEnabledSetting(
        component,
        if (enabled) {
            PackageManager.COMPONENT_ENABLED_STATE_ENABLED
        } else {
            PackageManager.COMPONENT_ENABLED_STATE_DISABLED
        },
        PackageManager.DONT_KILL_APP,
    )
}
