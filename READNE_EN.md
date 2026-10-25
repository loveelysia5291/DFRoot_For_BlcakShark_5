
# DFRoot (GPL-2.0)

Temporary root for Android 12 / kernel 4.19 (Black Shark SHARK PAR-H0): a kernel
module gives the app kernel privileges, then Magisk's `su` is bound under
`/debug_ramdisk`.

## License

**GNU General Public License v2.0** (see `LICENSE`). Derived from DFRoot
(loveelysia5291/DFRoot). Distributing binaries requires shipping the
corresponding source.

## What it does (4.9.0)

**Nothing has to be imported.** The deploy reads the installed Magisk manager's
APK and pulls `magisk`, `magiskinit`, `magiskboot`, `magiskpolicy`, `busybox`
and `init-ld` straight out of it, so the app no longer stores, compares or
rolls back a user-supplied payload.

Deploy outline:

1. Refuse to start when no Magisk is installed (`ERROR_NO_MAGISK`); nothing is
   locked or modified in that case
2. Hash the manager APK and skip extraction when it matches the last deploy
3. Version/signature gate: when that hash changes, the stale
   `magisk.db` `keystore` row is dropped so magiskd re-learns the manager
   certificate instead of removing the manager
4. Stage the full file set into `/data/adb/magisk`; `su` exists only as
   `/debug_ramdisk/su`

## UI

Jetpack Compose + [MIUIX 0.9.4](https://github.com/compose-miuix-ui/miuix). Three
pages you can **swipe** between, with the bottom bar following the visible page:

- **Home** — start root, deploy progress, Magisk/LSPosed shortcuts
- **Log** — live `ExploitRunner` output (selectable, saveable to Download)
- **Settings** — auto-run on boot, LSPosed soft reboot, module disable, about

Colours come from the system **Monet** palette (Android 12 wallpaper colours),
falling back to the defaults when the ROM exposes none. The **launcher icon
follows it too**: six plates ship in the APK (green/blue/purple/pink/orange/
teal) and on launch the app picks the one closest to `system_accent1_500` and
switches the enabled `activity-alias` — new entry is enabled before the old one
is disabled, so the app can never disappear from the launcher.

## Build

```sh
# JDK 21 and Android SDK (compileSdk 37)

./gradlew :app:assembleRelease   # R8 + resource shrinking, ~5 MB (used by CI)
./gradlew :app:assembleDebug     # unminified, debuggable, ~30 MB
./gradlew :app:assembleSlim      # same as release, always the debug key
```

## CI / releases

`.github/workflows/build.yml` runs a single job with a single command,
`./gradlew :app:assembleRelease`. Push to `master` uploads an artifact; pushing
a `v*` tag also creates a GitHub Release with the APK attached.

```sh
git tag v4.9.0
git push origin master --tags
```

## Signing

`assembleRelease` signs with `signing.properties` when both the file and the
keystore it names exist, otherwise with the committed
`keystore/debug.keystore` (`android` / `android`), which keeps the APK
installable as an update over earlier DFRoot builds. On CI, store the keystore
as the base64 secret `KEYSTORE_BASE64` (plus `KEYSTORE_PASSWORD`, `KEY_ALIAS`,
`KEY_PASSWORD`) to sign with your own key.

## Notes

- Magisk only — KernelSU support was removed
- `su` lives only at `/debug_ramdisk/su`; `/system/bin` and `/system/xbin` are
  cleaned
- The app never installs or uninstalls a manager and never guesses which app is
  Magisk from APK contents

Rebuilding the native engine / kernel modules: see [`BUILD.md`](BUILD.md)
(Chinese).

</details>

