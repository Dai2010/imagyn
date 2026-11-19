# 构建 Imagyn

本轮使用 Flutter 3.47.9（Dart 3.13.7）。准备 Git 和 Python 3，并从
仓库根目录运行以下命令。平台目录由脚本生成，脚手架应在干净的源码
目录里运行，因为它会重新生成指定平台目录。

## Linux x86_64

Fedora 的构建依赖为 `clang`、`cmake`、`ninja-build`、
`pkgconf-pkg-config`、`gtk3-devel` 和 `libsecret-devel`。
Ubuntu 上对应的 GTK 和 Secret Service 开发包为 `libgtk-3-dev`
和 `libsecret-1-dev`，还需 `clang`、`cmake`、`ninja-build`、
`pkg-config` 和 C++ 标准库开发文件。

```sh
python3 scripts/scaffold_platforms.py linux
flutter pub get --enforce-lockfile
flutter build linux --release --no-pub
./build/linux/x64/release/bundle/imagyn
```

分发时将整个 `build/linux/x64/release/bundle/` 打包，保留 `lib/`
和 `data/`。运行需要 GTK 3，以及用于存储凭据的 Secret Service。

## Windows 10／11 x64

- Windows x64 Flutter SDK 和 Git for Windows。便携 MinGit 也可用。
- 开启 Windows 开发人员模式，让 Flutter 能为插件创建符号链接。
- 安装 Visual Studio 2022 或 Build Tools 2022 的「使用 C++ 的桌面开发」。
  保留 MSVC v143 x86/x64、Windows SDK 及「用于 Windows 的 C++ CMake 工具」。
- 在安装器的「单个组件」中添加 **C++ ATL for v143（x86 和 x64）**，
  与 MSVC 版本匹配。Windows 安全存储插件需要其中的 `atlstr.h`。
  [Microsoft 组件清单](https://learn.microsoft.com/en-us/visualstudio/install/workload-component-id-vs-build-tools?view=vs-2022)

在 Windows 本地磁盘上的源码目录运行下列命令。若源码来自 VMware
共享目录，先解压至本地磁盘再构建。

```bat
py -3 scripts\scaffold_platforms.py windows
flutter pub get --enforce-lockfile
flutter build windows --release --no-pub
build\windows\x64\runner\Release\imagyn.exe
```

分发整个 `build\windows\x64\runner\Release\` 目录，保留 DLL
和 `data\`。便携包直接解压运行，最终用户无需 Flutter 或 Visual
Studio。若运行时缺少 MSVC DLL，可安装微软 Visual C++ x64
可再发行组件。

## Android

准备 JDK 21、Android SDK 命令行工具、Platform 36、Build-Tools
36.0.0、Platform-Tools、NDK 28.2.13676358 与 CMake 3.22.1。
使用 `JAVA_HOME` 和 `ANDROID_HOME` 指向已安装的工具链，并按
Android SDK 工具的提示接受所需许可。

```sh
python3 scripts/scaffold_platforms.py android --preview
flutter pub get --enforce-lockfile
flutter build apk --release --split-per-abi --no-pub
```

产物在 `build/app/outputs/flutter-apk/`。其中 `app-arm64-v8a-release.apk`
适用于 ARM64，`app-armeabi-v7a-release.apk` 适用于 32 位 ARM，
`app-x86_64-release.apk` 适用于 x86_64（含对应的 Waydroid 镜像）。

`--preview` 使用独立包名 `app.imagyn.preview`，最低支持 Android 7.0
（API 24）。本地预览使用构建环境的调试签名，同包名覆盖升级需签名
一致。正式发行需单独配置正式签名。

## 检查

```sh
flutter analyze --no-pub
flutter test --no-pub
python3 -m unittest discover -s test -p '*_test.py'
```
