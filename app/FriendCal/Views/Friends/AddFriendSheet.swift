import SwiftUI
import UIKit
import CoreImage.CIFilterBuiltins
import FriendCalCore

/// The Add a friend sheet (spec 4.1): your one reusable link, as text and as a QR code. `.medium` and
/// `.large`, flat layout, the coral Share button the only coral control. At accessibility sizes it
/// opens `.large` and scrolls.
///
///     Add a friend                                         Done
///     Share your link. Anyone who opens it can connect with you.
///     friendcal.app/f/<token>                              [Copy]
///     Anyone with it can connect.                    Reset link
///     [          Share link          ]
///     Show QR code  >
struct AddFriendSheet: View {
    @State var session: FriendLinkSession
    var onDone: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var detent: PresentationDetent = .medium
    @State private var showQR = false
    @State private var confirmReset = false
    @State private var copied = false
    @State private var copiedTask: Task<Void, Never>?
    @State private var toast = ToastCenter()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                    header
                    Text("Share your link. Anyone who opens it can connect with you.")
                        .textStyle(.body).foregroundStyle(DesignTokens.Colors.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    linkRow
                    resetRow
                    shareButton
                    qrRow
                }
                .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 24)
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(DesignTokens.Colors.surface.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showQR) {
                FriendQRView(session: session, onDone: onDone)
            }
            .toast(toast)
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .presentationBackground(DesignTokens.Colors.surface)
        .task {
            if typeSize.isAccessibilitySize { detent = .large }
            await session.load()
        }
        .onChange(of: showQR) { _, on in detent = on ? .large : (typeSize.isAccessibilitySize ? .large : .medium) }
        .onChange(of: session.resetCount) { _, _ in
            toast.show("New link ready")
        }
        .sensoryFeedback(.impact(weight: .light), trigger: copied) { _, new in new }
        .confirmationDialog("Reset your link?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset link", role: .destructive) { Task { await session.reset() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The old link stops working for anyone who hasn't joined yet. Friends already connected stay connected.")
        }
    }

    // MARK: Pieces

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Add a friend").textStyle(.display).foregroundStyle(DesignTokens.Colors.text)
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            Button(action: onDone) {
                Text("Done").textStyle(.title).foregroundStyle(DesignTokens.Colors.accentHover)
                    .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            }
            .accessibilityIdentifier("addFriend.done")
        }
    }

    @ViewBuilder
    private var linkRow: some View {
        switch session.phase {
        case .loading:
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                .fill(Color.skeleton).frame(height: 56)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Getting your link")
                .accessibilityIdentifier("addFriend.skeleton")
        case .failed(let error):
            InlineError(error: error, onRetry: { Task { await session.load() } })
        case .ready(let token):
            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
            layout {
                // Mono, selectable, no scheme and no name hint; wraps to as many lines as it needs and is never truncated.
                Text(FriendToken.display(token))
                    .textStyle(.mono).foregroundStyle(DesignTokens.Colors.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("addFriend.link")
                copyButton
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous).fill(DesignTokens.Colors.background))
            .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous).stroke(DesignTokens.Colors.border, lineWidth: 1))
            .opacity(session.isResetting ? 0.5 : 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Your friend link")
            .accessibilityValue(FriendToken.display(token))
            .accessibilityAction(named: "Copy") { copy() }
        }
    }

    private var copyButton: some View {
        Button(action: copy) {
            Text(copied ? "Copied" : "Copy").textStyle(.label)
                .foregroundStyle(DesignTokens.Colors.accentHover)
                .padding(.horizontal, 12).frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .disabled(!session.isUsable)
        .accessibilityHidden(true)
        .accessibilityIdentifier("addFriend.copy")
    }

    private var resetRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                Text("Anyone with it can connect.").textStyle(.caption).foregroundStyle(DesignTokens.Colors.textMuted)
                Spacer(minLength: 8)
                if session.isResetting {
                    ProgressView().accessibilityLabel("Resetting your link")
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityIdentifier("addFriend.resetting")
                } else {
                    Button { confirmReset = true } label: {
                        Text("Reset link").textStyle(.label).foregroundStyle(DesignTokens.Colors.accentHover)
                            .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                    }
                    .disabled(session.token == nil)
                    .accessibilityIdentifier("addFriend.reset")
                }
            }
            if let error = session.resetError {
                InlineError(error: error)
            }
        }
    }

    @ViewBuilder
    private var shareButton: some View {
        if let text = session.shareText, session.isUsable {
            ShareLink(item: text) { PrimaryPill(title: "Share link") }
                .accessibilityIdentifier("addFriend.share")
        } else {
            PrimaryPill(title: "Share link", isBusy: session.isResetting).opacity(0.45)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Share link")
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Not ready yet")
                .accessibilityIdentifier("addFriend.share")
                .allowsHitTesting(false)
        }
    }

    private var qrRow: some View {
        Button { showQR = true } label: {
            HStack {
                Image(systemName: "qrcode").accessibilityHidden(true)
                Text("Show QR code").textStyle(.title)
                Spacer()
                Image(systemName: "chevron.right").imageScale(.small).accessibilityHidden(true)
            }
            .foregroundStyle(session.isUsable ? DesignTokens.Colors.text : DesignTokens.Colors.textMuted)
            .frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!session.isUsable)
        .accessibilityIdentifier("addFriend.qr")
    }

    // MARK: Actions

    private func copy() {
        guard let url = session.shareURL else { return }
        UIPasteboard.general.string = url.absoluteString
        copied = true
        AccessibilityNotification.Announcement("Link copied").post()
        copiedTask?.cancel()
        copiedTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            copied = false
        }
    }
}

/// The QR (spec 4.2): a dark code on a white panel with a quiet zone, whatever the tokens say, so a
/// camera always reads it. Brightness goes up while it shows and comes back on back, on dismiss and
/// when the app leaves the foreground. Share shares the link, not an image. It mirrors the sheet's
/// loading and error states.
struct FriendQRView: View {
    let session: FriendLinkSession
    var onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var savedBrightness: CGFloat?

    var body: some View {
        ScrollView {
            VStack(spacing: DesignTokens.Spacing.md) {
                HStack {
                    Button { dismiss() } label: {
                        Label("Back", systemImage: "chevron.left").textStyle(.title).foregroundStyle(DesignTokens.Colors.accentHover)
                            .frame(minHeight: 44).contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("qr.back")
                    Spacer()
                    Button(action: onDone) {
                        Text("Done").textStyle(.title).foregroundStyle(DesignTokens.Colors.accentHover)
                            .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                    }
                }
                content
            }
            .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 24)
        }
        .background(DesignTokens.Colors.surface.ignoresSafeArea())
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { raiseBrightness() }
        .onDisappear { restoreBrightness() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { raiseBrightness() } else { restoreBrightness() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch session.phase {
        case .loading:
            RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous).fill(Color.skeleton)
                .frame(width: 280, height: 280)
                .accessibilityLabel("Getting your link")
        case .failed(let error):
            InlineError(error: error, onRetry: { Task { await session.load() } })
        case .ready(let token):
            if let image = QRCode.image(for: (session.shareURL ?? DeepLink.friend(token).shareURL).absoluteString) {
                Image(uiImage: image).interpolation(.none).resizable()
                    .frame(width: 240, height: 240)
                    .padding(20)
                    .background(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous).fill(Color.white))
                    .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous).stroke(DesignTokens.Colors.border, lineWidth: 1))
                    .accessibilityLabel("QR code for your friend link")
                    .accessibilityIdentifier("qr.code")
            }
            Text(FriendToken.display(token)).textStyle(.mono).foregroundStyle(DesignTokens.Colors.text)
                .textSelection(.enabled).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("qr.link")
            if let text = session.shareText, session.isUsable {
                ShareLink(item: text) { PrimaryPill(title: "Share link") }
            }
        }
    }

    private var screen: UIScreen? {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first
    }

    private func raiseBrightness() {
        guard let screen else { return }
        if savedBrightness == nil { savedBrightness = screen.brightness }
        screen.brightness = 1
    }

    private func restoreBrightness() {
        guard let screen, let saved = savedBrightness else { return }
        screen.brightness = saved
        savedBrightness = nil
    }
}

/// QR generation: CoreImage's generator, dark on white, with its own one-module quiet zone removed so
/// the white panel around it is the quiet zone.
enum QRCode {
    static func image(for text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let context = CIContext()
        guard let cg = context.createCGImage(output.transformed(by: CGAffineTransform(scaleX: 1, y: 1)), from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
