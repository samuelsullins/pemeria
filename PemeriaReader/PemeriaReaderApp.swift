import SwiftUI

/// Pemeria for iPhone and iPad: a read-only view of projects written on the Mac.
///
/// Projects are opened in place (usually from iCloud Drive) and never written to, so there is
/// nothing to sync back and nothing to conflict. See SPEC.md §2 for the package format.
@main
struct PemeriaReaderApp: App {
    @State private var library = Library()

    var body: some Scene {
        WindowGroup {
            LibraryView(library: library)
                .onOpenURL { url in library.add(url) }
        }
    }
}
