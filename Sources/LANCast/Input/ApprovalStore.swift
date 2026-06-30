import Foundation

/// A device that currently holds a control approval, for display in Settings.
struct ApprovedDevice: Identifiable {
    enum Kind {
        case timed(Date)   // expires at a specific date
        case permanent     // until manually revoked
        case session       // until streaming stops (not persisted)
    }

    let clientId: String
    let name: String
    let kind: Kind

    var id: String { clientId }

    /// Human-readable expiry description.
    var expiryLabel: String {
        switch kind {
        case .permanent: return "Always (until revoked)"
        case .session: return "Until streaming stops"
        case .timed(let date):
            let now = Date()
            if date <= now { return "Expired" }
            let mins = Int(date.timeIntervalSince(now) / 60)
            if mins < 60 { return "Expires in \(max(1, mins)) min" }
            let hours = Int((date.timeIntervalSince(now) / 3600).rounded())
            return "Expires in \(hours) hr"
        }
    }
}

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
    private let key = "controlApprovals"          // [clientId: expiry epoch seconds]
    private let namesKey = "controlApprovalNames"  // [clientId: device name]

    /// Approvals scoped to the current streaming session only (not persisted).
    private var untilStop: Set<String> = []
    private var sessionNames: [String: String] = [:]

    /// Marker far enough in the future to mean "permanent".
    private static let permanentTimestamp: Double = 4_102_444_800 // 2100-01-01

    private var map: [String: Double] {
        get { (defaults.dictionary(forKey: key) as? [String: Double]) ?? [:] }
        set { defaults.set(newValue, forKey: key) }
    }

    private var names: [String: String] {
        get { (defaults.dictionary(forKey: namesKey) as? [String: String]) ?? [:] }
        set { defaults.set(newValue, forKey: namesKey) }
    }

    /// Whether the given client currently has an unexpired approval.
    func isApproved(_ clientId: String) -> Bool {
        if untilStop.contains(clientId) { return true }
        if let ts = map[clientId] {
            if ts >= Date().timeIntervalSince1970 { return true }
            revoke(clientId) // prune expired
        }
        return false
    }

    func approve(_ clientId: String, name: String, expiry: Expiry) {
        let label = name.isEmpty ? clientId : name
        switch expiry {
        case .minutes15: store(clientId, name: label, Date().addingTimeInterval(15 * 60))
        case .hour1: store(clientId, name: label, Date().addingTimeInterval(60 * 60))
        case .permanent: store(clientId, name: label, Date(timeIntervalSince1970: Self.permanentTimestamp))
        case .untilStreamStops:
            untilStop.insert(clientId)
            sessionNames[clientId] = label
        }
    }

    private func store(_ clientId: String, name: String, _ date: Date) {
        var m = map; m[clientId] = date.timeIntervalSince1970; map = m
        var n = names; n[clientId] = name; names = n
    }

    /// All currently-approved devices, sorted by name. Prunes expired entries.
    func approvedDevices() -> [ApprovedDevice] {
        var result: [ApprovedDevice] = []
        let now = Date().timeIntervalSince1970
        let storedNames = names

        for (clientId, ts) in map {
            guard ts >= now else { revoke(clientId); continue }
            let name = storedNames[clientId] ?? clientId
            let kind: ApprovedDevice.Kind = ts >= Self.permanentTimestamp
                ? .permanent
                : .timed(Date(timeIntervalSince1970: ts))
            result.append(ApprovedDevice(clientId: clientId, name: name, kind: kind))
        }
        for clientId in untilStop {
            let name = sessionNames[clientId] ?? clientId
            result.append(ApprovedDevice(clientId: clientId, name: name, kind: .session))
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Revokes approval for a single device.
    func revoke(_ clientId: String) {
        var m = map; m[clientId] = nil; map = m
        var n = names; n[clientId] = nil; names = n
        untilStop.remove(clientId)
        sessionNames[clientId] = nil
    }

    /// Clears session-scoped approvals (call when streaming stops).
    func clearSession() {
        untilStop.removeAll()
        sessionNames.removeAll()
    }

    /// Forgets all approvals, persisted and session.
    func forgetAll() {
        defaults.removeObject(forKey: key)
        defaults.removeObject(forKey: namesKey)
        untilStop.removeAll()
        sessionNames.removeAll()
    }
}
