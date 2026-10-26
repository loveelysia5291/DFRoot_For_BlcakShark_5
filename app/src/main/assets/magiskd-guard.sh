#!/system/bin/sh
# DFRoot 4.8 detached magiskd guard.
#
# A late-loaded magiskd is not a boot service, so init will not restart it if
# another process kills it. This guard is launched by deploy-magisk.sh inside
# u:r:magisk:s0 (while that domain is still permissive) and is reparented to
# init with setsid. It only acts when `pidof magiskd` is EMPTY. It never tries
# to kill a process that is not present, and it never touches the daemon while
# the daemon is healthy.
#
# Restarting magiskd alone is not enough: trusted_cert lives only in daemon
# memory and is populated by --post-fs-data from /debug_ramdisk/stub.apk. If a
# bare daemon is started, Magisk's package check can treat the manager as a
# signature mismatch and uninstall it. Therefore a restart always seeds the
# stub, runs --post-fs-data once with the module directories VISIBLE (so Magisk
# can mount them), and hides only post-fs-data.d plus every module's
# post-fs-data.sh. Replaying those scripts after zygote is up is what made
# Zygisk Next restart zygote, so they are restored immediately afterwards.

export PATH=/debug_ramdisk:/system/xbin:/system/bin:/sbin:/vendor/bin
export MAGISKTMP=/debug_ramdisk
export SHELL=/system/bin/sh

SUDIR=/data/user_de/0/df.root
OLD_SUDIR=/data/adb/dfroot
MAGISK=/debug_ramdisk/magisk
FALLBACK_MAGISK=/data/adb/magisk/magisk
BB=/debug_ramdisk/.magisk/busybox/busybox
PIDFILE=$SUDIR/magiskd-guard.pid
LOG=$SUDIR/magiskd-guard.log
POL_BEFORE=$SUDIR/policies.guard.before
POL_AFTER=$SUDIR/policies.guard.after
STUB=/debug_ramdisk/stub.apk
MAGISK_FILE_CON=u:object_r:magisk_file:s0

BOOT_SCRIPT_SUFFIX=.dfroot_pfs_off
BOOT_PFSD_PREFIX=/data/adb/post-fs-data.d.dfroot_pfs_off
BOOT_SCRIPTS_OFF=0

log() {
    echo "$(date) $*" >> "$LOG" 2>/dev/null
}

have_bb() {
    [ -x "$BB" ] || BB=/data/adb/magisk/busybox
    [ -x "$BB" ]
}

pidof_magiskd() {
    have_bb && "$BB" pidof magiskd 2>/dev/null
}

# Avoid sending a signal to a PID that is no longer present.
kill_if_present() {
    for _p in $1; do
        case "$_p" in ''|*[!0-9]*) continue ;; esac
        kill -0 "$_p" 2>/dev/null || continue
        kill -9 "$_p" 2>/dev/null
    done
}

# Copy only when the MD5 differs. This keeps the manager APK in place across
# guard restarts and avoids rewriting it while it is being read.
copy_if_changed() {
    _cc_src=$1
    _cc_dst=$2
    _cc_mode=${3:-644}
    have_bb || return 1
    [ -f "$_cc_src" ] || return 1
    if [ -f "$_cc_dst" ]; then
        _cc_s=$("$BB" md5sum "$_cc_src" 2>/dev/null | "$BB" awk '{print $1}')
        _cc_d=$("$BB" md5sum "$_cc_dst" 2>/dev/null | "$BB" awk '{print $1}')
        if [ -n "$_cc_s" ] && [ "$_cc_s" = "$_cc_d" ]; then
            chmod "$_cc_mode" "$_cc_dst" 2>/dev/null
            return 0
        fi
    fi
    cp -f "$_cc_src" "$_cc_dst" 2>/dev/null || return 1
    chmod "$_cc_mode" "$_cc_dst" 2>/dev/null
    log "copied $("$BB" basename "$_cc_src") -> $_cc_dst"
    return 0
}

import_android_env() {
    _z=""
    have_bb || return 0
    for _name in zygote64 zygote; do
        _z=$("$BB" pidof "$_name" 2>/dev/null | "$BB" awk '{print $1; exit}')
        [ -n "$_z" ] && break
    done
    if [ -n "$_z" ] && [ -r "/proc/$_z/environ" ]; then
        _env=/data/local/tmp/dfroot.guard.env.$$
        if "$BB" tr '\0' '\n' < "/proc/$_z/environ" > "$_env" 2>/dev/null; then
            while IFS= read -r _kv; do
                case "$_kv" in
                    ANDROID_ROOT=*|ANDROID_DATA=*|ANDROID_ART_ROOT=*| \
                    ANDROID_RUNTIME_ROOT=*|ANDROID_I18N_ROOT=*| \
                    ANDROID_TZDATA_ROOT=*|ANDROID_ASSETS=*|ANDROID_STORAGE=*| \
                    ASEC_MOUNTPOINT=*|EXTERNAL_STORAGE=*|BOOTCLASSPATH=*| \
                    DEX2OATBOOTCLASSPATH=*|SYSTEMSERVERCLASSPATH=*| \
                    STANDALONE_SYSTEMSERVER_JARS=*)
                        export "$_kv"
                        ;;
                esac
            done < "$_env"
        fi
        rm -f "$_env" 2>/dev/null
    fi
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
}

# Restore one renamed path. Never overwrite a path that the system has
# re-created: leave a non-empty directory untouched and keep the old backup.
# Only remove an empty system-created directory, since it has no data.
restore_one_module() {
    _m=$1
    _off="/data/adb/$_m.dfroot_off"
    [ -e "$_off" ] || return 0
    if [ ! -e "/data/adb/$_m" ]; then
        mv "$_off" "/data/adb/$_m" 2>/dev/null && \
            log "modules restored: /data/adb/$_m"
    elif [ -d "/data/adb/$_m" ] && \
         [ -z "$("$BB" ls -A "/data/adb/$_m" 2>/dev/null)" ]; then
        rmdir "/data/adb/$_m" 2>/dev/null && \
            mv "$_off" "/data/adb/$_m" 2>/dev/null && \
            log "modules restored: /data/adb/$_m (removed empty system-created dir)"
    else
        log "kept system-created /data/adb/$_m; not overwriting (backup remains $_off)"
    fi
}

restore_one_boot_script() {
    _rbs=$1
    [ -e "$_rbs" ] || return 0
    _rbs_dir=${_rbs%/*}
    _rbs_name=${_rbs##*/}
    _rbs_name=${_rbs_name%%.dfroot_pfs_off*}
    _rbs_dst="$_rbs_dir/$_rbs_name"
    if [ ! -e "$_rbs_dst" ]; then
        mv "$_rbs" "$_rbs_dst" 2>/dev/null && \
            log "restored boot script: $_rbs_dst"
    else
        log "kept $_rbs_dst; backup remains $_rbs"
    fi
}

restore_module_scripts() {
    have_bb || return 0
    for _rms_base in /data/adb/modules /data/adb/modules_update; do
        [ -d "$_rms_base" ] || continue
        for _rms in "$_rms_base"/*/post-fs-data.sh.dfroot_pfs_off*; do
            [ -e "$_rms" ] || continue
            restore_one_boot_script "$_rms"
        done
    done
}

restore_pfsd_backups() {
    have_bb || return 0
    for _rpb in "$BOOT_PFSD_PREFIX"* /data/adb/post-fs-data.d.dfroot_off; do
        [ -e "$_rpb" ] || continue
        if [ ! -e /data/adb/post-fs-data.d ]; then
            mv "$_rpb" /data/adb/post-fs-data.d 2>/dev/null && \
                log "restored /data/adb/post-fs-data.d"
        elif [ -d /data/adb/post-fs-data.d ] && \
             [ -z "$("$BB" ls -A /data/adb/post-fs-data.d 2>/dev/null)" ]; then
            rmdir /data/adb/post-fs-data.d 2>/dev/null && \
                mv "$_rpb" /data/adb/post-fs-data.d 2>/dev/null && \
                log "restored /data/adb/post-fs-data.d (removed empty dir)"
        else
            log "kept /data/adb/post-fs-data.d; backup remains $_rpb"
        fi
    done
}

restore_boot_scripts() {
    restore_module_scripts
    restore_pfsd_backups
    BOOT_SCRIPTS_OFF=0
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
    log "could not suppress $_hbs"
    return 1
}

# Keep module directories visible so Magisk mounts them. Hide only boot-time
# scripts for this one post-fs-data pass; Zygisk Next's post-fs-data.sh is the
# script that calls ctl.restart zygote when it starts after zygote.
hide_boot_scripts() {
    have_bb || return 1
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
            log "boot scripts hidden: /data/adb/post-fs-data.d -> $_hbs_pfsd"
        else
            log "could not hide /data/adb/post-fs-data.d"
            _hbs_fail=1
        fi
    fi
    for _hbs_base in /data/adb/modules /data/adb/modules_update; do
        [ -d "$_hbs_base" ] || continue
        for _hbs_d in "$_hbs_base"/*; do
            [ -d "$_hbs_d" ] || continue
            hide_one_boot_script "$_hbs_d/post-fs-data.sh" || _hbs_fail=1
        done
    done
    log "boot scripts suppressed=$BOOT_SCRIPTS_OFF (modules remain visible)"
    [ "$_hbs_fail" = "0" ]
}

recover_stale_modules() {
    have_bb || return 0
    # Remove a stale disposable tmpfs from an old experimental build before
    # deciding whether a .dfroot_off backup can be restored.
    for _rm_m in modules modules_update post-fs-data.d; do
        if "$BB" grep -q " /data/adb/$_rm_m " /proc/mounts 2>/dev/null; then
            umount -l "/data/adb/$_rm_m" 2>/dev/null && \
                log "removed stale module mount: /data/adb/$_rm_m"
        fi
    done
    restore_one_module modules
    restore_one_module modules_update
    restore_pfsd_backups
    restore_module_scripts
}

seed_stub() {
    _src=""
    for _c in "$SUDIR/manager.apk" "$OLD_SUDIR/manager.apk"; do
        [ -s "$_c" ] && { _src=$_c; break; }
    done
    [ -n "$_src" ] || {
        log "stub seed failed: no manager.apk"
        return 1
    }
    if copy_if_changed "$_src" "$STUB" 644 && [ -s "$STUB" ]; then
        chcon "$MAGISK_FILE_CON" "$STUB" 2>/dev/null
        log "stub ready from $_src (md5 checked)"
        return 0
    fi
    log "stub seed copy failed: $_src"
    return 1
}

start_daemon() {
    rm -f /debug_ramdisk/.magisk/device/socket 2>/dev/null
    [ -x "$MAGISK" ] || MAGISK=$FALLBACK_MAGISK
    [ -x "$MAGISK" ] || {
        log "magisk binary missing"
        return 1
    }
    "$MAGISK" --daemon &
    _i=0
    while [ "$_i" -lt 15 ]; do
        [ -n "$(pidof_magiskd)" ] && return 0
        sleep 1
        _i=$((_i + 1))
    done
    log "magiskd did not start"
    return 1
}

wait_client() {
    _i=0
    while [ "$_i" -lt 15 ]; do
        "$MAGISK" -V >/dev/null 2>&1 && return 0
        sleep 1
        _i=$((_i + 1))
    done
    return 1
}

policy_rows() {
    "$MAGISK" --sqlite 'SELECT uid,policy,until,logging,notification FROM policies;' 2>/dev/null \
        | "$BB" awk -F'|' '
            NF >= 5 {
                for (i = 1; i <= 5; i++) sub(/^[^=]*=/, "", $i)
                if ($1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^-?[0-9]+$/ &&
                    $4 ~ /^[0-9]+$/ && $5 ~ /^[0-9]+$/)
                    print $1 "|" $2 "|" $3 "|" $4 "|" $5
            }'
}

snapshot_policies() {
    policy_rows > "$POL_BEFORE" 2>/dev/null
}

restore_missing_policies() {
    [ -s "$POL_BEFORE" ] || return 0
    have_bb || return 0
    policy_rows > "$POL_AFTER" 2>/dev/null
    "$BB" awk -F'|' '{print $1}' "$POL_AFTER" > "$SUDIR/policies.guard.uids" 2>/dev/null
    while IFS='|' read -r _uid _policy _until _log _notify; do
        [ -n "$_uid" ] && [ -n "$_policy" ] && [ -n "$_until" ] && \
            [ -n "$_log" ] && [ -n "$_notify" ] || continue
        case "$_uid$_policy$_log$_notify" in *[!0-9]*) continue ;; esac
        case "$_until" in
            -*) _digits=${_until#-} ;;
            *) _digits=$_until ;;
        esac
        [ -n "$_digits" ] || continue
        case "$_digits" in *[!0-9]*) continue ;; esac
        "$BB" grep -qx "$_uid" "$SUDIR/policies.guard.uids" 2>/dev/null && continue
        if [ "$_uid" -ge 10000 ] 2>/dev/null; then
            if ! "$BB" awk -v u="$_uid" '$2 == u { found=1 } END { exit !found }' \
                 /data/system/packages.list 2>/dev/null; then
                _installed=0
                for _d in /data/user_de/*/* /data/user/*/*; do
                    [ -d "$_d" ] || continue
                    _du=$("$BB" stat -c %u "$_d" 2>/dev/null)
                    [ "$_du" = "$_uid" ] && { _installed=1; break; }
                done
                [ "$_installed" = "1" ] || continue
            fi
        fi
        if "$MAGISK" --sqlite "INSERT OR REPLACE INTO policies(uid,policy,until,logging,notification) \
             VALUES($_uid,$_policy,$_until,$_log,$_notify);" >/dev/null 2>&1; then
            log "policy restored uid=$_uid"
        fi
    done < "$POL_BEFORE"
}

reset_bootloop() {
    "$MAGISK" --sqlite \
        "INSERT OR REPLACE INTO settings(key,value) VALUES('bootloop',0);" \
        >/dev/null 2>&1
}

restart_daemon() {
    [ -n "$(pidof_magiskd)" ] && return 0
    recover_stale_modules
    seed_stub || return 1
    # Suppress boot scripts BEFORE starting the daemon. Module directories
    # stay visible so the daemon's --post-fs-data can mount them.
    if ! hide_boot_scripts; then
        log "could not suppress every boot script; refusing post-fs-data to protect zygote"
        restore_boot_scripts
        return 1
    fi
    _zyg_before=$("$BB" pidof zygote64 2>/dev/null)
    [ -n "$_zyg_before" ] || _zyg_before=$("$BB" pidof zygote 2>/dev/null)
    import_android_env
    if ! start_daemon; then
        restore_boot_scripts
        return 1
    fi
    if ! wait_client; then
        log "magiskd client did not become ready"
        _p=$(pidof_magiskd)
        [ -n "$_p" ] && kill_if_present "$_p"
        restore_boot_scripts
        return 1
    fi
    snapshot_policies
    "$MAGISK" --post-fs-data >/dev/null 2>&1
    _rc=$?
    sleep 1
    # Restore immediately after the single controlled pass.
    restore_boot_scripts
    # setup_magisk_env() may call restorecon(), and the label on the f2fs
    # .magisk directory is what lets the manager (and the app) traverse the su
    # request FIFO. Re-apply the Magisk label after the boot stage.
    chcon -R "$MAGISK_FILE_CON" /debug_ramdisk/.magisk 2>/dev/null
    chcon "$MAGISK_FILE_CON" /debug_ramdisk/magisk 2>/dev/null

    _zyg_after=$("$BB" pidof zygote64 2>/dev/null)
    [ -n "$_zyg_after" ] || _zyg_after=$("$BB" pidof zygote 2>/dev/null)
    log "zygote before=[$_zyg_before] after=[$_zyg_after]"

    if [ -e "$STUB" ]; then
        # post-fs-data did not reach preserve_stub_apk(). Leave no daemon with
        # an empty trusted_cert: that is exactly the state that can make the
        # manager look like a signature mismatch. Retry on the next loop.
        log "post-fs-data did not consume stub (rc=$_rc)"
        _p=$(pidof_magiskd)
        [ -n "$_p" ] && kill_if_present "$_p"
        return 1
    fi

    restore_missing_policies
    reset_bootloop

    # Restore requester for hidden manager if manager.package exists
    if [ -f "$SUDIR/manager.package" ]; then
        _g_mgr=$("$BB" head -n1 "$SUDIR/manager.package" 2>/dev/null | "$BB" tr -d ' \r\n')
        if [ -n "$_g_mgr" ] && [ "$_g_mgr" != "com.topjohnwu.magisk" ]; then
            "$MAGISK" --sqlite "INSERT OR REPLACE INTO strings(key,value) VALUES('requester','$_g_mgr');" >/dev/null 2>&1
        fi
    fi

    log "magiskd restarted; trusted_cert loaded; modules visible with boot scripts suppressed"
    return 0
}

# ---------------------------------------------------------------------------
have_bb || exit 1
cd /
cleanup_on_exit() {
    restore_boot_scripts
    if [ "$(cat "$PIDFILE" 2>/dev/null)" = "$$" ]; then
        rm -f "$PIDFILE" 2>/dev/null
    fi
}
trap cleanup_on_exit EXIT INT TERM HUP
echo $$ > "$PIDFILE"
chmod 600 "$PIDFILE" 2>/dev/null
log "guard started pid=$$ context=$(/system/bin/cat /proc/self/attr/current 2>/dev/null)"

while :; do
    if [ ! -x /debug_ramdisk/magisk ] || [ ! -d /debug_ramdisk/.magisk ]; then
        log "debug_ramdisk disappeared; guard exiting"
        break
    fi
    if [ -z "$(pidof_magiskd)" ]; then
        log "magiskd absent; restarting"
        if ! restart_daemon; then
            log "restart failed; retrying in 10s"
        fi
    fi
    sleep 10
done
