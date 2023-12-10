//
// Copyright 2018 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import LibSignalClient

public enum AccountServiceClientError: Error {
    case captchaRequired
}

/// based on libsignal-service-java's AccountManager class
@objc
public class AccountServiceClient: NSObject {

    // MARK: - Public

    public func getPreKeysCount(for identity: OWSIdentity) -> Promise<(ecCount: Int, pqCount: Int)> {
        return serviceClient.getAvailablePreKeys(for: identity)
    }

    public func setPreKeys(
        for identity: OWSIdentity,
        signedPreKeyRecord: SignalServiceKit.SignedPreKeyRecord?,
        preKeyRecords: [SignalServiceKit.PreKeyRecord]?,
        pqLastResortPreKeyRecord: KyberPreKeyRecord?,
        pqPreKeyRecords: [KyberPreKeyRecord]?,
        auth: ChatServiceAuth
    ) -> Promise<Void> {
        return serviceClient.registerPreKeys(
            for: identity,
            signedPreKeyRecord: signedPreKeyRecord,
            preKeyRecords: preKeyRecords,
            pqLastResortPreKeyRecord: pqLastResortPreKeyRecord,
            pqPreKeyRecords: pqPreKeyRecords,
            auth: auth
        )
    }

    public func setSignedPreKey(_ signedPreKey: SignalServiceKit.SignedPreKeyRecord, for identity: OWSIdentity) -> Promise<Void> {
        return serviceClient.setCurrentSignedPreKey(signedPreKey, for: identity)
    }

    public func updatePrimaryDeviceAccountAttributes() async throws -> AccountAttributes {
        return try await serviceClient.updatePrimaryDeviceAccountAttributes()
    }

    public func getAccountWhoAmI() -> Promise<WhoAmIRequestFactory.Responses.WhoAmI> {
        return serviceClient.getAccountWhoAmI()
    }
}
