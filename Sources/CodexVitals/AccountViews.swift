import SwiftUI
import AppKit

private enum AccountAliasPrompt {
    static func edit(account: Account, save: (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = account.hasDisplayAlias ? "Edit Account Alias" : "Set Account Alias"
        alert.informativeText = account.email
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        textField.stringValue = account.displayAlias ?? ""
        textField.placeholderString = "Display alias"
        alert.accessoryView = textField

        if alert.runModal() == .alertFirstButtonReturn {
            save(Account.normalizedAlias(textField.stringValue))
        }
    }
}

private enum WorkspaceAliasPrompt {
    static func edit(workspace: String, displayName: String, hasAlias: Bool, save: (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = hasAlias ? "Edit Workspace Name" : "Set Workspace Name"
        alert.informativeText = hasAlias ? "Original: \(workspace)" : workspace
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        textField.stringValue = hasAlias ? displayName : ""
        textField.placeholderString = "Display name"
        alert.accessoryView = textField

        if alert.runModal() == .alertFirstButtonReturn {
            save(Account.normalizedAlias(textField.stringValue))
        }
    }
}

private enum PlanRenewalDatePrompt {
    static func edit(account: Account, save: (Date?) -> Void) {
        let alert = NSAlert()
        alert.messageText = account.planRenewalDate == nil
            ? "Set Plan Renewal Date"
            : "Edit Plan Renewal Date"
        alert.informativeText = "Enter the next billing date shown by your Claude subscription."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let picker = NSDatePicker(frame: NSRect(x: 0, y: 0, width: 180, height: 24))
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = .yearMonthDay
        picker.minDate = Calendar.current.startOfDay(for: Date())
        picker.dateValue = account.planRenewalDate
            ?? Calendar.current.date(byAdding: .month, value: 1, to: Date())
            ?? Date()
        alert.accessoryView = picker

        if alert.runModal() == .alertFirstButtonReturn {
            save(picker.dateValue)
        }
    }
}

struct AccountListView: View {
    @ObservedObject var vm: UsageViewModel

    var body: some View {
        listBody
    }

    @ViewBuilder
    private var listBody: some View {
        VStack(spacing: 4) {
            ForEach(providerSections, id: \.provider) { section in
                providerSection(section.provider, accountCount: section.accounts.count)
            }
        }
        .padding(.vertical, 4)
    }

    private var displayedAccounts: [Account] {
        vm.priorityAccounts
            + vm.normalActiveAccounts
            + vm.nonFreeExhaustedAccounts
            + vm.freeWaitingAccounts
            + vm.attentionAccounts
    }

    private var providerSections: [(provider: AccountProvider, accounts: [Account])] {
        UsageViewModel.groupByProvider(displayedAccounts)
    }

    @ViewBuilder
    private func providerSection(_ provider: AccountProvider, accountCount: Int) -> some View {
        VStack(spacing: 0) {
            ProviderSectionHeader(provider: provider, count: accountCount)
            if vm.groupByWorkspace {
                groupedProviderContent(provider)
            } else {
                flatProviderContent(provider)
            }
        }
        .background(Theme.providerSectionSurface(for: provider))
    }

    @ViewBuilder
    private func flatProviderContent(_ provider: AccountProvider) -> some View {
        let priority = providerAccounts(vm.priorityAccounts, provider: provider)
        let active = providerAccounts(vm.normalActiveAccounts, provider: provider)
        let exhausted = providerAccounts(vm.waitingForResetAccounts, provider: provider)
        let attention = providerAccounts(vm.attentionAccounts, provider: provider)

        if !priority.isEmpty {
            PrioritySeparatorHeader(count: priority.count)
            rows(priority)
        }
        if !active.isEmpty {
            rows(active)
        }
        if !exhausted.isEmpty {
            waitingForResetGroup(count: exhausted.count) {
                rows(providerAccounts(vm.nonFreeExhaustedAccounts, provider: provider))
                freeWaitingGroup(provider)
            }
        }
        if !attention.isEmpty {
            attentionGroup(count: attention.count) { rows(attention) }
        }
    }

    @ViewBuilder
    private func groupedProviderContent(_ provider: AccountProvider) -> some View {
        let priority = providerAccounts(vm.priorityAccounts, provider: provider)
        let active = providerAccounts(vm.normalActiveAccounts, provider: provider)
        let exhausted = providerAccounts(vm.waitingForResetAccounts, provider: provider)
        let attention = providerAccounts(vm.attentionAccounts, provider: provider)

        if !priority.isEmpty {
            PrioritySeparatorHeader(count: priority.count)
            workspaceGroups(providerGroups(vm.groupedPriorityAccounts, provider: provider), provider: provider)
        }
        if !active.isEmpty {
            workspaceGroups(providerGroups(vm.groupedNormalActiveAccounts, provider: provider), provider: provider)
        }
        if !exhausted.isEmpty {
            waitingForResetGroup(count: exhausted.count) {
                workspaceGroups(providerGroups(vm.groupedExhaustedAccounts, provider: provider), provider: provider)
                freeWaitingGroup(provider)
            }
        }
        if !attention.isEmpty {
            attentionGroup(count: attention.count) {
                workspaceGroups(providerGroups(vm.groupedAttentionAccounts, provider: provider), provider: provider)
            }
        }
    }

    @ViewBuilder
    private func workspaceGroups(
        _ groups: [(String, [Account])],
        provider: AccountProvider
    ) -> some View {
        ForEach(groups, id: \.0) { ws, accs in
            SectionHeader(
                originalName: ws,
                displayName: vm.workspaceDisplayName(for: ws, provider: provider),
                count: accs.count,
                hasAlias: vm.workspaceHasDisplayAlias(ws, provider: provider),
                setAlias: { vm.setWorkspaceAlias($0, for: ws, provider: provider) }
            )
            rows(accs)
        }
    }

    private func providerAccounts(_ accounts: [Account], provider: AccountProvider) -> [Account] {
        accounts.filter { $0.accountProvider == provider }
    }

    private func providerGroups(
        _ groups: [(String, [Account])],
        provider: AccountProvider
    ) -> [(String, [Account])] {
        groups.compactMap { workspace, accounts in
            let filtered = providerAccounts(accounts, provider: provider)
            return filtered.isEmpty ? nil : (workspace, filtered)
        }
    }

    @ViewBuilder
    private func waitingForResetGroup<Content: View>(
        count: Int,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let isCollapsed = vm.waitingForResetCollapsed && vm.searchText.isEmpty
        VStack(spacing: 0) {
            ExhaustedSeparatorHeader(
                count: count,
                isCollapsed: isCollapsed,
                toggle: { vm.toggleWaitingForResetCollapsed() }
            )
            if !isCollapsed {
                content()
            }
        }
        .opacity(0.8)
    }

    @ViewBuilder
    private func attentionGroup<Content: View>(count: Int, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundColor(Theme.warningText)
                Text("Needs attention · \(count)")
                    .foregroundColor(.secondary)
                Spacer()
            }
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 12)
            .frame(height: 27)
            content()
        }
    }

    @ViewBuilder
    private func freeWaitingGroup(_ provider: AccountProvider) -> some View {
        let accounts = providerAccounts(vm.freeWaitingAccounts, provider: provider)
        if !accounts.isEmpty {
            let isCollapsed = vm.freeWaitingCollapsed && vm.searchText.isEmpty
            FreeWaitingGroupHeader(
                count: accounts.count,
                isCollapsed: isCollapsed,
                toggle: { vm.toggleFreeWaitingCollapsed() }
            )
            if !isCollapsed {
                rows(accounts)
            }
        }
    }

    @ViewBuilder
    private func rows(_ accs: [Account]) -> some View {
        ForEach(accs, id: \.id) { acc in
            accountRow(for: acc)
        }
    }

    @ViewBuilder
    private func accountRow(for acc: Account) -> some View {
        ReorderableAccountRow(account: acc, viewModel: vm) {
            AccountCompactRow(
                account: acc,
                needsRelogin: vm.needsRelogin(acc),
                isRelogging: vm.isRelogging(acc),
                isReloginBlocked: vm.hasPendingAccountAction && !vm.isRelogging(acc),
                isSwitchingAccount: vm.isSwitchingAccount(acc),
                isActiveAccount: vm.isActiveAccount(acc),
                showsSwitchControls: vm.showsSwitchControls(for: acc),
                canSwitchAccount: vm.canSwitchAccount(acc),
                isSwitchBlocked: vm.hasPendingAccountAction && !vm.isSwitchingAccount(acc),
                isRemoving: vm.isRemoving(acc),
                isRemoveBlocked: vm.hasPendingAccountAction && !vm.isRemoving(acc),
                allowsRemoval: true,
                allowsAlias: true,
                allowsReordering: vm.canReorderAccount(acc),
                relogin: { vm.relogin(acc) },
                cancelRelogin: { vm.cancelRelogin() },
                switchAccount: { vm.switchAccount(to: acc) },
                removeAccount: { vm.removeAccount(acc) },
                setAlias: { vm.setAlias($0, for: acc) },
                setPlanRenewalDate: { vm.setPlanRenewalDate($0, for: acc) }
            )
        }
    }
}

private struct ReorderableAccountRow<Content: View>: View {
    let account: Account
    @ObservedObject var viewModel: UsageViewModel
    let content: Content
    @State private var isDropTarget = false

    init(
        account: Account,
        viewModel: UsageViewModel,
        @ViewBuilder content: () -> Content
    ) {
        self.account = account
        self.viewModel = viewModel
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        if viewModel.canReorderAccount(account) {
            content
                .draggable(account.id) {
                    dragPreview
                }
                .dropDestination(for: String.self) { accountIDs, location in
                    guard let draggedAccountID = accountIDs.first else { return false }
                    return viewModel.reorderAccount(
                        draggedAccountID: draggedAccountID,
                        targetAccountID: account.id,
                        placeAfterTarget: location.y > rowHeight / 2
                    )
                } isTargeted: { isTargeted in
                    isDropTarget = isTargeted
                }
                .background {
                    RoundedRectangle(cornerRadius: Theme.rowCornerRadius)
                        .fill(Theme.controlSelectedSurface.opacity(isDropTarget ? 1 : 0))
                        .padding(.horizontal, 4)
                }
                .animation(.easeOut(duration: 0.12), value: isDropTarget)
        } else {
            content
        }
    }

    private var rowHeight: CGFloat {
        CompactRowLayout.rowHeight(for: account)
    }

    private var dragPreview: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(Theme.brandAccent)
            Text(account.displayName)
                .font(Theme.accountTitleFont)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(Theme.settingsGroupSurface)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Section Headers

struct ProviderSectionHeader: View {
    let provider: AccountProvider
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(provider.displayName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 30)
    }
}

struct SectionHeader: View {
    let originalName: String
    let displayName: String
    let count: Int
    let hasAlias: Bool
    let setAlias: (String?) -> Void

    var body: some View {
        HStack {
            Text("\(displayName.uppercased()) (\(count))")
                .font(Theme.sectionTitleFont)
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12).frame(height: 27)
        .background(Theme.sectionSurface)
        .contentShape(Rectangle())
        .contextMenu {
            Button(hasAlias ? "Edit Workspace Name..." : "Set Workspace Name...") {
                WorkspaceAliasPrompt.edit(
                    workspace: originalName,
                    displayName: displayName,
                    hasAlias: hasAlias,
                    save: setAlias
                )
            }
            if hasAlias {
                Button("Clear Workspace Name") {
                    setAlias(nil)
                }
            }
        }
        .help(hasAlias ? "Original workspace: \(originalName)" : "Set workspace display name")
    }
}

struct PrioritySeparatorHeader: View {
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(Theme.warningText)
            Text("Reset soon · \(count)")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: 24)
    }
}

struct ExhaustedSeparatorHeader: View {
    let count: Int
    let isCollapsed: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 10)
                Text("Waiting for reset · \(count)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 27)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isCollapsed ? "Show waiting accounts" : "Hide waiting accounts")
    }
}

struct FreeWaitingGroupHeader: View {
    let count: Int
    let isCollapsed: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 10)
                Text("Free · \(count)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 27)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isCollapsed ? "Show free accounts" : "Hide free accounts")
    }
}

// MARK: - Expanded Row

struct AccountRow: View {
    let account: Account
    var setAlias: (String?) -> Void = { _ in }
    @State private var hovered = false

    private var exhausted: Bool { account.isWeeklyExhausted }

    var body: some View {
        let windows = account.usageWindows.filter { !exhausted || $0.kind == .weekly }
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 6, height: 6)
                accountIdentity
                Spacer()
                WorkspaceChip(ws: account.displayWorkspaceName, colorKey: account.workspace, compact: false)
            }
            .opacity(exhausted ? 0.5 : 1)

            ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
                BarRow(
                    label: window.label,
                    pct: window.remainingPercent,
                    resetSeconds: window.resetAfterSeconds,
                    style: window.kind == .weekly && exhausted ? .weeklyExhausted : .normal,
                    urgentReset: window.kind == .weekly && account.isWeeklyResetUrgent
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, windows.count > 1 ? 8 : 6)
        .frame(
            maxWidth: .infinity,
            minHeight: 38 + CGFloat(max(0, windows.count - 1)) * 18,
            alignment: .leading
        )
        .background(hovered ? Color.primary.opacity(0.06) : .clear)
        .onHover { hovered = $0 }
        .contextMenu {
            Button(account.hasDisplayAlias ? "Edit Alias..." : "Set Alias...") {
                AccountAliasPrompt.edit(account: account, save: setAlias)
            }
            if account.hasDisplayAlias {
                Button("Clear Alias") {
                    setAlias(nil)
                }
            }
            Divider()
            Button("Copy email") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(account.email, forType: .string)
            }
        }
    }

    @ViewBuilder
    private var accountIdentity: some View {
        if account.hasDisplayAlias {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    PlanBadge(text: account.displayPlanName, compact: false)
                    Text(account.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                        .allowsTightening(true)
                        .truncationMode(.tail)
                }
                Text(account.email)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } else {
            HStack(spacing: 5) {
                Text(account.email)
                    .font(.system(size: 13))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                PlanBadge(text: account.displayPlanName, compact: false)
            }
        }
    }
}

// MARK: - Compact Row

enum CompactRowLayout {
    static let horizontalPadding: CGFloat = 16
    static let actionWidth: CGFloat = 62
    static let bankedResetWidth: CGFloat = 180

    struct Metrics {
        let spacing: CGFloat
        let emailWidth: CGFloat
        let metricWidth: CGFloat
        let sessionResetWidth: CGFloat
        let weeklyResetWidth: CGFloat
        let quotaAreaWidth: CGFloat
        let planCycleWidth: CGFloat
        let actionWidth: CGFloat
        let bankedResetWidth: CGFloat
    }

    static func metrics(totalWidth: CGFloat, includesBankedResets: Bool) -> Metrics {
        let spacing: CGFloat = 12
        let quotaAreaWidth: CGFloat = 212
        let planCycleWidth: CGFloat = 80
        let resetWidth: CGFloat = 82
        let fixedWidth = horizontalPadding * 2 + actionWidth + quotaAreaWidth
            + planCycleWidth + (includesBankedResets ? bankedResetWidth + spacing : 0)
            + spacing * 3
        return Metrics(
            spacing: spacing,
            emailWidth: max(140, totalWidth - fixedWidth),
            metricWidth: quotaAreaWidth - resetWidth - 4,
            sessionResetWidth: resetWidth,
            weeklyResetWidth: resetWidth,
            quotaAreaWidth: quotaAreaWidth,
            planCycleWidth: planCycleWidth,
            actionWidth: actionWidth,
            bankedResetWidth: bankedResetWidth
        )
    }

    static func rowHeight(for account: Account) -> CGFloat {
        let baseHeight: CGFloat = account.fableQuotaWindow == nil ? 66 : 88
        let knownCount = min(max(0, account.availableResetCount ?? 0), account.bankedResetExpirations?.count ?? 0)
        let missing = knownCount < (account.availableResetCount ?? 0)
        return max(baseHeight, 38 + CGFloat(knownCount + (missing ? 1 : 0)) * 14)
    }
}

struct AccountCompactRow: View {
    let account: Account
    let needsRelogin: Bool
    let isRelogging: Bool
    let isReloginBlocked: Bool
    let isSwitchingAccount: Bool
    let isActiveAccount: Bool
    let showsSwitchControls: Bool
    let canSwitchAccount: Bool
    let isSwitchBlocked: Bool
    let isRemoving: Bool
    let isRemoveBlocked: Bool
    let allowsRemoval: Bool
    let allowsAlias: Bool
    let allowsReordering: Bool
    let relogin: () -> Void
    let cancelRelogin: () -> Void
    let switchAccount: () -> Void
    let removeAccount: () -> Void
    let setAlias: (String?) -> Void
    let setPlanRenewalDate: (Date?) -> Void
    @State private var hovered = false
    @State private var isShowingRemovalConfirmation = false

    private var exhausted: Bool { account.isWeeklyExhausted }
    private var rowHeight: CGFloat {
        CompactRowLayout.rowHeight(for: account)
    }
    private var canShowSwapControl: Bool {
        showsSwitchControls
            && canSwitchAccount
            && !isActiveAccount
            && !needsRelogin
            && !isRelogging
    }
    private var isUsingCachedClaudeUsage: Bool {
        account.isClaudeAccount && account.providerStatus == ClaudeAccountStatus.cached.rawValue
    }

    private var rowBackgroundColor: Color {
        if isActiveAccount {
            return Theme.activeRowSurface.opacity(hovered ? 1 : 0.78)
        }
        return hovered ? Theme.rowHoverSurface : .clear
    }

    var body: some View {
        GeometryReader { proxy in
            let layout = CompactRowLayout.metrics(
                totalWidth: proxy.size.width,
                includesBankedResets: true
            )
            let freeResetWidth = layout.quotaAreaWidth
                + layout.planCycleWidth
                + layout.spacing
            HStack(alignment: .center, spacing: layout.spacing) {
                accountIdentityView
                    .frame(width: layout.emailWidth, alignment: .leading)

                if needsRelogin || isRelogging {
                    accountActionControl(width: layout.actionWidth)
                    reconnectStatus(width: freeResetWidth, alignment: .leading)
                } else if account.isFreeWaitingForReset {
                    accountActionControl(width: layout.actionWidth)
                    freeResetStatus(width: freeResetWidth, alignment: .leading)
                } else {
                    accountActionControl(width: layout.actionWidth)
                    usageMetrics(layout: layout)
                }

                if !account.isClaudeAccount {
                    BankedResetListView(
                        count: account.availableResetCount,
                        expirations: account.bankedResetExpirations,
                        width: layout.bankedResetWidth
                    )
                }
            }
            .padding(.horizontal, CompactRowLayout.horizontalPadding)
            .padding(.vertical, 7)
            .frame(width: proxy.size.width, height: rowHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .frame(height: rowHeight)
        .background {
            RoundedRectangle(cornerRadius: Theme.rowCornerRadius, style: .continuous)
                .fill(rowBackgroundColor)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
        .contextMenu {
            if allowsAlias {
                Button(account.hasDisplayAlias ? "Edit Alias..." : "Set Alias...") {
                    AccountAliasPrompt.edit(account: account, save: setAlias)
                }
                if account.hasDisplayAlias {
                    Button("Clear Alias") {
                        setAlias(nil)
                    }
                }
                Divider()
            }
            if account.isClaudeAccount {
                Button(account.planRenewalDate == nil
                    ? "Set Plan Renewal Date..."
                    : "Edit Plan Renewal Date...") {
                    PlanRenewalDatePrompt.edit(
                        account: account,
                        save: setPlanRenewalDate
                    )
                }
                if account.planRenewalDate != nil {
                    Button("Clear Plan Renewal Date") {
                        setPlanRenewalDate(nil)
                    }
                }
                Divider()
            }
            Button("Copy email") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(account.email, forType: .string)
            }
            if allowsRemoval {
                Divider()
                Button("Remove Account...", role: .destructive) {
                    isShowingRemovalConfirmation = true
                }
                .disabled(isRemoveBlocked)
            }
        }
        .alert("Remove this account?", isPresented: $isShowingRemovalConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                removeAccount()
            }
        } message: {
            Text(removalConfirmationMessage)
        }
    }

    private var removalConfirmationMessage: String {
        if account.isClaudeAccount {
            if isActiveAccount {
                return "\(account.email) will be hidden from Headroom. Claude Code stays signed in."
            }
            return "\(account.email) will be removed from Headroom. The active Claude Code account is unchanged."
        }
        return "\(account.email) will be removed from Headroom. A local backup is created before its saved profile is deleted."
    }

    private var accountIdentityView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if isActiveAccount {
                    Circle().fill(Theme.healthyAccent).frame(width: 5, height: 5)
                        .accessibilityLabel("Active account")
                }
                Text(account.email)
                    .font(.system(size: 12, weight: isActiveAccount ? .semibold : .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack(spacing: 6) {
                PlanBadge(text: account.displayPlanName, compact: true)
                if let alias = account.displayAlias {
                    Text(alias).lineLimit(1)
                }
                if let workspace = account.secondaryWorkspaceName {
                    Text(workspace).lineLimit(1)
                }
                if isUsingCachedClaudeUsage { cachedUsageIndicator }
                if hovered && allowsReordering {
                    Image(systemName: "line.3.horizontal")
                        .help("Drag to reorder")
                }
            }
            .font(.system(size: 10, weight: .regular))
            .foregroundStyle(.secondary)
        }
        .help("\(account.email)\n\(account.displayName)\nWorkspace: \(account.displayWorkspaceName)")
    }

    private func quotaMetrics(layout: CompactRowLayout.Metrics) -> some View {
        VStack(spacing: 4) {
            ForEach(Array(account.usageWindows.prefix(2).enumerated()), id: \.offset) { _, window in
                quotaMetricGroup(window, layout: layout)
            }
            if let window = account.fableQuotaWindow {
                fableQuotaMetric(window, layout: layout, width: layout.quotaAreaWidth)
            }
        }
        .frame(width: layout.quotaAreaWidth, alignment: .leading)
    }

    private func usageMetrics(layout: CompactRowLayout.Metrics) -> some View {
        HStack(spacing: layout.spacing) {
            quotaMetrics(layout: layout)
            planCycleText(width: layout.planCycleWidth)
        }
    }

    private func fableQuotaMetric(
        _ window: QuotaWindow,
        layout: CompactRowLayout.Metrics,
        width: CGFloat
    ) -> some View {
        let dimmed = window.isExhausted
        let meterWidth = width - layout.weeklyResetWidth - 2
        return HStack(spacing: 2) {
            FableQuotaMeter(
                pct: window.remainingPercent,
                dimmed: dimmed,
                width: meterWidth
            )
            ResetTimeBadge(
                text: ResetFormatter.compact(seconds: window.resetAfterSeconds),
                color: .secondary,
                width: layout.weeklyResetWidth,
                help: ResetFormatter.fullTooltip(seconds: window.resetAfterSeconds)
            )
        }
        .frame(width: width, alignment: .trailing)
        .opacity(dimmed ? 0.76 : 1)
    }

    private func quotaMetricGroup(
        _ window: QuotaWindow,
        layout: CompactRowLayout.Metrics
    ) -> some View {
        let dimmed = window.isExhausted || (window.kind == .weekly && exhausted)
        let resetWidth = window.kind == .fiveHour
            ? layout.sessionResetWidth
            : layout.weeklyResetWidth

        return HStack(spacing: 2) {
            compactQuota(
                label: window.label,
                pct: window.remainingPercent,
                gray: dimmed,
                width: layout.metricWidth
            )
            quotaResetText(window, width: resetWidth, dimmed: dimmed)
        }
    }

    private func quotaResetText(
        _ window: QuotaWindow,
        width: CGFloat,
        dimmed: Bool
    ) -> some View {
        let urgent = window.kind == .weekly && account.isWeeklyResetUrgent && !dimmed
        let color: Color = urgent ? Theme.warningText : .secondary
        let text = window.kind == .fiveHour
            ? ResetFormatter.timeOnly(seconds: window.resetAfterSeconds)
            : ResetFormatter.compact(seconds: window.resetAfterSeconds)

        return ResetTimeBadge(
            text: text,
            color: color,
            width: width,
            help: "\(window.label) quota resets \(ResetFormatter.fullTooltip(seconds: window.resetAfterSeconds))",
            systemImage: "clock.arrow.circlepath"
        )
        .opacity(dimmed ? 0.76 : 1)
    }

    @ViewBuilder
    private func planCycleText(width: CGFloat) -> some View {
        Group {
            if let date = account.planRenewalDate {
                VStack(alignment: .leading, spacing: 5) {
                    Label(account.planCycleLabel, systemImage: account.planCycleSymbol)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(PlanCycleFormatter.relativeText(for: date))
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                }
                .help(PlanCycleFormatter.tooltip(for: date, label: account.planCycleLabel))
                .accessibilityElement(children: .combine)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Renewal").font(.system(size: 9.5))
                    Text("—").font(.system(size: 11))
                }
                .foregroundStyle(.tertiary)
                .help("Subscription renewal date unavailable")
            }
        }
        .frame(width: width, alignment: .leading)
    }

    @ViewBuilder
    private func accountActionControl(width: CGFloat) -> some View {
        Group {
            if isRelogging {
                Button(action: cancelRelogin) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .help("Cancel")
            } else if isSwitchingAccount {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.65)
            } else if canShowSwapControl {
                SwitchAccountButton(
                    action: switchAccount,
                    helpText: account.isClaudeAccount
                        ? "Switch Claude Code CLI to this account. Claude Desktop uses a separate sign-in."
                        : "Switch to this account in \(account.accountProvider.displayName). This does not use a banked reset."
                )
                    .disabled(isSwitchBlocked)
                    .opacity(isSwitchBlocked ? 0.35 : 1)
            } else if isUsingCachedClaudeUsage {
                cachedUsageIndicator
            } else {
                Color.clear.frame(width: width, height: 1)
            }
        }
        .frame(width: width, height: 28)
    }

    private var cachedUsageIndicator: some View {
        Image(systemName: "clock.arrow.circlepath")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .help("Showing the last successful Claude usage while refresh is paused")
    }
}

struct BankedResetListView: View {
    let count: Int?
    let expirations: [Date]?
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(BankedResetFormatter.compactCountLabel(count))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(count == nil || count == 0 ? Color.secondary : Color.primary)
            if count == nil {
                detailText("Temporarily unavailable")
            } else if let count, count > 0 {
                TimelineView(.periodic(from: .now, by: 60)) { timeline in
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(displayedExpirations.enumerated()), id: \.offset) { _, date in
                            detailText("Expires \(BankedResetFormatter.compactExpiration(date, now: timeline.date))")
                                .background(FastTooltip(text: "Expires \(BankedResetFormatter.expiration(date))"))
                                .accessibilityLabel("Banked reset expires \(BankedResetFormatter.expiration(date))")
                        }
                    }
                }
                if missingExpirationCount > 0 {
                    detailText(displayedExpirations.isEmpty ? "Expiration unavailable" : "+\(missingExpirationCount) expiration unknown")
                }
            }
        }
        .frame(width: width, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityText)
    }

    private var displayedExpirations: [Date] {
        guard let count, count > 0, let expirations else { return [] }
        return Array(expirations.sorted().prefix(count))
    }

    private var missingExpirationCount: Int {
        max(0, (count ?? 0) - displayedExpirations.count)
    }

    private var accessibilityText: String {
        let label = BankedResetFormatter.compactCountLabel(count)
        let dates = displayedExpirations.map { BankedResetFormatter.expiration($0) }.joined(separator: "; ")
        let missing = missingExpirationCount > 0 ? " Some expiration dates are unavailable." : ""
        return "\(label). \(dates.isEmpty ? "" : "Expires: " + dates + ".")\(missing)"
    }

    private func detailText(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 9.5))
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
    }
}

struct ResetTimeBadge: View {
    let text: String
    let color: Color
    let width: CGFloat
    let help: String
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 9, weight: .semibold))
            }
            Text(text)
                .font(Theme.metadataFont)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .foregroundStyle(color)
        .frame(width: width, height: 18, alignment: .leading)
        .help(help)
    }
}

struct PlanBadge: View {
    let text: String?
    var compact = false

    var body: some View {
        if let text {
            Text(text)
                .font(.system(size: compact ? 9.5 : 10, weight: .semibold))
                .foregroundStyle(Theme.workspaceTextColor(for: text))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .padding(.horizontal, compact ? 4 : 5)
                .frame(height: compact ? 17 : 18)
                .background(Theme.workspaceColor(for: text))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .fixedSize(horizontal: true, vertical: false)
                .help("Plan: \(text)")
        }
    }
}

struct ReloginAccountButton: View {
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.clockwise.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.warningText.opacity(hovered ? 1 : 0.88))
                .frame(width: 20, height: 18)
            .background(hovered ? Theme.controlHoverSurface : .clear)
            .clipShape(RoundedRectangle(cornerRadius: Theme.controlCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("Re-login")
    }
}

struct SwitchAccountButton: View {
    let action: () -> Void
    var helpText = "Switch account"
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text("Switch")
                Image(systemName: "arrow.up.right").font(.system(size: 8, weight: .semibold))
            }
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(Theme.brandAccent)
            .frame(width: CompactRowLayout.actionWidth, height: 28)
            .background(hovered ? Theme.controlSelectedSurface : Theme.controlHoverSurface.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(helpText)
        .accessibilityLabel("Switch account")
    }
}

struct CodexIconView: View {
    var foregroundColor: Color = .primary.opacity(0.82)

    private static let image: NSImage = {
        let codexPNG = Bundle.main.url(forResource: "codex", withExtension: "png")
        let image = codexPNG.flatMap { NSImage(contentsOf: $0) }
            ?? NSWorkspace.shared.icon(forFile: "/Applications/ChatGPT.app")
        image.size = NSSize(width: 16, height: 16)
        image.isTemplate = true
        return image
    }()

    var body: some View {
        Image(nsImage: Self.image)
            .resizable()
            .renderingMode(.template)
            .foregroundStyle(foregroundColor)
            .frame(width: 16, height: 16)
    }
}

struct ClaudeIconView: View {
    var foregroundColor: Color = Theme.warningText.opacity(0.9)

    private static let image: NSImage = {
        let repositoryAsset = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Support/ClaudeSpark.png")
        let candidates = [
            Bundle.main.url(forResource: "ClaudeSpark", withExtension: "png"),
            repositoryAsset
        ]
        let image = candidates.compactMap { url in
            url.flatMap { NSImage(contentsOf: $0) }
        }.first ?? NSImage(systemSymbolName: "asterisk", accessibilityDescription: "Claude")!
        image.size = NSSize(width: 16, height: 16)
        image.isTemplate = true
        return image
    }()

    var body: some View {
        Image(nsImage: Self.image)
            .resizable()
            .renderingMode(.template)
            .foregroundStyle(foregroundColor)
            .frame(width: 16, height: 16)
    }
}

struct ProviderIconView: View {
    let provider: AccountProvider
    var usesProviderColor = false

    var body: some View {
        Group {
            switch provider {
            case .codex:
                CodexIconView(
                    foregroundColor: usesProviderColor
                        ? Theme.providerText(for: provider)
                        : .primary.opacity(0.82)
                )
            case .claude:
                ClaudeIconView(
                    foregroundColor: usesProviderColor
                        ? Theme.providerText(for: provider)
                        : Theme.warningText.opacity(0.9)
                )
            }
        }
    }
}

private extension AccountCompactRow {
    func reconnectStatus(width: CGFloat, alignment: Alignment) -> some View {
        Group {
            if isRelogging {
                HStack(spacing: 5) {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.62)
                    Text("Reconnecting...")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 7)
                .frame(height: 20)
                .background(Theme.settingsGroupSurface)
                .clipShape(Capsule())
            } else {
                Button(action: relogin) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 8.5, weight: .bold))
                        Text("Reconnect")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundColor(Theme.warningText)
                    .padding(.horizontal, 8)
                    .frame(height: 20)
                    .background(Theme.warningSurface)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isReloginBlocked)
            }
        }
        .frame(width: width, alignment: alignment)
        .help(isRelogging ? "Reconnecting account" : "Reconnect this account")
    }

    func freeResetStatus(width: CGFloat, alignment: Alignment) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "clock")
                .font(.system(size: 8, weight: .semibold))
                .foregroundColor(.secondary)
            Text("Free resets \(ResetFormatter.formatFreeReturn(seconds: account.freePlanResetSeconds))")
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigit()
                .foregroundColor(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(width: width, alignment: alignment)
        .help("Free quota resets \(ResetFormatter.fullTooltip(seconds: account.freePlanResetSeconds))")
    }

    func compactQuota(label: String, pct: Double, gray: Bool, width: CGFloat) -> some View {
        QuotaMeter(
            label: label,
            pct: pct,
            fill: gray ? Theme.weeklyExhaustedBar : Theme.barColor(for: pct),
            dimmed: gray,
            width: width
        )
    }
}

struct QuotaMeter: View {
    let label: String
    let pct: Double
    let fill: Color
    let dimmed: Bool
    let width: CGFloat

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(Theme.metadataFont)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .allowsTightening(true)
                .frame(width: 20, alignment: .leading)

            MeterTrack(pct: pct, fill: fill, height: 4, minimumFill: 2)
                .frame(maxWidth: .infinity)

            Text(String(format: "%.0f%%", pct))
                .font(Theme.metricFont)
                .monospacedDigit()
                .foregroundColor(dimmed ? .secondary : Theme.statusTextColor(for: pct))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(width: 29, alignment: .trailing)
        }
        .padding(.horizontal, 4)
        .frame(width: width, height: 18, alignment: .leading)
        .opacity(dimmed ? 0.76 : 1)
    }
}

struct FableQuotaMeter: View {
    let pct: Double
    let dimmed: Bool
    let width: CGFloat

    var body: some View {
        HStack(spacing: 6) {
            Text("Fable")
                .font(Theme.metadataFont)
                .foregroundStyle(Theme.providerText(for: .claude))
                .lineLimit(1)
                .frame(width: 34, alignment: .leading)

            MeterTrack(
                pct: pct,
                fill: dimmed ? Theme.weeklyExhaustedBar : Theme.barColor(for: pct),
                height: 4,
                minimumFill: 2
            )
            .frame(maxWidth: .infinity)

            Text(String(format: "%.0f%%", pct))
                .font(Theme.metricFont)
                .monospacedDigit()
                .foregroundStyle(dimmed ? .secondary : Theme.statusTextColor(for: pct))
                .lineLimit(1)
                .frame(width: 34, alignment: .trailing)
        }
        .frame(width: width, height: 18)
        .help("Fable: \(String(format: "%.0f%%", pct)) remaining")
    }
}

struct MeterTrack: View {
    let pct: Double
    let fill: Color
    var height: CGFloat = 4
    var minimumFill: CGFloat = 2

    var body: some View {
        GeometryReader { geo in
            let fillWidth = max(minimumFill, geo.size.width * max(0, min(100, pct)) / 100)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.11))
                    .frame(height: height)
                if pct > 0.001 {
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [fill.opacity(0.68), fill],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: fillWidth, height: height)
                }
            }
            .frame(height: height)
        }
        .frame(height: height)
    }
}

// MARK: - Workspace Chip

struct WorkspaceChip: View {
    let ws: String
    let colorKey: String
    var compact: Bool = false

    init(ws: String, colorKey: String? = nil, compact: Bool = false) {
        self.ws = ws
        self.colorKey = colorKey ?? ws
        self.compact = compact
    }

    var body: some View {
        Text(ws)
            .font(.system(size: compact ? 10 : 11, weight: .medium))
            .foregroundColor(Theme.workspaceTextColor(for: colorKey))
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, compact ? 4 : 6)
            .padding(.vertical, compact ? 1 : 2)
            .background(Theme.workspaceColor(for: colorKey))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .help("Workspace: \(ws)")
    }
}

// MARK: - Horizontal Bar Row

enum BarRowStyle {
    case normal
    case weeklyExhausted
}

struct BarRow: View {
    let label: String
    let pct: Double
    let resetSeconds: Double
    let style: BarRowStyle
    let urgentReset: Bool

    var body: some View {
        let dimmed = style == .weeklyExhausted
        let fillColor: Color = dimmed ? Theme.weeklyExhaustedBar : Theme.barColor(for: pct)
        let textColor: Color = dimmed ? .secondary : Theme.statusTextColor(for: pct)

        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(textColor)
                .frame(width: 28, alignment: .leading)
                .opacity(dimmed ? 0.5 : 1)

            MeterTrack(pct: pct, fill: fillColor, height: 5, minimumFill: 4)
                .frame(height: 5)
                .padding(.vertical, 3)
                .background {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(dimmed ? Theme.metricSurface.opacity(0.7) : Theme.metricSurface)
                }
            .opacity(dimmed ? 0.5 : 1)

            Text(String(format: "%.0f%%", pct))
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundColor(textColor)
                .frame(width: 38, alignment: .trailing)
                .opacity(dimmed ? 0.5 : 1)

            Text("·")
                .foregroundColor(.secondary.opacity(0.5))
                .opacity(dimmed ? 0.5 : 1)

            HStack(spacing: 4) {
                if urgentReset && !dimmed {
                    Image(systemName: "clock")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Theme.warningText)
                }
                Text(dimmed ? ResetFormatter.formatReset(seconds: resetSeconds) : ResetFormatter.format(seconds: resetSeconds))
                    .font(.system(size: 11))
                    .foregroundColor(urgentReset && !dimmed ? Theme.warningText : .secondary)
                    .help(ResetFormatter.fullTooltip(seconds: resetSeconds))
            }
        }
        .frame(height: 14)
    }
}
