import SwiftUI
import BasketCore

/// "Check for Updates…" and automatic checks: the newer version with its notes, the download, or
/// why there is nothing to install. Security failures are final: no "try again", no "install anyway".
struct UpdateSheet: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let updates = store.updates
        Group {
            if let offer = updates.offer, showsOffer(updates.phase) {
                OfferView(updates: updates, offer: offer)
            } else {
                StatusView(updates: updates)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sheet.update")
        .interactiveDismissDisabled(updates.isBusy)
    }

    private func showsOffer(_ phase: UpdatePhase) -> Bool {
        switch phase {
        case .available, .downloading, .verifying, .relaunching: true
        case .failed(let failure): failure.retry == .install
        default: false
        }
    }
}

private struct SheetHeader: View {
    var title: String
    var subtitle: String
    var titleIdentifier: String

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 56, height: 56)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title2.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(titleIdentifier)
                Text(subtitle)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

/// A newer version: notes, size, download progress and Install and Relaunch / Later / Skip.
private struct OfferView: View {
    let updates: UpdateController
    let offer: UpdateOffer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                SheetHeader(title: "Basket \(offer.version) is available", subtitle: subtitle, titleIdentifier: "update.version")
                Text("What’s New").font(.headline)
                ReleaseNotesView(notes: offer.notes)
                    .accessibilityIdentifier("update.notes")
                status
            }
            .padding(20)
            Divider()
            HStack(spacing: 10) {
                Button("Skip This Version") { updates.skipThisVersion() }
                    .disabled(updates.isBusy)
                    .accessibilityIdentifier("update.skip")
                Spacer()
                if updates.isBusy {
                    Button("Cancel", role: .cancel) { updates.cancel() }
                        .keyboardShortcut(.cancelAction)
                        .disabled(updates.phase == .relaunching)
                        .accessibilityIdentifier("update.cancel")
                } else {
                    Button("Later") { updates.dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("update.later")
                }
                if case .failed(let failure) = updates.phase, let retry = failure.retry {
                    Button("Try Again") { updates.retry(retry) }
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("update.retry")
                } else {
                    Button("Install and Relaunch") { updates.install() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(updates.isBusy)
                        .accessibilityIdentifier("update.install")
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 560, height: 520)
    }

    private var subtitle: String {
        var parts = ["You have \(updates.currentVersionText)", "released \(offer.date.formatted(date: .long, time: .omitted))"]
        if let size = updates.offerSize { parts.append(Format.disk(size)) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var status: some View {
        switch updates.phase {
        case .downloading(let received, let expected):
            DownloadProgress(received: received, expected: expected)
        case .verifying:
            ProgressRow(text: "Verifying the signature…")
        case .relaunching:
            ProgressRow(text: "Installing. Basket quits and opens again…")
        case .failed(let failure):
            FailureBox(title: failure.title, message: failure.message, isSecurity: failure.isSecurity)
        default:
            Label("Signed by Basket’s maintainer and verified before it replaces this copy.", systemImage: "checkmark.shield")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(height: 30, alignment: .leading)
        }
    }
}

private struct DownloadProgress: View {
    var received: Int64
    var expected: Int64?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let expected, expected > 0 {
                ProgressView(value: Double(min(received, expected)), total: Double(expected))
                Text("Downloading… \(Format.disk(received)) of \(Format.disk(expected))")
                    .monospacedDigit()
            } else {
                ProgressView().progressViewStyle(.linear)
                Text("Downloading… \(Format.disk(received))").monospacedDigit()
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(height: 30)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("update.progress")
    }
}

private struct ProgressRow: View {
    var text: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(height: 30, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("update.progress")
    }
}

private struct FailureBox: View {
    var title: String?
    var message: String
    var isSecurity: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isSecurity ? "xmark.shield.fill" : "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(isSecurity ? Color.red : Color.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                if let title { Text(title).font(.callout.weight(.semibold)) }
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background((isSecurity ? Color.red : Color.orange).opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isSecurity ? "Security error" : "Error")
        .accessibilityIdentifier("update.error")
    }
}

/// Checking, up to date, unavailable for this copy, or a failed check / security failure.
private struct StatusView: View {
    let updates: UpdateController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                content
            }
            .padding(20)
            Spacer(minLength: 0)
            Divider()
            HStack(spacing: 10) {
                if updates.unavailableReason != nil {
                    Button("Open Releases Page") { NSWorkspace.shared.open(UpdatePolicy.releasesPageURL) }
                        .accessibilityIdentifier("update.releases")
                }
                Spacer()
                buttons
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var content: some View {
        if let reason = updates.unavailableReason {
            SheetHeader(title: "Updates aren’t available for this copy", subtitle: reason, titleIdentifier: "update.status")
        } else {
            switch updates.phase {
            case .checking:
                SheetHeader(title: "Checking for updates…", subtitle: "Basket \(updates.currentVersionText)",
                            titleIdentifier: "update.status")
                ProgressView().progressViewStyle(.linear)
                    .accessibilityLabel("Checking for updates")
                    .accessibilityIdentifier("update.progress")
            case .upToDate:
                SheetHeader(title: "You’re up to date", subtitle: "Basket \(updates.currentVersionText) is the newest version.",
                            titleIdentifier: "update.status")
            case .failed(let failure):
                SheetHeader(title: failure.title, subtitle: "Basket \(updates.currentVersionText) stays installed.",
                            titleIdentifier: "update.status")
                FailureBox(title: nil, message: failure.message, isSecurity: failure.isSecurity)
            default:
                SheetHeader(title: "Basket \(updates.currentVersionText)", subtitle: "Choose Check for Updates… to look for a newer version.",
                            titleIdentifier: "update.status")
            }
        }
    }

    @ViewBuilder private var buttons: some View {
        if updates.phase == .checking, updates.unavailableReason == nil {
            Button("Cancel", role: .cancel) { updates.cancel() }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("update.cancel")
        } else {
            if case .failed(let failure) = updates.phase, let retry = failure.retry, updates.unavailableReason == nil {
                Button("Try Again") { updates.retry(retry) }
                    .accessibilityIdentifier("update.retry")
            }
            Button(updates.phase == .upToDate ? "OK" : "Close") { updates.dismiss() }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("update.done")
        }
    }
}

/// Release notes from Markdown: headings, bullets and paragraphs, inline styles and links.
struct ReleaseNotesView: View {
    var notes: String

    var body: some View {
        let blocks = ReleaseNotes.blocks(notes)
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                if blocks.isEmpty {
                    Text("No release notes.").foregroundStyle(.secondary)
                }
                ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                    switch block {
                    case .heading(let text):
                        Text(Self.inline(text))
                            .font(.headline)
                            .padding(.top, index == 0 ? 0 : 6)
                    case .bullet(let text):
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("•").foregroundStyle(.secondary).accessibilityHidden(true)
                            Text(Self.inline(text)).fixedSize(horizontal: false, vertical: true)
                        }
                    case .paragraph(let text):
                        Text(Self.inline(text)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Release notes")
    }

    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
