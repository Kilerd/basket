import Foundation

/// Service discovery for compose projects. apple/container 1.7 resolves no container names (not even
/// on a shared network), so Basket writes the project's names into each container's `/etc/hosts`,
/// inside a marked block that is replaced on every start.
public enum ComposeHosts {
    public static let beginMarker = "# basket-compose begin (managed by Basket, rewritten on start)"
    public static let endMarker = "# basket-compose end"

    /// POSIX `sh` (busybox, dash, bash) using builtins only: drops the old block, appends `$1`.
    /// `$2` is the file (`/etc/hosts`). Written in place, because /etc/hosts may be a mount point.
    public static let script = """
        f="$2"; out=""; skip=0
        while IFS= read -r line || [ -n "$line" ]; do
          case "$line" in
            '# basket-compose begin'*) skip=1 ;;
            '# basket-compose end'*) skip=0 ;;
            *) if [ "$skip" = 0 ]; then out="$out$line
        "; fi ;;
          esac
        done < "$f"
        printf '%s%s' "$out" "$1" > "$f"
        """

    public struct Entry: Sendable, Hashable {
        public var address: String
        public var names: [String]
    }

    /// Entries for `target`: every running project container that shares a network with it
    /// (itself included), plus its `extra_hosts`.
    public static func entries(for target: ContainerSummary, in project: [ContainerSummary]) -> [Entry] {
        var result: [Entry] = []
        for other in project.sorted(by: { ComposeProject.serviceName(of: $0) < ComposeProject.serviceName(of: $1) }) {
            guard other.state == .running, let address = address(of: other, seenFrom: target) else { continue }
            result.append(Entry(address: address, names: names(of: other)))
        }
        for pair in (target.labels[ComposeLabels.extraHosts] ?? "").split(separator: ",") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty {
                result.append(Entry(address: parts[1], names: [parts[0]]))
            }
        }
        return result
    }

    /// `other`'s address on the first network it shares with `target` (its own primary address for
    /// itself); nil when they share none or it has no address.
    static func address(of other: ContainerSummary, seenFrom target: ContainerSummary) -> String? {
        if other.id == target.id { return other.ipv4Address.flatMap { $0.isEmpty ? nil : $0 } }
        for network in target.networks where other.networks.contains(network) {
            if let address = other.networkAddresses[network] ?? (other.networks.first == network ? other.ipv4Address : nil),
               !address.isEmpty {
                return address
            }
        }
        return nil
    }

    /// Service name, container name, then the aliases Basket recorded at `up`.
    public static func names(of container: ContainerSummary) -> [String] {
        let aliases = (container.labels[ComposeLabels.aliases] ?? "").split(separator: ",").map(String.init)
        return ([ComposeProject.serviceName(of: container), container.id] + aliases)
            .reduce(into: [String]()) { if !$1.isEmpty && !$0.contains($1) { $0.append($1) } }
    }

    public static func block(_ entries: [Entry]) -> String {
        ([beginMarker] + entries.map { "\($0.address)\t\($0.names.joined(separator: " "))" } + [endMarker])
            .joined(separator: "\n") + "\n"
    }

    /// The `exec` arguments that install `block` into `/etc/hosts`.
    public static func command(block: String, file: String = "/etc/hosts") -> [String] {
        ["sh", "-c", script, "basket-hosts", block, file]
    }
}
