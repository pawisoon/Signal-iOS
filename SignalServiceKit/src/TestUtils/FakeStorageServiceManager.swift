//
// Copyright 2019 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

#if TESTABLE_BUILD

@objc(OWSFakeStorageServiceManager)
public class FakeStorageServiceManager: NSObject, StorageServiceManager {
    public func recordPendingUpdates(updatedAccountIds: [AccountId]) {}
    public func recordPendingUpdates(updatedAddresses: [SignalServiceAddress]) {}
    public func recordPendingUpdates(updatedGroupV2MasterKeys: [Data]) {}
    public func recordPendingUpdates(updatedStoryDistributionListIds: [Data]) {}
    public func recordPendingUpdates(groupModel: TSGroupModel) {}
    public func recordPendingLocalAccountUpdates() {}

    public func setLocalIdentifiers(_ localIdentifiers: LocalIdentifiersObjC) {}

    public func backupPendingChanges(authedDevice: AuthedDevice) {}

    public var restoreOrCreateManifestIfNecessaryMock: (AuthedDevice) -> Promise<Void> = { _ in .value(()) }

    public func restoreOrCreateManifestIfNecessary(authedDevice: AuthedDevice) -> Promise<Void> {
        return restoreOrCreateManifestIfNecessaryMock(authedDevice)
    }

    public func waitForPendingRestores() -> AnyPromise { AnyPromise(Promise.value(())) }

    public func resetLocalData(transaction: DBWriteTransaction) {}
}

#endif
