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
      const needsStandardCompatibility =
        typeof Promise.withResolvers !== 'function'
        || typeof Promise.try !== 'function'
        || typeof globalThis.URL?.parse !== 'function'
        || typeof RegExp.escape !== 'function'
        || typeof Math.sumPrecise !== 'function'
        || typeof Map.prototype.getOrInsertComputed !== 'function'
        || typeof Map.prototype.getOrInsert !== 'function'
        || typeof Set.prototype.intersection !== 'function'
        || typeof Uint8Array.fromBase64 !== 'function';

      // The same installer runs in the page and in DSH's bundled PDF.js worker.
      // Keep it self-contained so its source can be prepended to the worker Blob.
      const installStandardCompatibility = (scope) => {
        if (typeof scope.Promise.withResolvers !== 'function') {
          scope.Promise.withResolvers = function() {
            let resolve, reject;
            const promise = new this((onResolve, onReject) => {
              resolve = onResolve;
              reject = onReject;
            });
            return { promise, resolve, reject };
          };
        }

        if (typeof scope.Promise.try !== 'function') {
          scope.Promise.try = function(callback, ...args) {
            return new this((resolve, reject) => {
              try {
                resolve(callback(...args));
              } catch (error) {
                reject(error);
              }
            });
          };
        }

        if (typeof scope.Math.sumPrecise !== 'function') {
          scope.Math.sumPrecise = (values) => {
            let sum = 0;
            let correction = 0;
            let sawValue = false;
            let onlyNegativeZero = true;
            for (const value of values) {
              if (typeof value !== 'number') throw new TypeError('Expected numbers.');
              sawValue = true;
              if (!Object.is(value, -0)) onlyNegativeZero = false;
              const next = sum + value;
              if (!Number.isFinite(next)) {
                sum = next;
                correction = 0;
              } else {
                correction += Math.abs(sum) >= Math.abs(value)
                  ? (sum - next) + value : (value - next) + sum;
                sum = next;
              }
            }
            if (!sawValue || onlyNegativeZero) return -0;
            return sum + correction;
          };
        }

        if (typeof scope.URL === 'function' && typeof scope.URL.parse !== 'function') {
          scope.URL.parse = function(input, base) {
            try {
              return base === undefined ? new this(input) : new this(input, base);
            } catch (_) {
              return null;
            }
          };
        }

        if (typeof scope.Map.prototype.getOrInsert !== 'function') {
          scope.Map.prototype.getOrInsert = function(key, defaultValue) {
            if (this.has(key)) return this.get(key);
            this.set(key, defaultValue);
            return defaultValue;
          };
        }

        if (typeof scope.Map.prototype.getOrInsertComputed !== 'function') {
          scope.Map.prototype.getOrInsertComputed = function(key, callback) {
            if (this.has(key)) return this.get(key);
            const value = callback(key);
            this.set(key, value);
            return value;
          };
        }

        if (typeof scope.Set.prototype.intersection !== 'function') {
          scope.Set.prototype.intersection = function(other) {
            const result = new scope.Set();
            for (const value of this) {
              if (other.has(value)) result.add(value);
            }
            return result;
          };
        }

        if (typeof scope.RegExp.escape !== 'function') {
          scope.RegExp.escape = (value) => {
            const slash = String.fromCharCode(92);
            return Array.from(String(value), (character, index) => {
              const code = character.charCodeAt(0);
              const hex = code.toString(16).padStart(2, '0');
              if (index === 0 && ((code >= 48 && code <= 57)
                  || (code >= 65 && code <= 90) || (code >= 97 && code <= 122))) {
                return slash + 'x' + hex;
              }
              if (character === slash || '^$.*+?()[]{}|/'.includes(character)) {
                return slash + character;
              }
              if (',-=<>#&!%:;@~'.includes(character) || code === 34
                  || code === 39 || code === 96 || code === 32) {
                return slash + 'x' + hex;
              }
              if (code === 10) return slash + 'n';
              if (code === 13) return slash + 'r';
              if (code === 9) return slash + 't';
              if (code === 11) return slash + 'v';
              if (code === 12) return slash + 'f';
              if (character.trim() === '') {
                return slash + 'u' + code.toString(16).padStart(4, '0');
              }
              return character;
            }).join('');
          };
        }

        if (typeof scope.Uint8Array.fromBase64 !== 'function' && typeof scope.atob === 'function') {
          scope.Uint8Array.fromBase64 = (value) => {
            const decoded = scope.atob(value);
            return scope.Uint8Array.from(decoded, (character) => character.charCodeAt(0));
          };
        }
      };

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

      installStandardCompatibility(globalThis);
      installIteratorCompatibility(globalThis);

      // DSH's document preview creates its bundled PDF.js worker from a
      // JavaScript Blob. User scripts do not run in workers, so prepend the
      // missing APIs only to that recognisable worker payload.
      if ((needsIteratorCompatibility || needsStandardCompatibility) && typeof Blob === 'function') {
        const NativeBlob = Blob;
        const workerCompatibilityScript =
          `(${installStandardCompatibility.toString()})(globalThis);\n`
          + `(${installIteratorCompatibility.toString()})(globalThis);\n`;
        globalThis.Blob = class Blob extends NativeBlob {
          constructor(parts, options) {
            const isDSHPDFWorker = options?.type === 'text/javascript'
              && Array.isArray(parts)
              && parts.some((part) => typeof part === 'string'
                && part.includes('globalThis.pdfjsWorker')
                && part.includes('Iterator.prototype.join'));
            super(isDSHPDFWorker ? [workerCompatibilityScript, ...parts] : parts, options);
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
