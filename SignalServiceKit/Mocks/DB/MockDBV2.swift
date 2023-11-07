//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import SignalCoreKit

// TODO: [DBV2] Ideally, these would live in a test target.
//
// The types in here are used in both SignalServiceKitTests and SignalTests,
// and we want to share them across the two. Unfortunately, that means they
// cannot live in SignalServiceKitTests. In the future, we should add a
// separate target (e.g., "SignalTestMocks") that encompasses classes that we
// want to share across our various test targets.

#if TESTABLE_BUILD

/// Mock implementation of a transaction.
///
/// Empty stub that does nothing, serving only to crash and fail tests if it is
/// ever unwrapped as a real SDS transaction.
private class MockTransaction: DBWriteTransaction {
    init() {}

    struct AsyncCompletion {
        let scheduler: Scheduler
        let block: () -> Void
    }

    var asyncCompletions = [AsyncCompletion]()

    func addAsyncCompletion(on scheduler: Scheduler, _ block: @escaping () -> Void) {
        asyncCompletions.append(AsyncCompletion(scheduler: scheduler, block: block))
    }
}

/// Mock database which does literally nothing.
/// It creates mock transaction objects which do...nothing.
/// It is expected (indeed, required) that classes under test that use DB
/// will stub out _every_ dependency that unwraps the db transactions and
/// just blindly pass the ones created by this class around.
public class MockDB: DB {

    private let queue: Scheduler
    /// A block invoked when a re-entrant transaction is detected.
    private let reentrantTransactionBlock: () -> Void
    /// A block invoked when an externally-retained transaction is detected.
    private let retainedTransactionBlock: () -> Void

    /// Create a mock DB.
    ///
    /// - Parameter reentrantTransactionBlock
    /// A block called if a read or write is performed within an existing read
    /// or write. Useful for, e.g., detecting reentrant transactions in tests.
    /// - Parameter retainedTransactionBlock
    /// A block called if a read or write completes and a transaction has been
    /// retained by the caller. Useful for, e.g., detecting retained
    /// transactions in tests.
    public init(
        schedulers: Schedulers = DispatchQueueSchedulers(),
        reentrantTransactionBlock: @escaping () -> Void = { fatalError("Re-entrant transaction!") },
        retainedTransactionBlock: @escaping () -> Void = { fatalError("Retained transaction!") }
    ) {
        self.queue = schedulers.queue(label: "mockDB")
        self.reentrantTransactionBlock = reentrantTransactionBlock
        self.retainedTransactionBlock = retainedTransactionBlock
    }

    private var weaklyHeldTransactions = WeakArray<MockTransaction>()

    private func performRead<R>(block: (DBReadTransaction) throws -> R) rethrows -> R {
        return try performWrite(block: block)
    }

    private func performWrite<R>(block: (DBWriteTransaction) throws -> R) rethrows -> R {
        var callIsReentrant = false

        if !weaklyHeldTransactions.elements.isEmpty {
            // If we're entering this method with live transactions, that means
            // we're re-entering.
            callIsReentrant = true
            reentrantTransactionBlock()
        }

        defer {
            // If we're in a reentrant call skip the retention check, since
            // otherwise we'll have transactions that may be alive via recursion
            // rather than retention.
            if !callIsReentrant {
                weaklyHeldTransactions.removeAll { _ in
                    // If we're leaving this method with live transactions, that
                    // means they've been retained outside our `autoreleasepool`.
                    //
                    // Call the block for each retained transaction, and chuck 'em.
                    retainedTransactionBlock()
                    return true
                }
            }
        }

        // This may result in objects created during the `block` being released
        // in addition to the transaction. If your block cares about when ARC
        // releases its objects (e.g., if you find yourself here to understand
        // why your objects are being released), you may wish to consider an
        // explicit memory management technique.
        return try autoreleasepool {
            let tx = MockTransaction()
            weaklyHeldTransactions.append(tx)

            let blockValue = try block(tx)

            tx.asyncCompletions.forEach {
                $0.scheduler.async($0.block)
            }

            return blockValue
        }
    }

    // MARK: - Async Methods

    public func asyncRead(
        file: String,
        function: String,
        line: Int,
        block: @escaping (DBReadTransaction) -> Void,
        completionQueue: DispatchQueue,
        completion: (() -> Void)?
    ) {
        queue.sync {
            performRead(block: block)

            guard let completion else { return }

            completionQueue.sync {
                completion()
            }
        }
    }

    public func asyncWrite(
        file: String,
        function: String,
        line: Int,
        block: @escaping (DBWriteTransaction) -> Void,
        completionQueue: DispatchQueue,
        completion: (() -> Void)?
    ) {
        queue.sync {
            performWrite(block: block)

            guard let completion else { return }

            completionQueue.sync {
                completion()
            }
        }
    }

    public func awaitableWrite<T>(
        file: String,
        function: String,
        line: Int,
        block: @escaping (DBWriteTransaction) throws -> T
    ) async rethrows -> T {
        await Task.yield()
        return try queue.sync {
            return try self.performWrite(block: block)
        }
    }

    // MARK: - Promises

    public func readPromise<T>(
        file: String,
        function: String,
        line: Int,
        _ block: @escaping (DBReadTransaction) throws -> T
    ) -> Promise<T> {
        do {
            let t = try queue.sync {
                return try performRead(block: block)
            }
            return Promise<T>.value(t)
        } catch {
            return Promise<T>.init(error: error)
        }
    }

    public func writePromise<T>(
        file: String,
        function: String,
        line: Int,
        _ block: @escaping (DBWriteTransaction) throws -> T
    ) -> Promise<T> {
        do {
            let t = try queue.sync {
                return try performWrite(block: block)
            }
            return Promise<T>.value(t)
        } catch {
            return Promise<T>(error: error)
        }
    }

    // MARK: - Value Methods

    public func read<T>(
        file: String,
        function: String,
        line: Int,
        block: (DBReadTransaction) throws -> T
    ) rethrows -> T {
        return try queue.sync {
            return try performRead(block: block)
        }
    }

    public func write<T>(
        file: String,
        function: String,
        line: Int,
        block: (DBWriteTransaction) throws -> T
    ) rethrows -> T {
        return try queue.sync {
            return try performWrite(block: block)
        }
    }

    public func appendDbChangeDelegate(_ dbChangeDelegate: DBChangeDelegate) {
        // Do nothing.
    }
}

#endif
