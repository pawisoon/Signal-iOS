//
// Copyright 2021 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

// Exposes singleton accessors.
//
// Swift classes which do not subclass NSObject can implement Dependencies protocol.

public protocol Dependencies {}

// MARK: - NSObject

@objc
public extension NSObject {
    final var attachmentDownloads: OWSAttachmentDownloads {
        SSKEnvironment.shared.attachmentDownloadsRef
    }

    static var attachmentDownloads: OWSAttachmentDownloads {
        SSKEnvironment.shared.attachmentDownloadsRef
    }

    final var blockingManager: BlockingManager {
        .shared
    }

    static var blockingManager: BlockingManager {
        .shared
    }

    @nonobjc
    final var bulkProfileFetch: BulkProfileFetch {
        SSKEnvironment.shared.bulkProfileFetchRef
    }

    @nonobjc
    static var bulkProfileFetch: BulkProfileFetch {
        SSKEnvironment.shared.bulkProfileFetchRef
    }

    final var databaseStorage: SDSDatabaseStorage {
        SDSDatabaseStorage.shared
    }

    static var databaseStorage: SDSDatabaseStorage {
        SDSDatabaseStorage.shared
    }

    final var disappearingMessagesJob: OWSDisappearingMessagesJob {
        SSKEnvironment.shared.disappearingMessagesJobRef
    }

    static var disappearingMessagesJob: OWSDisappearingMessagesJob {
        SSKEnvironment.shared.disappearingMessagesJobRef
    }

    final var groupV2UpdatesObjc: GroupV2Updates {
        SSKEnvironment.shared.groupV2UpdatesRef
    }

    static var groupV2UpdatesObjc: GroupV2Updates {
        SSKEnvironment.shared.groupV2UpdatesRef
    }

    final var linkPreviewManager: OWSLinkPreviewManager {
        SSKEnvironment.shared.linkPreviewManagerRef
    }

    static var linkPreviewManager: OWSLinkPreviewManager {
        SSKEnvironment.shared.linkPreviewManagerRef
    }

    final var messageFetcherJob: MessageFetcherJob {
        SSKEnvironment.shared.messageFetcherJobRef
    }

    static var messageFetcherJob: MessageFetcherJob {
        SSKEnvironment.shared.messageFetcherJobRef
    }

    @nonobjc
    final var messageReceiver: MessageReceiver {
        SSKEnvironment.shared.messageReceiverRef
    }

    @nonobjc
    static var messageReceiver: MessageReceiver {
        SSKEnvironment.shared.messageReceiverRef
    }

    @nonobjc
    final var messageSender: MessageSender {
        SSKEnvironment.shared.messageSenderRef
    }

    @nonobjc
    static var messageSender: MessageSender {
        SSKEnvironment.shared.messageSenderRef
    }

    final var messagePipelineSupervisor: MessagePipelineSupervisor {
        SSKEnvironment.shared.messagePipelineSupervisorRef
    }

    static var messagePipelineSupervisor: MessagePipelineSupervisor {
        SSKEnvironment.shared.messagePipelineSupervisorRef
    }

    final var networkManager: NetworkManager {
        SSKEnvironment.shared.networkManagerRef
    }

    static var networkManager: NetworkManager {
        SSKEnvironment.shared.networkManagerRef
    }

    final var notificationsManager: NotificationsProtocol {
        SSKEnvironment.shared.notificationsManagerRef
    }

    static var notificationsManager: NotificationsProtocol {
        SSKEnvironment.shared.notificationsManagerRef
    }

    final var ows2FAManager: OWS2FAManager {
        .shared
    }

    static var ows2FAManager: OWS2FAManager {
        .shared
    }

    final var receiptManager: OWSReceiptManager {
        .shared
    }

    static var receiptManager: OWSReceiptManager {
        .shared
    }

    final var profileManager: ProfileManagerProtocol {
        SSKEnvironment.shared.profileManagerRef
    }

    static var profileManager: ProfileManagerProtocol {
        SSKEnvironment.shared.profileManagerRef
    }

    final var reachabilityManager: SSKReachabilityManager {
        SSKEnvironment.shared.reachabilityManagerRef
    }

    static var reachabilityManager: SSKReachabilityManager {
        SSKEnvironment.shared.reachabilityManagerRef
    }

    final var storageCoordinator: StorageCoordinator {
        SSKEnvironment.shared.storageCoordinatorRef
    }

    static var storageCoordinator: StorageCoordinator {
        SSKEnvironment.shared.storageCoordinatorRef
    }

    final var syncManager: SyncManagerProtocol {
        SSKEnvironment.shared.syncManagerRef
    }

    static var syncManager: SyncManagerProtocol {
        SSKEnvironment.shared.syncManagerRef
    }

    final var typingIndicatorsImpl: TypingIndicators {
        SSKEnvironment.shared.typingIndicatorsRef
    }

    static var typingIndicatorsImpl: TypingIndicators {
        SSKEnvironment.shared.typingIndicatorsRef
    }

    @nonobjc
    final var udManager: OWSUDManager {
        SSKEnvironment.shared.udManagerRef
    }

    @nonobjc
    static var udManager: OWSUDManager {
        SSKEnvironment.shared.udManagerRef
    }

    final var contactsManager: ContactsManagerProtocol {
        SSKEnvironment.shared.contactsManagerRef
    }

    static var contactsManager: ContactsManagerProtocol {
        SSKEnvironment.shared.contactsManagerRef
    }

    final var storageServiceManagerObjc: StorageServiceManagerObjc {
        SSKEnvironment.shared.storageServiceManagerRef
    }

    static var storageServiceManagerObjc: StorageServiceManagerObjc {
        SSKEnvironment.shared.storageServiceManagerRef
    }

    final var modelReadCaches: ModelReadCaches {
        SSKEnvironment.shared.modelReadCachesRef
    }

    static var modelReadCaches: ModelReadCaches {
        SSKEnvironment.shared.modelReadCachesRef
    }

    final var messageProcessor: MessageProcessor {
        SSKEnvironment.shared.messageProcessorRef
    }

    static var messageProcessor: MessageProcessor {
        SSKEnvironment.shared.messageProcessorRef
    }

    final var groupsV2: GroupsV2 {
        SSKEnvironment.shared.groupsV2Ref
    }

    static var groupsV2: GroupsV2 {
        SSKEnvironment.shared.groupsV2Ref
    }

    @nonobjc
    final var signalService: OWSSignalServiceProtocol {
        SSKEnvironment.shared.signalServiceRef
    }

    @nonobjc
    static var signalService: OWSSignalServiceProtocol {
        SSKEnvironment.shared.signalServiceRef
    }

    final var accountServiceClient: AccountServiceClient {
        SSKEnvironment.shared.accountServiceClientRef
    }

    static var accountServiceClient: AccountServiceClient {
        SSKEnvironment.shared.accountServiceClientRef
    }

    final var groupsV2MessageProcessor: GroupsV2MessageProcessor {
        SSKEnvironment.shared.groupsV2MessageProcessorRef
    }

    static var groupsV2MessageProcessor: GroupsV2MessageProcessor {
        SSKEnvironment.shared.groupsV2MessageProcessorRef
    }

    final var versionedProfiles: VersionedProfiles {
        SSKEnvironment.shared.versionedProfilesRef
    }

    static var versionedProfiles: VersionedProfiles {
        SSKEnvironment.shared.versionedProfilesRef
    }

    final var grdbStorageAdapter: GRDBDatabaseStorageAdapter {
        databaseStorage.grdbStorage
    }

    static var grdbStorageAdapter: GRDBDatabaseStorageAdapter {
        databaseStorage.grdbStorage
    }

    final var signalServiceAddressCache: SignalServiceAddressCache {
        SSKEnvironment.shared.signalServiceAddressCacheRef
    }

    static var signalServiceAddressCache: SignalServiceAddressCache {
        SSKEnvironment.shared.signalServiceAddressCacheRef
    }

    final var messageDecrypter: OWSMessageDecrypter {
        SSKEnvironment.shared.messageDecrypterRef
    }

    static var messageDecrypter: OWSMessageDecrypter {
        SSKEnvironment.shared.messageDecrypterRef
    }

    final var outgoingReceiptManager: OWSOutgoingReceiptManager {
        SSKEnvironment.shared.outgoingReceiptManagerRef
    }

    static var outgoingReceiptManager: OWSOutgoingReceiptManager {
        SSKEnvironment.shared.outgoingReceiptManagerRef
    }

    final var earlyMessageManager: EarlyMessageManager {
        SSKEnvironment.shared.earlyMessageManagerRef
    }

    static var earlyMessageManager: EarlyMessageManager {
        SSKEnvironment.shared.earlyMessageManagerRef
    }

    // This singleton is configured after the environments are created.
    final var callMessageHandler: OWSCallMessageHandler? {
        SSKEnvironment.shared.callMessageHandlerRef
    }

    // This singleton is configured after the environments are created.
    static var callMessageHandler: OWSCallMessageHandler? {
        SSKEnvironment.shared.callMessageHandlerRef
    }

    final var pendingReceiptRecorder: PendingReceiptRecorder {
        SSKEnvironment.shared.pendingReceiptRecorderRef
    }

    static var pendingReceiptRecorder: PendingReceiptRecorder {
        SSKEnvironment.shared.pendingReceiptRecorderRef
    }

    final var outageDetection: OutageDetection {
        .shared
    }

    static var outageDetection: OutageDetection {
        .shared
    }

    final var notificationPresenter: NotificationsProtocol {
        SSKEnvironment.shared.notificationsManager
    }

    static var notificationPresenter: NotificationsProtocol {
        SSKEnvironment.shared.notificationsManager
    }

    final var paymentsHelper: PaymentsHelper {
        SSKEnvironment.shared.paymentsHelperRef
    }

    static var paymentsHelper: PaymentsHelper {
        SSKEnvironment.shared.paymentsHelperRef
    }

    final var paymentsCurrencies: PaymentsCurrencies {
        SSKEnvironment.shared.paymentsCurrenciesRef
    }

    static var paymentsCurrencies: PaymentsCurrencies {
        SSKEnvironment.shared.paymentsCurrenciesRef
    }

    final var paymentsEvents: PaymentsEvents {
        SSKEnvironment.shared.paymentsEventsRef
    }

    static var paymentsEvents: PaymentsEvents {
        SSKEnvironment.shared.paymentsEventsRef
    }

    final var spamChallengeResolver: SpamChallengeResolver {
        SSKEnvironment.shared.spamChallengeResolverRef
    }

    static var spamChallengeResolver: SpamChallengeResolver {
        SSKEnvironment.shared.spamChallengeResolverRef
    }

    final var senderKeyStore: SenderKeyStore {
        SSKEnvironment.shared.senderKeyStoreRef
    }

    static var senderKeyStore: SenderKeyStore {
        SSKEnvironment.shared.senderKeyStoreRef
    }

    final var phoneNumberUtil: PhoneNumberUtil {
        SSKEnvironment.shared.phoneNumberUtilRef
    }

    static var phoneNumberUtil: PhoneNumberUtil {
        SSKEnvironment.shared.phoneNumberUtilRef
    }

    var legacyChangePhoneNumber: LegacyChangePhoneNumber {
        SSKEnvironment.shared.legacyChangePhoneNumberRef
    }

    static var legacyChangePhoneNumber: LegacyChangePhoneNumber {
        SSKEnvironment.shared.legacyChangePhoneNumberRef
    }

    var subscriptionManager: SubscriptionManager {
        SSKEnvironment.shared.subscriptionManagerRef
    }

    static var subscriptionManager: SubscriptionManager {
        SSKEnvironment.shared.subscriptionManagerRef
    }

    @nonobjc
    var systemStoryManager: SystemStoryManagerProtocol {
        SSKEnvironment.shared.systemStoryManagerRef
    }

    @nonobjc
    static var systemStoryManager: SystemStoryManagerProtocol {
        SSKEnvironment.shared.systemStoryManagerRef
    }

    var sskJobQueues: SSKJobQueues {
        SSKEnvironment.shared.sskJobQueuesRef
    }

    static var sskJobQueues: SSKJobQueues {
        SSKEnvironment.shared.sskJobQueuesRef
    }

    @nonobjc
    var contactDiscoveryManager: ContactDiscoveryManager {
        SSKEnvironment.shared.contactDiscoveryManagerRef
    }

    @nonobjc
    static var contactDiscoveryManager: ContactDiscoveryManager {
        SSKEnvironment.shared.contactDiscoveryManagerRef
    }
}

public extension NSObject {

    final var storageServiceManager: StorageServiceManager {
        SSKEnvironment.shared.storageServiceManagerRef
    }

    static var storageServiceManager: StorageServiceManager {
        SSKEnvironment.shared.storageServiceManagerRef
    }

    final var remoteConfigManager: RemoteConfigManager {
        SSKEnvironment.shared.remoteConfigManagerRef
    }

    static var remoteConfigManager: RemoteConfigManager {
        SSKEnvironment.shared.remoteConfigManagerRef
    }
}

// MARK: - Obj-C Dependencies

public extension Dependencies {

    var attachmentDownloads: OWSAttachmentDownloads {
        SSKEnvironment.shared.attachmentDownloadsRef
    }

    static var attachmentDownloads: OWSAttachmentDownloads {
        SSKEnvironment.shared.attachmentDownloadsRef
    }

    var blockingManager: BlockingManager {
        .shared
    }

    static var blockingManager: BlockingManager {
        .shared
    }

    var bulkProfileFetch: BulkProfileFetch {
        SSKEnvironment.shared.bulkProfileFetchRef
    }

    static var bulkProfileFetch: BulkProfileFetch {
        SSKEnvironment.shared.bulkProfileFetchRef
    }

    var databaseStorage: SDSDatabaseStorage {
        SDSDatabaseStorage.shared
    }

    static var databaseStorage: SDSDatabaseStorage {
        SDSDatabaseStorage.shared
    }

    var disappearingMessagesJob: OWSDisappearingMessagesJob {
        SSKEnvironment.shared.disappearingMessagesJobRef
    }

    static var disappearingMessagesJob: OWSDisappearingMessagesJob {
        SSKEnvironment.shared.disappearingMessagesJobRef
    }

    var groupV2UpdatesObjc: GroupV2Updates {
        SSKEnvironment.shared.groupV2UpdatesRef
    }

    static var groupV2UpdatesObjc: GroupV2Updates {
        SSKEnvironment.shared.groupV2UpdatesRef
    }

    var linkPreviewManager: OWSLinkPreviewManager {
        SSKEnvironment.shared.linkPreviewManagerRef
    }

    static var linkPreviewManager: OWSLinkPreviewManager {
        SSKEnvironment.shared.linkPreviewManagerRef
    }

    var messageFetcherJob: MessageFetcherJob {
        SSKEnvironment.shared.messageFetcherJobRef
    }

    static var messageFetcherJob: MessageFetcherJob {
        SSKEnvironment.shared.messageFetcherJobRef
    }

    @nonobjc
    var messageReceiver: MessageReceiver {
        SSKEnvironment.shared.messageReceiverRef
    }

    @nonobjc
    static var messageReceiver: MessageReceiver {
        SSKEnvironment.shared.messageReceiverRef
    }

    var messageSender: MessageSender {
        SSKEnvironment.shared.messageSenderRef
    }

    static var messageSender: MessageSender {
        SSKEnvironment.shared.messageSenderRef
    }

    var messagePipelineSupervisor: MessagePipelineSupervisor {
        SSKEnvironment.shared.messagePipelineSupervisorRef
    }

    static var messagePipelineSupervisor: MessagePipelineSupervisor {
        SSKEnvironment.shared.messagePipelineSupervisorRef
    }

    var networkManager: NetworkManager {
        SSKEnvironment.shared.networkManagerRef
    }

    static var networkManager: NetworkManager {
        SSKEnvironment.shared.networkManagerRef
    }

    // This singleton is configured after the environments are created.
    var notificationsManager: NotificationsProtocol {
        SSKEnvironment.shared.notificationsManagerRef
    }

    // This singleton is configured after the environments are created.
    static var notificationsManager: NotificationsProtocol {
        SSKEnvironment.shared.notificationsManagerRef
    }

    var ows2FAManager: OWS2FAManager {
        .shared
    }

    static var ows2FAManager: OWS2FAManager {
        .shared
    }

    var receiptManager: OWSReceiptManager {
        .shared
    }

    static var receiptManager: OWSReceiptManager {
        .shared
    }

    var profileManager: ProfileManagerProtocol {
        SSKEnvironment.shared.profileManagerRef
    }

    static var profileManager: ProfileManagerProtocol {
        SSKEnvironment.shared.profileManagerRef
    }

    var reachabilityManager: SSKReachabilityManager {
        SSKEnvironment.shared.reachabilityManagerRef
    }

    static var reachabilityManager: SSKReachabilityManager {
        SSKEnvironment.shared.reachabilityManagerRef
    }

    var storageCoordinator: StorageCoordinator {
        SSKEnvironment.shared.storageCoordinatorRef
    }

    static var storageCoordinator: StorageCoordinator {
        SSKEnvironment.shared.storageCoordinatorRef
    }

    var syncManager: SyncManagerProtocol {
        SSKEnvironment.shared.syncManagerRef
    }

    static var syncManager: SyncManagerProtocol {
        SSKEnvironment.shared.syncManagerRef
    }

    var typingIndicatorsImpl: TypingIndicators {
        SSKEnvironment.shared.typingIndicatorsRef
    }

    static var typingIndicatorsImpl: TypingIndicators {
        SSKEnvironment.shared.typingIndicatorsRef
    }

    var udManager: OWSUDManager {
        SSKEnvironment.shared.udManagerRef
    }

    static var udManager: OWSUDManager {
        SSKEnvironment.shared.udManagerRef
    }

    var contactsManager: ContactsManagerProtocol {
        SSKEnvironment.shared.contactsManagerRef
    }

    static var contactsManager: ContactsManagerProtocol {
        SSKEnvironment.shared.contactsManagerRef
    }

    var storageServiceManager: StorageServiceManager {
        SSKEnvironment.shared.storageServiceManagerRef
    }

    static var storageServiceManager: StorageServiceManager {
        SSKEnvironment.shared.storageServiceManagerRef
    }

    var modelReadCaches: ModelReadCaches {
        SSKEnvironment.shared.modelReadCachesRef
    }

    static var modelReadCaches: ModelReadCaches {
        SSKEnvironment.shared.modelReadCachesRef
    }

    var messageProcessor: MessageProcessor {
        SSKEnvironment.shared.messageProcessorRef
    }

    static var messageProcessor: MessageProcessor {
        SSKEnvironment.shared.messageProcessorRef
    }

    var remoteConfigManager: RemoteConfigManager {
        SSKEnvironment.shared.remoteConfigManagerRef
    }

    static var remoteConfigManager: RemoteConfigManager {
        SSKEnvironment.shared.remoteConfigManagerRef
    }

    var groupsV2: GroupsV2 {
        SSKEnvironment.shared.groupsV2Ref
    }

    static var groupsV2: GroupsV2 {
        SSKEnvironment.shared.groupsV2Ref
    }

    var signalService: OWSSignalServiceProtocol {
        SSKEnvironment.shared.signalServiceRef
    }

    static var signalService: OWSSignalServiceProtocol {
        SSKEnvironment.shared.signalServiceRef
    }

    var accountServiceClient: AccountServiceClient {
        SSKEnvironment.shared.accountServiceClientRef
    }

    static var accountServiceClient: AccountServiceClient {
        SSKEnvironment.shared.accountServiceClientRef
    }

    var groupsV2MessageProcessor: GroupsV2MessageProcessor {
        SSKEnvironment.shared.groupsV2MessageProcessorRef
    }

    static var groupsV2MessageProcessor: GroupsV2MessageProcessor {
        SSKEnvironment.shared.groupsV2MessageProcessorRef
    }

    var versionedProfiles: VersionedProfiles {
        SSKEnvironment.shared.versionedProfilesRef
    }

    static var versionedProfiles: VersionedProfiles {
        SSKEnvironment.shared.versionedProfilesRef
    }

    var grdbStorageAdapter: GRDBDatabaseStorageAdapter {
        databaseStorage.grdbStorage
    }

    static var grdbStorageAdapter: GRDBDatabaseStorageAdapter {
        databaseStorage.grdbStorage
    }

    var signalServiceAddressCache: SignalServiceAddressCache {
        SSKEnvironment.shared.signalServiceAddressCacheRef
    }

    static var signalServiceAddressCache: SignalServiceAddressCache {
        SSKEnvironment.shared.signalServiceAddressCacheRef
    }

    var messageDecrypter: OWSMessageDecrypter {
        SSKEnvironment.shared.messageDecrypterRef
    }

    static var messageDecrypter: OWSMessageDecrypter {
        SSKEnvironment.shared.messageDecrypterRef
    }

    var outgoingReceiptManager: OWSOutgoingReceiptManager {
        SSKEnvironment.shared.outgoingReceiptManagerRef
    }

    static var outgoingReceiptManager: OWSOutgoingReceiptManager {
        SSKEnvironment.shared.outgoingReceiptManagerRef
    }

    var earlyMessageManager: EarlyMessageManager {
        SSKEnvironment.shared.earlyMessageManagerRef
    }

    static var earlyMessageManager: EarlyMessageManager {
        SSKEnvironment.shared.earlyMessageManagerRef
    }

    // This singleton is configured after the environments are created.
    var callMessageHandler: OWSCallMessageHandler? {
        SSKEnvironment.shared.callMessageHandlerRef
    }

    // This singleton is configured after the environments are created.
    static var callMessageHandler: OWSCallMessageHandler? {
        SSKEnvironment.shared.callMessageHandlerRef
    }

    var pendingReceiptRecorder: PendingReceiptRecorder {
        SSKEnvironment.shared.pendingReceiptRecorderRef
    }

    static var pendingReceiptRecorder: PendingReceiptRecorder {
        SSKEnvironment.shared.pendingReceiptRecorderRef
    }

    var outageDetection: OutageDetection {
        .shared
    }

    static var outageDetection: OutageDetection {
        .shared
    }

    var notificationPresenter: NotificationsProtocol {
        SSKEnvironment.shared.notificationsManager
    }

    static var notificationPresenter: NotificationsProtocol {
        SSKEnvironment.shared.notificationsManager
    }

    var paymentsHelper: PaymentsHelper {
        SSKEnvironment.shared.paymentsHelperRef
    }

    static var paymentsHelper: PaymentsHelper {
        SSKEnvironment.shared.paymentsHelperRef
    }

    var paymentsCurrencies: PaymentsCurrencies {
        SSKEnvironment.shared.paymentsCurrenciesRef
    }

    static var paymentsCurrencies: PaymentsCurrencies {
        SSKEnvironment.shared.paymentsCurrenciesRef
    }

    var paymentsEvents: PaymentsEvents {
        SSKEnvironment.shared.paymentsEventsRef
    }

    static var paymentsEvents: PaymentsEvents {
        SSKEnvironment.shared.paymentsEventsRef
    }

    var mobileCoinHelper: MobileCoinHelper {
        SSKEnvironment.shared.mobileCoinHelperRef
    }

    static var mobileCoinHelper: MobileCoinHelper {
        SSKEnvironment.shared.mobileCoinHelperRef
    }

    var spamChallengeResolver: SpamChallengeResolver {
        SSKEnvironment.shared.spamChallengeResolverRef
    }

    static var spamChallengeResolver: SpamChallengeResolver {
        SSKEnvironment.shared.spamChallengeResolverRef
    }

    var senderKeyStore: SenderKeyStore {
        SSKEnvironment.shared.senderKeyStoreRef
    }

    static var senderKeyStore: SenderKeyStore {
        SSKEnvironment.shared.senderKeyStoreRef
    }

    var phoneNumberUtil: PhoneNumberUtil {
        SSKEnvironment.shared.phoneNumberUtilRef
    }

    static var phoneNumberUtil: PhoneNumberUtil {
        SSKEnvironment.shared.phoneNumberUtilRef
    }

    var webSocketFactory: WebSocketFactory {
        SSKEnvironment.shared.webSocketFactoryRef
    }

    static var webSocketFactory: WebSocketFactory {
        SSKEnvironment.shared.webSocketFactoryRef
    }

    var legacyChangePhoneNumber: LegacyChangePhoneNumber {
        SSKEnvironment.shared.legacyChangePhoneNumberRef
    }

    static var legacyChangePhoneNumber: LegacyChangePhoneNumber {
        SSKEnvironment.shared.legacyChangePhoneNumberRef
    }

    var subscriptionManager: SubscriptionManager {
        SSKEnvironment.shared.subscriptionManagerRef
    }

    static var subscriptionManager: SubscriptionManager {
        SSKEnvironment.shared.subscriptionManagerRef
    }

    var systemStoryManager: SystemStoryManagerProtocol {
        SSKEnvironment.shared.systemStoryManagerRef
    }

    static var systemStoryManager: SystemStoryManagerProtocol {
        SSKEnvironment.shared.systemStoryManagerRef
    }

    var sskJobQueues: SSKJobQueues {
        SSKEnvironment.shared.sskJobQueuesRef
    }

    static var sskJobQueues: SSKJobQueues {
        SSKEnvironment.shared.sskJobQueuesRef
    }

    var contactDiscoveryManager: ContactDiscoveryManager {
        SSKEnvironment.shared.contactDiscoveryManagerRef
    }

    static var contactDiscoveryManager: ContactDiscoveryManager {
        SSKEnvironment.shared.contactDiscoveryManagerRef
    }
}

// MARK: - Swift-only Dependencies

public extension NSObject {

    final var groupsV2Swift: GroupsV2Swift {
        SSKEnvironment.shared.groupsV2Ref
    }

    static var groupsV2Swift: GroupsV2Swift {
        SSKEnvironment.shared.groupsV2Ref
    }

    final var groupV2Updates: GroupV2UpdatesSwift {
        SSKEnvironment.shared.groupV2UpdatesRef
    }

    static var groupV2Updates: GroupV2UpdatesSwift {
        SSKEnvironment.shared.groupV2UpdatesRef
    }

    final var serviceClient: SignalServiceClient {
        SignalServiceRestClient.shared
    }

    static var serviceClient: SignalServiceClient {
        SignalServiceRestClient.shared
    }

    final var paymentsHelperSwift: PaymentsHelperSwift {
        SSKEnvironment.shared.paymentsHelperRef
    }

    static var paymentsHelperSwift: PaymentsHelperSwift {
        SSKEnvironment.shared.paymentsHelperRef
    }

    final var paymentsCurrenciesSwift: PaymentsCurrenciesSwift {
        SSKEnvironment.shared.paymentsCurrenciesRef
    }

    static var paymentsCurrenciesSwift: PaymentsCurrenciesSwift {
        SSKEnvironment.shared.paymentsCurrenciesRef
    }

    var versionedProfilesSwift: VersionedProfilesSwift {
        SSKEnvironment.shared.versionedProfilesRef
    }

    static var versionedProfilesSwift: VersionedProfilesSwift {
        SSKEnvironment.shared.versionedProfilesRef
    }
}

// MARK: - Swift-only Dependencies

public extension Dependencies {

    var groupsV2Swift: GroupsV2Swift {
        SSKEnvironment.shared.groupsV2Ref
    }

    static var groupsV2Swift: GroupsV2Swift {
        SSKEnvironment.shared.groupsV2Ref
    }

    var groupV2Updates: GroupV2UpdatesSwift {
        SSKEnvironment.shared.groupV2UpdatesRef
    }

    static var groupV2Updates: GroupV2UpdatesSwift {
        SSKEnvironment.shared.groupV2UpdatesRef
    }

    var serviceClient: SignalServiceClient {
        SignalServiceRestClient.shared
    }

    static var serviceClient: SignalServiceClient {
        SignalServiceRestClient.shared
    }

    var paymentsHelperSwift: PaymentsHelperSwift {
        SSKEnvironment.shared.paymentsHelperRef
    }

    static var paymentsHelperSwift: PaymentsHelperSwift {
        SSKEnvironment.shared.paymentsHelperRef
    }

    var paymentsCurrenciesSwift: PaymentsCurrenciesSwift {
        SSKEnvironment.shared.paymentsCurrenciesRef
    }

    static var paymentsCurrenciesSwift: PaymentsCurrenciesSwift {
        SSKEnvironment.shared.paymentsCurrenciesRef
    }

    var versionedProfilesSwift: VersionedProfilesSwift {
        SSKEnvironment.shared.versionedProfilesRef
    }

    static var versionedProfilesSwift: VersionedProfilesSwift {
        SSKEnvironment.shared.versionedProfilesRef
    }
}

// MARK: -

@objc
public extension BlockingManager {
    static var shared: BlockingManager {
        SSKEnvironment.shared.blockingManagerRef
    }
}

// MARK: -

@objc
public extension SDSDatabaseStorage {
    static var shared: SDSDatabaseStorage {
        SSKEnvironment.shared.databaseStorageRef
    }
}

// MARK: -

@objc
public extension OWS2FAManager {
    static var shared: OWS2FAManager {
        SSKEnvironment.shared.ows2FAManagerRef
    }
}

// MARK: -

@objc
public extension OWSReceiptManager {
    static var shared: OWSReceiptManager {
        SSKEnvironment.shared.receiptManagerRef
    }
}

// MARK: -

@objc
public extension StickerManager {
    static var shared: StickerManager {
        SSKEnvironment.shared.stickerManagerRef
    }
}

// MARK: -

@objc
public extension ModelReadCaches {
    static var shared: ModelReadCaches {
        SSKEnvironment.shared.modelReadCachesRef
    }
}

// MARK: -

@objc
public extension SSKPreferences {
    static var shared: SSKPreferences {
        SSKEnvironment.shared.sskPreferencesRef
    }
}

// MARK: -

@objc
public extension MessageProcessor {
    static var shared: MessageProcessor {
        SSKEnvironment.shared.messageProcessorRef
    }
}

// MARK: -

@objc
public extension NetworkManager {
    static var shared: NetworkManager {
        SSKEnvironment.shared.networkManagerRef
    }
}

// MARK: -

@objc
public extension OWSOutgoingReceiptManager {
    static var shared: OWSOutgoingReceiptManager {
        SSKEnvironment.shared.outgoingReceiptManagerRef
    }
}

// MARK: -

@objc
public extension OWSDisappearingMessagesJob {
    static var shared: OWSDisappearingMessagesJob {
        SSKEnvironment.shared.disappearingMessagesJobRef
    }
}

// MARK: -

@objc
public extension PhoneNumberUtil {
    static var shared: PhoneNumberUtil {
        SSKEnvironment.shared.phoneNumberUtilRef
    }
}
