#!/usr/bin/env bash
#
# build-4.19.sh — build lkm/dfroot.c (with the SELinux-permissive + bootstrap
# chain) into the KO the DFRoot APK embeds for kernel 4.19 devices.
#
# Usage:
#   bash lkm/build-4.19.sh /path/to/device-kernel-source
#
# The kernel source tree must be the EXACT tree that built the device kernel
# (vermagic + modversions CRCs must match, e.g. 4.19.113-perf-g23687c382).
# It must already be configured with the device defconfig and have run
# modules_prepare / modules at least once (so Module.symvers + generated
# headers exist).
#
# Toolchain: clang/LLVM (LLVM=1 build). Either put clang, llvm-ar, llvm-nm,
# llvm-objcopy in PATH, or point ANDROID_NDK at an NDK whose toolchains/llvm
# has the bin/ directory.
#
set -euo pipefail

KDIR="${1:-}"
if [[ -z "${KDIR}" ]]; then
    echo "usage: bash $0 /path/to/device-kernel-source" >&2
    exit 2
fi
KDIR="$(realpath -m "${KDIR}")"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LKM_DIR="$(dirname "${SCRIPT_DIR}")/lkm"
REPO_ROOT="$(dirname "${LKM_DIR}")"
KO_OUT="${REPO_ROOT}/app/src/main/jni/ko/dfroot-android12-4.19.ko"

echo "==> preflight: ${KDIR}"
[[ -f "${KDIR}/Makefile" ]] || { echo "!! no Makefile in KDIR" >&2; exit 1; }
KMAJ="$(awk '/^VERSION[[:space:]]*=/{print $3; exit}' "${KDIR}/Makefile")"
KMIN="$(awk '/^PATCHLEVEL[[:space:]]*=/{print $3; exit}' "${KDIR}/Makefile")"
if [[ "${KMAJ}" != "4" || "${KMIN}" != "19" ]]; then
    echo "!! KDIR is kernel ${KMAJ}.${KMIN}, expected 4.19" >&2
    exit 1
fi
[[ -f "${KDIR}/.config" ]]   || { echo "!! ${KDIR}/.config missing (kernel not configured)" >&2; exit 1; }
[[ -f "${KDIR}/Module.symvers" ]] || { echo "!! ${KDIR}/Module.symvers missing — run modules_prepare/modules once on this tree first" >&2; exit 1; }
grep -q "CONFIG_MODVERSIONS=y" "${KDIR}/.config" || { echo "!! device kernel has CONFIG_MODVERSIONS=y; this tree does not — wrong tree" >&2; exit 1; }

# clang / LLVM tools
if command -v clang >/dev/null 2>&1; then
    export PATH="$(dirname "$(command -v clang)")":${PATH}
elif [[ -n "${ANDROID_NDK:-}" && -d "${ANDROID_NDK}/toolchains/llvm/prebuilt" ]]; then
    LLVM_BIN="$(ls -d "${ANDROID_NDK}"/toolchains/llvm/prebuilt/*/bin 2>/dev/null | head -1)"
    [[ -n "${LLVM_BIN}" ]] && export PATH="${LLVM_BIN}:${PATH}"
fi
command -v clang >/dev/null 2>&1 || { echo "!! clang not found (set PATH or ANDROID_NDK)" >&2; exit 1; }
command -v llvm-objcopy >/dev/null 2>&1 || { echo "!! llvm-objcopy not found" >&2; exit 1; }

echo "==> building dfroot.ko against ${KDIR}"
make -C "${LKM_DIR}" KDIR="${KDIR}" clean || true
make -C "${LKM_DIR}" KDIR="${KDIR}" all

echo "==> stripping"
llvm-objcopy --strip-unneeded \
    -R .comment -R .note.gnu.property \
    -R .note.Linux -R .note.GNU-stack \
    -R .BTF -R .BTF.base -R .llvm_addrsig \
    -R .hyp.text -R .hyp.bss -R .hyp.rodata -R .hyp.event_ids \
    -R .hyp.patchable_function_entries -R .hyp.data \
    "${LKM_DIR}/dfroot.ko"

mkdir -p "$(dirname "${KO_OUT}")"
cp "${LKM_DIR}/dfroot.ko" "${KO_OUT}"
make -C "${LKM_DIR}" KDIR="${KDIR}" clean || true

echo "==> verify"
echo "    vermagic : $(strings "${KO_OUT}" | awk '/^vermagic=/{print; exit}')"
echo "    desc     : $(strings "${KO_OUT}" | awk '/^description=/{print; exit}')"
SIZE="$(stat -c %s "${KO_OUT}")"
echo "    size     : ${SIZE} bytes"
if ! strings "${KO_OUT}" | grep -q "selinux_state permissive"; then
    echo "!! WARNING: built KO has no SELinux-permissive strings — did it really come from lkm/dfroot.c?" >&2
    exit 1
fi
if [[ "${SIZE}" -lt 8000 ]]; then
    echo "!! WARNING: KO looks too small (${SIZE}B); a stripped dfroot.ko is usually 10-14KB" >&2
fi

echo "==> done: ${KO_OUT}"
echo "    Next: make  (rebuild the APK, embeds this KO)"
