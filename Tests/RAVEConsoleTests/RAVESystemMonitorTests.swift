import Foundation
import Testing
@testable import RAVEConsole

@Suite("System monitor")
struct RAVESystemMonitorTests {

    @Test("The process footprint is readable and plausible")
    func footprint() throws {
        let footprint = try #require(RAVESystemMonitor.processFootprint())
        #expect(footprint > 0)
    }

    @Test("Physical memory is readable and plausible")
    func physicalMemory() {
        #expect(RAVESystemMonitor.physicalMemory() > 0)
    }

    /// macOS has no jetsam-style hard cap, unlike the iOS-family platforms
    /// this also runs on — the guard exists specifically so this never
    /// reports a headroom number that implies a ceiling macOS does not have.
    @Test("Available memory reports nil on macOS")
    func availableMemoryOnMac() {
        #if os(macOS)
        #expect(RAVESystemMonitor.availableMemory() == nil)
        #endif
    }

    @Test("Byte formatting matches what the monitor displays")
    func formatting() {
        #expect(RAVESystemMonitor.format(3 * 1024 * 1024 * 1024).contains("GB"))
        #expect(RAVESystemMonitor.format(512 * 1024 * 1024).contains("MB"))
        // Memory count style, so a GB is 1024³ — a decimal formatter would call
        // this 1.07 GB and every monitor built on this has always shown 1 GB.
        #expect(RAVESystemMonitor.format(1024 * 1024 * 1024).hasPrefix("1 GB"))
    }

    @Test("A gauge fraction needs both a reading and a ceiling")
    func gaugeFraction() throws {
        let reading = RAVESystemReading(gpuAllocated: 512 * 1024 * 1024)
        let fraction = try #require(reading.gpuFraction(of: 1024 * 1024 * 1024))
        #expect(abs(fraction - 0.5) < 1e-9)
        #expect(reading.gpuFraction(of: 0) == nil)
        #expect(RAVESystemReading().gpuFraction(of: 1024) == nil)
    }

    @Test("A default reading answers nothing rather than a misleading zero")
    func defaultReadingIsAllNil() {
        let reading = RAVESystemReading()
        #expect(reading.gpuAllocated == nil)
        #expect(reading.processFootprint == nil)
        #expect(reading.availableMemory == nil)
        #expect(reading.physicalMemory == nil)
        #expect(reading.thermalState == nil)
    }
}
