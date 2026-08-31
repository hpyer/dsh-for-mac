# DshForMac — AI 助手项目约束

## 产品身份

- 产品名称：**DshForMac**；全称：**DeepSeek Harness for Mac**。
- DshForMac 是 DeepSeek Harness（DSH）的原生 macOS 启动器、运行时管理器与本地 WebView 容器，不是 DSH 的分叉实现。
- 所有面向用户的标题、菜单、设置与文档都使用 “DshForMac” 或 “DeepSeek Harness for Mac”，不得再引入 “DSH Shell” 这一产品名。

## 技术基线

- 使用 Swift + AppKit；可用 SwiftUI 做局部界面，但不得引入 Electron、Node.js、WebView 桌面壳或第三方跨平台运行时。
- 最低部署目标为 macOS 11，产物最终应同时支持 Intel 与 Apple Silicon。
- 当前工程以 Swift Package 管理。除非用户明确要求，不要擅自迁移到其他构建系统或新增大型第三方依赖。
- 每次修改 Swift 代码后，运行 swift test；若本地沙盒阻止 SwiftPM/Xcode 的模块缓存或 sandbox 工具，说明原因后按权限流程重试。

## DSH 与 Node 边界

- 不捆绑、静默安装或全局升级 Node.js、pnpm 或 DSH。
- 首次启动必须检测 Node、npm/npx、pnpm、Node 版本与架构；Node 缺失或不兼容时提供解释、官网链接、重新检测和手动选择路径。
- 检测到兼容 Node.js 后立即自动进入 DSH 启动流程，不要求用户额外点击“继续”；仅在 Node 缺失或不兼容时显示安装与手动选择路径的引导。
- 启动 DSH 时必须使用直接进程执行，禁止经 shell 拼接命令字符串。
- DSH Web 服务默认监听 127.0.0.1:3080；端口可在设置中配置为 1–65535，内置 WebView 只允许加载配置的本机地址。
- 不设置 DSH_HOME，沿用 DSH 默认的用户数据路径，从而复用用户已有的配置、会话和插件；registry 仅通过环境变量注入子进程。不得运行 npm config set，不得改写用户的全局 npm/pnpm、shell 或 Homebrew 设置。

## 运行时与更新

- 只下载和启动 @deepseek-ai/dsh 的精确版本；安装前后校验包名、版本和 integrity。
- 每个 DSH 版本使用独立的受管目录，绝不依赖 npx 缓存实现回滚。
- 受管版本放在 `runtimes/versions/<version>`；`runtimes/current` 是最后一次通过健康检查的版本软链接，只能在新版本成功启动后更新，失败不得破坏当前指针。
- 下载完成后必须经过启动健康检查才能切换；运行中不得替换当前版本。
- 最多保留 3 个健康版本，且不能自动删除当前运行或用户固定的版本。
- 默认 registry 是 https://mirrors.cloud.tencent.com/npm/。registry 仅对 DshForMac 的子进程生效；不可用时应明确报告问题，而不是静默切换。

## 作用域与安全

- MVP 仅做环境检测、版本/进程生命周期、内嵌 DSH Web UI、基础设置和菜单栏控制。
- 局域网访问、跨应用窗口操控、自动执行插件安装、Mac App Store 分发、Developer ID 签名和 Apple 公证不属于当前实现范围；只有用户明确要求时才规划或实现。
- 不输出、上传或记录用户的 API Key、会话正文、工作区内容或完整环境变量。
- 修改架构或产品约束时，同步更新 docs/project-constraints.md、docs/architecture.md 与 docs/mvp-plan.md 中受影响的内容。

## 提交规则

- 创建提交前先检查变更范围并只暂存相关文件。
- 提交信息遵循 Conventional Commits：type(scope): summary。
