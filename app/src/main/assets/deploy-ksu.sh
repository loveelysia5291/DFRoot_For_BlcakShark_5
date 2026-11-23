#!/system/bin/sh
# ==============================================================================
# DFRoot -> KernelSU late-load deployment (Black Shark 5, SHARK PAR-H0)
# kernel 4.19.113-perf, non-GKI, RAM-only.
#
# Fixes vs. original deploy-ksu.sh:
#   1. Transitions ksud into u:r:ksu:s0 via /proc/self/attr/exec before exec,
#      compensating for external `insmod` (where kernel escape_to_root_for_init
#      only elevates the short-lived insmod process, not ksud).
#   2. Logs ksud late-load output to /data/local/tmp/ksud-late-load.log instead
#      of discarding it to /dev/null.
#   3. Waits for the daemonized `ksud late-load` process to finish (up to 15s)
#      instead of sleeping 0.1s and exiting immediately.
#   4. Verifies whether ksud actually restarted the Manager; if not, performs a
#      clean fallback `am force-stop` + `am start` (with `monkey` fallback).
#   5. Explicitly restores SELinux to Enforcing (`setenforce 1` /
#      `/sys/fs/selinux/enforce`) if still Permissive after late-load finishes.
#   6. Prevents duplicate DEPLOY_DONE lines via DONE_WRITTEN guard.
# ==============================================================================

export PATH=/debug_ramdisk:/system/xbin:/system/bin:/sbin:/vendor/bin
export SHELL=/system/bin/sh

STAGE=/data/user_de/0/df.root
PREFS=$STAGE/shared_prefs/dfroot.xml
DONE_MARKER=$STAGE/deploy.done
MIRROR_DONE=/data/local/tmp/ksu-deploy.done
KSUD_LOG=/data/local/tmp/ksud-late-load.log
ADBDIR=/data/adb/ksu
KSUD_INSTALL=/data/adb/ksud
KSUKO=$STAGE/ksu.ko
KSUD=$STAGE/ksud

RESULT=failed
DONE_WRITTEN=0

progress() {
    echo "PROGRESS $1"
}

log() {
    echo "[ksu] $@"
}

# Inherit zygote environ (BOOTCLASSPATH, etc.) so ksud and `am` can run;
# the root worker otherwise runs with a minimal environment.
adopt_zygote_env() {
    _z=$(pidof zygote64 zygote 2>/dev/null | awk '{print $1; exit}')
    if [ -z "$_z" ]; then
        return 1
    fi
    _env=/data/local/tmp/dfroot.zygote.env.$$
    if ! tr '\0' '\n' < "/proc/$_z/environ" > "$_env" 2>/dev/null; then
        rm -f "$_env" 2>/dev/null
        return 1
    fi
    while IFS= read -r kv; do
        case "$kv" in
            *=*) export "$kv" 2>/dev/null ;;
        esac
    done < "$_env"
    rm -f "$_env" 2>/dev/null
    return 0
}

# Execute a command in u:r:ksu:s0 SELinux domain when permitted.
run_in_ksu_ctx() {
    (
        if [ -w /proc/self/attr/exec ]; then
            printf 'u:r:ksu:s0' > /proc/self/attr/exec 2>/dev/null || true
        fi
        exec "$@"
    )
}

# Check whether any daemonized `ksud late-load` process is still running.
is_late_load_running() {
    for _p in /proc/[0-9]*; do
        [ -r "$_p/cmdline" ] || continue
        _cmd=$(tr '\0' ' ' < "$_p/cmdline" 2>/dev/null)
        case "$_cmd" in
            *ksud*late-load*)
                return 0
                ;;
        esac
    done
    return 1
}

# Read current SELinux enforcing state (returns 1 for Enforcing, 0 for Permissive).
get_selinux_enforce() {
    if [ -r /sys/fs/selinux/enforce ]; then
        cat /sys/fs/selinux/enforce 2>/dev/null
    elif command -v getenforce >/dev/null 2>&1; then
        case "$(getenforce 2>/dev/null)" in
            Enforcing|1) echo 1 ;;
            *) echo 0 ;;
        esac
    else
        echo unknown
    fi
}

# Restore SELinux to Enforcing mode if currently Permissive.
restore_selinux_enforcing() {
    _cur=$(get_selinux_enforce)
    log "selinux before restore: $_cur"
    if [ "$_cur" = "1" ]; then
        log "selinux already Enforcing"
        return 0
    fi

    if command -v setenforce >/dev/null 2>&1; then
        setenforce 1 2>/dev/null || true
    fi
    if [ "$(get_selinux_enforce)" != "1" ] && [ -w /sys/fs/selinux/enforce ]; then
        printf '1' > /sys/fs/selinux/enforce 2>/dev/null || true
    fi

    _after=$(get_selinux_enforce)
    log "selinux after restore: $_after"
    [ "$_after" = "1" ]
}

# Restart and open KernelSU Manager cleanly.
restart_manager_fallback() {
    _pkg="$1"
    log "running fallback manager launch for $_pkg"
    run_in_ksu_ctx am force-stop "$_pkg" >>"$KSUD_LOG" 2>&1 || true
    sleep 0.2
    if run_in_ksu_ctx am start -n "$_pkg/me.weishu.kernelsu.ui.MainActivity" >>"$KSUD_LOG" 2>&1; then
        log "am start MainActivity succeeded"
        return 0
    fi
    log "am start MainActivity failed; trying monkey launcher fallback"
    run_in_ksu_ctx monkey -p "$_pkg" -c android.intent.category.LAUNCHER 1 >>"$KSUD_LOG" 2>&1 || true
}

# Completion signal only (not a log). The Runner polls this marker to finish.
mark_done() {
    [ "$DONE_WRITTEN" = "1" ] && return 0
    DONE_WRITTEN=1
    _line="DEPLOY_DONE $(date) result=$RESULT"
    echo "$_line" > "$MIRROR_DONE" 2>/dev/null
    echo "$_line" > "$DONE_MARKER" 2>/dev/null
}

trap 'mark_done; exit 1' EXIT INT TERM

log "=== deploy-ksu.sh start pid=$$ date=$(date) ==="
log "DEPLOY_BUILD=offfix48 ksu-ctx-exec wait-late-load fallback-am-start restore-selinux"

# ---- sanity: worker must already be root ------------------------------------
if [ "$(id -u 2>/dev/null || echo 0)" != "0" ]; then
    echo root > /proc/dfroot_su 2>/dev/null
fi
if [ "$(id -u 2>/dev/null || echo 1)" != "0" ]; then
    log "FATAL: not root (uid != 0); aborting"
    exit 1
fi
log "root: uid=0 confirmed"
progress 40

# ---- manager package --------------------------------------------------------
MGR_PKG=""
if [ -f "$STAGE/manager.package" ]; then
    MGR_PKG=$(head -n1 "$STAGE/manager.package" 2>/dev/null | tr -d '\r\n ')
fi
if [ -z "$MGR_PKG" ] && [ -f "$PREFS" ]; then
    MGR_PKG=$(sed -n 's/.*name="su_manager"[^>]*value="\([^"]*\)".*/\1/p' "$PREFS" 2>/dev/null | head -n1)
    [ -z "$MGR_PKG" ] && MGR_PKG=$(sed -n 's/.*name="su_manager">\([^<]*\)<\/string>.*/\1/p' "$PREFS" 2>/dev/null | head -n1)
fi
[ -z "$MGR_PKG" ] && MGR_PKG=me.weishu.kernelsu
log "manager package: $MGR_PKG"
progress 50

# ---- payload presence -------------------------------------------------------
for f in "$KSUKO" "$KSUD"; do
    if [ ! -f "$f" ]; then
        log "FATAL: staged payload missing: $f"
        exit 1
    fi
done
log "payloads present: ksu.ko=$(wc -c < "$KSUKO") ksud=$(wc -c < "$KSUD")"

# ---- install ksud under /data/adb -------------------------------------------
mkdir -p "$ADBDIR/lib" /data/adb/modules 2>/dev/null
cp -f "$KSUD" "$KSUD_INSTALL" 2>/dev/null
chmod 0755 "$KSUD_INSTALL" 2>/dev/null
chown 0:0 "$KSUD_INSTALL" 2>/dev/null
chcon u:object_r:system_file:s0 "$KSUD_INSTALL" 2>/dev/null
[ -x "$KSUD_INSTALL" ] || { log "FATAL: ksud not executable after install"; exit 1; }
log "ksud installed -> $KSUD_INSTALL"
progress 60

# ---- load the KernelSU module -----------------------------------------------
if [ -x /vendor/bin/insmod ]; then
    INSMOD=/vendor/bin/insmod
elif [ -x /system/bin/insmod ]; then
    INSMOD=/system/bin/insmod
else
    INSMOD=insmod
fi

if grep -q '^ksu ' /proc/modules 2>/dev/null; then
    log "ksu.ko already loaded in kernel"
    RC=0
else
    "$INSMOD" "$KSUKO" spoof_uname=0
    RC=$?
fi
if [ "$RC" != "0" ]; then
    log "FATAL: insmod ksu.ko failed rc=$RC"
    exit 1
fi
log "ksu.ko insmod returned 0 (selinux=$(get_selinux_enforce))"
progress 75

# ---- ksud late-load (in u:r:ksu:s0 context, logged & waited) ----------------
adopt_zygote_env

KSUD_BIN="$KSUD_INSTALL"
[ -x "$KSUD_BIN" ] || KSUD_BIN="$KSUD"

: > "$KSUD_LOG" 2>/dev/null
run_in_ksu_ctx "$KSUD_BIN" late-load --package-name "$MGR_PKG" >>"$KSUD_LOG" 2>&1
KSUD_RC=$?
log "ksud late-load spawn rc=$KSUD_RC"

# ksud late-load calls daemonize(false); wait for the daemonized worker to finish.
_waited=0
_max_wait=150
sleep 0.2
while is_late_load_running; do
    _waited=$((_waited + 1))
    if [ "$_waited" -ge "$_max_wait" ]; then
        log "WARN: ksud late-load still running after 15s, continuing"
        break
    fi
    sleep 0.1
done
log "ksud late-load wait finished (ticks=$_waited)"
progress 90

# ---- verify manager launch (fallback if ksud step 14 did not run/succeed) ---
_mgr_restarted=0
if grep -q "Restarting KernelSU Manager" "$KSUD_LOG" 2>/dev/null; then
    sleep 0.5
    if pidof "$MGR_PKG" >/dev/null 2>&1; then
        _mgr_restarted=1
        log "manager already restarted by ksud late-load"
    fi
fi
if [ "$_mgr_restarted" = "0" ]; then
    restart_manager_fallback "$MGR_PKG"
fi

# ---- restore SELinux Enforcing if still Permissive --------------------------
restore_selinux_enforcing || log "WARN: failed to restore SELinux to Enforcing"

RESULT=ok
mark_done
progress 100
trap - EXIT INT TERM
