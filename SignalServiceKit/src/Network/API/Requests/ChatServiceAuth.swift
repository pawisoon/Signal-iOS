//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import LibSignalClient

/// Credentials to use on a TSRequest to the chat server.
@objc
public class ChatServiceAuth: NSObject {

    public enum Credentials: Equatable {
        case implicit
        case explicit(username: String, password: String)
    }

    @nonobjc
    public let credentials: Credentials

    private init(_ credentials: Credentials) {
        self.credentials = credentials
        super.init()
    }

    /// Will use auth credentials present on TSAccountManager
    @objc
    public static func implicit() -> ChatServiceAuth {
        return ChatServiceAuth(.implicit)
    }

    public typealias DeviceId = AuthedDevice.DeviceId

    @objc
    public static func explicit(
        aci: AciObjC,
        rawDeviceId: UInt32,
        password: String
    ) -> ChatServiceAuth {
        return ChatServiceAuth.explicit(
            aci: aci.wrappedAciValue,
            deviceId: rawDeviceId == OWSDevice.primaryDeviceId ? .primary : .secondary(rawDeviceId),
            password: password
        )
    }

    public static func explicit(
        aci: Aci,
        deviceId: DeviceId,
        password: String
    ) -> ChatServiceAuth {
        return ChatServiceAuth(.explicit(username: deviceId.authUsername(aci: aci), password: password))
    }

    public override var hash: Int {
        var hasher = Hasher()
        switch credentials {
        case .implicit:
            break
        case let .explicit(username, password):
            hasher.combine(username)
            hasher.combine(password)
        }
        return hasher.finalize()
    }

    public override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? ChatServiceAuth else {
            return false
        }
        return self.credentials == other.credentials
    }

    public func orIfImplicitUse(_ other: ChatServiceAuth) -> ChatServiceAuth {
        switch (self.credentials, other.credentials) {
        case (.explicit, _):
            return self
        case (_, .explicit):
            return other
        case (.implicit, .implicit):
            return other
        }
    }
}

extension TSRequest {
    @objc
    public func setAuth(_ auth: ChatServiceAuth) {
        switch auth.credentials {
        case .implicit:
            break
        case let .explicit(username, password):
            self.authUsername = username
            self.authPassword = password
        }
    }
}
