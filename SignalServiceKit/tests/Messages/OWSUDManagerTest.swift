//
// Copyright 2018 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest
import Foundation
import SignalCoreKit
import LibSignalClient
@testable import SignalServiceKit

class OWSUDManagerTest: SSKBaseTestSwift {

    private var udManagerImpl: OWSUDManagerImpl {
        return SSKEnvironment.shared.udManager as! OWSUDManagerImpl
    }

    // MARK: - Setup/Teardown

    private let aliceE164 = "+13213214321"
    private let aliceAci = Aci.randomForTesting()
    private lazy var aliceAddress = SignalServiceAddress(serviceId: aliceAci, phoneNumber: aliceE164)

    override func setUp() {
        super.setUp()

        databaseStorage.write { tx in
            (DependenciesBridge.shared.registrationStateChangeManager as! RegistrationStateChangeManagerImpl).registerForTests(
                localIdentifiers: .init(aci: aliceAci, pni: nil, e164: E164(aliceE164)!),
                tx: tx.asV2Write
            )
        }

        // Configure UDManager
        self.write { transaction in
            self.profileManager.setProfileKeyData(
                OWSAES256Key.generateRandom().keyData,
                for: self.aliceAddress,
                userProfileWriter: .tests,
                authedAccount: .implicit(),
                transaction: transaction
            )
        }
    }

    // MARK: - Tests

    func testMode_noProfileKey() {
        XCTAssert(DependenciesBridge.shared.tsAccountManager.registrationStateWithMaybeSneakyTransaction.isRegistered)

        // Ensure UD is enabled by setting our own access level to enabled.
        write { tx in
            udManagerImpl.setUnidentifiedAccessMode(.enabled, for: aliceAci, tx: tx)
        }

        let bobRecipientAci = Aci.randomForTesting()

        write { tx in
            let udAccess = udManagerImpl.udAccess(for: bobRecipientAci, tx: tx)!
            XCTAssertEqual(.unknown, udAccess.udAccessMode)
            XCTAssert(udAccess.isRandomKey)
        }

        write { tx in
            udManagerImpl.setUnidentifiedAccessMode(.unknown, for: bobRecipientAci, tx: tx)
            let udAccess = udManagerImpl.udAccess(for: bobRecipientAci, tx: tx)!
            XCTAssertEqual(.unknown, udAccess.udAccessMode)
            XCTAssert(udAccess.isRandomKey)
        }

        write { tx in
            udManagerImpl.setUnidentifiedAccessMode(.disabled, for: bobRecipientAci, tx: tx)
            let udAccess = udManagerImpl.udAccess(for: bobRecipientAci, tx: tx)
            XCTAssertNil(udAccess)
        }

        write { tx in
            udManagerImpl.setUnidentifiedAccessMode(.enabled, for: bobRecipientAci, tx: tx)
            let udAccess = udManagerImpl.udAccess(for: bobRecipientAci, tx: tx)
            XCTAssertNil(udAccess)
        }

        write { tx in
            // Bob should work in unrestricted mode, even if he doesn't have a profile key.
            udManagerImpl.setUnidentifiedAccessMode(.unrestricted, for: bobRecipientAci, tx: tx)
            let udAccess = udManagerImpl.udAccess(for: bobRecipientAci, tx: tx)!
            XCTAssertEqual(.unrestricted, udAccess.udAccessMode)
            XCTAssert(udAccess.isRandomKey)
        }
    }

    func testMode_withProfileKey() {
        XCTAssert(DependenciesBridge.shared.tsAccountManager.registrationStateWithMaybeSneakyTransaction.isRegistered)
        guard let localAddress = DependenciesBridge.shared.tsAccountManager.localIdentifiersWithMaybeSneakyTransaction?.aciAddress else {
            XCTFail("localAddress was unexpectedly nil")
            return
        }
        XCTAssert(localAddress.isValid)

        // Ensure UD is enabled by setting our own access level to enabled.
        write { tx in
            udManagerImpl.setUnidentifiedAccessMode(.enabled, for: aliceAci, tx: tx)
        }

        let bobRecipientAci = Aci.randomForTesting()
        self.write { transaction in
            self.profileManager.setProfileKeyData(
                OWSAES256Key.generateRandom().keyData,
                for: SignalServiceAddress(bobRecipientAci),
                userProfileWriter: .tests,
                authedAccount: .implicit(),
                transaction: transaction
            )
        }

        write { tx in
            let udAccess = udManagerImpl.udAccess(for: bobRecipientAci, tx: tx)!
            XCTAssertEqual(.unknown, udAccess.udAccessMode)
            XCTAssertFalse(udAccess.isRandomKey)
        }

        write { tx in
            udManagerImpl.setUnidentifiedAccessMode(.unknown, for: bobRecipientAci, tx: tx)
            let udAccess = udManagerImpl.udAccess(for: bobRecipientAci, tx: tx)!
            XCTAssertEqual(.unknown, udAccess.udAccessMode)
            XCTAssertFalse(udAccess.isRandomKey)

        }

        write { tx in
            udManagerImpl.setUnidentifiedAccessMode(.disabled, for: bobRecipientAci, tx: tx)
            let udAccess = udManagerImpl.udAccess(for: bobRecipientAci, tx: tx)
            XCTAssertNil(udAccess)
        }

        write { tx in
            udManagerImpl.setUnidentifiedAccessMode(.enabled, for: bobRecipientAci, tx: tx)
            let udAccess = udManagerImpl.udAccess(for: bobRecipientAci, tx: tx)!
            XCTAssertEqual(.enabled, udAccess.udAccessMode)
            XCTAssertFalse(udAccess.isRandomKey)
        }

        write { tx in
            udManagerImpl.setUnidentifiedAccessMode(.unrestricted, for: bobRecipientAci, tx: tx)
            let udAccess = udManagerImpl.udAccess(for: bobRecipientAci, tx: tx)!
            XCTAssertEqual(.unrestricted, udAccess.udAccessMode)
            XCTAssert(udAccess.isRandomKey)
        }
    }
}
