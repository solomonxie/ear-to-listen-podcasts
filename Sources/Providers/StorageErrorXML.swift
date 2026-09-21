import Foundation

/// The failure envelope every XML storage API in this app returns — S3's, COS's, OSS's
/// and Azure's are the same two elements:
///
/// ```xml
/// <Error><Code>AccessDenied</Code><Message>…</Message></Error>
/// ```
///
/// The code is the useful part, and what callers branch on (`NoSuchKey` is a normal
/// answer for a backup that hasn't been written yet), so it's carried rather than
/// flattened into a status number.
enum StorageErrorXML {
    static func parse(_ data: Data) -> (code: String?, message: String?) {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return (delegate.code, delegate.message)
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var code: String?
        var message: String?
        private var text = ""

        func parser(
            _ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
            qualifiedName: String?, attributes: [String: String] = [:]
        ) {
            text = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(
            _ parser: XMLParser, didEndElement element: String, namespaceURI: String?,
            qualifiedName: String?
        ) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch element {
            case "Code": code = value
            case "Message": message = value
            default: break
            }
            text = ""
        }
    }
}
