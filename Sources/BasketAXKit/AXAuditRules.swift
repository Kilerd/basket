import Foundation

/// Thresholds, role sets and the identifier contract used by `AXAuditor`.
public enum AXAuditRules {
    // MARK: Rule ids
    public static let missingLabel = "missing-label"
    public static let outOfWindow = "out-of-window"
    public static let overlap = "overlap"
    public static let tinyTarget = "tiny-target"
    public static let inconsistentHeight = "inconsistent-height"
    public static let duplicateIdentifier = "duplicate-identifier"
    public static let truncation = "truncation"
    public static let contract = "contract"
    public static let unknownRole = "unknown-role"
    public static let repeatedLabel = "repeated-label"
    public static let consistencyActions = "consistency-actions"
    public static let consistencySearch = "consistency-search"
    public static let consistencySidebar = "consistency-sidebar"
    public static let consistencyTitle = "consistency-title"
    public static let consistencyWindow = "consistency-window"

    // MARK: Thresholds (points)
    /// Edges may stick out of the window by this much (rounding) before it counts.
    public static let outOfWindowTolerance = 1.0
    /// Sibling interactive elements may share at most this much area.
    public static let overlapMinArea = 4.0
    /// Minimum hit target for buttons, links, pop-ups, sliders…
    public static let minTargetSize = 20.0
    /// Text inputs are wide; their height only has to reach the macOS small control size.
    public static let textInputMinHeight = 18.0
    /// Check boxes / radio buttons / switches: the frame covers box + title; the box itself is a
    /// standard 14–16 pt system glyph, so only anything smaller than that is flagged.
    public static let toggleMinSize = 14.0
    /// Buttons in one row may differ in height by at most this much.
    public static let heightTolerance = 2.0
    /// Measured text may exceed its frame by this much before it counts as truncated.
    public static let truncationTolerance = 2.0
    /// Shorter texts ("—", "4") aren't checked: they can't meaningfully truncate, and single
    /// glyphs measure differently across fonts (an em dash is 1 em in SF Pro, 0.6 em in SF Mono).
    /// Chinese and Japanese words are one or two characters ("容器"), so text with ideographs or
    /// kana is checked from two characters on.
    public static let truncationMinLength = 3
    public static let truncationMinLengthWide = 2

    /// Whether `text` holds CJK ideographs, kana or full-width forms.
    public static func hasWideCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x2E80...0x9FFF).contains($0.value) || (0xF900...0xFAFF).contains($0.value)
            || (0xFF00...0xFFEF).contains($0.value) || (0x20000...0x3FFFF).contains($0.value) }
    }
    /// Ellipsis-terminated text only counts as truncated when it fills its frame to within this.
    public static let ellipsisFillSlack = 4.0
    /// Two buttons are in the same row when their vertical extents overlap by this fraction
    /// of the shorter one.
    public static let rowBandOverlap = 0.5
    /// Cross-section: search fields must agree in y and width within these.
    public static let searchYTolerance = 4.0
    public static let searchWidthTolerance = 8.0
    /// Cross-section: sidebar items must not move ("identical" up to sub-pixel rounding).
    public static let sidebarTolerance = 0.5
    /// Cross-section: action buttons in the same placement share a height within this.
    public static let actionHeightTolerance = 2.0

    // MARK: Roles
    public static let interactiveRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton",
        "AXTextField", "AXSearchField", "AXSecureTextField", "AXTextArea", "AXComboBox",
        "AXSlider", "AXLink", "AXDisclosureTriangle", "AXIncrementor", "AXColorWell",
        "AXSegment", "AXDateField", "AXTimeField",
    ]
    public static let interactiveSubroles: Set<String> = [
        "AXSearchField", "AXSecureTextField", "AXSegment", "AXSwitch", "AXToggle", "AXTabButton",
    ]
    public static let textInputRoles: Set<String> = [
        "AXTextField", "AXSearchField", "AXSecureTextField", "AXTextArea", "AXComboBox",
        "AXDateField", "AXTimeField",
    ]
    public static let toggleRoles: Set<String> = ["AXCheckBox", "AXRadioButton"]
    /// Roles whose value is what VoiceOver announces as the name (the selected item, link text).
    public static let valueIsNameRoles: Set<String> = ["AXPopUpButton", "AXMenuButton", "AXLink"]
    /// Window chrome: named by AXRoleDescription, sized by the system.
    public static let windowChromeSubroles: Set<String> = [
        "AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton",
    ]
    /// System-drawn controls with a fixed size (disclosure triangles 13 pt, steppers 13×22).
    public static let fixedSizeSystemRoles: Set<String> = ["AXDisclosureTriangle", "AXIncrementor"]
    public static let textRoles: Set<String> = ["AXStaticText", "AXHeading"]
    /// Table plumbing that legitimately repeats names (columns, rows, cells).
    public static let structuralRoles: Set<String> = ["AXRow", "AXCell", "AXColumn", "AXSplitter"]
    static let anonymousWrapperRoles: Set<String> = ["AXGroup", "AXUnknown"]

    public static func isInteractive(_ node: AXNode) -> Bool {
        interactiveRoles.contains(node.role) || node.subrole.map(interactiveSubroles.contains) == true
    }

    public static func isTextInput(_ node: AXNode) -> Bool {
        textInputRoles.contains(node.role)
            || node.subrole.map { $0 == "AXSearchField" || $0 == "AXSecureTextField" } == true
    }

    public static func isToggle(_ node: AXNode) -> Bool {
        toggleRoles.contains(node.role) || node.subrole.map { $0 == "AXSwitch" || $0 == "AXToggle" } == true
    }

    public static func isWindowChrome(_ node: AXNode) -> Bool {
        node.subrole.map(windowChromeSubroles.contains) == true
    }

    /// Parts of system controls (stepper arrows, scroll-bar arrows/pages): named by
    /// AXRoleDescription and sized by AppKit. Seen out of process in sheets and scroll areas.
    public static let systemPartSubroles: Set<String> = [
        "AXIncrementArrow", "AXDecrementArrow", "AXIncrementPage", "AXDecrementPage",
    ]

    /// Window chrome or a system control part — exempt from label, size and row-height rules.
    public static func isSystemDrawn(_ node: AXNode) -> Bool {
        isWindowChrome(node) || node.subrole.map(systemPartSubroles.contains) == true
    }

    /// What VoiceOver announces as the element's name, or `nil` when it has none.
    public static func spokenName(_ node: AXNode) -> String? {
        if let name = node.accessibleName { return name }
        if valueIsNameRoles.contains(node.role), let v = nonBlank(node.value) { return v }
        // VoiceOver reads the placeholder of an empty text field.
        if isTextInput(node), let p = nonBlank(node.placeholder) { return p }
        return nil
    }

    // MARK: Identifier contract (docs/ARCHITECTURE.md)
    public static let mainWindowIdentifier = "basket.main"
    public static let sections = ["overview", "containers", "images", "volumes", "networks", "machines", "migration"]
    public static let listSections: Set<String> = ["containers", "images", "volumes", "networks", "machines", "migration"]
    /// Section titles that aren't just the capitalized section name.
    public static let sectionTitles = ["migration": "Migrate from OrbStack"]
    public static let overviewRequiredCards = ["memory", "disk", "system"]

    /// Identifiers that must be present (each inner array: at least one of them).
    public static func requiredIdentifiers(section: String?) -> [[String]] {
        var required: [[String]] = [[mainWindowIdentifier]]
        guard let section else { return required }
        required += sections.map { ["sidebar.\($0)"] }
        required.append(["section.\(section)"])
        if listSections.contains(section) {
            required.append(["\(section).search"])
            required.append(["\(section).action.refresh"])
            required.append(["\(section).list", "\(section).empty"])
        }
        if section == "overview" {
            required += overviewRequiredCards.map { ["overview.card.\($0)"] }
        }
        return required
    }
}

func nonBlank(_ s: String?) -> String? {
    guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return s
}
