import AppKit

/// Copying screenshots to the pasteboard and writing them to disk.
enum Output {
    static func bitmap(_ shot: Screenshot) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(cgImage: shot.image)
        // Point size carries the DPI, so a Retina capture pastes at its logical size.
        rep.size = shot.pointSize
        return rep
    }

    /// Returns false if the image didn't reach the pasteboard, e.g. another app took it meanwhile.
    static func copy(_ shot: Screenshot) -> Bool {
        let rep = bitmap(shot)
        // Encoded first, so a failure leaves the clipboard as it was.
        guard let png = rep.representation(using: .png, properties: [:]), let tiff = rep.tiffRepresentation
        else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.declareTypes([.png, .tiff], owner: nil)
        // A write fails once another app has taken the pasteboard.
        return pasteboard.setData(png, forType: .png) && pasteboard.setData(tiff, forType: .tiff)
    }

    static func encode(_ shot: Screenshot, as format: ImageFormat) -> Data? {
        switch format {
        case .webp: return WebP.encode(shot.image, scale: shot.scale)
        case .png: return bitmap(shot).representation(using: .png, properties: [:])
        case .jpeg: return bitmap(shot).representation(using: .jpeg, properties: [.compressionFactor: 0.9])
        }
    }

    static func write(_ shot: Screenshot, to url: URL, format: ImageFormat) throws {
        guard let data = encode(shot, as: format) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url, options: .atomic)
        markAsScreenCapture(url)
    }

    /// Sets the Spotlight attribute macOS uses for its own screenshots, so Finder's
    /// "Screenshot" kind and smart folders include the file.
    static func markAsScreenCapture(_ url: URL) {
        guard let value = try? PropertyListSerialization.data(fromPropertyList: true, format: .binary, options: 0)
        else { return }
        _ = value.withUnsafeBytes { bytes in
            setxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", bytes.baseAddress, bytes.count, 0, 0)
        }
    }

    /// Saves into the configured folder with a timestamped, non-clashing name.
    @discardableResult
    static func save(_ shot: Screenshot, settings: Settings = .shared) throws -> URL {
        let format = settings.imageFormat
        let url = try newFileURL(extension: format.fileExtension, settings: settings)
        try write(shot, to: url, format: format)
        return url
    }

    /// A timestamped, non-clashing file in the configured folder, which is created if needed.
    static func newFileURL(prefix: String = "", extension fileExtension: String,
                           settings: Settings = .shared) throws -> URL {
        let folder = settings.saveFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let baseName = prefix + formatter.string(from: Date())
        var url = folder.appendingPathComponent(baseName).appendingPathExtension(fileExtension)
        var index = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(baseName) (\(index))").appendingPathExtension(fileExtension)
            index += 1
        }
        return url
    }

    /// Puts a file on the pasteboard the way Finder copies one, e.g. a finished recording.
    /// Returns false if that failed.
    static func copyFile(_ url: URL) -> Bool {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.writeObjects([url as NSURL])
    }

    /// Copies and/or saves, then reports the result with a toast (and an alert if saving failed).
    /// Returns which of them worked.
    @discardableResult
    static func export(_ shot: Screenshot, copy shouldCopy: Bool,
                       save shouldSave: Bool) -> (copied: Bool, saved: Bool) {
        var copied = false, saved = false
        var messages: [String] = []
        if shouldCopy {
            copied = copy(shot)
            messages.append(copied ? "Copied to clipboard" : "Couldn’t copy to clipboard")
        }
        if shouldSave {
            do {
                let url = try save(shot)
                messages.append("Saved \(url.lastPathComponent)")
                saved = true
            } catch {
                NSApp.activate()
                NSAlert(error: error).runModal()
            }
        }
        if !messages.isEmpty {
            Toast.show(messages.joined(separator: "\n"))
        }
        return (copied, saved)
    }
}
