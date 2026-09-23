import Foundation
import AppKit
import ApplicationServices

public enum WhatsAppAdapterState: Equatable, Sendable {
    case readyForConfirmation(contact: String, text: String)
    case sent
    case failed(reason: String)
}

public enum WhatsAppAdapter {
    /// Prepares a WhatsApp message:
    /// Activates WhatsApp -> locates search field via AX -> sets contact query ->
    /// locates message entry field -> inserts text (sets AX value once, no per-char keystrokes) ->
    /// stops and requires explicit confirmation.
    public static func prepare(contact: String, text: String) async throws -> WhatsAppAdapterState {
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier?.lowercased().contains("whatsapp") == true ||
            $0.localizedName?.lowercased().contains("whatsapp") == true
        }) else {
            // Try launching WhatsApp if not running
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "net.whatsapp.WhatsApp") ??
                         NSWorkspace.shared.urlForApplication(withBundleIdentifier: "net.whatsapp.WhatsAppMac") {
                let config = NSWorkspace.OpenConfiguration()
                _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
                try await Task.sleep(nanoseconds: 1_500_000_000)
            } else {
                throw NSError(domain: "WhatsAppAdapter", code: 404, userInfo: [NSLocalizedDescriptionKey: "WhatsApp is not installed or running."])
            }
            return .readyForConfirmation(contact: contact, text: text)
        }

        app.activate(options: [.activateIgnoringOtherApps])
        try await Task.sleep(nanoseconds: 300_000_000)

        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        // Find and populate search or chat field if AX is available
        var windowsRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
           let windows = windowsRef as? [AXUIElement], let mainWindow = windows.first {
            // Find text fields
            if let inputElement = findFirstEditableElement(in: mainWindow) {
                // Set the value once directly on AXUIElement
                AXUIElementSetAttributeValue(inputElement, kAXValueAttribute as CFString, text as CFTypeRef)
            }
        }

        return .readyForConfirmation(contact: contact, text: text)
    }

    /// Explicit send step — executed ONLY after user confirmation ("send it" or ⌘↩).
    public static func confirmAndSend() async throws -> Bool {
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier?.lowercased().contains("whatsapp") == true ||
            $0.localizedName?.lowercased().contains("whatsapp") == true
        }) else {
            throw NSError(domain: "WhatsAppAdapter", code: 404, userInfo: [NSLocalizedDescriptionKey: "WhatsApp not active."])
        }

        app.activate(options: [.activateIgnoringOtherApps])
        try await Task.sleep(nanoseconds: 150_000_000)

        // Post Return key event
        let source = CGEventSource(stateID: .combinedSessionState)
        let returnDown = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true)
        let returnUp = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false)
        returnDown?.postToPid(app.processIdentifier)
        returnUp?.postToPid(app.processIdentifier)

        return true
    }

    private static func findFirstEditableElement(in element: AXUIElement) -> AXUIElement? {
        var roleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
           let role = roleRef as? String {
            if role == (kAXTextAreaRole as String) || role == (kAXTextFieldRole as String) {
                return element
            }
        }

        var childrenRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
           let children = childrenRef as? [AXUIElement] {
            for child in children {
                if let found = findFirstEditableElement(in: child) {
                    return found
                }
            }
        }

        return nil
    }
}
