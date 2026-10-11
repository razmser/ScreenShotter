import AppKit
import ScreenCaptureKit
import XCTest
@testable import Screenshotter

@MainActor
final class ScreenRecordingPermissionTests: XCTestCase {
    func testRecoveryIsOfferedOnlyForScreenRecordingDenials() {
        _ = NSApplication.shared
        let denied = NSError(domain: SCStreamError.errorDomain,
                             code: SCStreamError.Code.userDeclined.rawValue)
        XCTAssertTrue(ScreenRecordingPermission.captureErrorAlert(denied).buttons
            .contains { $0.title == "Reset Permission…" })

        for error in [
            NSError(domain: SCStreamError.errorDomain, code: SCStreamError.Code.internalError.rawValue),
            NSError(domain: NSCocoaErrorDomain, code: SCStreamError.Code.userDeclined.rawValue),
        ] {
            let alert = ScreenRecordingPermission.captureErrorAlert(error)
            XCTAssertFalse(alert.buttons.contains { $0.title == "Reset Permission…" })
            XCTAssertEqual(alert.informativeText, error.localizedDescription)
        }
    }

    func testResetScopesTheActualSubprocessToThisAppAndScreenRecording() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // A stand-in executable checks the real argv without touching privacy permissions.
        let script = try executable(in: directory, contents: """
            #!/bin/sh
            [ "$#" -eq 3 ] && [ "$1" = reset ] && [ "$2" = ScreenCapture ] && \
            [ "$3" = com.razmser.screenshotter ] || exit 42
            """)
        try await ScreenRecordingPermission.reset(executableURL: script)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let plist = try XCTUnwrap(NSDictionary(contentsOf: repo.appendingPathComponent("Resources/Info.plist")))
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, ScreenRecordingPermission.bundleIdentifier)
    }

    func testResetReportsNonzeroExitAndLaunchFailures() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = try executable(in: directory, contents: "#!/bin/sh\nexit 17\n")
        do {
            try await ScreenRecordingPermission.reset(executableURL: script)
            XCTFail("A failed reset must not report success")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("17"))
        }

        do {
            try await ScreenRecordingPermission.reset(executableURL: directory.appendingPathComponent("missing"))
            XCTFail("A launch failure must not report success")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func executable(in directory: URL, contents: String) throws -> URL {
        let url = directory.appendingPathComponent("tccutil-test")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
}
