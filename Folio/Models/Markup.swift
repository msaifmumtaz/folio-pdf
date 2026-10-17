import Foundation
import PDFKit
import UIKit

enum MarkupKind: String, Codable, CaseIterable, Sendable {
    case highlight, underline, strikeOut, ink, note
}

struct Markup: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var page: Int
    var kind: MarkupKind
    var bounds: CGRect
    var points: [CGPoint] = []
    var color: InkColor = .teal
    var width: Double = 3
    var text: String = ""

    // Page coordinates are preserved, including nonzero crop origins and rotation.
    func annotation() -> PDFAnnotation {
        let type: PDFAnnotationSubtype
        switch kind {
        case .highlight: type = .highlight
        case .underline: type = .underline
        case .strikeOut: type = .strikeOut
        case .ink: type = .ink
        case .note: type = .text
        }
        let annotation = PDFAnnotation(bounds: bounds, forType: type, withProperties: nil)
        annotation.userName = "Folio"
        annotation.setValue(id.uuidString, forAnnotationKey: .name)
        annotation.color = color.uiColor
        annotation.contents = text
        if kind == .ink {
            let border = PDFBorder()
            border.lineWidth = width
            annotation.border = border
            let path = UIBezierPath()
            for (index, point) in points.enumerated() {
                let local = CGPoint(x: point.x - bounds.minX, y: point.y - bounds.minY)
                if index == 0 { path.move(to: local) } else { path.addLine(to: local) }
            }
            if points.count == 1, let point = points.first {
                path.addLine(to: CGPoint(x: point.x - bounds.minX + 0.1, y: point.y - bounds.minY))
            }
            annotation.add(path)
        }
        if kind == .note { annotation.iconType = .note }
        return annotation
    }
}

enum InkColor: String, Codable, CaseIterable, Sendable {
    case teal, gold, coral, blue, graphite

    var uiColor: UIColor {
        switch self {
        case .teal: UIColor(red: 0.13, green: 0.52, blue: 0.48, alpha: 1)
        case .gold: UIColor(red: 0.98, green: 0.77, blue: 0.25, alpha: 1)
        case .coral: UIColor(red: 0.88, green: 0.36, blue: 0.30, alpha: 1)
        case .blue: UIColor(red: 0.27, green: 0.48, blue: 0.85, alpha: 1)
        case .graphite: UIColor(red: 0.20, green: 0.23, blue: 0.27, alpha: 1)
        }
    }
}

struct MarkupEnvelope: Codable, Sendable {
    var version = 2
    var marks: [Markup] = []
}

enum FolioError: LocalizedError {
    case invalidPDF, emptyPDF, missingFile, passwordRequired, wrongPassword, restricted, exportFailed, newerMarkup, sourceChanged, differentPDF
    var errorDescription: String? {
        switch self {
        case .invalidPDF: "This file could not be read as a PDF. Try another copy."
        case .emptyPDF: "This PDF has no pages."
        case .missingFile: "This PDF is unavailable. Retry when its file provider is ready, or locate the original in Files."
        case .passwordRequired: "Enter this document’s password to continue."
        case .wrongPassword: "That password didn’t unlock the document."
        case .restricted: "This document does not allow annotations."
        case .exportFailed: "The PDF could not be exported. Your saved annotations are still available."
        case .sourceChanged: "The original PDF has changed. Open the updated version to read it separately; your previous reading data is preserved."
        case .differentPDF: "Choose the matching original PDF. This file has different contents."
        case .newerMarkup: "These annotations were saved by a newer version of Folio."
        }
    }
}
