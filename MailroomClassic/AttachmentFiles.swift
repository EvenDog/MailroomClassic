// Saves received attachments to disk so you can open or keep them. Every file
// saved is marked as "downloaded from the internet" (quarantined), so macOS
// warns you before an attached app or script can run, like other mail apps.

import AppKit
import Foundation

enum AttachmentFiles {
    // Saves the attachment to a private temporary folder and opens it in its
    // usual app (Preview for PDFs, and so on).
    static func open(_ attachment: MailAttachment) throws {
        let url = try saveToTemporaryFolder(attachment)
        NSWorkspace.shared.open(url)
    }

    // Asks where to save the attachment, then saves it there.
    static func saveWithPanel(_ attachment: MailAttachment) throws {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = safeFilename(attachment.filename)
        guard panel.runModal() == .OK, let url = panel.url else { return }   // you clicked Cancel
        try write(attachment, to: url)
    }

    // Writes the attachment into its own new temporary folder (so files with the
    // same name never collide) and returns where it went.
    static func saveToTemporaryFolder(_ attachment: MailAttachment) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MailroomClassic", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(safeFilename(attachment.filename))
        try write(attachment, to: url)
        return url
    }

    private static func write(_ attachment: MailAttachment, to url: URL) throws {
        try attachment.data.write(to: url)
        // Mark the file as quarantined: this is what makes Gatekeeper check it before it runs.
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineAgentNameKey as String: "Mailroom Classic",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeEmailAttachment as String,
        ]
        var fileURL = url
        try fileURL.setResourceValues(values)
    }

    // Removes characters that aren't allowed in file names on a Mac.
    private static func safeFilename(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return cleaned.isEmpty ? "attachment" : cleaned
    }
}
