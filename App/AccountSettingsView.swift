import SwiftUI
import RingonomiCore

struct AccountSettingsView: View {
    let address: String
    @ObservedObject var account: BackendAccountStore
    @State private var username = ""
    @State private var password = ""
    @State private var operation: Task<Void, Never>?

    private var supportsLogin: Bool {
        (try? RingonomiClient(address: address).baseURL.scheme?.lowercased()) == "https"
    }

    var body: some View {
        Section("サーバーアカウント") {
            if address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("接続先のサーバーURLを入力してください。")
            } else {
                if let user = account.user {
                    Text("ログイン中：\(user.name)")
                } else {
                    if account.hasSavedCredential {
                        Text("保存済みのログイン情報があります。状態を確認するか、もう一度ログインしてください。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    TextField("KonomiTVのユーザー名", text: $username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .textContentType(.username)
                    SecureField("パスワード", text: $password)
                        .textContentType(.password)
                    Button("ログイン") {
                        let submittedPassword = password
                        password = ""
                        operation?.cancel()
                        operation = Task { await account.login(address: address, username: username, password: submittedPassword) }
                    }.disabled(!supportsLogin || username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty || account.isBusy)
                }
                if account.hasSavedCredential {
                    Button("ログイン状態を確認") {
                        operation?.cancel()
                        operation = Task { await account.restore(address: address) }
                    }
                        .disabled(account.isBusy)
                    Button("ログアウト") { password = ""; account.logout(address: address) }
                        .disabled(account.isBusy)
                }
                if account.removalPending {
                    Button("ログイン情報の削除を再試行") { account.logout(address: address) }
                        .disabled(account.isBusy)
                }
                if !supportsLogin { Text("ログインにはhttps://で始まる接続先を使用してください。") }
                if account.isBusy {
                    ProgressView("アカウントを確認しています…")
                    Button("キャンセル") { operation?.cancel(); account.cancelCurrentOperation() }
                }
                if let error = account.error { Text(error).foregroundStyle(.red) }
                Text("KonomiTVのアカウントを使用します。アカウントなしで利用できる機能は、ログインせずに使えます。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onChange(of: address) { _, _ in
            operation?.cancel(); operation = nil; username = ""; password = ""
        }
        .onDisappear { password = ""; operation?.cancel(); operation = nil }
    }
}
