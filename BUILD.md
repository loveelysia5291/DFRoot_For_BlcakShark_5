# 建置與發佈

[繁體中文](#建置與發佈)（預設）｜ [English ↓](#build--release-english)

## CI（GitHub Actions）

`.github/workflows/build.yml` 只有一個 job、一個指令：

```sh
./gradlew :app:assembleRelease
```

| 觸發 | 結果 |
|---|---|
| push `master` / `main` | 建置 + 上傳 artifact `DFRoot-release` |
| PR | 同上 |
| push tag `v*` | 建置 + 建立 GitHub Release，掛上 `DFRoot_<ver>.apk` |
| 手動 dispatch | 建置 + artifact |

發 release 只要打 tag：

```sh
git tag v4.9.0
git push origin master --tags
```

## 簽章

`assembleRelease` 的簽章來源有兩段：

1. `signing.properties` 存在**而且**它指向的 keystore 真的在磁碟上 → 用你的 key。
2. 否則退回版控內的 `keystore/debug.keystore`（`storePassword` / `keyPassword`
   都是 `android`），與舊版 DFRoot 同憑證，可直接覆蓋安裝。

CI 上的 keystore 是 `keystore/` 底下的檔案（已被 gitignore），所以要用 base64
secret 帶進去：

```sh
base64 -w0 keystore/release.keystore     # 存成 secret KEYSTORE_BASE64
```

再設 `KEYSTORE_PASSWORD` / `KEY_ALIAS` / `KEY_PASSWORD`（`KEYSTORE_FILE` 可省略，
預設 `keystore/release.keystore`）。沒設 `KEYSTORE_BASE64` 就用 debug key，CI
不會失敗。

本機同理：`signing.properties` 指到不存在的 keystore 時會自動退回 debug key，
不會像以前一樣直接讓 Gradle 掛在 `storeFile` 上。

## 本機

```sh
./gradlew :app:assembleRelease  # R8 + 資源縮減，約 5 MB（CI 用這個）
./gradlew :app:assembleDebug    # 不壓縮，約 30 MB
./gradlew :app:assembleSlim     # 與 release 等價，固定用 debug 憑證
```

需要 JDK 21、Android SDK `compileSdk 37`。

## 原生引擎 `libdfroot.so`

APK 裡的 `lib/arm64-v8a/libdfroot.so` 是**預先編好的**，`build.gradle.kts` 沒有
啟用 `externalNativeBuild`（AGP 的 CMake 步驟在受限環境會卡住），所以 CI 直接
打包它。它的來源是 `app/src/main/jni/`（`exp.c` + `elf_parser.c` + `libcxx.S`），
而 `CMakeLists.txt` 會把 `app/src/main/jni/ko/*.ko` 一起塞進去——因此 `.so` 就是
kernel module 的載體，APK 不需要另外放 `.ko`。

要重新產生 `.so` 時：

1. `lkm/` 內是 kernel module 原始碼。4.19（本機 SHARK PAR-H0）用
   `bash lkm/build-4.19.sh <kernel-source>`；GKI 核心用 `ghcr.io/ylarod/ddk-min`
   容器編（見 `lkm/Makefile`）。
2. 把產出的 `dfroot-<kmi>.ko` 放進 `app/src/main/jni/ko/`。
3. 暫時把 `app/build.gradle.kts` 的 `externalNativeBuild { cmake { ... } }` 打開，
   在沒有沙箱限制的機器上跑一次 `:app:assembleSlim`，把產出的 `libdfroot.so`
   放回 `app/src/main/jniLibs/arm64-v8a/`，再關掉該區塊。
---

<a id="build--release-english"></a>

<details>
<summary><b>English</b> — click to expand</summary>

## Build & Release (English)

CI (`.github/workflows/build.yml`) is a single job running a single command:

```sh
./gradlew :app:assembleRelease
```

Push to `master`/`main` or open a PR → build + `DFRoot-release` artifact.
Push a `v*` tag → the same build plus a GitHub Release with the APK attached.
Manual `workflow_dispatch` → build + artifact.

### Signing

`assembleRelease` signs with `signing.properties` when the file exists **and**
the keystore it names is really on disk; otherwise it falls back to the
committed `keystore/debug.keystore` (`android` / `android`), so the APK stays
installable as an update over earlier builds. On CI, put the keystore in the
base64 secret `KEYSTORE_BASE64` (with `KEYSTORE_PASSWORD`, `KEY_ALIAS`,
`KEY_PASSWORD`) and the workflow decodes it and writes `signing.properties`.

### Local

```sh
./gradlew :app:assembleRelease  # R8 + resource shrinking, ~5 MB (same as CI)
./gradlew :app:assembleDebug    # unminified, ~30 MB
./gradlew :app:assembleSlim     # same as release, always the debug key
```

Requires JDK 21 and Android SDK `compileSdk 37`.

### Native engine `libdfroot.so`

`lib/arm64-v8a/libdfroot.so` is **prebuilt**; `build.gradle.kts` does not enable
`externalNativeBuild`, so CI just packages it. It is produced from
`app/src/main/jni/` (`exp.c`, `elf_parser.c`, `libcxx.S`) and `CMakeLists.txt`
embeds `app/src/main/jni/ko/*.ko` into it — that is why the APK needs no `.ko`
files of its own and no kernel-module matrix in CI.

To regenerate it:

1. Kernel modules live in `lkm/`. For 4.19 (SHARK PAR-H0) run
   `bash lkm/build-4.19.sh <kernel-source>`; for GKI kernels use the
   `ghcr.io/ylarod/ddk-min` containers (see `lkm/Makefile`).
2. Drop the resulting `dfroot-<kmi>.ko` files into `app/src/main/jni/ko/`.
3. Temporarily enable `externalNativeBuild { cmake { ... } }` in
   `app/build.gradle.kts`, run `:app:assembleSlim` once on an unrestricted
   machine, copy the produced `libdfroot.so` back into
   `app/src/main/jniLibs/arm64-v8a/`, then disable the block again.

</details>