@testable import BasketAXKit

// Small builders for synthetic AX trees. Coordinates are screen points, top-left origin.

func r(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> AXRect {
    AXRect(x: x, y: y, width: w, height: h)
}

let windowFrame = r(100, 100, 1280, 820)

func window(_ children: [AXNode], id: String? = "basket.main", frame: AXRect? = windowFrame) -> AXNode {
    AXNode(role: "AXWindow", subrole: "AXStandardWindow", identifier: id, title: "Basket", frame: frame, children: children)
}

func group(_ children: [AXNode], id: String? = nil, frame: AXRect? = nil, role: String = "AXGroup") -> AXNode {
    AXNode(role: role, identifier: id, frame: frame, children: children)
}

func button(_ id: String?, _ frame: AXRect?, title: String? = "Action", label: String? = nil,
            subrole: String? = nil, children: [AXNode] = []) -> AXNode {
    AXNode(role: "AXButton", subrole: subrole, identifier: id, title: title, label: label,
           frame: frame, isEnabled: true, children: children)
}

func text(_ value: String, _ frame: AXRect?, id: String? = nil, role: String = "AXStaticText") -> AXNode {
    AXNode(role: role, identifier: id, label: role == "AXStaticText" ? nil : value,
           value: role == "AXStaticText" ? value : nil, frame: frame)
}

func field(_ id: String?, _ frame: AXRect?, placeholder: String? = "Search", subrole: String? = "AXSearchField") -> AXNode {
    AXNode(role: "AXTextField", subrole: subrole, identifier: id, placeholder: placeholder, frame: frame, isEnabled: true)
}

func node(_ role: String, _ id: String? = nil, _ frame: AXRect? = nil, children: [AXNode] = []) -> AXNode {
    AXNode(role: role, identifier: id, frame: frame, children: children)
}

/// A contract-complete, lint-clean main window showing `section`. Knobs shift single elements
/// so consistency rules can be exercised.
func basketWindow(
    section: String,
    origin: (x: Double, y: Double) = (100, 100),
    sidebarShift: Double = 0,
    searchY: Double = 70,
    searchWidth: Double = 300,
    refreshRole: String = "AXButton",
    refreshHeight: Double = 24,
    toolbarActionHeight: Double = 36,
    titleRole: String = "AXHeading",
    withTitle: Bool = true,
    size: (w: Double, h: Double) = (1280, 820)
) -> AXNode {
    let ox = origin.x, oy = origin.y
    func at(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> AXRect { r(ox + x, oy + y, w, h) }

    let sidebarRows = AXAuditRules.sections.enumerated().map { i, s in
        node("AXRow", nil, at(8, 60 + Double(i) * 32 + sidebarShift, 180, 32), children: [
            node("AXCell", nil, at(18, 60 + Double(i) * 32 + sidebarShift, 160, 32), children: [
                text(s.capitalized, at(30, 68 + Double(i) * 32 + sidebarShift, 80, 16), id: "sidebar.\(s)"),
            ]),
        ])
    }
    let sidebar = node("AXScrollArea", nil, at(8, 52, 180, 760), children: [
        node("AXOutline", nil, at(8, 52, 180, 760), children: sidebarRows),
    ])

    var content: [AXNode] = []
    if withTitle {
        content.append(text(AXAuditRules.sectionTitles[section] ?? section.capitalized, at(210, 30, 220, 20), role: titleRole))
    }
    if section == "overview" {
        content += ["memory", "disk", "system"].enumerated().map { i, card in
            group([text(card.capitalized, at(220 + Double(i) * 340, 120, 100, 16))],
                  id: "overview.card.\(card)", frame: at(210 + Double(i) * 340, 110, 320, 200))
        }
    } else {
        content.append(field("\(section).search", at(210, searchY, searchWidth, 24)))
        let refreshFrame = at(530, 70, 80, refreshHeight)
        content.append(AXNode(role: refreshRole, identifier: "\(section).action.refresh", title: "Refresh",
                              frame: refreshFrame, isEnabled: true))
        content.append(button("\(section).action.export", at(620, 70, 80, refreshHeight), title: "Export"))
        let rows = (0..<3).map { i in
            node("AXRow", nil, at(210, 120 + Double(i) * 24, 1000, 24), children: [
                node("AXCell", nil, at(220, 120 + Double(i) * 24, 980, 24), children: [
                    text("item-\(i)", at(226, 124 + Double(i) * 24, 60, 16), id: "\(section).row.item-\(i)"),
                ]),
            ])
        }
        content.append(node("AXScrollArea", nil, at(210, 110, 1000, 600), children: [
            node("AXOutline", "\(section).list", at(210, 110, 1000, 600), children: rows),
        ]))
    }
    let sectionGroup = group(content, id: "section.\(section)", frame: at(200, 52, 1080, 768))
    let toolbar = node("AXToolbar", nil, at(0, 0, size.w, 52), children: [
        button("\(section).action.new", at(1200, 8, 44, toolbarActionHeight), title: nil, label: "New"),
    ])
    let chrome = [
        button(nil, at(20, 18, 16, 16), title: nil, subrole: "AXCloseButton"),
        button(nil, at(42, 18, 16, 16), title: nil, subrole: "AXMinimizeButton"),
        button(nil, at(64, 18, 16, 16), title: nil, subrole: "AXZoomButton"),
    ]
    return window([group([node("AXSplitGroup", nil, at(0, 52, size.w, size.h - 52), children: [sidebar, sectionGroup])]),
                   toolbar] + chrome,
                  frame: r(ox, oy, size.w, size.h))
}

extension Array where Element == AXFinding {
    func rule(_ id: String) -> [AXFinding] { filter { $0.rule == id } }
}
