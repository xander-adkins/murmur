import AVFoundation
import Foundation
import os
import Speech

/// The only object the audio render thread touches during a take. It owns everything `feed`
/// needs (`let`s fixed at construction, a converter used by the tap thread alone) so the main
/// thread never shares mutable state with the tap. Counters cross threads under a lock.
@available(macOS 26, *)
final class AudioFeeder: @unchecked Sendable {
    struct Stats: Equatable {
        var fedFrames: Int64 = 0
        var conversionError: String?
    }

    let continuation: AsyncStream<AnalyzerInput>.Continuation
    let format: AVAudioFormat
    private var converter: AVAudioConverter?
    private let stats = OSAllocatedUnfairLock(initialState: Stats())

    init(continuation: AsyncStream<AnalyzerInput>.Continuation, format: AVAudioFormat) {
        self.continuation = continuation
        self.format = format
    }

    /// Main thread: read after the tap has been removed.
    var snapshot: Stats {
        stats.withLock { $0 }
    }

    /// Seconds of audio delivered so far.
    var fedSeconds: Double {
        Double(snapshot.fedFrames) / format.sampleRate
    }

    /// Render thread. Yielding after the stream is finished is a harmless no-op.
    func feed(_ buffer: AVAudioPCMBuffer) {
        if buffer.format == format {
            deliver(buffer)
            return
        }

        if converter == nil {
            converter = AVAudioConverter(from: buffer.format, to: format)
        }
        guard let converter else {
            recordConversionError("no converter from \(Int(buffer.format.sampleRate))Hz")
            return
        }

        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            return
        }

        var error: NSError?
        var supplied = false
        let status = converter.convert(to: converted, error: &error) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard status != .error else {
            recordConversionError(error?.localizedDescription ?? "unknown")
            return
        }
        if converted.frameLength > 0 {
            deliver(converted)
        }
    }

    private func deliver(_ buffer: AVAudioPCMBuffer) {
        stats.withLock { $0.fedFrames += Int64(buffer.frameLength) }
        continuation.yield(AnalyzerInput(buffer: buffer))
    }

    private func recordConversionError(_ detail: String) {
        stats.withLock { stats in
            if stats.conversionError == nil {
                stats.conversionError = detail
            }
        }
    }
}
