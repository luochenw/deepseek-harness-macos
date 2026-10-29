import AppKit
import Combine
import Darwin
import Foundation
import SwiftUI

struct DSHMarkdownHeading: Identifiable, Equatable, Sendable {
  let level: Int
  let title: String
  let anchor: String
  var id: String { anchor }
}

@MainActor
final class DSHMarkdownDocumentState: ObservableObject {
  enum LoadState: Equatable {
    case loading
    case loaded
    case failed(String)
  }

  private enum ReadResult: Sendable {
    case content(String)
    case failure(String)
  }

  let url: URL
  let allowedFileRoot: URL?
  @Published var text = ""
  @Published var headings: [DSHMarkdownHeading] = []
  @Published var loadState: LoadState = .loading
  @Published var updateNotice: String?
  @Published var requestedAnchor: String?
  var scrollOffset: CGFloat = 0

  private var directorySource: DispatchSourceFileSystemObject?
  private var fileSource: DispatchSourceFileSystemObject?
  private var reloadWorkItem: DispatchWorkItem?
  private var generation = 0

  init(url: URL, allowedFileRoot: URL? = nil) {
    self.url = url.standardizedFileURL
    self.allowedFileRoot = allowedFileRoot?.standardizedFileURL.resolvingSymlinksInPath()
    reload()
    startMonitoring()
  }

  var authorizedURL: URL? {
    guard let allowedFileRoot else { return url }
    return DSHModelWorkbenchTool.authorizedFileURL(url, within: allowedFileRoot)
  }

  func reload() {
    generation += 1
    let requestedGeneration = generation
    if text.isEmpty { loadState = .loading }
    let target = url
    let allowedFileRoot = allowedFileRoot
    Task {
      let result = await Task.detached(priority: .userInitiated) {
        Self.read(target, allowedFileRoot: allowedFileRoot)
      }.value
      guard requestedGeneration == generation else { return }
      switch result {
      case .content(let content):
        let changed = !text.isEmpty && content != text
        text = content
        headings = MarkdownText.headings(in: content)
        loadState = .loaded
        if changed {
          updateNotice = "已更新"
          Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if self.updateNotice == "已更新" { self.updateNotice = nil }
          }
        }
      case .failure(let message):
        loadState = .failed(message)
      }
    }
  }

  func stopMonitoring() {
    reloadWorkItem?.cancel()
    reloadWorkItem = nil
    directorySource?.cancel()
    directorySource = nil
    fileSource?.cancel()
    fileSource = nil
  }

  func requestAnchor(_ rawAnchor: String) {
    let decoded = rawAnchor.removingPercentEncoding ?? rawAnchor
    let anchor = MarkdownText.anchor(decoded)
    requestedAnchor = nil
    DispatchQueue.main.async { self.requestedAnchor = anchor }
  }

  private func startMonitoring() {
    startDirectoryMonitoring()
    startFileMonitoring()
  }

  private func startDirectoryMonitoring() {
    let directory = url.deletingLastPathComponent()
    let descriptor = open(directory.path, O_EVTONLY)
    guard descriptor >= 0 else { return }
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: descriptor,
      eventMask: [.write, .rename, .delete, .extend, .attrib],
      queue: DispatchQueue.global(qos: .utility))
    source.setEventHandler { [weak self] in
      DispatchQueue.main.async { self?.scheduleReload(reopenFileMonitor: true) }
    }
    source.setCancelHandler { close(descriptor) }
    source.resume()
    directorySource = source
  }

  private func startFileMonitoring() {
    fileSource?.cancel()
    fileSource = nil
    let descriptor = open(url.path, O_EVTONLY)
    guard descriptor >= 0 else { return }
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: descriptor,
      eventMask: [.write, .rename, .delete, .extend, .attrib, .revoke],
      queue: DispatchQueue.global(qos: .utility))
    source.setEventHandler { [weak self] in
      DispatchQueue.main.async { self?.scheduleReload(reopenFileMonitor: true) }
    }
    source.setCancelHandler { close(descriptor) }
    source.resume()
    fileSource = source
  }

  private func scheduleReload(reopenFileMonitor: Bool = false) {
    reloadWorkItem?.cancel()
    let item = DispatchWorkItem { [weak self] in
      guard let self else { return }
      if reopenFileMonitor { self.startFileMonitoring() }
      self.reload()
    }
    reloadWorkItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: item)
  }

  private nonisolated static func read(
    _ url: URL,
    allowedFileRoot: URL?
  ) -> ReadResult {
    do {
      let target: URL
      if let allowedFileRoot {
        guard let authorized = DSHModelWorkbenchTool.authorizedFileURL(
          url,
          within: allowedFileRoot)
        else { return .failure("文档已移出当前会话的工作目录。") }
        target = authorized
      } else {
        target = url
      }
      let data = try DSHVerifiedFile.readData(
        target,
        within: allowedFileRoot,
        maxBytes: 5 * 1024 * 1024)
      guard let content = String(data: data, encoding: .utf8) else { return .failure("文档不是 UTF-8 编码。") }
      return .content(content)
    } catch {
      return .failure(error.localizedDescription)
    }
  }
}

struct NativeMarkdownDocumentView: View {
  @EnvironmentObject private var harness: HarnessController
  let tabID: UUID

  var body: some View {
    if let document = harness.markdownDocument(for: tabID) {
      NativeMarkdownDocumentRuntimeView(document: document)
    } else {
      VStack(spacing: DSHSpace.s2) {
        Image(systemName: "doc.badge.ellipsis").font(.title2).foregroundStyle(DSHTheme.inkFaint)
        Text("文档标签已释放").font(.caption).foregroundStyle(DSHTheme.inkFaint)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}

private struct NativeMarkdownDocumentRuntimeView: View {
  @EnvironmentObject private var harness: HarnessController
  @ObservedObject var document: DSHMarkdownDocumentState

  var body: some View {
    VStack(spacing: 0) {
      documentToolbar
      ScrollViewReader { proxy in
        Group {
          switch document.loadState {
          case .loading:
            VStack(spacing: DSHSpace.s3) {
              ProgressView()
              Text("正在读取文档…").font(.caption).foregroundStyle(DSHTheme.inkFaint)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
          case .failed(let message):
            VStack(spacing: DSHSpace.s3) {
              Image(systemName: "doc.badge.exclamationmark").font(.title2).foregroundStyle(DSHTheme.warm)
              Text("无法读取文档").font(.headline).foregroundStyle(DSHTheme.ink)
              Text(message).font(.caption).foregroundStyle(DSHTheme.inkSoft).multilineTextAlignment(.center).textSelection(.enabled)
              HStack(spacing: DSHSpace.s2) {
                Button("重试", action: document.reload).buttonStyle(.dshPrimary)
                Button("默认应用") {
                  if let url = document.authorizedURL { NSWorkspace.shared.open(url) }
                }
                .buttonStyle(.dshSecondary)
                .disabled(document.authorizedURL == nil)
              }
            }
            .padding(DSHSpace.s5)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
          case .loaded:
            ScrollView {
              MarkdownText(
                text: document.text,
                presentation: .document,
                baseURL: document.url.deletingLastPathComponent(),
                allowedFileRoot: document.allowedFileRoot)
                .environment(\.openURL, OpenURLAction { destination in
                  if let fragment = destination.fragment,
                     destination.path.isEmpty {
                    document.requestAnchor(fragment)
                  } else {
                    harness.openMarkdownLink(
                      destination,
                      documentURL: document.url,
                      allowedFileRoot: document.allowedFileRoot)
                  }
                  return .handled
                })
                .padding(.horizontal, DSHSpace.s6)
                .padding(.vertical, DSHSpace.s5)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(MarkdownScrollPositionBridge(document: document))
            .dshThinScrollers()
          }
        }
        .onChange(of: document.requestedAnchor) { _, anchor in
          guard document.loadState == .loaded, let anchor else { return }
          DispatchQueue.main.async {
            proxy.scrollTo(anchor, anchor: .top)
            document.requestedAnchor = nil
          }
        }
        .onChange(of: document.loadState) { _, state in
          guard state == .loaded, let anchor = document.requestedAnchor else { return }
          DispatchQueue.main.async {
            proxy.scrollTo(anchor, anchor: .top)
            document.requestedAnchor = nil
          }
        }
      }
    }
  }

  private var documentToolbar: some View {
    HStack(spacing: DSHSpace.s2) {
      Image(systemName: "doc.richtext").foregroundStyle(DSHTheme.inkSoft)
      Text(document.url.path)
        .font(.caption.monospaced())
        .foregroundStyle(DSHTheme.inkSoft)
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer()
      if let notice = document.updateNotice {
        Text(notice).font(.caption2).foregroundStyle(DSHTheme.accent)
      }
      Menu {
        if document.headings.isEmpty {
          Text("没有标题")
        } else {
          ForEach(document.headings) { heading in
            Button(String(repeating: "　", count: max(0, heading.level - 1)) + heading.title) {
              document.requestAnchor(heading.anchor)
            }
          }
        }
      } label: {
        Image(systemName: "list.bullet.indent").frame(width: 24, height: 24)
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .help("文档目录")
      Button(action: document.reload) { Image(systemName: "arrow.clockwise") }
        .buttonStyle(.dshGhost).help("刷新")
      Button {
        if let url = document.authorizedURL {
          NSWorkspace.shared.activateFileViewerSelecting([url])
        }
      } label: {
        Image(systemName: "folder")
      }
      .buttonStyle(.dshGhost)
      .disabled(document.authorizedURL == nil)
      .help("在 Finder 中显示")
      Button {
        if let url = document.authorizedURL { NSWorkspace.shared.open(url) }
      } label: {
        Image(systemName: "arrow.up.right.square")
      }
      .buttonStyle(.dshGhost)
      .disabled(document.authorizedURL == nil)
      .help("使用默认应用打开")
    }
    .padding(.horizontal, DSHSpace.s3)
    .frame(height: 42)
    .background(DSHTheme.surface)
    .overlay(alignment: .bottom) { Rectangle().fill(DSHTheme.fieldStroke.opacity(0.55)).frame(height: 1) }
  }

}

private struct MarkdownScrollPositionBridge: NSViewRepresentable {
  @ObservedObject var document: DSHMarkdownDocumentState

  final class Coordinator {
    var observer: NSObjectProtocol?
    weak var scrollView: NSScrollView?
    deinit {
      if let observer { NotificationCenter.default.removeObserver(observer) }
    }
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    DispatchQueue.main.async { attach(from: view, coordinator: context.coordinator) }
    return view
  }

  func updateNSView(_ view: NSView, context: Context) {
    DispatchQueue.main.async { attach(from: view, coordinator: context.coordinator) }
  }

  private func attach(from view: NSView, coordinator: Coordinator) {
    guard let scrollView = enclosingScrollView(from: view) else { return }
    guard coordinator.scrollView !== scrollView else { return }
    if let observer = coordinator.observer { NotificationCenter.default.removeObserver(observer) }
    coordinator.scrollView = scrollView
    scrollView.contentView.postsBoundsChangedNotifications = true
    coordinator.observer = NotificationCenter.default.addObserver(
      forName: NSView.boundsDidChangeNotification,
      object: scrollView.contentView,
      queue: .main
    ) { [weak document] notification in
      guard let clipView = notification.object as? NSClipView else { return }
      Task { @MainActor in document?.scrollOffset = clipView.bounds.origin.y }
    }
    let maximum = max(0, (scrollView.documentView?.bounds.height ?? 0) - scrollView.contentView.bounds.height)
    let target = min(maximum, max(0, document.scrollOffset))
    scrollView.contentView.scroll(to: NSPoint(x: scrollView.contentView.bounds.origin.x, y: target))
    scrollView.reflectScrolledClipView(scrollView.contentView)
  }

  private func enclosingScrollView(from view: NSView) -> NSScrollView? {
    if let scrollView = view.enclosingScrollView { return scrollView }
    var ancestor = view.superview
    var hops = 0
    while let current = ancestor, hops < 6 {
      if let scrollView = current as? NSScrollView { return scrollView }
      if let nested = nestedScrollView(in: current) { return nested }
      ancestor = current.superview
      hops += 1
    }
    return nil
  }

  private func nestedScrollView(in view: NSView) -> NSScrollView? {
    if let scrollView = view as? NSScrollView { return scrollView }
    for subview in view.subviews {
      if let found = nestedScrollView(in: subview) { return found }
    }
    return nil
  }
}
