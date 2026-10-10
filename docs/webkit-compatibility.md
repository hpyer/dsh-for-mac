# DSH WebKit API 兼容审计

审计日期：2026-10-10。最低部署目标仍为 macOS 11；本次不安装或切换 DSH，不修改受管 npm 包。

## 发布代码范围

通过项目配置的腾讯云 npm registry 读取 `@deepseek-ai/dsh` 发布标签：`latest/next = 0.2.0-rc.2`，`alpha = 0.2.1-alpha.2`。检查本机这两个精确版本的发布产物，包括 `dsh-web-frontend` 页面入口和静态 JS、第一方 `client*.js`、延迟加载的终端、Excel、PDF，以及 PDF 内嵌 Worker 源码。分别扫描 135 和 140 个 JS 文件；检索结果再人工区分原生调用、库方法、注释和能力检测。

这是指定发布版本的 API 审计，不是对未来版本或所有 WebKit/CSS/JavaScript 语法的兼容保证。macOS 主版本不能单独决定 WebKit 能力，旧系统的不同补丁和 Safari/WebKit 更新也须实机复验。

## 新补丁

| API | 发布代码中的用途 | 兼容处理 |
| --- | --- | --- |
| `Object.hasOwn` | Cordis 页面入口、快捷键、对话和 PDF | 使用自有属性检测，兼容无原型对象与 Symbol 键 |
| `Array.at`、`String.at` | 弹窗焦点栈、对话事件末尾访问 | 支持负索引；越界返回 undefined |
| `Array.findLast/findLastIndex` | 对话消息选择与轨迹尾部定位 | 从末尾访问，保留空槽访问及回调 thisArg |
| `Array.toSorted/toReversed` | 模型、定时任务排序与 PDF 表头 | 返回普通数组，不改变原数组，空槽转为 undefined |
| `Symbol.dispose` | Session Controller 所有权释放、Gateway 清理 | 每个 realm 安装一个稳定 Symbol，重复注入不替换 |
| `structuredClone` | 设置操作快照、模型配置与 PDF 数据 | 保留循环引用、Map/Set、Date/RegExp、缓冲区和共享视图；支持 Blob/File 与常见 Error |
| `ArrayBuffer.transferToFixedLength` | PDF Worker 字体元数据编译 | 复制/截断/补零后通过原生 MessageChannel 同步脱离源缓冲区 |
| `Uint8Array.toBase64` | PDF 字体 data URL | 支持视图范围、padding 与 base64url；分段构建，避免大字体参数栈溢出 |
| `Response.bytes` | PDF 二进制资源读取 | 基于原生 arrayBuffer，保留 body 消费与失败语义 |
| `ReadableStream.values/@@asyncIterator` | PDF 文本流的 for-await 遍历 | 基于 getReader，串行化迭代请求；完成、失败、提前退出均释放锁，支持 preventCancel |
| `AbortSignal.throwIfAborted` | Gateway 流、HTML/Excel/PDF 预览 | 已取消时抛出原始 reason，包括显式 null |

实现位于 `WebKitLegacyAPIs.swift`。由 `WebKitCompatibility.script` 在文档开始加载时安装，且作为自包含函数前置到可识别的 PDF Worker Blob。只填补缺失 API，不替换已有实现；新增原型方法不可枚举。已有的 Promise、URL、RegExp、Map/Set、Iterator 等补丁继续保留。

WebKit 的原生支持时间可参见 [Safari 15.4](https://webkit.org/blog/12445/new-webkit-features-in-safari-15-4/)（hasOwn、structuredClone、at、findLast）、[Safari 17.4](https://webkit.org/blog/15063/webkit-features-in-safari-17-4/)（ArrayBuffer 转移）、[Safari 18.0](https://webkit.org/blog/15865/webkit-features-in-safari-18-0/)（Response.bytes）以及 [Safari 26.4](https://webkit.org/blog/17862/webkit-features-for-safari-26-4/)（ReadableStream 异步迭代）。

## 边界与已有上游回退

- structuredClone 回退只支持上述 DSH 数据类型；不支持的宿主对象（例如 ImageBitmap、MessagePort）和非 ArrayBuffer transfer 会明确抛出 DataCloneError，不会降级成空对象。已有原生 structuredClone 的系统不受此限制。失败序列化不脱离源缓冲区，循环和共享引用不通过 JSON 丢失。
- xterm 的 OffscreenCanvas 字符测量失败后会回退到 DOM 测量；requestIdleCallback 缺失时已有定时器回退。PDF 对 ImageDecoder、Float16Array、OffscreenCanvas 做能力检测；常规流解压失败后回到内置解析器。本次保留这些路径，不伪造图形或压缩能力。PDF 签名编辑涉及额外 CompressionStream 能力，不属于本次常规文档预览验证。
- WeakRef 的垃圾回收语义与正则/模块等引擎语法不能由这些 API 补丁完整模拟；不安装强引用假 WeakRef，也不改写发布包。未在所有 macOS 11 小版本上验证完整 DSH 页面，不能把当前机器的模拟测试当成旧系统实测。

## 验证

### 回退旧版 DSH 时的草稿兼容

2026-10-10 使用 Xcode 调试构建和 LLDB 运行真实 DSH 页面，发现 0.2.0-rc.2 的外层及滚动区域均正常填满窗口，实际为空的是 `conversation.session`：恢复草稿时在 `setDraft` 中对非字符串调用 `replace`，触发 TypeError 并卸载该插槽。这不是已复现的外层高度塌缩；仅靠扩大高度补丁不能恢复消息。此前未提交的外层高度链改动已撤回，保留原有对话根节点 flex 补丁。

精确发布代码显示：0.2.1-alpha.1 开始在原 `dsh.conversation.<session>` localStorage 键中保存结构化草稿 `{text, references}`，旧版会话效果钩子仍把 `storedDraft` 当字符串。新增 `WebKitDraftCompatibility` 仅注入早于此边界的 DSH 页面，对已识别的结构提供读取投影，并在旧版写回时保留结构与其他字段。未编辑草稿的引用保持原样；文本编辑后，未触碰区域的引用保留或重定位，被编辑的引用变为普通文本。读取不迁移或清空数据，不更改服务端会话；新版 DSH 使用自己的解析路径。

实际复验 0.1.7-rc.2、0.2.0-rc.1、0.2.0-rc.2、0.2.1-alpha.1 和 0.2.1-alpha.2：会话插槽错误计数均为 0，消息区域正常挂载，输入框底部与 752px 的可用视口底部对齐。调试仅收集元素几何与静态代码错误位置，不输出草稿、会话正文、存储键中的会话标识或认证 URL；临时诊断已移除。自动测试验证匿名结构化草稿恢复、引用保留及编辑重定位、未知字段、非目标键和 sessionStorage、重复安装、存储失败语义，以及切换版本时只增删目标脚本。真实页面复验环境为 macOS 26.6.2，不等同于旧系统实测。

自动测试强制移除对应 API，验证数组不变性、空槽、负索引、循环克隆、共享视图、拒绝非法类型、大字体 Base64 和保留原生实现。在真实 WKWebView 中验证缓冲区脱离、克隆失败保留源数据、流取消/错误后的锁释放与 Response body 消费；真实 Worker 验证 PDF 字体缓冲区转移及 Base64。现有测试继续验证普通 Blob 不注入。

旧系统仍需人工验证：模型菜单、定时任务列表、会话与轨迹、设置保存、内嵌终端、PDF 普通/嵌入字体及文字选择，覆盖 macOS 11 与 macOS 13。仅使用隔离的测试会话与文档。
