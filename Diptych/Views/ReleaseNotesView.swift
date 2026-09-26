import SwiftUI
import WebKit

/// Every release's notes, newest first, exactly as `build.sh` concatenated
/// them into the bundle. Shown once after an update.
///
/// Rendered, not shown as raw Markdown source: `MarkdownReport` already turns
/// Markdown into HTML for Quick Look's README preview, and reusing it here
/// means headings, lists, tables and code fences all read the way they were
/// written, rather than as asterisks and hash marks.
struct ReleaseNotesView: View {
    private var baseURL: URL { Bundle.main.resourceURL ?? Bundle.main.bundleURL }

    var body: some View {
        MarkdownWebView(html: html, baseURL: baseURL)
            .navigationTitle("Release Notes")
            .frame(minWidth: 560, minHeight: 420)
    }

    private var html: String {
        MarkdownReport.html(for: ReleaseNotesText.all, name: "Diptych Release Notes",
                           baseURL: baseURL)
    }
}

/// A plain page of HTML with nowhere to navigate to -- no back/forward, no
/// address bar -- and a link opens in the default browser instead of taking
/// this window somewhere else. Loaded once, in `makeNSView`: `html` is static
/// for the life of the window, and reloading it on every SwiftUI update would
/// reset the scroll position on every redraw.
private struct MarkdownWebView: NSViewRepresentable {
    let html: String
    let baseURL: URL?

    init(html: String, baseURL: URL? = nil) {
        self.html = html
        self.baseURL = baseURL
    }

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.navigationDelegate = context.coordinator
        view.loadHTMLString(html, baseURL: baseURL)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @MainActor @escaping (WKNavigationActionPolicy) -> Void) {
            // Anything but the page load itself -- a link inside the notes --
            // goes to the default browser rather than navigating this window
            // away from the notes it exists to show.
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}
