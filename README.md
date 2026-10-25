# DFRoot (GPL-2.0)

Android 12 / kernel 4.19 的臨時 root 注入工具，透過 LKM 載入 Magisk。

## 授權

本專案為 **GNU General Public License v2.0**（見 `LICENSE`）。
衍生自 DFRoot（loveelysia5291/DFRoot）。散布二進位時必須同時提供對應原始碼。

## 建置

```sh
# 需要 JDK 17+ 與 Android SDK (compileSdk 37)

# 小型發佈版：R8 + 資源精簡，使用 debug keystore 簽章（約 5 MB）
./gradlew :app:assembleSlim

# 開發版：不精簡、可除錯（約 30 MB）
./gradlew :app:assembleDebug
```

介面使用 Jetpack Compose + [MIUIX 0.9.4](https://github.com/compose-miuix-ui/miuix)
（`top.yukonga.miuix.kmp:miuix-ui`），底部固定「首頁 / 紀錄 / 設定」三分頁：

- **首頁**：啟動 Root 按鈕、部署進度條、Magisk/LSPosed 管理器入口
- **紀錄**：`ExploitRunner` 的即時注入輸出（可選取、可存到 Download）
- **設定**：Compose/MIUIX 的開機自動執行、LSPosed 軟重啟、停用模組與關於資訊

UI 需要的十個圖示由 `DfIcons.kt` 直接以 `ImageVector` 繪製，不引入
`miuix-icons`（該 artifact 在 debug APK 內約占 3.6 MB dex，且包含上千個未使用圖示）。
`assembleSlim` 會再由 R8 移除未使用的 MIUIX/Compose 類別與資源。

MIUIX 0.9.4 以 Kotlin 2.4.20 發佈，因此本專案使用同版本 Kotlin。AGP 9.4
內建的 Kotlin 是 2.2.10，讀不了 2.4 的 metadata，所以 `gradle.properties`
以 `android.builtInKotlin=false` + `android.newDsl=false` 讓 Kotlin Gradle
plugin 接管編譯（AGP 10 前需重新評估）。

Release 簽章：把 keystore 放到 `keystore/release.keystore`，並建立 `signing.properties`（格式見 `signing.properties.example`）。

## 注意

- 僅支援 Magisk（KernelSU 相關功能已移除）
- 注入後 su 只存在於 `/debug_ramdisk/su`
