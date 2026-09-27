/*
 RAVEDeviceSetup - read a setup code from a photo, without asking for access

 `PhotosPicker` runs out of process and hands back only the image the user
 picks, so the app needs neither camera nor photo-library permission. The
 photo can be one just taken with the Camera app (the Vision Pro's
 included), a screenshot, or on a Mac, anything in Photos.

 On iPhone and iPad the system Camera reads the code directly and opens the
 app's URL scheme, which is quicker; this is the route for everything else.
 */

#if !os(tvOS)

import PhotosUI
import SwiftUI

public enum RAVESetupScanFailure: LocalizedError, Sendable {
    case unreadable
    case noCode

    public var errorDescription: String? {
        switch self {
        case .unreadable: "That photo couldn't be opened."
        case .noCode: "No setup code was found in that photo. Take it straight on, with the whole code in view."
        }
    }
}

public struct RAVESetupScanPhotoButton<Label: View>: View {
    private let service: RAVESetupService
    private let onResult: (Result<RAVESetupCode, RAVESetupScanFailure>) -> Void
    private let label: Label
    @State private var selection: PhotosPickerItem?

    public init(service: RAVESetupService,
                onResult: @escaping (Result<RAVESetupCode, RAVESetupScanFailure>) -> Void,
                @ViewBuilder label: () -> Label) {
        self.service = service
        self.onResult = onResult
        self.label = label()
    }

    public var body: some View {
        PhotosPicker(selection: $selection, matching: .images, preferredItemEncoding: .current) {
            label
        }
        .onChange(of: selection) { _, item in
            guard let item else { return }
            selection = nil
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self) else {
                    onResult(.failure(.unreadable))
                    return
                }
                let service = service
                let codes = await Task.detached { RAVESetupQRCode.codes(inImageData: data, service: service) }.value
                onResult(codes.first.map { .success($0) } ?? .failure(.noCode))
            }
        }
    }
}

#endif
