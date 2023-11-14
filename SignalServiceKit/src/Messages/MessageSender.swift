//
// Copyright 2020 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import LibSignalClient

// MARK: - Message "isXYZ" properties

private extension TSOutgoingMessage {
    var isTransientSKDM: Bool {
        (self as? OWSOutgoingSenderKeyDistributionMessage)?.isSentOnBehalfOfOnlineMessage ?? false
    }

    var isResendRequest: Bool {
        self is OWSOutgoingResendRequest
    }
}

// MARK: -

extension MessageSender {
    public func pendingSendsPromise() -> Promise<Void> {
        // This promise blocks on all operations already in the queue,
        // but will not block on new operations added after this promise
        // is created. That's intentional to ensure that NotificationService
        // instances complete in a timely way.
        pendingTasks.pendingTasksPromise()
    }
}

// MARK: -

private extension MessageSender {
    static func containsValidSession(for serviceId: ServiceId, deviceId: UInt32, tx: DBReadTransaction) throws -> Bool {
        let sessionStore = DependenciesBridge.shared.signalProtocolStoreManager.signalProtocolStore(for: .aci).sessionStore
        do {
            guard let session = try sessionStore.loadSession(for: serviceId, deviceId: deviceId, tx: tx) else {
                return false
            }
            return session.hasCurrentState
        } catch {
            switch error {
            case RecipientIdError.mustNotUsePniBecauseAciExists:
                throw error
            default:
                return false
            }
        }
    }

    /// Establishes a session with the recipient if one doesn't already exist.
    private func ensureRecipientHasSession(
        recipientId: AccountId,
        serviceId: ServiceId,
        deviceId: UInt32,
        isOnlineMessage: Bool,
        isTransientSenderKeyDistributionMessage: Bool,
        isStoryMessage: Bool,
        udAccess: OWSUDAccess?
    ) async throws {
        let hasSession = try databaseStorage.read { tx in
            try Self.containsValidSession(for: serviceId, deviceId: deviceId, tx: tx.asV2Read)
        }
        if hasSession {
            return
        }

        let preKeyBundle = try await Self.makePrekeyRequest(
            recipientId: recipientId,
            serviceId: serviceId,
            deviceId: deviceId,
            isOnlineMessage: isOnlineMessage,
            isTransientSenderKeyDistributionMessage: isTransientSenderKeyDistributionMessage,
            isStoryMessage: isStoryMessage,
            udAccess: udAccess
        )

        try await databaseStorage.awaitableWrite { tx in
            try Self.createSession(
                for: preKeyBundle,
                recipientId: recipientId,
                serviceId: serviceId,
                deviceId: deviceId,
                transaction: tx
            )
        }
    }

    private static func makePrekeyRequest(
        recipientId: AccountId?,
        serviceId: ServiceId,
        deviceId: UInt32,
        isOnlineMessage: Bool,
        isTransientSenderKeyDistributionMessage: Bool,
        isStoryMessage: Bool,
        udAccess: OWSUDAccess?
    ) async throws -> SignalServiceKit.PreKeyBundle {
        Logger.info("serviceId: \(serviceId).\(deviceId)")

        if deviceRecentlyReportedMissing(serviceId: serviceId, deviceId: deviceId) {
            // We don't want to retry prekey requests if we've recently gotten a "404
            // missing device" for the same recipient/device. Fail immediately as
            // though we hit the "404 missing device" error again.
            Logger.info("Skipping prekey request to avoid missing device error.")
            throw MessageSenderError.missingDevice
        }

        // As an optimization, skip the request if an error is likely.
        if let recipientId, willLikelyHaveUntrustedIdentityKeyError(for: recipientId) {
            Logger.info("Skipping prekey request due to untrusted identity.")
            throw UntrustedIdentityError(serviceId: serviceId)
        }

        if let recipientId, willLikelyHaveInvalidKeySignatureError(for: recipientId) {
            Logger.info("Skipping prekey request due to invalid prekey signature.")

            // Check if this error is happening repeatedly for this recipientId.
            // If so, return an InvalidKeySignatureError as a terminal failure.
            throw InvalidKeySignatureError(serviceId: serviceId, isTerminalFailure: true)
        }

        if isOnlineMessage || isTransientSenderKeyDistributionMessage {
            Logger.info("Skipping prekey request for transient message")
            throw MessageSenderNoSessionForTransientMessageError()
        }

        let requestMaker = RequestMaker(
            label: "Prekey Fetch",
            requestFactoryBlock: { (udAccessKeyForRequest: SMKUDAccessKey?) -> TSRequest? in
                return OWSRequestFactory.recipientPreKeyRequest(
                    withServiceId: ServiceIdObjC.wrapValue(serviceId),
                    deviceId: deviceId,
                    udAccessKey: udAccessKeyForRequest,
                    requestPqKeys: true
                )
            },
            serviceId: serviceId,
            // Don't use UD for story preKey fetches, we don't have a valid UD auth key
            // TODO: (PreKey Cleanup)
            udAccess: isStoryMessage ? nil : udAccess,
            authedAccount: .implicit(),
            // The v2/keys endpoint isn't supported via web sockets, so don't try and
            // send pre key requests via the web socket.
            options: [.skipWebSocket]
        )

        do {
            let result = try await requestMaker.makeRequest().awaitable()
            guard let responseObject = result.responseJson as? [String: Any] else {
                throw OWSAssertionError("Prekey fetch missing response object.")
            }
            guard let bundle = SignalServiceKit.PreKeyBundle(from: responseObject, forDeviceNumber: NSNumber(value: deviceId)) else {
                throw OWSAssertionError("Prekey fetch returned an invalid bundle.")
            }
            return bundle
        } catch {
            switch error.httpStatusCode {
            case 404:
                self.reportMissingDeviceError(serviceId: serviceId, deviceId: deviceId)
                throw MessageSenderError.missingDevice
            case 413, 429:
                throw MessageSenderError.prekeyRateLimit
            case 428:
                // SPAM TODO: Only retry messages with -hasRenderableContent
                try await spamChallengeResolver.tryToHandleSilently(
                    bodyData: error.httpResponseData,
                    retryAfter: error.httpRetryAfterDate
                )
                // The resolver has 10s to asynchronously resolve a challenge. If it
                // resolves, great! We'll let MessageSender auto-retry. Otherwise, it'll be
                // marked as "pending".
                throw SpamChallengeResolvedError()
            default:
                throw error
            }
        }
    }

    static func createSession(
        for preKeyBundle: SignalServiceKit.PreKeyBundle,
        recipientId: String,
        serviceId: ServiceId,
        deviceId: UInt32,
        transaction: SDSAnyWriteTransaction
    ) throws {
        assert(!Thread.isMainThread)

        Logger.info("Creating session for \(serviceId), deviceId: \(deviceId)")

        if try containsValidSession(for: serviceId, deviceId: deviceId, tx: transaction.asV2Write) {
            Logger.warn("Session already exists.")
            return
        }

        let bundle: LibSignalClient.PreKeyBundle
        if preKeyBundle.preKeyPublic.isEmpty {
            if preKeyBundle.pqPreKeyPublic.isEmpty {
                Logger.info("Creating prekey bundle with signed prekey (\(preKeyBundle.signedPreKeyId))")
                bundle = try LibSignalClient.PreKeyBundle(
                    registrationId: UInt32(bitPattern: preKeyBundle.registrationId),
                    deviceId: UInt32(bitPattern: preKeyBundle.deviceId),
                    signedPrekeyId: UInt32(bitPattern: preKeyBundle.signedPreKeyId),
                    signedPrekey: try PublicKey(preKeyBundle.signedPreKeyPublic),
                    signedPrekeySignature: preKeyBundle.signedPreKeySignature,
                    identity: try LibSignalClient.IdentityKey(bytes: preKeyBundle.identityKey))
            } else {
                Logger.info("Creating prekey bundle with signed (\(preKeyBundle.signedPreKeyId)) and pq (\(preKeyBundle.pqPreKeyId)) prekey")
                bundle = try LibSignalClient.PreKeyBundle(
                    registrationId: UInt32(bitPattern: preKeyBundle.registrationId),
                    deviceId: UInt32(bitPattern: preKeyBundle.deviceId),
                    signedPrekeyId: UInt32(bitPattern: preKeyBundle.signedPreKeyId),
                    signedPrekey: try PublicKey(preKeyBundle.signedPreKeyPublic),
                    signedPrekeySignature: preKeyBundle.signedPreKeySignature,
                    identity: try LibSignalClient.IdentityKey(bytes: preKeyBundle.identityKey),
                    kyberPrekeyId: UInt32(bitPattern: preKeyBundle.pqPreKeyId),
                    kyberPrekey: try KEMPublicKey(preKeyBundle.pqPreKeyPublic),
                    kyberPrekeySignature: preKeyBundle.pqPreKeySignature
                )
            }
        } else {
            if preKeyBundle.pqPreKeyPublic.isEmpty {
                Logger.info("Creating prekey bundle with signed (\(preKeyBundle.signedPreKeyId)) and one-time (\(preKeyBundle.preKeyId)) prekey")
                bundle = try LibSignalClient.PreKeyBundle(
                    registrationId: UInt32(bitPattern: preKeyBundle.registrationId),
                    deviceId: UInt32(bitPattern: preKeyBundle.deviceId),
                    prekeyId: UInt32(bitPattern: preKeyBundle.preKeyId),
                    prekey: try PublicKey(preKeyBundle.preKeyPublic),
                    signedPrekeyId: UInt32(bitPattern: preKeyBundle.signedPreKeyId),
                    signedPrekey: try PublicKey(preKeyBundle.signedPreKeyPublic),
                    signedPrekeySignature: preKeyBundle.signedPreKeySignature,
                    identity: try LibSignalClient.IdentityKey(bytes: preKeyBundle.identityKey))
            } else {
                Logger.info("Creating prekey bundle with signed (\(preKeyBundle.signedPreKeyId)) and one-time (\(preKeyBundle.preKeyId)) and pq \(preKeyBundle.pqPreKeyId) prekey")
                bundle = try LibSignalClient.PreKeyBundle(
                    registrationId: UInt32(bitPattern: preKeyBundle.registrationId),
                    deviceId: UInt32(bitPattern: preKeyBundle.deviceId),
                    prekeyId: UInt32(bitPattern: preKeyBundle.preKeyId),
                    prekey: try PublicKey(preKeyBundle.preKeyPublic),
                    signedPrekeyId: UInt32(bitPattern: preKeyBundle.signedPreKeyId),
                    signedPrekey: try PublicKey(preKeyBundle.signedPreKeyPublic),
                    signedPrekeySignature: preKeyBundle.signedPreKeySignature,
                    identity: try LibSignalClient.IdentityKey(bytes: preKeyBundle.identityKey),
                    kyberPrekeyId: UInt32(bitPattern: preKeyBundle.pqPreKeyId),
                    kyberPrekey: try KEMPublicKey(preKeyBundle.pqPreKeyPublic),
                    kyberPrekeySignature: preKeyBundle.pqPreKeySignature
                )
            }
        }

        do {
            Logger.info("Process prekey bundle")
            let identityManager = DependenciesBridge.shared.identityManager
            let protocolAddress = ProtocolAddress(serviceId, deviceId: deviceId)
            try processPreKeyBundle(
                bundle,
                for: protocolAddress,
                sessionStore: DependenciesBridge.shared.signalProtocolStoreManager.signalProtocolStore(for: .aci).sessionStore,
                identityStore: identityManager.libSignalStore(for: .aci, tx: transaction.asV2Write),
                context: transaction
            )
        } catch SignalError.untrustedIdentity(_) {
            Logger.error("Found untrusted identity for \(serviceId)")
            handleUntrustedIdentityKeyError(
                serviceId: serviceId,
                recipientId: recipientId,
                preKeyBundle: preKeyBundle,
                transaction: transaction
            )
            throw UntrustedIdentityError(serviceId: serviceId)
        } catch SignalError.invalidSignature(_) {
            Logger.error("Invalid key signature for \(serviceId)")

            // Received this error from the server, so this could either be
            // an invalid key due to a broken client, or it may be a random
            // corruption in transit.  Mark having encountered an error for
            // this recipient so later checks can determine if this has happend
            // more than once and fail early.
            // The error thrown here is considered non-terminal which allows
            // the request to be retried.
            hadInvalidKeySignatureError(for: recipientId)
            throw InvalidKeySignatureError(serviceId: serviceId, isTerminalFailure: false)
        }
        owsAssertDebug(try containsValidSession(for: serviceId, deviceId: deviceId, tx: transaction.asV2Write), "Couldn't create session.")
    }

    private class func handleUntrustedIdentityKeyError(
        serviceId: ServiceId,
        recipientId: AccountId,
        preKeyBundle: SignalServiceKit.PreKeyBundle,
        transaction tx: SDSAnyWriteTransaction
    ) {
        do {
            let identityManager = DependenciesBridge.shared.identityManager
            let newIdentityKey = try IdentityKey(bytes: preKeyBundle.identityKey)
            identityManager.saveIdentityKey(newIdentityKey, for: serviceId, tx: tx.asV2Write)
            hadUntrustedIdentityKeyError(for: recipientId)
        } catch {
            owsFailDebug("Error: \(error)")
        }
    }
}

// MARK: - Prekey Rate Limits & Untrusted Identities

private extension MessageSender {
    private static let staleIdentityCache = AtomicDictionary<AccountId, Date>(lock: AtomicLock())

    class func hadUntrustedIdentityKeyError(for recipientId: AccountId) {
        staleIdentityCache[recipientId] = Date()
    }

    class func willLikelyHaveUntrustedIdentityKeyError(for recipientId: AccountId) -> Bool {
        assert(!Thread.isMainThread)

        // Prekey rate limits are strict. Therefore, we want to avoid requesting
        // prekey bundles that can't be processed. After a prekey request, we might
        // not be able to process it if the new identity key isn't trusted. We
        // therefore expect all subsequent fetches to fail until that key is
        // trusted, so we don't bother sending them unless the key is trusted.

        guard let mostRecentErrorDate = staleIdentityCache[recipientId] else {
            // We don't have a recent error, so a fetch will probably work.
            return false
        }

        let staleIdentityLifetime = kMinuteInterval * 5
        guard abs(mostRecentErrorDate.timeIntervalSinceNow) < staleIdentityLifetime else {
            // It's been more than five minutes since our last fetch. It's reasonable
            // to try again, even if we don't think it will work. (This helps us
            // discover if there's yet another new identity key.)
            return false
        }

        let identityManager = DependenciesBridge.shared.identityManager
        return databaseStorage.read { tx in
            guard let recipient = SignalRecipient.anyFetch(uniqueId: recipientId, transaction: tx) else {
                return false
            }
            // Otherwise, skip the request if we don't trust the identity.
            let untrustedIdentity = identityManager.untrustedIdentityForSending(
                to: recipient.address,
                untrustedThreshold: nil,
                tx: tx.asV2Read
            )
            return untrustedIdentity != nil
        }
    }
}

private extension MessageSender {
    private typealias InvalidSignatureCache = [AccountId: InvalidSignatureCacheItem]
    private struct InvalidSignatureCacheItem {
        let lastErrorDate: Date
        let errorCount: UInt32
    }
    private static let invalidKeySignatureCache = AtomicValue(InvalidSignatureCache(), lock: AtomicLock())

    class func hadInvalidKeySignatureError(for recipientId: AccountId) {
        invalidKeySignatureCache.update { cache in
            var errorCount: UInt32 = 1
            if let mostRecentError = cache[recipientId] {
                errorCount = mostRecentError.errorCount + 1
            }

            cache[recipientId] = InvalidSignatureCacheItem(
                lastErrorDate: Date(),
                errorCount: errorCount
            )
        }
    }

    class func willLikelyHaveInvalidKeySignatureError(for recipientId: AccountId) -> Bool {
        assert(!Thread.isMainThread)

        // Similar to untrusted identity errors, when an invalid signature for a prekey
        // is encountered, it will probably be encountered for a while until the
        // target client rotates prekeys and hopfully fixes the bad signature.
        // To avoid running into prekey rate limits, remember when an error is
        // encountered and slow down sending prekey requests for this recipient.
        //
        // Additionally, there is always a chance of corruption of the prekey
        // bundle during data transmission, which would result in an invalid
        // signature of an otherwise correct bundle. To handle this rare case,
        // don't begin limiting the prekey request until after encounting the
        // second bad signature for a particular recipient.

        guard let mostRecentError = invalidKeySignatureCache.get()[recipientId] else {
            return false
        }

        let staleIdentityLifetime = kMinuteInterval * 5
        guard abs(mostRecentError.lastErrorDate.timeIntervalSinceNow) < staleIdentityLifetime else {

            // Error has expired, remove it to reset the count
            invalidKeySignatureCache.update { cache in
               _ = cache.removeValue(forKey: recipientId)
            }

            return false
        }

        // Let the first error go, only skip starting on the second error
        guard mostRecentError.errorCount > 1 else {
            return false
        }

        return true
    }
}

// MARK: - Missing Devices

private extension MessageSender {
    private struct CacheKey: Hashable {
        let serviceId: ServiceId
        let deviceId: UInt32
    }

    private static var missingDevicesCache = AtomicDictionary<CacheKey, Date>(lock: .init())

    static func reportMissingDeviceError(serviceId: ServiceId, deviceId: UInt32) {
        assert(!Thread.isMainThread)

        guard deviceId == OWSDevice.primaryDeviceId else {
            // For now, only bother ignoring primary devices. HTTP 404s should cause
            // the recipient's device list to be updated, so linked devices shouldn't
            // be a problem.
            return
        }

        let cacheKey = CacheKey(serviceId: serviceId, deviceId: deviceId)
        missingDevicesCache[cacheKey] = Date()
    }

    static func deviceRecentlyReportedMissing(serviceId: ServiceId, deviceId: UInt32) -> Bool {
        assert(!Thread.isMainThread)

        // Prekey rate limits are strict. Therefore, we want to avoid requesting
        // prekey bundles that are missing on the service (404).

        let cacheKey = CacheKey(serviceId: serviceId, deviceId: deviceId)
        let recentlyReportedMissingDate = missingDevicesCache[cacheKey]

        guard let recentlyReportedMissingDate else {
            return false
        }

        // If the "missing device" was recorded more than N minutes ago, try
        // another prekey fetch.  It's conceivable that the recipient has
        // registered (in the primary device case) or linked to the device (in the
        // secondary device case).
        let missingDeviceLifetime = kMinuteInterval * 1
        guard abs(recentlyReportedMissingDate.timeIntervalSinceNow) < missingDeviceLifetime else {
            return false
        }

        return true
    }
}

// MARK: -

extension MessageSender {
    private static func prepareToSendMessages() async throws -> SenderCertificates {
        let isAppLockedDueToPreKeyUpdateFailures = databaseStorage.read { tx in
            DependenciesBridge.shared.preKeyManager.isAppLockedDueToPreKeyUpdateFailures(tx: tx.asV2Read)
        }
        if isAppLockedDueToPreKeyUpdateFailures {
            Logger.info("Rotating signed pre-key before sending message.")
            // Retry prekey update every time user tries to send a message while app is
            // disabled due to prekey update failures.
            //
            // Only try to update the signed prekey; updating it is sufficient to
            // re-enable message sending.
            try await DependenciesBridge.shared.preKeyManager.rotateSignedPreKeys().awaitable()
        }
        return try await udManager.ensureSenderCertificates(certificateExpirationPolicy: .permissive).awaitable()
    }

    // Mark skipped recipients as such. We may skip because:
    //
    // * A recipient is no longer in the group.
    // * A recipient is blocked.
    // * A recipient is unregistered.
    // * A recipient does not have the required capability.
    private static func markSkippedRecipients(
        of message: TSOutgoingMessage,
        sendingRecipients: [ServiceId],
        tx: SDSAnyWriteTransaction
    ) {
        let skippedRecipients = Set(message.sendingRecipientAddresses())
            .subtracting(sendingRecipients.lazy.map { SignalServiceAddress($0) })
        for address in skippedRecipients {
            // Mark this recipient as "skipped".
            message.update(withSkippedRecipient: address, transaction: tx)
        }
    }

    private static func unsentRecipients(
        of message: TSOutgoingMessage,
        in thread: TSThread,
        tx: SDSAnyReadTransaction
    ) throws -> [SignalServiceAddress] {
        guard let localAddress = DependenciesBridge.shared.tsAccountManager.localIdentifiers(tx: tx.asV2Read)?.aciAddress else {
            throw OWSAssertionError("Missing localAddress.")
        }
        if message.isSyncMessage {
            return [localAddress]
        }

        if let groupThread = thread as? TSGroupThread {
            // Send to the intersection of:
            //
            // * "sending" recipients of the message.
            // * members of the group.
            //
            // I.e. try to send a message IFF:
            //
            // * The recipient was in the group when the message was first tried to be sent.
            // * The recipient is still in the group.
            // * The recipient is in the "sending" state.

            var recipientAddresses = Set<SignalServiceAddress>()

            recipientAddresses.formUnion(message.sendingRecipientAddresses())

            // Only send to members in the latest known group member list.
            // If a member has left the group since this message was enqueued,
            // they should not receive the message.
            let groupMembership = groupThread.groupModel.groupMembership
            var currentValidRecipients = groupMembership.fullMembers

            // ...or latest known list of "additional recipients".
            //
            // This is used to send group update messages for v2 groups to
            // pending members who are not included in .sendingRecipientAddresses().
            if GroupManager.shouldMessageHaveAdditionalRecipients(message, groupThread: groupThread) {
                currentValidRecipients.formUnion(groupMembership.invitedMembers)
            }
            currentValidRecipients.remove(localAddress)
            recipientAddresses.formIntersection(currentValidRecipients)

            let blockedAddresses = blockingManager.blockedAddresses(transaction: tx)
            recipientAddresses.subtract(blockedAddresses)

            if recipientAddresses.contains(localAddress) {
                owsFailDebug("Message send recipients should not include self.")
            }
            return Array(recipientAddresses)
        } else if let contactAddress = (thread as? TSContactThread)?.contactAddress {
            // Treat 1:1 sends to blocked contacts as failures.
            // If we block a user, don't send 1:1 messages to them. The UI
            // should prevent this from occurring, but in some edge cases
            // you might, for example, have a pending outgoing message when
            // you block them.
            if blockingManager.isAddressBlocked(contactAddress, transaction: tx) {
                Logger.info("Skipping 1:1 send to blocked contact: \(contactAddress).")
                throw MessageSenderError.blockedContactRecipient
            } else {
                return [contactAddress]
            }
        } else {
            // Send to the intersection of:
            //
            // * "sending" recipients of the message.
            // * recipients of the thread
            //
            // I.e. try to send a message IFF:
            //
            // * The recipient was part of the thread when the message was first tried to be sent.
            // * The recipient is still part of the thread.
            // * The recipient is in the "sending" state.

            var recipientAddresses = Set(message.sendingRecipientAddresses())

            // Only send to members in the latest known thread recipients list.
            let currentValidThreadRecipients = thread.recipientAddresses(with: tx)

            recipientAddresses.formIntersection(currentValidThreadRecipients)

            let blockedAddresses = blockingManager.blockedAddresses(transaction: tx)
            recipientAddresses.subtract(blockedAddresses)

            if recipientAddresses.contains(localAddress) {
                owsFailDebug("Message send recipients should not include self.")
            }

            return Array(recipientAddresses)
        }
    }

    private static func partitionAddresses(_ addresses: [SignalServiceAddress]) -> ([ServiceId], [E164]) {
        var serviceIds = [ServiceId]()
        var phoneNumbers = [E164]()

        for address in addresses {
            if let serviceId = address.serviceId {
                serviceIds.append(serviceId)
            } else if let phoneNumber = address.e164 {
                phoneNumbers.append(phoneNumber)
            } else {
                owsFailDebug("Recipient has neither ServiceId nor E164.")
            }
        }

        return (serviceIds, phoneNumbers)
    }

    private static func lookUpPhoneNumbers(_ phoneNumbers: [E164]) async throws {
        _ = try await contactDiscoveryManager.lookUp(
            phoneNumbers: Set(phoneNumbers.lazy.map { $0.stringValue }),
            mode: .outgoingMessage
        ).awaitable()
    }
}

// MARK: -

@objc
public extension TSMessage {
    var isSyncMessage: Bool { self is OWSOutgoingSyncMessage }

    var canSendToLocalAddress: Bool {
        return (isSyncMessage ||
                self is OWSOutgoingCallMessage ||
                self is OWSOutgoingResendRequest ||
                self is OWSOutgoingResendResponse)
    }
}

// MARK: -

extension MessageSender {
    @objc
    @available(swift, obsoleted: 1.0)
    func sendMessageToServiceObjC(_ message: TSOutgoingMessage) -> AnyPromise {
        return AnyPromise(Promise.wrapAsync { try await self.sendMessageToService(message) })
    }

    private func sendMessageToService(_ message: TSOutgoingMessage) async throws {
        if DependenciesBridge.shared.appExpiry.isExpired {
            throw AppExpiredError()
        }
        if DependenciesBridge.shared.tsAccountManager.registrationStateWithMaybeSneakyTransaction.isRegistered.negated {
            throw AppDeregisteredError()
        }
        if message.shouldBeSaved {
            let latestCopy = databaseStorage.read { tx in
                TSInteraction.anyFetch(uniqueId: message.uniqueId, transaction: tx) as? TSOutgoingMessage
            }
            guard let latestCopy, latestCopy.wasRemotelyDeleted.negated else {
                throw MessageDeletedBeforeSentError()
            }
        }
        if DebugFlags.messageSendsFail.get() {
            throw OWSUnretryableMessageSenderError()
        }
        BenchManager.completeEvent(eventId: "sendMessagePreNetwork-\(message.timestamp)")
        BenchManager.startEvent(
            title: "Send Message Milestone: Network (\(message.timestamp))",
            eventId: "sendMessageNetwork-\(message.timestamp)"
        )
        do {
            let senderCertificates = try await Self.prepareToSendMessages()
            try await sendMessageToService(message, canLookUpPhoneNumbers: true, senderCertificates: senderCertificates)
        } catch {
            if message.wasSentToAnyRecipient {
                // Always ignore the sync error...
                try? await handleMessageSentLocally(message)
            }
            // ...so that we can throw the original error for the caller. (Note that we
            // throw this error even if the sync message is sent successfully.)
            throw error
        }
        try await handleMessageSentLocally(message)
    }

    private enum SendMessageNextAction {
        /// Look up missing phone numbers & then try sending again.
        case lookUpPhoneNumbersAndTryAgain([E164])

        /// Perform the `sendMessageToService` step.
        case sendMessage(
            serializedMessage: SerializedMessage,
            thread: TSThread,
            serviceIds: [ServiceId],
            udAccess: [ServiceId: OWSUDSendingAccess],
            localIdentifiers: LocalIdentifiers
        )
    }

    private func sendMessageToService(
        _ message: TSOutgoingMessage,
        canLookUpPhoneNumbers: Bool,
        senderCertificates: SenderCertificates
    ) async throws {
        let nextAction: SendMessageNextAction? = try await databaseStorage.awaitableWrite { tx in
            guard let thread = message.thread(tx: tx) else {
                throw MessageSenderError.threadMissing
            }

            let proposedAddresses = try Self.unsentRecipients(of: message, in: thread, tx: tx)
            let (serviceIds, phoneNumbersToFetch) = Self.partitionAddresses(proposedAddresses)

            // If we haven't yet tried to look up phone numbers, send an asynchronous
            // request to look up phone numbers, and then try to go through this logic
            // *again* in a new transaction. Things may change for that subsequent
            // attempt, and if there's still missing phone numbers at that point, we'll
            // skip them for this message.
            if canLookUpPhoneNumbers, !phoneNumbersToFetch.isEmpty {
                return .lookUpPhoneNumbersAndTryAgain(phoneNumbersToFetch)
            }

            Self.markSkippedRecipients(of: message, sendingRecipients: serviceIds, tx: tx)

            let canSendToThread: Bool = {
                if message is OWSOutgoingReactionMessage {
                    return thread.canSendReactionToThread
                }
                let isChatMessage = (
                    message.hasRenderableContent()
                    || message is OutgoingGroupCallUpdateMessage
                    || message is OWSOutgoingCallMessage
                )
                return isChatMessage ? thread.canSendChatMessagesToThread() : thread.canSendNonChatMessagesToThread
            }()
            guard canSendToThread else {
                if message.shouldBeSaved {
                    throw OWSAssertionError("Sending to thread blocked.")
                }
                // Pretend to succeed for non-visible messages like read receipts, etc.
                return nil
            }

            if let contactThread = thread as? TSContactThread {
                // In the "self-send" aka "Note to Self" special case, we only need to send
                // certain kinds of messages. (In particular, regular data messages are
                // sent via their implicit sync message only.)
                if contactThread.contactAddress.isLocalAddress, !message.canSendToLocalAddress {
                    owsAssertDebug(serviceIds.count == 1)
                    Logger.info("Dropping \(type(of: message)) sent to local address (it should be sent by sync message)")
                    // Don't mark self-sent messages as read (or sent) until the sync transcript is sent.
                    return nil
                }
            }

            if serviceIds.isEmpty {
                // All recipients are already sent or can be skipped. NOTE: We might still
                // need to send a sync transcript.
                return nil
            }

            guard let serializedMessage = self.buildAndRecordMessage(message, in: thread, tx: tx) else {
                throw OWSAssertionError("Couldn't build message.")
            }

            guard let localIdentifiers = DependenciesBridge.shared.tsAccountManager.localIdentifiers(tx: tx.asV2Read) else {
                throw OWSAssertionError("Not registered.")
            }

            let senderCertificate: SenderCertificate = {
                switch self.udManager.phoneNumberSharingMode(tx: tx).orDefault {
                case .everybody:
                    return senderCertificates.defaultCert
                case .nobody:
                    return senderCertificates.uuidOnlyCert
                }
            }()

            let udAccessMap = self.fetchSealedSenderAccess(
                for: serviceIds,
                message: message,
                senderCertificate: senderCertificate,
                localIdentifiers: localIdentifiers,
                tx: tx
            )

            return .sendMessage(
                serializedMessage: serializedMessage,
                thread: thread,
                serviceIds: serviceIds,
                udAccess: udAccessMap,
                localIdentifiers: localIdentifiers
            )
        }

        switch nextAction {
        case .none:
            return
        case .lookUpPhoneNumbersAndTryAgain(let phoneNumbers):
            try await Self.lookUpPhoneNumbers(phoneNumbers)
            try await sendMessageToService(message, canLookUpPhoneNumbers: false, senderCertificates: senderCertificates)
        case .sendMessage(let serializedMessage, let thread, let serviceIds, let udAccess, let localIdentifiers):
            let allErrors = AtomicArray<(serviceId: ServiceId, error: Error)>(lock: AtomicLock())
            do {
                try await sendMessage(
                    message,
                    serializedMessage: serializedMessage,
                    in: thread,
                    to: serviceIds,
                    udAccess: udAccess,
                    localIdentifiers: localIdentifiers,
                    senderCertificates: senderCertificates,
                    sendErrorBlock: { serviceId, error in
                        allErrors.append((serviceId, error))
                    }
                )
            } catch {
                // We ignore the thrown error & consult `allErrors` instead.
                try await handleSendFailure(message: message, thread: thread, perRecipientErrors: allErrors.get())
            }
        }
    }

    private func sendMessage(
        _ message: TSOutgoingMessage,
        serializedMessage: SerializedMessage,
        in thread: TSThread,
        to serviceIds: [ServiceId],
        udAccess sendingAccessMap: [ServiceId: OWSUDSendingAccess],
        localIdentifiers: LocalIdentifiers,
        senderCertificates: SenderCertificates,
        sendErrorBlock: @escaping (ServiceId, Error) -> Void
    ) async throws {
        // 3. If we have any participants that support sender key, build a promise
        // for their send.
        let senderKeyStatus = senderKeyStatus(for: thread, intendedRecipients: serviceIds, udAccessMap: sendingAccessMap)

        var senderKeyMessagePromise: Promise<Void>?
        var senderKeyServiceIds: [ServiceId] = senderKeyStatus.allSenderKeyParticipants
        var fanoutServiceIds: [ServiceId] = senderKeyStatus.fanoutParticipants
        if thread.usesSenderKey, senderKeyServiceIds.count >= 2, message.canSendWithSenderKey {
            senderKeyMessagePromise = senderKeyMessageSendPromise(
                message: message,
                plaintextContent: serializedMessage.plaintextData,
                payloadId: serializedMessage.payloadId,
                thread: thread,
                status: senderKeyStatus,
                udAccessMap: sendingAccessMap,
                senderCertificates: senderCertificates,
                sendErrorBlock: sendErrorBlock
            )
        } else {
            senderKeyServiceIds = []
            fanoutServiceIds = serviceIds
            if !message.canSendWithSenderKey {
                Logger.info("Last sender key send attempt failed for message \(message.timestamp). Fanning out")
            }
        }
        owsAssertDebug(fanoutServiceIds.count + senderKeyServiceIds.count == serviceIds.count)

        try await withThrowingTaskGroup(of: Void.self, returning: Void.self) { taskGroup in
            // Perform an "OWSMessageSend" for each non-senderKey recipient.
            for serviceId in fanoutServiceIds {
                let messageSend = OWSMessageSend(
                    message: message,
                    plaintextContent: serializedMessage.plaintextData,
                    plaintextPayloadId: serializedMessage.payloadId,
                    thread: thread,
                    serviceId: serviceId,
                    localIdentifiers: localIdentifiers
                )
                let sealedSenderParameters = sendingAccessMap[serviceId].map {
                    SealedSenderParameters(message: message, udSendingAccess: $0)
                }
                taskGroup.addTask {
                    do {
                        try await self.performMessageSend(messageSend, sealedSenderParameters: sealedSenderParameters)
                    } catch {
                        sendErrorBlock(serviceId, error)
                        throw error
                    }
                }
            }

            // Also wait for the sender key promise.
            if let senderKeyMessagePromise {
                taskGroup.addTask { try await senderKeyMessagePromise.awaitable() }
            }

            // Wait for everything to finish, and *then* throw an arbitrary error b/c
            // the caller doesn't care *what* error is thrown as long as *some* error
            // is thrown when a problem occurs.
            var results = [Result<Void, Error>]()
            while let result = await taskGroup.nextResult() {
                results.append(result)
            }
            for result in results {
                try result.get()
            }
        }
    }

    private func fetchSealedSenderAccess(
        for serviceIds: [ServiceId],
        message: TSOutgoingMessage,
        senderCertificate: SenderCertificate,
        localIdentifiers: LocalIdentifiers,
        tx: SDSAnyReadTransaction
    ) -> [ServiceId: OWSUDSendingAccess] {
        if DebugFlags.disableUD.get() {
            return [:]
        }
        var result = [ServiceId: OWSUDSendingAccess]()
        for serviceId in serviceIds {
            if localIdentifiers.contains(serviceId: serviceId) {
                continue
            }
            let udAccess = (
                message.isStorySend ? udManager.storyUdAccess() : udManager.udAccess(for: serviceId, tx: tx)
            )
            guard let udAccess else {
                continue
            }
            result[serviceId] = OWSUDSendingAccess(udAccess: udAccess, senderCertificate: senderCertificate)
        }
        return result
    }

    private func handleSendFailure(
        message: TSOutgoingMessage,
        thread: TSThread,
        perRecipientErrors allErrors: [(serviceId: ServiceId, error: Error)]
    ) async throws {
        // Some errors should be ignored when sending messages to non 1:1 threads.
        // See discussion on NSError (MessageSender) category.
        let shouldIgnoreError = { (error: Error) -> Bool in
            return !(thread is TSContactThread) && error.shouldBeIgnoredForNonContactThreads
        }

        // Record the individual error for each "failed" recipient.
        await databaseStorage.awaitableWrite { tx in
            for (serviceId, error) in Dictionary(allErrors, uniquingKeysWith: { _, new in new }) {
                if shouldIgnoreError(error) {
                    continue
                }
                message.update(withFailedRecipient: SignalServiceAddress(serviceId), error: error, transaction: tx)
            }
            self.normalizeRecipientStatesIfNeeded(message: message, recipientErrors: allErrors, tx: tx)
        }

        let filteredErrors = allErrors.lazy.map { $0.error }.filter { !shouldIgnoreError($0) }

        // Some errors should never be retried, in order to avoid hitting rate
        // limits, for example.  Unfortunately, since group send retry is
        // all-or-nothing, we need to fail immediately even if some of the other
        // recipients had retryable errors.
        if let fatalError = filteredErrors.first(where: { $0.isFatalError }) {
            throw fatalError
        }

        // If any of the send errors are retryable, we want to retry. Therefore,
        // prefer to propagate a retryable error.
        if let retryableError = filteredErrors.first(where: { $0.isRetryable }) {
            throw retryableError
        }

        // Otherwise, if we have any error at all, propagate it.
        if let anyError = filteredErrors.first {
            throw anyError
        }

        // If we only received errors that we should ignore, consider this send a
        // success, unless the message could not be sent to any recipient.
        if message.sentRecipientsCount() == 0 {
            throw MessageSenderErrorNoValidRecipients()
        }
    }

    private func normalizeRecipientStatesIfNeeded(
        message: TSOutgoingMessage,
        recipientErrors: [(serviceId: ServiceId, error: Error)],
        tx: SDSAnyWriteTransaction
    ) {
        guard recipientErrors.contains(where: {
            switch $0.error {
            case RecipientIdError.mustNotUsePniBecauseAciExists:
                return true
            default:
                return false
            }
        }) else {
            return
        }
        let recipientStateMerger = RecipientStateMerger(
            recipientDatabaseTable: DependenciesBridge.shared.recipientDatabaseTable,
            signalServiceAddressCache: signalServiceAddressCache
        )
        message.anyUpdateOutgoingMessage(transaction: tx) { message in
            recipientStateMerger.normalize(&message.recipientAddressStates, tx: tx.asV2Read)
        }
    }

    /// Sending a reply to a hidden recipient unhides them. But how we
    /// define "reply" is not inclusive of all outgoing messages. We unhide
    /// when the message indicates the user's intent to resume association
    /// with the hidden recipient.
    ///
    /// It is important to be conservative about which messages unhide a
    /// recipient. It is far better to not unhide when should than to
    /// unhide when we should not.
    private func shouldMessageSendUnhideRecipient(_ message: TSOutgoingMessage) -> Bool {
        if message.hasRenderableContent() {
            return true
        }
        if message is OWSOutgoingReactionMessage {
            return true
        }
        if
            let message = message as? OWSOutgoingCallMessage,
            /// OWSOutgoingCallMessages include not only calling
            /// someone (ie, an "offer message"), but also sending
            /// hangup messages, busy messages, and other kinds of
            /// call-related "messages" that do not indicate the
            /// sender's intent to resume association with a recipient.
            message.offerMessage != nil
        {
            return true
        }
        return false
    }

    private func handleMessageSentLocally(_ message: TSOutgoingMessage) async throws {
        await databaseStorage.awaitableWrite { tx in
            if
                let thread = message.thread(tx: tx) as? TSContactThread,
                self.shouldMessageSendUnhideRecipient(message),
                let localAddress = DependenciesBridge.shared.tsAccountManager.localIdentifiers(tx: tx.asV2Read)?.aciAddress,
                !localAddress.isEqualToAddress(thread.contactAddress)
            {
                DependenciesBridge.shared.recipientHidingManager.removeHiddenRecipient(
                    thread.contactAddress,
                    wasLocallyInitiated: true,
                    tx: tx.asV2Write
                )
            }
            if message.shouldBeSaved {
                let latestInteraction = TSInteraction.anyFetch(uniqueId: message.uniqueId, transaction: tx)
                guard let latestMessage = latestInteraction as? TSOutgoingMessage else {
                    Logger.warn("Could not update expiration for deleted message.")
                    return
                }
                ViewOnceMessages.completeIfNecessary(message: latestMessage, transaction: tx)
            }
        }

        try await sendSyncTranscriptIfNeeded(for: message)

        // Don't mark self-sent messages as read (or sent) until the sync
        // transcript is sent.
        //
        // NOTE: This only applies to the 'note to self' conversation.
        if message.isSyncMessage {
            return
        }
        let thread = databaseStorage.read { tx in message.thread(tx: tx) }
        guard let contactThread = thread as? TSContactThread, contactThread.contactAddress.isLocalAddress else {
            return
        }
        owsAssertDebug(message.recipientAddresses().count == 1)
        await databaseStorage.awaitableWrite { tx in
            let deviceId = DependenciesBridge.shared.tsAccountManager.storedDeviceId(tx: tx.asV2Read)
            for sendingAddress in message.sendingRecipientAddresses() {
                message.update(
                    withReadRecipient: sendingAddress,
                    deviceId: deviceId,
                    readTimestamp: message.timestamp,
                    tx: tx
                )
                if message.isVoiceMessage || message.isViewOnceMessage {
                    message.update(
                        withViewedRecipient: sendingAddress,
                        deviceId: deviceId,
                        viewedTimestamp: message.timestamp,
                        tx: tx
                    )
                }
            }
        }
    }

    private func sendSyncTranscriptIfNeeded(for message: TSOutgoingMessage) async throws {
        guard message.shouldSyncTranscript() else {
            return
        }
        do {
            try await message.sendSyncTranscript()
            await databaseStorage.awaitableWrite { tx in
                message.update(withHasSyncedTranscript: true, transaction: tx)
            }
            Logger.info("Successfully sent sync transcript.")
        } catch {
            Logger.info("Failed to send sync transcript: \(error) (isRetryable: \(error.isRetryable))")
        }
    }
}

// MARK: -

extension MessageSender {
    struct SerializedMessage {
        let plaintextData: Data
        let payloadId: Int64?
    }

    func buildAndRecordMessage(
        _ message: TSOutgoingMessage,
        in thread: TSThread,
        tx: SDSAnyWriteTransaction
    ) -> SerializedMessage? {
        guard let plaintextData = message.buildPlainTextData(thread, transaction: tx) else {
            return nil
        }
        let messageSendLog = SSKEnvironment.shared.messageSendLogRef
        let payloadId = messageSendLog.recordPayload(plaintextData, for: message, tx: tx)
        return SerializedMessage(plaintextData: plaintextData, payloadId: payloadId)
    }

    func performMessageSend(
        _ messageSend: OWSMessageSend,
        sealedSenderParameters: SealedSenderParameters?
    ) async throws {
        try await performMessageSendAttempt(
            messageSend,
            sealedSenderParameters: sealedSenderParameters,
            remainingAttempts: 3
        )
    }

    private func retryMessageSend(
        _ messageSend: OWSMessageSend,
        remainingAttempts: Int,
        orThrow error: Error,
        sealedSenderParameters: SealedSenderParameters?
    ) async throws {
        guard remainingAttempts > 1 else {
            throw error
        }
        try await performMessageSendAttempt(
            messageSend,
            sealedSenderParameters: sealedSenderParameters,
            remainingAttempts: remainingAttempts - 1
        )
    }

    private func performMessageSendAttempt(
        _ messageSend: OWSMessageSend,
        sealedSenderParameters: SealedSenderParameters?,
        remainingAttempts: Int
    ) async throws {
        // The caller has access to the error, so they must throw it if no more
        // retries are allowed.
        owsAssert(remainingAttempts > 0)

        let message = messageSend.message
        let serviceId = messageSend.serviceId

        Logger.info("Sending message: \(type(of: message)); timestamp: \(message.timestamp); serviceId: \(serviceId)")

        let deviceMessages: [DeviceMessage]
        do {
            deviceMessages = try await buildDeviceMessages(
                messageSend: messageSend,
                sealedSenderParameters: sealedSenderParameters
            )
        } catch {
            switch error {
            case RequestMakerUDAuthError.udAuthFailure:
                try await retryMessageSend(
                    messageSend,
                    remainingAttempts: remainingAttempts,
                    orThrow: error,
                    sealedSenderParameters: nil  // Retry as an unsealed send.
                )
                return
            default:
                break
            }
            throw error
        }

        if shouldSkipMessageSend(messageSend, deviceMessages: deviceMessages) {
            // This emulates the completion logic of an actual successful send (see below).
            await self.databaseStorage.awaitableWrite { tx in
                message.update(withSkippedRecipient: messageSend.localIdentifiers.aciAddress, transaction: tx)
            }
            return
        }

        for deviceMessage in deviceMessages {
            let hasValidMessageType: Bool = {
                switch deviceMessage.type {
                case .unidentifiedSender:
                    return sealedSenderParameters != nil
                case .ciphertext, .prekeyBundle, .plaintextContent:
                    return sealedSenderParameters == nil
                case .unknown, .keyExchange, .receipt, .senderkeyMessage:
                    return false
                }
            }()
            guard hasValidMessageType else {
                owsFailDebug("Invalid message type: \(deviceMessage.type)")
                throw OWSUnretryableMessageSenderError()
            }
        }

        try await sendDeviceMessages(
            deviceMessages,
            messageSend: messageSend,
            sealedSenderParameters: sealedSenderParameters,
            remainingAttempts: remainingAttempts
        )
    }

    /// We can skip sending sync messages if we know that we have no linked
    /// devices. However, we need to be sure to handle the case where the linked
    /// device list has just changed.
    ///
    /// The linked device list is reflected in two separate pieces of state:
    ///
    /// * OWSDevice's state is updated when you link or unlink a device.
    /// * SignalRecipient's state is updated by 409 "Mismatched devices"
    /// responses from the service.
    ///
    /// If _both_ of these pieces of state agree that there are no linked
    /// devices, then can safely skip sending sync message.
    private func shouldSkipMessageSend(_ messageSend: OWSMessageSend, deviceMessages: [DeviceMessage]) -> Bool {
        guard messageSend.localIdentifiers.contains(serviceId: messageSend.serviceId) else {
            return false
        }
        owsAssertDebug(messageSend.message.canSendToLocalAddress)

        let hasMessageForLinkedDevice = deviceMessages.contains(where: {
            $0.destinationDeviceId != DependenciesBridge.shared.tsAccountManager.storedDeviceIdWithMaybeTransaction
        })

        if hasMessageForLinkedDevice {
            return false
        }

        let mayHaveLinkedDevices = databaseStorage.read { tx in
            DependenciesBridge.shared.deviceManager.mayHaveLinkedDevices(transaction: tx.asV2Read)
        }

        if mayHaveLinkedDevices {
            // We may have just linked a new secondary device which is not yet
            // reflected in the SignalRecipient that corresponds to ourself. Continue
            // sending, where we expect to learn about new devices via a 409 response.
            return false
        }

        return true
    }

    func buildDeviceMessages(
        messageSend: OWSMessageSend,
        sealedSenderParameters: SealedSenderParameters?
    ) async throws -> [DeviceMessage] {
        let recipientDatabaseTable = DependenciesBridge.shared.recipientDatabaseTable
        let recipient = databaseStorage.read { tx in
            return recipientDatabaseTable.fetchRecipient(serviceId: messageSend.serviceId, transaction: tx.asV2Read)
        }

        // If we think the recipient isn't registered, don't build any device
        // messages. Instead, send an empty message to the server to learn if the
        // account has any devices.
        guard let recipient, recipient.isRegistered else {
            return []
        }

        var recipientDeviceIds = recipient.deviceIds

        if messageSend.localIdentifiers.contains(serviceId: messageSend.serviceId) {
            let localDeviceId = DependenciesBridge.shared.tsAccountManager.storedDeviceIdWithMaybeTransaction
            recipientDeviceIds.removeAll(where: { $0 == localDeviceId })
        }

        var results = [DeviceMessage]()
        for deviceId in recipientDeviceIds {
            let deviceMessage = try await buildDeviceMessage(
                messagePlaintextContent: messageSend.plaintextContent,
                messageEncryptionStyle: messageSend.message.encryptionStyle,
                recipientId: recipient.accountId,
                serviceId: messageSend.serviceId,
                deviceId: deviceId,
                isOnlineMessage: messageSend.message.isOnline,
                isTransientSenderKeyDistributionMessage: messageSend.message.isTransientSKDM,
                isStoryMessage: messageSend.message.isStorySend,
                isResendRequestMessage: messageSend.message.isResendRequest,
                sealedSenderParameters: sealedSenderParameters
            )
            if let deviceMessage {
                results.append(deviceMessage)
            }
        }
        return results
    }

    /// Build a ``DeviceMessage`` for the given parameters describing a message.
    ///
    /// A `nil` return value indicates that the given message could not be built
    /// due to an invalid device ID.
    func buildDeviceMessage(
        messagePlaintextContent: Data,
        messageEncryptionStyle: EncryptionStyle,
        recipientId: AccountId,
        serviceId: ServiceId,
        deviceId: UInt32,
        isOnlineMessage: Bool,
        isTransientSenderKeyDistributionMessage: Bool,
        isStoryMessage: Bool,
        isResendRequestMessage: Bool,
        sealedSenderParameters: SealedSenderParameters?
    ) async throws -> DeviceMessage? {
        AssertNotOnMainThread()

        do {
            try await ensureRecipientHasSession(
                recipientId: recipientId,
                serviceId: serviceId,
                deviceId: deviceId,
                isOnlineMessage: isOnlineMessage,
                isTransientSenderKeyDistributionMessage: isTransientSenderKeyDistributionMessage,
                isStoryMessage: isStoryMessage,
                udAccess: sealedSenderParameters?.udSendingAccess.udAccess
            )
        } catch let error {
            switch error {
            case MessageSenderError.missingDevice:
                // If we have an invalid device exception, remove this device from the
                // recipient and suppress the error.
                await databaseStorage.awaitableWrite { tx in
                    Self.updateDevices(
                        serviceId: serviceId,
                        devicesToAdd: [],
                        devicesToRemove: [deviceId],
                        transaction: tx
                    )
                }
                return nil
            case is MessageSenderNoSessionForTransientMessageError:
                // When users re-register, we don't want transient messages (like typing
                // indicators) to cause users to hit the prekey fetch rate limit. So we
                // silently discard these message if there is no pre-existing session for
                // the recipient.
                throw error
            case is UntrustedIdentityError:
                // This *can* happen under normal usage, but it should happen relatively
                // rarely. We expect it to happen whenever Bob reinstalls, and Alice
                // messages Bob before she can pull down his latest identity. If it's
                // happening a lot, we should rethink our profile fetching strategy.
                throw error
            case is InvalidKeySignatureError:
                // This should never happen unless a broken client is uploading invalid
                // keys. The server should now enforce valid signatures on upload,
                // resulting in this become exceedingly rare as time goes by.
                throw error
            case MessageSenderError.prekeyRateLimit:
                throw SignalServiceRateLimitedError()
            case is SpamChallengeRequiredError, is SpamChallengeResolvedError:
                throw error
            case RecipientIdError.mustNotUsePniBecauseAciExists:
                throw error
            case RequestMakerUDAuthError.udAuthFailure:
                throw error
            default:
                owsAssertDebug(error.isNetworkFailureOrTimeout)
                throw OWSRetryableMessageSenderError()
            }
        }

        do {
            return try await databaseStorage.awaitableWrite { tx in
                switch messageEncryptionStyle {
                case .whisper:
                    return try self.encryptMessage(
                        plaintextContent: messagePlaintextContent,
                        serviceId: serviceId,
                        deviceId: deviceId,
                        sealedSenderParameters: sealedSenderParameters,
                        transaction: tx
                    )
                case .plaintext:
                    return try self.wrapPlaintextMessage(
                        plaintextContent: messagePlaintextContent,
                        serviceId: serviceId,
                        deviceId: deviceId,
                        isResendRequestMessage: isResendRequestMessage,
                        sealedSenderParameters: sealedSenderParameters,
                        transaction: tx
                    )
                @unknown default:
                    throw OWSAssertionError("Unrecognized encryption style")
                }
            }
        } catch {
            Logger.warn("Failed to encrypt message \(error)")
            throw error
        }
    }

    private func sendDeviceMessages(
        _ deviceMessages: [DeviceMessage],
        messageSend: OWSMessageSend,
        sealedSenderParameters: SealedSenderParameters?,
        remainingAttempts: Int
    ) async throws {
        let message: TSOutgoingMessage = messageSend.message

        let requestMaker = RequestMaker(
            label: "Message Send",
            requestFactoryBlock: { (udAccessKey: SMKUDAccessKey?) in
                OWSRequestFactory.submitMessageRequest(
                    withServiceId: ServiceIdObjC.wrapValue(messageSend.serviceId),
                    messages: deviceMessages,
                    timestamp: message.timestamp,
                    udAccessKey: udAccessKey,
                    isOnline: message.isOnline,
                    isUrgent: message.isUrgent,
                    isStory: message.isStorySend
                )
            },
            serviceId: messageSend.serviceId,
            udAccess: sealedSenderParameters?.udSendingAccess.udAccess,
            authedAccount: .implicit(),
            options: []
        )

        do {
            let result = try await requestMaker.makeRequest().awaitable()
            await messageSendDidSucceed(
                messageSend,
                deviceMessages: deviceMessages,
                wasSentByUD: result.wasSentByUD,
                wasSentByWebsocket: result.wasSentByWebsocket
            )
        } catch {
            try await messageSendDidFail(
                messageSend,
                responseError: error,
                sealedSenderParameters: sealedSenderParameters,
                remainingAttempts: remainingAttempts
            )
        }
    }

    private func messageSendDidSucceed(
        _ messageSend: OWSMessageSend,
        deviceMessages: [DeviceMessage],
        wasSentByUD: Bool,
        wasSentByWebsocket: Bool
    ) async {
        let message: TSOutgoingMessage = messageSend.message

        Logger.info("Successfully sent message: \(type(of: message)), serviceId: \(messageSend.serviceId), timestamp: \(message.timestamp), wasSentByUD: \(wasSentByUD), wasSentByWebsocket: \(wasSentByWebsocket)")

        await databaseStorage.awaitableWrite { transaction in
            if deviceMessages.isEmpty, messageSend.localIdentifiers.contains(serviceId: messageSend.serviceId) {
                // Since we know we have no linked devices, we can record that
                // fact to later avoid unnecessary sync message sends unless we
                // later learn of a new linked device.

                Logger.info("Sent a message with no device messages. Recording no linked devices.")

                DependenciesBridge.shared.deviceManager.setMayHaveLinkedDevices(
                    false,
                    transaction: transaction.asV2Write
                )
            }

            deviceMessages.forEach { deviceMessage in
                if let payloadId = messageSend.plaintextPayloadId, let recipientAci = messageSend.serviceId as? Aci {
                    let messageSendLog = SSKEnvironment.shared.messageSendLogRef
                    messageSendLog.recordPendingDelivery(
                        payloadId: payloadId,
                        recipientAci: recipientAci,
                        recipientDeviceId: deviceMessage.destinationDeviceId,
                        message: message,
                        tx: transaction
                    )
                }
            }

            message.update(withSentRecipient: ServiceIdObjC.wrapValue(messageSend.serviceId), wasSentByUD: wasSentByUD, transaction: transaction)

            transaction.addSyncCompletion {
                BenchManager.completeEvent(eventId: "sendMessageNetwork-\(message.timestamp)")
                BenchManager.completeEvent(eventId: "sendMessageMarkedAsSent-\(message.timestamp)")
                BenchManager.startEvent(title: "Send Message Milestone: Post-Network (\(message.timestamp))",
                                        eventId: "sendMessagePostNetwork-\(message.timestamp)")
            }

            // If we've just delivered a message to a user, we know they have a valid
            // Signal account. However, if we're sending a story, the server will
            // always tell us the recipient is registered, so we can't use this as an
            // affirmate indication for the existence of an account.
            //
            // This is low trust because we don't actually know for sure the fully
            // qualified address is valid.
            if !message.isStorySend {
                let recipientFetcher = DependenciesBridge.shared.recipientFetcher
                let recipient = recipientFetcher.fetchOrCreate(
                    serviceId: messageSend.serviceId,
                    tx: transaction.asV2Write
                )
                recipient.markAsRegisteredAndSave(tx: transaction)
            }

            Self.profileManager.didSendOrReceiveMessage(
                from: SignalServiceAddress(messageSend.serviceId),
                authedAccount: .implicit(),
                transaction: transaction
            )
        }
    }

    private struct MessageSendFailureResponse: Decodable {
        let code: Int?
        let extraDevices: [UInt32]?
        let missingDevices: [UInt32]?
        let staleDevices: [UInt32]?

        static func parse(_ responseData: Data?) -> MessageSendFailureResponse? {
            guard let responseData = responseData else {
                return nil
            }
            do {
                return try JSONDecoder().decode(MessageSendFailureResponse.self, from: responseData)
            } catch {
                owsFailDebug("Error: \(error)")
                return nil
            }
        }
    }

    private func messageSendDidFail(
        _ messageSend: OWSMessageSend,
        responseError: Error,
        sealedSenderParameters: SealedSenderParameters?,
        remainingAttempts: Int
    ) async throws {
        let message: TSOutgoingMessage = messageSend.message

        Logger.warn("\(type(of: message)) to \(messageSend.serviceId), timestamp: \(message.timestamp), error: \(responseError)")

        let httpError: OWSHTTPError?
        switch responseError {
        case RequestMakerUDAuthError.udAuthFailure:
            try await retryMessageSend(
                messageSend,
                remainingAttempts: remainingAttempts,
                orThrow: responseError,
                sealedSenderParameters: nil  // Retry as an unsealed send.
            )
            return
        case let responseError as OWSHTTPError:
            httpError = responseError
        default:
            owsFailDebug("Unexpected error when sending a message.")
            httpError = nil
        }
        switch httpError?.httpStatusCode {
        case 401:
            Logger.warn("Unable to send due to invalid credentials.")
            throw MessageSendUnauthorizedError()
        case 404:
            try await failSendForUnregisteredRecipient(messageSend)
        case 409:
            Logger.warn("Mismatched devices for \(messageSend.serviceId)")

            guard let response = MessageSendFailureResponse.parse(responseError.httpResponseData) else {
                owsFailDebug("Couldn't parse JSON response.")
                throw OWSRetryableMessageSenderError()
            }

            await handleMismatchedDevices(for: messageSend.serviceId, response: response)
        case 410:
            guard let response = MessageSendFailureResponse.parse(responseError.httpResponseData) else {
                owsFailDebug("Couldn't parse JSON response.")
                throw OWSRetryableMessageSenderError()
            }
            await databaseStorage.awaitableWrite { tx in
                self.handleStaleDevices(response.staleDevices, for: messageSend.serviceId, tx: tx.asV2Write)
            }
        case 428:
            // SPAM TODO: Only retry messages with -hasRenderableContent
            Logger.warn("Server requested user complete spam challenge.")
            try await spamChallengeResolver.tryToHandleSilently(
                bodyData: responseError.httpResponseData,
                retryAfter: responseError.httpRetryAfterDate
            )
            // The resolver has 10s to asynchronously resolve a challenge If it
            // resolves, great! We'll let MessageSender auto-retry. Otherwise, it'll be
            // marked as "pending"
        default:
            break
        }

        try await retryMessageSend(
            messageSend,
            remainingAttempts: remainingAttempts,
            orThrow: responseError,
            sealedSenderParameters: sealedSenderParameters
        )
    }

    private func failSendForUnregisteredRecipient(_ messageSend: OWSMessageSend) async throws -> Never {
        let message: TSOutgoingMessage = messageSend.message

        if !message.isSyncMessage {
            await databaseStorage.awaitableWrite { writeTx in
                self.markAsUnregistered(
                    serviceId: messageSend.serviceId,
                    message: message,
                    thread: messageSend.thread,
                    transaction: writeTx
                )
            }
        }

        throw MessageSenderNoSuchSignalRecipientError()
    }

    func markAsUnregistered(
        serviceId: ServiceId,
        message: TSOutgoingMessage,
        thread: TSThread,
        transaction tx: SDSAnyWriteTransaction
    ) {
        owsAssertDebug(!Thread.isMainThread)

        let address = SignalServiceAddress(serviceId)

        if thread.isNonContactThread {
            // Mark as "skipped" group members who no longer have signal accounts.
            message.update(withSkippedRecipient: address, transaction: tx)
        }

        let recipientDatabaseTable = DependenciesBridge.shared.recipientDatabaseTable
        let recipient = recipientDatabaseTable.fetchRecipient(serviceId: serviceId, transaction: tx.asV2Read)
        recipient?.markAsUnregisteredAndSave(tx: tx)
        // TODO: Should we deleteAllSessionsForContact here?
        //       If so, we'll need to avoid doing a prekey fetch every
        //       time we try to send a message to an unregistered user.
    }
}

extension MessageSender {
    private func handleMismatchedDevices(for serviceId: ServiceId, response: MessageSendFailureResponse) async {
        await databaseStorage.awaitableWrite { transaction in
            Self.updateDevices(
                serviceId: serviceId,
                devicesToAdd: response.missingDevices ?? [],
                devicesToRemove: response.extraDevices ?? [],
                transaction: transaction
            )
        }
    }

    // Called when the server indicates that the devices no longer exist - e.g. when the remote recipient has reinstalled.
    func handleStaleDevices(_ staleDevices: [UInt32]?, for serviceId: ServiceId, tx: DBWriteTransaction) {
        let staleDevices = staleDevices ?? []

        Logger.warn("staleDevices: \(staleDevices) for \(serviceId)")

        guard !staleDevices.isEmpty else {
            return
        }

        let sessionStore = DependenciesBridge.shared.signalProtocolStoreManager.signalProtocolStore(for: .aci).sessionStore
        for staleDeviceId in staleDevices {
            sessionStore.archiveSession(for: serviceId, deviceId: staleDeviceId, tx: tx)
        }
    }

    static func updateDevices(
        serviceId: ServiceId,
        devicesToAdd: [UInt32],
        devicesToRemove: [UInt32],
        transaction: SDSAnyWriteTransaction
    ) {
        AssertNotOnMainThread()
        owsAssertDebug(Set(devicesToAdd).isDisjoint(with: devicesToRemove))

        if !devicesToAdd.isEmpty, SignalServiceAddress(serviceId).isLocalAddress {
            DependenciesBridge.shared.deviceManager.setMayHaveLinkedDevices(
                true,
                transaction: transaction.asV2Write
            )
        }

        let recipientFetcher = DependenciesBridge.shared.recipientFetcher
        let recipient = recipientFetcher.fetchOrCreate(serviceId: serviceId, tx: transaction.asV2Write)
        recipient.modifyAndSave(deviceIdsToAdd: devicesToAdd, deviceIdsToRemove: devicesToRemove, tx: transaction)

        if !devicesToRemove.isEmpty {
            Logger.info("Archiving sessions for extra devices: \(devicesToRemove)")
            let sessionStore = DependenciesBridge.shared.signalProtocolStoreManager.signalProtocolStore(for: .aci).sessionStore
            for deviceId in devicesToRemove {
                sessionStore.archiveSession(for: serviceId, deviceId: deviceId, tx: transaction.asV2Write)
            }
        }
    }
}

// MARK: - Message encryption

private extension MessageSender {
    func encryptMessage(
        plaintextContent plainText: Data,
        serviceId: ServiceId,
        deviceId: UInt32,
        sealedSenderParameters: SealedSenderParameters?,
        transaction: SDSAnyWriteTransaction
    ) throws -> DeviceMessage {
        owsAssertDebug(!Thread.isMainThread)

        guard try Self.containsValidSession(for: serviceId, deviceId: deviceId, tx: transaction.asV2Write) else {
            throw MessageSendEncryptionError(serviceId: serviceId, deviceId: deviceId)
        }

        let paddedPlaintext = plainText.paddedMessageBody

        let serializedMessage: Data
        let messageType: SSKProtoEnvelopeType

        let identityManager = DependenciesBridge.shared.identityManager
        let signalProtocolStore = DependenciesBridge.shared.signalProtocolStoreManager.signalProtocolStore(for: .aci)
        let protocolAddress = ProtocolAddress(serviceId, deviceId: deviceId)

        if let sealedSenderParameters {
            let secretCipher = try SMKSecretSessionCipher(
                sessionStore: signalProtocolStore.sessionStore,
                preKeyStore: signalProtocolStore.preKeyStore,
                signedPreKeyStore: signalProtocolStore.signedPreKeyStore,
                kyberPreKeyStore: signalProtocolStore.kyberPreKeyStore,
                identityStore: identityManager.libSignalStore(for: .aci, tx: transaction.asV2Write),
                senderKeyStore: Self.senderKeyStore
            )

            serializedMessage = try secretCipher.encryptMessage(
                for: serviceId,
                deviceId: deviceId,
                paddedPlaintext: paddedPlaintext,
                contentHint: sealedSenderParameters.contentHint.signalClientHint,
                groupId: sealedSenderParameters.envelopeGroupId(tx: transaction.asV2Read),
                senderCertificate: sealedSenderParameters.udSendingAccess.senderCertificate,
                protocolContext: transaction
            )

            messageType = .unidentifiedSender

        } else {
            let result = try signalEncrypt(
                message: paddedPlaintext,
                for: protocolAddress,
                sessionStore: signalProtocolStore.sessionStore,
                identityStore: identityManager.libSignalStore(for: .aci, tx: transaction.asV2Write),
                context: transaction
            )

            switch result.messageType {
            case .whisper:
                messageType = .ciphertext
            case .preKey:
                messageType = .prekeyBundle
            case .plaintext:
                messageType = .plaintextContent
            default:
                owsFailDebug("Unrecognized message type")
                messageType = .unknown
            }

            serializedMessage = Data(result.serialize())

            // The message is smaller than the envelope, but if the message
            // is larger than this limit, the envelope will be too.
            if serializedMessage.count > MessageProcessor.largeEnvelopeWarningByteCount {
                Logger.verbose("serializedMessage: \(serializedMessage.count) > \(MessageProcessor.largeEnvelopeWarningByteCount)")
                owsFailDebug("Unexpectedly large encrypted message.")
            }
        }

        // We had better have a session after encrypting for this recipient!
        let session = try signalProtocolStore.sessionStore.loadSession(
            for: protocolAddress,
            context: transaction
        )!

        return DeviceMessage(
            type: messageType,
            destinationDeviceId: protocolAddress.deviceId,
            destinationRegistrationId: try session.remoteRegistrationId(),
            serializedMessage: serializedMessage
        )
    }

    func wrapPlaintextMessage(
        plaintextContent rawPlaintext: Data,
        serviceId: ServiceId,
        deviceId: UInt32,
        isResendRequestMessage: Bool,
        sealedSenderParameters: SealedSenderParameters?,
        transaction: SDSAnyWriteTransaction
    ) throws -> DeviceMessage {
        owsAssertDebug(!Thread.isMainThread)

        let identityManager = DependenciesBridge.shared.identityManager
        let protocolAddress = ProtocolAddress(serviceId, deviceId: deviceId)

        // Only resend request messages are allowed to use this codepath.
        guard isResendRequestMessage else {
            throw OWSAssertionError("Unexpected message type")
        }

        let plaintext = try PlaintextContent(bytes: rawPlaintext)

        let serializedMessage: Data
        let messageType: SSKProtoEnvelopeType

        if let sealedSenderParameters {
            let usmc = try UnidentifiedSenderMessageContent(
                CiphertextMessage(plaintext),
                from: sealedSenderParameters.udSendingAccess.senderCertificate,
                contentHint: sealedSenderParameters.contentHint.signalClientHint,
                groupId: sealedSenderParameters.envelopeGroupId(tx: transaction.asV2Read) ?? Data()
            )
            let outerBytes = try sealedSenderEncrypt(
                usmc,
                for: protocolAddress,
                identityStore: identityManager.libSignalStore(for: .aci, tx: transaction.asV2Write),
                context: transaction
            )

            serializedMessage = Data(outerBytes)
            messageType = .unidentifiedSender

        } else {
            serializedMessage = Data(plaintext.serialize())
            messageType = .plaintextContent
        }

        let sessionStore = DependenciesBridge.shared.signalProtocolStoreManager.signalProtocolStore(for: .aci).sessionStore
        let session = try sessionStore.loadSession(for: protocolAddress, context: transaction)!
        return DeviceMessage(
            type: messageType,
            destinationDeviceId: protocolAddress.deviceId,
            destinationRegistrationId: try session.remoteRegistrationId(),
            serializedMessage: serializedMessage
        )
    }
}
