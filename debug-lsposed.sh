#!/system/bin/sh
# DFRoot LSPosed white-screen diagnostics.
#
# Run on the phone as root:
#   su -c 'sh /sdcard/Download/debug-lsposed.sh'
#
# It reproduces the manager launch once, takes a screenshot/UI dump, captures
# logcat (before and after), LSPosed/Zygisk logs, SELinux denials and a manager
# process backtrace. Work files live in /data/local/tmp/lsposed-debug-* and the
# final archive is copied to /sdcard/Download/lsposed-debug-*.
# Review the archive before sharing: logcat can contain app names.

PATH=/data/adb/magisk:/system/bin:/system/xbin:/vendor/bin:$PATH
export PATH

PKG=org.lsposed.manager
ACT=org.lsposed.manager.ui.activity.MainActivity
STAMP=$(date +%Y%m%d-%H%M%S 2>/dev/null || date)
# Write diagnostics under /data/local/tmp first. On this ROM `/system/bin/cmd`
# can run in the system_server SELinux domain; redirecting its stdout directly
# to FUSE (/sdcard) makes the command fail with a misleading "Failed
# transaction" before it can report the real result.
BASE=/data/local/tmp
OUT="$BASE/lsposed-debug-$STAMP"

say() { echo "[*] $*"; }
have() { command -v "$1" >/dev/null 2>&1; }

if [ "$(id -u 2>/dev/null)" != "0" ]; then
    echo "ERROR: run this script as root (su -c 'sh $0')."
    exit 1
fi

if ! mkdir -p "$OUT" 2>/dev/null; then
    BASE=/sdcard/Download
    OUT="$BASE/lsposed-debug-$STAMP"
    mkdir -p "$OUT" 2>/dev/null || {
        echo "ERROR: cannot create output directory"
        exit 1
    }
fi
mkdir -p "$OUT/dropbox" "$OUT/tombstones" "$OUT/anr" "$OUT/lspd" 2>/dev/null
umask 022

# Capture command output through a shell pipe instead of letting a command
# (notably system/bin/cmd) write directly to the output file. The system_server
# SELinux domain is denied writes to app/FUSE storage on this ROM.
dump() {
    _df=$1
    shift
    _do=$("$@" 2>&1)
    _dr=$?
    {
        echo "\$ $*"
        printf '%s\n' "$_do"
        [ "$_dr" -ne 0 ] && echo "rc=$_dr"
    } >"$OUT/$_df"
}

dump_sh() {
    _df=$1
    _ds=$2
    _do=$(/system/bin/sh -c "$_ds" 2>&1)
    _dr=$?
    {
        echo "\$ $_ds"
        printf '%s\n' "$_do"
        [ "$_dr" -ne 0 ] && echo "rc=$_dr"
    } >"$OUT/$_df"
}

say "output: $OUT"

# ---------------------------------------------------------------------------
# Basic state
# ---------------------------------------------------------------------------
{
    echo "date=$(date 2>/dev/null)"
    echo "id=$(id 2>/dev/null)"
    echo "uname=$(uname -a 2>/dev/null)"
    echo "fingerprint=$(getprop ro.build.fingerprint 2>/dev/null)"
    echo "sdk=$(getprop ro.build.version.sdk 2>/dev/null)"
    echo "release=$(getprop ro.build.version.release 2>/dev/null)"
    echo "abi=$(getprop ro.product.cpu.abi 2>/dev/null)"
    echo "native_bridge=$(getprop ro.dalvik.vm.native.bridge 2>/dev/null)"
    echo "enforcing=$(getenforce 2>/dev/null)"
    echo "manager_pkg=$PKG"
    echo "manager_activity=$ACT"
} >"$OUT/basic.txt" 2>&1

say "capturing package and process state"
dump package-path.txt /system/bin/pm path "$PKG"
dump package-list.txt /system/bin/pm list packages -f
dump package-disabled.txt /system/bin/pm list packages -d
dump package-enabled.txt /system/bin/pm list packages -e
dump package-resolve.txt /system/bin/cmd package resolve-activity --brief \
    -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -p "$PKG"
dump package-dump.txt /system/bin/dumpsys package "$PKG"
dump activity-exit-info.txt /system/bin/dumpsys activity exit-info "$PKG"
dump activity-processes.txt /system/bin/dumpsys activity processes
dump activity-top-before.txt /system/bin/dumpsys activity top
dump window-before.txt /system/bin/dumpsys window windows
dump display.txt /system/bin/dumpsys display
dump ps-before.txt /system/bin/ps -A -o PID,PPID,USER,NAME,ARGS
dump zygiskd-status.txt /data/adb/modules/zygisksu/bin/zygiskd status
dump zygisk-next-prop.txt /system/bin/cat /data/adb/modules/zygisksu/module.prop
dump zygisk-module-ls.txt /system/bin/ls -la /data/adb/modules/zygisksu
dump lsposed-prop.txt /system/bin/cat /data/adb/modules/zygisk_lsposed/module.prop
dump lsposed-module-ls.txt /system/bin/ls -la /data/adb/modules/zygisk_lsposed
dump lsposed-manager-apk-ls.txt /system/bin/ls -l /data/adb/lspd/manager.apk /data/adb/modules/zygisk_lsposed/manager.apk
dump lspd-ls.txt /system/bin/ls -la /data/adb/lspd
dump lspd-log-ls.txt /system/bin/ls -la /data/adb/lspd/log
dump lspd-monitor.txt /system/bin/cat /data/adb/lspd/monitor
dump dfroot-dir.txt /system/bin/ls -la /data/user_de/0/df.root
dump dfroot-lsposed-done.txt /system/bin/cat /data/user_de/0/df.root/lsposed.done
dump dfroot-lsposed-restart.txt /system/bin/cat /data/user_de/0/df.root/lsposed.restart
dump dfroot-deploy.txt /system/bin/cat /data/user_de/0/df.root/deploy.log
dump avc-dmesg.txt /system/bin/sh -c "dmesg 2>/dev/null | grep -iE 'avc: denied|selinux' | tail -n 300"
dump avc-logcat-before.txt /system/bin/sh -c \
    "logcat -d -b all -v threadtime 2>/dev/null | grep -iE 'avc: denied|lsposed_file|org\.lsposed' | tail -n 300"

# Copy LSPosed verbose logs (latest three).
say "copying LSPosed logs"
for _lf in $(/system/bin/ls -t /data/adb/lspd/log/verbose_*.log 2>/dev/null | /system/bin/head -n 3); do
    [ -f "$_lf" ] && /system/bin/cp -f "$_lf" "$OUT/lspd/" 2>/dev/null
done

# Copy module scripts that affect startup.
for _mf in module.prop sepolicy.rule service.sh post-fs-data.sh customize.sh; do
    [ -f "/data/adb/modules/zygisk_lsposed/$_mf" ] && \
        /system/bin/cp -f "/data/adb/modules/zygisk_lsposed/$_mf" "$OUT/lspd/" 2>/dev/null
done

# ---------------------------------------------------------------------------
# Capture pre-launch logcat, then reproduce the manager launch once.
# ---------------------------------------------------------------------------
say "capturing logcat before launch"
/system/bin/logcat -d -b all -v threadtime -t 30000 >"$OUT/logcat-before.txt" 2>&1
/system/bin/logcat -d -b crash -v threadtime >"$OUT/logcat-crash-before.txt" 2>&1
/system/bin/logcat -d -b events -v threadtime -t 10000 >"$OUT/logcat-events-before.txt" 2>&1

say "force-stopping and relaunching $PKG"
/system/bin/am force-stop "$PKG" >"$OUT/manager-force-stop.txt" 2>&1
sleep 1
/system/bin/logcat -c >/dev/null 2>&1 || true

_launch_out=$(
    {
        echo "### am start -W"
        if have timeout; then
            timeout 30 /system/bin/am start --user 0 -W -n "$PKG/$ACT"
        else
            /system/bin/am start --user 0 -W -n "$PKG/$ACT"
        fi
        _arc=$?
        echo "am_rc=$_arc"
        if [ "$_arc" != "0" ]; then
            echo "### fallback: cmd activity start-activity -W"
            if have timeout; then
                timeout 30 /system/bin/cmd activity start-activity --user 0 -W -n "$PKG/$ACT"
            else
                /system/bin/cmd activity start-activity --user 0 -W -n "$PKG/$ACT"
            fi
            echo "cmd_rc=$?"
        fi
    } 2>&1
)
printf '%s\n' "$_launch_out" >"$OUT/manager-launch.txt"

# Give the Compose UI time to draw or fail.
sleep 10

say "capturing screenshot and UI hierarchy"
/system/bin/screencap -p "$OUT/screen.png" >"$OUT/screencap.txt" 2>&1
if have timeout; then
    timeout 20 /system/bin/uiautomator dump "$OUT/ui.xml" >"$OUT/uiautomator.txt" 2>&1
else
    /system/bin/uiautomator dump "$OUT/ui.xml" >"$OUT/uiautomator.txt" 2>&1
fi

say "capturing logcat after launch"
/system/bin/logcat -d -b all -v threadtime -t 40000 >"$OUT/logcat-after.txt" 2>&1
/system/bin/logcat -d -b crash -v threadtime >"$OUT/logcat-crash-after.txt" 2>&1
/system/bin/logcat -d -b events -v threadtime -t 15000 >"$OUT/logcat-events-after.txt" 2>&1
{
    echo "### filtered LSPosed/Zygisk/Java/SELinux"
    /system/bin/grep -iE \
        'lsposed|org\.lsposed|lspd|zygisk|AndroidRuntime|FATAL EXCEPTION|ANR in|JNI DETECTED|nativeSpecializeAppProcess|avc: denied|SELinux' \
        "$OUT/logcat-after.txt" 2>/dev/null
} >"$OUT/logcat-lsposed.txt" 2>&1
{
    echo "### manager process lines"
    /system/bin/grep -iE 'org\.lsposed|LSPosedManager' "$OUT/logcat-after.txt" 2>/dev/null
} >"$OUT/logcat-manager.txt" 2>&1
{
    echo "### graphics/window lines"
    /system/bin/grep -iE \
        'OpenGLRenderer|HWUI|Skia|SurfaceFlinger|Choreographer|EGL|RenderThread|BLAST|Compose|WindowManager|ActivityTaskManager|InputDispatcher' \
        "$OUT/logcat-after.txt" 2>/dev/null
} >"$OUT/logcat-graphics-window.txt" 2>&1

dump activity-top-after.txt /system/bin/dumpsys activity top
dump activity-activities-after.txt /system/bin/dumpsys activity activities
dump window-after.txt /system/bin/dumpsys window windows
dump activity-processes-after.txt /system/bin/dumpsys activity processes
dump surfaceflinger-list.txt /system/bin/dumpsys SurfaceFlinger --list
dump gfxinfo.txt /system/bin/dumpsys gfxinfo "$PKG"
dump meminfo.txt /system/bin/dumpsys meminfo "$PKG"
dump activity-exit-info-after.txt /system/bin/dumpsys activity exit-info "$PKG"

# Manager process backtrace if it is still alive.
MPID=$(/system/bin/pidof "$PKG" 2>/dev/null | /system/bin/awk '{print $1}')
if [ -n "$MPID" ]; then
    {
        echo "pid=$MPID"
        echo "--- /proc/$MPID/status"
        /system/bin/cat "/proc/$MPID/status" 2>/dev/null
        echo "--- cmdline"
        /system/bin/tr '\0' ' ' <"/proc/$MPID/cmdline" 2>/dev/null
        echo
        echo "--- wchan"
        /system/bin/cat "/proc/$MPID/wchan" 2>/dev/null
        echo
        echo "--- stack"
        /system/bin/cat "/proc/$MPID/stack" 2>/dev/null
    } >"$OUT/manager-process.txt" 2>&1
    say "dumping manager native backtrace (debuggerd)"
    if have timeout; then
        timeout 20 /system/bin/debuggerd -b "$MPID" >"$OUT/manager-backtrace.txt" 2>&1 || true
    else
        /system/bin/debuggerd -b "$MPID" >"$OUT/manager-backtrace.txt" 2>&1 || true
    fi
else
    echo "manager process not running after launch" >"$OUT/manager-process.txt"
fi

# ---------------------------------------------------------------------------
# Crash/ANR/tombstone and SELinux context artifacts.
# ---------------------------------------------------------------------------
say "copying matching dropbox/tombstone/ANR artifacts"
for _df in /data/system/dropbox/*; do
    case "$_df" in
        *.txt) ;;
        *) continue ;;
    esac
    if /system/bin/grep -qiE 'org\.lsposed|lspd|lsposed' "$_df" 2>/dev/null; then
        /system/bin/cp -f "$_df" "$OUT/dropbox/" 2>/dev/null
    fi
done

_i=0
for _tf in $(/system/bin/ls -t /data/tombstones/tombstone_* 2>/dev/null | /system/bin/head -n 5); do
    [ -f "$_tf" ] || continue
    /system/bin/cp -f "$_tf" "$OUT/tombstones/" 2>/dev/null
    _i=$((_i + 1))
done

_i=0
for _af in $(/system/bin/ls -t /data/anr/anr_* 2>/dev/null | /system/bin/head -n 3); do
    [ -f "$_af" ] || continue
    /system/bin/cp -f "$_af" "$OUT/anr/" 2>/dev/null
    _i=$((_i + 1))
done

# SELinux labels around LSPosed; -Z is not available on every ROM.
{
    echo "### ls -laZ /data/adb/lspd"
    /system/bin/ls -laZ /data/adb/lspd 2>&1
    echo
    echo "### ls -laZ /data/adb/modules/zygisk_lsposed"
    /system/bin/ls -laZ /data/adb/modules/zygisk_lsposed 2>&1
    echo
    echo "### ls -laZ /data/adb/modules/zygisksu"
    /system/bin/ls -laZ /data/adb/modules/zygisksu 2>&1
} >"$OUT/selinux-labels.txt" 2>&1

dmesg 2>/dev/null | grep -iE 'avc: denied|selinux' | tail -n 500 >"$OUT/avc-dmesg-after.txt" 2>&1

# ---------------------------------------------------------------------------
# Summary and archive.
# ---------------------------------------------------------------------------
{
    echo "DFRoot LSPosed white-screen diagnostics"
    echo "Generated: $(date 2>/dev/null)"
    echo "Output: $OUT"
    echo
    echo "The script force-stopped and relaunched $PKG/$ACT, then captured:"
    echo "  logcat-before/after, crash/events, screenshot, UI hierarchy,"
    echo "  manager process/backtrace, package state, LSPosed/Zygisk logs,"
    echo "  DFRoot deploy log, SELinux/AVC, dropbox, tombstones, ANR."
    echo
    echo "Share the whole .tar.gz. If the archive is missing, share the folder."
    echo
    echo "Quick checks:"
    echo "  - package-path.txt: is the manager installed?"
    echo "  - manager-launch.txt: did am report an error?"
    echo "  - logcat-lsposed.txt: Java crash / JNI / ANR / SELinux denial"
    echo "  - lspd/verbose_*.log: 'binder received' present?"
    echo "  - manager-backtrace.txt: native stack if the UI is stuck"
} >"$OUT/README.txt" 2>&1

ARCHIVE="$OUT.tar.gz"
if have tar; then
    say "creating archive"
    tar -czf "$ARCHIVE" -C "$OUT" . 2>/dev/null || ARCHIVE=""
fi
if [ -n "$ARCHIVE" ] && [ -f "$ARCHIVE" ]; then
    chmod 644 "$ARCHIVE" 2>/dev/null
    # The shell (magisk domain) can write FUSE even when system_server/cmd
    # cannot. Keep the /data/local/tmp copy if the Download copy fails.
    _dl="/sdcard/Download/${ARCHIVE##*/}"
    if cp -f "$ARCHIVE" "$_dl" 2>/dev/null; then
        chmod 644 "$_dl" 2>/dev/null
        ARCHIVE=$_dl
    else
        echo "WARN: could not copy archive to /sdcard/Download; use adb pull"
    fi
    echo "ARCHIVE=$ARCHIVE"
else
    echo "ARCHIVE=(not created; folder is at $OUT)"
fi
chmod -R a+rX "$OUT" 2>/dev/null
echo "OUT=$OUT"
echo "=== COLLECTION DONE ==="
