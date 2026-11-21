import Foundation

/// Where updates come from and what they may look like (docs/updates.md).
public struct UpdatePolicy: Sendable, Equatable {
    public static let bundleIdentifier = "dev.basket.app"
    public static let productionFeedURL = URL(string: "https://github.com/Kilerd/basket/releases/latest/download/latest.json")!
    public static let productionDownloadPrefix = "https://github.com/Kilerd/basket/releases/download/"
    public static let releasesPageURL = URL(string: "https://github.com/Kilerd/basket/releases")!
    /// `latest.json` is a few KB; anything bigger is not ours.
    public static let maxManifestBytes = 1 << 20
    /// Basket.zip is ~10 MB; a generous cap so a broken or hostile server can't fill the disk.
    public static let defaultMaxArchiveBytes: Int64 = 256 << 20

    public var feedURL: URL
    /// The manifest's `url` must start with one of these.
    public var downloadPrefixes: [String]
    public var maxArchiveBytes: Int64

    public init(feedURL: URL, downloadPrefixes: [String], maxArchiveBytes: Int64 = UpdatePolicy.defaultMaxArchiveBytes) {
        self.feedURL = feedURL
        self.downloadPrefixes = downloadPrefixes
        self.maxArchiveBytes = maxArchiveBytes
    }

    public static let production = UpdatePolicy(feedURL: productionFeedURL, downloadPrefixes: [productionDownloadPrefix])

    /// A local test feed (the app's DEBUG-only `BASKET_UPDATE_FEED_URL`): archives must sit in the
    /// feed's own directory, so a `file://` feed only ever allows `file://` URLs next to it.
    public static func testFeed(_ feedURL: URL) -> UpdatePolicy {
        UpdatePolicy(feedURL: feedURL, downloadPrefixes: [feedURL.deletingLastPathComponent().absoluteString])
    }
}

/// `latest.json` as published with every release (docs/updates.md).
public struct UpdateManifest: Codable, Equatable, Sendable {
    public var version: String
    public var pubDate: String
    public var notes: String
    public var minimumSystemVersion: String
    public var url: String
    public var sha256: String
    public var signature: String

    enum CodingKeys: String, CodingKey {
        case version
        case pubDate = "pub_date"
        case notes
        case minimumSystemVersion = "minimum_system_version"
        case url, sha256, signature
    }

    public init(version: String, pubDate: String, notes: String, minimumSystemVersion: String,
                url: String, sha256: String, signature: String) {
        self.version = version
        self.pubDate = pubDate
        self.notes = notes
        self.minimumSystemVersion = minimumSystemVersion
        self.url = url
        self.sha256 = sha256
        self.signature = signature
    }

    /// Decodes `latest.json`; every field is required and must be a string (unknown keys are
    /// ignored so the format can grow).
    public static func decode(_ data: Data) throws -> UpdateManifest {
        guard data.count <= UpdatePolicy.maxManifestBytes else { throw UpdateError.invalidManifest(String(localized: "it is too large", bundle: .main)) }
        do {
            return try JSONDecoder().decode(UpdateManifest.self, from: data)
        } catch DecodingError.keyNotFound(let key, _) {
            throw UpdateError.invalidManifest(String(localized: "“\(key.stringValue)” is missing", bundle: .main))
        } catch DecodingError.valueNotFound(_, let context), DecodingError.typeMismatch(_, let context) {
            guard let key = context.codingPath.last?.stringValue else {
                throw UpdateError.invalidManifest(String(localized: "a value isn't a string", bundle: .main))
            }
            throw UpdateError.invalidManifest(String(localized: "“\(key)” isn't a string", bundle: .main))
        } catch {
            throw UpdateError.invalidManifest(String(localized: "it isn't valid JSON", bundle: .main))
        }
    }

    /// Checks every field against the format and `policy`; the result is safe to show and download.
    public func validated(policy: UpdatePolicy) throws -> UpdateOffer {
        guard let version = SemanticVersion(version) else {
            throw UpdateError.invalidManifest(String(localized: "“version” \(quoted(version)) isn't X.Y.Z", bundle: .main))
        }
        guard let date = Self.parseDate(pubDate) else {
            throw UpdateError.invalidManifest(String(localized: "“pub_date” \(quoted(pubDate)) isn't an ISO 8601 date", bundle: .main))
        }
        guard let minimum = SystemVersion(minimumSystemVersion) else {
            throw UpdateError.invalidManifest(String(localized: "“minimum_system_version” \(quoted(minimumSystemVersion)) isn't a macOS version", bundle: .main))
        }
        let url = try Self.downloadURL(url, policy: policy)
        let sha = sha256.lowercased()
        guard sha.count == 64, sha.allSatisfy({ $0.isHexDigit && $0.isASCII }) else {
            throw UpdateError.invalidManifest(String(localized: "“sha256” isn't 64 hexadecimal characters", bundle: .main))
        }
        guard let signature = Data(base64Encoded: signature), signature.count == 64 else {
            throw UpdateError.invalidManifest(String(localized: "“signature” isn't a base64 Ed25519 signature", bundle: .main))
        }
        return UpdateOffer(version: version, date: date, notes: notes, minimumSystemVersion: minimum,
                           url: url, sha256: sha, signature: signature)
    }

    static func downloadURL(_ string: String, policy: UpdatePolicy) throws -> URL {
        guard let prefix = policy.downloadPrefixes.first(where: { !$0.isEmpty && string.hasPrefix($0) }) else {
            guard let allowed = policy.downloadPrefixes.first else {
                throw UpdateError.invalidManifest(String(localized: "“url” isn't a Basket release download (none are allowed)", bundle: .main))
            }
            throw UpdateError.invalidManifest(String(localized: "“url” isn't a Basket release download (\(allowed))", bundle: .main))
        }
        guard let url = URL(string: string), let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              url.absoluteString == string
        else { throw UpdateError.invalidManifest(String(localized: "“url” isn't a valid URL", bundle: .main)) }
        let rest = string.dropFirst(prefix.count)
        let segments = rest.split(separator: "/", omittingEmptySubsequences: false)
        guard components.query == nil, components.fragment == nil, components.user == nil, components.password == nil,
              !rest.contains("\\"), !rest.contains("%"),
              !segments.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
              string.hasSuffix(".zip")
        else { throw UpdateError.invalidManifest(String(localized: "“url” must name a .zip directly under \(prefix)", bundle: .main)) }
        // Only a test feed (DEBUG builds) can allow file:// — production only allows GitHub over https.
        if prefix.hasPrefix("file://") {
            guard url.isFileURL else { throw UpdateError.invalidManifest(String(localized: "“url” must be a file URL", bundle: .main)) }
        } else {
            // The production prefix pins the host; a DEBUG https test feed may use a port.
            guard components.scheme == "https", components.host != nil else {
                throw UpdateError.invalidManifest(String(localized: "“url” must use https", bundle: .main))
            }
        }
        return url
    }

    static func parseDate(_ string: String) -> Date? {
        if let date = try? Date(string, strategy: Date.ISO8601FormatStyle()) { return date }
        return try? Date(string, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    private func quoted(_ s: String) -> String { "“\(s.prefix(40))”" }
}

/// A validated manifest: what the update sheet shows and the installer downloads.
public struct UpdateOffer: Equatable, Sendable {
    public let version: SemanticVersion
    public let date: Date
    /// Markdown (the version's CHANGELOG section).
    public let notes: String
    public let minimumSystemVersion: SystemVersion
    public let url: URL
    /// Lower-case hex.
    public let sha256: String
    /// Raw 64-byte Ed25519 signature over the zip.
    public let signature: Data

    public init(version: SemanticVersion, date: Date, notes: String, minimumSystemVersion: SystemVersion,
                url: URL, sha256: String, signature: Data) {
        self.version = version
        self.date = date
        self.notes = notes
        self.minimumSystemVersion = minimumSystemVersion
        self.url = url
        self.sha256 = sha256
        self.signature = signature
    }

    public enum Eligibility: Equatable, Sendable {
        case available
        /// Same or older than the running version: nothing to do (never a downgrade).
        case upToDate
        case requiresNewerSystem(SystemVersion)
    }

    public func eligibility(current: SemanticVersion, system: SystemVersion) -> Eligibility {
        guard version > current else { return .upToDate }
        guard system >= minimumSystemVersion else { return .requiresNewerSystem(minimumSystemVersion) }
        return .available
    }
}
