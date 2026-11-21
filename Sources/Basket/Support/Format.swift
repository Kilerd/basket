import Foundation
import BasketCore

enum Format {
    /// Memory sizes use binary units (what Activity Monitor shows), in the user's locale
    /// ("1.2 GB", "1,2 Go").
    static func memory(_ bytes: Int64) -> String {
        // The formatter spells zero out ("Zero kB"); a dashboard reads better with a digit.
        bytes == 0 ? zero(.memory) : bytes.formatted(.byteCount(style: .memory))
    }

    /// Disk sizes use decimal units (what Finder shows).
    static func disk(_ bytes: Int64) -> String {
        bytes == 0 ? zero(.file) : bytes.formatted(.byteCount(style: .file))
    }

    /// "0 MB" in the user's locale.
    private static func zero(_ style: ByteCountFormatStyle.Style) -> String {
        Int64(0).formatted(.byteCount(style: style, allowedUnits: .mb, spellsOutZero: false))
    }

    /// `value` is in percent: 15.3 → "15.3%" ("15,3 %" in French).
    static func percent(_ value: Double) -> String {
        (value / 100).formatted(.percent.precision(.fractionLength(1)))
    }

    /// A count in the user's locale ("1,234", "1 234").
    static func count(_ value: Int) -> String {
        value.formatted()
    }

    static func relative(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }

    static func dateTime(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    /// A name in the user's quotation marks: “web”, 「web」, « web », „web“.
    static func quoted(_ name: String) -> String {
        String(localized: "“\(name)”", comment: "A name in quotes")
    }

    /// Names in quotation marks, joined as a list in the user's language.
    static func quotedList(_ names: [String]) -> String {
        names.map(quoted).localizedList
    }

    /// Whole sentences run together as one paragraph: with a space, except in languages written
    /// without spaces between sentences (Chinese, Japanese).
    static func sentences(_ parts: [String]) -> String {
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        let separator = ["zh", "ja"].contains(where: { language.hasPrefix($0) }) ? "" : " "
        return parts.joined(separator: separator)
    }

    static func shortDigest(_ digest: String) -> String {
        let hex = digest.split(separator: ":").last.map(String.init) ?? digest
        return String(hex.prefix(12))
    }

    static func port(_ p: PortMapping) -> String {
        let host = (p.hostAddress == "0.0.0.0" || p.hostAddress.isEmpty) ? "" : "\(p.hostAddress):"
        let range = p.count > 1 ? "\(p.hostPort)-\(p.hostPort + p.count - 1)" : "\(p.hostPort)"
        let proto = p.proto.lowercased() == "tcp" ? "" : "/\(p.proto)"
        // "8080" when host and container ports match, "8080→80" otherwise.
        let target = p.hostPort == p.containerPort ? "" : "→\(p.containerPort)"
        return "\(host)\(range)\(target)\(proto)"
    }

    static func ports(_ ports: [PortMapping]) -> String {
        ports.isEmpty ? "—" : ports.map(port).joined(separator: ", ")
    }
}

/// Splits "docker.io/library/nginx:1.27" into a display name ("nginx") and tag ("1.27").
struct ImageName: Hashable {
    var repository: String
    var tag: String
    var registry: String?

    init(_ reference: String) {
        var rest = reference
        var digestTag: String?
        if let at = rest.firstIndex(of: "@") {
            digestTag = String(rest[rest.index(after: at)...])
            rest = String(rest[..<at])
        }
        var tag = "latest"
        if let colon = rest.lastIndex(of: ":"), !rest[colon...].contains("/") {
            tag = String(rest[rest.index(after: colon)...])
            rest = String(rest[..<colon])
        }
        var parts = rest.split(separator: "/").map(String.init)
        if parts.count > 1, parts[0].contains(".") || parts[0].contains(":") || parts[0] == "localhost" {
            registry = parts.removeFirst()
        }
        if registry == "docker.io", parts.first == "library" { parts.removeFirst() }
        repository = parts.joined(separator: "/")
        self.tag = digestTag.map { Format.shortDigest($0) } ?? tag
    }

    var display: String { "\(repository):\(tag)" }
}

enum MemorySize {
    /// "512M" for 512 MiB, "2G" for whole GiB.
    static func cliString(megabytes: Int) -> String {
        megabytes % 1024 == 0 ? "\(megabytes / 1024)G" : "\(megabytes)M"
    }
}
