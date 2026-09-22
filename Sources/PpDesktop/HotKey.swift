import AppKit
import Carbon

@MainActor
final class HotKey {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onCancel: (() -> Void)?

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var isPressed = false
    private static let signature: OSType = 0x50704473 // PpDs

    func register(_ shortcut: KeyboardShortcut = .load()) throws {
        guard hotKey == nil else { return }
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let installed = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                let owner = Unmanaged<HotKey>.fromOpaque(context).takeUnretainedValue()
                // Carbon application events run on the main event loop.
                return MainActor.assumeIsolated { owner.handle(event) }
            },
            eventTypes.count, &eventTypes,
            Unmanaged.passUnretained(self).toOpaque(), &handler
        )
        guard installed == noErr else {
            throw HotKeyError(code: installed, operation: "Install keyboard handler")
        }
        let registered = RegisterEventHotKey(
            shortcut.keyCode, shortcut.modifiers,
            EventHotKeyID(signature: Self.signature, id: 1),
            GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &hotKey
        )
        guard registered == noErr else {
            unregister()
            throw HotKeyError(code: registered, operation: "Register \(shortcut.label)")
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == UInt16(kVK_Escape), !event.isARepeat {
                MainActor.assumeIsolated { self?.onCancel?() }
            }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == UInt16(kVK_Escape), !event.isARepeat {
                MainActor.assumeIsolated { self?.onCancel?() }
            }
        }
    }

    func unregister() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        if let handler { RemoveEventHandler(handler) }
        handler = nil
        isPressed = false
    }

    private func handle(_ event: EventRef) -> OSStatus {
        var identifier = EventHotKeyID()
        let result = GetEventParameter(
            event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
            nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier
        )
        guard result == noErr, identifier.signature == Self.signature, identifier.id == 1 else {
            return OSStatus(eventNotHandledErr)
        }
        switch GetEventKind(event) {
        case UInt32(kEventHotKeyPressed):
            if !isPressed {
                isPressed = true
                onPress?()
            }
        case UInt32(kEventHotKeyReleased):
            if isPressed {
                isPressed = false
                onRelease?()
            }
        default:
            return OSStatus(eventNotHandledErr)
        }
        return noErr
    }
}

private struct HotKeyError: LocalizedError {
    let code: OSStatus
    let operation: String

    var errorDescription: String? {
        if code == OSStatus(eventHotKeyExistsErr) {
            return "That shortcut is already registered by another app. Choose a different combination."
        }
        return "\(operation) failed (macOS error \(code))."
    }
}

struct KeyboardShortcut: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let label: String

    static let defaultShortcut = KeyboardShortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey), label: "⌃⌥Space")
    static func load(defaults: UserDefaults = .standard) -> KeyboardShortcut {
        guard let data = defaults.data(forKey: "VoiceShortcut"),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return defaultShortcut }
        return value
    }
    func save(defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: "VoiceShortcut") }
    }
    init(keyCode: UInt32, modifiers: UInt32, label: String) {
        self.keyCode = keyCode; self.modifiers = modifiers; self.label = label
    }
    init(event: NSEvent) {
        let flags = event.modifierFlags
        var mask: UInt32 = 0
        var prefix = ""
        for (flag, carbon, symbol) in [(NSEvent.ModifierFlags.control, controlKey, "⌃"), (.option, optionKey, "⌥"), (.shift, shiftKey, "⇧"), (.command, cmdKey, "⌘")] {
            if flags.contains(flag) { mask |= UInt32(carbon); prefix += symbol }
        }
        let names: [UInt16: String] = [49: "Space", 36: "Return", 48: "Tab", 51: "Delete", 53: "Escape", 123: "←", 124: "→", 125: "↓", 126: "↑", 117: "Forward Delete", 115: "Home", 119: "End", 116: "Page Up", 121: "Page Down"]
        let functions: [UInt16] = [122,120,99,118,96,97,98,100,101,109,103,111,105,107,113,106,64,79,80,90]
        let name = names[event.keyCode] ?? functions.firstIndex(of: event.keyCode).map { "F\($0 + 1)" } ?? event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)"
        self.init(keyCode: UInt32(event.keyCode), modifiers: mask, label: prefix + name)
    }
}
