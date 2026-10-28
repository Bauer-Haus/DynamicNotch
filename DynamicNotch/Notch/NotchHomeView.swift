//
import AVKit
import Combine
import Defaults
import SwiftUI

// MARK: - Main View

struct NotchHomeView: View {
    @EnvironmentObject var vm: NotchViewModel
    @ObservedObject var coordinator = NotchCoordinator.shared
    let albumArtNamespace: Namespace.ID

    var body: some View {
        Group {
            if !coordinator.firstLaunch {
                mainContent
            }
        }
        // simplified: use a straightforward opacity transition
        .transition(.opacity)
    }

    private var mainContent: some View {
        HStack(alignment: .top, spacing: 15) {
            MusicPlayerView(albumArtNamespace: albumArtNamespace)
        }
        .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .top)), removal: .opacity))
        .blur(radius: vm.notchState == .closed ? 30 : 0)
    }
}
