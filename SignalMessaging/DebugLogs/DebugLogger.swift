//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import CocoaLumberjack
import SignalServiceKit

extension DebugLogger {
    // MARK: Enable/Disable

    public func setUpFileLoggingIfNeeded(appContext: AppContext, canLaunchInBackground: Bool) {
        let oldValue = fileLogger != nil
        let newValue = Preferences.isLoggingEnabled

        if newValue == oldValue {
            return
        }

        if newValue {
            enableFileLogging(appContext: appContext, canLaunchInBackground: canLaunchInBackground)
        } else {
            disableFileLogging()
        }
    }

    public func enableFileLogging(appContext: AppContext, canLaunchInBackground: Bool) {
        let logsDirPath = appContext.debugLogsDirPath

        let logFileManager = DebugLogFileManager(
            logsDirectory: logsDirPath,
            defaultFileProtectionLevel: canLaunchInBackground ? .completeUntilFirstUserAuthentication : .completeUnlessOpen
        )

        // Keep last 3 days of logs - or last 3 logs (if logs rollover due to max
        // file size). Keep extra log files in internal builds.
        logFileManager.maximumNumberOfLogFiles = DebugFlags.extraDebugLogs ? 32 : 3

        let fileLogger = DDFileLogger(logFileManager: logFileManager)
        fileLogger.rollingFrequency = kDayInterval
        fileLogger.maximumFileSize = 3 * 1024 * 1024
        fileLogger.logFormatter = ScrubbingLogFormatter()

        self.fileLogger = fileLogger
        DDLog.add(fileLogger)
    }

    public func disableFileLogging() {
        guard let fileLogger else { return }
        DDLog.remove(fileLogger)
        self.fileLogger = nil
    }

    public func enableTTYLoggingIfNeeded() {
        #if DEBUG
        guard let ttyLogger = DDTTYLogger.sharedInstance else { return }
        ttyLogger.logFormatter = LogFormatter()
        DDLog.add(ttyLogger)
        #endif
    }
}
