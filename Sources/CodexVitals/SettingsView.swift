import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: UsageViewModel
    @ObservedObject var appUpdater: AppUpdater
    @StateObject private var launchAtLogin = LaunchAtLoginModel()
    private let contentWidth: CGFloat = ContentView.preferredWidth - 32

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                appIdentity

                settingsSection("General") {
                    generalSettings
                }

                statusMessages

                settingsSection("Updates") {
                    updateSettings
                }

                settingsSection("Project") {
                    aboutSettings
                }

                quitCard
            }
            .frame(width: contentWidth)
            .padding(.vertical, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            launchAtLogin.refresh()
            viewModel.refreshResetNotificationAuthorization()
            appUpdater.refreshSettings()
        }
    }

    private var appIdentity: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(AppInfo.name)
                    .font(.system(size: 17, weight: .semibold))
                AppCreditsView()
                    .padding(.vertical, 4)
                Text(AppInfo.versionText)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var generalSettings: some View {
        VStack(spacing: 0) {
            settingsRow {
                Toggle(isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }
                )) {
                    settingsLabel("Launch at Login", systemImage: "power.circle")
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(Theme.brandAccent)
            }

            settingsDivider

            settingsRow {
                Toggle(isOn: $viewModel.groupByWorkspace) {
                    settingsLabel("Group by Workspace", systemImage: "rectangle.3.group")
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(Theme.brandAccent)
            }

            settingsDivider

            settingsRow {
                HStack(spacing: 10) {
                    settingsLabel("Account Order", systemImage: "arrow.up.arrow.down")
                    Spacer(minLength: 8)
                    Picker("", selection: Binding(
                        get: { viewModel.accountSortMode },
                        set: { viewModel.setAccountSortMode($0) }
                    )) {
                        ForEach(AccountSortMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .frame(width: 96)
                }
            }

            settingsDivider

            settingsRow {
                HStack(spacing: 10) {
                    settingsLabel("Auto Refresh", systemImage: "clock.arrow.circlepath")
                    Spacer(minLength: 8)
                    Picker("", selection: $viewModel.autoRefreshInterval) {
                        ForEach(AutoRefreshInterval.allCases) { interval in
                            Text(interval.displayName).tag(interval)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .frame(width: 96)
                }
            }

            settingsDivider

            settingsRow {
                Toggle(isOn: Binding(
                    get: { viewModel.resetNotificationsEnabled },
                    set: { viewModel.setResetNotificationsEnabled($0) }
                )) {
                    settingsLabel("Reset Notifications", systemImage: "bell.badge")
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(Theme.brandAccent)
                .disabled(viewModel.isRequestingResetNotificationPermission)
                .help("Notify after an automatic refresh confirms that usage has reset")
            }
        }
    }

    @ViewBuilder
    private var statusMessages: some View {
        if launchStatusMessage != nil || viewModel.resetNotificationStatusMessage != nil {
            VStack(alignment: .leading, spacing: 4) {
                if let launchStatusMessage {
                    Text(launchStatusMessage)
                }
                if let resetNotificationStatusMessage = viewModel.resetNotificationStatusMessage {
                    Text(resetNotificationStatusMessage)
                }
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundColor(Theme.warningText)
            .lineLimit(2)
            .padding(.horizontal, 2)
        }
    }

    private var updateSettings: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Updates from your repository")
                    .font(.system(size: 11, weight: .medium))
                Text("TheMakerOfWorlds/codex-vitals")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            settingsRow {
                Toggle(isOn: Binding(
                    get: { appUpdater.automaticallyChecksForUpdates },
                    set: { appUpdater.setAutomaticallyChecksForUpdates($0) }
                )) {
                    settingsLabel("Check Automatically", systemImage: "clock.badge.checkmark")
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(Theme.brandAccent)
            }

            settingsDivider

            settingsRow {
                Toggle(isOn: Binding(
                    get: { appUpdater.automaticallyInstallsUpdates },
                    set: { appUpdater.setAutomaticallyInstallsUpdates($0) }
                )) {
                    settingsLabel("Install Automatically", systemImage: "arrow.down.app")
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(Theme.brandAccent)
                .disabled(!appUpdater.automaticallyChecksForUpdates)
            }

            settingsDivider

            Button {
                appUpdater.checkForUpdates()
            } label: {
                externalRow("Check for Updates", systemImage: "arrow.clockwise.circle") {
                    Text(AppInfo.versionText)
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .buttonStyle(.plain)
            .disabled(!appUpdater.canCheckForUpdates)
            .help("Check for a new Headroom version")
        }
    }

    private var aboutSettings: some View {
        VStack(spacing: 0) {
            Button { open(AppInfo.repositoryURL) } label: {
                externalRow("Keystone Science on GitHub", systemImage: "chevron.left.forwardslash.chevron.right") { externalArrow }
            }
            .buttonStyle(.plain)
            Button { open(AppInfo.releasesURL) } label: {
                externalRow("Upstream release history", systemImage: "shippingbox") { externalArrow }
            }
            .buttonStyle(.plain)
        }
    }

    private var quitCard: some View {
        VStack(spacing: 0) {
            Button {
                NSApp.terminate(nil)
            } label: {
                HStack(spacing: 10) {
                    Label("Quit Headroom", systemImage: "power")
                        .font(Theme.settingsLabelFont)
                        .foregroundStyle(Theme.dangerText)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .frame(height: 42)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Quit Headroom")
        }
        .background(Theme.settingsGroupSurface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.settingsCardCornerRadius, style: .continuous))
    }

    private var launchStatusMessage: String? {
        if let errorMessage = launchAtLogin.errorMessage {
            return errorMessage
        }
        return launchAtLogin.statusNotice
    }

    private func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    private func settingsSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(Theme.sectionTitleFont)
                .foregroundStyle(.secondary)
                .padding(.leading, 2)

            VStack(spacing: 0) {
                content()
            }
            .background(Theme.settingsGroupSurface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.settingsCardCornerRadius, style: .continuous))
        }
    }

    private func settingsRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack {
            content()
                .font(Theme.settingsLabelFont)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
        .contentShape(Rectangle())
    }

    private var settingsDivider: some View { Color.clear.frame(height: 2) }

    private func settingsLabel(_ title: String, systemImage: String) -> some View {
        Label {
            Text(title)
                .font(Theme.settingsLabelFont)
                .foregroundStyle(.primary)
        } icon: {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16)
        }
    }

    private func externalRow<Trailing: View>(
        _ title: String,
        systemImage: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 10) {
            settingsLabel(title, systemImage: systemImage)
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
        .contentShape(Rectangle())
    }

    private var externalArrow: some View {
        Image(systemName: "arrow.up.right")
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.secondary)
    }
}

@MainActor
final class LaunchAtLoginModel: ObservableObject {
    @Published var isEnabled = false
    @Published private(set) var statusNotice: String?
    @Published var errorMessage: String?

    func refresh() {
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled
        statusNotice = status.noticeText
    }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }
}

private extension SMAppService.Status {
    var noticeText: String? {
        switch self {
        case .enabled, .notRegistered:
            return nil
        case .requiresApproval:
            return "Launch at Login needs approval in System Settings"
        case .notFound:
            return "Launch at Login is unavailable for this build"
        @unknown default:
            return "Launch at Login status is unknown"
        }
    }
}

struct AppCreditsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(AppInfo.publisher)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
            Text(AppInfo.contributors)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
