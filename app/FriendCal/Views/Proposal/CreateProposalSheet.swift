import SwiftUI
import FriendCalCore

/// "New plan" (issue #5 D4, D13, design 3.2A, 3.3A, 5.4A): one card of labeled inputs (title,
/// date-only From / To snapped to day bounds, the inclusive headcount stepper), Create disabled until
/// valid, inline errors per field, then the success step with the link, a real ShareLink and Done.
/// Edit mode (creator, from the invite's menu): title and headcount while requesting; the dates are
/// frozen once any friend has marked a time.
struct CreateProposalSheet: View {
    enum Mode {
        case create(ProposalStore, calendar: Calendar, now: () -> Date)
        case edit(ProposalSession)
    }

    let mode: Mode
    /// Create only: called with the new proposal when Done is tapped on the success step (3.2A).
    var onCreated: (Proposal) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ProposalDraft
    @State private var isSaving = false
    @State private var error: UserFacingError?
    @State private var created: Proposal?
    @State private var copied = false
    @FocusState private var titleFocused: Bool

    init(mode: Mode, onCreated: @escaping (Proposal) -> Void) {
        self.mode = mode
        self.onCreated = onCreated
        switch mode {
        case .create(_, let calendar, let now): _draft = State(initialValue: ProposalDraft.default(now: now(), calendar: calendar))
        case .edit(let session): _draft = State(initialValue: session.proposal.map(ProposalDraft.init(editing:)) ?? ProposalDraft.default(now: session.now(), calendar: session.calendar))
        }
    }

    private var calendar: Calendar {
        switch mode {
        case .create(_, let calendar, _): return calendar
        case .edit(let session): return session.calendar
        }
    }

    private var isEdit: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var datesFrozen: Bool {
        if case .edit(let session) = mode { return session.hasAnyHold }
        return false
    }

    private var minimumPeople: Int {
        if case .edit(let session) = mode { return max(ProposalDraft.minimumExpected, session.proposal?.joinedCount ?? 0) }
        return ProposalDraft.minimumExpected
    }

    private var errors: [ProposalDraft.ValidationError] { draft.errors(calendar: calendar) }
    private var isValid: Bool { errors.isEmpty && draft.expectedCount >= minimumPeople }

    var body: some View {
        NavigationStack {
            ScrollView {
                if let created {
                    success(created)
                } else {
                    form
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(DesignTokens.Colors.background.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(created == nil ? "Cancel" : "Done") { finish() }
                        .foregroundStyle(DesignTokens.Colors.accentHover)
                        .accessibilityIdentifier(created == nil ? "create.cancel" : "create.done")
                }
            }
        }
        .accessibilityIdentifier("createSheet")
    }

    // MARK: Form

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isEdit ? "Edit plan" : "New plan").textStyle(.display).foregroundStyle(DesignTokens.Colors.text)
                .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: 14) {
                field("Plan title") {
                    TextField("Brunch", text: $draft.title)
                        .textStyle(.body).foregroundStyle(DesignTokens.Colors.text)
                        .focused($titleFocused)
                        .submitLabel(.next)
                        .padding(.horizontal, 12).frame(minHeight: 44)
                        .background(RoundedRectangle(cornerRadius: DesignTokens.Radius.md).stroke(DesignTokens.Colors.border, lineWidth: 1))
                        .accessibilityIdentifier("create.title")
                }
                field("From") {
                    DatePicker("From", selection: $draft.from, displayedComponents: .date)
                        .labelsHidden()
                        .disabled(datesFrozen)
                        .accessibilityIdentifier("create.from")
                }
                field("To") {
                    DatePicker("To", selection: $draft.to, displayedComponents: .date)
                        .labelsHidden()
                        .disabled(datesFrozen)
                        .accessibilityIdentifier("create.to")
                    if datesFrozen {
                        Text("Can't change the dates once friends have marked times")
                            .textStyle(.caption).foregroundStyle(DesignTokens.Colors.textMuted)
                            .accessibilityIdentifier("create.datesFrozen")
                    }
                    if errors.contains(.endBeforeStart) {
                        fieldError("The end has to come after the start.", id: "create.error.window")
                    } else if let tooLong = errors.first(where: { if case .tooLong = $0 { return true }; return false }), case .tooLong(let days) = tooLong {
                        fieldError("That's \(days) days. Keep it to \(ProposalDraft.maxDays) or fewer.", id: "create.error.window")
                    }
                }
                field("How many people, counting you?") {
                    HStack {
                        Text("\(draft.expectedCount)").textStyle(.title).foregroundStyle(DesignTokens.Colors.text)
                            .accessibilityIdentifier("create.expectedValue")
                        Spacer()
                        Stepper("People", value: $draft.expectedCount, in: minimumPeople...max(50, minimumPeople))
                            .labelsHidden()
                            .accessibilityValue("\(draft.expectedCount)")
                    }
                    Text("Sets when the plan can lock.").textStyle(.caption).foregroundStyle(DesignTokens.Colors.textMuted)
                    if errors.contains(.tooFewPeople) {
                        fieldError("Invite at least one friend.", id: "create.error.people")
                    }
                }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg).fill(DesignTokens.Colors.surface))
            .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg).stroke(DesignTokens.Colors.border, lineWidth: 1))

            Button { submit() } label: { PrimaryPill(title: isEdit ? "Save" : "Create", isBusy: isSaving) }
                .buttonStyle(.plain)
                .disabled(!isValid || isSaving)
                .opacity(isValid ? 1 : 0.5)
                .accessibilityIdentifier("create.submit")

            if let error {
                InlineError(error: error, retryTitle: "Retry") { submit() }
            }
        }
        .padding(20)
        .disabled(isSaving && error == nil)
        .onSubmit { titleFocused = false }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).textStyle(.label).foregroundStyle(DesignTokens.Colors.text)
            content()
        }
    }

    private func fieldError(_ text: String, id: String) -> some View {
        Text(text).textStyle(.caption).foregroundStyle(DesignTokens.Colors.error).accessibilityIdentifier(id)
    }

    // MARK: Success (design 3.2A)

    private func success(_ p: Proposal) -> some View {
        let link = DeepLink.proposal(p.id).url
        return VStack(alignment: .leading, spacing: 16) {
            Text("\(p.title) is live").textStyle(.display).foregroundStyle(DesignTokens.Colors.text)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("create.success")
            Text(DateText.dayRange(p.window, calendar: calendar, locale: .current))
                .textStyle(.body).foregroundStyle(DesignTokens.Colors.textMuted)
            HStack(spacing: 8) {
                Text(link.absoluteString).textStyle(.mono).foregroundStyle(DesignTokens.Colors.text)
                    .lineLimit(2).minimumScaleFactor(0.7)
                    .accessibilityIdentifier("create.link")
                Spacer(minLength: 4)
                Button {
                    UIPasteboard.general.string = link.absoluteString
                    copied = true
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc").foregroundStyle(DesignTokens.Colors.accentHover)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(copied ? "Copied" : "Copy link")
                .accessibilityIdentifier("create.copy")
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: DesignTokens.Radius.md).fill(DesignTokens.Colors.surface))
            .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.md).stroke(DesignTokens.Colors.border, lineWidth: 1))

            ShareLink(item: ShareText.invite(title: p.title, url: link)) { PrimaryPill(title: "Share invite") }
                .accessibilityIdentifier("create.share")

            Button { finish() } label: {
                Text("Done").textStyle(.title).foregroundStyle(DesignTokens.Colors.accentHover)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .accessibilityIdentifier("create.doneButton")
        }
        .padding(20)
    }

    // MARK: Actions

    private func submit() {
        error = nil
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                switch mode {
                case .create(let store, let calendar, _):
                    let plan = try draft.validate(calendar: calendar)
                    created = try await store.create(plan)
                case .edit(let session):
                    try await session.edit(draft)
                    dismiss()
                }
            } catch let failure as UserFacingError {
                error = failure
            } catch {
                self.error = UserFacingError.map(error, action: isEdit ? .edit : .create)
            }
        }
    }

    private func finish() {
        dismiss()
        if let created { onCreated(created) }
    }
}

#Preview("Create") {
    CreateProposalSheet(mode: .create(InMemoryProposalStore(currentUserID: UUID()), calendar: .current, now: { .now }), onCreated: { _ in })
}

#Preview("Edit") {
    CreateProposalSheet(mode: .edit(ProposalSession(fixture: FixtureData.make(.lockedInviteCreator))), onCreated: { _ in })
}
