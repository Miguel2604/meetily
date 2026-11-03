// Meety sidecar: English transcription on the Apple Neural Engine through FluidAudio
// (Parakeet Ultra or Phonon-2, both Parakeet TDT 0.6B v3 derivatives).
//
//   asr-helper status   --model <ultra|phonon2> --dir <model dir>  -> {"downloaded":bool}
//   asr-helper download --model <ultra|phonon2> --dir <model dir>  -> {"progress":0..1} lines, then {"done":true}
//   asr-helper serve    --model <ultra|phonon2> --dir <model dir>  -> {"ready":true}, then per stdin frame
//                                                                    one {"text":"..."} or {"error":"..."} line
//
// serve frames: u32 little-endian sample count, then that many f32 LE mono samples at 16 kHz.
// Protocol lines go to the original stdout; anything else printed goes to stderr.
import FluidAudio
import Foundation

let protocolOut = FileHandle(fileDescriptor: dup(STDOUT_FILENO), closeOnDealloc: true)
dup2(STDERR_FILENO, STDOUT_FILENO)

func emit(_ object: [String: Any]) {
    var data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{\"error\":\"encode\"}".utf8)
    data.append(0x0A)
    protocolOut.write(data)
}

func fail(_ message: String) -> Never {
    emit(["error": message])
    exit(1)
}

func readExactly(_ count: Int) -> Data? {
    var data = Data()
    while data.count < count {
        let chunk = FileHandle.standardInput.readData(ofLength: count - data.count)
        if chunk.isEmpty { return nil }
        data.append(chunk)
    }
    return data
}

func option(_ name: String) -> String? {
    let args = CommandLine.arguments
    return args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
}

let args = CommandLine.arguments
guard args.count >= 2, let dirPath = option("--dir") else {
    fail("usage: asr-helper status|download|serve --model ultra|phonon2 --dir <path>")
}
let version: AsrModelVersion
switch option("--model") {
case "ultra": version = .ultra
case "phonon2": version = .phonon2
default: fail("--model must be ultra or phonon2")
}
let dir = URL(fileURLWithPath: dirPath, isDirectory: true)
let maxSamples = 16_000 * 60 * 30 // one frame is a VAD chunk; 30 min is far past any

switch args[1] {
case "status":
    emit(["downloaded": AsrModels.modelsExist(at: dir, version: version)])

case "download":
    do {
        try await AsrModels.download(to: dir, version: version) { progress in
            emit(["progress": progress.fractionCompleted])
        }
        // The first full load builds the Neural Engine plan (~100 s for Phonon-2); pay it here, not mid-meeting.
        emit(["preparing": true])
        _ = try await AsrModels.load(from: dir, version: version)
        emit(["done": true])
    } catch {
        fail("\(error)")
    }

case "serve":
    let asr = AsrManager(config: .default)
    do {
        let models = try await AsrModels.load(from: dir, version: version)
        try await asr.loadModels(models)
    } catch {
        fail("\(error)")
    }
    emit(["ready": true])
    while let header = readExactly(4) {
        let count = Int(header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
        guard count <= maxSamples, let body = readExactly(count * 4) else { fail("bad frame (\(count) samples)") }
        var samples = body.withUnsafeBytes { raw in
            (0..<count).map { Float(bitPattern: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self).littleEndian) }
        }
        if samples.isEmpty {
            emit(["text": ""])
            continue
        }
        // FluidAudio rejects chunks under 0.3 s as invalidAudioData; pad short VAD chunks with silence instead.
        let minSamples = ASRConstants.minimumRequiredSamples(forSampleRate: 16_000)
        if samples.count < minSamples {
            samples += [Float](repeating: 0, count: minSamples - samples.count)
        }
        do {
            // Each frame is an independent speech chunk, so it starts from a fresh decoder state.
            var state = try TdtDecoderState()
            let result = try await asr.transcribe(samples, decoderState: &state)
            emit(["text": result.text])
        } catch {
            emit(["error": "\(error)"])
        }
    }

default:
    fail("unknown command \(args[1])")
}
