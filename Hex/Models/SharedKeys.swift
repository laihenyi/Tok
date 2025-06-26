import ComposableArchitecture

// Defines a global shared flag that indicates whether the Karaoke feature is currently recording.
// Other parts of the application (e.g. TranscriptionFeature) can consult this value to adjust their behaviour.
extension SharedReaderKey where Self == InMemoryKey<Bool>.Default {
    /// True while KaraokeFeature is actively transcribing (recording), false otherwise.
    static var isKaraokeRecording: Self {
        Self[.inMemory("isKaraokeRecording"), default: false]
    }
} 