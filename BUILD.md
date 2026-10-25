# 建置與發佈

## CI（GitHub Actions）

`.github/workflows/build.yml` 只有一個 job、一個指令：

```sh
./gradlew :app:assembleSlim
```

| 觸發 | 結果 |
|---|---|
| push `master` / `main` | 建置 + 上傳 artifact `DFRoot-slim` |
| PR | 同上 |
| push tag `v*` | 建置 + 建立 GitHub Release，掛上 `DFRoot_<ver>.apk` |
| 手動 dispatch | 建置 + artifact |

發 release 只要打 tag：

```sh
git tag v4.9.0
git push origin master --tags
```

## 簽章

`assembleSlim` 用版控內的 `keystore/debug.keystore`（`storePassword`/`keyPassword`
都是 `android`），所以 CI 不需要任何 secret，而且與舊版 DFRoot 同憑證，可直接
覆蓋安裝。

要換成自己的 key，在 repo secrets 設 `KEYSTORE_FILE` / `KEYSTORE_PASSWORD` /
`KEY_ALIAS` / `KEY_PASSWORD`，workflow 會寫出 `signing.properties`；再把
`app/build.gradle.kts` 裡 slim 的 `signingConfig` 改成 `release` 即可。

## 本機

```sh
./gradlew :app:assembleSlim    # R8 + 資源縮減，約 5 MB
./gradlew :app:assembleDebug   # 不壓縮，約 30 MB
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
