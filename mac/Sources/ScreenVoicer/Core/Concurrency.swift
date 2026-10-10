import Foundation

/// A value guarded by a lock, readable from any thread.
@propertyWrapper
final class Atomic<Value> {
    private var value: Value
    private let lock = NSLock()

    init(wrappedValue: Value) {
        value = wrappedValue
    }

    var wrappedValue: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        set {
            lock.lock()
            value = newValue
            lock.unlock()
        }
    }
}

/// A mutex for async code: waiters resume in order, release() is synchronous (usable in defer).
final class AsyncMutex {
    private let lock = NSLock()
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if !locked {
                locked = true
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func release() {
        lock.lock()
        if waiters.isEmpty {
            locked = false
            lock.unlock()
        } else {
            let next = waiters.removeFirst()
            lock.unlock()
            next.resume()
        }
    }
}

/// Downloads a file with progress and an inactivity timeout (a stalled connection fails after `stallTimeout`).
final class FileDownloader: NSObject, URLSessionDownloadDelegate {
    struct DownloadError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private let destination: URL
    private let progress: (Double, Int64) -> Void
    private var continuation: CheckedContinuation<Int64, Error>?
    private var session: URLSession?
    private var movedBytes: Int64 = -1
    private var moveError: Error?

    private init(destination: URL, progress: @escaping (Double, Int64) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    /// Returns the number of bytes written to `destination`.
    static func download(_ url: URL, to destination: URL, stallTimeout: TimeInterval = 30,
                         progress: @escaping (Double, Int64) -> Void) async throws -> Int64 {
        let downloader = FileDownloader(destination: destination, progress: progress)
        return try await downloader.start(url, stallTimeout: stallTimeout)
    }

    private func start(_ url: URL, stallTimeout: TimeInterval) async throws -> Int64 {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = stallTimeout
        config.timeoutIntervalForResource = 6 * 3600
        config.httpAdditionalHeaders = ["User-Agent": "ScreenVoicer/\(AppInfo.version)"]
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = session
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 {
            progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), totalBytesExpectedToWrite)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            moveError = DownloadError(message: "сервер відповів \(status)")
            return
        }
        do {
            let fm = FileManager.default
            try? fm.removeItem(at: destination)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: location, to: destination)
            let size = (try fm.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
            let expected = downloadTask.countOfBytesExpectedToReceive
            if expected > 0 && size != expected {
                try? fm.removeItem(at: destination)
                moveError = DownloadError(message: "файл завантажився не повністю")
                return
            }
            movedBytes = size
        } catch {
            moveError = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        session.finishTasksAndInvalidate()
        self.session = nil
        let continuation = self.continuation
        self.continuation = nil
        if let error {
            let timedOut = (error as? URLError)?.code == .timedOut
            continuation?.resume(throwing: timedOut ? DownloadError(message: "з'єднання зависло") : error)
        } else if let moveError {
            continuation?.resume(throwing: moveError)
        } else {
            continuation?.resume(returning: max(movedBytes, 0))
        }
    }
}
