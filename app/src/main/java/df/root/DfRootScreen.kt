package df.root

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
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
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
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
import top.yukonga.miuix.kmp.basic.Icon
import top.yukonga.miuix.kmp.basic.IconButton
import top.yukonga.miuix.kmp.basic.LinearProgressIndicator
import top.yukonga.miuix.kmp.basic.NavigationBar
import top.yukonga.miuix.kmp.basic.NavigationBarItem
import top.yukonga.miuix.kmp.basic.ProgressIndicatorDefaults
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

@Composable
fun DfRootApp(
    state: DfRootUiState,
    onLaunchRoot: () -> Unit,
    onOpenMagisk: () -> Unit,
    onUpgradeMagisk: () -> Unit,
    onImportMagisk: () -> Unit,
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
    onSaveLog: () -> Unit,
    onClearLog: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    val pager = rememberPagerState(pageCount = { 2 })
    val tab = pager.currentPage

    fun go(page: Int) = scope.launch { pager.animateScrollToPage(page) }

    // Back from 設定 returns to 首頁 instead of leaving the app.
    BackHandler(enabled = pager.currentPage != 0) {
        scope.launch { pager.animateScrollToPage(0) }
    }

    Scaffold(
        topBar = {
            SmallTopAppBar(
                title = when (tab) {
                    0 -> "DFRoot"
                    else -> "設定"
                },
                subtitle = if (tab == 0) "@diabl0w github/xda" else "",
                actions = {
                    IconButton(onClick = onSaveLog) {
                        Icon(
                            imageVector = DfIcons.Download,
                            contentDescription = "儲存紀錄",
                            modifier = Modifier.size(24.dp),
                            tint = MiuixTheme.colorScheme.onSurface,
                        )
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
                    onSaveLog = onSaveLog,
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
    onSaveLog: () -> Unit,
    onClearLog: () -> Unit,
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
        animationSpec = tween(durationMillis = 280),
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

    val rootButtonEnabled = !state.running && !state.hooked && !state.rooted

    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(horizontal = 14.dp, vertical = 6.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        // Status row & percentage
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            modifier = Modifier.fillMaxWidth(),
        ) {
            if (isSuccess) {
                Icon(
                    imageVector = DfIcons.Check,
                    contentDescription = "成功",
                    modifier = Modifier.size(24.dp),
                    tint = Color(0xFF4CAF50),
                )
            } else if (isFailed) {
                Icon(
                    imageVector = DfIcons.Close,
                    contentDescription = "失敗",
                    modifier = Modifier.size(24.dp),
                    tint = Color(0xFFE53935),
                )
            }
            AnimatedContent(
                targetState = headlineText,
                transitionSpec = { fadeIn(tween(200)) togetherWith fadeOut(tween(150)) },
                label = "headline",
            ) { text ->
                Text(
                    text = text,
                    style = MiuixTheme.textStyles.title3,
                    color = statusColor,
                )
            }
            Spacer(Modifier.weight(1f))
            Text(
                text = "${(progress * 100f).roundToInt()}%",
                style = MiuixTheme.textStyles.body2,
                color = statusColor,
            )
        }

        // Progress bar
        LinearProgressIndicator(
            progress = progress,
            colors = progressColors,
            modifier = Modifier
                .fillMaxWidth()
                .height(6.dp),
        )

        // Status text
        Text(
            text = state.status,
            style = MiuixTheme.textStyles.footnote1,
            color = colors.onSurfaceVariantSummary,
            maxLines = 1,
        )

        // Primary action buttons: 啟動 Root & 開啟 Magisk
        if (state.managerAvailable) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Button(
                    onClick = onLaunchRoot,
                    enabled = rootButtonEnabled,
                    modifier = Modifier
                        .weight(1f)
                        .height(42.dp),
                    colors = ButtonDefaults.buttonColorsPrimary(),
                ) {
                    Text(
                        text = when {
                            state.running -> "部署中…"
                            state.rooted -> "已 Root"
                            else -> "啟動 Root"
                        },
                        style = MiuixTheme.textStyles.button,
                    )
                }
                Button(
                    onClick = onOpenMagisk,
                    modifier = Modifier
                        .weight(1f)
                        .height(42.dp),
                ) {
                    Text("開啟 Magisk", style = MiuixTheme.textStyles.button)
                }
            }
        } else {
            Button(
                onClick = onLaunchRoot,
                enabled = rootButtonEnabled,
                modifier = Modifier
                    .fillMaxWidth()
                    .height(42.dp),
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
        }

        // Import & Upgrade in ONE Row
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Button(
                onClick = onImportMagisk,
                enabled = !state.running,
                modifier = Modifier
                    .weight(1f)
                    .height(38.dp),
            ) {
                Text("導入 APK", style = MiuixTheme.textStyles.button)
            }
            Button(
                onClick = { showUpgrade = true },
                enabled = !state.running,
                modifier = Modifier
                    .weight(1f)
                    .height(38.dp),
            ) {
                Text("升級 Magisk", style = MiuixTheme.textStyles.button)
            }
        }

        // Realtime log Card - fill remaining vertical space (.weight(1f))
        Card(
            modifier = Modifier
                .fillMaxWidth()
                .weight(1f),
        ) {
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(horizontal = 12.dp, vertical = 8.dp),
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
                    Row(
                        horizontalArrangement = Arrangement.spacedBy(2.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        IconButton(onClick = onSaveLog) {
                            Icon(
                                imageVector = DfIcons.Download,
                                contentDescription = "儲存日誌",
                                modifier = Modifier.size(20.dp),
                                tint = colors.primary,
                            )
                        }
                        TextButton(
                            text = "清空",
                            onClick = onClearLog,
                            enabled = state.output.isNotEmpty(),
                        )
                    }
                }
                Spacer(Modifier.height(4.dp))
                val logScroll = rememberScrollState()
                LaunchedEffect(state.output.length) {
                    if (state.output.isNotEmpty()) {
                        withFrameNanos { }
                        logScroll.scrollTo(logScroll.maxValue)
                    }
                }
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .background(
                            color = if (isSystemInDarkTheme()) Color(0xFF1E1E1E) else Color(0xFFF5F5F5),
                            shape = RoundedCornerShape(8.dp),
                        )
                        .padding(8.dp)
                        .verticalScroll(logScroll),
                ) {
                    SelectionContainer {
                        Text(
                            text = state.output.ifBlank { "尚未有執行日誌…" },
                            style = MiuixTheme.textStyles.body2.copy(
                                fontFamily = FontFamily.Monospace,
                                fontSize = 11.sp,
                                lineHeight = 16.sp,
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
                .padding(top = 2.dp, bottom = 4.dp),
            textAlign = TextAlign.Center,
        )
    }
}
