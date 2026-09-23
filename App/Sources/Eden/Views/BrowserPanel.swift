import AppKit
import SwiftUI
import WebKit

/// The Browser tab's page: one WebKit view for the window, kept while you
/// switch tabs and sessions, like a tab in Safari. It starts blank and shows
/// your app's pages (a dev server, docs, a local HTML file); Eden's own
/// interface stays native (see AGENTS.md).
@MainActor @Observable
final class BrowserState: NSObject, WKNavigationDelegate {
    @ObservationIgnored let webView: WKWebView
    var url: URL?
    var title = ""
    var canGoBack = false
    var canGoForward = false
    var isLoading = false
    var failure: String?
    /// The web view's own properties, watched: they change on links, redirects,
    /// Back and Forward, and scripts, not only when a load finishes.
    @ObservationIgnored private var watching: [NSKeyValueObservation] = []

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        // WebKit reports these on the main thread.
        watching = [
            // Not while a failure shows: WebKit puts back the last page's address, but the field keeps the one that failed.
            webView.observe(\.url) { [weak self] web, _ in
                MainActor.assumeIsolated {
                    guard let self, self.failure == nil, let url = web.url else { return }
                    self.url = url
                }
            },
            webView.observe(\.title) { [weak self] web, _ in MainActor.assumeIsolated { self?.title = web.title ?? "" } },
            webView.observe(\.canGoBack) { [weak self] web, _ in MainActor.assumeIsolated { self?.canGoBack = web.canGoBack } },
            webView.observe(\.canGoForward) { [weak self] web, _ in MainActor.assumeIsolated { self?.canGoForward = web.canGoForward } },
            webView.observe(\.isLoading) { [weak self] web, _ in MainActor.assumeIsolated { self?.isLoading = web.isLoading } },
        ]
    }

    /// Loads what you typed: a URL, a host and port ("localhost:5173"), a
    /// bare host ("apple.com"), or a file on this Mac ("~/site/index.html").
    func load(_ text: String) {
        var address = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return }
        if address.hasPrefix("/") || address.hasPrefix("~") {
            address = URL(fileURLWithPath: (address as NSString).expandingTildeInPath).absoluteString
        } else if !address.contains("://") {
            let local = address.hasPrefix("localhost") || address.hasPrefix("127.") || address.hasPrefix("0.0.0.0")
            address = (local ? "http://" : "https://") + address
        }
        guard let url = URL(string: address) else {
            failure = "That isn't a web address."
            return
        }
        failure = nil
        self.url = url
        if url.isFileURL {
            // A page can read the files next to it: its styles, images, and links.
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    /// Reloads the page, or, after a failed load, tries that address again.
    func reload() {
        if failure != nil || webView.url == nil, let url {
            load(url.absoluteString)
        } else {
            webView.reload()
        }
    }

    // The delegate only reports failures; the page's state comes from watching the web view.

    nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        MainActor.assumeIsolated { failure = nil }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        MainActor.assumeIsolated { fail(error) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        MainActor.assumeIsolated { fail(error) }
    }

    /// The address stays what you asked for, so the field shows it and a
    /// local one gets the dev-server hint.
    private func fail(_ error: any Error) {
        let error = error as NSError
        // A newer navigation replacing this one isn't a failure.
        if error.code == NSURLErrorCancelled { return }
        failure = error.localizedDescription
        if let failing = error.userInfo[NSURLErrorFailingURLErrorKey] as? URL { url = failing }
    }
}

/// Back, Forward, and Reload, the address field, and a menu, over the page.
/// Blank until you enter an address.
struct BrowserPanel: View {
    @Bindable var browser: BrowserState
    @State private var typed = ""
    /// What the field last showed of the page, to tell your typing from ours.
    @State private var shown = ""
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                navButton("Back", symbol: "chevron.left", enabled: browser.canGoBack) { browser.webView.goBack() }
                navButton("Forward", symbol: "chevron.right", enabled: browser.canGoForward) { browser.webView.goForward() }
                navButton(browser.isLoading ? "Stop" : "Reload", symbol: browser.isLoading ? "xmark" : "arrow.clockwise",
                          enabled: browser.url != nil) {
                    if browser.isLoading { browser.webView.stopLoading() } else { browser.reload() }
                }
                address
                    .padding(.leading, 6)
                Spacer(minLength: 8)
                Menu {
                    Button("Open in Default Browser", systemImage: "safari") {
                        if let url = browser.url { NSWorkspace.shared.open(url) }
                    }
                    Button("Copy Link", systemImage: "link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(browser.url?.absoluteString ?? "", forType: .string)
                    }
                    Divider()
                    Button("Actual Size", systemImage: "1.magnifyingglass") { browser.webView.pageZoom = 1 }
                    Button("Zoom In", systemImage: "plus.magnifyingglass") { browser.webView.pageZoom += 0.1 }
                    Button("Zoom Out", systemImage: "minus.magnifyingglass") { browser.webView.pageZoom = max(0.3, browser.webView.pageZoom - 0.1) }
                } label: {
                    Label("More", systemImage: "ellipsis")
                        .labelStyle(.iconOnly)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .disabled(browser.url == nil)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            Divider()
            ZStack {
                WebViewHost(webView: browser.webView)
                if browser.url == nil {
                    // Nothing loaded yet: the panel's own background, not a white page.
                    WindowBackdrop(covers: true)
                } else if let failure = browser.failure {
                    ContentUnavailableView {
                        Label("Can't Open the Page", systemImage: "globe")
                    } description: {
                        Text(failure + (isLocal ? "\nStart your dev server in the Terminal tab, then reload." : ""))
                    } actions: {
                        Button("Reload") { browser.reload() }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background { WindowBackdrop(covers: true) }
                }
            }
        }
        .onAppear {
            show(browser.url)
            // A fresh tab starts in the address field, ready to type.
            if browser.url == nil { addressFocused = true }
        }
        // The field follows the page (links, Back, redirects) unless you've typed something else into it.
        .onChange(of: browser.url) { if !addressFocused || typed == shown { show(browser.url) } }
    }

    private func show(_ url: URL?) {
        typed = url?.absoluteString ?? ""
        shown = typed
    }

    private var isLocal: Bool {
        guard let host = browser.url?.host() else { return false }
        return host == "localhost" || host.hasPrefix("127.") || host == "0.0.0.0"
    }

    /// The address as a field that's always there, like Safari's.
    private var address: some View {
        TextField("Enter a URL", text: $typed)
            .textFieldStyle(.plain)
            .focused($addressFocused)
            .lineLimit(1)
            .truncationMode(.middle)
            .onSubmit {
                browser.load(typed)
                // Hand the field back to the page, which shows the address as loaded.
                addressFocused = false
                show(browser.url)
            }
            .onExitCommand {
                show(browser.url)
                addressFocused = false
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(minWidth: 120, maxWidth: 420)
            // A small control, so a rounded rectangle (see AGENTS.md).
            .background(Color.primary.opacity(addressFocused ? 0.1 : 0.06), in: RoundedRectangle(cornerRadius: 8))
            .help(browser.url?.absoluteString ?? "Enter a URL, a local port like localhost:3000, or a file path")
    }

    private func navButton(_ title: String, symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .labelStyle(.iconOnly)
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        // Neutral, like the page's other controls: the tint is for Send.
        .foregroundStyle(.secondary)
        .disabled(!enabled)
        .help(title)
    }
}

/// Hosts the window's one WebKit view, moving it here when the tab appears.
private struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView {
        webView.removeFromSuperview()
        return webView
    }

    func updateNSView(_ view: WKWebView, context: Context) {}
}
