# Seraphim — 服务器与本地服务管理工具

macOS 原生 app（Swift + SwiftUI），双击运行。应用本身不依赖 Python；管理 Python 项目和环境时需要本机已有 Python。

界面语言中文。数据库服务在本机管理；证书、宝塔、云端任务和 pip 安装等功能会按操作需要访问网络。

---

## 能干什么

### 项目管理

可以添加多个工程目录，它们会同时显示在项目管理页，分别刷新、展开和运行命令。每个工程会扫描自身及最多 5 层子目录，分别列出找到的 Node 和 Python 子工程。同一个目录里也可以有多个 `package.json` 和多个 Python 入口。扫描会跳过 `node_modules`、虚拟环境、构建产物及 Git 目录。

- **Node**：读取各 `package.json` 的 `scripts`，逐条运行 `npm run <脚本名>`，工作目录设为对应 `package.json` 所在目录。开发服务器输出本地 HTTP 地址后，可点「打开网页」；也可为子工程保存一个固定网址。
- **Python**：发现 `main.py`、`pyproject.toml` 或 `requirements.txt` 时显示 Python 入口，默认运行 `main.py`；入口文件和参数可修改。优先选该子工程或其父目录中的 `.venv` / `venv` / `env`，也可以用「添加…」选任意可执行的 Python 解释器并保存。
- **微信小程序**：发现 `project.config.json` 或 `dev:mp-weixin` 等脚本时显示「微信开发者工具打开」。对 uni-app 会优先打开生成的 `dist/dev/mp-weixin`，未生成时提示先运行开发或构建脚本；使用本机开发者工具的 `cli open --project` 打开。
- 左侧列出所有工程与子工程，工程可折叠；右侧显示选中子工程的命令，底部固定高度的输出区只显示当前选中命令的日志。可同时运行多个命令并分别停止。切换页面后命令继续运行；退出应用时会停止由项目管理启动的命令。工程目录、折叠状态、网页地址和手动选择的 Python 解释器会保存在应用支持目录的 `projects.json` 中。

运行前需要自行安装项目依赖。Node 工程需要 `npm`，Python 工程需要可用的虚拟环境或 `python3`。

### 清理

「其他」里的「清理」页扫描家目录顶层的 `.log` 文件，只列出超过 24 小时且内容明确属于 Xcode 构建、设备安装/启动或 DerivedData 检查输出的日志。可逐项查看、取消勾选，确认后移到 macOS 废纸篓；移动前会重新核对文件，发生变化的文件会跳过。不会扫描或清理项目目录、应用运行日志及其他无法识别的日志。

### 快捷启动

「其他」里的「快捷启动」按工作区方案管理。可新建、重命名、删除多个方案，每个方案从系统 `/Applications` 和用户 `~/Applications` 中分别选择要启动的 App；点击「启动此方案」即可一次打开该方案的所有应用。方案及当前选择会自动保存，旧版单组应用列表会迁移为「默认方案」。若应用已移走，页面会标出并在启动时提示，可从列表中移除。

### 剪贴板

「其他」里的「剪贴板」记录复制过的**文本**历史，点任意一条即可复制回系统剪贴板，也可以逐条删除或一键清空。

- **两种存储**：整份历史同时放 Redis（key `dbm:clipboard:history`，读一次就拿到全部，**读取快**）和本地文件 `~/Library/Application Support/DBManager/clipboard.json`（**关机重启后还在**）。载入时以文件打底、Redis 合并进来，Redis 连不上就只用文件；Redis 里的内容不会被空历史覆盖。
- **上限**：本地固化文件最多 **2 MB**，条目最多 500 条，单条文本最多 256 KB（超出按 UTF-8 字节截断，不会切坏中文），超限时从**最旧**的条目开始丢。
- **只记文本**：图片、文件等非文本内容既不进 Redis、也不写本地文件 —— 所以固化文件里永远没有图片。密码管理器标记为「隐式/瞬态」（`org.nspasteboard.ConcealedType` 等）的内容同样跳过。
- 页面上的开关可以随时暂停/恢复记录（关掉只是不再记新的，已有历史照常保留）。App 没打开该页面时也在记录。

顺带说明：整份历史是**明文**存在本地文件里的（和 `settings.json` 一样），敏感内容请自行用「清空」处理。

### 打开软件时自动启动

侧边栏「设置」页可以勾选「打开 Seraphim 时自动启动 MongoDB / Redis」。本工具**不注册系统级开机自启**（不写 LaunchAgent、不进「登录项」）：只在你打开本软件之后，按勾选把这些服务用本工具自己的启动逻辑拉起来 —— 走的是同一份配置、同一套失败提示，已经在运行就跳过。

### 顶部小组件

侧边栏「小组件 → 顶部小组件」集中管理显示开关和布局。可调整刘海状态宽高、展开宽高、展开态距屏幕顶边及左右边缘的间隙、左右两栏各自宽度、两态不透明度；胶囊态与展开态分别设置液态玻璃效果。展开面板与屏幕边缘留有间隙时，顶部也显示圆角。尺寸支持滑块和精确数值输入。宽度和分栏按屏幕比例保存，切换显示器时随屏幕缩放；macOS 26 以下使用深色底板。收起后鼠标离开再移回可立即展开，也可直接点击胶囊展开。小组件的菜单栏图标还提供「小组件设置…」入口。展开态添加应用时会临时隐藏顶部面板，避免挡住文件选择窗口。

### Python 环境

独立的「Python 环境」页会查找本机 Python、已添加工程内的 venv、常见虚拟环境目录及 pyenv 安装。可以手动添加现有环境目录或解释器，也能选择父目录和基础 Python 新建 venv。环境可从列表移除；确认后还能删除带 `pyvenv.cfg` 的虚拟环境目录，系统 Python 不会作为目录删除。

选中环境后可查看已安装包，并通过该解释器执行 `python -m pip install`。包名支持版本约束和多个包；pip 源可填完整的 HTTP(S) 索引地址，留空则使用 pip 自身的默认配置。手动添加的环境会出现在项目管理的 Python 解释器列表中。环境列表和 pip 源保存在应用支持目录的 `python-environments.json` 中。

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

### 服务器管理与服务器运维

「服务器管理」支持多台服务器连接，已实现「服务器状态」「文件管理」「软件管理」「环境管理」「域名管理」「网站管理」「项目管理」「数据库管理」「防火墙」「计划任务」「软件商店」。Go 服务通过 HTTPS 提供状态、文件、服务、环境、网站、项目、数据库、防火墙规则、计划任务和软件安装 API，客户端不发送 SSH 命令。文件管理可浏览整个服务器文件系统，默认从 `/www/seraphim` 开始，双击文件夹可进入，支持新建、上传下载、覆盖、重命名和删除，不提供内容编辑。网站管理支持 Nginx、Apache、OpenResty 的 HTTP 静态站点与反向代理，可绑定多个域名、启停、修改与删除配置；删除配置会保留网站文件。环境管理集中列出 Python、Go、Node.js、Java、.NET、Ruby、Bun、Deno、PHP，可检查服务器上的实际版本与可执行文件，并安装、卸载及查看日志。项目管理支持 Python、Node.js、Go、Java、.NET、Ruby、Bun、Deno 项目的创建、启停、重启、自启和日志；项目文件位于 `/www/seraphim/projects`。数据库管理显示七种数据库实例；MySQL、MariaDB、PostgreSQL 支持建库、账户和授权管理，Redis、Valkey 支持持久化 ACL 账户、密码重置与只读/读写权限；MongoDB、SQLite 目前显示实例状态。防火墙页支持 firewalld/ufw 简单 TCP/UDP 入站端口规则，计划任务页通过 systemd timer 定时执行结构化配置的程序并显示日志。软件管理展示防火墙及已安装的软件；有常驻服务的软件可控制运行与开机启动，MySQL、Grafana、MinIO 可下载初始密码。软件商店按分类列出 35 款软件，全部具备安装流程，可查看进度与日志，并快捷启动、停止、重启常驻服务。程序统一安装到 `/www/seraphim/server`。连接配置和令牌保存在本机 `~/Library/Application Support/Seraphim/server-management/connections.json`，不使用钥匙串。部署与接口说明见 [server-status/README.md](server-status/README.md)。

「域名管理」把阿里云解析和 acme.sh 证书申请放进同一工作区，选中域名后可管理记录或带入证书申请表单。原有 iCloud 证书备份与复制证书到任意路径的入口已移除。旧「服务器运维」只保留宝塔面板；域名管理和宝塔面板继续共用运维配置：

> **一份配置 = 一个阿里云账号 + 多个宝塔面板 + 一套证书设置。**

切换运维配置时，域名解析、证书申请和宝塔面板仍会一起切换。旧设置首次载入会**自动合并**：按名字把阿里云账号和宝塔面板配成一组，没配上名的并入一份「其余配置」，证书设置复制给每份配置；归得不对在页面上改即可。

### 域名解析（阿里云云解析 / AliDNS）

「服务器管理 → 域名管理」可查看域名、增删改解析记录。AccessKey 属于**当前配置**；证书申请的「阿里云自动验证」用的也是这个账号。

| 功能 | 说明 |
| --- | --- |
| 凭据 | 当前配置的阿里云 AccessKey ID / Secret（一份配置一个账号，换账号就切配置）；旧版的多组凭据与单组凭据都会自动读入。先只支持阿里云一家（设置里留了 `provider` 字段，以后加 Cloudflare / DNSPod 不用动设置文件结构） |
| 域名列表 | `DescribeDomains`：域名、解析记录条数、云解析版本 |
| 解析记录 | `DescribeDomainRecords`：主机记录、类型、值、TTL、线路、状态（ENABLE / DISABLE） |
| 增 / 改 / 删 | `AddDomainRecord` / `UpdateDomainRecord` / `DeleteDomainRecord`；支持 A、AAAA、CNAME、TXT、MX、NS、SRV、CAA，只有 MX / SRV 才要优先级 |
| 本地校验 | 提交前先挡一道：A 记录必须是合法 IPv4、主机记录不能写全域名（只填最左边一段）、MX 必须填 1–50 的优先级 —— 阿里云这些报错文案不好懂，来回一趟也慢 |

**签名是自己算的**：阿里云是 RPC 风格接口，参数要按名字典序排、`percentEncode` 编**两遍**（时间戳里的 `:` 第一次变 `%3A`、第二次变 `%253A`），再 `Base64(HMAC-SHA1(secret + "&", StringToSign))`。工具直接用 `CryptoKit` 算，不引第三方库、也不依赖 `aliyun` CLI —— 只要这台机器能联网就能用。自测里拿官方文档给的那个 `StringToSign` 示例做了逐字比对。

⚠️ AccessKey 明文保存在设置文件里，**强烈建议用只有 `AliyunDNSFullAccess` 权限的 RAM 子账号**：它只能动解析记录，碰不了你账号里别的东西。

### 证书（Let's Encrypt，走 acme.sh）

| 功能 | 说明 |
| --- | --- |
| 申请方式 | **阿里云 DNS 自动**（DNS-01：自动写入/删除 `_acme-challenge` 的 TXT 记录）；**手动 DNS**（工具给出 TXT 记录，你自己加到解析里，再回来点完成签发） |
| 域名 | **手填，或点「从解析记录选…」直接从阿里云解析记录里勾**（`@` 就是主域名本身，子域自动拼成 `admin.example.com`），省得手打拼错；支持多个域名与泛域名（`example.com, *.example.com` —— 泛域名解析记录里没有，只能手填）；密钥可选 ECC（推荐）或 RSA 2048 / 4096 |
| 证书列表 | 主域名、密钥类型、附加域名、下次续期时间、证书路径（可复制）、手动续期 |
| 自动续期 | 一键安装 acme.sh 的续期任务（每天检查，到期前 30 天自动续）。acme.sh 只保存一组全局阿里云凭据；若证书来自不同阿里云账号，请在「域名管理 → 申请与续期」选择对应账号手动续期 |

**为什么走 DNS-01 而不是 HTTP-01**：DNS-01 不需要域名解析到本机、不需要开放 80 端口，而且**能签泛域名** `*.example.com`；代价是需要域名解析的写权限（阿里云就是它的 AccessKey）。

**关于 CA**：acme.sh 新版本默认改用 ZeroSSL，所以工具在每次申请时都显式传 `--server letsencrypt`，确保签出来的是 **Let's Encrypt** 证书。

**首次使用**：域名管理的「申请与续期」页会显示 acme.sh 的安装状态；未安装时可以直接点按钮执行官方安装命令（会显示将执行的完整命令），也可以自己在终端装。签发后如需用于 `sera` 服务端，证书安装仍由管理员手动完成。

⚠️ 阿里云 AccessKey 属于**当前配置**（明文保存在设置文件里），**建议用只有 DNS 解析权限的 RAM 子账号**。申请和手动续期都用当前配置的这个账号；换账号在页面顶部切换配置。

### 宝塔面板（API 集成）

| 功能 | 说明 |
| --- | --- |
| 连接配置 | 一份配置下可挂多个面板，各含地址、API 密钥和 HTTPS 自签证书校验选项，在「宝塔面板」标签页里切换；旧版单面板 / 多面板配置自动读入 |
| 系统概览 | 面板版本、操作系统、CPU 核心、内存、磁盘、负载、运行时长 |
| 服务管理 | Nginx / Apache / OpenResty / MySQL / MariaDB / Redis / MongoDB / Pure-Ftpd / Memcached / PHP / Docker 等一键 **启动 / 停止 / 重启 / 重载** |
| 网站列表 | 网站名、状态、域名、目录；可启停 |
| **新建项目 / 网站** | 点「新建项目」弹出表单，先选**项目类型**（HTML / PHP / 反向代理 / Python / Node / Java / Go / .NET / 其他，共 9 类），字段按类型动态变化。根目录**只填域名**即可（自动补 `/www/wwwroot/`，填绝对路径则原样用）；运行方式 / 包管理器是**下拉**；Python 解释器从面板的**虚拟环境列表**里选；默认值已预填（应用对象 `app`、启动文件 `main.py`、后端地址 `http://127.0.0.1`）。依赖的运行时没装时表单里会提示、创建会被面板拒绝。创建后自动刷新列表 |
| 数据库列表 | 名称、类型、大小 |
| **部署 SSL** | 把「证书」页签发的证书直接提交给面板，配好该网站的 HTTPS（申请 → 部署一条龙） |
| 原始响应 | 每次调用都保留面板返回的原始内容，面板版本差异时方便对照排查 |

**签名规则**：`request_token = md5(request_time + md5(api_sk))`，参数以 form 表单提交。不同面板版本的插件接口偶有差异，所以工具在收到「签名错误」时会**自动改用备选算法重试**，并且**始终保留原始响应**。

**新建项目的两个坑**（都是实测踩出来的）：

1. 路由是**路径式** `POST /project/<类型>/<方法>`，而且**表单里必须再带一个同名的 `action` 字段** —— 只给路径、不给 action，9 类全部返回 404。
2. 参数缺失或内部异常时，面板也会把它吞成 **nginx 404**。所以工具在响应失败时会**回查一次网站 / 项目列表**，名字真的出现了才算创建成功。

9 类项目对应面板源码里的 `/www/server/panel/class/projectModel/` 下 9 个 Model，但**请求路径不统一**（照官方前端抓包）：多数走 `/project/<类型>/<方法>`，**PHP 项目其实是 `/site?action=AddSite`**，**反向代理是 `/mod/proxy/com/create`**。工具只暴露每类的核心必填字段，固定参数（`ftp=false`、`codeing=utf8mb4`、`proxy_host=$http_host` 等）照抄官方前端。

面板接口的整理见 [`docs/baota.json`](docs/baota.json)（OpenAPI 3.0）：鉴权算法、响应约定、各模块 action 与参数，依据面板 13.1.0 的源码与在线实测整理。

⚠️ API 密钥会明文保存在工具的设置文件里，建议只在本机使用。

### AI 开发（codex 无人值守）

把 Codex CLI 当无人值守的开发工人用：你写任务、挑目录、选模型，之后不用守着。

| 功能 | 说明 |
| --- | --- |
| 看门狗 | 在 App 里循环执行 `codex exec`；被 **5 小时用量上限**中断后，解析出「几点恢复」等到那个时间点，再 `codex exec resume --last` 接着同一个会话干，不重复已完成的活 |
| 模型选择 | 模型列表来自 codex 自己（`codex debug models`，读不到时退回 `~/.codex/models_cache.json`、再退回内置列表），账号能用的模型变了界面自动跟上；也可以选「跟随 Codex 配置」 |
| 推理强度 | 按所选模型支持的档位列出（`low / medium / high / xhigh / max / ultra`），带每个档位的说明；改模型时自动落到该模型的默认档 |
| 权限档位 | 默认 `-s workspace-write --approve-for-me`（只在任务目录里读写，越界命令自动审批），另可选「完全放开」与「只读」 |
| 本机代理开关 | 打开时读 macOS 系统代理（`scutil --proxy`）并注入 `HTTP_PROXY / HTTPS_PROXY / ALL_PROXY`（大小写各一份）和 `NO_PROXY`；页面会列出探测结果，也可以手填地址覆盖 |
| **进度探测** | 默认用 `codex exec --json` 事件流：统计每轮跑了几条命令、改了哪些文件、todo 完成到几分之几；日志按人话渲染（`$ 命令` / `✎ 改动文件` / `☐ 计划 1/3`），不再是原始 JSON。**连续两轮「没有任何命令执行和文件改动」就判断它没活可干了，自动收工**——避免自动续跑无限空转烧额度 |
| 续跑控制 | `exit 0` 后可选自动续跑（带间隔）、最多轮次上限、随时停止（`SIGTERM` → 3 秒后 `SIGKILL`）；一键「标记任务完成」写入 `.codex_done`，看门狗下一轮开始前收工 |
| 日志 | 每轮输出实时写进任务目录的 `.dbm-ai-watchdog.log`，页面显示最后几百行；日志里能看到每轮实际执行的完整命令行 |
| **完成判定** | 配了验收命令就以它为准：**全部退出码 0 才算「开发完成」**，模型说 DONE 不算数。开工前跑一次基线并记录哪些命令本来就红（TDD 式需求允许基线红），连续 3 轮验收结果没变化就判定卡住并停下 |
| **审查与修复** | 开发跑完请**另一位模型**（默认 DeepSeek `deepseek-v4-flash`）整体复核一次：送审材料是需求原文 + 每轮自我说明 + 完整 diff（含未跟踪的新文件）+ 验收结果，产出结构化的「必修复清单」；确认要修就**逐条**驱动 codex 修（每条一轮、改完跑验收、连续两轮修不好就停下等你） |
| 页面结构 | 顶部常驻「运行」条（状态 + 开始 / 续跑 / 停止 / 标记完成），下面按 **任务 / 模型与权限 / 代理与环境 / 审查与修复 / 日志** 五个标签页分开，不用一屏滚到底 |

环境要求：本机装好 Codex CLI 并登录过（`codex login`）——工具直接复用 `~/.codex` 的登录态，不需要额外配置。

### AI 云端任务（`codex cloud`）

「丢一句需求 → 云端的沙箱里自己干 → 回来看 diff → 满意就 apply 到本地」。这是**最省事**的一条路：任务在 OpenAI 云端跑，本机可以关掉，也不受本机 5 小时限额和本地沙箱影响。

| 功能 | 说明 |
| --- | --- |
| 派任务 | 写一句需求 → `codex cloud exec --env <环境>`；`best-of-N` 可以让同一需求跑几次取最好（`--attempts`） |
| 任务列表 | `codex cloud list --json`：状态灯（排队 / 进行中 / 完成 / 失败）+ 需求摘要 + 时间；可展开看这条任务的原始 JSON |
| 状态 / 改动 | `codex cloud status` / `codex cloud diff` 的输出直接显示（就是 unified diff，适合直接读） |
| 应用到本地 | `codex cloud apply` 把这条任务的 diff 打到「本地仓库」目录，之后你自己 review、提交 |
| 云端环境 | 环境 ID（一份带仓库的云端沙箱）只能在终端跑 `codex cloud` 浏览/创建——CLI 里没有"列环境"的子命令，所以这里手填一次 |

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

跨平台 Electron 版现已提供服务器管理模块，可打包为 Windows、macOS 和 Linux 客户端。开发命令、产物格式与功能范围见 [Electron 客户端说明](electron/README.md)。原生 macOS 版仍按下文构建。

推送到 `main` 后，GitHub Actions 会自动构建原生 SwiftUI macOS 版和 Electron 的 macOS、Windows、Linux 版。在仓库的 **Actions → Build Seraphim → 对应运行 → Artifacts** 下载压缩包；也可用 `workflow_dispatch` 手动运行。产物保留 30 天。

```bash
# 1) 装数据库本体（本工具不负责安装，只管已有实例）
brew install mongodb-community     # 自带 mongosh
brew install redis

# 2) 构建 app（需要 Swift 编译器和 Go 1.25+，后者用于打包 Linux 服务端）
./build.sh

# 3) 运行
open build/Seraphim.app
```

首次打开若被系统拦下（app 是本机 ad-hoc 签名），在 Finder 里右键 → **打开**。

想装到「应用程序」里，用 `ditto`（不要用 Finder 拖动，拖动会留下替身文件）：

```bash
ditto build/Seraphim.app /Applications/Seraphim.app
```

**遇到问题时**：看 `~/Library/Application Support/DBManager/log/run.log`（记录每次点击执行了什么命令、返回码）和 `crash.log`（崩溃记录）。应用名称已改为 Seraphim，旧数据目录和配置标识继续沿用，以保留现有设置与服务器连接。

---

## 界面结构

```
侧边栏
├── 本地环境管理
│   ├── MongoDB       数据库 / 配置 / 用户与密码 / 日志
│   ├── MySQL         数据库 / 配置 / 用户与密码 / 日志
│   ├── Redis         数据浏览 / 概览 / 配置 / 控制台 / 日志
│   └── Python 环境   本机解释器列表与 pip 源
├── 项目管理       一个项目下的多入口（多个子工程 / 脚本 / 服务）
├── 服务器管理     服务器状态 / 文件 / 软件 / 环境 / 域名解析与证书 / 网站 / 项目 / 数据库 / 防火墙 / 计划任务 / 软件商店
├── 云端任务       派需求到 codex cloud；看状态 / diff；apply 到本地仓库
├── 剪贴板         文本历史：点一条即复制回剪贴板；Redis 缓存 + 本地文件固化（上限 2 MB）
└── 设置           标签页：常规（诊断 / 自动探测 / 打开软件时自动启动）· MongoDB · Redis · MySQL
```

> 顶部小组件的代码仍在（`Docklet*`），但侧边栏入口已撤下 —— 功能还不完善，先不暴露。
> 旧版「服务器运维」（宝塔面板那一套）已整体移除，宝塔相关的源码与设置字段也一并删掉了。

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
| 剪贴板历史（明文、只存文本、上限 2 MB） | `~/Library/Application Support/DBManager/clipboard.json`；同时缓存在 Redis 的 `dbm:clipboard:history` |
| AI 任务的中间产物 | `<任务目录>/.ai/{rounds.md,review-request.md,review-report.md}`（每轮的自我说明、送审材料、审查报告）；看门狗日志与完成标记在任务目录下的 `.dbm-ai-watchdog.log` / `.codex_done` |
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
- **剪贴板只认文本**：轮询系统剪贴板的 `changeCount`（0.7 秒一次，挂在 `.common` RunLoop mode 上，滚动时不漏），只取 `NSPasteboard.string`；图片/富文本在这里就被丢掉，所以固化文件里永远不会出现图片数据。整份历史放 Redis 单个字符串 key（读一次全拿到）+ 本地 JSON 文件（2 MB 上限，超了丢最旧的），写盘与 Redis 同步都走后台串行队列，复制动作不会卡界面。自己写回剪贴板后同步一次 `changeCount`，免得轮询把刚复制的内容又记一遍。
- **不做系统级开机自启**：既没写 LaunchAgent，也没用 `SMAppService`（本 app 是 ad-hoc 签名、常放在 `build/` 下，注册登录项容易失败）。「打开软件时自动启动」只是在 App 启动后按设置调一次本工具自己的 `start()`，先探端口确认没在运行才动手。
- **`--full-auto` 已经不存在了**：codex 0.157 起 `codex exec` 不再接受它（实测报 `unexpected argument '--full-auto'`），照着旧脚本抄会直接起不来。现在按权限档位换成 `-s workspace-write --approve-for-me` / `-s read-only` / `--dangerously-bypass-approvals-and-sandbox`；另外 **`codex exec resume` 没有 `-s`**，所以续跑轮改用 `-c sandbox_mode=…` 覆盖（会话本身也记着首轮的沙箱设置）。
- **等额度要等准**：限额文案里带着恢复时间（`… hit your usage limit … resets at 9:30 PM`），解析出来直接等到那时（+60 秒缓冲）比盲目指数退避到 1 小时省事；解析不出来才退回 300 秒起的指数退避（封顶 1 小时）。解析时 `DateFormatter` 必须设 `defaultDate`，否则没有年份的文案（`Sep 26, 9:30 PM`）会被补成 **2000 年**。
- **别把限额当致命错误**：登录/鉴权类报错（`not logged in` 等）要停下让人处理，但限额提示里也常出现 login / account 字样，所以判定顺序是**先排限额、再判致命**。
- **代理探测**：`scutil --proxy` 的键值分隔是带空格的 ` : `，而 IPv6 地址自己带冒号，不能简单按 `:` 切前一段；注入时代理变量**大小写各写一份**（不同 HTTP 客户端认的名字不同），并补上 `NO_PROXY`（系统例外 + localhost / 127.0.0.1 / ::1）。
- **看门狗只在 App 里跑**：关闭 App（`applicationWillTerminate`）会 `SIGTERM` 掉 codex 子进程，不留后台孤儿；等待限额期间每 0.5 秒检查一次「停止」与完成标记，所以点停止是立刻生效的。
- **事件流的字段名是挖出来的，不是猜的**：`codex exec --json` 没有公开 schema，所以直接从 codex 二进制里的 `ThreadEvent` 定义读出真实名字（顶层 `thread.started` / `turn.started|completed|failed` / `item.started|updated|completed`，item 类别 `agent_message` / `reasoning` / `command_execution` / `file_change` / `todo_list` / `web_search` / `mcp_tool_call`，命令项字段 `command` / `aggregated_output` / `exit_code`）。解析一律宽松：缺字段、改名字、非 JSON（比如 stderr 混进来的告警）都不崩；**只在真收到事件时才做「空转」判断**，所以关掉 `--json` 或解析失败也不会误停。
- **「做完了」怎么判断**：模型不会自己写 `.codex_done`，所以完成信号分两层——① 事件流里**整轮没有任何命令执行和文件改动**（说明它只是说了句话），连续两轮即判定没活可干并收工；② 你手动点「标记任务完成」。前者只在 `autoContinue` 打开时生效，避免自动续跑空转。
- **日志按人话渲染**：开了 `--json` 后 stdout 是一行一个 JSON，直接记下来没法看，所以每条事件都会渲染成 `$ 命令` / `↳ 退出码 1`（失败附输出尾部）/ `✎ 改动文件` / `☐ 计划 1/3` / `✔ 本轮结束（tokens…）`，`item.updated` 这种流式中间态只累计不写日志（否则刷屏）。stderr 单独接管、原样透传，不参与事件解析。
- **「做完了」只能由客观证据说了算**：验收命令全部退出码 0 才算完成，模型输出 DONE 只是参考。开工前跑一次基线并记录哪些命令本来就红——**基线红不拦人**（需求本身可能就是「让失败的测试通过」），防死循环靠的是「连续 3 轮验收结果一模一样就停下」。修复队列要单独加一份：每条必修项一轮、改完立刻验收、连续两轮修不好就停下等你。
- **修复必须分条，不能一次塞一堆**：一次丢 10 条问题给模型，它会顾此失彼、顺手重构别处、只做前两条。所以审查报告的「必修」当队列用，每条一轮、每轮都要求「只修这一条、不要动无关文件」，并且每条都能被验收命令独立验证。
- **审查材料要带「意图」**：光给 diff 看不出"它以为自己做了什么"，所以每轮的 `agent_message` 会记进 `.ai/rounds.md` 一并送审——**意图与实际改动的落差**最容易暴露问题（它说修了 A，diff 里改的是 B）。
- **`git diff` 不包含未跟踪的新文件**：而"它新建了什么"恰恰最需要看，所以未跟踪文件的内容要单独附到 diff 末尾再送审。
- **审查者与开发者异源**：默认用 DeepSeek 而不是同一家的模型，避免"同源盲区"（监督者与被监督者共享同一套偏见时，审查就退化成自我确认）。
- **`codex cloud` 只有 `list` 支持 `--json`**（实测）：所以列表走 JSON 解析，`status` / `diff` / `apply` / `exec` 一律把原始文本交给界面显示——codex 换了文案最多是"不好看"，不会把工具搞崩。任务 JSON 的字段名也靠候选列表宽松匹配（`task_id`/`taskId`、`instructions`/`title`/`query`、`task_status`/`status`…），因为官方没公开 schema；认不出就留空，并保留原始 JSON 供人核对。
- **云端任务不需要本机常驻**：它是「派出去 → 云端自己跑 → 回来收」的模式，所以这页没有看门狗、没有轮询循环——想看了点一下刷新即可（这也正是它比"本地定时轮询 codex"省心的原因）。
- **`codex cloud` 会往当前工作目录写 `error.log`**（名字叫 error，内容其实是 startup/auth/http 的调试日志，实测每次调用都会生成）：所以除了 `apply`（必须在目标仓库里跑，`git apply` 要有上下文），其余命令的 cwd 都切到工具自己的日志目录；`apply` 前后会检查并收掉**新出现的**那个文件，不让它留在用户仓库里。
- 目标 `arm64-apple-macos13.0`，`-Xfrontend -disable-sandbox` 是编译期需要（`@State` 等 SwiftUI 宏要跑 `swift-plugin-server`）。

---

## 自测

```bash
./tests/run.sh
```

自测覆盖：配置行级读写（mongod.conf / redis.conf / my.cnf 三种格式）/ 注释保留 / CRLF 处理 / 命令解析 / RESP 客户端 / SCAN 与各类型值解析 / 概览统计 / 配置备份 / 缺依赖时的降级提示 / 进程归属校验 / 日志脱敏 / 设置的宽松解码 / 剪贴板历史（2 MB 上限裁剪、按 UTF-8 字节安全截断、去重合并、文件与 Redis 的读写往返、Redis 不可用时的降级） / **域名解析页的阿里云签名（拿官方文档的 `StringToSign` 示例逐字比对，含 `:` 变 `%253A` 的两次编码）、域名与解析记录的宽松解析（字段名/类型都能变、单条也认）、A / MX 等记录类型的本地校验、错误码翻译、以及旧设置合并成「服务器运维配置」的一次性迁移（按名称把阿里云账号与宝塔面板配对成组、其余合成一组、证书设置复制到每组）与多配置的切换 / 增删** / MySQL 的 SQL 转义与库名校验 / acme.sh 输出解析（手动 TXT 记录、证书列表）/ 宝塔 API 的 MD5 与签名算法、响应判定与网站解析 / **AI 页的 `scutil --proxy` 解析与代理环境变量注入、限额文案里的恢复时间解析（ISO / 本地时间 / `9:30 PM` / 跨天）、codex 参数构造（首轮与 resume 轮的沙箱参数差异）、模型目录解析、`codex exec --json` 事件解析与 humanLine 渲染（命令 / 改动文件 / todo / tokens）、空转轮次判定、审查报告的 Markdown 解析（必修 / 建议 / 存疑、位置与验收方式抽取）、审查者请求体与响应解析、验收命令判定与自动探测（npm 假 test 脚本识别）、git 材料收集的错误路径、`codex cloud` 任务 JSON 的宽松解析与状态归一**，并用 mongosh 桩**真实执行**了生成的建库·改密码·删库·建管理员·重置密码脚本（本机没装 mongosh 时自动跳过），还包括配置项类型与密码生成器（长度 / 字符集 / 200 轮随机验证）的断言。
Redis 部分用**进程内假服务器**（自动挑空闲端口），所以**不需要真的装 MongoDB 或 Redis**。

---

## 已知限制

- Redis 集合类内容最多展示前 200 项（`set` 为随机取样），string 预览 8000 字符。
- MongoDB 侧只做服务、库、用户管理，不提供集合内文档浏览。
- 一次只管一组配置（单实例），不支持多实例切换。
- 不做安装/卸载数据库本体。
- 「AI 开发」页只驱动本机已登录的 `codex`，不做额度兜底：GPT 的 5 小时窗口耗尽时看门狗只等到恢复时间再续跑，不会切别的模型顶上。
- 「任务完成」没有可靠的自动判定：现在是「连续两轮没有任何命令执行和文件改动」这个启发式 + 你手动点「标记任务完成」。纯问答类任务（本来就不改文件）跑两轮就会收工，点「续跑最近会话」即可继续。

---

## 设计考量：为什么不用本地小模型当看门狗

评估过「本机跑本地模型来当无人值守看门狗」，结论是**不接入**，记录理由备查（结论基于本机实测：Apple M5 Pro / 24 GB）。

**先纠正一个常见前提**：7B 不是这台机器的上限。7B Q4 只占约 4.5 GB，而 24 GB 内存实际能喂给模型的有 14–18 GB —— 能跑 **gpt-oss-20b**（MXFP4 约 12–13 GB，也正是 codex 唯一内置适配的 OSS 模型：二进制里 `oss-20b`、`oss-120b` 0 次）或 14B 稠密；Qwen3-30B-A3B 勉强。所以「本机最好的」是 gpt-oss-20b 这一档，用 7B 属于白扔一半内存。

**"看门狗"其实是三个角色，分别看**：

| 角色 | 要求 | 结论 |
| --- | --- | --- |
| 替代 GPT 做开发主力 | 长程规划、工具调用可靠、长上下文 | ❌ 20B 级与前沿模型在 agentic 编程上差几十个百分点，且更爱幻觉 API、忽略约束；**无人值守会放大它**（没人看着，它会自信地改坏） |
| 确定性判断（限额 / 退出码 / 有没有干活） | 机械判断 | ⛔ 不需要 LLM。规则 + `--json` 事件流比小模型准，而且已经实现 |
| 模糊监督（改动合不合理、算不算做完） | 识别执行者的细微错误 | ⚠️ 收益低：**监督者看不穿比它强的执行者**——GPT-6 的错误多是设计走偏、边界漏这类细节，弱模型只会觉得"看起来都对"；**同源监督更是等于自我确认**（7B 监督 7B 零信息量） |

**弱模型最不擅长的地方，恰好就是"模糊监督"唯一需要它的地方；而它擅长的机械计数，规则已经做得更好。**

如果将来要做，有价值的定位不是"监督者"，而是：

1. **额度耗尽时的兜底执行者**：切 `codex exec --oss --local-provider ollama -m gpt-oss:20b` 去干被严格限定的低风险活（跑测试、修 lint、补测试、写文档），本地不烧额度。前提是 git worktree 隔离 + 测试验收，改坏能回滚。
2. **确定性验收**：每轮跑测试 + 检查 `git diff` 有没有越界改文件，不通过就停下等人 —— 这条**用规则实现，别交给小模型**。
3. **进度摘要**：本地小模型把每轮日志压成两三句写进 `progress.md`，不参与决策，错了也无害。

当前选择：**云端模型开发 + 规则/事件流裁决 + 另一位云端模型（默认 DeepSeek）做交付审查 + 人来决定修不修**。

注意审查者这条路我们**没有**用本地小模型，而是用了另一位云端模型：审查只在交付后跑一次（不需要 24/7 常驻，所以本地模型"免费"的优势没用），但对判断力要求很高（要看出设计走偏、幻觉出的待办、越界改动）——这正是 7B/20B 最弱的环节。选 DeepSeek 而不是同一家的模型，是为了**异源**：监督者与被监督者共享同一套偏见时，审查就退化成自我确认。
