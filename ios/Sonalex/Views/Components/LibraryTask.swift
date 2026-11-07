import SwiftUI

extension View {
    /// Loads a screen's data (instantly from cache), reloads it when the library is refreshed,
    /// and adds pull-to-refresh that re-downloads everything from the server.
    func libraryTask(_ load: @escaping () async -> Void) -> some View {
        modifier(LibraryTaskModifier(load: load))
    }
}

private struct LibraryTaskModifier: ViewModifier {
    let load: () async -> Void

    func body(content: Content) -> some View {
        content
            .task(id: LibrarySync.shared.version) { await load() }
            .refreshable {
                LibrarySync.shared.refreshAll()
                await load()
            }
    }
}
