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

    var isFastmail: Bool { host == "imap.fastmail.com" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Connect your mail").font(.h2)
                field("Email address") {
                    TextField("", text: $email, prompt: Text("you@fastmail.com").foregroundStyle(T.faint))
                        .font(.system(size: 13, design: .monospaced))
                        .onChange(of: email) { host = AppModel.imapHost(for: email) }
                }
                if email.contains("@") {
                    if isFastmail {
                        HStack(spacing: 12) {
                            Text("F").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(hex: 0x6AB2EC))
                                .frame(width: 32, height: 32).background(RoundedRectangle(cornerRadius: 9).fill(Color(hex: 0x6AB2EC).opacity(0.15)))
                            VStack(alignment: .leading) {
                                Text("Fastmail detected").fontWeight(.semibold)
                                Text("Use an app password from Fastmail → Settings → Privacy & Security. It is kept in your Keychain.")
                                    .font(.meta12).foregroundStyle(T.faint)
                            }
                        }
                    } else {
                        field("IMAP server") { TextField("", text: $host).font(.system(size: 13, design: .monospaced)) }
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

            HStack {
                Button("Back", action: back).buttonStyle(GhostButton())
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Sign in") { Task { await signIn() } }
                    .buttonStyle(PrimaryButton()).keyboardShortcut(.defaultAction)
                    .disabled(busy || !email.contains("@") || password.isEmpty || host.isEmpty)
            }
            .padding(.top, 24)
        }
        .textFieldStyle(.plain)
        .frame(width: 620)
        .padding(.top, 64)
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

    func signIn() async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            try await model.add(email: email.trimmingCharacters(in: .whitespaces), host: host, password: password)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
