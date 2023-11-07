//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import LibSignalClient
import SignalCoreKit

public protocol PniHelloWorldManager {
    /// Perform a "PNI Hello World" operation, if necessary. PNI Hello World
    /// refers to the distribution of PNI identity key material from a primary
    /// device that generated it to linked devices.
    ///
    /// New linked devices receive identity key material during linking.
    /// However, old linked devices may have in the past received now
    /// out-of-date PNI identity keys, or may never received any identity keys.
    ///
    /// This "hello world" operation runs when all devices on the local account
    /// are confirmed to be "PNP capable", to ensure that they have the correct
    /// PNI identity key.
    func sayHelloWorldIfNecessary(tx: DBWriteTransaction)
}

class PniHelloWorldManagerImpl: PniHelloWorldManager {
    private enum StoreConstants {
        static let collectionName = "PniHelloWorldManagerImpl"
        static let hasSaidHelloWorldKey = "hasSaidHelloWorld"
    }

    private let logger = PrefixedLogger(prefix: "PHWM")

    private let database: DB
    private let identityManager: Shims.IdentityManager
    private let keyValueStore: KeyValueStore
    private let networkManager: Shims.NetworkManager
    private let pniDistributionParameterBuilder: PniDistributionParamaterBuilder
    private let pniSignedPreKeyStore: SignalSignedPreKeyStore
    private let pniKyberPreKeyStore: SignalKyberPreKeyStore
    private let profileManager: Shims.ProfileManager
    private let schedulers: Schedulers
    private let signalRecipientStore: Shims.SignalRecipientStore
    private let tsAccountManager: TSAccountManager

    init(
        database: DB,
        identityManager: Shims.IdentityManager,
        keyValueStoreFactory: KeyValueStoreFactory,
        networkManager: Shims.NetworkManager,
        pniDistributionParameterBuilder: PniDistributionParamaterBuilder,
        pniSignedPreKeyStore: SignalSignedPreKeyStore,
        pniKyberPreKeyStore: SignalKyberPreKeyStore,
        profileManager: Shims.ProfileManager,
        schedulers: Schedulers,
        signalRecipientStore: Shims.SignalRecipientStore,
        tsAccountManager: TSAccountManager
    ) {
        self.database = database
        self.identityManager = identityManager
        self.keyValueStore = keyValueStoreFactory.keyValueStore(collection: StoreConstants.collectionName)
        self.networkManager = networkManager
        self.pniDistributionParameterBuilder = pniDistributionParameterBuilder
        self.pniSignedPreKeyStore = pniSignedPreKeyStore
        self.pniKyberPreKeyStore = pniKyberPreKeyStore
        self.profileManager = profileManager
        self.schedulers = schedulers
        self.signalRecipientStore = signalRecipientStore
        self.tsAccountManager = tsAccountManager
    }

    func sayHelloWorldIfNecessary(tx syncTx: DBWriteTransaction) {
        let logger = logger

        guard tsAccountManager.registrationState(tx: syncTx).isRegisteredPrimaryDevice else {
            logger.info("Skipping PNI Hello World, am a linked device.")
            return
        }

        guard !keyValueStore.getBool(
            StoreConstants.hasSaidHelloWorldKey,
            defaultValue: false,
            transaction: syncTx
        ) else {
            logger.info("Skipping PNI Hello World, already completed.")
            return
        }

        guard
            let localIdentifiers = tsAccountManager.localIdentifiers(tx: syncTx),
            localIdentifiers.pni != nil,
            let (
                localAccountId,
                localUserAllDeviceIds
            ) = signalRecipientStore.localAccountAndDeviceIds(
                localAci: localIdentifiers.aci,
                tx: syncTx
            )
        else {
            logger.warn("Skipping PNI Hello World, missing local account parameters!")
            return
        }

        guard profileManager.isLocalProfilePniCapable() else {
            logger.info("Skipping PNI Hello World, profile not yet PNI capable.")
            return
        }

        // Use the primary device's existing PNI identity and e164.
        guard
            let localE164 = E164(localIdentifiers.phoneNumber),
            let localPniIdentityKeyPair = identityManager.pniIdentityKeyPair(tx: syncTx),
            let localDevicePniSignedPreKey = pniSignedPreKeyStore.currentSignedPreKey(tx: syncTx),
            let localDevicePniPqLastResortPreKey = pniKyberPreKeyStore.getLastResortKyberPreKey(tx: syncTx)
        else {
            logger.warn("Skipping PNI Hello World, missing PNI parameters!")
            return
        }

        let localDeviceId = tsAccountManager.storedDeviceId(tx: syncTx)
        let localDevicePniRegistrationId = tsAccountManager.getOrGeneratePniRegistrationId(tx: syncTx)

        firstly(on: schedulers.sync) { () -> Guarantee<PniDistribution.ParameterGenerationResult> in
            logger.info("Building PNI distribution parameters.")

            return self.pniDistributionParameterBuilder.buildPniDistributionParameters(
                localAci: localIdentifiers.aci,
                localAccountId: localAccountId,
                localDeviceId: localDeviceId,
                localUserAllDeviceIds: localUserAllDeviceIds,
                localPniIdentityKeyPair: localPniIdentityKeyPair,
                localE164: localE164,
                localDevicePniSignedPreKey: localDevicePniSignedPreKey,
                localDevicePniPqLastResortPreKey: localDevicePniPqLastResortPreKey,
                localDevicePniRegistrationId: localDevicePniRegistrationId
            )
        }.map(on: schedulers.sync) { parameterGenerationResult throws -> PniDistribution.Parameters in
            switch parameterGenerationResult {
            case .success(let parameters):
                return parameters
            case .failure:
                throw OWSGenericError("Failed to generate PNI distribution parameters!")
            }
        }.then(on: schedulers.sync) { pniDistributionParameters -> Promise<Void> in
            logger.info("Making hello world request.")

            return self.networkManager.makeHelloWorldRequest(
                pniDistributionParameters: pniDistributionParameters
            )
        }.done(on: schedulers.global()) {
            self.database.write { tx in
                self.keyValueStore.setBool(
                    true,
                    key: StoreConstants.hasSaidHelloWorldKey,
                    transaction: tx
                )
            }

            logger.info("Hello world succeeded!")
        }.catch(on: schedulers.sync) { error in
            logger.error("Failed to say Hello World! \(error)")
        }
    }
}

private extension OWSRequestFactory {
    static func pniHelloWorldRequest(
        pniDistributionParameters: PniDistribution.Parameters
    ) -> TSRequest {
        return TSRequest(
            url: URL(string: "v2/accounts/phone_number_identity_key_distribution")!,
            method: HTTPMethod.put.methodName,
            parameters: pniDistributionParameters.requestParameters()
        )
    }
}

// MARK: - Dependencies

extension PniHelloWorldManagerImpl {
    enum Shims {
        typealias IdentityManager = _PniHelloWorldManagerImpl_IdentityManager_Shim
        typealias NetworkManager = _PniHelloWorldManagerImpl_NetworkManager_Shim
        typealias ProfileManager = _PniHelloWorldManagerImpl_ProfileManager_Shim
        typealias SignalRecipientStore = _PniHelloWorldManagerImpl_SignalRecipientStore_Shim
    }

    enum Wrappers {
        typealias IdentityManager = _PniHelloWorldManagerImpl_IdentityManager_Wrapper
        typealias NetworkManager = _PniHelloWorldManagerImpl_NetworkManager_Wrapper
        typealias ProfileManager = _PniHelloWorldManagerImpl_ProfileManager_Wrapper
        typealias SignalRecipientStore = _PniHelloWorldManagerImpl_SignalRecipientStore_Wrapper
    }
}

// MARK: IdentityManager

protocol _PniHelloWorldManagerImpl_IdentityManager_Shim {
    func pniIdentityKeyPair(tx: DBReadTransaction) -> ECKeyPair?
}

class _PniHelloWorldManagerImpl_IdentityManager_Wrapper: _PniHelloWorldManagerImpl_IdentityManager_Shim {
    private let identityManager: OWSIdentityManager

    init(_ identityManager: OWSIdentityManager) {
        self.identityManager = identityManager
    }

    func pniIdentityKeyPair(tx: DBReadTransaction) -> ECKeyPair? {
        return identityManager.identityKeyPair(for: .pni, tx: tx)
    }
}

// MARK: NetworkManager

protocol _PniHelloWorldManagerImpl_NetworkManager_Shim {
    func makeHelloWorldRequest(pniDistributionParameters: PniDistribution.Parameters) -> Promise<Void>
}

class _PniHelloWorldManagerImpl_NetworkManager_Wrapper: _PniHelloWorldManagerImpl_NetworkManager_Shim {
    private let networkManager: NetworkManager

    init(_ networkManager: NetworkManager) {
        self.networkManager = networkManager
    }

    func makeHelloWorldRequest(pniDistributionParameters: PniDistribution.Parameters) -> Promise<Void> {
        let helloWorldRequest = OWSRequestFactory.pniHelloWorldRequest(
            pniDistributionParameters: pniDistributionParameters
        )

        return networkManager.makePromise(request: helloWorldRequest).asVoid()
    }
}

// MARK: ProfileManager

protocol _PniHelloWorldManagerImpl_ProfileManager_Shim {
    func isLocalProfilePniCapable() -> Bool
}

class _PniHelloWorldManagerImpl_ProfileManager_Wrapper: _PniHelloWorldManagerImpl_ProfileManager_Shim {
    private let profileManager: ProfileManagerProtocol

    init(_ profileManager: ProfileManagerProtocol) {
        self.profileManager = profileManager
    }

    func isLocalProfilePniCapable() -> Bool {
        return profileManager.localProfileIsPniCapable()
    }
}

// MARK: SignalRecipientStore

protocol _PniHelloWorldManagerImpl_SignalRecipientStore_Shim {
    func localAccountAndDeviceIds(
        localAci: Aci,
        tx: DBReadTransaction
    ) -> (accountId: String, deviceIds: [UInt32])?
}

class _PniHelloWorldManagerImpl_SignalRecipientStore_Wrapper: _PniHelloWorldManagerImpl_SignalRecipientStore_Shim {
    func localAccountAndDeviceIds(
        localAci: Aci,
        tx: DBReadTransaction
    ) -> (accountId: String, deviceIds: [UInt32])? {
        guard
            let localRecipient = SignalRecipient.fetchRecipient(
                for: SignalServiceAddress(localAci),
                onlyIfRegistered: false,
                tx: SDSDB.shimOnlyBridge(tx)
            )
        else {
            return nil
        }

        return (
            localRecipient.accountId,
            localRecipient.deviceIds
        )
    }
}
