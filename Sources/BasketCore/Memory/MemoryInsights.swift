import Foundation

/// Where each running container's host memory goes, and how much of it a restart would return.
///
/// apple/container VMs have no memory balloon: the host footprint of a VM follows the guest's
/// high-water mark and never shrinks until the VM restarts. Measured on container 1.7.1 / macOS 26
/// (phys_footprint of the `com.apple.Virtualization.VirtualMachine` process):
///
/// | limit | guest in use | host footprint |
/// |-------|--------------|----------------|
/// | 256M  | ~2 MB        | 240 MB         |
/// | 1G    | ~2 MB        | 287 MB         |
/// | 2G    | ~2 MB        | 312 MB         |
/// | 1G    | 55 MB (after allocating and freeing 500 MB) | 778 MB |
///
/// The model splits the footprint into three parts that always add up to it:
///
///     host footprint = guest in use + VM overhead + stranded
///     VM overhead(limit) ≈ 238 MiB + 25 MiB × log2(max(limit, 256 MiB) / 256 MiB)
///     stranded           = max(0, host footprint − estimated overhead − guest in use)
///
/// The overhead curve fits the three idle measurements within ±3 MB (238 / 288 / 313 MiB). A VM is
/// flagged *stranded* only when stranded ≥ 128 MiB **and** ≥ 10 % of its footprint: a freshly
/// started idle VM lands within a few MB of the curve, and guest usage moves between the stats and
/// footprint samples, so small remainders are noise. The 778 MB / 55 MB case gives
/// 778 − 288 − 55 ≈ 435 MB (56 %) and is flagged.
public struct MemoryInsights: Sendable, Hashable {
    /// The overhead curve and the stranded threshold.
    public struct Model: Sendable, Hashable {
        public var overheadBaseBytes: Int64
        public var overheadPerDoublingBytes: Int64
        /// Limit at which the overhead equals `overheadBaseBytes` (smaller limits cost the same).
        public var referenceLimitBytes: Int64
        public var strandedMinimumBytes: Int64
        /// Stranded memory must also be at least this fraction of the host footprint.
        public var strandedMinimumFraction: Double

        public init(
            overheadBaseBytes: Int64 = 238 * mebibyte, overheadPerDoublingBytes: Int64 = 25 * mebibyte,
            referenceLimitBytes: Int64 = 256 * mebibyte, strandedMinimumBytes: Int64 = 128 * mebibyte,
            strandedMinimumFraction: Double = 0.10
        ) {
            self.overheadBaseBytes = overheadBaseBytes
            self.overheadPerDoublingBytes = overheadPerDoublingBytes
            self.referenceLimitBytes = referenceLimitBytes
            self.strandedMinimumBytes = strandedMinimumBytes
            self.strandedMinimumFraction = strandedMinimumFraction
        }

        /// Fitted to apple/container 1.7.1 on macOS 26 (see `MemoryInsights`).
        public static let measured = Model()

        /// What an idle VM with this memory limit costs the host. Unknown limits (0) use the base cost.
        public func overheadBytes(forLimit limit: Int64) -> Int64 {
            let doublings = log2(Double(max(limit, referenceLimitBytes)) / Double(referenceLimitBytes))
            return overheadBaseBytes + Int64((Double(overheadPerDoublingBytes) * doublings).rounded())
        }

        public func isStranded(_ strandedBytes: Int64, hostFootprintBytes: Int64) -> Bool {
            strandedBytes >= strandedMinimumBytes
                && Double(strandedBytes) >= strandedMinimumFraction * Double(hostFootprintBytes)
        }
    }

    /// One running container whose VM footprint and guest usage are both known.
    public struct Breakdown: Identifiable, Sendable, Hashable {
        public var id: String
        public var hostFootprintBytes: Int64
        public var guestInUseBytes: Int64
        public var memoryLimitBytes: Int64
        /// Estimated VM cost, capped so the three parts never exceed the footprint.
        public var overheadBytes: Int64
        /// Memory the VM holds beyond overhead and guest usage; a restart returns it.
        public var strandedBytes: Int64
        /// `strandedBytes` is above the noise threshold; worth a restart.
        public var isStranded: Bool

        public init(
            id: String, hostFootprintBytes: Int64, guestInUseBytes: Int64, memoryLimitBytes: Int64,
            overheadBytes: Int64, strandedBytes: Int64, isStranded: Bool
        ) {
            self.id = id
            self.hostFootprintBytes = hostFootprintBytes
            self.guestInUseBytes = guestInUseBytes
            self.memoryLimitBytes = memoryLimitBytes
            self.overheadBytes = overheadBytes
            self.strandedBytes = strandedBytes
            self.isStranded = isStranded
        }
    }

    public struct Totals: Sendable, Hashable {
        public var hostFootprintBytes: Int64 = 0
        public var guestInUseBytes: Int64 = 0
        public var overheadBytes: Int64 = 0
        /// Sum over flagged containers only: what reclaiming everything would return.
        public var strandedBytes: Int64 = 0
        public var strandedCount = 0

        public init() {}
    }

    public static let mebibyte: Int64 = 1_048_576

    /// Sorted by stranded bytes, largest first, then by id.
    public private(set) var containers: [Breakdown]
    public private(set) var totals: Totals

    public var stranded: [Breakdown] { containers.filter(\.isStranded) }

    public subscript(id: String) -> Breakdown? { containers.first { $0.id == id } }

    /// Running containers with both a footprint (attributed to their id) and a stats sample.
    /// Machines, unattributed VMs and stopped containers are left out.
    public init(
        containers: [ContainerSummary], stats: [String: ContainerStats], footprints: [HostMemoryFootprint],
        model: Model = .measured
    ) {
        var host: [String: Int64] = [:]
        for footprint in footprints {
            guard let owner = footprint.ownerID else { continue }
            host[owner, default: 0] += footprint.footprintBytes
        }
        var list: [Breakdown] = []
        var totals = Totals()
        for container in containers where container.state == .running {
            guard let footprint = host[container.id], footprint > 0, let sample = stats[container.id] else { continue }
            let limit = container.memoryLimitBytes > 0 ? container.memoryLimitBytes : sample.memoryLimitBytes
            // Stats and footprints are sampled at different moments; never let the parts exceed the whole.
            let guest = min(max(0, sample.memoryUsageBytes), footprint)
            let overhead = min(model.overheadBytes(forLimit: limit), footprint - guest)
            let stranded = footprint - guest - overhead
            let flagged = model.isStranded(stranded, hostFootprintBytes: footprint)
            list.append(Breakdown(
                id: container.id, hostFootprintBytes: footprint, guestInUseBytes: guest, memoryLimitBytes: limit,
                overheadBytes: overhead, strandedBytes: stranded, isStranded: flagged))
            totals.hostFootprintBytes += footprint
            totals.guestInUseBytes += guest
            totals.overheadBytes += overhead
            if flagged {
                totals.strandedBytes += stranded
                totals.strandedCount += 1
            }
        }
        self.containers = list.sorted { ($0.strandedBytes, $1.id) > ($1.strandedBytes, $0.id) }
        self.totals = totals
    }
}
