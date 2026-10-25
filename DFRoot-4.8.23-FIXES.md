# DFRoot 4.8.23 — 8 項目標狀態總表

## 產物

| 項目 | 值 |
|---|---|
| 版本 | **4.8.23**（versionCode 431） |
| APK | `DFRoot_4.8.23.apk` |
| 大小 | 5,467,436 bytes |
| SHA-256 | `D9AA736098F8906A2F5EAB5355CC886C433EC82090AF9A80B6A4ED32D62F5903` |
| 簽章 | `25558160…db5cf`（與 4.8.11 以後相同，可覆蓋安裝） |

> 4.8.23 相對 4.8.22 只改了日誌標頭（原本寫死 `4.8.10`，會讓 deploy.log 看起來像舊版），
> 方便之後對照日誌。功能與 4.8.22 相同。

## 逐項狀態

### 1. LSPosed「dex 最佳化不支援」✅ 已修（待實測）

你附的日誌證明根因是**兩個 lspd**：部署在 zygote 重啟前先啟動一個，
bridge 不存在 → 它重試後結束 → supervisor 重開 → 新實例 `bind` dex2oat socket 得到
`EADDRINUSE` → `no dex2oat socket could be started`。

改法（照你的 `fix_lspd.sh`）：

1. 殺光 lspd/supervisor、清 `monitor`/`lock`
2. 讀 zygote 的 `BOOTCLASSPATH` / `DEX2OATBOOTCLASSPATH`
3. 直接跑 `zygiskd daemon` + `service-stage`
4. 用 `setsid nsenter … app_process` 起**唯一**一個 lspd（沒有 supervisor 會重開它）
5. `kill -9 zygote64`（不用 `ctl.restart`，這台 init 會忽略它）
6. 等新 system_server → 等 `binder received`（失敗走方案 B：殺 system_server）
7. 靜置 15 秒 → `chmod 644 /data/adb/lspd/monitor` → 恢復 Enforcing

**打包後的自我檢查**（直接對 APK 內的 `assets/deploy-magisk.sh` 驗證，
不是只看原始碼）：

```
OK  4.8.23 start
OK  detect_manager_from_db
OK  stage_manager_stub
OK  disable_all_modules
OK  chmod 600 /proc/dfroot_su
OK  [7] waiting for the binder bridge
OK  chmod 644 /data/adb/lspd/monitor
OK  zygiskd daemon
OK  zygiskd service-stage
OK  kill -9 $ZYGOTE_BEFORE
```

以及流程檢查（`stop_lspd` → 讀 BOOTCLASSPATH/DEX2OATBOOTCLASSPATH → zygiskd →
setsid/nsenter + app_process → kill -9 zygote → 等舊 SS 死/新 SS 起 → bridge 60 秒 →
方案 B → settle 15 秒 → chmod 644 monitor）全部存在。

### 2. 注入慢／執行不完全 ✅ 已修

- `soft_reboot_lsposed` 原本被呼叫**兩次**（等於整個流程跑兩遍）→ 只留一次。
- App 端：deploy.log 240 秒沒增長就停止等待並回報（原本死等 600 秒）。
- 你日誌中的 `vendor io: batched helper` + `verified: … matches the KO image`
  + `restored to the original bytes` 代表注入/還原本體正常。

### 3. 已有 su 權限仍重複執行 ✅ 已修

`deploy.done` 最後一筆是 `result=ok` 且寫入時間在本次開機之後 → 直接跳過，
按鈕顯示 `Already rooted (this boot)`。

### 4. 精簡 + 移除 KSU ✅

- `bootstrap.c`、CMake target、`hasKsud()`、`libksud.so` staging、su manager 下拉、
  `item_su_manager*.xml`、KSU 設定項 → 全移除
- `deploy-magisk.sh` 3,728 → **3,057 行**（-18%），刪掉 10 個無人呼叫的函式
- 平衡檢查：`case/esac` 41/41、`for+while/do` 64/64；唯一「不平衡」的 2 個 `if`
  是 awk 程式內的 `if (...)`，不是 shell

### 5. Magisk 不偵測包名 ✅

四層解析：

1. 上次記下的包名（還安裝著就用）
2. 上次記下的**簽章憑證 SHA-256**（隱藏/重新打包不換簽章）
3. 包名含 `magisk`
4. APK 內容（`lib/*/libmagisk*.so`、dex 內 `com.topjohnwu.magisk`）

再加上 root 後查 `magisk.db` 的 `strings.requester`（真正「綁定」的管理器包名），
找到後回寫 `manager.package`。`manager.package` 不再被刪除（保留憑證）。

### 6. 全域 SELinux Enforcing ✅

- 每條 return/fatal/中斷路徑都 `setenforce 1`
- 腳本結尾再確認一次；`on_exit` trap 也設
- `magisk` domain permissive 是上游 Magisk 行為（`permissive([proc])`），
  不影響 `getenforce`（顯示 Enforcing）

### 7. 不洩漏 su ✅

- LKM 建的 `/proc/dfroot_su` 是 0666，worker 一啟動就 `chmod 600`
- 所有結束路徑讀一次關閉 latch，並移除 LKM 暫存的 su client
- 不再安裝 4.7 的 wrapper（唯一 su 是 Magisk 的 symlink）

### 8. Play Integrity ⚠️ 只做了「不破壞」

已處理：全域 Enforcing、關閉 `/proc/dfroot_su`、不再重啟 zygote 兩次。

但「已 root + Zygisk/LSPosed 注入」本身就會讓 `MEETS_DEVICE_INTEGRITY` 不保證過；
`MEETS_STRONG_INTEGRITY` 還牽涉 bootloader 解鎖與硬體金鑰。請告訴我是哪一項沒過，
我才能針對該項處理（例如隱藏 `/system/xbin` 掛載、或改走 DenyList）。

## 附加功能：Update Magisk payload

`⋮` → Update Magisk payload… → 選 Magisk APK（arm64）：

- 只取 `lib/arm64-v8a/libmagisk.so`（及 magiskinit/magiskboot/magiskpolicy/init-ld/busybox）
- 缺 `busybox`/`magiskpolicy` → 拒絕（不覆蓋現有檔案）
- 存到 `/data/user_de/0/df.root/payload/`，下次部署套用
- 套用後 MD5 相同就不再重寫，之後每次部署都不會重複覆蓋

### 用真實 APK 驗證過（`D:\download\Magisk-v30.7.apk`）

拿 Magisk v30.7 官方 APK 依同樣規則提取，逐檔比對 DFRoot 內建的資產：

```
lib/arm64-v8a/libmagisk.so        -> magisk           IDENTICAL (394232)
lib/arm64-v8a/libbusybox.so       -> busybox          IDENTICAL (1710600)
lib/arm64-v8a/libmagiskpolicy.so  -> magiskpolicy     IDENTICAL (356584)
lib/arm64-v8a/libmagiskinit.so    -> magiskinit       IDENTICAL (199960)
lib/arm64-v8a/libmagiskboot.so    -> magiskboot       IDENTICAL (788840)
lib/arm64-v8a/libinit-ld.so       -> init-ld          IDENTICAL (5208)
assets/stub.apk                   -> stub.apk         IDENTICAL (70013)
assets/util_functions.sh          -> util_functions.sh IDENTICAL (20418)
assets/addon.d.sh                 -> addon.d.sh       IDENTICAL (4095)
assets/boot_patch.sh              -> boot_patch.sh     IDENTICAL (7197)

10/10 檔案位元組完全相同
```

這同時證明兩件事：

1. 提取規則（`lib/arm64-v8a/lib<name>.so` → `<name>`）與 Magisk 實際打包方式一致。
2. DFRoot 內建的 Magisk 檔案集就是 Magisk 30.7 的原始檔案，所以選同一版 APK
   不會產生任何變動（全部 MD5 相同、不會重寫）；選新版則會整組換掉。

註：Magisk 30.7 的 APK 只有 `libmagisk.so`（每個 ABI 一份），沒有 `libmagisk32/64.so`；
32 位檔案（`magisk32`）仍由內建資產提供，不影響 arm64 漏洞本體。

## 建置

- 沙箱內 AGP 的 CMake configure 會卡死，因此 `libdfroot.so` 使用已驗證的預編譯檔
  （`app/src/main/jniLibs/arm64-v8a/`，C 原始碼本輪未改）
- 已比對：新版 APK 內的 `lib/arm64-v8a/libdfroot.so` 與你最後一次驗證過的
  4.8.11 APK 內的同一顆 **位元組完全相同**（158,848 bytes，
  SHA-256 `d1224bb8…e06a95`），所以改動都在 Java 與 shell，漏洞程式本体沒變
- Debug 簽章使用 `keystore/debug.keystore`（你原本 `~/.android` 的複本）
- 已做過一次 `rm -rf app/build` 的乾淨重建，產物大小一致

## 待你實測

1. LSPosed Manager 是否還是「dex 最佳化不支援」
2. 隱藏 Magisk 時是否出現 `manager from magisk.db requester: …`
3. `getenforce` = Enforcing
4. Play Integrity 是哪一項沒過
