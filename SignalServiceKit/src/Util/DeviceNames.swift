//
// Copyright 2018 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import LibSignalClient

public enum DeviceNameError: Error {
    case assertionFailure
    case invalidInput
    case cryptError(_ description: String)
}

@objc
public class DeviceNames: NSObject {
    // Never instantiate this class.
    private override init() {}

    private static let syntheticIVLength: UInt = 16

    public class func encryptDeviceName(plaintext: String, identityKeyPair: IdentityKeyPair) throws -> Data {

        guard let plaintextData = plaintext.data(using: .utf8) else {
            owsFailDebug("Could not convert text to UTF-8.")
            throw DeviceNameError.invalidInput
        }

        let ephemeralKeyPair = IdentityKeyPair.generate()

        // master_secret = ECDH(ephemeral_private, identity_public).
        let masterSecret = Data(ephemeralKeyPair.privateKey.keyAgreement(with: identityKeyPair.publicKey))

        // synthetic_iv = HmacSHA256(key=HmacSHA256(key=master_secret, input=“auth”), input=plaintext)[0:16]
        let syntheticIV = try computeSyntheticIV(masterSecret: masterSecret,
                                                 plaintextData: plaintextData)

        // cipher_key = HmacSHA256(key=HmacSHA256(key=master_secret, “cipher”), input=synthetic_iv)
        let cipherKey = try computeCipherKey(masterSecret: masterSecret, syntheticIV: syntheticIV)

        // cipher_text = AES-CTR(key=cipher_key, input=plaintext, counter=0)
        var ciphertext = plaintextData
        // An all-zeros IV corresponds to an AES CTR counter of zero.
        try Aes256Ctr32.process(&ciphertext, key: cipherKey, nonce: Data(count: Aes256Ctr32.nonceLength))

        let protoBuilder = SignalIOSProtoDeviceName.builder(
            ephemeralPublic: Data(ephemeralKeyPair.publicKey.serialize()),
            syntheticIv: syntheticIV,
            ciphertext: ciphertext
        )
        return try protoBuilder.buildSerializedData()
    }

    private class func computeSyntheticIV(masterSecret: Data,
                                          plaintextData: Data) throws -> Data {
        // synthetic_iv = HmacSHA256(key=HmacSHA256(key=master_secret, input=“auth”), input=plaintext)[0:16]
        guard let syntheticIVInput = "auth".data(using: .utf8) else {
            owsFailDebug("Could not convert text to UTF-8.")
            throw DeviceNameError.assertionFailure
        }
        guard let syntheticIVKey = Cryptography.computeSHA256HMAC(syntheticIVInput, key: masterSecret) else {
            owsFailDebug("Could not compute synthetic IV key.")
            throw DeviceNameError.assertionFailure
        }
        guard let syntheticIV = Cryptography.computeSHA256HMAC(plaintextData, key: syntheticIVKey, truncatedToBytes: syntheticIVLength) else {
            owsFailDebug("Could not compute synthetic IV.")
            throw DeviceNameError.assertionFailure
        }
        return syntheticIV
    }

    private class func computeCipherKey(masterSecret: Data,
                                        syntheticIV: Data) throws -> Data {
        // cipher_key = HmacSHA256(key=HmacSHA256(key=master_secret, “cipher”), input=synthetic_iv)
        guard let cipherKeyInput = "cipher".data(using: .utf8) else {
            owsFailDebug("Could not convert text to UTF-8.")
            throw DeviceNameError.assertionFailure
        }
        guard let cipherKeyKey = Cryptography.computeSHA256HMAC(cipherKeyInput, key: masterSecret) else {
            owsFailDebug("Could not compute cipher key key.")
            throw DeviceNameError.assertionFailure
        }
        guard let cipherKey = Cryptography.computeSHA256HMAC(syntheticIV, key: cipherKeyKey) else {
            owsFailDebug("Could not compute cipher key.")
            throw DeviceNameError.assertionFailure
        }
        return cipherKey
    }

    public class func decryptDeviceName(base64String: String, identityKeyPair: IdentityKeyPair) throws -> String {

        guard let protoData = Data(base64Encoded: base64String) else {
            // Not necessarily an error; might be a legacy device name.
            throw DeviceNameError.invalidInput
        }

        return try decryptDeviceName(protoData: protoData, identityKeyPair: identityKeyPair)
    }

    public class func decryptDeviceName(protoData: Data, identityKeyPair: IdentityKeyPair) throws -> String {

        let proto: SignalIOSProtoDeviceName
        do {
            proto = try SignalIOSProtoDeviceName(serializedData: protoData)
        } catch {
            // Not necessarily an error; might be a legacy device name.
            Logger.error("failed to parse proto")
            throw DeviceNameError.invalidInput
        }

        let ephemeralPublicData = proto.ephemeralPublic
        let receivedSyntheticIV = proto.syntheticIv
        let ciphertext = proto.ciphertext

        let ephemeralPublic: PublicKey
        do {
            ephemeralPublic = try PublicKey(ephemeralPublicData)
        } catch {
            owsFailDebug("failed to remove key type")
            throw DeviceNameError.invalidInput
        }

        guard receivedSyntheticIV.count == syntheticIVLength else {
            owsFailDebug("Invalid synthetic IV.")
            throw DeviceNameError.assertionFailure
        }
        guard ciphertext.count > 0 else {
            owsFailDebug("Invalid cipher text.")
            throw DeviceNameError.assertionFailure
        }

        // master_secret = ECDH(identity_private, ephemeral_public)
        let masterSecret = Data(identityKeyPair.privateKey.keyAgreement(with: ephemeralPublic))

        // cipher_key = HmacSHA256(key=HmacSHA256(key=master_secret, input=“cipher”), input=synthetic_iv)
        let cipherKey = try computeCipherKey(masterSecret: masterSecret, syntheticIV: receivedSyntheticIV)

        // plaintext = AES-CTR(key=cipher_key, input=ciphertext, counter=0)
        var plaintextData = ciphertext
        // An all-zeros IV corresponds to an AES CTR counter of zero.
        try Aes256Ctr32.process(&plaintextData, key: cipherKey, nonce: Data(count: Aes256Ctr32.nonceLength))

        // Verify the synthetic IV was correct.
        // constant_time_compare(HmacSHA256(key=HmacSHA256(key=master_secret, input=”auth”), input=plaintext)[0:16], synthetic_iv) == true
        let computedSyntheticIV = try computeSyntheticIV(masterSecret: masterSecret,
                                                         plaintextData: plaintextData)
        guard receivedSyntheticIV.ows_constantTimeIsEqual(to: computedSyntheticIV) else {
            throw DeviceNameError.cryptError("Synthetic IV did not match.")
        }

        guard let plaintext = String(bytes: plaintextData, encoding: .utf8) else {
            owsFailDebug("Invalid plaintext.")
            throw DeviceNameError.invalidInput
        }

        return plaintext
    }
}
