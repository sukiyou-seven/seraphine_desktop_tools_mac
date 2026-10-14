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

推送到仓库 `main` 时，`.github/workflows/build.yml` 会在 GitHub Actions 上运行测试并打包四个桌面产物（含原生 SwiftUI macOS 版）。四个平台版本分别作为独立 Artifact 上传，并自动创建包含四个压缩包和 `SHA256SUMS.txt` 的预览版 GitHub Release。推送 `v*` 标签会创建正式 Release；手动触发也会创建预览版。CI 产物尚未使用开发者证书签名或公证。

`npm run prepare:server` 会从 `../server-status` 构建 Linux 二进制文件。已有构建文件时，可设置 `SERA_USE_EXISTING_SERVER_BINARIES=1` 仅用于打包；正式发布建议重新构建。

## 连接和安装

Electron 在 macOS 上读取与 SwiftUI 版相同的服务器连接配置：`~/Library/Application Support/Seraphim/server-management/connections.json`。Windows、Linux 使用各自的应用数据目录。令牌、阿里云解析密钥和 SSH 主机指纹写入应用数据文件，客户端不调用系统钥匙串。应用数据文件在类 Unix 系统上使用 `0600` 权限。

「安装服务端」支持 SSH 安装和命令行安装。SSH 模式先展示主机密钥指纹供核对，确认后通过 SFTP 上传对应架构的二进制并安装；SSH 密码仅在这次操作中使用。日常服务器管理走 HTTPS API，不发送 SSH 命令。命令行模式可导出安装文件自行部署。服务端目前要求 Linux、systemd、root/sudo，监听 TCP 27520。

## 当前范围

已提供服务器状态、文件、域名解析和证书申请及网站 HTTPS 部署、网站、项目、环境变量管理、数据库、软件、环境、防火墙、计划任务、API 设置，以及服务端安装。软件安装支持串行队列、任务列表和停止。与原生端一致，**软件商店只负责安装，装好后的启停、开机启动、日志与卸载在「软件管理」；运行环境的版本选择在「环境管理」**，商店里的安装任务与软件管理里的卸载任务各自只显示自己那一类。**「环境变量管理」是独立模块**：面板保管一份公用变量，项目勾上才加载（默认不勾，同名以项目为准），代码也可以直接读服务器上导出的共用文件；保存后立即更新共用文件，并只同步那些勾了加载的项目单元。SwiftUI 版的本地 MongoDB、剪贴板、顶部组件和 AI 功能尚未移植到 Electron。

项目管理与原生端同样提供「详情」面板：启动自检清单（每条带一键修复入口）、运行信息（PID / 内存 / 已运行 / 重启次数 / systemd 结果）、依赖状态与项目日志（依赖清单按工程里实际存在的文件识别，Python 认 `requirements.txt` / `pyproject.toml` / `setup.py`，Node 按锁文件在 `pnpm` / `yarn` / `npm` 之间选，认不出或用不了时给出的解释直接来自服务端），进程没起来时追加 systemd 系统日志；**项目卡片上就写着一行依赖结论**（`pyproject.toml · 尚未安装（pip install .）` 这种），不必先点进详情——服务端把依赖结论随项目列表一起返回，运行环境本来就不装依赖的项目（Java 的 jar、.NET 的 dll、Deno）不占这一行；面板每 3 秒自刷一次，所以依赖安装、启停、重启的结果都会跟着变。卡片上只留「详情 / 启动·停止 / 重启」，其余动作（编辑、打开目录、安装依赖、创建虚拟环境、安装启动器、开机自启、复制反向代理地址、清空日志、删除）收进「更多」浮层；反复重启的项目会被标成「反复重启」而不是「运行中」。新建/编辑表单支持环境变量键值对（每行一个 `KEY=VALUE`）、是否加载工程目录下的 `.env`、是否加载面板那份公用变量（默认不勾），以及「选择空闲端口」。

`npm test` 里除了路由与传输层测试，还有一组渲染层冒烟测试（`tests/renderer.test.js`）：用一个极简 DOM 替身把 `renderer/app.js` 跑起来，直接调用 `renders.projects` / `renders.variables` / `renders.api` / `renderProjectDetail` 检查产出的 HTML。模板字符串写坏了不必等打开界面才发现。

**「API 设置」给的是接口清单和一把能直接复制走的 API key**：按模块分组列出全部接口（常用几条带可直接粘贴的 curl 示例），加上服务地址与请求头；同一份数据配出面板自带的 MCP 端点，HTTP 传输的客户端直接填地址，只支持 stdio 的点「下载桥脚本」拿 `seraphim-mcp.py` 再照配置写。**这把 key 是服务端单独生成的一把**，与面板连服务器用的凭据分开，所以页面上可以「重置 key」：旧的一把立刻失效，正在用它的脚本和 AI 客户端都要换成新的，而已经连上的面板不受影响。key 只能由服务端生成——页面上没有填写框，重置前会明确确认一次。

当前证书功能依赖的 `acme-client` 间接使用 `node-forge`；截至本次打包，`npm audit --omit=dev` 报告该依赖有 2 条高危告警，尚无兼容更新。正式公开分发前需要复查并处理。Windows 与 Linux 包在 macOS 上完成归档检查，仍需各自系统上的启动与交互验证。
