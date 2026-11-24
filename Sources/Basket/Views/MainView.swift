import SwiftUI
import BasketCore

struct MainView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            SectionHost(section: store.selectedSection)
                .safeAreaInset(edge: .top, spacing: 0) {
                    if let banner = store.banner {
                        BannerView(banner: banner) { store.banner = nil }
                    }
                }
        }
        .frame(minWidth: 1100, minHeight: 700)
        .background(WindowAccessor { window in store.attach(window: window) })
        .sheet(item: $store.activeSheet) { sheet in
            SheetHost(sheet: sheet)
        }
        .alert(
            store.confirmation?.title ?? "",
            isPresented: Binding(get: { store.confirmation != nil }, set: { if !$0 { store.confirmation = nil } }),
            presenting: store.confirmation
        ) { confirmation in
            if let label = confirmation.confirmLabel, confirmation.cancelIsDefault {
                Button("Cancel", role: .cancel) {}
                    .keyboardShortcut(.defaultAction)
                Button(label, role: confirmation.isDestructive ? .destructive : nil) { confirmation.action() }
            } else if let label = confirmation.confirmLabel {
                Button(label, role: confirmation.isDestructive ? .destructive : nil) { confirmation.action() }
                Button("Cancel", role: .cancel) {}
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: { confirmation in
            Text(confirmation.message)
        }
        .transaction { if store.options.isUITest { $0.disablesAnimations = true } }
    }
}

private struct SectionHost: View {
    var section: AppSection

    var body: some View {
        Group {
            switch section {
            case .overview: OverviewView()
            case .containers: ContainersView()
            case .images: ImagesView()
            case .volumes: VolumesView()
            case .networks: NetworksView()
            case .machines: MachinesView()
            case .migration: MigrationView()
            case .settings: SettingsView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(section.title)
        .accessibilityIdentifier("section.\(section.rawValue)")
    }
}

private struct SheetHost: View {
    var sheet: ActiveSheet

    var body: some View {
        switch sheet {
        case .newContainer(let draft): NewContainerSheet(draft: draft)
        case .pullImage(let ref): PullImageSheet(reference: ref)
        case .newVolume: NewVolumeSheet()
        case .newNetwork: NewNetworkSheet()
        case .newMachine: NewMachineSheet()
        case .reclaim: ReclaimSheet()
        case .reclaimMemory: ReclaimMemorySheet()
        case .composePlan(let url): ComposePlanSheet(url: url)
        case .update: UpdateSheet()
        }
    }
}

// MARK: - Sidebar

private struct SidebarView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        List(selection: selection) {
            SidebarItem(section: .overview)
            Section("Resources") {
                SidebarItem(section: .containers)
                SidebarItem(section: .images)
                SidebarItem(section: .volumes)
                SidebarItem(section: .networks)
            }
            Section("Linux") {
                SidebarItem(section: .machines)
            }
            // Only for people who have OrbStack (#47).
            if store.isVisible(.migration) {
                Section("OrbStack") {
                    SidebarItem(section: .migration)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                SidebarSettingsItem(selection: selection)
                SidebarFooter()
            }
        }
    }

    private var selection: Binding<AppSection?> {
        Binding(get: { store.selectedSection }, set: { if let s = $0 { store.selectedSection = s } })
    }
}

private struct SidebarItem: View {
    @Environment(AppStore.self) private var store
    var section: AppSection

    var body: some View {
        Label(section.title, systemImage: section.systemImage)
            .badge(badgeCount)
            .tag(section)
            .accessibilityIdentifier("sidebar.\(section.rawValue)")
    }

    private var badgeCount: Int {
        switch section {
        case .containers: store.runningContainers.count
        case .machines: store.machines.filter { $0.state == .running }.count
        default: 0
        }
    }
}

/// Settings, pinned under the sections and above the footer: a one-row sidebar list sharing the
/// selection, so it looks, highlights and reads (VoiceOver) like the rows above.
private struct SidebarSettingsItem: View {
    var selection: Binding<AppSection?>
    @Environment(\.sidebarRowSize) private var rowSize

    var body: some View {
        List(selection: selection) {
            SidebarItem(section: .settings)
        }
        .listStyle(.sidebar)
        .scrollDisabled(true)
        .scrollContentBackground(.hidden)
        .frame(height: height)
    }

    /// The row (24, 32 or 40 pt for the sidebar icon size in System Settings ▸ Appearance,
    /// measured on macOS 26) and 12 pt above the footer. The list adds no top inset here.
    private var height: CGFloat {
        switch rowSize {
        case .small: 36
        case .large: 52
        default: 44
        }
    }
}

/// Always-visible resource summary: the product's point is memory and disk.
private struct SidebarFooter: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: statusSymbol).foregroundStyle(statusColor)
                Text(statusText).font(.callout.weight(.medium))
            }
            footerLine("memorychip", "Memory", store.footprintsAvailable ? Format.memory(store.totalHostMemory) : "—")
            footerLine("internaldrive", "Disk", store.diskUsage.map { Format.disk($0.totalBytes) } ?? "—")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sidebar.status")
    }

    private func footerLine(_ symbol: String, _ label: LocalizedStringKey, _ value: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 16)
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value).monospacedDigit()
        }
        .font(.callout)
    }

    private var statusText: String {
        switch store.availability {
        case .running: String(localized: "System running", comment: "Sidebar footer: the container system is running")
        case .stopped: String(localized: "System stopped", comment: "Sidebar footer: the container system is stopped")
        case .cliMissing: String(localized: "CLI not found", comment: "Sidebar footer: the container CLI is missing")
        case .unknown: String(localized: "Connecting…")
        }
    }

    private var statusSymbol: String {
        switch store.availability {
        case .running: "checkmark.circle.fill"
        case .stopped: "pause.circle.fill"
        case .cliMissing: "exclamationmark.triangle.fill"
        case .unknown: "circle.dotted"
        }
    }

    private var statusColor: Color {
        switch store.availability {
        case .running: .green
        case .stopped: .secondary
        case .cliMissing: .orange
        case .unknown: .secondary
        }
    }
}

// MARK: - Banner

private struct BannerView: View {
    var banner: BannerMessage
    var dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(banner.title).font(.callout.weight(.semibold))
                Text(banner.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            Button("Dismiss", systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .frame(minWidth: 22, minHeight: 22)
                .help("Dismiss")
                .accessibilityIdentifier("basket.banner.dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.orange.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("basket.banner")
    }
}

// MARK: - Shared section pieces

/// Chooses between the service-unavailable state, the empty state and the list.
struct ListSectionBody<Content: View, Empty: View>: View {
    @Environment(AppStore.self) private var store
    var section: AppSection
    var isEmpty: Bool
    @ViewBuilder var content: Content
    @ViewBuilder var empty: Empty

    var body: some View {
        VStack(spacing: 0) {
            sectionContent
            SectionStatusBar(section: section)
        }
    }

    @ViewBuilder private var sectionContent: some View {
        if ServiceUnavailableView.isShown(for: store.availability) {
            ServiceUnavailableView(section: section)
        } else if isEmpty && store.isLoaded(section) {
            let query = store.search(section).trimmingCharacters(in: .whitespaces)
            if query.isEmpty {
                empty
            } else {
                SectionEmptyState(section: section, title: "No Results for “\(query)”", systemImage: "magnifyingglass",
                                  message: "Check the spelling or try a different search.") {
                    Button("Clear Search") { store.searchText[section] = "" }
                        .accessibilityIdentifier("\(section.rawValue).action.clear-search")
                }
            }
        } else {
            content
        }
    }
}

/// Finder-style status bar: what the list costs in memory or disk.
struct SectionStatusBar: View {
    @Environment(AppStore.self) private var store
    var section: AppSection

    var body: some View {
        HStack(spacing: 6) {
            Text(store.statusLine(for: section))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(height: 28)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("\(section.rawValue).status")
    }
}

struct RefreshButton: View {
    @Environment(AppStore.self) private var store
    var section: AppSection

    var body: some View {
        Button {
            Task { await store.refreshAll() }
        } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
        }
        .help("Refresh (⌘R)")
        .disabled(store.isRefreshing)
        .accessibilityIdentifier("\(section.rawValue).action.refresh")
    }
}

struct SectionSearchField: View {
    @Environment(AppStore.self) private var store
    var section: AppSection

    var body: some View {
        ToolbarSearchField(
            text: Binding(get: { store.search(section) }, set: { store.searchText[section] = $0 }),
            prompt: section.searchPrompt,
            identifier: "\(section.rawValue).search"
        ) { store.searchField = $0 }
        .frame(width: 200)
        .accessibilityIdentifier("\(section.rawValue).search")
    }
}

/// The search field, set apart from the section's action group.
struct CommonToolbarItems: ToolbarContent {
    var section: AppSection

    var body: some ToolbarContent {
        ToolbarSpacer(.fixed)
        ToolbarItem {
            SectionSearchField(section: section)
        }
    }
}

/// Toolbar button with an icon, an accessible name, a tooltip and an AX identifier.
struct ToolbarActionButton: View {
    var title: LocalizedStringKey
    var systemImage: String
    var identifier: String
    var help: LocalizedStringKey?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }
        .help(help ?? title)
        .accessibilityIdentifier(identifier)
    }
}
