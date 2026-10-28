import SwiftUI
import UIKit
import WebKit
import JobScanCore

/// Shows one report. HTML reports render as in a browser; job links open in Safari.
struct ReportView: View {
    let entry: ReportEntry

    var body: some View {
        content
            .navigationTitle(entry.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { shareButton }
            }
    }

    @ViewBuilder
    private var content: some View {
        if let url = entry.primaryURL {
            if entry.primaryFormat == .html {
                ReportWebView(fileURL: url)
                    .ignoresSafeArea(edges: .bottom)
            } else {
                ScrollView {
                    Text((try? String(contentsOf: url, encoding: .utf8)) ?? "")
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            }
        } else {
            ContentUnavailableView("Report not found", systemImage: "doc.questionmark")
        }
    }

    @ViewBuilder
    private var shareButton: some View {
        let files = entry.allFiles
        if files.count == 1, let only = files.first {
            ShareLink(item: only.url)
        } else if !files.isEmpty {
            Menu {
                ForEach(files, id: \.format) { file in
                    ShareLink(item: file.url) {
                        Label(file.format.displayName, systemImage: "square.and.arrow.up")
                    }
                }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .accessibilityLabel("Share")
        }
    }
}

struct ReportWebView: UIViewRepresentable {
    let fileURL: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.uiDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        webView.loadFileURL(fileURL, allowingReadAccessTo: fileURL.deletingLastPathComponent())
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKUIDelegate {
        /// Every job link in a report has target="_blank": open it in Safari.
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url, Self.isWebLink(url) {
                MainActor.assumeIsolated { UIApplication.shared.open(url) }
            }
            return nil
        }

        static func isWebLink(_ url: URL) -> Bool {
            let scheme = url.scheme?.lowercased()
            return scheme == "http" || scheme == "https"
        }
    }
}
