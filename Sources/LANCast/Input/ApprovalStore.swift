import Foundation

/// Persists which client browsers (identified by a `clientId` stored in the
/// browser's localStorage) are approved to control the host, and until when.
final class ApprovalStore {

    /// How long a control approval should last.
    enum Expiry: CaseIterable {
        case minutes15
        case hour1
        case untilStreamStops
        case permanent

        var label: String {
            switch self {
            case .minutes15: return "15 minutes"
            case .hour1: return "1 hour"
            case .untilStreamStops: return "Until streaming stops"
            case .permanent: return "Always (until revoked)"
            }
        }
    }

    private let defaults = UserDefaults.standard
    private let key = "controlApprovals" // [clientId: expiry epoch seconds]

    /// Approvals scoped to the current streaming session only (not persisted).
    private var untilStop: Set<String> = []

    /// Marker far enough in the future to mean "permanent".
    private static let permanentTimestamp: Double = 4_102_444_800 // 2100-01-01

    private var map: [String: Double] {
        get { (defaults.dictionary(forKey: key) as? [String: Double]) ?? [:] }
        set { defaults.set(newValue, forKey: key) }
    }

    /// Whether the given client currently has an unexpired approval.
    func isApproved(_ clientId: String) -> Bool {
        if untilStop.contains(clientId) { return true }
        if let ts = map[clientId] {
            if ts >= Date().timeIntervalSince1970 { return true }
            var m = map; m[clientId] = nil; map = m // prune expired
        }
        return false
    }

    func approve(_ clientId: String, expiry: Expiry) {
        switch expiry {
        case .minutes15: store(clientId, Date().addingTimeInterval(15 * 60))
        case .hour1: store(clientId, Date().addingTimeInterval(60 * 60))
        case .permanent: store(clientId, Date(timeIntervalSince1970: Self.permanentTimestamp))
        case .untilStreamStops: untilStop.insert(clientId)
        }
    }

    private func store(_ clientId: String, _ date: Date) {
        var m = map; m[clientId] = date.timeIntervalSince1970; map = m
    }

    /// Clears session-scoped approvals (call when streaming stops).
    func clearSession() { untilStop.removeAll() }

    /// Forgets all approvals, persisted and session.
    func forgetAll() {
        defaults.removeObject(forKey: key)
        untilStop.removeAll()
    }
}
