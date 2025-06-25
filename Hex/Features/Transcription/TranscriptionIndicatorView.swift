//
//  HexCapsuleView.swift
//  Hex
//
//  Created by Kit Langton on 1/25/25.
//

import Pow
import SwiftUI
import Dependencies

struct TranscriptionIndicatorView: View {
  enum Status {
    case hidden
    case optionKeyPressed
    case recording
    case transcribing
    case streamingTranscription
    case prewarming
    case enhancing
  }

  var status: Status
  var meter: Meter
  var recordingProgress: RecordingProgress?
  var enhancementProgress: EnhancementProgress?
  var showRecordingPulse: Bool
  var streamingTranscription: StreamingTranscription?

  let transcribeBaseColor: Color = .blue
  let enhanceBaseColor: Color = .green
  let streamingBaseColor: Color = .orange

  // Access to cleanWhisperTokens for helper methods
  @Dependency(\.transcription) private var transcriptionClient

  private var backgroundColor: Color {
    switch status {
    case .hidden: return Color.clear
    case .optionKeyPressed: return Color.black
    case .recording: return .red.mix(with: .black, by: 0.5).mix(with: .red, by: meter.averagePower * 3)
    case .transcribing: return transcribeBaseColor.mix(with: .black, by: 0.5)
    case .streamingTranscription: return streamingBaseColor.mix(with: .black, by: 0.5)
    case .prewarming: return transcribeBaseColor.mix(with: .black, by: 0.5)
    case .enhancing: return enhanceBaseColor.mix(with: .black, by: 0.5)
    }
  }

  private var strokeColor: Color {
    switch status {
    case .hidden: return Color.clear
    case .optionKeyPressed: return Color.black
    case .recording: return Color.red.mix(with: .white, by: 0.1).opacity(0.6)
    case .transcribing: return transcribeBaseColor.mix(with: .white, by: 0.1).opacity(0.6)
    case .streamingTranscription: return streamingBaseColor.mix(with: .white, by: 0.1).opacity(0.6)
    case .prewarming: return transcribeBaseColor.mix(with: .white, by: 0.1).opacity(0.6)
    case .enhancing: return enhanceBaseColor.mix(with: .white, by: 0.1).opacity(0.6)
    }
  }

  private var innerShadowColor: Color {
    switch status {
    case .hidden: return Color.clear
    case .optionKeyPressed: return Color.clear
    case .recording: return Color.red
    case .transcribing: return transcribeBaseColor
    case .streamingTranscription: return streamingBaseColor
    case .prewarming: return transcribeBaseColor
    case .enhancing: return enhanceBaseColor
    }
  }

  private let cornerRadius: CGFloat = 8
  private let baseWidth: CGFloat = 16
  private let expandedWidth: CGFloat = 56

  var isHidden: Bool {
    status == .hidden
  }

  @State var transcribeEffect = 0
  @State var enhanceEffect = 0

  // Memoize these calculations to prevent recalculating on every render
  private func recordingOpacity(for power: Double, threshold: Double = 0.1) -> Double {
    guard status == .recording else { return 0 }
    return power < threshold ? power / threshold : 1
  }

  // Cache shadow colors based on status and power
  @ViewBuilder
  private func shadowEffect(averagePower: Double) -> some View {
    switch status {
    case .recording:
      EmptyView()
        .shadow(color: .red.opacity(averagePower), radius: 4)
        .shadow(color: .red.opacity(averagePower * 0.5), radius: 8)
    case .streamingTranscription:
      EmptyView()
        .shadow(color: streamingBaseColor.opacity(0.7), radius: 4)
        .shadow(color: streamingBaseColor.opacity(0.4), radius: 8)
    case .enhancing:
      EmptyView()
        .shadow(color: enhanceBaseColor.opacity(0.7), radius: 4)
        .shadow(color: enhanceBaseColor.opacity(0.4), radius: 8)
    case .transcribing, .prewarming:
      EmptyView()
        .shadow(color: transcribeBaseColor.opacity(0.7), radius: 4)
        .shadow(color: transcribeBaseColor.opacity(0.4), radius: 8)
    default:
      EmptyView()
        .shadow(color: .red.opacity(0), radius: 4)
        .shadow(color: .red.opacity(0), radius: 8)
    }
  }

  var body: some View {
    // Fast track hidden state
    if status == .hidden {
      EmptyView()
    } else {
      let averagePower = min(1, meter.averagePower * 3)
      let peakPower     = min(1, meter.peakPower     * 3)

      // Build the reusable capsule w/ overlays once
      let capsule = ZStack {
        CapsuleWithEffects(
          status: status,
          cornerRadius: cornerRadius,
          averagePower: averagePower,
          peakPower: peakPower,
          innerShadowColor: innerShadowColor,
          backgroundColor: backgroundColor,
          strokeColor: strokeColor
        )
        .frame(
          width: status == .recording ? expandedWidth : baseWidth,
          height: baseWidth
        )
        .scaleEffect(status == .optionKeyPressed ? 0.95 : 1)
        .opacity(status == .hidden ? 0 : 1)
        .modifier(LightweightEffects(status: status, enhanceBaseColor: enhanceBaseColor))
        .apply(needsShine: status == .transcribing || status == .enhancing,
               transcribeEffect: transcribeEffect,
               enhanceEffect: enhanceEffect)
        .scaleEffect(showRecordingPulse && status == .recording ? 1.1 : 1.0)
        .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: showRecordingPulse)
        .compositingGroup()

        // Overlays
        if (status == .recording || status == .streamingTranscription), let progress = recordingProgress {
          RecordingProgressOverlay(progress: progress)
        }
        if status == .enhancing, let progress = enhancementProgress {
          EnhancementProgressOverlay(progress: progress)
        }

        // Tooltip overlays positioned above capsule
        if status == .prewarming {
          VStack(spacing: 4) {
            Text("Model prewarming...")
              .font(.system(size: 12, weight: .medium))
              .foregroundColor(.white)
              .padding(.horizontal, 8)
              .padding(.vertical, 4)
              .background(
                RoundedRectangle(cornerRadius: 4)
                  .fill(Color.black.opacity(0.8))
              )
          }
          .offset(y: -24)
          .transition(.opacity)
          .zIndex(2)
        }

        if status == .recording, let progress = recordingProgress {
          RecordingStatusTooltip(progress: progress)
            .offset(y: -32)
            .transition(.opacity)
            .zIndex(2)
        }
      }

      // Layout based on status
      Group {
        switch status {
        case .streamingTranscription:
          if let streaming = streamingTranscription {
            VStack(alignment: .center, spacing: 6) {
              // First row: capsule + waveform + duration inside one StatusBar
              StatusBar {
                capsule
                VoiceWaveView(power: min(1, averagePower * 3))
                  .frame(width: 160, height: 16)
                  .clipShape(RoundedRectangle(cornerRadius: 0))
                Text(durationText(for: streaming))
                  .font(.system(size: 12, weight: .medium))
                  .foregroundColor(.white)
                  .frame(minWidth: 42, alignment: .center)
              }
              // Live transcription text underneath
              Text(displayText(for: streaming))
                .font(.system(size: dynamicFontSize(for: streaming), weight: .medium))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .lineLimit(5)
                .minimumScaleFactor(0.5)
                .frame(maxWidth: 420)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                  RoundedRectangle(cornerRadius: 12)
                    .fill(Color.black.opacity(0.9))
                )
            }
          }
        case .enhancing:
          if let progress = enhancementProgress {
            StatusBar {
              capsule
              Text(progress.message)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white)
            }
          }
        default:
          capsule
        }
      }
      .task(id: status) {
        guard status == .transcribing || status == .enhancing else { return }
        while (status == .transcribing || status == .enhancing), !Task.isCancelled {
          try? await Task.sleep(for: .milliseconds(250))
          if Task.isCancelled { break }
          if status == .transcribing { transcribeEffect += 1 }
          else if status == .enhancing { enhanceEffect += 1 }
          try? await Task.sleep(for: .milliseconds(250))
        }
      }
      .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.7), value: status)
    }
  }

  // Helper methods for streaming text/duration/font size
  private func durationText(for streaming: StreamingTranscription) -> String {
    let start = streaming.startTime ?? Date()
    let seconds = Int(Date().timeIntervalSince(start))
    return "\(seconds)s"
  }

  private func displayText(for streaming: StreamingTranscription) -> String {
    let confirmedText = streaming.confirmedSegments.map(\.text).joined(separator: " ")
    let unconfirmedText = streaming.unconfirmedSegments.map(\.text).joined(separator: " ")
    var parts: [String] = []
    if !confirmedText.isEmpty { parts.append(confirmedText) }
    if !streaming.currentText.isEmpty {
      parts.append(streaming.currentText)
    } else if !unconfirmedText.isEmpty {
      parts.append("\(unconfirmedText)...")
    }
    guard !parts.isEmpty else { return "Listening..." }
    return transcriptionClient.cleanWhisperTokens(parts.joined(separator: " "))
  }

  private func dynamicFontSize(for streaming: StreamingTranscription) -> CGFloat {
    let base: CGFloat = 15
    let length = displayText(for: streaming).count
    switch length {
    case 0..<100:   return base
    case 100..<160: return base - 1
    case 160..<220: return base - 2
    case 220..<280: return base - 3
    case 280..<350: return base - 4
    default:        return max(base - 5, 10)
    }
  }
}

// Optimized view hierarchy to improve performance
struct CapsuleWithEffects: View {
  var status: TranscriptionIndicatorView.Status
  var cornerRadius: CGFloat
  var averagePower: Double
  var peakPower: Double
  var innerShadowColor: Color
  var backgroundColor: Color
  var strokeColor: Color
  
  // Cache calculated values to avoid recalculation
  private let recordingOpacity: Double
  private let whiteOverlayOpacity: Double
  private let peakOverlayOpacity: Double
  private let primaryShadowColor: Color
  private let secondaryShadowColor: Color
  
  // This will help us avoid constant rebuilding of the view
  @ViewBuilder private var innerOverlays: some View {
    if status == .recording {
      RoundedRectangle(cornerRadius: cornerRadius)
        .fill(Color.red.opacity(recordingOpacity))
        .blur(radius: 2)
        .blendMode(.screen)
        .padding(6)
      
      RoundedRectangle(cornerRadius: cornerRadius)
        .fill(Color.white.opacity(whiteOverlayOpacity))
        .blur(radius: 1)
        .blendMode(.screen)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(7)
    }
  }
  
  // Constructor to pre-calculate all values
  init(status: TranscriptionIndicatorView.Status, cornerRadius: CGFloat, averagePower: Double, peakPower: Double, 
       innerShadowColor: Color, backgroundColor: Color, strokeColor: Color) {
    self.status = status
    self.cornerRadius = cornerRadius
    self.averagePower = averagePower
    self.peakPower = peakPower
    self.innerShadowColor = innerShadowColor
    self.backgroundColor = backgroundColor
    self.strokeColor = strokeColor
    
    // Precalculate all values once during initialization
    self.recordingOpacity = status == .recording ? (averagePower < 0.1 ? averagePower / 0.1 : 1) : 0
    self.whiteOverlayOpacity = status == .recording ? (averagePower < 0.1 ? averagePower / 0.1 : 0.5) : 0
    self.peakOverlayOpacity = status == .recording ? (peakPower < 0.1 ? (peakPower / 0.1) * 0.5 : 0.5) : 0
    
    // Precalculate shadow colors
    switch status {
    case .recording:
      self.primaryShadowColor = .red.opacity(averagePower)
      self.secondaryShadowColor = .red.opacity(averagePower * 0.5)
    case .enhancing:
      self.primaryShadowColor = Color.green.opacity(0.7)
      self.secondaryShadowColor = Color.green.opacity(0.4)
    case .transcribing, .prewarming:
      self.primaryShadowColor = Color.blue.opacity(0.7)
      self.secondaryShadowColor = Color.blue.opacity(0.4)
    default:
      self.primaryShadowColor = .red.opacity(0)
      self.secondaryShadowColor = .red.opacity(0)
    }
  }
  
  var body: some View {
    ZStack {
      // Base capsule
      Capsule()
        .fill(backgroundColor.shadow(.inner(color: innerShadowColor, radius: 4)))
      
      // Border capsule
      Capsule()
        .stroke(strokeColor, lineWidth: 1)
        .blendMode(.screen)
      
      // Conditionally add overlays for performance
      innerOverlays
      
      // Only use GeometryReader when in recording mode
      if status == .recording {
        GeometryReader { proxy in
          RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color.red.opacity(peakOverlayOpacity))
            .frame(width: max(proxy.size.width * (peakPower + 0.6), 0), height: proxy.size.height, alignment: .center)
            .frame(maxWidth: .infinity, alignment: .center)
            .blur(radius: 4)
            .blendMode(.screen)
            .padding(6)
        }
      }
    }
    // Apply common modifiers
    .cornerRadius(cornerRadius)
    .shadow(color: primaryShadowColor, radius: 4)
    .shadow(color: secondaryShadowColor, radius: 8)
    .animation(status == .recording ? .interactiveSpring(response: 0.35) : nil, value: averagePower)
  }
}

// Lightweight modifier for effects
struct LightweightEffects: ViewModifier {
  var status: TranscriptionIndicatorView.Status
  var enhanceBaseColor: Color
  
  func body(content: Content) -> some View {
    content.changeEffect(
      .glow(color: status == .enhancing ? enhanceBaseColor.opacity(0.4) : .red.opacity(0.4), radius: 6),
      value: status
    )
  }
}

// Extension to conditionally apply shine effects
extension View {
  @ViewBuilder
  func apply(needsShine: Bool, transcribeEffect: Int, enhanceEffect: Int) -> some View {
    if needsShine {
      self
        .changeEffect(.shine(angle: .degrees(0), duration: 0.8), value: transcribeEffect)
        .changeEffect(.shine(angle: .degrees(0), duration: 0.8), value: enhanceEffect)
    } else {
      self
    }
  }
}

// MARK: - Real-time Feedback Overlays

struct RecordingProgressOverlay: View {
  let progress: RecordingProgress
  
  var body: some View {
    // Simple progress indicator based on recording quality
    Circle()
      .fill(qualityColor.opacity(0.8))
      .frame(width: 3, height: 3)
      .scaleEffect(progress.recordingQuality == .excellent ? 1.5 : 1.0)
      .animation(.easeInOut(duration: 0.5), value: progress.recordingQuality)
  }
  
  private var qualityColor: Color {
    switch progress.recordingQuality {
    case .excellent: return .green
    case .good: return .yellow
    case .poor: return .red
    case .unknown: return .gray
    }
  }
}

struct EnhancementProgressOverlay: View {
  let progress: EnhancementProgress
  
  var body: some View {
    // Animated dots to show AI processing
    HStack(spacing: 2) {
      ForEach(0..<3, id: \.self) { index in
        Circle()
          .fill(Color.white.opacity(0.8))
          .frame(width: 3, height: 3)
          .scaleEffect(animationIndex == index ? 1.3 : 0.8)
          .animation(.easeInOut(duration: 0.6).repeatForever(), value: animationIndex)
      }
    }
    .onAppear {
      withAnimation {
        animationIndex = 0
      }
    }
    .task {
      while !Task.isCancelled {
        for i in 0..<3 {
          animationIndex = i
          try? await Task.sleep(for: .milliseconds(200))
        }
      }
    }
  }
  
  @State private var animationIndex = 0
}

struct RecordingStatusTooltip: View {
  let progress: RecordingProgress
  
  var body: some View {
    VStack(spacing: 2) {
      Text(statusText)
        .font(.system(size: 10, weight: .medium))
        .foregroundColor(.white)
      
      if progress.duration > 0 {
        Text(String(format: "%.1fs", progress.duration))
          .font(.system(size: 9, weight: .regular))
          .foregroundColor(.white.opacity(0.8))
      }
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 3)
    .background(
      RoundedRectangle(cornerRadius: 4)
        .fill(Color.black.opacity(0.8))
    )
  }
  
  private var statusText: String {
    switch progress.recordingQuality {
    case .excellent: return "Excellent"
    case .good: return "Good"
    case .poor: return "Speak up"
    case .unknown: return "Recording..."
    }
  }
}

struct EnhancementStatusTooltip: View {
  let progress: EnhancementProgress
  
  var body: some View {
    StatusBar(backgroundOpacity: 0.8, cornerRadius: 4) {
      Text(progress.message)
        .font(.system(size: 10, weight: .medium))
        .foregroundColor(.white)
    }
  }
}

struct StreamingTranscriptionTooltip: View {
  let streaming: StreamingTranscription
  let averagePower: Double
  
  @Dependency(\.transcription) var transcriptionClient
  @State private var now: Date = Date()
  // Reduced height to make waveform more compact and leave room for overlays
  private let boxSize = CGSize(width: 160, height: 16)
  
  var body: some View {
    VStack(alignment: .center, spacing: 6) {
      // Waveform + duration bar
      StatusBar {
        // Voice waveform visualisation
        VoiceWaveView(power: min(1, averagePower * 3))
          .frame(width: boxSize.width, height: boxSize.height)
          .clipShape(RoundedRectangle(cornerRadius: 0))

        // Elapsed duration label
        Text(durationText)
          .font(.system(size: 12, weight: .medium))
          .foregroundColor(.white)
          .frame(minWidth: 42, alignment: .center)
      }

      // Live transcription text box
      Text(displayText)
        .font(.system(size: dynamicFontSize, weight: .medium))
        .foregroundColor(.white)
        .multilineTextAlignment(.center)
        .lineLimit(5)
        .minimumScaleFactor(0.5)
        .frame(maxWidth: 420)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
          RoundedRectangle(cornerRadius: 12)
            .fill(Color.black.opacity(0.9))
        )
    }
    .task {
      while !Task.isCancelled {
        now = Date()
        try? await Task.sleep(for: .seconds(1))
      }
    }
  }
  
  private var durationText: String {
    guard let start = streaming.startTime else { return "0s" }
    let seconds = Int(now.timeIntervalSince(start))
    return "\(seconds)s"
  }
  
  // Build combined live transcription text similar to previous implementation
  private var displayText: String {
    let confirmedText = streaming.confirmedSegments.map(\.text).joined(separator: " ")
    let unconfirmedText = streaming.unconfirmedSegments.map(\.text).joined(separator: " ")
    
    var parts: [String] = []
    if !confirmedText.isEmpty { parts.append(confirmedText) }
    if !streaming.currentText.isEmpty {
      parts.append(streaming.currentText)
    } else if !unconfirmedText.isEmpty {
      parts.append("\(unconfirmedText)...")
    }
    guard !parts.isEmpty else { return "Listening..." }
    let combined = transcriptionClient.cleanWhisperTokens(parts.joined(separator: " "))
    return combined
  }
  
  private var dynamicFontSize: CGFloat {
    let base: CGFloat = 15
    let length = displayText.count
    switch length {
    case 0..<100:   return base
    case 100..<160: return base - 1
    case 160..<220: return base - 2
    case 220..<280: return base - 3
    case 280..<350: return base - 4
    default:        return max(base - 5, 10)
    }
  }
}

// Dynamic bar waveform view – renders sliding vertical bars whose heights reflect recent mic levels.
struct VoiceWaveView: View {
  /// Normalized average power for the latest frame (0…1)
  var power: Double
  
  /// Rolling history of recent power samples (most-recent last)
  @State private var history: [Double] = []
  private let maxSamples = 40               // number of bars visible
  private let barWidth: CGFloat = 3
  private let spacing: CGFloat = 2

  var body: some View {
    GeometryReader { geo in
      let maxHeight = geo.size.height
      HStack(alignment: .bottom, spacing: spacing) {
        ForEach(history.indices, id: \.self) { idx in
          let value = history[idx]
          Capsule()
            .fill(Color.white.opacity(idx == history.count - 1 ? 0.95 : 0.7))
            .frame(width: barWidth,
                   height: max(2, CGFloat(value) * maxHeight))
        }
      }
      // Right-align so newest bar appears at the far right, sliding older bars left.
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }
    // Push new sample whenever "power" changes.
    .onChange(of: power) { newValue in
      let clamped = max(0, min(newValue, 1))
      history.append(clamped)
      if history.count > maxSamples {
        history.removeFirst(history.count - maxSamples)
      }
    }
    // Smooth linear animation for bar movement.
    .animation(.linear(duration: 0.05), value: history)
  }
}

// MARK: - Shared Status Bar Component

/// A reusable horizontal pill-style status bar with consistent dark background styling.
/// Supply arbitrary content (e.g. progress dots, waveform, time label) and it will
/// automatically apply spacing, padding, and rounded-rectangle background.
struct StatusBar<Content: View>: View {
  var backgroundOpacity: Double = 0.85
  var cornerRadius: CGFloat = 24

  @ViewBuilder var content: Content

  init(backgroundOpacity: Double = 0.85,
       cornerRadius: CGFloat = 24,
       @ViewBuilder content: () -> Content) {
    self.backgroundOpacity = backgroundOpacity
    self.cornerRadius = cornerRadius
    self.content = content()
  }

  var body: some View {
    HStack(spacing: 8) {
      content
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(
      RoundedRectangle(cornerRadius: cornerRadius)
        .fill(Color.black.opacity(backgroundOpacity))
    )
  }
}

#Preview("HEX") {
  VStack(spacing: 8) {
    TranscriptionIndicatorView(
      status: .hidden, 
      meter: .init(averagePower: 0, peakPower: 0), 
      recordingProgress: nil, 
      enhancementProgress: nil, 
      showRecordingPulse: false,
      streamingTranscription: nil
    )
    TranscriptionIndicatorView(
      status: .optionKeyPressed, 
      meter: .init(averagePower: 0, peakPower: 0), 
      recordingProgress: nil, 
      enhancementProgress: nil, 
      showRecordingPulse: false,
      streamingTranscription: nil
    )
    TranscriptionIndicatorView(
      status: .recording, 
      meter: .init(averagePower: 0.5, peakPower: 0.5), 
      recordingProgress: RecordingProgress(), 
      enhancementProgress: nil, 
      showRecordingPulse: true,
      streamingTranscription: nil
    )
    TranscriptionIndicatorView(
      status: .transcribing, 
      meter: .init(averagePower: 0, peakPower: 0), 
      recordingProgress: nil, 
      enhancementProgress: nil, 
      showRecordingPulse: false,
      streamingTranscription: nil
    )
    TranscriptionIndicatorView(
      status: .streamingTranscription, 
      meter: .init(averagePower: 0, peakPower: 0), 
      recordingProgress: nil, 
      enhancementProgress: nil, 
      showRecordingPulse: false,
      streamingTranscription: StreamingTranscription()
    )
    TranscriptionIndicatorView(
      status: .prewarming, 
      meter: .init(averagePower: 0, peakPower: 0), 
      recordingProgress: nil, 
      enhancementProgress: nil, 
      showRecordingPulse: false,
      streamingTranscription: nil
    )
    TranscriptionIndicatorView(
      status: .enhancing, 
      meter: .init(averagePower: 0, peakPower: 0), 
      recordingProgress: nil, 
      enhancementProgress: EnhancementProgress(), 
      showRecordingPulse: false,
      streamingTranscription: nil
    )
  }
  .padding(40)
}