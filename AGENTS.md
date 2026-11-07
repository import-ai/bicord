# Bicord 开发指南

Bicord 是一款 macOS 本地录音应用，专注于将系统声音和麦克风录进同一个 M4A 文件。面向用户的介绍、下载和使用说明放在 [README.md](README.md)。开发、测试、打包和发布说明放在本文。

## 代码入口

| 路径 | 职责 |
| --- | --- |
| `src/main.tsx`、`src/index.css` | React、TypeScript 和 shadcn/ui 界面，包括音源开关、电平、录音控制和文件列表 |
| `src-tauri/src/main.rs` | Tauri 命令、录音会话、目录设置、文件列表和保存 |
| `src-tauri/native/recorder.m` | Core Audio 系统内录、AVAudioEngine 麦克风采集、设备跟随、混音和 M4A 导出 |
| `src-tauri/native/recorder-test.m` | 原生混音、单路导出和保存行为的回归验证 |
| `src-tauri/tauri.conf.json`、`src-tauri/Info.plist`、`src-tauri/Entitlements.plist` | 应用标识、窗口配置、macOS 权限说明和签名权限 |
| `src-tauri/icons/icon.svg` | 界面与应用图标的源文件。修改后需重新生成同目录下的 `icon.png` 和 `icon.icns` |
| `.github/workflows/build.yml` | 双架构打包、签名、公证和上传 |

代码注释使用英文。产品显示名称为 Bicord。修改音源选项或状态时，同步检查 React 调用、Rust 命令与原生接口。

## 本地开发和构建

需要 macOS 14.2 或更新版本、Node.js 22.12+、Rust 和 Xcode Command Line Tools。从仓库根目录运行。

```sh
npm ci
npm run tauri dev
```

`npm run build` 执行 TypeScript 检查和前端生产构建。生成本机应用的命令如下。

```sh
npm run tauri build -- --bundles app -- --locked
open src-tauri/target/release/bundle/macos/Bicord.app
```

本机默认使用 ad-hoc 签名。涉及录音权限的验收请使用打包后的 `.app`，并在系统音频和麦克风权限允许的情况下进行。

图标源文件更新后，在临时目录运行图标生成命令，只将生成的 `icon.png` 和 `icon.icns` 复制回仓库。

```sh
icon_output=$(mktemp -d)
npm run tauri icon -- src-tauri/icons/icon.svg --output "$icon_output"
cp "$icon_output/icon.png" "$icon_output/icon.icns" src-tauri/icons/
```

## 录音和文件约定

- 系统声音和麦克风默认开启，可在录音前分别关闭。前端和后端都要求至少开启一路，录音期间锁定音源开关。
- 录音期间跟随 macOS 默认输入和输出设备。设备变更后重新连接已开启的音源，按时间拼接到同一次录音。
- 默认目录为 `~/bicord`，自定义目录保存在应用配置目录的 `recording-directory` 文件中。录音期间保持当前会话的保存目录。
- 原始音频片段写入录音目录下的隐藏子目录。成功导出并移动成品后清理片段。导出失败时保留原始片段，并在界面提示所在路径。
- 新文件使用「录音」前缀，历史文件可能使用「会议录音」。列表和打开文件入口都应支持两种前缀，并按时间排序。

## 验证混音

```sh
xcrun clang -fobjc-arc -fblocks -mmacosx-version-min=14.2 \
  src-tauri/native/recorder-test.m -o /tmp/bicord-recorder-test \
  -framework AppKit -framework Foundation -framework AVFoundation -framework AudioToolbox \
  -framework CoreAudio -framework CoreMedia
/tmp/bicord-recorder-test
```

测试用四种频率的合成音模拟设备切换，验证 M4A 保留切换前后的系统声音和麦克风输入、采样率变化及两路起始时间差。测试还检查两种单路导出，以及保存时拒绝覆盖同名文件的行为。改动采集逻辑后，在实际 Mac 上分别验收双路、仅系统声音和仅麦克风三种录音。

## CI、签名和公证

[Desktop build](.github/workflows/build.yml) 在 macOS runner 上构建 Apple Silicon 和 Intel 两种 DMG。推送到 `main`、推送 `v*` 标签、提交 PR 或手动运行均可触发。DMG 上传到对应运行的 Artifacts。

主分支、版本标签和手动构建使用 import-ai 的 Developer ID 签名。CI 提交最终 DMG 给 Apple 公证，附加并校验票据后才上传。PR 构建使用 ad-hoc 应用签名。签名证书和公证凭证从 GitHub Actions Secrets 读取，所需配置以工作流为准。
