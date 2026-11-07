import SwiftUI

struct LoginView: View {
    @Environment(SessionStore.self) private var session

    @AppStorage("jm.lastServer") private var server = ""
    @AppStorage("jm.lastUser") private var username = ""
    @State private var password = ""
    @State private var loading = false
    @State private var error: String? = nil
    @State private var signingUp = false
    @FocusState private var focus: Field?

    private enum Field { case server, user, password }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                Spacer(minLength: 50)

                Image("Logo")
                    .resizable()
                    .frame(width: 112, height: 112)
                    .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .shadow(color: .appAccent.opacity(0.35), radius: 24, y: 10)
                    .accessibilityHidden(true)

                VStack(spacing: 8) {
                    Text(AppInfo.name)
                        .font(.largeTitle.bold())
                    Text("Sign in to your Jellyfin server\nto get all your music.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 0) {
                    field("Server", systemImage: "server.rack") {
                        TextField("https://jellyfin.exemple.fr", text: $server)
                            .keyboardType(.URL)
                            .textContentType(.URL)
                            .focused($focus, equals: .server)
                            .submitLabel(.next)
                            .onSubmit { focus = .user }
                    }
                    Divider().padding(.leading, 52)
                    field("User", systemImage: "person.fill") {
                        TextField("Username", text: $username)
                            .textContentType(.username)
                            .focused($focus, equals: .user)
                            .submitLabel(.next)
                            .onSubmit { focus = .password }
                    }
                    Divider().padding(.leading, 52)
                    field("Password", systemImage: "lock.fill") {
                        SecureField("Password", text: $password)
                            .textContentType(.password)
                            .focused($focus, equals: .password)
                            .submitLabel(.go)
                            .onSubmit(signIn)
                    }
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                if let error {
                    Label(error, systemImage: "exclamationmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .transition(.opacity)
                }

                Button(action: signIn) {
                    ZStack {
                        if loading {
                            ProgressView().tint(.white)
                        } else {
                            Text("Sign In").font(.headline)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .foregroundStyle(.white)
                    .background(Color.appAccent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(PressableStyle(scale: 0.98))
                .disabled(loading || server.isEmpty || username.isEmpty)
                .opacity(server.isEmpty || username.isEmpty ? 0.5 : 1)

                Button { signingUp = true } label: {
                    Text(Community.pendingSignUp == nil ? "Create an Account" : "Your Request Is Waiting…")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .foregroundStyle(Color.appAccent)
                        .background(Color.appAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(PressableStyle(scale: 0.98))

                about

                Spacer(minLength: 20)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: 500)
            .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $signingUp) {
            let pending = Community.pendingSignUp
            SignUpView(server: pending?.server ?? server, resuming: pending).appEnvironment()
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .animation(.default, value: error)
    }

    /// What Sonalex needs, and where to find the rest.
    private var about: some View {
        VStack(spacing: 14) {
            Label("Works with any Jellyfin server", systemImage: "checkmark.seal.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.appAccent)
            Text("Sonalex plays the music of your own Jellyfin server: nothing is stored on ours. The free, optional Sonalex server adds Mix transitions and playback that moves between your devices.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 18) {
                Link(destination: AppInfo.repository) {
                    Label("Project on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Link(destination: AppInfo.jellyfin) {
                    Label("Discover Jellyfin", systemImage: "server.rack")
                }
            }
            .font(.footnote.weight(.semibold))
            Link("Privacy", destination: AppInfo.privacyPolicy)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }

    private func field<F: View>(_ label: String, systemImage: String, @ViewBuilder content: () -> F) -> some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 17))
                .foregroundStyle(Color.appAccent)
                .frame(width: 24)
            content()
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .accessibilityLabel(label)
    }

    private func signIn() {
        guard !loading else { return }
        focus = nil
        loading = true
        error = nil
        Task {
            defer { loading = false }
            do {
                let s = try await JellyfinClient.shared.login(server: server, username: username, password: password)
                server = s.server
                session.signIn(s)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
