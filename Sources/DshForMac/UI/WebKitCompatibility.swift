import Foundation

enum WebKitCompatibility {
    /// DSH 0.1.6-alpha.2 focuses a row when the model menu opens. WebKit does
    /// not focus a button on mouse-down, so its blur has a null relatedTarget;
    /// DSH closes the menu before mouse-up can deliver the row's click.
    /// Preventing the focus change keeps the row mounted without altering its click.
    static let modelSelectionMouseScript = """
    (() => {
      const menuLabels = new Set(['模型与推理等级', 'Model and reasoning effort']);
      document.addEventListener('mousedown', (event) => {
        if (!(event.target instanceof Element)) return;
        const button = event.target.closest('button');
        const menu = button?.closest('[role="menu"]');
        if (menu && menuLabels.has(menu.getAttribute('aria-label'))) {
          event.preventDefault();
        }
      }, true);
    })();
    """

    /// DSH 0.1.6's xterm DOM renderer names only ordinary monospace fonts.
    /// Explicit local fallback is necessary for private-use Nerd Font symbols.
    /// Restrict the face to symbols so ASCII keeps xterm's original cell metrics.
    static let terminalFontScript = """
    (() => {
      if (document.getElementById('dsh-for-mac-terminal-font')) return;
      const style = document.createElement('style');
      style.id = 'dsh-for-mac-terminal-font';
      style.textContent = `
        @font-face {
          font-family: "DshForMac Terminal Symbols";
          src: local("MesloLGS NF Regular"), local("MesloLGS NF"),
               local("MesloLGS Nerd Font Mono"), local("MesloLGM Nerd Font Mono"),
               local("JetBrainsMono Nerd Font Mono"), local("FiraCode Nerd Font Mono"),
               local("Hack Nerd Font Mono"), local("Symbols Nerd Font Mono");
          unicode-range: U+E000-F8FF, U+F0000-FFFFD, U+100000-10FFFD;
        }
        .xterm .xterm-rows {
          font-family: "DshForMac Terminal Symbols", ui-monospace, SFMono-Regular,
                       Menlo, Consolas, monospace !important;
        }
      `;
      (document.head || document.documentElement).appendChild(style);
    })();
    """

    /// Supplies Web APIs used by recent DSH web releases but absent from the
    /// WebKit shipped with older supported macOS versions (for example, macOS 13).
    static let script = """
    (() => {
      const needsIteratorCompatibility = typeof globalThis.Iterator === 'undefined';
      const installIteratorCompatibility = (scope) => {
        if (typeof scope.Iterator !== 'undefined') return;

        const arrayIterator = [][Symbol.iterator]();
        const iteratorPrototype = Object.getPrototypeOf(Object.getPrototypeOf(arrayIterator));
        if (!iteratorPrototype) return;

        function Iterator() {
          throw new TypeError('Iterator is not constructible.');
        }
        Iterator.prototype = iteratorPrototype;
        Object.defineProperty(scope, 'Iterator', {
          value: Iterator,
          writable: true,
          configurable: true
        });
      };

      installIteratorCompatibility(globalThis);

      // DSH's document preview creates its bundled PDF.js worker from a
      // JavaScript Blob. User scripts do not run in workers, so prepend the
      // same small Iterator shim only to that recognisable worker payload.
      if (needsIteratorCompatibility && typeof Blob === 'function') {
        const NativeBlob = Blob;
        const workerIteratorScript = `(${installIteratorCompatibility.toString()})(globalThis);\n`;
        globalThis.Blob = class Blob extends NativeBlob {
          constructor(parts, options) {
            const isDSHPDFWorker = options?.type === 'text/javascript'
              && Array.isArray(parts)
              && parts.some((part) => typeof part === 'string'
                && part.includes('globalThis.pdfjsWorker')
                && part.includes('Iterator.prototype.join'));
            super(isDSHPDFWorker ? [workerIteratorScript, ...parts] : parts, options);
          }
        };
      }

      if (typeof AbortSignal === 'undefined' || typeof AbortController === 'undefined') return;

      const abortWithSourceReason = (controller, source) => {
        try {
          controller.abort(source && 'reason' in source ? source.reason : undefined);
        } catch (_) {
          controller.abort();
        }
      };

      if (typeof AbortSignal.timeout !== 'function') {
        AbortSignal.timeout = (milliseconds) => {
          const controller = new AbortController();
          const duration = Number(milliseconds);
          const delay = Number.isFinite(duration) ? Math.max(0, duration) : 0;
          window.setTimeout(() => {
            let reason;
            try {
              reason = new DOMException('The operation timed out.', 'TimeoutError');
            } catch (_) {
              reason = new Error('The operation timed out.');
              reason.name = 'TimeoutError';
            }
            try {
              controller.abort(reason);
            } catch (_) {
              controller.abort();
            }
          }, delay);
          return controller.signal;
        };
      }

      if (typeof AbortSignal.any !== 'function') {
        AbortSignal.any = (signals) => {
          const sources = Array.from(signals);
          if (sources.some((source) => !source || typeof source.addEventListener !== 'function')) {
            throw new TypeError('AbortSignal.any expects AbortSignal instances.');
          }

          const controller = new AbortController();
          const listeners = [];
          let didAbort = false;
          const abortFrom = (source) => {
            if (didAbort) return;
            didAbort = true;
            listeners.forEach(({ signal, listener }) => signal.removeEventListener('abort', listener));
            abortWithSourceReason(controller, source);
          };

          for (const source of sources) {
            if (source.aborted) {
              abortFrom(source);
              return controller.signal;
            }
          }

          for (const source of sources) {
            const listener = () => abortFrom(source);
            listeners.push({ signal: source, listener });
            source.addEventListener('abort', listener, { once: true });
          }
          return controller.signal;
        };
      }
    })();
    """
}
