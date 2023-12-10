//
// Copyright 2020 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import SignalServiceKit
import SignalRingRTC

/// A delegate for managing "accessory" messages in response to change in group
/// call state on the local device.
///
/// In addition to RingRTC messages, we send some additional messages to the
/// group and to our linked devices in response to certain group call state
/// changes, such as joining. This delegate handles those messages, as well as
/// updating the state that powers them, such as the ``CallRecord`` associated
/// with the group call.
///
/// For example, we send "group call update messages" when we join or leave a
/// group, and send "call event sync messages" when we join a call or decline a
/// group ring.
protocol GroupCallAccessoryMessageDelegate: AnyObject, CallServiceObserver {
    /// Tells the delegate that the local device may have joined a group call.
    ///
    /// This method should be called from any RingRTC callback in which either
    /// the local device's ``JoinState`` or the call's era ID change, when the
    /// join state is `.joined` and we have an era ID for the call.
    ///
    /// - Important
    /// This method must be safe to call repeatedly.
    /// - Important
    /// This method must be called on the main thread.
    /// - Note
    /// For the purposes of accessory messages, we consider ourselves to have
    /// "joined" a call the first time we find that the local device's join
    /// state is `.joined` and we have an era ID for the call.
    func localDeviceMaybeJoinedGroupCall(
        eraId: String,
        groupThread: TSGroupThread,
        groupCallRingState: SignalCall.GroupCallRingState
    )

    /// Tells the delegate that the local device may have left a group call.
    ///
    /// This method should be called from a RingRTC callback whenever the local
    /// device state changes such that its ``JoinState`` is not `.joined`.
    ///
    /// - Important
    /// This method must be safe to call repeatedly.
    /// - Important
    /// This method must be called on the main thread.
    func localDeviceMaybeLeftGroupCall(
        groupThread: TSGroupThread,
        groupCall: GroupCall
    )

    /// Tells the delegate that any group call the local device was joined to
    /// has now ended.
    ///
    /// - Important
    /// This method must be called on the main thread.
    func localDeviceGroupCallDidEnd()

    /// Tells the delegate that the local device has declined a group ring.
    /// 
    /// - Important
    /// This method must be called on the main thread.
    func localDeviceDeclinedGroupRing(
        ringId: Int64,
        groupThread: TSGroupThread
    )
}

class GroupCallAccessoryMessageHandler: GroupCallAccessoryMessageDelegate {
    private let databaseStorage: SDSDatabaseStorage
    private let groupCallRecordManager: GroupCallRecordManager
    private let messageSenderJobQueue: MessageSenderJobQueue

    private let logger = PrefixedLogger(prefix: "GCAMH")

    /// RingRTC does not offer guarantees as to the sequence of callbacks that
    /// will be invoked while joining a group call, and we may learn that we are
    /// "joined" (for the purposes of accessory messages) from multiple
    /// callbacks that may be invoked multiple times with the appropriate
    /// "joined" state.
    ///
    /// This property allows us to track whether or not we have already learned
    /// that we have joined a group call, when receiving our delegate callbacks.
    private var hasJoinedGroupCall: Bool = false

    init(
        databaseStorage: SDSDatabaseStorage,
        groupCallRecordManager: GroupCallRecordManager,
        messageSenderJobQueue: MessageSenderJobQueue
    ) {
        self.databaseStorage = databaseStorage
        self.groupCallRecordManager = groupCallRecordManager
        self.messageSenderJobQueue = messageSenderJobQueue
    }

    // MARK: - CallServiceObserver

    func didUpdateCall(from oldValue: SignalCall?, to newValue: SignalCall?) {
        if let (oldGroupThread, oldGroupCall) = oldValue.flatMap({ $0.unpackGroupCall() }) {
            localDeviceMaybeLeftGroupCall(
                groupThread: oldGroupThread,
                groupCall: oldGroupCall
            )
        }

        localDeviceGroupCallDidEnd()
    }

    // MARK: - GroupCallAccessoryMessageDelegate

    func localDeviceMaybeJoinedGroupCall(
        eraId: String,
        groupThread: TSGroupThread,
        groupCallRingState: SignalCall.GroupCallRingState
    ) {
        AssertIsOnMainThread()

        guard !hasJoinedGroupCall else { return }
        hasJoinedGroupCall = true

        logger.info("Sending join messages for call.")

        databaseStorage.asyncWrite { tx in
            let groupCallUpdateMessage = self.sendGroupCallUpdateMessage(
                groupThread: groupThread,
                eraId: eraId,
                tx: tx
            )

            guard FeatureFlags.groupCallDispositionSyncMessages else {
                return
            }

            // The group call update message is how we tell other members that
            // we've joined the call. Correspondingly, we'll make its timestamp
            // the "official" timestamp for when we joined the call.
            let joinTimestamp = groupCallUpdateMessage.timestamp

            self.groupCallRecordManager.createOrUpdateCallRecordForJoin(
                eraId: eraId,
                groupThread: groupThread,
                groupCallRingState: groupCallRingState,
                joinTimestamp: joinTimestamp,
                tx: tx
            )
        }
    }

    func localDeviceMaybeLeftGroupCall(
        groupThread: TSGroupThread,
        groupCall: GroupCall
    ) {
        AssertIsOnMainThread()

        guard hasJoinedGroupCall else { return }
        hasJoinedGroupCall = false

        logger.info("Sending leave message for call.")

        databaseStorage.asyncWrite { tx in
            _ = self.sendGroupCallUpdateMessage(
                groupThread: groupThread,
                eraId: groupCall.peekInfo?.eraId,
                tx: tx
            )
        }
    }

    func localDeviceGroupCallDidEnd() {
        AssertIsOnMainThread()

        hasJoinedGroupCall = false
    }

    func localDeviceDeclinedGroupRing(
        ringId: Int64,
        groupThread: TSGroupThread
    ) {
        AssertIsOnMainThread()

        guard FeatureFlags.groupCallDispositionSyncMessages else {
            return
        }

        databaseStorage.asyncWrite { tx in
            self.groupCallRecordManager.createOrUpdateCallRecordForDeclinedRing(
                ringId: ringId,
                groupThread: groupThread,
                tx: tx
            )
        }
    }

    // MARK: -

    private func sendGroupCallUpdateMessage(
        groupThread: TSGroupThread,
        eraId: String?,
        tx: SDSAnyWriteTransaction
    ) -> OutgoingGroupCallUpdateMessage {
        let updateMessage = OutgoingGroupCallUpdateMessage(
            thread: groupThread,
            eraId: eraId,
            tx: tx
        )

        messageSenderJobQueue.add(
            message: updateMessage.asPreparer, transaction: tx
        )

        return updateMessage
    }
}

private extension GroupCallRecordManager {
    /// Create or update a call record in response to the local device joining
    /// a group call.
    ///
    /// - Note
    /// Joining a group call always sends a sync message.
    func createOrUpdateCallRecordForJoin(
        eraId: String,
        groupThread: TSGroupThread,
        groupCallRingState: SignalCall.GroupCallRingState,
        joinTimestamp: UInt64,
        tx: SDSAnyWriteTransaction
    ) {
        let callId = callIdFromEra(eraId)
        let groupCallStatus: CallRecord.CallStatus.GroupCallStatus
        let callDirection: CallRecord.CallDirection

        switch groupCallRingState {
        case .ringingEnded, .incomingRing, .incomingRingCancelled:
            owsFailDebug("Unexpected group call ring state: \(groupCallRingState)!")
            fallthrough
        case .shouldRing:
            // Confusingly, this is the default value for a call's ring state,
            // even if we're joining a call someone else started. So, we need to
            // treat this case like "joined" - if we want "ringing", we need to
            // already actively be ringing.
            fallthrough
        case .doNotRing:
            groupCallStatus = .joined
            callDirection = .incoming
        case .ringing:
            // We don't track the state of outgoing rings, so we'll just
            // treat it as accepted.
            groupCallStatus = .ringingAccepted
            callDirection = .outgoing
        }

        createOrUpdateCallRecord(
            callId: callId,
            groupThread: groupThread,
            callDirection: callDirection,
            groupCallStatus: groupCallStatus,
            callEventTimestamp: joinTimestamp,
            shouldSendSyncMessage: true,
            tx: tx.asV2Write
        )
    }

    /// Create or update a call record in response to the local declining a ring
    /// for a group call.
    ///
    /// - Note
    /// Declining a group ring always sends a sync message.
    func createOrUpdateCallRecordForDeclinedRing(
        ringId: Int64,
        groupThread: TSGroupThread,
        tx: SDSAnyWriteTransaction
    ) {
        createOrUpdateCallRecord(
            callId: callIdFromRingId(ringId),
            groupThread: groupThread,
            callDirection: .incoming,
            groupCallStatus: .ringingNotAccepted,
            callEventTimestamp: Date().ows_millisecondsSince1970,
            shouldSendSyncMessage: true,
            tx: tx.asV2Write
        )
    }
}
