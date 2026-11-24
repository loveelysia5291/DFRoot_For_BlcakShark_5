<p align="center">
  <img src="docs/icon.png" width="132" height="132" alt="DFRoot">
</p>

# DFRoot (GPL-2.0)

**繁體中文** ｜ [English](READNE_EN.md)

針對 Black Shark 5 (SHARK PAR-H0) 的臨時 Root 注入工具：
透過 LKM 取得核心權限，並透過 `bootstrap` 與 `ksud late-load` 載入 KernelSU。

## 授權

本專案為 **GNU General Public License v2.0**（見 `LICENSE`）。
衍生自 DFRoot（loveelysia5291/DFRoot）。散布二進位時必須同時提供對應原始碼。

## 目前版本（4.9.6）

**執行漏洞前請先安裝 KernelSU 管理器。**

部署流程：
1. 檢測已安裝的 KernelSU 管理器
2. 將管理器的 `libksud.so` 提取並暫存為 `/data/user_de/0/df.root/ksud`。
3. 將原生 `libbootstrap.so` 暫存為 `/data/user_de/0/df.root/bootstrap`。
4. 執行 `libdfroot.so` 觸發內核漏洞並掛載 LKM 模組。
5. 由 `libcxx.S` / LKM 啟動 `bootstrap`，執行 `ksud late-load` 完成 KernelSU 初始化。

## 介面

Jetpack Compose + [MIUIX 0.9.4](https://github.com/compose-miuix-ui/miuix)
（`top.yukonga.miuix.kmp:miuix-ui`）。

- **首頁**：啟動 Root、開啟 KernelSU、即時滾動執行日誌。
- **設定**：開機自動部署、自動軟重啟 (LSPosed)、停用所有模組。

## 建置

```sh
# 需要 JDK 21、Android SDK (compileSdk 37)

./gradlew :app:assembleRelease   # R8 + 資源精簡（CI 用這個）
./gradlew :app:assembleDebug     # 不精簡、可除錯
./gradlew :app:assembleSlim      # 與 release 等價，固定用 debug 憑證
```

APK 輸出路徑：`app/build/outputs/apk/<variant>/DFRoot_<version>.apk`。
