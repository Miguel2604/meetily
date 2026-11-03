import Foundation

/// A summary template: the report skeleton and per-section instructions (port of `templates/types.rs`).
public struct Template: Codable, Sendable, Hashable {
    public struct Section: Codable, Sendable, Hashable {
        public var title: String
        public var instruction: String
        /// "paragraph", "list" or "string".
        public var format: String
        public var itemFormat: String?
        public var exampleItemFormat: String?

        public init(title: String, instruction: String, format: String, itemFormat: String? = nil, exampleItemFormat: String? = nil) {
            self.title = title
            self.instruction = instruction
            self.format = format
            self.itemFormat = itemFormat
            self.exampleItemFormat = exampleItemFormat
        }

        enum CodingKeys: String, CodingKey {
            case title, instruction, format, itemFormat = "item_format", exampleItemFormat = "example_item_format"
        }
    }

    public var name: String
    public var description: String
    public var sections: [Section]

    public func validate() throws(TemplateError) {
        guard !name.isEmpty else { throw .invalid("Template name cannot be empty") }
        guard !description.isEmpty else { throw .invalid("Template description cannot be empty") }
        guard !sections.isEmpty else { throw .invalid("Template must have at least one section") }
        for (index, section) in sections.enumerated() {
            guard !section.title.isEmpty else { throw .invalid("Section \(index) has empty title") }
            guard !section.instruction.isEmpty else { throw .invalid("Section '\(section.title)' has empty instruction") }
            guard ["paragraph", "list", "string"].contains(section.format) else {
                throw .invalid("Section '\(section.title)' has invalid format '\(section.format)'. Must be 'paragraph', 'list', or 'string'")
            }
        }
    }

    var markdownStructure: String {
        sections.reduce("# <Add Title here>\n\n") { $0 + "**\($1.title)**\n\n" }
    }

    var sectionInstructions: String {
        sections.reduce("- **For the main title (`# [AI-Generated Title]`):** Analyze the entire transcript and create a concise, descriptive title for the meeting.\n") { text, section in
            var text = text + "- **For the '\(section.title)' section:** \(section.instruction).\n"
            if let format = section.itemFormat ?? section.exampleItemFormat {
                text += "  - Items in this section should follow the format: `\(format)`.\n"
            }
            return text
        }
    }
}

public enum TemplateError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case invalid(String)
    case notFound(String)

    public var description: String {
        switch self {
        case .invalid(let message): message
        case .notFound(let id): "Template '\(id)' not found"
        }
    }

    public var errorDescription: String? { description }
}

/// Templates by id: a user's JSON in `~/Library/Application Support/Meetily/templates` wins over the six bundled ones.
public enum Templates {
    public static let customDirectory = URL.applicationSupportDirectory.appending(path: "Meetily/templates", directoryHint: .isDirectory)

    public static func load(_ id: String, customDirectory: URL? = customDirectory) throws(TemplateError) -> Template {
        guard !id.isEmpty, !id.contains("/"), !id.hasPrefix(".") else { throw .notFound(id) }
        let custom = customDirectory?.appending(path: "\(id).json")
        let bundled = Bundle.module.url(forResource: id, withExtension: "json", subdirectory: "templates")
        guard let data = [custom, bundled].compactMap({ $0 }).lazy.compactMap({ try? Data(contentsOf: $0) }).first else {
            throw .notFound(id)
        }
        return try parse(data)
    }

    public static func parse(_ data: Data) throws(TemplateError) -> Template {
        let template: Template
        do { template = try JSONDecoder().decode(Template.self, from: data) } catch {
            throw .invalid("Failed to parse template JSON: \(error.localizedDescription)")
        }
        try template.validate()
        return template
    }

    public static func ids(customDirectory: URL? = customDirectory) -> [String] {
        let bundled = Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: "templates") ?? []
        let custom = customDirectory.flatMap { try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) } ?? []
        return Set((bundled + custom).filter { $0.pathExtension == "json" }.map { $0.deletingPathExtension().lastPathComponent }).sorted()
    }

    /// (id, name, description) for every template that loads.
    public static func list(customDirectory: URL? = customDirectory) -> [(id: String, name: String, description: String)] {
        ids(customDirectory: customDirectory).compactMap { id in
            (try? load(id, customDirectory: customDirectory)).map { (id, $0.name, $0.description) }
        }
    }
}
