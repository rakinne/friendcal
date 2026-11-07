import SwiftUI
import FriendCalCore

/// "Brunch overlap" card (D18, D24, D30): 7 x 3 count-only grid paged by week. The number, fill,
/// best pill and VoiceOver text all use commonCount (D13). In `.select` mode a tap selects (D22);
/// the best cell gets a pill, the selected cell a ring (D26). In `.mark` mode (issue #5 design
/// 1.4A, 5.1A, 5.2A, 6.1A) a tap toggles the current user's hold: mine cells carry a teal ring and
/// check, past cells go quiet, and the layout drops the gutter for 44pt-wide cells.
struct HeatmapCard: View {
    enum Content {
        case loading
        case noProposal
        case weeks([HeatmapWeek])
    }

    enum Mode: Equatable {
        case select
        case mark(mine: Set<HeatmapCell.ID>, now: Date)
    }

    /// nil hides the title line (the availability sheet carries its own).
    var title: String? = "Brunch overlap"
    let content: Content
    var mode: Mode = .select
    var total: Int = 0
    var visibleWeekID: Date?
    var selectedCellID: HeatmapCell.ID?
    /// The locked window's cell (design 2.2A): a `primary` "locked" pill replaces the best pill.
    var lockedCellID: HeatmapCell.ID?
    var lastUpdated: Date = .now
    var calendar: Calendar = .current
    var onShowWeek: (Date?) -> Void = { _ in }
    var onSelect: (HeatmapCell.ID) -> Void = { _ in }
    var onRequestTimes: () -> Void = {}
    /// When set, the title row is a link to the invite (design 1.1A: "Brunch overlap ›").
    var onOpenInvite: (() -> Void)?

    static let gutter: CGFloat = 52
    static let cellHeight: CGFloat = 44
    /// Each cell pads half the 4pt gap on every side so hit areas tile the grid (D32).
    static let halfGap: CGFloat = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch content {
            case .loading:
                skeletonHeader
                HeatmapGrid(week: nil, weekIndex: 0, mode: mode, selectedCellID: nil, lockedCellID: nil, calendar: calendar, onSelect: { _ in })
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
        .accessibilityIdentifier(isMark ? "markCard" : "heatmapCard")
    }

    private var isMark: Bool {
        if case .mark = mode { return true }
        return false
    }

    // MARK: Header

    @ViewBuilder
    private func header(weeks: [HeatmapWeek]) -> some View {
        let range = (weeks.first { $0.id == visibleWeekID } ?? weeks.first).map { Self.rangeLabel(for: $0, calendar: calendar) } ?? ""
        let ofTotal = Text("of \(total) free").textStyle(.caption).foregroundStyle(DesignTokens.Colors.textMuted)
        let live = LiveBadge(lastUpdated: lastUpdated, weeks: weeks)
        let dates = Text(range).textStyle(.caption).foregroundStyle(DesignTokens.Colors.textMuted)
        if let title {
            let titleText = HStack(spacing: 2) {
                Text(title).textStyle(.title).foregroundStyle(DesignTokens.Colors.text)
                if onOpenInvite != nil {
                    Image(systemName: "chevron.right").imageScale(.small).foregroundStyle(DesignTokens.Colors.textMuted)
                }
            }
            let row = ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { titleText; ofTotal; live; Spacer(minLength: 4); dates }.lineLimit(1)
                VStack(alignment: .leading, spacing: 2) {
                    titleText
                    HStack(spacing: 8) { ofTotal; live; Spacer(minLength: 4); dates }
                }
            }
            if let onOpenInvite {
                Button(action: onOpenInvite) { row.contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits([.isHeader, .isButton])
                    .accessibilityHint("Opens the invite")
                    .accessibilityIdentifier("heatmap.openInvite")
            } else {
                row.accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
            }
        } else {
            HStack(spacing: 8) { ofTotal; live; Spacer(minLength: 4); dates }
                .lineLimit(1)
                .accessibilityElement(children: .combine)
        }
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
                    HeatmapGrid(week: week, weekIndex: i, mode: mode, selectedCellID: selectedCellID, lockedCellID: lockedCellID, calendar: calendar, onSelect: onSelect)
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

        if weeks.indices.contains(visibleIndex), weeks[visibleIndex].best == nil, lockedCellID == nil {
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
        return DateText.dayRange(DateRange(lower: week.weekStart, upper: end), calendar: calendar, locale: .current)
    }
}

// MARK: - Grid

/// One week: column headers, row labels and 21 cells. `week == nil` draws the loading skeleton.
/// `.select` keeps the 52pt gutter (D30); `.mark` puts each row's label above it and tiles the
/// full width (design 6.1A). Both draw the same `HeatmapCellView`.
private struct HeatmapGrid: View {
    let week: HeatmapWeek?
    let weekIndex: Int
    let mode: HeatmapCard.Mode
    let selectedCellID: HeatmapCell.ID?
    let lockedCellID: HeatmapCell.ID?
    let calendar: Calendar
    let onSelect: (HeatmapCell.ID) -> Void

    private static let rowLabels: [(Daypart, String, String)] = [
        (.morning, "Morning", "6a–12p"), (.afternoon, "Afternoon", "12p–5p"), (.evening, "Evening", "5p–11p"),
    ]

    private var isMark: Bool {
        if case .mark = mode { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if !isMark { Color.clear.frame(width: HeatmapCard.gutter, height: 1) }
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
                if isMark {
                    Text("\(name) · \(hours)")
                        .textStyle(.label).foregroundStyle(DesignTokens.Colors.textMuted)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
                        .padding(.horizontal, HeatmapCard.halfGap)
                        .accessibilityHidden(true)
                }
                HStack(spacing: 0) {
                    if !isMark {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(name).textStyle(.label).foregroundStyle(DesignTokens.Colors.text)
                            Text(hours).textStyle(.caption).foregroundStyle(DesignTokens.Colors.textMuted)
                        }
                        .lineLimit(1).minimumScaleFactor(0.6)
                        .frame(width: HeatmapCard.gutter, alignment: .leading)
                        .accessibilityHidden(true)
                    }
                    ForEach(0..<7, id: \.self) { d in
                        if let week {
                            let cell = week.cell(dayIndex: d, daypart: part)
                            let style = style(for: cell)
                            HeatmapCellView(cell: cell, style: style, label: label(for: cell, style: style), hint: hint(for: cell, style: style))
                                .modifier(CellTap(enabled: style.isTappable) { onSelect(cell.id) })
                                .accessibilityIdentifier("\(isMark ? "mark" : "heatmap").w\(weekIndex).d\(d).\(part)")
                                .zIndex(cell.isBest || cell.id == selectedCellID || cell.id == lockedCellID ? 1 : 0)
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
                .zIndex(week?.cells.contains { $0.daypart == part && ($0.isBest || $0.id == selectedCellID || $0.id == lockedCellID) } == true ? 1 : 0)
            }
        }
        // D31: numerals and day headers stop growing at xxxLarge; cells offer the Large Content Viewer.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    private func style(for cell: HeatmapCell) -> HeatmapCellStyle {
        switch mode {
        case .select:
            return HeatmapCellStyle(isSelected: cell.id == selectedCellID, isMine: false, isPast: false,
                                    isLocked: cell.id == lockedCellID, hideZero: cell.id != selectedCellID, isTappable: cell.isEnabled)
        case .mark(let mine, let now):
            let past = cell.interval.map { $0.upperBound <= now } ?? false
            return HeatmapCellStyle(isSelected: false, isMine: mine.contains(cell.id), isPast: past,
                                    isLocked: cell.id == lockedCellID, hideZero: true, isTappable: cell.isEnabled && !past)
        }
    }

    /// "Saturday afternoon, 13 of 15 free, best, selected" (D22); in mark mode ", you're free here"
    /// or ", not marked" (design 5.1A); a past cell reads "Monday morning, already passed" (5.2A).
    private func label(for cell: HeatmapCell, style: HeatmapCellStyle) -> String {
        let name = DateText.dayPart(day: cell.day, daypart: cell.daypart, calendar: calendar, locale: .current, long: true)
        guard cell.isEnabled else { return "\(name), outside the proposal window" }
        if style.isPast { return "\(name), already passed" }
        var parts = [name, cell.total == 0 ? "no one invited" : "\(cell.commonCount) of \(cell.total) free"]
        if style.isLocked { parts.append("locked") } else if cell.isBest { parts.append("best") }
        if style.isSelected { parts.append("selected") }
        if isMark { parts.append(style.isMine ? "you're free here" : "not marked") }
        return parts.joined(separator: ", ")
    }

    private func hint(for cell: HeatmapCell, style: HeatmapCellStyle) -> String? {
        guard isMark, style.isTappable else { return nil }
        return style.isMine ? "Double-tap to take it back" : "Double-tap to mark free"
    }

    /// Monday-first short weekday names from the calendar's locale.
    static func shortDay(_ index: Int, calendar: Calendar) -> String {
        let symbols = calendar.shortWeekdaySymbols // Sunday first
        return symbols[(index + 1) % 7]
    }
}

/// Tap and the VoiceOver default action only on tappable cells: a disabled or past cell carries no
/// action, so it is not a button (design 5.2A).
private struct CellTap: ViewModifier {
    let enabled: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        if enabled {
            content.onTapGesture { action() }.accessibilityAction { action() }
        } else {
            content
        }
    }
}

struct HeatmapCellStyle: Equatable {
    var isSelected: Bool
    var isMine: Bool
    var isPast: Bool
    var isLocked: Bool
    var hideZero: Bool
    var isTappable: Bool
}

/// One cell, shared by both grid modes: ramp fill, numeral, best / locked pill, selection or
/// my-hold ring (DESIGN.md Heatmap: selection ring = `text`, my-hold ring = `accent` + check).
struct HeatmapCellView: View {
    let cell: HeatmapCell
    let style: HeatmapCellStyle
    let label: String
    var hint: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if style.isPast {
                // Design 5.2A: quiet, no numeral, no border, no button trait.
                RoundedRectangle(cornerRadius: DesignTokens.Radius.sm).fill(DesignTokens.Colors.surface2)
            } else if cell.isEnabled {
                RoundedRectangle(cornerRadius: DesignTokens.Radius.sm).fill(fill)
                // 0-count cells are blank so zero overlap reads as an empty grid (D19); the
                // selected cell keeps its number, and VoiceOver still says "0 of 15 free".
                Text(cell.total == 0 ? "–" : "\(cell.commonCount)")
                    .opacity(cell.total > 0 && cell.commonCount == 0 && style.hideZero ? 0 : 1)
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
            if style.isSelected || style.isMine {
                // 2pt ring outside a 2pt surface gap (D26); `accent` for my hold (design 5.1A).
                RoundedRectangle(cornerRadius: DesignTokens.Radius.sm + 4)
                    .strokeBorder(style.isMine ? DesignTokens.Colors.accent : DesignTokens.Colors.text, lineWidth: 2)
                    .padding(-4)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topTrailing) {
            if style.isMine {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(DesignTokens.Colors.onPrimary)
                    .frame(width: 16, height: 16)
                    .background(SwiftUI.Circle().fill(DesignTokens.Colors.accent))
                    .offset(x: 4, y: -4)
                    .transition(reduceMotion ? .identity : .scale)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottom) {
            if style.isLocked {
                pill("locked", fill: DesignTokens.Colors.primary, text: DesignTokens.Colors.onPrimary, stroke: DesignTokens.Colors.primary)
            } else if cell.isBest {
                pill("best", fill: DesignTokens.Colors.surface, text: DesignTokens.Colors.text, stroke: DesignTokens.Colors.primary)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: style.isMine)
        .padding(HeatmapCard.halfGap)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityHint(hint ?? "")
        .accessibilityAddTraits(style.isTappable ? [.isButton] : [])
        .accessibilityAddTraits(style.isSelected ? .isSelected : [])
        .accessibilityShowsLargeContentViewer {
            Text(cell.isEnabled ? "\(cell.commonCount) of \(cell.total)" : "–")
        }
    }

    private func pill(_ word: String, fill: Color, text: Color, stroke: Color) -> some View {
        Text(word)
            .textStyle(.badge)
            .foregroundStyle(text)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(fill))
            .overlay(Capsule().stroke(stroke, lineWidth: 1))
            .fixedSize()
            .offset(y: 8)
            .allowsHitTesting(false)
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
    @State var model: ProposalSession
    var mark = false
    var body: some View {
        HeatmapCard(title: mark ? nil : "Brunch overlap",
                    content: model.proposal == nil ? .noProposal : .weeks(model.weeks),
                    mode: mark ? .mark(mine: model.myHoldCellIDs, now: model.now()) : .select,
                    total: model.total,
                    visibleWeekID: model.visibleWeekID, selectedCellID: model.selectedCellID, lockedCellID: model.lockedCellID,
                    lastUpdated: model.lastUpdated, calendar: model.calendar,
                    onShowWeek: model.showWeek, onSelect: { id in
                        if mark, let cell = model.visibleWeek?.cells.first(where: { $0.id == id }) { Task { await model.toggle(cell) } } else { model.select(id) }
                    })
            .padding(20)
            .background(DesignTokens.Colors.background)
    }
}

#Preview("Heatmap, populated") { HeatmapPreview(model: ProposalSession(fixture: FixtureData.make(.populated))) }
#Preview("Heatmap, mark mode") { HeatmapPreview(model: ProposalSession(fixture: FixtureData.make(.lockedInvite)), mark: true) }
#Preview("Heatmap, locked") { HeatmapPreview(model: ProposalSession(fixture: FixtureData.make(.lockedPlan))) }
#Preview("Heatmap, zero overlap") { HeatmapPreview(model: ProposalSession(fixture: FixtureData.make(.zeroOverlap))) }
#Preview("Heatmap, single week") { HeatmapPreview(model: ProposalSession(fixture: FixtureData.make(.singleWeek))) }
#Preview("Heatmap, stale") { HeatmapPreview(model: ProposalSession(fixture: FixtureData.make(.stale))) }
#Preview("Heatmap, no proposal") { HeatmapPreview(model: ProposalSession(fixture: FixtureData.make(.noProposal))) }
#Preview("Heatmap, loading") {
    HeatmapCard(content: .loading).padding(20).background(DesignTokens.Colors.background)
}
