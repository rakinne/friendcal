import SwiftUI
import FriendCalCore

/// "Brunch overlap" card (D18, D24, D30): 7 x 3 count-only grid paged by week. The number, fill,
/// best pill and VoiceOver text all use commonCount (D13). Tap selects (D22); the best cell gets a
/// pill, the selected cell a ring (D26).
struct HeatmapCard: View {
    enum Content {
        case loading
        case noProposal
        case weeks([HeatmapWeek])
    }

    var title = "Brunch overlap"
    let content: Content
    var total: Int = 0
    var visibleWeekID: Date?
    var selectedCellID: HeatmapCell.ID?
    var lastUpdated: Date = .now
    var calendar: Calendar = .current
    var onShowWeek: (Date?) -> Void = { _ in }
    var onSelect: (HeatmapCell.ID) -> Void = { _ in }
    var onRequestTimes: () -> Void = {}

    static let gutter: CGFloat = 52
    static let cellHeight: CGFloat = 44
    /// Each cell pads half the 4pt gap on every side so hit areas tile the grid (D32).
    static let halfGap: CGFloat = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch content {
            case .loading:
                skeletonHeader
                HeatmapGrid(week: nil, weekIndex: 0, total: 0, selectedCellID: nil, calendar: calendar, onSelect: { _ in })
            case .noProposal:
                noProposal
            case .weeks(let weeks):
                header(weeks: weeks)
                pager(weeks: weeks)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg).fill(DesignTokens.Colors.surface))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg).stroke(DesignTokens.Colors.border, lineWidth: 1))
        .shadow(color: DesignTokens.Colors.shadow.opacity(0.12), radius: 12, x: 0, y: 8)
        .sensoryFeedback(.selection, trigger: selectedCellID)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("heatmapCard")
    }

    // MARK: Header

    private func header(weeks: [HeatmapWeek]) -> some View {
        let range = (weeks.first { $0.id == visibleWeekID } ?? weeks.first).map { Self.rangeLabel(for: $0, calendar: calendar) } ?? ""
        let titleText = Text(title).textStyle(.title).foregroundStyle(DesignTokens.Colors.text)
        let ofTotal = Text("of \(total) free").textStyle(.caption).foregroundStyle(DesignTokens.Colors.textMuted)
        let live = LiveBadge(lastUpdated: lastUpdated, weeks: weeks)
        let dates = Text(range).textStyle(.caption).foregroundStyle(DesignTokens.Colors.textMuted)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { titleText; ofTotal; live; Spacer(minLength: 4); dates }.lineLimit(1)
            VStack(alignment: .leading, spacing: 2) {
                titleText
                HStack(spacing: 8) { ofTotal; live; Spacer(minLength: 4); dates }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var skeletonHeader: some View {
        HStack {
            Capsule().fill(Color.skeleton).frame(width: 150, height: 16)
            Spacer()
            Capsule().fill(Color.skeleton).frame(width: 56, height: 12)
        }
        .frame(height: 22)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading overlap")
    }

    // MARK: Pager

    @ViewBuilder
    private func pager(weeks: [HeatmapWeek]) -> some View {
        let visibleIndex = weeks.firstIndex { $0.id == visibleWeekID } ?? 0
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(weeks.enumerated()), id: \.element.id) { i, week in
                    HeatmapGrid(week: week, weekIndex: i, total: total, selectedCellID: selectedCellID, calendar: calendar, onSelect: onSelect)
                        .containerRelativeFrame(.horizontal)
                        .id(week.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollIndicators(.hidden)
        .scrollPosition(id: Binding(get: { visibleWeekID }, set: onShowWeek))
        .scrollClipDisabled(false)

        if weeks.indices.contains(visibleIndex), weeks[visibleIndex].best == nil {
            Text("No overlap yet. Nudge your crew.")
                .textStyle(.label).foregroundStyle(DesignTokens.Colors.textMuted)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("heatmap.noOverlap")
        }
        if weeks.count > 1 {
            PageDots(count: weeks.count, index: visibleIndex,
                     label: Self.rangeLabel(for: weeks[visibleIndex], calendar: calendar)) { next in
                onShowWeek(weeks[next].id)
            }
        }
    }

    // MARK: Empty

    private var noProposal: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text("No plans brewing").textStyle(.title).foregroundStyle(DesignTokens.Colors.text)
                .accessibilityAddTraits(.isHeader)
            Text("Send a Request for Times and your crew's overlap shows up here.")
                .textStyle(.body).foregroundStyle(DesignTokens.Colors.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onRequestTimes) {
                Text("Request times").textStyle(.button).foregroundStyle(DesignTokens.Colors.onPrimary)
                    .padding(.horizontal, 20).frame(minHeight: 44)
                    .background(Capsule().fill(DesignTokens.Colors.accentHover))
            }
            .accessibilityIdentifier("heatmap.requestTimes")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Labels

    /// "Nov 9–15" or "Nov 30–Dec 6".
    static func rangeLabel(for week: HeatmapWeek, calendar: Calendar) -> String {
        let end = calendar.date(byAdding: .day, value: 6, to: week.weekStart)!
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.setLocalizedDateFormatFromTemplate("MMMd")
        let sameMonth = calendar.component(.month, from: week.weekStart) == calendar.component(.month, from: end)
        let endText = sameMonth ? String(calendar.component(.day, from: end)) : f.string(from: end)
        return "\(f.string(from: week.weekStart))–\(endText)"
    }
}

// MARK: - Grid

/// One week: column headers, row labels and 21 cells. `week == nil` draws the loading skeleton.
private struct HeatmapGrid: View {
    let week: HeatmapWeek?
    let weekIndex: Int
    let total: Int
    let selectedCellID: HeatmapCell.ID?
    let calendar: Calendar
    let onSelect: (HeatmapCell.ID) -> Void

    private static let rowLabels: [(Daypart, String, String)] = [
        (.morning, "Morning", "6a–12p"), (.afternoon, "Afternoon", "12p–5p"), (.evening, "Evening", "5p–11p"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.frame(width: HeatmapCard.gutter, height: 1)
                ForEach(0..<7, id: \.self) { d in
                    Text(Self.shortDay(d, calendar: calendar))
                        .textStyle(.caption).foregroundStyle(DesignTokens.Colors.textMuted)
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.bottom, HeatmapCard.halfGap)
            .accessibilityHidden(true)

            ForEach(Self.rowLabels, id: \.0) { part, name, hours in
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(name).textStyle(.label).foregroundStyle(DesignTokens.Colors.text)
                        Text(hours).textStyle(.caption).foregroundStyle(DesignTokens.Colors.textMuted)
                    }
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .frame(width: HeatmapCard.gutter, alignment: .leading)
                    .accessibilityHidden(true)
                    ForEach(0..<7, id: \.self) { d in
                        if let week {
                            let cell = week.cell(dayIndex: d, daypart: part)
                            HeatmapCellView(cell: cell, isSelected: cell.id == selectedCellID, label: label(for: cell))
                                .onTapGesture { if cell.isEnabled { onSelect(cell.id) } }
                                .accessibilityIdentifier("heatmap.w\(weekIndex).d\(d).\(part)")
                                .accessibilityAction { if cell.isEnabled { onSelect(cell.id) } }
                                .zIndex(cell.isBest || cell.id == selectedCellID ? 1 : 0)
                        } else {
                            RoundedRectangle(cornerRadius: DesignTokens.Radius.sm).fill(DesignTokens.Colors.peachLight)
                                .frame(height: HeatmapCard.cellHeight)
                                .padding(HeatmapCard.halfGap)
                                .frame(maxWidth: .infinity)
                                .accessibilityHidden(true)
                        }
                    }
                }
                // The best pill hangs below its row, so that row draws over the next one.
                .zIndex(week?.cells.contains { $0.daypart == part && ($0.isBest || $0.id == selectedCellID) } == true ? 1 : 0)
            }
        }
        // D31: numerals and day headers stop growing at xxxLarge; cells offer the Large Content Viewer.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    /// "Saturday afternoon, 13 of 15 free, best, selected" (D22).
    private func label(for cell: HeatmapCell) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "EEEE"
        let name = "\(f.string(from: cell.day)) \(String(describing: cell.daypart))"
        guard cell.isEnabled else { return "\(name), outside the proposal window" }
        var parts = [name, cell.total == 0 ? "no one invited" : "\(cell.commonCount) of \(cell.total) free"]
        if cell.isBest { parts.append("best") }
        if cell.id == selectedCellID { parts.append("selected") }
        return parts.joined(separator: ", ")
    }

    /// Monday-first short weekday names from the calendar's locale.
    static func shortDay(_ index: Int, calendar: Calendar) -> String {
        let symbols = calendar.shortWeekdaySymbols // Sunday first
        return symbols[(index + 1) % 7]
    }
}

private struct HeatmapCellView: View {
    let cell: HeatmapCell
    let isSelected: Bool
    let label: String

    var body: some View {
        ZStack {
            if cell.isEnabled {
                RoundedRectangle(cornerRadius: DesignTokens.Radius.sm).fill(fill)
                Text(cell.total == 0 ? "–" : "\(cell.commonCount)")
                    .textStyle(.mono)
                    .foregroundStyle(DesignTokens.Colors.text) // D25: >= 5.5:1 on every ramp step
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            } else {
                RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
                    .strokeBorder(DesignTokens.Colors.border, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .frame(height: HeatmapCard.cellHeight)
        .overlay {
            if isSelected {
                // 2pt text ring outside a 2pt surface gap (D26).
                RoundedRectangle(cornerRadius: DesignTokens.Radius.sm + 4)
                    .strokeBorder(DesignTokens.Colors.text, lineWidth: 2)
                    .padding(-4)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottom) {
            if cell.isBest {
                Text("best")
                    .textStyle(.badge)
                    .foregroundStyle(DesignTokens.Colors.text)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(DesignTokens.Colors.surface))
                    .overlay(Capsule().stroke(DesignTokens.Colors.primary, lineWidth: 1))
                    .fixedSize()
                    .offset(y: 8)
                    .allowsHitTesting(false)
            }
        }
        .padding(HeatmapCard.halfGap)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityAddTraits(cell.isEnabled ? [.isButton] : [])
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityShowsLargeContentViewer {
            Text(cell.isEnabled ? "\(cell.commonCount) of \(cell.total)" : "–")
        }
    }

    private var fill: Color {
        switch cell.ramp {
        case .primary: return DesignTokens.Colors.primary
        case .orange: return DesignTokens.Colors.heatOrange
        case .peach: return DesignTokens.Colors.peach
        case .peachLight, nil: return DesignTokens.Colors.peachLight
        }
    }
}

// MARK: - LIVE

/// Solid teal LIVE that turns grey "Updated Nm ago" after 5 minutes (D19), reading time from a
/// minute timeline rather than `Date()` in the body. Pulses once, only when the weeks change (D23).
private struct LiveBadge: View {
    let lastUpdated: Date
    let weeks: [HeatmapWeek]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var beat = 0

    var body: some View {
        TimelineView(.everyMinute) { context in
            let minutes = Int(context.date.timeIntervalSince(lastUpdated) / 60)
            let stale = minutes >= 5
            HStack(spacing: 4) {
                SwiftUI.Circle()
                    .fill(stale ? DesignTokens.Colors.textMuted : DesignTokens.Colors.accent)
                    .frame(width: 6, height: 6)
                    .phaseAnimator([1.0, 1.8, 1.0], trigger: beat) { dot, scale in
                        dot.scaleEffect(scale)
                    } animation: { _ in .easeOut(duration: 0.16) }
                Text(stale ? "Updated \(minutes)m ago" : "LIVE")
                    .textStyle(.badge)
                    .tracking(stale ? 0 : 0.4)
                    .foregroundStyle(stale ? DesignTokens.Colors.textMuted : DesignTokens.Colors.accentHover)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(stale ? "Updated \(minutes) minutes ago" : "Live")
            .accessibilityIdentifier("heatmap.live")
        }
        .onChange(of: weeks) { if !reduceMotion { beat += 1 } }
    }
}

// MARK: - Page dots

/// Week indicator; VoiceOver swipes up/down to change week.
private struct PageDots: View {
    let count: Int
    let index: Int
    let label: String
    let onChange: (Int) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                SwiftUI.Circle()
                    .fill(i == index ? DesignTokens.Colors.text : DesignTokens.Colors.border)
                    .frame(width: 6, height: 6)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Week")
        .accessibilityValue("\(index + 1) of \(count), \(label)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: if index + 1 < count { onChange(index + 1) }
            case .decrement: if index > 0 { onChange(index - 1) }
            @unknown default: break
            }
        }
        .accessibilityIdentifier("heatmap.pageIndicator")
    }
}

// MARK: - Previews

private struct HeatmapPreview: View {
    @State var model: HomeModel
    var body: some View {
        HeatmapCard(content: model.proposal == nil ? .noProposal : .weeks(model.weeks), total: model.total,
                    visibleWeekID: model.visibleWeekID, selectedCellID: model.selectedCellID,
                    lastUpdated: model.lastUpdated, calendar: model.calendar,
                    onShowWeek: model.showWeek, onSelect: model.select)
            .padding(20)
            .background(DesignTokens.Colors.background)
    }
}

#Preview("Heatmap, populated") { HeatmapPreview(model: HomeModel(fixture: FixtureData.make(.populated))) }
#Preview("Heatmap, zero overlap") { HeatmapPreview(model: HomeModel(fixture: FixtureData.make(.zeroOverlap))) }
#Preview("Heatmap, single week") { HeatmapPreview(model: HomeModel(fixture: FixtureData.make(.singleWeek))) }
#Preview("Heatmap, stale") { HeatmapPreview(model: HomeModel(fixture: FixtureData.make(.stale))) }
#Preview("Heatmap, no proposal") { HeatmapPreview(model: HomeModel(fixture: FixtureData.make(.noProposal))) }
#Preview("Heatmap, loading") {
    HeatmapCard(content: .loading).padding(20).background(DesignTokens.Colors.background)
}
