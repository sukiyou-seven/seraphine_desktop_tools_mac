# DBManager — 本地 MongoDB / MySQL / Redis 管理小工具

macOS 原生 app（Swift + SwiftUI），双击运行。**不用终端、不用浏览器、不用 Python、不用 tkinter。**

界面语言中文，只操作本机数据库进程，不做任何联网行为。

---

## 能干什么

### MongoDB（需本机已装 `mongod`；建库/改密码需要 `mongosh`）

| 功能 | 说明 |
| --- | --- |
| 启动 / 停止 / 重启 | 在后台派生 `mongod --config …`（**不用 `--fork`**，MongoDB 8 起 macOS 已禁用），停止走 `--shutdown` + 信号兜底，不依赖 `brew services` |
| 状态 | 运行标记、版本、监听地址、PID、配置文件、数据目录、实际连通性（发 `ping` 验证登录） |
| 修改配置 | 常用项表单（bindIp / port / dbPath / 日志 / 鉴权 / fork / 慢查询 …）+ 配置文件全文编辑 |
| 新建数据库 | 惰性建库会写入一个 `_bootstrap` 集合让新库立刻可见；**可同时为该库创建用户**（用户名默认与库名相同、留空自动同步，密码留空自动生成，角色可选 readWrite / read / dbOwner / dbAdmin）。创建成功后**账号密码会被记住**，直接显示在下面的数据库列表里 |
| 数据库列表 | 每个库一行：名称、占用、**用户名（可复制）**、**密码（默认打码，可显示 / 复制）**、删除。只有本工具创建的库才有密码记录，其余显示「不是本工具创建的库」 |
| 删除数据库 | 带二次确认 |
| 用户与密码 | 查看指定库的用户；创建用户或改密码并覆盖角色；密码支持**一键生成强密码 / 显示 / 复制**，成功后给出可直接使用的连接串 |
| 日志 | 日志文件尾部实时查看 |

### MySQL（需本机已装 `mysql` / `mysqld`；`brew install mysql` 自带）

| 功能 | 说明 |
| --- | --- |
| 启动 / 停止 / 重启 | `mysqld --daemonize` 启动（数据目录没初始化时会给出初始化命令），停止走 `mysqladmin shutdown` + 信号兜底 |
| 状态 | 运行标记、版本、监听地址、PID、my.cnf、数据目录、连通性（真的执行一次 `SELECT 1` 验证登录） |
| 修改配置 | my.cnf 常用项表单（port / bind-address / datadir / socket / 字符集 / 排序规则 / 存储引擎 / 连接数 / 缓冲池 / 跳过域名反解）+ 全文编辑（INI 格式，保留注释与其它 section） |
| 新建数据库 | 固定 `utf8mb4`；**可同时创建用户并授权**（用户名默认与库名相同、密码留空自动生成、权限可选 ALL PRIVILEGES / 读写 / 只读、来源可选 `%` 或 `localhost`） |
| 数据库列表 | 名称、占用、**该库在本工具创建过的账号（用户名可复制、密码可显示可复制）**、删除 |
| 用户与密码 | 列出所有用户（用户名 + 允许来源）、创建用户 / 改密码、授权到指定库 |
| 日志 | 错误日志尾部查看 |

MySQL 的账号是「用户名 + 允许来源」的组合（例如 `myapp@%`）；密码同样**读不出来**（只存哈希），工具能显示的只有它自己创建或重置过的那份。

### 证书（Let's Encrypt，走 acme.sh）

| 功能 | 说明 |
| --- | --- |
| 申请方式 | **阿里云 DNS 自动**（DNS-01：自动写入/删除 `_acme-challenge` 的 TXT 记录）；**手动 DNS**（工具给出 TXT 记录，你自己加到解析里，再回来点完成签发） |
| 域名 | 支持多个域名与泛域名（`example.com, *.example.com`）；密钥可选 ECC（推荐）或 RSA 2048 / 4096 |
| 证书列表 | 主域名、密钥类型、附加域名、下次续期时间、证书路径（可复制）、手动续期 |
| 部署 | 把 key / fullchain 复制到指定路径（给 Nginx 等用），并可选配置续期后的重载命令 |
| 自动续期 | 一键安装 acme.sh 的续期任务（每天检查，到期前 30 天自动续） |

**为什么走 DNS-01 而不是 HTTP-01**：DNS-01 不需要域名解析到本机、不需要开放 80 端口，而且**能签泛域名** `*.example.com`；代价是需要域名解析的写权限（阿里云就是它的 AccessKey）。

**关于 CA**：acme.sh 新版本默认改用 ZeroSSL，所以工具在每次申请时都显式传 `--server letsencrypt`，确保签出来的是 **Let's Encrypt** 证书。

**首次使用**：证书页会显示 acme.sh 的安装状态；未安装时可以直接点按钮执行官方安装命令（会显示将执行的完整命令），也可以自己在终端装。

⚠️ 阿里云 AccessKey 会明文保存在工具的设置文件里，**建议用只有 DNS 解析权限的 RAM 子账号**。

### 宝塔面板（API 集成）

| 功能 | 说明 |
| --- | --- |
| 连接配置 | 面板地址 + API 密钥（面板「设置 → API 接口」里开启并生成）；HTTPS 自签证书可忽略校验 |
| 系统概览 | 面板版本、操作系统、CPU 核心、内存、磁盘、负载、运行时长 |
| 服务管理 | Nginx / Apache / OpenResty / MySQL / MariaDB / Redis / MongoDB / Pure-Ftpd / Memcached / PHP / Docker 等一键 **启动 / 停止 / 重启 / 重载** |
| 网站列表 | 网站名、状态、域名、目录；可启停 |
| 数据库列表 | 名称、类型、大小 |
| **部署 SSL** | 把「证书」页签发的证书直接提交给面板，配好该网站的 HTTPS（申请 → 部署一条龙） |
| 原始响应 | 每次调用都保留面板返回的原始内容，面板版本差异时方便对照排查 |

**签名规则**：`request_token = md5(request_time + md5(api_sk))`，参数以 form 表单提交。不同面板版本的插件接口偶有差异，所以工具在收到「签名错误」时会**自动改用备选算法重试**，并且**始终保留原始响应**。

⚠️ API 密钥会明文保存在工具的设置文件里，建议只在本机使用。

### Redis（需本机已装 `redis-server`；**查看内容不需要 `redis-cli`**）

| 功能 | 说明 |
| --- | --- |
| 启动 / 停止 / 重启 | `redis-server <conf>` 并显式指定 `--dir/--logfile/--pidfile`（避免配置里的相对路径在 GUI 环境下写不进去），停止走协议层 `SHUTDOWN SAVE` |
| 状态 | 运行标记、版本、监听地址、PID、配置文件、工作目录、握手结果 |
| 修改配置 | 常用项表单（bind / port / requirepass / maxmemory / appendonly / dir / save …）+ 全文编辑 |
| 数据浏览 | 选库（db0–db15）、按模式 `SCAN` 分页、key 列表带类型与 TTL、值详情支持 string / hash / list / set / zset / stream |
| 运行概览 | 版本、模式、角色、连接数、内存、命中率、各库 key 数量 |
| 控制台 | 直接执行任意 Redis 命令（支持引号），写操作会真的生效 |
| 日志 | 日志文件尾部查看 |

所有配置改动**先备份成 `xxx.bak` 再落盘**，并且改写单个配置项时**保留原有的文件头注释与行内注释**。

### 配置项：文本 / 选择两种输入

- **布尔型与枚举型**（`security.authorization`、`processManagement.fork`、`operationProfiling.mode`、`daemonize`、`appendonly`、`protected-mode`、`maxmemory-policy`）渲染成**下拉选择**，选完立即写回配置，不需要手敲 `enabled`/`true` 这种值。
- 端口、路径、内存大小等仍为文本输入，改完点「保存」。
- 进入「配置」页会自动读取一次，也可以点「加载 / 重新读取」。

### 密码生成器

「生成」按钮产生 20 位强密码，刻意排除了：

- **容易看错的字符**：`l` `I` `1` `O` `0`
- **会破坏连接串 / URL 的字符**：`@` `:` `/` `#` `?` `&` `=` `%` 空格
- **会引起 shell / 配置转义麻烦的字符**：`"` `\` `'`

所以生成的密码可以直接贴进 `mongodb://user:pwd@host/db`，**不需要任何 URL 编码**就能用。旁边有「显示」和「复制」。

---

## 快速开始

```bash
# 1) 装数据库本体（本工具不负责安装，只管已有实例）
brew install mongodb-community     # 自带 mongosh
brew install redis

# 2) 构建 app
./build.sh

# 3) 运行
open build/DBManager.app
```

首次打开若被系统拦下（app 是本机 ad-hoc 签名），在 Finder 里右键 → **打开**。

想装到「应用程序」里，用 `ditto`（不要用 Finder 拖动，拖动会留下替身文件）：

```bash
rm -rf /Applications/DBManager.app
ditto build/DBManager.app /Applications/DBManager.app
```

**遇到问题时**：看 `~/Library/Application Support/DBManager/log/run.log`（记录每次点击执行了什么命令、返回码）和 `crash.log`（崩溃记录）。

---

## 界面结构

```
侧边栏
├── MongoDB
│   ├── 数据库    新建 / 列表（含占用大小）/ 删除
│   ├── 配置      常用项表单 + 配置全文编辑
│   ├── 用户与密码 查看用户、创建/改密码、角色勾选
│   └── 日志
├── Redis
│   ├── 数据浏览  key 列表（左）+ 值详情（右）
│   ├── 概览      INFO 关键指标 + 各库 key 数
│   ├── 配置      常用项表单 + 配置全文编辑
│   ├── 控制台    任意命令
│   └── 日志
└── 设置          路径探测结果、二进制路径、端口、管理员账号、密码
```

---

## 文件位置

| 内容 | 位置 |
| --- | --- |
| 设置（含密码，权限 600） | `~/Library/Application Support/DBManager/settings.json` |
| 自动生成的配置 | `~/Library/Application Support/DBManager/conf/{mongod,redis}.conf` |
| 各库账号密码（600） | `~/Library/Application Support/DBManager/credentials.json` |
| 运行日志 / 崩溃记录 | `~/Library/Application Support/DBManager/log/{run.log,crash.log}` |
| 日志 / PID | `~/Library/Application Support/DBManager/{log,run}/` |
| 配置备份 | 与配置文件同目录的 `xxx.bak` |
| app 图标源文件 | 项目根目录 `title_icon.png`；`./tools/make-icon.sh` 会生成 `Resources/AppIcon.icns`，`./build.sh` 自动打包（换图标只需替换该 PNG 后跑这两个脚本） |

探测顺序：**设置里的显式值 → Homebrew 默认位置（`/opt/homebrew`、`/usr/local`）→ PATH**。只有需要自定义时才在设置里填，留空即自动。

---

## 关于鉴权（重要）

- 建库、改密码、列用户都通过 `mongosh` 执行，因此本机需要 `mongosh`（`brew install mongodb-community` 自带；单独的 `mongosh` formula 也可以）。
- 如果实例已在 `mongod.conf` 里开启 `security.authorization: enabled`，请在**设置**里填管理员用户名/密码与 authSource（一般为 `admin`），否则这些操作会报认证失败并给出提示。
- 密码以明文保存在 `settings.json`（本地文件，权限 `600`）。不放心就留空，操作时再临时填。

---

## 实现要点

- **不依赖 `brew services`**：自己管进程（`mongod` 后台派生 + `--shutdown`、`redis-server <conf>`），PID 从 pidfile / 配置文件 / 端口占用三处确认。
- **MongoDB 8 的坑**：macOS 上 `--fork` 与 `processManagement.fork` 已被移除（`BadValue: Server fork+exec ... is incompatible with macOS`）。工具改为「后台派生 + 端口就绪即成功」，并在检测到配置里写着 `fork: true` 时自动改正（保留 `.bak` 备份）。
- **失败反馈**：启动失败时立刻返回（不干等），并把 mongod 日志尾部记到运行日志里，界面只给一句人话摘要。
- **「运行中」只认端口**：pid 文件会残留、pid 还会被系统复用，所以状态判定以「端口是否在监听」为准；要 `kill` 时先确认**该 pid 的进程名真的是 mongod / redis-server**，避免误杀无辜进程。
- **图标**：`sips`/`iconutil` 在受限环境里用不了系统临时目录，所以图标由 `swift` 缩放 + 手工组装 icns（`icp4`…`ic14` 条目内直接放 PNG）生成，构建脚本会自动复制进 bundle。
- **Redis 客户端是自己写的 RESP2 实现**（标准库 socket），所以查看内容、执行命令、优雅关停都不需要 `redis-cli`。
- **显式探测 `/opt/homebrew/bin` 等路径**：GUI app 的 `PATH` 只有 `/usr/bin:/bin:/usr/sbin:/sbin`，不补路径会找不到 `mongod` / `redis-server`。
- **mongosh 的游标陷阱**：`db.getUsers()` 返回的是**游标**（没有 `map`/`some`），写 `.map(...)` 会报 `d.getUsers().map is not a function`。所以所有用户/库操作用服务器命令（`usersInfo` / `createUser` / `updateUser` / `dropDatabase` / `listDatabases`），返回的都是普通文档，行为不受 shell 版本影响。自测里用 mongosh 的桩真实执行了这些脚本，防回归。
- **CRLF 陷阱**：Swift 里 `"\r\n"` 是**一个** `Character`（字形簇），直接用 `split(separator: "\n")` 切 Redis 的 CRLF 输出会一行都切不开。内部统一走自定义的 `String.lines`（`whereSeparator: isNewline`）。
- **写文件**：优先原子写，失败自动降级为普通写（某些受限环境会拒绝原子写）。
- **日志脱敏**：工具会执行带凭据的 `mongodb://user:pass@host/…` 命令，所以写进 `run.log` 前会把密码替换成 `***`（正则 `://user:pass@` → `://user:***@`），避免密码明文落到日志里。
- **设置的宽松解码**：Swift 合成的 `Codable` 解码器要求所有字段都在，手写或旧版的 `settings.json` 会因为缺字段导致**整份**设置解码失败（凭据丢失）。所以 `MongoSettings`/`RedisSettings`/`AppSettings` 都改成了 `decodeIfPresent ?? 默认值`，缺字段只影响那一项。
- **进页面自动加载**：服务状态是异步拿到的，直接在 `onAppear` 里加载会被「未运行」挡掉。现在状态刷新确认「在运行」后会补一次加载，列表不会一直空着。
- 目标 `arm64-apple-macos13.0`，`-Xfrontend -disable-sandbox` 是编译期需要（`@State` 等 SwiftUI 宏要跑 `swift-plugin-server`）。

---

## 自测

```bash
./tests/run.sh
```

178 项断言，覆盖：配置行级读写（mongod.conf / redis.conf / my.cnf 三种格式）/ 注释保留 / CRLF 处理 / 命令解析 / RESP 客户端 / SCAN 与各类型值解析 / 概览统计 / 配置备份 / 缺依赖时的降级提示 / 进程归属校验 / 日志脱敏 / 设置的宽松解码 / MySQL 的 SQL 转义与库名校验 / acme.sh 输出解析（手动 TXT 记录、证书列表、iCloud 路径）/ 宝塔 API 的 MD5 与签名算法、响应判定与网站解析，并用 mongosh 桩**真实执行**了生成的建库·改密码·删库·建管理员·重置密码脚本（本机没装 mongosh 时自动跳过），还包括配置项类型与密码生成器（长度 / 字符集 / 200 轮随机验证）的断言。
Redis 部分用**进程内假服务器**（自动挑空闲端口），所以**不需要真的装 MongoDB 或 Redis**。

---

## 已知限制

- Redis 集合类内容最多展示前 200 项（`set` 为随机取样），string 预览 8000 字符。
- MongoDB 侧只做服务、库、用户管理，不提供集合内文档浏览。
- 一次只管一组配置（单实例），不支持多实例切换。
- 不做安装/卸载数据库本体。
