//
//  RecordingClient.swift
//  Hex
//
//  Created by Kit Langton on 1/24/25.
//

import AppKit // For NSEvent media key simulation
import AVFoundation
import ComposableArchitecture
import CoreAudio
import Dependencies
import DependenciesMacros
import Foundation
import AudioToolbox

/// Represents an audio input device
struct AudioInputDevice: Identifiable, Equatable {
  var id: String
  var name: String
}

/// Represents an audio output device
struct AudioOutputDevice: Identifiable, Equatable {
  var id: String
  var name: String
}

@DependencyClient
struct RecordingClient {
  var startRecording: @Sendable () async -> Void = {}
  var stopRecording: @Sendable () async -> URL = { URL(fileURLWithPath: "") }
  var requestMicrophoneAccess: @Sendable () async -> Bool = { false }
  var observeAudioLevel: @Sendable () async -> AsyncStream<Meter> = { AsyncStream { _ in } }
  var getAvailableInputDevices: @Sendable () async -> [AudioInputDevice] = { [] }
  var getAvailableOutputDevices: @Sendable () async -> [AudioOutputDevice] = { [] }
  var warmUpAudioInput: @Sendable () async -> Void = {}
}

extension RecordingClient: DependencyKey {
  static var liveValue: Self {
    let live = RecordingClientLive()
    return Self(
      startRecording: { await live.startRecording() },
      stopRecording: { await live.stopRecording() },
      requestMicrophoneAccess: { await live.requestMicrophoneAccess() },
      observeAudioLevel: { await live.observeAudioLevel() },
      getAvailableInputDevices: { await live.getAvailableInputDevices() },
      getAvailableOutputDevices: { await live.getAvailableOutputDevices() },
      warmUpAudioInput: { await live.warmUpAudioInput() }
    )
  }
}

/// Simple structure representing audio metering values.
struct Meter: Equatable {
  let averagePower: Double
  let peakPower: Double
}

// Define function pointer types for the MediaRemote functions.
typealias MRNowPlayingIsPlayingFunc = @convention(c) (DispatchQueue, @escaping (Bool) -> Void) -> Void

/// Wraps a few MediaRemote functions.
@Observable
class MediaRemoteController {
  private var mediaRemoteHandle: UnsafeMutableRawPointer?
  private var mrNowPlayingIsPlaying: MRNowPlayingIsPlayingFunc?

  init?() {
    // Open the private framework.
    guard let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW) as UnsafeMutableRawPointer? else {
      print("Unable to open MediaRemote")
      return nil
    }
    mediaRemoteHandle = handle

    // Get pointer for the "is playing" function.
    guard let playingPtr = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying") else {
      print("Unable to find MRMediaRemoteGetNowPlayingApplicationIsPlaying")
      return nil
    }
    mrNowPlayingIsPlaying = unsafeBitCast(playingPtr, to: MRNowPlayingIsPlayingFunc.self)
  }

  deinit {
    if let handle = mediaRemoteHandle {
      dlclose(handle)
    }
  }

  /// Asynchronously refreshes the "is playing" status.
  func isMediaPlaying() async -> Bool {
    await withCheckedContinuation { continuation in
      mrNowPlayingIsPlaying?(DispatchQueue.main) {  isPlaying in
        continuation.resume(returning: isPlaying)
      }
    }
  }
}

// Global instance of MediaRemoteController
private let mediaRemoteController = MediaRemoteController()

func isAudioPlayingOnDefaultOutput() async -> Bool {
  // Refresh the state before checking
  await mediaRemoteController?.isMediaPlaying() ?? false
}

/// Check if an application is installed by looking for its bundle
private func isAppInstalled(bundleID: String) -> Bool {
  let workspace = NSWorkspace.shared
  return workspace.urlForApplication(withBundleIdentifier: bundleID) != nil
}

/// Get a list of installed media player apps we should control
private func getInstalledMediaPlayers() -> [String: String] {
  var result: [String: String] = [:]
  
  if isAppInstalled(bundleID: "com.apple.Music") {
    result["Music"] = "com.apple.Music"
  }
  
  if isAppInstalled(bundleID: "com.apple.iTunes") {
    result["iTunes"] = "com.apple.iTunes"
  }
  
  if isAppInstalled(bundleID: "com.spotify.client") {
    result["Spotify"] = "com.spotify.client"
  }
  
  if isAppInstalled(bundleID: "org.videolan.vlc") {
    result["VLC"] = "org.videolan.vlc"
  }
  
  return result
}

func pauseAllMediaApplications() async -> [String] {
  // First check which media players are actually installed
  let installedPlayers = getInstalledMediaPlayers()
  if installedPlayers.isEmpty {
    return []
  }

  print("Installed media players: \(installedPlayers.keys.joined(separator: ", "))")
  
  // Create AppleScript that only targets installed players
  var scriptParts: [String] = ["set pausedPlayers to {}"]

  for (appName, _) in installedPlayers {
    if appName == "VLC" {
      // VLC has a different AppleScript interface
      scriptParts.append("""
      try
        set appName to "VLC"
        if application appName is running then
          tell application appName to set isVLCplaying to playing
            if isVLCplaying then
              tell application appName to play
              set end of pausedPlayers to appName
            end if
        end if
      end try
      """)
    } else {
      // Standard interface for Music/iTunes/Spotify
      scriptParts.append("""
      try
        set appName to "\(appName)"
        tell application appName
          if it is running and player state is playing then
            pause
            set end of pausedPlayers to appName
          end if
        end tell
      end try
      """)
    }
  }
  
  scriptParts.append("return pausedPlayers")
  let script = scriptParts.joined(separator: "\n\n")
  
  let appleScript = NSAppleScript(source: script)
  var error: NSDictionary?
  guard let resultDescriptor = appleScript?.executeAndReturnError(&error) else {
    if let error = error {
      print("Error pausing media applications: \(error)")
    }
    return []
  }
  
  // Convert AppleScript list to Swift array
  var pausedPlayers: [String] = []
  let count = resultDescriptor.numberOfItems
  
  for i in 0...count {
    if let item = resultDescriptor.atIndex(i)?.stringValue {
      pausedPlayers.append(item)
    }
  }
    
  print("Paused media players: \(pausedPlayers.joined(separator: ", "))")
  
  return pausedPlayers
}

func resumeMediaApplications(_ players: [String]) async {
  guard !players.isEmpty else { return }
  
  // First check which media players are actually installed
  let installedPlayers = getInstalledMediaPlayers()
  
  // Only attempt to resume players that are installed
  let validPlayers = players.filter { installedPlayers.keys.contains($0) }
  if validPlayers.isEmpty {
    return
  }
  
  // Create specific resume script for each player
  var scriptParts: [String] = []
  
  for player in validPlayers {
    if player == "VLC" {
      // VLC has a different AppleScript interface
      scriptParts.append("""
      try
        tell application id "org.videolan.vlc"
          if it is running then
            tell application id "org.videolan.vlc" to play
          end if
        end tell
      end try
      """)
    } else {
      // Standard interface for Music/iTunes/Spotify
      scriptParts.append("""
      try
        if application "\(player)" is running then
          tell application "\(player)" to play
        end if
      end try
      """)
    }
  }
  
  let script = scriptParts.joined(separator: "\n\n")
  
  let appleScript = NSAppleScript(source: script)
  var error: NSDictionary?
  appleScript?.executeAndReturnError(&error)
  if let error = error {
    print("Error resuming media applications: \(error)")
  }
}

/// Simulates a media key press (the Play/Pause key) by posting a system-defined NSEvent.
/// This toggles the state of the active media app.
private func sendMediaKey() {
  let NX_KEYTYPE_PLAY: UInt32 = 16
  func postKeyEvent(down: Bool) {
    let flags: NSEvent.ModifierFlags = down ? .init(rawValue: 0xA00) : .init(rawValue: 0xB00)
    let data1 = Int((NX_KEYTYPE_PLAY << 16) | (down ? 0xA << 8 : 0xB << 8))
    if let event = NSEvent.otherEvent(with: .systemDefined,
                                      location: .zero,
                                      modifierFlags: flags,
                                      timestamp: 0,
                                      windowNumber: 0,
                                      context: nil,
                                      subtype: 8,
                                      data1: data1,
                                      data2: -1)
    {
      event.cgEvent?.post(tap: .cghidEventTap)
    }
  }
  postKeyEvent(down: true)
  postKeyEvent(down: false)
}

// MARK: - RecordingClientLive Implementation

actor RecordingClientLive {
  private var recorder: AVAudioRecorder?
  private let recordingURL = FileManager.default.temporaryDirectory.appendingPathComponent("recording.wav")
  private let (meterStream, meterContinuation) = AsyncStream<Meter>.makeStream()
  private var meterTask: Task<Void, Never>?
  
  // Audio mixing components for input/output mixing
  private var audioEngine: AVAudioEngine?
  private var inputNode: AVAudioInputNode?
  private var outputTap: AVAudioNode?
  private var mixerNode: AVAudioMixerNode?
  private var audioFile: AVAudioFile?
  
  /// Tracks the current recording state to prevent overlapping operations
  private var isRecording: Bool = false
    
  @Shared(.hexSettings) var hexSettings: HexSettings

  /// Tracks whether media was paused using the media key when recording started.
  private var didPauseMedia: Bool = false
  
  /// Tracks which specific media players were paused
  private var pausedPlayers: [String] = []
  
  // Cache to store already-processed device information
  private var deviceCache: [AudioDeviceID: (hasInput: Bool, name: String?, hasOutput: Bool?)] = [:]
  private var lastDeviceCheck = Date(timeIntervalSince1970: 0)
  
  // System-audio capture helpers
  private var systemAudioEngine: AVAudioEngine?
  private var systemAudioPlayerNode: AVAudioPlayerNode?
  
  // ProcessTap for capturing system-wide audio
  private var processTap: ProcessTap?
  private var tapQueue: DispatchQueue?
  
  /// Gets all available output devices on the system
  func getAvailableOutputDevices() async -> [AudioOutputDevice] {
    // Reset cache if it's been more than 5 minutes since last full refresh
    let now = Date()
    if now.timeIntervalSince(lastDeviceCheck) > 300 {
      deviceCache.removeAll()
      lastDeviceCheck = now
    }
    
    // Get all available audio devices
    let devices = getAllAudioDevices()
    var outputDevices: [AudioOutputDevice] = []
    
    // Filter to only output devices and convert to our model
    for device in devices {
      let hasOutput: Bool
      let name: String?
      
      // Check cache first to avoid expensive Core Audio calls
      if let cached = deviceCache[device] {
        hasOutput = cached.hasOutput ?? false
        name = cached.name
      } else {
        hasOutput = deviceHasOutput(deviceID: device)
        name = hasOutput ? getDeviceName(deviceID: device) : nil
        deviceCache[device] = (hasInput: deviceCache[device]?.hasInput ?? false, name: name, hasOutput: hasOutput)
      }
      
      if hasOutput, let deviceName = name {
        outputDevices.append(AudioOutputDevice(id: String(device), name: deviceName))
      }
    }
    
    return outputDevices
  }

  /// Gets all available input devices on the system
  func getAvailableInputDevices() async -> [AudioInputDevice] {
    // Reset cache if it's been more than 5 minutes since last full refresh
    let now = Date()
    if now.timeIntervalSince(lastDeviceCheck) > 300 {
      deviceCache.removeAll()
      lastDeviceCheck = now
    }
    
    // Get all available audio devices
    let devices = getAllAudioDevices()
    var inputDevices: [AudioInputDevice] = []
    
    // Filter to only input devices and convert to our model
    for device in devices {
      let hasInput: Bool
      let name: String?
      
      // Check cache first to avoid expensive Core Audio calls
      if let cached = deviceCache[device] {
        hasInput = cached.hasInput
        name = cached.name
      } else {
        hasInput = deviceHasInput(deviceID: device)
        name = hasInput ? getDeviceName(deviceID: device) : nil
        deviceCache[device] = (hasInput, name, nil)
      }
      
      if hasInput, let deviceName = name {
        inputDevices.append(AudioInputDevice(id: String(device), name: deviceName))
      }
    }
    
    return inputDevices
  }
  
  // MARK: - Core Audio Helpers
  
  /// Get all available audio devices
  private func getAllAudioDevices() -> [AudioDeviceID] {
    var propertySize: UInt32 = 0
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    
    // Get the property data size
    var status = AudioObjectGetPropertyDataSize(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      0,
      nil,
      &propertySize
    )
    
    if status != 0 {
      print("Error getting audio devices property size: \(status)")
      return []
    }
    
    // Calculate device count
    let deviceCount = Int(propertySize) / MemoryLayout<AudioDeviceID>.size
    var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
    
    // Get the device IDs
    status = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      0,
      nil,
      &propertySize,
      &deviceIDs
    )
    
    if status != 0 {
      print("Error getting audio devices: \(status)")
      return []
    }
    
    return deviceIDs
  }
  
  /// Get device name for the given device ID
  private func getDeviceName(deviceID: AudioDeviceID) -> String? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyDeviceNameCFString,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    
    var deviceName: CFString? = nil
    var size = UInt32(MemoryLayout<CFString?>.size)
    let deviceNamePtr = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<CFString?>.alignment)
    defer { deviceNamePtr.deallocate() }
    
    let status = AudioObjectGetPropertyData(
      deviceID,
      &address,
      0,
      nil,
      &size,
      deviceNamePtr
    )
    
    if status == 0 {
        deviceName = deviceNamePtr.load(as: CFString?.self)
    }
    
    if status != 0 {
      print("Error getting device name: \(status)")
      return nil
    }
    
    return deviceName as String?
  }
  
  /// Check if device has input capabilities
  private func deviceHasInput(deviceID: AudioDeviceID) -> Bool {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreamConfiguration,
      mScope: kAudioDevicePropertyScopeInput,
      mElement: kAudioObjectPropertyElementMain
    )
    
    var propertySize: UInt32 = 0
    let status = AudioObjectGetPropertyDataSize(
      deviceID,
      &address,
      0,
      nil,
      &propertySize
    )
    
    if status != 0 {
      return false
    }
    
    let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(propertySize))
    defer { bufferList.deallocate() }
    
    let getStatus = AudioObjectGetPropertyData(
      deviceID,
      &address,
      0,
      nil,
      &propertySize,
      bufferList
    )
    
    if getStatus != 0 {
      return false
    }
    
    // Check if we have any input channels
    let buffersPointer = UnsafeMutableAudioBufferListPointer(bufferList)
    return buffersPointer.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
  }
  
  /// Check if device has output capabilities
  private func deviceHasOutput(deviceID: AudioDeviceID) -> Bool {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreamConfiguration,
      mScope: kAudioDevicePropertyScopeOutput,
      mElement: kAudioObjectPropertyElementMain
    )
    
    var propertySize: UInt32 = 0
    let status = AudioObjectGetPropertyDataSize(
      deviceID,
      &address,
      0,
      nil,
      &propertySize
    )
    
    if status != 0 {
      return false
    }
    
    let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(propertySize))
    defer { bufferList.deallocate() }
    
    let getStatus = AudioObjectGetPropertyData(
      deviceID,
      &address,
      0,
      nil,
      &propertySize,
      bufferList
    )
    
    if getStatus != 0 {
      return false
    }
    
    // Check if we have any output channels
    let buffersPointer = UnsafeMutableAudioBufferListPointer(bufferList)
    return buffersPointer.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
  }
  
  /// Set device as the default input device
  private func setInputDevice(deviceID: AudioDeviceID) {
    var device = deviceID
    let size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultInputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    
    let status = AudioObjectSetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      0,
      nil,
      size,
      &device
    )
    
    if status != 0 {
      print("Error setting default input device: \(status)")
    } else {
      print("Successfully set input device to: \(deviceID)")
    }
  }

  func requestMicrophoneAccess() async -> Bool {
    await AVCaptureDevice.requestAccess(for: .audio)
  }

  func warmUpAudioInput() async {
    let warmupStart = Date()
    print("🎙️ [TIMING] Audio input warmup started at: \(warmupStart.timeIntervalSince1970)")

    do {
      // Create a temporary recorder to warm up the audio input device
      // Note: On macOS, AVAudioSession is not available, so we skip session setup
      let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("warmup.wav")
      let settings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatLinearPCM),
        AVSampleRateKey: 16000.0,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
      ]

      let tempRecorder = try AVAudioRecorder(url: tempURL, settings: settings)
      tempRecorder.prepareToRecord()

      // Start recording briefly to warm up the audio input device
      tempRecorder.record()

      // Record for a very short time (100ms) to warm up the device
      try await Task.sleep(for: .milliseconds(100))

      tempRecorder.stop()

      // Clean up the temporary file
      try? FileManager.default.removeItem(at: tempURL)

      let warmupEnd = Date()
      let warmupDuration = warmupEnd.timeIntervalSince(warmupStart)
      print("🎙️ [TIMING] Audio input warmup completed in: \(String(format: "%.3f", warmupDuration))s")
    } catch {
      print("🎙️ [WARNING] Audio input warmup failed: \(error)")
    }
  }

  func startRecording() async {
    // Guard against starting a new recording while one is already in progress
    guard !isRecording else {
      print("🎙️ [WARNING] Recording start ignored - recording already in progress")
      return
    }
    
    // Check if audio mixing is enabled
    if hexSettings.enableAudioMixing {
      await startMixedRecording()
    } else {
      await startSimpleRecording()
    }
  }
  
  /// Start recording with audio mixing (input + output)
  private func startMixedRecording() async {
    let startTime = Date()
    print("🎙️ [TIMING] Mixed recording start requested at: \(startTime.timeIntervalSince1970)")
    
    // Mark that we're starting a recording
    isRecording = true
    
    do {
      // Initialize audio engine
      audioEngine = AVAudioEngine()
      guard let engine = audioEngine else { 
        print("🎙️ [ERROR] Failed to create audio engine")
        isRecording = false
        return 
      }
      
      // Get input node
      inputNode = engine.inputNode
      guard let input = inputNode else {
        print("🎙️ [ERROR] Failed to get input node")
        isRecording = false
        return
      }
      
      // Create mixer node for combining input and output
      mixerNode = AVAudioMixerNode()
      guard let mixer = mixerNode else {
        print("🎙️ [ERROR] Failed to create mixer node")
        isRecording = false
        return
      }
      
      engine.attach(mixer)
      
      // -------------------------------------------------------------
      // Microphone input -> mixer with adjustable gain
      // -------------------------------------------------------------
      // We'll decide final recording format once we know the system audio's format.
      var recordingFormat = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
      let inputFormat = input.inputFormat(forBus: 0)

      let inputGain = Float(hexSettings.audioMixingInputGain)
      let inputGainNode = AVAudioMixerNode()
      engine.attach(inputGainNode)
      inputGainNode.outputVolume = inputGain

      engine.connect(input, to: inputGainNode, format: inputFormat)
      engine.connect(inputGainNode, to: mixer, format: inputFormat)
      
      // -----------------------------------------------------------------------------
      // System-audio ("what you hear") capture using ProcessTap
      // -----------------------------------------------------------------------------
      if hexSettings.enableAudioMixing {
        // Player node that will *feed* the captured buffers into our main mixer (silent – no playback).
        let systemPlayerNode = AVAudioPlayerNode()
        self.systemAudioPlayerNode = systemPlayerNode
        engine.attach(systemPlayerNode)

        // Create system-wide ProcessTap
        let systemProcess = AudioProcess(
          id: AudioTarget.systemWidePID,
          kind: .system,
          name: "System",
          objectID: AudioObjectID(kAudioObjectSystemObject),
          audioActive: true
        )

        let tap = ProcessTap(process: systemProcess)
        self.processTap = tap
        await MainActor.run { tap.activate() }

        guard var streamDesc = tap.tapStreamDescription else {
          print("🎙️ [ERROR] No stream description from ProcessTap")
          return
        }
        print("🎙️ [DEBUG] ProcessTap stream desc: mSampleRate=\(streamDesc.mSampleRate), channels=\(streamDesc.mChannelsPerFrame), bytesPerFrame=\(streamDesc.mBytesPerFrame)")

        let sysFormat = AVAudioFormat(streamDescription: &streamDesc)!
        // Adopt system audio's sample rate for our recording format to avoid costly real-time resampling by AVAudioEngine.
        recordingFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                       sampleRate: sysFormat.sampleRate,
                                       channels: 2,
                                       interleaved: false)!

        // Connect player node to mixer letting AVAudioEngine negotiate format conversion
        engine.connect(systemPlayerNode, to: mixer, format: nil)
        systemPlayerNode.play()

        // Dispatch queue for the tap callback
        let queue = DispatchQueue(label: "HexSystemAudioTapQueue")
        self.tapQueue = queue

        let playerCapture = systemPlayerNode
        do {
          try tap.run(on: queue, ioBlock: { (now: UnsafePointer<AudioTimeStamp>, inputData: UnsafePointer<AudioBufferList>, inputTime: UnsafePointer<AudioTimeStamp>, outputData: UnsafeMutablePointer<AudioBufferList>?, outputTime: UnsafePointer<AudioTimeStamp>) in
            let player = playerCapture

            // Convert AudioBufferList -> AVAudioPCMBuffer
            let ablPointer = UnsafeMutablePointer<AudioBufferList>(mutating: inputData)
            let srcBuffers = UnsafeMutableAudioBufferListPointer(ablPointer)

            guard srcBuffers.count > 0 else { return }

            let bytesPerFrame = Int(streamDesc.mBytesPerFrame)
            let frameCount = Int(srcBuffers[0].mDataByteSize) / bytesPerFrame

            // Calculate RMS of system audio buffer to see if it has signal
            var rms: Float = 0
            if let firstBuffer = srcBuffers.first, let data = firstBuffer.mData {
              if streamDesc.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
                let samples = data.bindMemory(to: Float.self, capacity: frameCount)
                var sumSquares: Float = 0
                for i in 0..<frameCount {
                  let s = samples[i]
                  sumSquares += s * s
                }
                rms = sqrt(sumSquares / Float(frameCount))
              } else if streamDesc.mBitsPerChannel == 16 {
                let samples = data.bindMemory(to: Int16.self, capacity: frameCount)
                var sumSquares: Float = 0
                for i in 0..<frameCount {
                  let s = Float(samples[i]) / 32768.0
                  sumSquares += s * s
                }
                rms = sqrt(sumSquares / Float(frameCount))
              } else if streamDesc.mBitsPerChannel == 32 {
                let samples = data.bindMemory(to: Int32.self, capacity: frameCount)
                var sumSquares: Float = 0
                for i in 0..<frameCount {
                  let s = Float(samples[i]) / 2147483648.0
                  sumSquares += s * s
                }
                rms = sqrt(sumSquares / Float(frameCount))
              }
            }
            print("🎙️ [DEBUG] ProcessTap delivered \(frameCount) frames (sys audio), rms=\(rms)")

            guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: sysFormat, frameCapacity: AVAudioFrameCount(frameCount)) else { return }
            pcmBuffer.frameLength = AVAudioFrameCount(frameCount)

            let dstBuffers = UnsafeMutableAudioBufferListPointer(pcmBuffer.mutableAudioBufferList)

            for channel in 0..<srcBuffers.count {
              let src = srcBuffers[channel]
              let dst = dstBuffers[channel]
              if let srcData = src.mData, let dstData = dst.mData {
                memcpy(dstData, srcData, Int(src.mDataByteSize))
              }
            }

            // Feed buffer to player node as-is; engine will handle any format conversion.
            player.scheduleBuffer(pcmBuffer, at: nil, options: .interrupts, completionHandler: nil)
          }, invalidationHandler: { [weak self] tap in
            Task { [weak self] in
              await self?.stopSystemTapDueToInvalidation()
            }
          })
          print("🎙️ [DEBUG] ProcessTap.run successfully started")
        } catch {
          print("🎙️ [ERROR] Failed to start ProcessTap: \(error)")
        }
      }
      
      // Set up recording file
      let audioFile = try AVAudioFile(forWriting: recordingURL, settings: recordingFormat.settings)
      self.audioFile = audioFile
      
      // Install tap on mixer to record mixed audio
      mixer.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, time in
        do {
          let frameLen = Int(buffer.frameLength)
          var rmsMix: Float = 0
          if let data = buffer.floatChannelData?.pointee {
            var sum: Float = 0
            for i in 0..<frameLen { sum += data[i]*data[i] }
            rmsMix = sqrt(sum / Float(frameLen))
          }
          print("🎙️ [DEBUG] Mixer tap received buffer with \(frameLen) frames, rms=\(rmsMix)")
          try audioFile.write(from: buffer)
          
          // Calculate audio levels for metering
          let channelData = buffer.floatChannelData?[0]
          let frameLength = Int(buffer.frameLength)
          
          if let data = channelData, frameLength > 0 {
            var sum: Float = 0
            var peak: Float = 0
            
            for i in 0..<frameLength {
              let sample = abs(data[i])
              sum += sample * sample
              peak = max(peak, sample)
            }
            
            let averagePower = sqrt(sum / Float(frameLength))
            let meter = Meter(averagePower: Double(averagePower), peakPower: Double(peak))
            
            Task { @MainActor in
              self?.meterContinuation.yield(meter)
            }
          }
        } catch {
          print("🎙️ [ERROR] Failed to write audio buffer: \(error)")
        }
      }
      
      // NOTE: Do NOT route the mixed audio back to the system output.  We only need the tap on the
      // mixer for recording, so we intentionally avoid connecting the mixer to the engine's
      // main output.  This prevents the microphone signal from being played back through the
      // user's speakers / headset while still allowing the engine to pull audio for the tap.
      // NOTE: We still need the engine to **pull** audio through the graph.  The most reliable
      // way to do that without creating audible feedback is to connect our mixer to the
      // engine's main mixer and mute its output.  This keeps the signal silent for the user
      // while ensuring the tap installed on the mixer receives filled buffers.
      mixer.outputVolume = 1.0 // keep audible signal for tap
      engine.connect(mixer, to: engine.mainMixerNode, format: nil)
      // Mute app playback to avoid feedback while leaving recording intact
      engine.mainMixerNode.outputVolume = 0.0
      
      // Start the audio engine
      try engine.start()
      
      print("🎙️ [DEBUG] Audio engine started. isRunning=\(engine.isRunning)")
      
      let totalDuration = Date().timeIntervalSince(startTime)
      print("🎙️ [TIMING] Total mixed recording start duration: \(String(format: "%.3f", totalDuration))s")
      print("Mixed recording started.")
      
    } catch {
      print("🎙️ [ERROR] Could not start mixed recording: \(error)")
      await stopMixedRecording()
      isRecording = false
    }
  }
  
  /// Start simple recording (microphone only)
  private func startSimpleRecording() async {
    
    let startTime = Date()
    print("🎙️ [TIMING] Recording start requested at: \(startTime.timeIntervalSince1970)")

    // Mark that we're starting a recording
    isRecording = true

    // If audio is playing on the default output, pause it.
    if hexSettings.pauseMediaOnRecord {
      let mediaPauseStart = Date()
      print("🎙️ [TIMING] Starting media pause check at: \(mediaPauseStart.timeIntervalSince1970)")

      // First, pause all media applications using their AppleScript interface.
      pausedPlayers = await pauseAllMediaApplications()
      // If no specific players were paused, pause generic media using the media key.
      if pausedPlayers.isEmpty {
        if await isAudioPlayingOnDefaultOutput() {
          print("Audio is playing on the default output; pausing it for recording.")
          await MainActor.run {
            sendMediaKey()
          }
          didPauseMedia = true
          print("Media was playing; pausing it for recording.")
        }
      } else {
        print("Paused media players: \(pausedPlayers.joined(separator: ", "))")
      }

      let mediaPauseEnd = Date()
      let mediaPauseDuration = mediaPauseEnd.timeIntervalSince(mediaPauseStart)
      print("🎙️ [TIMING] Media pause completed in: \(String(format: "%.3f", mediaPauseDuration))s")
    }

    // If user has selected a specific microphone, verify it exists and set it as the default input device
    let deviceSetupStart = Date()
    print("🎙️ [TIMING] Starting device setup at: \(deviceSetupStart.timeIntervalSince1970)")

    if let selectedDeviceIDString = hexSettings.selectedMicrophoneID,
       let selectedDeviceID = AudioDeviceID(selectedDeviceIDString) {
      // Check if the selected device is still available
      let devices = getAllAudioDevices()
      if devices.contains(selectedDeviceID) && deviceHasInput(deviceID: selectedDeviceID) {
        print("Setting selected input device: \(selectedDeviceID)")
        setInputDevice(deviceID: selectedDeviceID)
      } else {
        // Device no longer available, fall back to system default
        print("Selected device \(selectedDeviceID) is no longer available, using system default")
      }
    } else {
      print("Using default system microphone")
    }

    let deviceSetupEnd = Date()
    let deviceSetupDuration = deviceSetupEnd.timeIntervalSince(deviceSetupStart)
    print("🎙️ [TIMING] Device setup completed in: \(String(format: "%.3f", deviceSetupDuration))s")

    let recorderSetupStart = Date()
    print("🎙️ [TIMING] Starting AVAudioRecorder setup at: \(recorderSetupStart.timeIntervalSince1970)")

    // Note: AVAudioSession is not available on macOS, so we skip audio session setup

    let settings: [String: Any] = [
      AVFormatIDKey: Int(kAudioFormatLinearPCM),
      AVSampleRateKey: 16000.0,
      AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 32,
      AVLinearPCMIsFloatKey: true,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false,
    ]

    do {
      let recorderInitStart = Date()
      recorder = try AVAudioRecorder(url: recordingURL, settings: settings)
      let recorderInitEnd = Date()
      let recorderInitDuration = recorderInitEnd.timeIntervalSince(recorderInitStart)
      print("🎙️ [TIMING] AVAudioRecorder init completed in: \(String(format: "%.3f", recorderInitDuration))s")

      let meteringSetupStart = Date()
      recorder?.isMeteringEnabled = true
      let meteringSetupEnd = Date()
      let meteringSetupDuration = meteringSetupEnd.timeIntervalSince(meteringSetupStart)
      print("🎙️ [TIMING] Metering enabled in: \(String(format: "%.3f", meteringSetupDuration))s")

      // Prepare the recorder to warm up the audio input device
      let prepareStart = Date()
      recorder?.prepareToRecord()
      let prepareEnd = Date()
      let prepareDuration = prepareEnd.timeIntervalSince(prepareStart)
      print("🎙️ [TIMING] prepareToRecord() completed in: \(String(format: "%.3f", prepareDuration))s")

      let recordStart = Date()
      print("🎙️ [TIMING] Calling recorder.record() at: \(recordStart.timeIntervalSince1970)")
      recorder?.record()
      let recordEnd = Date()
      let recordDuration = recordEnd.timeIntervalSince(recordStart)
      print("🎙️ [TIMING] recorder.record() completed in: \(String(format: "%.3f", recordDuration))s")

      let meterTaskStart = Date()
      startMeterTask()
      let meterTaskEnd = Date()
      let meterTaskDuration = meterTaskEnd.timeIntervalSince(meterTaskStart)
      print("🎙️ [TIMING] Meter task started in: \(String(format: "%.3f", meterTaskDuration))s")

      let totalDuration = Date().timeIntervalSince(startTime)
      print("🎙️ [TIMING] Total recording start duration: \(String(format: "%.3f", totalDuration))s")
      print("Recording started.")

      // Pause any playing media *after* the microphone is already recording to avoid delaying capture startup.
      if hexSettings.pauseMediaOnRecord {
        let mediaPauseStart = Date()
        print("🎙️ [TIMING] Starting media pause check (post-record start) at: \(mediaPauseStart.timeIntervalSince1970)")

        // First, pause all media applications using their AppleScript interface.
        pausedPlayers = await pauseAllMediaApplications()
        // If no specific players were paused, pause generic media using the media key.
        if pausedPlayers.isEmpty {
          if await isAudioPlayingOnDefaultOutput() {
            print("Audio is playing on the default output; pausing it for recording.")
            await MainActor.run { sendMediaKey() }
            didPauseMedia = true
            print("Media was playing; pausing it for recording.")
          }
        } else {
          print("Paused media players: \(pausedPlayers.joined(separator: ", "))")
        }

        let mediaPauseEnd = Date()
        let mediaPauseDuration = mediaPauseEnd.timeIntervalSince(mediaPauseStart)
        print("🎙️ [TIMING] Media pause completed in: \(String(format: "%.3f", mediaPauseDuration))s")
      }
    } catch {
      print("Could not start recording: \(error)")
      // Reset recording state if we failed to start
      isRecording = false
    }
  }

  func stopRecording() async -> URL {
    // Guard against multiple stop calls
    guard isRecording else {
      print("🎙️ [WARNING] Stop recording ignored - no recording in progress")
      return recordingURL
    }
    
    // Mark that we're no longer recording
    isRecording = false
    
    // Stop based on recording mode
    if hexSettings.enableAudioMixing {
      await stopMixedRecording()
    } else {
      recorder?.stop()
      recorder = nil
      stopMeterTask()
    }
    
    print("Recording stopped.")

    // Resume media if we previously paused specific players
    if !pausedPlayers.isEmpty {
      print("Resuming previously paused players: \(pausedPlayers.joined(separator: ", "))")
      await resumeMediaApplications(pausedPlayers)
      pausedPlayers = []
    }
    // Resume generic media if we paused it with the media key
    else if didPauseMedia {
      await MainActor.run {
        sendMediaKey()
      }
      didPauseMedia = false
      print("Resuming previously paused media.")
    }
    return recordingURL
  }
  
  /// Stop mixed recording and clean up audio engine
  private func stopMixedRecording() async {
    // Remove tap from mixer if it exists
    if let mixer = mixerNode {
      mixer.removeTap(onBus: 0)
    }
    
    // Stop and reset audio engine
    audioEngine?.stop()
    audioEngine?.reset()
    audioEngine = nil
    
    // Invalidate ProcessTap if active
    processTap?.invalidate()
    processTap = nil
    tapQueue = nil

    // Release player node
    systemAudioPlayerNode = nil
    
    // Clean up nodes
    inputNode = nil
    outputTap = nil
    mixerNode = nil
    
    // Close audio file
    audioFile = nil
    
    print("Mixed recording stopped and cleaned up.")
  }

  func startMeterTask() {
    meterTask = Task {
      let meterTaskStart = Date()
      print("🎙️ [TIMING] Meter task started at: \(meterTaskStart.timeIntervalSince1970)")

      var lastMeter = Meter(averagePower: 0, peakPower: 0)
      var updateCount = 0
      var lastUpdateTime = Date()
      var firstAudioDetected = false

      // Use lower sampling rates when there's less activity
      var inactiveCount = 0
      var samplingInterval: Duration = .milliseconds(100) // Start with default

      while !Task.isCancelled, let r = self.recorder, r.isRecording {
        r.updateMeters()
        let averagePower = r.averagePower(forChannel: 0)
        let averageNormalized = pow(10, averagePower / 20.0)
        let peakPower = r.peakPower(forChannel: 0)
        let peakNormalized = pow(10, peakPower / 20.0)
        let currentMeter = Meter(averagePower: Double(averageNormalized), peakPower: Double(peakNormalized))

        // Track when we first detect meaningful audio input
        if !firstAudioDetected && (averageNormalized > 0.01 || peakNormalized > 0.01) {
          let firstAudioTime = Date()
          let timeToFirstAudio = firstAudioTime.timeIntervalSince(meterTaskStart)
          print("🎙️ [TIMING] First audio detected after: \(String(format: "%.3f", timeToFirstAudio))s (avg: \(String(format: "%.4f", averageNormalized)), peak: \(String(format: "%.4f", peakNormalized)))")
          firstAudioDetected = true
        }

        // Determine threshold for significant change (adaptive based on current levels)
        let averageThreshold = max(0.05, lastMeter.averagePower * 0.15) // More sensitive at low levels
        let peakThreshold = max(0.1, lastMeter.peakPower * 0.15)

        // Check if there's a significant change
        let significantChange = abs(currentMeter.averagePower - lastMeter.averagePower) > averageThreshold ||
                               abs(currentMeter.peakPower - lastMeter.peakPower) > peakThreshold

        // Force update if too much time has passed (prevents UI from appearing frozen)
        let timeSinceLastUpdate = Date().timeIntervalSince(lastUpdateTime)
        let forceUpdate = timeSinceLastUpdate > 0.3 // Max 300ms between updates for smooth UI

        // Adaptive sampling rate based on activity level
        if significantChange {
          inactiveCount = 0
          samplingInterval = .milliseconds(80) // Faster sampling during active periods
        } else {
          inactiveCount += 1
          if inactiveCount > 10 {
            // Gradually increase sampling interval during periods of low activity
            samplingInterval = .milliseconds(min(150, 80 + inactiveCount * 5))
          }
        }

        if significantChange || forceUpdate || updateCount >= 3 {
          meterContinuation.yield(currentMeter)
          lastMeter = currentMeter
          lastUpdateTime = Date()
          updateCount = 0
        } else {
          updateCount += 1
        }

        try? await Task.sleep(for: samplingInterval)
      }
    }
  }

  func stopMeterTask() {
    meterTask?.cancel()
    meterTask = nil
  }

  func observeAudioLevel() -> AsyncStream<Meter> {
    meterStream
  }

  private func stopSystemTapDueToInvalidation() {
    processTap = nil
    print("🎙️ ProcessTap invalidated")
  }
}

extension DependencyValues {
  var recording: RecordingClient {
    get { self[RecordingClient.self] }
    set { self[RecordingClient.self] = newValue }
  }
}
