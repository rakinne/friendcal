import SwiftUI
import FriendCalCore

/// "Set your status" (variant D, Status Studio): pick a scene from the gallery, write an away
/// message, choose how long, and watch your own row wear it before you share. The scene is the
/// status: there is no separate "background" step. Opens from the header pill, your row, a sticker in
/// the tray and the Moments nudge.
struct StatusStudioSheet: View {
    let session: GroupsSession
    var initialKind: StatusKind?
    var onShared: (FriendStatus) -> Void = { _ in }
    var onCleared: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var kind: StatusKind
    @State private var message: String
    @State private var duration: StatusDuration = .twoHours

    init(session: GroupsSession, initialKind: StatusKind? = nil,
         onShared: @escaping (FriendStatus) -> Void = { _ in }, onCleared: @escaping () -> Void = {}) {
        self.session = session
        self.initialKind = initialKind
        self.onShared = onShared
        self.onCleared = onCleared
        let current = session.myPresence.status
        let start = initialKind ?? current?.kind ?? .work
        _kind = State(initialValue: start)
        _message = State(initialValue: current?.kind == start ? current?.message ?? "" : "")
    }

    private var draft: FriendStatus {
        FriendStatus(kind: kind, message: message, since: session.now, until: duration.end(from: session.now, calendar: session.calendar))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                header
                preview
                messageField
                gallery
                durations
                actions
            }
            .padding(.horizontal, 20)
            .padding(.top, DesignTokens.Spacing.md)
            .padding(.bottom, DesignTokens.Spacing.lg)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
        .background(DesignTokens.Colors.background.ignoresSafeArea())
        .sensoryFeedback(.selection, trigger: kind)
        .sensoryFeedback(.selection, trigger: duration)
        .accessibilityIdentifier("studio")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Set your status").textStyle(.display).foregroundStyle(DesignTokens.Colors.text)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button("Cancel") { dismiss() }
                .textStyle(.title)
                .foregroundStyle(DesignTokens.Colors.accentHover)
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityIdentifier("studio.cancel")
        }
    }

    /// Your own row, live: the same view the list draws, so what you see is what friends get.
    private var preview: some View {
        let presence = Presence.status(draft)
        return GroupRow(buddy: session.you, presence: presence,
                        text: presence.rowText(name: session.you.name, isYou: true, now: session.now, calendar: session.calendar), isYou: true)
            .accessibilityIdentifier("studio.preview")
    }

    private var messageField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Away message").textStyle(.label).foregroundStyle(DesignTokens.Colors.textMuted)
                Spacer()
                Text("\(message.count)/\(FriendStatus.maxMessageLength)").textStyle(.mono).foregroundStyle(DesignTokens.Colors.textMuted)
                    .accessibilityHidden(true)
            }
            TextField(kind.messageExample, text: $message)
                .textStyle(.body)
                .italic()
                .submitLabel(.done)
                .padding(.horizontal, 14)
                .frame(minHeight: 48)
                .background(RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous).fill(DesignTokens.Colors.surface))
                .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous).stroke(DesignTokens.Colors.border, lineWidth: 1))
                .onChange(of: message) { _, new in
                    if new.count > FriendStatus.maxMessageLength { message = String(new.prefix(FriendStatus.maxMessageLength)) }
                }
                .accessibilityIdentifier("studio.message")
        }
    }

    private var gallery: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Scene").textStyle(.label).foregroundStyle(DesignTokens.Colors.textMuted)
            ScrollView(.horizontal) {
                LazyHStack(spacing: 10) {
                    ForEach(StatusKind.allCases) { k in card(k) }
                }
                .scrollTargetLayout()
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned)
            .scrollClipDisabled()
        }
    }

    private func card(_ k: StatusKind) -> some View {
        let selected = k == kind
        return Button { kind = k } label: {
            ZStack(alignment: .bottom) {
                SceneArt(style: .status(k), anchor: 0.5, animates: selected)
                HStack(spacing: 5) {
                    Image(systemName: k.symbolName).font(.system(size: 12, weight: .bold)).accessibilityHidden(true)
                    Text(k.word).textStyle(.label)
                }
                .foregroundStyle(DesignTokens.Colors.text)
                .padding(.horizontal, 10)
                .frame(minHeight: 30)
                .background(Capsule().fill(DesignTokens.Colors.surface))
                .padding(.bottom, 8)
            }
            .frame(width: 112, height: 140)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous)
                .stroke(selected ? DesignTokens.Colors.primary : DesignTokens.Colors.border, lineWidth: selected ? 3 : 1))
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 22))
                        .foregroundStyle(DesignTokens.Colors.onPrimary, DesignTokens.Colors.primary)
                        .padding(8).transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.18), value: selected)
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(k.word)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("studio.kind.\(k.word)")
    }

    private var durations: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("For").textStyle(.label).foregroundStyle(DesignTokens.Colors.textMuted)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(StatusDuration.allCases, id: \.self) { d in chip(d) }
            }
        }
    }

    private func chip(_ d: StatusDuration) -> some View {
        let selected = d == duration
        let label = d.label(from: session.now, calendar: session.calendar)
        return Button { duration = d } label: {
            Text(label).textStyle(.label).lineLimit(1).minimumScaleFactor(0.8)
                .foregroundStyle(selected ? DesignTokens.Colors.onPrimary : DesignTokens.Colors.accentHover)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(Capsule().fill(selected ? DesignTokens.Colors.accentHover : DesignTokens.Colors.surface))
                .overlay(Capsule().stroke(selected ? Color.clear : DesignTokens.Colors.accentHover, lineWidth: 1.5))
        }
        .buttonStyle(PressableStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("studio.duration.\(label)")
    }

    private var actions: some View {
        VStack(spacing: 4) {
            Button {
                let stored = session.setMyStatus(kind: kind, message: message, duration: duration)
                dismiss()
                onShared(stored)
            } label: {
                Text("Share status").textStyle(.button).foregroundStyle(DesignTokens.Colors.onPrimary)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(Capsule().fill(DesignTokens.Colors.primary))
            }
            .buttonStyle(PressableStyle())
            .accessibilityIdentifier("studio.share")
            if session.myPresence.status != nil {
                Button("Clear my status") {
                    session.clearMyStatus()
                    dismiss()
                    onCleared()
                }
                .textStyle(.title)
                .foregroundStyle(DesignTokens.Colors.accentHover)
                .frame(maxWidth: .infinity, minHeight: 44)
                .accessibilityIdentifier("studio.clear")
            }
        }
    }
}
