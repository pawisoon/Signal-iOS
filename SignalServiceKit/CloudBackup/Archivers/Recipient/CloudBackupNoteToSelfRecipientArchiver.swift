//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/**
 * Archiver for the ``BackupProtoSelfRecipient`` recipient, a.k.a. Note To Self.
 */
public class CloudBackupNoteToSelfRecipientArchiver: CloudBackupRecipientDestinationArchiver {

    public func archiveRecipients(
        stream: CloudBackupProtoOutputStream,
        context: CloudBackup.RecipientArchivingContext,
        tx: DBReadTransaction
    ) -> ArchiveFramesResult {
        let recipientId = context.assignRecipientId(to: .noteToSelf)
        let selfRecipientBuilder = BackupProtoSelfRecipient.builder()
        let recipientBuilder = BackupProtoRecipient.builder(id: recipientId.value)

        let error = Self.writeFrameToStream(stream) { frameBuilder in
            let selfRecipientProto = try selfRecipientBuilder.build()
            recipientBuilder.setSelfRecipient(selfRecipientProto)
            let recipientProto = try recipientBuilder.build()
            frameBuilder.setRecipient(recipientProto)
            return try frameBuilder.build()
        }
        if let error {
            return .partialSuccess([error.asArchiveFramesError(objectId: recipientId)])
        } else {
            return .success
        }
    }

    static func canRestore(_ recipient: BackupProtoRecipient) -> Bool {
        return recipient.selfRecipient != nil
    }

    public func restore(
        _ recipient: BackupProtoRecipient,
        context: CloudBackup.RecipientRestoringContext,
        tx: DBWriteTransaction
    ) -> RestoreFrameResult {
        guard let noteToSelfRecipient = recipient.selfRecipient else {
            owsFail("Invalid proto for class")
        }

        context[recipient.recipientId] = .noteToSelf

        return .success
    }
}
