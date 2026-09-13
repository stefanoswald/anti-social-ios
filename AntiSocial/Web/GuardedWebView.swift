import SwiftUI
import WebKit

/// SwiftUI wrapper around a controller's web view. The pool keeps the
/// controller alive, so this view can come and go without reloading pages.
struct GuardedWebView: UIViewRepresentable {
    @ObservedObject var controller: WebController

    func makeUIView(context: Context) -> UIView {
        controller.loadHomeIfNeeded()
        return controller.container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // Nothing to push. The controller owns all state.
    }
}
