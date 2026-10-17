import AppKit
import WebKit

/// The page receives a public CAPTCHA ID only. Login credentials stay in the native client.
final class CaptchaView: NSView {
    private let webView: WKWebView
    private let coordinator: Coordinator

    /// `onRetry` asks for a fresh view after a load failure; `onExpand` reports whether the puzzle is open and needs room.
    init(captchaId: String, onResult: @escaping ([String: Any]) -> Void, onError: @escaping (String) -> Void,
         onRetry: @escaping () -> Void, onExpand: @escaping (Bool) -> Void) {
        coordinator = Coordinator(onResult: onResult, onError: onError, onRetry: onRetry, onExpand: onExpand)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.userContentController.add(coordinator, name: "captcha")
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        super.init(frame: .zero)
        addFilling(webView)
        coordinator.attach(webView, captchaId: captchaId)
        webView.loadHTMLString(Self.page, baseURL: Self.pageURL)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Tears down the challenge, releases the page's handler and removes the view.
    func close() {
        coordinator.close()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "captcha")
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        removeFromSuperview()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        let onResult: ([String: Any]) -> Void
        let onError: (String) -> Void
        let onRetry: () -> Void
        let onExpand: (Bool) -> Void
        private weak var webView: WKWebView?
        private var captchaId = ""
        private var loaded = false
        private var closed = false
        private var delivered = false

        init(onResult: @escaping ([String: Any]) -> Void, onError: @escaping (String) -> Void,
             onRetry: @escaping () -> Void, onExpand: @escaping (Bool) -> Void) {
            self.onResult = onResult
            self.onError = onError
            self.onRetry = onRetry
            self.onExpand = onExpand
        }

        func attach(_ webView: WKWebView, captchaId: String) {
            self.webView = webView
            self.captchaId = captchaId
        }

        private func initialize() {
            guard loaded, !closed else { return }
            guard !captchaId.isEmpty else { fail("Imou did not provide a CAPTCHA ID."); return }
            webView?.callAsyncJavaScript("window.captchaBridge.initialize(captchaId);",
                                         arguments: ["captchaId": captchaId], in: nil, in: .page) { [weak self] result in
                if case .failure = result { self?.fail("Could not initialize the verification challenge.") }
            }
        }

        func close() {
            closed = true
            webView?.evaluateJavaScript("window.captchaBridge?.destroy();", completionHandler: nil)
            webView?.stopLoading()
            captchaId = ""
        }

        private func fail(_ text: String) {
            guard !closed else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.closed else { return }
                self.onError(text)
            }
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard !closed, message.frameInfo.isMainFrame, message.webView === webView,
                  let body = message.body as? [String: Any], let kind = body["kind"] as? String else { return }
            if kind == "scriptReady" { loaded = true; initialize(); return }
            // Load failures are shown in the page beside its Try Again button, not repeated natively.
            if kind == "error" { return }
            if kind == "retry" { DispatchQueue.main.async { [weak self] in self?.onRetry() }; return }
            if kind == "expand" || kind == "collapse" {
                let open = kind == "expand"
                DispatchQueue.main.async { [weak self] in self?.onExpand(open) }
                return
            }
            guard kind == "success", !delivered, let values = body["result"] as? [String: Any] else { return }
            let keys = ["captcha_id", "lot_number", "captcha_output", "pass_token", "gen_time"]
            var result: [String: Any] = [:]
            for key in keys {
                guard let value = values[key] as? String, !value.isEmpty, value.utf8.count <= 65_536 else {
                    fail("Verification returned an incomplete result. Please try again.")
                    return
                }
                result[key] = value
            }
            guard result["captcha_id"] as? String == captchaId else {
                fail("Verification returned an unexpected CAPTCHA ID.")
                return
            }
            delivered = true
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.closed else { return }
                self.onResult(result)
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
            if navigationAction.targetFrame?.isMainFrame == true {
                decisionHandler(url.absoluteString == "about:blank" || url == CaptchaView.pageURL ? .allow : .cancel)
            } else {
                decisionHandler(url.scheme == "https" || url.absoluteString == "about:blank" ? .allow : .cancel)
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            fail("Could not load the verification page.")
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            fail("Verification stopped. Please reopen it and try again.")
        }

        func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                     initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                     decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            decisionHandler(.deny)
        }
    }

    // Match the page origin used by the shipped Windows client; the document itself is local.
    static let pageURL = URL(string: "https://pc.imoulife.com/h5-pc-base-v6/static/GeeTest.html")!

    // Imou's overseas V9.7+ client selects Geelab; both providers expose initGeetest4.
    static let page = #"""
    <!doctype html><html lang="en"><meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <title>Imou account verification</title>
    <style>
    :root { color-scheme:light dark; font:13px -apple-system,BlinkMacSystemFont,sans-serif }
    body { margin:0;padding:8px 0;display:flex;flex-direction:column;align-items:center;gap:12px;text-align:center }
    #status { margin:0;min-height:18px;opacity:.75 }
    #status.error { color:#ff6b5e;opacity:1 }
    button { font:600 14px -apple-system,sans-serif;border:0;border-radius:18px;padding:9px 0;width:100%;max-width:400px;
             background:#f06620;color:#fff;cursor:pointer }
    button:disabled { opacity:.45;cursor:default }
    </style>
    <p id="status" role="status" aria-live="polite">Loading verification…</p>
    <button id="verify" disabled>Verify</button>
    <script>
    'use strict';
    (() => {
      const post = (kind, extra = {}) => window.webkit?.messageHandlers?.captcha?.postMessage({kind, ...extra});
      const status = document.getElementById('status');
      const button = document.getElementById('verify');
      let captcha = null, generation = 0, timer;
      const say = (text, isError = false) => { status.textContent = text; status.classList.toggle('error', isError); };
      // GeeTest error codes are public diagnostics; keep only a short alphanumeric code.
      const error = detail => {
        clearTimeout(timer);
        const code = String(detail?.code ?? detail ?? '').replace(/[^\w-]/g, '').slice(0, 24);
        post('collapse');
        post('error', {code});
        // Keep provider rejection codes without guessing that the challenge expired.
        if (code.startsWith('-501')) {
          say('Verification could not load (' + code + '). Cancel and sign in again.', true);
          button.hidden = true;
          return;
        }
        say('Verification couldn’t load' + (code ? ' (' + code + ')' : '') + '.', true);
        button.textContent = 'Try Again';
        button.disabled = false;
        button.onclick = () => post('retry');
      };
      window.captchaBridge = {
        scriptReady() {
          clearTimeout(timer);
          if (typeof window.initGeetest4 !== 'function') { error('script'); return; }
          post('scriptReady');
        },
        scriptError: () => error('network'),
        destroy() {
          generation++;
          clearTimeout(timer);
          button.onclick = null;
          button.disabled = true;
          if (captcha) { try { captcha.destroy(); } catch (_) {} captcha = null; }
        },
        initialize(captchaId) {
          this.destroy();
          const current = generation;
          say('Preparing verification…');
          if (!captchaId || typeof window.initGeetest4 !== 'function') { error('setup'); return; }
          timer = setTimeout(() => current === generation && error('timeout'), 30000);
          try {
            window.initGeetest4({captchaId, product:'bind', language:'en', nextWidth:'340px', protocol:'https://',
              onError: e => current === generation && error(e)}, instance => {
              if (current !== generation) { instance.destroy(); return; }
              captcha = instance;
              instance.onReady(() => {
                if (current !== generation) return;
                clearTimeout(timer);
                button.textContent = 'Verify';
                button.disabled = false;
                say('Click Verify, then complete the puzzle.');
              }).onSuccess(() => {
                if (current !== generation) return;
                post('collapse');
                const values = instance.getValidate();
                if (!values) { error('result'); return; }
                const result = {};
                for (const key of ['captcha_id','lot_number','captcha_output','pass_token','gen_time'])
                  if (Object.hasOwn(values, key)) result[key] = values[key];
                if (!Object.hasOwn(result, 'captcha_id')) result.captcha_id = captchaId;
                button.disabled = true;
                say('Verified. Signing in…');
                post('success', {result});
              }).onError(e => current === generation && error(e)).onClose(() => {
                if (current !== generation) return;
                post('collapse');
                say('Click Verify when you’re ready.');
              });
              button.onclick = () => {
                if (current !== generation || button.disabled) return;
                post('expand');
                instance.showCaptcha();
              };
            });
          } catch (e) { error(e); }
        },
      };
      timer = setTimeout(() => error('timeout'), 20000);
      addEventListener('pagehide', () => window.captchaBridge.destroy());
    })();
    </script>
    <script src="https://pc.imoulife.com/h5-pc-base-v6/static/gl4.js" onload="window.captchaBridge.scriptReady()" onerror="window.captchaBridge.scriptError()"></script>
    </html>
    """#
}
