import SwiftUI

// MARK: - ContentView

/// Root view: NavigationSplitView with setup sidebar, results list, and group detail.
struct ContentView: View {
    @StateObject private var engine = ScanEngine()
    @State private var selectedGroupID: DuplicateGroup.ID?

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            ScanSetupView(engine: engine)
        } content: {
            ResultsView(engine: engine, selectedGroup: selectedGroupBinding)
        } detail: {
            if let id = selectedGroupID,
               let idx = engine.duplicateGroups.firstIndex(where: { $0.id == id }) {
                DuplicateGroupView(group: $engine.duplicateGroups[idx], engine: engine)
            } else {
                ContentUnavailableView(
                    "Select a Group",
                    systemImage: "film.stack",
                    description: Text("Choose a duplicate group from the list to review its files.")
                )
            }
        }
        .frame(minWidth: 1100, minHeight: 650)
        .alert("Error", isPresented: .constant(engine.errorMessage != nil)) {
            Button("OK") { engine.errorMessage = nil }
        } message: {
            Text(engine.errorMessage ?? "")
        }
    }

    // MARK: - Binding helpers

    /// A Binding<DuplicateGroup?> that drives the list selection via group IDs.
    private var selectedGroupBinding: Binding<DuplicateGroup?> {
        Binding(
            get: {
                guard let id = selectedGroupID else { return nil }
                return engine.duplicateGroups.first { $0.id == id }
            },
            set: { selectedGroupID = $0?.id }
        )
    }
}
