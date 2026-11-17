import Foundation

/// Line terminator style of a text (TortoiseMerge's `EOL` status-bar combo, `EOL.h`).
public enum LineEndingStyle: String, Sendable {
    case lf = "LF"
    case crlf = "CRLF"
    case cr = "CR"
    case mixed = "Mixed"
    case none = "None"

    /// Characters appended to a line when writing; mixed files are written with LF.
    public var terminator: String {
        switch self {
        case .crlf: return "\r\n"
        case .cr: return "\r"
        default: return "\n"
        }
    }

    public static func detect(in text: String) -> LineEndingStyle {
        var lf = 0, crlf = 0, cr = 0
        var previousWasCR = false
        for scalar in text.unicodeScalars {
            if scalar == "\n" {
                if previousWasCR { crlf += 1; cr -= 1 } else { lf += 1 }
                previousWasCR = false
            } else if scalar == "\r" {
                cr += 1
                previousWasCR = true
            } else {
                previousWasCR = false
            }
        }
        let kinds = [lf, crlf, cr].filter { $0 > 0 }.count
        if kinds == 0 { return .none }
        if kinds > 1 { return .mixed }
        return lf > 0 ? .lf : (crlf > 0 ? .crlf : .cr)
    }
}

/// A decoded text file that remembers how to write itself back — TortoiseMerge's `CFileTextLines`
/// keeps the encoding, BOM and EOL style so a save does not silently convert the file.
public struct DecodedText: Sendable {
    public let text: String
    public let encoding: String.Encoding
    public let hasBOM: Bool
    public let lineEnding: LineEndingStyle

    /// Human-readable name for status bars ("UTF-8 BOM", "UTF-16 LE BOM", "Windows-1252").
    public var encodingName: String {
        let base: String
        switch encoding {
        case .utf8: base = "UTF-8"
        case .utf16LittleEndian: base = "UTF-16 LE"
        case .utf16BigEndian: base = "UTF-16 BE"
        case .utf32LittleEndian: base = "UTF-32 LE"
        case .utf32BigEndian: base = "UTF-32 BE"
        case .windowsCP1252: base = "Windows-1252"
        case .isoLatin1: base = "ISO-8859-1"
        case .ascii: base = "ASCII"
        default: base = String.localizedName(of: encoding)
        }
        return hasBOM ? "\(base) BOM" : base
    }

    /// Encodes `newText` with the original encoding and BOM; nil if a character cannot be represented.
    public func encode(_ newText: String) -> Data? {
        guard let body = newText.data(using: encoding, allowLossyConversion: false) else { return nil }
        guard hasBOM else { return body }
        return TextFileEncoding.bom(for: encoding) + body
    }
}

public enum TextFileEncoding {
    /// git's own heuristic (`buffer_is_binary`): a NUL byte in the first 8000 bytes.
    public static func isBinary(_ data: Data) -> Bool {
        if bomEncoding(of: data) != nil { return false }
        return data.prefix(8000).contains(0)
    }

    /// Decodes file contents: BOM first, then strict UTF-8, then Windows-1252 (TortoiseMerge falls back
    /// to the ANSI code page the same way). Returns nil for binary data.
    public static func decode(_ data: Data) -> DecodedText? {
        if let (encoding, bomLength) = bomEncoding(of: data) {
            guard let text = String(data: data.dropFirst(bomLength), encoding: encoding) else { return nil }
            return DecodedText(text: text, encoding: encoding, hasBOM: true, lineEnding: .detect(in: text))
        }
        if isBinary(data) { return nil }
        if let text = String(data: data, encoding: .utf8) {
            return DecodedText(text: text, encoding: .utf8, hasBOM: false, lineEnding: .detect(in: text))
        }
        for encoding in [String.Encoding.windowsCP1252, .isoLatin1] {
            if let text = String(data: data, encoding: encoding) {
                return DecodedText(text: text, encoding: encoding, hasBOM: false, lineEnding: .detect(in: text))
            }
        }
        return nil
    }

    static func bomEncoding(of data: Data) -> (String.Encoding, Int)? {
        let bytes = [UInt8](data.prefix(4))
        if bytes.starts(with: [0xFF, 0xFE, 0x00, 0x00]) { return (.utf32LittleEndian, 4) }
        if bytes.starts(with: [0x00, 0x00, 0xFE, 0xFF]) { return (.utf32BigEndian, 4) }
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { return (.utf8, 3) }
        if bytes.starts(with: [0xFF, 0xFE]) { return (.utf16LittleEndian, 2) }
        if bytes.starts(with: [0xFE, 0xFF]) { return (.utf16BigEndian, 2) }
        return nil
    }

    static func bom(for encoding: String.Encoding) -> Data {
        switch encoding {
        case .utf8: return Data([0xEF, 0xBB, 0xBF])
        case .utf16LittleEndian: return Data([0xFF, 0xFE])
        case .utf16BigEndian: return Data([0xFE, 0xFF])
        case .utf32LittleEndian: return Data([0xFF, 0xFE, 0x00, 0x00])
        case .utf32BigEndian: return Data([0x00, 0x00, 0xFE, 0xFF])
        default: return Data()
        }
    }
}
