import Foundation
import OrgPresentation

/// The app icon's badge: the entries in the agenda's Overdue section that aren't done.
public enum OverdueBadge {
    /// The count for each day from `today`, for `days` days, if nothing is done meanwhile: today's
    /// overdue entries, then each day's scheduled and deadline entries once their day has passed.
    public static func counts(_ groups: [AgendaDayGroup], today: Int, days: Int) -> [Int] {
        func key(_ row: AgendaRow) -> String? {
            guard let item = row.item, !row.isDone, item.habit == nil, row.planningDay != nil else { return nil }
            return "\(item.path):\(item.headingOffset ?? item.markerOffset)"
        }
        var overdue = Set(groups.first { $0.day == today }?.overdue.compactMap(key) ?? [])
        var counts = [overdue.count]
        for day in today..<(today + days - 1) {
            let rows = groups.first { $0.day == day }?.rows ?? []
            overdue.formUnion(rows.filter { $0.planningDay == day }.compactMap(key))
            counts.append(overdue.count)
        }
        return counts
    }
}
