import AppKit
import SwiftUI

struct DraftImagePasteMonitor: NSViewRepresentable {
  let isEnabled: Bool
  let handlePaste: () -> Bool

  func makeCoordinator() -> Coordinator {
    Coordinator(isEnabled: isEnabled, handlePaste: handlePaste)
  }

  func makeNSView(context: Context) -> NSView {
    context.coordinator.start()
    return NSView(frame: .zero)
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    context.coordinator.isEnabled = isEnabled
    context.coordinator.handlePaste = handlePaste
  }

  static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
    coordinator.stop()
  }

  @MainActor
  final class Coordinator {
    var isEnabled: Bool
    var handlePaste: () -> Bool
    private var monitor: Any?

    init(isEnabled: Bool, handlePaste: @escaping () -> Bool) {
      self.isEnabled = isEnabled
      self.handlePaste = handlePaste
    }

    func start() {
      guard monitor == nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        guard let self,
              self.isEnabled,
              event.charactersIgnoringModifiers?.lowercased() == "v" else {
          return event
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command),
              !flags.contains(.shift),
              !flags.contains(.option),
              !flags.contains(.control) else {
          return event
        }
        return self.handlePaste() ? nil : event
      }
    }

    func stop() {
      guard let monitor else { return }
      NSEvent.removeMonitor(monitor)
      self.monitor = nil
    }

    deinit {
      if let monitor { NSEvent.removeMonitor(monitor) }
    }
  }
}
