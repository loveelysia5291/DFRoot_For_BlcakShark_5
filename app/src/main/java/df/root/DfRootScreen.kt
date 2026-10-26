package df.root

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.tween
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.clickable
import androidx.compose.foundation.background
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.launch
import top.yukonga.miuix.kmp.basic.Button
import top.yukonga.miuix.kmp.basic.ButtonDefaults
import top.yukonga.miuix.kmp.basic.Card
import top.yukonga.miuix.kmp.basic.HorizontalDivider
import top.yukonga.miuix.kmp.basic.Icon
import top.yukonga.miuix.kmp.basic.IconButton
import top.yukonga.miuix.kmp.basic.LinearProgressIndicator
import top.yukonga.miuix.kmp.basic.ProgressIndicatorDefaults
import top.yukonga.miuix.kmp.basic.NavigationBar
import top.yukonga.miuix.kmp.basic.NavigationBarItem
import top.yukonga.miuix.kmp.basic.Scaffold
import top.yukonga.miuix.kmp.basic.SmallTopAppBar
import top.yukonga.miuix.kmp.basic.Text
import top.yukonga.miuix.kmp.basic.TextButton
import top.yukonga.miuix.kmp.overlay.OverlayDialog
import top.yukonga.miuix.kmp.theme.MiuixTheme
import top.yukonga.miuix.kmp.theme.darkColorScheme
import top.yukonga.miuix.kmp.theme.lightColorScheme
import kotlin.math.roundToInt

/** Everything the Compose tree renders; owned by [MainActivity]. */
@Immutable
data class DfRootUiState(
    val status: String = "",
    val progress: Float = 0f,
    val running: Boolean = false,
    val rooted: Boolean = false,
    val hooked: Boolean = false,
    val managerAvailable: Boolean = false,
    val output: String = "",
)

/**
 * Wraps the MIUIX theme and the three-page swipeable scaffold.
 *
 * Fixed MIUIX light/dark palette; no Monet / wallpaper colour extraction.
 *
 * All durations go through Compose's animation clock, which is driven by the
 * system animator duration scale, so turning animations off in the ROM's
 * developer options or slowing them down in Settings applies here too.
 */
@Composable
fun DfRootApp(
    state: DfRootUiState,
    onLaunchRoot: () -> Unit,
    onOpenMagisk: () -> Unit,
    onUpgradeMagisk: () -> Unit,
    onImportMagisk: () -> Unit,
    onOpenRecords: () -> Unit,
    onSaveLog: () -> Unit,
    onClearLog: () -> Unit,
) {
    val dark = isSystemInDarkTheme()
    val content: @Composable () -> Unit = {
        DfRootContent(
            state = state,
            onLaunchRoot = onLaunchRoot,
            onOpenMagisk = onOpenMagisk,
            onUpgradeMagisk = onUpgradeMagisk,
            onImportMagisk = onImportMagisk,
            onOpenRecords = onOpenRecords,
            onSaveLog = onSaveLog,
            onClearLog = onClearLog,
        )
    }
    MiuixTheme(colors = if (dark) darkColorScheme() else lightColorScheme(), content = content)
}

@Composable
private fun DfRootContent(
    state: DfRootUiState,
    onLaunchRoot: () -> Unit,
    onOpenMagisk: () -> Unit,
    onUpgradeMagisk: () -> Unit,
    onImportMagisk: () -> Unit,
    onOpenRecords: () -> Unit,
    onSaveLog: () -> Unit,
    onClearLog: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    val pager = rememberPagerState(pageCount = { 3 })
    // currentPage follows the finger, so the bar highlights what is on
    // screen rather than what was last tapped.
    val tab = pager.currentPage

    fun go(page: Int) = scope.launch { pager.animateScrollToPage(page) }

    // Back from 紀錄/設定 returns to 首頁 instead of leaving the app.
    BackHandler(enabled = pager.currentPage != 0) {
        scope.launch { pager.animateScrollToPage(0) }
    }

    Scaffold(
        topBar = {
            SmallTopAppBar(
                title = when (tab) {
                    0 -> "DFRoot"
                    1 -> "紀錄"
                    else -> "設定"
                },
                subtitle = if (tab == 0) "@diabl0w github/xda" else "",
                actions = {
                    if (tab == 1) {
                        IconButton(onClick = onSaveLog) {
                            Icon(
                                imageVector = DfIcons.Download,
                                contentDescription = "儲存紀錄",
                                modifier = Modifier.size(24.dp),
                                tint = MiuixTheme.colorScheme.onSurface,
                            )
                        }
                    }
                },
            )
        },
        bottomBar = {
            NavigationBar {
                NavigationBarItem(
                    selected = tab == 0,
                    onClick = { go(0) },
                    icon = DfIcons.Home,
                    label = "首頁",
                )
                NavigationBarItem(
                    selected = tab == 1,
                    onClick = { go(1) },
                    icon = DfIcons.Records,
                    label = "紀錄",
                )
                NavigationBarItem(
                    selected = tab == 2,
                    onClick = { go(2) },
                    icon = DfIcons.Settings,
                    label = "設定",
                )
            }
        },
    ) { innerPadding ->
        HorizontalPager(
            state = pager,
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding),
        ) { page ->
            when (page) {
                0 -> HomeScreen(
                    state = state,
                    onLaunchRoot = onLaunchRoot,
                    onOpenMagisk = onOpenMagisk,
                    onUpgradeMagisk = onUpgradeMagisk,
                    onImportMagisk = onImportMagisk,
                    onOpenRecords = { go(1) },
                    onOpenSettings = { go(2) },
                )

                1 -> RecordsScreen(
                    output = state.output,
                    onClearLog = onClearLog,
                )

                else -> SettingsScreen()
            }
        }
    }
}

/* ------------------------------------------------------------------ home -- */

@Composable
private fun HomeScreen(
    state: DfRootUiState,
    onLaunchRoot: () -> Unit,
    onOpenMagisk: () -> Unit,
    onUpgradeMagisk: () -> Unit,
    onImportMagisk: () -> Unit,
    onOpenSettings: () -> Unit,
    onOpenRecords: () -> Unit,
) {
    val colors = MiuixTheme.colorScheme
    var showUpgrade by remember { mutableStateOf(false) }

    val isSuccess = state.rooted
    val isFailed = !state.running && !state.hooked && !state.rooted &&
            (state.status.contains("失敗") || state.status.contains("failed") || state.status.contains("錯誤"))

    val targetProgress = when {
        isSuccess -> 1f
        isFailed -> state.progress.coerceAtLeast(0.05f)
        else -> state.progress
    }

    val progress by animateFloatAsState(
        targetValue = targetProgress,
        animationSpec = tween(durationMillis = 320),
        label = "deploy-progress",
    )

    val headlineText = when {
        isSuccess -> "注入成功"
        isFailed -> "注入失敗"
        state.hooked -> "部署進行中"
        state.running -> "部署中"
        else -> "尚未部署"
    }

    val statusColor = when {
        isSuccess -> Color(0xFF4CAF50)
        isFailed -> Color(0xFFE53935)
        state.running || state.hooked -> colors.primary
        else -> colors.onSurface
    }

    val progressColors = when {
        isSuccess -> ProgressIndicatorDefaults.progressIndicatorColors(
            foregroundColor = Color(0xFF4CAF50),
        )
        isFailed -> ProgressIndicatorDefaults.progressIndicatorColors(
            foregroundColor = Color(0xFFE53935),
        )
        else -> ProgressIndicatorDefaults.progressIndicatorColors(
            foregroundColor = colors.primary,
        )
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 16.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            if (isSuccess) {
                Icon(
                    imageVector = DfIcons.Check,
                    contentDescription = "成功",
                    modifier = Modifier.size(28.dp),
                    tint = Color(0xFF4CAF50),
                )
            } else if (isFailed) {
                Icon(
                    imageVector = DfIcons.Close,
                    contentDescription = "失敗",
                    modifier = Modifier.size(28.dp),
                    tint = Color(0xFFE53935),
                )
            }
            AnimatedContent(
                targetState = headlineText,
                transitionSpec = { fadeIn(tween(220)) togetherWith fadeOut(tween(160)) },
                label = "headline",
            ) { text ->
                Text(
                    text = text,
                    style = MiuixTheme.textStyles.title2,
                    color = statusColor,
                )
            }
        }
        Text(
            text = state.status,
            style = MiuixTheme.textStyles.body2,
            color = colors.onSurfaceVariantSummary,
        )

        Card {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(16.dp),
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        text = "部署進度",
                        style = MiuixTheme.textStyles.body1,
                        modifier = Modifier.weight(1f),
                    )
                    Text(
                        text = "${(progress * 100f).roundToInt()}%",
                        style = MiuixTheme.textStyles.body1,
                        color = statusColor,
                    )
                }
                Spacer(Modifier.height(10.dp))
                LinearProgressIndicator(
                    progress = progress,
                    colors = progressColors,
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        }

        Button(
            onClick = onLaunchRoot,
            enabled = !state.running && !state.hooked && !state.rooted,
            modifier = Modifier
                .fillMaxWidth()
                .height(56.dp),
            colors = ButtonDefaults.buttonColorsPrimary(),
        ) {
            Text(
                text = when {
                    state.running -> "部署中…"
                    state.rooted -> "已於本次開機 Root"
                    else -> "啟動 Root"
                },
                style = MiuixTheme.textStyles.button,
            )
        }

        if (state.managerAvailable) {
            Button(
                onClick = onOpenMagisk,
                modifier = Modifier
                    .fillMaxWidth()
                    .height(48.dp),
            ) {
                Text("開啟 Magisk", style = MiuixTheme.textStyles.button)
            }
        }

        Card {
            Column(modifier = Modifier.fillMaxWidth()) {
                // Same row style as 設定 / 檢視紀錄, above 設定. The deploy no
                // longer hashes the manager APK, so this is the only way to
                // refresh the staged Magisk file set.
                ActionRow(
                    icon = DfIcons.Import,
                    title = "導入 Magisk APK",
                    summary = "自訂 Magisk APK，替換二進制並提取包名",
                    enabled = !state.running,
                    onClick = onImportMagisk,
                )
                HorizontalDivider()
                ActionRow(
                    icon = DfIcons.Refresh,
                    title = "升級 Magisk 版本",
                    summary = "從目前已安裝的 Magisk APK 重新提取檔案",
                    enabled = !state.running,
                    onClick = { showUpgrade = true },
                )
                HorizontalDivider()
                ActionRow(
                    icon = DfIcons.Settings,
                    title = "設定",
                    summary = "開機自動執行、模組保護、軟重啟",
                    onClick = onOpenSettings,
                )
                HorizontalDivider()
                ActionRow(
                    icon = DfIcons.Records,
                    title = "檢視紀錄",
                    summary = "查看注入輸出、可存到 Download",
                    onClick = onOpenRecords,
                )
            }
        }

        Card(
            modifier = Modifier.fillMaxWidth(),
        ) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(16.dp),
            ) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween,
                ) {
                    Text(
                        text = "即時執行日誌",
                        style = MiuixTheme.textStyles.title4,
                    )
                    Text(
                        text = "切換至紀錄頁 ➔",
                        style = MiuixTheme.textStyles.body2,
                        color = colors.primary,
                        modifier = Modifier.clickable { onOpenRecords() },
                    )
                }
                Spacer(Modifier.height(8.dp))
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(min = 120.dp, max = 260.dp)
                        .background(
                            color = if (isSystemInDarkTheme()) Color(0xFF1E1E1E) else Color(0xFFF5F5F5),
                            shape = RoundedCornerShape(8.dp)
                        )
                        .padding(10.dp)
                        .verticalScroll(rememberScrollState()),
                ) {
                    SelectionContainer {
                        Text(
                            text = state.output.ifBlank { "尚未有執行日誌…" },
                            style = MiuixTheme.textStyles.body2.copy(
                                fontFamily = FontFamily.Monospace,
                                fontSize = 12.sp,
                            ),
                            color = if (state.output.isBlank()) colors.onSurfaceVariantSummary else colors.onSurface,
                        )
                    }
                }
            }
        }

        if (showUpgrade) {
            OverlayDialog(
                show = true,
                title = "確認升級 Magisk 版本？",
                summary = "會重新讀取目前已安裝的 Magisk APK，把它裡面的 magisk／magiskinit／"
                    + "magiskpolicy 等檔案換成該版本，並重新比對簽章。\n\n"
                    + "簽章不一致時流程與原本相同：不卸載、不重裝管理器，"
                    + "只更新 /data/adb/magisk 的檔案。\n\n"
                    + "按「確定」後會立刻開始部署。",
                onDismissRequest = { showUpgrade = false },
            ) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(top = 12.dp),
                    horizontalArrangement = Arrangement.End,
                ) {
                    TextButton(text = "取消", onClick = { showUpgrade = false })
                    Spacer(Modifier.width(8.dp))
                    TextButton(
                        text = "確定",
                        onClick = {
                            showUpgrade = false
                            onUpgradeMagisk()
                        },
                        colors = ButtonDefaults.textButtonColorsPrimary(),
                    )
                }
            }
        }

        Text(
            text = "DFRoot ${BuildConfig.VERSION_NAME} · 核心 " +
                System.getProperty("os.version", "?"),
            style = MiuixTheme.textStyles.footnote2,
            color = colors.onSurfaceVariantSummary,
            modifier = Modifier
                .fillMaxWidth()
                .padding(top = 4.dp, bottom = 8.dp),
            textAlign = TextAlign.Center,
        )
    }
}

@Composable
private fun ActionRow(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    title: String,
    summary: String,
    enabled: Boolean = true,
    onClick: () -> Unit,
) {
    val colors = MiuixTheme.colorScheme
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            modifier = Modifier.size(22.dp),
            tint = if (enabled) colors.primary else colors.onSurfaceVariantSummary,
        )
        Spacer(Modifier.width(14.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(text = title, style = MiuixTheme.textStyles.body1,
                color = if (enabled) colors.onSurface else colors.onSurfaceVariantSummary)
            Text(
                text = summary,
                style = MiuixTheme.textStyles.footnote1,
                color = colors.onSurfaceVariantSummary,
            )
        }
        Icon(
            imageVector = DfIcons.ChevronRight,
            contentDescription = null,
            modifier = Modifier.size(18.dp),
            tint = colors.onSurfaceVariantSummary,
        )
    }
}

/* --------------------------------------------------------------- records -- */

@Composable
private fun RecordsScreen(
    output: String,
    onClearLog: () -> Unit,
) {
    val colors = MiuixTheme.colorScheme
    val scroll = rememberScrollState()

    LaunchedEffect(output.length) {
        if (output.isEmpty()) return@LaunchedEffect
        // The text is measured in the next frame; maxValue is still 0 now.
        withFrameNanos { }
        scroll.scrollTo(scroll.maxValue)
    }

    Column(modifier = Modifier.fillMaxSize()) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(start = 20.dp, end = 8.dp, top = 4.dp, bottom = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = if (output.isEmpty()) "注入輸出" else "注入輸出 · ${output.count { it == '\n' }} 行",
                style = MiuixTheme.textStyles.footnote1,
                color = colors.onSurfaceVariantSummary,
                modifier = Modifier.weight(1f),
            )
            TextButton(
                text = "清空",
                onClick = onClearLog,
                enabled = output.isNotEmpty(),
            )
        }

        if (output.isEmpty()) {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .weight(1f),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    text = "尚無紀錄。回到首頁按「啟動 Root」開始部署。",
                    style = MiuixTheme.textStyles.body2,
                    color = colors.onSurfaceVariantSummary,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.padding(32.dp),
                )
            }
        } else {
            SelectionContainer(
                modifier = Modifier
                    .fillMaxWidth()
                    .weight(1f),
            ) {
                Text(
                    text = output,
                    modifier = Modifier
                        .fillMaxSize()
                        .verticalScroll(scroll)
                        .padding(horizontal = 16.dp, vertical = 4.dp),
                    fontFamily = FontFamily.Monospace,
                    fontSize = 11.sp,
                    lineHeight = 16.sp,
                    color = colors.onSurface,
                )
            }
        }
    }
}
