import SwiftUI

/// A short banner that slides in when a page gets blocked, then goes away on
/// its own. Purely informational. Turn it off in Settings if it gets old.
struct BlockToast: View {
    let event: BlockEvent?
    let enabled: Bool

    @State private var visibleEvent: BlockEvent?

    var body: some View {
        VStack {
            if let visibleEvent {
                HStack(spacing: 8) {
                    Image(systemName: "hand.raised.fill")
                    Text("Blocked: \(visibleEvent.reason)")
                        .font(.subheadline.weight(.medium))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.thinMaterial, in: Capsule())
                .overlay(Capsule().stroke(.quaternary))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
                .padding(.top, 10)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.spring(duration: 0.35), value: visibleEvent?.id)
        .allowsHitTesting(false)
        .task(id: event?.id) {
            guard enabled, let event else { return }
            visibleEvent = event
            try? await Task.sleep(for: .seconds(2.5))
            if visibleEvent?.id == event.id {
                visibleEvent = nil
            }
        }
    }
}
