//
//  RAVELauncherSheets.swift
//  RAVELauncher
//
//  The two questions a launcher asks: may this app add a tile (with what it
//  will open, since the sender can't be verified), and which link opens an app
//  that offered none.
//

import Foundation
import RAVEUI
import SwiftUI

/// Asks before a shortcut request becomes a tile. The sender named itself in a URL
/// anyone can send, so the owner is presented as the request's claim and the
/// destination is shown for the person to check.
public struct RAVELauncherShortcutRequestView: View {
    let request: RAVELauncherShortcutRequest
    let ownerName: String
    let error: String?
    let onCancel: () -> Void
    let onAdd: () -> Void

    public init(request: RAVELauncherShortcutRequest, ownerName: String, error: String?,
                onCancel: @escaping () -> Void, onAdd: @escaping () -> Void) {
        self.request = request
        self.ownerName = ownerName
        self.error = error
        self.onCancel = onCancel
        self.onAdd = onAdd
    }

    /// The page behind a wrapper link (`raven://open?url=https://…`) when there is one, as
    /// host and path: what the person recognises.
    var targetDescription: String {
        guard let url = URL(string: request.targetURL) else { return request.targetURL }
        let nested = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "url" })?.value.flatMap(URL.init(string:))
        let destination = nested ?? url
        return destination.host.map { "\($0)\(destination.path.isEmpty ? "" : destination.path)" }
            ?? destination.absoluteString
    }

    public var body: some View {
        VStack(spacing: 20) {
            RAVELauncherIconView(icon: request.iconData.map { .data($0) }
                                     ?? .remote(request.iconURL.flatMap(URL.init(string:))),
                                 name: request.title, size: 84)
            VStack(spacing: 6) {
                Text("Add to Home?")
                    .font(.title2.weight(.semibold))
                Text(request.title)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text("This request says it will open with \(ownerName). Check the destination before adding.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text(targetDescription)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
            }
            HStack(spacing: 12) {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                Button("Add to Home", action: onAdd)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("acceptLauncherShortcut")
            }
        }
        .padding(28)
        .frame(width: 460)
        .raveScreenTitle("Add to Home")
    }
}

/// Edit the link that opens an app: its custom scheme or a universal link the app routes
/// to its main screen. Save hands back nil for Remove.
public struct RAVELaunchLinkEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var value: String
    @State private var error: String?

    let name: String
    let forbidding: Set<String>
    let onSave: (URL?) -> Void

    public init(name: String, currentURL: String, forbidding: Set<String> = [], onSave: @escaping (URL?) -> Void) {
        self.name = name
        self.forbidding = forbidding
        self.onSave = onSave
        _value = State(initialValue: currentURL)
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Launch Link for \(name)") {
                    TextField("myapp://open", text: $value)
                        .autocorrectionDisabled()
                        #if !os(macOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                }
                Section {
                    Text("Use a link the app handles, such as its custom URL scheme or universal link. The app can route this link to its main screen.")
                        .foregroundStyle(.secondary)
                }
                if let error {
                    Text(error).foregroundStyle(.red)
                }
            }
            .navigationTitle("Launch Link")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                ToolbarItem(placement: .destructiveAction) {
                    if !value.isEmpty { Button("Remove", role: .destructive) { onSave(nil); dismiss() } }
                }
            }
        }
        .frame(minWidth: 480, minHeight: 340)
    }

    private func save() {
        guard let url = RAVELaunchLink.validated(value, forbidding: forbidding) else {
            error = "Enter a valid app link or universal link."
            return
        }
        onSave(url)
        dismiss()
    }
}
