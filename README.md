# Bicord

Bicord 是一款 macOS 录音应用，可同时录制系统声音和麦克风，并保存为同一个 M4A 文件。需要 macOS 14.2 或更新版本。

打开 `Bicord.app`，点击「开始录音」，按 macOS 提示允许系统音频录制和麦克风访问。系统声音和麦克风默认开启，可在录音前分别关闭，开始录音时至少需要开启一路。界面会显示 macOS 当前输入和输出设备，录音中的设备切换会接入同一次录音，设备重新连接时可能有短暂静音。

点击「停止并保存」后，合成的 M4A 文件默认保存在 `~/bicord`。可在「录音文件」中点击「更改目录」，应用会记住选择，并显示该目录中的录音。可以从应用内播放文件，或在 Finder 中定位。录音期间，原始音频片段保存在同一目录下的隐藏子目录，导出成功后会清理。导出失败时，界面会显示原始片段的路径。

## 构建

在本目录运行。需要 Node.js 22.12+、Rust 和 Xcode Command Line Tools。

```sh
npm ci
npm run tauri build -- --bundles app
open src-tauri/target/release/bundle/macos/Bicord.app
```

本机产物使用 ad-hoc 签名。录音验收请使用 `.app`，让 macOS 按应用识别权限。

## 验证混音

```sh
xcrun clang -fobjc-arc -fblocks -mmacosx-version-min=14.2 \
  src-tauri/native/recorder-test.m -o /tmp/bicord-recorder-test \
  -framework AppKit -framework Foundation -framework AVFoundation -framework AudioToolbox \
  -framework CoreAudio -framework CoreMedia
/tmp/bicord-recorder-test
```

测试用四种不同频率的合成音模拟设备切换，验证导出的 M4A 保留切换前后的系统声和麦克风、采样率变化及两路起始时间差。

## CI

GitHub Actions 为 Apple Silicon 和 Intel Mac 构建 DMG。推送到 `main`、创建 `v*` 标签或提交 PR 时会触发构建，也可以手动运行。安装包在对应运行的 Artifacts 中下载。主分支、版本标签和手动构建的 DMG 使用 import-ai 的 Developer ID 签名，并附上 Apple 公证票据。PR 构建使用 ad-hoc 应用签名。
