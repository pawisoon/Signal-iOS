//
// Copyright 2021 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import AVFoundation
import Foundation
import SignalMessaging
import SignalUI

extension ConversationViewController: AttachmentApprovalViewControllerDelegate {

    public func attachmentApproval(_ attachmentApproval: AttachmentApprovalViewController,
                                   didApproveAttachments attachments: [SignalAttachment],
                                   messageBody: MessageBody?) {
        AssertIsOnMainThread()

        guard hasViewWillAppearEverBegun else {
            owsFailDebug("InputToolbar not yet ready.")
            return
        }
        guard let inputToolbar = inputToolbar else {
            owsFailDebug("Missing inputToolbar.")
            return
        }

        tryToSendAttachments(attachments, messageBody: messageBody)
        inputToolbar.clearTextMessage(animated: false)
        dismiss(animated: true, completion: nil)
        // We always want to scroll to the bottom of the conversation after the local user
        // sends a message.
        scrollToBottomOfConversation(animated: false)
    }

    public func attachmentApprovalDidCancel(_ attachmentApproval: AttachmentApprovalViewController) {
        dismiss(animated: true, completion: nil)
    }

    public func attachmentApproval(_ attachmentApproval: AttachmentApprovalViewController,
                                   didChangeMessageBody newMessageBody: MessageBody?) {
        AssertIsOnMainThread()

        guard hasViewWillAppearEverBegun else {
            owsFailDebug("InputToolbar not yet ready.")
            return
        }
        guard let inputToolbar = inputToolbar else {
            owsFailDebug("Missing inputToolbar.")
            return
        }
        inputToolbar.setMessageBody(newMessageBody, animated: false)
    }

    public func attachmentApproval(_ attachmentApproval: AttachmentApprovalViewController, didRemoveAttachment attachment: SignalAttachment) { }

    public func attachmentApprovalDidTapAddMore(_ attachmentApproval: AttachmentApprovalViewController) { }

    public func attachmentApproval(_ attachmentApproval: AttachmentApprovalViewController, didChangeViewOnceState isViewOnce: Bool) { }
}

extension ConversationViewController: AttachmentApprovalViewControllerDataSource {

    public var attachmentApprovalTextInputContextIdentifier: String? { textInputContextIdentifier }

    public var attachmentApprovalRecipientNames: [String] {
        [ Self.contactsManager.displayNameWithSneakyTransaction(thread: thread) ]
    }

    public func attachmentApprovalMentionableAddresses(tx: DBReadTransaction) -> [SignalServiceAddress] {
        supportsMentions ? thread.recipientAddresses(with: SDSDB.shimOnlyBridge(tx)) : []
    }

    public func attachmentApprovalMentionCacheInvalidationKey() -> String {
        return thread.uniqueId
    }
}

// MARK: -

extension ConversationViewController: ContactPickerDelegate {

    public func contactPickerDidCancel(_: ContactPickerViewController) {
        dismiss(animated: true, completion: nil)
    }

    public func contactPicker(_ contactPicker: ContactPickerViewController, didSelect contact: Contact) {
        AssertIsOnMainThread()
        owsAssertDebug(contact.cnContactId != nil)

        guard let cnContact = contactsManager.cnContact(withId: contact.cnContactId) else {
            owsFailDebug("Could not load system contact.")
            return
        }

        Logger.verbose("Contact: \(contact)")

        let contactShareRecord = OWSContact(cnContact: cnContact)
        var isProfileAvatar = false
        var avatarImageData: Data? = contactsManager.avatarData(forCNContactId: cnContact.identifier)
        for address in contact.registeredAddresses() {
            if avatarImageData != nil {
                break
            }
            avatarImageData = contactsManagerImpl.profileImageDataForAddress(withSneakyTransaction: address)
            if avatarImageData != nil {
                isProfileAvatar = true
            }
        }
        contactShareRecord.isProfileAvatar = isProfileAvatar

        let contactShare = ContactShareViewModel(contactShareRecord: contactShareRecord,
                                                 avatarImageData: avatarImageData)

        let approveContactShare = ContactShareViewController(contactShare: contactShare)
        approveContactShare.shareDelegate = self
        guard let navigationController = contactPicker.navigationController else {
            owsFailDebug("Missing contactsPicker.navigationController.")
            return
        }
        navigationController.pushViewController(approveContactShare, animated: true)
    }

    public func contactPicker(_: ContactPickerViewController, didSelectMultiple contacts: [Contact]) {
        owsFailDebug("Multiple selection not allowed.")
        dismiss(animated: true, completion: nil)
    }

    public func contactPicker(_: ContactPickerViewController, shouldSelect contact: Contact) -> Bool {
        // Any reason to preclude contacts?
        return true
    }
}

// MARK: -

extension ConversationViewController: ContactShareViewControllerDelegate {

    public func contactShareViewController(_ viewController: ContactShareViewController, didApproveContactShare contactShare:
        ContactShareViewModel) {
        dismiss(animated: true) {
            self.send(contactShare: contactShare)
        }
    }

    public func contactShareViewControllerDidCancel(_ viewController: ContactShareViewController) {
        dismiss(animated: true, completion: nil)
    }

    public func titleForContactShareViewController(_ viewController: ContactShareViewController) -> String? {
        return nil
    }

    public func recipientsDescriptionForContactShareViewController(_ viewController: ContactShareViewController) -> String? {
        return databaseStorage.read { transaction in
            Self.contactsManager.displayName(for: self.thread, transaction: transaction)
        }
    }

    public func approvalModeForContactShareViewController(_ viewController: ContactShareViewController) -> ApprovalMode {
        return .send
    }

    private func send(contactShare: ContactShareViewModel) {
        Logger.verbose("Sending contact share.")

        let thread = self.thread
        Self.databaseStorage.asyncWrite { transaction in
            let didAddToProfileWhitelist = ThreadUtil.addThreadToProfileWhitelistIfEmptyOrPendingRequest(
                thread,
                setDefaultTimerIfNecessary: true,
                tx: transaction
            )

            // TODO - in line with QuotedReply and other message attachments, saving should happen as part of sending
            // preparation rather than duplicated here and in the SAE
            if let avatarImage = contactShare.avatarImage {
                contactShare.dbRecord.saveAvatarImage(avatarImage, transaction: transaction)
            }

            transaction.addAsyncCompletionOnMain {
                let message = ThreadUtil.enqueueMessage(withContactShare: contactShare.dbRecord, thread: thread)
                self.messageWasSent(message)

                if didAddToProfileWhitelist {
                    self.ensureBannerState()
                }
            }
        }
    }
}

// MARK: -

extension ConversationViewController: ContactShareViewHelperDelegate {
    public func didCreateOrEditContact() {
        AssertIsOnMainThread()

        Logger.info("")

        self.dismiss(animated: true, completion: nil)
    }
}

// MARK: -

extension ConversationViewController: ConversationHeaderViewDelegate {
    public func didTapConversationHeaderView(_ conversationHeaderView: ConversationHeaderView) {
        AssertIsOnMainThread()

        showConversationSettings()
    }

    public func didTapConversationHeaderViewAvatar(_ conversationHeaderView: ConversationHeaderView) {
        AssertIsOnMainThread()

        if conversationHeaderView.avatarView.configuration.hasStoriesToDisplay {
            let vc = StoryPageViewController(
                context: thread.storyContext,
                spoilerState: spoilerState
            )
            present(vc, animated: true)
        } else {
            showConversationSettings()
        }
    }
}

// MARK: -

extension ConversationViewController: ConversationInputTextViewDelegate {
    public func didPasteAttachment(_ attachment: SignalAttachment?) {
        AssertIsOnMainThread()

        guard let attachment = attachment else {
            owsFailDebug("Missing attachment.")
            return
        }

        // If the thing we pasted is sticker-like, send it immediately
        // and render it borderless.
        if attachment.isBorderless {
            tryToSendAttachments([ attachment ], messageBody: nil)
        } else {
            showApprovalDialog(forAttachment: attachment)
        }
    }

    public func inputTextViewSendMessagePressed() {
        AssertIsOnMainThread()

        sendButtonPressed()
    }

    public func textViewDidChange(_ textView: UITextView) {
        AssertIsOnMainThread()

        if textView.text.strippedOrNil != nil {
            typingIndicatorsImpl.didStartTypingOutgoingInput(inThread: thread)
        }
    }
}

// MARK: -

extension ConversationViewController: ConversationSearchControllerDelegate {
    public func didDismissSearchController(_ searchController: UISearchController) {
        AssertIsOnMainThread()

        Logger.verbose("")

        // This method is called not only when the user taps "cancel" in the searchController, but also
        // called when the searchController was dismissed because we switched to another uiMode, like
        // "selection". We only want to revert to "normal" in the former case - when the user tapped
        // "cancel" in the search controller. Otherwise, if we're already in another mode, like
        // "selection", we want to stay in that mode.
        if uiMode == .search {
            uiMode = .normal
        }
    }

    public func conversationSearchController(_ conversationSearchController: ConversationSearchController,
                                             didUpdateSearchResults resultSet: ConversationScreenSearchResultSet?) {
        AssertIsOnMainThread()

        Logger.verbose("conversationScreenSearchResultSet: \(resultSet.debugDescription)")

        self.lastSearchedText = resultSet?.searchText
        loadCoordinator.enqueueReload()
    }

    public func conversationSearchController(_ conversationSearchController: ConversationSearchController,
                                             didSelectMessageId messageId: String) {
        AssertIsOnMainThread()

        Logger.verbose("messageId: \(messageId)")

        ensureInteractionLoadedThenScrollToInteraction(messageId,
                                                       onScreenPercentage: 1,
                                                       alignment: .centerIfNotEntirelyOnScreen,
                                                       isAnimated: true)
    }
}

// MARK: -

extension ConversationViewController: InputAccessoryViewPlaceholderDelegate {
    public func inputAccessoryPlaceholderKeyboardIsPresenting(animationDuration: TimeInterval,
                                                              animationCurve: UIView.AnimationCurve) {
        AssertIsOnMainThread()

        handleKeyboardStateChange(animationDuration: animationDuration,
                                  animationCurve: animationCurve)
    }

    public func inputAccessoryPlaceholderKeyboardDidPresent() {
        AssertIsOnMainThread()

        updateBottomBarPosition()
        updateContentInsets()
    }

    public func inputAccessoryPlaceholderKeyboardIsDismissing(animationDuration: TimeInterval,
                                                              animationCurve: UIView.AnimationCurve) {
        AssertIsOnMainThread()

        handleKeyboardStateChange(animationDuration: animationDuration,
                                  animationCurve: animationCurve)
    }

    public func inputAccessoryPlaceholderKeyboardDidDismiss() {
        AssertIsOnMainThread()

        updateBottomBarPosition()
        updateContentInsets()
        updateScrollingContent()
    }

    public func inputAccessoryPlaceholderKeyboardIsDismissingInteractively() {
        AssertIsOnMainThread()

        // No animation, just follow along with the keyboard.
        self.isDismissingInteractively = true
        updateBottomBarPosition()
        self.isDismissingInteractively = false
    }

    private func handleKeyboardStateChange(animationDuration: TimeInterval,
                                           animationCurve: UIView.AnimationCurve) {
        AssertIsOnMainThread()

        if let transitionCoordinator = self.transitionCoordinator,
           transitionCoordinator.isInteractive {
            return
        }

        let isAnimatingHeightChange = viewState.inputToolbar?.isAnimatingHeightChange ?? false
        let duration = isAnimatingHeightChange ? ConversationInputToolbar.heightChangeAnimationDuration : animationDuration

        if shouldAnimateKeyboardChanges, duration > 0 {
            if hasViewDidAppearEverCompleted {
                // Make note of when the keyboard animation will block
                // loads from landing during the keyboard animation.
                // It isn't safe to block loads for long, so we cap
                // how long they will be blocked for.
                let animationCompletionDate = Date().addingTimeInterval(duration)
                let lastKeyboardAnimationDate = Date().addingTimeInterval(-1.0)
                if viewState.lastKeyboardAnimationDate == nil ||
                    viewState.lastKeyboardAnimationDate?.isBefore(lastKeyboardAnimationDate) == true {
                    viewState.lastKeyboardAnimationDate = animationCompletionDate
                }
            }

            // The animation curve provided by the keyboard notifications
            // is a private value not represented in UIViewAnimationOptions.
            // We don't use a block based animation here because it's not
            // possible to pass a curve directly to block animations.
            UIView.animate(
                withDuration: duration,
                delay: 0,
                options: animationCurve.asAnimationOptions,
                animations: { [self] in
                    updateBottomBarPosition()
                    // To minimize risk, only animatedly update insets when animating quoted reply for now
                    if isAnimatingHeightChange { updateContentInsets() }
                }
            )
            if !isAnimatingHeightChange { updateContentInsets() }
        } else {
            updateBottomBarPosition()
            updateContentInsets()
        }
    }
}

// MARK: -

extension ConversationViewController: ConversationCollectionViewDelegate {
    public func collectionViewWillChangeSize(from oldSize: CGSize, to newSize: CGSize) {
        AssertIsOnMainThread()

        // Do nothing.
    }

    public func collectionViewDidChangeSize(from oldSize: CGSize, to newSize: CGSize) {
        AssertIsOnMainThread()

        if oldSize.width != newSize.width {
            resetForSizeOrOrientationChange()
        }

        updateScrollingContent()
    }

    public func collectionViewWillAnimate() {
        AssertIsOnMainThread()

        scrollingAnimationDidStart()
    }

    public func collectionViewShouldRecognizeSimultaneously(with otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return otherGestureRecognizer == collectionViewContextMenuGestureRecognizer
    }

    public func scrollingAnimationDidStart() {
        AssertIsOnMainThread()

        // scrollingAnimationStartDate blocks landing of loads, so we must ensure
        // that it is always cleared in a timely way, even if the animation
        // is cancelled. Wait no more than N seconds.
        scrollingAnimationCompletionTimer?.invalidate()
        scrollingAnimationCompletionTimer = Timer.weakScheduledTimer(withTimeInterval: 5,
                                                                     target: self,
                                                                     selector: #selector(scrollingAnimationCompletionTimerDidFire),
                                                                     userInfo: nil,
                                                                     repeats: false)
    }

    @objc
    private func scrollingAnimationCompletionTimerDidFire(_ timer: Timer) {
        AssertIsOnMainThread()

        Logger.warn("Scrolling animation did not complete in a timely way.")

        // scrollingAnimationCompletionTimer should already have been cleared,
        // but we need to ensure that it is cleared in a timely way.
        scrollingAnimationDidComplete()
    }
}

// MARK: -

extension ConversationViewController {
    func scrollingAnimationDidComplete() {
        AssertIsOnMainThread()

        scrollingAnimationCompletionTimer?.invalidate()
        scrollingAnimationCompletionTimer = nil

        _ = autoLoadMoreIfNecessary()
    }

    func resetForSizeOrOrientationChange() {
        AssertIsOnMainThread()

        updateConversationStyle()
    }
}
