import SwiftUI
import Observation
import FriendCalCore

/// The lock sheet's picker state (issue #5 D14, D22, design 5.3A): segments 1 h / 1.5 h / 2 h / 3 h,
/// those longer than the common span disabled, an "All · 1 h 20" segment when the span is not
/// itself one of the four, default 2 h when enabled else the longest enabled duration. When a
/// snapshot shrinks the span while the sheet is open, `update(span:)` re-evaluates: a now-overlong
/// selection falls back with the note "Overlap changed: now up to 1 h 20".
@Observable
final class LockSheetModel {
    struct Option: Identifiable, Equatable {
        let id: String
        let label: String
        /// nil = the whole span ("All").
        let duration: TimeInterval?
        let isEnabled: Bool
    }

    private(set) var span: DateRange
    private(set) var options: [Option] = []
    var selectedID: String = ""
    private(set) var note: String?

    init(span: DateRange) {
        self.span = span
        options = Self.options(for: span)
        selectedID = Self.defaultSelection(options)
    }

    var spanLength: TimeInterval { span.upperBound.timeIntervalSince(span.lowerBound) }
    var selected: Option? { options.first { $0.id == selectedID } }
    /// The window the selection locks: [span.lower, min(span.lower + duration, span.upper)).
    var window: DateRange? {
        guard let selected, selected.isEnabled else { return nil }
        let upper = selected.duration.map { min(span.lowerBound.addingTimeInterval($0), span.upperBound) } ?? span.upperBound
        return DateRange(lower: span.lowerBound, upper: upper)
    }
    /// Under 60 minutes there is nothing to lock (design 5.3A).
    var isTooShort: Bool { spanLength < HeatmapBuilder.minimumCommonDuration }

    func update(span newSpan: DateRange) {
        guard newSpan != span else { return }
        let shrank = newSpan.upperBound.timeIntervalSince(newSpan.lowerBound) < spanLength
        span = newSpan
        options = Self.options(for: newSpan)
        if let current = options.first(where: { $0.id == selectedID }), current.isEnabled {
            note = nil
        } else {
            selectedID = Self.defaultSelection(options)
            note = shrank ? "Overlap changed: now up to \(DateText.duration(spanLength))" : nil
        }
    }

    static func options(for span: DateRange) -> [Option] {
        let length = span.upperBound.timeIntervalSince(span.lowerBound)
        var out = ProposalService.durations.map { d in
            Option(id: "\(Int(d))", label: DateText.duration(d), duration: d, isEnabled: d <= length + 1)
        }
        if !ProposalService.durations.contains(where: { abs($0 - length) < 1 }) {
            out.append(Option(id: "all", label: "All · \(DateText.duration(length))", duration: nil, isEnabled: length >= HeatmapBuilder.minimumCommonDuration))
        }
        return out
    }

    static func defaultSelection(_ options: [Option]) -> String {
        if let two = options.first(where: { $0.duration == ProposalService.defaultDuration && $0.isEnabled }) { return two.id }
        if let longest = options.filter({ $0.isEnabled && $0.duration != nil }).last { return longest.id }
        return options.first { $0.isEnabled }?.id ?? options.first?.id ?? ""
    }
}

/// The duration segments (design 5.3A, D22): a segmented control whose overlong segments are truly
/// disabled (SwiftUI's segmented Picker ignores `.disabled` on its items); the selected segment is
/// `accentHover` with `onPrimary` text.
private struct DurationSegments: View {
    let options: [LockSheetModel.Option]
    @Binding var selectedID: String

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options) { option in
                let selected = option.id == selectedID
                Button { selectedID = option.id } label: {
                    Text(option.label).textStyle(.label).lineLimit(1).minimumScaleFactor(0.7)
                        .foregroundStyle(selected ? DesignTokens.Colors.onPrimary : DesignTokens.Colors.text)
                        .padding(.horizontal, 4)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(RoundedRectangle(cornerRadius: DesignTokens.Radius.sm).fill(selected ? DesignTokens.Colors.accentHover : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!option.isEnabled)
                .opacity(option.isEnabled ? 1 : 0.4)
                .accessibilityLabel(option.label)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("lock.option.\(option.id)")
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: DesignTokens.Radius.md).fill(DesignTokens.Colors.surface2))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.md).stroke(DesignTokens.Colors.border, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Duration")
    }
}

/// Outcome-first lock confirmation (design 5.3A): "Lock Sat, Nov 14?", the duration segments, the
/// resulting window in mono, who is in, and the coral "Lock it in". A refusal stays inline with
/// Retry and Details; the sheet closes on success (the invite fires the acknowledgment, 3.4A).
struct LockSheet: View {
    var session: ProposalSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var model: LockSheetModel
    @State private var isLocking = false
    @State private var error: UserFacingError?

    init(session: ProposalSession) {
        self.session = session
        _model = State(initialValue: LockSheetModel(span: session.lockSpan ?? DateRange(lower: session.now(), upper: session.now())))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Lock \(DateText.day(model.span.lowerBound, calendar: session.calendar, locale: .current))?")
                        .textStyle(.display).foregroundStyle(DesignTokens.Colors.text)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("lock.title")

                    DurationSegments(options: model.options, selectedID: $model.selectedID)

                    if let window = model.window {
                        Text(DateText.timeRange(window, calendar: session.calendar, locale: .current))
                            .textStyle(.mono).foregroundStyle(DesignTokens.Colors.text)
                            .accessibilityIdentifier("lock.window")
                    }
                    if let note = model.note {
                        Text(note).textStyle(.caption).foregroundStyle(DesignTokens.Colors.textMuted)
                            .accessibilityIdentifier("lock.note")
                    }

                    attendees

                    if model.isTooShort {
                        Text("Everyone's free for less than an hour here.")
                            .textStyle(.caption).foregroundStyle(DesignTokens.Colors.textMuted)
                            .accessibilityIdentifier("lock.tooShort")
                    }

                    Button { lock() } label: { PrimaryPill(title: "Lock it in", isBusy: isLocking) }
                        .buttonStyle(.plain)
                        .disabled(isLocking || model.isTooShort || model.window == nil)
                        .opacity(model.isTooShort || model.window == nil ? 0.5 : 1)
                        .accessibilityIdentifier("lock.confirm")

                    if let error {
                        InlineError(error: error, retryTitle: "Retry") { lock() }
                    }
                }
                .padding(20)
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(DesignTokens.Colors.background.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundStyle(DesignTokens.Colors.accentHover)
                        .accessibilityIdentifier("lock.cancel")
                }
            }
        }
        .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.medium, .large])
        .onChange(of: session.lockSpan) { _, span in if let span { model.update(span: span) } }
        .onChange(of: session.lockState?.isLocked ?? false) { _, locked in if locked { dismiss() } }
        .accessibilityIdentifier("lockSheet")
    }

    /// Who the lock settles: the best cell's free members (design 5.3A).
    @ViewBuilder
    private var attendees: some View {
        if let state = session.lockState, let best = state.bestCell, let p = session.proposal {
            let free = session.members.filter { best.roster[$0.id] == .free }
            HStack(spacing: 10) {
                HStack(spacing: -6) {
                    ForEach(free.prefix(5)) { m in
                        FriendAvatar(member: m, size: 28, style: .badge)
                            .overlay(SwiftUI.Circle().stroke(DesignTokens.Colors.background, lineWidth: 1.5))
                    }
                    if free.count > 5 {
                        Text("+\(free.count - 5)").textStyle(.badge).foregroundStyle(DesignTokens.Colors.text)
                            .frame(width: 28, height: 28)
                            .background(SwiftUI.Circle().fill(DesignTokens.Colors.surface))
                            .overlay(SwiftUI.Circle().stroke(DesignTokens.Colors.border, lineWidth: 1))
                    }
                }
                Text("\(best.commonCount) of \(p.headcount) are in").textStyle(.body).foregroundStyle(DesignTokens.Colors.text)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("lock.attendees")
        }
    }

    private func lock() {
        guard let option = model.selected else { return }
        error = nil
        isLocking = true
        Task {
            defer { isLocking = false }
            do {
                try await session.lock(duration: option.duration)
                dismiss()
            } catch let failure as UserFacingError {
                error = failure
            } catch {
                self.error = UserFacingError.map(error, action: .lock, creatorName: session.creatorName)
            }
        }
    }
}

#Preview("Lock sheet") {
    let session = ProposalSession(fixture: FixtureData.make(.lockedInviteCreator))
    return LockSheet(session: session)
}
