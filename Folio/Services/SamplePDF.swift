import UIKit
import PDFKit

enum SamplePDF {
    static func create(at url: URL, pages: Int = 25, scanned: Bool = false, rotated: Bool = false) throws {
        let topics = [
            ("A little space\\nto focus.", "A field guide to reading with intention"),
            ("Make it yours.", "Highlight a thought. Leave a note. Follow an idea."),
            ("Pick up where\\nyou left off.", "Good reading doesn’t need a restart."),
            ("Room for\\na new idea.", "There is always something between the lines."),
            ("Slow down.\\nRead deeply.", "A small ritual for a clearer mind.")
        ]
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        let data = renderer.pdfData { context in
            for index in 0..<pages {
                context.beginPage()
                let draw = {
                    UIColor(red: 0.98, green: 0.97, blue: 0.94, alpha: 1).setFill()
                    UIRectFill(bounds)
                    let ink = UIColor(red: 0.08, green: 0.15, blue: 0.19, alpha: 1)
                    let teal = UIColor(red: 0.15, green: 0.47, blue: 0.42, alpha: 1)
                    func text(_ value: String, _ rect: CGRect, _ size: CGFloat, _ color: UIColor, serif: Bool = false) {
                        let font = UIFont(name: serif ? "Georgia" : "Helvetica", size: size) ?? UIFont.systemFont(ofSize: size)
                        (value as NSString).draw(in: rect, withAttributes: [.font: font, .foregroundColor: color])
                    }
                    text("F O L I O   /   F I E L D   N O T E S", CGRect(x: 54, y: 48, width: 500, height: 24), 11, teal)
                    let topic = topics[index % topics.count]
                    text(topic.0.replacingOccurrences(of: "\\n", with: "\n"), CGRect(x: 50, y: 125, width: 512, height: 170), 54, ink, serif: true)
                    text(topic.1, CGRect(x: 54, y: 325, width: 480, height: 50), 18, teal)
                    text("A good document is a place to think. Give yourself a moment to notice the details, connect the ideas, and make a little room for curiosity.\n\nSelect these words to highlight, underline, or strike through a passage. Switch to the pen to draw in the margin, or add a note to capture a thought.\n\nFolio remembers your page automatically. Close this document and open it again whenever you’re ready to continue.",
                         CGRect(x: 54, y: 410, width: 470, height: 250), 17, ink)
                    teal.setFill()
                    UIRectFill(CGRect(x: 54, y: 716, width: 34, height: 3))
                    text("A QUIETER WAY TO READ", CGRect(x: 101, y: 709, width: 320, height: 20), 10, teal)
                    text(String(format: "%02d", index + 1), CGRect(x: 522, y: 706, width: 45, height: 26), 16, ink)
                }
                if scanned {
                    UIGraphicsImageRenderer(size: bounds.size).image { _ in draw() }.draw(in: bounds)
                } else { draw() }
            }
        }
        if rotated, let pdf = PDFDocument(data: data) {
            for index in 0..<pages {
                pdf.page(at: index)?.rotation = index.isMultiple(of: 2) ? 90 : 0
                if !index.isMultiple(of: 2) { pdf.page(at: index)?.setBounds(CGRect(x: 20, y: 30, width: 550, height: 720), for: .cropBox) }
            }
            guard pdf.write(to: url) else { throw FolioError.exportFailed }
        } else { try data.write(to: url, options: .atomic) }
    }
}
