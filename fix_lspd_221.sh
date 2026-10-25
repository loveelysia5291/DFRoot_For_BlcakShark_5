#!/system/bin/sh
# Manual LSPosed 2.2.1 activation using the full module already installed in
# /data/adb/modules/zygisk_lsposed. DFRoot no longer bundles the module tar.
#
# Run on the phone as root:
#   su -c 'sh /sdcard/Download/fix_lspd_221.sh'
#
# This is the manual equivalent of DFRoot's AUTO LSPosed sequence. It stops
# every old lspd/daemon supervisor and the old Zygisk Next injector, starts
# Zygisk Next, starts exactly one fresh lspd, restarts zygote once, and waits
# for the LSPosed binder bridge.

PATH=/system/bin:/system/xbin:/vendor/bin:/data/adb/magisk:$PATH
export PATH

MODDIR=/data/adb/modules/zygisk_lsposed
ZYGISKDIR=/data/adb/modules/zygisksu
LOGDIR=/data/adb/lspd/log
APP_PROCESS=/system/bin/app_process
[ -x /system/bin/app_process64 ] && APP_PROCESS=/system/bin/app_process64
SETSID=/system/bin/setsid
[ -x "$SETSID" ] || SETSID=setsid

say() { echo "[*] $*"; }
die() { echo "ERROR: $*"; exit 1; }

FIX_REV=2026-10-22-zombie-cmdline

proc_state() {
    awk '{print $3}' "/proc/$1/stat" 2>/dev/null
}

proc_alive() {
    [ -d "/proc/$1" ] || return 1
    [ "$(proc_state "$1")" = "Z" ] && return 1
    return 0
}

dump_lspd() {
    for PID in "$@"; do
        echo "  pid=$PID comm=$(cat "/proc/$PID/comm" 2>/dev/null) state=$(proc_state "$PID") cmd=$(cat "/proc/$PID/cmdline" 2>/dev/null | tr '\0' ' ')"
    done
}

# Only live lspd workers; a killed worker can stay visible as a zombie for a
# short time, and counting that zombie makes a healthy single lspd look like a
# duplicate.
lspd_pids() {
    for d in /proc/[0-9]*; do
        PID=${d#/proc/}
        [ -r "$d/comm" ] || continue
        if [ "$(cat "$d/comm" 2>/dev/null)" != "lspd" ]; then
            CMD=$(cat "$d/cmdline" 2>/dev/null | tr '\0' ' ')
            case "$CMD" in
                lspd|lspd\ *) ;;
                *) continue ;;
            esac
        fi
        [ "$(proc_state "$PID")" = "Z" ] && continue
        echo "$PID"
    done
}

# Every live LSPosed worker and its daemon/service supervisor. Killing only
# lspd leaves `daemon --force` alive; a later service.sh call can then start a
# second lspd (the dex2oat "Address already in use" failure).
lsposed_pids() {
    for d in /proc/[0-9]*; do
        PID=${d#/proc/}
        case "$PID" in ''|*[!0-9]*) continue ;; esac
        [ "$PID" = "$$" ] && continue
        [ -r "$d/comm" ] || continue
        COMM=$(cat "$d/comm" 2>/dev/null)
        if [ "$COMM" = "lspd" ]; then
            [ "$(proc_state "$PID")" = "Z" ] || echo "$PID"
            continue
        fi
        CMD=$(cat "$d/cmdline" 2>/dev/null | tr '\0' ' ')
        case "$CMD" in
            *zygisk_lsposed/daemon*|*zygisk_lsposed/lspd*|*zygisk_lsposed/service.sh*|*lsposed-daemon*|*org.lsposed.lspd.Main*|*daemon.apk*)
                [ "$(proc_state "$PID")" = "Z" ] || echo "$PID"
                ;;
        esac
    done
}

stop_lsposed_all() {
    i=0
    while [ "$i" -lt 4 ]; do
        PIDS=$(lsposed_pids; lspd_pids)
        [ -n "$PIDS" ] || return 0
        echo "  stopping: $(echo $PIDS)"
        for PID in $PIDS; do
            proc_alive "$PID" && kill "$PID" 2>/dev/null
        done
        sleep 1
        i=$((i + 1))
    done
    PIDS=$(lsposed_pids; lspd_pids)
    [ -n "$PIDS" ] || return 0
    for PID in $PIDS; do
        proc_alive "$PID" && kill -9 "$PID" 2>/dev/null
    done
    i=0
    while [ "$i" -lt 6 ]; do
        sleep 1
        [ -z "$(lsposed_pids; lspd_pids)" ] && return 0
        i=$((i + 1))
    done
    [ -z "$(lsposed_pids; lspd_pids)" ]
}

wait_single_lspd() {
    i=0
    while [ "$i" -lt 20 ]; do
        sleep 1
        set -- $(lspd_pids)
        if [ "$#" -eq 1 ]; then
            _ws_pid=$1
            sleep 2
            if [ "$(lspd_pids)" = "$_ws_pid" ] && [ -d "/proc/$_ws_pid" ]; then
                LSPD_PID=$_ws_pid
                return 0
            fi
        elif [ "$#" -gt 1 ]; then
            echo "  multiple lspd workers: $*"
            dump_lspd "$@"
            return 2
        fi
        i=$((i + 1))
    done
    return 1
}

start_lspd_once() {
    $SETSID nsenter -t 1 -m -- /system/bin/sh -c "
        cd '$MODDIR' || exit 1
        export $BOOTCP
        [ -n '$DEX2OAT' ] && export $DEX2OAT
        export PATH=$PATH
        exec '$APP_PROCESS' -Djava.class.path='$MODDIR/daemon.apk' -Xnoimage-dex2oat /system/bin --nice-name=lspd org.lsposed.lspd.Main
    " </dev/null >/dev/null 2>&1 &
}

[ "$(id -u 2>/dev/null)" = "0" ] || die "run as root"
say "fix revision: $FIX_REV (live lspd via comm, zombies excluded)"
[ -f "$MODDIR/module.prop" ] || die "LSPosed module is not installed"
[ -f "$ZYGISKDIR/module.prop" ] || die "Zygisk Next is not installed"
[ -f "$MODDIR/daemon.apk" ] || die "LSPosed daemon.apk is missing"

MODULE_VC=$(sed -n 's/^versionCode=//p' "$MODDIR/module.prop" 2>/dev/null | head -1)
say "LSPosed module versionCode=${MODULE_VC:-unknown} ($MODDIR)"
[ "$MODULE_VC" = "7930" ] || die "module is not 2.2.1 (7930); install the full LSPosed 2.2.1 module first"
[ -x "$MODDIR/lspctl" ] || die "module is incomplete (lspctl missing); install the full module first"
MGR_VC=$(dumpsys package org.lsposed.manager 2>/dev/null \
    | sed -n 's/.*versionCode=\([0-9][0-9]*\).*/\1/p' | head -1)
say "LSPosed manager versionCode=${MGR_VC:-unknown}"
[ "$MGR_VC" = "7930" ] || die "manager is not 2.2.1 (7930); install the matching LSPosed manager"

rm -f /data/local/tmp/daemon.apk /data/local/tmp/manager.apk 2>/dev/null
say "[1] stopping old lspd and daemon/service supervisors"
stop_lsposed_all || die "could not stop all lspd/daemon supervisors"
[ -z "$(lspd_pids)" ] || die "lspd survived the stop; refusing to start a duplicate"
say "  no lspd/daemon supervisor remains"
sleep 1

say "[2] stopping old Zygisk Next injector (needed after module update)"
for PID in $(ps -A -o PID 2>/dev/null); do
    case "$PID" in ''|*[!0-9]*) continue ;; esac
    [ "$PID" = "$$" ] && continue
    EXE=$(readlink "/proc/$PID/exe" 2>/dev/null)
    case "$EXE" in
        *zygisksu*)
            kill -9 "$PID" 2>/dev/null && echo "  killed zygisk pid=$PID ($EXE)"
            ;;
    esac
done
sleep 1

say "[3] reading live zygote environment"
ZPID=$(ps -A -o PID,NAME 2>/dev/null | awk '$2 == "zygote64" {print $1; exit}')
[ -n "$ZPID" ] || die "zygote64 not found"
BOOTCP=$(cat "/proc/$ZPID/environ" 2>/dev/null | tr '\0' '\n' | grep '^BOOTCLASSPATH=' | head -1)
DEX2OAT=$(cat "/proc/$ZPID/environ" 2>/dev/null | tr '\0' '\n' | grep '^DEX2OATBOOTCLASSPATH=' | head -1)
[ -n "$BOOTCP" ] || die "BOOTCLASSPATH not found in zygote"
say "  zygote64 PID=$ZPID BOOTCLASSPATH=${#BOOTCP} chars"

say "[4] clearing Zygisk Next module cache"
mkdir -p /data/adb/zygisksu
[ -f /data/adb/zygisksu/znctx ] && mv -f /data/adb/zygisksu/znctx /data/adb/zygisksu/znctx.old
[ -f /data/adb/zygisksu/modules_info ] && mv -f /data/adb/zygisksu/modules_info /data/adb/zygisksu/modules_info.old

say "[5] starting Zygisk Next via post-fs-data.sh"
if [ -x /system/bin/nsenter ]; then
    ( unset ZYGISK_ENABLED
      $SETSID /system/bin/nsenter -t 1 -m -- /system/bin/sh "$ZYGISKDIR/post-fs-data.sh" ) \
        >/dev/null 2>&1 &
else
    ( unset ZYGISK_ENABLED
      cd "$ZYGISKDIR" && /system/bin/sh ./post-fs-data.sh ) >/dev/null 2>&1 &
fi
i=0
ZN_PID=""
while [ "$i" -lt 45 ]; do
    sleep 1
    for PID in $(ps -A -o PID 2>/dev/null); do
        case "$PID" in ''|*[!0-9]*) continue ;; esac
        EXE=$(readlink "/proc/$PID/exe" 2>/dev/null)
        case "$EXE" in
            *zygisksu/bin/zygiskd*) ZN_PID=$PID; break 2 ;;
        esac
    done
    i=$((i + 1))
done
if [ -z "$ZN_PID" ]; then
    say "  post-fs-data did not start zygiskd; trying direct daemon"
    cd "$ZYGISKDIR" || die "cannot cd $ZYGISKDIR"
    ./bin/zygiskd daemon >/dev/null 2>&1 &
    sleep 5
    for PID in $(ps -A -o PID 2>/dev/null); do
        case "$PID" in ''|*[!0-9]*) continue ;; esac
        EXE=$(readlink "/proc/$PID/exe" 2>/dev/null)
        case "$EXE" in
            *zygisksu/bin/zygiskd*) ZN_PID=$PID; break ;;
        esac
    done
fi
[ -n "$ZN_PID" ] || die "Zygisk Next daemon did not start"
say "  zygiskd PID=$ZN_PID"
ps -A -o PID,NAME 2>/dev/null | grep -i zygisk | head -10

say "[6] starting Zygisk Next service-stage"
if [ -x /system/bin/nsenter ]; then
    ( unset ZYGISK_ENABLED
      /system/bin/nsenter -t 1 -m -- /system/bin/sh "$ZYGISKDIR/service.sh" ) >/dev/null 2>&1
else
    ( unset ZYGISK_ENABLED
      cd "$ZYGISKDIR" && /system/bin/sh ./service.sh ) >/dev/null 2>&1
fi
sleep 5
i=0
while [ "$i" -lt 15 ]; do
    [ -s /data/adb/zygisksu/modules_info ] && break
    sleep 1
    i=$((i + 1))
done
if [ -s /data/adb/zygisksu/modules_info ]; then
    echo "  modules_info refreshed"
else
    echo "  WARN: modules_info not present yet"
fi

say "[7] clearing old LSPosed state"
rm -f /data/adb/lspd/monitor /data/adb/lspd/lock /data/adb/lspd/manager.apk 2>/dev/null

OLD_SS=$(ps -A -o PID,NAME 2>/dev/null | awk '$2 == "system_server" {print $1; exit}')
say "[8] old system_server PID=${OLD_SS:-none}"

say "[9] starting fresh lspd from $MODDIR"
set -- $(lspd_pids)
if [ "$#" -ne 0 ]; then
    say "  unexpected lspd before start: $*; stopping all first"
    stop_lsposed_all || die "could not stop leftover lspd before start"
fi
LSPD_PID=""
start_lspd_once
wait_single_lspd
RC=$?
if [ "$RC" != "0" ]; then
    say "  lspd was not a single stable process; stopping all and retrying once"
    stop_lsposed_all || die "could not stop duplicate lspd/daemon supervisors"
    start_lspd_once
    wait_single_lspd || die "lspd did not start as exactly one stable process"
fi
say "  lspd PID=$LSPD_PID (single, stable)"
setenforce 1 2>/dev/null
say "  SELinux=$(getenforce 2>/dev/null) before zygote restart"

say "[10] killing zygote64 PID=$ZPID"
kill -9 "$ZPID"
[ -n "$OLD_SS" ] && {
    i=0
    while [ "$i" -lt 15 ]; do
        sleep 1
        kill -0 "$OLD_SS" 2>/dev/null || { echo "  old system_server exited (${i}s)"; break; }
        i=$((i + 1))
    done
}

say "[11] waiting for new system_server"
SSPID=""
i=0
while [ "$i" -lt 30 ]; do
    sleep 1
    NEW_SS=$(ps -A -o PID,NAME 2>/dev/null | awk '$2 == "system_server" {print $1; exit}')
    if [ -n "$NEW_SS" ] && [ "$NEW_SS" != "$OLD_SS" ]; then
        SSPID=$NEW_SS
        echo "  new system_server PID=$SSPID (${i}s)"
        break
    fi
    i=$((i + 1))
done
[ -n "$SSPID" ] || die "new system_server did not start"

NEW_ZPID=$(ps -A -o PID,NAME 2>/dev/null | awk '$2 == "zygote64" {print $1; exit}')
say "[12] new zygote64 PID=${NEW_ZPID:-unknown}"

say "[13] waiting for LSPosed binder bridge (max 60s)"
BRIDGE=""
i=0
while [ "$i" -lt 60 ]; do
    sleep 1
    LATEST=$(ls -t "$LOGDIR"/verbose_*.log 2>/dev/null | head -1)
    if [ -n "$LATEST" ]; then
        BRIDGE=$(grep 'binder received' "$LATEST" 2>/dev/null | grep "$SSPID" | tail -1)
        if [ -n "$BRIDGE" ]; then
            echo "  bridge established (${i}s)"
            echo "  $BRIDGE"
            break
        fi
    fi
    i=$((i + 1))
done

if [ -z "$BRIDGE" ]; then
    # Same guarded recovery as DFRoot AUTO: one new system_server makes
    # zygote re-fork after Zygisk Next is already active. Do it once only.
    OLD_SS2=$SSPID
    say "[13b] no bridge; forcing one system_server refork"
    setenforce 0 2>/dev/null
    kill -9 "$OLD_SS2" 2>/dev/null
    setenforce 1 2>/dev/null
    SSPID=""
    i=0
    while [ "$i" -lt 30 ]; do
        sleep 1
        NEW_SS=$(ps -A -o PID,NAME 2>/dev/null | awk '$2 == "system_server" {print $1; exit}')
        if [ -n "$NEW_SS" ] && [ "$NEW_SS" != "$OLD_SS2" ]; then
            SSPID=$NEW_SS
            echo "  new system_server PID=$SSPID (${i}s)"
            break
        fi
        i=$((i + 1))
    done
    [ -n "$SSPID" ] || die "new system_server did not start after refork"
    i=0
    while [ "$i" -lt 30 ]; do
        sleep 1
        LATEST=$(ls -t "$LOGDIR"/verbose_*.log 2>/dev/null | head -1)
        if [ -n "$LATEST" ]; then
            BRIDGE=$(grep 'binder received' "$LATEST" 2>/dev/null | grep "$SSPID" | tail -1)
            if [ -n "$BRIDGE" ]; then
                echo "  bridge established after refork (${i}s)"
                echo "  $BRIDGE"
                break
            fi
        fi
        i=$((i + 1))
    done
fi
setenforce 1 2>/dev/null

say "[14] final state"
LSPD_PID=$(lspd_pids | head -1)
LSPD_COUNT=$(lspd_pids | wc -l | tr -d ' ')
echo "  lspd=${LSPD_PID:-DEAD} count=$LSPD_COUNT zygote64=${NEW_ZPID:-?} system_server=${SSPID:-?}"
echo "  monitor=$(cat /data/adb/lspd/monitor 2>/dev/null)"
[ -n "$BRIDGE" ] && rm -f /data/user_de/0/df.root/lsposed.zygisk.reload 2>/dev/null

if [ -n "$BRIDGE" ] && [ "$LSPD_COUNT" = "1" ]; then
    echo "=== LSPosed 2.2.1 manual activation OK ==="
else
    echo "=== LSPosed activation FAILED; collect debug-lsposed.sh ==="
    exit 1
fi
