import Foundation

enum AccountTokenMaintenance {
    static let interval: TimeInterval = 24 * 60 * 60
    static let checkInterval: TimeInterval = 15 * 60
    static let lastSuccessfulCheckKey = "headroomLastSuccessfulAccountCheck"

    static func isDue(lastSuccessfulCheck: Date?, now: Date = Date()) -> Bool {
        guard let lastSuccessfulCheck else { return true }
        return now.timeIntervalSince(lastSuccessfulCheck) >= interval
    }
}
