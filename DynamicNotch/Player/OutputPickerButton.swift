//
import AVKit
import Combine
import Defaults
import SwiftUI

/// The output picker (AirPlay, speakers, headphones). macOS's picker draws a small fixed-size
/// icon, so this shows an iPhone-sized icon and presses the (nearly invisible) picker behind it,
/// which opens macOS's own output menu.
struct OutputPickerButton: View {
    let size: CGFloat
    @State private var holder = RoutePickerHolder()

    var body: some View {
        HoverButton(icon: "airplay.audio", iconColor: .gray, scale: .medium, pointSize: size) {
            holder.open()
        }
        .background(
            RoutePickerHost(picker: holder.picker)
                .frame(width: size, height: size)
                .opacity(0.02)
        )
    }
}

final class RoutePickerHolder {
    let picker: AVRoutePickerView = {
        let picker = AVRoutePickerView()
        picker.isRoutePickerButtonBordered = false
        return picker
    }()

    /// Presses the picker's own button, which shows the output menu below it.
    func open() {
        func button(in view: NSView) -> NSButton? {
            if let button = view as? NSButton { return button }
            for sub in view.subviews { if let found = button(in: sub) { return found } }
            return nil
        }
        button(in: picker)?.performClick(nil)
    }
}

private struct RoutePickerHost: NSViewRepresentable {
    let picker: AVRoutePickerView
    func makeNSView(context: Context) -> AVRoutePickerView { picker }
    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {}
}
