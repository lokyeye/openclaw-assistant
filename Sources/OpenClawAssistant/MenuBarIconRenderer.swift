import AppKit
import Foundation

enum MenuBarIconRenderer {
    static func image(for reports: [InstanceReport]) -> NSImage {
        let symbolName = symbolName(for: reports)
        let configuration = NSImage.SymbolConfiguration(
            pointSize: 13,
            weight: .bold
        )

        if let image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: "OpenClaw 状态"
        )?.withSymbolConfiguration(configuration) {
            image.isTemplate = true
            return image
        }

        let image = NSImage(size: NSSize(width: 16, height: 16))
        image.lockFocus()
        drawFallbackBadge()
        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    private static func symbolName(for reports: [InstanceReport]) -> String {
        guard !reports.isEmpty else {
            return "questionmark.circle.fill"
        }

        if reports.contains(where: { $0.status == .crashed }) {
            return "exclamationmark.triangle.fill"
        }
        if reports.contains(where: { $0.status == .missingProject }) {
            return "questionmark.folder.fill"
        }

        let runningCount = reports.filter { $0.status == .running || $0.status == .starting }.count
        if runningCount == reports.count {
            return "checkmark.circle.fill"
        }
        if runningCount > 0 {
            return "play.circle.fill"
        }

        return "stop.circle.fill"
    }

    private static func drawFallbackBadge() {
        NSColor.black.setFill()
        let badge = NSBezierPath(roundedRect: NSRect(x: 1, y: 1, width: 14, height: 14), xRadius: 4, yRadius: 4)
        badge.fill()

        let text = NSString(string: "OC")
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        text.draw(at: CGPoint(x: 2.5, y: 3.5), withAttributes: attributes)
    }
}
