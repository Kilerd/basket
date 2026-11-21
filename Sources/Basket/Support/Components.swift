import SwiftUI
import AppKit
import BasketCore

// MARK: - Palette

extension Color {
    init(light: NSColor, dark: NSColor) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// Categorical series colours (validated light/dark steps; see the dataviz palette).
enum Series {
    static let blue = Color(light: NSColor(hex: 0x2A78D6), dark: NSColor(hex: 0x3987E5))
    static let orange = Color(light: NSColor(hex: 0xEB6834), dark: NSColor(hex: 0xD95926))
    static let aqua = Color(light: NSColor(hex: 0x1BAF7A), dark: NSColor(hex: 0x199E70))
    /// Neutral track behind meters.
    static let track = Color.primary.opacity(0.08)
}

extension ContainerState {
    var color: Color {
        switch self {
        case .running: .green
        case .stopping: .orange
        case .created: .blue
        case .stopped, .unknown: .secondary
        }
    }

    var symbol: String {
        switch self {
        case .running: "play.circle.fill"
        case .stopping: "hourglass.circle.fill"
        case .created: "circle.dashed"
        case .stopped: "stop.circle"
        case .unknown: "questionmark.circle"
        }
    }
}

// MARK: - Badges & meters

/// Status shown as icon + label (never colour alone).
struct StateBadge: View {
    var state: ContainerState
    /// A running operation's progress phrase ("Stopping…", see `PendingOperation`), shown instead
    /// of the state.
    var pendingVerb: String?

    var body: some View {
        HStack(spacing: 5) {
            if let pendingVerb {
                ProgressView().controlSize(.mini)
                Text(verbatim: pendingVerb).foregroundStyle(.secondary)
            } else {
                Image(systemName: state.symbol).foregroundStyle(state.color).accessibilityHidden(true)
                Text(state.title)
            }
        }
    }
}

/// A thin horizontal meter with rounded ends.
struct MeterBar: View {
    var fraction: Double
    var color: Color = Series.blue
    var height: CGFloat = 6
    /// Set to expose the bar to VoiceOver as a progress indicator ("Memory usage, 15%");
    /// nil keeps it decorative (a neighbouring label already says the same).
    var accessibilityLabel: LocalizedStringKey?

    var body: some View {
        let clamped = min(1, max(0, fraction))
        let bar = GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Series.track)
                Capsule().fill(color)
                    .frame(width: max(fraction > 0 ? height : 0, proxy.size.width * clamped))
            }
        }
        .frame(height: height)
        if let accessibilityLabel {
            bar.accessibilityRepresentation { ProgressView(accessibilityLabel, value: clamped) }
        } else {
            bar.accessibilityHidden(true)
        }
    }
}

/// "used / limit ▬▬" memory cell. Same geometry in every row so a column lines up: `used`
/// right-aligned in the flexible part, "/ limit" in a fixed-width slot, then a fixed-width bar
/// (an empty track when nothing is known).
struct MemoryUsageCell: View {
    var used: Int64
    var limit: Int64

    static let limitWidth: CGFloat = 64
    static let barWidth: CGFloat = 44
    /// Narrowest the column can be without truncating "1023.9 MB / 512 MB".
    static let minimumWidth: CGFloat = 64 + 6 + limitWidth + 6 + barWidth

    var body: some View {
        HStack(spacing: 6) {
            Text(used < 0 ? "—" : Format.memory(used))
                .foregroundStyle(used < 0 ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text(verbatim: limit > 0 ? "/ \(Format.memory(limit))" : "")
                .foregroundStyle(.secondary)
                .frame(width: Self.limitWidth, alignment: .leading)
            MeterBar(
                fraction: used >= 0 && limit > 0 ? Double(used) / Double(limit) : 0, color: Series.blue, height: 5,
                accessibilityLabel: used >= 0 && limit > 0 ? "Memory usage" : nil)
                .frame(width: Self.barWidth)
        }
        .monospacedDigit()
        .lineLimit(1)
    }
}

/// Right-aligned number for table columns (pair with `.alignment(.numeric)` on the column). An
/// optional status mark sits in a fixed slot just left of a fixed-width number area, so numbers
/// and marks line up down the column whether or not a row has a mark.
struct NumericCell<Mark: View>: View {
    var text: String
    var isPlaceholder = false
    /// Width of the number area when a mark slot is used; wider values push the mark left.
    var valueWidth: CGFloat = 0
    var markWidth: CGFloat = 0
    @ViewBuilder var mark: Mark

    var body: some View {
        HStack(spacing: 4) {
            Spacer(minLength: 0)
            if markWidth > 0 {
                mark.frame(width: markWidth, alignment: .trailing)
            }
            Text(text)
                .monospacedDigit()
                .lineLimit(1)
                .foregroundStyle(isPlaceholder ? .secondary : .primary)
                .frame(minWidth: valueWidth, alignment: .trailing)
        }
    }
}

extension NumericCell where Mark == EmptyView {
    init(_ text: String, isPlaceholder: Bool = false) {
        self.init(text: text, isPlaceholder: isPlaceholder) { EmptyView() }
    }
}

struct Pill: View {
    var text: LocalizedStringKey
    var systemImage: String?
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 3) {
            // The text says it all; the icon would only add a symbol-named AX image.
            if let systemImage { Image(systemName: systemImage).accessibilityHidden(true) }
            Text(text)
        }
        .font(.caption)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundStyle(tint)
        .background(tint.opacity(0.12), in: Capsule())
        .fixedSize()
    }
}

// MARK: - Cards (Overview)

struct Card<Content: View, Accessory: View>: View {
    var title: LocalizedStringKey
    var systemImage: String
    var identifier: String
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    init(_ title: LocalizedStringKey, systemImage: String, identifier: String,
         @ViewBuilder accessory: () -> Accessory = { EmptyView() }, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.identifier = identifier
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Label(title, systemImage: systemImage)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                accessory
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
    }
}

/// Big number + caption (a stat tile).
struct HeroNumber: View {
    var value: String
    var caption: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(caption)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Empty / unavailable states

struct SectionEmptyState<Actions: View>: View {
    var section: AppSection
    var title: LocalizedStringKey
    var systemImage: String
    var message: LocalizedStringKey
    @ViewBuilder var actions: Actions

    init(section: AppSection, title: LocalizedStringKey, systemImage: String, message: LocalizedStringKey,
         @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.section = section
        self.title = title
        self.systemImage = systemImage
        self.message = message
        self.actions = actions()
    }

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        } actions: {
            actions
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("\(section.rawValue).empty")
    }
}

/// Replaces a list when the service is down or the CLI is missing; nil when the list can show.
struct ServiceUnavailableView: View {
    @Environment(AppStore.self) private var store
    var section: AppSection

    var body: some View {
        switch store.availability {
        case .stopped:
            SectionEmptyState(
                section: section, title: "Container System Stopped", systemImage: "power.circle",
                message: Self.stoppedMessage(section)
            ) {
                Button("Start Container System") { Task { await store.startSystem() } }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("\(section.rawValue).action.start-system")
            }
        case .cliMissing(let message):
            SectionEmptyState(section: section, title: "container CLI Not Found", systemImage: "exclamationmark.triangle",
                              message: "\(message)") {
                SettingsLink { Text("Open Settings…") }
                    .accessibilityIdentifier("\(section.rawValue).action.settings")
            }
        default:
            EmptyView()
        }
    }

    /// One full sentence per section: languages inflect the noun differently.
    private static func stoppedMessage(_ section: AppSection) -> LocalizedStringKey {
        switch section {
        case .overview, .containers:
            "Start the container system to see your containers. It uses no memory until containers run."
        case .images: "Start the container system to see your images. It uses no memory until containers run."
        case .volumes: "Start the container system to see your volumes. It uses no memory until containers run."
        case .networks: "Start the container system to see your networks. It uses no memory until containers run."
        case .machines: "Start the container system to see your machines. It uses no memory until containers run."
        case .migration: "Start the container system to compare OrbStack with Basket. It uses no memory until containers run."
        }
    }

    static func isShown(for availability: Availability) -> Bool {
        switch availability {
        case .stopped, .cliMissing: true
        default: false
        }
    }
}

// MARK: - Info sections

/// A titled block of label/value rows, laid out side by side in detail panes.
struct InfoSection<Content: View>: View {
    var title: LocalizedStringKey
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                content
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

struct InfoRow: View {
    var label: Text
    var value: String
    var monospaced = false
    /// UI labels are short and never truncated; data labels (long label keys) may be.
    private var labelIsUIText = true

    /// A row whose label is UI text ("Image", "Created").
    init(label: LocalizedStringKey, value: String, monospaced: Bool = false) {
        self.label = Text(label)
        self.value = value
        self.monospaced = monospaced
    }

    /// A row whose label is data (an environment variable, a mount path, a service name).
    init(verbatimLabel: String, value: String, monospaced: Bool = false) {
        self.label = Text(verbatim: verbatimLabel)
        self.value = value
        self.monospaced = monospaced
        self.labelIsUIText = false
    }

    /// Width of an `InfoSection` whose rows have these labels and values up to `valueWidth`:
    /// `minimum` (sized for English) or more when the translated labels are longer.
    static func sectionWidth(labels: [String.LocalizationValue], valueWidth: CGFloat, minimum: CGFloat) -> CGFloat {
        let font = NSFont.preferredFont(forTextStyle: .callout)
        let widest = labels.map { (String(localized: $0) as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        // Section padding (12 + 12) and the grid's column spacing (12).
        return max(minimum, (widest + 12 + valueWidth + 24).rounded(.up))
    }

    var body: some View {
        GridRow {
            label
                .foregroundStyle(.secondary)
                .lineLimit(1)
                // A UI label keeps its full width (German and French run long); the value
                // takes what is left.
                .fixedSize(horizontal: labelIsUIText, vertical: false)
                .gridColumnAlignment(.leading)
            Text(value.isEmpty ? "—" : value)
                .font(monospaced ? .callout.monospaced() : .callout)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(value)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
    }
}

// MARK: - Resizable master/detail split

/// Table on top, detail pane below, with a draggable divider. Pure SwiftUI: `VSplitView` hosts
/// each pane separately, which mis-applies the toolbar safe area and AX frames.
struct DetailSplit<Top: View, Bottom: View>: View {
    var showsBottom: Bool
    @ViewBuilder var top: Top
    @ViewBuilder var bottom: Bottom
    @State private var bottomHeight: CGFloat = 330
    @State private var dragOrigin: CGFloat?

    private let minTop: CGFloat = 140
    private let minBottom: CGFloat = 220

    var body: some View {
        GeometryReader { proxy in
            let height = clamped(bottomHeight, total: proxy.size.height)
            VStack(spacing: 0) {
                top.frame(maxWidth: .infinity, maxHeight: .infinity)
                if showsBottom {
                    Divider()
                        .overlay {
                            Color.clear
                                .frame(height: 9)
                                .contentShape(Rectangle())
                                .pointerStyle(.rowResize)
                                .gesture(
                                    DragGesture(minimumDistance: 1, coordinateSpace: .global)
                                        .onChanged { value in
                                            let origin = dragOrigin ?? height
                                            dragOrigin = origin
                                            bottomHeight = clamped(origin - value.translation.height, total: proxy.size.height)
                                        }
                                        .onEnded { _ in dragOrigin = nil }
                                )
                                .accessibilityHidden(true)
                        }
                    bottom
                        .frame(maxWidth: .infinity)
                        .frame(height: height)
                }
            }
        }
    }

    private func clamped(_ value: CGFloat, total: CGFloat) -> CGFloat {
        min(max(value, minBottom), max(minBottom, total - minTop))
    }
}
