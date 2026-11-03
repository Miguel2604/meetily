import AVFoundation

public enum AudioError: Error, Equatable {
    case converter
    case osStatus(String, OSStatus)
    case permissionDenied(String)
    case noDevice
}

/// Streaming mono resampler on AVAudioConverter; keeps filter state across blocks. Not real-time safe.
public final class Resampler {
    private let converter: AVAudioConverter?
    private let input: AVAudioFormat
    private let output: AVAudioFormat
    private let ratio: Double

    public init(from sourceRate: Double, to targetRate: Double) throws {
        input = AVAudioFormat(standardFormatWithSampleRate: sourceRate, channels: 1)!
        output = AVAudioFormat(standardFormatWithSampleRate: targetRate, channels: 1)!
        ratio = targetRate / sourceRate
        if sourceRate == targetRate {
            converter = nil
        } else {
            guard let c = AVAudioConverter(from: input, to: output) else { throw AudioError.converter }
            c.sampleRateConverterQuality = AVAudioQuality.high.rawValue
            converter = c
        }
    }

    public func process(_ samples: [Float]) -> [Float] {
        guard let converter else { return samples }
        guard !samples.isEmpty,
              let inBuffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(samples.count)),
              let outBuffer = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: AVAudioFrameCount(Double(samples.count) * ratio) + 64)
        else { return [] }
        inBuffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { inBuffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        nonisolated(unsafe) var fed = false
        _ = converter.convert(to: outBuffer, error: nil) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return inBuffer
        }
        return Array(UnsafeBufferPointer(start: outBuffer.floatChannelData![0], count: Int(outBuffer.frameLength)))
    }
}
