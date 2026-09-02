# DshForMac 架构设计

## 定位与边界

DshForMac（DeepSeek Harness for Mac）是 [DeepSeek Harness（DSH）](https://www.npmjs.com/package/@deepseek-ai/dsh) 的原生 macOS 启动器、运行时管理器和本地 WebView 容器，并不修改或分叉 DSH。本项目使用 Swift Package Manager、Swift 与 AppKit，最低支持 macOS 11，并由打包脚本生成同时支持 Intel 与 Apple Silicon 的通用应用。

应用不捆绑、不静默安装，也不全局升级 Node.js、npm、pnpm 或 DSH。DSH 的用户数据路径不由 DshForMac 重定向，因此继续使用 DSH 上游默认位置，以便复用用户既有配置、会话与插件。

## 主要组成

```text
DshForMac AppKit 应用
  ├─ AppDelegate：窗口、菜单栏、工具栏与应用生命周期
  ├─ MainViewController：Node 检测、DSH 启动状态、WKWebView 与产出物预览
  ├─ SettingsViewController：端口、镜像、版本与更新频率设置
  ├─ NodeRuntimeDetector：定位 node/npm/npx/pnpm/corepack，验证版本与架构
  ├─ DSHRuntimeManager：下载、校验、启动、健康检查、版本回收与进程停止
  └─ FilePreviewViewController：只读文本、Markdown、图片和 SVG 预览

子进程
  └─ <node> node_modules/@deepseek-ai/dsh/lib/bin.js web --no-open --port <port>

本地服务
  └─ http://127.0.0.1:<port> → WKWebView
```

DSH 网页中的本机文件链接，以及由用户点击产出物按钮触发的 `host.openPath` 请求，会由原生界面拦截后显示在右侧只读预览栏。不能预览的文件仍可交给默认应用打开。

## 启动与运行时流程

1. 应用启动时检测 Node.js。检测范围包括 `PATH`、Homebrew 常用路径和 nvm、fnm、Volta、mise、asdf 等常见管理器路径；也支持用户手动选择 `node` 可执行文件。
2. Node.js 仅在版本为 22.19 或以上的 v22，或 v24 及以上，且同目录/环境中可找到 npm 与 npx 时视为可用。检测成功后自动进入 DSH 启动流程。
3. 应用优先使用用户选定的版本，其次使用最近一次健康检查成功的当前版本；两者都不存在时，才会通过配置的 registry 查询候选版本。`latest` 始终会被检查；用户可显式启用额外标签检查，再选择 `alpha`、`beta` 或 `next`。应用按完整 SemVer 优先级从可用候选中选择较新版本，并保留标签来源。
4. DSH 被安装在独立版本目录中。优先使用 pnpm；未找到 pnpm 时会尝试通过 Corepack 启用，失败则使用 npm。下载后读取锁文件，确认 `@deepseek-ai/dsh` 的 integrity 与 registry 元数据一致。
5. 应用使用已检测到的 `node` 直接执行 DSH 的 `lib/bin.js`，不经过 shell，也不会打开外部浏览器。服务通过 `http://127.0.0.1:<port>/` 健康检查；默认端口为 3080。
6. 健康检查成功后才更新 `current` 软链接。重启只启动当前或手动选择的版本，不额外检查更新。正常退出或重启时，应用会终止自己管理的 DSH 子进程。

下载到的版本最多自动保留三个，同时保护正在使用的版本和用户在设置中固定的版本。

## 本地数据与设置

应用受管运行时位于：

```text
~/Library/Application Support/DshForMac/
  runtimes/
    versions/<version>/        # 每个精确 DSH 版本的独立依赖目录
    current -> versions/<version>  # 最近一次健康检查成功的版本
```

界面设置由 macOS `UserDefaults` 保存，包括：

- 包下载镜像：腾讯云镜像（默认）、npmmirror、Yarn 镜像或 npm 官方源；仅注入 DshForMac 子进程环境变量，不会修改用户全局 npm/pnpm 配置。
- DSH 版本选择与已安装版本目录。
- 更新检查频率：每次启动、每天、每周、每月或不检查；也可手动立即检查。`latest` 始终参与检查；用户可显式启用 `alpha`、`beta` 或 `next` 中的一项作为额外预发布标签。某一标签无法解析时，另一个可用标签仍会作为候选，并在结果中提示。检查到的新版本会先下载和校验，不会替换运行中的服务。
- 服务端口：1–65535，默认 3080。
- 用户手动选择的 Node.js 路径。

## WebView 与预览安全

- 内嵌 WebView 只允许加载配置端口的 `http://127.0.0.1` DSH 服务；其他链接或文件需要用户确认后才交给浏览器或默认应用。
- 在加载本机 DSH 页面前，WebView 会仅为缺失的 `AbortSignal.timeout` 和 `AbortSignal.any` 注入兼容实现，以支持 macOS 13 及更早系统自带的 WebKit；系统已提供时不会覆盖原生实现。
- 产出物桥接只接受用户触发的请求，并使用每次应用启动生成的私有令牌校验消息。
- 文本、Markdown、图片和 SVG 仅以只读方式预览。预览有文件大小、图片像素和文本长度限制；Markdown 与 SVG 在受限 WebView 中渲染，禁止其脚本和外部导航。
- DSH 启动命令、端口、版本和 registry 均以结构化参数传入；应用不设置 `DSH_HOME`，不执行 `npm config set`，也不改写用户 shell 配置。

## 打包方式

`scripts/package-dmg.sh` 默认会以 release 配置分别构建 x86_64 与 arm64 二进制，合成为通用 `DshForMac.app`，再生成未签名的 DMG：

```text
dist/DshForMac-x.y.z-unsigned.dmg
```

脚本不会覆盖同名已有产物；需要重新打包时应先改版本号或手动处理旧产物。

GitHub Actions 的标签发布流程则在 Intel 与 Apple Silicon Runner 上分别构建和打包，发布两个架构专用 DMG，不合并为通用文件。
