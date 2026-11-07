import SwiftUI

/// "Create an account": asks the owner of a Sonalex server to join it. The account is made at
/// once but stays off until the owner accepts; then this screen signs in by itself.
struct SignUpView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss

    enum Step { case server, details, waiting, refused }

    @State private var step: Step = .server
    @State var server: String
    @State private var info: Community.ServerInfo?
    @State private var name = ""
    @State private var password = ""
    @State private var confirm = ""
    @State private var service: MusicService = .none
    @State private var deezer = ""
    @State private var signUp: Community.SignUp?
    @State private var working = false
    @State private var error: String?
    @FocusState private var focused: Bool

    init(server: String, resuming: Community.SignUp? = nil) {
        _server = State(initialValue: server)
        _signUp = State(initialValue: resuming)
        _step = State(initialValue: resuming == nil ? .server : .waiting)
        _name = State(initialValue: resuming?.name ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                switch step {
                case .server: serverStep
                case .details: detailsStep
                case .waiting: waitingStep
                case .refused: refusedStep
                }
                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Create an Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .disabled(working)
            .animation(.default, value: step)
        }
    }

    // MARK: Steps

    private var serverStep: some View {
        Section {
            TextField("https://jellyfin.example.com", text: $server)
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focused)
                .onSubmit(checkServer)
            Button(action: checkServer) {
                HStack {
                    Text("Continue")
                    if working { Spacer(); ProgressView() }
                }
            }
            .disabled(server.trimmingCharacters(in: .whitespaces).isEmpty)
        } header: {
            Text("Server")
        } footer: {
            Text("The address of the Jellyfin server you want to join. Its owner must run the Sonalex server, and will be asked to accept you.")
        }
    }

    @ViewBuilder private var detailsStep: some View {
        Section {
            TextField("First name", text: $name)
                .textContentType(.givenName)
            SecureField("Password (6 characters or more)", text: $password)
                .textContentType(.newPassword)
            SecureField("Confirm password", text: $confirm)
                .textContentType(.newPassword)
        } header: {
            Text(info?.serverName.map { "Join \($0)" } ?? "Your account")
        } footer: {
            Text("Your first name is your username, and what friends on this server see.")
        }
        Section {
            Picker("Music service", selection: $service) {
                ForEach(services) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            if service == .deezer {
                TextField("Deezer profile link", text: $deezer)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        } header: {
            Text("Your music")
        } footer: {
            Text(serviceFooter)
        }
        Section {
            Button(action: submit) {
                HStack {
                    Text("Send Request")
                    if working { Spacer(); ProgressView() }
                }
            }
            .disabled(!canSubmit)
        }
    }

    private var waitingStep: some View {
        Section {
            VStack(spacing: 16) {
                ProgressView().controlSize(.large)
                Text("Request sent")
                    .font(.title3.weight(.semibold))
                Text("\(info?.owner ?? "The server's owner") has been told. You'll be signed in as soon as you're accepted — keep the app open, or come back later.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .task(id: signUp?.id) { await waitForAnswer() }
            if password.isEmpty {
                SecureField("Your password (to sign in once accepted)", text: $password)
                    .textContentType(.password)
            }
        }
    }

    private var refusedStep: some View {
        Section {
            Label("Your request wasn't accepted.", systemImage: "xmark.circle")
            Button("Start Over") {
                Community.pendingSignUp = nil
                signUp = nil
                step = .server
            }
        }
    }

    // MARK: Logic

    private var services: [MusicService] {
        guard let providers = info?.providers else { return [.none] }
        return MusicService.allCases.filter {
            switch $0 {
            case .spotify: providers.spotify
            case .deezer: providers.deezer
            case .none: true
            }
        }
    }

    private var serviceFooter: String {
        switch service {
        case .spotify: "Once you're accepted, connect Spotify from your profile: your liked songs and playlists come into your library, and stay in sync."
        case .deezer: "Your Deezer favorites and playlists come into your library. Your profile must be public: Deezer → Settings → Privacy. Copy its link from your profile page (Share)."
        case .none: "Your library fills up with what you add yourself. You can connect a service later."
        }
    }

    private var canSubmit: Bool {
        name.trimmingCharacters(in: .whitespaces).count >= 2 && password.count >= 6 && password == confirm
            && (service != .deezer || !deezer.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    private func checkServer() {
        let address = JellyfinClient.normalize(server: server)
        working = true
        error = nil
        Task {
            defer { working = false }
            do {
                info = try await Community.serverInfo(address)
                server = address
                step = .details
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func submit() {
        guard canSubmit else {
            if password != confirm { error = "The passwords don't match." }
            return
        }
        working = true
        error = nil
        Task {
            defer { working = false }
            do {
                let request = try await Community.requestAccount(
                    server: server, name: name.trimmingCharacters(in: .whitespaces), password: password, service: service,
                    deezer: service == .deezer ? deezer.trimmingCharacters(in: .whitespaces) : nil)
                Community.pendingSignUp = request
                signUp = request
                Notifier.requestPermission()
                step = .waiting
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// Asks the server every few seconds; signs in once accepted.
    private func waitForAnswer() async {
        guard let request = signUp else { return }
        while !Task.isCancelled {
            if let status = try? await Community.status(of: request) {
                if status.status == "approved" {
                    Community.pendingSignUp = nil
                    Notifier.post(title: "Welcome to the server!", body: "Your account is ready, \(status.name).", id: "approved-\(request.id)")
                    await signIn(request)
                    return
                }
                if status.status == "denied" {
                    Community.pendingSignUp = nil
                    step = .refused
                    return
                }
            }
            try? await Task.sleep(for: .seconds(4))
        }
    }

    private func signIn(_ request: Community.SignUp) async {
        guard !password.isEmpty else {
            error = "You're accepted! Type your password above to sign in."
            while password.isEmpty, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(500)) }
            return await signIn(request)
        }
        do {
            let s = try await JellyfinClient.shared.login(server: request.server, username: request.name, password: password)
            UserDefaults.standard.set(s.server, forKey: "jm.lastServer")
            UserDefaults.standard.set(request.name, forKey: "jm.lastUser")
            session.signIn(s)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
