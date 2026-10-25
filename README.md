<p align="center">
  <img src="docs/icon.png" width="132" height="132" alt="DFRoot">
</p>

# DFRoot (GPL-2.0)

**繁體中文** ｜ [English](#READNE_EN.md)

Android 12 / kernel 4.19（Black Shark SHARK PAR-H0）的臨時 root 注入工具：
透過 LKM 取得核心權限，再把 Magisk 的 su 掛到 `/debug_ramdisk`。

## 授權

本專案為 **GNU General Public License v2.0**（見 `LICENSE`）。
衍生自 DFRoot（loveelysia5291/DFRoot）。散布二進位時必須同時提供對應原始碼。

## 目前版本（4.9.0）

**執行漏洞前請先安裝Magisk(https://github.com/topjohnwu/Magisk)

部署流程（`app/src/main/assets/deploy-magisk.sh`）：

1. 先確認有安裝 Magisk，沒有就直接 `ERROR_NO_MAGISK` 結束，**不取鎖、不改任何檔案**
2. 取出管理器的 APK，比對 md5：與上次部署相同就跳過解壓（快速路徑）
3. 版本／簽章閘門：APK md5 有變就清掉 `magisk.db` 裡舊的 `keystore` 憑證，
   讓 magiskd 重新學習，避免管理器被 Magisk 判成簽章不符而移除
4. 部署完整檔案集到 `/data/adb/magisk`，su 只留在 `/debug_ramdisk/su`

## 介面

Jetpack Compose + [MIUIX 0.9.4](https://github.com/compose-miuix-ui/miuix)
（`top.yukonga.miuix.kmp:miuix-ui`）。三頁可**左右滑動**切換，底部導覽列跟著目前頁面：

- **首頁**：啟動 Root、部署進度、Magisk/LSPosed 管理器入口
- **紀錄**：`ExploitRunner` 的即時注入輸出（可選取、可存到 Download）
- **設定**：開機自動執行、LSPosed 軟重啟、停用模組與關於資訊

配色走系統的 **Monet**（Android 12 桌布取色），沒有可用色盤才退回預設值。
**啟動圖示也會跟著取色**：內建六套底板（綠／藍／紫／粉／橙／青），開啟 App 時
依 `system_accent1_500` 的色相選最接近的一套並切換啟動入口
（`activity-alias`，見 `AndroidManifest.xml`；切換時先啟用新的再停用舊的，
不會讓 App 從桌面消失）。

UI 圖示由 `DfIcons.kt` 以 `ImageVector` 直接繪製，不引入 `miuix-icons`
（該 artifact 在 debug APK 內約占 3.6 MB dex，且包含上千個未使用圖示）。

## 建置

```sh
# 需要 JDK 21、Android SDK (compileSdk 37)

./gradlew :app:assembleRelease   # R8 + 資源精簡，約 5 MB（CI 用這個）
./gradlew :app:assembleDebug     # 不精簡、可除錯，約 30 MB
./gradlew :app:assembleSlim      # 與 release 等價，固定用 debug 憑證
```

`app/build/outputs/apk/<variant>/DFRoot_<version>.apk`。

## CI 與發 Release

`.github/workflows/build.yml` 只有一個 job、一個指令 `./gradlew :app:assembleRelease`：

| 觸發 | 結果 |
|---|---|
| push `master` / `main` | 建置、上傳 artifact |
| PR | 同上 |
| push tag `v*` | 建置 + 建立 GitHub Release，掛上 APK |

```sh
git tag v4.9.0
git push origin master --tags
```

## 簽章

1. `signing.properties` 存在**且**它指向的 keystore 真的在磁碟上 → 用你的金鑰
2. 否則退回版控內的 `keystore/debug.keystore`（`android` / `android`），
   與舊版 DFRoot 同憑證，可直接覆蓋安裝

CI 要換金鑰就把 keystore 轉成 base64 存進 secret `KEYSTORE_BASE64`
（`KEYSTORE_PASSWORD` / `KEY_ALIAS` / `KEY_PASSWORD` 一起設），
workflow 會自動解出來並寫 `signing.properties`。

## 注意

- 僅支援 Magisk（KernelSU 相關功能已移除）
- su 只存在於 `/debug_ramdisk/su`，`/system/bin`、`/system/xbin` 一律清掉
- 不會自動安裝或卸載任何管理器，也不會用 APK 內容去猜哪個 App 是 Magisk

更詳細的原生引擎與 kernel module 重建說明見 [`BUILD.md`](BUILD.md)。

