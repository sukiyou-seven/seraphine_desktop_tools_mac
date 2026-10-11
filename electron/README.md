# Seraphim Electron 客户端

跨平台桌面客户端，当前包含「服务器管理」模块。macOS 原生 SwiftUI 版继续由仓库根目录的 `build.sh` 构建。

## 开发与打包

需要 Node.js、npm、Go（构建内置 Linux 服务端）。在本目录执行：

```sh
npm ci
npm start
npm test
npm run pack:all
```

本目录的 `.npmrc` 跳过可选原生扩展，以便在一台 Mac 上生成三个平台的包；SSH 功能使用 `ssh2` 的纯 JavaScript 实现。

打包结果位于 `../build/electron`：macOS 为含 `.app` 的 ZIP，Windows 为含 `.exe` 的 ZIP，Linux 为 `.tar.gz`。三个包都内置 Linux amd64/arm64 的 `sera` 安装文件。也可分别运行 `pack:mac`、`pack:win`、`pack:linux`。目前 macOS 产物未签名，分发前仍需开发者签名与公证；Windows 产物未进行代码签名。

解压后，macOS 打开 `Seraphim.app`，Windows 运行 `Seraphim.exe`，Linux 运行解压目录中的 `seraphim-electron`。

推送到仓库 `main` 时，`.github/workflows/build.yml` 会在 GitHub Actions 上运行测试并打包四个桌面产物（含原生 SwiftUI macOS 版），上传带 SHA-256 校验文件的 Artifacts；也支持手动触发。CI 产物和本地构建一样，尚未使用开发者证书签名或公证。

`npm run prepare:server` 会从 `../server-status` 构建 Linux 二进制文件。已有构建文件时，可设置 `SERA_USE_EXISTING_SERVER_BINARIES=1` 仅用于打包；正式发布建议重新构建。

## 连接和安装

Electron 在 macOS 上读取与 SwiftUI 版相同的服务器连接配置：`~/Library/Application Support/Seraphim/server-management/connections.json`。Windows、Linux 使用各自的应用数据目录。令牌、阿里云解析密钥和 SSH 主机指纹写入应用数据文件，客户端不调用系统钥匙串。应用数据文件在类 Unix 系统上使用 `0600` 权限。

「安装服务端」支持 SSH 安装和命令行安装。SSH 模式先展示主机密钥指纹供核对，确认后通过 SFTP 上传对应架构的二进制并安装；SSH 密码仅在这次操作中使用。日常服务器管理走 HTTPS API，不发送 SSH 命令。命令行模式可导出安装文件自行部署。服务端目前要求 Linux、systemd、root/sudo，监听 TCP 27520。

## 当前范围

已提供服务器状态、文件、域名解析和证书、网站、项目、数据库、软件、环境、防火墙、计划任务，以及服务端安装。SwiftUI 版的本地 MongoDB、剪贴板、顶部组件和 AI 功能尚未移植到 Electron。

当前证书功能依赖的 `acme-client` 间接使用 `node-forge`；截至本次打包，`npm audit --omit=dev` 报告该依赖有 2 条高危告警，尚无兼容更新。正式公开分发前需要复查并处理。Windows 与 Linux 包在 macOS 上完成归档检查，仍需各自系统上的启动与交互验证。
