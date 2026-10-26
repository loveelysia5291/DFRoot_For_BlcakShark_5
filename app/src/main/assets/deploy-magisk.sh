#!/system/bin/sh
# =============================================================================
# DFRoot 4.8 -- one-shot late-load Magisk deployment (root / u:r:init:s0)
#
# WHAT CHANGED IN 4.8 (fixing the three reported regressions):
#
# A) THE MAGISK AUTHORIZATION LIST IS NO LONGER OVERWRITTEN.
#    4.7 executed `DELETE FROM policies;` and then inserted its own rows, and
#    also overwrote settings.root_access / multiuser_mode. That is why the
#    user's Magisk authorization list disappeared. 4.8 never deletes the
#    policy table. It snapshots the exact rows, and after Magisk's
#    --post-fs-data it restores ONLY rows that (a) existed before, (b)
#    disappeared during that stage, and (c) still map to an installed app.
#    It never invents a grant. Other writes are:
#      * settings.bootloop = 0        (bookkeeping; Magisk itself does this)
#      * a stale strings.requester is deleted when its dyn/current.apk is
#        missing (that stale value made every Query silently DENY)
#      * a non-standard manager gets its dyn/current.apk + requester set
#
# B) THE `magisk` DOMAIN IS NOT FORCED ENFORCING.
#    Upstream Magisk ships `permissive([proc])` for its own domain
#    (rules.rs). app_request() needs app_process + binder + the FIFO to be
#    usable. 4.7 ran `enforce magisk`, which is exactly what broke the su
#    dialog. 4.8 loads `--magisk` and leaves the domain permissive; global
#    SELinux is still set to Enforcing at the end.
#
# C) STOCK-STYLE su ONLY.
#    /system/xbin/su and /debug_ramdisk/su are symlinks to
#    /debug_ramdisk/magisk. check-client compares st_dev+st_ino of
#    /proc/<pid>/exe with the daemon's binary, so a symlink to the SAME file
#    is required (a copy would fail). The directory /system/xbin is mounted
#    with context=magisk_file AND chcon'd: without search permission on the
#    directory an app cannot execute su at all. The 4.7 shell wrapper is
#    DISABLED: a non-Magisk su bypasses the manager dialog and triggers the
#    "su binary not from Magisk" warning. On failure the script leaves the
#    Magisk symlinks in place and closes /proc/dfroot_su instead of falling
#    back to the wrapper.
#
# D) MODULES MOUNT, BOOT SCRIPTS DO NOT REPLAY.
#    Only `--post-fs-data` is requested once. /data/adb/modules and
#    modules_update stay VISIBLE so Magisk builds its immutable module list and
#    actually mounts the module files. During that one late pass only boot-time
#    scripts are hidden: post-fs-data.d and every module's post-fs-data.sh are
#    renamed, then restored immediately. --service and --boot-complete are NOT
#    replayed. This prevents Zygisk Next and other module daemons from starting
#    after zygote is already up (their ctl.restart zygote was the soft-reboot
#    trigger) without hiding the modules from Magisk.
#
# E) exp.c restores crash_dump64 and the patched vendor library after the LKM
#    is loaded (see DFRoot-4.8-FIXES.md). This script closes the legacy
#    /proc/dfroot_su channel on success and on every failure/interrupt path.
#
# F) APP_PROCESS TRANSPORT.
#    Magisk 30.7 su_connect.rs hard-codes /system/bin/app_process. Some OEM
#    Android 12 ROMs only ship app_process64, so AM_OK was 0 and the manager
#    could never receive a su intent. The runtime /debug_ramdisk/magisk copy is
#    patched in place to a same-length /debug_ramdisk/apppro64 symlink; the
#    stock asset and /data/adb/magisk/magisk are never modified. The magisk
#    domain remains permissive.
#
# G) ANDROID ENVIRONMENT FOR app_process.
#    The init worker starts this script with a minimal environment
#    (MAGISKTMP/PATH/SHELL only). app_process needs the zygote environment
#    (ANDROID_ROOT, ANDROID_DATA, BOOTCLASSPATH, ...). Without those variables
#    it starts but produces no output, so su_connect's exec_cmd loop respawns
#    app_process forever and AM_OK/prompt never succeed. Import the whitelisted
#    Android variables from /proc/<zygote>/environ before magiskd starts; both
#    magiskd's su_connect child and this script's am self-test inherit them.
#
# H) OPTIONAL LSPOSED / ZYGISK NEXT (4.8.3).
#    The normal deploy still never restarts zygote. When Settings > Auto Soft
#    Reboot is ON and BOTH zygisk_lsposed and zygisksu are installed/enabled,
#    the deploy:
#      1. starts Zygisk Next's injector and LSPosed's lspd (the scripts that
#         hide_boot_scripts() deliberately suppresses during --post-fs-data),
#      2. re-applies /debug_ramdisk and /system/xbin in init's mount namespace
#         so the new zygote/apps still see them,
#      3. patches LSPosed's daemon to use app_process64 on ROMs that do not
#         ship /system/bin/app_process,
#      4. performs ONE clean `setprop ctl.restart zygote` (never kill -9),
#      5. waits for the new zygote, verifies lspd/zygiskd and logcat, and
#         restores Enforcing.
#    If either daemon fails to start, the restart is refused. A normal reboot
#    is always a safe recovery because nothing here modifies the boot image.
#
# I) FULL LSPOSED MODULE UPDATE (4.8.10).
#    The manager APK, lspd and zygisk library are one matched set. v2.0.0's
#    zygisk library aborts every v2.2.1 manager process during zygote app
#    specialization (JNI java_array == null), which looks like a white screen.
#    This build embeds the official 2.2.1 (7930) module archive, replaces the
#    complete module file set (never manager-only), keeps the old module under
#    the DFRoot device-protected directory, and refuses LSPosed activation if
#    the manager/module version pair still differs.
# =============================================================================

export PATH=/debug_ramdisk:/system/xbin:/system/bin:/sbin:/vendor/bin
export MAGISKTMP=/debug_ramdisk
export SHELL=/system/bin/sh

SCRIPT_REV=4.9.6

# Emitted as a plain log line so the app can show a real percentage.
progress() { echo "PROGRESS $1"; }

STAGE=/data/user_de/0/df.root
DATABIN=/data/adb/magisk
# DFRoot runtime files stay in the app's own device-protected directory.
# /data/adb contains Magisk's standard files only; no /data/adb/dfroot is
# created and no DFRoot file is mixed into DATABIN.
SUDIR=$STAGE
LOG=$STAGE/deploy.log
DONE_MARKER=$STAGE/deploy.done
ADB_LOG=/data/local/tmp/dfroot-deploy.log
PKGLIST=/data/system/packages.list

MAGISK=$DATABIN/magisk
MPOLICY=$DATABIN/magiskpolicy
if [ -x "$DATABIN/busybox" ]; then
    BB="$DATABIN/busybox"
elif [ -x "$STAGE/busybox" ]; then
    BB="$STAGE/busybox"
else
    BB="/debug_ramdisk/.magisk/busybox/busybox"
fi
CLIENT=/debug_ramdisk/magisk
MAGISK_FILE_CON=u:object_r:magisk_file:s0

MGR_PKG=""
MGR_UID=""
MGR_GID=""
MGR_APK=""
MGR_DE=""
PROMPT_MODE=0
MAGISK_READY=0
STUB_LOADED=0
STUB_SEEDED=0
APP_PROCESS=""
APP_RUN=""
APP_PROXY=/debug_ramdisk/apppro64
APP_PATCHED=0
APP_TRANSPORT_OK=0
# Set to 1 when the staged Magisk file set must be re-copied to DATABIN.
MAGISK_FILES_FORCE=0
# Set to 1 when a new file set was extracted, so the stale manager
# certificate in magisk.db has to be dropped.
MAGISK_NEW_SET=0
ANDROID_ENV_OK=0
ANDROID_ENV_SOURCE=""
AM_OK=0
XBIN_OK=0
SU_LINKS_OK=0
MAGISK_SU_OK=0
XATTR_BIND_OK=0
# Root-owned state must NOT live in the app's DE directory: a bind-mounted
# xattr_ramdisk there cannot be removed on uninstall ("Failed to delete
# /data/user_de/0/df.root (code 39)"), and the leftover root-owned directory
# then makes the next launch die with "mkdirs failed". Keep it under /data/adb,
# which is root-only and survives uninstall cleanly.
DFROOT_DIR=/data/adb/dfroot
mkdir -p "$DFROOT_DIR" 2>/dev/null || DFROOT_DIR=$STAGE
F2FS_RD=$DFROOT_DIR/xattr_ramdisk
DEBUG_RD_F2FS=0
GUARD_STARTED=0
GUARD_PIDFILE=$SUDIR/magiskd-guard.pid
MODULES_STATE=skipped
BOOT_SCRIPTS_OFF=0
ZYGOTE_BEFORE=""
ZYGOTE_AFTER=""
ROOT_ACCESS=3
TEST_SU=""
PROMPT_TEST=disabled
ROOT_PRE=0
ROOT_SU_OK=0
ROOT_OUT=""
CHANNEL=open
MANAGER_LOST=0
POL_BEFORE="?"
POL_AFTER="?"
POL_RESTORED=0
POL_SNAPSHOT=$SUDIR/policies.before
RQ_AFTER=""
MAGLOG=""
DONE_FD_OPEN=0

# Optional LSPosed / Zygisk Next mode (4.8.3). All of this is inert unless
# Settings > Auto Soft Reboot is ON and both modules are installed/enabled.
# DISABLE_MODULES is the one-shot boot-safety switch (Settings > Disable All
# Modules): every module gets a `disable` marker for this deploy only.
SOFT_REBOOT=0
DISABLE_MODULES=0
LSPOSED_MODE=0
LSPOSED_PRESENT=0
ZYGISK_NEXT=0
LSPOSED_DIR=""
ZYGISKSU_DIR=""
LSPOSED_PREP=0
LSPOSED_RESULT=skipped
LSPD_PID=""
ZN_PID=""
NSENTER_CMD=""
LSPOSED_FILE_TYPE=0
LSPOSED_FILE_COMPAT=0
LSPOSED_MANAGER_PKG=org.lsposed.manager
LSPOSED_MANAGER_APK=""
LSPOSED_MGR_STATUS=not_checked
LSPOSED_MODULE_VC=0
LSPOSED_MODULE_VER=""
LSPOSED_MODULE_STATUS=not_checked
LSPOSED_MODULE_UPDATED=0
LSPOSED_MANAGER_VC=""
LSPOSED_BUNDLE=$STAGE/lsposed-2.2.1-7930.tar
LSPOSED_BUNDLE_VC=7930
LSPOSED_ZYGISK_RELOAD=$STAGE/lsposed.zygisk.reload
LSPOSED_ABI64=""
LSPOSED_ABI32=""
LSPOSED_ARCH=""
LSPOSED_ZNABI=""
LSPOSED_RESTART_MODE=none
LSPOSED_BRIDGE=unknown
MODULE_POLICY_COUNT=0
MODULE_POLICY_FILE=$SUDIR/modules.sepolicy.rule

mkdir -p "$STAGE" 2>/dev/null
exec >"$LOG" 2>&1
chmod 666 "$LOG" 2>/dev/null
rm -f "$DONE_MARKER" 2>/dev/null

# Syntax guard: mksh parses this script incrementally, so a typo further down
# would only surface after half the deploy had already run (and could leave the
# phone permissive). Parse the whole file first and fail cleanly.
if ! /system/bin/sh -n "$0" 2>"$STAGE/syntax.err"; then
    echo "FATAL: deploy-magisk.sh has a syntax error; nothing was changed"
    /system/bin/cat "$STAGE/syntax.err" 2>/dev/null | /system/bin/head -n 20
    case "$(getenforce 2>/dev/null)" in
        Enforcing) ;;
        *) setenforce 1 2>/dev/null ;;
    esac
    printf 'DEPLOY_FAILED %s result=failed error=syntax\n' "$(date)" >> "$DONE_MARKER" 2>/dev/null
    exit 1
fi

# LEAK FIX: the LKM creates /proc/dfroot_su mode 0666, so until this worker
# starts *any* app could write '1' and become root. The app has already handed
# control to this worker, so restrict the node to root now and close it at the
# end (on_exit/fatal do that on every path).
chmod 600 /proc/dfroot_su 2>/dev/null

echo "=== dfroot deploy-magisk.sh $SCRIPT_REV start pid=$$ date=$(date) ==="
id
echo "kernel: $(uname -a)"
echo "selinux at start: $(getenforce 2>&1)"

# ---------- helpers ---------------------------------------------------------
mount_xbin() {
    XBIN_OK=0
    if [ -L /system/xbin ]; then
        echo "WARN: /system/xbin is a symlink -> $($BB readlink -f /system/xbin 2>/dev/null); not overlaying"
        return 1
    fi
    mkdir -p /system/xbin 2>/dev/null
    # Propagate the overlay into app/zygote mount namespaces, otherwise the
    # app can only try /debug_ramdisk/su (and only if that bind propagated).
    mount --make-rshared / 2>/dev/null
    # context= gives the directory AND the symlinks magisk_file without a
    # follow-up chcon (a symlink chcon would follow the link, not label it).
    mount -t tmpfs tmpfs /system/xbin -o "mode=0755,context=$MAGISK_FILE_CON" 2>/dev/null
    if ! touch /system/xbin/.dfroot_rw 2>/dev/null; then
        mount -t tmpfs tmpfs /system/xbin -o mode=0755 2>/dev/null
    fi
    if touch /system/xbin/.dfroot_rw 2>/dev/null; then
        rm -f /system/xbin/.dfroot_rw 2>/dev/null
        chcon "$MAGISK_FILE_CON" /system/xbin 2>/dev/null
        XBIN_OK=1
        echo "xbin tmpfs ready (context mounted where supported)"
        return 0
    fi
    echo "WARN: could not overlay /system/xbin"
    return 1
}

install_stock_su() {
    rm -f /system/xbin/su /system/xbin/magisk 2>/dev/null
    rm -f /system/bin/su /system/bin/magisk 2>/dev/null
    rm -f /system/sbin/su 2>/dev/null
    echo "su installed: /debug_ramdisk/su only (xbin/bin cleaned)"

    rm -f /debug_ramdisk/su 2>/dev/null
    ln -sf /debug_ramdisk/magisk /debug_ramdisk/su
    chmod 755 /debug_ramdisk/magisk 2>/dev/null
    chcon "$MAGISK_FILE_CON" /debug_ramdisk/magisk 2>/dev/null
    chcon "$MAGISK_FILE_CON" /debug_ramdisk/su 2>/dev/null
    chcon -h "$MAGISK_FILE_CON" /debug_ramdisk/su 2>/dev/null
    chcon "$MAGISK_FILE_CON" /debug_ramdisk 2>/dev/null
    chcon -R "$MAGISK_FILE_CON" /debug_ramdisk/.magisk 2>/dev/null
    echo "debug_ramdisk su: $(ls -l /debug_ramdisk/su 2>&1)"

    SU_LINKS_OK=0
    if su_is_magisk_link /debug_ramdisk/su; then
        SU_LINKS_OK=1
        TEST_SU=/debug_ramdisk/su
        echo "su link verified: /debug_ramdisk/su -> /debug_ramdisk/magisk"
    else
        TEST_SU=/debug_ramdisk/su
        echo "WARN: /debug_ramdisk/su is not a Magisk symlink"
    fi
    XBIN_OK=0
}

lsposed_module_enabled() {
    for _lme in /data/adb/modules/zygisk_lsposed /data/adb/modules/lsposed; do
        [ -f "$_lme/module.prop" ] || continue
        [ -f "$_lme/disable" ] && continue
        [ -f "$_lme/remove" ] && continue
        return 0
    done
    return 1
}

lsposed_file_type_present() {
    _lftp_bb=${PBB:-$BB}
    _lftp_line=$($_lftp_bb timeout 30 "$MPOLICY" --print-rules 2>/dev/null | \
        $_lftp_bb grep -m1 -E '^type lsposed_file( |$)')
    [ -n "$_lftp_line" ]
}

apply_module_sepolicy_rules() {
    MODULE_POLICY_COUNT=0
    : > "$MODULE_POLICY_FILE" 2>/dev/null || {
        echo "WARN: cannot create $MODULE_POLICY_FILE"
        return 1
    }
    for _amsf in /data/adb/modules/*/sepolicy.rule; do
        [ -f "$_amsf" ] || continue
        _amsd=${_amsf%/*}
        [ -f "$_amsd/disable" ] && continue
        [ -f "$_amsd/remove" ] && continue
        [ -f "$_amsd/update" ] && continue
        if cat "$_amsf" >> "$MODULE_POLICY_FILE" 2>/dev/null; then
            printf '\n' >> "$MODULE_POLICY_FILE" 2>/dev/null
            MODULE_POLICY_COUNT=$((MODULE_POLICY_COUNT + 1))
            echo "module sepolicy: $_amsf"
        else
            echo "WARN: cannot read $_amsf"
        fi
    done
    if [ "$MODULE_POLICY_COUNT" -gt 0 ]; then
        "$MPOLICY" --live --apply "$MODULE_POLICY_FILE" >/dev/null 2>&1
        echo "module sepolicy apply rc=$? files=$MODULE_POLICY_COUNT"
    else
        echo "module sepolicy: no enabled module rules"
    fi

    LSPOSED_FILE_TYPE=0
    LSPOSED_FILE_COMPAT=0
    if ! lsposed_module_enabled; then
        echo "lsposed_file: LSPosed module not enabled; compatibility type not needed"
        return 0
    fi
    if lsposed_file_type_present; then
        LSPOSED_FILE_TYPE=1
        echo "lsposed_file: defined by module sepolicy"
        return 0
    fi
    echo "lsposed_file: missing after module rules; adding compatibility type"
    "$MPOLICY" --live \
        "type lsposed_file file_type" \
        "typeattribute lsposed_file mlstrustedobject" \
        "allow magisk lsposed_file file *" \
        "allow magisk lsposed_file dir *" \
        "allow magisk lsposed_file lnk_file *" \
        "allow magisk lsposed_file fifo_file *" \
        "allow magisk lsposed_file sock_file *" \
        "allow appdomain lsposed_file file { read open getattr map }" \
        "allow appdomain lsposed_file dir { search read open getattr }" \
        "allow system_server lsposed_file file { read open getattr map }" \
        "allow system_server lsposed_file dir { search read open getattr }" \
        "allow shell lsposed_file file { read open getattr }" \
        "allow shell lsposed_file dir { search read open getattr }" \
        "allow installd lsposed_file file { read open getattr }" \
        "allow installd lsposed_file dir { search read open getattr }" \
        "allow zygote lsposed_file file { read open getattr map }" \
        "allow zygote lsposed_file dir { search read open getattr }" \
        >/dev/null 2>&1
    _amsf_rc=$?
    echo "lsposed_file compatibility rc=$_amsf_rc"
    if [ "$MODULE_POLICY_COUNT" -gt 0 ]; then
        "$MPOLICY" --live --apply "$MODULE_POLICY_FILE" >/dev/null 2>&1
        echo "module sepolicy replay rc=$? (after lsposed_file definition)"
    fi
    if lsposed_file_type_present; then
        LSPOSED_FILE_TYPE=1
        LSPOSED_FILE_COMPAT=1
        echo "lsposed_file: compatibility definition active"
    else
        echo "WARN: lsposed_file still missing; LSPosed manager staging may fail"
    fi
    return 0
}

detect_lsposed() {
    LSPOSED_PRESENT=0
    ZYGISK_NEXT=0
    LSPOSED_DIR=""
    ZYGISKSU_DIR=/data/adb/modules/zygisksu
    if [ -f "$ZYGISKSU_DIR/module.prop" ] &&
       [ ! -f "$ZYGISKSU_DIR/remove" ] &&
       [ ! -f "$ZYGISKSU_DIR/disable" ]; then
        ZYGISK_NEXT=1
        echo "Zygisk Next: $($BB grep '^version=' "$ZYGISKSU_DIR/module.prop" 2>/dev/null | $BB head -n1)"
    else
        echo "Zygisk Next: not installed/enabled ($ZYGISKSU_DIR)"
    fi
    for _ld in /data/adb/modules/zygisk_lsposed /data/adb/modules/lsposed; do
        [ -f "$_ld/module.prop" ] || continue
        if [ -f "$_ld/remove" ] || [ -f "$_ld/disable" ]; then
            echo "LSPosed: $_ld is disabled/removed"
            continue
        fi
        LSPOSED_DIR=$_ld
        LSPOSED_PRESENT=1
        echo "LSPosed: $_ld $($BB grep '^version=' "$_ld/module.prop" 2>/dev/null | $BB head -n1)"
        break
    done
    [ "$LSPOSED_PRESENT" = "1" ] || echo "LSPosed: module not installed/enabled"
}

lsposed_ns_enter() {
    NSENTER_CMD=""
    if $PBB timeout 8 $PBB nsenter -t 1 -m /system/bin/true >/dev/null 2>&1; then
        NSENTER_CMD="$PBB nsenter -t 1 -m"
        echo "lsposed: using init mount namespace"
    else
        echo "WARN: lsposed: nsenter -t 1 -m unavailable; using worker namespace"
    fi
}

lspd_wait_stable() {
    _lws_pid=$1
    _lws_need=${2:-4}
    _lws_bb=${PBB:-$BB}
    [ -n "$_lws_pid" ] || return 1
    _lws_i=0
    while [ "$_lws_i" -lt "$_lws_need" ]; do
        sleep 1
        [ -d "/proc/$_lws_pid" ] || return 1
        _lws_now=$($_lws_bb pidof lspd 2>/dev/null | $_lws_bb tr '\n' ' ')
        case " $_lws_now " in
            *" $_lws_pid "*) ;;
            *) return 1 ;;
        esac
        _lws_i=$((_lws_i + 1))
    done
    return 0
}

lsposed_process_pids() {
    _lpp_bb=${PBB:-$BB}
    for _lpp_dir in /proc/[0-9]*; do
        _lpp_pid=${_lpp_dir#/proc/}
        case "$_lpp_pid" in ''|*[!0-9]*) continue ;; esac
        [ "$_lpp_pid" = "$$" ] && continue
        [ "$_lpp_pid" = "$PPID" ] && continue
        _lpp_comm=$($_lpp_bb cat "$_lpp_dir/comm" 2>/dev/null)
        case "$_lpp_comm" in
            lspd)
                [ "$($_lpp_bb awk '{print $3}' "$_lpp_dir/stat" 2>/dev/null)" = "Z" ] || \
                    printf '%s\n' "$_lpp_pid"
                continue
                ;;
        esac
        _lpp_cmd=$($_lpp_bb tr '\0' ' ' < "$_lpp_dir/cmdline" 2>/dev/null)
        case "$_lpp_cmd" in
            lspd|lspd\ *|*zygisk_lsposed/daemon*|*zygisk_lsposed/lspd*|*zygisk_lsposed/service.sh*|*lsposed-daemon*|*org.lsposed.lspd.Main*|*daemon.apk*|*--nice-name=lspd*)
                [ "$($_lpp_bb awk '{print $3}' "$_lpp_dir/stat" 2>/dev/null)" = "Z" ] || \
                    printf '%s\n' "$_lpp_pid"
                ;;
        esac
    done
}

lspd_live_pids() {
    _llp_bb=${PBB:-$BB}
    for _llp_dir in /proc/[0-9]*; do
        _llp_pid=${_llp_dir#/proc/}
        case "$_llp_pid" in ''|*[!0-9]*) continue ;; esac
        [ "$_llp_pid" = "$$" ] && continue
        [ "$_llp_pid" = "$PPID" ] && continue
        _llp_comm=$($_llp_bb cat "$_llp_dir/comm" 2>/dev/null)
        if [ "$_llp_comm" != "lspd" ]; then
            _llp_cmd=$($_llp_bb tr '\0' ' ' < "$_llp_dir/cmdline" 2>/dev/null)
            case "$_llp_cmd" in
                lspd|lspd\ *) ;;
                *) continue ;;
            esac
        fi
        [ "$($_llp_bb awk '{print $3}' "$_llp_dir/stat" 2>/dev/null)" = "Z" ] && continue
        printf '%s\n' "$_llp_pid"
    done
}

lspd_single_pid() {
    _lsp_list=$(lspd_live_pids)
    set -- $_lsp_list
    [ "$#" -eq 1 ] || return 1
    printf '%s\n' "$1"
}

stop_lsposed_daemon() {
    _sl_bb=${PBB:-$BB}
    _sl_saw=0
    _sl_round=0
    while [ "$_sl_round" -lt 4 ]; do
        _sl_pids=$(lsposed_process_pids)
        [ -n "$_sl_pids" ] || break
        _sl_saw=1
        echo "lspd: stopping pid(s)=$(printf '%s' "$_sl_pids" | $_sl_bb tr '\n' ' ')"
        for _sl_p in $_sl_pids; do
            [ -d "/proc/$_sl_p" ] || continue
            kill "$_sl_p" 2>/dev/null
        done
        sleep 1
        _sl_round=$((_sl_round + 1))
    done
    _sl_left=$(lsposed_process_pids)
    if [ -n "$_sl_left" ]; then
        echo "lspd: still alive after TERM; sending KILL to $(printf '%s' "$_sl_left" | $_sl_bb tr '\n' ' ')"
        for _sl_p in $_sl_left; do
            [ -d "/proc/$_sl_p" ] || continue
            kill -9 "$_sl_p" 2>/dev/null
        done
        _sl_round=0
        while [ "$_sl_round" -lt 6 ]; do
            sleep 1
            [ -z "$(lsposed_process_pids)" ] && break
            _sl_round=$((_sl_round + 1))
        done
    fi
    if [ -n "$(lsposed_process_pids)" ]; then
        echo "WARN: lspd/daemon supervisor is still running"
        return 1
    fi
    if [ "$_sl_saw" = "1" ]; then
        echo "lspd: stopped all lspd/daemon supervisors"
    else
        echo "lspd: no existing daemon"
    fi
    return 0
}

lsposed_module_vc() {
    _lmv_bb=${PBB:-$BB}
    _lmv_vc=$($_lmv_bb sed -n 's/^versionCode=//p' "$LSPOSED_DIR/module.prop" 2>/dev/null | $_lmv_bb head -n1)
    case "$_lmv_vc" in
        ''|*[!0-9]*) _lmv_vc=0 ;;
    esac
    printf '%s\n' "$_lmv_vc"
}

lsposed_module_ver() {
    _lmver_bb=${PBB:-$BB}
    $_lmver_bb sed -n 's/^version=//p' "$LSPOSED_DIR/module.prop" 2>/dev/null | $_lmver_bb head -n1
}

lsposed_abi() {
    _la_abi=$(getprop ro.product.cpu.abi 2>/dev/null)
    case "$_la_abi" in
        arm64-v8a)
            LSPOSED_ABI64=arm64-v8a
            LSPOSED_ABI32=armeabi-v7a
            LSPOSED_ARCH=arm64
            LSPOSED_ZNABI=arm64-v8a
            ;;
        armeabi-v7a|armeabi)
            LSPOSED_ABI64=""
            LSPOSED_ABI32=armeabi-v7a
            LSPOSED_ARCH=arm
            LSPOSED_ZNABI=armeabi-v7a
            ;;
        x86_64)
            LSPOSED_ABI64=x86_64
            LSPOSED_ABI32=""
            LSPOSED_ARCH=x64
            LSPOSED_ZNABI=x86_64
            ;;
        riscv64)
            LSPOSED_ABI64=riscv64
            LSPOSED_ABI32=""
            LSPOSED_ARCH=riscv64
            LSPOSED_ZNABI=riscv64
            ;;
        *)
            LSPOSED_ABI64=""
            LSPOSED_ABI32=""
            LSPOSED_ARCH=""
            LSPOSED_ZNABI=""
            echo "WARN: unsupported primary ABI for LSPosed: ${_la_abi:-unknown}"
            return 1
            ;;
    esac
    echo "LSPosed ABI: primary=${LSPOSED_ZNABI} 64=${LSPOSED_ABI64:-none} 32=${LSPOSED_ABI32:-none}"
    return 0
}

lsposed_module_complete() {
    _lmc_ok=1
    for _lmc_f in module.prop service.sh daemon.apk daemon lspd lspctl \
                  manager.apk framework.dex sepolicy.rule zn_modules.txt; do
        [ -s "$LSPOSED_DIR/$_lmc_f" ] || {
            echo "LSPosed module incomplete: missing $_lmc_f"
            _lmc_ok=0
        }
    done
    for _lmc_f in daemon lspd lspctl; do
        [ -x "$LSPOSED_DIR/$_lmc_f" ] || {
            echo "LSPosed module incomplete: $_lmc_f is not executable"
            _lmc_ok=0
        }
    done
    if [ -n "$LSPOSED_ABI64" ]; then
        for _lmc_f in "zygisk/$LSPOSED_ABI64.so" lib/libpreload64.so; do
            [ -s "$LSPOSED_DIR/$_lmc_f" ] || {
                echo "LSPosed module incomplete: missing $_lmc_f"
                _lmc_ok=0
            }
        done
        [ -x "$LSPOSED_DIR/bin/dex2oat64" ] || {
            echo "LSPosed module incomplete: bin/dex2oat64 is not executable"
            _lmc_ok=0
        }
    fi
    if [ -n "$LSPOSED_ABI32" ]; then
        for _lmc_f in "zygisk/$LSPOSED_ABI32.so" lib/libpreload32.so; do
            [ -s "$LSPOSED_DIR/$_lmc_f" ] || {
                echo "LSPosed module incomplete: missing $_lmc_f"
                _lmc_ok=0
            }
        done
        [ -x "$LSPOSED_DIR/bin/dex2oat32" ] || {
            echo "LSPosed module incomplete: bin/dex2oat32 is not executable"
            _lmc_ok=0
        }
    fi
    [ "$_lmc_ok" = "1" ]
}

check_lsposed_versions() {
    LSPOSED_MODULE_VC=$(lsposed_module_vc)
    LSPOSED_MODULE_VER=$(lsposed_module_ver)
    _clv_bb=${PBB:-$BB}
    LSPOSED_MANAGER_VC=$($_clv_bb timeout 20 dumpsys package "$LSPOSED_MANAGER_PKG" 2>/dev/null \
        | $_clv_bb sed -n 's/.*versionCode=\([0-9][0-9]*\).*/\1/p' | $_clv_bb head -n1)
    echo "LSPosed version pair: module=${LSPOSED_MODULE_VC:-unknown} ($LSPOSED_MODULE_VER) manager=${LSPOSED_MANAGER_VC:-unknown}"
    if [ -z "$LSPOSED_MODULE_VC" ] || [ "$LSPOSED_MODULE_VC" = "0" ]; then
        echo "ERROR: LSPosed module version is unknown; refusing to activate LSPosed"
        return 1
    fi
    if [ -z "$LSPOSED_MANAGER_VC" ]; then
        if [ "$LSPOSED_MGR_STATUS" = "installed" ]; then
            echo "WARN: LSPosed manager version is unknown, but the package is installed"
            return 0
        fi
        echo "ERROR: LSPosed manager version is unknown and the package is not installed"
        return 1
    fi
    if [ "$LSPOSED_MANAGER_VC" -gt "$LSPOSED_MODULE_VC" ] 2>/dev/null; then
        echo "ERROR: LSPosed manager ($LSPOSED_MANAGER_VC) is newer than module/lspd ($LSPOSED_MODULE_VC)"
        echo "       This mismatch crashes the manager during zygote specialization."
        return 1
    fi
    if [ "$LSPOSED_MANAGER_VC" -lt "$LSPOSED_MODULE_VC" ] 2>/dev/null; then
        echo "ERROR: LSPosed manager ($LSPOSED_MANAGER_VC) is older than module/lspd ($LSPOSED_MODULE_VC)"
        return 1
    fi
    return 0
}

lsposed_manager_apk_path() {
    for _lma in "$LSPOSED_DIR/manager.apk" /data/adb/lspd/manager.apk \
                "$LSPOSED_DIR/system/priv-app/LSPosed/LSPosed.apk"; do
        [ -s "$_lma" ] || continue
        printf '%s\n' "$_lma"
        return 0
    done
    return 1
}

install_lsposed_manager() {
    LSPOSED_MGR_STATUS=not_found
    _lim_bb=${PBB:-$BB}
    _lim_apk=$(lsposed_manager_apk_path)
    if [ -z "$_lim_apk" ]; then
        echo "LSPosed manager: manager.apk not found (module=$LSPOSED_DIR)"
        return 1
    fi
    LSPOSED_MANAGER_APK=$_lim_apk
    echo "LSPosed manager apk: $_lim_apk ($($_lim_bb wc -c < "$_lim_apk" 2>/dev/null) bytes)"
    _lim_installed=$($_lim_bb timeout 15 /system/bin/cmd package path "$LSPOSED_MANAGER_PKG" 2>/dev/null \
        | $_lim_bb grep -m1 '^package:')
    _lim_had_installed=0
    if [ -n "$_lim_installed" ]; then
        _lim_had_installed=1
        echo "LSPosed manager already installed: $_lim_installed"
        _lim_module_vc=$($_lim_bb sed -n 's/^versionCode=//p' \
            "$LSPOSED_DIR/module.prop" 2>/dev/null | $_lim_bb head -n1)
        _lim_installed_vc=$($_lim_bb timeout 20 dumpsys package "$LSPOSED_MANAGER_PKG" 2>/dev/null \
            | $_lim_bb sed -n 's/.*versionCode=\([0-9][0-9]*\).*/\1/p' | $_lim_bb head -n1)
        echo "LSPosed manager version: installed=${_lim_installed_vc:-unknown} module=${_lim_module_vc:-unknown}"
        if [ -n "$_lim_installed_vc" ] && [ -n "$_lim_module_vc" ] &&
           [ "$_lim_installed_vc" -ge "$_lim_module_vc" ] 2>/dev/null; then
            echo "LSPosed manager is current (installed >= module); no update needed"
            LSPOSED_MGR_STATUS=installed
            return 0
        fi
        echo "LSPosed manager is older than the module; updating it"
    fi
    _lim_tmp=/data/local/tmp/dfroot-lsposed-manager.apk
    if ! $_lim_bb timeout 20 $_lim_bb runcon u:r:magisk:s0 \
            cp -f "$_lim_apk" "$_lim_tmp" 2>/dev/null; then
        cp -f "$_lim_apk" "$_lim_tmp" 2>/dev/null || {
            echo "WARN: LSPosed manager: cannot copy manager.apk to $_lim_tmp"
            LSPOSED_MGR_STATUS=stage_failed
            return 1
        }
    fi
    chmod 644 "$_lim_tmp" 2>/dev/null
    chcon u:object_r:magisk_file:s0 "$_lim_tmp" 2>/dev/null
    echo "LSPosed manager staging: $(ls -l "$_lim_tmp" 2>/dev/null | $_lim_bb head -n1)"
    _lim_out=$($_lim_bb timeout 120 /system/bin/cmd package install -r -g --user 0 "$_lim_tmp" 2>&1)
    _lim_rc=$?
    echo "LSPosed manager install rc=$_lim_rc"
    printf '%s\n' "$_lim_out" | $_lim_bb head -n 3
    if [ "$_lim_rc" != "0" ]; then
        _lim_out=$($_lim_bb timeout 120 /system/bin/cmd package install -r --user 0 "$_lim_tmp" 2>&1)
        _lim_rc=$?
        echo "LSPosed manager install retry rc=$_lim_rc"
        printf '%s\n' "$_lim_out" | $_lim_bb head -n 3
    fi
    rm -f "$_lim_tmp" 2>/dev/null
    _lim_i=0
    _lim_installed=""
    while [ "$_lim_i" -lt 10 ]; do
        _lim_installed=$($_lim_bb timeout 10 /system/bin/cmd package path "$LSPOSED_MANAGER_PKG" 2>/dev/null \
            | $_lim_bb grep -m1 '^package:')
        [ -n "$_lim_installed" ] && break
        sleep 1
        _lim_i=$((_lim_i + 1))
    done
    if [ -n "$_lim_installed" ]; then
        LSPOSED_MGR_STATUS=installed
        echo "LSPosed manager status=installed path=$_lim_installed"
        return 0
    fi
    case "$_lim_out" in
        *INSTALL_FAILED_VERSION_DOWNGRADE*|*"version downgrade"*|*"Downgrade detected"*)
            if [ "$_lim_had_installed" = "1" ]; then
                echo "LSPosed manager: existing manager is newer; keeping it"
                LSPOSED_MGR_STATUS=installed
                return 0
            fi
            ;;
    esac
    if [ "$_lim_had_installed" = "1" ]; then
        echo "WARN: LSPosed manager update failed; keeping existing manager"
        LSPOSED_MGR_STATUS=installed
        return 0
    fi
    LSPOSED_MGR_STATUS=install_failed
    echo "WARN: LSPosed manager status=install_failed (lspd may try again)"
    return 1
}

zn_injector_pid() {
    for _p in $($PBB pidof zygiskd64 2>/dev/null) $($PBB pidof zygiskd 2>/dev/null) \
              $($PBB pidof zygisk-ptrace64 2>/dev/null) $($PBB pidof zygisk-ptrace 2>/dev/null); do
        _exe=$($PBB readlink /proc/$_p/exe 2>/dev/null)
        case "$_exe" in
            *zygisksu*) ;;
            *) continue ;;
        esac
        $PBB grep -aq 'service-stage' "/proc/$_p/cmdline" 2>/dev/null && continue
        echo "$_p"
        return 0
    done
    return 1
}

zn_daemon_pid() {
    for _p in $($PBB pidof zygiskd64 2>/dev/null) $($PBB pidof zygiskd 2>/dev/null); do
        _exe=$($PBB readlink /proc/$_p/exe 2>/dev/null)
        case "$_exe" in
            *zygisksu*) ;;
            *) continue ;;
        esac
        $PBB grep -aq 'service-stage' "/proc/$_p/cmdline" 2>/dev/null && continue
        echo "$_p"
        return 0
    done
    return 1
}

stop_zygisk_next() {
    _sz_bb=${PBB:-$BB}
    _sz_pids=""
    for _sz_p in $($_sz_bb ps -A -o PID 2>/dev/null); do
        case "$_sz_p" in
            ''|*[!0-9]*) continue ;;
        esac
        _sz_exe=$($_sz_bb readlink /proc/$_sz_p/exe 2>/dev/null)
        case "$_sz_exe" in
            *zygisksu*) _sz_pids="$_sz_pids $_sz_p" ;;
        esac
    done
    [ -n "$_sz_pids" ] || {
        echo "zygisk: no existing injector/daemon"
        return 0
    }
    echo "zygisk: stopping old injector/daemon pid(s)=$_sz_pids"
    for _sz_p in $_sz_pids; do
        kill "$_sz_p" 2>/dev/null
    done
    _sz_i=0
    while [ "$_sz_i" -lt 5 ]; do
        _sz_alive=0
        for _sz_p in $_sz_pids; do
            [ -d "/proc/$_sz_p" ] && _sz_alive=1
        done
        [ "$_sz_alive" = "0" ] && break
        sleep 1
        _sz_i=$((_sz_i + 1))
    done
    for _sz_p in $_sz_pids; do
        [ -d "/proc/$_sz_p" ] && kill -9 "$_sz_p" 2>/dev/null
    done
    sleep 1
    _sz_alive=0
    for _sz_p in $_sz_pids; do
        [ -d "/proc/$_sz_p" ] && _sz_alive=1
    done
    if [ "$_sz_alive" = "1" ]; then
        echo "ERROR: old Zygisk Next process survived kill; refusing to continue"
        return 1
    fi
    echo "zygisk: old processes stopped"
    return 0
}

install_global_root() {
    if [ -z "$NSENTER_CMD" ]; then
        echo "WARN: global root: no init mount namespace; skipping"
        return 1
    fi
    echo "re-applying global /debug_ramdisk and /system/xbin in init namespace"
    $PBB timeout 20 $PBB runcon u:r:magisk:s0 $NSENTER_CMD /system/bin/sh -c "
        mount --make-rshared / 2>/dev/null
        if [ -d '$F2FS_RD' ]; then
            mount --bind '$F2FS_RD' /debug_ramdisk 2>/dev/null
        fi
        rm -f /system/xbin/su /system/xbin/magisk /system/bin/su /system/bin/magisk 2>/dev/null
        ls -l /debug_ramdisk/su 2>&1
    "
    _igr_rc=$?
    echo "global root rc=$_igr_rc"
    return $_igr_rc
}

restart_lspd_clean() {
    _rl_bb=${PBB:-$BB}
    _rl_ns=$NSENTER_CMD
    _rl_zpid=$(zygote_primary_pid)
    if [ -z "$_rl_zpid" ]; then
        echo "lspd: no zygote process"
        return 1
    fi
    _rl_boot=$($_rl_bb tr '\0' '\n' < "/proc/$_rl_zpid/environ" 2>/dev/null |
               $_rl_bb grep -m1 '^BOOTCLASSPATH=')
    _rl_dex=$($_rl_bb tr '\0' '\n' < "/proc/$_rl_zpid/environ" 2>/dev/null |
              $_rl_bb grep -m1 '^DEX2OATBOOTCLASSPATH=')
    if [ -z "$_rl_boot" ]; then
        echo "lspd: cannot read BOOTCLASSPATH from zygote=$_rl_zpid"
        return 1
    fi
    _rl_dir=$LSPOSED_DIR
    if [ ! -f "$_rl_dir/daemon.apk" ]; then
        echo "lspd: $_rl_dir/daemon.apk missing"
        return 1
    fi

    stop_lsposed_daemon
    rm -f /data/adb/lspd/monitor /data/adb/lspd/lock 2>/dev/null

    if [ -x "$ZYGISKSU_DIR/bin/zygiskd" ]; then
        ( cd "$ZYGISKSU_DIR" && exec ./bin/zygiskd daemon ) >/dev/null 2>&1 &
        sleep 3
        ( cd "$ZYGISKSU_DIR" && exec ./bin/zygiskd service-stage ) >/dev/null 2>&1 &
        sleep 2
        ZN_PID=$(zn_injector_pid)
        echo "lspd: zygiskd before lspd pid=${ZN_PID:-?}"
    fi

    _rl_app=/system/bin/app_process
    [ -x "$_rl_app" ] || _rl_app=${APP_PROCESS:-/system/bin/app_process64}
    _rl_setsid="$_rl_bb setsid"
    $_rl_bb setsid true >/dev/null 2>&1 || _rl_setsid=""
    $_rl_setsid $_rl_ns /system/bin/sh -c "
        cd $_rl_dir
        export $_rl_boot
        [ -n '$_rl_dex' ] && export $_rl_dex
        export PATH=$PATH
        exec $_rl_app -Djava.class.path=$_rl_dir/daemon.apk -Xnoimage-dex2oat /system/bin --nice-name=lspd org.lsposed.lspd.Main
    " </dev/null >/dev/null 2>&1 &

    sleep 3
    LSPD_PID=$(lspd_single_pid 2>/dev/null)
    if [ -z "$LSPD_PID" ]; then
        echo "lspd: did not start"
        return 1
    fi
    if ! lspd_wait_stable "$LSPD_PID" 3; then
        echo "lspd: pid=$LSPD_PID is not stable"
        return 1
    fi
    chmod 644 /data/adb/lspd/monitor 2>/dev/null
    echo "lspd: single instance ready pid=$LSPD_PID"
    return 0
}

prepare_lsposed() {
    _lsp_pre_enforce=$(getenforce 2>/dev/null)
    if [ "$DISABLE_MODULES" = "1" ]; then
        LSPOSED_RESULT=modules_disabled
        echo "LSPosed: skipped (Disable All Modules is ON for this run)"
        setenforce 0 2>/dev/null
        return 0
    fi
    setenforce 0 2>/dev/null
    detect_lsposed
    if [ "$LSPOSED_PRESENT" != "1" ] || [ "$ZYGISK_NEXT" != "1" ]; then
        LSPOSED_RESULT=no_modules
        echo "LSPosed: skipped (need both zygisk_lsposed and zygisksu enabled)"
        setenforce 0 2>/dev/null
        return 0
    fi
    _builtin_zn=0
    for _bz_p in $($PBB pidof zygiskd64 2>/dev/null) $($PBB pidof zygiskd 2>/dev/null); do
        _bz_exe=$($PBB readlink /proc/$_bz_p/exe 2>/dev/null)
        case "$_bz_exe" in
            *zygisksu*) ;;
            *zygisk*) echo "WARN: built-in Magisk zygiskd is running: $_bz_exe"; _builtin_zn=1 ;;
        esac
    done
    if [ "$_builtin_zn" = "1" ]; then
        LSPOSED_RESULT=builtin_zygisk
        echo "ERROR: built-in Magisk Zygisk is enabled; turn it OFF in Magisk"
        setenforce 0 2>/dev/null
        return 0
    fi
    lsposed_ns_enter
    install_global_root
    if [ "$SOFT_REBOOT" = "1" ]; then
        LSPOSED_MODE=auto
        if ! stop_lsposed_daemon; then
            LSPOSED_PREP=0
            LSPOSED_RESULT=lspd_stop_failed
            echo "ERROR: could not stop the previous lspd; refusing zygote restart"
            setenforce 0 2>/dev/null
            return 0
        fi
        if ! lsposed_module_complete >/dev/null 2>&1; then
            lsposed_module_complete
            LSPOSED_PREP=0
            LSPOSED_RESULT=module_incomplete
            echo "ERROR: installed LSPosed module is incomplete; refusing zygote restart"
            setenforce 0 2>/dev/null
            return 0
        fi
        LSPOSED_MODULE_STATUS=kept_installed
        LSPOSED_MODULE_UPDATED=0
        if ! pkg_installed "$LSPOSED_MANAGER_PKG"; then
            install_lsposed_manager
            echo "LSPosed manager: status=$LSPOSED_MGR_STATUS pkg=$LSPOSED_MANAGER_PKG apk=$LSPOSED_MANAGER_APK"
        else
            LSPOSED_MGR_STATUS=installed
            echo "LSPosed manager: already installed ($LSPOSED_MANAGER_PKG)"
        fi
        check_lsposed_versions || echo "WARN: LSPosed manager/module version differ; continuing with the installed pair"
        LSPOSED_PREP=1
        LSPOSED_RESULT=prepared
        echo "LSPosed: AUTO mode; policy/module/manager ready, lspd starts after Zygisk Next"
    else
        LSPOSED_MODE=manual
        if ! lsposed_module_complete >/dev/null 2>&1; then
            lsposed_module_complete
            LSPOSED_PREP=0
            LSPOSED_RESULT=module_incomplete
            echo "ERROR: installed LSPosed module is incomplete; do not restart yet"
            setenforce 0 2>/dev/null
            return 0
        fi
        LSPOSED_MODULE_STATUS=kept_installed
        LSPOSED_MODULE_UPDATED=0
        if ! pkg_installed "$LSPOSED_MANAGER_PKG"; then
            install_lsposed_manager
        fi
        LSPOSED_MGR_STATUS=installed
        echo "LSPosed manager: status=$LSPOSED_MGR_STATUS pkg=$LSPOSED_MANAGER_PKG"
        check_lsposed_versions || echo "WARN: LSPosed manager/module version differ; continuing"
        setenforce 0 2>/dev/null
        LSPOSED_PREP=0
        LSPOSED_RESULT=prepared_manual
        echo "LSPosed: MANUAL mode; policy/manager verified, lspd and zygote untouched"
    fi
    setenforce 0 2>/dev/null
    echo "lsposed prep enforcing=$(getenforce 2>/dev/null) deferred"
}

zygote_primary_pid() {
    for _zpp in zygote64 zygote; do
        _zpp_out=$(${PBB:-$BB} pidof "$_zpp" 2>/dev/null)
        [ -n "$_zpp_out" ] && {
            printf '%s\n' "$_zpp_out"
            return 0
        }
    done
    return 1
}

soft_reboot_lsposed() {
    [ "$LSPOSED_PREP" = "1" ] || return 0
    LSPOSED_RESTART_MODE=none
    LSPOSED_BRIDGE=unknown
    LSPD_PID=""
    ZN_PID=""

    _srl_bb=${PBB:-$BB}
    _srl_ns=$NSENTER_CMD
    [ -n "$_srl_ns" ] || _srl_ns=""

    setenforce 0 2>/dev/null

    echo "[1] killing old lspd"
    stop_lsposed_daemon
    rm -f /data/adb/lspd/monitor /data/adb/lspd/lock 2>/dev/null
    sleep 1

    echo "[2] reading zygote environment"
    _srl_zpid=$(zygote_primary_pid)
    if [ -z "$_srl_zpid" ]; then
        LSPOSED_RESULT=zygote_missing
        echo "ERROR: no zygote64/zygote process; refusing to restart"
        setenforce 1 2>/dev/null
        return 1
    fi
    _srl_boot=$($_srl_bb tr '\0' '\n' < "/proc/$_srl_zpid/environ" 2>/dev/null |
               $_srl_bb grep -m1 '^BOOTCLASSPATH=')
    _srl_dex=$($_srl_bb tr '\0' '\n' < "/proc/$_srl_zpid/environ" 2>/dev/null |
               $_srl_bb grep -m1 '^DEX2OATBOOTCLASSPATH=')
    if [ -z "$_srl_boot" ]; then
        LSPOSED_RESULT=no_bootclasspath
        echo "ERROR: cannot read BOOTCLASSPATH from zygote=$_srl_zpid; refusing"
        setenforce 1 2>/dev/null
        return 1
    fi

    echo "[3] starting zygiskd daemon from $ZYGISKSU_DIR"
    if [ ! -x "$ZYGISKSU_DIR/bin/zygiskd" ]; then
        LSPOSED_RESULT=zn_binary_missing
        echo "ERROR: $ZYGISKSU_DIR/bin/zygiskd is missing; refusing"
        setenforce 1 2>/dev/null
        return 1
    fi
    ( cd "$ZYGISKSU_DIR" && exec ./bin/zygiskd daemon ) >/dev/null 2>&1 &
    sleep 3
    ZN_PID=$(zn_injector_pid)

    echo "[4] running zygiskd service-stage"
    ( cd "$ZYGISKSU_DIR" && exec ./bin/zygiskd service-stage ) >/dev/null 2>&1 &
    sleep 2

    echo "[5] starting lspd"
    _srl_app=/system/bin/app_process
    [ -x "$_srl_app" ] || _srl_app=${APP_PROCESS:-/system/bin/app_process64}
    _srl_dir=$LSPOSED_DIR
    if [ ! -f "$_srl_dir/daemon.apk" ]; then
        LSPOSED_RESULT=daemon_apk_missing
        echo "ERROR: $_srl_dir/daemon.apk is missing; refusing"
        setenforce 1 2>/dev/null
        return 1
    fi
    _srl_setsid="$_srl_bb setsid"
    $_srl_bb setsid true >/dev/null 2>&1 || _srl_setsid=""
    $_srl_setsid $_srl_ns /system/bin/sh -c "
        cd $_srl_dir
        export $_srl_boot
        [ -n '$_srl_dex' ] && export $_srl_dex
        export PATH=$PATH
        exec $_srl_app -Djava.class.path=$_srl_dir/daemon.apk -Xnoimage-dex2oat /system/bin --nice-name=lspd org.lsposed.lspd.Main
    " </dev/null >/dev/null 2>&1 &

    LSPD_PID=""
    for _lw in 1 2 3 4 5 6 7 8 9 10; do
        LSPD_PID=$(lspd_single_pid 2>/dev/null)
        [ -n "$LSPD_PID" ] && break
        $BB usleep 150000 2>/dev/null || sleep 1
    done

    if [ -z "$LSPD_PID" ]; then
        LSPOSED_RESULT=lspd_died
        echo "ERROR: lspd did not start"
        setenforce 1 2>/dev/null
        return 1
    $BB usleep 500000 2>/dev/null || sleep 1
    LSPD_PID=$(lspd_single_pid 2>/dev/null)
    [ -n "$LSPD_PID" ] || { setenforce 1 2>/dev/null; return 1; }

    _srl_old_ss=$($_srl_bb pidof system_server 2>/dev/null)
    ZYGOTE_BEFORE=$(zygote_primary_pid)
    echo "[6] killing zygote64 pid=$ZYGOTE_BEFORE"
    kill -9 $ZYGOTE_BEFORE 2>/dev/null
    LSPOSED_RESTART_MODE=kill-zygote

    _srl_i=0
    if [ -n "$_srl_old_ss" ]; then
        while [ "$_srl_i" -lt 15 ]; do
            sleep 1
            kill -0 $_srl_old_ss 2>/dev/null || break
            _srl_i=$((_srl_i + 1))
        done
    fi

    _srl_i=0
    SYSTEM_SERVER_AFTER=""
    while [ "$_srl_i" -lt 30 ]; do
        sleep 1
        _srl_ss=$($_srl_bb pidof system_server 2>/dev/null)
        if [ -n "$_srl_ss" ] && [ "$_srl_ss" != "$_srl_old_ss" ]; then
            SYSTEM_SERVER_AFTER=$_srl_ss
            break
        fi
        _srl_i=$((_srl_i + 1))
    done
    ZYGOTE_AFTER=$(zygote_primary_pid)
    if [ -z "$SYSTEM_SERVER_AFTER" ]; then
        LSPOSED_RESULT=system_server_timeout
        setenforce 1 2>/dev/null
        return 1
    fi

    echo "[7] waiting for the binder bridge"
    _srl_bridge_log=""
    _srl_i=0
    while [ "$_srl_i" -lt 60 ]; do
        sleep 1
        _srl_bridge_log=$(ls -t /data/adb/lspd/log/verbose_*.log 2>/dev/null | $_srl_bb head -n1)
        if [ -n "$_srl_bridge_log" ]; then
            _srl_line=$($_srl_bb grep 'binder received' "$_srl_bridge_log" 2>/dev/null |
                        $_srl_bb grep "$SYSTEM_SERVER_AFTER" | $_srl_bb tail -n1)
            if [ -n "$_srl_line" ]; then
                LSPOSED_BRIDGE=1
                break
            fi
        fi
        _srl_i=$((_srl_i + 1))
    done

    if [ "$LSPOSED_BRIDGE" != "1" ]; then
        kill -9 $SYSTEM_SERVER_AFTER 2>/dev/null
        sleep 3
        _srl_i=0
        SYSTEM_SERVER_AFTER=""
        while [ "$_srl_i" -lt 20 ]; do
            sleep 1
            _srl_ss=$($_srl_bb pidof system_server 2>/dev/null)
            if [ -n "$_srl_ss" ] && [ "$_srl_ss" != "$_srl_old_ss" ]; then
                SYSTEM_SERVER_AFTER=$_srl_ss
                break
            fi
            _srl_i=$((_srl_i + 1))
        done
        if [ -n "$SYSTEM_SERVER_AFTER" ]; then
            _srl_i=0
            while [ "$_srl_i" -lt 30 ]; do
                sleep 1
                _srl_bridge_log=$(ls -t /data/adb/lspd/log/verbose_*.log 2>/dev/null | $_srl_bb head -n1)
                if [ -n "$_srl_bridge_log" ]; then
                    _srl_line=$($_srl_bb grep 'binder received' "$_srl_bridge_log" 2>/dev/null |
                                $_srl_bb grep "$SYSTEM_SERVER_AFTER" | $_srl_bb tail -n1)
                    if [ -n "$_srl_line" ]; then
                        LSPOSED_BRIDGE=1
                        LSPOSED_RESTART_MODE="$LSPOSED_RESTART_MODE+ss-kill"
                        break
                    fi
                fi
                _srl_i=$((_srl_i + 1))
            done
        fi
    fi

    for _mw in 1 2 3 4 5 6 7 8 9 10; do
        [ -e /data/adb/lspd/monitor ] && break
        $BB usleep 200000 2>/dev/null || sleep 1
    done
    chmod 644 /data/adb/lspd/monitor 2>/dev/null
    LSPD_PID=$(lspd_single_pid 2>/dev/null)
    setenforce 1 2>/dev/null

    if [ -n "$LSPD_PID" ] && [ "$LSPOSED_BRIDGE" = "1" ]; then
        LSPOSED_RESULT=ok
    else
        LSPOSED_RESULT=partial
    fi
    return 0
}

debug_ramdisk_xattr_ok() {
    _probe=/debug_ramdisk/.dfroot_xattr_probe
    rm -f "$_probe" 2>/dev/null
    touch "$_probe" 2>/dev/null || return 1
    chcon u:object_r:app_data_file:s0 "$_probe" 2>/dev/null || {
        rm -f "$_probe" 2>/dev/null
        return 1
    }
    _label=$(ls -Z "$_probe" 2>/dev/null)
    rm -f "$_probe" 2>/dev/null
    case "$_label" in
        *app_data_file*) return 0 ;;
    esac
    return 1
}

prepare_debug_ramdisk() {
    DEBUG_RD_F2FS=0
    umount -l /debug_ramdisk/.magisk 2>/dev/null
    mkdir -p "$F2FS_RD" 2>/dev/null || return 1
    mount --make-rshared / 2>/dev/null
    if mount --bind "$F2FS_RD" /debug_ramdisk 2>/dev/null; then
        DEBUG_RD_F2FS=1
    else
        return 1
    fi
    rm -rf /debug_ramdisk/* /debug_ramdisk/.[!.]* /debug_ramdisk/..?* 2>/dev/null
    mkdir -p /debug_ramdisk/.magisk/busybox /debug_ramdisk/.magisk/device \
             /debug_ramdisk/.magisk/block 2>/dev/null
    chmod 755 /debug_ramdisk 2>/dev/null
    chcon "$MAGISK_FILE_CON" /debug_ramdisk 2>/dev/null
    rm -rf /debug_ramdisk/.magisk/pts 2>/dev/null
    if ! debug_ramdisk_xattr_ok; then
        return 1
    fi
    XATTR_BIND_OK=1
    return 0
}

count_installed_modules() {
    _cim=0
    for _cim_d in /data/adb/modules/*; do
        [ -d "$_cim_d" ] && _cim=$((_cim + 1))
    done
    echo "$_cim"
}

probe_activity_service() {
    _bb=${PBB:-$BB}
    _cmd_out=$($_bb timeout 8 /system/bin/cmd activity get-current-user 2>&1)
    _cmd_rc=$?
    ACTIVITY_PROBE_OUT="cmd: rc=$_cmd_rc"
    case "$_cmd_out" in
        *"Can't find service"*|*"Can't connect to activity manager"*|*"Failure calling service activity"*)
            return 1 ;;
    esac
    [ "$_cmd_rc" = "0" ] && return 0
    return 2
}

wait_for_activity_service() {
    _want=${1:-60}
    _i=0
    while [ "$_i" -lt "$_want" ]; do
        probe_activity_service && return 0
        sleep 1
        _i=$((_i + 1))
    done
    return 1
}

kill_pid_list() {
    for _kp in $1; do
        case "$_kp" in ''|*[!0-9]*) continue ;; esac
        kill -0 "$_kp" 2>/dev/null || continue
        kill -9 "$_kp" 2>/dev/null
    done
}

stop_magiskd_guard() {
    if [ -s "$GUARD_PIDFILE" ]; then
        _gp=$(cat "$GUARD_PIDFILE" 2>/dev/null)
        case "$_gp" in
            ''|*[!0-9]*) ;;
            *)
                if kill -0 "$_gp" 2>/dev/null; then
                    kill "$_gp" 2>/dev/null
                    sleep 1
                fi
                ;;
        esac
        rm -f "$GUARD_PIDFILE" 2>/dev/null
    fi
}

start_magiskd_guard() {
    GUARD_STARTED=0
    stop_magiskd_guard
    if [ -f "$SUDIR/magiskd-guard.asset.sh" ]; then
        cp -f "$SUDIR/magiskd-guard.asset.sh" "$SUDIR/magiskd-guard.sh" 2>/dev/null
    fi
    [ -f "$SUDIR/magiskd-guard.sh" ] || return 1
    chmod 755 "$SUDIR/magiskd-guard.sh" 2>/dev/null
    chcon "$MAGISK_FILE_CON" "$SUDIR/magiskd-guard.sh" 2>/dev/null
    _runner=${PBB:-$BB}
    [ -x "$_runner" ] || _runner=$BB
    $_runner setsid $_runner runcon u:r:magisk:s0 /system/bin/sh \
        "$SUDIR/magiskd-guard.sh" >/dev/null 2>&1 &
    sleep 2
    [ -s "$GUARD_PIDFILE" ] && GUARD_STARTED=1
    [ "$GUARD_STARTED" = "1" ]
}

su_is_magisk_link() {
    [ -L "$1" ] || return 1
    [ "$(readlink "$1" 2>/dev/null)" = "/debug_ramdisk/magisk" ]
}

legacy_su_cleanup() {
    for _p in /debug_ramdisk/su /system/xbin/su; do
        [ -e "$_p" ] || [ -L "$_p" ] || continue
        if su_is_magisk_link "$_p"; then
            continue
        fi
        rm -f "$_p" 2>/dev/null
    done
}

close_legacy_channel() {
    CHANNEL=closed
    [ -e /proc/dfroot_su ] || return 0
    /system/bin/cat /proc/dfroot_su >/dev/null 2>&1
    sleep 1
    if printf '1' > /proc/dfroot_su 2>/dev/null; then
        CHANNEL=open
        return 1
    fi
    return 0
}

restore_one_module() {
    _rom_name=$1
    _rom_off="/data/adb/$_rom_name.dfroot_off"
    [ -e "$_rom_off" ] || return 0
    _rom_dst="/data/adb/$_rom_name"
    [ ! -e "$_rom_dst" ] && mv "$_rom_off" "$_rom_dst" 2>/dev/null
}

restore_one_boot_script() {
    _rbs=$1
    [ -e "$_rbs" ] || return 0
    _rbs_dir=${_rbs%/*}
    _rbs_name=${_rbs##*/}
    _rbs_name=${_rbs_name%%.dfroot_pfs_off*}
    _rbs_dst="$_rbs_dir/$_rbs_name"
    [ ! -e "$_rbs_dst" ] && mv "$_rbs" "$_rbs_dst" 2>/dev/null
}

restore_module_scripts() {
    for _rms_base in /data/adb/modules /data/adb/modules_update; do
        [ -d "$_rms_base" ] || continue
        for _rms in "$_rms_base"/*/post-fs-data.sh.dfroot_pfs_off*; do
            [ -e "$_rms" ] || continue
            restore_one_boot_script "$_rms"
        done
    done
}

restore_pfsd_backups() {
    for _rpb in "$BOOT_PFSD_PREFIX"* /data/adb/post-fs-data.d.dfroot_off; do
        [ -e "$_rpb" ] || continue
        [ ! -e /data/adb/post-fs-data.d ] && mv "$_rpb" /data/adb/post-fs-data.d 2>/dev/null
    done
}

restore_boot_scripts() {
    restore_module_scripts
    restore_pfsd_backups
    BOOT_SCRIPTS_OFF=0
}

disable_all_modules() {
    MODULES_DISABLED_BY_US=""
    [ "$DISABLE_MODULES" = "1" ] || return 0
    for _dam_m in /data/adb/modules/*; do
        [ -d "$_dam_m" ] || continue
        [ -f "$_dam_m/disable" ] && continue
        if : > "$_dam_m/disable" 2>/dev/null; then
            MODULES_DISABLED_BY_US="$MODULES_DISABLED_BY_US $_dam_m"
        fi
    done
}

restore_disabled_modules() {
    [ -n "$MODULES_DISABLED_BY_US" ] || return 0
    for _rdm_m in $MODULES_DISABLED_BY_US; do
        rm -f "$_rdm_m/disable" 2>/dev/null
    done
    MODULES_DISABLED_BY_US=""
}

hide_one_boot_script() {
    _hbs=$1
    [ -e "$_hbs" ] || return 0
    _hbs_off="$_hbs$BOOT_SCRIPT_SUFFIX.$$"
    if mv "$_hbs" "$_hbs_off" 2>/dev/null; then
        BOOT_SCRIPTS_OFF=$((BOOT_SCRIPTS_OFF + 1))
        return 0
    fi
    return 1
}

hide_boot_scripts() {
    BOOT_SCRIPTS_OFF=0
    _hbs_fail=0
    if [ -e /data/adb/post-fs-data.d ]; then
        _hbs_pfsd="$BOOT_PFSD_PREFIX.$$"
        if mv /data/adb/post-fs-data.d "$_hbs_pfsd" 2>/dev/null; then
            BOOT_SCRIPTS_OFF=$((BOOT_SCRIPTS_OFF + 1))
        else
            _hbs_fail=1
        fi
    fi
    for _hbs_base in /data/adb/modules /data/adb/modules_update; do
        [ -d "$_hbs_base" ] || continue
        for _hbs_d in "$_hbs_base"/*; do
            [ -d "$_hbs_d" ] || continue
            [ -e "$_hbs_d/post-fs-data.sh" ] || continue
            hide_one_boot_script "$_hbs_d/post-fs-data.sh" || _hbs_fail=1
        done
    done
    [ "$_hbs_fail" = "0" ]
}

recover_modules() {
    restore_one_module modules
    restore_one_module modules_update
    restore_pfsd_backups
    restore_module_scripts
}

on_exit() {
    restore_boot_scripts
    restore_disabled_modules
    [ -e /proc/dfroot_su ] && /system/bin/cat /proc/dfroot_su >/dev/null 2>&1
    rm -f /data/local/tmp/su /data/local/tmp/su-client \
          "$SUDIR/su.legacy" 2>/dev/null
    setenforce 1 2>/dev/null
}
trap on_exit EXIT INT TERM HUP

fatal() {
    echo "FATAL: $*"
    legacy_su_cleanup
    close_legacy_channel
    if [ "$DONE_FD_OPEN" = "1" ]; then
        printf 'DEPLOY_FAILED %s result=failed fallback=%s enforcing=%s channel=%s\n' \
            "$(date)" "$FALLBACK" "$(getenforce 2>/dev/null)" "$CHANNEL" >&9
    else
        printf 'DEPLOY_FAILED %s result=failed fallback=%s enforcing=%s channel=%s\n' \
            "$(date)" "$FALLBACK" "$(getenforce 2>/dev/null)" "$CHANNEL" >> "$DONE_MARKER" 2>/dev/null
    fi
    exit 1
}

pkg_installed() {
    if [ -r "$PKGLIST" ] &&
       $BB awk -v p="$1" '$1 == p { found=1 } END { exit !found }' "$PKGLIST" 2>/dev/null; then
        return 0
    fi
    apk_of "$1" >/dev/null 2>&1 && return 0
    return 1
}

pkg_uid() {
    _pu=$($BB awk -v p="$1" '$1 == p { print $2; exit }' "$PKGLIST" 2>/dev/null)
    [ -z "$_pu" ] && _pu=$(stat -c %u "/data/user_de/0/$1" 2>/dev/null)
    [ -n "$_pu" ] && echo "$_pu"
}

apk_of() {
    for g in /data/app/*/"$1"-*/base.apk /data/app/"$1"-*/base.apk; do
        if [ -f "$g" ]; then
            echo "$g"
            return 0
        fi
    done
    return 1
}

is_magisk_apk() {
    [ -f "$1" ] || return 1
    $BB unzip -p "$1" assets/util_functions.sh 2>/dev/null | $BB grep -q 'MAGISK_VER=' || return 1
    return 0
}

import_android_env() {
    ANDROID_ENV_OK=0
    _z=""
    for _name in zygote64 zygote; do
        _z=$($BB pidof "$_name" 2>/dev/null | $BB awk '{print $1; exit}')
        [ -n "$_z" ] && break
    done
    if [ -n "$_z" ] && [ -r "/proc/$_z/environ" ]; then
        _env=/data/local/tmp/dfroot.zygote.env.$$
        if $PBB tr '\0' '\n' < "/proc/$_z/environ" > "$_env" 2>/dev/null; then
            while IFS= read -r _kv; do
                case "$_kv" in
                    ANDROID_ROOT=*|ANDROID_DATA=*|ANDROID_ART_ROOT=*| \
                    ANDROID_I18N_ROOT=*|ANDROID_TZDATA_ROOT=*|ANDROID_ASSETS=*| \
                    ANDROID_STORAGE=*|ASEC_MOUNTPOINT=*|EXTERNAL_STORAGE=*| \
                    BOOTCLASSPATH=*|DEX2OATBOOTCLASSPATH=*| \
                    SYSTEMSERVERCLASSPATH=*|STANDALONE_SYSTEMSERVER_JARS=*)
                        export "$_kv"
                        ;;
                esac
            done < "$_env"
        fi
        rm -f "$_env" 2>/dev/null
    fi
    [ -n "$ANDROID_ROOT" ] || ANDROID_ROOT=/system
    [ -n "$ANDROID_DATA" ] || ANDROID_DATA=/data
    export ANDROID_ROOT ANDROID_DATA
    ANDROID_ENV_OK=1
    return 0
}

sql_run() {
    if [ -x /debug_ramdisk/.magisk/busybox/busybox ]; then
        /debug_ramdisk/.magisk/busybox/busybox timeout 25 "$CLIENT" --sqlite "$1" 2>&1
    else
        $BB timeout 25 "$CLIENT" --sqlite "$1" 2>&1
    fi
}

detect_app_process() {
    APP_PROCESS=""
    for p in /system/bin/app_process64 /system/bin/app_process \
             /system/bin/app_process32 \
             /apex/com.android.art/bin/app_process64 \
             /apex/com.android.art/bin/app_process; do
        if [ -f "$p" ] && [ -x "$p" ]; then
            APP_PROCESS="$p"
            return 0
        fi
    done
    return 1
}

find_app_process_offsets() {
    _f=$1
    $BB strings -t d -n 23 "$_f" 2>/dev/null \
        | $BB grep -F '/system/bin/app_process' 2>/dev/null \
        | $BB awk '
            {
                off = $1
                line = $0
                sub(/^[ \t]*[0-9]+[ \t]+/, "", line)
                pos = index(line, "/system/bin/app_process")
                if (pos > 0)
                    print off + pos - 1
            }'
}

setup_app_process_transport() {
    APP_RUN="$APP_PROCESS"
    APP_PATCHED=0
    if [ -z "$APP_PROCESS" ]; then
        return 1
    fi
    if [ "$APP_PROCESS" = "/system/bin/app_process" ]; then
        APP_TRANSPORT_OK=1
        return 0
    ]
    if ! ln -sf "$APP_PROCESS" "$APP_PROXY" 2>/dev/null; then
        return 1
    fi
    if ! cp -f /debug_ramdisk/magisk "$SUDIR/magisk.before_appprocess" 2>/dev/null; then
        rm -f "$APP_PROXY" 2>/dev/null
        return 1
    fi
    OFFS=$(find_app_process_offsets /debug_ramdisk/magisk)
    if [ -z "$OFFS" ]; then
        rm -f "$APP_PROXY" 2>/dev/null
        return 1
    fi
    PATCHED=0
    for off in $OFFS; do
        case "$off" in ''|*[!0-9]*) continue ;; esac
        if printf '%s' "$APP_PROXY" | $BB dd of=/debug_ramdisk/magisk \
             bs=1 seek="$off" conv=notrunc 2>/dev/null; then
            PATCHED=$((PATCHED + 1))
        fi
    done
    if [ "$PATCHED" = "0" ]; then
        cp -f "$SUDIR/magisk.before_appprocess" /debug_ramdisk/magisk 2>/dev/null
        chmod 755 /debug_ramdisk/magisk 2>/dev/null
        chcon "$MAGISK_FILE_CON" /debug_ramdisk/magisk 2>/dev/null
        rm -f "$APP_PROXY" 2>/dev/null
        return 1
    fi
    chmod 755 /debug_ramdisk/magisk 2>/dev/null
    chcon "$MAGISK_FILE_CON" /debug_ramdisk/magisk 2>/dev/null
    APP_PATCHED=1
    APP_TRANSPORT_OK=1
    APP_RUN="$APP_PROXY"
    return 0
}

policy_rows() {
    _bb=$BB
    [ -x /debug_ramdisk/.magisk/busybox/busybox ] && \
        _bb=/debug_ramdisk/.magisk/busybox/busybox
    sql_run 'SELECT uid,policy,until,logging,notification FROM policies;' 2>/dev/null \
        | $_bb awk -F'|' '
            NF >= 5 {
                for (i = 1; i <= 5; i++) sub(/^[^=]*=/, "", $i)
                if ($1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^-?[0-9]+$/ &&
                    $4 ~ /^[0-9]+$/ && $5 ~ /^[0-9]+$/)
                    print $1 "|" $2 "|" $3 "|" $4 "|" $5
            }'
}

uid_is_installed() {
    _uid="$1"
    _bb=$BB
    [ -x /debug_ramdisk/.magisk/busybox/busybox ] && \
        _bb=/debug_ramdisk/.magisk/busybox/busybox
    if $_bb awk -v u="$_uid" '$2 == u { found = 1 } END { exit !found }' \
         "$PKGLIST" 2>/dev/null; then
        return 0
    fi
    for _d in /data/user_de/*/* /data/user/*/*; do
        [ -d "$_d" ] || continue
        _du=$($_bb stat -c %u "$_d" 2>/dev/null)
        [ "$_du" = "$_uid" ] && return 0
    done
    return 1
}

restore_missing_policies() {
    POL_CURRENT="$1"
    POL_RESTORED=0
    [ -s "$POL_SNAPSHOT" ] || return 0
    POL_UIDS="$SUDIR/policies.current.uids"
    _bb=$BB
    [ -x /debug_ramdisk/.magisk/busybox/busybox ] && \
        _bb=/debug_ramdisk/.magisk/busybox/busybox
    $_bb awk -F'|' '{ print $1 }' "$POL_CURRENT" 2>/dev/null > "$POL_UIDS"
    while IFS='|' read -r uid policy pol_until pol_logging pol_notification; do
        [ -n "$uid" ] && [ -n "$policy" ] || continue
        if $_bb grep -qx "$uid" "$POL_UIDS" 2>/dev/null; then
            continue
        fi
        if [ "$uid" -ge 10000 ] 2>/dev/null; then
            if ! uid_is_installed "$uid"; then
                continue
            fi
        fi
        if sql_run "INSERT OR REPLACE INTO policies(uid,policy,until,logging,notification) \
                    VALUES($uid,$policy,$pol_until,$pol_logging,$pol_notification);" >/dev/null 2>&1; then
            POL_RESTORED=$((POL_RESTORED + 1))
        fi
    done < "$POL_SNAPSHOT"
}

copy_if_changed() {
    _cc_src=$1
    _cc_dst=$2
    _cc_mode=${3:-755}
    _cc_bb=${PBB:-$BB}
    [ -f "$_cc_src" ] || return 1
    _cc_dir=${_cc_dst%/*}
    [ -n "$_cc_dir" ] && mkdir -p "$_cc_dir" 2>/dev/null
    cp -f "$_cc_src" "$_cc_dst" 2>/dev/null || return 1
    chmod "$_cc_mode" "$_cc_dst" 2>/dev/null
    return 0
}

stage_bin() {
    [ -s "$1" ] || return 1
    cp -f "$1" "$2" 2>/dev/null && chmod "$3" "$2" 2>/dev/null
}

# ---------- 0a. Magisk must be installed; no lock, no import ---------------
MGR_PKG=""
MGR_APK=""
for _g_pkg in "$(/system/bin/cat "$SUDIR/manager.package" 2>/dev/null | $BB head -n1 | $BB tr -d ' \r\n')" \
               com.topjohnwu.magisk; do
    [ -n "$_g_pkg" ] || continue
    case "$_g_pkg" in *[!A-Za-z0-9._]*) continue ;; esac
    _g_apk=$(apk_of "$_g_pkg" 2>/dev/null)
    if [ -n "$_g_apk" ] && [ -s "$_g_apk" ]; then
        MGR_PKG=$_g_pkg
        MGR_APK=$_g_apk
        break
    fi
done
if [ -z "$MGR_APK" ]; then
    echo "ERROR_NO_MAGISK: 沒有偵測到已安裝的 Magisk"
    printf 'DEPLOY_FAILED %s result=failed error=no_magisk\n' "$(date)" >> "$DONE_MARKER" 2>/dev/null
    setenforce 1 2>/dev/null
    exit 1
fi
MGR_UID=$(stat -c %u "/data/user_de/0/$MGR_PKG" 2>/dev/null)
MGR_DE=/data/user_de/0/$MGR_PKG
echo "magisk: $MGR_PKG  apk=$MGR_APK"

APK_VER_CODE=$($BB unzip -p "$MGR_APK" assets/util_functions.sh 2>/dev/null |
               $BB sed -n 's/^MAGISK_VER_CODE=//p' | $BB head -1 | $BB tr -dc '0-9')
APK_VER_NAME=$($BB unzip -p "$MGR_APK" assets/util_functions.sh 2>/dev/null |
               $BB sed -n 's/^MAGISK_VER=//p' | $BB head -1 | $BB tr -d '" \r\n')
DEPLOYED_VER=$($BB cat "$SUDIR/installed.version" 2>/dev/null | $BB tr -dc '0-9')

# 如果尚未部署版本，或者有 upgrade.request，強制觸發解壓縮
if [ ! -s "$SUDIR/deployed.version" ] && [ ! -s "$STAGE/upgrade.request" ]; then
    : > "$STAGE/upgrade.request" 2>/dev/null
fi

if [ -s "$STAGE/upgrade.request" ] || [ ! -s "$STAGE/magisk" ]; then
    rm -f "$STAGE/upgrade.request" 2>/dev/null
    echo "magisk: extracting the arm64-v8a file set from the installed APK to STAGE ($STAGE)"
    mkdir -p "$STAGE/chromeos" 2>/dev/null
    _ex_n=0
    
    # 針對 arm64-v8a 進行精確解壓縮並重命名
    for _pair in \
        "lib/arm64-v8a/libmagisk.so:magisk" \
        "lib/arm64-v8a/libmagiskinit.so:magiskinit" \
        "lib/arm64-v8a/libmagiskboot.so:magiskboot" \
        "lib/arm64-v8a/libmagiskpolicy.so:magiskpolicy" \
        "lib/arm64-v8a/libbusybox.so:busybox" \
        "lib/arm64-v8a/libinit-ld.so:init-ld" \
        "lib/arm64-v8a/libbootctl.so:bootctl" \
        "assets/boot_patch.sh:boot_patch.sh" \
        "assets/util_functions.sh:util_functions.sh" \
        "assets/addon.d.sh:addon.d.sh" \
        "assets/module_installer.sh:module_installer.sh" \
        "assets/app_functions.sh:app_functions.sh" \
        "assets/uninstaller.sh:uninstaller.sh" ; do
        
        _src=${_pair%%:*}
        _dst=${_pair##*:}
        if $BB unzip -p "$MGR_APK" "$_src" > "$STAGE/$_dst" 2>/dev/null && [ -s "$STAGE/$_dst" ]; then
            chmod 755 "$STAGE/$_dst" 2>/dev/null
            _ex_n=$((_ex_n + 1))
        else
            rm -f "$STAGE/$_dst" 2>/dev/null
        fi
    done
    
    for _a in futility kernel.keyblock kernel_data_key.vbprivk; do
        $BB unzip -p "$MGR_APK" "assets/chromeos/$_a" > "$STAGE/chromeos/$_a.tmp" 2>/dev/null
        if [ -s "$STAGE/chromeos/$_a.tmp" ]; then
            mv -f "$STAGE/chromeos/$_a.tmp" "$STAGE/chromeos/$_a" 2>/dev/null
        else
            rm -f "$STAGE/chromeos/$_a.tmp" 2>/dev/null
        fi
    done
    echo "magisk: extracted $_ex_n file(s) from the APK into $STAGE"
    
    rm -f "$STAGE/magisk32" "$STAGE/magisk64" 2>/dev/null
    printf '%s\n' "${APK_VER_CODE:-0}" > "$SUDIR/installed.version" 2>/dev/null
    chmod 644 "$SUDIR/installed.version" 2>/dev/null
    
    # 修正 STAGE 目錄下的所有檔案與擁有者權限，解決 FileNotFoundException 與權限拒絕
    _df_uid=$(pkg_uid df.root 2>/dev/null)
    [ -n "$_df_uid" ] && chown -R "$_df_uid:$_df_uid" "$STAGE" 2>/dev/null
    
    rm -f "$STAGE/payload.applied" "$STAGE/payload.manifest" 2>/dev/null
    MAGISK_FILES_FORCE=1
    MAGISK_NEW_SET=1
fi

DPL_FAST=0
if [ -s "$SUDIR/deployed.version" ] && [ -s "$DATABIN/magisk" ] \
   && [ "${MAGISK_FILES_FORCE:-0}" != "1" ]; then
    DPL_FAST=1
fi

echo "--- stage components ---"
mkdir -p "$DATABIN" "$DATABIN/chromeos" "$SUDIR" 2>/dev/null
chmod 700 /data/adb 2>/dev/null

if [ "$DPL_FAST" = "1" ]; then
    echo "deployed: already in $DATABIN, skipping copy"
else
    stage_bin "$STAGE/busybox" "$DATABIN/busybox" 755
    stage_bin "$STAGE/magisk" "$DATABIN/magisk" 755
    stage_bin "$STAGE/magiskinit" "$DATABIN/magiskinit" 755
    stage_bin "$STAGE/magiskboot" "$DATABIN/magiskboot" 755
    stage_bin "$STAGE/magiskpolicy" "$DATABIN/magiskpolicy" 755
    [ -s "$STAGE/init-ld" ] && stage_bin "$STAGE/init-ld" "$DATABIN/init-ld" 755
    stage_bin "$STAGE/util_functions.sh" "$DATABIN/util_functions.sh" 755
    copy_if_changed "$STAGE/addon.d.sh" "$DATABIN/addon.d.sh" 755
    stage_bin "$STAGE/boot_patch.sh" "$DATABIN/boot_patch.sh" 755
    copy_if_changed "$STAGE/chromeos/futility" "$DATABIN/chromeos/futility" 755
    copy_if_changed "$STAGE/chromeos/kernel.keyblock" "$DATABIN/chromeos/kernel.keyblock" 644
    copy_if_changed "$STAGE/chromeos/kernel_data_key.vbprivk" "$DATABIN/chromeos/kernel_data_key.vbprivk" 644
    [ -x "$DATABIN/busybox" ] && BB="$DATABIN/busybox"
fi

chmod 755 "$STAGE/deploy-magisk.sh" "$STAGE/magiskd-guard.sh" 2>/dev/null

MAGISK_MISSING=""
for _mf in magisk magiskinit magiskboot magiskpolicy \
           busybox util_functions.sh addon.d.sh boot_patch.sh; do
    [ -s "$DATABIN/$_mf" ] || MAGISK_MISSING="$MAGISK_MISSING $_mf"
done
if [ -n "$MAGISK_MISSING" ]; then
    fatal "incomplete Magisk file set:$MAGISK_MISSING"
fi
echo "Magisk file set: complete"
progress 30

read_soft_reboot_pref() {
    SOFT_REBOOT=0
    DISABLE_MODULES=0
    _sr_xml=$STAGE/shared_prefs/dfroot.xml
    if [ -f "$_sr_xml" ]; then
        $BB grep -q 'name="soft_reboot".*value="true"' "$_sr_xml" 2>/dev/null && SOFT_REBOOT=1
        $BB grep -q 'name="disable_modules".*value="true"' "$_sr_xml" 2>/dev/null && DISABLE_MODULES=1
    fi
}

detect_app_process

stop_magiskd_guard
recover_modules
OLD=$($BB pidof magiskd 2>/dev/null)
if [ -n "$OLD" ]; then
    kill_pid_list "$OLD"
    sleep 1
    rm -f /debug_ramdisk/.magisk/device/socket 2>/dev/null
fi

setenforce 0 2>/dev/null
read_soft_reboot_pref
$MPOLICY --live --magisk
apply_module_sepolicy_rules
$MPOLICY --live "allow magisk * * *"
$MPOLICY --live "allow magisk magisk process execmem"
$MPOLICY --live "allow init magisk unix_stream_socket { connectto getopt }"
for t in ptmx_device devpts devpts_t; do
    $MPOLICY --live "allow magisk $t chr_file { read write open getattr ioctl }" >/dev/null 2>&1
    $MPOLICY --live "allow magisk $t dir { search read open getattr }" >/dev/null 2>&1
done
$MPOLICY --live "allow magisk proc file { read write open getattr }" >/dev/null 2>&1

if : > "$DONE_MARKER" 2>/dev/null; then
    chmod 644 "$DONE_MARKER" 2>/dev/null
    exec 9>>"$DONE_MARKER"
    DONE_FD_OPEN=1
else
    exec 9>/dev/null
fi

try_manager() {
    _tm_pkg=$1
    [ -n "$_tm_pkg" ] || return 1
    pkg_installed "$_tm_pkg" || return 1
    _tm_apk=$(apk_of "$_tm_pkg") || return 1
    [ -n "$_tm_apk" ] || return 1
    MGR_PKG=$_tm_pkg
    MGR_UID=$(pkg_uid "$_tm_pkg")
    MGR_APK=$_tm_apk
    MGR_DE=/data/user_de/0/$_tm_pkg
    return 0
}

if [ -f /data/adb/magisk.db ]; then
    _db_rq=$($BB timeout 5 "$BB" sqlite3 /data/adb/magisk.db "SELECT value FROM strings WHERE key='requester';" 2>/dev/null | $BB tr -d ' \r\n')
    [ -n "$_db_rq" ] && try_manager "$_db_rq"
fi
[ -z "$MGR_PKG" ] && pkg_installed com.topjohnwu.magisk && try_manager com.topjohnwu.magisk

if [ -n "$MGR_PKG" ]; then
    MGR_UID=$(pkg_uid "$MGR_PKG")
    MGR_APK=$(apk_of "$MGR_PKG")
    MGR_DE=/data/user_de/0/$MGR_PKG
    printf '%s\n' "$MGR_PKG" > "$SUDIR/manager.package" 2>/dev/null
    _mp_appuid=$(pkg_uid df.root 2>/dev/null)
    [ -n "$_mp_appuid" ] && chown "$_mp_appuid:$_mp_appuid" "$SUDIR/manager.package" 2>/dev/null
fi

prepare_debug_ramdisk || fatal "could not prepare xattr-capable /debug_ramdisk"
mkdir -p /debug_ramdisk/.magisk/busybox /debug_ramdisk/.magisk/device \
         /debug_ramdisk/.magisk/block /debug_ramdisk/.magisk/worker 2>/dev/null
rm -rf /debug_ramdisk/.magisk/pts 2>/dev/null

if [ -d /debug_ramdisk/.magisk/worker ]; then
    mount --bind /debug_ramdisk/.magisk/worker /debug_ramdisk/.magisk/worker 2>/dev/null
    mount --make-private /debug_ramdisk/.magisk/worker 2>/dev/null
fi

STUB_SEEDED=1
STUB_LOADED=1

copy_if_changed "$MAGISK" /debug_ramdisk/magisk 755
chcon "$MAGISK_FILE_CON" /debug_ramdisk/magisk 2>/dev/null
setup_app_process_transport
import_android_env

cd /
/debug_ramdisk/magisk --daemon &

MPID=""
for _w in 1 2 3 4 5 6 7 8 9 10; do
    MPID=$($BB pidof magiskd 2>/dev/null)
    [ -n "$MPID" ] && break
    $BB usleep 100000 2>/dev/null || sleep 1
done
[ -n "$MPID" ] || fatal "magiskd did not start"

SQLBIN=/debug_ramdisk/magisk
for i in 1 2 3 4 5; do
    $BB timeout 2 "$SQLBIN" -V >/dev/null 2>&1 && break
    $BB usleep 150000 2>/dev/null || sleep 1
done

_DPL_VER=$($BB timeout 5 "$SQLBIN" -V 2>&1 | $BB head -1 | $BB tr -dc '0-9')
if [ -n "$_DPL_VER" ]; then
    printf 'Magisk %s\n' "$_DPL_VER" > "$SUDIR/deployed.version" 2>/dev/null
    _dv_uid=$(pkg_uid df.root 2>/dev/null)
    [ -n "$_dv_uid" ] && chown "$_dv_uid:$_dv_uid" "$SUDIR/deployed.version" 2>/dev/null
fi

if [ -n "$MGR_PKG" ]; then
    sql_run "INSERT OR REPLACE INTO strings (key,value) VALUES ('requester','$MGR_PKG');" >/dev/null 2>&1
    sql_run "DELETE FROM strings WHERE key='keystore';" >/dev/null 2>&1
fi

if [ -n "$MGR_UID" ]; then
    sql_run "INSERT OR REPLACE INTO policies (uid,policy,until,logging,notification) VALUES ($MGR_UID,2,0,1,0);" >/dev/null 2>&1
fi

policy_rows > "$POL_SNAPSHOT"
sql_run "INSERT OR REPLACE INTO settings(key,value) VALUES('bootloop',0);" >/dev/null

disable_all_modules
hide_boot_scripts

$PBB timeout 60 "$CLIENT" --post-fs-data
restore_boot_scripts
restore_disabled_modules
sleep 1

POL_CURRENT=$SUDIR/policies.after
policy_rows > "$POL_CURRENT"
restore_missing_policies "$POL_CURRENT"

install_stock_su

if [ "$APP_PATCHED" = "1" ]; then
    ln -sf "$APP_PROCESS" "$APP_PROXY" 2>/dev/null
fi

start_magiskd_guard

MPID=$($PBB pidof magiskd 2>/dev/null)
ROOT_SU_OK=0
if [ -n "$TEST_SU" ] && [ -x "$TEST_SU" ]; then
    ROOT_OUT=$($PBB timeout 20 "$TEST_SU" -c 'id' 2>&1)
    case "$ROOT_OUT" in *uid=0*) ROOT_SU_OK=1 ;; esac
fi

MAGISK_SU_OK=0
if [ "$MAGISK_READY" = "1" ] || [ "$ROOT_SU_OK" = "1" ]; then
    MAGISK_SU_OK=1
fi

close_legacy_channel

if [ "$MAGISK_SU_OK" = "1" ]; then
    prepare_lsposed
    RESULT=ok
    echo "clean: 注入成功，移除 user_de 暫存二進制檔案"
    rm -f "$STAGE/magisk" "$STAGE/magiskinit" "$STAGE/magiskboot" "$STAGE/magiskpolicy" \
          "$STAGE/busybox" "$STAGE/init-ld" "$STAGE/bootctl" "$STAGE/magisk32" "$STAGE/magisk64" \
          "$STAGE/boot_patch.sh" "$STAGE/addon.d.sh" "$STAGE/module_installer.sh" \
          "$STAGE/app_functions.sh" "$STAGE/uninstaller.sh" "$STAGE/stub.apk" "$STAGE"/*.tmp 2>/dev/null
    rm -rf "$STAGE/chromeos" 2>/dev/null
    printf 'Magisk installed to %s at %s\n' "$DATABIN" "$(date)" > "$STAGE/magisk_installed.marker" 2>/dev/null
else
    RESULT=failed
fi

_df_uid=$(pkg_uid df.root 2>/dev/null)
if [ -n "$_df_uid" ]; then
    chown -R "$_df_uid:$_df_uid" "$STAGE" 2>/dev/null
    chmod 771 "$STAGE" 2>/dev/null
fi

write_deploy_done() {
    _wdd_line="DEPLOY_DONE $(date) result=$RESULT enforcing=$(getenforce 2>/dev/null) stage=final"
    if [ "$DONE_FD_OPEN" = "1" ]; then
        printf '%s\n' "$_wdd_line" >&9 2>/dev/null || printf '%s\n' "$_wdd_line" >> "$DONE_MARKER" 2>/dev/null
        exec 9>&-
        DONE_FD_OPEN=0
    else
        printf '%s\n' "$_wdd_line" >> "$DONE_MARKER" 2>/dev/null
    fi
}

write_deploy_done
setenforce 1 2>/dev/null
exit 0
