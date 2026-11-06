import Foundation

/// Which heatmap cell is selected (X6, X10). One selection, always in the visible week.
public enum HeatmapSelection {
    /// Keeps `current` while it is an enabled cell of `week`, including a cell whose count dropped
    /// to 0 (X10). Otherwise (first load, a page change, or the selected cell became disabled or
    /// missing after a rebuild) falls back to the week's best; a week with no best selects nothing.
    public static func resolve(current: HeatmapCell.ID?, week: HeatmapWeek?) -> HeatmapCell.ID? {
        guard let week else { return nil }
        if let current, week.cells.contains(where: { $0.id == current && $0.isEnabled }) { return current }
        return week.best?.id
    }

    /// Share needs a selected cell with at least one friend in a common window (X10), so a
    /// "0 of 15" slot can never be sent and ShareText always has a time to print (X9).
    public static func canShare(_ cell: HeatmapCell?) -> Bool {
        guard let cell else { return false }
        return cell.commonCount >= 1 && cell.commonWindow != nil
    }
}
