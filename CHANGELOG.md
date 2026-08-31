# 更新日志

本项目遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 的记录方式。

## [0.1.0] - 初始版本

### 新增

- 提供原生 AppKit macOS 应用，将 DeepSeek Harness（DSH）作为本地 Web 服务嵌入应用窗口。
- 检测本机 Node.js、npm 与 npx，并支持从 `PATH`、Homebrew 及常见 Node 版本管理器路径查找；可手动选择 `node` 可执行文件。
- 校验 Node.js 兼容性：支持 v22.19+（限 v22）和 v24+。
- 自动下载、安装并完整性校验 `@deepseek-ai/dsh` 的精确版本；优先使用 pnpm，必要时尝试通过 Corepack 启用 pnpm，并可回退使用 npm。
- 为每个 DSH 版本创建独立运行时目录，并仅在本地健康检查成功后更新当前版本软链接；自动保留最多三个版本，同时保护当前和用户选定的版本。
- 使用 `127.0.0.1` 本地地址启动 DSH，默认端口为 3080，支持在设置中配置 1–65535 端口范围。
- 提供 DSH 版本选择、更新检查频率、立即检查更新、下载镜像选择和已安装版本目录入口。
- 提供菜单栏状态图标、运行状态指示、一键重启 DSH、重新加载 DSH 页面和应用内设置窗口。
- 支持在右侧只读预览 DSH 产出的文本、Markdown、图片和 SVG 文件，并可将不受支持的文件交给默认应用打开。
- 提供 Intel 与 Apple Silicon 通用二进制的未签名 DMG 打包脚本。

### 安全与行为

- DSH 由已检测到的 Node.js 直接启动，不通过 shell 拼接命令，也不会自动打开系统浏览器。
- 内嵌 WebView 仅加载配置端口的 `http://127.0.0.1` 服务；其他链接和文件须经用户确认后打开。
- 不捆绑、静默安装或修改用户的 Node.js、npm、pnpm 与全局配置；npm registry 仅通过 DshForMac 子进程环境变量传入。
- 不设置 `DSH_HOME`，保留 DSH 上游默认用户数据路径，以便复用既有配置、会话和插件。
