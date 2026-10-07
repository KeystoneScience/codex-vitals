import XCTest
import UserNotifications
@testable import CodexVitals

final class AccountListVisibilityTests: XCTestCase {
    func testPersonalWorkspaceDoesNotDuplicatePlanBadge() {
        let account = Account(
            id: "personal", profileKey: "personal", email: "person@example.com",
            workspace: "pro", plan: "pro", sessionFree: 80, weeklyFree: 80,
            sessionResetSeconds: 100, weeklyResetSeconds: 500,
            planRenewalDate: nil, hasError: false, errorMessage: nil
        )
        XCTAssertEqual(account.workspace, "pro")
        XCTAssertNil(account.secondaryWorkspaceName)
        var aliased = account
        aliased.workspaceAlias = "Client lab"
        XCTAssertEqual(aliased.secondaryWorkspaceName, "Client lab")
        aliased.workspaceAlias = " Pro "
        XCTAssertNil(aliased.secondaryWorkspaceName)
    }

    func testRenewalMetadataDoesNotConfuseDiscountAndSubscriptionDates() {
        let cycle = UsageService.planCycle(from: [
            "renews_at": "2026-10-04T10:00:00Z",
            "expires_at": "2026-10-05T10:00:00Z",
            "discount": ["discount_expires_at": "2026-09-05T10:00:00Z"],
        ])
        XCTAssertEqual(cycle?.kind, .renewal)
        XCTAssertEqual(cycle?.date, ISO8601DateFormatter().date(from: "2026-10-04T10:00:00Z"))
        XCTAssertNil(UsageService.planCycle(from: ["discount": ["discount_expires_at": "2026-09-05T10:00:00Z"]]))
    }

    func testSubscriptionExpiryIsNotPresentedAsRenewal() {
        let cycle = UsageService.planCycle(from: ["renews_at": NSNull(), "expires_at": "2026-10-05T10:00:00Z"])
        XCTAssertEqual(cycle?.kind, .expiration)
        var account = makeAccount(id: "expiry", email: "person@example.com", hasError: false)
        account.planRenewalDate = cycle?.date
        account.planCycleKind = cycle?.kind
        XCTAssertEqual(account.planCycleLabel, "Plan ends")
        XCTAssertEqual(account.planCycleSymbol, "calendar")
    }

    func testRenewalCountdownUsesCalendarDaysAndIdentifiesStaleDates() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let formatter = ISO8601DateFormatter()
        let now = formatter.date(from: "2026-09-04T23:55:00Z")!
        XCTAssertEqual(PlanCycleFormatter.relativeText(for: formatter.date(from: "2026-09-05T00:05:00Z")!, now: now, calendar: calendar), "Tomorrow")
        XCTAssertEqual(PlanCycleFormatter.relativeText(for: formatter.date(from: "2026-09-04T00:05:00Z")!, now: now, calendar: calendar), "Today")
        XCTAssertEqual(PlanCycleFormatter.relativeText(for: formatter.date(from: "2026-09-03T23:00:00Z")!, now: now, calendar: calendar), "Date passed")
    }

    func testSnapshotWithoutCycleProvenanceDoesNotClaimBillingRenewal() throws {
        let account = makeAccount(id: "old", email: "person@example.com", hasError: false)
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(account)) as? [String: Any])
        payload.removeValue(forKey: "planCycleKind")
        let decoded = try JSONDecoder().decode(Account.self, from: JSONSerialization.data(withJSONObject: payload))
        XCTAssertEqual(decoded.planCycleLabel, "Cycle ends")
        XCTAssertEqual(decoded.planCycleSymbol, "calendar")
    }

    func testCachedExhaustedClaudeAccountRemainsSwitchable() {
        var account = Account(
            id: "claude-cached", profileKey: nil, email: "person@example.com",
            workspace: "Claude", plan: "Pro", sessionFree: 0, weeklyFree: 0,
            sessionResetSeconds: 100, weeklyResetSeconds: 500,
            planRenewalDate: nil, hasError: false, errorMessage: nil,
            provider: .claude, providerProfileID: "cached", providerStatus: "cached"
        )
        XCTAssertTrue(account.canSwitchProviderAccount)
        account.providerStatus = "reauth_required"
        XCTAssertFalse(account.canSwitchProviderAccount)
    }

    @MainActor
    func testErroredAccountsStayVisible() {
        let healthy = makeAccount(id: "ok@example.com|acc-ok", email: "ok@example.com", hasError: false)
        let errored = makeAccount(id: "bad@example.com|acc-bad", email: "bad@example.com", hasError: true)

        let visible = UsageViewModel.visibleAccounts(from: [healthy, errored])

        XCTAssertEqual(visible.map(\.id), [healthy.id, errored.id])
        XCTAssertEqual(UsageViewModel.errorCount(in: visible), 1)
    }

    @MainActor
    func testAuthenticationFailuresAreSeparateFromConfirmedQuotaResets() {
        let healthy = makeAccount(id: "healthy", email: "healthy@example.com", hasError: false)
        let failed = makeAccount(id: "failed", email: "failed@example.com", hasError: true)
        let exhausted = makeAccount(id: "exhausted", email: "exhausted@example.com", plan: "team",
                                    sessionFree: 0, weeklyFree: 80, sessionResetSeconds: 3600)
        let viewModel = UsageViewModel(resetNotificationService: NoopUsageResetNotifier(), loadPersistedState: false)
        viewModel.accounts = [healthy, failed, exhausted]
        XCTAssertFalse(failed.isWaitingForReset)
        XCTAssertTrue(exhausted.isWaitingForReset)
        XCTAssertEqual(viewModel.attentionAccounts.map(\.id), [failed.id])
        XCTAssertEqual(viewModel.waitingForResetAccounts.map(\.id), [exhausted.id])
        XCTAssertEqual(viewModel.nonFreeExhaustedAccounts.map(\.id), [exhausted.id])
        XCTAssertEqual((viewModel.priorityAccounts + viewModel.normalActiveAccounts).map(\.id), [healthy.id])
    }

    func testDedupIDFallsBackToProfileKeyWhenAccountIDIsMissing() {
        let first = UsageService.dedupID(
            email: "same@example.com",
            accountID: "",
            profileKey: "openai-codex:team:same@example.com"
        )
        let second = UsageService.dedupID(
            email: "same@example.com",
            accountID: "",
            profileKey: "openai-codex:plus:same@example.com"
        )

        XCTAssertNotEqual(first, second)
    }

    func testResolvedAccountIDFallsBackWhenUsageContainsEmptyValue() {
        let accountID = UsageService.resolvedAccountID(
            usage: ["account_id": "  "],
            profile: ["accountId": "account-uuid"]
        )

        XCTAssertEqual(accountID, "account-uuid")
    }

    func testAccountIDDoesNotExposeSyntheticProfileKeyFallback() {
        let profileKey = "openai-codex:team:person@example.com"
        let account = Account(
            id: "person@example.com|\(profileKey)",
            profileKey: profileKey,
            email: "person@example.com",
            workspace: "team",
            plan: "team",
            sessionFree: 80,
            weeklyFree: 80,
            sessionResetSeconds: 0,
            weeklyResetSeconds: 0,
            planRenewalDate: nil,
            hasError: false,
            errorMessage: nil
        )

        XCTAssertEqual(account.accountID, "")
    }

    func testExpiredOrRevokedAuthError() {
        XCTAssertTrue(UsageService.isExpiredOrRevokedAuthError("Expired or revoked"))
        XCTAssertTrue(UsageService.isExpiredOrRevokedAuthError("Token expired"))
        XCTAssertTrue(UsageService.isExpiredOrRevokedAuthError("token expired"))
        XCTAssertTrue(UsageService.isExpiredOrRevokedAuthError("Token invalidated"))
        XCTAssertTrue(UsageService.isExpiredOrRevokedAuthError("Token revoked"))
        XCTAssertTrue(UsageService.isExpiredOrRevokedAuthError("Refresh failed - re-login required"))
        XCTAssertFalse(UsageService.isExpiredOrRevokedAuthError("Workspace deactivated"))
    }

    func testRecoverableAuthErrorIsNotARowSwitchAffordance() {
        XCTAssertTrue(UsageService.isRecoverableAuthError("Token expired"))
        XCTAssertFalse(UsageService.requiresRelogin("token expired"))
        XCTAssertFalse(UsageService.isRecoverableAuthError("Token revoked"))
        XCTAssertFalse(UsageService.isRecoverableAuthError("Token invalidated"))
        XCTAssertFalse(UsageService.isRecoverableAuthError("HTTP 403"))
    }

    func testFreePlanSessionZeroUsesDedicatedResetState() {
        let account = Account(
            id: "free@example.com|acc-free",
            profileKey: "free@example.com",
            email: "free@example.com",
            workspace: "free",
            plan: "free",
            sessionFree: 0,
            weeklyFree: 100,
            sessionResetSeconds: 86_400,
            weeklyResetSeconds: 0,
            planRenewalDate: nil,
            hasError: false,
            errorMessage: nil
        )

        XCTAssertTrue(account.isFreeWaitingForReset)
        XCTAssertFalse(account.isUsableForCodex)
        XCTAssertTrue(account.canSwitchProviderAccount)
        XCTAssertEqual(account.freePlanResetSeconds, 86_400)
    }

    @MainActor
    func testWeeklyOnlyPrimaryWindowDoesNotCreateFakeFiveHourQuota() {
        let windows = UsageService.quotaWindows(from: [
            "primary_window": [
                "limit_window_seconds": 604_800,
                "used_percent": 14,
                "reset_after_seconds": 597_667,
            ],
            "secondary_window": NSNull(),
        ])

        let account = Account(
            id: "weekly@example.com|acc",
            profileKey: "weekly@example.com",
            email: "weekly@example.com",
            workspace: "pro",
            plan: "pro",
            sessionFree: 100,
            weeklyFree: 100,
            sessionResetSeconds: 0,
            weeklyResetSeconds: 0,
            quotaWindows: windows,
            planRenewalDate: nil,
            hasError: false,
            errorMessage: nil
        )

        XCTAssertEqual(windows.map(\.label), ["1w"])
        XCTAssertNil(account.fiveHourQuotaWindow)
        XCTAssertEqual(account.weeklyQuotaWindow?.remainingPercent, 86)
        XCTAssertEqual(UsageViewModel.smartScore(account), 86)
        XCTAssertTrue(account.isUsableForCodex)
    }

    @MainActor
    func testExhaustedWeeklyOnlyWindowUsesWeeklyReset() {
        let windows = UsageService.quotaWindows(from: [
            "primary_window": [
                "limit_window_seconds": 604_800,
                "used_percent": 100,
                "reset_after_seconds": 345_600,
            ],
        ])

        let account = Account(
            id: "exhausted@example.com|acc",
            profileKey: "exhausted@example.com",
            email: "exhausted@example.com",
            workspace: "pro",
            plan: "pro",
            sessionFree: 100,
            weeklyFree: 100,
            sessionResetSeconds: 0,
            weeklyResetSeconds: 0,
            quotaWindows: windows,
            planRenewalDate: nil,
            hasError: false,
            errorMessage: nil
        )

        XCTAssertTrue(account.isWeeklyExhausted)
        XCTAssertFalse(account.isUsableForCodex)
        XCTAssertTrue(account.canSwitchProviderAccount)
        XCTAssertEqual(account.nextWaitingResetSeconds, 345_600)
    }

    func testErroredCodexAccountStillRequiresReconnectBeforeSwitching() {
        let account = makeAccount(
            id: "error@example.com|acc",
            email: "error@example.com",
            hasError: true
        )

        XCTAssertFalse(account.canSwitchProviderAccount)
    }

    func testExhaustedClaudeAccountCanStillBeSwitchedWhenAuthenticated() {
        var account = makeAccount(
            id: "claude-native:exhausted",
            email: "claude@example.com",
            plan: "max",
            sessionFree: 0,
            weeklyFree: 100,
            sessionResetSeconds: 3_600
        )
        account.provider = .claude
        account.providerStatus = "ok"

        XCTAssertFalse(account.isUsableForCodex)
        XCTAssertTrue(account.canSwitchProviderAccount)
    }

    func testResetCreditCountParsesAvailableAndZeroValues() {
        XCTAssertEqual(
            UsageService.availableResetCount(from: [
                "rate_limit_reset_credits": ["available_count": 2]
            ]),
            2
        )
        XCTAssertEqual(
            UsageService.availableResetCount(from: ["available_count": 3]),
            3
        )
        XCTAssertEqual(
            UsageService.availableResetCount(from: ["available_count": NSNumber(value: 0)]),
            0
        )
        XCTAssertNil(UsageService.availableResetCount(from: ["available_count": -1]))
        XCTAssertNil(UsageService.availableResetCount(from: ["error": "HTTP 401"]))
        XCTAssertNil(UsageService.availableResetCount(from: [:]))
    }

    func testBankedResetAvailabilityParsesAndSortsAvailableExpirationDates() throws {
        let availability = try XCTUnwrap(UsageService.bankedResetAvailability(from: [
            "available_count": 2,
            "credits": [
                [
                    "status": "available",
                    "expires_at": "2027-03-21T18:45:00Z",
                ],
                [
                    "status": "redeemed",
                    "expires_at": "2026-09-01T00:00:00Z",
                ],
                [
                    "status": "AVAILABLE",
                    "expires_at": "2026-09-21T23:09:00.000Z",
                ],
            ],
        ]))

        XCTAssertEqual(availability.count, 2)
        XCTAssertEqual(
            availability.expirations,
            [
                ISO8601DateFormatter().date(from: "2026-09-21T23:09:00Z")!,
                ISO8601DateFormatter().date(from: "2027-03-21T18:45:00Z")!,
            ]
        )
    }

    func testNestedUsageCountMarksExpirationDetailsUnavailable() throws {
        let availability = try XCTUnwrap(UsageService.bankedResetAvailability(from: [
            "rate_limit_reset_credits": ["available_count": 1]
        ]))

        XCTAssertEqual(availability.count, 1)
        XCTAssertNil(availability.expirations)
    }

    func testZeroBankedResetsHasAnEmptyExpirationList() throws {
        let availability = try XCTUnwrap(UsageService.bankedResetAvailability(from: [
            "available_count": 0
        ]))

        XCTAssertEqual(availability.count, 0)
        XCTAssertEqual(availability.expirations, [])
    }

    func testBankedResetCountSurvivesSnapshotRoundTrip() throws {
        var account = makeAccount(
            id: "resets@example.com|acc",
            email: "resets@example.com",
            hasError: false
        )
        account.availableResetCount = 2
        account.bankedResetExpirations = [
            Date(timeIntervalSince1970: 1_800_000_000),
            Date(timeIntervalSince1970: 1_900_000_000),
        ]

        let data = try JSONEncoder().encode(account)
        let decoded = try JSONDecoder().decode(Account.self, from: data)

        XCTAssertEqual(decoded.availableResetCount, 2)
        XCTAssertEqual(decoded.bankedResetExpirations, account.bankedResetExpirations)
    }

    func testBankedResetFormatterIncludesExactLocalTimeAndZone() {
        let date = ISO8601DateFormatter().date(from: "2027-03-21T18:45:00Z")!
        let denver = TimeZone(identifier: "America/Denver")!

        XCTAssertEqual(
            BankedResetFormatter.expiration(date, timeZone: denver),
            "Mar 21, 2027 at 12:45 PM MDT"
        )
        XCTAssertEqual(BankedResetFormatter.countLabel(0), "0 BANKED RESETS")
        XCTAssertEqual(BankedResetFormatter.countLabel(1), "1 BANKED RESET")
        XCTAssertEqual(BankedResetFormatter.countLabel(2), "2 BANKED RESETS")
    }

    func testResetTimesUseAMPMAtMidnightNoonAndAfternoon() {
        let zone = TimeZone(secondsFromGMT: 0)!
        for (timestamp, expected) in [
            ("2026-09-18T00:05:00Z", "12:05 AM"),
            ("2026-09-18T09:07:00Z", "9:07 AM"),
            ("2026-09-18T12:00:00Z", "12:00 PM"),
            ("2026-09-18T23:09:00Z", "11:09 PM"),
        ] {
            let date = ISO8601DateFormatter().date(from: timestamp)!
            XCTAssertEqual(ResetFormatter.timeText(date, timeZone: zone), expected)
        }
    }

    func testCompactBankedExpirationShowsLocalTimeWithinSevenDays() {
        let now = ISO8601DateFormatter().date(from: "2026-09-20T06:00:00Z")!
        let denver = TimeZone(identifier: "America/Denver")!
        for (timestamp, expected) in [
            ("2026-09-20T06:00:00Z", "Sep 20 at 12:00 AM"),
            ("2026-09-22T05:09:00Z", "Sep 21 at 11:09 PM"),
            ("2026-09-27T06:00:00Z", "Sep 27 at 12:00 AM"),
            ("2026-09-27T06:00:01Z", "Sep 27"),
            ("2026-10-18T16:30:00Z", "Oct 18"),
        ] {
            let date = ISO8601DateFormatter().date(from: timestamp)!
            XCTAssertEqual(BankedResetFormatter.compactExpiration(date, now: now, timeZone: denver), expected)
        }
    }

    func testCompactBankedExpirationOmitsYearAcrossNewYear() {
        let now = ISO8601DateFormatter().date(from: "2026-12-30T12:00:00Z")!
        let date = ISO8601DateFormatter().date(from: "2027-01-01T18:45:00Z")!
        let zone = TimeZone(secondsFromGMT: 0)!
        XCTAssertEqual(
            BankedResetFormatter.compactExpiration(date, now: now, timeZone: zone),
            "Jan 1 at 6:45 PM"
        )
        XCTAssertEqual(BankedResetFormatter.expiration(date, timeZone: zone), "Jan 1, 2027 at 6:45 PM GMT")
    }

    func testResetTooltipIncludesYearMinuteAndLocalTimeZone() {
        let date = ISO8601DateFormatter().date(from: "2026-09-21T23:09:00Z")!
        let zone = TimeZone(identifier: "America/Los_Angeles")!
        XCTAssertEqual(
            ResetFormatter.fullTooltip(date: date, timeZone: zone),
            "Monday, September 21, 2026 at 4:09 PM PDT"
        )
        XCTAssertEqual(
            BankedResetFormatter.expiration(date, timeZone: zone),
            "Sep 21, 2026 at 4:09 PM PDT"
        )
    }

    @MainActor
    func testRefreshPreservesMatchingRecentBankedResetDetails() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var previous = makeAccount(
            id: "resets@example.com|acc",
            email: "resets@example.com",
            hasError: false
        )
        previous.availableResetCount = 2
        previous.bankedResetExpirations = [
            now.addingTimeInterval(-60),
            now.addingTimeInterval(3_600),
        ]
        var current = previous
        current.bankedResetExpirations = nil

        let merged = UsageViewModel.preservingBankedResetDetails(
            in: [current],
            from: [previous],
            previousFetchedAt: now.addingTimeInterval(-300),
            now: now
        )

        XCTAssertEqual(merged.first?.availableResetCount, 2)
        XCTAssertEqual(merged.first?.bankedResetExpirations, [now.addingTimeInterval(3_600)])
    }

    @MainActor
    func testRefreshUsesRecentCachedCountWhenLookupTemporarilyFails() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var previous = makeAccount(
            id: "resets@example.com|acc",
            email: "resets@example.com",
            hasError: false
        )
        previous.availableResetCount = 2
        previous.bankedResetExpirations = [
            now.addingTimeInterval(-60),
            now.addingTimeInterval(3_600),
        ]
        var current = previous
        current.availableResetCount = nil
        current.bankedResetExpirations = nil

        let merged = UsageViewModel.preservingBankedResetDetails(
            in: [current],
            from: [previous],
            previousFetchedAt: now.addingTimeInterval(-300),
            now: now
        )

        XCTAssertEqual(merged.first?.availableResetCount, 1)
        XCTAssertEqual(merged.first?.bankedResetExpirations, [now.addingTimeInterval(3_600)])
    }

    func testQuotaWindowsUseDurationInsteadOfPrimarySecondaryPosition() {
        let windows = UsageService.quotaWindows(from: [
            "primary_window": [
                "limit_window_seconds": 604_800.0,
                "used_percent": 30.0,
                "reset_after_seconds": 500_000.0,
            ],
            "secondary_window": [
                "limit_window_seconds": 18_000.0,
                "used_percent": 20.0,
                "reset_after_seconds": 10_000.0,
            ],
        ])

        XCTAssertEqual(windows.map(\.label), ["5h", "1w"])
        XCTAssertEqual(windows.map(\.remainingPercent), [80, 70])
    }

    func testUnknownQuotaDurationUsesItsActualPeriodLabel() {
        let windows = UsageService.quotaWindows(from: [
            "primary_window": [
                "limit_window_seconds": 86_400,
                "used_percent": 25,
                "reset_after_seconds": 40_000,
            ],
        ])

        XCTAssertEqual(windows.map(\.label), ["1d"])
        XCTAssertEqual(windows.first?.kind, .custom)
    }

    func testLegacySnapshotWithoutQuotaWindowsKeepsFiveHourAndWeeklyWindows() throws {
        let account = makeAccount(
            id: "legacy@example.com|acc",
            email: "legacy@example.com",
            plan: "plus",
            sessionFree: 75,
            weeklyFree: 60,
            sessionResetSeconds: 1_000,
            weeklyResetSeconds: 500_000
        )

        let data = try JSONEncoder().encode(account)
        let decoded = try JSONDecoder().decode(Account.self, from: data)

        XCTAssertNil(decoded.quotaWindows)
        XCTAssertEqual(decoded.usageWindows.map(\.label), ["5h", "1w"])
        XCTAssertEqual(decoded.limitingQuotaRemaining, 60)
    }

    func testLegacySnapshotWithoutFableWindowStillDecodes() throws {
        let account = makeAccount(
            id: "legacy@example.com|acc",
            email: "legacy@example.com",
            plan: "plus",
            sessionFree: 75,
            weeklyFree: 60,
            sessionResetSeconds: 1_000,
            weeklyResetSeconds: 500_000
        )
        let encoded = try JSONEncoder().encode(account)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "fableQuotaWindow")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(Account.self, from: legacyData)

        XCTAssertNil(decoded.fableQuotaWindow)
        XCTAssertEqual(decoded.usageWindows.map(\.label), ["5h", "1w"])
    }

    func testExhaustedFableWindowDoesNotDisableClaudeAccount() {
        var account = makeAccount(
            id: "claude-native:account-1",
            email: "claude@example.com",
            plan: "claude",
            sessionFree: 80,
            weeklyFree: 70,
            sessionResetSeconds: 1_000,
            weeklyResetSeconds: 500_000
        )
        account.provider = .claude
        account.providerStatus = "ok"
        account.fableQuotaWindow = QuotaWindow(
            limitSeconds: QuotaWindow.weeklySeconds,
            remainingPercent: 0,
            resetAfterSeconds: 500_000
        )

        XCTAssertTrue(account.isUsableForCodex)
        XCTAssertTrue(account.canSwitchProviderAccount)
        XCTAssertFalse(account.isWeeklyExhausted)
        XCTAssertEqual(account.limitingQuotaRemaining, 70)
    }

    func testPlanDisplayNameNormalizesCommonPlans() {
        XCTAssertEqual(PlanDisplayFormatter.badgeText(for: "pro"), "Pro")
        XCTAssertEqual(PlanDisplayFormatter.badgeText(for: "plus"), "Plus")
        XCTAssertEqual(PlanDisplayFormatter.badgeText(for: "pro_lite"), "Pro Lite")
        XCTAssertEqual(PlanDisplayFormatter.badgeText(for: "pro-lite"), "Pro Lite")
        XCTAssertEqual(PlanDisplayFormatter.badgeText(for: "free"), "Free")
        XCTAssertNil(PlanDisplayFormatter.badgeText(for: "?"))
    }

    func testAutoRefreshIntervalOptionsUseExpectedDefaults() {
        let previousValue = UserDefaults.standard.object(forKey: AutoRefreshInterval.userDefaultsKey)
        defer {
            if let previousValue {
                UserDefaults.standard.set(previousValue, forKey: AutoRefreshInterval.userDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: AutoRefreshInterval.userDefaultsKey)
            }
        }

        UserDefaults.standard.removeObject(forKey: AutoRefreshInterval.userDefaultsKey)

        XCTAssertEqual(AutoRefreshInterval.stored, .tenMinutes)
        XCTAssertNil(AutoRefreshInterval.off.seconds)
        XCTAssertEqual(AutoRefreshInterval.fiveMinutes.seconds, 300)
        XCTAssertEqual(AutoRefreshInterval.tenMinutes.displayName, "10 min")

        AutoRefreshInterval.thirtyMinutes.save()
        XCTAssertEqual(AutoRefreshInterval.stored, .thirtyMinutes)
    }

    func testAccountDisplayPlanNameIsIndependentOfAlias() {
        var account = makeAccount(
            id: "person@example.com|acc",
            email: "person@example.com",
            plan: "plus",
            sessionFree: 80,
            weeklyFree: 80,
            sessionResetSeconds: 0
        )
        account.alias = "Lab Member 01"

        XCTAssertEqual(account.displayName, "Lab Member 01")
        XCTAssertEqual(account.displayPlanName, "Plus")
    }

    func testClaudeDisplayPlanNameShowsKnownPlanButHidesProviderPlaceholder() {
        var account = Account(
            id: "claude-native:1",
            profileKey: nil,
            email: "claude@example.com",
            workspace: "Claude",
            plan: "Max 5x",
            sessionFree: 80,
            weeklyFree: 80,
            sessionResetSeconds: 0,
            weeklyResetSeconds: 0,
            hasError: false,
            errorMessage: nil,
            provider: .claude
        )

        XCTAssertEqual(account.displayPlanName, "Max 5x")

        account = Account(
            id: "claude-native:2",
            profileKey: nil,
            email: "fallback@example.com",
            workspace: "Claude",
            plan: "Claude",
            sessionFree: 80,
            weeklyFree: 80,
            sessionResetSeconds: 0,
            weeklyResetSeconds: 0,
            hasError: false,
            errorMessage: nil,
            provider: .claude
        )
        XCTAssertNil(account.displayPlanName)
    }

    func testFreeResetFormatterIncludesReturnContext() {
        let text = ResetFormatter.formatFreeReturn(seconds: 60)

        XCTAssertNotEqual(text, ResetFormatter.timeOnly(seconds: 60))
        XCTAssertTrue(text.contains(" "))
    }

    func testCompactResetDateUsesUnambiguousMonthName() throws {
        let calendar = Calendar.current
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 2)))
        let sameYear = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 7)))
        let nextYear = try XCTUnwrap(calendar.date(from: DateComponents(year: 2027, month: 9, day: 7)))

        XCTAssertEqual(ResetFormatter.dateString(target: sameYear, now: now), "Sep 7")
        XCTAssertEqual(ResetFormatter.dateString(target: nextYear, now: now), "Sep 7, 2027")
    }

    @MainActor
    func testAccountDisplayAliasIsPresentationOnly() {
        var account = makeAccount(id: "person@example.com|acc", email: "person@example.com", hasError: false)
        account.alias = "  Lab Member 01  "

        XCTAssertEqual(account.displayAlias, "Lab Member 01")
        XCTAssertEqual(account.displayName, "Lab Member 01")
        XCTAssertEqual(account.email, "person@example.com")
        XCTAssertEqual(account.accountID, "acc")
    }

    @MainActor
    func testAccountSearchMatchesAliasAndEmail() {
        var account = makeAccount(id: "person@example.com|acc", email: "person@example.com", hasError: false)
        account.alias = "Lab Member 01"

        XCTAssertTrue(UsageViewModel.matchesSearch(account, searchText: "member 01"))
        XCTAssertTrue(UsageViewModel.matchesSearch(account, searchText: "person@example"))
        XCTAssertFalse(UsageViewModel.matchesSearch(account, searchText: "unrelated"))
    }

    @MainActor
    func testWorkspaceDisplayAliasIsSearchableWithoutChangingOriginalWorkspace() {
        var account = makeAccount(id: "person@example.com|acc", email: "person@example.com", hasError: false)
        account.workspaceAlias = "Lab Pool A"

        XCTAssertEqual(account.workspace, "team")
        XCTAssertEqual(account.displayWorkspaceName, "Lab Pool A")
        XCTAssertTrue(account.hasDisplayWorkspaceAlias)
        XCTAssertTrue(UsageViewModel.matchesSearch(account, searchText: "pool a"))
        XCTAssertTrue(UsageViewModel.matchesSearch(account, searchText: "team"))
    }

    @MainActor
    func testProviderGroupingKeepsCodexBeforeClaude() {
        let codex = makeAccount(id: "codex@example.com|acc", email: "codex@example.com", hasError: false)
        var claude = makeAccount(id: "claude-native:1", email: "claude@example.com", hasError: false)
        claude.provider = .claude

        let sections = UsageViewModel.groupByProvider([claude, codex])

        XCTAssertEqual(sections.map(\.provider), [.codex, .claude])
        XCTAssertEqual(sections.map { $0.accounts.map(\.id) }, [[codex.id], [claude.id]])
    }

    @MainActor
    func testWaitingForResetSortsPaidBeforeFreeThenSoonestReset() {
        let freeSoon = makeAccount(
            id: "free-soon@example.com|acc",
            email: "free-soon@example.com",
            plan: "free",
            sessionFree: 0,
            weeklyFree: 100,
            sessionResetSeconds: 60
        )
        let plusLater = makeAccount(
            id: "plus-later@example.com|acc",
            email: "plus-later@example.com",
            plan: "plus",
            sessionFree: 0,
            weeklyFree: 100,
            sessionResetSeconds: 600
        )
        let plusSoon = makeAccount(
            id: "plus-soon@example.com|acc",
            email: "plus-soon@example.com",
            plan: "plus",
            sessionFree: 0,
            weeklyFree: 100,
            sessionResetSeconds: 120
        )

        let sorted = UsageViewModel.sortedExhaustedAccounts([freeSoon, plusLater, plusSoon])

        XCTAssertEqual(sorted.map(\.email), [
            "plus-soon@example.com",
            "plus-later@example.com",
            "free-soon@example.com"
        ])
    }

    func testAccountSortModeMigratesAndPersistsLegacyManualSetting() {
        let suiteName = "AccountSortModeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: AccountSortMode.legacyManualOrderKey)
        XCTAssertEqual(AccountSortMode.stored(in: defaults), .manual)

        AccountSortMode.usage.save(in: defaults)
        XCTAssertEqual(AccountSortMode.stored(in: defaults), .usage)
        XCTAssertFalse(defaults.bool(forKey: AccountSortMode.legacyManualOrderKey))
    }

    @MainActor
    func testDragReorderPlacesAccountBeforeOrAfterTarget() {
        let ids = ["a", "b", "c", "d"]

        XCTAssertEqual(
            UsageViewModel.reorderedIDs(
                ids,
                moving: "d",
                relativeTo: "b",
                placeAfterTarget: false
            ),
            ["a", "d", "b", "c"]
        )
        XCTAssertEqual(
            UsageViewModel.reorderedIDs(
                ids,
                moving: "a",
                relativeTo: "c",
                placeAfterTarget: true
            ),
            ["b", "c", "a", "d"]
        )
    }

    private func makeAccount(id: String, email: String, hasError: Bool) -> Account {
        Account(
            id: id,
            profileKey: id,
            email: email,
            workspace: hasError ? "?" : "team",
            plan: hasError ? "?" : "team",
            sessionFree: hasError ? 0 : 80,
            weeklyFree: hasError ? 0 : 80,
            sessionResetSeconds: 0,
            weeklyResetSeconds: 0,
            planRenewalDate: nil,
            hasError: hasError,
            errorMessage: hasError ? "Codex usage unavailable" : nil
        )
    }

    private func makeAccount(
        id: String,
        email: String,
        plan: String,
        sessionFree: Double,
        weeklyFree: Double,
        sessionResetSeconds: Double,
        weeklyResetSeconds: Double = 0
    ) -> Account {
        Account(
            id: id,
            profileKey: id,
            email: email,
            workspace: plan,
            plan: plan,
            sessionFree: sessionFree,
            weeklyFree: weeklyFree,
            sessionResetSeconds: sessionResetSeconds,
            weeklyResetSeconds: weeklyResetSeconds,
            planRenewalDate: nil,
            hasError: false,
            errorMessage: nil
        )
    }
}

private final class NoopUsageResetNotifier: UsageResetNotifying {
    func requestAuthorization() async -> Bool { false }
    func authorizationStatus() async -> UNAuthorizationStatus { .denied }
    func deliver(events: [UsageResetEvent]) async {}
}
