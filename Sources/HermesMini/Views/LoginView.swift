import SwiftUI

struct LoginView: View {
    @StateObject private var store = AppStore.shared
    @State private var urlString = ""
    @State private var password = ""

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 46))
                .foregroundStyle(.tint)
            Text("Hermes Mini")
                .font(.title2.bold())
            Text("Připoj se ke svému Hermes serveru")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(spacing: 10) {
                TextField("Server URL", text: $urlString)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                SecureField("Heslo", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { connect() }
            }
            .frame(width: 340)

            Button("Připojit") { connect() }
                .buttonStyle(.borderedProminent)
                .disabled(urlString.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty)

            if let error = store.errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(width: 340)
            }
            Spacer()
        }
        .padding(24)
        .onAppear {
            if urlString.isEmpty {
                urlString = store.serverURLString
            }
        }
    }

    private func connect() {
        Task {
            await store.connect(urlString: urlString, password: password)
        }
    }
}
