import FriendCalCore
import SwiftUI

struct MyCommitmentsView: View {
    var commitments: [Commitment]
    var state: MeView.CommitmentsLoadState = .loaded
    @Environment(\.calendar) private var calendar
    @State private var now = Date()

    var body: some View {
        Group {
            switch state {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let err):
                InlineError(error: err)
                    .padding()
            case .loaded:
                if commitments.isEmpty {
                    VStack(spacing: 8) {
                        Text("Nothing yet").textStyle(.title).foregroundStyle(DesignTokens.Colors.text)
                        Text("When you hold a time or lock a plan, it shows here.").textStyle(.body).foregroundStyle(DesignTokens.Colors.textMuted)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    timeline
                }
            }
        }
        .background(DesignTokens.Colors.background.ignoresSafeArea())
        .navigationTitle("My commitments")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .principal) { Text("My commitments").textStyle(.title) } }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { now = $0 }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in now = Date() }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in now = Date() }
    }

    private var timeline: some View {
        let days = Commitment.grouped(Commitment.live(commitments, from: now, now: now), calendar: calendar)
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Read-only — holds expire, Busy stays until the plan ends.").textStyle(.caption).foregroundStyle(DesignTokens.Colors.textMuted)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                ForEach(days) { day in
                    Text(dayHeader(day.date)).textStyle(.mono).foregroundStyle(DesignTokens.Colors.textMuted)
                        .padding(.horizontal, 16).padding(.top, 12)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(day.commitments) { c in
                        CommitmentRow(commitment: c)
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("\(c.kind.label), \(c.planTitle ?? "a plan"), \(DateText.timeRange(c.range, calendar: calendar, locale: .current))")
                    }
                }
            }
        }
    }
    private func dayHeader(_ d: Date) -> String {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none
        return f.string(from: d).uppercased()
    }
}

private struct CommitmentRow: View {
    let commitment: Commitment
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // decorative rail
            Rectangle().fill(DesignTokens.Colors.border).frame(width: 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(commitment.kind.label).textStyle(.label).foregroundStyle(DesignTokens.Colors.text)
                    if let title = commitment.planTitle {
                        Text(title).textStyle(.body).foregroundStyle(DesignTokens.Colors.text)
                    } else if commitment.sourceProposalID != nil {
                        Text("A plan").textStyle(.body).foregroundStyle(DesignTokens.Colors.textMuted)
                    }
                }
                Text(DateText.timeRange(commitment.range, calendar: .current, locale: .current)).textStyle(.caption).foregroundStyle(DesignTokens.Colors.textMuted)
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(DesignTokens.Colors.surface)
        .accessibilityIdentifier("commitment.row")
    }
}
