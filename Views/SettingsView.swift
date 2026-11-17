import SwiftUI
import WebKit
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject private var hotKeys = HotKeyManager.shared
    @AppStorage(UserDefaultsKeys.pageZoom.rawValue) private var pageZoom: Double = Constants.defaultPageZoom
    @AppStorage(UserDefaultsKeys.hideWindowAtLaunch.rawValue) private var hideWindowAtLaunch: Bool = false
    @AppStorage(UserDefaultsKeys.hideDockIcon.rawValue) private var hideDockIcon: Bool = false
    @AppStorage(UserDefaultsKeys.appTheme.rawValue) private var appTheme: String = AppTheme.system.rawValue
    @AppStorage(UserDefaultsKeys.userAgentOption.rawValue) private var userAgentOption: String = UserAgentOption.safari.rawValue
    @AppStorage(UserDefaultsKeys.customUserAgent.rawValue) private var customUserAgent: String = ""
    @AppStorage(UserDefaultsKeys.panelPosition.rawValue) private var panelPosition: String = PanelPosition.bottomCenter.rawValue
    @AppStorage(UserDefaultsKeys.notifyOnResponse.rawValue) private var notifyOnResponse: Bool = true

    @State private var showingResetAlert = false
    @State private var isClearing = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var hasScreenPermission = ScreenCapture.hasPermission

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { newValue in
                        do {
                            try newValue ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                        } catch { launchAtLogin = !newValue }
                    }
                Toggle("Hide Desktop Window at Launch", isOn: $hideWindowAtLaunch)
                Toggle("Hide Dock Icon", isOn: $hideDockIcon)
                    .onChange(of: hideDockIcon) { newValue in
                        NSApp.setActivationPolicy(newValue ? .accessory : .regular)
                    }
                Toggle("Notify When Gemini Finishes Responding in the Background", isOn: $notifyOnResponse)
                    .onChange(of: notifyOnResponse) { newValue in
                        if newValue { ResponseNotifier.shared.requestAuthorizationIfNeeded() }
                    }
            }

            Section {
                ForEach(HotKeyAction.allCases) { action in
                    HStack {
                        Label(action.displayName, systemImage: action.systemImage)
                        Spacer()
                        ShortcutRecorder(action: action)
                    }
                }
                HStack {
                    Text("Shortcuts work system-wide, even when Gemini is in the background.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore Defaults") { hotKeys.resetToDefaults() }
                        .controlSize(.small)
                }
            } header: {
                Text("Keyboard Shortcuts")
            }

            Section("Quick Chat") {
                HStack {
                    Label("Position on Screen", systemImage: "rectangle.bottomthird.inset.filled")
                    Spacer()
                    Picker("", selection: $panelPosition) {
                        ForEach([PanelPosition.bottomLeft, .bottomCenter, .bottomRight], id: \.rawValue) { pos in
                            Text(pos.displayName).tag(pos.rawValue)
                        }
                        Divider()
                        Text(PanelPosition.rememberLast.displayName).tag(PanelPosition.rememberLast.rawValue)
                    }
                    .labelsHidden()
                    .frame(width: 200)
                    .onChange(of: panelPosition) { _ in
                        coordinator.resetChatBarPosition()
                    }
                }
            }

            Section("Screen Context") {
                HStack {
                    Label(hasScreenPermission ? "Screen Recording permission granted" : "Screen Recording permission needed",
                          systemImage: hasScreenPermission ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundColor(hasScreenPermission ? .green : .orange)
                    Spacer()
                    if !hasScreenPermission {
                        Button("Grant…") {
                            ScreenCapture.ensurePermission()
                            hasScreenPermission = ScreenCapture.hasPermission
                        }
                    }
                }
                Text("Lets Gemini see a window or part of your screen when you use \"Ask About Active Window\" or \"Ask About Screen Area\". After granting access, quit and reopen the app.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Tip: select text in any app, then right-click → Services → Ask Gemini. You can give that service its own shortcut in System Settings → Keyboard → Keyboard Shortcuts → Services.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Appearance") {
                HStack {
                    Text("Theme:")
                    Spacer()
                    Picker("", selection: $appTheme) {
                        ForEach(AppTheme.allCases, id: \.rawValue) { theme in
                            Text(theme.displayName).tag(theme.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                    .onChange(of: appTheme) { newValue in
                        (AppTheme(rawValue: newValue) ?? .system).apply()
                    }
                }
                HStack {
                    Text("Text Size: \(Int((pageZoom * 100).rounded()))%")
                    Spacer()
                    Stepper("",
                            value: $pageZoom,
                            in: Constants.minPageZoom...Constants.maxPageZoom,
                            step: Constants.pageZoomStep)
                        .onChange(of: pageZoom) { newValue in
                            coordinator.webViewModel.wkWebView.pageZoom = newValue
                        }
                        .labelsHidden()
                }
            }

            Section("User Agent") {
                HStack {
                    Text("Browser Identity:")
                    Spacer()
                    Picker("", selection: $userAgentOption) {
                        ForEach(UserAgentOption.allCases, id: \.rawValue) { option in
                            Text(option.displayName).tag(option.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                    .onChange(of: userAgentOption) { _ in
                        coordinator.webViewModel.applyUserAgent()
                    }
                }
                if userAgentOption == UserAgentOption.custom.rawValue {
                    TextField("Custom User Agent", text: $customUserAgent, prompt: Text("Enter custom user agent string"))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            coordinator.webViewModel.applyUserAgent()
                        }
                }
                Text(currentUserAgentDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Privacy") {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Reset Website Data")
                        Text("Clears cookies, cache, and login sessions")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Reset", role: .destructive) { showingResetAlert = true }
                        .disabled(isClearing)
                        .overlay { if isClearing { ProgressView().scaleEffect(0.7) } }
                }
            }

            Section {
                HStack {
                    Text("Gemini Desktop \(appVersion)")
                    Spacer()
                    Text("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            hasScreenPermission = ScreenCapture.hasPermission
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
        .alert("Reset Website Data?", isPresented: $showingResetAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Reset", role: .destructive) { clearWebsiteData() }
        } message: {
            Text("This will clear all cookies, cache, and login sessions. You will need to sign in to Gemini again.")
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? short : "\(short) (\(build))"
    }

    private var currentUserAgentDescription: String {
        let option = UserAgentOption(rawValue: userAgentOption) ?? .safari
        return option.settingsDescription(custom: customUserAgent)
    }

    private func clearWebsiteData() {
        isClearing = true
        let dataStore = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        dataStore.fetchDataRecords(ofTypes: types) { records in
            dataStore.removeData(ofTypes: types, for: records) {
                DispatchQueue.main.async {
                    isClearing = false
                    coordinator.webViewModel.loadHome()
                }
            }
        }
    }
}

extension SettingsView {

    struct Constants {
        static let defaultPageZoom: Double = 1.0
        static let minPageZoom: Double = 0.6
        static let maxPageZoom: Double = 1.4
        static let pageZoomStep: Double = 0.05
    }

}
