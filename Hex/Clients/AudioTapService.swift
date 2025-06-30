import Foundation
import AVFoundation
import AudioToolbox
import CoreAudio
import OSLog
import SwiftUI
import Observation

// Namespace/subsystem identifier for unified logging
let kAppSubsystem = "com.hex.audiotap"

// MARK: - Lightweight Models needed by ProcessTap

/// Represents an audio process (application or the system output) for tap creation.
struct AudioProcess: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case process
        case system
    }
    var id: pid_t
    var kind: Kind = .process
    var name: String
    var objectID: AudioObjectID
    var audioActive: Bool = true
}

/// Convenience constants that mirror the original AudioTap implementation.
enum AudioTarget {
    static let systemWidePID: pid_t = 0
}

// MARK: - ProcessTap

@Observable
final class ProcessTap {
    typealias AudioTapID = AudioObjectID
    typealias InvalidationHandler = (ProcessTap) -> Void

    // Public properties
    let process: AudioProcess
    let muteWhenRunning: Bool

    // Internal State
    private let logger: Logger
    @ObservationIgnored private var processTapID: AudioTapID = .unknown
    @ObservationIgnored private var deviceProcID: AudioDeviceIOProcID?
    @ObservationIgnored private var aggregateDeviceID: AudioObjectID?
    @ObservationIgnored private(set) var tapStreamDescription: AudioStreamBasicDescription?
    @ObservationIgnored private var invalidationHandler: InvalidationHandler?
    @ObservationIgnored private var tapUUID: UUID?
    @ObservationIgnored private(set) var activated = false

    init(process: AudioProcess, muteWhenRunning: Bool = false) {
        self.process = process
        self.muteWhenRunning = muteWhenRunning
        self.logger = Logger(subsystem: kAppSubsystem, category: "ProcessTap(\(process.name))")
    }

    deinit { invalidate() }

    // MARK: Public lifecycle

    func activate() {
        guard !activated else { return }
        activated = true
        logger.debug("Activate tap")

        do {
            try prepare(for: process.objectID)
        } catch {
            logger.error("Failed to prepare tap: \(String(describing: error), privacy: .public)")
        }
    }

    func invalidate() {
        guard activated else { return }
        defer { activated = false }

        logger.debug("Invalidate tap")

        invalidationHandler?(self)
        invalidationHandler = nil

        // Clean up any IOProc or aggregate device
        if let aggregateDeviceID {
            let err = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            if err != noErr {
                logger.warning("Failed to destroy aggregate device: \(err)")
            }
            self.aggregateDeviceID = nil
        }

        if let deviceProcID {
            let err = AudioDeviceDestroyIOProcID(process.objectID, deviceProcID)
            if err != noErr {
                logger.warning("Failed to destroy device IOProc: \(err)")
            }
            self.deviceProcID = nil
        }

        if processTapID.isValid {
            let err = AudioHardwareDestroyProcessTap(processTapID)
            if err != noErr {
                logger.warning("Failed to destroy process tap: \(err)")
            }
            self.processTapID = .unknown
        }
    }

    // MARK: Preparation

    private func prepare(for objectID: AudioObjectID) throws {
        var tapDescription: CATapDescription

        if process.id == AudioTarget.systemWidePID {
            logger.debug("Creating system-wide audio tap (mono global)")
            // Use the dedicated mono-global initialiser so that audio from processes which
            // start *after* the tap has been created is still captured automatically.
            // We currently don't exclude any PIDs, but the array is kept for future use –
            // e.g. to exclude Tok's own UI sounds.
            tapDescription = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        } else {
            logger.debug("Creating process-specific audio tap for objectID: \(objectID)")
            tapDescription = CATapDescription(stereoMixdownOfProcesses: [objectID])
        }

        // Common configuration
        let uuid = UUID()
        tapDescription.uuid = uuid
        tapDescription.muteBehavior = muteWhenRunning ? .mutedWhenTapped : .unmuted
        self.tapUUID = uuid

        // Create the tap
        var tapID: AUAudioObjectID = .unknown
        let err = AudioHardwareCreateProcessTap(tapDescription, &tapID)
        guard err == noErr else {
            throw "Process tap creation failed with error \(err)"
        }

        logger.debug("Created process tap id: \(tapID)")
        self.processTapID = tapID
        self.tapStreamDescription = try tapID.readAudioTapStreamBasicDescription()
    }

    // MARK: Running

    func run(on queue: DispatchQueue,
             ioBlock: @escaping AudioDeviceIOBlock,
             invalidationHandler: @escaping InvalidationHandler) throws {
        assert(activated, "run(on:ioBlock:) called before activate()")
        self.invalidationHandler = invalidationHandler

        if process.id == AudioTarget.systemWidePID {
            // If the tap stream description indicates a low sample rate (e.g. 16 kHz), macOS is
            // delivering down-sampled / silent buffers. In that case, go straight to the aggregate
            // device approach which usually provides full-fidelity audio.
            if let desc = tapStreamDescription, desc.mSampleRate < 20000 {
                logger.debug("Tap stream has low sample-rate (\(desc.mSampleRate)). Using aggregate device.")
                try setupAggregateDeviceForSystemWide(queue: queue, ioBlock: ioBlock)
            } else {
                // Otherwise, try the direct tap first.
                try setupSystemWideTap(queue: queue, ioBlock: ioBlock)
            }
        } else {
            try setupProcessSpecificTap(queue: queue, ioBlock: ioBlock)
        }
    }

    // MARK: Private helpers

    private func setupSystemWideTap(queue: DispatchQueue, ioBlock: @escaping AudioDeviceIOBlock) throws {
        logger.debug("Setting up system-wide tap (direct)")

        // Try to create IOProc directly on the process tap
        let tapDeviceID = processTapID
        var procID: AudioDeviceIOProcID?
        var err = AudioDeviceCreateIOProcIDWithBlock(&procID, tapDeviceID, queue, ioBlock)
        guard err == noErr else {
            logger.warning("Direct system-wide IOProc creation failed: \(err). Falling back to aggregate device.")
            try setupAggregateDeviceForSystemWide(queue: queue, ioBlock: ioBlock)
            return
        }

        err = AudioDeviceStart(tapDeviceID, procID)
        if err != noErr {
            logger.warning("Failed to start IOProc on tap device: \(err). Falling back.")
            if let procID { AudioDeviceDestroyIOProcID(tapDeviceID, procID) }
            try setupAggregateDeviceForSystemWide(queue: queue, ioBlock: ioBlock)
            return
        }

        self.deviceProcID = procID
        logger.info("System-wide audio tap started successfully (direct)")
    }

    private func setupProcessSpecificTap(queue: DispatchQueue, ioBlock: @escaping AudioDeviceIOBlock) throws {
        logger.debug("Setting up process-specific tap via default system output")
        let systemOutputID = try AudioObjectID.readDefaultSystemOutputDevice()
        var procID: AudioDeviceIOProcID?
        let err = AudioDeviceCreateIOProcIDWithBlock(&procID, systemOutputID, queue, ioBlock)
        guard err == noErr else { throw "Failed to create device IOProc: \(err)" }
        let startErr = AudioDeviceStart(systemOutputID, procID)
        guard startErr == noErr else { throw "Failed to start device: \(startErr)" }
        self.deviceProcID = procID
        logger.info("Process-specific audio tap started successfully")
    }

    private func setupAggregateDeviceForSystemWide(queue: DispatchQueue, ioBlock: @escaping AudioDeviceIOBlock) throws {
        logger.debug("Setting up aggregate device fallback for system-wide tap")
        let systemOutputID = try AudioObjectID.readDefaultSystemOutputDevice()
        let outputUID = try systemOutputID.readString(kAudioDevicePropertyDeviceUID)
        let aggregateUID = UUID().uuidString
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "HexSystemAudioTap",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                              kAudioSubTapUIDKey: tapUUID?.uuidString ?? ""]]
        ]

        var aggregateID: AudioObjectID = .unknown
        let aggErr = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID)
        guard aggErr == noErr else { throw "Failed to create aggregate device: \(aggErr)" }
        self.aggregateDeviceID = aggregateID

        var procID: AudioDeviceIOProcID?
        let err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue, ioBlock)
        guard err == noErr else {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            throw "Failed to create IOProc for aggregate device: \(err)"
        }
        let startErr = AudioDeviceStart(aggregateID, procID)
        guard startErr == noErr else {
            if let procID { AudioDeviceDestroyIOProcID(aggregateID, procID) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            throw "Failed to start aggregate device: \(startErr)"
        }
        self.deviceProcID = procID
        logger.info("Aggregate device tap started successfully")
    }
} 