import Foundation

// Decodable mirrors of the docker CLI's JSON (docker 29, containerd image store), as OrbStack's
// `docker --context orbstack …` prints it. Only the fields the migrator reads; everything optional
// so a newer/older docker never sinks a whole list.

/// One line of `docker image ls -a --digests --no-trunc --format json` (JSON Lines, sizes are
/// human-readable decimal strings).
struct RawDockerImageLine: Decodable, Sendable {
    var Containers: String?
    var CreatedAt: String?
    var Digest: String?
    var ID: String?
    var Repository: String?
    var Size: String?
    var Tag: String?
}

/// One element of `docker image inspect` (optionally `--platform`).
struct RawDockerImage: Decodable, Sendable {
    var Id: String?
    var RepoTags: [String]?
    var RepoDigests: [String]?
    var Created: String?
    var Size: Int64?
    var Os: String?
    var Architecture: String?
    var Variant: String?
    var Config: RawDockerConfig?
    /// Uncompressed layer digests of the resolved platform.
    var RootFS: RawDockerRootFS?
    /// What the reference points at: an index for a default lookup of a multi-platform image, the
    /// platform manifest for `--platform` lookups.
    var Descriptor: RawDockerDescriptor?
}

struct RawDockerRootFS: Decodable, Sendable {
    var Layers: [String]?
}

struct RawDockerDescriptor: Decodable, Sendable {
    var mediaType: String?
    var digest: String?
}

/// `Config` of an image or a container.
struct RawDockerConfig: Decodable, Sendable {
    var Hostname: String?
    var User: String?
    var Env: [String]?
    var Cmd: [String]?
    var Entrypoint: [String]?
    var WorkingDir: String?
    var Labels: [String: String]?
    var Image: String?
    var Tty: Bool?
    var OpenStdin: Bool?
    var Healthcheck: RawDockerHealthcheck?
    var ExposedPorts: [String: EmptyObject]?
    var Volumes: [String: EmptyObject]?
    var StopSignal: String?
}

struct EmptyObject: Decodable, Sendable, Hashable {}

struct RawDockerHealthcheck: Decodable, Sendable {
    var Test: [String]?
}

/// One line of `docker ps -a --no-trunc --format json`.
struct RawDockerPSLine: Decodable, Sendable {
    var ID: String?
    var Names: String?
    var Image: String?
    var State: String?
    var Status: String?
    var Ports: String?
    var CreatedAt: String?
}

/// One element of `docker inspect --type container`.
struct RawDockerContainer: Decodable, Sendable {
    var Id: String?
    var Created: String?
    var Name: String?
    /// Image ID (`sha256:…`), not the reference the user typed (that is `Config.Image`).
    var Image: String?
    var Platform: String?
    var State: RawDockerState?
    var Config: RawDockerConfig?
    var HostConfig: RawDockerHostConfig?
    var Mounts: [RawDockerMount]?
    var NetworkSettings: RawDockerNetworkSettings?
}

struct RawDockerState: Decodable, Sendable {
    var Status: String?
    var Running: Bool?
}

struct RawDockerHostConfig: Decodable, Sendable {
    var Binds: [String]?
    var NetworkMode: String?
    var PortBindings: [String: [RawDockerPortBinding]?]?
    var RestartPolicy: RawDockerRestartPolicy?
    var AutoRemove: Bool?
    var VolumeDriver: String?
    var VolumesFrom: [String]?
    var CapAdd: [String]?
    var CapDrop: [String]?
    var Dns: [String]?
    var DnsOptions: [String]?
    var DnsSearch: [String]?
    var ExtraHosts: [String]?
    var GroupAdd: [String]?
    var IpcMode: String?
    var Links: [String]?
    var PidMode: String?
    var Privileged: Bool?
    var PublishAllPorts: Bool?
    var ReadonlyRootfs: Bool?
    var SecurityOpt: [String]?
    var UTSMode: String?
    var UsernsMode: String?
    var Runtime: String?
    var Memory: Int64?
    var NanoCpus: Int64?
    var CpuPeriod: Int64?
    var CpuQuota: Int64?
    var Devices: [RawDockerDevice]?
    var DeviceRequests: [RawDockerDeviceRequest]?
    var Ulimits: [RawDockerUlimit]?
    var Init: Bool?
    var Tmpfs: [String: String]?
    var Sysctls: [String: String]?
}

struct RawDockerPortBinding: Decodable, Sendable, Hashable {
    var HostIp: String?
    var HostPort: String?
}

struct RawDockerRestartPolicy: Decodable, Sendable {
    var Name: String?
    var MaximumRetryCount: Int?
}

struct RawDockerDevice: Decodable, Sendable {
    var PathOnHost: String?
    var PathInContainer: String?
}

struct RawDockerDeviceRequest: Decodable, Sendable {
    var Driver: String?
    var Count: Int?
}

struct RawDockerUlimit: Decodable, Sendable {
    var Name: String?
    var Soft: Int64?
    var Hard: Int64?
}

struct RawDockerMount: Decodable, Sendable {
    var `Type`: String?
    var Name: String?
    var Source: String?
    var Destination: String?
    var Driver: String?
    var Mode: String?
    var RW: Bool?
}

struct RawDockerNetworkSettings: Decodable, Sendable {
    var Ports: [String: [RawDockerPortBinding]?]?
    var Networks: [String: RawDockerEndpoint]?
}

struct RawDockerEndpoint: Decodable, Sendable {
    var Aliases: [String]?
    var Links: [String]?
    var IPAMConfig: RawDockerIPAMConfig?
    var DNSNames: [String]?
}

struct RawDockerIPAMConfig: Decodable, Sendable {
    var IPv4Address: String?
    var IPv6Address: String?
}

/// `docker version --format json` (only what the status line shows).
struct RawDockerVersion: Decodable, Sendable {
    struct Server: Decodable, Sendable {
        var Version: String?
        var Os: String?
        var Arch: String?
    }
    var Server: Server?
}

// MARK: - Parsing helpers

enum DockerFormat {
    /// Media types of a single-platform image manifest.
    static let manifestMediaTypes: Set<String> = [
        "application/vnd.oci.image.manifest.v1+json", "application/vnd.docker.distribution.manifest.v2+json",
    ]

    /// Decodes JSON Lines (`--format json` on list commands), skipping lines that don't decode.
    static func decodeLines<T: Decodable>(_ type: T.Type, from data: Data) -> [T] {
        let decoder = JSONDecoder()
        return data.split(separator: UInt8(ascii: "\n")).compactMap { line in
            let trimmed = Data(line).trimmingWhitespace()
            guard trimmed.first == UInt8(ascii: "{") else { return nil }
            return try? decoder.decode(T.self, from: trimmed)
        }
    }

    /// Decodes a JSON array (`inspect`), keeping the elements that decode; [] for empty output.
    static func decodeArray<T: Decodable>(_ type: T.Type, from data: Data, command: String) throws -> [T] {
        let trimmed = data.trimmingWhitespace()
        guard !trimmed.isEmpty else { return [] }
        return try RawJSON.decode([Lossy<T>].self, from: trimmed, command: command).compactMap(\.value)
    }

    /// "76.5MB", "1.48GB", "907kB", "0B" → bytes. Docker (go-units `HumanSize`) uses decimal units.
    static func parseSize(_ text: String?) -> Int64? {
        guard let text = text?.trimmingCharacters(in: .whitespaces),
              let match = text.wholeMatch(of: /([0-9]+(?:\.[0-9]+)?)\s*([kKMGTP]?)B/),
              let value = Double(match.1)
        else { return nil }
        let exponent = ["": 0, "k": 1, "K": 1, "M": 2, "G": 3, "T": 4, "P": 5][String(match.2)] ?? 0
        return Int64((value * pow(1000, Double(exponent))).rounded())
    }

    /// "2026-11-19 14:04:55 +0900 JST" (list output) or RFC 3339 (inspect output).
    static func parseDate(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        if let date = RawJSON.parseDate(text) { return date }
        let parts = text.split(separator: " ")
        guard parts.count >= 3 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return formatter.date(from: parts.prefix(3).joined(separator: " "))
    }

    /// Docker's zero time ("0001-01-01T00:00:00Z") means "never".
    static func meaningfulDate(_ text: String?) -> Date? {
        guard let date = parseDate(text), date.timeIntervalSince1970 > 0 else { return nil }
        return date
    }

    /// "os/arch[/variant]" from an inspect element; nil when docker had no content for it.
    static func platform(of image: RawDockerImage) -> String? {
        guard let os = image.Os, !os.isEmpty, let arch = image.Architecture, !arch.isEmpty else { return nil }
        if let variant = image.Variant, !variant.isEmpty { return "\(os)/\(arch)/\(variant)" }
        return "\(os)/\(arch)"
    }
}
