import Foundation
import Synchronization

/// Catalog status of a downloadable model.
public enum ModelStatus: Sendable, Hashable {
    case missing
    case downloading(Double)
    case available
}

/// Downloads `url` to `destination` with fractional progress; cancelling the task cancels the transfer.
public func fetch(_ url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
    let running = Mutex<(task: URLSessionDownloadTask?, observation: NSKeyValueObservation?)>((nil, nil))
    try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let task = URLSession.shared.downloadTask(with: url) { temp, response, error in
                running.withLock { $0.observation = nil }
                if let error {
                    continuation.resume(throwing: (error as? URLError)?.code == .cancelled ? CancellationError() : error)
                    return
                }
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    continuation.resume(throwing: URLError(.badServerResponse, userInfo: [NSURLErrorFailingURLErrorKey: url]))
                    return
                }
                do {
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: temp!, to: destination)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            let last = Mutex(-1.0)
            let observation = task.progress.observe(\.fractionCompleted) { p, _ in
                let value = min(p.fractionCompleted, 1)
                // KVO fires per received block; pass on 0.5 % steps.
                guard last.withLock({ old in value - old >= 0.005 ? { old = value; return true }() : false }) else { return }
                progress(value)
            }
            running.withLock { $0 = (task, observation) }
            task.resume()
            if Task.isCancelled { task.cancel() }
        }
    } onCancel: {
        running.withLock { $0.task?.cancel() }
    }
}
