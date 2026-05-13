import Carbon
import Foundation

final class GlobalHotKeyManager {
    private let action: () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private let hotKeyID: EventHotKeyID

    init(id: UInt32 = 1, action: @escaping () -> Void) {
        self.action = action
        self.hotKeyID = EventHotKeyID(signature: GlobalHotKeyManager.signature, id: id)
    }

    deinit {
        unregister()
    }

    @discardableResult
    func setEnabled(_ isEnabled: Bool, configuration: HotKeyConfiguration) -> OSStatus {
        if isEnabled {
            return register(configuration)
        } else {
            unregister()
            return noErr
        }
    }

    private func register(_ configuration: HotKeyConfiguration) -> OSStatus {
        unregister()
        var registeredHotKey: EventHotKeyRef?
        let status = RegisterEventHotKey(
            configuration.keyCode,
            HotKeyModifier.carbonModifiers(from: configuration.modifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &registeredHotKey
        )
        if status == noErr {
            hotKeyRef = registeredHotKey
            let handlerStatus = installEventHandler()
            if handlerStatus != noErr {
                UnregisterEventHotKey(registeredHotKey)
                hotKeyRef = nil
                return handlerStatus
            }
        }
        return status
    }

    private func installEventHandler() -> OSStatus {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        let handler: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return noErr }

            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            let manager = Unmanaged<GlobalHotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            guard status == noErr,
                  hotKeyID.signature == GlobalHotKeyManager.signature,
                  hotKeyID.id == manager.hotKeyID.id
            else { return noErr }

            DispatchQueue.main.async {
                NSLog("VibeCopy global hotkey triggered")
                manager.action()
            }
            return noErr
        }

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            handler,
            1,
            &eventType,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            &eventHandlerRef
        )
        if status != noErr {
            NSLog("[VibeCopy] GlobalHotKeyManager InstallEventHandler failed: %d for hotkey ID=%u", status, hotKeyID.id)
        }
        return status
    }

    private func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
    }

    private static let signature: OSType = {
        let scalars = Array("VBCP".unicodeScalars)
        return scalars.reduce(0) { result, scalar in
            (result << 8) + OSType(scalar.value)
        }
    }()
}
