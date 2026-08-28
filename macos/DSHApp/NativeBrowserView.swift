import AppKit
import Combine
import SwiftUI
import WebKit

@MainActor
final class DSHBrowserRuntime: NSObject, ObservableObject {
  @Published var address = ""
  @Published var title = "新标签"
  @Published var isLoading = false
  @Published var progress = 0.0
  @Published var canGoBack = false
  @Published var canGoForward = false
  @Published var errorMessage: String?
  @Published var downloadMessage: String?
  @Published var wantsAddressFocus = false

  let webView: WKWebView
  let restrictToHTTP: Bool
  var onTitleChange: ((String) -> Void)?
  var onOpenNewWindow: ((URL) -> Void)?
  var onOpenFile: ((URL) -> Void)?
  private var observations: [NSKeyValueObservation] = []
  private var downloads: [ObjectIdentifier: WKDownload] = [:]
  private var downloadDestinations: [ObjectIdentifier: (temporary: URL, final: URL)] = [:]

  init(restrictToHTTP: Bool = false) {
    self.restrictToHTTP = restrictToHTTP
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .default()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = true
    webView = WKWebView(frame: .zero, configuration: configuration)
    super.init()
    webView.navigationDelegate = self
    webView.uiDelegate = self
    webView.allowsMagnification = true
    webView.allowsBackForwardNavigationGestures = true
    webView.underPageBackgroundColor = .clear
    observeWebView()
  }

  nonisolated static func normalizedURL(from rawAddress: String) -> URL? {
    let trimmed = rawAddress.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if trimmed.hasPrefix("//") { return URL(string: "https:\(trimmed)") }
    if trimmed.range(of: "^[A-Za-z][A-Za-z0-9+.-]*://", options: .regularExpression) != nil {
      return URL(string: trimmed)
    }
    if let direct = URL(string: trimmed),
       ["about", "mailto", "tel"].contains(direct.scheme?.lowercased() ?? "") {
      return direct
    }
    guard let host = URLComponents(string: "//\(trimmed)")?.host else { return nil }
    let lower = host.lowercased()
    let local = lower == "localhost"
      || lower.hasSuffix(".localhost")
      || lower == "::1"
      || lower.range(of: "^[0-9.]+$", options: .regularExpression) != nil
      || lower.contains(":")
    return URL(string: "\(local ? "http" : "https")://\(trimmed)")
  }

  func navigate(_ rawAddress: String) {
    guard let url = Self.normalizedURL(from: rawAddress) else {
      errorMessage = "无法识别地址：\(rawAddress)"
      return
    }
    navigate(to: url)
  }

  func navigate(to url: URL) {
    if restrictToHTTP,
       !["http", "https"].contains(url.scheme?.lowercased() ?? "") {
      errorMessage = "模型打开的浏览器标签仅允许 HTTP(S) 页面。"
      return
    }
    if url.isFileURL {
      onOpenFile?(url)
      return
    }
    guard ["http", "https", "about"].contains(url.scheme?.lowercased() ?? "") else {
      NSWorkspace.shared.open(url)
      return
    }
    errorMessage = nil
    downloadMessage = nil
    webView.load(URLRequest(url: url))
  }

  func reloadOrStop() {
    if isLoading { webView.stopLoading() }
    else if webView.url != nil { webView.reload() }
    else { navigate(address) }
  }

  func openExternally() {
    guard let url = webView.url ?? Self.normalizedURL(from: address) else { return }
    NSWorkspace.shared.open(url)
  }

  func requestAddressFocus() {
    wantsAddressFocus = true
  }

  func consumeAddressFocusRequest() {
    wantsAddressFocus = false
  }

  func pauseMedia() {
    webView.evaluateJavaScript("document.querySelectorAll('video,audio').forEach((item) => item.pause())")
  }

  func stop() {
    webView.stopLoading()
    webView.navigationDelegate = nil
    webView.uiDelegate = nil
    onTitleChange = nil
    onOpenNewWindow = nil
    onOpenFile = nil
    downloads.values.forEach {
      $0.cancel(nil)
      $0.delegate = nil
    }
    downloadDestinations.values.forEach { try? FileManager.default.removeItem(at: $0.temporary) }
    downloads.removeAll()
    downloadDestinations.removeAll()
    observations.removeAll()
  }

  private func track(_ download: WKDownload) {
    downloads[ObjectIdentifier(download)] = download
    download.delegate = self
  }

  private func observeWebView() {
    observations = [
      webView.observe(\.title, options: [.initial, .new]) { [weak self] webView, _ in
        DispatchQueue.main.async {
          guard let self else { return }
          let next = webView.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
          self.title = next.isEmpty ? webView.url?.host ?? "新标签" : next
          self.onTitleChange?(self.title)
        }
      },
      webView.observe(\.url, options: [.initial, .new]) { [weak self] webView, _ in
        DispatchQueue.main.async {
          guard let self else { return }
          self.address = webView.url?.absoluteString ?? self.address
        }
      },
      webView.observe(\.estimatedProgress, options: [.initial, .new]) { [weak self] webView, _ in
        DispatchQueue.main.async { self?.progress = webView.estimatedProgress }
      },
      webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] webView, _ in
        DispatchQueue.main.async { self?.isLoading = webView.isLoading }
      },
      webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] webView, _ in
        DispatchQueue.main.async { self?.canGoBack = webView.canGoBack }
      },
      webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] webView, _ in
        DispatchQueue.main.async { self?.canGoForward = webView.canGoForward }
      },
    ]
  }
}

extension DSHBrowserRuntime: WKNavigationDelegate {
  func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
  ) {
    guard let url = navigationAction.request.url else {
      decisionHandler(.cancel)
      return
    }
    let scheme = url.scheme?.lowercased() ?? ""
    if restrictToHTTP, !["http", "https"].contains(scheme) {
      errorMessage = "模型打开的浏览器标签仅允许 HTTP(S) 页面。"
      decisionHandler(.cancel)
      return
    }
    if navigationAction.shouldPerformDownload {
      decisionHandler(.download)
      return
    }
    if ["http", "https", "about"].contains(scheme) {
      decisionHandler(.allow)
    } else if scheme == "file" {
      onOpenFile?(url)
      decisionHandler(.cancel)
    } else {
      NSWorkspace.shared.open(url)
      decisionHandler(.cancel)
    }
  }

  func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationResponse: WKNavigationResponse,
    decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
  ) {
    decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    errorMessage = nil
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    presentNavigationError(error)
  }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    presentNavigationError(error)
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    isLoading = false
    errorMessage = "网页进程已退出，可以重新载入。"
  }

  func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
    track(download)
  }

  func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
    track(download)
  }

  private func presentNavigationError(_ error: Error) {
    let nsError = error as NSError
    guard nsError.code != NSURLErrorCancelled else { return }
    isLoading = false
    errorMessage = error.localizedDescription
  }
}

extension DSHBrowserRuntime: WKUIDelegate {
  func webView(
    _ webView: WKWebView,
    createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction,
    windowFeatures: WKWindowFeatures
  ) -> WKWebView? {
    if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
      if restrictToHTTP,
         !["http", "https"].contains(url.scheme?.lowercased() ?? "") {
        errorMessage = "模型打开的浏览器标签仅允许 HTTP(S) 页面。"
      } else {
        onOpenNewWindow?(url)
      }
    }
    return nil
  }
}

extension DSHBrowserRuntime: WKDownloadDelegate {
  func download(
    _ download: WKDownload,
    decideDestinationUsing response: URLResponse,
    suggestedFilename: String,
    completionHandler: @escaping (URL?) -> Void
  ) {
    let panel = NSSavePanel()
    panel.title = "保存下载"
    panel.nameFieldStringValue = suggestedFilename
    panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    guard panel.runModal() == .OK, let destination = panel.url else {
      completionHandler(nil)
      return
    }
    let temporary = destination.deletingLastPathComponent()
      .appendingPathComponent(".\(destination.lastPathComponent).dsh-download-\(UUID().uuidString)")
    downloadDestinations[ObjectIdentifier(download)] = (temporary, destination)
    completionHandler(temporary)
  }

  func downloadDidFinish(_ download: WKDownload) {
    let id = ObjectIdentifier(download)
    defer {
      downloads[id] = nil
      downloadDestinations[id] = nil
    }
    guard let destination = downloadDestinations[id] else {
      downloadMessage = "下载完成"
      return
    }
    do {
      if FileManager.default.fileExists(atPath: destination.final.path) {
        _ = try FileManager.default.replaceItemAt(destination.final, withItemAt: destination.temporary)
      } else {
        try FileManager.default.moveItem(at: destination.temporary, to: destination.final)
      }
      downloadMessage = "下载完成：\(destination.final.lastPathComponent)"
    } catch {
      try? FileManager.default.removeItem(at: destination.temporary)
      downloadMessage = "保存下载失败：\(error.localizedDescription)"
    }
  }

  func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
    let id = ObjectIdentifier(download)
    if let destination = downloadDestinations[id] {
      try? FileManager.default.removeItem(at: destination.temporary)
    }
    downloads[id] = nil
    downloadDestinations[id] = nil
    downloadMessage = "下载失败：\(error.localizedDescription)"
  }
}

struct NativeBrowserTabView: View {
  @EnvironmentObject private var harness: HarnessController
  let tabID: UUID

  var body: some View {
    if let runtime = harness.browserRuntime(for: tabID) {
      NativeBrowserRuntimeView(runtime: runtime)
    } else {
      WorkbenchBrowserUnavailable()
    }
  }
}

private struct NativeBrowserRuntimeView: View {
  @ObservedObject var runtime: DSHBrowserRuntime
  @State private var addressDraft = ""
  @FocusState private var addressFocused: Bool

  var body: some View {
    VStack(spacing: 0) {
      browserToolbar
      ZStack {
        DSHWebView(runtime: runtime)
        if runtime.webView.url == nil && !runtime.isLoading {
          VStack(spacing: DSHSpace.s3) {
            Image(systemName: "globe").font(.title2).foregroundStyle(DSHTheme.inkFaint)
            Text("输入地址开始浏览").font(.caption).foregroundStyle(DSHTheme.inkFaint)
          }
        }
        if let error = runtime.errorMessage {
          browserError(error)
        }
      }
      if let message = runtime.downloadMessage {
        HStack(spacing: DSHSpace.s2) {
          Image(systemName: message.hasPrefix("下载完成") ? "checkmark.circle" : "exclamationmark.triangle")
          Text(message).lineLimit(1)
          Spacer()
          Button(action: { runtime.downloadMessage = nil }) { Image(systemName: "xmark") }.buttonStyle(.dshGhost)
        }
        .font(.caption)
        .foregroundStyle(message.hasPrefix("下载完成") ? DSHTheme.accent : DSHTheme.coral)
        .padding(.horizontal, DSHSpace.s3)
        .frame(height: 32)
        .background(DSHTheme.surface)
      }
    }
    .onAppear {
      addressDraft = runtime.address
      if runtime.webView.url == nil || runtime.wantsAddressFocus {
        addressFocused = true
        runtime.consumeAddressFocusRequest()
      }
    }
    .onChange(of: runtime.address) { _, value in
      if !addressFocused { addressDraft = value }
    }
    .onChange(of: runtime.wantsAddressFocus) { _, requested in
      guard requested else { return }
      addressDraft = runtime.address
      addressFocused = true
      runtime.consumeAddressFocusRequest()
    }
  }

  private var browserToolbar: some View {
    VStack(spacing: 0) {
      HStack(spacing: DSHSpace.s1) {
        Button(action: { runtime.webView.goBack() }) { Image(systemName: "chevron.left") }
          .buttonStyle(.dshGhost).disabled(!runtime.canGoBack).help("后退").accessibilityLabel("后退")
        Button(action: { runtime.webView.goForward() }) { Image(systemName: "chevron.right") }
          .buttonStyle(.dshGhost).disabled(!runtime.canGoForward).help("前进").accessibilityLabel("前进")
        Button(action: runtime.reloadOrStop) { Image(systemName: runtime.isLoading ? "xmark" : "arrow.clockwise") }
          .buttonStyle(.dshGhost).help(runtime.isLoading ? "停止载入" : "重新载入")
          .accessibilityLabel(runtime.isLoading ? "停止载入" : "重新载入")
        TextField("输入网址", text: $addressDraft)
          .dshField(radius: DSHRadius.sm)
          .focused($addressFocused)
          .onSubmit {
            runtime.navigate(addressDraft)
            addressFocused = false
          }
        Button(action: runtime.openExternally) { Image(systemName: "safari") }
          .buttonStyle(.dshGhost).help("在默认浏览器打开").accessibilityLabel("在默认浏览器打开")
      }
      .padding(.horizontal, DSHSpace.s3)
      .padding(.vertical, DSHSpace.s2)
      .background(DSHTheme.surface)
      if runtime.isLoading {
        ProgressView(value: runtime.progress)
          .progressViewStyle(.linear)
          .tint(DSHTheme.accent)
          .frame(height: 2)
      }
    }
  }

  private func browserError(_ message: String) -> some View {
    VStack(spacing: DSHSpace.s3) {
      Image(systemName: "exclamationmark.triangle").font(.title2).foregroundStyle(DSHTheme.warm)
      Text("无法打开网页").font(.headline).foregroundStyle(DSHTheme.ink)
      Text(message).font(.caption).foregroundStyle(DSHTheme.inkSoft).multilineTextAlignment(.center).textSelection(.enabled)
      HStack(spacing: DSHSpace.s2) {
        Button("重新载入", action: runtime.reloadOrStop).buttonStyle(.dshPrimary)
        Button("默认浏览器", action: runtime.openExternally).buttonStyle(.dshSecondary)
      }
    }
    .padding(DSHSpace.s5)
    .frame(maxWidth: 360)
    .dshCard(tint: DSHTheme.surface, radius: DSHRadius.lg)
  }
}

private struct DSHWebView: NSViewRepresentable {
  let runtime: DSHBrowserRuntime

  func makeNSView(context: Context) -> WKWebView { runtime.webView }
  func updateNSView(_ nsView: WKWebView, context: Context) {}
}

private struct WorkbenchBrowserUnavailable: View {
  var body: some View {
    VStack(spacing: DSHSpace.s2) {
      Image(systemName: "globe.badge.chevron.backward").font(.title2).foregroundStyle(DSHTheme.inkFaint)
      Text("浏览器标签已释放").font(.caption).foregroundStyle(DSHTheme.inkFaint)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
