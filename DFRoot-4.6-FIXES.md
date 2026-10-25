# DFRoot 4.6 — 修正內容與重建說明

本版只動「使用者空間」為主（deploy 腳本、su、Java、版本號），另外把 LKM 裡
「讓 SELinux 假強制」的那段程式碼移除（需要重新編譯 4.19 的 .ko 才會生效）。

---

## 一、四個真正的問題

### 1. 互動式 `su` 直接失敗
```
Received unexpected number of fds: expected=1 actual=255
```
舊腳本建立了 `/debug_ramdisk/.magisk/pts` 這個「空目錄」。
只要呼叫 `su` 的行程有 TTY（也就是人手打 `su`），Magisk 的子行程就會去開
`$MAGISKTMP/.magisk/pts/ptmx`；開不起來就 `exit 255`，而 255 這個結束碼
被用戶端當成「fd 數量」讀進來 → 就是那句 expected=1 actual=255。

4.6：**不再建立那個目錄**（如果殘留就刪掉），Magisk 改用 `/dev/pts`。

### 2. `magiskd` / `system_server` 吃 CPU
`policies` 表只有 uid 2000 一筆。其他 uid（MT 管理器…）查不到 → 走
`SuPolicy::Query` → `app_request()` → `am start`，而 `am start` 是
`loop { … }` 無窮重試，每次 `su` 都留一個 `app_process` 在跑，順便把
`system_server` 拖上去。

4.6：把 `/data/system/packages.list` 裡**所有 uid**（加 0/1000/1001/2000
與本 App）預先寫入 `policies`，`policy=2`（允許）、`logging=0`、
`notification=0`（不記錄、不跳通知）。`connect_app()` 對這種列直接 return，
不會再開 `am`。

### 3. SELinux「顯示 Enforcing，其實全開」
- 舊腳本的自測一定失敗（問題 1），失敗分支又執行
  `magiskpolicy --live "permissive magisk"`。
- `--magisk` 本身也會加 `permissive magisk`。
- 更關鍵的是 LKM 把 `avc_has_perm` / `avc_has_perm_noaudit` 改成
  **永遠回 0**，所以整個系統的 SELinux 檢查全部放行，`getenforce` 卻還是
  印 Enforcing → 這就是「偽裝強制」。

4.6：
- LKM 移除 AVC patch（只保留 `selinux_state` 的 permissive 寫入，讓部署
  過程能跑；最後 `setenforce 1` 會真的恢復強制）。
- 腳本會把 `permissive magisk` 清掉、用 `--print-rules` 驗證、並且
  **沒有任何自動回退成 permissive 的路徑**。
- 加了「AVC 活體檢測」：`--magisk` 會加
  `deny all kernel:security load_policy`，所以在 `setenforce 1` 之後，
  `magiskpolicy --live` **必須失敗**。若它成功 → `AVC_LIVE=0`
  → 就是 LKM 還在 patch AVC（假強制）。
- 只有當「強制」真的把 su 弄壞時，才退回 Magisk 官方的
  `permissive magisk`（只限 magisk 這個 domain，系統其他部分仍然強制），
  並在 log 明講 `DOMAIN_PERM=1`。

### 4. `su` 被 Magisk 拒絕（ACCESS_DENIED）
舊腳本把 `/system/xbin/magisk` 用 `cp` 複製過去。Magisk 30.x 的
`check-client` 會比對 `/proc/<pid>/exe` 的 `st_dev`+`st_ino` 是否等於
daemon 自己的執行檔；複製檔 inode 不同 → 拒絕。

4.6：`/system/xbin/magisk` 改成**符號連結**到 `/debug_ramdisk/magisk`
（同一個 inode），`su` 則是純 shell 腳本。

---

## 二、su 的兩條路徑

`/system/xbin/su`（以及 `/data/adb/dfroot/su`、`/debug_ramdisk/su`）是腳本：

1. **核心通道**：`printf '1' > /proc/dfroot_su`
   → LKM 用 `prepare_kernel_cred(NULL)` 直接把「寫入的行程」變成 uid 0 /
   `u:r:init:s0`，再由腳本 `exec /system/bin/sh`。
   部署成功並驗證 su 可用後，腳本會把節點關掉（`cat /proc/dfroot_su`
   → LKM 記 `escalation node closed`）。關掉後這條路自然失效。
   `/system/xbin/.dfroot_channel` 這個小檔案記錄 `open`/`closed`，
   腳本會先讀它，避免對已關閉的節點亂寫而產生 avc denial。
2. **MagiskSU**：`exec /debug_ramdisk/magisk su "$@"`（參數原封不動）。
   Magisk 的 `exec_root_shell()` 會 `clearenv()` 後重新匯入呼叫端的
   `/proc/<pid>/environ`，所以 **PATH 會保留** → MT 終端裡的
   `sdcard` 這類自家 term/bin 指令在 `su` 之後仍然找得到、跑得動。

---

## 三、怎麼看 `deploy.log`

| 欄位 | 意義 |
| --- | --- |
| `avc live: 1` | AVC 沒被 patch，`setenforce 1` 是**真的**強制 |
| `avc live: 0` | LKM 還在 patch AVC → 只有換掉 4.19 的 .ko 才能真的強制 |
| `magisk domain permissive: 0` | magisk domain 也是強制的 |
| `magisk domain permissive: 1` | 退回官方預設（只有 magisk domain permissive，其他仍強制） |
| `pty su (pre/post): 1 / 1` | 互動式 su（有 TTY）在「permissive 時 / 強制後」都成功 |
| `dfroot channel: closed` | `/proc/dfroot_su` 已關閉（dmesg 有 `escalation node closed`） |
| `su wrapper: … (xbin_ok=1)` | `/system/xbin/su` 已安裝 |

dmesg 可交叉檢查：
```
dmesg | grep -E 'dfroot|avc.*magisk'
```

---

## 四、重建

### 1. APK（必要）
assets 改了，一定要重編：

```bash
./gradlew :app:assembleRelease      # 或 assembleDebug（debug 免簽章設定）
```
輸出：`app/build/outputs/apk/release/DFRoot_4.6.apk`
（`app/src/main/jni/ko/*.ko` 是用 `.incbin` 內嵌，重編 APK 會一併帶新的 .ko。）

> 若用 debug 簽章，請先解除安裝舊版（簽章不同）。

### 2. 4.19 的 LKM（強烈建議，只有它能讓「真強制」成立）
```bash
make ko-4.19 KDIR_419=/path/to/android12-4.19-kernel
```
（跟原本一樣的 build 環境即可；`lkm/dfroot.c` 這次只刪掉 AVC patch 那兩段。）
編好後覆蓋 `app/src/main/jni/ko/dfroot-android12-4.19.ko`，再重編 APK。

### 3. 安裝前先重開機
`ExploitRunner` 只要看到 `/dev/df` 存在就會拒絕再跑（避免重複 hook），
所以**先重開機**，再開 4.6 部署。

---

## 五、已知限制

- 沒有重編 4.19 LKM 時，`AVC_LIVE` 一定是 0：`getenforce` 會顯示
  Enforcing，但那是舊 .ko 的 patch 造成的，log 會誠實寫出來。
- `/system/xbin` 是符號連結的機型不會被覆蓋（腳本會警告），此時 su 只放在
  `/data/adb/dfroot/su`。
- magiskd 啟動時會把 `/debug_ramdisk` 下的檔案改標成 `system_file`，
  腳本在 daemon 起來之後會再 `chcon` 回 `magisk_file`（順序很重要）。
