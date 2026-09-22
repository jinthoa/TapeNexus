import SwiftUI

/// Single-window shell (approach A): no sidebar. The whole UI is one page —
/// QueueView holds the brand strip, paste field, segmented All/Active/Done/
/// Failed filter, and the unified list. Settings lives in the standard app
/// menu (Tape Nexus ▸ Settings… ⌘,) and is presented here as a sheet.
struct ContentView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        QueueView()
            .frame(minWidth: 880, minHeight: 580)
            .background(Theme.bg)
            .sheet(isPresented: $state.showSettings) {
                SettingsSheet()
            }
    }
}