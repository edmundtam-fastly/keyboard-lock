import Foundation

/// Opt-in recorder for tuning the auto-lock thresholds against real usage.
///
/// **This is deliberately not a keystroke recorder.** The detector's rules
/// only ever consider how many keys are down, how long they've been down,
/// and how close together they arrived — never which keys they are. So this
/// log stores exactly those measurements and nothing else: no key codes, no
/// characters, no window or application names. Nothing written here could
/// reconstruct what was typed, by design rather than by redaction.
enum CalibrationLog {
    /// One evaluation of the detector, reduced to the numbers its rules use.
    struct Sample {
        let time: TimeInterval          // seconds since logging began
        let kind: String                // "down" | "up" | "poll" | "mark-cat"
        let heldCount: Int              // keys physically down right now
        let heldSpread: TimeInterval    // arrival spread across those keys
        let maxHold: TimeInterval       // longest current hold
        let pinnedCount: Int            // keys held past the sitting duration
        let pinnedSpread: TimeInterval  // arrival spread across pinned keys
        let windowDowns: Int            // keyDowns inside the burst window
        let windowDistinct: Int         // distinct keys among those (count only)
        let trigger: String             // rule that fired, or "" for none
    }

    private static let header =
        "t,kind,held,held_spread_ms,max_hold_ms,pinned,pinned_spread_ms,win_downs,win_distinct,trigger\n"

    private static let directoryURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("KeyboardLock", isDirectory: true)
    }()

    static let fileURL: URL = directoryURL.appendingPathComponent("calibration.csv")

    /// Rows are appended from the event tap on the main run loop, so they're
    /// buffered in memory and flushed on a background queue — file I/O must
    /// never sit in the keystroke path.
    private static var buffer: [String] = []
    private static var started: TimeInterval?
    private static let flushQueue = DispatchQueue(label: "com.edmundtam.keyboardlock.calibration")
    private static let flushThreshold = 100
    private static let maxFileBytes: UInt64 = 20 * 1024 * 1024

    static func begin() {
        started = ProcessInfo.processInfo.systemUptime
        buffer.removeAll()
        flushQueue.async {
            do {
                try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: fileURL.path) {
                    try header.write(to: fileURL, atomically: true, encoding: .utf8)
                }
            } catch {
                NSLog("KeyboardLock: could not start calibration log: %@", String(describing: error))
            }
        }
    }

    static func end() {
        flush()
        started = nil
    }

    static func record(_ sample: Sample) {
        guard started != nil else { return }
        let millis = { (seconds: TimeInterval) in String(format: "%.0f", seconds * 1000) }
        let row = [
            String(format: "%.3f", sample.time),
            sample.kind,
            String(sample.heldCount),
            millis(sample.heldSpread),
            millis(sample.maxHold),
            String(sample.pinnedCount),
            millis(sample.pinnedSpread),
            String(sample.windowDowns),
            String(sample.windowDistinct),
            sample.trigger,
        ].joined(separator: ",")
        buffer.append(row)
        if buffer.count >= flushThreshold { flush() }
    }

    static func elapsed() -> TimeInterval {
        guard let started else { return 0 }
        return ProcessInfo.processInfo.systemUptime - started
    }

    private static func flush() {
        guard !buffer.isEmpty else { return }
        let pending = buffer.joined(separator: "\n") + "\n"
        buffer.removeAll(keepingCapacity: true)
        flushQueue.async {
            guard let data = pending.data(using: .utf8) else { return }
            do {
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                let size = try handle.seekToEnd()
                // Stop growing rather than silently eating the disk; the
                // first stretch of a session is the representative part.
                guard size < maxFileBytes else { return }
                try handle.write(contentsOf: data)
            } catch {
                NSLog("KeyboardLock: calibration write failed: %@", String(describing: error))
            }
        }
    }
}
