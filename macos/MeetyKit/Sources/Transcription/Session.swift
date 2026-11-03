import Audio
import Core
import Foundation
import Synchronization

/// A started, pull-based 48 kHz mono capture. `drain()` is called from one consumer.
public protocol AudioSource: AnyObject, Sendable {
    func drain() -> [Float]
    func stop()
    var droppedSamples: Int { get }
}

extension MicrophoneCapture: AudioSource {}
extension SystemAudioCapture: AudioSource {}

/// Plays back samples as a capture would, `chunk` samples per drain (tests, profiling runs).
public final class SampleSource: AudioSource {
    private let state: Mutex<(samples: [Float], position: Int)>
    private let chunk: Int

    public init(samples: [Float], chunk: Int = 960) {
        state = Mutex((samples, 0))
        self.chunk = chunk
    }

    public var isFinished: Bool { state.withLock { $0.position >= $0.samples.count } }
    public var droppedSamples: Int { 0 }
    public func stop() {}

    public func drain() -> [Float] {
        state.withLock { s in
            let end = min(s.position + chunk, s.samples.count)
            defer { s.position = end }
            return Array(s.samples[s.position..<end])
        }
    }
}

/// One transcript line as it appears live; `sequence` orders lines and keys `transcripts.json`.
public struct LiveSegment: Sendable, Hashable {
    public var sequence: Int
    public var text: String
    public var start: Double
    public var end: Double
}

/// Live recording: capture → mic DSP → mixer → `RecordingWriter`, and in parallel the mixed audio
/// → 16 kHz → VAD → one serial ASR queue → segments (writer JSON, `events`, and the DB on stop).
/// Times are seconds of recorded audio, so pauses (which are cut from the file) don't shift them.
public actor RecordingSession {
    public enum Event: Sendable, Equatable {
        case segment(LiveSegment)
        /// Dropped audio or a transcription falling behind or failing; the recording continues.
        case warning(String)
        /// Stop finished and the meeting row exists.
        case saved(String)
    }

    public nonisolated let events: AsyncStream<Event>
    /// Latest block levels for meters (read at display rate, never queued).
    public nonisolated let levels = Mutex((microphone: AudioLevel.silent, system: AudioLevel.silent))

    private let eventSink: AsyncStream<Event>.Continuation
    private let title: String
    private let store: Store
    private let engine: any TranscriptionEngine
    private let microphone: (any AudioSource)?
    private let system: (any AudioSource)?
    private let writer: RecordingWriter
    private let backlogWarning: Double
    private var dsp = MicrophoneDSP()
    private var mixer = AudioMixer()
    private let resampler: Resampler
    private var segmenter: SpeechSegmenter
    private let speech: AsyncStream<SpeechChunk>.Continuation
    private let speechChunks: AsyncStream<SpeechChunk>
    private var asr: Task<Void, Never>?
    private var poll: Task<Void, Never>?
    private var paused = false
    private var segments: [LiveSegment] = []
    private var backlog = 0.0
    private var warnedBacklog = false
    private var dropped = 0

    public init(title: String, folder: URL, store: Store, engine: any TranscriptionEngine, detector: any VoiceDetector,
                microphone: (any AudioSource)?, system: (any AudioSource)?,
                microphoneName: String? = nil, systemName: String? = nil, backlogWarning: Double = 60) throws {
        self.title = title
        self.store = store
        self.engine = engine
        self.microphone = microphone
        self.system = system
        self.backlogWarning = backlogWarning
        writer = try RecordingWriter(folder: folder, meetingName: title, microphone: microphoneName, systemAudio: systemName)
        resampler = try Resampler(from: RecordingWriter.sampleRate, to: transcriptionSampleRate)
        segmenter = SpeechSegmenter(detector: detector, config: .live)
        (events, eventSink) = AsyncStream.makeStream(of: Event.self)
        (speechChunks, speech) = AsyncStream.makeStream(of: SpeechChunk.self)
    }

    public var isPaused: Bool { paused }

    /// Starts pulling audio every 20 ms.
    public func start() {
        guard poll == nil else { return }
        asr = Task { [engine, speechChunks] in
            for await chunk in speechChunks {
                do {
                    let result = try await engine.transcribe(samples: chunk.samples)
                    self.transcribed(chunk, result)
                } catch {
                    self.transcribed(chunk, [])
                    self.warn("Transcription failed: \(error)")
                }
            }
        }
        poll = Task {
            while !Task.isCancelled {
                await self.tick()
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    public func pause() {
        paused = true
        writer.pause()
    }

    public func resume() {
        paused = false
        writer.resume()
    }

    /// Stops capture, transcribes everything still queued, finishes the file and saves the meeting.
    /// Returns the new meeting id.
    public func stop() async throws -> String {
        start() // no-op once started
        poll?.cancel()
        _ = await poll?.value
        microphone?.stop()
        system?.stop()
        await tick() // whatever the captures still held
        if !paused { try await feed(mixer.flush()) }
        queue(try await segment { try await $0.flush() })
        speech.finish()
        await asr?.value
        try await writer.finish()
        let id = try await store.saveMeeting(
            title: title,
            segments: segments.sorted { $0.sequence < $1.sequence }.map {
                NewSegment(text: $0.text, timestamp: Timestamp.now(), audioStartTime: $0.start, audioEndTime: $0.end)
            },
            folderPath: writer.folder.path)
        eventSink.yield(.saved(id))
        eventSink.finish()
        return id
    }

    private func tick() async {
        let mic = microphone?.drain() ?? []
        let sys = system?.drain() ?? []
        levels.withLock { $0 = (AudioLevel(samples: mic), AudioLevel(samples: sys)) }
        let lost = (microphone?.droppedSamples ?? 0) + (system?.droppedSamples ?? 0) + mixer.droppedMic + mixer.droppedSystem
        if lost > dropped {
            warn(String(format: "Dropped %.1f s of audio", Double(lost - dropped) / RecordingWriter.sampleRate))
            dropped = lost
        }
        guard !paused else { return }
        if !mic.isEmpty { mixer.add(mic: dsp.process(mic)) }
        if !sys.isEmpty { mixer.add(system: sys) }
        do {
            while let window = mixer.nextWindow() { try await feed(window) }
        } catch {
            warn("Voice detection failed: \(error)")
        }
    }

    private func feed(_ window: [Float]) async throws {
        guard !window.isEmpty else { return }
        writer.append(window)
        let audio = resampler.process(window)
        queue(try await segment { try await $0.process(audio) })
    }

    /// Runs the segmenter outside the actor's storage; safe because only the poll loop, then stop, use it.
    private func segment(_ body: (inout SpeechSegmenter) async throws -> [SpeechChunk]) async throws -> [SpeechChunk] {
        var copy = segmenter
        defer { segmenter = copy }
        return try await body(&copy)
    }

    private func queue(_ chunks: [SpeechChunk]) {
        for chunk in chunks {
            backlog += chunk.end - chunk.start
            if backlog > backlogWarning, !warnedBacklog {
                warnedBacklog = true
                warn(String(format: "Transcription is falling behind (%.0f s of speech queued)", backlog))
            }
            speech.yield(chunk)
        }
    }

    private func transcribed(_ chunk: SpeechChunk, _ result: [Segment]) {
        backlog -= chunk.end - chunk.start
        if backlog < backlogWarning / 2 { warnedBacklog = false }
        for piece in result where !piece.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let segment = LiveSegment(sequence: segments.count, text: piece.text, start: chunk.start + piece.start, end: chunk.start + piece.end)
            segments.append(segment)
            try? writer.upsertSegment(id: "segment-\(segment.sequence)", text: segment.text, start: segment.start,
                                      end: segment.end, sequence: segment.sequence)
            eventSink.yield(.segment(segment))
        }
    }

    private func warn(_ message: String) { eventSink.yield(.warning(message)) }
}
