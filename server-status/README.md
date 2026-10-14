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

软件商店中的 35 款软件分别安装到 `/www/seraphim/server/{id}`。持久化数据保存在对应软件目录的 `data/`，下载包放在 `/www/seraphim/download`，安装与运行日志放在 `/www/seraphim/logs`。安装和卸载进入串行任务队列，任务列表显示进度，并允许停止排队或正在运行的任务；停止后如留下部分安装目录，需先清理再重新安装。编译依赖和共享库可能由系统的 apt 或 dnf 安装；软件本体和自带运行环境位于指定目录。常驻服务的 systemd 单元作为启动入口，保存在 `/etc/systemd/system`；工具链与 Podman 没有常驻服务。卸载先停止并禁用服务，再移除该软件的安装目录和服务单元；可选择把完整目录移到 `/www/seraphim/backup/software`（仍占用磁盘空间），或连同配置和数据彻底删除。系统依赖包、下载缓存及共享日志不会随卸载删除。

文件管理页浏览服务器文件系统（默认从 `/www/seraphim` 开始，服务端以 `-files-root` 限定可触达范围），列表逐项显示权限与所有者，点击即可修改：权限是三位或四位八进制，所有者与用户组可填账户名或数字 ID，用户组留空表示保持不变，改目录时可勾选递归应用到全部子项。账户表来自 `/etc/passwd`、`/etc/group` 的一次扫描（缓存 15 秒，查不到时退回 `os/user`），因此列表不会为每个文件反复读盘。递归改属会跳过面板自己的元数据文件 `.sera-project.json` 与 `.sera-account`，项目进程因此改不掉自己的身份配置；软链接既不跟随也不改动。账户不存在时接口返回 422，界面提示「指定的用户或用户组不存在」。固定目录本身（`/`、`/etc`、`/www`、`/www/seraphim` 及各服务目录）不允许改属或删除，目录内部的条目不受这条限制。

网站管理要求先从软件商店安装 Nginx、Apache 或 OpenResty。三者分别监听 HTTP 80、8082、8083 端口。静态和 PHP 网站使用 `/www/seraphim/web/{服务}/{首个域名}`；PHP 网站需先安装相应版本的 PHP。静态网站拒绝直接读取 `.php` 源码。反向代理可指向 HTTP/HTTPS 上游。每次变更都会先检查 Web 服务配置，再在服务运行时重载；检查或重载失败则恢复原配置。删除网站仅删除站点定义和 Web 服务配置，保留网站目录。证书可在桌面端「域名管理」签发后选择服务器和网站部署；服务端验证证书、私钥及全部网站域名，写入 `/www/seraphim/sites/certificates/{服务}/{网站}`，在 443 端口启用 HTTPS 并重载。也可以直接在「网站管理」的每个网站上部署证书：点「部署证书/更换证书」会列出本机 acme.sh 已签发的证书（覆盖本站域名的排在前面并标注未覆盖的），选中即上传部署，不必再切换页面。网站列表还会带出已部署证书的到期时间、覆盖域名与签发者——这三项由服务端在列表时现读证书文件算出，不写进网站元数据，所以续期后立刻显示新日期；证书文件丢失时（手工清理或只恢复了一半的备份）保存网站会把 `tls` 自动纠正为 false，避免 vhost 一直引用不存在的证书、导致之后每次保存都因配置检查失败而报错。不同 Web 服务不能同时占用 443，同一个 Web 服务下的多个网站可以各自部署证书、按域名（SNI）区分；证书续期后需再次部署。删除网站会删除服务端证书，网站文件保留。

网站和项目都以同一个共享账户 `sera` 运行，服务器上只有两种身份：root（主程序，负责 systemd、绑端口、写 `/etc`）与 `sera`（其余一切业务进程）。站点目录 `/www/seraphim/web/{服务}/{首个域名}` 归 `sera` 所有、权限 `0750`，PHP 也以 `sera` 运行，因此它能在自己的目录里写文件、建上传目录（装插件、写缓存不再 Permission denied）。Nginx、OpenResty 的 `user` 指令与 Apache 的 `User`/`Group` 同样指向 `sera`，工作进程天然读得到站点内容、也连得上 PHP-FPM socket。数据库、中间件这些各有独立账户的软件既不是属主也不在 `sera` 组，读不到站点目录。共享一个身份意味着网站之间、项目之间彼此可读写——这是为了把权限模型压成两层而有意接受的取舍，排错时不必再猜某个目录归哪个账户所有。

PHP 网站的 `.php` 请求转发到所选版本的共享 FPM 实例：默认安装监听 `127.0.0.1:9000`，`versions/` 下的多版本安装用各自前缀里的 `run/php-fpm.sock`。启用网站时面板会确保该版本的 FPM 已启动，并把早期安装残留的 `seraphim-web` 账户校正为 `sera`——单元、池配置、socket 目录与日志属主一并改写，然后重启一次该 FPM。Apache 的 `User`/`Group` 也会在写入 vhost 时收敛到 `sera`。

环境管理从各软件官方发布源读取版本和下载校验值，查询结果缓存 15 分钟。新版本安装在 `/www/seraphim/server/{id}/versions/{version}`，可与同种环境的其他版本并存；升级前的 `/www/seraphim/server/{id}` 仍被识别为旧版安装。安装包下载后验证发布源提供的 SHA-256 或 SHA-512，客户端仅选择版本，不传下载地址或命令。项目管理可指定已安装的运行环境版本；旧项目继续使用原有路径。环境管理的 PHP 每个版本有独立的 FPM 服务和监听地址，网站服务的 PHP 请求就转发到所选版本的这个实例。环境管理不会修改系统全局 PATH。

项目管理支持 Python、Node.js、Go、Java JAR、.NET DLL、Ruby、Bun 和 Deno 常驻项目。可以先创建项目配置，再安装运行环境并选择版本。工程目录默认是 `/www/seraphim/projects/{项目标识}`，也可以指定服务器上已有的绝对目录；入口相对于工程目录。Go 的入口可为 `.` 或 `.go` 文件。.NET 工程如果是**自包含发布**（`dotnet publish --self-contained`），启动命令直接执行工程自带的可执行文件、使用自带的运行时——服务器上不装 dotnet 也能启动，自检的「运行环境」一条相应显示「自包含发布」；框架依赖发布的工程仍用面板装的 dotnet 运行入口 dll。自包含的两种形态都认：入口 dll 同名的可执行文件与 `libcoreclr.so` 都在发布目录里（普通自包含），或者入口本身就是一个无扩展名的可执行文件（`PublishSingleFile` 单文件发布，目录里没有 dll）。上传丢掉的可执行位会在识别出自包含布局时自动补回——没有 +x 位连 systemd 都起不来。Python 项目可使用位于管理目录 `data/venv` 的独立虚拟环境，并通过接口安装工程目录依赖清单里声明的依赖：`requirements.txt`、`pyproject.toml`（PEP 621 的 `[project] dependencies`）、`setup.py` 依次识别，前一份在就用前一份。没有虚拟环境的 Python 项目面板不给依赖入口——依赖只能装进共享的 Python，会牵连所有项目；但**清单照常认**，自检与项目卡片会列出工程里找到的是哪份清单，并说明面板为什么不替它装。新建 Python Web 项目默认使用 Gunicorn，也可选择 Uvicorn（ASGI）或 uWSGI（WSGI）；三者都要求项目虚拟环境、端口和应用对象。Gunicorn 可选择 `sync`、`gthread` 或 `uvicorn_worker.UvicornWorker`，后者会同时安装 `uvicorn-worker` 与 `uvicorn`。入口写 `app.py` 或 `package/app.py`，服务端转换为 Python 模块路径，再以 `module:callable` 启动；可配置 1–32 个进程、每进程 1–64 个线程，固定监听 `127.0.0.1:{端口}`。创建虚拟环境后可单独安装所选启动器，或者将其写入 `requirements.txt`；服务端会在启动前检查可执行文件。旧 Python 项目继续直接运行脚本，编辑后可切换。项目还可以配置自定义环境变量（最多 64 项，名称限 `[A-Za-z_][A-Za-z0-9_]{0,63}`，`PATH`、`HOME`、`PORT`、`VIRTUAL_ENV` 等由面板管理的名称会被拒绝），以及选择是否额外加载工程目录下的 `.env`（`EnvironmentFile=-<工程目录>/.env`，文件不存在也不影响启动）。`PORT` 由面板统一注入，不放进自定义变量。想读面板「环境变量管理」里那份公用变量，要在项目配置里明确勾上 `use_global_env`——**默认不勾**，面板不替项目决定要不要读。反向代理可在网站管理中手动指向 `http://127.0.0.1:{端口}`。

面板会为每个项目算出启动自检清单，`GET /v1/projects/{id}/status` 把失败点、原因和可点的修复动作一起返回：单元是否因反复崩溃被 systemd 放弃重启、运行环境与版本是否就绪、工程目录是否存在、入口文件是否可读、虚拟环境与启动器是否装好、依赖清单是否装过、端口是否被占、入口源码看起来是 ASGI 还是 WSGI 而启动器 worker class 是否匹配。入口用 FastAPI/Starlette 却配了 Gunicorn `sync`（WSGI）时，进程会在跑、端口会在听，但每个请求都 500——这一条会直接点出来。`GET /v1/projects/{id}/status` 还带出进程没起来时的 systemd `journal`（最后 40 行），因为这时项目日志是空的、原因只在系统日志里。`start`/`restart` 失败时不会把 systemd 的原话「Job for X failed because the control process exited with error code」直接抛给用户，而是换成「启动失败：进程以退出码 1 结束（启动后立即退出）；项目「详情」里有启动自检和系统日志」。

依赖安装按「工程里实际有哪份清单」选择固定命令，运行环境各自的清单都会被认出来：Python 依次看 `requirements.txt`（`pip install -r`）、`pyproject.toml`（`pip install .`，失败时退一步只装 `[project] dependencies` 里声明的依赖，应付扁平布局构建失败的工程）、`setup.py`；Node 认锁文件——有 `pnpm-lock.yaml` 且运行环境里装了 `pnpm` 就用 `pnpm install`，有 `yarn.lock` 且装了 `yarn` 就用 `yarn install`，否则有 `package-lock.json` 走 `npm ci`、再否则 `npm install`（用 npm 顶替 pnpm/yarn 时会在自检里说明 `node_modules` 布局不同）；另有 Bun、Go、Ruby 各自的 `bun install`、`go mod download`、`bundle install`。Java 的 jar、.NET 的 dll、Deno 自己拉依赖，都没有这一步。清单名只有工具配置的 `pyproject.toml` 不会被当成可安装的项目，面板会直说没法照它装、建议补 `requirements.txt`，而不是让它去报一句 setuptools 的原始错误。安装要求项目已停止——一边跑一边改 `node_modules` 很容易装出半成品。依赖结论（认到哪份清单、装过没有、该执行什么命令）随 `GET /v1/projects` 一起返回，客户端在项目卡片上就能写出来，不必先点进详情。安装结果按依赖清单与锁文件的大小、mtime 指纹记到项目 `data/.sera-deps`，清单改动后会重新提示安装；`pip install` 有可能覆盖启动器自己依赖的包（例如把 `uvicorn` 降级导致 `uvicorn-worker` 导入失败），服务端装完会复核启动器是否仍可用并提示再点一次。项目单元带 `StartLimitIntervalSec=60` 与 `StartLimitBurst=5`，连续崩溃 5 次后 systemd 会进入 `failed` 并拒绝后续 `start`；面板在启停前会先 `reset-failed`，所以不会出现「点了启动毫无反应」。单元同时带 `TimeoutStopSec=15` 与 `PYTHONUNBUFFERED=1`（日志实时落盘，不必等缓冲区刷出），`ProtectHome` 按工程目录位置自适应，`ReadWritePaths` 同时包含工程目录与项目 `data/`，工程目录里的相对路径写入因此不会被只读沙箱挡住。`systemctl show` 拿到的 `SubState=auto-restart` 与 `Result` 才是真相：反复崩溃时 `ActiveState` 仍是 `activating`/`active`，只看它会把崩溃显示成「运行中」。`GET /v1/projects/ports?after=3000` 返回 5 个既没被占用、也没分配给其他项目的空闲端口，供新建项目时直接取用。

项目以共享的 `sera` 账户运行，与网站同一身份。工程目录 `/www/seraphim/projects/{项目标识}` 归 `sera` 所有、权限 `0750`，项目 `data/` 与工程目录都可写；数据库、中间件这些独立软件账户读不到工程目录。早期版本给每个项目建过专属账户（`sera-project-{标识}`），启动项目时面板会把单元与目录自动收敛回 `sera`。服务日志位于 `/www/seraphim/logs/projects`，可读取最近 64 KiB 并支持清空（用截断而不是删除，保住 systemd 手里的追加描述符）。可以查看运行状态、启停、重启、设置开机启动及读取日志。删除项目会停用服务并删除项目定义，但保留源文件、数据和日志。客户端只传结构化项目配置和固定动作，服务端生成 systemd 单元，不接受任意命令文本。

**「环境变量管理」是一个独立的模块，不是某个项目的设置。** 面板统一保管一份公用变量，保存在 `/www/seraphim/server/variables.json`（权限 `0600`，最多 128 项），可以随时增删，例如 `PROJECT_RUNTIME=dev`，需要切到生产时改这一处即可。面板只负责存，**谁去读、读哪几个由使用方自己决定**，取用有两条路：

- **项目读取**：项目配置里勾上 `use_global_env`，值会写进它的 systemd 单元；默认不勾，不勾就完全不碰这个项目。同名时项目自己的变量优先，所以既能共用、也能个别例外。保存时服务端立刻重写所有勾选者的单元并 `daemon-reload`，其中正在运行的项目会重启一次，接口返回实际被同步的项目名；单元内容没变的项目不重写、也不重启。
- **代码读取**：同一份值会导出成 `/www/seraphim/server/env`，shell 里 `. /www/seraphim/server/env` 就能用，任何语言逐行读也行（每行 `KEY=VALUE`，`#` 为注释，必要时加引号并转义 `$`）。文件属组 `sera`、权限 `0640`：项目进程与 Web 服务能读，其他本地用户读不到。**这条路不需要改项目配置。**

计划任务执行命令时也会带上同一份值，脚本和常驻服务看到的东西一致。名称与取值规则和项目变量完全一致，`PORT`、`PATH`、`HOME`、`VIRTUAL_ENV` 这类由面板按项目分配的变量会被拒绝并给出理由。项目自检清单里有一条「面板环境变量」，直接说明这个项目跟那份值是什么关系：没加载就明说「默认不加载」并给出共用文件路径，加载了就列出读到几项、哪几项被项目自己的变量覆盖——「我明明设了 XXX 怎么没生效」几乎都出在这两件事上。

数据库管理显示 MySQL、MariaDB、PostgreSQL、MongoDB、Redis、Valkey、SQLite 七种实例的安装与运行状态。MySQL、MariaDB、PostgreSQL 可建库、删库、建用户、重置密码、删除用户、授予只读或读写权限以及撤销权限。用户密码由服务端随机生成，创建或重置时返回并保存到权限为 `0600` 的 `/www/seraphim/server/.sera-credentials/{engine}/{user}`，之后可显式查看；管理接口只接收结构化字段，服务端执行固定数据库客户端与限定的 SQL 模板。MySQL 首次使用时可把安装生成的临时 root 密码更换为管理密码，保存在 `/www/seraphim/server/mysql/sera-admin-password`，权限为 `0600`；已有密码也可验证后保存。PostgreSQL 新安装默认支持本机 SCRAM 密码连接，旧安装可在界面显式启用并重启；不会对外网开放数据库端口。PostgreSQL 对现有表、序列和 `public` schema 授权，其他 schema 与未来由别的账户创建的对象需要另行配置。Redis、Valkey 支持 ACL 账户创建、删除、停用、密码重置及只读/读写权限切换；权限作用于该实例的全部键，默认账户和自定义 ACL 账户在界面中受保护。新安装默认把 ACL 文件放在各自的 `data/users.acl`；旧安装可在界面启用持久化，服务会重启一次。ACL 文件和数据目录分别限制为 `0600` 与 `0700`，普通账户密码保存于上述受限目录，之后可显式查看。若已有默认账户密码，须先在界面验证并保存。MongoDB、SQLite 目前只提供实例总览。

防火墙规则页支持正在运行的 firewalld 或 ufw，展示当前活动区域中的直接端口规则，支持添加、删除 TCP/UDP 入站端口。firewalld 会同时写入运行配置与持久配置，不触发全量重载；ufw 使用自身规则命令。SSH 默认端口 22 和 API 端口 27520 的规则禁止从此页删除。界面只删除 ufw 对所有来源开放的简单规则，不会更改限定来源的规则；firewalld 服务规则、富规则及云安全组不在本页管理。防火墙服务本身的启停也在本页操作。

计划任务页按每小时、每天或每周运行程序。客户端传结构化的程序绝对路径、逐项参数、工作目录和时间；服务端生成 systemd timer，运行时由 `sera task-run` 直接执行程序，不经过 shell 或 SSH。任务以服务端的 root 身份运行，因此只应给可信管理员连接令牌。程序标准输出与错误输出写入 `/www/seraphim/logs/tasks/{id}.log`；界面可查看末尾 64 KiB。删除任务会停用并删除定时器和定义，日志保留。

新服务器可在桌面端「服务器管理 → 服务器状态 → 安装服务端…」选择命令行或 SSH 安装。两种方式都使用应用内置的 Linux 二进制；服务器无需 Go 或 Docker。命令行方式先导出与 `uname -m` 匹配的文件，上传至服务器，然后以 root 执行（将示例 IP 换成实际客户端访问的 IP 或域名）：

```sh
chmod 755 /tmp/sera-install
sudo /tmp/sera-install install -host 203.0.113.10
```

`install` 首次运行时创建约定目录，将自身复制到 `/www/seraphim/server/sera`，生成一年有效的自签证书及随机 256 位令牌，写入 systemd 单元并启动服务，最后打印 HTTPS 地址、API 令牌和证书 SHA-256 指纹。再次执行同一命令会覆盖升级已有服务端：先在 `/www/seraphim/backup/server` 备份旧程序，再原子替换并重启；检查原证书指纹及原令牌的 HTTPS 接口，失败时恢复旧程序。升级不改动令牌、证书、定制的 systemd 单元、项目和业务数据。若安装不完整或服务单元指向其他程序路径，安装器会报错而不覆盖。SSH 方式会识别 x86_64/aarch64 架构、上传安装文件、运行相同命令，并把连接信息保存到桌面端；SSH 密码只在本次操作期间使用，不保存。首次 SSH 连接由应用记录主机公钥，保存在本机应用数据目录的 `ssh_known_hosts`；之后密钥变化会在安装窗口显示此前和当前的指纹，由用户决定是否更新。非 root 用户须具有 sudo 权限，可填写 sudo 密码或使用免密 sudo。

服务端仅支持运行 systemd 的 Linux 系统，不依赖发行版的 apt 或 dnf。安装后仍需在主机防火墙及云安全组放行 TCP 27520。`init` 仍可用于手动初始化凭据，不会覆盖现有凭据。面板凭据存放于 `/www/seraphim/server/config/token`，配置目录为 `0700`，私钥与令牌为 `0600`。给脚本与 AI 用的 API key 存在同目录的 `api-key`（`0600`，首次访问「API 设置」或重置时生成，已装好的服务器不需要重装）。服务名沿用 `server-status` 方便已有安装升级；命令行程序名为 `sera`。

升级已有安装时，将新二进制上传为服务器上的 `/tmp/sera-new`，然后执行：

```sh
chmod 755 /tmp/sera-new
sudo /tmp/sera-new install -host 203.0.113.10
```

将示例 IP 换成客户端使用的地址。升级不会覆盖连接令牌、证书或已有站点与数据库。计划任务生成的 systemd 单元始终调用固定路径 `/www/seraphim/server/sera`。

服务通过 HTTPS 监听 `27520`。文件管理覆盖整个服务器文件系统，服务管理能控制防火墙的 systemd 单元，因此服务以 root 运行；持有连接令牌的人可以进行服务器操作。云安全组应只允许自己的客户端来源地址访问 27520，令牌只保存在可信设备。上传默认不覆盖，目录递归删除必须显式请求；根目录、常见系统顶层目录和上述固定布局目录不可整体删除或重命名。文件或目录内的普通条目仍按系统权限操作，软链接不能作为路径穿越。

## 手动绑定域名和正式证书

域名解析、证书签发和安装由管理员完成。先将域名指向服务器，取得覆盖该域名的 PEM 全链和私钥，然后放到 `/www/seraphim/server/config/tls`，私钥设为 `0600`。将 systemd 服务的 `ExecStart=` 改为：

```ini
ExecStart=/www/seraphim/server/sera serve -listen 0.0.0.0:27520 -dir /www/seraphim/server/config -files-root / -cert-file /www/seraphim/server/config/tls/fullchain.pem -key-file /www/seraphim/server/config/tls/privkey.pem -domain status.example.com
```

将域名换成实际值，运行 `systemctl daemon-reload && systemctl restart server-status`。启动时会检查证书、私钥和域名是否匹配。续期后替换文件并重启服务。桌面端填写 `https://status.example.com:27520`；受 macOS 信任的正式证书可留空指纹，自签证书必须填写指纹。域名管理页的 acme.sh 在 Mac 上运行；网站证书可在该页部署到已连接的 Seraphim 网站。此节的手动步骤只适用于 27520 管理 API 的证书。

## 桌面端连接

Seraphim「服务器管理 → 服务器状态」支持保存多台服务器。每台填写 HTTPS 地址、API 令牌和自签证书的 SHA-256 指纹。配置统一保存在本机 `~/Library/Application Support/Seraphim/server-management/connections.json`，目录权限 `0700`、文件权限 `0600`，不使用 macOS 钥匙串。状态每 5 秒刷新一次；「文件管理」初始位置为 `/www/seraphim`，可浏览整个服务器文件系统，双击文件夹可进入。「软件管理」只列出已安装的软件，可查看运行状态与开机启动、下载初始密码、看日志和卸载，支持按名称搜索与按运行状态筛选。「防火墙」页面展示防火墙服务，优先显示正在运行的服务，均未运行时依次选择 firewalld、ufw、nftables、iptables。运行和开机状态显示中文，可执行启动、停止、重启、启用、禁用；操作前会要求确认，启动和开机启用防火墙时提醒检查管理端口。

「软件商店」与「软件管理」「环境管理」同属「运行与安全」分组，按分类列出 Web 服务、数据库、缓存与消息、运行环境、容器工具、监控搜索等 35 款软件；全部都有独立安装流程。三者职责互不重叠：商店只负责安装，装好后的启停、开机启动、日志和卸载都在「软件管理」，运行环境那 9 项没有"默认版本"这回事，安装入口统一交给「环境管理」按版本选择，商店里只留一个跳转按钮。安装器下载经过校验的发布包或源码，vsftpd 从 Linux 内核镜像站获取与上游相同的源码包，并校验固定的 SHA-256 或 SHA-512 值；原有 MySQL 安装器使用官方 GPG 签名和 MD5 校验。下载缓存也会重新校验。如果系统已有 aria2，安装器会使用分段下载；否则使用 curl。编译类安装器使用单线程，以降低峰值内存。源码编译和大包解压可能耗时较久，后台任务最长允许 3 小时；界面会显示阶段与日志。同一时刻只允许一个安装任务，安装完成后不自动启动或启用开机自启。

安装器支持带 systemd 的 apt 系发行版（如 Ubuntu、Debian）和 dnf 系发行版（如 Alibaba Cloud Linux、RHEL 系、Fedora）。依赖包名称由安装器映射，安装前会更新 apt 软件包索引。Caddy、Traefik、OpenJDK、Kafka、Prometheus 等使用独立的官方二进制包，可在受支持的 Linux 架构上安装。MySQL、MariaDB、MongoDB、Docker、Grafana、Elasticsearch、OpenSearch 的本轮固定包仅面向 x86_64。界面会根据架构、systemd 和包管理器禁用不支持的安装按钮。Alpine/OpenRC、zypper、pacman 等组合尚未适配。Podman 无常驻服务；Docker 使用 `/www/seraphim/server/docker/run/docker.sock`，不会占用系统默认 Docker 套接字。Kafka 将自带所需 JDK；RabbitMQ 将在自己的目录内编译 Erlang/OTP；MinIO 与 Podman 将自带或复用商店安装的 Go 工具链。

若服务器无法直连某个官方发布地址，可由管理员先把该脚本指定文件名的安装包放入 `/www/seraphim/download`，再从软件商店安装。校验值不匹配会直接失败。安装器源码在 [`installers/`](installers/)；该目录列出支持的版本、下载地址和校验值。安装失败会回滚本次创建的软件目录和 systemd 单元；已安装的系统依赖包和下载缓存会保留。

MinIO 源码编译需要 Go 模块代理。安装器先探测 `proxy.golang.org`，不可达时改用 `goproxy.cn`，两者均不可达则直接连接模块源。服务器管理员可通过 `SERA_GOPROXY` 环境变量指定自己的代理地址。

MySQL 默认只监听 `127.0.0.1:3306`；初始化的临时 root 密码保存在 `/www/seraphim/server/mysql/initial-root-password`（`0600`）。Grafana、MinIO 也会生成初始管理密码文件，可在「软件管理」下载。Redis 默认只监听 `127.0.0.1:6379`，设置 128 MiB 数据上限和 AOF 持久化；PHP-FPM 的共享实例默认只监听 `127.0.0.1:9000`，网站则各自使用专属 FPM 的 Unix socket，无需手工添加 FastCGI 转发。新增数据库、消息与监控服务默认仅监听本机或 Unix 套接字。Elasticsearch 和 OpenSearch 启动前还需要满足内存与 `vm.max_map_count` 要求。

## 运行环境版本

「环境管理」中的 Python、Go、Node.js、OpenJDK、.NET、Ruby、Bun、Deno 和 PHP 从发布源动态获取当前架构可安装的版本。各版本独立安装在 `server/{id}/versions/{version}`，可同时存在；升级前的旧版安装路径继续识别。已安装版本在列表和选择菜单中标明，安装目录中的工具可逐个检查。软件商店不再为这 9 项提供安装按钮，只显示状态和一个跳转入口——同一个运行时若有两条安装路径，会出现"商店装的是默认版本、环境管理能选版本"这种能力不一致。

## HTTPS API

所有路由都要求 `Authorization: Bearer <key>`。无凭据或凭据错误返回 401。

服务端认两把互不相干的钥匙，权限相同，区别只在「能不能单独作废」：

| 凭据 | 存放位置 | 用途 |
| --- | --- | --- |
| 面板凭据 | `server/config/token`（安装时生成） | 桌面客户端连服务器；安装输出里打印，重装才会变 |
| API key | `server/config/api-key`（首次访问或重置时生成） | 脚本、AI 客户端；在「API 设置」页可以重置 |

这样分开，脚本或 AI 客户端那边泄露时就重置 API key：旧的一把立刻失效，已经连上的面板不受影响；反过来重装面板也不会打断正在跑的自动化。

`GET /v1/api` 返回接口清单（分组）、服务地址、当前这把 API key（明文，用户在这一页就是要把 key 复制到脚本或 AI 客户端里）以及 MCP 接入信息。`POST /v1/api/key` 重置 API key 并返回同一份信息——**key 只由服务端用 `crypto/rand` 生成，接口一律不读请求体里的值**，页面上也没有填写框，用户能做的只有「换一把」。文件始终 `0600`，先写临时文件再 rename，损坏时报错而不是悄悄换一把。

| 方法与路径 | 功能 |
| --- | --- |
| `GET /v1/status` | CPU、内存、交换空间、磁盘、网卡速率和主机运行时间；JSON `schema_version: 1` |
| `GET /v1/api` | 接口清单（分组）、服务地址、当前 API key、MCP 接入信息（端点、请求头、桥脚本地址、工具清单） |
| `POST /v1/api/key` | 重置 API key，返回同一份接入信息；旧的立刻失效，请求体被忽略 |
| `POST /v1/mcp` | MCP 端点，JSON-RPC 2.0 无状态：`initialize`、`ping`、`tools/list`、`tools/call`。工具覆盖项目（增删改查、启停、依赖、日志、导入）、文件读写、网站、服务、公用变量、计划任务与服务器状态；工具级失败放在结果里带 `isError`，不算协议错误 |
| `GET /v1/mcp/script` | 下载 stdio 桥脚本（`seraphim-mcp.py`），供只支持 stdio 的 AI 客户端转发到 MCP 端点 |
| `GET /v1/files?path=/...` | 列出目录，返回名称、类型、八进制权限、大小和修改时间 |
| `POST /v1/files` | JSON `operation=mkdir` 新建目录、`touch` 新建空文件、`rename` 重命名或移动、`chmod` 修改权限（`permissions` 为 `0644` 等八进制字符串）；重命名可显式设 `overwrite=true` 覆盖普通文件 |
| `PUT /v1/files/content?path=/...&overwrite=true` | 流式上传文件，默认不覆盖；新普通文件权限 `0644`，网站文件始终为 `0644`，受管理的项目文件保持 `0600` 且归项目用户所有，覆盖其他文件时保留原权限与所有者；单文件上限 2 GiB；同目录临时文件写完后原子替换 |
| `GET /v1/files/content?path=/...` | 流式下载普通文件，支持 HTTP Range |
| `DELETE /v1/files?path=/...&recursive=true` | 删除文件或目录；非空目录必须显式请求递归删除 |
| `GET /v1/services` | 最多返回一个受支持的防火墙 systemd 服务及其状态 |
| `POST /v1/services` | 只接受当前选中的防火墙 `.service` 单元；`action` 仅可为 `start`、`stop`、`restart`、`enable`、`disable`，不接受命令文本 |
| `GET /v1/software` | 分类软件目录、安装可用性、安装阶段、运行状态、日志位置 |
| `GET /v1/software/jobs` | 查看当前进程中的软件任务列表与状态 |
| `POST /v1/software/{id}/cancel` | 取消排队任务或停止正在运行的安装、卸载 |
| `POST /v1/software/{id}/install` | 进入串行后台安装队列；运行环境可传 JSON `version`，只接受服务端列出的版本，省略时使用默认版本；返回 202 |
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
| `POST /v1/sites` | 创建网站；JSON `provider`、`domains`、`kind`（`static`、`php` 或 `proxy`）、`php_version`、`upstream`、`enabled`；返回 201，响应含服务端分配的 `account` |
| `PUT /v1/sites/{provider}/{id}` | 修改域名、类型、PHP 版本、上游或启用状态；配置检查通过后生效 |
| `DELETE /v1/sites/{provider}/{id}` | 删除网站配置、专属 PHP-FPM 单元和服务端证书，保留 `/www/seraphim/web` 下的文件 |
| `POST /v1/sites/{provider}/{id}/certificate` | 上传 PEM `certificate` 与 `private_key`，验证后启用 HTTPS 443 |
| `GET /v1/projects` | 列出项目及八种运行环境的安装状态；每个项目同时带出 systemd 运行态（`sub_state`、`unit_file_state`、`result`、`main_pid`、`exit_status`、`restarts`、`memory_bytes`、`uptime_seconds`、`port_busy`）、`use_global_env`，以及**依赖结论 `dependency`**（认到哪份清单、装过没有、该执行什么命令）——客户端不用进详情就能在卡片上写出来。该字段是现算的运行时信息，不落盘 |
| `POST /v1/projects` | 创建项目，接收 `id`、`name`、`runtime`、`runtime_version`、`directory`、`entry`、`port`、Python 的 `use_venv` 与启动器参数，以及环境变量 `env`（键值对，最多 64 项）与 `env_file`（是否加载工程目录下的 `.env`）；`use_global_env` 控制是否加载「环境变量管理」里那份公用变量，**缺省为不加载**；运行环境可稍后安装 |
| `GET /v1/projects/ports?after=3000` | 从 `after` 之后返回 5 个未被占用、也未分配给其他项目的空闲端口；该固定路径排在项目 id 之前，`ports` 因此是保留 id |
| `POST /v1/projects/import` | 上传内容并一步建好项目：body 是压缩包（zip / tar.gz / tar，按魔数识别）时直接从 query 取 `id`、`runtime`、`entry`、`port`、`name`、`start`、`overwrite`、`use_venv`；body 是 JSON 时可带 `files`（每个文件 `path`/`content`/`mode`，适合 AI 直接生成代码）或 `archive_base64`。解压只接受普通文件与目录，路径穿越与软链接一律跳过并记进 `skipped`；压缩包上限 1 GiB、解压后总量 4 GiB、条目数 20000。压缩包里只有一个顶层目录时会剥掉它（GitHub 打包的那一层）；工程目录已有内容且未带 `overwrite=true` 时拒绝。落地后走与 `POST /v1/projects` 相同的校验，`start=true` 顺带启动，启动失败只记进 `start_error` 不算导入失败 |
| `PUT /v1/projects/{id}` | 更新项目；运行中的项目自动重启，失败时恢复原配置 |
| `POST /v1/projects/{id}/action` | 仅接受 `start`、`stop`、`restart`、`enable`、`disable`；`failed` 单元会先 `reset-failed`，否则 `StartLimitBurst` 触发后 systemd 会一直拒绝启动 |
| `POST /v1/projects/{id}/venv` | Python 项目虚拟环境操作，`action` 为 `create`、`install_requirements` 或 `install_server`；安装启动器时只接受项目配置中的 Gunicorn/Uvicorn/uWSGI 名称，不接受命令文本 |
| `POST /v1/projects/{id}/deps` | 按工程里实际存在的依赖清单安装依赖（Python 认 `requirements.txt` / `pyproject.toml` / `setup.py`，Node 按锁文件选 `pnpm`/`yarn`/`npm ci`/`npm install`，另有 Bun、Go、Ruby 各自的清单）；要求项目已停止，安装结果按清单与锁文件的大小、mtime 指纹记录到 `data/.sera-deps`，清单改动后会重新提示安装；找不到清单、清单用不了、Python 没开虚拟环境时都返回 409 并说明原因 |
| `GET /v1/projects/{id}/status` | 启动自检：逐条返回 `checks`（含 `level`、`detail`、`hint`、可点的 `action`）、`status` 运行态、`dependency` 依赖状态、`global_variables`（该项目实际加载到的公用变量，没勾就是空）、`log` 与进程没起来时的 `journal`（systemd 最后 40 行） |
| `GET /v1/projects/{id}/log` | 读取最近 64 KiB 项目日志 |
| `DELETE /v1/projects/{id}/log` | 清空项目日志；用截断而非删除，systemd 手里的追加描述符仍然有效 |
| `DELETE /v1/projects/{id}` | 删除项目服务和定义，保留项目文件及日志 |
| `GET /v1/variables` | 读取「环境变量管理」里的公用变量（`variables`、`updated_at`、`file` 共用文件路径、`consumers`）；这份值由勾选了加载的项目与计划任务取用 |
| `PUT /v1/variables` | 整表替换（最多 128 项）；保存后同时更新共用文件 `/www/seraphim/server/env`，并立即重写所有勾选了 `use_global_env`、且单元内容有变化的项目单元并 `daemon-reload`，运行中的项目重启一次，返回 `applied` 列出被同步的项目名 |
| `GET /v1/databases` | 七种数据库实例的安装、运行、端口和认证状态 |
| `GET /v1/databases/{engine}/catalog` | 列出 MySQL、MariaDB 或 PostgreSQL 的数据库与账户 |
| `POST /v1/databases/{engine}/databases` | 创建数据库；名称由服务端校验。可选传 `user` 和 `level`（`read`/`readwrite`）一次性建好账户：服务端生成密码、授权并返回 `{database, user, password, level}`，密码只返回这一次。账户名已被占用、或某一步失败时会回滚本次创建的库与账户，不会删除既有账户 |
| `DELETE /v1/databases/{engine}/databases/{name}` | 删除非系统数据库及其中数据 |
| `POST /v1/databases/{engine}/users` | 创建账户并返回一次随机密码 |
| `POST /v1/databases/{engine}/users/{name}:reset` | 重置账户密码并返回新密码 |
| `GET /v1/databases/{engine}/users/{name}:password` | 显式读取已保存的账户密码 |
| `DELETE /v1/databases/{engine}/users/{name}` | 删除非系统账户 |
| `POST /v1/databases/{engine}/grants` | 给账户授予指定数据库的只读或读写权限 |
| `DELETE /v1/databases/{engine}/grants` | 撤销指定账户在数据库上的权限 |
| `POST /v1/databases/mysql/bootstrap` | 用安装时的临时密码初始化 MySQL 管理密码 |
| `POST /v1/databases/mysql/credential` | 验证并保存已有 MySQL 管理密码 |
| `GET /v1/databases/mysql/credential` | 显式读取已保存的 MySQL 管理密码 |
| `POST /v1/databases/mysql/credential/change` | 验证当前密码后修改并保存新密码 |
| `POST /v1/databases/postgresql/local-access` | 为旧版安装启用本机密码连接并重启 PostgreSQL |
| `GET /v1/databases/{redis|valkey}/acl` | 列出 ACL 账户与持久化状态，不返回密码哈希 |
| `POST /v1/databases/{redis|valkey}/acl/enable` | 为旧安装启用 ACL 文件并重启服务 |
| `POST /v1/databases/{redis|valkey}/acl/credential` | 验证并保存已有默认账户密码。密码错误返回 `409`「密码验证失败，请填写该实例当前的管理员密码」，不写入凭据文件 |
| `GET /v1/databases/{redis|valkey}/acl/credential` | 显式读取已保存的默认账户密码 |
| `GET /v1/databases/{redis|valkey}/acl/users/{name}:password` | 显式读取已保存的 ACL 账户密码 |
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

数据库凭据保存在 `/www/seraphim/server/.sera-credentials/{engine}/{user}`，MySQL 管理密码在 `server/mysql/sera-admin-password`，Redis/Valkey 在 `server/{engine}/sera-admin-password`，权限均为 `0600`。保存凭据前服务端一定先用它连一次数据库验证；Redis/Valkey 的 `redis-cli` 对 `NOAUTH`/`WRONGPASS` 这类服务端错误回复**退出码是 0**，因此判定不能依赖退出码或输出前缀，否则会把错误密码当成成功写入。面板读取 ACL 时若遇到认证失败，会返回“该实例已设置密码，但面板还没保存正确的管理员密码”并提示前往「设置已有管理员密码」，而不是抛出裸的 `NOAUTH Authentication required.`。
