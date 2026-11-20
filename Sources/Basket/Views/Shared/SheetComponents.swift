import SwiftUI

/// Title, scrollable grouped form and a button row — the layout every Basket sheet uses.
struct SheetScaffold<Content: View, Footer: View>: View {
    var title: String
    var subtitle: String
    var identifier: String
    var width: CGFloat = 520
    var height: CGFloat = 560
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title2.weight(.semibold))
                Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 4)
            Form { content }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
            Divider()
            HStack(spacing: 10) { footer }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
        .frame(width: width, height: height)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}

struct ListEntry: Identifiable, Hashable {
    var id = UUID()
    var value: String
}

/// Editable list of strings ("8080:80", "KEY=value", …) with add/remove buttons.
struct StringListEditor: View {
    var noun: String
    var placeholder: String
    var identifier: String
    @Binding var entries: [ListEntry]

    var body: some View {
        ForEach($entries) { $entry in
            HStack(spacing: 8) {
                TextField(noun, text: $entry.value, prompt: Text(placeholder))
                    .labelsHidden()
                    .font(.body.monospaced())
                    .accessibilityLabel(noun)
                Button {
                    entries.removeAll { $0.id == entry.id }
                } label: {
                    Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .frame(minWidth: 22, minHeight: 22)
                .help("Remove")
                .accessibilityLabel("Remove \(noun.lowercased()) \(entry.value)")
            }
        }
        Button {
            entries.append(ListEntry(value: ""))
        } label: {
            Label("Add \(noun)", systemImage: "plus.circle")
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier(identifier)
    }
}

/// Streamed command output (pull / create) with an optional determinate progress bar.
struct ProgressLog: View {
    var lines: [String]
    var identifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let fraction = Self.fraction(in: lines.last) {
                ProgressView(value: fraction)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(lines.suffix(200).enumerated()), id: \.offset) { index, line in
                            Text(line).font(.caption.monospaced()).foregroundStyle(.secondary).id(index)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(height: 90)
                .onChange(of: lines.count) {
                    proxy.scrollTo(min(lines.count, 200) - 1, anchor: .bottom)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    /// Picks the last "NN%" out of a progress line.
    static func fraction(in line: String?) -> Double? {
        guard let line, let match = line.firstMatch(of: /(\d{1,3}(?:\.\d+)?)%/), let value = Double(match.1) else { return nil }
        return min(1, max(0, value / 100))
    }
}

/// Sizes offered for memory pickers, in MiB.
let memoryChoicesMB = [256, 512, 1024, 2048, 4096, 8192, 16384]

func memoryChoiceLabel(_ mb: Int) -> String {
    mb >= 1024 ? "\(mb / 1024) GB" : "\(mb) MB"
}

/// "CPUs        2 [⌃⌄]" — label left, value and stepper right, as in System Settings.
struct StepperRow: View {
    var title: String
    @Binding var value: Int
    var range: ClosedRange<Int>
    var identifier: String

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Text("\(value)").monospacedDigit()
                Stepper(title, value: $value, in: range)
                    .labelsHidden()
                    .accessibilityIdentifier(identifier)
            }
        }
    }
}
