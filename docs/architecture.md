# DshForMac 架构设计

## 定位与边界

DshForMac（DeepSeek Harness for Mac）是 [DeepSeek Harness（DSH）](https://www.npmjs.com/package/@deepseek-ai/dsh) 的原生 macOS 启动器、运行时管理器和本地 WebView 容器，并不修改或分叉 DSH。本项目使用 Swift Package Manager、Swift 与 AppKit，最低支持 macOS 11，并由打包脚本生成同时支持 Intel 与 Apple Silicon 的通用应用。

应用不捆绑、不静默安装，也不全局升级 Node.js、npm、pnpm 或 DSH。DSH 的用户数据路径不由 DshForMac 重定向，因此继续使用 DSH 上游默认位置，以便复用用户既有配置、会话与插件。

## 主要组成

```text
DshForMac AppKit 应用
  ├─ AppDelegate：窗口、菜单栏、工具栏与应用生命周期
  ├─ MainViewController：Node 检测、DSH 启动状态、WKWebView 与产出物预览
  ├─ SettingsViewController：端口、镜像、版本、更新频率与推荐插件设置
  ├─ NodeRuntimeDetector：定位 node/npm/npx/pnpm/corepack，验证版本与架构
  ├─ DSHRuntimeManager：下载、校验、启动、健康检查、版本回收与进程停止
  ├─ AppUpdateController：独立检查 DshForMac 发布版本并协调应用内替换与重启
  └─ FilePreviewViewController：只读文本、Markdown、图片和 SVG 预览

子进程
  └─ <node> node_modules/@deepseek-ai/dsh/lib/bin.js web --no-open --port <port>

本地服务
  └─ http://127.0.0.1:<port> → WKWebView
```

DSH 网页中的本机文件链接，以及由用户点击产出物按钮触发的 `session/openWorkspacePath` 请求（兼容旧版 `host/openPath`），会由原生界面拦截后显示在右侧只读预览栏。不能预览的文件仍可交给默认应用打开。

菜单栏依次显示应用版本与 DSH 运行状态、带快捷键的主窗口／页面重载／重启／设置操作、两种更新检查，以及单独的退出项。状态文字使用辅助文字颜色。关闭主窗口不会结束受管服务，Dock 重新打开或选择“显示主窗口”（⌘0）会将已有窗口置前。

主窗口使用 AppKit 的窗口帧自动保存机制恢复上次尺寸和位置。若保存的位置在当前所有屏幕的可见区域之外，启动时将窗口重新居中。

Mac 唤醒时独立探测当前已验证的本机 DSH 地址。服务正常且 WebView 未报错时保留页面；确认连接中断后进行有限次数的重试，恢复后重载现有页面。WebView 导航失败或内容进程终止时也进入此流程；多次失败后显示手动重连入口。探测不下载 DSH，也不自动重启服务。

DSH 0.1.2-rc.1 会将思考链和相对路径产物（例如 `.sql`、`.md`）按会话工作区解析，再以 Connection RPC 请求原生打开：路径位于 `payload.args.request.path`；旧版路径位于 `payload.path`。预览桥接同时解析两种结构，并在页面世界包装 DSH 的请求传输，以便覆盖对话内链接、思考链和产物链接。

推荐插件中的 `dsh-workspace-drop2add` 使用混合桥接：插件加载后以一次性令牌向原生 WebView 握手；只有握手成功，原生层才会截获左侧栏内从 Finder 拖入的单个目录，并将真实绝对路径回传给插件创建 DSH 工作区。右侧和其他区域的拖放仍交给 DSH。插件未安装、已禁用或尚未握手时，原生层不会拦截任何拖放。项目自研插件均在 `dsh-plugins/` 这一 pnpm workspace 根目录下管理。

后台任务提醒由用户在设置中明确启用本地 `dsh-task-notifications` 插件后生效。插件从 DSH 会话服务读取运行状态与待处理交互，WebView 通过随机令牌把事件类型、会话 ID 和去重键传给原生层；提醒内容不包含标题、工作目录或会话正文。原生层只在应用不在前台时短暂显示不激活应用的 AppKit 面板，不保留待处理列表或历史；点击卡片按钮会激活窗口并调用 DSH 的 `uiWorkspace.openSession`。设置中的测试按钮可在前台显示同款面板，不调用 DSH 会话。DSH `0.1.5-rc.3` 起读取 `uiSession.pendingInteractions` 与会话列表；`0.1.6-alpha.2` 起优先读取统一的 `uiSession.sessionStatus`。可读到 `turn/end` 事件时只把 `completed` 作为“已完成”；未保留的会话无法读取事件原因，运行转为停止时使用“已结束”。首次订阅的状态只作基线，不重放提醒。插件不启动额外服务，且只有用户选择启用时才修改 DSH web profile。

## 启动与运行时流程

1. 应用启动时检测 Node.js。检测范围包括 `PATH`、Homebrew 常用路径和 nvm、fnm、Volta、mise、asdf 等常见管理器路径；也支持用户手动选择 `node` 可执行文件。
2. Node.js 仅在版本为 22.19 或以上的 v22，或 v24 及以上，且同目录/环境中可找到 npm 与 npx 时视为可用。检测成功后自动进入 DSH 启动流程。
3. 应用优先使用用户选定的版本，其次使用最近一次健康检查成功的当前版本；两者都不存在时，才会通过配置的 registry 查询候选版本。`latest` 始终会被检查；用户可多选 `alpha`、`next` 作为额外检查标签，旧设置中的 `beta` 会被忽略。应用按完整 SemVer 优先级从可用候选中选择较新版本，并保留标签来源。启动和下载前以 `AppMetadata.minimumSupportedDSHVersion` 校验版本；当前门槛为 `0.1.5-rc.1`。低于门槛时不启动，也不因本次检查删除受管运行时；主窗口说明所需版本并提供 DSH 更新入口。回退候选也须满足门槛。
4. DSH 被安装在独立版本目录中。优先使用 pnpm；未找到 pnpm 时会尝试通过 Corepack 启用，失败则使用 npm。下载后读取锁文件，确认 `@deepseek-ai/dsh` 的 integrity 与 registry 元数据一致，并执行包管理器的待处理构建，以生成 `fs-ext`、`node-pty` 等原生依赖。
5. 应用使用已检测到的 `node` 直接执行 DSH 的 `lib/bin.js`，不经过 shell，也不会打开外部浏览器。服务通过 `http://127.0.0.1:<port>/` 健康检查；默认端口为 3080。
6. 健康检查成功后才更新 `current` 软链接。重启只启动当前或手动选择的版本，不额外检查更新。正常退出或重启时，应用会终止自己管理的 DSH 子进程。

子进程 PATH 依次包含选定 Node 与检测到的 pnpm 目录、应用继承的路径、`/etc/paths` 与按文件名排序的 `/etc/paths.d` 条目，最后补齐 Intel/Apple Silicon 的 Homebrew bin/sbin 和基础系统目录，并去重。系统文件缺失或不可读时继续使用兜底路径；不执行 shell 来获取环境。这样从 Finder 启动时，DSH 内的交互式 zsh 也能找到 Homebrew 安装的 fnm、direnv、starship 等配置依赖；原生启动器不主动执行或修改用户 shell 配置。

DSH 0.1.6 的 xterm DOM 渲染器只指定普通等宽字体。WebView 在文档加载后为 `.xterm .xterm-rows` 添加本机 Nerd Font 的显式字体回退，优先使用 MesloLGS NF，覆盖私用区图标（含 Powerline 分隔符）。字体映射只作用于私用区，普通文字沿用 DSH 原有字体和字符宽度，不影响聊天页面。没有安装候选字体时沿用原有回退，不下载字体，也不修改受管 DSH 包。

每次启动健康检查通过后，按完整 SemVer 优先级保留最新五个受管版本（稳定版与预发布版合并计数）。正在使用的版本和用户在设置中固定的版本若不在这五个之中，会额外保留。

## 更新检查与下载

### DshForMac 应用更新

应用本体通过 Sparkle 2.9.3 检查 GitHub Release 的 `appcast.xml`，使用 EdDSA 签名验证更新源和通用 DMG，保持 macOS 11 兼容。默认每 24 小时检查一次；下载和安装由用户在更新提示中选择。设置页版本号旁、应用菜单和系统菜单栏均可手动检查。检查和安装不依赖 Node.js 或 DSH；应用退出时仍由现有生命周期代码停止受管 DSH 子进程。失败后显示原因，提供重试和 GitHub Releases 入口；签名验证失败不会自动安装。源码运行不启动更新器。

每次应用发布的 `CHANGELOG.md` 版本条目须写出最低兼容 DSH 版本。发布工作流将该条目复制为 Release Notes 前，校验版本号与 `AppMetadata.minimumSupportedDSHVersion` 一致；提升门槛时无需改变用户的已安装运行时目录。

### DSH 运行时更新

- `MainViewController` 在首次成功启动 DSH 后进行启动检查。应用持续运行时，每分钟判断每天、每周、每月检查是否到期；应用重新激活、Dock 重新打开和系统唤醒时也判断一次。所有触发共用最后成功检查时间；“每次启动”不参与后台定时检查，“不检查”仅允许手动检查。
- 自动检查失败后至少等待 15 分钟再重试；检查与下载不能重复或同时发起。保存检查间隔后按新的设置判断是否到期，无需重启应用。
- `DSHRuntimeManager.checkForUpdates` 不执行安装、不修复未完成的安装，也不启用包管理器。`downloadVersion` 在用户点击后按精确版本重新读取元数据，再使用独立目录下载；使用 pnpm 时写入临时 `pnpm-workspace.yaml`，显式允许 DSH 依赖所需的构建脚本，然后构建待处理依赖并在存在时显式重建 `fs-ext`，最后校验安装。首次运行与用户主动重新下载仍通过启动流程安装必要运行时。
- 下载后的待处理原生依赖构建失败会阻止该版本通过校验和启动；启动日志会提取缺失模块并建议重新下载。
- 发现新版与下载完成是两个独立状态，均由 `UserDefaults` 保存。工具栏在发现新版时即提示；待下载状态跨应用重启保留，失败后可在设置中重试。运行所提示的版本或更新版本后移除提示。

## 本地数据与设置

应用受管运行时位于：

```text
~/Library/Application Support/DshForMac/
  runtimes/
    versions/<version>/        # 每个精确 DSH 版本的独立依赖目录
    current -> versions/<version>  # 最近一次健康检查成功的版本
```

应用标识为 `cn.hpyer.dshformac`。首次以此标识启动时，应用会将旧标识下的偏好设置复制到新域，保留新域中已有的值；旧域不删除。受管运行时目录和 DSH 自身数据路径不受标识变更影响。

界面设置由 macOS `UserDefaults` 保存，包括：

- 设置中的“DSH 检查标签”支持多选，首项 `latest` 默认勾选且不可取消；检查标签与包下载镜像修改后立即保存，后续检查和下载直接使用新设置，无需先点击“保存”。
- 包下载镜像：腾讯云镜像（默认）、npmmirror、Yarn 镜像或 npm 官方源；仅注入 DshForMac 子进程环境变量，不会修改用户全局 npm/pnpm 配置。
- DSH 版本选择与已安装版本目录。
- DSH 更新检查频率：每次启动、每天、每周、每月或不检查；也可在设置的“运行状态”旁手动点击“检查 DSH 更新”，检查结果及下载入口显示在该栏下方。`latest` 始终参与检查；用户可多选 `alpha`、`next` 作为额外检查标签。某一标签无法解析时，其他可用标签仍会作为候选，并在结果中提示。检查仅解析版本元数据和读取本地校验信息，发现比当前运行版本更新的版本后立即显示“有新 DSH 版本”工具栏提示；设置中的状态说明会询问是否下载，只有点击链接样式的“下载”按钮才下载和校验该精确版本。下载完成后可在版本列表中选择，不会替换运行中的服务。
- 服务端口：1–65535，默认 3080。
- 用户手动选择的 Node.js 路径。
- 推荐插件：设置中的勾选项直接读取和修改 DSH 默认 `web` profile。`dshmarket` 如果原本就在该 profile 中，会自动显示为已启用；`dsh-workspace-drop2add` 的安装源随 DshForMac 应用包提供。启动时会将该插件的旧本地 link（含旧包名）迁移到当前应用包内的资源，但不会覆盖用户自行从 registry 安装的同名包。变更后会重启 DSH 才生效，DshForMac 不维护第二份插件启用状态。
- 后台任务提醒：本地插件随应用包提供，至少要求 DSH `0.1.5-rc.3`。启用不申请 macOS 系统通知授权；AppKit 面板仅在应用运行时显示，约 8 秒后消失，不提供待处理列表。关闭主窗口不终止服务。已启用的本地 link 在应用路径变化后会迁移到当前应用包；禁用时移除 web profile 中的对应插件。
- 与系统通知的边界：提醒不进入通知中心或锁屏，不受系统专注模式管理；错过卡片后不可找回，应用退出或 Mac 睡眠时不可用。当前未签名和本地临时签名包在 macOS 26.6.2 实测无法取得系统通知授权（`UNErrorDomain` 错误 1），因此不尝试调用系统通知接口，也不引导用户到系统设置手动添加应用。

## WebView 与预览安全

- 内嵌 WebView 只允许加载配置端口的 `http://127.0.0.1` DSH 服务；其他链接或文件需要用户确认后才交给浏览器或默认应用。
- 在加载本机 DSH 页面前，WebView 会为缺失的 `Iterator`、`AbortSignal.timeout` 和 `AbortSignal.any` 注入兼容实现，以支持 macOS 13 及更早系统自带的 WebKit；DSH 文档预览创建的 PDF Worker 也会获得同一份 `Iterator` 兼容实现，系统已提供时不会覆盖原生实现。
- 产出物桥接只接受用户触发的请求，并使用每次应用启动生成的私有令牌校验消息。
- 文件夹工作区桥接只接受已加载 `dsh-workspace-drop2add` 插件的随机令牌，并且只接受左侧栏中的单个本地目录；它不会把路径注入普通对话附件的拖放流程。
- 任务提醒桥接只接受本机 DSH 主框架、当前插件令牌和有限长度的会话标识；点击提醒时仅向本机 WebView 传回会话 ID。
- 文本、Markdown、图片和 SVG 仅以只读方式预览。预览有文件大小、图片像素和文本长度限制；Markdown 与 SVG 在受限 WebView 中渲染，禁止其脚本和外部导航。
- DSH 启动命令、端口、版本和 registry 均以结构化参数传入；应用不设置 `DSH_HOME`，不执行 `npm config set`，也不改写用户 shell 配置。

## 打包方式

`scripts/package-dmg.sh` 默认会以 release 配置分别构建 x86_64 与 arm64 二进制，合成为通用 `DshForMac.app`，再生成未签名的 DMG：

```text
dist/DshForMac-x.y.z-unsigned.dmg
```

脚本不会覆盖同名已有产物；需要重新打包时应先改版本号或手动处理旧产物。

GitHub Actions 的标签发布流程在 Intel 与 Apple Silicon Runner 上分别构建和测试，随后合成并验证一个通用 DMG。Sparkle 工具使用仓库 `SPARKLE_PRIVATE_KEY` 密钥生成签名 appcast；工作流先创建草稿 Release，上传通用 DMG 与 `appcast.xml` 后公开。应用从固定的 GitHub `releases/latest/download/appcast.xml` 地址读取稳定版更新源，不调用 Releases API。`CFBundleVersion` 随发布递增；应用仍以未经过 Apple 签名和公证的形式发布。
