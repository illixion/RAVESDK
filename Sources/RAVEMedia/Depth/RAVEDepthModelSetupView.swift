/*
 RAVEMedia — choosing and installing a depth model.

 `DepthModelManager` already lives here and owns everything hard about this:
 the variant catalogue, the Hugging Face download, integrity checking, and the
 managed store. What used to be app-side was the twenty lines of SwiftUI in
 front of it, which two apps then wrote separately — Spatial Stash to onboard
 fake-3D video, Raven to onboard converting a web page's video. The rows, the
 progress, the "Use" affordance and the byte labels are the same view of the
 same state, so they live with the state.

 What deliberately does *not* live here is the preference the choice writes.
 Spatial Stash has two roles to set (realtime and pre-process) and a settings
 screen that also edits them; Raven has one and no settings at all. So this
 view reports the chosen variant and the host decides what that means —
 `onSelect` is called only after the model is genuinely installed.

 The lead paragraph is likewise the host's, because the sentence that makes
 sense of a download depends on what the user just tapped.
 */

import SwiftUI

@MainActor
public struct RAVEDepthModelSetupView<Footer: View>: View {
    @Environment(\.dismiss) private var dismiss
    @State private var models = DepthModelManager.shared

    private let title: String
    private let prompt: String
    private let footer: Footer
    private let onSelect: (DepthModelManager.Variant) -> Void

    /// - Parameters:
    ///   - prompt: the lead paragraph. Say what the download is *for* in the
    ///     terms of whatever the user just tried to do.
    ///   - onSelect: called with an installed variant, before dismissal. The
    ///     host persists its own model preference here and resumes its work.
    ///   - footer: anything host-specific below the list (Spatial Stash puts
    ///     its "bring your own model" note here).
    public init(
        title: String = "Add a 3D Depth Model",
        prompt: String,
        onSelect: @escaping (DepthModelManager.Variant) -> Void,
        @ViewBuilder footer: () -> Footer = { EmptyView() }
    ) {
        self.title = title
        self.prompt = prompt
        self.onSelect = onSelect
        self.footer = footer()
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(prompt)
                        .foregroundStyle(.secondary)

                    ForEach(DepthModelManager.variants) { variant in
                        row(variant)
                    }

                    if let error = models.errorMessage {
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }

                    footer
                }
                .padding(24)
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .frame(minWidth: 460, minHeight: 440)
    }

    @ViewBuilder
    private func row(_ variant: DepthModelManager.Variant) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(variant.displayName)
                    .font(.headline)
                Text(variant.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if models.isDownloading(variant) {
                ProgressView(value: models.progress[variant.name] ?? 0)
                    .frame(width: 120)
            } else if models.isInstalled(variant) {
                Button("Use") { finish(variant) }
                    .buttonStyle(.borderedProminent)
            } else {
                Button {
                    Task {
                        await models.download(variant)
                        // Only on success: a failed download leaves
                        // `errorMessage` on screen and the sheet up, rather
                        // than dismissing into a conversion that cannot run.
                        if models.isInstalled(variant) { finish(variant) }
                    }
                } label: {
                    Label(byteLabel(variant.approxBytes), systemImage: "arrow.down.circle")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func finish(_ variant: DepthModelManager.Variant) {
        onSelect(variant)
        dismiss()
    }

    private func byteLabel(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
