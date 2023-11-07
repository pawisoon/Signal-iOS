//
// Copyright 2018 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import LibSignalClient

public class SignalServiceProfile {

    public enum ValidationError: Error {
        case invalid(description: String)
        case invalidIdentityKey(description: String)
        case invalidProfileName(description: String)
    }

    public let serviceId: ServiceId
    public let identityKey: Data
    public let profileNameEncrypted: Data?
    public let bioEncrypted: Data?
    public let bioEmojiEncrypted: Data?
    public let avatarUrlPath: String?
    public let paymentAddressEncrypted: Data?
    public let unidentifiedAccessVerifier: Data?
    public let hasUnrestrictedUnidentifiedAccess: Bool
    public let supportsAnnouncementOnlyGroups: Bool
    public let supportsSenderKey: Bool
    public let supportsChangeNumber: Bool
    public let credential: Data?
    public let badges: [(OWSUserProfileBadgeInfo, ProfileBadge)]

    public let canReceiveGiftBadges: Bool
    public let isPniCapable: Bool

    public init(serviceId: ServiceId, responseObject: Any?) throws {
        guard let params = ParamParser(responseObject: responseObject) else {
            throw ValidationError.invalid(description: "invalid response: \(String(describing: responseObject))")
        }

        self.serviceId = serviceId

        let identityKeyWithType = try params.requiredBase64EncodedData(key: "identityKey")
        guard identityKeyWithType.count == OWSIdentityManagerImpl.Constants.identityKeyLength else {
            throw ValidationError.invalidIdentityKey(description: "malformed identity key \(identityKeyWithType.hexadecimalString) with decoded length: \(identityKeyWithType.count)")
        }
        do {
            self.identityKey = try identityKeyWithType.removeKeyType()
        } catch {
            owsFailDebug("identify key had unexpected format")
            throw ValidationError.invalidIdentityKey(description: "malformed identity key \(identityKeyWithType.hexadecimalString)")
        }

        self.profileNameEncrypted = try params.optionalBase64EncodedData(key: "name")

        self.bioEncrypted = try params.optionalBase64EncodedData(key: "about")

        self.bioEmojiEncrypted = try params.optionalBase64EncodedData(key: "aboutEmoji")

        let avatarUrlPath: String? = try params.optional(key: "avatar")
        self.avatarUrlPath = avatarUrlPath

        self.paymentAddressEncrypted = try params.optionalBase64EncodedData(key: "paymentAddress")

        self.unidentifiedAccessVerifier = try params.optionalBase64EncodedData(key: "unidentifiedAccess")

        self.hasUnrestrictedUnidentifiedAccess = try params.optional(key: "unrestrictedUnidentifiedAccess") ?? false

        self.supportsAnnouncementOnlyGroups = Self.parseCapabilityFlag(capabilityKey: "announcementGroup",
                                                                       params: params,
                                                                       requireCapability: true)
        self.supportsSenderKey = Self.parseCapabilityFlag(capabilityKey: "senderKey",
                                                          params: params,
                                                          requireCapability: true)
        self.supportsChangeNumber = Self.parseCapabilityFlag(capabilityKey: "changeNumber",
                                                             params: params,
                                                             requireCapability: true)

        self.credential = try params.optionalBase64EncodedData(key: "credential")

        self.canReceiveGiftBadges = Self.parseCapabilityFlag(capabilityKey: "giftBadges", params: params, requireCapability: true)

        self.isPniCapable = Self.parseCapabilityFlag(capabilityKey: "pni", params: params, requireCapability: true)

        if RemoteConfig.donorBadgeDisplay,
           let badgeArray: [[String: Any]] = try params.optional(key: "badges") {
            self.badges = badgeArray.compactMap {
                do {
                    let badgeParams = ParamParser(dictionary: $0)
                    let isVisible: Bool? = try badgeParams.optional(key: "visible")
                    let expiration: TimeInterval? = try badgeParams.optional(key: "expiration")
                    let expirationMills = expiration.flatMap { UInt64($0 * 1000) }

                    let badge = try ProfileBadge(jsonDictionary: $0)
                    let badgeMetadata: OWSUserProfileBadgeInfo
                    if let expirationMills = expirationMills, let isVisible = isVisible {
                        badgeMetadata = OWSUserProfileBadgeInfo(badgeId: badge.id, expiration: expirationMills, isVisible: isVisible)
                    } else {
                        badgeMetadata = OWSUserProfileBadgeInfo(badgeId: badge.id)
                    }
                    return (badgeMetadata, badge)
                } catch {
                    owsFailDebug("Invalid badge: \(error)")
                    return nil
                }
            }
        } else {
            self.badges = []
        }
    }

    private static func parseCapabilityFlag(capabilityKey: String,
                                            params: ParamParser,
                                            requireCapability: Bool) -> Bool {
        do {
            let capabilitiesJson: Any? = try params.required(key: "capabilities")
            if let capabilities = ParamParser(responseObject: capabilitiesJson) {
                if let value: Bool = try capabilities.optional(key: capabilityKey) {
                    return value
                } else {
                    if requireCapability {
                        Logger.verbose("capabilitiesJson: \(String(describing: capabilitiesJson))")
                        owsFailDebug("Missing capability: \(capabilityKey).")
                    } else {
                        Logger.warn("Missing capability: \(capabilityKey).")
                    }
                    // The capability has been retired from the service.
                    return true
                }
            } else {
                owsFailDebug("Missing capabilities.")
                return true
            }
        } catch {
            owsFailDebug("Error: \(error)")
            return true
        }
    }
}
