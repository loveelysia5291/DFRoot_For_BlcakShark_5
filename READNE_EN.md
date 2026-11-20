<p align="center">
  <img src="docs/icon.png" width="132" height="132" alt="DFRoot">
</p>

# DFRoot (GPL-2.0)

[繁體中文](README.md) ｜ **English**

One-shot temporary root deployment for Black Shark 5 (SHARK PAR-H0):
Gains kernel privileges via an LKM and loads KernelSU via `bootstrap` and `ksud late-load`.

## License

GNU General Public License v2.0 (see `LICENSE`).
Forked from DFRoot (loveelysia5291/DFRoot). Source code must accompany binaries.

## Usage

**Install KernelSU or KernelSU-Next Manager APK before running the exploit.**

Deployment flow:
1. Auto-detects installed KernelSU manager (`me.weishu.kernelsu`, `io.github.a13e300.ksu`, etc.).
2. Stages `libksud.so` to `/data/user_de/0/df.root/ksud`.
3. Stages native `libbootstrap.so` to `/data/user_de/0/df.root/bootstrap`.
4. Runs `libdfroot.so` to trigger the exploit and insmod the LKM.
5. `bootstrap` runs `ksud late-load` to complete KernelSU setup.

## UI

Jetpack Compose + [MIUIX 0.9.4](https://github.com/compose-miuix-ui/miuix).
- **Home**: Launch Root, Open KernelSU, Realtime Scrolling Logs.
- **Settings**: Boot Auto-Deploy, Soft Reboot (LSPosed), Disable All Modules.
