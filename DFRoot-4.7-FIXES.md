# DFRoot 4.7 修正說明（DFRoot + Magisk 合併版）

版本：4.7（versionCode 407）
前一版：4.6（su 已可用，但「所有 App 預先授權」＋「管理器不彈窗」）

---

## 一、這次改了什麼

### 1. 取消「全部 App 預先授權 su」

4.6 的做法是把 `/data/system/packages.list` 裡**每一個 uid** 都寫進
Magisk 的 `policies` 表（`policy=2` = 永遠允許、不記錄、不通知）。
結果：

* 任何 App（含來路不明的）都能直接拿到 root，不會詢問。
* Magisk 管理器完全沒有機會跳「授權 su」的窗。

4.7 改成：

```
DELETE FROM policies;      -- 先清掉 4.6 留下的整份名單
```

只保留這幾筆：

| uid | 來源 | 說明 |
|-----|------|------|
| `df.root` 的 uid | 自動 | 安裝 root 的 App 本身 |
| `2000` | 自動 | adb shell（方便除錯） |
| 其他 | `/data/adb/dfroot/presu.list` | 預設**空白**，要加才加 |

其餘 App 一律走 Magisk 原生流程：`Query` → 管理器彈窗 → 使用者決定。

> 如果你之前裝過 4.6，這一步會把舊的「全 App 授權」清掉，這是必要的。

---

### 2. 修好「Magisk 管理器不彈窗」的根因

magiskd 不是「有裝管理器就會彈窗」，它必須先**辨識**管理器
（`get_manager()`），需要同時滿足：

1. `/data/app/.../<套件名>-*/base.apk` 找得到（讀簽章）
2. `/data/user_de/0/<套件名>` 存在（讀 uid）
3. `/debug_ramdisk/stub.apk` 的憑證 == 管理器 APK 的憑證

#### 4.6 的 bug

4.6 用這個路徑找 stub.apk：

```
/data/app/com.topjohnwu.magisk-*/base.apk
```

Android 11 以後的實際路徑是：

```
/data/app/~~<隨機>/com.topjohnwu.magisk-<隨機>/base.apk
```

所以 **stub.apk 根本沒複製成功**，`trusted_cert` 是空的。

更嚴重的是：Magisk 30.x 正式版預設開啟 `check-signature`，
`check_orig()` 一旦發現憑證不符，會**直接卸載管理器**：

```
if cert.is_empty() || cert != self.trusted_cert {
    uninstall_pkg("com.topjohnwu.magisk");   // release build
}
```

4.6 因為「全部預授權」，`get_manager()` 從來沒被呼叫，所以沒踩到；
4.7 一拿掉預授權就會踩。這次已經處理。

#### 4.7 的做法

1. 從 `/data/system/packages.list` 找管理器套件：
   * 優先用 `com.topjohnwu.magisk`
   * 找不到就用名稱含 `magisk` 的套件
   * 可用 `/data/adb/dfroot/manager.txt`（一行套件名）手動指定
2. 用套件名找真正的 `base.apk`（`/data/app/*/<pkg>-*/base.apk`、
   `/data/app/*/*/<pkg>-*/base.apk`）。
3. 讀 APK 結尾註解裡的 `versionCode`（Magisk 打包時會寫入）。
   * 只有 `versionCode >= 內建 magisk（30700）` 才複製成
     `/debug_ramdisk/stub.apk` 並開啟彈窗模式。
   * 太舊的管理器會被 Magisk 移除，所以寧可先不開。
4. `/data/user_de/0/<pkg>` 不存在時，用 packages.list 的 uid 建立（700）。
5. 管理器套件**不是** `com.topjohnwu.magisk`（Alpha / Kitsune / 其他 fork）時：
   * 額外建立 `/data/user_de/0/<pkg>/dyn/current.apk`（同一份 APK）
   * 寫入 `settings.requester = <pkg>`
   * 這樣 `check_stub()` + `check_dyn()` 就能認得它，不需要重編 magiskd。
6. 管理器 APK 另外備份到 `/data/adb/dfroot/manager.apk`，
   万一被卸載可以 `pm install -r /data/adb/dfroot/manager.apk` 還原。

---

### 3. `am` 卡死保護（CPU 爆走）

Magisk 的 `app_request()` 用 `am start` 呼叫管理器，程式碼長這樣：

```rust
loop {
    if let Ok(output) = cmd.output() && !output.stdout.is_empty() {
        break;
    }
}
```

只要 `am` 完全跑不起來（stdout 永遠是空的），就是**無窮迴圈**，
這就是 4.5 讓 magiskd / system_server 吃滿 CPU 的原因。

4.7 做兩件事：

1. 部署時（enforcing 已開啟）在 `magisk` domain 實際跑一次
   `app_process ... com.android.commands.am.Am`：
   * 成功 → `AM_OK=1`，維持 `enforce magisk`
   * 失敗 → 退回 `permissive magisk`（上游 Magisk 的預設值），
     系統其餘部分仍是 enforcing，並在 log 寫明原因
2. 安裝 watchdog：`/data/adb/dfroot/am-guard.sh`
   * 每 30 秒掃一次 `/proc`
   * 殺掉存活超過 120 秒的 `com.android.commands.am.Am` /
     `com.android.commands.content.Content` helper
   * 同時複製到 `/data/adb/service.d/`，開機由 `magisk --service` 執行
   * log：`/data/adb/dfroot/am-guard.log`

---

### 4. 保留 4.6 已修好的 su 部分（沒有動）

* 不建立 `/debug_ramdisk/.magisk/pts`（空目錄會讓 su 死於
  `Received unexpected number of fds: expected=1 actual=255`）
* `/system/xbin/magisk` 是 symlink（Magisk 30.x `check-client` 比對 inode）
* `/system/xbin/su` 是 shell wrapper（kernel channel → `magisk su`）
* SELinux 真 enforcing：`setenforce 1` + `--print-rules` 驗證
  `permissive magisk` 已清除 + AVC 活體檢測（`AVC_LIVE`）

---

## 二、部署後要看的 log

位置：`/data/user_de/0/df.root/deploy.log`
（App 畫面也會即時顯示）

### 管理器辨識

```
--- magisk manager ---
bundled magisk versionCode: 30700
manager pkg=com.topjohnwu.magisk uid=10xxx apk=/data/app/~~xxxx/com.topjohnwu.magisk-yyyy/base.apk
manager APK versionCode=30700
manager de dir: drwx------ ... /data/user_de/0/com.topjohnwu.magisk
stub.apk <- /data/app/~~xxxx/com.topjohnwu.magisk-yyyy/base.apk (12345678 bytes)
PROMPT_MODE=1
```

### su 授權名單

```
auto-grant uids: 10xxx 2000
```

（10xxx 是 `df.root` 的 uid；沒有其他 App）

### 結果區塊

```
=== RESULT ===
enforcing:      Enforcing
avc live:       1 (0 = avc_has_perm patched -> fake enforcing)
magisk domain permissive: 0 (1 = upstream default fallback; rest of system still enforcing)
manager:        com.topjohnwu.magisk uid=10xxx dialog=1 (1 = su dialog enabled)
am helper:      1 (1 = magiskd can spawn the manager intent)
auto-grant:     10xxx 2000
pty su (pre/post): 1 / 1
dfroot channel: closed
```

* `dialog=1` → 彈窗模式已開啟
* `dialog=0` → 找不到可用管理器，會退回 4.6 的預授權（log 有 WARN）
* `am helper=1` → magiskd 叫得動管理器
* `am helper=0` → 自動退回 `permissive magisk`（su 仍可用）

---

## 三、測試方法

1. 重開機（ExploitRunner 看到 `/dev/df` 就不會再跑）。
2. 開 DFRoot → 部署（這次最多等 360 秒）。
3. 開一個「不在名單」的 App（例如 MT Manager）執行 `su`。
4. 正常應該跳出 Magisk 的「授予 su 權限？」視窗。
   選「允許」，需要的話勾「記住選擇」。
5. 之後再 `su` 就不會再問（Magisk 會自己寫入 `policies`）。

### 如果還是沒彈窗

依序檢查：

1. `deploy.log` 的 `manager pkg=` 是不是你實際安裝的管理器。
2. 用 `pm list packages | grep -i magisk` 確認套件名。
3. 如果管理器不是 `com.topjohnwu.magisk`：
   把套件名寫進 `/data/adb/dfroot/manager.txt`（一行），重跑部署。
4. 管理器版本必須 ≥ 30.7（versionCode 30700）。
   * `manager APK versionCode=` 小於 `bundled magisk versionCode` 就是太舊。
   * log 會出現 `WARN: no usable manager APK`。
   * 更新 Magisk App 後重跑部署即可。
5. 確認 `/data/user_de/0/<pkg>` 存在（log 有 `manager de dir:`）。

---

## 四、想讓某些 App 不跳窗

編輯 `/data/adb/dfroot/presu.list`，一行一個 uid：

```
# uid   package（# 後面是註解）
2000    adb shell
10123   bin.mt.plus
```

存檔後重跑部署。預設內容只有註解，也就是「只有 df.root 和 2000 不用問」。

> 查 uid：`dumpsys package <套件名> | grep userId=`
> 或看 `/data/system/packages.list` 第二欄。

---

## 五、已知限制

* magiskd 內寫死的管理器套件名是 `com.topjohnwu.magisk`。
  其他 fork 是靠 `settings.requester` + `dyn/current.apk` 模擬「隱藏管理器」，
  少數 fork 若攔截 provider / intent 的方式不同，可能仍無法彈窗，
  此時請把 `manager.txt` 指到官方 Magisk App。
* 管理器版本比內建 magisk 舊時，Magisk 會卸載它（上游行為）。
  4.7 已提前擋住（不開彈窗模式），並保留
  `/data/adb/dfroot/manager.apk` 供還原。
* LKM 的 `dfroot-android12-4.19.ko` 仍是舊版（本機沒有 4.19 編譯環境），
  不影響這次的使用者空間修正。
