import SwiftUI

struct LoginView: View {
    @Environment(SessionStore.self) private var session

    @AppStorage("jm.lastServer") private var server = ""
    @AppStorage("jm.lastUser") private var username = ""
    @State private var password = ""
    @State private var loading = false
    @State private var error: String? = nil
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
                    Text("Connecte-toi à ton serveur Jellyfin\npour retrouver toute ta musique.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 0) {
                    field("Serveur", systemImage: "server.rack") {
                        TextField("https://jellyfin.exemple.fr", text: $server)
                            .keyboardType(.URL)
                            .textContentType(.URL)
                            .focused($focus, equals: .server)
                            .submitLabel(.next)
                            .onSubmit { focus = .user }
                    }
                    Divider().padding(.leading, 52)
                    field("Utilisateur", systemImage: "person.fill") {
                        TextField("Nom d’utilisateur", text: $username)
                            .textContentType(.username)
                            .focused($focus, equals: .user)
                            .submitLabel(.next)
                            .onSubmit { focus = .password }
                    }
                    Divider().padding(.leading, 52)
                    field("Mot de passe", systemImage: "lock.fill") {
                        SecureField("Mot de passe", text: $password)
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
                            Text("Se connecter").font(.headline)
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

                about

                Spacer(minLength: 20)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: 500)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .animation(.default, value: error)
    }

    /// What Sonalex needs, and where to find the rest.
    private var about: some View {
        VStack(spacing: 14) {
            Label("Compatible avec tout serveur Jellyfin", systemImage: "checkmark.seal.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.appAccent)
            Text("Sonalex lit la musique de ton propre serveur Jellyfin : rien n’est stocké chez nous. Le serveur Sonalex, optionnel et gratuit, ajoute les transitions Mix et la lecture d’un appareil à l’autre.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 18) {
                Link(destination: AppInfo.repository) {
                    Label("Projet sur GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Link(destination: AppInfo.jellyfin) {
                    Label("Découvrir Jellyfin", systemImage: "server.rack")
                }
            }
            .font(.footnote.weight(.semibold))
            Link("Confidentialité", destination: AppInfo.privacyPolicy)
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
