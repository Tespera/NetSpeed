import Cocoa

class NetSpeedStatusView: NSView {
    weak var statusItem: NSStatusItem?
    var font: NSFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
    var showIcons: Bool = true
    var alignment: NSTextAlignment = .right
    var horizontalPadding: CGFloat = 0
    var lineGap: CGFloat = 0
    var upIcon: String = "↑"
    var downIcon: String = "↓"
    var arrowKern: CGFloat = -0.6
    private var upText: String = ""
    private var downText: String = ""

    func setText(up: String, down: String) {
        upText = up
        downText = down
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let par = NSMutableParagraphStyle()
        par.alignment = alignment
        par.lineBreakMode = .byTruncatingMiddle
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: par,
            .foregroundColor: NSColor.labelColor
        ]

        let upHas = !upText.isEmpty
        let downHas = !downText.isEmpty
        let up = upHas ? ((showIcons ? upIcon : "") + upText) : ""
        let down = downHas ? ((showIcons ? downIcon : "") + downText) : ""

        let lineRectWidth = bounds.width - horizontalPadding * 2

        if upHas && downHas {
            let upSize = up.size(withAttributes: attrs)
            let downSize = down.size(withAttributes: attrs)
            let totalHeight = upSize.height + downSize.height - lineGap
            let startY = floor((bounds.height - totalHeight) / 2)
            let upRect = NSRect(x: horizontalPadding, y: startY + downSize.height - lineGap, width: lineRectWidth, height: upSize.height)
            let downRect = NSRect(x: horizontalPadding, y: startY, width: lineRectWidth, height: downSize.height)
            buildAttributed(up, attrs).draw(in: upRect)
            buildAttributed(down, attrs).draw(in: downRect)
        } else if upHas {
            let upSize = up.size(withAttributes: attrs)
            let y = floor((bounds.height - upSize.height) / 2)
            let rect = NSRect(x: horizontalPadding, y: y, width: lineRectWidth, height: upSize.height)
            buildAttributed(up, attrs).draw(in: rect)
        } else if downHas {
            let downSize = down.size(withAttributes: attrs)
            let y = floor((bounds.height - downSize.height) / 2)
            let rect = NSRect(x: horizontalPadding, y: y, width: lineRectWidth, height: downSize.height)
            buildAttributed(down, attrs).draw(in: rect)
        } else {
            let dash = "—"
            let size = dash.size(withAttributes: attrs)
            let y = floor((bounds.height - size.height) / 2)
            let rect = NSRect(x: horizontalPadding, y: y, width: lineRectWidth, height: size.height)
            NSAttributedString(string: dash, attributes: attrs).draw(in: rect)
        }
    }

    // Click handling is provided by NSStatusItem.button's menu.
    private func buildAttributed(_ text: String, _ attrs: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let ms = NSMutableAttributedString(string: text, attributes: attrs)
        if showIcons && text.count > 1 {
            ms.addAttribute(.kern, value: arrowKern, range: NSRange(location: 0, length: 1))
        }
        return ms
    }
}
