import SwiftUI

@main
struct VideoFuzzyDuplicateApp: App {
    var body: some Scene {
        WindowGroup("Video Duplicate Finder") {
            ContentView()
        }
        .defaultSize(width: 1200, height: 750)
        .windowResizability(.contentSize)
    }
}
