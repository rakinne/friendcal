import AuthenticationServices
import CryptoKit
import FriendCalCore
import SwiftUI

/// "Sign in with Apple" for the network store. The nonce is the replay guard: Apple gets its SHA-256
/// and signs that into the identity token; Supabase gets the raw value and checks the two match.
struct AppleSignInSection: View {
    @ObservedObject var auth: AuthGateModel
    @State private var rawNonce = ""
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        SignInWithAppleButton(.continue) { request in
            rawNonce = Self.makeNonce()
            request.requestedScopes = [.fullName]
            request.nonce = Self.sha256(rawNonce)
        } onCompletion: { result in
            switch result {
            case .success(let authorization):
                guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                      let tokenData = credential.identityToken, let token = String(data: tokenData, encoding: .utf8) else {
                    auth.fail("Apple didn't send a sign-in token. Try again.")
                    return
                }
                let name = credential.fullName.flatMap { PersonNameComponentsFormatter.localizedString(from: $0, style: .default) }
                let nonce = rawNonce
                Task { await auth.signInWithApple(idToken: token, nonce: nonce, displayName: name) }
            case .failure(let error):
                // Dismissing the sheet is not an error worth a message.
                if (error as? ASAuthorizationError)?.code != .canceled {
                    auth.fail("Sign in with Apple didn't finish. Try again.")
                }
            }
        }
        .signInWithAppleButtonStyle(.black)
        .frame(height: 48)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.md))
        .disabled(auth.state == .signingIn)
        .opacity(auth.state == .signingIn ? 0.5 : 1)
        .accessibilityIdentifier("auth.apple")
    }

    private static func makeNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        precondition(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
