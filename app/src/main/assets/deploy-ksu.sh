#!/system/bin/sh
# =============================================================================
# DFRoot -> KernelSU late-load deployment (Black Shark 5, SHARK PAR-H0)
# kernel 4.19.113-perf, non-GKI, RAM-only. Slim fast path: the proven DFRoot
# exploit + root LKM are unchanged; only the KSU backend is loaded.
#
# Staged payloads (the Runner stages the self-built module from APK assets and
# extracts ksud from the installed manager; no ksud is bundled in the APK):
#   STAGE/ksu.ko        -> self-built 4.19 module, chosen by the Runner to pair
#                           with the extracted ksud UAPI (uapi5 / uapi6 image)
#   STAGE/ksud          -> ksud binary extracted from the installed manager
#                           (md5 + UAPI cached in ksu-cache.props)
#
# Manager identity comes from the kernel signature crown; the persisted list,
# SELinux enforcing restore and the manager restart are all owned by KSU/ksud.
# This script installs ksud, loads the module and spawns late-load only.
#
# The worker looks for STAGE/deploy-magisk.sh (legacy name kept to match the
# hardcoded path in libcxx.S); the Runner stages this file under that name.
# =============================================================================

export PATH=/debug_ramdisk:/system/xbin:/system/bin:/sbin:/vendor/bin
export SHELL=/system/bin/sh

STAGE=/data/user_de/0/df.root
PREFS=$STAGE/shared_prefs/dfroot.xml
DONE_MARKER=$STAGE/deploy.done
MIRROR_DONE=/data/local/tmp/ksu-deploy.done

ADBDIR=/data/adb/ksu
KSUD_INSTALL=/data/adb/ksud
KSUKO=$STAGE/ksu.ko
KSUD=$STAGE/ksud

RESULT=failed

progress() {
    echo "PROGRESS $1"
}

log() {
    echo "[ksu] $@"
}

# Inherit zygote environ (BOOTCLASSPATH etc.) so ksud can start; the root
# worker otherwise runs with a minimal env.
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

# Completion signal only (not a log). The Runner polls this marker to finish.
mark_done() {
    _line="DEPLOY_DONE $(date) result=$RESULT"
    echo "$_line" >> "$MIRROR_DONE" 2>/dev/null
    echo "$_line" >> "$DONE_MARKER" 2>/dev/null
    cp -f "$MIRROR_DONE" "$DONE_MARKER" 2>/dev/null
}

trap 'mark_done; exit 1' EXIT INT TERM

log "=== deploy-ksu.sh start pid=$$ date=$(date) ==="
log "DEPLOY_BUILD=offfix47 no-bundle-ksud uapi-cache dual-ko-bucket manager-extract-only"

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
    [ -z "$MGR_PKG" ] && MGR_PKG=$(sed -n 's/.*name="su_manager">\(.*\)<\/string>.*/\1/p' "$PREFS" 2>/dev/null | head -n1)
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

# ---- install ksud under /data/adb ------------------------------------------
mkdir -p "$ADBDIR/lib" /data/adb/modules 2>/dev/null

cp -f "$KSUD" "$KSUD_INSTALL" 2>/dev/null
chmod 0755 "$KSUD_INSTALL" 2>/dev/null
chown 0:0 "$KSUD_INSTALL" 2>/dev/null
chcon u:object_r:system_file:s0 "$KSUD_INSTALL" 2>/dev/null
[ -x "$KSUD_INSTALL" ] || { log "FATAL: ksud not executable after install"; exit 1; }
log "ksud installed -> $KSUD_INSTALL"

progress 60

# ---- load the KernelSU module -----------------------------------------------
# No defer_enforcing: SELinux enforcing restore is left to the ko/ksud native
# path; this deploy worker runs no SELinux restore code itself.
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
log "ksu.ko insmod returned 0"
progress 70

progress 80

# ---- ksud late-load (detached, never block deploy on it) -------------------
adopt_zygote_env

KSUD_BIN="$KSUD"
[ -x "$KSUD_BIN" ] || KSUD_BIN="$KSUD_INSTALL"

(
    "$KSUD_BIN" late-load --package-name "$MGR_PKG" >/dev/null 2>&1
) &

# Brief settle so ksud daemonizes; deploy completion does not block on it.
sleep 0.1
progress 90

# Best-effort: bring the KernelSU manager forward. Plain launch only — no
# force-stop; ksud owns its own manager restart. Runs detached so it never
# blocks deploy completion.
(
    sleep 1
    /system/bin/am start -a android.intent.action.MAIN \
        -c android.intent.category.LAUNCHER \
        -p "$MGR_PKG" >/dev/null 2>&1
) &

RESULT=ok
mark_done
progress 100

exit 0
