import Foundation

/// DSH Market delegates restarts to the owner of the managed child process.
enum DSHMarketRestartBridge {
    static let handlerName = "dshMarketRestartBridge"

    static func script(token: String) -> String {
        """
        (() => {
          const bridge = window.webkit?.messageHandlers?.\(handlerName);
          if (!bridge || window.__dshForMacMarketRestartInstalled) return;
          window.__dshForMacMarketRestartInstalled = true;

          const interceptRestart = (delegate, input, init) => {
            const request = new URL(input instanceof Request ? input.url : String(input), window.location.href);
            const method = (init?.method ?? (input instanceof Request ? input.method : 'GET')).toUpperCase();
            if (request.origin === window.location.origin
                && request.pathname === '/dsh-market/restart' && method === 'POST') {
              bridge.postMessage({ token: '\(token)' });
              return Promise.resolve(new Response(JSON.stringify({ ok: true, managed: true }), {
                status: 202,
                headers: { 'content-type': 'application/json' }
              }));
            }
            return delegate(input, init);
          };

          const originalFetch = window.fetch.bind(window);
          window.fetch = (input, init) => interceptRestart(originalFetch, input, init);

          // DSH may install its own transport during boot. Cover it without
          // intercepting file-opening RPCs or inspecting their request bodies.
          const wrappedTransports = new WeakSet();
          const wrapTransportFetch = () => {
            const transport = window.__DSH_TRANSPORT__;
            if (!transport || typeof transport.fetch !== 'function' || wrappedTransports.has(transport)) return;
            const delegate = transport.fetch.bind(transport);
            transport.fetch = (input, init) => interceptRestart(delegate, input, init);
            wrappedTransports.add(transport);
          };
          wrapTransportFetch();
          const watcher = window.setInterval(wrapTransportFetch, 50);
          window.setTimeout(() => window.clearInterval(watcher), 10_000);
        })();
        """
    }
}
