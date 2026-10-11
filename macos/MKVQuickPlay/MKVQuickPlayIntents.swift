import AppIntents
import Cocoa

/// The App Intents suite (Shortcuts, Siri, Spotlight on macOS 26+, Finder
/// Quick Actions). Everything here targets the macOS 13.0 App Intents floor
/// on purpose — no `supportedModes`/`openAppWhenRun` declarations, so every
/// intent runs in the background (the default across 13…27), which is exactly
/// right for driving an external mpv window from an LSUIElement app. The
/// system background-launches the app to run `perform()` when it isn't
/// already running; `applicationDidFinishLaunching` has wired all callbacks
/// by the time any `perform()` is delivered.
///
/// All real work goes through the intent facade in AppDelegate.swift
/// (`intent…` methods, @MainActor by contract — every `perform()` here is
/// @MainActor). Intents always pass `allowToggle: false`: an automation that
/// says "preview" must never be misread as a toggle-close.

// MARK: - Errors

enum MKVQPIntentError: Error, CustomLocalizedStringResourceConvertible {
    case noActiveSession
    case noVideosSelected
    case automationDenied
    case selectionUnavailable
    case notAFolder
    case noVideosInFolder
    case launchFailed
    case trashFailed
    case tagFailed

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noActiveSession:
            return "No video preview is open."
        case .noVideosSelected:
            return "No video files were selected. Select videos in Finder, or pass files to this action."
        case .automationDenied:
            return "MKV QuickPlay isn't allowed to read the Finder selection. Enable it in System Settings > Privacy & Security > Automation, or pass files to this action directly."
        case .selectionUnavailable:
            return "Finder didn't answer in time. Try again, or pass files to this action directly."
        case .notAFolder:
            return "That isn't a folder."
        case .noVideosInFolder:
            return "That folder contains no supported video files."
        case .launchFailed:
            return "The video player could not be started. Is mpv installed? (brew install mpv)"
        case .trashFailed:
            return "The file could not be moved to the Trash."
        case .tagFailed:
            return "The tag could not be changed."
        }
    }
}

/// The running app's delegate — the facade every intent calls into.
@MainActor
private func appDelegate() throws -> AppDelegate {
    guard let delegate = NSApp.delegate as? AppDelegate else {
        throw MKVQPIntentError.launchFailed
    }
    return delegate
}

// MARK: - Intents

struct PreviewVideosIntent: AppIntent {
    static let title: LocalizedStringResource = "Preview Videos"
    static let description = IntentDescription(
        "Open a quick mpv preview of videos. Pass files in (e.g. from a Finder Quick Action), or leave empty to preview the current Finder selection.",
        categoryName: "Preview")

    // Untyped on purpose: every @Parameter overload carrying
    // `supportedContentTypes:`/`description:` is macOS 15+, and this app's
    // floor is 13.0. Filtering happens in code (isVideoFile) — the same
    // philosophy as the NSServices entry's public.data + code filter.
    @Parameter(title: "Videos")
    var files: [IntentFile]?

    static var parameterSummary: some ParameterSummary {
        Summary("Preview \(\.$files)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let delegate = try appDelegate()
        let urls: [URL]
        if let files = files, !files.isEmpty {
            urls = files.compactMap { $0.fileURL }
        } else {
            // Same Apple Events channel as the global hotkey (needs the
            // Automation permission; the thrown errors explain the fix).
            urls = try await delegate.intentFinderSelection()
        }
        let count = try delegate.intentPreview(urls: urls)
        return .result(dialog: count == 1 ? "Previewing 1 video." : "Previewing \(count) videos.")
    }
}

struct NextVideoIntent: AppIntent {
    static let title: LocalizedStringResource = "Next Video"
    static let description = IntentDescription(
        "Skip the open preview to the next video in the folder.", categoryName: "Preview")

    static var parameterSummary: some ParameterSummary {
        Summary("Skip to the next video")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        switch try appDelegate().intentNavigate(forward: true) {
        case .moved(let name): return .result(dialog: "Now playing \(name).")
        case .atEnd, .atStart: return .result(dialog: "Already at the last video.")
        }
    }
}

struct PreviousVideoIntent: AppIntent {
    static let title: LocalizedStringResource = "Previous Video"
    static let description = IntentDescription(
        "Skip the open preview to the previous video in the folder.", categoryName: "Preview")

    static var parameterSummary: some ParameterSummary {
        Summary("Skip to the previous video")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        switch try appDelegate().intentNavigate(forward: false) {
        case .moved(let name): return .result(dialog: "Now playing \(name).")
        case .atEnd, .atStart: return .result(dialog: "Already at the first video.")
        }
    }
}

struct TrashCurrentVideoIntent: AppIntent {
    static let title: LocalizedStringResource = "Move Current Video to Trash"
    static let description = IntentDescription(
        "Move the video currently being previewed to the Trash and advance to the next one. Works even when the Delete-key safety is off — invoking this action by name is not an accidental keypress.",
        categoryName: "Culling")

    static var parameterSummary: some ParameterSummary {
        Summary("Move the current video to the Trash")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let name = try appDelegate().intentTrashCurrent()
        return .result(dialog: "Moved \(name) to the Trash.")
    }
}

struct TogglePurpleTagIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Purple Tag"
    static let description = IntentDescription(
        "Toggle the Purple Finder tag on the video currently being previewed — mark keepers during a culling pass.",
        categoryName: "Culling")

    static var parameterSummary: some ParameterSummary {
        Summary("Toggle the Purple tag on the current video")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> & ProvidesDialog {
        let tagged = try appDelegate().intentTogglePurpleTag()
        return .result(value: tagged, dialog: tagged ? "Tagged Purple." : "Purple tag removed.")
    }
}

struct StopPreviewIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Preview"
    static let description = IntentDescription(
        "Close the open video preview window.", categoryName: "Preview")

    static var parameterSummary: some ParameterSummary {
        Summary("Stop the video preview")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let closed = try appDelegate().intentStopPreview()
        return .result(dialog: closed ? "Preview closed." : "No preview was open.")
    }
}

struct ReviewFolderIntent: AppIntent {
    static let title: LocalizedStringResource = "Review Folder"
    static let description = IntentDescription(
        "Start a review session over every video in a folder, in Finder's displayed order — step through with the arrow keys, cull with Delete, mark keepers with P.",
        categoryName: "Culling")

    // Untyped for the macOS 13 floor (see above); perform() validates
    // that it is a directory.
    @Parameter(title: "Folder")
    var folder: IntentFile

    static var parameterSummary: some ParameterSummary {
        Summary("Review the videos in \(\.$folder)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        guard let url = folder.fileURL else { throw MKVQPIntentError.notAFolder }
        let count = try appDelegate().intentReviewFolder(url)
        return .result(value: count,
                       dialog: count == 1 ? "Reviewing 1 video." : "Reviewing \(count) videos.")
    }
}

// MARK: - App Shortcuts (Siri phrases + Spotlight on macOS 26+)

struct MKVQuickPlayShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PreviewVideosIntent(), phrases: [
            "Preview videos with \(.applicationName)",
            "Preview the selected videos in \(.applicationName)",
        ])
        AppShortcut(intent: NextVideoIntent(), phrases: [
            "Next video in \(.applicationName)",
            "Skip to the next video in \(.applicationName)",
        ])
        AppShortcut(intent: PreviousVideoIntent(), phrases: [
            "Previous video in \(.applicationName)",
            "Go back a video in \(.applicationName)",
        ])
        AppShortcut(intent: TrashCurrentVideoIntent(), phrases: [
            "Trash this video in \(.applicationName)",
            "Move this video to the Trash in \(.applicationName)",
        ])
        AppShortcut(intent: TogglePurpleTagIntent(), phrases: [
            "Tag this video in \(.applicationName)",
            "Toggle the Purple tag in \(.applicationName)",
        ])
        AppShortcut(intent: StopPreviewIntent(), phrases: [
            "Stop the preview in \(.applicationName)",
            "Close \(.applicationName)",
        ])
    }
}
