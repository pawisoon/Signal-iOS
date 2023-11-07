//
// Copyright 2021 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import PassKit
import LibSignalClient
import SignalServiceKit

public enum PaymentProcessor: String {
    /// Represents the payment processor Stripe, which we use for Apple Pay and
    /// credit/debit card payments.
    case stripe = "STRIPE"

    /// Represents the payment processor Braintree, which we use for PayPal
    /// payments.
    case braintree = "BRAINTREE"
}

public enum OneTimeBadgeLevel: Hashable {
    case boostBadge
    case giftBadge(OWSGiftBadge.Level)

    public var rawValue: UInt64 {
        switch self {
        case .boostBadge:
            return 1
        case .giftBadge(let level):
            return level.rawLevel
        }
    }
}

public enum SubscriptionBadgeIds: String, CaseIterable {
    case low = "R_LOW"
    case med = "R_MED"
    case high = "R_HIGH"

    public static func contains(_ id: String) -> Bool {
        return Self(rawValue: id) != nil
    }
}

public enum BoostBadgeIds: String {
    case boost = "BOOST"

    public static func contains(_ id: String) -> Bool {
        return Self(rawValue: id) != nil
    }
}

public enum GiftBadgeIds: String {
    case gift = "GIFT"

    public static func contains(_ id: String) -> Bool {
        return Self(rawValue: id) != nil
    }
}

public enum SubscriptionRedemptionFailureReason: Int {
    case none = 0
    case localValidationFailed = 1
    case serverValidationFailed = 400
    case paymentFailed = 402
    case paymentNotFound = 404
    case paymentIntentRedeemed = 409
}

public class SubscriptionLevel: Comparable, Equatable {
    public let level: UInt
    public let name: String
    public let badge: ProfileBadge
    public let amounts: [Currency.Code: FiatMoney]

    public init(
        level: UInt,
        name: String,
        badge: ProfileBadge,
        amounts: [Currency.Code: FiatMoney]
    ) {
        self.level = level
        self.name = name
        self.badge = badge
        self.amounts = amounts
    }

    // MARK: Comparable

    public static func < (lhs: SubscriptionLevel, rhs: SubscriptionLevel) -> Bool {
        return lhs.level < rhs.level
    }

    public static func == (lhs: SubscriptionLevel, rhs: SubscriptionLevel) -> Bool {
        return lhs.level == rhs.level
    }
}

public struct Subscription: Equatable {
    public struct ChargeFailure: Equatable {
        /// The error code reported by the server.
        ///
        /// If nil, we know there was a charge failure but don't know the code. This is unusual,
        /// but can happen if the server sends an invalid response.
        public let code: String?

        public init() {
            code = nil
        }

        public init(code: String) {
            self.code = code
        }

        public init(jsonDictionary: [String: Any]) {
            code = try? ParamParser(dictionary: jsonDictionary).optional(key: "code")
        }
    }

    /// The state of the subscription as understood by the backend
    ///
    /// A subscription will be in the `active` state as long as the current subscription payment has been
    /// successfully processed by the payment processor.
    ///
    /// One note regarding `active` state: If the user hasn't communicated with the backend in
    /// 30-45 days, the backend will consider the user 'inactive' and set `cancelAtEndOfPeriod`
    /// to `true`.  Once the `endOfCurrentPeriod` time has passed, the subscription status will
    /// transition from `active` to `canceled`
    public enum SubscriptionStatus: String {
        case unknown
        case trialing = "trialing"
        case active = "active"
        case incomplete = "incomplete"
        case incompleteExpired = "incomplete_expired"
        case pastDue = "past_due"
        case canceled = "canceled"
        case unpaid = "unpaid"
    }

    public let level: UInt
    public let amount: FiatMoney
    public let endOfCurrentPeriod: TimeInterval
    public let billingCycleAnchor: TimeInterval
    public let active: Bool
    public let cancelAtEndOfPeriod: Bool
    public let status: SubscriptionStatus
    public let paymentProcessor: PaymentProcessor
    public let chargeFailure: ChargeFailure?

    public var debugDescription: String {
        [
            "Subscription",
            "End of current period: \(endOfCurrentPeriod)",
            "Billing cycle anchor: \(billingCycleAnchor)",
            "Cancel at end of period?: \(cancelAtEndOfPeriod)",
            "Status: \(status)",
            "Charge failure: \(chargeFailure.debugDescription)"
        ].joined(separator: ". ")
    }

    public init(subscriptionDict: [String: Any], chargeFailureDict: [String: Any]?) throws {
        let params = ParamParser(dictionary: subscriptionDict)
        level = try params.required(key: "level")
        let currencyCode: Currency.Code = try {
            let raw: String = try params.required(key: "currency")
            return raw.uppercased()
        }()
        amount = FiatMoney(
            currencyCode: currencyCode,
            value: try {
                let integerValue: Int64 = try params.required(key: "amount")
                let decimalValue = Decimal(integerValue)
                if DonationUtilities.zeroDecimalCurrencyCodes.contains(currencyCode) {
                    return decimalValue
                } else {
                    return decimalValue / 100
                }
            }()
        )
        endOfCurrentPeriod = try params.required(key: "endOfCurrentPeriod")
        billingCycleAnchor = try params.required(key: "billingCycleAnchor")
        active = try params.required(key: "active")
        cancelAtEndOfPeriod = try params.required(key: "cancelAtPeriodEnd")
        status = SubscriptionStatus(rawValue: try params.required(key: "status")) ?? .unknown

        let processorString: String = try params.required(key: "processor")
        if let paymentProcessor = PaymentProcessor(rawValue: processorString) {
            self.paymentProcessor = paymentProcessor
        } else {
            throw OWSAssertionError("Unexpected payment processor: \(processorString)")
        }

        if let chargeFailureDict = chargeFailureDict {
            chargeFailure = ChargeFailure(jsonDictionary: chargeFailureDict)
        } else {
            chargeFailure = nil
        }
    }
}

public extension Notification.Name {
    static let hasExpiredGiftBadgeDidChangeNotification = NSNotification.Name("hasExpiredGiftBadgeDidChangeNotification")
}

@objc
public class SubscriptionManagerImpl: NSObject {

    @objc
    public override init() {
        super.init()

        SwiftSingletons.register(self)

        AppReadiness.runNowOrWhenAppWillBecomeReady {
            Self.warmCaches()
        }

        AppReadiness.runNowOrWhenAppDidBecomeReadyAsync {
            DispatchQueue.global().async {
                Self.performMigrationToStorageServiceIfNecessary()
                Self.performSubscriptionKeepAliveIfNecessary()
            }
        }
    }

    private static func warmCaches() {
        Logger.info("[Donations] Warming caches")
        let value = databaseStorage.read { displayBadgesOnProfile(transaction: $0) }
        displayBadgesOnProfileCache.set(value)
    }

    private static func performMigrationToStorageServiceIfNecessary() {
        let hasMigratedToStorageService = databaseStorage.read { transaction in
            subscriptionKVS.getBool(hasMigratedToStorageServiceKey, defaultValue: false, transaction: transaction)
        }

        guard !hasMigratedToStorageService else { return }

        Logger.info("[Donations] Migrating to storage service")

        databaseStorage.write { transaction in
            subscriptionKVS.setBool(true, key: hasMigratedToStorageServiceKey, transaction: transaction)

            let localProfile = profileManagerImpl.localUserProfile()
            let allBadges = localProfile.profileBadgeInfo ?? []
            let displayBadgesOnProfile = allBadges.allSatisfy { badge in
                badge.isVisible ?? {
                    owsFailDebug("Local user badges should always have a non-nil visibility flag")
                    return true
                }()
            }

            setDisplayBadgesOnProfile(displayBadgesOnProfile, transaction: transaction)
        }

        storageServiceManager.recordPendingLocalAccountUpdates()
    }

    public static var subscriptionJobQueue: SubscriptionReceiptCredentialRedemptionJobQueue { smJobQueues.subscriptionReceiptCredentialJobQueue }
    public static let SubscriptionJobQueueDidFinishJobNotification = NSNotification.Name("SubscriptionJobQueueDidFinishJobNotification")
    public static let SubscriptionJobQueueDidFailJobNotification = NSNotification.Name("SubscriptionJobQueueDidFailJobNotification")
    private static let subscriptionKVS = SDSKeyValueStore(collection: "SubscriptionKeyValueStore")

    fileprivate static let subscriberIDKey = "subscriberID"
    fileprivate static let subscriberCurrencyCodeKey = "subscriberCurrencyCode"
    fileprivate static let lastSubscriptionExpirationKey = "subscriptionExpiration"
    fileprivate static let lastSubscriptionHeartbeatKey = "subscriptionHeartbeat"
    fileprivate static let lastSubscriptionReceiptRedemptionFailedKey = "lastSubscriptionReceiptRedemptionFailedKey"
    fileprivate static let userManuallyCancelledSubscriptionKey = "userManuallyCancelledSubscriptionKey"
    fileprivate static let displayBadgesOnProfileKey = "displayBadgesOnProfileKey"
    fileprivate static let knownUserSubscriptionBadgeIDsKey = "knownUserSubscriptionBadgeIDsKey"
    fileprivate static let knownUserBoostBadgeIDsKey = "knownUserBoostBadgeIDsKey"
    fileprivate static let knownUserGiftBadgeIDsKey = "knownUserGiftBageIDsKey"
    fileprivate static let mostRecentlyExpiredBadgeIDKey = "mostRecentlyExpiredBadgeIDKey"
    fileprivate static let mostRecentlyExpiredGiftBadgeIDKey = "mostRecentlyExpiredGiftBadgeIDKey"
    fileprivate static let showExpirySheetOnHomeScreenKey = "showExpirySheetOnHomeScreenKey"
    fileprivate static let mostRecentSubscriptionPaymentMethodKey = "mostRecentSubscriptionPaymentMethod"
    fileprivate static let hasMigratedToStorageServiceKey = "hasMigratedToStorageServiceKey"

    // MARK: Current subscription status

    public class func currentProfileSubscriptionBadges() -> [OWSUserProfileBadgeInfo] {
        let snapshot = profileManagerImpl.localProfileSnapshot(shouldIncludeAvatar: false)
        let profileBadges = snapshot.profileBadgeInfo ?? []
        return profileBadges.compactMap { (badge: OWSUserProfileBadgeInfo) -> OWSUserProfileBadgeInfo? in
            guard SubscriptionBadgeIds.contains(badge.badgeId) else { return nil }
            return badge
        }
    }

    public class func getCurrentSubscriptionStatus(for subscriberID: Data) -> Promise<Subscription?> {
        let request = OWSRequestFactory.subscriptionGetCurrentSubscriptionLevelRequest(subscriberID: subscriberID)
        return firstly {
            networkManager.makePromise(request: request)
        }.map(on: DispatchQueue.global()) { response in
            let statusCode = response.responseStatusCode

            if statusCode != 200 {
                throw OWSAssertionError("Got bad response code \(statusCode).")
            }

            if let json = response.responseBodyJson as? [String: Any] {
                guard let parser = ParamParser(responseObject: json) else {
                    throw OWSAssertionError("Missing or invalid response.")
                }

                guard let subscriptionDict: [String: Any] = try parser.optional(key: "subscription") else {
                    return nil
                }
                let chargeFailureDict: [String: Any]? = try? parser.optional(key: "chargeFailure")

                return try Subscription(subscriptionDict: subscriptionDict,
                                        chargeFailureDict: chargeFailureDict)
            } else {
                return nil
            }
        }
    }

    // MARK: Subscription management

    /// Perform processor-agnostic steps to set up a new subscription, before
    /// payment has been authorized.
    ///
    /// - Returns: The new subscriber ID.
    public class func prepareNewSubscription(currencyCode: Currency.Code) -> Promise<Data> {
        firstly {
            Logger.info("[Donations] Setting up new subscription")

            return setupNewSubscriberID()
        }.map(on: DispatchQueue.sharedUserInitiated) { subscriberID -> Data in
            Logger.info("[Donations] Caching params after setting up new subscription")

            databaseStorage.write { transaction in
                self.setUserManuallyCancelledSubscription(false, transaction: transaction)
                self.setSubscriberID(subscriberID, transaction: transaction)
                self.setSubscriberCurrencyCode(currencyCode, transaction: transaction)
                self.setMostRecentlyExpiredBadgeID(badgeID: nil, transaction: transaction)
                self.setShowExpirySheetOnHomeScreenKey(show: false, transaction: transaction)
            }

            self.storageServiceManager.recordPendingLocalAccountUpdates()

            return subscriberID
        }
    }

    /// Finalize a new subscription, after payment has been authorized with the
    /// given processor.
    public class func finalizeNewSubscription(
        forSubscriberId subscriberId: Data,
        withPaymentId paymentId: String,
        usingPaymentMethod paymentMethod: DonationPaymentMethod,
        subscription: SubscriptionLevel,
        currencyCode: Currency.Code
    ) -> Promise<Subscription> {
        firstly { () -> Promise<Void> in
            Logger.info("[Donations] Setting default payment method on service")

            return setDefaultPaymentMethod(
                for: subscriberId,
                using: paymentMethod.paymentProcessor,
                paymentID: paymentId
            )
        }.then(on: DispatchQueue.sharedUserInitiated) { _ -> Promise<Subscription> in
            Logger.info("[Donations] Selecting subscription level on service")

            databaseStorage.write { transaction in
                Self.setMostRecentSubscriptionPaymentMethod(paymentMethod: paymentMethod, transaction: transaction)
            }

            return setSubscription(
                for: subscriberId,
                subscription: subscription,
                currencyCode: currencyCode
            )
        }
    }

    /// Update the subscription level for the given subscriber ID.
    public class func updateSubscriptionLevel(
        for subscriberID: Data,
        to subscription: SubscriptionLevel,
        currencyCode: Currency.Code
    ) -> Promise<Subscription> {
        Logger.info("[Donations] Updating subscription level")

        return setSubscription(
            for: subscriberID,
            subscription: subscription,
            currencyCode: currencyCode
        )
    }

    /// Cancel a subscription for the given subscriber ID.
    public class func cancelSubscription(for subscriberID: Data) -> Promise<Void> {
        Logger.info("[Donations] Cancelling subscription")

        let request = OWSRequestFactory.deleteSubscriberID(subscriberID)
        return firstly {
            networkManager.makePromise(request: request)
        }.map(on: DispatchQueue.global()) { response in
            switch response.responseStatusCode {
            case 200, 404:
                break
            default:
                throw OWSAssertionError("Got bad response code \(response.responseStatusCode).")
            }

            databaseStorage.write { transaction in
                self.setSubscriberID(nil, transaction: transaction)
                self.setSubscriberCurrencyCode(nil, transaction: transaction)
                self.setLastSubscriptionExpirationDate(nil, transaction: transaction)
                self.setLastReceiptRedemptionFailed(failureReason: .none, transaction: transaction)
                self.setMostRecentSubscriptionPaymentMethod(paymentMethod: nil, transaction: transaction)
                self.setUserManuallyCancelledSubscription(true, transaction: transaction)
            }

            self.storageServiceManager.recordPendingLocalAccountUpdates()
        }
    }

    /// Generate and register an ID for a new subscriber.
    ///
    /// - Returns the new subscriber ID.
    private class func setupNewSubscriberID() -> Promise<Data> {
        Logger.info("[Donations] Setting up new subscriber ID")

        let newSubscriberID = Cryptography.generateRandomBytes(UInt(32))
        return firstly {
            self.postSubscriberID(subscriberID: newSubscriberID)
        }.map(on: DispatchQueue.global()) { _ in
            return newSubscriberID
        }
    }

    private class func postSubscriberID(subscriberID: Data) -> Promise<Void> {
        let request = OWSRequestFactory.setSubscriberID(subscriberID)
        return firstly {
            networkManager.makePromise(request: request)
        }.map(on: DispatchQueue.global()) { response in
            let statusCode = response.responseStatusCode

            if statusCode != 200 {
                throw OWSAssertionError("Got bad response code \(statusCode).")
            }
        }
    }

    private class func setDefaultPaymentMethod(
        for subscriberID: Data,
        using processor: PaymentProcessor,
        paymentID: String
    ) -> Promise<Void> {
        let request = OWSRequestFactory.subscriptionSetDefaultPaymentMethod(
            subscriberID: subscriberID,
            processor: processor.rawValue,
            paymentID: paymentID
        )

        return firstly {
            networkManager.makePromise(request: request)
        }.map(on: DispatchQueue.global()) { response in
            let statusCode = response.responseStatusCode
            if statusCode != 200 {
                throw OWSAssertionError("Got bad response code \(statusCode).")
            }
        }
    }

    /// Set the current subscription to the given level and currency.
    ///
    /// - Returns
    /// The updated subscription.
    private class func setSubscription(
        for subscriberID: Data,
        subscription: SubscriptionLevel,
        currencyCode: Currency.Code
    ) -> Promise<Subscription> {
        let key = Cryptography.generateRandomBytes(UInt(32)).asBase64Url
        let request = OWSRequestFactory.subscriptionSetSubscriptionLevelRequest(
            subscriberID: subscriberID,
            level: subscription.level,
            currency: currencyCode,
            idempotencyKey: key
        )
        return firstly {
            networkManager.makePromise(request: request)
        }.then(on: DispatchQueue.global()) { response -> Promise<Subscription?> in
            let statusCode = response.responseStatusCode
            if statusCode != 200 {
                throw OWSAssertionError("Got bad response code \(statusCode).")
            }

            return self.getCurrentSubscriptionStatus(for: subscriberID)
        }.map(on: DispatchQueue.global()) { subscription in
            guard let subscription = subscription else {
                throw OWSAssertionError("Failed to fetch valid subscription object after setSubscription")
            }

            databaseStorage.write { transaction in
                self.setSubscriberCurrencyCode(currencyCode, transaction: transaction)
                self.setLastSubscriptionExpirationDate(Date(timeIntervalSince1970: subscription.endOfCurrentPeriod), transaction: transaction)
            }

            self.storageServiceManager.recordPendingLocalAccountUpdates()

            return subscription
        }
    }

    public class func requestAndRedeemReceiptsIfNecessary(
        for subscriberID: Data,
        usingPaymentProcessor paymentProcessor: PaymentProcessor,
        subscriptionLevel: UInt,
        priorSubscriptionLevel: UInt?
    ) {
        let request = generateReceiptRequest()

        // Remove prior operations if one exists (allow prior job to complete)
        for redemptionJob in subscriptionJobQueue.runningOperations.get() {
            if !redemptionJob.isBoost {
                redemptionJob.reportError(OWSAssertionError("Job did not complete before next subscription run"))
            }
        }

        // Reset failure state
        databaseStorage.write { transaction in
            self.setLastReceiptRedemptionFailed(failureReason: .none, transaction: transaction)
        }

        databaseStorage.asyncWrite { transaction in
            self.subscriptionJobQueue.addSubscriptionJob(
                paymentProcessor: paymentProcessor,
                receiptCredentialRequestContext: request.context.serialize().asData,
                receiptCredentialRequest: request.request.serialize().asData,
                subscriberID: subscriberID,
                targetSubscriptionLevel: subscriptionLevel,
                priorSubscriptionLevel: priorSubscriptionLevel,
                transaction: transaction
            )
        }
    }

    public class func generateReceiptRequest() -> (context: ReceiptCredentialRequestContext, request: ReceiptCredentialRequest) {
        do {
            let clientOperations = try clientZKReceiptOperations()
            let receiptSerial = try generateReceiptSerial()

            let receiptCredentialRequestContext = try clientOperations.createReceiptCredentialRequestContext(receiptSerial: receiptSerial)
            let receiptCredentialRequest = try receiptCredentialRequestContext.getRequest()
            return (receiptCredentialRequestContext, receiptCredentialRequest)
        } catch {
            // This operation happens entirely on-device and is unlikely to fail.
            // If it does, a full crash is probably desirable.
            owsFail("Could not generate receipt request: \(error)")
        }
    }

    public class func requestReceiptCredentialPresentation(for subscriberID: Data,
                                                           context: ReceiptCredentialRequestContext,
                                                           request: ReceiptCredentialRequest,
                                                           targetSubscriptionLevel: UInt,
                                                           priorSubscriptionLevel: UInt = 0) throws -> Promise<ReceiptCredentialPresentation> {
        let clientOperations = try clientZKReceiptOperations()
        let request = OWSRequestFactory.subscriptionReceiptCredentialsRequest(
            subscriberID: subscriberID,
            request: request.serialize().asData
        )
        return firstly {
            networkManager.makePromise(request: request)
        }.map(on: DispatchQueue.global()) { response in
            let statusCode = response.responseStatusCode

            if statusCode == 200 {
                Logger.info("Got valid receipt response")
            } else if statusCode == 204 {
                Logger.info("User has no active subscriptions when getting receipt presentation, retrying!")
                throw OWSRetryableSubscriptionError()
            } else {
                Logger.info("Got undefined non-4xx error fetching receipt presentation, retrying!")
                throw OWSRetryableSubscriptionError()
            }

            let failValidation = {
                databaseStorage.write { transaction in
                    self.setLastReceiptRedemptionFailed(failureReason: .localValidationFailed, transaction: transaction)
                }
            }

            guard let json = response.responseBodyJson as? [String: Any] else {
                failValidation()
                throw OWSAssertionError("Unable to parse receipt presentation response body.")
            }

            guard let parser = ParamParser(responseObject: json) else {
                failValidation()
                throw OWSAssertionError("Missing or invalid receipt presentation response.")
            }

            let receiptCredentialResponseString: String = try parser.required(key: "receiptCredentialResponse")
            guard let receiptCredentialResponseData = Data(base64Encoded: receiptCredentialResponseString) else {
                failValidation()
                throw OWSAssertionError("Unable to parse receiptCredentialResponse into data.")
            }

            let receiptCredentialResponse = try ReceiptCredentialResponse(contents: [UInt8](receiptCredentialResponseData))
            let receiptCredential = try clientOperations.receiveReceiptCredential(receiptCredentialRequestContext: context, receiptCredentialResponse: receiptCredentialResponse)

            // Validate that receipt credential level matches requested level, or prior subscription level
            let level = try receiptCredential.getReceiptLevel()
            var receiptCredentialHasValidLevel = (level == targetSubscriptionLevel)

            if !receiptCredentialHasValidLevel && priorSubscriptionLevel != 0 {
                receiptCredentialHasValidLevel = (level == priorSubscriptionLevel)
            }

            guard receiptCredentialHasValidLevel else {
                failValidation()
                throw OWSAssertionError("Unexpected receipt credential level, validation failed. Got \(level), expected \(targetSubscriptionLevel) or \(priorSubscriptionLevel)")
            }

            // Validate receipt credential expiration % 86400 == 0, per server spec
            let expiration = try receiptCredential.getReceiptExpirationTime()
            guard expiration % 86400 == 0 else {
                failValidation()
                throw OWSAssertionError("Invalid receipt credential expiration, expiration mod != 0, validation failed")
            }

            // Validate expiration is less than 90 days from now
            let maximumValidExpirationDate = Date().timeIntervalSince1970 + (90 * 24 * 60 * 60)
            guard TimeInterval(expiration) < maximumValidExpirationDate else {
                failValidation()
                throw OWSAssertionError("Invalid receipt credential expiration, expiration is more than 90 days from now")
            }

            let receiptCredentialPresentation = try clientOperations.createReceiptCredentialPresentation(receiptCredential: receiptCredential)

            return receiptCredentialPresentation
        }.recover { error -> Promise<ReceiptCredentialPresentation> in
            if let error = error as? OWSHTTPError {
                let statusCode = error.responseStatusCode
                if statusCode == 400 || statusCode == 402 || statusCode == 403 || statusCode == 404 || statusCode ==  409 {
                    let failureReason = SubscriptionRedemptionFailureReason(rawValue: statusCode) ?? .none
                    databaseStorage.write { transaction in
                        self.setLastReceiptRedemptionFailed(failureReason: failureReason, transaction: transaction)
                    }
                    throw OWSAssertionError("Receipt redemption failed with unrecoverable HTTP code \(statusCode)")
                } else {
                    Logger.info("Receipt redemption failed with retryable HTTP code \(statusCode)")
                    throw OWSRetryableSubscriptionError()
                }
            }
            throw error
        }
    }

    public class func redeemReceiptCredentialPresentation(
        receiptCredentialPresentation: ReceiptCredentialPresentation
    ) -> Promise<Void> {
        let expiresAtForLogging: String = {
            guard let result = try? receiptCredentialPresentation.getReceiptExpirationTime() else { return "UNKNOWN" }
            return String(result)
        }()
        Logger.info("[Donations] Redeeming receipt credential presentation. Expires at \(expiresAtForLogging)")

        let receiptCredentialPresentationData = receiptCredentialPresentation.serialize().asData

        let request = OWSRequestFactory.subscriptionRedeemReceiptCredential(
            receiptCredentialPresentation: receiptCredentialPresentationData
        )
        return firstly(on: DispatchQueue.global()) {
            networkManager.makePromise(request: request)
        }.map(on: DispatchQueue.global()) { response in
            let statusCode = response.responseStatusCode
            if statusCode != 200 {
                Logger.warn("[Donations] Receipt credential presentation request failed with status code \(statusCode)")
                throw OWSRetryableSubscriptionError()
            }
        }.then(on: DispatchQueue.global()) {
            self.profileManagerImpl.fetchLocalUsersProfilePromise(authedAccount: .implicit()).asVoid()
        }
    }

    private class func generateReceiptSerial() throws -> ReceiptSerial {
        let count = ReceiptSerial.SIZE
        let bytes = Cryptography.generateRandomBytes(UInt(count))
        return try ReceiptSerial(contents: [UInt8](bytes))
    }

    private class func clientZKReceiptOperations() throws -> ClientZkReceiptOperations {
        let params = try GroupsV2Protos.serverPublicParams()
        return ClientZkReceiptOperations(serverPublicParams: params)
    }

    // 3 day heartbeat interval
    private static let heartbeatInterval: TimeInterval = 3 * 24 * 60 * 60

    // MARK: Heartbeat
    @objc
    public class func performSubscriptionKeepAliveIfNecessary() {

        // Kick job queue
        _ = subscriptionJobQueue.runAnyQueuedRetry()

        Logger.info("[Donations] Checking for subscription heartbeat")

        // Fetch subscriberID / subscriber currencyCode
        var lastKeepAliveHeartbeat: Date?
        var lastSubscriptionExpiration: Date?
        var subscriberID: Data?
        var currencyCode: Currency.Code?
        databaseStorage.read { transaction in
            lastKeepAliveHeartbeat = self.subscriptionKVS.getDate(self.lastSubscriptionHeartbeatKey, transaction: transaction)
            lastSubscriptionExpiration = self.subscriptionKVS.getDate(self.lastSubscriptionExpirationKey, transaction: transaction)
            subscriberID = self.getSubscriberID(transaction: transaction)
            currencyCode = self.getSubscriberCurrencyCode(transaction: transaction)
        }

        let lastSubscriptionExpirationForLogging: String = {
            guard let lastSubscriptionExpiration = lastSubscriptionExpiration else { return "nil" }
            return String(lastSubscriptionExpiration.timeIntervalSince1970)
        }()
        Logger.info("[Donations] Last subscription expiration: \(lastSubscriptionExpirationForLogging)")

        var performHeartbeat: Bool = true
        if let lastKeepAliveHeartbeat = lastKeepAliveHeartbeat, Date().timeIntervalSince(lastKeepAliveHeartbeat) < heartbeatInterval {
            performHeartbeat = false
        }

        guard performHeartbeat else {
            Logger.info("[Donations] Not performing subscription heartbeat, last heartbeat within allowed interval")
            return
        }

        Logger.info("[Donations] Performing subscription heartbeat")

        guard DependenciesBridge.shared.tsAccountManager.registrationStateWithMaybeSneakyTransaction.isPrimaryDevice ?? false else {
            Logger.info("[Donations] Bailing out of remaining heartbeat tasks, this is not the primary device")
            return
        }

        guard let subscriberID = subscriberID, currencyCode != nil else {
            Logger.info("[Donations] No subscription + currency code found")
            self.updateSubscriptionHeartbeatDate()
            return
        }

        firstly(on: DispatchQueue.global()) {
            self.postSubscriberID(subscriberID: subscriberID)
        }.then(on: DispatchQueue.global()) {
            self.getCurrentSubscriptionStatus(for: subscriberID)
        }.done(on: DispatchQueue.global()) { subscription in
            guard let subscription = subscription else {
                Logger.info("[Donations] No current subscription for this subscriberID")
                self.updateSubscriptionHeartbeatDate()
                return
            }

            if let lastSubscriptionExpiration = lastSubscriptionExpiration, lastSubscriptionExpiration.timeIntervalSince1970 < subscription.endOfCurrentPeriod {
                // Re-kick
                let newDate = Date(timeIntervalSince1970: subscription.endOfCurrentPeriod)
                Logger.info("[Donations] Triggering receipt redemption job during heartbeat, last expiration \(lastSubscriptionExpiration), new expiration \(newDate)")
                self.requestAndRedeemReceiptsIfNecessary(
                    for: subscriberID,
                    usingPaymentProcessor: subscription.paymentProcessor,
                    subscriptionLevel: subscription.level,
                    priorSubscriptionLevel: nil
                )

                // Save last expiration
                databaseStorage.write { transaction in
                    self.setLastSubscriptionExpirationDate(Date(timeIntervalSince1970: subscription.endOfCurrentPeriod), transaction: transaction)
                }
            } else {
                Logger.info("[Donations] Not triggering receipt redemption, expiration date is the same")
            }

            // Save heartbeat
            self.updateSubscriptionHeartbeatDate()

        }.catch(on: DispatchQueue.global()) { error in
            owsFailDebug("Failed subscription heartbeat with error \(error)")
        }
    }

    private static func updateSubscriptionHeartbeatDate() {
        databaseStorage.write { transaction in
            // Update keepalive
            self.subscriptionKVS.setDate(Date(), key: self.lastSubscriptionHeartbeatKey, transaction: transaction)
        }
    }

    @objc
    public class func performDeviceSubscriptionExpiryUpdate() {
        Logger.info("[Donations] doing subscription expiry update")

        var lastSubscriptionExpiration: Date?
        var subscriberID: Data?
        databaseStorage.read { transaction in
            lastSubscriptionExpiration = self.subscriptionKVS.getDate(self.lastSubscriptionExpirationKey, transaction: transaction)
            subscriberID = self.getSubscriberID(transaction: transaction)
        }

        guard let subscriberID = subscriberID else {
            owsFailDebug("Device missing subscriberID")
            return
        }

        firstly(on: DispatchQueue.global()) {
            // Fetch current subscription
            self.getCurrentSubscriptionStatus(for: subscriberID)
        }.done(on: DispatchQueue.global()) { subscription in
            guard let subscription = subscription else {
                Logger.info("[Donations] No current subscription for this subscriberID")
                return
            }

            if let lastSubscriptionExpiration = lastSubscriptionExpiration, lastSubscriptionExpiration.timeIntervalSince1970 == subscription.endOfCurrentPeriod {
                Logger.info("[Donations] Not updating last subscription expiration, expirations are the same")
            } else {
                Logger.info("[Donations] Updating last subscription expiration")
                // Save last expiration
                databaseStorage.write { transaction in
                    self.setLastSubscriptionExpirationDate(Date(timeIntervalSince1970: subscription.endOfCurrentPeriod), transaction: transaction)
                }
            }

        }.catch(on: DispatchQueue.global()) { error in
            owsFailDebug("Failed last subscription expiration update with error \(error)")
        }
    }
}

extension SubscriptionManagerImpl {

    public static func getSubscriberID(transaction: SDSAnyReadTransaction) -> Data? {
        guard let subscriberID = subscriptionKVS.getObject(
            forKey: subscriberIDKey,
            transaction: transaction
        ) as? Data else {
            return nil
        }
        return subscriberID
    }

    public static func setSubscriberID(_ subscriberID: Data?, transaction: SDSAnyWriteTransaction) {
        subscriptionKVS.setObject(subscriberID,
                                  key: subscriberIDKey,
                                  transaction: transaction)
    }

    public static func getSubscriberCurrencyCode(transaction: SDSAnyReadTransaction) -> String? {
        guard let subscriberCurrencyCode = subscriptionKVS.getObject(
            forKey: subscriberCurrencyCodeKey,
            transaction: transaction
        ) as? String else {
            return nil
        }
        return subscriberCurrencyCode
    }

    public static func setSubscriberCurrencyCode(
        _ currencyCode: Currency.Code?,
        transaction: SDSAnyWriteTransaction
    ) {
        subscriptionKVS.setObject(currencyCode,
                                  key: subscriberCurrencyCodeKey,
                                  transaction: transaction)
    }

    public static func setLastReceiptRedemptionFailed(failureReason: SubscriptionRedemptionFailureReason, transaction: SDSAnyWriteTransaction) {
        subscriptionKVS.setInt(failureReason.rawValue, key: lastSubscriptionReceiptRedemptionFailedKey, transaction: transaction)
    }

    public static func lastReceiptRedemptionFailed(transaction: SDSAnyReadTransaction) -> SubscriptionRedemptionFailureReason {
        let intValue = subscriptionKVS.getInt(lastSubscriptionReceiptRedemptionFailedKey, transaction: transaction)
        guard let intValue = intValue else {
            return .none
        }

        if let reason = SubscriptionRedemptionFailureReason(rawValue: intValue) {
            return reason
        } else {
            return .none
        }
    }

    public static func userManuallyCancelledSubscription(transaction: SDSAnyReadTransaction) -> Bool {
        return subscriptionKVS.getBool(userManuallyCancelledSubscriptionKey, transaction: transaction) ?? false
    }

    private static func setUserManuallyCancelledSubscription(_ value: Bool, updateStorageService: Bool = false, transaction: SDSAnyWriteTransaction) {
        guard value != userManuallyCancelledSubscription(transaction: transaction) else { return }
        subscriptionKVS.setBool(value, key: userManuallyCancelledSubscriptionKey, transaction: transaction)
        if updateStorageService {
            storageServiceManager.recordPendingLocalAccountUpdates()
        }
    }

    private static func displayBadgesOnProfile(transaction: SDSAnyReadTransaction) -> Bool {
        return subscriptionKVS.getBool(displayBadgesOnProfileKey, transaction: transaction) ?? false
    }

    private static var displayBadgesOnProfileCache = AtomicBool(false)
    private static func setDisplayBadgesOnProfile(_ value: Bool, updateStorageService: Bool = false, transaction: SDSAnyWriteTransaction) {
        guard value != displayBadgesOnProfile(transaction: transaction) else { return }
        displayBadgesOnProfileCache.set(value)
        subscriptionKVS.setBool(value, key: displayBadgesOnProfileKey, transaction: transaction)
        if updateStorageService {
            storageServiceManager.recordPendingLocalAccountUpdates()
        }
    }

    fileprivate static func lastSubscriptionExpirationDate(transaction: SDSAnyReadTransaction) -> Date? {
        return subscriptionKVS.getDate(lastSubscriptionExpirationKey, transaction: transaction)
    }

    fileprivate static func setLastSubscriptionExpirationDate(_ expirationDate: Date?, transaction: SDSAnyWriteTransaction) {
        guard let expirationDate = expirationDate else {
            subscriptionKVS.removeValue(forKey: lastSubscriptionExpirationKey, transaction: transaction)
            return
        }

        subscriptionKVS.setDate(expirationDate, key: lastSubscriptionExpirationKey, transaction: transaction)
    }

    fileprivate static func setKnownUserSubscriptionBadgeIDs(badgeIDs: [String], transaction: SDSAnyWriteTransaction) {
        subscriptionKVS.setObject(badgeIDs, key: knownUserSubscriptionBadgeIDsKey, transaction: transaction)
    }

    fileprivate static func knownUserSubscriptionBadgeIDs(transaction: SDSAnyReadTransaction) -> [String] {
        let ids = subscriptionKVS.getObject(forKey: knownUserSubscriptionBadgeIDsKey, transaction: transaction) as? [String]
        return ids ?? []
    }

    fileprivate static func setKnownUserBoostBadgeIDs(badgeIDs: [String], transaction: SDSAnyWriteTransaction) {
        subscriptionKVS.setObject(badgeIDs, key: knownUserBoostBadgeIDsKey, transaction: transaction)
    }

    fileprivate static func knownUserBoostBadgeIDs(transaction: SDSAnyReadTransaction) -> [String] {
        guard let ids = subscriptionKVS.getObject(forKey: knownUserBoostBadgeIDsKey, transaction: transaction) as? [String] else {
            return []
        }

        return ids
    }

    fileprivate static func setKnownUserGiftBadgeIDs(badgeIDs: [String], transaction: SDSAnyWriteTransaction) {
        subscriptionKVS.setObject(badgeIDs, key: knownUserGiftBadgeIDsKey, transaction: transaction)
    }

    fileprivate static func knownUserGiftBadgeIDs(transaction: SDSAnyReadTransaction) -> [String] {
        subscriptionKVS.getObject(forKey: knownUserGiftBadgeIDsKey, transaction: transaction) as? [String] ?? []
    }

    fileprivate static func setMostRecentlyExpiredBadgeID(badgeID: String?, transaction: SDSAnyWriteTransaction) {
        guard let badgeID = badgeID else {
            subscriptionKVS.removeValue(forKey: mostRecentlyExpiredBadgeIDKey, transaction: transaction)
            return
        }

        subscriptionKVS.setString(badgeID, key: mostRecentlyExpiredBadgeIDKey, transaction: transaction)

    }

    public static func mostRecentlyExpiredBadgeID(transaction: SDSAnyReadTransaction) -> String? {
        subscriptionKVS.getString(mostRecentlyExpiredBadgeIDKey, transaction: transaction)
    }

    public static func clearMostRecentlyExpiredBadgeIDWithSneakyTransaction() {
        databaseStorage.write { transaction in
            self.setMostRecentlyExpiredBadgeID(badgeID: nil, transaction: transaction)
        }
    }

    fileprivate static func setMostRecentlyExpiredGiftBadgeID(badgeID: String?, transaction: SDSAnyWriteTransaction) {
        if let badgeID = badgeID {
            subscriptionKVS.setString(badgeID, key: mostRecentlyExpiredGiftBadgeIDKey, transaction: transaction)
        } else {
            subscriptionKVS.removeValue(forKey: mostRecentlyExpiredGiftBadgeIDKey, transaction: transaction)
        }
        transaction.addAsyncCompletionOnMain {
            NotificationCenter.default.post(name: .hasExpiredGiftBadgeDidChangeNotification, object: nil)
        }
    }

    public static func mostRecentlyExpiredGiftBadgeID(transaction: SDSAnyReadTransaction) -> String? {
        subscriptionKVS.getString(mostRecentlyExpiredGiftBadgeIDKey, transaction: transaction)
    }

    public static func clearMostRecentlyExpiredGiftBadgeIDWithSneakyTransaction() {
        databaseStorage.write { transaction in
            self.setMostRecentlyExpiredGiftBadgeID(badgeID: nil, transaction: transaction)
        }
    }

    public static func setShowExpirySheetOnHomeScreenKey(show: Bool, transaction: SDSAnyWriteTransaction) {
        Logger.info("\(show)")
        subscriptionKVS.setBool(show, key: showExpirySheetOnHomeScreenKey, transaction: transaction)
    }

    public static func showExpirySheetOnHomeScreenKey(transaction: SDSAnyReadTransaction) -> Bool {
        return subscriptionKVS.getBool(showExpirySheetOnHomeScreenKey, transaction: transaction) ?? false
    }

    public static func setMostRecentSubscriptionPaymentMethod(
        paymentMethod: DonationPaymentMethod?,
        transaction: SDSAnyWriteTransaction
    ) {
        subscriptionKVS.setString(paymentMethod?.rawValue, key: mostRecentSubscriptionPaymentMethodKey, transaction: transaction)
    }

    public static func getMostRecentSubscriptionPaymentMethod(transaction: SDSAnyReadTransaction) -> DonationPaymentMethod? {
        guard let paymentMethodString = subscriptionKVS.getString(mostRecentSubscriptionPaymentMethodKey, transaction: transaction) else {
            return nil
        }

        guard let paymentMethod = DonationPaymentMethod(rawValue: paymentMethodString) else {
            owsFailBeta("Unexpected payment method string: \(paymentMethodString)")
            return nil
        }

        return paymentMethod
    }
}

public class OWSRetryableSubscriptionError: NSObject, CustomNSError, IsRetryableProvider {
    @objc
    public static var asNSError: NSError {
        OWSRetryableSubscriptionError() as Error as NSError
    }

    // MARK: - IsRetryableProvider

    public var isRetryableProvider: Bool { true }
}

extension SubscriptionManagerImpl {
    public class func createAndRedeemBoostReceipt(
        for intentId: String,
        withPaymentProcessor paymentProcessor: PaymentProcessor,
        amount: FiatMoney
    ) {
        let request = generateReceiptRequest()

        // Remove prior operations if one exists (allow prior job to complete)
        for redemptionJob in subscriptionJobQueue.runningOperations.get() {
            if redemptionJob.isBoost {
                redemptionJob.reportError(OWSAssertionError("Job did not complete before next subscription run"))
            }
        }

        databaseStorage.asyncWrite { transaction in
            self.subscriptionJobQueue.addBoostJob(
                amount: amount,
                paymentProcessor: paymentProcessor,
                receiptCredentialRequestContext: request.context.serialize().asData,
                receiptCredentialRequest: request.request.serialize().asData,
                boostPaymentIntentID: intentId,
                transaction: transaction
            )
        }
    }

    public static func requestBoostReceiptCredentialPresentation(
        for intentId: String,
        context: ReceiptCredentialRequestContext,
        request: ReceiptCredentialRequest,
        expectedBadgeLevel: OneTimeBadgeLevel,
        paymentProcessor: PaymentProcessor
    ) throws -> Promise<ReceiptCredentialPresentation> {

        let clientOperations = try clientZKReceiptOperations()

        let request = OWSRequestFactory.boostReceiptCredentials(
            with: intentId,
            for: paymentProcessor.rawValue,
            request: request.serialize().asData
        )

        return firstly {
            networkManager.makePromise(request: request)
        }.map(on: DispatchQueue.global()) { response in
            let statusCode = response.responseStatusCode

            if statusCode == 200 {
                Logger.debug("Got valid receipt response")
            } else if statusCode == 204 {
                Logger.debug("No receipt could be found for this boost payment intent")
                throw OWSRetryableSubscriptionError()
            } else {
                Logger.info("Got undefined non-4xx error fetching boost receipt presentation, retrying!")
                throw OWSRetryableSubscriptionError()
            }

            guard let json = response.responseBodyJson as? [String: Any] else {
                throw OWSAssertionError("Unable to parse response body.")
            }

            guard let parser = ParamParser(responseObject: json) else {
                throw OWSAssertionError("Missing or invalid response.")
            }

            do {
                let receiptCredentialResponseString: String = try parser.required(key: "receiptCredentialResponse")
                guard let receiptCredentialResponseData = Data(base64Encoded: receiptCredentialResponseString) else {
                    throw OWSAssertionError("Unable to parse receiptCredentialResponse into data.")
                }

                let receiptCredentialResponse = try ReceiptCredentialResponse(contents: [UInt8](receiptCredentialResponseData))
                let receiptCredential = try clientOperations.receiveReceiptCredential(receiptCredentialRequestContext: context, receiptCredentialResponse: receiptCredentialResponse)

                // Validate that receipt credential level matches boost level
                let level = try receiptCredential.getReceiptLevel()
                guard level == expectedBadgeLevel.rawValue else {
                    throw OWSAssertionError("Unexpected receipt credential level")
                }

                // Validate receipt credential expiration % 86400 == 0, per server spec
                let expiration = try receiptCredential.getReceiptExpirationTime()
                guard expiration % 86400 == 0 else {
                    throw OWSAssertionError("Invalid receipt credential expiration, expiration mod != 0")
                }

                // Validate expiration is less than 90 days from now
                let maximumValidExpirationDate = Date().timeIntervalSince1970 + (90 * 24 * 60 * 60)
                guard TimeInterval(expiration) < maximumValidExpirationDate else {
                    throw OWSAssertionError("Invalid receipt credential expiration, expiration is more than 90 days from now")
                }

                let receiptCredentialPresentation = try clientOperations.createReceiptCredentialPresentation(receiptCredential: receiptCredential)

                return receiptCredentialPresentation
            } catch {
                throw OWSAssertionError("Missing clientID key")
            }
        }.recover { error -> Promise<ReceiptCredentialPresentation> in
            if let error = error as? OWSHTTPError {
                let statusCode = error.responseStatusCode
                if [400, 402, 409].contains(statusCode) {
                    throw OWSAssertionError("Boost receipt redemption failed with unrecoverable HTTP code \(statusCode)")
                } else {
                    Logger.info("Boost receipt redemption failed with retryable HTTP code \(statusCode)")
                    throw OWSRetryableSubscriptionError()
                }
            }
            throw error
        }
    }

    private static var cachedBadges = [OneTimeBadgeLevel: CachedBadge]()

    public class func getCachedBadge(level: OneTimeBadgeLevel) -> CachedBadge {
        if let cachedBadge = self.cachedBadges[level] {
            return cachedBadge
        }
        let cachedBadge = CachedBadge(level: level)
        self.cachedBadges[level] = cachedBadge
        return cachedBadge
    }

    public class func getBoostBadge() -> Promise<ProfileBadge> {
        firstly {
            getBadge(level: .boostBadge)
        }.map { profileBadge in
            guard let profileBadge = profileBadge else {
                owsFail("No badge for this level was found")
            }
            return profileBadge
        }
    }

    public class func getBadge(level: OneTimeBadgeLevel) -> Promise<ProfileBadge?> {
        firstly { () -> Promise<DonationConfiguration> in
            fetchDonationConfiguration()
        }.map { donationConfiguration -> ProfileBadge? in
            switch level {
            case .boostBadge:
                return donationConfiguration.boost.badge
            case .giftBadge(let level):
                guard donationConfiguration.gift.level == level.rawLevel else {
                    Logger.warn("Requested gift badge with level \(level), which did not match known gift badge with level \(donationConfiguration.gift.level)")
                    return nil
                }

                return donationConfiguration.gift.badge
            }
        }
    }
}

extension SubscriptionManagerImpl: SubscriptionManager {
    public func reconcileBadgeStates(transaction: SDSAnyWriteTransaction) {
        Logger.info("Reconciling badge state.")

        // Get current badges
        let currentBadges = profileManagerImpl.localUserProfile().profileBadgeInfo ?? []
        let currentSubscriberBadgeIDs = currentBadges.compactMap { (badge: OWSUserProfileBadgeInfo) -> String? in
            guard SubscriptionBadgeIds.contains(badge.badgeId) else { return nil }
            return badge.badgeId
        }

        let currentBoostBadgeIDs = currentBadges.compactMap { (badge: OWSUserProfileBadgeInfo) -> String? in
            guard BoostBadgeIds.contains(badge.badgeId) else { return nil }
            return badge.badgeId
        }

        let currentGiftBadgeIDs = currentBadges.compactMap { (badge: OWSUserProfileBadgeInfo) -> String? in
            guard GiftBadgeIds.contains(badge.badgeId) else { return nil }
            return badge.badgeId
        }

        // Read existing values
        let persistedSubscriberBadgeIDs = Self.knownUserSubscriptionBadgeIDs(transaction: transaction)
        let persistedBoostBadgeIDs = Self.knownUserBoostBadgeIDs(transaction: transaction)
        let persistedGiftBadgeIDs = Self.knownUserGiftBadgeIDs(transaction: transaction)
        let oldExpiredGiftBadgeID = Self.mostRecentlyExpiredGiftBadgeID(transaction: transaction)
        var expiringBadgeId = Self.mostRecentlyExpiredBadgeID(transaction: transaction)
        var userManuallyCancelled = Self.userManuallyCancelledSubscription(transaction: transaction)
        var showExpiryOnHomeScreen = Self.showExpirySheetOnHomeScreenKey(transaction: transaction)
        var displayBadgesOnProfile = Self.displayBadgesOnProfile(transaction: transaction)

        let isCurrentlyDisplayingBadgesOnProfile = currentBadges.allSatisfy { badge in
            badge.isVisible ?? {
                owsFailDebug("Local user badges should always have a non-nil visibility flag")
                return true
            }()
        }
        if displayBadgesOnProfile != isCurrentlyDisplayingBadgesOnProfile {
            displayBadgesOnProfile = isCurrentlyDisplayingBadgesOnProfile
            Logger.info("Updating displayBadgesOnProfile to reflect state on profile \(displayBadgesOnProfile)")
        }

        let newSubscriberBadgeIds = Set(currentSubscriberBadgeIDs).subtracting(persistedSubscriberBadgeIDs)
        Logger.info("Learned of \(newSubscriberBadgeIds.count) new subscriber badge ids: \(newSubscriberBadgeIds)")

        let expiredSubscriberBadgeIds = Set(persistedSubscriberBadgeIDs).subtracting(currentSubscriberBadgeIDs)
        Logger.info("Learned of \(expiredSubscriberBadgeIds.count) newly expired subscriber badge ids: \(expiredSubscriberBadgeIds)")

        let newBoostBadgeIds = Set(currentBoostBadgeIDs).subtracting(persistedBoostBadgeIDs)
        Logger.info("Learned of \(newBoostBadgeIds.count) new boost badge ids: \(newBoostBadgeIds)")

        let expiredBoostBadgeIds = Set(persistedBoostBadgeIDs).subtracting(currentBoostBadgeIDs)
        Logger.info("Learned of \(expiredBoostBadgeIds.count) newly expired boost badge ids: \(expiredBoostBadgeIds)")

        let newGiftBadgeIds = Set(currentGiftBadgeIDs).subtracting(persistedGiftBadgeIDs)
        Logger.info("Learned of \(newGiftBadgeIds.count) new gift badge ids: \(newGiftBadgeIds)")

        let expiredGiftBadgeIds = Set(persistedGiftBadgeIDs).subtracting(currentGiftBadgeIDs)
        Logger.info("Learned of \(expiredGiftBadgeIds.count) newly expired gift badge ids: \(expiredGiftBadgeIds)")

        var newExpiringBadgeId: String?
        if let persistedBadgeId = persistedSubscriberBadgeIDs.first, currentSubscriberBadgeIDs.isEmpty {
            if !userManuallyCancelled {
                Logger.info("Last subscription badge id expired \(persistedBadgeId)")
                newExpiringBadgeId = persistedBadgeId
            } else {
                Logger.info("Last subscription badge id expired \(persistedBadgeId), but ignoring because subscription was manually cancelled")
            }
        }

        if let persistedBadgeId = persistedBoostBadgeIDs.first, currentBoostBadgeIDs.isEmpty {
            if (expiringBadgeId == nil || BoostBadgeIds.contains(expiringBadgeId!)) && newExpiringBadgeId == nil {
                Logger.info("Last boost badge id expired \(persistedBadgeId)")
                newExpiringBadgeId = persistedBadgeId
            } else {
                Logger.info("Last boost badge id expired \(persistedBadgeId), but ignoring because subscription badge also expired")
            }
        }

        if let newExpiringBadgeId = newExpiringBadgeId, newExpiringBadgeId != expiringBadgeId {
            Logger.info("Recording new expired badge id to show on home screen \(newExpiringBadgeId)")
            expiringBadgeId = newExpiringBadgeId
            showExpiryOnHomeScreen = true
        } else if let oldExpiringBadgeId = expiringBadgeId {
            if SubscriptionBadgeIds.contains(oldExpiringBadgeId), !newSubscriberBadgeIds.isEmpty {
                Logger.info("Clearing expired subscription badge id \(oldExpiringBadgeId), new subscription badge found.")
                expiringBadgeId = nil
                showExpiryOnHomeScreen = false
            } else if BoostBadgeIds.contains(oldExpiringBadgeId), !newBoostBadgeIds.isEmpty {
                Logger.info("Clearing expired boost badge id \(oldExpiringBadgeId), new boost badge found.")
                expiringBadgeId = nil
                showExpiryOnHomeScreen = false
            }
        }

        if userManuallyCancelled, !newSubscriberBadgeIds.isEmpty {
            Logger.info("Clearing manual subscription cancellation, new subscription badge found.")
            userManuallyCancelled = false
        }

        let newExpiredGiftBadgeID: String?
        if currentGiftBadgeIDs.isEmpty {
            // If you don't have any remaining gift badges, show (a) the badge that
            // *just* expired, (b) a gift that expired during a previous call to
            // reconcile badge states, or (c) nothing. Most users will fall into (c).
            newExpiredGiftBadgeID = expiredGiftBadgeIds.first ?? oldExpiredGiftBadgeID ?? nil
        } else {
            // If you have a gift badge, don't show any expiration about gift badges.
            // Perhaps you redeemed another gift before we displayed the sheet.
            newExpiredGiftBadgeID = nil
        }

        Logger.info("""
        Reconciled badge state:
            Subscriber Badge Ids: \(currentSubscriberBadgeIDs)
            Boost Badge Ids: \(currentBoostBadgeIDs)
            Gift Badge Ids: \(currentGiftBadgeIDs)
            Most Recently Expired Badge Id: \(expiringBadgeId ?? "nil")
            Expired Gift Badge Id: \(newExpiredGiftBadgeID ?? "nil")
            Show Expiry On Home Screen: \(showExpiryOnHomeScreen)
            User Manually Cancelled Subscription: \(userManuallyCancelled)
            Display Badges On Profile: \(displayBadgesOnProfile)
        """)

        // Persist new values
        Self.setKnownUserSubscriptionBadgeIDs(badgeIDs: currentSubscriberBadgeIDs, transaction: transaction)
        Self.setKnownUserBoostBadgeIDs(badgeIDs: currentBoostBadgeIDs, transaction: transaction)
        Self.setKnownUserGiftBadgeIDs(badgeIDs: currentGiftBadgeIDs, transaction: transaction)
        Self.setMostRecentlyExpiredGiftBadgeID(badgeID: newExpiredGiftBadgeID, transaction: transaction)
        Self.setMostRecentlyExpiredBadgeID(badgeID: expiringBadgeId, transaction: transaction)
        Self.setShowExpirySheetOnHomeScreenKey(show: showExpiryOnHomeScreen, transaction: transaction)
        Self.setUserManuallyCancelledSubscription(userManuallyCancelled, transaction: transaction)
        Self.setDisplayBadgesOnProfile(displayBadgesOnProfile, transaction: transaction)
    }

    public func hasCurrentSubscription(transaction: SDSAnyReadTransaction) -> Bool {
        guard !Self.currentProfileSubscriptionBadges().isEmpty else { return false }

        guard Self.getSubscriberID(transaction: transaction) != nil else { return false }

        guard let lastSubscriptionExpiryDate = Self.lastSubscriptionExpirationDate(transaction: transaction) else {
            return false
        }

        return lastSubscriptionExpiryDate.isAfterNow
    }

    public func timeSinceLastSubscriptionExpiration(transaction: SDSAnyReadTransaction) -> TimeInterval {
        guard let lastSubscriptionExpiryDate = Self.lastSubscriptionExpirationDate(transaction: transaction) else {
            return -Date.distantPast.timeIntervalSinceNow
        }

        guard lastSubscriptionExpiryDate.isBeforeNow else {
            return 0
        }

        return -lastSubscriptionExpiryDate.timeIntervalSinceNow
    }

    public func userManuallyCancelledSubscription(transaction: SDSAnyReadTransaction) -> Bool {
        return Self.userManuallyCancelledSubscription(transaction: transaction)
    }

    public func setUserManuallyCancelledSubscription(_ userCancelled: Bool, updateStorageService: Bool, transaction: SDSAnyWriteTransaction) {
        Self.setUserManuallyCancelledSubscription(userCancelled, updateStorageService: updateStorageService, transaction: transaction)
    }

    public var displayBadgesOnProfile: Bool { Self.displayBadgesOnProfileCache.get() }

    public func displayBadgesOnProfile(transaction: SDSAnyReadTransaction) -> Bool {
        return Self.displayBadgesOnProfile(transaction: transaction)
    }

    public func setDisplayBadgesOnProfile(_ displayBadgesOnProfile: Bool, updateStorageService: Bool, transaction: SDSAnyWriteTransaction) {
        Self.setDisplayBadgesOnProfile(displayBadgesOnProfile, updateStorageService: updateStorageService, transaction: transaction)
    }
}
