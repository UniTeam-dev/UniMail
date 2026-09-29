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

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let height = self.height
            webView.evaluateJavaScript("document.documentElement.scrollHeight") { result, _ in
                guard let number = result as? NSNumber, number.doubleValue > 0 else { return }
                let value = CGFloat(number.doubleValue)
                Task { @MainActor in height.wrappedValue = value }
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
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
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
