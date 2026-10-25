<p align="center">
  <img src="docs/icon.png" width="132" height="132" alt="DFRoot">
</p>

# DFRoot (GPL-2.0)

**繁體中文**（預設） ｜ [English](#english)

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

---

<a id="english"></a>

<details>
<summary><b>English</b> — click to expand</summary>

# DFRoot (GPL-2.0)

Temporary root for Android 12 / kernel 4.19 (Black Shark SHARK PAR-H0): a kernel
module gives the app kernel privileges, then Magisk's `su` is bound under
`/debug_ramdisk`.

## License

**GNU General Public License v2.0** (see `LICENSE`). Derived from DFRoot
(loveelysia5291/DFRoot). Distributing binaries requires shipping the
corresponding source.

## What it does (4.9.0)

**Nothing has to be imported.** The deploy reads the installed Magisk manager's
APK and pulls `magisk`, `magiskinit`, `magiskboot`, `magiskpolicy`, `busybox`
and `init-ld` straight out of it, so the app no longer stores, compares or
rolls back a user-supplied payload.

Deploy outline:

1. Refuse to start when no Magisk is installed (`ERROR_NO_MAGISK`); nothing is
   locked or modified in that case
2. Hash the manager APK and skip extraction when it matches the last deploy
3. Version/signature gate: when that hash changes, the stale
   `magisk.db` `keystore` row is dropped so magiskd re-learns the manager
   certificate instead of removing the manager
4. Stage the full file set into `/data/adb/magisk`; `su` exists only as
   `/debug_ramdisk/su`

## UI

Jetpack Compose + [MIUIX 0.9.4](https://github.com/compose-miuix-ui/miuix). Three
pages you can **swipe** between, with the bottom bar following the visible page:

- **Home** — start root, deploy progress, Magisk/LSPosed shortcuts
- **Log** — live `ExploitRunner` output (selectable, saveable to Download)
- **Settings** — auto-run on boot, LSPosed soft reboot, module disable, about

Colours come from the system **Monet** palette (Android 12 wallpaper colours),
falling back to the defaults when the ROM exposes none. The **launcher icon
follows it too**: six plates ship in the APK (green/blue/purple/pink/orange/
teal) and on launch the app picks the one closest to `system_accent1_500` and
switches the enabled `activity-alias` — new entry is enabled before the old one
is disabled, so the app can never disappear from the launcher.

## Build

```sh
# JDK 21 and Android SDK (compileSdk 37)

./gradlew :app:assembleRelease   # R8 + resource shrinking, ~5 MB (used by CI)
./gradlew :app:assembleDebug     # unminified, debuggable, ~30 MB
./gradlew :app:assembleSlim      # same as release, always the debug key
```

## CI / releases

`.github/workflows/build.yml` runs a single job with a single command,
`./gradlew :app:assembleRelease`. Push to `master` uploads an artifact; pushing
a `v*` tag also creates a GitHub Release with the APK attached.

```sh
git tag v4.9.0
git push origin master --tags
```

## Signing

`assembleRelease` signs with `signing.properties` when both the file and the
keystore it names exist, otherwise with the committed
`keystore/debug.keystore` (`android` / `android`), which keeps the APK
installable as an update over earlier DFRoot builds. On CI, store the keystore
as the base64 secret `KEYSTORE_BASE64` (plus `KEYSTORE_PASSWORD`, `KEY_ALIAS`,
`KEY_PASSWORD`) to sign with your own key.

## Notes

- Magisk only — KernelSU support was removed
- `su` lives only at `/debug_ramdisk/su`; `/system/bin` and `/system/xbin` are
  cleaned
- The app never installs or uninstalls a manager and never guesses which app is
  Magisk from APK contents

Rebuilding the native engine / kernel modules: see [`BUILD.md`](BUILD.md)
(Chinese).

</details>
