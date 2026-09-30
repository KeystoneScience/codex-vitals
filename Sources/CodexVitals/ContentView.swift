import AppKit
import Combine
import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: UsageViewModel
    @ObservedObject var appUpdater: AppUpdater
    @State private var isShowingSettings = false

    static let preferredWidth: CGFloat = 900

    static func preferredHeight() -> CGFloat {
        let visibleHeight = NSScreen.main?.visibleFrame.height ?? 900
        return min(720, floor(visibleHeight * 0.85))
    }

    static func listMaxHeight() -> CGFloat {
        max(280, preferredHeight() - 84)
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                HeaderView(vm: viewModel, isShowingSettings: $isShowingSettings)

                if isShowingSettings {
                    SettingsView(viewModel: viewModel, appUpdater: appUpdater)
                        .frame(maxWidth: .infinity, maxHeight: Self.listMaxHeight())
                } else {
                    if viewModel.isLoading && viewModel.accounts.isEmpty {
                        SkeletonView()
                    } else if !viewModel.hasAnyAccount {
                        emptyState
                    } else {
                        ScrollView(.vertical) {
                            AccountListView(vm: viewModel)
                                .frame(maxWidth: .infinity)
                        }
                        .background(Theme.listSurfaceTint)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.panelCornerRadius, style: .continuous))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 7)
                        .frame(maxHeight: Self.listMaxHeight())
                    }
                }


                if !isShowingSettings && viewModel.errorsCount > 0 {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(Theme.warningText)
                            .font(.system(size: 11))
                        Text("\(viewModel.errorsCount) account(s) with errors")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 12).padding(.vertical, 4)
                }

                if let accountActionError = viewModel.accountActionError {
                    FooterView(message: accountActionError)
                }
            }
        }
        .frame(width: Self.preferredWidth)
        .background(Theme.appBackground)
        .background(
            Group {
                Button("") { isShowingSettings.toggle() }.keyboardShortcut(",", modifiers: .command)
                Button("") { viewModel.toggleGroupByWorkspace() }.keyboardShortcut("g", modifiers: [.command, .shift])
                Button("") { viewModel.refresh(forceMetadataRefresh: true) }.keyboardShortcut("r", modifiers: .command)
                Button("") { NSApp.terminate(nil) }.keyboardShortcut("q", modifiers: .command)
            }.opacity(0)
        )
    }


    @ViewBuilder
    private var emptyState: some View {
        if !viewModel.searchText.isEmpty {
            Text("No account matches '\(viewModel.searchText)'")
                .font(.system(size: 14)).foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
                .padding(.horizontal, 16)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.system(size: 32)).foregroundColor(.secondary)
                Text("No accounts found")
                    .font(.system(size: 14)).foregroundColor(.secondary)
                Menu {
                    Button("Add Codex Account", systemImage: "command") {
                        viewModel.addCodexAccount()
                    }
                    Button {
                        viewModel.addClaudeAccount()
                    } label: {
                        Label {
                            Text("Add Claude Account")
                        } icon: {
                            ClaudeIconView(foregroundColor: .primary)
                        }
                    }
                } label: {
                    Label("Add account", systemImage: "person.badge.plus")
                        .font(.system(size: 12, weight: .semibold))
                }
                .controlSize(.small)
                .disabled(viewModel.hasPendingAccountAction)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
            .padding(.horizontal, 16)
        }
    }
}

// MARK: - Header

struct HeaderView: View {
    @ObservedObject var vm: UsageViewModel
    @Binding var isShowingSettings: Bool
    @State private var manualRefreshPending = false
    @State private var showsRefreshSuccess = false
    @State private var refreshSuccessTask: Task<Void, Never>?
    @State private var isSearchVisible = false

    var body: some View {
        HStack(spacing: 8) {
            if isShowingSettings {
                settingsTitle
                Spacer(minLength: 0)
            } else if shouldShowSearchField {
                compactSearchField
                Spacer(minLength: 0)
            } else {
                appBrandLockup
                Spacer(minLength: 0)
            }

            if !isShowingSettings {
                KeepAwakeControl(controller: .shared)
                toolbarControls
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .frame(height: 56)
        .background(Theme.headerSurface)
        .animation(.easeInOut(duration: 0.16), value: shouldShowSearchField)
        .onReceive(vm.$isLoading.dropFirst()) { isLoading in
            handleLoadingChange(isLoading)
        }
    }

    @ViewBuilder
    private var toolbarControls: some View {
        HStack(spacing: 1) {
            HeaderActionButton(
                action: toggleSearch,
                isSelected: shouldShowSearchField,
                helpText: shouldShowSearchField ? "Hide search" : "Search",
                accessibilityText: shouldShowSearchField ? "Hide search" : "Search accounts"
            ) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(shouldShowSearchField ? Theme.brandAccent : .secondary)
            }

            if vm.isAddingAccount {
                HeaderActionButton(
                    action: { vm.cancelRelogin() },
                    isSelected: true,
                    helpText: "Cancel adding account",
                    accessibilityText: "Cancel adding account"
                ) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                }
            } else {
                HeaderAccountMenu(vm: vm)
            }

            HeaderActionButton(
                action: requestRefresh,
                isDisabled: vm.isLoading,
                helpText: showsRefreshSuccess ? "Updated" : "Refresh",
                accessibilityText: showsRefreshSuccess ? "Usage updated" : "Refresh all accounts"
            ) {
                if vm.isLoading {
                    ProgressView()
                        .controlSize(.mini)
                } else if showsRefreshSuccess {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.healthyAccent)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                }
            }


            HeaderActionButton(
                action: { isShowingSettings = true },
                helpText: "Settings",
                accessibilityText: "Settings"
            ) {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
            }
        }
        .padding(3)
    }

    private var settingsTitle: some View {
        HStack(spacing: 8) {
            Button {
                isShowingSettings = false
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Back to accounts")

            Text("Settings")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
        }
    }

    private func toggleSearch() {
        if shouldShowSearchField && vm.searchText.isEmpty {
            isSearchVisible = false
        } else {
            isSearchVisible = true
        }
    }

    private var shouldShowSearchField: Bool {
        isSearchVisible || !vm.searchText.isEmpty
    }

    private var appBrandLockup: some View {
        HStack(spacing: 8) {
            HeadroomHeaderIcon()
            Text(AppInfo.name)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
                .fixedSize()
        }
    }

    private var compactSearchField: some View {
        HStack(spacing: 6) {
            SearchTextField("Search", text: $vm.searchText)
                .frame(width: searchFieldWidth)
                .frame(minHeight: 16)

            if !vm.searchText.isEmpty {
                Button {
                    vm.searchText = ""
                    isSearchVisible = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Theme.toolbarSurface)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: Theme.controlCornerRadius, style: .continuous))
        .transition(.opacity.combined(with: .move(edge: .trailing)))
    }

    private var searchFieldWidth: CGFloat {
        170
    }

    private func requestRefresh() {
        guard !vm.isLoading else { return }
        manualRefreshPending = true
        showsRefreshSuccess = false
        refreshSuccessTask?.cancel()
        vm.refresh(forceMetadataRefresh: true)
    }

    private func handleLoadingChange(_ isLoading: Bool) {
        guard !isLoading, manualRefreshPending else { return }
        manualRefreshPending = false
        showsRefreshSuccess = true
        refreshSuccessTask?.cancel()
        refreshSuccessTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            showsRefreshSuccess = false
        }
    }
}

/// The selected white quota glyph is used only beside the header title.
private struct HeadroomHeaderIcon: View {
    private static let image: NSImage = {
        let repositoryAsset = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Support/HeadroomHeader.png")
        let image = [
            Bundle.main.url(forResource: "HeadroomHeader", withExtension: "png"),
            repositoryAsset
        ].compactMap { $0.flatMap { NSImage(contentsOf: $0) } }.first
            ?? NSImage(systemSymbolName: "chart.bar.xaxis", accessibilityDescription: nil)!
        image.isTemplate = true
        return image
    }()

    var body: some View {
        Image(nsImage: Self.image)
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .foregroundStyle(.primary)
            .frame(width: 32, height: 32)
            .accessibilityHidden(true)
    }
}

private struct HeaderAccountMenu: View {
    @ObservedObject var vm: UsageViewModel
    @State private var isHovered = false

    var body: some View {
        Menu {
            Button("Add Codex Account", systemImage: "command") {
                vm.addCodexAccount()
            }
            Button {
                vm.addClaudeAccount()
            } label: {
                Label {
                    Text("Add Claude Account")
                } icon: {
                    ClaudeIconView(foregroundColor: .primary)
                }
            }
        } label: {
            Image(systemName: "person.badge.plus")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Theme.healthyAccent)
                .frame(width: 28, height: 28)
                .background {
                    RoundedRectangle(cornerRadius: Theme.controlCornerRadius, style: .continuous)
                        .fill(isHovered ? Theme.controlHoverSurface : .clear)
                }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(vm.hasPendingAccountAction)
        .opacity(vm.hasPendingAccountAction ? 0.55 : 1)
        .scaleEffect(isHovered && !vm.hasPendingAccountAction ? 1.02 : 1)
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .onHover { isHovered = $0 }
        .help("Add account")
        .accessibilityLabel("Add Codex or Claude account")
    }
}

private struct HeaderActionButton<Label: View>: View {
    let action: () -> Void
    var isSelected = false
    var isDisabled = false
    let helpText: String
    let accessibilityText: String
    let label: Label
    @State private var isHovered = false

    init(
        action: @escaping () -> Void,
        isSelected: Bool = false,
        isDisabled: Bool = false,
        helpText: String,
        accessibilityText: String,
        @ViewBuilder label: () -> Label
    ) {
        self.action = action
        self.isSelected = isSelected
        self.isDisabled = isDisabled
        self.helpText = helpText
        self.accessibilityText = accessibilityText
        self.label = label()
    }

    var body: some View {
        Button(action: action) {
            label
                .frame(width: 28, height: 28)
                .background {
                    RoundedRectangle(cornerRadius: Theme.controlCornerRadius, style: .continuous)
                        .fill(controlSurface)
                }
                .contentShape(RoundedRectangle(cornerRadius: Theme.controlCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.55 : 1)
        .scaleEffect(isSelected ? 1.02 : (isHovered && !isDisabled ? 1.02 : 1))
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .animation(.easeOut(duration: 0.16), value: isSelected)
        .onHover { isHovered = $0 }
        .help(helpText)
        .accessibilityLabel(accessibilityText)
    }

    private var controlSurface: Color {
        if isSelected {
            return Theme.controlSelectedSurface
        }
        return isHovered ? Theme.controlHoverSurface : .clear
    }


}

struct SearchTextField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String

    init(_ placeholder: String, text: Binding<String>) {
        self.placeholder = placeholder
        self._text = text
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> ShortcutTextField {
        let field = ShortcutTextField()
        field.delegate = context.coordinator
        field.placeholderString = placeholder
        field.font = NSFont.systemFont(ofSize: 13)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ nsView: ShortcutTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.placeholderString = placeholder
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding var text: String

        init(text: Binding<String>) {
            self._text = text
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            text = field.stringValue
        }
    }
}

final class ShortcutTextField: NSTextField {
    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.control),
           event.charactersIgnoringModifiers?.lowercased() == "a" {
            currentEditor()?.selectAll(nil)
            return
        }
        super.keyDown(with: event)
    }
}

// MARK: - Footer

struct FooterView: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Text(message)
                .font(.system(size: 11))
                .foregroundColor(Theme.warningText)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(height: 40)
    }
}

// MARK: - Skeleton

struct SkeletonView: View {
    @State private var pulse = false

    private let rowHeight: CGFloat = 28

    var body: some View {
        VStack(spacing: 8) {
            ForEach(0..<6, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(pulse ? 0.08 : 0.04))
                    .frame(height: rowHeight)
                    .padding(.horizontal, 12)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .onAppear {
            withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}
