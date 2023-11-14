//
// Copyright 2018 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

// A class used for making HTTP requests against the main service.
@objc
public class NetworkManager: NSObject {
    private let restNetworkManager = RESTNetworkManager()

    @objc
    public override init() {
        super.init()

        SwiftSingletons.register(self)
    }

    // This method can be called from any thread.
    public func makePromise(request: TSRequest, canUseWebSocket: Bool = false) -> Promise<HTTPResponse> {
        // If REST is deprecated, don't bother trying it.
        if FeatureFlags.deprecateREST {
            return websocketRequestPromise(request: request)
        }

        // Otherwise, try the web socket first if it's allowed for this request.
        let useWebSocket = canUseWebSocket && OWSWebSocket.canAppUseSocketsToMakeRequests
        return useWebSocket ? websocketRequestPromise(request: request) : restRequestPromise(request: request)
    }

    private func restRequestPromise(request: TSRequest) -> Promise<HTTPResponse> {
        restNetworkManager.makePromise(request: request)
    }

    private func websocketRequestPromise(request: TSRequest) -> Promise<HTTPResponse> {
        DependenciesBridge.shared.socketManager.makeRequestPromise(request: request)
    }
}

// MARK: -

#if TESTABLE_BUILD

@objc
public class OWSFakeNetworkManager: NetworkManager {

    public override func makePromise(request: TSRequest, canUseWebSocket: Bool = false) -> Promise<HTTPResponse> {
        Logger.info("Ignoring request: \(request)")
        // Never resolve.
        let (promise, _) = Promise<HTTPResponse>.pending()
        return promise
    }
}

#endif
