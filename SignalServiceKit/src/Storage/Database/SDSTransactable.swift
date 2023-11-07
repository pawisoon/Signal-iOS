//
// Copyright 2019 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import GRDB
import SignalCoreKit

// A base class for SDSDatabaseStorage and SDSAnyDatabaseQueue.
@objc
public class SDSTransactable: NSObject {
    fileprivate let asyncWriteQueue = DispatchQueue(label: "org.signal.database.write-async", qos: .userInitiated)

    public func read(file: String = #file,
                     function: String = #function,
                     line: Int = #line,
                     block: (SDSAnyReadTransaction) -> Void) {
        owsFail("Method should be implemented by subclasses.")
    }

    public func write(file: String = #file,
                      function: String = #function,
                      line: Int = #line,
                      block: (SDSAnyWriteTransaction) -> Void) {
        owsFail("Method should be implemented by subclasses.")
    }
}

// MARK: - Async Methods

public extension SDSTransactable {
    @objc(asyncReadWithBlock:)
    func asyncReadObjC(block: @escaping (SDSAnyReadTransaction) -> Void) {
        asyncRead(file: "objc", function: "block", line: 0, block: block)
    }

    @objc(asyncReadWithBlock:completion:)
    func asyncReadObjC(block: @escaping (SDSAnyReadTransaction) -> Void, completion: @escaping () -> Void) {
        asyncRead(file: "objc", function: "block", line: 0, block: block, completion: completion)
    }

    func asyncRead(file: String = #file,
                   function: String = #function,
                   line: Int = #line,
                   block: @escaping (SDSAnyReadTransaction) -> Void,
                   completionQueue: DispatchQueue = .main,
                   completion: (() -> Void)? = nil) {
        DispatchQueue.global().async {
            self.read(file: file, function: function, line: line, block: block)

            if let completion = completion {
                completionQueue.async(execute: completion)
            }
        }
    }
}

// MARK: - Async Methods

// NOTE: This extension is not @objc. See SDSDatabaseStorage+Objc.h.
public extension SDSTransactable {
    func asyncWrite(file: String = #file,
                    function: String = #function,
                    line: Int = #line,
                    block: @escaping (SDSAnyWriteTransaction) -> Void) {
        asyncWrite(file: file,
                   function: function,
                   line: line,
                   block: block,
                   completion: nil)
    }

    func asyncWrite(file: String = #file,
                    function: String = #function,
                    line: Int = #line,
                    block: @escaping (SDSAnyWriteTransaction) -> Void,
                    completion: (() -> Void)?) {
        asyncWrite(file: file,
                   function: function,
                   line: line,
                   block: block,
                   completionQueue: .main,
                   completion: completion)
    }

    func asyncWrite(file: String = #file,
                    function: String = #function,
                    line: Int = #line,
                    block: @escaping (SDSAnyWriteTransaction) -> Void,
                    completionQueue: DispatchQueue,
                    completion: (() -> Void)?) {
        self.asyncWriteQueue.async {
            self.write(file: file,
                       function: function,
                       line: line,
                       block: block)

            if let completion = completion {
                completionQueue.async(execute: completion)
            }
        }
    }
}

// MARK: - Awaitable Methods

extension SDSTransactable {
    public func awaitableWrite<T>(
        file: String = #file,
        function: String = #function,
        line: Int = #line,
        block: @escaping (SDSAnyWriteTransaction) throws -> T
    ) async rethrows -> T {
        return try await _awaitableWrite(file: file, function: function, line: line, block: block, rescue: { throw $0 })
    }

    private func _awaitableWrite<T>(
        file: String,
        function: String,
        line: Int,
        block: @escaping (SDSAnyWriteTransaction) throws -> T,
        rescue: @escaping (Error) throws -> Void
    ) async rethrows -> T {
        let result: Result<T, Error> = await withCheckedContinuation { continuation in
            asyncWriteQueue.async {
                do {
                    let result = try self.write(file: file, function: function, line: line, block: block)
                    continuation.resume(returning: .success(result))
                } catch {
                    continuation.resume(returning: .failure(error))
                }
            }
        }
        switch result {
        case .success(let value):
            return value
        case .failure(let error):
            try rescue(error)
            fatalError()
        }
    }
}

// MARK: - Promises

public extension SDSTransactable {
    func read<T>(_: PromiseNamespace,
                 file: String = #file,
                 function: String = #function,
                 line: Int = #line,
                 _ block: @escaping (SDSAnyReadTransaction) throws -> T) -> Promise<T> {
        return Promise { future in
            DispatchQueue.global().async {
                do {
                    future.resolve(try self.read(file: file, function: function, line: line, block: block))
                } catch {
                    future.reject(error)
                }
            }
        }
    }

    func write<T>(_: PromiseNamespace,
                  file: String = #file,
                  function: String = #function,
                  line: Int = #line,
                  _ block: @escaping (SDSAnyWriteTransaction) throws -> T) -> Promise<T> {
        return Promise { future in
            self.asyncWriteQueue.async {
                do {
                    future.resolve(try self.write(file: file, function: function, line: line, block: block))
                } catch {
                    future.reject(error)
                }
            }
        }
    }
}

// MARK: - Value Methods

public extension SDSTransactable {
    @discardableResult
    func read<T>(
        file: String = #file,
        function: String = #function,
        line: Int = #line,
        block: (SDSAnyReadTransaction) throws -> T
    ) rethrows -> T {
        return try _read(file: file, function: function, line: line, block: block, rescue: { throw $0 })
    }

    // The "rescue" pattern is used in LibDispatch (and replicated here) to
    // allow "rethrows" to work properly.
    private func _read<T>(
        file: String,
        function: String,
        line: Int,
        block: (SDSAnyReadTransaction) throws -> T,
        rescue: (Error) throws -> Void
    ) rethrows -> T {
        var value: T!
        var thrown: Error?
        read(file: file, function: function, line: line) { tx in
            do {
                value = try block(tx)
            } catch {
                thrown = error
            }
        }
        if let thrown {
            try rescue(thrown.grdbErrorForLogging)
        }
        return value
    }

    @discardableResult
    func write<T>(
        file: String = #file,
        function: String = #function,
        line: Int = #line,
        block: (SDSAnyWriteTransaction) throws -> T
    ) rethrows -> T {
        return try _write(file: file, function: function, line: line, block: block, rescue: { throw $0 })
    }

    // The "rescue" pattern is used in LibDispatch (and replicated here) to
    // allow "rethrows" to work properly.
    private func _write<T>(
        file: String,
        function: String,
        line: Int,
        block: (SDSAnyWriteTransaction) throws -> T,
        rescue: (Error) throws -> Void
    ) rethrows -> T {
        var value: T!
        var thrown: Error?
        write(file: file, function: function, line: line) { tx in
            do {
                value = try block(tx)
            } catch {
                thrown = error
            }
        }
        if let thrown {
            try rescue(thrown.grdbErrorForLogging)
        }
        return value
    }
}

// MARK: - @objc macro methods

// NOTE: Do NOT call these methods directly. See SDSDatabaseStorage+Objc.h.
@objc
public extension SDSTransactable {
    @available(*, deprecated, message: "Use DatabaseStorageWrite() instead")
    func __private_objc_write(
        file: String = #file,
        function: String = #function,
        line: Int = #line,
        block: (SDSAnyWriteTransaction) -> Void
    ) {
        write(file: file, function: function, line: line, block: block)
    }

    @available(*, deprecated, message: "Use DatabaseStorageAsyncWrite() instead")
    func __private_objc_asyncWrite(
        file: String = #file,
        function: String = #function,
        line: Int = #line,
        block: @escaping (SDSAnyWriteTransaction) -> Void
    ) {
        asyncWrite(file: file,
                   function: function,
                   line: line,
                   block: block,
                   completion: nil)
    }
}
