//
// Copyright 2021 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalCoreKit
import SignalMessaging
import SignalUI

extension ChatListViewController {

    public static let clearSearch = Notification.Name("clearSearch")

    public func observeNotifications() {
        AssertIsOnMainThread()

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(signalAccountsDidChange),
                                               name: .OWSContactsManagerSignalAccountsDidChange,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(applicationWillEnterForeground),
                                               name: .OWSApplicationWillEnterForeground,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(applicationDidBecomeActive),
                                               name: .OWSApplicationDidBecomeActive,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(applicationWillResignActive),
                                               name: .OWSApplicationWillResignActive,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(registrationStateDidChange),
                                               name: .registrationStateDidChange,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(outageStateDidChange),
                                               name: OutageDetection.outageStateDidChange,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(localProfileDidChange),
                                               name: .localProfileDidChange,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(profileWhitelistDidChange),
                                               name: .profileWhitelistDidChange,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(otherProfileDidChange(_:)),
                                               name: .otherUsersProfileDidChange,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(appExpiryDidChange),
                                               name: AppExpiryImpl.AppExpiryDidChange,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(preferContactAvatarsPreferenceDidChange),
                                               name: SSKPreferences.preferContactAvatarsPreferenceDidChange,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(blockListDidChange),
                                               name: BlockingManager.blockListDidChange,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(clearSearch),
                                               name: ChatListViewController.clearSearch,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(clearSearch),
                                               name: ReactionManager.localUserReacted,
                                               object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(localUsernameStateDidChange),
            name: Usernames.localUsernameStateChangedNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(showBadgeSheetIfNecessary),
            name: SubscriptionReceiptCredentialRedemptionOperation.DidSucceedNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(showBadgeSheetIfNecessary),
            name: SubscriptionReceiptCredentialRedemptionOperation.DidFailNotification,
            object: nil
        )

        contactsViewHelper.addObserver(self)

        databaseStorage.appendDatabaseChangeDelegate(self)
    }

    // MARK: -

    @objc
    private func preferContactAvatarsPreferenceDidChange(_ notification: NSNotification) {
        AssertIsOnMainThread()

        reloadTableDataAndResetCellContentCache()
    }

    @objc
    private func signalAccountsDidChange(_ notification: NSNotification) {
        AssertIsOnMainThread()

        // This is wasteful but this event is very rare.
        reloadTableDataAndResetCellContentCache()
    }

    @objc
    private func registrationStateDidChange(_ notification: NSNotification) {
        AssertIsOnMainThread()

        updateReminderViews()
    }

    @objc
    private func outageStateDidChange(_ notification: NSNotification) {
        AssertIsOnMainThread()

        updateReminderViews()
    }

    @objc
    private func localProfileDidChange(_ notification: NSNotification) {
        AssertIsOnMainThread()

        showBadgeSheetIfNecessary()
    }

    @objc
    private func appExpiryDidChange(_ notification: NSNotification) {
        AssertIsOnMainThread()

        updateReminderViews()
    }

    @objc
    private func applicationWillEnterForeground(_ notification: NSNotification) {
        AssertIsOnMainThread()

        loadCoordinator.applicationWillEnterForeground()
    }

    @objc
    private func applicationDidBecomeActive(_ notification: NSNotification) {
        AssertIsOnMainThread()

        updateShouldBeUpdatingView()

        if !ExperienceUpgradeManager.presentNext(fromViewController: self) {
            presentGetStartedBannerIfNecessary()
        }
    }

    @objc
    private func applicationWillResignActive(_ notification: NSNotification) {
        AssertIsOnMainThread()

        updateShouldBeUpdatingView()
    }

    @objc
    private func profileWhitelistDidChange(_ notification: NSNotification) {
        AssertIsOnMainThread()

        // If profile whitelist just changed, we need to update the associated
        // thread to reflect the latest message request state.
        let address: SignalServiceAddress? = notification.userInfo?[kNSNotificationKey_ProfileAddress] as? SignalServiceAddress
        let groupId: Data? = notification.userInfo?[kNSNotificationKey_ProfileGroupId] as? Data

        let changedThreadId: String? = databaseStorage.read { transaction in
            if let address = address,
               address.isValid {
                return TSContactThread.getWithContactAddress(address, transaction: transaction)?.uniqueId
            } else if let groupId = groupId {
                return TSGroupThread.threadId(forGroupId: groupId, transaction: transaction)
            } else {
                return nil
            }
        }

        if let threadId = changedThreadId {
            Logger.info("[Scroll Perf Debug] Scheduling load for threadId \(threadId) because whitelist did change.")
            self.loadCoordinator.scheduleLoad(updatedThreadIds: Set([threadId]))
        }
    }

    @objc
    private func otherProfileDidChange(_ notification: NSNotification) {
        AssertIsOnMainThread()

        let address = notification.userInfo?[kNSNotificationKey_ProfileAddress] as? SignalServiceAddress

        let changedThreadId: String? = databaseStorage.read { readTx in
            if let address = address, address.isValid {
                return TSContactThread.getWithContactAddress(address, transaction: readTx)?.uniqueId
            } else {
                return nil
            }
        }

        if let changedThreadId = changedThreadId {
            if DebugFlags.internalLogging {
                Logger.info("[Scroll Perf Debug] Scheduling load for threadId \(changedThreadId) because other profile did change.")
            }
            self.loadCoordinator.scheduleLoad(updatedThreadIds: Set([changedThreadId]))
        }
    }

    @objc
    private func blockListDidChange(_ notification: NSNotification) {
        AssertIsOnMainThread()

        // This is wasteful but this event is very rare.
        reloadTableDataAndResetCellContentCache()
    }

    @objc
    private func clearSearch(_ notification: NSNotification) {
        DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 0.1) { [weak self] in
            if let self = self {
                self.searchBar.delegate?.searchBarCancelButtonClicked?(self.searchBar)
            }
        }
    }

    @objc
    private func localUsernameStateDidChange() {
        updateReminderViews()
    }
}

// MARK: - Notifications

extension ChatListViewController: DatabaseChangeDelegate {

    public func databaseChangesDidUpdate(databaseChanges: DatabaseChanges) {
        AssertIsOnMainThread()

        if databaseChanges.didUpdateModel(collection: TSPaymentModel.collection()) {
            if DebugFlags.internalLogging {
                Logger.info("[Scroll Perf Debug] TSPaymentModel did update")
            }
            updateUnreadPaymentNotificationsCountWithSneakyTransaction()
        }

        if !databaseChanges.threadUniqueIdsForChatListUpdate.isEmpty {
            if DebugFlags.internalLogging {
                Logger.info("[Scroll Perf Debug] Scheduling load for threadIds (count \(databaseChanges.threadUniqueIdsForChatListUpdate.count): \(databaseChanges.threadUniqueIdsForChatListUpdate)")
            }
            self.loadCoordinator.scheduleLoad(updatedThreadIds: databaseChanges.threadUniqueIdsForChatListUpdate)
        }
    }

    public func databaseChangesDidUpdateExternally() {
        AssertIsOnMainThread()

        Logger.verbose("")

        // External database modifications can't be converted into incremental updates,
        // so rebuild everything.  This is expensive and usually isn't necessary, but
        // there's no alternative.
        self.loadCoordinator.scheduleHardReset()
    }

    public func databaseChangesDidReset() {
        AssertIsOnMainThread()

        // This should only happen if we need to recover from an error in the
        // database change observation pipeline.  This should never occur,
        // but when it does we need to rebuild everything.  This is expensive,
        // but there's no alternative.
        self.loadCoordinator.scheduleHardReset()
    }
}

extension ChatListViewController: ContactsViewHelperObserver {
    public func contactsViewHelperDidUpdateContacts() {
        if !firstConversationCueView.isHidden {
            updateFirstConversationLabel()
        }
    }
}
