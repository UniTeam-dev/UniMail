import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Маленькое дерево XML для ответов EWS: имена без префиксов пространств имён, атрибуты, текст.
final class XNode: @unchecked Sendable {
    let name: String
    var attributes: [String: String]
    var children: [XNode] = []
    var text = ""

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    /// Первый прямой потомок с именем.
    func child(_ name: String) -> XNode? { children.first { $0.name == name } }

    func children(_ name: String) -> [XNode] { children.filter { $0.name == name } }

    /// Путь по прямым потомкам: `node["RootFolder", "Items"]`.
    subscript(_ path: String...) -> XNode? {
        var node: XNode? = self
        for part in path { node = node?.child(part) }
        return node
    }

    /// Текст потомка по пути (обрезанный).
    func value(_ path: String...) -> String? {
        var node: XNode? = self
        for part in path { node = node?.child(part) }
        guard let node else { return nil }
        return node.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Все потомки на любой глубине с именем.
    func descendants(_ name: String) -> [XNode] {
        var result: [XNode] = []
        for child in children {
            if child.name == name { result.append(child) }
            result += child.descendants(name)
        }
        return result
    }

    func firstDescendant(_ name: String) -> XNode? {
        for child in children {
            if child.name == name { return child }
            if let found = child.firstDescendant(name) { return found }
        }
        return nil
    }
}

enum XMLTree {
    /// Разбор документа. nil — не XML.
    static func parse(_ data: Data) -> XNode? {
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = builder
        guard parser.parse() else { return nil }
        return builder.root
    }

    /// Экранирование текста и атрибутов.
    static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for ch in text {
            switch ch {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&apos;"
            default: result.append(ch)
            }
        }
        return result
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: XNode?
        private var stack: [XNode] = []

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            // Атрибуты тоже могут прийти с префиксом — оставляем локальное имя.
            var attributes: [String: String] = [:]
            for (key, value) in attributeDict {
                let local = key.split(separator: ":").last.map(String.init) ?? key
                attributes[local] = value
            }
            let element = XNode(name: elementName, attributes: attributes)
            if let parent = stack.last { parent.children.append(element) } else { root = element }
            stack.append(element)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            _ = stack.popLast()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.text += string
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            stack.last?.text += String(decoding: CDATABlock, as: UTF8.self)
        }
    }
}
