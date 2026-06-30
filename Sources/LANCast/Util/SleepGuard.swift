import Foundation
import IOKit.pwr_mgt

/// Holds an IOKit power assertion to keep the Mac (and its display) awake while
/// a stream is running. A sleeping display stops ScreenCaptureKit from
/// delivering frames, so we prevent display sleep specifically. Releasing the
/// guard restores normal power behavior.
final class SleepGuard {
    private var assertionID: IOPMAssertionID = 0
    private var active = false

    /// Begins preventing idle display/system sleep. No-op if already active.
    func begin(reason: String) {
        guard !active else { return }
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &id
        )
        if result == kIOReturnSuccess {
            assertionID = id
            active = true
            Log.log("Sleep prevented while streaming")
        } else {
            Log.log("Failed to create power assertion (\(result))")
        }
    }

    /// Releases the assertion, allowing the Mac to sleep again. No-op if inactive.
    func end() {
        guard active else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
        active = false
        Log.log("Sleep prevention released")
    }

    deinit { end() }
}
