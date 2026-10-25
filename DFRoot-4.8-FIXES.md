# DFRoot 4.8.4 修正說明（DFRoot + Magisk）

## 版本與產物

- 版本：**4.8.4**
- versionCode：**412**
- 套件：`df.root`
- ABI：`arm64-v8a`
- APK：`DFRoot_4.8.4.apk`
- 大小：**5,496,631 bytes**
- SHA-256：**`EF088686A6D84F951D3A243E57BC77A997F61B2383E7F7FC328EB78A50DF26BB`**
- 簽章：Android Debug certificate
  - SHA-256：`2555816082595d99a8f294ac2539300e0d7cad6f50040a37ec19d46c20fdb5cf`

這個 APK 必須以同一個 debug 簽章覆蓋安裝；不需要清除資料。

## 4.8.4 重點：vendor batch helper 卡住已修正

4.8.3 在 `vendor io: batched helper (1 exec per operation)` 之後卡住，根因是
batch helper 繼承了控制 pipe 的**寫入端**：父程序關閉自己的寫入端時，helper
仍持有另一份，永遠等不到 EOF，最後 `vs_close()` 的 `waitpid()` 無限等待。

4.8.4 的修正：

- helper 啟動時關閉所有不需要的繼承 fd，特別是控制 pipe 的寫入端。
- batch helper 啟動後先做一次 16 bytes 讀取探測；失敗就自動切到
  legacy per-block helper，不再進入卡死狀態。
- batch 讀寫加上 5 秒 timeout 與 helper 存活檢查；失敗會記錄原因並
  fallback，不會無限 block。
- `vs_close()` 最多等 500 ms，之後直接殺掉 helper，避免 shutdown 卡住。
- legacy fallback 前會確認 `crash_dump64` helper 已重新套用；若無法套用
  就明確中止，不會用原廠 `crash_dump64` 執行 helper 參數。

如果 4.8.3 已經卡住，**直接正常重開機**即可；注入只改 page cache，磁碟上的
vendor library 沒有被改寫。重開機後再安裝 4.8.4 重試。

若 4.8.4 仍失敗，日誌會出現 `batch helper probe failed`、
`batch helper exited (...)`、`switching to per-block helper` 或
`cannot restore the crash_dump64 helper` 等明確訊息，請把 `deploy.log` 傳回。

## 0. 4.8.3 的變更：可選的 LSPosed / Zygisk Next

4.8.3 **一般部署仍然不會重啟 zygote**。只有當設定中的
**Auto Soft Reboot** 開啟，而且 `zygisk_lsposed` 與 `zygisksu` 兩個模組都
已安裝且啟用時，部署才會進入 LSPosed 模式。

### 0.1 為什麼要改

DFRoot 在 `magisk --post-fs-data` 期間會暫時隱藏所有模組的
`post-fs-data.sh`，避免模組在 DFRoot 不知情的情況下啟動 Zygisk daemon。
副作用是：

- Zygisk Next 的 `zygiskd` 沒有啟動；
- LSPosed 的 `lspd` 沒有啟動；
- 此時手動殺 zygote 只會得到新的 zygote，但沒有注入器、也沒有 `lspd`，
  所以 LSPosed 仍然不會掛載。

4.8.3 把這個流程改成「先啟動兩個 daemon，再做一次乾淨的 zygote 重啟」。

### 0.2 執行順序

1. 檢查 `zygisk_lsposed` 與 `zygisksu` 都存在、沒有 `disable`/`remove`。
2. 拒絕在 Magisk 內建 Zygisk 的 `zygiskd` 正在執行時繼續（避免兩個注入器）。
3. 暫時設為 permissive，啟動 LSPosed 的 `lspd`：
   - 這台 ROM 沒有 `/system/bin/app_process`，只有 `app_process64`；
   - 部署會把模組的 `daemon` 複製到
     `/data/user_de/0/df.root/lsposed-daemon`，把 `dir=` 固定到模組目錄，
     並把 `/system/bin/app_process` 換成實際可執行的 `app_process64`。
4. 在 init 的 mount namespace 重新套用 `/debug_ramdisk` 與 `/system/xbin`
   的 Magisk 路徑，讓重啟後的新 zygote / App 仍看得到 `su`。
5. 啟動 Zygisk Next 的 `post-fs-data.sh`，等 `zygiskd`（或舊版的
   `zygisk-ptrace64 monitor`）出現，再跑它的 `service.sh` / service-stage。
6. 再確認 `lspd` 與 Zygisk Next 注入器都還活著。
7. 用**一次** `setprop ctl.restart zygote` 重啟 zygote；不使用
   `kill -9`、也不直接殺 `zygote`。
8. 等新的 zygote / system_server，檢查 `lspd`、`zygiskd` 與 logcat，
   最後恢復 **Enforcing**。

### 0.3 安全與失敗處理

- 任何一個 daemon 沒起來，部署會拒絕重啟 zygote，只留下錯誤訊息。
- Magisk 內建 Zygisk 開著時，會記錄 `LSPOSED_RESULT=builtin_zygisk` 並拒絕；
  請先在 Magisk 設定關閉內建 Zygisk。
- Auto Soft Reboot 沒開時，一般部署不會進入 LSPosed 模式，Final marker 會是
  `lsposed=skipped`，不重啟 zygote（`pref_off` 只是函式內的保險分支）。
- 重啟後若 `lspd` 不見，會再嘗試啟動修補過的 daemon；Zygisk Next 則會等待
  它的 daemon/monitor。
- 這個模式不會修改 boot image；一般重開機即可恢復。若 LSPosed 仍失敗，
  請提供 `deploy.log` 與 LSPosed logcat。

### 0.4 App 仍然不會要求 SU

LSPosed 模式只改變部署腳本以 root 啟動 daemon 的流程；DFRoot App 本身
仍然不執行 `su`、不建立 `df.root` 的 Magisk 授權列。

## 1. 4.8.2 的變更：注入加速與部署日誌修正

### 1.1 注入不再逐區塊 exec（原本約 30 秒）

`libcxx.so` 的 vendor 修補/還原原本每個 16 bytes 區塊都 `fork + exec crash_dump64`
一次（約 1650 次，每次 8–9 ms）。4.8.2 改成三層，依實際權限自動選擇：

1. **direct**：LKM 載入後 SELinux 已由 LKM 處理，App 可以自己
   `open()` / `pread()` / `splice()` 該 vendor 檔案，完全不 exec。
2. **batch**：若 App 直接開檔被拒絕，只啟動**一個** `crash_dump64` helper，
   用 pipe 餵 `R`/`W` 記錄，做完才結束。一次 patch/restore 總共 4 次 exec
   （patch、驗證、restore、驗證），不再是 1650 次。
3. **legacy**：上述都失敗時才回到原本的「每區塊一次 exec」路徑。

因此在正常裝置上注入時間由約 30 秒降到 **1–2 秒**（direct 路徑幾乎全是 syscall）。

### 1.2 修好 vendor 還原「靜默失敗」

內嵌的 4.19 LKM 在 init 時會清掉 `crash_dump64` 的 page cache
（dmesg 的 `cleared page cache for crash_dump64`），使先前寫入的 splice helper
被還原成原廠 binary；之後 helper 讀寫都回傳 0 bytes，日誌只看到
`WARN: /vendor/lib64/libstagefrighthw.so restore failed: -1`。4.8.2：

- 每次要用 helper 前，先確認並**重新套用** splice helper（`reapply_helper()`）。
- patch 與 restore 完成後都用**讀回比對**驗證（`vendor_verify()` /
  `file_matches()`）；KO 寫入內容不符時會自動 rollback 回原內容並中止。
- `crash_dump64` 還原也會驗證。

### 1.3 部署日誌不再出現 binder 假錯誤

- `activity service` 探測改用原生 `cmd activity get-current-user`，並只把
  `Service activity: found` 當成成功（舊的 `grep -q found` 會把 `not found`
  當成 found，出現假的 `ready after 0s`）。
- 若 init worker 真的連不到 activity service（本機 OEM ROM 的
  `Can't find service: activity`），只輸出一行原因與 binder/servicemanager
  診斷，不再重複 `am rc=20`、`monkey rc=253` 三次失敗。
- 這種情況下**不再由部署腳本硬開管理器**，改由 DFRoot App 開啟（見 0.4）。

### 1.4 管理器改由 App 開啟

- 部署腳本把解析到的管理器套件寫入
  `/data/user_de/0/df.root/manager.package`。
- 部署成功後，DFRoot App（前景、binder 正常）讀取該檔並以
  `ACTION_MAIN` / `CATEGORY_LAUNCHER` 啟動管理器。
- 若 init worker 的 activity service 可用，腳本仍會先自己開；兩條路徑不衝突。
- 這與 SU 無關：App 不會執行 `su`，也不會要求授權。

### 1.5 其他

- `dmesg` 的 dfroot 視窗由 10 行放寬到 40 行，可看到 LKM init 的
  `cleared page cache` / SELinux 訊息。
- RESULT 摘要新增 `am transport: ... mode=` 與
  `manager: ... launch=`，可直接看出管理器是由腳本或 App 開啟。

## 2. DFRoot 不再向 Magisk 要求 SU

- 已移除 App 端的 `testSu()`、Magisk 管理器偵測與舊的 `manager.pkg` 授權標記。
- App 不會執行 `su -c`，也不會替 `df.root` 建立 Magisk 授權列。
- 部署腳本只從 **uid 0** 驗證 MagiskSU 是否可用；這是 root 程序檢查，不是 App
  的 SU 請求。
- `manager.package` 只包含管理器套件名稱，用途是「部署後開啟管理器」，不會觸發
  SU 查詢或授權。
- 因此正常部署時不應再出現「DFRoot 要求 SU」的對話框，也不會多出一筆
  `df.root` 的授權紀錄。

## 3. `/data/adb/magisk` 補成完整 Magisk 30.7 檔案集

部署會把下列 **15 個檔案**放進 `/data/adb/magisk`，並逐一確認存在且非空：

```
magisk
magisk32
magisk64
magiskinit
magiskboot
magiskpolicy
init-ld
busybox
stub.apk
addon.d.sh
boot_patch.sh
util_functions.sh
chromeos/futility
chromeos/kernel.keyblock
chromeos/kernel_data_key.vbprivk
```

其中：

- `magisk` 是主要執行檔；`magisk64` 保留以相容舊版管理器與舊資料。
- `init-ld` 是 Magisk 標準安裝的一部分，先前的檔案集漏掉它。
- `chromeos/` 會自動建立。
- 複製前先用 MD5 比對，相同就不重寫；不同才更新。
- 任何一個必要檔案缺少時，部署會直接失敗並輸出
  `incomplete Magisk file set: ...`，不會留下「看起來成功、管理器卻顯示檔案不完整」
  的狀態。

## 4. `/data/adb` 只放 Magisk 檔案

- DFRoot 不再建立 `/data/adb/dfroot`。
- 部署腳本、guard、`manager.apk`、policy 備份、log 與 `xattr_ramdisk` 都移到
  App 的 device-protected 目錄：
  `/data/user_de/0/df.root`。
- 舊版若已留下 `/data/adb/dfroot`，本版**不會自動刪除**，以免刪掉使用者的
  policy 備份；但本版不會再往該目錄寫入新檔案。
- `/data/adb/magisk` 內不會混入 DFRoot 的檔案。

## 5. 一般部署不重啟 zygote；LSPosed 模式才重啟一次

- 只執行一次 Magisk `--post-fs-data`，且執行時讓模組目錄保持可見，讓 Magisk
  正確建立 `module_list` 並掛載模組。
- 在這個階段暫時隱藏 `post-fs-data.d` 與各模組的 `post-fs-data.sh`，避免
  Zygisk Next 等模組在 zygote 已啟動後又執行 late boot script；結束後立即恢復。
- 一般部署不執行 `--service`、`--boot-complete`，也不執行
  `ctl.restart zygote` 或 kill zygote。
- 唯一例外是第 0 節的 LSPosed 模式：Auto Soft Reboot 開啟且兩個模組都啟用時，
  先啟動 `lspd` 與 Zygisk Next，再執行**一次** `setprop ctl.restart zygote`；
  任何一個 daemon 沒起來就拒絕重啟。
- 部署前會先停掉舊的 `magiskd-guard.sh`，避免兩個 guard 競爭模組目錄。

## 6. SU 路徑與 SELinux

- 只保留 Magisk 的 SU 符號連結：
  - `/debug_ramdisk/su -> /debug_ramdisk/magisk`
  - `/system/xbin/su -> /debug_ramdisk/magisk`（若 xbin overlay 可用）
- LSPosed 模式在重啟 zygote 前，會用 `nsenter -t 1 -m` 在 init 的 mount
  namespace 重新套用 `/debug_ramdisk` 與 `/system/xbin`，避免新 zygote/App
  看不到這兩個路徑。
- 不建立舊版 wrapper、`su.legacy` 或第二個 root 執行檔。
- 若舊版留下 `/data/adb/dfroot/su.legacy` 或 `/data/adb/dfroot/su`，只移除這兩個
  過時執行檔；舊 policy 備份不刪。
- 最終全域 SELinux 必須是 **Enforcing**。
- `magisk` domain 保持 permissive，這是上游 Magisk 的正常行為；不等於全域
  permissive。

## 7. 安裝後快速檢查

不需要 adb，直接從檔案管理器覆蓋安裝即可。安裝後可檢查：

1. 執行 DFRoot，選擇 **Magisk (4.19)**，執行部署。
2. App 不應跳出要求 SU 的對話框。
3. Magisk 管理器不再顯示檔案不完整，且首頁可看到 Magisk 版本。
4. `/data/adb/magisk/magisk` 存在。
5. `/data/adb` 下沒有新建的 `dfroot` 目錄。
6. 最終 `getenforce` 為 `Enforcing`。
7. 一般部署時模組清單仍可載入，且 zygote 沒有被重啟。
8. 注入日誌應出現 `vendor io: direct (no helper exec)`（或 batch），且
   `verified: ... restored to the original bytes`。
9. 部署完成後管理器應自動開到模組頁；若日誌顯示
   `manager: launch deferred to DFRoot app`，由 App 接手開啟。
10. （LSPosed 模式）Auto Soft Reboot 開啟、Magisk 內建 Zygisk 關閉、
    `zygisk_lsposed` 與 `zygisksu` 都啟用後再部署。日誌應出現
    `LSPosed: daemon ready`、`LSPosed: post-restart result=ok`；LSPosed
    Manager 應顯示已啟用。若出現 `builtin_zygisk`、`pref_off`、
    `lspd_failed` 或 `zn_failed`，依日誌指示修正後再試。

## 8. 已知限制

- 本版仍需要 Magisk 管理器版本不低於內建的 Magisk 30.7（versionCode 30700）。
- 若裝置已有舊的 `/data/adb/dfroot`，請自行確認是否需要保留裡面的 policy 備份；
  本版不會主動刪除它。
- 若 Magisk 管理器的簽章與目前安裝的 APK 不一致，請先安裝相符的管理器，否則
  `trusted_cert` / `stub.apk` 檢查會失敗。
- 內嵌的 4.19 KO 仍是舊版映像（本機沒有 kernel tree/toolchain 可重建），因此
  LKM 載入時仍會清掉 `crash_dump64` 的 page cache、並以舊方式處理 AVC；4.8.2
  是在這個前提下用「重新套用 helper + 讀回驗證」來保證正確性。

## 9. 4.8.4 的 batch helper 修正細節

### 9.1 現象

4.8.3 日誌停在 `vendor io: batched helper (1 exec per operation)`，之後沒有
`patched ...`、`verified ...` 或錯誤訊息，App 一直等待。

### 9.2 根因

`vs_start_batch()` 用 `clone(SIGCHLD | CLONE_VFORK | CLONE_VM)` 啟動 helper，
但 child 只 dup2 了 stdin/stdout/control/ack，沒有關掉從父程序繼承的其他 fd。
其中包含控制 pipe 的寫入端 `ctrl[1]`。父程序在 `vs_close()` 關閉自己的
`ctrl_wr` 時，helper 仍持有同一 pipe 的寫入端，所以 helper 的
`read(CTRL_FD)` 永遠等不到 EOF，`vs_close()` 的 `waitpid(pid, ..., 0)` 就
永遠不返回。實際上 vendor patch 可能已完成，日誌只是停在 patch 前的 banner。

### 9.3 修正

- child 先以 `F_DUPFD` 保存 ctrl/ack/packet 三個端點，再關閉 0..255 中所有
  不需要的 fd（包含 `ctrl[1]`、`ack[0]`、`pipe_rd`），最後才 dup2 到
  1/3/4 並 exec。
- `vs_start_batch()` 啟動後用 `waitpid(WNOHANG)` 檢查 helper 是否在 exec
  前就退出。
- `vs_open()` 啟動 batch helper 後先讀 vendor offset 0 的 16 bytes 做 probe；
  probe 失敗就 kill helper、重建 packet pipe、重新套用 helper，改用 legacy。
- `vs_read()` / `vs_write()` 的 batch 路徑改用 `poll()` + 5 秒 deadline，
  每 200 ms 檢查 helper 是否還活著；失敗會印出原因並 fallback。
- `vs_write()` fallback 時重建 packet pipe，再重送同一個 16-byte block。
- `vs_close()` / `vs_stop_batch()` 最多等 500 ms，之後 SIGKILL helper，
  並以 `waitpid` 收回；不會再無限等待。
- legacy fallback 前確認 helper 已重新套用；若 `reapply_helper()` 失敗就
  中止，避免原廠 `crash_dump64` 被當成 helper 執行而卡在 `waitpid`。

### 9.4 卡住後的處理

4.8.3 卡住時直接**正常重開機**。注入只修改 page cache；原始 vendor library
與 crash_dump64 的磁碟內容沒有被改寫。重開機後安裝 4.8.4 再部署即可。
