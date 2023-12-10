//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

public protocol IndividualCallRecordManager {
    /// Updates the call interaction type for the given interaction, and
    /// correspondingly updates the call record for this interaction if one
    /// exists.
    func updateInteractionTypeAndRecordIfExists(
        individualCallInteraction: TSCall,
        individualCallInteractionRowId: Int64,
        contactThread: TSContactThread,
        newCallInteractionType: RPRecentCallType,
        tx: DBWriteTransaction
    )

    /// Update the call record for the given call interaction's current state,
    /// or create one if none exists.
    func createOrUpdateRecordForInteraction(
        individualCallInteraction: TSCall,
        individualCallInteractionRowId: Int64,
        contactThread: TSContactThread,
        contactThreadRowId: Int64,
        callId: UInt64,
        tx: DBWriteTransaction
    )

    /// Create a call record for the given interaction's current state.
    func createRecordForInteraction(
        individualCallInteraction: TSCall,
        individualCallInteractionRowId: Int64,
        contactThread: TSContactThread,
        contactThreadRowId: Int64,
        callId: UInt64,
        callType: CallRecord.CallType,
        callDirection: CallRecord.CallDirection,
        individualCallStatus: CallRecord.CallStatus.IndividualCallStatus,
        shouldSendSyncMessage: Bool,
        tx: DBWriteTransaction
    )

    /// Update the given call record.
    func updateRecord(
        contactThread: TSContactThread,
        existingCallRecord: CallRecord,
        newIndividualCallStatus: CallRecord.CallStatus.IndividualCallStatus,
        shouldSendSyncMessage: Bool,
        tx: DBWriteTransaction
    )
}

public class IndividualCallRecordManagerImpl: IndividualCallRecordManager {
    private let callRecordStore: CallRecordStore
    private let interactionStore: InteractionStore
    private let outgoingSyncMessageManager: CallRecordOutgoingSyncMessageManager

    private var logger: PrefixedLogger { CallRecordLogger.shared }

    init(
        callRecordStore: CallRecordStore,
        interactionStore: InteractionStore,
        outgoingSyncMessageManager: CallRecordOutgoingSyncMessageManager
    ) {
        self.callRecordStore = callRecordStore
        self.interactionStore = interactionStore
        self.outgoingSyncMessageManager = outgoingSyncMessageManager
    }

    public func updateInteractionTypeAndRecordIfExists(
        individualCallInteraction: TSCall,
        individualCallInteractionRowId: Int64,
        contactThread: TSContactThread,
        newCallInteractionType: RPRecentCallType,
        tx: DBWriteTransaction
    ) {
        guard
            let newIndividualCallStatus = CallRecord.CallStatus.IndividualCallStatus(
                individualCallInteractionType: newCallInteractionType
            )
        else {
            logger.error("Cannot update interaction or call record, missing or invalid parameters!")
            return
        }

        interactionStore.updateIndividualCallInteractionType(
            individualCallInteraction: individualCallInteraction,
            newCallInteractionType: newCallInteractionType,
            tx: tx
        )

        guard let existingCallRecord = callRecordStore.fetch(
            interactionRowId: individualCallInteractionRowId, tx: tx
        ) else {
            logger.info("No existing call record found!")
            return
        }

        updateRecord(
            contactThread: contactThread,
            existingCallRecord: existingCallRecord,
            newIndividualCallStatus: newIndividualCallStatus,
            shouldSendSyncMessage: true,
            tx: tx
        )
    }

    /// Create or update the record for the given interaction, using the latest
    /// state of the interaction.
    ///
    /// Sends a sync message with the latest call record.
    public func createOrUpdateRecordForInteraction(
        individualCallInteraction: TSCall,
        individualCallInteractionRowId: Int64,
        contactThread: TSContactThread,
        contactThreadRowId: Int64,
        callId: UInt64,
        tx: DBWriteTransaction
    ) {
        guard
            let callDirection = CallRecord.CallDirection(
                individualCallInteractionType: individualCallInteraction.callType
            ),
            let individualCallStatus = CallRecord.CallStatus.IndividualCallStatus(
                individualCallInteractionType: individualCallInteraction.callType
            )
        else { return }

        if let existingCallRecord = callRecordStore.fetch(
            callId: callId,
            threadRowId: contactThreadRowId,
            tx: tx
        ) {
            updateRecord(
                contactThread: contactThread,
                existingCallRecord: existingCallRecord,
                newIndividualCallStatus: individualCallStatus,
                shouldSendSyncMessage: true,
                tx: tx
            )
        } else {
            createRecordForInteraction(
                individualCallInteraction: individualCallInteraction,
                individualCallInteractionRowId: individualCallInteractionRowId,
                contactThread: contactThread,
                contactThreadRowId: contactThreadRowId,
                callId: callId,
                callType: CallRecord.CallType(individualCallOfferTypeType: individualCallInteraction.offerType),
                callDirection: callDirection,
                individualCallStatus: individualCallStatus,
                shouldSendSyncMessage: true,
                tx: tx
            )
        }
    }

    public func createRecordForInteraction(
        individualCallInteraction: TSCall,
        individualCallInteractionRowId: Int64,
        contactThread: TSContactThread,
        contactThreadRowId: Int64,
        callId: UInt64,
        callType: CallRecord.CallType,
        callDirection: CallRecord.CallDirection,
        individualCallStatus: CallRecord.CallStatus.IndividualCallStatus,
        shouldSendSyncMessage: Bool,
        tx: DBWriteTransaction
    ) {
        logger.info("Creating new 1:1 call record from interaction.")

        let callRecord = CallRecord(
            callId: callId,
            interactionRowId: individualCallInteractionRowId,
            threadRowId: contactThreadRowId,
            callType: callType,
            callDirection: callDirection,
            callStatus: .individual(individualCallStatus),
            callBeganTimestamp: individualCallInteraction.timestamp
        )

        guard callRecordStore.insert(
            callRecord: callRecord, tx: tx
        ) else { return }

        if shouldSendSyncMessage {
            outgoingSyncMessageManager.sendSyncMessage(
                contactThread: contactThread,
                callRecord: callRecord,
                tx: tx
            )
        }
    }

    public func updateRecord(
        contactThread: TSContactThread,
        existingCallRecord: CallRecord,
        newIndividualCallStatus: CallRecord.CallStatus.IndividualCallStatus,
        shouldSendSyncMessage: Bool,
        tx: DBWriteTransaction
    ) {
        guard callRecordStore.updateRecordStatusIfAllowed(
            callRecord: existingCallRecord,
            newCallStatus: .individual(newIndividualCallStatus),
            tx: tx
        ) else { return }

        if shouldSendSyncMessage {
            outgoingSyncMessageManager.sendSyncMessage(
                contactThread: contactThread,
                callRecord: existingCallRecord,
                tx: tx
            )
        }
    }
}

private extension CallRecord.CallType {
    init(individualCallOfferTypeType: TSRecentCallOfferType) {
        switch individualCallOfferTypeType {
        case .audio: self = .audioCall
        case .video: self = .videoCall
        }
    }
}

private extension CallRecord.CallDirection {
    init?(
        individualCallInteractionType: RPRecentCallType
    ) {
        switch individualCallInteractionType {
        case
                .incoming,
                .incomingMissed,
                .incomingDeclined,
                .incomingIncomplete,
                .incomingBusyElsewhere,
                .incomingDeclinedElsewhere,
                .incomingAnsweredElsewhere,
                .incomingMissedBecauseOfDoNotDisturb,
                .incomingMissedBecauseOfChangedIdentity,
                .incomingMissedBecauseBlockedSystemContact:
            self = .incoming
        case
                .outgoing,
                .outgoingIncomplete,
                .outgoingMissed:
            self = .outgoing
        @unknown default:
            CallRecordLogger.shared.warn("Unknown call type!")
            return nil
        }
    }
}

extension CallRecord.CallStatus.IndividualCallStatus {
    public init?(
        individualCallInteractionType: RPRecentCallType
    ) {
        switch individualCallInteractionType {
        case
                .incomingIncomplete,
                .outgoingIncomplete:
            self = .pending
        case
                .incoming,
                .outgoing,
                .incomingAnsweredElsewhere:
            // The "elsewhere" is a linked device that should be sending us a
            // sync message.
            self = .accepted
        case
                .incomingDeclined,
                .outgoingMissed,
                .incomingDeclinedElsewhere:
            // The "elsewhere" is a linked device that should be sending us a
            // sync message.
            self = .notAccepted
        case
                .incomingMissed,
                .incomingMissedBecauseOfChangedIdentity,
                .incomingMissedBecauseOfDoNotDisturb,
                .incomingMissedBecauseBlockedSystemContact,
                .incomingBusyElsewhere:
            // Note that "busy elsewhere" means we should display the call
            // as missed, but the busy linked device won't send a sync
            // message.
            self = .incomingMissed
        @unknown default:
            CallRecordLogger.shared.warn("Unknown call type!")
            return nil
        }
    }
}
