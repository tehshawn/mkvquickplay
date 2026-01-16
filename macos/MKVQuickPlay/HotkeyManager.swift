import Cocoa
import Carbon.HIToolbox

/// Manages global hotkey detection for Control+Space
class HotkeyManager {

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    var isPreviewActive = false

    // Callbacks
    var onHotkeyPressed: (() -> Void)?
    var onUpArrowPressed: (() -> Void)?
    var onDownArrowPressed: (() -> Void)?
    var onEscapePressed: (() -> Void)?

    init() {
        checkAccessibilityPermission()
    }

    deinit {
        stop()
    }

    @discardableResult
    func checkAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)

        if !trusted {
            showAccessibilityAlert()
        }

        return trusted
    }

    private func showAccessibilityAlert() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Accessibility Permission Required"
            alert.informativeText = "MKV QuickPlay needs accessibility permission to detect Control+Space hotkey.\n\nPlease grant permission in System Settings > Privacy & Security > Accessibility."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Later")

            if alert.runModal() == .alertFirstButtonReturn {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    private func showEventTapFailedAlert() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Hotkey Detection Failed"
            alert.informativeText = "Could not start hotkey detection (Control+Space).\n\nThis may happen if:\n1. Accessibility permission was not granted\n2. The app needs to be re-authorized\n\nTry these steps:\n1. Open System Settings > Privacy & Security > Accessibility\n2. Remove MKV QuickPlay from the list\n3. Quit and relaunch MKV QuickPlay\n4. Grant permission when prompted"
            alert.alertStyle = .critical
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "OK")

            if alert.runModal() == .alertFirstButtonReturn {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    func start() {
        guard eventTap == nil else { return }

        NSLog("[MKVQuickPlay] Starting hotkey manager...")

        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue)

        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passRetained(event) }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
            return manager.handleEvent(proxy: proxy, type: type, event: event)
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: refcon
        ) else {
            NSLog("[MKVQuickPlay] ERROR: Failed to create event tap!")
            NSLog("[MKVQuickPlay] This may be due to:")
            NSLog("[MKVQuickPlay] 1. Accessibility permission not granted")
            NSLog("[MKVQuickPlay] 2. App not properly signed/authorized for this Mac")
            NSLog("[MKVQuickPlay] Please check System Settings > Privacy & Security > Accessibility")
            showEventTapFailedAlert()
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        NSLog("[MKVQuickPlay] Event tap created successfully - hotkeys active")
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }

        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            runLoopSource = nil
        }

        eventTap = nil
    }

    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-enable tap if disabled
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passRetained(event)
        }

        guard type == .keyDown else {
            return Unmanaged.passRetained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        // Control+Space (keyCode 49)
        if keyCode == 49 && flags.contains(.maskControl) {
            DispatchQueue.main.async { [weak self] in
                self?.onHotkeyPressed?()
            }
            return nil
        }

        // Arrow keys and Escape only work when preview is active
        if isPreviewActive {
            switch keyCode {
            case 126: // Up arrow
                DispatchQueue.main.async { [weak self] in
                    self?.onUpArrowPressed?()
                }
                return nil

            case 125: // Down arrow
                DispatchQueue.main.async { [weak self] in
                    self?.onDownArrowPressed?()
                }
                return nil

            case 53: // Escape
                DispatchQueue.main.async { [weak self] in
                    self?.onEscapePressed?()
                }
                return nil

            default:
                break
            }
        }

        return Unmanaged.passRetained(event)
    }
}
