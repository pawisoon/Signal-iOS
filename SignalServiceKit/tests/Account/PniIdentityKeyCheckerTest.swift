//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import LibSignalClient
import XCTest

@testable import SignalServiceKit

final class PniIdentityKeyCheckerTest: XCTestCase {
    private var db: MockDB!
    private var identityManagerMock: IdentityManagerMock!
    private var profileFetcherMock: ProfileFetcherMock!
    private var testScheduler: TestScheduler!

    private var pniIdentityKeyChecker: PniIdentityKeyCheckerImpl!

    override func setUp() {
        db = MockDB()
        identityManagerMock = IdentityManagerMock()
        profileFetcherMock = ProfileFetcherMock()

        testScheduler = TestScheduler()
        let schedulers = TestSchedulers(scheduler: testScheduler)

        pniIdentityKeyChecker = PniIdentityKeyCheckerImpl(
            db: db,
            identityManager: identityManagerMock,
            profileFetcher: profileFetcherMock,
            schedulers: schedulers
        )
    }

    override func tearDown() {
        profileFetcherMock.profileFetchResult.ensureUnset()
    }

    /// Runs the identity key checker.
    /// - Returns
    /// Whether or not the checker found a match. Throws if there was an error
    /// while running the checker.
    private func checkForMatch() throws -> Bool {
        let promise = db.read { tx -> Promise<Bool> in
            return pniIdentityKeyChecker.serverHasSameKeyAsLocal(
                localPni: Pni.randomForTesting(),
                tx: tx
            )
        }

        testScheduler.runUntilIdle()

        switch promise.result! {
        case let .success(matched):
            return matched
        case let .failure(error):
            throw error
        }
    }

    func testDoesNotMatchIfLocalPniIdentityKeyMissing() throws {
        XCTAssertFalse(try checkForMatch())
    }

    func testErrorMatchingIfProfileFetchFails() {
        identityManagerMock.pniIdentityKey = try! IdentityKey(bytes: [0x05] + Data(repeating: 0, count: 32))
        profileFetcherMock.profileFetchResult = .error()

        XCTAssertThrowsError(try checkForMatch())
    }

    func testDoesNotMatchIfRemotePniIdentityKeyMissing() throws {
        identityManagerMock.pniIdentityKey = try! IdentityKey(bytes: [0x05] + Data(repeating: 0, count: 32))
        profileFetcherMock.profileFetchResult = .value(nil)

        XCTAssertFalse(try checkForMatch())
    }

    func testDoesNotMatchIfRemotePniIdentityKeyDiffers() throws {
        identityManagerMock.pniIdentityKey = try! IdentityKey(bytes: [0x05] + Data(repeating: 0, count: 32))
        profileFetcherMock.profileFetchResult = .value(try! IdentityKey(bytes: [0x05] + Data(repeating: 1, count: 32)))

        XCTAssertFalse(try checkForMatch())
    }

    func testMatchesIfRemotePniIdentityKeyMatches() throws {
        identityManagerMock.pniIdentityKey = try! IdentityKey(bytes: [0x05] + Data(repeating: 0, count: 32))
        profileFetcherMock.profileFetchResult = .value(try! IdentityKey(bytes: [0x05] + Data(repeating: 0, count: 32)))

        XCTAssertTrue(try checkForMatch())
    }
}

// MARK: - Mocks

// MARK: IdentityManager

private class IdentityManagerMock: PniIdentityKeyCheckerImpl.Shims.IdentityManager {
    var pniIdentityKey: IdentityKey?

    func pniIdentityKey(tx _: DBReadTransaction) -> IdentityKey? {
        return pniIdentityKey
    }
}

// MARK: ProfileFetcher

private class ProfileFetcherMock: PniIdentityKeyCheckerImpl.Shims.ProfileFetcher {
    var profileFetchResult: ConsumableMockPromise<IdentityKey?> = .unset

    func fetchPniIdentityPublicKey(localPni: Pni) -> Promise<IdentityKey?> {
        return profileFetchResult.consumeIntoPromise()
    }
}
