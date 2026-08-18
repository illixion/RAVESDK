/*
 RAVE SDK — live process, GPU and thermal readings, and a compact view for them.

 The GPU figure is Spatial Stash's: it built a monitor to compare lossy against
 lossless texture storage, a question only `MTLDevice.currentAllocatedSize`
 answers. Ported here rather than left there because "how much memory does
 this feature actually cost" is a question every RAVE app eventually asks, not
 a Spatial-Stash-specific one — and every app that wants it already links
 RAVEConsole for the log viewer, so this rides along rather than needing a
 dedicated diagnostics target of its own.

 Three numbers easy to confuse, because on Apple Silicon they all draw on the
 same physical pool but move for different reasons:

 - `gpuAllocated` moves with texture/resource count and compression mode, and
   with nothing else — an app that isn't touching Metal resources will show
   this flat regardless of what else it is doing.
 - `processFootprint` is what jetsam counts against this process, and moves
   with everything the process holds, GPU-backed or not.
 - `availableMemory` is headroom before jetsam ends the process — the number
   that actually decides whether a feature is safe to ship, and derivable from
   neither of the other two.

 `physicalMemory` and `thermalState` are the additional facts worth reading
 alongside those three: a gauge sized to a hardcoded per-model constant goes
 stale the moment this runs on different hardware, and a decode/encode-heavy
 feature that looks like a memory problem can actually be thermal throttling —
 nothing above this line can tell the two apart without it.
 */

import Foundation
import Metal

#if canImport(SwiftUI)
import SwiftUI
#endif

/// One reading of the memory and thermal situation. All byte values are in
/// bytes; every field is nil where the platform or configuration cannot
/// answer, rather than a misleading zero.
public struct RAVESystemReading: Sendable, Equatable {
    /// `MTLDevice.currentAllocatedSize` — what Metal is holding for this
    /// process on `device`.
    public var gpuAllocated: Int?
    /// `task_vm_info.phys_footprint` — what jetsam counts against this process.
    public var processFootprint: Int?
    /// `os_proc_available_memory()` — headroom before this process is
    /// terminated. Only meaningful under the hard memory cap iOS-family
    /// platforms impose; nil on macOS, which has none.
    public var availableMemory: Int?
    /// Total physical RAM on this device.
    public var physicalMemory: Int?
    /// `ProcessInfo.thermalState`.
    public var thermalState: ProcessInfo.ThermalState?

    public init(
        gpuAllocated: Int? = nil,
        processFootprint: Int? = nil,
        availableMemory: Int? = nil,
        physicalMemory: Int? = nil,
        thermalState: ProcessInfo.ThermalState? = nil
    ) {
        self.gpuAllocated = gpuAllocated
        self.processFootprint = processFootprint
        self.availableMemory = availableMemory
        self.physicalMemory = physicalMemory
        self.thermalState = thermalState
    }

    /// Fraction of a nominal ceiling the GPU allocation occupies, for a gauge.
    public func gpuFraction(of ceiling: Int) -> Double? {
        guard let gpuAllocated, ceiling > 0 else { return nil }
        return Double(gpuAllocated) / Double(ceiling)
    }
}

public enum RAVESystemMonitor {
    /// Bytes Metal currently has allocated on `device`.
    public static func gpuAllocated(device: (any MTLDevice)?) -> Int? {
        device?.currentAllocatedSize
    }

    /// This process's physical footprint — the number jetsam judges.
    public static func processFootprint() -> Int? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Int(info.phys_footprint)
    }

    /// Bytes this process may still allocate before it is terminated.
    public static func availableMemory() -> Int? {
        #if os(visionOS) || os(iOS) || os(tvOS) || os(watchOS)
        let available = os_proc_available_memory()
        return available > 0 ? available : nil
        #else
        return nil
        #endif
    }

    /// Total physical RAM on this device, for sizing a gauge to what is
    /// actually installed rather than a constant that goes stale on the next
    /// piece of hardware.
    public static func physicalMemory() -> Int {
        Int(ProcessInfo.processInfo.physicalMemory)
    }

    public static func thermalState() -> ProcessInfo.ThermalState {
        ProcessInfo.processInfo.thermalState
    }

    /// Everything at once. `device` is optional so a caller with no Metal
    /// resources of its own (or none handy) still gets the other four.
    public static func reading(device: (any MTLDevice)? = nil) -> RAVESystemReading {
        RAVESystemReading(
            gpuAllocated: gpuAllocated(device: device),
            processFootprint: processFootprint(),
            availableMemory: availableMemory(),
            physicalMemory: physicalMemory(),
            thermalState: thermalState()
        )
    }

    /// `ByteCountFormatter` with the settings every readout here wants:
    /// memory count style, KB through GB.
    public static func format(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .memory
        return formatter.string(fromByteCount: Int64(bytes))
    }
}

#if canImport(SwiftUI)

/// A live-updating GPU gauge plus the rest of `RAVESystemReading`, polled once
/// a second while visible. Generic across every RAVE app — nothing here
/// assumes windows, textures or any app-specific concept the way Spatial
/// Stash's original (built to compare texture-compression modes) did.
public struct RAVESystemMonitorView: View {
    private let device: (any MTLDevice)?

    @State private var reading = RAVESystemReading()
    @State private var peakGPU: Int = 0
    @State private var pollingTask: Task<Void, Never>?

    /// - Parameters:
    ///   - device: the Metal device to read `gpuAllocated` from. Nil reports
    ///     that field as unavailable rather than reaching for
    ///     `MTLCreateSystemDefaultDevice()` on the caller's behalf — a caller
    ///     that already owns a device (a renderer, an engine) should hand it
    ///     over, since a second device handle is not guaranteed to report the
    ///     same process-wide allocation on every OS version.
    public init(device: (any MTLDevice)? = nil) {
        self.device = device
    }

    private var currentGPU: Int { reading.gpuAllocated ?? 0 }
    /// The device's own total RAM, once the first reading arrives — sized to
    /// what is actually installed rather than a guessed constant.
    private var ceiling: Int { max(reading.physicalMemory ?? 0, 1) }

    public var body: some View {
        VStack(spacing: 16) {
            if reading.gpuAllocated != nil {
                Gauge(value: Double(currentGPU), in: 0...Double(ceiling)) {
                    Text("GPU Allocated")
                } currentValueLabel: {
                    Text(RAVESystemMonitor.format(currentGPU))
                        .font(.system(.title3, design: .monospaced))
                        .fontWeight(.bold)
                } minimumValueLabel: {
                    Text("0").font(.caption2)
                } maximumValueLabel: {
                    Text(RAVESystemMonitor.format(ceiling)).font(.caption2)
                }
                .gaugeStyle(.accessoryLinear)
            }

            HStack(spacing: 24) {
                statBox("GPU", optional(reading.gpuAllocated))
                statBox("Peak GPU", RAVESystemMonitor.format(peakGPU))
                statBox("Footprint", optional(reading.processFootprint))
            }
            HStack(spacing: 24) {
                statBox("Headroom", optional(reading.availableMemory))
                statBox("Total RAM", optional(reading.physicalMemory))
                statBox(
                    "Thermal",
                    reading.thermalState.map(thermalLabel) ?? "—",
                    tint: reading.thermalState.map(thermalColor)
                )
            }

            Button("Reset Peak") { peakGPU = currentGPU }
                .buttonStyle(.bordered)
        }
        .onAppear { start() }
        .onDisappear { stop() }
    }

    private func start() {
        sample()
        pollingTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { break }
                sample()
            }
        }
    }

    private func stop() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func sample() {
        reading = RAVESystemMonitor.reading(device: device)
        if currentGPU > peakGPU { peakGPU = currentGPU }
    }

    private func optional(_ bytes: Int?) -> String {
        bytes.map(RAVESystemMonitor.format) ?? "—"
    }

    private func thermalLabel(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "Nominal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        @unknown default: "Unknown"
        }
    }

    private func thermalColor(_ state: ProcessInfo.ThermalState) -> Color {
        switch state {
        case .nominal: .green
        case .fair: .yellow
        case .serious: .orange
        case .critical: .red
        @unknown default: .secondary
        }
    }

    private func statBox(_ label: String, _ value: String, tint: Color? = nil) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(.body, design: .monospaced))
                .fontWeight(.medium)
                .foregroundStyle(tint ?? .primary)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// The monitor wrapped in a `NavigationStack` with a title — what a tab or a
/// standalone window wants, as opposed to embedding `RAVESystemMonitorView`
/// bare. Mirrors `RAVEConsoleScreen`.
public struct RAVESystemMonitorScreen: View {
    private let device: (any MTLDevice)?
    private let onClose: (() -> Void)?

    /// - Parameter onClose: shown as a toolbar button when non-nil — see
    ///   `RAVEConsoleScreen`'s parameter of the same name. A screen reached
    ///   through a section switcher rather than a tab bar has no way back
    ///   without one, since the switcher lives in the *other* section's
    ///   chrome, not this one's.
    public init(device: (any MTLDevice)? = nil, onClose: (() -> Void)? = nil) {
        self.device = device
        self.onClose = onClose
    }

    public var body: some View {
        NavigationStack {
            RAVESystemMonitorView(device: device)
                .padding()
                .navigationTitle("System")
                .toolbar {
                    if let onClose {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close", action: onClose)
                        }
                    }
                }
        }
    }
}

#endif
