import Darwin
import Foundation

/// Measures what the host pays for each container VM.
///
/// Every apple/container VM runs in its own `com.apple.Virtualization.VirtualMachine` XPC process whose
/// parent is launchd, so the process tree doesn't link it to its container. macOS *responsibility*
/// does: the VM's responsible process is the `container-runtime-linux start --root <bundle> --uuid <id>`
/// that launched it. Machines run as containers named `<machine>-<6 hex>` labelled
/// `com.apple.container.plugin=machine`; those are attributed to the machine id.
enum HostMemorySampler {
    static let vmExecutableName = "com.apple.Virtualization.VirtualMachine"

    struct VMProcess: Sendable, Hashable {
        var pid: pid_t
        var footprintBytes: Int64
        var responsiblePID: pid_t?
        var responsiblePath: String?
    }

    static func virtualMachineProcesses() -> [VMProcess] {
        // Polled every couple of seconds across ~1000 processes: filter on the short name first
        // (~6× cheaper than resolving every executable path).
        var nameBuffer = [CChar](repeating: 0, count: 64)
        let prefix = String(vmExecutableName.prefix(24))
        return ProcessInspector.allPIDs().compactMap { pid in
            guard ProcessInspector.shortName(of: pid, buffer: &nameBuffer)?.hasPrefix(prefix) == true,
                  let path = ProcessInspector.executablePath(of: pid),
                  (path as NSString).lastPathComponent == vmExecutableName,
                  let footprint = ProcessInspector.physFootprint(of: pid)
            else { return nil }
            let responsible = ProcessInspector.responsiblePID(for: pid).flatMap { $0 == pid ? nil : $0 }
            return VMProcess(
                pid: pid, footprintBytes: footprint, responsiblePID: responsible,
                responsiblePath: responsible.flatMap(ProcessInspector.executablePath(of:)))
        }
    }

    /// VMs launched by apple/container (plus VMs whose launcher can't be determined, with `ownerID: nil`).
    /// VMs that clearly belong to another app (UTM, Tart, …) are left out.
    static func containerVMFootprints() -> [HostMemoryFootprint] {
        virtualMachineProcesses().compactMap { vm in
            guard let responsible = vm.responsiblePID, let launcherPath = vm.responsiblePath else {
                return HostMemoryFootprint(ownerID: nil, pid: vm.pid, footprintBytes: vm.footprintBytes)
            }
            guard isContainerRuntime(launcherPath) else { return nil }
            let owner = ProcessInspector.arguments(of: responsible).flatMap(ownerID(fromRuntimeArguments:))
            return HostMemoryFootprint(ownerID: owner, pid: vm.pid, footprintBytes: vm.footprintBytes)
        }
        .sorted { $0.pid < $1.pid }
    }

    static func isContainerRuntime(_ path: String) -> Bool {
        (path as NSString).lastPathComponent.hasPrefix("container-runtime-")
    }

    /// `container-runtime-linux start --root <bundle> --uuid <id>` → container id, or machine id for
    /// machine-backed containers.
    static func ownerID(fromRuntimeArguments arguments: [String]) -> String? {
        let root = value(after: "--root", in: arguments)
        guard let runtimeID = value(after: "--uuid", in: arguments)
            ?? root.map({ ($0 as NSString).lastPathComponent })
        else { return nil }
        guard let root, let machineID = machineID(forBundle: URL(fileURLWithPath: root), runtimeID: runtimeID) else {
            return runtimeID
        }
        return machineID
    }

    /// Reads the bundle's `config.json`; returns the machine id when the container backs a machine.
    static func machineID(forBundle bundle: URL, runtimeID: String) -> String? {
        struct BundleConfig: Decodable {
            var labels: [String: String]?
        }
        guard let data = try? Data(contentsOf: bundle.appendingPathComponent("config.json")),
              let config = try? JSONDecoder().decode(BundleConfig.self, from: data),
              config.labels?[ResourceLabels.plugin] == "machine"
        else { return nil }
        return machineID(fromContainerID: runtimeID)
    }

    /// "dev-box-32cb51" → "dev-box" (apple/container names machine containers `<id>-<6 lowercase hex>`).
    static func machineID(fromContainerID containerID: String) -> String {
        guard let range = containerID.range(of: #"-[0-9a-f]{6}$"#, options: .regularExpression) else {
            return containerID
        }
        return String(containerID[..<range.lowerBound])
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}

/// Bytes a file actually occupies on disk (`st_blocks * 512`), which for sparse images is far less
/// than the logical size.
func allocatedBytes(atPath path: String) -> Int64? {
    var info = stat()
    guard !path.isEmpty, stat(path, &info) == 0 else { return nil }
    return Int64(info.st_blocks) * 512
}
