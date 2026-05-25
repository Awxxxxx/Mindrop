import SwiftUI

struct WelcomeView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let presentationContext: PresentationContext
    @State private var sheet: AuthSheet?
    @State private var account = ""
    @State private var password = ""
    @State private var confirmPassword = ""

    init(presentationContext: PresentationContext = .launch) {
        self.presentationContext = presentationContext
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [.softMint.opacity(0.74), .cardSurface, .appCanvas],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            if presentationContext.showsBackButton {
                backButton
            }

            VStack(spacing: 0) {
                brandSection
                    .padding(.top, 132)

                Spacer()

                VStack(spacing: 20) {
                    HStack(spacing: 18) {
                        Button("登录") { sheet = .login }
                            .buttonStyle(AuthButtonStyle(kind: .primary))
                        Button("注册") { sheet = .register }
                            .buttonStyle(AuthButtonStyle(kind: .secondary))
                    }

                    Button("离线使用", action: continueOffline)
                        .buttonStyle(AuthButtonStyle(kind: .plain))
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 36)
            }
        }
        .navigationBarBackButtonHidden(presentationContext.showsBackButton)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(presentationContext.hidesTabBar ? .hidden : .automatic, for: .tabBar)
        .enableNavigationSwipeBack()
        .animateTabBarReturnWhenDisappearing(shouldAnimate: presentationContext.animatesTabBarReturn)
        .fullScreenCover(item: $sheet) { sheet in
            AuthFullScreenView(
                mode: sheet,
                account: $account,
                password: $password,
                confirmPassword: $confirmPassword,
                onFinish: finishAuthFlow
            )
            .environmentObject(store)
        }
    }

    private var backButton: some View {
        VStack {
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(Color.mindInk)
                        .frame(width: 52, height: 52)
                        .background(Color.cardSurface.opacity(0.86), in: Circle())
                        .shadow(color: .black.opacity(0.035), radius: 10, y: 5)
                }
                .buttonStyle(.plain)

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)

            Spacer()
        }
        .zIndex(2)
    }

    private var brandSection: some View {
        VStack(spacing: 34) {
            BrandMark(size: 176)
                .accessibilityLabel("念落笔记")

            VStack(spacing: 8) {
                Text("念落笔记")
                    .font(.system(size: 32, weight: .heavy))
                    .foregroundStyle(Color.mindInk)
                    .multilineTextAlignment(.center)
                Text("接住你每一个想法")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.welcomeTagline)
            }
        }
    }

    private func continueOffline() {
        switch presentationContext {
        case .launch:
            store.useOffline()
        case .profile, .settings:
            dismiss()
        }
    }

    private func dismissIfNeeded() {
        guard presentationContext.showsBackButton else { return }
        DispatchQueue.main.async {
            dismiss()
        }
    }

    private func finishAuthFlow() {
        if presentationContext == .profile {
            store.selectedTab = .profile
        }
        sheet = nil
        dismissIfNeeded()
    }
}

enum PresentationContext {
    case launch
    case profile
    case settings

    var showsBackButton: Bool {
        self == .profile || self == .settings
    }

    var hidesTabBar: Bool {
        self == .profile || self == .settings
    }

    var animatesTabBarReturn: Bool {
        self == .profile
    }
}

private enum AuthSheet: String, Identifiable {
    case login
    case register

    var id: String { rawValue }
    var title: String { self == .login ? "登录" : "注册" }
    var actionTitle: String { title }
    var loadingTitle: String { self == .login ? "正在登录..." : "正在注册..." }
    var passwordTextContentType: UITextContentType {
        self == .login ? .password : .newPassword
    }
}

private enum AuthFocusedField {
    case email
    case password
    case confirmPassword
}

private struct AuthButtonStyle: ButtonStyle {
    enum Kind: Equatable {
        case primary
        case secondary
        case plain
    }

    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .heavy))
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity)
            .frame(height: kind == .plain ? 54 : 56)
            .background(background, in: Capsule())
            .overlay {
                if kind == .secondary {
                    Capsule()
                        .stroke(Color.mindLime.opacity(0.45), lineWidth: 1)
                }
            }
            .shadow(color: shadowColor, radius: 14, y: 7)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }

    private var foreground: Color {
        switch kind {
        case .primary, .secondary: Color.mindDeepGreen
        case .plain: Color.authPlainButtonText
        }
    }

    private var background: AnyShapeStyle {
        switch kind {
        case .primary, .secondary:
            AnyShapeStyle(
                LinearGradient(
                    colors: [Color.mindLime, Color.mindLime.opacity(0.82)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
        case .plain:
            AnyShapeStyle(Color.mindPaleButton)
        }
    }

    private var shadowColor: Color {
        kind == .plain ? Color.clear : Color.mindLime.opacity(0.24)
    }
}

private struct AuthFullScreenView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let mode: AuthSheet
    @Binding var account: String
    @Binding var password: String
    @Binding var confirmPassword: String
    let onFinish: () -> Void
    @State private var helperText: String?
    @State private var hasValidatedRegisterEmail = false
    @FocusState private var focusedField: AuthFocusedField?

    var body: some View {
        ZStack {
            Color.authPageBackground
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    closeButton
                        .padding(.top, 26)

                    Text(mode.title)
                        .font(.system(size: 32, weight: .heavy))
                        .foregroundStyle(Color.mindInk)
                        .padding(.top, 30)

                    VStack(spacing: 23) {
                        AuthEmailField(
                            text: $account,
                            focusedField: $focusedField,
                            showsError: showsEmailError,
                            helperText: showsEmailError ? "请输入正确的邮箱地址" : nil
                        )
                        AuthPasswordField(
                            title: "密码",
                            text: $password,
                            focusedField: $focusedField,
                            field: .password,
                            textContentType: mode.passwordTextContentType,
                            showsError: showsPasswordError,
                            helperText: mode == .register ? "密码需包含字母和数字，且不低于8位" : nil
                        )

                        if mode == .register {
                            AuthPasswordField(
                                title: "再次输入密码",
                                text: $confirmPassword,
                                focusedField: $focusedField,
                                field: .confirmPassword,
                                textContentType: .newPassword
                            )
                        }
                    }
                    .padding(.top, 24)

                    Button(store.isAuthenticating ? mode.loadingTitle : mode.actionTitle) {
                        submit()
                    }
                    .disabled(store.isAuthenticating)
                    .buttonStyle(AuthButtonStyle(kind: .primary))
                    .padding(.top, 39)

                    if mode == .login {
                        Button("无法登录？") {
                            helperText = "请确认邮箱和密码是否正确，或稍后重新注册。"
                        }
                        .font(.system(size: 17, weight: .heavy))
                        .foregroundStyle(Color.authInteractiveText)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 42)

                        if let helperText {
                            Text(helperText)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Color.mindInk.opacity(0.52))
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 12)
                        }
                    }

                    Spacer(minLength: 80)
                }
                .padding(.horizontal, 20)
            }

            if let toast = store.toast {
                ToastView(text: toast)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(3)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: store.toast)
        .onChange(of: focusedField) { oldField, newField in
            if mode == .register, oldField == .email, newField != .email {
                hasValidatedRegisterEmail = true
            }
        }
    }

    private var trimmedAccount: String {
        account.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var showsEmailError: Bool {
        mode == .register &&
        hasValidatedRegisterEmail &&
        !trimmedAccount.isEmpty &&
        !trimmedAccount.isAuthValidEmail
    }

    private var showsPasswordError: Bool {
        mode == .register &&
        !password.isEmpty &&
        !password.isAuthValidPassword
    }

    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 25, weight: .medium))
                .foregroundStyle(Color.mindInk)
                .frame(width: 52, height: 52)
                .background(Color.cardSurface.opacity(0.82), in: Circle())
                .shadow(color: .black.opacity(0.035), radius: 12, y: 6)
        }
        .buttonStyle(.plain)
    }

    private func submit() {
        Task {
            if mode == .login {
                if await store.login(account: account, password: password) {
                    dismiss()
                    onFinish()
                }
                return
            }

            hasValidatedRegisterEmail = true
            if await store.register(account: account, password: password, confirmPassword: confirmPassword) {
                account = ""
                password = ""
                confirmPassword = ""
                hasValidatedRegisterEmail = false
                if store.session != .welcome {
                    dismiss()
                    onFinish()
                } else {
                    dismiss()
                }
            }
        }
    }
}

private struct AuthEmailField: View {
    @Binding var text: String
    let focusedField: FocusState<AuthFocusedField?>.Binding
    let showsError: Bool
    let helperText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("您的电子邮箱")
                .authFieldLabel()

            TextField("", text: $text)
                .focused(focusedField, equals: .email)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.emailAddress)
                .authFieldContainer(showsError: showsError)

            if let helperText {
                Text(helperText)
                    .authFieldHelper(isError: showsError)
            }
        }
    }
}

private struct AuthPasswordField: View {
    let title: String
    @Binding var text: String
    let focusedField: FocusState<AuthFocusedField?>.Binding
    let field: AuthFocusedField
    let textContentType: UITextContentType
    var showsError = false
    var helperText: String?
    @State private var isSecure = true

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .authFieldLabel()

            HStack(spacing: 10) {
                Group {
                    if isSecure {
                        SecureField("", text: $text)
                    } else {
                        TextField("", text: $text)
                    }
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(textContentType)
                .focused(focusedField, equals: field)

                Button {
                    isSecure.toggle()
                } label: {
                    Image(systemName: isSecure ? "eye" : "eye.slash")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.authInteractiveText)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
            }
            .authFieldContainer(showsError: showsError)

            if let helperText {
                Text(helperText)
                    .authFieldHelper(isError: showsError)
            }
        }
    }
}

private extension Text {
    func authFieldLabel() -> some View {
        font(.system(size: 15, weight: .heavy))
            .foregroundStyle(Color.mindInk)
    }
}

private extension View {
    func authFieldContainer(showsError: Bool = false) -> some View {
        self
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(Color.mindInk)
            .padding(.horizontal, 15)
            .frame(height: 56)
            .background(Color.cardSurface.opacity(0.42), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(showsError ? Color.authError : Color.mindInk.opacity(0.42), lineWidth: 1)
            }
    }

    func authFieldHelper(isError: Bool) -> some View {
        self
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(isError ? Color.authError : Color.mindInk.opacity(0.46))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, -2)
    }
}

private extension Color {
    static let mindLime = Color(red: 0.62, green: 0.91, blue: 0.43)
    static let mindDeepGreen = Color(red: 0.11, green: 0.24, blue: 0.08)
    static let mindPaleButton = adaptive(
        light: UIColor(red: 0.93, green: 0.95, blue: 0.91, alpha: 1),
        dark: UIColor(red: 0.90, green: 0.93, blue: 0.86, alpha: 1)
    )
    static let welcomeTagline = adaptive(
        light: UIColor(red: 0.11, green: 0.24, blue: 0.08, alpha: 0.72),
        dark: UIColor(red: 0.68, green: 0.91, blue: 0.53, alpha: 0.88)
    )
    static let authPlainButtonText = adaptive(
        light: UIColor(red: 0.12, green: 0.14, blue: 0.18, alpha: 0.62),
        dark: UIColor(red: 0.11, green: 0.24, blue: 0.08, alpha: 0.86)
    )
    static let authInteractiveText = adaptive(
        light: UIColor(red: 0.11, green: 0.24, blue: 0.08, alpha: 1),
        dark: UIColor(red: 0.68, green: 0.91, blue: 0.53, alpha: 1)
    )
    static let authPageBackground = adaptive(
        light: UIColor(red: 0.995, green: 0.994, blue: 0.985, alpha: 1),
        dark: UIColor(red: 0.055, green: 0.060, blue: 0.070, alpha: 1)
    )
    static let authError = Color(red: 0.84, green: 0.20, blue: 0.18)

    private static func adaptive(light: UIColor, dark: UIColor) -> Color {
        Color(UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        })
    }
}

private extension String {
    var isAuthValidEmail: Bool {
        range(of: #"^[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"#, options: .regularExpression) != nil
    }

    var isAuthValidPassword: Bool {
        count >= 8 &&
        range(of: #"[A-Za-z]"#, options: .regularExpression) != nil &&
        range(of: #"\d"#, options: .regularExpression) != nil
    }
}
