import SwiftUI

/// Screens 25 (Welcome) and 26 (Add account). Fastmail signs in with an app password (decided 24 Nov).
struct Onboarding: View {
    let model: AppModel
    @Local private var adding = false

    var body: some View {
        if adding { AddAccount(model: model, back: { adding = false }) } else { welcome }
    }

    var welcome: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("midway").font(.display)
            Text("Mail and calendars for your Mac.").foregroundStyle(T.muted).padding(.top, 8)
            Button { adding = true } label: { Text("Add an account").frame(maxWidth: .infinity) }
                .buttonStyle(PrimaryButton()).keyboardShortcut(.defaultAction).padding(.top, 32)
            Text("Tags stay on this Mac.\nWorks offline.\nAI runs only when you ask.")
                .font(.meta12).foregroundStyle(T.faint).lineSpacing(8).padding(.top, 24)
        }
        .frame(width: 360)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct AddAccount: View {
    let model: AppModel
    let back: () -> Void
    @Local private var email = ""
    @Local private var host = ""
    @Local private var password = ""
    @Local private var busy = false
    @Local private var error: String?
    @Local private var signing: Task<Void, Never>?

    var isFastmail: Bool { host == "imap.fastmail.com" }
    var isGmail: Bool { AppModel.isGmail(email) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Connect your mail").font(.h2)
                field("Email address") {
                    TextField("", text: $email, prompt: Text("you@fastmail.com").foregroundStyle(T.faint))
                        .font(T.font(13, mono: true))
                        .onChange(of: email) { host = AppModel.imapHost(for: email) }
                }
                if isGmail {
                    provider("G", 0xEE8F72, "Google account detected", "Sign in opens in your browser. midway never sees your password.")
                } else if email.contains("@") {
                    if isFastmail {
                        provider("F", 0x6AB2EC, "Fastmail detected", "Use an app password from Fastmail → Settings → Privacy & Security. It is kept in your Keychain.")
                    } else {
                        field("IMAP server") { TextField("", text: $host).font(T.font(13, mono: true)) }
                    }
                    field("App password") { SecureField("", text: $password) }
                }
                if let error { Text(error).font(.meta12).foregroundStyle(T.gold) }
                VStack(alignment: .leading, spacing: 4) {
                    check("Incoming mail", "IMAP · port 993 · TLS")
                }
                .padding(.top, 12).overlay(alignment: .top) { Rectangle().fill(T.line).frame(height: 1) }
            }
            .padding(32)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(T.line))

            Text("Or choose a provider").font(.label11).foregroundStyle(T.faint)
                .frame(maxWidth: .infinity).padding(.top, 24)
            // Google Workspace addresses use custom domains, so Gmail is also offered by name.
            Button { start { try await model.addGoogle(loginHint: nil) } } label: {
                HStack(spacing: 12) {
                    badge("G", 0xEE8F72)
                    Text("Gmail or Google Workspace")
                    Spacer()
                }
                .padding(12).frame(width: 280)
                .background(RoundedRectangle(cornerRadius: 6).fill(T.surface))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(T.line))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(busy)
            .frame(maxWidth: .infinity).padding(.top, 12)

            HStack {
                Button("Back") { signing?.cancel(); back() }.buttonStyle(GhostButton())
                Spacer()
                if busy {
                    ProgressView().controlSize(.small)
                    if signing != nil {
                        Text("Waiting for your browser…").font(.meta12).foregroundStyle(T.muted)
                        Button("Cancel") { signing?.cancel() }.buttonStyle(GhostButton())
                    }
                }
                Button("Sign in") { signIn() }
                    .buttonStyle(PrimaryButton()).keyboardShortcut(.defaultAction)
                    .disabled(busy || !email.contains("@") || (!isGmail && (password.isEmpty || host.isEmpty)))
            }
            .padding(.top, 24)
        }
        .textFieldStyle(.plain)
        .frame(width: 620)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    func field<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.meta12).foregroundStyle(T.faint)
            content().padding(.horizontal, 12).frame(height: 40)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(T.line))
        }
    }

    func check(_ what: String, _ detail: String) -> some View {
        HStack(spacing: 12) {
            Text("✓").foregroundStyle(T.teal)
            Text(what)
            Spacer()
            Text(detail).font(.mono12).foregroundStyle(T.faint)
        }
    }

    func provider(_ letter: String, _ color: UInt32, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 12) {
            badge(letter, color)
            VStack(alignment: .leading) {
                Text(title).fontWeight(.semibold)
                Text(detail).font(.meta12).foregroundStyle(T.faint)
            }
        }
    }

    func badge(_ letter: String, _ color: UInt32) -> some View {
        Text(letter).font(T.font(13, .semibold)).foregroundStyle(Color(hex: color))
            .frame(width: 32, height: 32).background(RoundedRectangle(cornerRadius: 9).fill(Color(hex: color).opacity(0.15)))
    }

    func signIn() {
        let address = email.trimmingCharacters(in: .whitespaces)
        if isGmail {
            start { try await model.addGoogle(loginHint: address) }
        } else {
            busy = true
            error = nil
            Task {
                defer { busy = false }
                do { try await model.add(email: address, host: host, password: password) } catch { self.error = error.localizedDescription }
            }
        }
    }

    /// Google sign-in waits on the browser, so it can be cancelled.
    func start(_ work: @escaping @MainActor () async throws -> Void) {
        busy = true
        error = nil
        signing = Task {
            defer { busy = false; signing = nil }
            do { try await work() } catch is CancellationError {} catch { self.error = (error as? LocalizedError)?.errorDescription ?? String(describing: error) }
        }
    }
}
