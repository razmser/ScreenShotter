import AppKit
import ScreenCaptureKit

enum ScreenRecordingPermission {
    static let bundleIdentifier = "com.razmser.screenshotter"

    static func isPermissionError(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == SCStreamError.errorDomain
            && error.code == SCStreamError.Code.userDeclined.rawValue
    }

    static func presentCaptureError(_ error: Error) async {
        NSApp.activate()
        let response = captureErrorAlert(error).runModal()
        guard isPermissionError(error) else { return }
        switch response {
        case .alertFirstButtonReturn:
            openSettings()
        case .alertThirdButtonReturn:
            await recover()
        default:
            break
        }
    }

    static func captureErrorAlert(_ error: Error) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Screen capture failed"
        alert.informativeText = error.localizedDescription
        if isPermissionError(error) {
            alert.informativeText = """
                Allow ScreenShotter in System Settings → Privacy & Security → \
                Screen & System Audio Recording, then relaunch the app.

                Already enabled, but capture still fails after installing another build? \
                Reset Permission clears ScreenShotter’s old permission so you can grant it again. \
                Other apps’ permissions are unchanged.
                """
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Reset Permission…")
        } else {
            alert.addButton(withTitle: "OK")
        }
        return alert
    }

    static func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    /// Never reset all apps or all services. Keep the subprocess off the UI thread.
    /// The executable override lets tests exercise failures without changing TCC.
    static func reset(executableURL: URL = URL(fileURLWithPath: "/usr/bin/tccutil")) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = executableURL
            process.arguments = ["reset", "ScreenCapture", bundleIdentifier]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { process in
                if process.terminationReason == .exit && process.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: ResetError.failed(process.terminationStatus))
                }
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }

    private enum ResetError: LocalizedError {
        case failed(Int32)

        var errorDescription: String? {
            switch self {
            case .failed(let status):
                "macOS could not reset ScreenShotter’s Screen Recording permission (exit code \(status))."
            }
        }
    }

    static func recover() async {
        do {
            try await reset()
        } catch {
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = "Couldn’t reset permission"
            alert.informativeText = """
                \(error.localizedDescription)

                In Screen & System Audio Recording settings, remove ScreenShotter with the − button, \
                then use + to add it again. Enable it and relaunch the app.
                """
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn { openSettings() }
            return
        }

        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Screen Recording permission reset"
        alert.informativeText = """
            Open Screen & System Audio Recording settings and enable ScreenShotter. \
            If it isn’t listed, click + and select this app:

            \(Bundle.main.bundleURL.path)

            Then choose Quit & Reopen when macOS asks, or quit and reopen ScreenShotter yourself. \
            Save any open screenshots before restarting.
            """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn { openSettings() }
    }
}
