<p align="center">
  <img src="docs/icon.png" width="132" height="132" alt="DFRoot">
</p>

# DFRoot (GPL-2.0)

**繁體中文** ｜ [English](READNE_EN.md)

For Black Shark SHARK PAR-H0 的臨時 root 注入工具：
透過 LKM 取得核心權限，再把 Magisk 的 su 掛到 `/debug_ramdisk`。

## 授權

本專案為 **GNU General Public License v2.0**（見 `LICENSE`）。
衍生自 DFRoot（loveelysia5291/DFRoot）。散布二進位時必須同時提供對應原始碼。

## 目前版本（4.9.0）

**執行漏洞前請先安裝Magisk(https://github.com/topjohnwu/Magisk)

部署流程（`app/src/main/assets/deploy-magisk.sh`）：

1. 須先安裝Magisk
2. 取出管理器的 APK，比對 md5：與上次部署相同就跳過解壓
3. 版本／簽章：APK md5 有變就清掉 `magisk.db` 裡舊的 `keystore` 憑證，
   讓 magiskd 重新學習，避免管理器被 Magisk 判成簽章不符而移除
4. 部署完整檔案集到 `/data/adb/magisk`，su 只留在 `/debug_ramdisk/su`

## 介面

Jetpack Compose + [MIUIX 0.9.4](https://github.com/compose-miuix-ui/miuix)
（`top.yukonga.miuix.kmp:miuix-ui`）。

- **首頁**：啟動 Root、部署進度、Magisk/LSPosed 

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



## 注意

更詳細的說明與 kernel module 
[`BUILD.md`](BUILD.md)。

