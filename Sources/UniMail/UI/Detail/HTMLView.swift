import AppKit
import SwiftUI
import WebKit

/// Изолированный показ HTML письма: без JavaScript, без удалённых загрузок (если не разрешено),
/// ссылки открываются в браузере, высота подстраивается под содержимое.
@MainActor
struct HTMLView: NSViewRepresentable {
    let html: String
    let allowRemote: Bool
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(height: $height) }

    func makeNSView(context: Context) -> PassthroughWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        let view = PassthroughWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        // Ширина колонки поменялась (окно растянули) — пересчитываем масштаб и высоту.
        view.onWidthChange = { [weak coordinator = context.coordinator, weak view] in
            guard let coordinator, let view else { return }
            coordinator.fit(view)
        }
        return view
    }

    func updateNSView(_ view: PassthroughWebView, context: Context) {
        let key = "\(allowRemote)|\(html.hashValue)"
        guard context.coordinator.loadedKey != key else { return }
        context.coordinator.loadedKey = key

        Task { @MainActor in
            let controller = view.configuration.userContentController
            controller.removeAllContentRuleLists()
            if !allowRemote, let rules = await RemoteContentRules.shared() {
                controller.add(rules)
            }
            view.loadHTMLString(html, baseURL: nil)
        }
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var height: Binding<CGFloat>
        var loadedKey: String?

        init(height: Binding<CGFloat>) { self.height = height }

        /// Письма с фиксированной шириной (таблицы, вёрстка из Word) шире колонки чтения:
        /// уменьшаем их масштабом (CSS zoom), чтобы ничего не обрезалось, и берём итоговую высоту.
        static let fitScript = """
        (function () {
          var b = document.body, d = document.documentElement;
          if (!b) { return d.scrollHeight; }
          b.style.zoom = '';
          var vw = d.clientWidth || window.innerWidth;
          var w = Math.max(d.scrollWidth, b.scrollWidth);
          if (vw > 0 && w > vw + 2) { b.style.zoom = String(Math.max(vw / w, 0.35)); }
          return Math.max(d.scrollHeight, b.scrollHeight * (parseFloat(b.style.zoom) || 1));
        })();
        """

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            fit(webView)
        }

        func fit(_ webView: WKWebView) {
            let height = self.height
            webView.evaluateJavaScript(Self.fitScript) { result, _ in
                guard let number = result as? NSNumber, number.doubleValue > 0 else { return }
                let value = ceil(CGFloat(number.doubleValue))
                Task { @MainActor in
                    if abs(height.wrappedValue - value) > 1 { height.wrappedValue = value }
                }
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor action: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            if action.navigationType == .linkActivated, let url = action.request.url {
                NSWorkspace.shared.open(url)
                return .cancel
            }
            // Разрешаем только первичную загрузку нашей строки.
            let scheme = action.request.url?.scheme ?? "about"
            return scheme == "about" || scheme == "data" ? .allow : .cancel
        }
    }
}

/// WKWebView, который не перехватывает прокрутку — её получает внешний ScrollView треда.
final class PassthroughWebView: WKWebView {
    var onWidthChange: (() -> Void)?
    private var lastWidth: CGFloat = 0
    private var pendingFit: DispatchWorkItem?

    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard abs(newSize.width - lastWidth) > 1 else { return }
        lastWidth = newSize.width
        pendingFit?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onWidthChange?() }
        pendingFit = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
}

/// Правило WebKit: блокировать любые http(s)-загрузки. Компилируется один раз.
@MainActor
enum RemoteContentRules {
    private static var cached: WKContentRuleList?

    static func shared() async -> WKContentRuleList? {
        if let cached { return cached }
        let json = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]"#
        let list = try? await WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "unimail-block-remote",
            encodedContentRuleList: json
        )
        cached = list
        return list
    }
}
