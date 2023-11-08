//
// Copyright 2017 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import CoreServices
import Intents
import PureLayout
import SignalMessaging
import SignalServiceKit
import SignalUI

public class ShareViewController: UIViewController, ShareViewDelegate, SAEFailedViewDelegate {

    enum ShareViewControllerError: Error, Equatable {
        case assertionError(description: String)
        case unsupportedMedia
        case notRegistered
        case obsoleteShare
        case screenLockEnabled
        case tooManyAttachments
    }

    private var hasInitialRootViewController = false
    private var isReadyForAppExtensions = false

    private var progressPoller: ProgressPoller?
    lazy var loadViewController = SAELoadViewController(delegate: self)

    public var shareViewNavigationController: OWSNavigationController?

    override open func loadView() {
        super.loadView()

        // This should be the first thing we do.
        let appContext = ShareAppExtensionContext(rootViewController: self)
        SetCurrentAppContext(appContext, false)

        let debugLogger = DebugLogger.shared()
        debugLogger.enableTTYLoggingIfNeeded()
        debugLogger.setUpFileLoggingIfNeeded(appContext: appContext, canLaunchInBackground: false)

        Logger.info("")

        Cryptography.seedRandom()

        // We don't need to use DeviceSleepManager in the SAE.

        // We don't need to use applySignalAppearence in the SAE.

        if appContext.isRunningTests {
            // TODO: Do we need to implement isRunningTests in the SAE context?
            return
        }

        // We shouldn't set up our environment until after we've consulted isReadyForAppExtensions.
        let databaseContinuation = AppSetup().start(
            appContext: appContext,
            appVersion: AppVersionImpl.shared,
            paymentsEvents: PaymentsEventsAppExtension(),
            mobileCoinHelper: MobileCoinHelperMinimal(),
            webSocketFactory: WebSocketFactoryNative(),
            callMessageHandler: NoopCallMessageHandler(),
            notificationPresenter: NoopNotificationsManager()
        )

        // Configure the rest of the globals before preparing the database.
        SUIEnvironment.shared.setup()
        SMEnvironment.shared.lightweightGroupCallManagerRef = LightweightGroupCallManager()

        databaseContinuation.prepareDatabase().done(on: DispatchQueue.main) { finalContinuation in
            switch finalContinuation.finish(willResumeInProgressRegistration: false) {
            case .corruptRegistrationState:
                self.showNotRegisteredView()
            case nil:
                self.setAppIsReady()
            }
        }

        let shareViewNavigationController = OWSNavigationController()
        shareViewNavigationController.presentationController?.delegate = self
        shareViewNavigationController.delegate = self
        self.shareViewNavigationController = shareViewNavigationController

        // Don't display load screen immediately, in hopes that we can avoid it altogether.
        Guarantee.after(seconds: 0.8).done { [weak self] in
            AssertIsOnMainThread()

            guard let strongSelf = self else { return }
            guard strongSelf.presentedViewController == nil else {
                Logger.debug("setup completed quickly, no need to present load view controller.")
                return
            }

            Logger.debug("setup is slow - showing loading screen")
            strongSelf.showPrimaryViewController(strongSelf.loadViewController)
        }

        // We don't need to use "screen protection" in the SAE.

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(registrationStateDidChange),
                                               name: .registrationStateDidChange,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(owsApplicationWillEnterForeground),
                                               name: .OWSApplicationWillEnterForeground,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(applicationDidEnterBackground),
                                               name: .OWSApplicationDidEnterBackground,
                                               object: nil)

        Logger.info("completed.")

        OWSAnalytics.appLaunchDidBegin()
    }

    deinit {
        Logger.info("deinit")
    }

    @objc
    private func applicationDidEnterBackground() {
        AssertIsOnMainThread()

        Logger.info("")

        if ScreenLock.shared.isScreenLockEnabled() {
            Logger.info("dismissing.")
            dismissAndCompleteExtension(animated: false, error: ShareViewControllerError.screenLockEnabled)
        }
    }

    private func activate() {
        AssertIsOnMainThread()

        Logger.debug("")

        // We don't need to use "screen protection" in the SAE.

        ensureRootViewController()

        // Always check prekeys after app launches, and sometimes check on app activation.
        self.databaseStorage.read { tx in
            if DependenciesBridge.shared.tsAccountManager.registrationState(tx: tx.asV2Read).isRegistered {
                DependenciesBridge.shared.preKeyManager.checkPreKeysIfNecessary(tx: tx.asV2Read)
            }
        }

        // We don't need to use RTCInitializeSSL() in the SAE.

        if DependenciesBridge.shared.tsAccountManager.registrationStateWithMaybeSneakyTransaction.isRegistered {
            Logger.info("running post launch block for registered user: \(String(describing: DependenciesBridge.shared.tsAccountManager.localIdentifiersWithMaybeSneakyTransaction?.aciAddress))")
        } else {
            Logger.info("running post launch block for unregistered user.")

            // We don't need to update the app icon badge number in the SAE.

            // We don't need to prod the SocketManager in the SAE.
        }

        if DependenciesBridge.shared.tsAccountManager.registrationStateWithMaybeSneakyTransaction.isRegistered {
            DispatchQueue.main.async { [weak self] in
                guard self != nil else { return }
                Logger.info("running post launch block for registered user: \(String(describing: DependenciesBridge.shared.tsAccountManager.localIdentifiersWithMaybeSneakyTransaction?.aciAddress))")

                // We don't need to use the SocketManager in the SAE.

                // TODO: Re-enable when system contact fetching uses less memory.
                // self.contactsManager.fetchSystemContactsOnceIfAlreadyAuthorized()

                // We don't need to fetch messages in the SAE.

                // We don't need to use OWSSyncPushTokensJob in the SAE.
            }
        }
    }

    private func setAppIsReady() {
        Logger.debug("")
        AssertIsOnMainThread()
        owsAssert(!AppReadiness.isAppReady)

        // We don't need to use LaunchJobs in the SAE.

        // Note that this does much more than set a flag; it will also run all deferred blocks.
        AppReadiness.setAppIsReady()

        if DependenciesBridge.shared.tsAccountManager.registrationStateWithMaybeSneakyTransaction.isRegistered {
            Logger.info("localAddress: \(String(describing: DependenciesBridge.shared.tsAccountManager.localIdentifiersWithMaybeSneakyTransaction?.aciAddress))")

            // We don't need to use messageFetcherJob in the SAE.

            // We don't need to use SyncPushTokensJob in the SAE.
        }

        // We don't need to use DeviceSleepManager in the SAE.

        AppVersionImpl.shared.saeLaunchDidComplete()

        ensureRootViewController()

        // We don't need to fetch the local profile in the SAE
    }

    @objc
    private func registrationStateDidChange() {
        AssertIsOnMainThread()

        Logger.debug("")

        if DependenciesBridge.shared.tsAccountManager.registrationStateWithMaybeSneakyTransaction.isRegistered {
            Logger.info("localAddress: \(String(describing: DependenciesBridge.shared.tsAccountManager.localIdentifiersWithMaybeSneakyTransaction?.aciAddress))")

            // We don't need to use ExperienceUpgradeFinder in the SAE.

            // We don't need to use OWSDisappearingMessagesJob in the SAE.
        }
    }

    private func ensureRootViewController() {
        AssertIsOnMainThread()

        Logger.debug("")

        guard AppReadiness.isAppReady else {
            return
        }
        guard !hasInitialRootViewController else {
            return
        }
        hasInitialRootViewController = true

        Logger.info("Presenting initial root view controller")

        if ScreenLock.shared.isScreenLockEnabled() {
            presentScreenLock()
        } else {
            presentContentView()
        }
    }

    private func presentContentView() {
        AssertIsOnMainThread()

        Logger.debug("")

        Logger.info("Presenting content view")

        guard DependenciesBridge.shared.tsAccountManager.registrationStateWithMaybeSneakyTransaction.isRegistered else {
            showNotRegisteredView()
            return
        }

        let localProfileExists = databaseStorage.read { transaction in
            return self.profileManager.localProfileExists(with: transaction)
        }
        guard localProfileExists else {
            // This is a rare edge case, but we want to ensure that the user
            // has already saved their local profile key in the main app.
            showNotReadyView()
            return
        }

        buildAttachmentsAndPresentConversationPicker()
        // We don't use the AppUpdateNag in the SAE.
    }

    // MARK: Error Views

    private func showNotReadyView() {
        AssertIsOnMainThread()

        let failureTitle = OWSLocalizedString("SHARE_EXTENSION_NOT_YET_MIGRATED_TITLE",
                                             comment: "Title indicating that the share extension cannot be used until the main app has been launched at least once.")
        let failureMessage = OWSLocalizedString("SHARE_EXTENSION_NOT_YET_MIGRATED_MESSAGE",
                                               comment: "Message indicating that the share extension cannot be used until the main app has been launched at least once.")
        showErrorView(title: failureTitle, message: failureMessage)
    }

    private func showNotRegisteredView() {
        AssertIsOnMainThread()

        let failureTitle = OWSLocalizedString("SHARE_EXTENSION_NOT_REGISTERED_TITLE",
                                             comment: "Title indicating that the share extension cannot be used until the user has registered in the main app.")
        let failureMessage = OWSLocalizedString("SHARE_EXTENSION_NOT_REGISTERED_MESSAGE",
                                               comment: "Message indicating that the share extension cannot be used until the user has registered in the main app.")
        showErrorView(title: failureTitle, message: failureMessage)
    }

    private func showErrorView(title: String, message: String) {
        AssertIsOnMainThread()

        let viewController = SAEFailedViewController(delegate: self, title: title, message: message)

        let navigationController = UINavigationController()
        navigationController.presentationController?.delegate = self
        navigationController.setViewControllers([viewController], animated: false)
        if self.presentedViewController == nil {
            Logger.debug("presenting modally: \(viewController)")
            self.present(navigationController, animated: true)
        } else {
            owsFailDebug("modal already presented. swapping modal content for: \(viewController)")
            assert(self.presentedViewController == navigationController)
        }
    }

    // MARK: View Lifecycle

    override open func viewDidLoad() {
        super.viewDidLoad()

        Logger.debug("")

        if isReadyForAppExtensions {
            AppReadiness.runNowOrWhenAppDidBecomeReadySync { [weak self] in
                AssertIsOnMainThread()
                self?.activate()
            }
        }
    }

    override open func viewWillAppear(_ animated: Bool) {
        Logger.debug("")

        super.viewWillAppear(animated)
    }

    override open func viewDidAppear(_ animated: Bool) {
        Logger.debug("")

        super.viewDidAppear(animated)
    }

    override open func viewWillDisappear(_ animated: Bool) {
        Logger.debug("")

        super.viewWillDisappear(animated)
    }

    @objc
    private func owsApplicationWillEnterForeground() throws {
        AssertIsOnMainThread()

        Logger.debug("")

        // If a user unregisters in the main app, the SAE should shut down
        // immediately.
        guard !DependenciesBridge.shared.tsAccountManager.registrationStateWithMaybeSneakyTransaction.isRegistered else {
            // If user is registered, do nothing.
            return
        }
        guard let shareViewNavigationController = shareViewNavigationController else {
            owsFailDebug("Missing shareViewNavigationController")
            return
        }
        guard let firstViewController = shareViewNavigationController.viewControllers.first else {
            // If no view has been presented yet, do nothing.
            return
        }
        if firstViewController is SAEFailedViewController {
            // If root view is an error view, do nothing.
            return
        }
        throw ShareViewControllerError.notRegistered
    }

    // MARK: ShareViewDelegate, SAEFailedViewDelegate

    public func shareViewWasUnlocked() {
        Logger.info("")

        presentContentView()
    }

    public func shareViewWasCompleted() {
        Logger.info("")
        dismissAndCompleteExtension(animated: true, error: nil)
    }

    public func shareViewWasCancelled() {
        Logger.info("")
        dismissAndCompleteExtension(animated: true, error: ShareViewControllerError.obsoleteShare)
    }

    public func shareViewFailed(error: Error) {
        owsFailDebug("Error: \(error)")
        dismissAndCompleteExtension(animated: true, error: error)
    }

    private func dismissAndCompleteExtension(animated: Bool, error: Error?) {
        let extensionContext = self.extensionContext
        dismiss(animated: animated) {
            AssertIsOnMainThread()

            if let error {
                extensionContext?.cancelRequest(withError: error)
            } else {
                extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
            }

            // Share extensions reside in a process that may be reused between usages.
            // That isn't safe; the codebase is full of statics (e.g. singletons) which
            // we can't easily clean up.
            ExitShareExtension()
        }
    }

    // MARK: Helpers

    // This view controller is not visible to the user. It exists to intercept touches, set up the
    // extensions dependencies, and eventually present a visible view to the user.
    // For speed of presentation, we only present a single modal, and if it's already been presented
    // we swap out the contents.
    // e.g. if loading is taking a while, the user will see the load screen presented with a modal
    // animation. Next, when loading completes, the load view will be switched out for the contact
    // picker view.
    private func showPrimaryViewController(_ viewController: UIViewController) {
        AssertIsOnMainThread()

        guard let shareViewNavigationController = shareViewNavigationController else {
            owsFailDebug("Missing shareViewNavigationController")
            return
        }
        shareViewNavigationController.setViewControllers([viewController], animated: true)
        if self.presentedViewController == nil {
            Logger.debug("presenting modally: \(viewController)")
            self.present(shareViewNavigationController, animated: true)
        } else {
            Logger.debug("modal already presented. swapping modal content for: \(viewController)")
            assert(self.presentedViewController == shareViewNavigationController)
        }
    }

    private lazy var conversationPicker = SharingThreadPickerViewController(shareViewDelegate: self)
    private func buildAttachmentsAndPresentConversationPicker() {
        let selectedThread: TSThread?
        if let intent = extensionContext?.intent as? INSendMessageIntent,
           let threadUniqueId = intent.conversationIdentifier {
            selectedThread = databaseStorage.read { TSThread.anyFetch(uniqueId: threadUniqueId, transaction: $0) }
        } else {
            selectedThread = nil
        }

        // If we have a pre-selected thread, we wait to show the approval view
        // until the attachments have been built. Otherwise, we'll present it
        // immediately and tell it what attachments we're sharing once we've
        // finished building them.
        if selectedThread == nil { showPrimaryViewController(conversationPicker) }

        firstly(on: DispatchQueue.sharedUserInitiated) { () -> Promise<[UnloadedItem]> in
            guard let inputItems = self.extensionContext?.inputItems as? [NSExtensionItem] else {
                throw OWSAssertionError("no input item")
            }
            let result = try self.itemsToLoad(inputItems: inputItems)
            DispatchQueue.main.async { [weak self] in
                self?.conversationPicker.areAttachmentStoriesCompatPrecheck = result.allSatisfy { item in
                    switch item.itemType {
                    case .movie, .image, .webUrl, .text, .richText:
                        return true
                    case .fileUrl, .contact, .pdf, .pkPass, .other:
                        return false
                    }
                }
            }
            return Promise.value(result)
        }.then(on: DispatchQueue.sharedUserInitiated) { [weak self] (unloadedItems: [UnloadedItem]) -> Promise<[LoadedItem]> in
            guard let self = self else { throw PromiseError.cancelled }

            return self.loadItems(unloadedItems: unloadedItems)
        }.then(on: DispatchQueue.sharedUserInitiated) { [weak self] (loadedItems: [LoadedItem]) -> Promise<[SignalAttachment]> in
            guard let self = self else { throw PromiseError.cancelled }

            return self.buildAttachments(loadedItems: loadedItems)
        }.done { [weak self] (attachments: [SignalAttachment]) in
            guard let self = self else { throw PromiseError.cancelled }

            // Make sure the user is not trying to share more than our attachment limit.
            guard attachments.filter({ !$0.isConvertibleToTextMessage }).count <= SignalAttachment.maxAttachmentsAllowed else {
                throw ShareViewControllerError.tooManyAttachments
            }

            self.progressPoller = nil

            Logger.info("Setting picker attachments: \(attachments)")
            self.conversationPicker.attachments = attachments

            if let selectedThread = selectedThread {
                let approvalVC = try self.conversationPicker.buildApprovalViewController(for: selectedThread)
                self.showPrimaryViewController(approvalVC)
            }
        }.catch { [weak self] error in
            guard let self = self else { return }

            let alertTitle: String
            let alertMessage: String?

            if let error = error as? ShareViewControllerError, error == .tooManyAttachments {
                let format = OWSLocalizedString("IMAGE_PICKER_CAN_SELECT_NO_MORE_TOAST_FORMAT",
                                               comment: "Momentarily shown to the user when attempting to select more images than is allowed. Embeds {{max number of items}} that can be shared.")

                alertTitle = String(format: format, OWSFormat.formatInt(SignalAttachment.maxAttachmentsAllowed))
                alertMessage = nil
            } else {
                alertTitle = OWSLocalizedString("SHARE_EXTENSION_UNABLE_TO_BUILD_ATTACHMENT_ALERT_TITLE",
                                               comment: "Shown when trying to share content to a Signal user for the share extension. Followed by failure details.")
                alertMessage = error.userErrorDescription
            }

            OWSActionSheets.showActionSheet(
                title: alertTitle,
                message: alertMessage,
                buttonTitle: CommonStrings.cancelButton
            ) { _ in
                self.shareViewWasCancelled()
            }
            owsFailDebug("building attachment failed with error: \(error)")
        }
    }

    private func presentScreenLock() {
        AssertIsOnMainThread()

        let screenLockUI = SAEScreenLockViewController(shareViewDelegate: self)
        Logger.debug("presentScreenLock: \(screenLockUI)")
        showPrimaryViewController(screenLockUI)
        Logger.info("showing screen lock")
    }

    private class func itemMatchesSpecificUtiType(itemProvider: NSItemProvider, utiType: String) -> Bool {
        // URLs, contacts and other special items have to be detected separately.
        // Many shares (e.g. pdfs) will register many UTI types and/or conform to kUTTypeData.
        guard itemProvider.registeredTypeIdentifiers.count == 1 else {
            return false
        }
        guard let firstUtiType = itemProvider.registeredTypeIdentifiers.first else {
            return false
        }
        return firstUtiType == utiType
    }

    private class func isVisualMediaItem(itemProvider: NSItemProvider) -> Bool {
        return (itemProvider.hasItemConformingToTypeIdentifier(kUTTypeImage as String) ||
            itemProvider.hasItemConformingToTypeIdentifier(kUTTypeMovie as String))
    }

    private class func isUrlItem(itemProvider: NSItemProvider) -> Bool {
        return itemMatchesSpecificUtiType(itemProvider: itemProvider,
                                          utiType: kUTTypeURL as String)
    }

    private class func isContactItem(itemProvider: NSItemProvider) -> Bool {
        return itemMatchesSpecificUtiType(itemProvider: itemProvider,
                                          utiType: kUTTypeContact as String)
    }

    private func itemsToLoad(inputItems: [NSExtensionItem]) throws -> [UnloadedItem] {
        for inputItem in inputItems {
            guard let itemProviders = inputItem.attachments else {
                throw OWSAssertionError("attachments was empty")
            }

            let itemsToLoad: [UnloadedItem] = itemProviders.map { itemProvider in
                if itemProvider.hasItemConformingToTypeIdentifier(kUTTypeMovie as String) {
                    return UnloadedItem(itemProvider: itemProvider, itemType: .movie)
                }

                if itemProvider.hasItemConformingToTypeIdentifier(kUTTypeImage as String) {
                    return UnloadedItem(itemProvider: itemProvider, itemType: .image)
                }

                // A single inputItem can have multiple attachments, e.g. sharing from Firefox gives
                // one url attachment and another text attachment, where the url would be https://some-news.com/articles/123-cat-stuck-in-tree
                // and the text attachment would be something like "Breaking news - cat stuck in tree"
                //
                // FIXME: For now, we prefer the URL provider and discard the text provider, since it's more useful to share the URL than the caption
                // but we *should* include both. This will be a bigger change though since our share extension is currently heavily predicated
                // on one itemProvider per share.
                if ShareViewController.isUrlItem(itemProvider: itemProvider) {
                    return UnloadedItem(itemProvider: itemProvider, itemType: .webUrl)
                }

                if itemProvider.hasItemConformingToTypeIdentifier(kUTTypeFileURL as String) {
                    return UnloadedItem(itemProvider: itemProvider, itemType: .fileUrl)
                }

                if itemProvider.hasItemConformingToTypeIdentifier(kUTTypeVCard as String) {
                    return UnloadedItem(itemProvider: itemProvider, itemType: .contact)
                }

                if itemProvider.hasItemConformingToTypeIdentifier(kUTTypeRTF as String) {
                    return UnloadedItem(itemProvider: itemProvider, itemType: .richText)
                }

                if itemProvider.hasItemConformingToTypeIdentifier(kUTTypeText as String) {
                    return UnloadedItem(itemProvider: itemProvider, itemType: .text)
                }

                if itemProvider.hasItemConformingToTypeIdentifier(kUTTypePDF as String) {
                    return UnloadedItem(itemProvider: itemProvider, itemType: .pdf)
                }

                if itemProvider.hasItemConformingToTypeIdentifier("com.apple.pkpass") {
                    return UnloadedItem(itemProvider: itemProvider, itemType: .pkPass)
                }

                owsFailDebug("unexpected share item: \(itemProvider)")
                return UnloadedItem(itemProvider: itemProvider, itemType: .other)
            }

            // Prefer a URL if available. If there's an image item and a URL item,
            // the URL is generally more useful. e.g. when sharing an app from the
            // App Store the image would be the app icon and the URL is the link
            // to the application.
            if let urlItem = itemsToLoad.first(where: { $0.itemType == .webUrl }) {
                return [urlItem]
            }

            let visualMediaItems = itemsToLoad.filter { ShareViewController.isVisualMediaItem(itemProvider: $0.itemProvider) }

            // We only allow sharing 1 item, unless they are visual media items. And if they are
            // visualMediaItems we share *only* the visual media items - a mix of visual and non
            // visual items is not supported.
            if visualMediaItems.count > 0 {
                return visualMediaItems
            } else if itemsToLoad.count > 0 {
                return Array(itemsToLoad.prefix(1))
            }
        }
        throw OWSAssertionError("no input item")
    }

    private
    struct LoadedItem {
        enum LoadedItemPayload {
            case fileUrl(_ fileUrl: URL)
            case inMemoryImage(_ image: UIImage)
            case webUrl(_ webUrl: URL)
            case contact(_ contactData: Data)
            case richText(_ richText: NSAttributedString)
            case text(_ text: String)
            case pdf(_ data: Data)
            case pkPass(_ data: Data)

            var debugDescription: String {
                switch self {
                case .fileUrl:
                    return "fileUrl"
                case .inMemoryImage:
                    return "inMemoryImage"
                case .webUrl:
                    return "webUrl"
                case .contact:
                    return "contact"
                case .richText:
                    return "richText"
                case .text:
                    return "text"
                case .pdf:
                    return "pdf"
                case .pkPass:
                    return "pkPass"
                }
            }
        }

        let itemProvider: NSItemProvider
        let payload: LoadedItemPayload

        var customFileName: String? {
            isContactShare ? "Contact.vcf" : nil
        }

        private var isContactShare: Bool {
            if case .contact = payload {
                return true
            } else {
                return false
            }
        }

        var debugDescription: String {
            payload.debugDescription
        }
    }

    private
    struct UnloadedItem {
        enum ItemType {
            case movie
            case image
            case webUrl
            case fileUrl
            case contact
            case richText
            case text
            case pdf
            case pkPass
            case other
        }

        let itemProvider: NSItemProvider
        let itemType: ItemType
    }

    private func loadItems(unloadedItems: [UnloadedItem]) -> Promise<[LoadedItem]> {
        let loadPromises: [Promise<LoadedItem>] = unloadedItems.map { unloadedItem in
            loadItem(unloadedItem: unloadedItem)
        }

        return Promise.when(fulfilled: loadPromises)
    }
    
    private func removeQueryParamsFromURL(url: URL) -> URL? {
        let paramsToRemove = ["igshid", "si", "fbclid", "ttclid", "utm_campaign", "utm_source", "utm_medium", "gclid"]
        let twitterHosts = ["twitter.com", "www.twitter.com", "x.com", "www.x.com"]
        let twitterParamsToRemove = ["t"]
        
        var components = URLComponents(url: url, resolvingAgainstBaseURL: true)
        let items = components?.queryItems
        components?.queryItems = items?.filter { item in
            !paramsToRemove.contains(item.name)
        }
        
        // Remove "t=" parameter only for twitter/x
        if let host = components?.host, twitterHosts.contains(where: { $0 == host }) {
            components?.queryItems = items?.filter { item in
                !twitterParamsToRemove.contains(item.name)
            }
        }
        
        // Remove "/?" or "?" at the end of URL
        if let noQueryItemsLeft = components?.queryItems?.isEmpty, noQueryItemsLeft { components?.query = nil }
        return components?.url
    }

    private func loadItem(unloadedItem: UnloadedItem) -> Promise<LoadedItem> {
        Logger.info("unloadedItem: \(unloadedItem)")

        let itemProvider = unloadedItem.itemProvider

        switch unloadedItem.itemType {
        case .movie:
            return itemProvider.loadUrl(forTypeIdentifier: kUTTypeMovie as String, options: nil).map { fileUrl in
                LoadedItem(itemProvider: unloadedItem.itemProvider,
                           payload: .fileUrl(fileUrl))

            }
        case .image:
            // When multiple image formats are available, kUTTypeImage will
            // defer to jpeg when possible. On iPhone 12 Pro, when 'heic'
            // and 'jpeg' are the available options, the 'jpeg' data breaks
            // UIImage (and underlying) in some unclear way such that trying
            // to perform any kind of transformation on the image (such as
            // resizing) causes memory to balloon uncontrolled. Luckily,
            // iOS 14 provides native UIImage support for heic and iPhone
            // 12s can only be running iOS 14+, so we can request the heic
            // format directly, which behaves correctly for all our needs.
            // A radar has been opened with apple reporting this issue.
            let desiredTypeIdentifier: String
            if #available(iOS 14, *), itemProvider.registeredTypeIdentifiers.contains("public.heic") {
                desiredTypeIdentifier = "public.heic"
            } else {
                desiredTypeIdentifier = kUTTypeImage as String
            }

            return itemProvider.loadUrl(forTypeIdentifier: desiredTypeIdentifier, options: nil).map { fileUrl in
                LoadedItem(itemProvider: unloadedItem.itemProvider,
                           payload: .fileUrl(fileUrl))
            }.recover(on: DispatchQueue.global()) { error -> Promise<LoadedItem> in
                let nsError = error as NSError
                assert(nsError.domain == NSItemProvider.errorDomain)
                assert(nsError.code == NSItemProvider.ErrorCode.unexpectedValueClassError.rawValue)

                // If a URL wasn't available, fall back to an in-memory image.
                // One place this happens is when sharing from the screenshot app on iOS13.
                return itemProvider.loadImage(forTypeIdentifier: kUTTypeImage as String, options: nil).map { image in
                    LoadedItem(itemProvider: unloadedItem.itemProvider,
                               payload: .inMemoryImage(image))
                }
            }
        case .webUrl:
            return itemProvider.loadUrl(forTypeIdentifier: kUTTypeURL as String, options: nil).map { url in
                var localURL = url
                
                if Self.preferences.doRemoveURLTrackers {
                    var notTrackedURL: URL {
                        if let cleanedURL = self.removeQueryParamsFromURL(url: url) {
                            return cleanedURL
                        }
                        return url
                    }
                    localURL = notTrackedURL
                }
                
                return LoadedItem(itemProvider: unloadedItem.itemProvider,
                           payload: .webUrl(localURL))
            }
        case .fileUrl:
            return itemProvider.loadUrl(forTypeIdentifier: kUTTypeFileURL as String, options: nil).map { fileUrl in
                LoadedItem(itemProvider: unloadedItem.itemProvider,
                           payload: .fileUrl(fileUrl))
            }
        case .contact:
            return itemProvider.loadData(forTypeIdentifier: kUTTypeContact as String, options: nil).map { contactData in
                LoadedItem(itemProvider: unloadedItem.itemProvider,
                           payload: .contact(contactData))
            }
        case .richText:
            return itemProvider.loadAttributedText(forTypeIdentifier: kUTTypeRTF as String, options: nil).map { richText in
                LoadedItem(itemProvider: unloadedItem.itemProvider,
                           payload: .richText(richText))
            }
        case .text:
            return itemProvider.loadText(forTypeIdentifier: kUTTypeText as String, options: nil).map { text in
                LoadedItem(itemProvider: unloadedItem.itemProvider,
                           payload: .text(text))
            }
        case .pdf:
            return itemProvider.loadData(forTypeIdentifier: kUTTypePDF as String, options: nil).map { data in
                LoadedItem(itemProvider: unloadedItem.itemProvider,
                           payload: .pdf(data))
            }
        case .pkPass:
            return itemProvider.loadData(forTypeIdentifier: "com.apple.pkpass", options: nil).map { data in
                LoadedItem(itemProvider: unloadedItem.itemProvider,
                           payload: .pkPass(data))
            }
        case .other:
            return itemProvider.loadUrl(forTypeIdentifier: kUTTypeFileURL as String, options: nil).map { fileUrl in
                LoadedItem(itemProvider: unloadedItem.itemProvider,
                           payload: .fileUrl(fileUrl))
            }
        }
    }

    private func buildAttachments(loadedItems: [LoadedItem]) -> Promise<[SignalAttachment]> {
        var attachmentPromises = [Promise<SignalAttachment>]()
        for loadedItem in loadedItems {
            attachmentPromises.append(firstly(on: DispatchQueue.sharedUserInitiated) { () -> Promise<SignalAttachment> in
                self.buildAttachment(loadedItem: loadedItem)
            })
        }
        return Promise.when(fulfilled: attachmentPromises)
    }

    /// Creates an attachment with from a generic "loaded item". The data source
    /// backing the returned attachment must "own" the data it provides - i.e.,
    /// it must not refer to data/files that other components refer to.
    private func buildAttachment(loadedItem: LoadedItem) -> Promise<SignalAttachment> {
        let itemProvider = loadedItem.itemProvider
        switch loadedItem.payload {
        case .webUrl(let webUrl):
            let dataSource = DataSourceValue.dataSource(withOversizeText: webUrl.absoluteString)
            let attachment = SignalAttachment.attachment(dataSource: dataSource, dataUTI: kUTTypeText as String)
            attachment.isConvertibleToTextMessage = true
            return Promise.value(attachment)
        case .contact(let contactData):
            let dataSource = DataSourceValue.dataSource(with: contactData, utiType: kUTTypeContact as String)
            let attachment = SignalAttachment.attachment(dataSource: dataSource, dataUTI: kUTTypeContact as String)
            attachment.isConvertibleToContactShare = true
            return Promise.value(attachment)
        case .richText(let richText):
            let dataSource = DataSourceValue.dataSource(withOversizeText: richText.string)
            let attachment = SignalAttachment.attachment(dataSource: dataSource, dataUTI: kUTTypeText as String)
            attachment.isConvertibleToTextMessage = true
            return Promise.value(attachment)
        case .text(let text):
            let dataSource = DataSourceValue.dataSource(withOversizeText: text)
            let attachment = SignalAttachment.attachment(dataSource: dataSource, dataUTI: kUTTypeText as String)
            attachment.isConvertibleToTextMessage = true
            return Promise.value(attachment)
        case .fileUrl(let originalItemUrl):
            var itemUrl = originalItemUrl
            do {
                if isVideoNeedingRelocation(itemProvider: itemProvider, itemUrl: itemUrl) {
                    itemUrl = try SignalAttachment.copyToVideoTempDir(url: itemUrl)
                }
            } catch {
                let error = ShareViewControllerError.assertionError(description: "Could not copy video")
                return Promise(error: error)
            }

            guard let dataSource = try? DataSourcePath.dataSource(with: itemUrl, shouldDeleteOnDeallocation: false) else {
                let error = ShareViewControllerError.assertionError(description: "Attachment URL was not a file URL")
                return Promise(error: error)
            }
            dataSource.sourceFilename = itemUrl.lastPathComponent

            let utiType = MIMETypeUtil.utiType(forFileExtension: itemUrl.pathExtension) ?? kUTTypeData as String

            if SignalAttachment.isVideoThatNeedsCompression(dataSource: dataSource, dataUTI: utiType) {
                // This can happen, e.g. when sharing a quicktime-video from iCloud drive.

                let (promise, exportSession) = SignalAttachment.compressVideoAsMp4(dataSource: dataSource, dataUTI: utiType)

                // TODO: How can we move waiting for this export to the end of the share flow rather than having to do it up front?
                // Ideally we'd be able to start it here, and not block the UI on conversion unless there's still work to be done
                // when the user hits "send".
                if let exportSession = exportSession {
                    DispatchQueue.main.async {
                        let progressPoller = ProgressPoller(timeInterval: 0.1, ratioCompleteBlock: { return exportSession.progress })

                        self.progressPoller = progressPoller
                        progressPoller.startPolling()

                        self.loadViewController.progress = progressPoller.progress
                    }
                }

                return promise
            }

            let attachment = SignalAttachment.attachment(dataSource: dataSource, dataUTI: utiType)

            // If we already own the attachment's data - i.e. we have copied it
            // from the URL originally passed in, and therefore no one else can
            // be referencing it - we can return the attachment as-is...
            if attachment.dataUrl != originalItemUrl {
                return Promise.value(attachment)
            }

            // ...otherwise, we should clone the attachment to ensure we aren't
            // touching data someone else might be referencing.
            do {
                return Promise.value(try attachment.cloneAttachment())
            } catch {
                let error = ShareViewControllerError.assertionError(description: "Failed to clone attachment")
                return Promise(error: error)
            }
        case .inMemoryImage(let image):
            guard let pngData = image.pngData() else {
                return Promise(error: OWSAssertionError("pngData was unexpectedly nil"))
            }
            let dataSource = DataSourceValue.dataSource(with: pngData, fileExtension: "png")
            let attachment = SignalAttachment.attachment(dataSource: dataSource, dataUTI: kUTTypePNG as String)
            return Promise.value(attachment)
        case .pdf(let pdf):
            let dataSource = DataSourceValue.dataSource(with: pdf, fileExtension: "pdf")
            let attachment = SignalAttachment.attachment(dataSource: dataSource, dataUTI: kUTTypePDF as String)
            return Promise.value(attachment)
        case .pkPass(let pkPass):
            let dataSource = DataSourceValue.dataSource(with: pkPass, fileExtension: "pkpass")
            let attachment = SignalAttachment.attachment(dataSource: dataSource, dataUTI: "com.apple.pkpass")
            return Promise.value(attachment)
        }
    }

    // Some host apps (e.g. iOS Photos.app) sometimes auto-converts some video formats (e.g. com.apple.quicktime-movie)
    // into mp4s as part of the NSItemProvider `loadItem` API. (Some files the Photo's app doesn't auto-convert)
    //
    // However, when using this url to the converted item, AVFoundation operations such as generating a
    // preview image and playing the url in the AVMoviePlayer fails with an unhelpful error: "The operation could not be completed"
    //
    // We can work around this by first copying the media into our container.
    //
    // I don't understand why this is, and I haven't found any relevant documentation in the NSItemProvider
    // or AVFoundation docs.
    //
    // Notes:
    //
    // These operations succeed when sending a video which initially existed on disk as an mp4.
    // (e.g. Alice sends a video to Bob through the main app, which ensures it's an mp4. Bob saves it, then re-shares it)
    //
    // I *did* verify that the size and SHA256 sum of the original url matches that of the copied url. So there
    // is no difference between the contents of the file, yet one works one doesn't.
    // Perhaps the AVFoundation APIs require some extra file system permssion we don't have in the
    // passed through URL.
    private func isVideoNeedingRelocation(itemProvider: NSItemProvider, itemUrl: URL) -> Bool {
        let pathExtension = itemUrl.pathExtension
        if pathExtension.isEmpty {
            Logger.verbose("item URL has no file extension: \(itemUrl).")
            return false
        }
        guard let utiTypeForURL = MIMETypeUtil.utiType(forFileExtension: pathExtension) else {
            Logger.verbose("item has unknown UTI type: \(itemUrl).")
            return false
        }
        Logger.verbose("utiTypeForURL: \(utiTypeForURL)")
        guard utiTypeForURL == kUTTypeMPEG4 as String else {
            // Either it's not a video or it was a video which was not auto-converted to mp4.
            // Not affected by the issue.
            return false
        }

        // If video file already existed on disk as an mp4, then the host app didn't need to
        // apply any conversion, so no need to relocate the file.
        return !itemProvider.registeredTypeIdentifiers.contains(kUTTypeMPEG4 as String)
    }
}

extension ShareViewController: UIAdaptivePresentationControllerDelegate {
    public func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        shareViewWasCancelled()
    }
}

// MARK: -

extension ShareViewController: UINavigationControllerDelegate {

    public func navigationController(_ navigationController: UINavigationController, willShow viewController: UIViewController, animated: Bool) {
        updateNavigationBarVisibility(for: viewController, in: navigationController, animated: animated)
    }

    public func navigationController(_ navigationController: UINavigationController, didShow viewController: UIViewController, animated: Bool) {
        updateNavigationBarVisibility(for: viewController, in: navigationController, animated: animated)
    }

    private func updateNavigationBarVisibility(for viewController: UIViewController,
                                               in navigationController: UINavigationController,
                                               animated: Bool) {
        switch viewController {
        case is AttachmentApprovalViewController:
            navigationController.setNavigationBarHidden(true, animated: animated)
        default:
            navigationController.setNavigationBarHidden(false, animated: animated)
        }
    }
}

// Exposes a Progress object, whose progress is updated by polling the return of a given block
private class ProgressPoller: NSObject {

    let progress: Progress
    private(set) var timer: Timer?

    // Higher number offers higher ganularity
    let progressTotalUnitCount: Int64 = 10000
    private let timeInterval: Double
    private let ratioCompleteBlock: () -> Float

    init(timeInterval: TimeInterval, ratioCompleteBlock: @escaping () -> Float) {
        self.timeInterval = timeInterval
        self.ratioCompleteBlock = ratioCompleteBlock

        self.progress = Progress()

        progress.totalUnitCount = progressTotalUnitCount
        progress.completedUnitCount = Int64(ratioCompleteBlock() * Float(progressTotalUnitCount))
    }

    func startPolling() {
        guard self.timer == nil else {
            owsFailDebug("already started timer")
            return
        }

        self.timer = WeakTimer.scheduledTimer(timeInterval: timeInterval, target: self, userInfo: nil, repeats: true) { [weak self] (timer) in
            guard let strongSelf = self else {
                return
            }

            let completedUnitCount = Int64(strongSelf.ratioCompleteBlock() * Float(strongSelf.progressTotalUnitCount))
            strongSelf.progress.completedUnitCount = completedUnitCount

            if completedUnitCount == strongSelf.progressTotalUnitCount {
                Logger.debug("progress complete")
                timer.invalidate()
            }
        }
    }
}
