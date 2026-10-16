import Foundation

enum DSHSessionRepairBridge {
    static let handlerName = "dshSessionRepairBridge"

    static func script(token: String) -> String {
        """
        (() => {
          if (window.__dshForMacSessionRepairInstalled) return;
          const bridge = window.webkit?.messageHandlers?.\(handlerName);
          if (!bridge) return;
          window.__dshForMacSessionRepairInstalled = true;
          const style = document.createElement('style');
          style.textContent = `
            button[data-dshformac-session-repair] {
              --repair-text: #30343b;
              --repair-fill: #fff;
              --repair-border: #dce0e5;
              --repair-hover: #f3f5f7;
              --repair-focus: #4d6bfe;
              appearance: none;
              -webkit-appearance: none;
              box-sizing: border-box;
              display: block;
              width: fit-content;
              max-width: 100%;
              min-height: 32px;
              margin: 12px 0 0;
              padding: 5px 12px;
              border: 1px solid var(--dsw-alias-border-l2, var(--repair-border));
              border-radius: 6px;
              background: var(--dsw-alias-bg-base, var(--repair-fill));
              color: var(--dsw-alias-label-primary, var(--repair-text));
              font: 500 13px/20px var(--dsw-font-family, -apple-system, BlinkMacSystemFont, sans-serif);
              text-align: center;
              text-decoration: none;
              cursor: pointer;
              transition: background-color 120ms, border-color 120ms;
            }
            button[data-dshformac-session-repair]:hover {
              background: var(--dsw-alias-interactive-bg-hover, var(--repair-hover));
              border-color: var(--dsw-alias-border-l3, #aeb6c2);
            }
            button[data-dshformac-session-repair]:active {
              background: var(--dsw-alias-interactive-bg-active, var(--repair-hover));
            }
            button[data-dshformac-session-repair]:focus {
              outline: 2px solid var(--dsw-focus-ring-color, var(--repair-focus));
              outline-offset: 2px;
            }
            @supports selector(:focus-visible) {
              button[data-dshformac-session-repair]:focus:not(:focus-visible) { outline: none; }
            }
            @media (prefers-color-scheme: dark) {
              button[data-dshformac-session-repair] {
                --repair-text: #e4e6eb;
                --repair-fill: #202226;
                --repair-border: #41464f;
                --repair-hover: #2c3037;
                --repair-focus: #8a9bff;
              }
            }
            @media (prefers-reduced-motion: reduce) {
              button[data-dshformac-session-repair] { transition: none; }
            }
          `;
          document.head.appendChild(style);
          const installed = new WeakMap();
          const update = () => {
            // Only DSH's history error element, never conversation/message bodies.
            for (const element of document.querySelectorAll('[data-chat-flow] > [class*="openError"]')) {
              const text = Array.from(element.childNodes).filter(n => n.nodeType === Node.TEXT_NODE)
                .map(n => n.textContent).join('');
              const match = text.match(/failed to observe session "(session-[a-zA-Z0-9-]{1,128})":.*unknown to this harness and not marked ignorable;.*\\(raw log: ([^\\n]+?session\\.v4\\.jsonl\\.zstd)\\)/);
              const previous = installed.get(element);
              if (previous?.text === text && previous.button.isConnected) continue;
              previous?.button.remove();
              if (!match) continue;
              const button = document.createElement('button');
              button.type = 'button';
              button.textContent = '修复会话格式…';
              button.dataset.dshformacSessionRepair = '';
              button.title = '将会话格式修复为当前 DSH 版本可读取的形式，修复前会完整备份原始日志';
              button.addEventListener('click', () => bridge.postMessage({
                token: '\(token)', sessionId: match[1], file: match[2]
              }));
              installed.set(element, { text, button });
              element.appendChild(button);
            }
          };
          let pending = false;
          new MutationObserver(() => {
            if (pending) return;
            pending = true;
            setTimeout(() => { pending = false; update(); }, 100);
          }).observe(document.documentElement, { subtree: true, childList: true, characterData: true });
          update();
        })();
        """
    }
}

struct DSHSessionRepairRequest {
    let sessionId: String
    let file: String

    init?(payload: [String: Any]) {
        guard let sessionId = payload["sessionId"] as? String,
              sessionId.range(of: "^session-[a-zA-Z0-9-]{1,128}$", options: .regularExpression) != nil,
              let file = payload["file"] as? String,
              file.utf8.count < 4096, file.hasPrefix("/"),
              !file.contains("\n"), !file.contains("\0"),
              URL(fileURLWithPath: file).lastPathComponent == "session.v4.jsonl.zstd",
              URL(fileURLWithPath: file).deletingLastPathComponent().lastPathComponent == sessionId
        else { return nil }
        self.sessionId = sessionId
        self.file = file
    }
}

struct DSHSessionRepairResult: Decodable {
    let ok: Bool
    let code: String?
    let digest: String?
    let changed: Int?
    let eventCount: Int?
    let manifest: String?
    let sessionId: String?
}

struct DSHSessionRepairError: LocalizedError {
    let code: String

    var errorDescription: String? {
        switch code {
        case "unsupportedVersion":
            "所选 DSH 版本低于应用兼容要求，或受管包与所选版本不一致。请重新选择兼容的已安装版本。"
        case "unsupportedReader":
            "当前 DSH 未提供可用的严格会话读取器或会话锁，无法安全修复。请检查该受管版本的安装。"
        case "unsupportedFormat":
            "当前修复规则只适用于 V4 会话，所选 DSH 使用不同的会话格式，无法直接转换。"
        case "sessionBusy":
            "此会话仍被 DSH 进程占用。请先停止其他正在使用它的 DSH，再重试。"
        case "sessionChanged":
            "会话在检查后已发生变化。为避免覆盖新消息，本次操作已停止。请重新检查；恢复备份时不能覆盖修复后新增的历史。"
        case "nothingToRepair":
            "未发现当前规则可以修复的事件，原会话未改动。"
        case "unknownEvent", "validationFailed":
            "当前版本无法完整校验此会话，可能包含其他不支持的事件或格式。未应用修复，请使用创建它的 DSH 版本。"
        case "invalidBackup":
            "备份文件无效或校验失败，未恢复会话。请选择完整的原始备份记录。"
        case "invalidFile", "invalidLog":
            "会话路径、压缩日志或格式校验失败。仅支持默认数据目录中的完整 V4 会话日志。"
        default:
            "会话操作未完成。请检查文件权限和磁盘空间；备份未完成或校验未通过时不会替换原日志。"
        }
    }
}
