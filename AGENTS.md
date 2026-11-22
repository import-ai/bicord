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
- 原始 PCM 音频按约 30 秒分块写入录音目录下的隐藏子目录。每块 CAF 配套 `.caf.json` 保存 hostTime；`session.json` 保存文件名、音源与进程信息。设备切换、格式变化与较长回调缺口同样切块，导出按 hostTime 排序、保留两路时间关系。
- 成功导出并移动成品后才清理片段。部分片段损坏时导出可读音频，同时保留原件并写入 `published` 标记避免重复提醒。导出失败保留片段，列表显示“待保存的录音”，可以重试；重启后恢复同样依赖磁盘元数据，不依赖内存状态。
- 导出任务使用独立临时文件，失败删除该临时文件；禁止覆盖同名成品。停止和导出期间不持有会话互斥锁。片段读取超时为 10 秒，M4A 编码超时为 120 秒，设备停止总等待最多 15 秒，单路写入排空最多 5 秒。超时保留原始片段。
- 退出时停止采集并封闭分块，不等待 M4A 编码。下次打开会显示待保存录音；正在导出时也允许退出，原始片段留待重试。异常退出可能影响最后一个尚未封闭的分块；已封闭块不依赖当前进程恢复。
- 写入失败保留 NSError 详情，约一秒后尝试创建新块恢复采集。异常时钟跳变禁止触发无限补静音，最多只对两秒以内的缺口补齐，较长有效缺口由拼接时间线表示。
- 新文件使用「录音」前缀，历史文件可能使用「会议录音」。列表和打开文件入口都应支持两种前缀，并按时间排序。

## 验证混音

```sh
xcrun clang -fobjc-arc -fblocks -mmacosx-version-min=14.2 \
  src-tauri/native/recorder-test.m -o /tmp/bicord-recorder-test \
  -framework AppKit -framework Foundation -framework AVFoundation -framework AudioToolbox \
  -framework CoreAudio -framework CoreMedia
/tmp/bicord-recorder-test
```

测试用四种频率的合成音模拟设备切换，验证 M4A 保留切换前后的系统声音和麦克风输入、采样率变化及两路起始时间差。测试还检查两种单路导出、31 分钟合成音分块后丢弃内存对象再恢复、导出失败后重试、模拟磁盘不可写后恢复、损坏片段跳过、巨大时间戳跳变，以及保存时拒绝覆盖同名文件的行为。`cargo test --manifest-path src-tauri/Cargo.toml --locked` 检查恢复元数据、成品冲突保护和部分导出保留原件。CI 同样运行这些检查。改动采集逻辑后，在实际 Mac 上分别验收双路、仅系统声音和仅麦克风三种录音。

## CI、签名和公证

[Desktop build](.github/workflows/build.yml) 在 macOS runner 上构建 Apple Silicon 和 Intel 两种 DMG。推送到 `main`、推送 `v*` 标签、提交 PR 或手动运行均可触发。DMG 上传到对应运行的 Artifacts。

主分支、版本标签和手动构建使用 import-ai 的 Developer ID 签名。CI 提交最终 DMG 给 Apple 公证，附加并校验票据后才上传。PR 构建使用 ad-hoc 应用签名。签名证书和公证凭证从 GitHub Actions Secrets 读取，所需配置以工作流为准。
