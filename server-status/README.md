# Seraphim 服务器 API

Linux 服务端是 Go 标准库编写的单个 `sera` 可执行文件。SwiftUI 客户端只发送 HTTPS API 请求，不发送 SSH 命令。当前提供服务器状态、文件、软件、环境、网站、项目、数据库、防火墙规则和计划任务管理。

## 构建

开发机需要 Go 1.25 或更新版本；服务器无需安装 Go 或 Docker。

```sh
cd server-status
go test ./...
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags='-s -w' -o ../build/sera-linux-amd64 .
# ARM 服务器将 GOARCH 改为 arm64、输出文件名改为 sera-linux-arm64。
```

## 目录布局

新安装和后续运行环境、网站、下载包、备份及日志统一放在 `/www/seraphim`：

| 目录 | 用途 |
| --- | --- |
| `/www/seraphim/server` | `sera` 程序和后续运行环境；`config/` 存放 HTTPS 证书、私钥、API 令牌 |
| `/www/seraphim/server/tasks` | 计划任务定义和上次执行结果，文件权限 `0600` |
| `/www/seraphim/web` | 网站文件 |
| `/www/seraphim/sites` | 网站定义及各 Web 服务加载的站点配置 |
| `/www/seraphim/projects` | 项目配置及各项目可写的 `data/`；默认工程目录也位于此处 |
| `/www/seraphim/download` | 下载的安装包 |
| `/www/seraphim/backup` | 备份 |
| `/www/seraphim/logs` | 服务日志；API 服务写入 `sera.log`，计划任务日志位于 `tasks/` |
| `/www/seraphim/tmp` | 临时工作目录 |

软件商店中的 35 款软件分别安装到 `/www/seraphim/server/{id}`。持久化数据保存在对应软件目录的 `data/`，下载包放在 `/www/seraphim/download`，安装与运行日志放在 `/www/seraphim/logs`。编译依赖和共享库可能由系统的 apt 或 dnf 安装；软件本体和自带运行环境位于指定目录。常驻服务的 systemd 单元作为启动入口，保存在 `/etc/systemd/system`；工具链与 Podman 没有常驻服务。卸载先停止并禁用服务，再移除该软件的安装目录和服务单元；可选择把完整目录移到 `/www/seraphim/backup/software`（仍占用磁盘空间），或连同配置和数据彻底删除。系统依赖包、下载缓存及共享日志不会随卸载删除。

网站管理要求先从软件商店安装 Nginx、Apache 或 OpenResty。三者分别监听 HTTP 80、8082、8083 端口。静态和 PHP 网站使用 `/www/seraphim/web/{服务}/{首个域名}`；PHP 网站需先安装相应版本的 PHP，网站配置会将 `.php` 请求转发到该版本的 FPM。启用网站时会启动所选 Web 服务及 PHP-FPM。静态网站拒绝直接读取 `.php` 源码。反向代理可指向 HTTP/HTTPS 上游。每次变更都会先检查 Web 服务配置，再在服务运行时重载；检查或重载失败则恢复原配置。删除网站仅删除站点定义和 Web 服务配置，保留网站目录。网站证书尚未由此页面部署，当前创建的是 HTTP 站点。

环境管理从各软件官方发布源读取版本和下载校验值，查询结果缓存 15 分钟。新版本安装在 `/www/seraphim/server/{id}/versions/{version}`，可与同种环境的其他版本并存；升级前的 `/www/seraphim/server/{id}` 仍被识别为旧版安装。安装包下载后验证发布源提供的 SHA-256 或 SHA-512，客户端仅选择版本，不传下载地址或命令。项目管理可指定已安装的运行环境版本；旧项目继续使用原有路径。PHP 每个新版本拥有独立的 FPM 服务和 Unix socket。环境管理不会修改系统全局 PATH。

项目管理支持 Python、Node.js、Go、Java JAR、.NET DLL、Ruby、Bun 和 Deno 常驻项目。可以先创建项目配置，再安装运行环境并选择版本。工程目录默认是 `/www/seraphim/projects/{项目标识}`，也可以指定服务器上已有的绝对目录；入口相对于工程目录。Go 的入口可为 `.` 或 `.go` 文件。Python 项目可使用位于管理目录 `data/venv` 的独立虚拟环境，并通过接口安装工程目录中的 `requirements.txt`。`PORT` 是可选的环境变量，反向代理可在网站管理中手动指向 `http://127.0.0.1:{端口}`。项目由独立的 `sera-project` 系统账户运行，工程目录在服务中只读，项目 `data/` 可写；服务日志位于 `/www/seraphim/logs/projects`。可以查看运行状态、启停、重启、设置开机启动及读取日志。删除项目会停用服务并删除项目定义，但保留源文件、数据和日志。客户端只传结构化项目配置和固定动作，服务端生成 systemd 单元，不接受任意命令文本。

数据库管理显示 MySQL、MariaDB、PostgreSQL、MongoDB、Redis、Valkey、SQLite 七种实例的安装与运行状态。MySQL、MariaDB、PostgreSQL 可建库、删库、建用户、重置密码、删除用户、授予只读或读写权限以及撤销权限。用户密码由服务端随机生成，创建或重置时返回一次；管理接口只接收结构化字段，服务端执行固定数据库客户端与限定的 SQL 模板。MySQL 首次使用时可把安装生成的临时 root 密码更换为管理密码，保存在 `/www/seraphim/server/mysql/sera-admin-password`，权限为 `0600`；已有密码也可验证后保存。PostgreSQL 新安装默认支持本机 SCRAM 密码连接，旧安装可在界面显式启用并重启；不会对外网开放数据库端口。PostgreSQL 对现有表、序列和 `public` schema 授权，其他 schema 与未来由别的账户创建的对象需要另行配置。Redis、Valkey 支持 ACL 账户创建、删除、停用、密码重置及只读/读写权限切换；权限作用于该实例的全部键，默认账户和自定义 ACL 账户在界面中受保护。新安装默认把 ACL 文件放在各自的 `data/users.acl`；旧安装可在界面启用持久化，服务会重启一次。ACL 文件和数据目录分别限制为 `0600` 与 `0700`，普通账户密码仅在创建或重置时显示一次。若已有默认账户密码，须先在界面验证并保存。MongoDB、SQLite 目前只提供实例总览。

防火墙规则页支持正在运行的 firewalld 或 ufw，展示当前活动区域中的直接端口规则，支持添加、删除 TCP/UDP 入站端口。firewalld 会同时写入运行配置与持久配置，不触发全量重载；ufw 使用自身规则命令。SSH 默认端口 22 和 API 端口 27520 的规则禁止从此页删除。界面只删除 ufw 对所有来源开放的简单规则，不会更改限定来源的规则；firewalld 服务规则、富规则及云安全组不在本页管理。防火墙服务启停仍位于「软件管理」。

计划任务页按每小时、每天或每周运行程序。客户端传结构化的程序绝对路径、逐项参数、工作目录和时间；服务端生成 systemd timer，运行时由 `sera task-run` 直接执行程序，不经过 shell 或 SSH。任务以服务端的 root 身份运行，因此只应给可信管理员连接令牌。程序标准输出与错误输出写入 `/www/seraphim/logs/tasks/{id}.log`；界面可查看末尾 64 KiB。删除任务会停用并删除定时器和定义，日志保留。

新服务器可在桌面端「服务器管理 → 服务器状态 → 安装服务端…」选择命令行或 SSH 安装。两种方式都使用应用内置的 Linux 二进制；服务器无需 Go 或 Docker。命令行方式先导出与 `uname -m` 匹配的文件，上传至服务器，然后以 root 执行（将示例 IP 换成实际客户端访问的 IP 或域名）：

```sh
chmod 755 /tmp/sera-install
sudo /tmp/sera-install install -host 203.0.113.10
```

`install` 创建约定目录，将自身复制到 `/www/seraphim/server/sera`，生成一年有效的自签证书及随机 256 位令牌，写入 systemd 单元并启动服务，最后打印 HTTPS 地址、API 令牌和证书 SHA-256 指纹。若已有程序、单元或凭据，安装器拒绝覆盖。启动失败时清理本次创建的安装文件。SSH 方式会识别 x86_64/aarch64 架构、上传安装文件、运行相同命令，并把连接信息保存到桌面端；SSH 密码只在安装期间使用，不保存。首次 SSH 连接由应用记录主机公钥，保存在本机应用数据目录的 `ssh_known_hosts`；之后密钥变化会在安装窗口显示此前和当前的指纹，由用户决定是否更新。非 root 用户须具有 sudo 权限，可填写 sudo 密码或使用免密 sudo。

服务端仅支持运行 systemd 的 Linux 系统，不依赖发行版的 apt 或 dnf。安装后仍需在主机防火墙及云安全组放行 TCP 27520。`init` 仍可用于手动初始化凭据，不会覆盖现有凭据。令牌存放于 `/www/seraphim/server/config/token`，配置目录为 `0700`，私钥与令牌为 `0600`。服务名沿用 `server-status` 方便已有安装升级；命令行程序名为 `sera`。

升级已有安装时，先把新二进制上传为服务器上的 `/tmp/sera-new`，再以 root 执行：

```sh
cp -p /www/seraphim/server/sera /www/seraphim/server/sera.backup
install -m 0755 /tmp/sera-new /www/seraphim/server/sera.new
mv /www/seraphim/server/sera.new /www/seraphim/server/sera
systemctl restart server-status
systemctl is-active server-status
```

若服务未恢复为 `active`，将 `sera.backup` 复制回 `sera` 并再次重启。升级不会覆盖连接令牌、证书或已有站点与数据库。计划任务生成的 systemd 单元始终调用固定路径 `/www/seraphim/server/sera`。

服务通过 HTTPS 监听 `27520`。文件管理覆盖整个服务器文件系统，服务管理能控制防火墙的 systemd 单元，因此服务以 root 运行；持有连接令牌的人可以进行服务器操作。云安全组应只允许自己的客户端来源地址访问 27520，令牌只保存在可信设备。上传默认不覆盖，目录递归删除必须显式请求；根目录、常见系统顶层目录和上述固定布局目录不可整体删除或重命名。文件或目录内的普通条目仍按系统权限操作，软链接不能作为路径穿越。

## 手动绑定域名和正式证书

域名解析、证书签发和安装由管理员完成。先将域名指向服务器，取得覆盖该域名的 PEM 全链和私钥，然后放到 `/www/seraphim/server/config/tls`，私钥设为 `0600`。将 systemd 服务的 `ExecStart=` 改为：

```ini
ExecStart=/www/seraphim/server/sera serve -listen 0.0.0.0:27520 -dir /www/seraphim/server/config -files-root / -cert-file /www/seraphim/server/config/tls/fullchain.pem -key-file /www/seraphim/server/config/tls/privkey.pem -domain status.example.com
```

将域名换成实际值，运行 `systemctl daemon-reload && systemctl restart server-status`。启动时会检查证书、私钥和域名是否匹配。续期后替换文件并重启服务。桌面端填写 `https://status.example.com:27520`；受 macOS 信任的正式证书可留空指纹，自签证书必须填写指纹。域名管理页的 acme.sh 在 Mac 上运行，证书文件用于服务器时仍需手动安装。

## 桌面端连接

Seraphim「服务器管理 → 服务器状态」支持保存多台服务器。每台填写 HTTPS 地址、API 令牌和自签证书的 SHA-256 指纹。配置统一保存在本机 `~/Library/Application Support/Seraphim/server-management/connections.json`，目录权限 `0700`、文件权限 `0600`，不使用 macOS 钥匙串。状态每 5 秒刷新一次；「文件管理」初始位置为 `/www/seraphim`，可浏览整个服务器文件系统，双击文件夹可进入。「软件管理」展示已安装软件和一个防火墙服务；防火墙优先显示正在运行的服务，均未运行时依次选择 firewalld、ufw、nftables、iptables。运行和开机状态显示中文，可执行启动、停止、重启、启用、禁用；操作前会要求确认，启动和开机启用防火墙时提醒检查管理端口。

「软件商店」位于服务器管理最后，按分类列出 Web 服务、数据库、缓存与消息、运行环境、容器工具、监控搜索等 35 款软件；全部都有独立安装流程。安装器下载经过校验的发布包或源码，vsftpd 从 Linux 内核镜像站获取与上游相同的源码包，并校验固定的 SHA-256 或 SHA-512 值；原有 MySQL 安装器使用官方 GPG 签名和 MD5 校验。下载缓存也会重新校验。如果系统已有 aria2，安装器会使用分段下载；否则使用 curl。编译类安装器使用单线程，以降低峰值内存。源码编译和大包解压可能耗时较久，后台任务最长允许 3 小时；界面会显示阶段与日志。同一时刻只允许一个安装任务，安装完成后不自动启动或启用开机自启。

安装器支持带 systemd 的 apt 系发行版（如 Ubuntu、Debian）和 dnf 系发行版（如 Alibaba Cloud Linux、RHEL 系、Fedora）。依赖包名称由安装器映射，安装前会更新 apt 软件包索引。Caddy、Traefik、OpenJDK、Kafka、Prometheus 等使用独立的官方二进制包，可在受支持的 Linux 架构上安装。MySQL、MariaDB、MongoDB、Docker、Grafana、Elasticsearch、OpenSearch 的本轮固定包仅面向 x86_64。界面会根据架构、systemd 和包管理器禁用不支持的安装按钮。Alpine/OpenRC、zypper、pacman 等组合尚未适配。Podman 无常驻服务；Docker 使用 `/www/seraphim/server/docker/run/docker.sock`，不会占用系统默认 Docker 套接字。Kafka 将自带所需 JDK；RabbitMQ 将在自己的目录内编译 Erlang/OTP；MinIO 与 Podman 将自带或复用商店安装的 Go 工具链。

若服务器无法直连某个官方发布地址，可由管理员先把该脚本指定文件名的安装包放入 `/www/seraphim/download`，再从软件商店安装。校验值不匹配会直接失败。安装器源码在 [`installers/`](installers/)；该目录列出支持的版本、下载地址和校验值。安装失败会回滚本次创建的软件目录和 systemd 单元；已安装的系统依赖包和下载缓存会保留。

MinIO 源码编译需要 Go 模块代理。安装器先探测 `proxy.golang.org`，不可达时改用 `goproxy.cn`，两者均不可达则直接连接模块源。服务器管理员可通过 `SERA_GOPROXY` 环境变量指定自己的代理地址。

MySQL 默认只监听 `127.0.0.1:3306`；初始化的临时 root 密码保存在 `/www/seraphim/server/mysql/initial-root-password`（`0600`）。Grafana、MinIO 也会生成初始管理密码文件，可在「软件管理」下载。Redis 默认只监听 `127.0.0.1:6379`，设置 128 MiB 数据上限和 AOF 持久化；PHP-FPM 默认只监听 `127.0.0.1:9000`，还需在网站配置中添加 FastCGI 转发。新增数据库、消息与监控服务默认仅监听本机或 Unix 套接字。Elasticsearch 和 OpenSearch 启动前还需要满足内存与 `vm.max_map_count` 要求。

## 运行环境版本

「环境管理」中的 Python、Go、Node.js、OpenJDK、.NET、Ruby、Bun、Deno 和 PHP 从发布源动态获取当前架构可安装的版本。各版本独立安装在 `server/{id}/versions/{version}`，可同时存在；升级前的旧版安装路径继续识别。已安装版本在列表和选择菜单中标明，安装目录中的工具可逐个检查。软件商店继续提供其默认版本的安装入口。

## HTTPS API

所有路由都要求 `Authorization: Bearer <token>`。无令牌或令牌错误返回 401；没有修改文件内容的编辑接口。

| 方法与路径 | 功能 |
| --- | --- |
| `GET /v1/status` | CPU、内存、交换空间、磁盘、网卡速率和主机运行时间；JSON `schema_version: 1` |
| `GET /v1/files?path=/...` | 列出目录，返回名称、类型、八进制权限、大小和修改时间 |
| `POST /v1/files` | JSON `operation=mkdir` 新建目录、`touch` 新建空文件、`rename` 重命名或移动、`chmod` 修改权限（`permissions` 为 `0644` 等八进制字符串）；重命名可显式设 `overwrite=true` 覆盖普通文件 |
| `PUT /v1/files/content?path=/...&overwrite=true` | 流式上传文件，默认不覆盖；新普通文件权限 `0644`，网站文件始终为 `0644`，受管理的项目文件保持 `0600` 且归项目用户所有，覆盖其他文件时保留原权限与所有者；单文件上限 2 GiB；同目录临时文件写完后原子替换 |
| `GET /v1/files/content?path=/...` | 流式下载普通文件，支持 HTTP Range |
| `DELETE /v1/files?path=/...&recursive=true` | 删除文件或目录；非空目录必须显式请求递归删除 |
| `GET /v1/services` | 最多返回一个受支持的防火墙 systemd 服务及其状态 |
| `POST /v1/services` | 只接受当前选中的防火墙 `.service` 单元；`action` 仅可为 `start`、`stop`、`restart`、`enable`、`disable`，不接受命令文本 |
| `GET /v1/software` | 分类软件目录、安装可用性、安装阶段、运行状态、日志位置 |
| `POST /v1/software/{id}/install` | 启动单个后台安装任务；运行环境可传 JSON `version`，只接受服务端列出的版本，省略时使用默认版本；返回 202 |
| `POST /v1/software/{id}/uninstall` | JSON `mode` 为 `backup` 或 `purge`，启动后台卸载任务，返回 202 |
| `GET /v1/software/{id}/log` | 读取该软件最近一次安装或卸载操作日志的末尾 16 KiB |
| `POST /v1/software/{id}/service` | JSON `action` 为固定的启动、停止、重启、启用或禁用动作；仅操作已安装且有常驻服务的 `sera-*.service` |
| `GET /v1/environments` | 列出九种运行环境及各自已安装版本、状态、目录和预设工具路径，不执行工具 |
| `GET /v1/environments/{id}/versions` | 从官方发布源获取当前架构可安装的版本 |
| `POST /v1/environments/{id}/install` | 按请求中的 `version` 安装到独立目录，不覆盖已有版本 |
| `POST /v1/environments/{id}/versions/{version}/check` | 验证指定已安装版本的工具 |
| `POST /v1/environments/{id}/versions/{version}/uninstall` | 备份或删除指定版本 |
| `POST /v1/environments/php/versions/{version}/service` | 启停指定版本的 PHP-FPM |
| `POST /v1/environments/{id}/check` | 检查旧版安装路径中的工具；新安装请使用指定版本的检查接口 |
| `GET /v1/sites` | 列出网站和 Nginx、Apache、OpenResty 的安装、运行及端口状态 |
| `POST /v1/sites` | 创建网站；JSON `provider`、`domains`、`kind`（`static` 或 `proxy`）、`upstream`、`enabled`；返回 201 |
| `PUT /v1/sites/{provider}/{id}` | 修改域名、类型、上游或启用状态；配置检查通过后生效 |
| `DELETE /v1/sites/{provider}/{id}` | 删除网站配置，保留 `/www/seraphim/web` 下的文件 |
| `GET /v1/projects` | 列出项目及八种运行环境的安装状态 |
| `POST /v1/projects` | 创建项目，接收 `id`、`name`、`runtime`、`runtime_version`、`directory`、`entry`、`port` 和 Python 的 `use_venv`；运行环境可稍后安装 |
| `PUT /v1/projects/{id}` | 更新项目；运行中的项目自动重启，失败时恢复原配置 |
| `POST /v1/projects/{id}/action` | 仅接受 `start`、`stop`、`restart`、`enable`、`disable` |
| `POST /v1/projects/{id}/venv` | Python 项目虚拟环境操作，`action` 为 `create` 或 `install_requirements`；直接运行所选解释器，不接受命令文本 |
| `GET /v1/projects/{id}/log` | 读取最近 64 KiB 项目日志 |
| `DELETE /v1/projects/{id}` | 删除项目服务和定义，保留项目文件及日志 |
| `GET /v1/databases` | 七种数据库实例的安装、运行、端口和认证状态 |
| `GET /v1/databases/{engine}/catalog` | 列出 MySQL、MariaDB 或 PostgreSQL 的数据库与账户 |
| `POST /v1/databases/{engine}/databases` | 创建数据库；名称由服务端校验 |
| `DELETE /v1/databases/{engine}/databases/{name}` | 删除非系统数据库及其中数据 |
| `POST /v1/databases/{engine}/users` | 创建账户并返回一次随机密码 |
| `POST /v1/databases/{engine}/users/{name}:reset` | 重置账户密码并返回新密码 |
| `DELETE /v1/databases/{engine}/users/{name}` | 删除非系统账户 |
| `POST /v1/databases/{engine}/grants` | 给账户授予指定数据库的只读或读写权限 |
| `DELETE /v1/databases/{engine}/grants` | 撤销指定账户在数据库上的权限 |
| `POST /v1/databases/mysql/bootstrap` | 用安装时的临时密码初始化 MySQL 管理密码 |
| `POST /v1/databases/mysql/credential` | 验证并保存已有 MySQL 管理密码 |
| `POST /v1/databases/postgresql/local-access` | 为旧版安装启用本机密码连接并重启 PostgreSQL |
| `GET /v1/databases/{redis|valkey}/acl` | 列出 ACL 账户与持久化状态，不返回密码哈希 |
| `POST /v1/databases/{redis|valkey}/acl/enable` | 为旧安装启用 ACL 文件并重启服务 |
| `POST /v1/databases/{redis|valkey}/acl/credential` | 验证并保存已有默认账户密码 |
| `POST /v1/databases/{redis|valkey}/acl/users` | 创建只读或读写账户，返回一次随机密码 |
| `PUT /v1/databases/{redis|valkey}/acl/users/{name}` | 更新账户启用状态和权限 |
| `POST /v1/databases/{redis|valkey}/acl/users/{name}:reset` | 重置密码并返回一次新密码 |
| `DELETE /v1/databases/{redis|valkey}/acl/users/{name}` | 删除非系统账户 |
| `GET /v1/firewall` | 当前 firewalld/ufw 后端、区域和简单入站端口规则 |
| `POST /v1/firewall` | 结构化 `action=add/remove`、`port`、`protocol=tcp/udp`；禁止删除管理端口规则 |
| `GET /v1/tasks` | 列出计划任务与上次执行结果 |
| `POST /v1/tasks` | 创建计划任务，传标识、频率、时间、程序、参数、工作目录和启用状态 |
| `PUT /v1/tasks/{id}` | 更新计划任务并同步 systemd timer |
| `DELETE /v1/tasks/{id}` | 停用并删除计划任务，保留日志 |
| `GET /v1/tasks/{id}?view=log` | 读取该任务日志末尾 64 KiB |

文件 API 路径为绝对路径；软链接可在列表中看到，但不能通过它进入目录或下载目标。文件上传时不读取整份文件到内存。系统状态内存“已用量”按 `MemTotal - MemAvailable` 计算；磁盘可用量是普通用户可用空间，可能与总量减已用量不同。
