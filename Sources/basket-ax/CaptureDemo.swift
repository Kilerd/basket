import AppKit
import SwiftUI
import BasketAXKit

/// Hidden `capture-demo` subcommand: opens a tiny SwiftUI window in this process, snapshots its
/// NSAccessibility tree with `InProcessAXCapture` and prints the JSON. It proves that SwiftUI's
/// `.accessibilityIdentifier`, labels and frames (toolbar included) are visible in-process.
/// `--audit` also prints the lint findings for the demo window to stderr.
enum CaptureDemo {
    @MainActor
    static func run(_ args: [String]) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()

        let controller = NSHostingController(rootView: DemoView())
        controller.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = "AX capture demo"
        window.setContentSize(NSSize(width: 760, height: 460))
        window.setAccessibilityIdentifier("demo.main")
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate()

        pumpEvents(seconds: 1.0)
        // The first walk wakes SwiftUI's lazily built accessibility tree; settle, then capture.
        _ = InProcessAXCapture.snapshot(of: window)
        pumpEvents(seconds: 0.5)
        let node = InProcessAXCapture.snapshot(of: window)
        window.orderOut(nil)

        guard let data = try? node.jsonData() else { return 2 }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))

        if args.contains("--audit") {
            let findings = AXAuditor.audit(window: node, section: nil)
            var lines = ["\(node.nodeCount) nodes, \(findings.count) findings:"]
            lines += findings.map { "  [\($0.severity.rawValue)] \($0.rule): \($0.message) — \($0.path)" }
            FileHandle.standardError.write(Data((lines.joined(separator: "\n") + "\n").utf8))
        }
        return 0
    }

    @MainActor
    static func pumpEvents(seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.05),
                                           inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
        }
    }
}

private struct DemoView: View {
    @State private var selection: String? = "containers"
    @State private var query = ""
    @State private var autoStart = true
    private let sections = ["overview", "containers", "images"]
    private let rows = ["web", "db", "cache"]

    var body: some View {
        NavigationSplitView {
            List(sections, id: \.self, selection: $selection) { section in
                Label(section.capitalized, systemImage: "shippingbox")
                    .accessibilityIdentifier("sidebar.\(section)")
            }
            .navigationSplitViewColumnWidth(180)
        } detail: {
            VStack(alignment: .leading, spacing: 12) {
                Text("Containers").font(.title2).accessibilityAddTraits(.isHeader)
                TextField("Search", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("containers.search")
                HStack {
                    Button("Refresh") {}.accessibilityIdentifier("containers.action.refresh")
                    Button("New Container") {}.accessibilityIdentifier("containers.action.new")
                    Toggle("Auto-start", isOn: $autoStart).accessibilityIdentifier("demo.toggle")
                    // Deliberate defects so the audit output shows the rules firing.
                    Button { } label: { Circle().fill(.red).frame(width: 12, height: 12) }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("demo.defect.unlabeled")
                    Button("x") {}.buttonStyle(.borderless).controlSize(.mini)
                        .accessibilityIdentifier("demo.defect.tiny")
                }
                // A label on a GridRow is copied onto every cell: three unknown-role elements.
                Grid {
                    GridRow {
                        Text("Host (real)")
                        ProgressView(value: 0.5).frame(width: 100)
                        Text("2.4 GB")
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Host (real)")
                }
                Text("A very long status line that cannot possibly fit into its narrow frame")
                    .lineLimit(1)
                    .frame(width: 120, alignment: .leading)
                    .accessibilityIdentifier("demo.defect.truncated")
                List(rows, id: \.self) { row in
                    HStack {
                        Text(row)
                        Spacer()
                        Text("running").foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("containers.row.\(row)")
                }
                .accessibilityIdentifier("containers.list")
            }
            .padding()
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("section.containers")
            .toolbar {
                ToolbarItem {
                    Button { } label: { Label("Pull", systemImage: "arrow.down.circle") }
                        .accessibilityIdentifier("images.action.pull")
                }
            }
        }
    }
}
