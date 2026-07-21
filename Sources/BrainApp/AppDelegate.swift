import AppKit
import Carbon.HIToolbox

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hotKeyRef: EventHotKeyRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        // Capture-free closure → C function pointer. Carbon dispatches hotkey
        // events on the main thread's event loop, so assumeIsolated is safe.
        InstallEventHandler(GetEventDispatcherTarget(), { _, _, _ in
            MainActor.assumeIsolated { AskPanelController.shared.toggle() }
            return noErr
        }, 1, &spec, nil, nil)

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4252_4149), id: 1) // "BRAI"
        let status = RegisterEventHotKey(
            UInt32(kVK_Space), UInt32(optionKey), hotKeyID,
            GetEventDispatcherTarget(), 0, &ref
        )
        if status != noErr {
            // ⌥Space taken by another app; the menu-bar "Ask Claude" row still works.
            NSLog("Brain: ⌥Space hotkey registration failed (\(status))")
        }
        hotKeyRef = ref
    }
}
