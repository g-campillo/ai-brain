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

        // GUI-test hook: BRAIN_ASK_TEST=1 summons the panel with a canned transcript.
        // Synthetic input is off the table here — a synthesized ⌥Space is seen by the
        // frontmost app (Chrome opens claude.ai), and fake typing can leak into a live
        // terminal — so visual checks go through this instead.
        if ProcessInfo.processInfo.environment["BRAIN_ASK_TEST"] != nil {
            AskPanelController.shared.showSeeded()
        }
    }
}
