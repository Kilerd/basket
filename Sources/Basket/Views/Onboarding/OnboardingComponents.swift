import SwiftUI
import AppKit

/// Centered icon, title and one-paragraph explanation, then the step's content. The step root
/// carries `onboarding.step.<name>` (AX contract).
struct OnboardingStepScaffold<Icon: View, Content: View>: View {
    var step: OnboardingStep
    var title: String
    var message: String
    /// Vertically centred (the welcome page) instead of top-aligned like the task steps.
    var centered = false
    @ViewBuilder var icon: Icon
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            if centered { Spacer(minLength: 0) }
            icon
                .frame(minHeight: 56)
                .accessibilityHidden(true)
                .padding(.bottom, 12)
            Text(title)
                .font(.title.weight(.semibold))
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("onboarding.title")
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 460)
                .padding(.top, 8)
            VStack(alignment: .leading, spacing: 14) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 20)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 40)
        .padding(.top, 44)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityIdentifier("onboarding.step.\(step.rawValue)")
    }
}

extension OnboardingStepScaffold where Icon == OnboardingSymbol {
    init(step: OnboardingStep, symbol: String, title: String, message: String, @ViewBuilder content: () -> Content) {
        self.init(step: step, title: title, message: message, icon: { OnboardingSymbol(name: symbol) }, content: content)
    }
}

/// The step's SF Symbol at the size of the welcome step's app icon.
struct OnboardingSymbol: View {
    var name: String

    var body: some View {
        Image(systemName: name)
            .font(.system(size: 40, weight: .regular))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.tint)
    }
}

/// Rounded, grouped box of rows (System Settings style).
struct OnboardingBox<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
    }
}

/// What a status row says about its subject.
enum OnboardingStatus {
    case ok, warning, blocked, neutral, working

    var symbol: String {
        switch self {
        case .ok: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .blocked: "xmark.circle.fill"
        case .neutral: "circle.dashed"
        case .working: ""
        }
    }

    var tint: Color {
        switch self {
        case .ok: .green
        case .warning: .orange
        case .blocked: .red
        case .neutral, .working: .secondary
        }
    }

    /// Spoken with the row so state isn't conveyed by colour alone.
    var spoken: String? {
        switch self {
        case .ok: "Done"
        case .warning: "Needs attention"
        case .blocked: "Not supported"
        case .neutral: nil
        case .working: "In progress"
        }
    }
}

/// Icon + title + detail. The icon sits in a fixed 20 pt slot so titles line up down the box.
struct OnboardingStatusRow: View {
    var status: OnboardingStatus
    var title: String
    var detail: String?
    var identifier: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Group {
                if status == .working {
                    // A spinner has no text baseline: centre it on the title's first line.
                    ProgressView().controlSize(.small)
                        .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 4 }
                } else {
                    Image(systemName: status.symbol).foregroundStyle(status.tint)
                }
            }
            .frame(width: 20)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                if let detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityValue(status.spoken ?? "")
        .modifier(OptionalIdentifier(identifier: identifier))
    }
}

struct OptionalIdentifier: ViewModifier {
    var identifier: String?

    func body(content: Content) -> some View {
        if let identifier { content.accessibilityIdentifier(identifier) } else { content }
    }
}

/// Divider inset to the row text (after the 20 pt icon slot).
struct OnboardingRowDivider: View {
    var body: some View {
        Divider().padding(.leading, 44)
    }
}

/// Streamed command output: selectable, follows the tail.
struct OnboardingLog: View {
    var lines: [String]
    var label: String

    var body: some View {
        MonospacedTextView(text: lines.joined(separator: "\n"), followTail: true, identifier: "onboarding.log", label: label)
            .frame(height: 112)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
    }
}

/// Error text under a step's actions.
struct OnboardingFailure: View {
    var message: String

    var body: some View {
        Label {
            Text(message).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        } icon: {
            Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("onboarding.error")
    }
}

/// Exact text Basket will add to a file.
struct OnboardingCodeBlock: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.callout.monospaced())
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
    }
}
