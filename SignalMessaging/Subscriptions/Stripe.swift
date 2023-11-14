//
// Copyright 2021 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import PassKit
import SignalServiceKit

/// Stripe donations
///
/// One-time donation ("boost") process:
/// 1. Start flow
///     - ``Stripe/boost(amount:level:for:)``
/// 2. Intent creation
///     - ``Stripe/createBoostPaymentIntent(for:level:paymentMethod:)``
/// 3. Payment source tokenization
///     - `Stripe.API.createToken(with:)`
///     - Cards need to be tokenized.
///     - SEPA transfers are not tokenized.
/// 4. PaymentMethod creation
///     - ``Stripe/createPaymentMethod(with:)``
/// 5. Intent confirmation
///     - Charges the user's payment method
///     - ``Stripe/confirmPaymentIntent(paymentIntentClientSecret:paymentIntentId:paymentMethodId:idempotencyKey:)``
public struct Stripe: Dependencies {
    public struct PaymentIntent {
        let id: String
        let clientSecret: String

        fileprivate init(clientSecret: String) throws {
            self.id = try API.id(for: clientSecret)
            self.clientSecret = clientSecret
        }
    }

    /// Step 1: Starts the boost payment flow.
    public static func boost(
        amount: FiatMoney,
        level: OneTimeBadgeLevel,
        for paymentMethod: PaymentMethod
    ) -> Promise<ConfirmedIntent> {
        firstly { () -> Promise<PaymentIntent> in
            createBoostPaymentIntent(for: amount, level: level, paymentMethod: paymentMethod.stripePaymentMethod)
        }.then { intent in
            confirmPaymentIntent(
                for: paymentMethod,
                clientSecret: intent.clientSecret,
                paymentIntentId: intent.id
            )
        }
    }

    /// Step 2: Creates boost payment intent
    public static func createBoostPaymentIntent(
        for amount: FiatMoney,
        level: OneTimeBadgeLevel,
        paymentMethod: OWSRequestFactory.StripePaymentMethod
    ) -> Promise<PaymentIntent> {
        firstly(on: DispatchQueue.sharedUserInitiated) { () -> Promise<HTTPResponse> in
            // The description is never translated as it's populated into an
            // english only receipt by Stripe.
            let request = OWSRequestFactory.boostStripeCreatePaymentIntent(
                integerMoneyValue: DonationUtilities.integralAmount(for: amount),
                inCurrencyCode: amount.currencyCode,
                level: level.rawValue,
                paymentMethod: paymentMethod
            )

            return networkManager.makePromise(request: request)
        }.map(on: DispatchQueue.sharedUserInitiated) { response in
            guard let json = response.responseBodyJson else {
                throw OWSAssertionError("Missing or invalid JSON")
            }
            guard let parser = ParamParser(responseObject: json) else {
                throw OWSAssertionError("Failed to decode JSON response")
            }
            return try PaymentIntent(
                clientSecret: try parser.required(key: "clientSecret")
            )
        }
    }

    /// Steps 3 and 4: Payment source tokenization and creates payment method
    public static func createPaymentMethod(
        with paymentMethod: PaymentMethod
    ) -> Promise<PaymentMethodID> {
        requestPaymentMethod(with: paymentMethod).map(on: DispatchQueue.sharedUserInitiated) { response in
            guard let json = response.responseBodyJson else {
                throw OWSAssertionError("Missing responseBodyJson")
            }
            guard let parser = ParamParser(responseObject: json) else {
                throw OWSAssertionError("Failed to decode JSON response")
            }
            return try parser.required(key: "id")
        }.recover(on: DispatchQueue.sharedUserInitiated) { error -> Promise<PaymentMethodID> in
            throw convertToStripeErrorIfPossible(error)
        }
    }

    private static func requestPaymentMethod(
        with paymentMethod: PaymentMethod
    ) -> Promise<HTTPResponse> {
        switch paymentMethod {
        case let .applePay(payment: payment):
            return requestPaymentMethod(with: API.parameters(for: payment))
        case let .creditOrDebitCard(creditOrDebitCard: card):
            return requestPaymentMethod(with: API.parameters(for: card))
        case let .bankTransferSEPA(mandate: _, account: sepaAccount):
            return firstly(on: DispatchQueue.sharedUserInitiated) { () -> Promise<HTTPResponse> in
                // Step 3 not required.
                // Step 4: Payment method creation
                let parameters: [String: String] = [
                    "billing_details[name]": sepaAccount.name,
                    "billing_details[email]": sepaAccount.email,
                    "sepa_debit[iban]": sepaAccount.iban,
                    "type": "sepa_debit",
                ]
                return try API.postForm(endpoint: "payment_methods", parameters: parameters)
            }
        }
    }

    private static func requestPaymentMethod(
        with tokenizationParameters: [String: any Encodable]
    ) -> Promise<HTTPResponse> {
        firstly(on: DispatchQueue.sharedUserInitiated) { () -> Promise<API.Token> in
            // Step 3: Payment source tokenization
            API.createToken(with: tokenizationParameters)
        }.then(on: DispatchQueue.sharedUserInitiated) { tokenId -> Promise<HTTPResponse> in
            // Step 4: Payment method creation
            let parameters: [String: Any] = ["card": ["token": tokenId], "type": "card"]
            return try API.postForm(endpoint: "payment_methods", parameters: parameters)
        }
    }

    public struct ConfirmedIntent {
        public let intentId: String
        public let redirectToUrl: URL?
    }

    public typealias PaymentMethodID = String

    /// Steps 3, 4, and 5: Tokenizes payment source, creates payment method, and confirms payment intent.
    static func confirmPaymentIntent(
        for paymentMethod: PaymentMethod,
        clientSecret: String,
        paymentIntentId: String
    ) -> Promise<ConfirmedIntent> {
        firstly(on: DispatchQueue.sharedUserInitiated) { () -> Promise<PaymentMethodID> in
            // Steps 3 and 4: Payment source tokenization and payment method creation
            createPaymentMethod(with: paymentMethod)
        }.then(on: DispatchQueue.sharedUserInitiated) { paymentMethodId -> Promise<ConfirmedIntent> in
            // Step 5: Confirm payment intent
            confirmPaymentIntent(
                mandate: paymentMethod.mandate,
                paymentIntentClientSecret: clientSecret,
                paymentIntentId: paymentIntentId,
                paymentMethodId: paymentMethodId
            )
        }
    }

    /// Step 5: Confirms payment intent
    public static func confirmPaymentIntent(
        mandate: PaymentMethod.Mandate?,
        paymentIntentClientSecret: String,
        paymentIntentId: String,
        paymentMethodId: PaymentMethodID,
        idempotencyKey: String? = nil
    ) -> Promise<ConfirmedIntent> {
        firstly(on: DispatchQueue.sharedUserInitiated) { () -> Promise<HTTPResponse> in
            try API.postForm(
                endpoint: "payment_intents/\(paymentIntentId)/confirm",
                parameters: [
                    "payment_method": paymentMethodId,
                    "client_secret": paymentIntentClientSecret,
                    "return_url": RETURN_URL_FOR_3DS,
                ].merging(
                    mandate?.parameters ?? [:],
                    uniquingKeysWith: { _, new in new }
                ),
                idempotencyKey: idempotencyKey
            )
        }.map(on: DispatchQueue.sharedUserInitiated) { response -> ConfirmedIntent in
            .init(
                intentId: paymentIntentId,
                redirectToUrl: parseNextActionRedirectUrl(from: response.responseBodyJson)
            )
        }.recover(on: DispatchQueue.sharedUserInitiated) { error -> Promise<ConfirmedIntent> in
            throw convertToStripeErrorIfPossible(error)
        }
    }

    public static func confirmSetupIntent(
        mandate: PaymentMethod.Mandate?,
        for paymentIntentID: String,
        clientSecret: String
    ) -> Promise<ConfirmedIntent> {
        firstly(on: DispatchQueue.sharedUserInitiated) { () -> Promise<HTTPResponse> in
            let setupIntentId = try API.id(for: clientSecret)
            return try API.postForm(
                endpoint: "setup_intents/\(setupIntentId)/confirm",
                parameters: [
                    "payment_method": paymentIntentID,
                    "client_secret": clientSecret,
                    "return_url": RETURN_URL_FOR_3DS,
                ].merging(
                    mandate?.parameters ?? [:],
                    uniquingKeysWith: { _, new in new }
                )
            )
        }.map(on: DispatchQueue.sharedUserInitiated) { response -> ConfirmedIntent in
            .init(
                intentId: paymentIntentID,
                redirectToUrl: parseNextActionRedirectUrl(from: response.responseBodyJson)
            )
        }.recover(on: DispatchQueue.sharedUserInitiated) { error -> Promise<ConfirmedIntent> in
            throw convertToStripeErrorIfPossible(error)
        }
    }
}

// MARK: - API
fileprivate extension Stripe {

    static let publishableKey: String = TSConstants.isUsingProductionService
        ? "pk_live_6cmGZopuTsV8novGgJJW9JpC00vLIgtQ1D"
        : "pk_test_sngOd8FnXNkpce9nPXawKrJD00kIDngZkD"

    static let authorizationHeader = "Basic \(Data("\(publishableKey):".utf8).base64EncodedString())"

    static let urlSession = OWSURLSession(
        baseUrl: URL(string: "https://api.stripe.com/v1/")!,
        securityPolicy: OWSURLSession.defaultSecurityPolicy,
        configuration: URLSessionConfiguration.ephemeral
    )

    struct API {
        static func id(for clientSecret: String) throws -> String {
            let components = clientSecret.components(separatedBy: "_secret_")
            if components.count >= 2, !components[0].isEmpty {
                return components[0]
            } else {
                throw OWSAssertionError("Invalid client secret")
            }
        }

        // MARK: Common Stripe integrations

        static func parameters(for payment: PKPayment) -> [String: any Encodable] {
            var parameters = [String: any Encodable]()
            parameters["pk_token"] = String(data: payment.token.paymentData, encoding: .utf8)

            if let billingContact = payment.billingContact {
                parameters["card"] = self.parameters(for: billingContact)
            }

            parameters["pk_token_instrument_name"] = payment.token.paymentMethod.displayName?.nilIfEmpty
            parameters["pk_token_payment_network"] = payment.token.paymentMethod.network.map { $0.rawValue }

            if payment.token.transactionIdentifier == "Simulated Identifier" {
                owsAssertDebug(!TSConstants.isUsingProductionService, "Simulated ApplePay only works in staging")
                // Generate a fake transaction identifier
                parameters["pk_token_transaction_id"] = "ApplePayStubs~4242424242424242~0~USD~\(UUID().uuidString)"
            } else {
                parameters["pk_token_transaction_id"] =  payment.token.transactionIdentifier.nilIfEmpty
            }

            return parameters
        }

        static func parameters(for contact: PKContact) -> [String: String] {
            var parameters = [String: String]()

            if let name = contact.name {
                parameters["name"] = OWSFormat.formatNameComponents(name).nilIfEmpty
            }

            if let email = contact.emailAddress {
                parameters["email"] = email.nilIfEmpty
            }

            if let phoneNumber = contact.phoneNumber {
                parameters["phone"] = phoneNumber.stringValue.nilIfEmpty
            }

            if let address = contact.postalAddress {
                parameters["address_line1"] = address.street.nilIfEmpty
                parameters["address_city"] = address.city.nilIfEmpty
                parameters["address_state"] = address.state.nilIfEmpty
                parameters["address_zip"] = address.postalCode.nilIfEmpty
                parameters["address_country"] = address.isoCountryCode.uppercased()
            }

            return parameters
        }

        /// Get the query parameters for a request to make a Stripe card token.
        ///
        /// See [Stripe's docs][0].
        ///
        /// [0]: https://stripe.com/docs/api/tokens/create_card
        static func parameters(
            for creditOrDebitCard: PaymentMethod.CreditOrDebitCard
        ) -> [String: String] {
            func pad(_ n: UInt8) -> String { n < 10 ? "0\(n)" : "\(n)" }
            return [
                "card[number]": creditOrDebitCard.cardNumber,
                "card[exp_month]": pad(creditOrDebitCard.expirationMonth),
                "card[exp_year]": pad(creditOrDebitCard.expirationTwoDigitYear),
                "card[cvc]": String(creditOrDebitCard.cvv)
            ]
        }

        typealias Token = String

        /// Step 3 of the process. Payment source tokenization
        static func createToken(with tokenizationParameters: [String: any Encodable]) -> Promise<Token> {
            firstly(on: DispatchQueue.sharedUserInitiated) { () -> Promise<HTTPResponse> in
                return try postForm(endpoint: "tokens", parameters: tokenizationParameters)
            }.map(on: DispatchQueue.sharedUserInitiated) { response in
                guard let json = response.responseBodyJson else {
                    throw OWSAssertionError("Missing responseBodyJson")
                }
                guard let parser = ParamParser(responseObject: json) else {
                    throw OWSAssertionError("Failed to decode JSON response")
                }
                return try parser.required(key: "id")
            }
        }

        /// Make a `POST` request to the Stripe API.
        static func postForm(endpoint: String,
                             parameters: [String: Any],
                             idempotencyKey: String? = nil) throws -> Promise<HTTPResponse> {
            guard let formData = AFQueryStringFromParameters(parameters).data(using: .utf8) else {
                throw OWSAssertionError("Failed to generate post body data")
            }

            var headers: [String: String] = [
                "Content-Type": "application/x-www-form-urlencoded",
                "Authorization": authorizationHeader
            ]
            if let idempotencyKey = idempotencyKey {
                headers["Idempotency-Key"] = idempotencyKey
            }

            return urlSession.dataTaskPromise(
                endpoint,
                method: .post,
                headers: headers,
                body: formData
            )
        }

    }
}

// MARK: - Converting to StripeError

extension Stripe {
    private static func convertToStripeErrorIfPossible(_ error: Error) -> Error {
        guard
            let responseJson = error.httpResponseJson as? [String: Any],
            let errorJson = responseJson["error"] as? [String: Any],
            let code = errorJson["code"] as? String,
            !code.isEmpty
        else {
            return error
        }
        return StripeError(code: code)
    }
}

// MARK: - Currency
// See https://stripe.com/docs/currencies

public extension Stripe {
    static let preferredCurrencyCodes: [Currency.Code] = [
        "USD",
        "AUD",
        "BRL",
        "GBP",
        "CAD",
        "CNY",
        "EUR",
        "HKD",
        "INR",
        "JPY",
        "KRW",
        "PLN",
        "SEK",
        "CHF"
    ]
    static let preferredCurrencyInfos: [Currency.Info] = {
        Currency.infos(for: preferredCurrencyCodes, ignoreMissingNames: true, shouldSort: false)
    }()
}
