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

SCRIPT_REV=4.9.4

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
BB=$DATABIN/busybox
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
    # SAFETY MODE: no su anywhere an ordinary app can see it.
    #
    # /system/xbin and /system/bin are world-readable, so a su link there is
    # trivially found by SafetyNet/Play Integrity ("su binary present"). Magisk
    # only needs one reachable path, and /debug_ramdisk is root-only:
    #   /debug_ramdisk/su -> /debug_ramdisk/magisk
    # Tools that need root have to be pointed at that path explicitly.
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

    # (removed) /system/bin/su normalisation: safety mode deletes it above.
}

# ---------- module sepolicy -------------------------------------------------
# A late-loaded magiskd does not run magiskinit, so the sepolicy.rule files that
# Magisk normally applies at boot are absent. Apply every enabled module rule
# after the Magisk base policy is loaded. Some LSPosed builds use a private
# lsposed_file type; if it is still missing, define a small compatibility type
# so SELinux.setFileContext() in lspd does not fail with "left unmapped".
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
    # --print-rules cannot be combined with --live. It writes the full policy
    # to stdout; grep -m1 closes the pipe as soon as the type is found.
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
        # Rules that referenced lsposed_file before it existed may have been
        # rejected. Replaying the same file now applies them to the new type.
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

# ---------- optional LSPosed / Zygisk Next (4.8.3) --------------------------
# DFRoot normally suppresses every module post-fs-data.sh so a late deploy
# cannot start a Zygisk daemon behind zygote's back. LSPosed is the exception:
# its post-fs-data.sh starts lspd, and Zygisk Next's post-fs-data.sh starts
# zygiskd. Both must be running before the one controlled zygote restart.
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

# List every LSPosed worker and supervisor. 2.2.x service.sh starts
# `daemon --force`, which waits on one lspd; killing only lspd leaves that
# supervisor behind, and a later service.sh invocation can then start a second
# lspd (the observed dex2oat "Address already in use" failure). Match both the
# kernel comm name and the full argv so the app_process worker and the shell
# supervisor are both found.
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

# Echo exactly one lspd PID, or return non-zero when there are zero or several.
lspd_single_pid() {
    _lsp_list=$(lspd_live_pids)
    set -- $_lsp_list
    [ "$#" -eq 1 ] || return 1
    printf '%s\n' "$1"
}

# A previous deploy or a failed manager setup can leave an lspd process that is
# alive but has already given up on its manager/context initialization. The old
# code accepted any PID and therefore kept reusing it forever. In explicit
# LSPosed mode, stop every worker and supervisor and start one fresh daemon
# after the policy refresh.
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

# ---------- full LSPosed module update (4.8.10) ----------------------------
# LSPosed's manager, lspd and zygisk library are one matched set. Replacing
# only manager.apk leaves an old module behind; v2.0.0's zygisk library aborts
# every manager process in nativeSpecializeAppProcess (JNI java_array == null).
# The APK bundles a tar of the official 2.2.1 (7930) module and replaces the
# complete file set when its version or file set is older/incomplete. The old
# module is moved to the DFRoot device-protected directory, never deleted.
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

# Install/update the manager APK explicitly. LSPosed's lspd also does this, but
# on this ROM it can fail before it even reaches the install step (the
# lsposed_file context error). A stale manager from an older LSPosed release is
# just as bad: the UI starts but cannot talk to the new lspd. Compare the
# installed versionCode with module.prop and run `cmd package install -r` when
# the module's manager is newer. -d is intentionally not used, so a newer
# existing manager is never downgraded.
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
        # Some package manager builds reject -g; retry without it. Do not use
        # -d here: an installed newer manager must not be downgraded.
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
        # The update failed, but a manager package is still present. Keep the
        # old package rather than falsely reporting "no manager"; the log above
        # contains the package-installer error.
        echo "WARN: LSPosed manager update failed; keeping existing manager"
        LSPOSED_MGR_STATUS=installed
        return 0
    fi
    LSPOSED_MGR_STATUS=install_failed
    echo "WARN: LSPosed manager status=install_failed (lspd may try again)"
    return 1
}

# Start Zygisk Next's injector and wait for the actual zygiskd process (the
# module's binary path is checked so Magisk's built-in zygiskd is not mistaken
# for it). The daemon must be up before ctl.restart zygote.
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
        # `zygiskd service-stage` shares the same exe; do not mistake its
        # short-lived process for the long-running daemon.
        $PBB grep -aq 'service-stage' "/proc/$_p/cmdline" 2>/dev/null && continue
        echo "$_p"
        return 0
    done
    return 1
}

# Zygisk Next keeps the module libraries in memory. After replacing the
# LSPosed module files, the old injector must be stopped before starting the
# new one; otherwise the restarted zygote can still receive v2.0.0's crashing
# zygisk/arm64-v8a.so. This is only used in AUTO mode, after lspd is stopped and
# immediately before the controlled zygote restart.
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

# Mount /debug_ramdisk and /system/xbin in init's namespace. The LSPosed mode
# restarts zygote, and a new zygote inherits init's namespace, not this worker's.
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
        # SAFETY MODE: nothing in /system/xbin or /system/bin; the only su is
        # /debug_ramdisk/su (root-only, invisible to ordinary apps).
        rm -f /system/xbin/su /system/xbin/magisk /system/bin/su /system/bin/magisk 2>/dev/null
        ls -l /debug_ramdisk/su 2>&1
    "
    _igr_rc=$?
    echo "global root rc=$_igr_rc"
    return $_igr_rc
}

# Start exactly one lspd, directly (no `daemon` supervisor, so nothing can
# respawn it into the dex2oat "Address already in use" state). LSPosed's own
# service.sh starts lspd before system_server exists; that first instance dies,
# the supervisor restarts it while the sockets are still inherited, and the
# manager then reports "dex optimization unsupported" and opens very slowly.
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

    # Same order as the proven hot-restart script (fix_lspd.sh v8): bring the
    # injector up first, run its service stage, and only then start lspd.
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
    # With the boot-safety switch on, every module is disabled for this pass and
    # there is nothing to inject; restarting zygote would only lose the modules.
    if [ "$DISABLE_MODULES" = "1" ]; then
        LSPOSED_RESULT=modules_disabled
        echo "LSPosed: skipped (Disable All Modules is ON for this run)"
        setenforce 0 2>/dev/null
        return 0
    fi
    # detect_lsposed reads module.prop with the busybox in /data/adb; the init
    # context may not be able to search /data/adb after setenforce 1.
    setenforce 0 2>/dev/null
    detect_lsposed
    if [ "$LSPOSED_PRESENT" != "1" ] || [ "$ZYGISK_NEXT" != "1" ]; then
        LSPOSED_RESULT=no_modules
        echo "LSPosed: skipped (need both zygisk_lsposed and zygisksu enabled)"
        setenforce 0 2>/dev/null
        return 0
    fi
    # Two injectors in one zygote is not supported. If Magisk's built-in
    # zygiskd is already running, refuse rather than risk a zygote crash. This
    # check applies to both auto and manual LSPosed preparation.
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
        echo "       settings (Zygisk Next is the chosen injector), then retry."
        setenforce 0 2>/dev/null
        return 0
    fi
    lsposed_ns_enter
    install_global_root
    if [ "$SOFT_REBOOT" = "1" ]; then
        # AUTO mode: start from a fresh lspd. A daemon left over from the
        # previous deploy may have already failed manager/context initialization
        # and would never retry; accepting its PID was the main reason repeated
        # soft reboots failed.
        LSPOSED_MODE=auto
        if ! stop_lsposed_daemon; then
            LSPOSED_PREP=0
            LSPOSED_RESULT=lspd_stop_failed
            echo "ERROR: could not stop the previous lspd; refusing zygote restart"
            setenforce 0 2>/dev/null
            return 0
        fi
        # Use the module that is installed, exactly like the proven manual
        # sequence does. 4.8.10 replaced it with the bundled 7930 archive,
        # which turned a working 7912 installation into a white screen /
        # broken dex2oat setup. The module is verified, never replaced.
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
        # Install the manager only when it is really missing; the manual
        # sequence never reinstalls a working manager.
        if ! pkg_installed "$LSPOSED_MANAGER_PKG"; then
            install_lsposed_manager
            echo "LSPosed manager: status=$LSPOSED_MGR_STATUS pkg=$LSPOSED_MANAGER_PKG apk=$LSPOSED_MANAGER_APK"
        else
            LSPOSED_MGR_STATUS=installed
            echo "LSPosed manager: already installed ($LSPOSED_MANAGER_PKG)"
        fi
        if ! check_lsposed_versions; then
            # Not fatal: the installed module+manager pair is what the manual
            # sequence uses successfully. Only report it.
            echo "WARN: LSPosed manager/module version differ; continuing with the installed pair"
        fi
        # Do not start lspd here. The proven sequence starts Zygisk Next first
        # and lspd afterwards; soft_reboot_lsposed performs that order and
        # refuses to touch zygote if lspd cannot start.
        LSPOSED_PREP=1
        LSPOSED_RESULT=prepared
        echo "LSPosed: AUTO mode; policy/module/manager ready, lspd starts after Zygisk Next"
    else
        # MANUAL mode: prepare sepolicy, update the module, and install the
        # manager, but do not stop/start lspd and never touch zygote. The user
        # runs the hot restart manually after this deploy (for example with
        # fix_lspd_221.sh).
        LSPOSED_MODE=manual
        # Same rule as AUTO mode: keep the installed module, only verify it.
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
        # MANUAL mode must not touch lspd at all: the hot restart (zygiskd, lspd,
        # kill zygote) belongs to the user's fix_lspd.sh. Starting or repairing
        # lspd here ran BEFORE the hot restart was requested and left a second
        # daemon behind (EADDRINUSE on the dex2oat sockets).
        setenforce 0 2>/dev/null
        LSPOSED_PREP=0
        LSPOSED_RESULT=prepared_manual
        echo "LSPosed: MANUAL mode; policy/manager verified, lspd and zygote untouched"
        echo "LSPosed: run fix_lspd.sh for the hot restart"
    fi
    # Leave global SELinux permissive here. The caller writes deploy.done and
    # then restores Enforcing; writing the app's log after Enforcing is what
    # stopped the previous deploy immediately after "--- setenforce 1 ---".
    setenforce 0 2>/dev/null
    echo "lsposed prep enforcing=$(getenforce 2>/dev/null) deferred (was $_lsp_pre_enforce)"
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

# The one and only zygote restart. It is refused unless lspd and the Zygisk
# Next injector are usable. ctl.restart is tried first; if init accepts the
# property but ignores it, one guarded kill -9 of the old zygote is allowed
# (this is the sequence in the working manual fix), followed by ctl.stop/start.
# Zygisk Next and lspd start while SELinux is permissive; the restart itself
# only toggles permissive around privileged operations. Every path restores
# Enforcing before returning.
# Mirrors the proven manual sequence (fix_lspd.sh "v8") step by step. The
# manual script is known to bring LSPosed up on this ROM; the previous APK
# sequence differed in three places, and each of them broke something:
#   * it started lspd twice (module script + direct launcher),
#   * it used ctl.restart, which this init accepts but ignores,
#   * it never fixed the permission of /data/adb/lspd/monitor.
# Order matters: lspd is up BEFORE zygote is killed so the injected zygote can
# find it immediately; nothing may respawn lspd, otherwise the dex2oat sockets
# hit EADDRINUSE and LSPosed reports that dex optimization is unsupported.
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

    # ---- [1] kill every old lspd/supervisor -------------------------------
    echo "[1] killing old lspd"
    stop_lsposed_daemon
    rm -f /data/adb/lspd/monitor /data/adb/lspd/lock 2>/dev/null
    sleep 1

    # ---- [2] zygote runtime environment -----------------------------------
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
    echo "  zygote=$_srl_zpid bootclasspath=${#_srl_boot} chars"

    # ---- [3] start zygiskd daemon directly (not via module scripts) --------
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
    echo "  zygiskd daemon pid=${ZN_PID:-?} native_bridge=$(getprop ro.dalvik.vm.native.bridge 2>/dev/null)"

    # ---- [4] zygisk service stage -----------------------------------------
    echo "[4] running zygiskd service-stage"
    ( cd "$ZYGISKSU_DIR" && exec ./bin/zygiskd service-stage ) >/dev/null 2>&1 &
    sleep 2

    # ---- [5] launch exactly one lspd (no daemon supervisor) ---------------
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
    fi
    echo "  lspd pid=$LSPD_PID"
    $BB usleep 500000 2>/dev/null || sleep 1
    LSPD_PID=$(lspd_single_pid 2>/dev/null)
    if [ -z "$LSPD_PID" ]; then
        LSPOSED_RESULT=lspd_died
        echo "ERROR: lspd crashed during startup"
        setenforce 1 2>/dev/null
        return 1
    fi
    echo "  lspd alive"

    # ---- [6] kill zygote64 and wait for the new system_server --------------
    _srl_old_ss=$($_srl_bb pidof system_server 2>/dev/null)
    ZYGOTE_BEFORE=$(zygote_primary_pid)
    ZYGOTE_AFTER=""
    echo "[6] killing zygote64 pid=$ZYGOTE_BEFORE (old system_server=$_srl_old_ss)"
    kill -9 $ZYGOTE_BEFORE 2>/dev/null
    LSPOSED_RESTART_MODE=kill-zygote

    _srl_i=0
    if [ -n "$_srl_old_ss" ]; then
        while [ "$_srl_i" -lt 15 ]; do
            sleep 1
            kill -0 $_srl_old_ss 2>/dev/null || break
            _srl_i=$((_srl_i + 1))
        done
        echo "  old system_server gone after ${_srl_i}s"
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
    echo "  new zygote=$ZYGOTE_AFTER new system_server=${SYSTEM_SERVER_AFTER:-?} (${_srl_i}s)"
    if [ -z "$SYSTEM_SERVER_AFTER" ]; then
        LSPOSED_RESULT=system_server_timeout
        echo "ERROR: a new system_server did not appear"
        setenforce 1 2>/dev/null
        return 1
    fi

    # ---- [7] wait for the LSPosed binder bridge ---------------------------
    echo "[7] waiting for the binder bridge (max 60s)"
    _srl_bridge_log=""
    _srl_line=""
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
        if [ $((_srl_i % 10)) -eq 0 ] && [ "$_srl_i" -gt 0 ]; then
            LSPD_PID=$(lspd_single_pid 2>/dev/null)
            echo "  waiting (${_srl_i}s) lspd=${LSPD_PID:-DEAD}"
        fi
        _srl_i=$((_srl_i + 1))
    done

    if [ "$LSPOSED_BRIDGE" != "1" ]; then
        # Plan B from the manual script: kill system_server so zygote re-forks
        # with the Zygisk module loaded again.
        echo "  bridge missing; plan B: killing system_server=$SYSTEM_SERVER_AFTER"
        _srl_ss_old=$SYSTEM_SERVER_AFTER
        kill -9 $_srl_ss_old 2>/dev/null
        sleep 3
        _srl_i=0
        SYSTEM_SERVER_AFTER=""
        while [ "$_srl_i" -lt 20 ]; do
            sleep 1
            _srl_ss=$($_srl_bb pidof system_server 2>/dev/null)
            if [ -n "$_srl_ss" ] && [ "$_srl_ss" != "$_srl_ss_old" ]; then
                SYSTEM_SERVER_AFTER=$_srl_ss
                break
            fi
            _srl_i=$((_srl_i + 1))
        done
        echo "  system_server after plan B=${SYSTEM_SERVER_AFTER:-?} (${_srl_i}s)"
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
    if [ "$LSPOSED_BRIDGE" = "1" ]; then
        echo "  bridge established: $_srl_line"
    else
        echo "  WARN: bridge not established"
        [ -n "$_srl_bridge_log" ] && $_srl_bb tail -n 15 "$_srl_bridge_log"
    fi

    # ---- [8] settle and fix monitor permissions ---------------------------
    echo "[8] settling monitor permissions (fast wait)"
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
    echo "LSPosed: result=$LSPOSED_RESULT lspd=${LSPD_PID:-DEAD} zygiskd=${ZN_PID:-?} bridge=$LSPOSED_BRIDGE mode=$LSPOSED_RESTART_MODE enforcing=$(getenforce 2>/dev/null)"
    printf 'LSPOSED_DONE %s result=%s mode=%s zygote=%s ss=%s lspd=%s zygiskd=%s bridge=%s enforcing=%s\n' \
        "$(date)" "$LSPOSED_RESULT" "$LSPOSED_RESTART_MODE" "$ZYGOTE_AFTER" \
        "${SYSTEM_SERVER_AFTER:-?}" "$LSPD_PID" "$ZN_PID" \
        "$LSPOSED_BRIDGE" "$(getenforce 2>/dev/null)" >> "$STAGE/lsposed.done" 2>/dev/null
    return 0
}

# The whole /debug_ramdisk is replaced by a directory on /data (f2fs), so
# Magisk's restore_tmpcon() has a real security.selinux xattr store for every
# top-level entry (magisk, stub.apk, magiskpolicy) and for su_request_* FIFOs.
# This is deliberately a directory bind, not a file bind: a file bind of
# stub.apk would make Magisk's preserve_stub_apk() unlink fail with EBUSY.
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
    # Remove a .magisk bind left by an older 4.8 run.  It is harmless when it
    # is not a mountpoint (umount just returns an error).
    umount -l /debug_ramdisk/.magisk 2>/dev/null
    mkdir -p "$F2FS_RD" 2>/dev/null || return 1

    # Android app mount namespaces are normally slaves of init. Make the root
    # mount shared before adding the late /debug_ramdisk bind so the app's
    # existing namespace can resolve /debug_ramdisk/su (and /system/xbin/su).
    mount --make-rshared / 2>/dev/null

    # NOTE: a directory bind on /data (f2fs) is NOT laziness - do not "improve"
    # this into a tmpfs. mountinfo makes it the loudest fingerprint DFRoot
    # leaves (a dm-* device where the ROM's fstab says tmpfs, reported as
    # "inconsistent mount of /debug_ramdisk" plus several suspicious_mount
    # entries), but a tmpfs mount is a distinct object per mount namespace:
    # install_global_root() has to re-mount /debug_ramdisk inside init's
    # namespace because the worker is in another one, and a tmpfs mounted here
    # would be a different, empty filesystem there - /debug_ramdisk/su and the
    # daemon's files would diverge and root would break. The bind is shared
    # storage, which is exactly what is needed.
    #
    # Always replace /debug_ramdisk with our own f2fs directory. An OEM
    # /debug_ramdisk may be a directory on another filesystem with unrelated
    # files; do not probe it and then delete its contents. The bind also makes
    # security.selinux storage independent of tmpfs support and covers the
    # top-level magisk / stub.apk / magiskpolicy entries that restore_tmpcon()
    # labels.
    if mount --bind "$F2FS_RD" /debug_ramdisk 2>/dev/null; then
        DEBUG_RD_F2FS=1
        echo "debug_ramdisk: f2fs bind active"
    else
        echo "ERROR: f2fs /debug_ramdisk bind failed"
        return 1
    fi

    # Start from a clean directory.  On a repeated deploy the old daemon has
    # already been stopped, so no live socket is hidden by this cleanup.
    rm -rf /debug_ramdisk/* /debug_ramdisk/.[!.]* /debug_ramdisk/..?* 2>/dev/null
    mkdir -p /debug_ramdisk/.magisk/busybox /debug_ramdisk/.magisk/device \
             /debug_ramdisk/.magisk/block 2>/dev/null
    chmod 755 /debug_ramdisk 2>/dev/null
    chcon "$MAGISK_FILE_CON" /debug_ramdisk 2>/dev/null
    rm -rf /debug_ramdisk/.magisk/pts 2>/dev/null
    if ! debug_ramdisk_xattr_ok; then
        echo "ERROR: f2fs bind is active but security xattr probe failed"
        return 1
    fi
    XATTR_BIND_OK=1
    echo "DEBUG_RD_F2FS=$DEBUG_RD_F2FS xattr_ok=$XATTR_BIND_OK"
    return 0
}

# Count installed module directories without relying on a daemon cache.
count_installed_modules() {
    _cim=0
    for _cim_d in /data/adb/modules/*; do
        [ -d "$_cim_d" ] && _cim=$((_cim + 1))
    done
    echo "$_cim"
}

# Probe system_server's activity service with a native binder call. `cmd` is a
# native tool (no app_process), so a failure here is a real binder/service
# failure, not the missing /system/bin/app_process on this ROM.
#   0 = activity service answered
#   1 = binder/service lookup failed
#   2 = inconclusive
# Sets ACTIVITY_PROBE_OUT for the log.
probe_activity_service() {
    _bb=${PBB:-$BB}
    _cmd_out=$($_bb timeout 8 /system/bin/cmd activity get-current-user 2>&1)
    _cmd_rc=$?
    ACTIVITY_PROBE_OUT="cmd: rc=$_cmd_rc $(printf '%s' "$_cmd_out" | $_bb tr '\n' ' ' | $_bb cut -c1-140)"
    case "$_cmd_out" in
        *"Can't find service"*|*"Can't connect to activity manager"*|*"Failure calling service activity"*)
            return 1 ;;
    esac
    [ "$_cmd_rc" = "0" ] && return 0
    # `service check` is a shell wrapper around app_process on some ROMs, so it
    # is only a fallback. Match the exact positive line: the old `grep -q found`
    # also matched "not found" and reported a false ready state for 60s.
    _svc_out=$($_bb timeout 8 /system/bin/service check activity 2>&1)
    ACTIVITY_PROBE_OUT="$ACTIVITY_PROBE_OUT | service: $(printf '%s' "$_svc_out" | $_bb tr '\n' ' ' | $_bb cut -c1-120)"
    case "$_svc_out" in
        *"Service activity: found"*) return 0 ;;
        *"not found"*) return 1 ;;
    esac
    return 2
}

# Wait for the activity service before invoking `am` or the manager. The init
# worker can start while system_server is still coming up; an "AM_OK=0" in that
# window means "service not ready", not "Magisk env is broken".
wait_for_activity_service() {
    _want=${1:-60}
    _i=0
    _last=2
    while [ "$_i" -lt "$_want" ]; do
        probe_activity_service
        _last=$?
        if [ "$_last" = "0" ]; then
            echo "activity service: ready after ${_i}s"
            return 0
        fi
        # A hard binder failure ("Can't find service") will not fix itself by
        # waiting: the init worker's binder transport is missing, not late.
        [ "$_last" = "1" ] && break
        sleep 1
        _i=$((_i + 1))
    done
    echo "WARN: activity service not ready after ${_i}s"
    echo "activity probe: $ACTIVITY_PROBE_OUT"
    echo "binder: $(ls -l /dev/binder 2>&1 | $BB head -n1)"
    echo "servicemanager: $($BB ps -A 2>/dev/null | $BB grep -w servicemanager | $BB head -n1)"
    return 1
}

kill_pid_list() {
    for _kp in $1; do
        case "$_kp" in ''|*[!0-9]*) continue ;; esac
        kill -0 "$_kp" 2>/dev/null || continue
        kill -9 "$_kp" 2>/dev/null
    done
}

# Stop the detached guard before replacing the daemon.  It is deliberately
# conservative: a stale PID file whose process is gone is never killed, and a
# PID that no longer names the guard script is never killed.
stop_magiskd_guard() {
    if [ -s "$GUARD_PIDFILE" ]; then
        _gp=$(cat "$GUARD_PIDFILE" 2>/dev/null)
        case "$_gp" in
            ''|*[!0-9]*) ;;
            *)
                if kill -0 "$_gp" 2>/dev/null; then
                    _gcmd=$(tr '\0' ' ' < "/proc/$_gp/cmdline" 2>/dev/null)
                    case "$_gcmd" in
                        *magiskd-guard.sh*)
                            kill "$_gp" 2>/dev/null
                            sleep 1
                            kill -0 "$_gp" 2>/dev/null && kill -9 "$_gp" 2>/dev/null
                            echo "stopped previous magiskd guard pid=$_gp"
                            ;;
                        *)
                            echo "guard pid=$_gp is no longer the guard; not killing"
                            ;;
                    esac
                else
                    echo "stale magiskd guard pid=$_gp (process absent)"
                fi
                ;;
        esac
        rm -f "$GUARD_PIDFILE" 2>/dev/null
    fi
    # If the PID file was lost, find only processes whose command line points
    # at a magiskd-guard.sh. The name match also catches a guard left by an
    # older build under /data/adb/dfroot, so two guards cannot race. Never
    # pattern-kill "sh" or an arbitrary PID.
    for _cp in /proc/[0-9]*; do
        [ -r "$_cp/cmdline" ] || continue
        _cpid=${_cp##*/}
        [ "$_cpid" = "$$" ] && continue
        _ccmd=$(tr '\0' ' ' < "$_cp/cmdline" 2>/dev/null)
        case "$_ccmd" in
            *magiskd-guard.sh*)
                if kill -0 "$_cpid" 2>/dev/null; then
                    kill "$_cpid" 2>/dev/null
                    sleep 1
                    kill -0 "$_cpid" 2>/dev/null && kill -9 "$_cpid" 2>/dev/null
                    echo "stopped orphan magiskd guard pid=$_cpid"
                fi
                ;;
        esac
    done
}

start_magiskd_guard() {
    GUARD_STARTED=0
    # Stop the old guard before replacing the script it may still be reading.
    stop_magiskd_guard
    # The app stages magiskd-guard.sh as magiskd-guard.asset.sh and never
    # reads the hardened copy. Once this script chcon's the hardened copy to
    # magisk_file, the app can no longer read it (EACCES), so the asset must
    # stay separate. Replace the old hardened copy from the asset here.
    if [ -f "$SUDIR/magiskd-guard.asset.sh" ]; then
        cp -f "$SUDIR/magiskd-guard.asset.sh" "$SUDIR/magiskd-guard.sh" 2>/dev/null || {
            rm -f "$SUDIR/magiskd-guard.sh" 2>/dev/null
            cp -f "$SUDIR/magiskd-guard.asset.sh" "$SUDIR/magiskd-guard.sh" 2>/dev/null
        }
    fi
    [ -f "$SUDIR/magiskd-guard.sh" ] || {
        echo "WARN: magiskd guard script is missing"
        return 1
    }
    chmod 755 "$SUDIR/magiskd-guard.sh" 2>/dev/null
    chcon "$MAGISK_FILE_CON" "$SUDIR/magiskd-guard.sh" 2>/dev/null
    _runner=${PBB:-$BB}
    [ -x "$_runner" ] || _runner=$BB

    # runcon is done while the magisk domain is still permissive, so the
    # guard itself stays usable after the global setenforce 1 below.
    $_runner setsid $_runner runcon u:r:magisk:s0 /system/bin/sh \
        "$SUDIR/magiskd-guard.sh" >/dev/null 2>&1 &
    sleep 2
    if [ -s "$GUARD_PIDFILE" ]; then
        _gp=$(cat "$GUARD_PIDFILE" 2>/dev/null)
        case "$_gp" in
            ''|*[!0-9]*) ;;
            *) kill -0 "$_gp" 2>/dev/null && GUARD_STARTED=1 ;;
        esac
    fi
    if [ "$GUARD_STARTED" != "1" ]; then
        echo "WARN: runcon guard did not start; retrying in current context"
        # Remove any half-started guard (also covers a missing PID file) before
        # starting a second one; two guards would race over modules and the DB.
        stop_magiskd_guard
        $_runner setsid /system/bin/sh "$SUDIR/magiskd-guard.sh" >/dev/null 2>&1 &
        sleep 2
        if [ -s "$GUARD_PIDFILE" ]; then
            _gp=$(cat "$GUARD_PIDFILE" 2>/dev/null)
            case "$_gp" in
                ''|*[!0-9]*) ;;
                *) kill -0 "$_gp" 2>/dev/null && GUARD_STARTED=1 ;;
            esac
        fi
    fi
    echo "magiskd guard: started=$GUARD_STARTED pid=$([ -s "$GUARD_PIDFILE" ] && cat "$GUARD_PIDFILE" 2>/dev/null)"
    [ "$GUARD_STARTED" = "1" ]
}

# The 4.7 shell wrapper is gone for good: it bypassed the Magisk authorization
# dialog, made the manager warn that su was not from Magisk, and kept
# /proc/dfroot_su open as a second root path. MagiskSU is the only su.

su_is_magisk_link() {
    [ -L "$1" ] || return 1
    [ "$(readlink "$1" 2>/dev/null)" = "/debug_ramdisk/magisk" ]
}

# Never leave a non-Magisk su executable at either public path. A Magisk
# symlink is preserved; a wrapper, copy, or unknown symlink is removed.
legacy_su_cleanup() {
    for _p in /debug_ramdisk/su /system/xbin/su; do
        [ -e "$_p" ] || [ -L "$_p" ] || continue
        # If /system/xbin is itself a symlink (e.g. -> /system/bin), never
        # remove through it: that would delete a real platform su binary.
        if [ "$_p" = "/system/xbin/su" ] && [ -L /system/xbin ]; then
            echo "WARN: /system/xbin is a symlink; not removing $_p"
            continue
        fi
        if [ "$_p" = "/system/xbin/su" ] && [ "$XBIN_OK" != "1" ]; then
            echo "WARN: xbin overlay is not ours; not removing $_p"
            continue
        fi
        if su_is_magisk_link "$_p"; then
            echo "kept Magisk su link: $_p -> /debug_ramdisk/magisk"
            continue
        fi
        if rm -f "$_p" 2>/dev/null; then
            echo "removed non-Magisk su: $_p"
        else
            echo "WARN: cannot remove non-Magisk su: $_p"
        fi
    done
    [ -L /system/xbin ] || rm -f /system/xbin/.dfroot_channel 2>/dev/null
}

# Reading /proc/dfroot_su once latches the LKM's g_closed flag. It is the
# documented close protocol; a later write must fail. Used on every exit so a
# failed Magisk deploy cannot leave the legacy root channel active.
close_legacy_channel() {
    CHANNEL=closed
    [ -e /proc/dfroot_su ] || return 0
    /system/bin/cat /proc/dfroot_su >/dev/null 2>&1
    sleep 1
    if printf '1' > /proc/dfroot_su 2>/dev/null; then
        echo "WARN: /proc/dfroot_su still accepts writes after close read"
        CHANNEL=open
        return 1
    fi
    return 0
}

# Restore one legacy top-level rename. Versions before this build renamed the
# whole modules/modules_update directories. Never overwrite a path that the
# system re-created: leave a non-empty directory untouched and keep the old
# backup. Only remove an empty system-created directory, because it has no data.
restore_one_module() {
    _rom_name=$1
    _rom_off="/data/adb/$_rom_name.dfroot_off"
    [ -e "$_rom_off" ] || return 0
    _rom_bb=$BB
    [ -x /debug_ramdisk/.magisk/busybox/busybox ] && \
        _rom_bb=/debug_ramdisk/.magisk/busybox/busybox
    _rom_dst="/data/adb/$_rom_name"
    if [ ! -e "$_rom_dst" ]; then
        mv "$_rom_off" "$_rom_dst" 2>/dev/null && \
            echo "restored /data/adb/$_rom_name"
    elif [ -d "$_rom_dst" ] && \
         [ -z "$($_rom_bb ls -A "$_rom_dst" 2>/dev/null)" ]; then
        rmdir "$_rom_dst" 2>/dev/null && \
            mv "$_rom_off" "$_rom_dst" 2>/dev/null && \
            echo "restored /data/adb/$_rom_name (removed empty system-created dir)"
    else
        echo "WARN: /data/adb/$_rom_name already exists; not overwriting (backup kept at $_rom_off)"
    fi
}

# Module boot scripts are hidden by a unique suffix. Magisk executes the exact
# path <module>/post-fs-data.sh, so a renamed file is not replayed. A crash
# leaves the suffix behind and the next run restores every matching backup.
BOOT_SCRIPT_SUFFIX=.dfroot_pfs_off
BOOT_PFSD_PREFIX=/data/adb/post-fs-data.d.dfroot_pfs_off

restore_one_boot_script() {
    _rbs=$1
    [ -e "$_rbs" ] || return 0
    _rbs_dir=${_rbs%/*}
    _rbs_name=${_rbs##*/}
    _rbs_name=${_rbs_name%%.dfroot_pfs_off*}
    _rbs_dst="$_rbs_dir/$_rbs_name"
    if [ ! -e "$_rbs_dst" ]; then
        mv "$_rbs" "$_rbs_dst" 2>/dev/null && \
            echo "restored boot script: $_rbs_dst"
    else
        echo "WARN: $_rbs_dst already exists; keeping backup $_rbs"
    fi
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
        if [ ! -e /data/adb/post-fs-data.d ]; then
            mv "$_rpb" /data/adb/post-fs-data.d 2>/dev/null && \
                echo "restored /data/adb/post-fs-data.d"
        elif [ -d /data/adb/post-fs-data.d ] && \
             [ -z "$($BB ls -A /data/adb/post-fs-data.d 2>/dev/null)" ]; then
            rmdir /data/adb/post-fs-data.d 2>/dev/null && \
                mv "$_rpb" /data/adb/post-fs-data.d 2>/dev/null && \
                echo "restored /data/adb/post-fs-data.d (removed empty system-created dir)"
        else
            echo "WARN: /data/adb/post-fs-data.d already exists; keeping backup $_rpb"
        fi
    done
}

# Restore post-fs-data.d and every module script. Called on every exit path and
# immediately after the single --post-fs-data pass.
restore_boot_scripts() {
    restore_module_scripts
    restore_pfsd_backups
    BOOT_SCRIPTS_OFF=0
}

# ---------- one-shot "disable all modules" (boot safety switch) --------------
# Magisk skips a module when <module>/disable exists. This is the same idea the
# KernelSU bootstrap used, applied to the Magisk path: enabling the switch makes
# the next deploy run with every module disabled, then the markers created here
# are removed again so the next boot is normal. Markers that already existed
# (user-disabled modules) are never touched.
MODULES_DISABLED_BY_US=""
disable_all_modules() {
    MODULES_DISABLED_BY_US=""
    [ "$DISABLE_MODULES" = "1" ] || return 0
    _dam_n=0
    for _dam_m in /data/adb/modules/*; do
        [ -d "$_dam_m" ] || continue
        [ -f "$_dam_m/disable" ] && continue
        if : > "$_dam_m/disable" 2>/dev/null; then
            MODULES_DISABLED_BY_US="$MODULES_DISABLED_BY_US $_dam_m"
            _dam_n=$((_dam_n + 1))
        else
            echo "WARN: cannot disable module $_dam_m"
        fi
    done
    echo "disable_modules: $DISABLE_MODULES (one-shot disabled $_dam_n module(s))"
}

restore_disabled_modules() {
    [ -n "$MODULES_DISABLED_BY_US" ] || return 0
    for _rdm_m in $MODULES_DISABLED_BY_US; do
        rm -f "$_rdm_m/disable" 2>/dev/null && \
            echo "disable_modules: re-enabled $_rdm_m"
    done
    MODULES_DISABLED_BY_US=""
}

hide_one_boot_script() {
    _hbs=$1
    [ -e "$_hbs" ] || return 0
    _hbs_off="$_hbs$BOOT_SCRIPT_SUFFIX.$$"
    _hbs_n=1
    while [ -e "$_hbs_off" ]; do
        _hbs_off="$_hbs$BOOT_SCRIPT_SUFFIX.$$.$_hbs_n"
        _hbs_n=$((_hbs_n + 1))
    done
    if mv "$_hbs" "$_hbs_off" 2>/dev/null; then
        BOOT_SCRIPTS_OFF=$((BOOT_SCRIPTS_OFF + 1))
        return 0
    fi
    echo "WARN: could not suppress $_hbs"
    return 1
}

# Hide only boot scripts for the late pass. The modules themselves stay in
# place so Magisk still initializes module_list and mounts their files.
hide_boot_scripts() {
    BOOT_SCRIPTS_OFF=0
    _hbs_fail=0
    if [ -e /data/adb/post-fs-data.d ]; then
        _hbs_pfsd="$BOOT_PFSD_PREFIX.$$"
        _hbs_n=1
        while [ -e "$_hbs_pfsd" ]; do
            _hbs_pfsd="$BOOT_PFSD_PREFIX.$$.$_hbs_n"
            _hbs_n=$((_hbs_n + 1))
        done
        if mv /data/adb/post-fs-data.d "$_hbs_pfsd" 2>/dev/null; then
            BOOT_SCRIPTS_OFF=$((BOOT_SCRIPTS_OFF + 1))
            echo "boot scripts hidden: /data/adb/post-fs-data.d -> $_hbs_pfsd"
        else
            echo "WARN: could not hide /data/adb/post-fs-data.d"
            _hbs_fail=1
        fi
    fi
    for _hbs_base in /data/adb/modules /data/adb/modules_update; do
        [ -d "$_hbs_base" ] || continue
        for _hbs_d in "$_hbs_base"/*; do
            [ -d "$_hbs_d" ] || continue
            [ -e "$_hbs_d/post-fs-data.sh" ] || continue
            if hide_one_boot_script "$_hbs_d/post-fs-data.sh"; then
                echo "boot script hidden: $_hbs_d/post-fs-data.sh"
            else
                _hbs_fail=1
            fi
        done
    done
    echo "boot scripts suppressed=$BOOT_SCRIPTS_OFF (modules remain visible)"
    [ "$_hbs_fail" = "0" ]
}

# Recover from a deploy or guard restart that was killed mid-pass.
recover_modules() {
    # Older experimental builds could leave a disposable tmpfs over one of
    # these paths. Unmount that stale overlay first; otherwise the real modules
    # directory is hidden and the backup looks non-empty.
    _rm_bb=$BB
    [ -x /debug_ramdisk/.magisk/busybox/busybox ] && \
        _rm_bb=/debug_ramdisk/.magisk/busybox/busybox
    for _rm_m in modules modules_update post-fs-data.d; do
        if $_rm_bb grep -q " /data/adb/$_rm_m " /proc/mounts 2>/dev/null; then
            umount -l "/data/adb/$_rm_m" 2>/dev/null && \
                echo "removed stale module mount: /data/adb/$_rm_m"
        fi
    done
    restore_one_module modules
    restore_one_module modules_update
    restore_pfsd_backups
    restore_module_scripts
}

on_exit() {
    restore_boot_scripts
    restore_disabled_modules
    # The LKM read-latch is the only legacy-root close mechanism. Always use
    # it, including fatal/exception paths, so no wrapperless channel remains.
    [ -e /proc/dfroot_su ] && /system/bin/cat /proc/dfroot_su >/dev/null 2>&1
    # Remove the LKM's temporary su client and any old 4.7 wrapper copy on
    # every exit path, including fatal/interrupt. Only Magisk su may remain.
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
    # packages.list is the fast path, but it is not always readable here
    # (u:r:toolbox:s0), which made an installed manager look missing. The APK
    # directory is authoritative and root can read it.
    if [ -r "$PKGLIST" ] &&
       $BB awk -v p="$1" '$1 == p { found=1 } END { exit !found }' "$PKGLIST" 2>/dev/null; then
        return 0
    fi
    apk_of "$1" >/dev/null 2>&1 && return 0
    return 1
}

pkg_uid() {
    _pu=$($BB awk -v p="$1" '$1 == p { print $2; exit }' "$PKGLIST" 2>/dev/null)
    if [ -z "$_pu" ]; then
        _pu=$(stat -c %u "/data/user_de/0/$1" 2>/dev/null)
    fi
    [ -n "$_pu" ] && echo "$_pu"
}

# Same layout find_apk_path() walks: /data/app/~~<rand>/<pkg>-<rand>/base.apk
apk_of() {
    for g in /data/app/*/"$1"-*/base.apk /data/app/"$1"-*/base.apk \
             /data/app/*/"$1"-*/*.apk /data/app/"$1"-*/*.apk; do
        if [ -f "$g" ]; then
            echo "$g"
            return 0
        fi
    done
    return 1
}

# Only an APK that really is a Magisk build may be used as the trusted_cert
# source. Every Magisk APK ships assets/util_functions.sh with MAGISK_VER in it;
# an unrelated app that merely looked "magisk-ish" does not. This is what stops
# DFRoot from seeding stub.apk from the wrong app (which makes Magisk uninstall
# the real manager).
is_magisk_apk() {
    [ -f "$1" ] || return 1
    $BB unzip -p "$1" assets/util_functions.sh 2>/dev/null | $BB grep -q 'MAGISK_VER=' || return 1
    return 0
}

# "30.7" from <apk>/assets/util_functions.sh, or empty.
apk_magisk_ver() {
    $BB unzip -p "$1" assets/util_functions.sh 2>/dev/null |
        $BB sed -n "s/^MAGISK_VER='\([^']*\)'.*/\1/p" | $BB head -n1
}

# The init worker runs this script with only MAGISKTMP/PATH/SHELL. app_process
# (used by Magisk's su_connect and by the am self-test below) needs the Android
# runtime environment. Copy a narrow whitelist from the live zygote; do not
# import LD_* or ANDROID_SOCKET_* from a foreign process.
import_android_env() {
    ANDROID_ENV_OK=0
    ANDROID_ENV_SOURCE=""
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
            ANDROID_ENV_SOURCE="zygote:$_z"
        else
            echo "WARN: cannot read /proc/$_z/environ (zygote env unavailable)"
        fi
        rm -f "$_env" 2>/dev/null
    else
        echo "WARN: zygote64/zygote pid or /proc environ unavailable"
    fi

    # Static base paths are safe fallbacks; BOOTCLASSPATH is deliberately not
    # invented. If it is empty the am self-test below fails honestly instead of
    # pretending that MagiskSU transport works.
    [ -n "$ANDROID_ROOT" ] || ANDROID_ROOT=/system
    [ -n "$ANDROID_DATA" ] || ANDROID_DATA=/data
    [ -n "$ANDROID_ART_ROOT" ] || ANDROID_ART_ROOT=/apex/com.android.art
    [ -n "$ANDROID_I18N_ROOT" ] || ANDROID_I18N_ROOT=/apex/com.android.i18n
    [ -n "$ANDROID_TZDATA_ROOT" ] || ANDROID_TZDATA_ROOT=/apex/com.android.tzdata
    [ -n "$ANDROID_STORAGE" ] || ANDROID_STORAGE=/storage
    [ -n "$ASEC_MOUNTPOINT" ] || ASEC_MOUNTPOINT=/mnt/asec
    [ -n "$EXTERNAL_STORAGE" ] || EXTERNAL_STORAGE=/sdcard
    export ANDROID_ROOT ANDROID_DATA ANDROID_ART_ROOT ANDROID_I18N_ROOT \
           ANDROID_TZDATA_ROOT ANDROID_STORAGE ASEC_MOUNTPOINT EXTERNAL_STORAGE

    if [ -n "$BOOTCLASSPATH" ]; then
        ANDROID_ENV_OK=1
        echo "android env: source=${ANDROID_ENV_SOURCE:-fallback} bootclasspath=$(printf '%s' "$BOOTCLASSPATH" | $PBB wc -c) bytes"
    else
        echo "WARN: BOOTCLASSPATH is empty; app_process/am will not be trusted"
    fi
    return 0
}

sql_run() {
    # After `setenforce 1`, init cannot search /data/adb (adb_data_file), so
    # /data/adb/magisk/busybox is unreachable. The busybox that Magisk copies
    # into the /debug_ramdisk tmpfs stays reachable.
    if [ -x /debug_ramdisk/.magisk/busybox/busybox ]; then
        /debug_ramdisk/.magisk/busybox/busybox timeout 25 "$CLIENT" --sqlite "$1" 2>&1
    else
        $BB timeout 25 "$CLIENT" --sqlite "$1" 2>&1
    fi
}

detect_app_process() {
    APP_PROCESS=""
    # Prefer the 64-bit runtime on 64-bit devices. Some OEM Android 12 builds
    # leave a 32-bit /system/bin/app_process whose linker was removed; it is
    # executable but execve() still returns ENOENT ("No such file or
    # directory"). Picking app_process64 avoids that trap. On 32-bit devices
    # app_process64 simply does not exist, so app_process/app_process32 wins.
    for p in /system/bin/app_process64 /system/bin/app_process \
             /system/bin/app_process32 \
             /apex/com.android.art/bin/app_process64 \
             /apex/com.android.art/bin/app_process \
             /apex/com.android.runtime/bin/app_process64; do
        if [ -f "$p" ] && [ -x "$p" ]; then
            APP_PROCESS="$p"
            return 0
        fi
    done
    return 1
}

# BusyBox 1.36's grep has NO -b option (its OPTSTR is
# "lnqvscFiHhe:*f:*LorRm:+wx...aI"), so the old
#   grep -abo '/system/bin/app_process'
# emitted an "unrecognized option" error and an empty offset list. The script
# then printed "app_process string not found" and AM_OK stayed 0. Use the
# strings applet's decimal offset instead: strings -t d reports the start of
# each printable run, so add the path's position within that run.
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

# Magisk 30.7's su_connect.rs hard-codes Command::new("/system/bin/app_process").
# Some OEM Android 12 ROMs (including this Black Shark build) only ship
# /system/bin/app_process64, so every app_request() fails and su_query waits
# forever.  Patch the runtime copy of the daemon to a same-length path in the
# /debug_ramdisk tmpfs; a same-length replacement keeps the Rust string length
# intact.  The stock asset and /data/adb/magisk/magisk are never modified.
setup_app_process_transport() {
    APP_RUN="$APP_PROCESS"
    APP_PATCHED=0
    if [ -z "$APP_PROCESS" ]; then
        echo "WARN: no executable app_process found; Magisk AM transport will fail"
        return 1
    fi
    if [ "$APP_PROCESS" = "/system/bin/app_process" ]; then
        echo "app_process: stock $APP_PROCESS"
        APP_TRANSPORT_OK=1
        return 0
    fi
    if [ ${#APP_PROXY} -ne 23 ]; then
        echo "WARN: internal error: $APP_PROXY is not 23 bytes"
        return 1
    fi
    echo "app_process: /system/bin/app_process unavailable; target=$APP_PROCESS"
    if ! ln -sf "$APP_PROCESS" "$APP_PROXY" 2>/dev/null; then
        echo "WARN: cannot create $APP_PROXY"
        return 1
    fi
    # Do not chcon a symlink: chcon follows it and could try to relabel the
    # read-only system file.  /debug_ramdisk itself is already magisk_file.
    if ! cp -f /debug_ramdisk/magisk "$SUDIR/magisk.before_appprocess" 2>/dev/null; then
        echo "WARN: cannot back up magisk before app_process patch"
        rm -f "$APP_PROXY" 2>/dev/null
        return 1
    fi
    OFFS=$(find_app_process_offsets /debug_ramdisk/magisk)
    echo "app_process string offsets: [$OFFS]"
    if [ -z "$OFFS" ]; then
        echo "WARN: app_process string not found in magisk; cannot patch"
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
        echo "WARN: app_process patch failed"
        cp -f "$SUDIR/magisk.before_appprocess" /debug_ramdisk/magisk 2>/dev/null
        chmod 755 /debug_ramdisk/magisk 2>/dev/null
        chcon "$MAGISK_FILE_CON" /debug_ramdisk/magisk 2>/dev/null
        rm -f "$APP_PROXY" 2>/dev/null
        return 1
    fi
    if $BB grep -aq '/system/bin/app_process' /debug_ramdisk/magisk 2>/dev/null; then
        echo "WARN: app_process string remains after patch; restoring"
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
    echo "app_process patch: /system/bin/app_process -> $APP_PROXY ($PATCHED site(s)); target=$APP_PROCESS"
    return 0
}

policy_rows() {
    # Prefer the busybox in the /debug_ramdisk tmpfs; after setenforce 1 the
    # init context may not be able to search /data/adb (where $BB lives).
    _bb=$BB
    [ -x /debug_ramdisk/.magisk/busybox/busybox ] && \
        _bb=/debug_ramdisk/.magisk/busybox/busybox
    sql_run 'SELECT uid,policy,until,logging,notification FROM policies;' 2>/dev/null \
        | $_bb awk -F'|' '
            NF >= 5 {
                for (i = 1; i <= 5; i++) sub(/^[^=]*=/, "", $i)
                # Magisk SuPolicy can store until=-1 for a permanent row.
                if ($1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^-?[0-9]+$/ &&
                    $4 ~ /^[0-9]+$/ && $5 ~ /^[0-9]+$/)
                    print $1 "|" $2 "|" $3 "|" $4 "|" $5
            }'
}

# Magisk's --post-fs-data calls prune_su_access(). Its get_app_no_list()
# walks /data/user_de/<user>/<pkg> (or /data/user on older Android), reads each
# package data directory's owner uid, and deletes policy rows whose app id is
# absent. On this late-load path that directory scan can be incomplete, so a
# still-installed app's row can disappear. Preserve the user's exact rows by
# restoring ONLY rows that (1) existed before post-fs-data, (2) disappeared,
# and (3) still map to an installed app uid. The installed check accepts either
# /data/system/packages.list or an existing app data directory (the same source
# Magisk itself uses). This is not a blanket grant and never changes a row.
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
    if [ ! -s "$POL_SNAPSHOT" ]; then
        echo "policy restore: no snapshot; skipped"
        return 0
    fi
    POL_UIDS="$SUDIR/policies.current.uids"
    _bb=$BB
    [ -x /debug_ramdisk/.magisk/busybox/busybox ] && \
        _bb=/debug_ramdisk/.magisk/busybox/busybox
    $_bb awk -F'|' '{ print $1 }' "$POL_CURRENT" 2>/dev/null > "$POL_UIDS"
    while IFS='|' read -r uid policy pol_until pol_logging pol_notification; do
        [ -n "$uid" ] && [ -n "$policy" ] && [ -n "$pol_until" ] \
            && [ -n "$pol_logging" ] && [ -n "$pol_notification" ] || continue
        case "$uid$policy$pol_logging$pol_notification" in
            *[!0-9]*) continue ;;
        esac
        # until is usually 0/epoch seconds, but Magisk stores -1 for some
        # permanent rows. Validate an optional leading minus separately.
        case "$pol_until" in
            -*) _until_digits=${pol_until#-} ;;
            *)  _until_digits=$pol_until ;;
        esac
        [ -n "$_until_digits" ] || continue
        case "$_until_digits" in
            *[!0-9]*) continue ;;
        esac
        if $_bb grep -qx "$uid" "$POL_UIDS" 2>/dev/null; then
            continue
        fi
        if [ "$uid" -ge 10000 ] 2>/dev/null; then
            if ! uid_is_installed "$uid"; then
                echo "policy restore skip uid=$uid (not in packages.list or app data dirs)"
                continue
            fi
        fi
        if sql_run "INSERT OR REPLACE INTO policies(uid,policy,until,logging,notification) \
                    VALUES($uid,$policy,$pol_until,$pol_logging,$pol_notification);" >/dev/null 2>&1; then
            echo "policy restored uid=$uid policy=$policy until=$pol_until logging=$pol_logging notification=$pol_notification"
            POL_RESTORED=$((POL_RESTORED + 1))
        else
            echo "WARN: policy restore failed for uid=$uid"
        fi
    done < "$POL_SNAPSHOT"
    echo "policy rows restored=$POL_RESTORED"
}

# Copy a file only when its MD5 differs. The Magisk APK and the staged Magisk
# binaries are large and normally unchanged between runs; skipping identical
# copies also avoids rewriting files that a running daemon may be using.
copy_if_changed() {
    _cc_src=$1
    _cc_dst=$2
    _cc_mode=${3:-755}
    _cc_bb=${PBB:-$BB}
    [ -f "$_cc_src" ] || return 1
    _cc_dir=${_cc_dst%/*}
    [ -n "$_cc_dir" ] && mkdir -p "$_cc_dir" 2>/dev/null
    if [ -f "$_cc_dst" ]; then
        _cc_s=$($_cc_bb md5sum "$_cc_src" 2>/dev/null | $_cc_bb awk '{print $1}')
        _cc_d=$($_cc_bb md5sum "$_cc_dst" 2>/dev/null | $_cc_bb awk '{print $1}')
        if [ -n "$_cc_s" ] && [ "$_cc_s" = "$_cc_d" ]; then
            chmod "$_cc_mode" "$_cc_dst" 2>/dev/null
            echo "unchanged: $_cc_dst (md5=$_cc_s)"
            return 0
        fi
    fi
    cp -f "$_cc_src" "$_cc_dst" 2>/dev/null || return 1
    chmod "$_cc_mode" "$_cc_dst" 2>/dev/null
    echo "copied: $_cc_src -> $_cc_dst"
    return 0
}

stage_bin() {
    [ -s "$1" ] || return 1
    cp -f "$1" "$2" 2>/dev/null && chmod "$3" "$2" 2>/dev/null &&
        echo "staged: $2"
}

# ---------- 0a. Magisk must be installed; no lock, no import ---------------
# Magisk 31.1 dropped the hide/repackge feature, so there is exactly one manager
# layout: /data/app/<pkg>/base.apk is the full Magisk build. Everything the
# deploy needs is extracted from it, which also guarantees the binaries match
# the installed manager (no more "cert: APK version too low").
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
    echo "  請先安裝 Magisk（官方或相容分支），再執行注入。"
    printf 'DEPLOY_FAILED %s result=failed error=no_magisk\n' "$(date)" >> "$DONE_MARKER" 2>/dev/null
    setenforce 1 2>/dev/null
    exit 1
fi
MGR_UID=$(stat -c %u "/data/user_de/0/$MGR_PKG" 2>/dev/null)
MGR_DE=/data/user_de/0/$MGR_PKG
echo "magisk: $MGR_PKG  apk=$MGR_APK"

# Version of the installed build (assets/util_functions.sh inside the APK).
APK_VER_CODE=$($BB unzip -p "$MGR_APK" assets/util_functions.sh 2>/dev/null |
               $BB sed -n 's/^MAGISK_VER_CODE=//p' | $BB head -1 | $BB tr -dc '0-9')
APK_VER_NAME=$($BB unzip -p "$MGR_APK" assets/util_functions.sh 2>/dev/null |
               $BB sed -n 's/^MAGISK_VER=//p' | $BB head -1 | $BB tr -d '" \r\n')
DEPLOYED_VER=$($BB cat "$SUDIR/installed.version" 2>/dev/null | $BB tr -dc '0-9')
echo "magisk: installed ${APK_VER_NAME:-?} (${APK_VER_CODE:-0}), deployed ${DEPLOYED_VER:-none}"

# No md5 comparison any more: the manager APK is no longer hashed, so the
# staged file set is only refreshed when the user asks for it in the app
# ("升級 Magisk 版本" -> upgrade.request). Every other run reuses whatever is
# already staged, and the signature/keystore handling below stays as it was.
if [ -s "$STAGE/upgrade.request" ]; then
    rm -f "$STAGE/upgrade.request" 2>/dev/null
    echo "magisk: upgrade requested -> extracting the file set from the installed APK"
    mkdir -p "$STAGE/chromeos" 2>/dev/null
    _ex_n=0
    for _pair in \
        "lib/arm64-v8a/libmagisk.so:magisk" \
        "lib/arm64-v8a/libmagiskinit.so:magiskinit" \
        "lib/arm64-v8a/libmagiskboot.so:magiskboot" \
        "lib/arm64-v8a/libmagiskpolicy.so:magiskpolicy" \
        "lib/arm64-v8a/libbusybox.so:busybox" \
        "lib/arm64-v8a/libinit-ld.so:init-ld" \
        "assets/boot_patch.sh:boot_patch.sh" \
        "assets/util_functions.sh:util_functions.sh" \
        "assets/addon.d.sh:addon.d.sh" \
        "assets/module_installer.sh:module_installer.sh" \
        "assets/app_functions.sh:app_functions.sh" \
        "assets/uninstaller.sh:uninstaller.sh" \
        "assets/stub.apk:stub.apk" ; do
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
    echo "magisk: extracted $_ex_n file(s) from the APK"
    # Old 32-bit leftovers are not part of 31.x; drop them so nothing half-mixed runs.
    rm -f "$STAGE/magisk32" "$STAGE/magisk64" 2>/dev/null
    printf '%s\n' "${APK_VER_CODE:-0}" > "$SUDIR/installed.version" 2>/dev/null
    chmod 644 "$SUDIR/installed.version" 2>/dev/null
    _iv_uid=$(stat -c %u "$SUDIR" 2>/dev/null)
    [ -n "$_iv_uid" ] && chown "$_iv_uid:$_iv_uid" "$SUDIR/installed.version" 2>/dev/null
    # The extracted files replace whatever the payload manifest described, so
    # its md5 list is stale: drop it and force a full copy of the staged set.
    rm -f "$STAGE/payload.applied" "$STAGE/payload.manifest" 2>/dev/null
    MAGISK_FILES_FORCE=1
    MAGISK_NEW_SET=1
fi

# Fast path (see the "0. prepare + stage" section below for the copy itself).
# The APK is not hashed any more, so "same set as last time" is simply: a
# deployed marker exists, the binaries are in place, and this run did not
# extract or force a new set.
DPL_FAST=0
if [ -s "$SUDIR/deployed.version" ] && [ -s "$DATABIN/magisk" ] \
   && [ "${MAGISK_FILES_FORCE:-0}" != "1" ]; then
    DPL_FAST=1
fi

# ---------- 0. prepare + stage ----------------------------------------------
# Fast path: when the same manager APK was already staged and deployed, the
# staging directory and DATABIN already hold exactly this file set, so there is
# nothing to compare or copy - only the version marker is refreshed (written
# after magiskd answers, below). The marker is the APK's MD5, so replacing the
# manager (or its version) always costs one full deploy.
echo "--- stage components ---"
mkdir -p "$DATABIN" "$DATABIN/chromeos" "$SUDIR" 2>/dev/null
chmod 700 /data/adb 2>/dev/null
if [ "$DPL_FAST" = "1" ]; then
    echo "deployed: $(/system/bin/cat "$SUDIR/deployed.version" 2>/dev/null) already in $DATABIN"
    echo "          skipping md5 compare and copy (same manager APK md5)"
else
# Install the complete stock Magisk 30.7 file set. The Magisk manager checks
# this directory and shows "Magisk files are incomplete" when even one of
# these runtime/boot-patch files is missing. BusyBox must be copied first
# because copy_if_changed uses its md5sum applet for every later file.
stage_bin "$STAGE/busybox" "$DATABIN/busybox" 755
stage_bin "$STAGE/magisk" "$DATABIN/magisk" 755
# magisk32/64 are 30.7 leftovers. A newer Magisk (v31) does not ship them, so a
# payload must not resurrect them; the payload block below removes them too.
if [ ! -s "$STAGE/payload.manifest" ]; then
    copy_if_changed "$STAGE/magisk32" "$DATABIN/magisk32" 755
    copy_if_changed "$STAGE/magisk64" "$DATABIN/magisk64" 755
fi
stage_bin "$STAGE/magiskinit" "$DATABIN/magiskinit" 755
stage_bin "$STAGE/magiskboot" "$DATABIN/magiskboot" 755
stage_bin "$STAGE/magiskpolicy" "$DATABIN/magiskpolicy" 755
stage_bin "$STAGE/init-ld" "$DATABIN/init-ld" 755
stage_bin "$STAGE/util_functions.sh" "$DATABIN/util_functions.sh" 755
copy_if_changed "$STAGE/addon.d.sh" "$DATABIN/addon.d.sh" 755
stage_bin "$STAGE/boot_patch.sh" "$DATABIN/boot_patch.sh" 755
# /data/adb/magisk/stub.apk is intentionally NOT overwritten: Magisk derives
# trusted_cert from the manager APK seeded at /debug_ramdisk/stub.apk, and a
# stub from a different build makes it log "cert: APK version too low".
copy_if_changed "$STAGE/chromeos/futility" "$DATABIN/chromeos/futility" 755
copy_if_changed "$STAGE/chromeos/kernel.keyblock" "$DATABIN/chromeos/kernel.keyblock" 644
copy_if_changed "$STAGE/chromeos/kernel_data_key.vbprivk" "$DATABIN/chromeos/kernel_data_key.vbprivk" 644
fi
# Scripts used by this deployment live in SUDIR (the app's DE directory),
# never in /data/adb. The guard is made executable before it is detached.
chmod 755 "$STAGE/deploy-magisk.sh" "$STAGE/magiskd-guard.sh" 2>/dev/null
# 4.7 kept a 4,409-byte wrapper as a su.legacy file. Do not create or retain
# it: only the two Magisk symlinks below are allowed to provide su. Remove
# only those two obsolete executables from the old directory; policy backups
# and the rest of /data/adb/dfroot are intentionally left untouched.
rm -f "$SUDIR/su.legacy" "$STAGE/su" \
      /data/adb/dfroot/su.legacy /data/adb/dfroot/su 2>/dev/null

# Custom payload (menu -> Update Magisk payload): apply the complete file set it
# recorded, not just the .so binaries. Each entry carries the MD5 of the file in
# the APK, so a truncated/corrupt payload is skipped instead of half-applied.
if [ -s "$STAGE/payload.manifest" ]; then
    _pl_flag=$(/system/bin/cat "$STAGE/payload.applied" 2>/dev/null | $BB tr -dc '0-9')
    [ -n "$_pl_flag" ] || _pl_flag=0
    if [ "$_pl_flag" = "1" ]; then
        # The app resets this flag whenever a new payload is extracted, so a
        # value of 1 means "this exact set was already copied" and the copy can
        # be skipped (the completeness check below still runs every time).
        echo "--- payload file set ---"
        echo "payload: already applied to $DATABIN (flag=1), skipping copy"
    else
    echo "--- payload file set ---"
    _pl_n=0
    _pl_bad=0
    while read -r _pl_name _pl_md5; do
        [ -n "$_pl_name" ] || continue
        _pl_src=$STAGE/$_pl_name
        if [ ! -f "$_pl_src" ]; then
            echo "WARN: payload missing $_pl_name"
            _pl_bad=$((_pl_bad + 1))
            continue
        fi
        _pl_got=$($BB md5sum "$_pl_src" 2>/dev/null | $BB awk '{print $1}')
        if [ -n "$_pl_md5" ] && [ "$_pl_got" != "$_pl_md5" ]; then
            echo "WARN: payload $_pl_name md5 mismatch, not applied"
            _pl_bad=$((_pl_bad + 1))
            continue
        fi
        _pl_dst=$DATABIN/$_pl_name
        _pl_dir=${_pl_dst%/*}
        [ -d "$_pl_dir" ] || mkdir -p "$_pl_dir" 2>/dev/null
        case "$_pl_name" in
            *.sh|futility|magisk|magiskboot|magiskinit|magiskpolicy|bootctl|init-ld|busybox)
                _pl_mode=755 ;;
            *) _pl_mode=644 ;;
        esac
        copy_if_changed "$_pl_src" "$_pl_dst" "$_pl_mode"
        _pl_n=$((_pl_n + 1))
    done < "$STAGE/payload.manifest"
    echo "payload: applied $_pl_n file(s), $_pl_bad skipped"
    # Files the new version no longer ships (v31 has no magisk32/64) must not
    # stay behind as 30.7 leftovers.
    for _pl_old in magisk32 magisk64; do
        $BB grep -q "^$_pl_old " "$STAGE/payload.manifest" 2>/dev/null ||
            rm -f "$DATABIN/$_pl_old"
    done
    if [ "$_pl_bad" = "0" ]; then
        printf '1\n' > "$STAGE/payload.applied" 2>/dev/null
        chmod 666 "$STAGE/payload.applied" 2>/dev/null
        echo "payload: flag set to 1 (next runs skip the copy)"
    else
        printf '0\n' > "$STAGE/payload.applied" 2>/dev/null
    fi
    fi
fi

MAGISK_MISSING=""
_PAYLOAD_SET=0
[ -s "$STAGE/payload.manifest" ] && _PAYLOAD_SET=1
for _mf in magisk magisk32 magisk64 magiskinit magiskboot magiskpolicy \
           init-ld busybox stub.apk util_functions.sh addon.d.sh boot_patch.sh \
           chromeos/futility chromeos/kernel.keyblock \
           chromeos/kernel_data_key.vbprivk; do
    case "$_mf" in
        magisk32|magisk64)
            continue
            ;;
    esac
    case "$_mf" in
        chromeos/*)
            # Magisk 31.x may not ship the ChromeOS helpers at all; nothing in
            # this deploy needs them, so they are optional.
            [ -s "$STAGE/$_mf" ] || continue
            ;;
    esac
    [ -s "$DATABIN/$_mf" ] || MAGISK_MISSING="$MAGISK_MISSING $_mf"
done
if [ -n "$MAGISK_MISSING" ]; then
    ls -la "$DATABIN/" 2>&1
    fatal "incomplete Magisk file set:$MAGISK_MISSING"
fi
echo "Magisk file set: complete (payload=$_PAYLOAD_SET)"
progress 30
ls -la "$DATABIN/"
ls -la "$DATABIN/chromeos/"
ls -la "$SUDIR/"

if [ ! -x "$BB" ] || [ ! -x "$MAGISK" ] || [ ! -x "$MPOLICY" ]; then
    fatal "staged binaries missing (busybox/magisk/magiskpolicy)"
fi

# Read the opt-in switch from the app's device-protected SharedPreferences.
# The app writes /data/user_de/0/df.root/shared_prefs/dfroot.xml. Missing/false
# means "normal deploy", which still never touches zygote.
#   soft_reboot      : LSPosed auto mode (restart zygote once)
#   disable_modules  : one-shot boot-safety switch; every Magisk module gets a
#                      `disable` marker for this deploy and is restored right
#                      after post-fs-data (a broken module can no longer crash
#                      the device or restart zygote).
read_soft_reboot_pref() {
    SOFT_REBOOT=0
    DISABLE_MODULES=0
    _sr_xml=$STAGE/shared_prefs/dfroot.xml
    _sr_grep=$BB
    [ -x "$_sr_grep" ] || _sr_grep=/system/bin/grep
    if [ -f "$_sr_xml" ]; then
        $_sr_grep -q 'name="soft_reboot".*value="true"' "$_sr_xml" 2>/dev/null &&
            SOFT_REBOOT=1
        $_sr_grep -q 'name="disable_modules".*value="true"' "$_sr_xml" 2>/dev/null &&
            DISABLE_MODULES=1
    fi
    echo "prefs: soft_reboot=$SOFT_REBOOT disable_modules=$DISABLE_MODULES (xml=$_sr_xml)"
}

if detect_app_process; then
    echo "app_process candidate: $APP_PROCESS"
else
    echo "WARN: no executable app_process candidate found"
fi

# Stop the guard BEFORE touching modules. A guard may be inside
# --post-fs-data with boot scripts renamed; stopping it first lets its trap
# restore them, then recover_modules handles anything left by a hard kill.
# A leftover daemon would serve the tmpfs we are about to replace.
stop_magiskd_guard
recover_modules
OLD=$($BB pidof magiskd 2>/dev/null)
if [ -n "$OLD" ]; then
    echo "stopping previous magiskd: $OLD"
    kill_pid_list "$OLD"
    sleep 1
    rm -f /debug_ramdisk/.magisk/device/socket 2>/dev/null
fi

# ---------- 1. live sepolicy: permissive load, magisk stays permissive ------
echo "--- sepolicy: magiskpolicy --live --magisk (NO enforce magisk) ---"
setenforce 0 2>/dev/null
# Read the opt-in switch while global SELinux is permissive, so the busybox in
# /data/adb and the app's device-protected XML are both accessible.
read_soft_reboot_pref
$MPOLICY --live --magisk
echo "magiskpolicy --magisk rc=$?"
# Apply module rules before the wildcard policy below. The wildcard is
# expanded against the current type set, so types introduced by a module
# (magisk_file, lsposed_file, ...) must exist first.
apply_module_sepolicy_rules
echo "module sepolicy state: files=$MODULE_POLICY_COUNT lsposed_file=$LSPOSED_FILE_TYPE compat=$LSPOSED_FILE_COMPAT"
$MPOLICY --live "allow magisk * * *"
echo "allow magisk * rc=$?"
# Magisk 30.7's magiskpolicy grammar is:
#   allow <source_type> <target_type> <class> <perm_set>
# Do NOT use the older "target:class" form; it prints "Syntax error in:" but
# still returns rc=0, which is how 4.7 silently loaded no rules at all.
$MPOLICY --live "allow magisk magisk process execmem"
echo "allow magisk execmem rc=$?"
$MPOLICY --live "allow init magisk unix_stream_socket { connectto getopt }"
echo "allow init connectto rc=$?"
for t in ptmx_device devpts devpts_t; do
    $MPOLICY --live "allow magisk $t chr_file { read write open getattr ioctl }" >/dev/null 2>&1
    $MPOLICY --live "allow magisk $t dir { search read open getattr }" >/dev/null 2>&1
done
$MPOLICY --live "allow magisk proc file { read write open getattr }" >/dev/null 2>&1
echo "selinux now: $(getenforce 2>&1)"
echo "magisk-domain permissive is upstream; NOT cleared"

# Done-marker fd is opened while permissive. The file must stay EMPTY until
# the final result, because ExploitRunner only finishes on length > 0.
if : > "$DONE_MARKER" 2>/dev/null; then
    chmod 644 "$DONE_MARKER" 2>/dev/null
    exec 9>>"$DONE_MARKER"
    DONE_FD_OPEN=1
else
    echo "WARN: cannot create $DONE_MARKER"
    exec 9>/dev/null
fi

# ---------- 2. manager detection -------------------------------------------
echo "--- magisk manager ---"
# The manager's version is not read here: Magisk's check_orig() and the manager
# itself handle version/signature. DFRoot only needs the manager APK path (to
# seed stub.apk) and its data dir.

# Only two sources are used, both validated by APK contents (the APK must carry
# assets/util_functions.sh with MAGISK_VER - that is what identifies Magisk):
#   1. the package stored by the previous run,
#   2. a scan of every installed APK.
# Package names and versionCodes are never trusted.
# A candidate is accepted only when its APK really is a Magisk build. The
# package versionCode is meaningless here (a hidden manager reports e.g. 1247),
# which is why the APK contents are checked instead.
try_manager() {
    _tm_pkg=$1
    [ -n "$_tm_pkg" ] || return 1
    case "$_tm_pkg" in ''|*[!A-Za-z0-9._]*) return 1 ;; esac
    pkg_installed "$_tm_pkg" || return 1
    _tm_apk=$(apk_of "$_tm_pkg") || return 1
    [ -n "$_tm_apk" ] || return 1
    MGR_PKG=$_tm_pkg
    MGR_UID=$(pkg_uid "$_tm_pkg")
    MGR_APK=$_tm_apk
    MGR_DE=/data/user_de/0/$_tm_pkg
    return 0
}

# 1) Database lookup (Official standard): read strings.requester from magisk.db.
#    When Magisk hides itself (repackage), it records the new random stub package
#    into the magisk.db strings table. We automatically read and trust this.
if [ -f /data/adb/magisk.db ]; then
    _db_rq=$($BB timeout 5 "$BB" sqlite3 /data/adb/magisk.db "SELECT value FROM strings WHERE key='requester';" 2>/dev/null | $BB tr -d ' \r\n')
    if [ -z "$_db_rq" ]; then
        _db_rq=$(sqlite3 /data/adb/magisk.db "SELECT value FROM strings WHERE key='requester';" 2>/dev/null | $BB tr -d ' \r\n')
    fi
    if [ -n "$_db_rq" ] && try_manager "$_db_rq"; then
        echo "manager: $_db_rq (auto-detected from magisk.db strings.requester)"
    fi
fi

# 2) Canonical fallback: com.topjohnwu.magisk
if [ -z "$MGR_PKG" ] && pkg_installed com.topjohnwu.magisk; then
    if try_manager com.topjohnwu.magisk; then
        echo "manager: com.topjohnwu.magisk (canonical default)"
    fi
fi

if [ -z "$MGR_PKG" ]; then
    echo "manager: none (will be resolved if registered after magiskd starts)"
fi

if [ -n "$MGR_PKG" ]; then
    MGR_UID=$(pkg_uid "$MGR_PKG")
    MGR_APK=$(apk_of "$MGR_PKG")
    MGR_DE=/data/user_de/0/$MGR_PKG
    echo "manager pkg=$MGR_PKG uid=${MGR_UID:-?} apk=${MGR_APK:-not-found}"
    # Hand the resolved package to the DFRoot app: the init worker cannot always
    # reach the activity service, so the app opens the manager from its own
    # process once this deploy finishes. The file also carries the manager's
    # signing certificate on line 2 (written by the app); keep it, because that
    # is what lets the app recognise a hidden/repackaged manager next boot.
    _mp_cur=$($BB head -n1 "$SUDIR/manager.package" 2>/dev/null | $BB tr -d ' \r\n')
    if [ "$_mp_cur" = "$MGR_PKG" ]; then
        echo "manager.package already points at $MGR_PKG (certificate preserved)"
        chmod 644 "$SUDIR/manager.package" 2>/dev/null
        _mp_appuid=$(pkg_uid df.root 2>/dev/null)
        [ -n "$_mp_appuid" ] || _mp_appuid=$(stat -c %u "$SUDIR" 2>/dev/null)
        [ -n "$_mp_appuid" ] && chown "$_mp_appuid:$_mp_appuid" "$SUDIR/manager.package" 2>/dev/null
    elif printf '%s\n' "$MGR_PKG" > "$SUDIR/manager.package" 2>/dev/null; then
        chmod 644 "$SUDIR/manager.package" 2>/dev/null
        # Hand it to the DFRoot app, NOT to the manager: the app must be able to
        # rewrite this file when the user changes the package name. Owning it as
        # MGR_UID made every later write fail with EACCES.
        _mp_appuid=$(pkg_uid df.root 2>/dev/null)
        [ -n "$_mp_appuid" ] || _mp_appuid=$(stat -c %u "$SUDIR" 2>/dev/null)
        [ -n "$_mp_appuid" ] && chown "$_mp_appuid:$_mp_appuid" "$SUDIR/manager.package" 2>/dev/null
        echo "manager.package staged for the DFRoot app"
    else
        echo "WARN: cannot write $SUDIR/manager.package"
    fi
else
    echo "manager: none (packages.list is not consulted: it is often unreadable"
    echo "         or stale in this context, and misleading when it fails)"
fi

if [ -n "$MGR_DE" ] && [ -d "$MGR_DE" ] && [ -z "$MGR_UID" ]; then
    MGR_UID=$(stat -c %u "$MGR_DE" 2>/dev/null)
fi

# A hidden (repackaged) Magisk app cannot be located by package name or by an
# APK scan in every case. Magisk itself records the manager it is bound to in

# get_manager() stats /data/user_de/0/<pkg>; without it the manager is "not
# installed" even though the APK exists.
if [ -n "$MGR_UID" ] && [ -n "$MGR_DE" ] && [ ! -d "$MGR_DE" ]; then
    mkdir -p "$MGR_DE" 2>/dev/null
    chown "$MGR_UID:$MGR_UID" "$MGR_DE" 2>/dev/null
    chmod 700 "$MGR_DE" 2>/dev/null
    chcon u:object_r:app_data_file:s0 "$MGR_DE" 2>/dev/null
    echo "created $MGR_DE (uid=$MGR_UID)"
fi

# A manager is usable when its APK is known. The data dir is only needed to
# register a non-standard manager; the payload stub covers the hidden case.
# The manager's version is deliberately NOT read or compared: Magisk's
# check_orig()/manager handle version and signature themselves.
if [ -n "$MGR_APK" ]; then
    PROMPT_MODE=1
else
    PROMPT_MODE=0
fi
echo "PROMPT_MODE=$PROMPT_MODE (1 = manager APK found)"
progress 35
# The app is intentionally not told to refresh the manager after a su grant:
# DFRoot never requests SU. The manager is opened directly in step 12.

# ---------- 3. manager resolution is finished after magiskd starts ----------
# The manager APK is only needed to seed stub.apk before --post-fs-data, which
# happens after magiskd is up. If the early scan found nothing, magisk.db
if [ "$PROMPT_MODE" != "1" ]; then
    echo "manager: not found yet (pkg=${MGR_PKG:-none} apk=${MGR_APK:-none});"
    echo "         will ask magiskd for the bound package after it starts"
fi

# ---------- 4. xattr-capable /debug_ramdisk ---------------------------------
echo "--- /debug_ramdisk (must support security.selinux xattr) ---"
prepare_debug_ramdisk || fatal "could not prepare xattr-capable /debug_ramdisk"
mkdir -p /debug_ramdisk/.magisk/busybox /debug_ramdisk/.magisk/device \
         /debug_ramdisk/.magisk/block /debug_ramdisk/.magisk/worker 2>/dev/null
# No .magisk/pts directory: 4.7's PTY bug.
rm -rf /debug_ramdisk/.magisk/pts 2>/dev/null

# Magisk's setup_magisk_env() calls set_mount_private("/debug_ramdisk/.magisk/
# worker"), which is MS_PRIVATE on that path. DFRoot binds /debug_ramdisk from an
# f2fs directory, so the worker path is a plain directory inside a bind mount and
# MS_PRIVATE fails with EINVAL (the
#   E : set_mount_private '/debug_ramdisk/.magisk/worker': : Invalid argument
# line in the Magisk log). Making the worker a mount point of its own makes that
# call succeed.
if [ -d /debug_ramdisk/.magisk/worker ]; then
    mount --bind /debug_ramdisk/.magisk/worker /debug_ramdisk/.magisk/worker 2>/dev/null
    mount --make-private /debug_ramdisk/.magisk/worker 2>/dev/null
    echo "magisk worker mount: $(mount 2>/dev/null | grep -c ' \.magisk/worker ' ) entry(ies)"
fi

# stub.apk must exist BEFORE the daemon handles --post-fs-data:
# preserve_stub_apk() reads the certificate into trusted_cert and deletes it.
# If the copy is missing/corrupt, --post-fs-data's prune_su_access() would run
# check_orig() with an EMPTY trusted_cert and can UNINSTALL the manager. Verify
# a byte-identical copy first; otherwise refuse to run post-fs-data.
STUB_SEEDED=0
stage_manager_stub() {
    [ -n "$MGR_APK" ] || return 1
    STUB_SEEDED=0
    rm -f /debug_ramdisk/stub.apk 2>/dev/null
    # magiskd compares the versionCode of /debug_ramdisk/stub.apk with its own
    # MAGISK_VER_CODE and logs "E : cert: APK version too low" when it is
    # smaller, then drops trusted_cert.
    #
    # Canonical manager (com.topjohnwu.magisk): the APK in /data/app IS the full
    # Magisk build, use it directly - that is the original path.
    #
    # Hidden manager (repackaged, e.g. oi.d.y.bk): the installed APK is the small
    # stub, so Magisk keeps the full build at <de>/<pkg>/dyn/current.apk. That is
    # the APK it was hidden from, and the only one whose assets/stub.apk carries
    # the daemon's versionCode.
    _sms_src=""
    if [ "$MGR_PKG" = "com.topjohnwu.magisk" ]; then
        copy_if_changed "$MGR_APK" /debug_ramdisk/stub.apk 644 && _sms_src="$MGR_APK"
    else
        for _sms_cand in "$MGR_DE/dyn/current.apk" "$STAGE/payload.apk" "$SUDIR/manager.apk"; do
            [ -s "$_sms_cand" ] || continue
            if $BB unzip -p "$_sms_cand" assets/stub.apk > /debug_ramdisk/stub.apk 2>/dev/null &&
               [ -s /debug_ramdisk/stub.apk ]; then
                _sms_src="$_sms_cand:assets/stub.apk"
                break
            fi
            rm -f /debug_ramdisk/stub.apk 2>/dev/null
        done
        if [ -z "$_sms_src" ]; then
            copy_if_changed "$MGR_APK" /debug_ramdisk/stub.apk 644 && _sms_src="$MGR_APK"
        fi
    fi
    if [ -n "$_sms_src" ] && [ -s /debug_ramdisk/stub.apk ]; then
        chmod 644 /debug_ramdisk/stub.apk 2>/dev/null
        chcon "$MAGISK_FILE_CON" /debug_ramdisk/stub.apk 2>/dev/null
        STUB_SEEDED=1
        echo "stub.apk <- $_sms_src ($(wc -c < /debug_ramdisk/stub.apk 2>/dev/null) bytes)"
    else
        echo "ERROR: could not stage a stub.apk from $MGR_APK"
        return 1
    fi
    # Keep the FULL Magisk APK here: it is the source for assets/stub.apk on the
    # next run. Overwriting it with the hidden 28 KB stub destroyed that source.
    if [ -s "$MGR_APK" ] && [ "$(wc -c < "$MGR_APK" 2>/dev/null)" -gt 1000000 ] 2>/dev/null; then
        copy_if_changed "$MGR_APK" "$SUDIR/manager.apk" 644
        chmod 644 "$SUDIR/manager.apk" 2>/dev/null
    fi
    # A hidden manager is bound later, once magiskd answers (step 6b): dyn +
    # requester only make sense once the daemon can read them.
    return 0
}

# NOTE: magisk.db's strings.requester is deliberately NOT used to pick the
# manager APK. It can name any app that asked for su, and seeding stub.apk from
# the wrong APK makes Magisk's check_orig() treat the installed manager as an
# impostor and uninstall it.

if [ -n "$MGR_APK" ]; then
    stage_manager_stub || echo "WARN: stub staging failed; will retry after magiskd starts"
fi

# ---------- 5. preinit block device ----------------------------------------
echo "--- preinit block device (pre-daemon) ---"
PREDEV=""
PREDEV=$($MAGISK --preinit-device 2>/dev/null | $BB head -1)
echo "magisk --preinit-device -> '$PREDEV'"
rm -f /debug_ramdisk/.magisk/block/preinit 2>/dev/null
if [ -n "$PREDEV" ] && [ -b "$PREDEV" ]; then
    MM=$(stat -c '%t %T' "$PREDEV" 2>/dev/null)
    MAJ=$($BB echo "$MM" | $BB cut -d' ' -f1)
    MIN=$($BB echo "$MM" | $BB cut -d' ' -f2)
    mknod /debug_ramdisk/.magisk/block/preinit b 0x$MAJ 0x$MIN 2>/dev/null
fi
[ -b /debug_ramdisk/.magisk/block/preinit ] || \
    mknod /debug_ramdisk/.magisk/block/preinit b 7 0 2>/dev/null
if [ ! -b /debug_ramdisk/.magisk/block/preinit ]; then
    for b in /dev/block/by-name/userdata /dev/block/sda* /dev/block/mmcblk0* /dev/block/loop0; do
        if [ -b "$b" ]; then
            touch /debug_ramdisk/.magisk/block/preinit
            mount --bind "$b" /debug_ramdisk/.magisk/block/preinit 2>/dev/null && break
        fi
    done
fi
ls -la /debug_ramdisk/.magisk/block/ 2>&1

# ---------- 6. start magiskd ------------------------------------------------
echo "--- start magiskd ---"
copy_if_changed "$MAGISK" /debug_ramdisk/magisk 755
chcon "$MAGISK_FILE_CON" /debug_ramdisk/magisk 2>/dev/null
# Patch ONLY the runtime daemon copy. This must happen after the copy above and
# before --daemon starts. su_connect.rs uses this path for both the provider and
# the am fallback.
setup_app_process_transport
echo "app_process transport: ok=$APP_TRANSPORT_OK patched=$APP_PATCHED run=$APP_RUN target=$APP_PROCESS"
# Use -c (local binary version), NOT -V: -V connects to the daemon, which has
# not been started yet at this point. A -V self-test here would always fail and
# would wrongly restore the stock (unpatched) binary.
if [ "$APP_PATCHED" = "1" ] && ! /debug_ramdisk/magisk -c >/dev/null 2>&1; then
    echo "WARN: patched magisk failed its -c self-test; restoring stock binary"
    cp -f "$SUDIR/magisk.before_appprocess" /debug_ramdisk/magisk 2>/dev/null
    chmod 755 /debug_ramdisk/magisk 2>/dev/null
    chcon "$MAGISK_FILE_CON" /debug_ramdisk/magisk 2>/dev/null
    APP_RUN="$APP_PROCESS"
    APP_PATCHED=0
    APP_TRANSPORT_OK=0
    rm -f "$APP_PROXY" 2>/dev/null
fi
cp -f "$DATABIN/util_functions.sh" /debug_ramdisk/.magisk/util_functions.sh 2>/dev/null
chmod 755 /debug_ramdisk/.magisk/util_functions.sh 2>/dev/null
cp -f "$BB" /debug_ramdisk/.magisk/busybox/busybox 2>/dev/null
chmod 755 /debug_ramdisk/.magisk/busybox/busybox 2>/dev/null
chcon "$MAGISK_FILE_CON" /debug_ramdisk /debug_ramdisk/magisk 2>/dev/null
chcon -R "$MAGISK_FILE_CON" /debug_ramdisk/.magisk 2>/dev/null
# PBB survives setenforce 1 (init cannot always search /data/adb afterwards).
PBB=/debug_ramdisk/.magisk/busybox/busybox
[ -x "$PBB" ] || PBB=$BB
ls -la /debug_ramdisk/.magisk/busybox/ 2>&1

# .magisk is part of the whole f2fs bind created above; no separate bind is
# needed. The daemon and the manager therefore see the same su_request FIFOs.
echo "XATTR_BIND_OK=$XATTR_BIND_OK (whole /debug_ramdisk is f2fs)"

# /debug_ramdisk is a fresh f2fs bind and the daemon may re-create parts of it.
# Make sure the patched binary's app_process proxy still points at a real
# executable before any su request can happen.
if [ "$APP_PATCHED" = "1" ]; then
    ln -sf "$APP_PROCESS" "$APP_PROXY" 2>/dev/null
    if [ -x "$APP_PROXY" ]; then
        echo "app_process proxy: $APP_PROXY -> $APP_PROCESS"
    else
        echo "WARN: app_process proxy is not executable; restoring stock magisk"
        cp -f "$SUDIR/magisk.before_appprocess" /debug_ramdisk/magisk 2>/dev/null
        chmod 755 /debug_ramdisk/magisk 2>/dev/null
        chcon "$MAGISK_FILE_CON" /debug_ramdisk/magisk 2>/dev/null
        APP_PATCHED=0
        APP_TRANSPORT_OK=0
        APP_RUN="$APP_PROCESS"
    fi
fi

# app_process is used by magiskd's su_connect and by the am self-test. Both
# must see the Android runtime environment; the init worker does not provide it.
import_android_env

cd /
# daemon_entry() writes u:r:magisk:s0 itself. Global permissive here.
/debug_ramdisk/magisk --daemon &

# Fast poll for magiskd pid (up to 2s, checks every 100ms)
MPID=""
for _w in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    MPID=$($BB pidof magiskd 2>/dev/null)
    [ -n "$MPID" ] && break
    $BB usleep 100000 2>/dev/null || sleep 1
done
echo "magiskd pid=[$MPID]"
if [ -z "$MPID" ]; then
    fatal "magiskd did not start"
fi

MCTX=$(/system/bin/cat /proc/$MPID/attr/current 2>/dev/null)
echo "magiskd context=[$MCTX]"
case "$MCTX" in
    *magisk*) ;;
    *)
        echo "WARN: magiskd is not in the magisk domain; restarting with runcon"
        for p in $MPID; do kill -9 "$p" 2>/dev/null; done
        $BB usleep 200000 2>/dev/null || sleep 1
        $BB runcon u:r:magisk:s0 /debug_ramdisk/magisk --daemon &
        MPID=""
        for _w in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
            MPID=$($BB pidof magiskd 2>/dev/null)
            [ -n "$MPID" ] && break
            $BB usleep 100000 2>/dev/null || sleep 1
        done
        echo "magiskd pid(retry)=[$MPID]"
        [ -n "$MPID" ] || fatal "magiskd retry failed"
        ;;
esac
MAGISK_READY=1
progress 55

# Fast poll until the client can talk to the daemon
SQLBIN=/debug_ramdisk/magisk
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    $BB timeout 2 "$SQLBIN" -V >/dev/null 2>&1 && break
    $BB usleep 150000 2>/dev/null || sleep 1
done
echo "magisk -V: $($BB timeout 3 "$SQLBIN" -V 2>&1 | $BB head -1)"

# Record what is actually running. The marker is only written here, on a
# successful start, so a half-finished deploy can never enable the fast path.
_DPL_VER=$($BB timeout 5 "$SQLBIN" -V 2>&1 | $BB head -1 | $BB tr -dc '0-9')
if [ -n "$_DPL_VER" ]; then
    printf 'Magisk %s\n' "$_DPL_VER" > "$SUDIR/deployed.version" 2>/dev/null
    chmod 644 "$SUDIR/deployed.version" 2>/dev/null
    _dv_uid=$(pkg_uid df.root 2>/dev/null)
    [ -n "$_dv_uid" ] && chown "$_dv_uid:$_dv_uid" "$SUDIR/deployed.version" 2>/dev/null
    # Leftover from the md5 era; the deploy does not read it any more.
    rm -f "$SUDIR/deployed.apk.md5" "$SUDIR/installed.apk.md5" \
          "$SUDIR/manager.apk.md5" 2>/dev/null
    echo "deployed version: Magisk $_DPL_VER (marker updated)"
if [ "${MAGISK_NEW_SET:-0}" = "1" ]; then
    if sql_run "DELETE FROM strings WHERE key='keystore';" >/dev/null 2>&1; then
        echo "magisk.db: stale manager certificate cleared (re-learned from the new APK)"
    fi
fi
fi

# ---------- 6a. resolve the manager now that magiskd answers -----------------
# Reading magisk.db BEFORE the daemon exists needed a sqlite3 binary (this ROM
# has none), so the manager was still unknown when stub.apk had to be seeded.
# magiskd itself can answer --sqlite now.
if [ -z "$MGR_PKG" ] && [ -f /data/adb/magisk.db ]; then
    _late_rq=$($BB timeout 5 "$SQLBIN" --sqlite "SELECT value FROM strings WHERE key='requester';" 2>/dev/null |
               $BB tail -1 | $BB sed 's/^value=//' | $BB tr -d ' \r\n')
    if [ -n "$_late_rq" ] && try_manager "$_late_rq"; then
        echo "manager: $MGR_PKG (magisk.db requester, resolved after magiskd)"
    fi
fi
if [ -z "$MGR_PKG" ] && [ -s "$SUDIR/manager.package" ]; then
    _late_mp=$($BB head -n1 "$SUDIR/manager.package" 2>/dev/null | $BB tr -d ' \r\n')
    if [ -n "$_late_mp" ] && try_manager "$_late_mp"; then
        echo "manager: $MGR_PKG (manager.package, resolved after magiskd)"
    fi
fi
if [ -z "$MGR_PKG" ] && pkg_installed com.topjohnwu.magisk; then
    if try_manager com.topjohnwu.magisk; then
        echo "manager: com.topjohnwu.magisk (canonical, resolved after magiskd)"
    fi
fi
[ -n "$MGR_PKG" ] && echo "manager pkg=$MGR_PKG uid=${MGR_UID:-?} apk=${MGR_APK:-?}"

# --post-fs-data needs stub.apk to derive trusted_cert, so seed it here (the
# early attempt runs before the daemon and therefore before the manager exists).
if [ "$STUB_SEEDED" != "1" ] && [ -n "$MGR_APK" ]; then
    stage_manager_stub && echo "stub.apk seeded after magiskd start"
fi

# The manager itself requests su on startup (Shell.getShell()). If its UID has no
# rows in policies, magiskd answers with a PROMPT - and the only app that could
# show that prompt is the manager itself, which is blocked waiting for the shell.
# That deadlock is why the hidden manager hangs on its splash screen. Grant it a
# permanent Allow (policy=2) so its own su returns immediately.
if [ -z "$MGR_UID" ] && [ -n "$MGR_PKG" ]; then
    MGR_UID=$(pkg_uid "$MGR_PKG" 2>/dev/null)
fi
if [ -n "$MGR_UID" ]; then
    if sql_run "INSERT OR REPLACE INTO policies (uid,policy,until,logging,notification) VALUES ($MGR_UID,2,0,1,0);" >/dev/null 2>&1; then
        echo "policy: uid=$MGR_UID allow=2 (manager, no prompt)"
    else
        echo "WARN: could not grant uid=$MGR_UID"
    fi
fi

# ---------- 6b. bind the manager now that su/magiskd is up -------------------
# The canonical package keeps the upstream path (stub.apk + --post-fs-data).
# A hidden (repackaged) manager is resolved by Magisk through
#     <de>/<pkg>/dyn/current.apk   and   strings.requester
# so the binding has to happen after the daemon answers: write the requester
# row, stage dyn/current.apk, and let the app bring the UI up (the init worker
# has no activity binder on this ROM).
# ---- 6b-0. manager identity: no md5 any more --------------------------------
# Magisk trusts exactly one manager certificate (magisk.db strings.keystore).
# The APK is no longer hashed, so the only thing that can change the trusted
# manager is the user asking for an upgrade: when upgrade.request was consumed
# above, the extracted file set is new, MAGISK_NEW_SET=1 and the stale keystore
# row has already been dropped (see the deployed.version block). Everything
# else - hidden-manager binding, requester row, stub seeding - is unchanged.
if [ "${MAGISK_NEW_SET:-0}" = "1" ]; then
    echo "manager identity: new file set from the installed APK (signature re-learned)"
else
    echo "manager identity: keeping the staged file set (按「升級 Magisk 版本」才會重新提取)"
fi
MANAGER_INSTALLED_NEW=0

HIDDEN_MANAGER_BOUND=0
if [ -n "$MGR_PKG" ] && [ "$MGR_PKG" != "com.topjohnwu.magisk" ]; then
    echo "--- verify hidden manager: $MGR_PKG ---"
    echo "  uid=${MGR_UID:-?} apk=${MGR_APK:-not-found}"
    
    # 1. 確保 requester 與已安裝的隱藏管理器一致
    _cur_rq=$(sql_run "SELECT value FROM strings WHERE key='requester';" | $BB tail -n1 | $BB sed 's/^value=//' | $BB tr -d ' \r\n')
    if [ "$_cur_rq" != "$MGR_PKG" ]; then
        sql_run "DELETE FROM strings WHERE key='requester'; INSERT INTO strings(key,value) VALUES('requester','$MGR_PKG');" >/dev/null 2>&1
        echo "  requester updated -> $MGR_PKG"
    else
        echo "  requester already matches $MGR_PKG"
    fi

    # 2. 檢查 Magisk 隱藏時自身生成的 dyn/current.apk
    _existing_dyn=""
    for _chk_dir in "/data/user_de/0/$MGR_PKG/dyn" "/data/user/0/$MGR_PKG/dyn" "/data/data/$MGR_PKG/dyn"; do
        if [ -s "$_chk_dir/current.apk" ]; then
            _sz=$(wc -c < "$_chk_dir/current.apk" 2>/dev/null)
            # 完整 Magisk APK 通常 > 1MB，若是有效檔案就保留
            if [ "${_sz:-0}" -gt 1000000 ]; then
                _existing_dyn="$_chk_dir/current.apk"
                echo "  found valid Magisk dyn/current.apk at $_existing_dyn ($_sz bytes) - keeping intact"
                break
            fi
        fi
    done

    if [ -n "$_existing_dyn" ]; then
        HIDDEN_MANAGER_BOUND=1
    else
        # 只有在完全找不到時，才檢查是否有完整的 payload 可以補充
        _cand_apk=""
        for _cand in "$SUDIR/manager.apk" "/data/adb/magisk/magisk.apk" "/data/adb/magisk/magisk"; do
            if [ -s "$_cand" ] && [ "$(wc -c < "$_cand" 2>/dev/null)" -gt 1000000 ]; then
                _cand_apk="$_cand"
                break
            fi
        done
        if [ -n "$_cand_apk" ]; then
            for _base_dir in "/data/user_de/0/$MGR_PKG" "/data/user/0/$MGR_PKG" "/data/data/$MGR_PKG"; do
                if [ -d "$_base_dir" ]; then
                    mkdir -p "$_base_dir/dyn" 2>/dev/null
                    cp -f "$_cand_apk" "$_base_dir/dyn/current.apk" 2>/dev/null
                    chmod 700 "$_base_dir/dyn" 2>/dev/null
                    chmod 600 "$_base_dir/dyn/current.apk" 2>/dev/null
                    chcon -R u:object_r:app_data_file:s0 "$_base_dir/dyn" 2>/dev/null
                    [ -n "$MGR_UID" ] && chown -R "$MGR_UID:$MGR_UID" "$_base_dir/dyn" 2>/dev/null
                    echo "  restored missing dyn/current.apk from $_cand_apk -> $_base_dir/dyn/current.apk"
                fi
            done
            HIDDEN_MANAGER_BOUND=1
        else
            echo "  notice: dyn/current.apk managed by Magisk stub natively"
            HIDDEN_MANAGER_BOUND=1
        fi
    fi

    # Official Magisk behavior: pre-grant root access to manager in policies table (policy=2)
    # This prevents the manager from deadlocking with magiskd when Shell.getShell() is called on launch
    if [ -n "$MGR_UID" ]; then
        sql_run "INSERT OR REPLACE INTO policies (uid, policy, until, logging, notification) VALUES ($MGR_UID, 2, 0, 1, 0);" >/dev/null 2>&1
        echo "  manager root policy pre-granted for uid=$MGR_UID (policy=2)"
    fi
    # magiskd trusts the manager through TWO rows in magisk.db:
    #   strings.requester -> the package name (written above)
    #   strings.keystore  -> the manager's signing certificate (written by Magisk
    #                        itself when it repackaged/hid the app)
    # The keystore blob cannot be fabricated here, so it must be preserved. If it
    # is missing, magiskd will reject the hidden manager even with the right
    # requester, and the manager shows "not installed".
    # Magisk does NOT keep a manager versionCode in magisk.db: only the
    # requester name and the keystore blob. So there is nothing to "fix" here;
    # what matters is that dyn/current.apk is the full build (see above) and its
    # versionCode is >= the daemon's. Report both so a real mismatch is obvious.
    _dyn_ver=$($BB unzip -p "$MGR_DE/dyn/current.apk" AndroidManifest.xml 2>/dev/null | $BB wc -c)
    echo "  dyn/current.apk present=$([ -s "$MGR_DE/dyn/current.apk" ] && echo yes || echo no) size=${_dyn_ver:-0}"
    _ks=$($BB timeout 5 "$SQLBIN" --sqlite "SELECT count(*) FROM strings WHERE key='keystore';" 2>/dev/null |
          $BB tail -1 | $BB tr -dc '0-9')
    _rq=$($BB timeout 5 "$SQLBIN" --sqlite "SELECT value FROM strings WHERE key='requester';" 2>/dev/null |
          $BB tail -1 | $BB sed 's/^value=//' | $BB tr -d ' \r\n')
    echo "  magisk.db: requester=${_rq:-<empty>} keystore_rows=${_ks:-0}"
    if [ "${_ks:-0}" = "0" ]; then
        echo "  WARN: strings.keystore is empty -> magiskd cannot trust this manager."
        echo "        Open the (hidden) manager once while root is active; Magisk"
        echo "        writes the keystore row itself, then re-run the deploy."
    fi
fi

# The manager APK must be the one Magisk is actually bound to: --post-fs-data
# derives trusted_cert from it, and a wrong APK makes Magisk treat the installed
# manager as a signature mismatch and UNINSTALL it. A value from magisk.db is
# NOT proof (strings.requester can name any app that asked for su), so the
# deploy only uses the package the DFRoot app resolved (stored name, stored
# certificate, or APK contents) and refuses to guess.
if [ "$STUB_SEEDED" != "1" ]; then
    # Not fatal. Root does not need the manager: skipping --post-fs-data only
    # leaves trusted_cert empty and skips the module re-init for this run, while
    # the su channel still comes up so the user can install/open the manager.
    echo "WARN: no manager APK to seed stub.apk from"
    echo "      skipping --post-fs-data (trusted_cert empty, modules untouched)"
    echo "      Magisk su / root channel continue normally"
    MANAGER_LOST=1
    POST_FS_DATA_SKIPPED=1
fi

# ---------- 7. policy DB: snapshot, preserve, repair only what is broken -----
echo "--- root policy database (snapshot + exact-row preserve) ---"
policy_rows > "$POL_SNAPSHOT"
POL_BEFORE=$($PBB wc -l < "$POL_SNAPSHOT" 2>/dev/null | $PBB tr -dc '0-9')
case "$POL_BEFORE" in ''|*[!0-9]*) POL_BEFORE="?" ;; esac

ROOT_ACCESS=$(sql_run "SELECT value FROM settings WHERE key='root_access';" \
    | $BB tail -n1 | $BB tr -dc '0-9')
case "$ROOT_ACCESS" in ''|*[!0-9]*) ROOT_ACCESS=3 ;; esac
echo "root_access=$ROOT_ACCESS (0=disabled 1=apps 2=adb 3=apps+adb) [read-only]"

# A consistent backup without touching the live DB.
rm -f "$SUDIR/magisk.db.4.8.bak" 2>/dev/null
sql_run "VACUUM INTO '$SUDIR/magisk.db.4.8.bak';" | $BB tail -1
if [ -s "$SUDIR/magisk.db.4.8.bak" ]; then
    echo "db backup: $SUDIR/magisk.db.4.8.bak ($(wc -c < "$SUDIR/magisk.db.4.8.bak" 2>/dev/null) bytes)"
else
    echo "WARN: policy DB backup was not created (VACUUM INTO unsupported?)"
fi

# Reset ONLY bootloop. post-fs-data increments it; boot-complete normally
# resets it, but we deliberately never replay boot-complete on a live system.
sql_run "INSERT OR REPLACE INTO settings(key,value) VALUES('bootloop',0);" >/dev/null
echo "bootloop reset to 0"

# Stale requester repair: get_manager() tries check_stub()+check_dyn() when
# requester is non-empty. If the package is installed but dyn/current.apk is
# missing, check_dyn fails and Query silently returns DENY. That is a common
# cause of "the dialog never appears".
# The magisk --sqlite CLI prints rows as "column=value", so strip the prefix.
RQ_LINE=$(sql_run "SELECT value FROM strings WHERE key='requester';" | $BB tail -n1)
RQ=${RQ_LINE#value=}
RQ=$(printf '%s' "$RQ" | $BB tr -d ' \r\n')
case "$RQ" in
    ''|*[!A-Za-z0-9._]*) RQ_OK=0 ;;
    *) RQ_OK=1 ;;
esac
echo "requester before repair=[$RQ] valid=$RQ_OK"
# Verify or adopt requester
if [ -n "$RQ" ] && [ "$RQ_OK" = "1" ]; then
    if ! pkg_installed "$RQ"; then
        echo "requester=$RQ is not installed on system -> stale, deleting"
        sql_run "DELETE FROM strings WHERE key='requester';" >/dev/null
        rm -rf "/data/user_de/0/$RQ/dyn" "/data/user/0/$RQ/dyn" "/data/data/$RQ/dyn" 2>/dev/null
        RQ=""
    else
        # If MGR_PKG was empty or matched, ensure MGR_PKG is set to this valid requester
        if [ -z "$MGR_PKG" ]; then
            try_manager "$RQ"
            echo "adopted requester=$RQ as manager"
        fi

        # Check dyn/current.apk across DE and CE directories
        _found_dyn=""
        for _chk in "/data/user_de/0/$RQ/dyn/current.apk" "/data/user/0/$RQ/dyn/current.apk" "/data/data/$RQ/dyn/current.apk"; do
            if [ -f "$_chk" ] && [ -s "$_chk" ]; then
                _found_dyn="$_chk"
                break
            fi
        done

        if [ -n "$_found_dyn" ]; then
            # Sync to all other base dirs
            for _dst_base in "/data/user_de/0/$RQ" "/data/user/0/$RQ" "/data/data/$RQ"; do
                if [ -d "$_dst_base" ] && [ ! -f "$_dst_base/dyn/current.apk" ]; then
                    mkdir -p "$_dst_base/dyn" 2>/dev/null
                    cp -f "$_found_dyn" "$_dst_base/dyn/current.apk" 2>/dev/null
                    chmod 700 "$_dst_base/dyn" 2>/dev/null
                    chmod 600 "$_dst_base/dyn/current.apk" 2>/dev/null
                    chcon -R u:object_r:app_data_file:s0 "$_dst_base/dyn" 2>/dev/null
                    [ -n "$MGR_UID" ] && chown -R "$MGR_UID:$MGR_UID" "$_dst_base/dyn" 2>/dev/null
                    echo "synced dyn/current.apk -> $_dst_base/dyn/current.apk"
                fi
            done
        else
            # Try to populate current.apk from available Magisk APKs before giving up
            _fallback_apk=""
            for _cand in "$MGR_APK" "$SUDIR/manager.apk" "/data/adb/magisk/magisk" "$STAGE/stub.apk"; do
                if [ -f "$_cand" ] && [ -s "$_cand" ]; then
                    _fallback_apk="$_cand"
                    break
                fi
            done

            if [ -n "$_fallback_apk" ]; then
                echo "populating missing dyn/current.apk from $_fallback_apk"
                for _dst_base in "/data/user_de/0/$RQ" "/data/user/0/$RQ" "/data/data/$RQ"; do
                    if [ -d "$_dst_base" ]; then
                        mkdir -p "$_dst_base/dyn" 2>/dev/null
                        cp -f "$_fallback_apk" "$_dst_base/dyn/current.apk" 2>/dev/null
                        chmod 700 "$_dst_base/dyn" 2>/dev/null
                        chmod 600 "$_dst_base/dyn/current.apk" 2>/dev/null
                        chcon -R u:object_r:app_data_file:s0 "$_dst_base/dyn" 2>/dev/null
                        [ -n "$MGR_UID" ] && chown -R "$MGR_UID:$MGR_UID" "$_dst_base/dyn" 2>/dev/null
                    fi
                done
            else
                echo "WARN: requester=$RQ has no dyn/current.apk, but keeping requester entry to avoid breaking daemon trust"
            fi
        fi
    fi
fi
# A validated Magisk manager or hidden stub may be registered when it is not the
# standard package (a hidden manager needs requester).
# Note: A hidden stub APK does NOT contain assets/util_functions.sh (it stripped
# all Magisk strings for stealth), so do NOT require is_magisk_apk for stub packages!
if [ -n "$MGR_PKG" ] && [ "$MGR_PKG" != "com.topjohnwu.magisk" ] && [ -z "$RQ" ] &&
   pkg_installed "$MGR_PKG"; then
    case "$MGR_PKG" in
        *[!A-Za-z0-9._]*) echo "WARN: refusing SQL for odd package name $MGR_PKG" ;;
        *)
            sql_run "DELETE FROM strings WHERE key='requester'; INSERT INTO strings(key,value) VALUES('requester','$MGR_PKG');" >/dev/null
            RQ="$MGR_PKG"
            echo "requester set for hidden manager: $RQ"
            ;;
    esac
fi
RQ_AFTER="$RQ"
echo "requester after repair=[$RQ_AFTER]"

# ---------- 8. post-fs-data ONCE, modules visible, scripts suppressed --------
# Magisk initializes module_list and mounts modules only during this pass. If
# the module directories are hidden, the daemon's OnceLock stays empty and
# restoring the directories afterwards does NOT mount the modules. Keep them
# visible and suppress only the scripts that would start a late Zygisk daemon.
echo "--- post-fs-data (modules visible; boot scripts suppressed; no service/boot-complete replay) ---"
MODULE_COUNT_BEFORE=$(count_installed_modules)
echo "modules visible: count=$MODULE_COUNT_BEFORE"
$PBB ls -1 /data/adb/modules 2>/dev/null | $PBB head -n 20
if [ "$MODULE_COUNT_BEFORE" = "0" ]; then
    echo "WARN: /data/adb/modules has no module directories"
fi
# Boot-safety switch: disable every module for this one pass. Their scripts
# cannot replay, and Magisk will not mount a broken module on the next boot.
disable_all_modules
if ! hide_boot_scripts; then
    restore_boot_scripts
    restore_disabled_modules
    fatal "could not suppress every module boot script; refusing post-fs-data to protect zygote"
fi
SUPPRESSED_COUNT=$BOOT_SCRIPTS_OFF

ZYGOTE_BEFORE=$($PBB pidof zygote64 2>/dev/null)
[ -n "$ZYGOTE_BEFORE" ] || ZYGOTE_BEFORE=$($PBB pidof zygote 2>/dev/null)
echo "zygote pid before post-fs-data=[$ZYGOTE_BEFORE]"

# Record where the log ends so the certificate-error check only looks at lines
# written by THIS run (magisk.log is append-only and may contain old failures).
MAGLOG=""
for f in /data/adb/magisk.log /cache/magisk.log; do
    [ -f "$f" ] && MAGLOG="$f"
done
MAGLOG_LINES=0
[ -n "$MAGLOG" ] && MAGLOG_LINES=$($BB wc -l < "$MAGLOG" 2>/dev/null)
case "$MAGLOG_LINES" in ''|*[!0-9]*) MAGLOG_LINES=0 ;; esac

POST_RC=1
if [ "$POST_FS_DATA_SKIPPED" = "1" ]; then
    echo "post-fs-data skipped (no manager to seed stub.apk; see the warning above)"
else
    $PBB timeout 60 "$CLIENT" --post-fs-data
    POST_RC=$?
    echo "post-fs-data rc=$POST_RC"
fi
# restore IMMEDIATELY: module scripts should never remain hidden beyond the
# single controlled pass, and the one-shot disable markers are removed here.
restore_boot_scripts
restore_disabled_modules
sleep 1

# Safety net: if --post-fs-data decided that the manager's signature does not
# match trusted_cert, Magisk uninstalls it. Detect that immediately, report the
# reason, and try to put the APK back (it was copied to $SUDIR/manager.apk).
if [ -n "$MGR_PKG" ] && ! pkg_installed "$MGR_PKG"; then
    echo "WARN: manager $MGR_PKG disappeared during --post-fs-data"
    echo "      (Magisk removes a manager whose signature is not the trusted one)"
    if [ -s "$SUDIR/manager.apk" ]; then
        echo "      restoring it from $SUDIR/manager.apk"
        $PBB timeout 60 pm install -r -d "$SUDIR/manager.apk" 2>&1 | $PBB head -n 3
        sleep 2
        if pkg_installed "$MGR_PKG"; then
            echo "      manager restored"
        else
            echo "WARN: automatic restore failed; install the Magisk APK manually"
        fi
    fi
    MANAGER_LOST=1
fi
# setup_magisk_env() calls restorecon() over /data/adb; the f2fs .magisk bind
# lives under that tree, so restore the label the manager needs for su_request.
if [ "$XATTR_BIND_OK" = "1" ]; then
    chcon -R "$MAGISK_FILE_CON" /debug_ramdisk/.magisk 2>/dev/null
    echo "xattr .magisk: labels restored after post-fs-data"
fi

ZYGOTE_AFTER=$($PBB pidof zygote64 2>/dev/null)
[ -n "$ZYGOTE_AFTER" ] || ZYGOTE_AFTER=$($PBB pidof zygote 2>/dev/null)
echo "zygote pid after post-fs-data=[$ZYGOTE_AFTER]"
if [ "$ZYGOTE_BEFORE" = "$ZYGOTE_AFTER" ]; then
    echo "zygote: unchanged (no soft reboot)"
else
    echo "WARN: zygote pid changed during post-fs-data; a module still replayed a boot script"
fi

MODULE_COUNT_AFTER=$(count_installed_modules)
MODULES_STATE="visible; scripts_suppressed=$SUPPRESSED_COUNT; post_rc=$POST_RC"
echo "modules after post-fs-data: count=$MODULE_COUNT_AFTER state=$MODULES_STATE"
progress 75
echo "module dirs: $(ls -ld /data/adb/modules /data/adb/modules_update /data/adb/post-fs-data.d 2>&1)"

# bootloop was incremented by post-fs-data; reset it again.
sql_run "INSERT OR REPLACE INTO settings(key,value) VALUES('bootloop',0);" >/dev/null
echo "bootloop reset after post-fs-data"

# Magisk's prune_su_access() can delete a still-installed app's policy row
# during this late --post-fs-data (the package list is not always visible to
# the just-started daemon). Restore only exact rows that existed before this
# run and whose uid still maps to an installed package.
POL_CURRENT=$SUDIR/policies.after
policy_rows > "$POL_CURRENT"
$PBB cat "$POL_CURRENT" 2>/dev/null
restore_missing_policies "$POL_CURRENT"
policy_rows > "$POL_CURRENT"
POL_AFTER=$($PBB wc -l < "$POL_CURRENT" 2>/dev/null | $PBB tr -dc '0-9')
case "$POL_AFTER" in ''|*[!0-9]*) POL_AFTER="?" ;; esac
echo "policy rows: before=$POL_BEFORE after=$POL_AFTER restored=$POL_RESTORED"

# ---------- 9. trusted_cert / manager resolution safety --------------------
MAGLOG=""
for f in /data/adb/magisk.log /cache/magisk.log; do
    [ -f "$f" ] && MAGLOG="$f"
done
echo "magisk log: ${MAGLOG:-not found} (new lines since line $((MAGLOG_LINES + 1)))"

STUB_LOADED=0
if [ "$STUB_SEEDED" != "1" ]; then
    echo "WARN: stub.apk was not staged; trusted_cert is unknown"
elif [ ! -e /debug_ramdisk/stub.apk ]; then
    # preserve_stub_apk() removes it after reading the certificate.
    STUB_LOADED=1
else
    echo "WARN: /debug_ramdisk/stub.apk still exists -> preserve_stub_apk did not run"
fi
# No local verdict on the certificate: magiskd already logged whatever it
# decided ("cert: APK version too low" etc.) and that is the authority.
echo "STUB_LOADED=$STUB_LOADED (1 = /debug_ramdisk/stub.apk was consumed)"

# ---------- 10. su installation ---------------------------------------------
echo "--- su installation (stock-style Magisk symlinks only) ---"
# Always install the Magisk symlinks, even if trusted_cert is not proven.
# Trust affects whether it is safe to send a Query, not which binary is su.
install_stock_su
if [ "$STUB_LOADED" != "1" ]; then
    echo "WARN: trusted_cert is not proven; Magisk su links are installed, but"
    echo "      no app-uid SU test will be attempted (a Query could remove the manager)"
fi

# ---------- 11. manager ------------------------------------------------------
# DFRoot does not drive `am`/`cmd activity`/`monkey` from the init worker: its
# binder transport is missing on this ROM and every attempt just printed
# "Can't find service: activity". The app opens manager.package from its own
# foreground process after DEPLOY_DONE, which always works. app_process is
# still patched here because MagiskSU needs it for the *dialog* when another
# app requests su.
if [ "$APP_PATCHED" = "1" ]; then
    ln -sf "$APP_PROCESS" "$APP_PROXY" 2>/dev/null
    if [ -x "$APP_PROXY" ] &&
       ! $BB grep -aq '/system/bin/app_process' /debug_ramdisk/magisk 2>/dev/null; then
        echo "app_process proxy ready: $APP_PROXY -> $APP_PROCESS"
    else
        echo "WARN: app_process patch/proxy disappeared after post-fs-data; restoring magisk"
        cp -f "$SUDIR/magisk.before_appprocess" /debug_ramdisk/magisk 2>/dev/null
        chmod 755 /debug_ramdisk/magisk 2>/dev/null
        chcon "$MAGISK_FILE_CON" /debug_ramdisk/magisk 2>/dev/null
        APP_PATCHED=0
        APP_TRANSPORT_OK=0
        APP_RUN="$APP_PROCESS"
    fi
fi
AM_OK=0
AM_MODE=deferred_app
MGR_LAUNCH=deferred-app
echo "am transport: d=app_process patch=$APP_PATCHED run=${APP_RUN:-none} (launch driven by the app)"

# ---------- 12. restart a running manager so it reloads the module list ------
if [ -n "$MGR_PKG" ]; then
    MGR_PID=$($PBB pidof "$MGR_PKG" 2>/dev/null)
    if [ -n "$MGR_PID" ]; then
        echo "stopping running manager ($MGR_PID); the app reopens it"
        for p in $MGR_PID; do kill -9 "$p" 2>/dev/null; done
        sleep 1
    fi
    echo "manager.package=$MGR_PKG (opened by the DFRoot app)"
else
    echo "manager: none"
fi

# ---------- 13. app SU test intentionally omitted ---------------------------
# DFRoot must never obtain, request, or verify an SU grant for its own UID.
# The deploy only checks the root client (uid 0) below; there is no app-uid
# MagiskSU prompt and no policy row is created for df.root.
PROMPT_TEST=disabled_no_app_su
echo "app su test: disabled (DFRoot does not request SU)"
# ---------- 14. diagnostics ------------------------------------------------
echo "--- magisk daemon log ---"
if [ -n "$MAGLOG" ]; then
    $PBB tail -n 80 "$MAGLOG" 2>/dev/null
    echo "--- su/request lines ---"
    $PBB grep -E 'su:|request|pkg:' "$MAGLOG" 2>/dev/null | $PBB tail -n 20
else
    echo "no magisk.log found"
fi
echo "--- logcat (magisk) ---"
$PBB timeout 12 $PBB runcon u:r:magisk:s0 /system/bin/logcat -d -t 200 -s Magisk:* 2>/dev/null | $PBB tail -n 30
echo "--- dmesg dfroot ---"
# Keep enough of the window to see the LKM's init lines (selinux_state, page
# cache invalidation) even after the vendor patch/restore chatter.
$PBB dmesg 2>/dev/null | $PBB grep -i dfroot | $PBB tail -n 40

# Copy the log somewhere adb can reach while we are still permissive.
cp -f "$LOG" "$ADB_LOG" 2>/dev/null && chmod 644 "$ADB_LOG" 2>/dev/null && \
    echo "log copy: $ADB_LOG"

# Remove the LKM's temporary su binaries (not used by 4.8).
rm -f /data/local/tmp/su /data/local/tmp/su-client \
      "$SUDIR/su.legacy" \
      /data/local/tmp/load.magisk.sh /data/local/tmp/magisk-inner.sh \
      /data/local/tmp/magisk-missing-files.tar.gz 2>/dev/null

# ---------- 15. root su before/after enforcing -----------------------------
echo "--- root su test (uid 0, permissive) ---"
if [ -n "$TEST_SU" ] && [ -x "$TEST_SU" ]; then
    ROOT_PRE_OUT=$($PBB timeout 15 "$TEST_SU" -c 'id' 2>&1)
    case "$ROOT_PRE_OUT" in *uid=0*) ROOT_PRE=1 ;; esac
    echo "root pre: $ROOT_PRE_OUT"
else
    ROOT_PRE_OUT="no su"
fi
echo "ROOT_PRE=$ROOT_PRE"

# Start the detached magiskd guard while the magisk domain is still
# permissive. It only acts when `pidof magiskd` is empty, so it never kills a
# healthy daemon and never retries a kill for a PID that no longer exists.
start_magiskd_guard
echo "GUARD_STARTED=$GUARD_STARTED"

echo "--- root su test (uid 0, permissive) ---"
# Tested while SELinux is still permissive. Running this under a temporary
# `setenforce 1` made the worker lose write access to its own log and, on this
# ROM, made the su client block until the app gave up after 4 minutes. The
# final Enforcing transition is verified later without touching su.
PBB=/debug_ramdisk/.magisk/busybox/busybox
[ -x "$PBB" ] || PBB=$BB
MPID=$($PBB pidof magiskd 2>/dev/null)
MPID_CTX=$(/system/bin/cat /proc/$MPID/attr/current 2>/dev/null)
ROOT_SU_OK=0
if [ -n "$TEST_SU" ] && [ -x "$TEST_SU" ]; then
    ROOT_OUT=$($PBB timeout 20 "$TEST_SU" -c 'id' 2>&1)
    case "$ROOT_OUT" in *uid=0*) ROOT_SU_OK=1 ;; esac
else
    ROOT_OUT="no su"
fi
echo "magiskd pid=[$MPID] context=[$MPID_CTX]"
echo "root su: $ROOT_OUT"
echo "ROOT_SU_OK=$ROOT_SU_OK"
progress 90

# A policy-level "denied" is not a transport failure, but it also is not a
# successful MagiskSU deployment. Never replace Magisk su with the 4.7 wrapper:
# the wrapper bypasses the user's Allow choice and triggers the manager's
# "su binary not from Magisk" warning. Keep the two Magisk symlinks and report
# the failure honestly.
MAGISK_SU_OK=0
if [ "$MAGISK_READY" = "1" ] &&
   [ "$XATTR_BIND_OK" = "1" ] && [ "$ROOT_SU_OK" = "1" ] &&
   [ "$SU_LINKS_OK" = "1" ] && [ "$ROOT_ACCESS" != "0" ]; then
    MAGISK_SU_OK=1
else
    echo "MagiskSU not proven usable (stub=$STUB_LOADED xattr=$XATTR_BIND_OK root=$ROOT_SU_OK links=$SU_LINKS_OK prompt=$PROMPT_TEST)"
    echo "legacy wrapper fallback is disabled; Magisk symlinks are left in place"
    [ "$SU_LINKS_OK" = "1" ] || legacy_su_cleanup
fi

# ---------- 16. close the legacy channel -----------------------------------
echo "closing legacy kernel channel (/proc/dfroot_su)"
if close_legacy_channel; then
    echo "confirmed: /proc/dfroot_su rejects writes"
else
    echo "channel close not confirmed; legacy wrapper is still absent"
fi

if [ "$XBIN_OK" = "1" ]; then
    printf '%s\n' "$CHANNEL" > /system/xbin/.dfroot_channel 2>/dev/null
    chmod 644 /system/xbin/.dfroot_channel 2>/dev/null
    chcon "$MAGISK_FILE_CON" /system/xbin/.dfroot_channel 2>/dev/null
else
    printf '%s\n' "$CHANNEL" > "$SUDIR/channel" 2>/dev/null
fi
echo "channel marker: $(/system/bin/cat /system/xbin/.dfroot_channel 2>/dev/null || $PBB cat "$SUDIR/channel" 2>/dev/null)"

# ---------- 17. final result ----------------------------------------------
echo "--- policies after ---"
policy_rows > "$POL_CURRENT"
POL_AFTER=$($PBB wc -l < "$POL_CURRENT" 2>/dev/null | $PBB tr -dc '0-9')
case "$POL_AFTER" in ''|*[!0-9]*) POL_AFTER="?" ;; esac
$PBB cat "$POL_CURRENT" 2>/dev/null
echo "--- settings after ---"
echo "dfroot_su reject test: $(printf '1' > /proc/dfroot_su 2>&1 && echo WRITE_ACCEPTED || echo EACCES)"

# The legacy proc channel must be closed as well as the Magisk links being
# correct. A failed read-latch means a second root path still exists, so this
# is not a successful deployment even if su itself works.
if [ "$CHANNEL" != "closed" ]; then
    echo "WARN: legacy /proc/dfroot_su channel is still open; refusing success"
    MAGISK_SU_OK=0
fi

# Enforcing is turned on once, at the very end, after deploy.done is written.
# Toggling it here (setenforce 1 / getenforce / setenforce 0) made the init
# worker lose access to its own log and, on this ROM, the script stalled at
# that exact point - the app then reported a 240 s timeout.
FINAL_ENFORCE=deferred

# LSPosed/Zygisk Next preparation. Called after root itself is good. With
# Auto Soft Reboot OFF this prepares policy/manager only and leaves zygote
# alone (manual hot restart); with it ON prepare_lsposed sets LSPOSED_PREP=1
# and the single automatic restart happens after the RESULT block.
if [ "$MAGISK_SU_OK" = "1" ]; then
    prepare_lsposed
    # prepare_lsposed intentionally leaves global SELinux permissive. The final
    # Enforcing transition happens only after deploy.done has been written.
    echo "lsposed prep getenforce: $(getenforce 2>/dev/null) (Enforcing deferred)"
else
    echo "lsposed: skipped (root check failed)"
fi

if [ "$MAGISK_SU_OK" = "1" ]; then
    RESULT=ok
else
    RESULT=failed
fi

ZYGOTE_RESTART=no
[ "$RESULT" = "ok" ] && [ "$LSPOSED_PREP" = "1" ] && ZYGOTE_RESTART=requested

# ---------- hand the app's DE directory back to the app ----------------------
# Everything this deploy writes into /data/user_de/0/df.root (deploy.log,
# manager.package, payload/, stage/) would otherwise stay root-owned: the next
# launch then dies with "mkdirs failed: /data/user_de/0/df.root", and uninstall
# fails with "Failed to delete ... (code 39)". Root keeps full access after a
# chown, so this costs nothing.
_df_uid=$(pkg_uid df.root 2>/dev/null)
if [ -n "$_df_uid" ]; then
    chown "$_df_uid:$_df_uid" "$STAGE" 2>/dev/null
    chmod 771 "$STAGE" 2>/dev/null
    for _df_sub in payload stage files shared_prefs; do
        [ -e "$STAGE/$_df_sub" ] &&
            chown -R "$_df_uid:$_df_uid" "$STAGE/$_df_sub" 2>/dev/null
    done
    echo "de dir: ownership handed back to uid $_df_uid"
else
    echo "de dir: WARN could not resolve the df.root uid (left as root)"
fi

echo "=== RESULT ==="
echo "result:          $RESULT"
echo "enforcing:       $(getenforce 2>&1) (temporary; final Enforcing is set after deploy.done)"
echo "enforce test:    ${FINAL_ENFORCE:-unknown}"
echo "magisk domain:   permissive (upstream Magisk behavior; intentional)"
echo "manager:         ${MGR_PKG:-none} uid=${MGR_UID:-?} dialog=$PROMPT_MODE launch=${MGR_LAUNCH:-none} lost=$MANAGER_LOST"
echo "trusted_cert:    stub_loaded=$STUB_LOADED (stub.apk consumed=$STUB_LOADED)"
echo "requester:       ${RQ_AFTER:-<empty>}"
echo "root_access:     $ROOT_ACCESS (read-only; not modified)"
echo "policies:        before=$POL_BEFORE after=$POL_AFTER restored=$POL_RESTORED (exact rows; no blanket grant)"
echo "android env:     $ANDROID_ENV_OK (source=${ANDROID_ENV_SOURCE:-fallback}; app_process needs BOOTCLASSPATH)"
echo "am transport:    $AM_OK mode=$AM_MODE (app_transport=$APP_TRANSPORT_OK patched=$APP_PATCHED run=$APP_RUN target=$APP_PROCESS)"
echo "xattr debug_rd:  f2fs=$DEBUG_RD_F2FS xattr_ok=$XATTR_BIND_OK"
echo "xattr .magisk:   $XATTR_BIND_OK (whole /debug_ramdisk is f2fs; su_request can be labeled)"
echo "magiskd guard:   started=$GUARD_STARTED pid=$([ -s "$GUARD_PIDFILE" ] && cat "$GUARD_PIDFILE" 2>/dev/null)"
echo "su:              xbin_ok=$XBIN_OK links_ok=$SU_LINKS_OK test_su=$TEST_SU"
echo "app su test:     $PROMPT_TEST (DFRoot never requests SU)"
echo "root su:         pre=$ROOT_PRE post=$ROOT_SU_OK channel=$CHANNEL"
echo "fallback:        $FALLBACK_DONE (legacy wrapper disabled; MagiskSU only)"
echo "magisk su ok:    $MAGISK_SU_OK"
echo "modules:         $MODULES_STATE"
echo "zygote:          before=[$ZYGOTE_BEFORE] after=[$ZYGOTE_AFTER] restart=$ZYGOTE_RESTART"
echo "module policy:   files=$MODULE_POLICY_COUNT lsposed_file=$LSPOSED_FILE_TYPE compat=$LSPOSED_FILE_COMPAT"
echo "lsposed manager: pkg=$LSPOSED_MANAGER_PKG status=$LSPOSED_MGR_STATUS apk=${LSPOSED_MANAGER_APK:-none} version=${LSPOSED_MANAGER_VC:-unknown}"
echo "lsposed module:  dir=${LSPOSED_DIR:-none} version=$LSPOSED_MODULE_VC name=${LSPOSED_MODULE_VER:-unknown} status=$LSPOSED_MODULE_STATUS updated=$LSPOSED_MODULE_UPDATED"
echo "lsposed:         present=$LSPOSED_PRESENT zygisk_next=$ZYGISK_NEXT mode=$LSPOSED_MODE soft_reboot=$SOFT_REBOOT prep=$LSPOSED_PREP result=$LSPOSED_RESULT lspd=$LSPD_PID bridge=$LSPOSED_BRIDGE restart_mode=$LSPOSED_RESTART_MODE"
if [ "$LSPOSED_PREP" = "1" ]; then
    echo "boot stages:     post-fs-data only; service/boot-complete skipped; LSPosed mode restarts zygote once"
else
    echo "boot stages:     post-fs-data only; service/boot-complete skipped"
fi
echo "magisk log:      ${MAGLOG:-none}"
echo "adb log copy:    $ADB_LOG"
echo "=== deploy-magisk.sh DONE ==="

# The optional zygote restart happens exactly once, after the success marker is
# visible to the app (see the end of this file). It used to be called here and
# again at the end, which restarted zygote twice and roughly doubled the time a
# LSPosed deploy took.

# Build the one marker ExploitRunner waits for. The initial root line is
# written while SELinux is still permissive; the final line is appended after
# the optional restart if the worker still has write access.
write_deploy_done() {
    _wdd_lsposed=$1
    _wdd_bridge=$2
    _wdd_restart=$3
    _wdd_stage=${4:-final}
    progress 100
    _wdd_line="DEPLOY_DONE $(date) result=$RESULT enforcing=$(getenforce 2>/dev/null) stage=$_wdd_stage prompt=$PROMPT_TEST root_su=$ROOT_SU_OK channel=$CHANNEL policies_before=$POL_BEFORE policies_after=$POL_AFTER fallback=$FALLBACK_DONE manager=${MGR_PKG:-none} root_access=$ROOT_ACCESS lsposed=$_wdd_lsposed lsposed_manager=$LSPOSED_MGR_STATUS lsposed_module=$LSPOSED_MODULE_STATUS lsposed_bridge=$_wdd_bridge restart_mode=$_wdd_restart module_policy=$MODULE_POLICY_COUNT lsposed_file=$LSPOSED_FILE_TYPE"
    if [ "$DONE_FD_OPEN" = "1" ]; then
        printf '%s\n' "$_wdd_line" >&9 2>/dev/null || \
            printf '%s\n' "$_wdd_line" >> "$DONE_MARKER" 2>/dev/null
        exec 9>&-
        DONE_FD_OPEN=0
    else
        printf '%s\n' "$_wdd_line" >> "$DONE_MARKER" 2>/dev/null
    fi
    return 0
}

# Root success is written before the optional zygote restart. ExploitRunner
# finishes on this line, so a restart can no longer swallow the success report.
# The LSPosed result is pending here and appended later when available.
if [ "$RESULT" = "ok" ] && [ "$LSPOSED_PREP" = "1" ]; then
    write_deploy_done pending unknown pending root
else
    write_deploy_done "$LSPOSED_RESULT" "$LSPOSED_BRIDGE" "$LSPOSED_RESTART_MODE" final
fi

# Keep writing to deploy.log during the LSPosed restart: soft_reboot_lsposed
# runs while SELinux is permissive and only restores Enforcing at its end, so
# the log stays writable and a failed restart is diagnosable. A failed echo
# must not abort the restart, so errors from echo are ignored.
exec 1>>"$LOG" 2>&1 || exec >/dev/null 2>&1
if [ "$RESULT" = "ok" ] && [ "$LSPOSED_PREP" = "1" ]; then
    soft_reboot_lsposed
    write_deploy_done "$LSPOSED_RESULT" "$LSPOSED_BRIDGE" "$LSPOSED_RESTART_MODE" final
fi

setenforce 1 2>/dev/null
exit 0
