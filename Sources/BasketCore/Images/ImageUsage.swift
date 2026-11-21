import Foundation

/// Which containers and machines use each image. References are compared normalised, so "alpine"
/// and "docker.io/library/alpine:latest" match. Machines count: `container list --all` doesn't show
/// them, so the CLI's own notion of "unused" would offer a machine's base image for deletion.
public struct ImageUsage: Sendable {
    public struct Users: Sendable, Hashable {
        public var containers: [String] = []
        public var machines: [String] = []

        public var isEmpty: Bool { containers.isEmpty && machines.isEmpty }
        /// "web, worker, and machine ubuntu" in the user's language.
        public var description: String {
            let names = containers + machines.map { String(localized: "machine \($0)", bundle: .main, comment: "A Linux machine named in a list of image users") }
            return names.formatted(.list(type: .and))
        }
    }

    private var users: [String: Users] = [:]
    /// Why Basket can't tell which images are unused, or nil when it can (see `unused`).
    public let unknownReason: String?

    /// `machinesKnown` false: the machine list couldn't be read, so any image may be a machine's.
    /// A machine without an image (its `machine inspect` failed or timed out) has the same effect.
    public init(containers: [ContainerSummary], machines: [MachineSummary], machinesKnown: Bool = true) {
        for container in containers where !container.imageReference.isEmpty {
            users[Self.normalized(container.imageReference), default: Users()].containers.append(container.id)
        }
        for machine in machines where !machine.image.isEmpty {
            users[Self.normalized(machine.image), default: Users()].machines.append(machine.id)
        }
        let unknown = machines.filter { $0.image.isEmpty }.map(\.id).sorted()
        if !machinesKnown {
            unknownReason = String(localized: "Basket couldn't list the machines, so it can't tell which images they boot from.", bundle: .main)
        } else if !unknown.isEmpty {
            let names = unknown.map { String(localized: "“\($0)”", bundle: .main, comment: "A name in quotes") }.localizedList
            unknownReason = unknown.count == 1
                ? String(localized: "Basket couldn't read which image machine \(names) boots from (`container machine inspect` failed), so any image may be in use.", bundle: .main)
                : String(localized: "Basket couldn't read which image machines \(names) boot from (`container machine inspect` failed), so any image may be in use.", bundle: .main)
        } else {
            unknownReason = nil
        }
    }

    public func users(of reference: String) -> Users {
        users[Self.normalized(reference)] ?? Users()
    }

    public func isUsed(_ reference: String) -> Bool { !users(of: reference).isEmpty }

    /// `images` no container or machine uses — none at all while `unknownReason` is set: a machine's
    /// base image must never look unused because its inspect failed.
    public func unused(_ images: [ImageSummary]) -> [ImageSummary] {
        guard unknownReason == nil else { return [] }
        return images.filter { !isUsed($0.reference) }
    }

    public static func normalized(_ reference: String) -> String {
        normalizeImageReference(reference.trimmingCharacters(in: .whitespaces))
    }
}
