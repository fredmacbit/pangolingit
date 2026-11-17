import Foundation
import CoreServices
import PangolinGitCore

/// Monitors repository file system changes via macOS FSEvents with event debouncing.
/// Replaces Windows `ReadDirectoryChangesW` / `CDirectoryWatcher` (`src/TGitCache/DirectoryWatcher.cpp`).
final class FSEventsWatcher: @unchecked Sendable {
    typealias ChangeHandler = @Sendable ([String]) -> Void
    
    private var streamRef: FSEventStreamRef?
    private let path: String
    private let onChange: ChangeHandler
    private let queue = DispatchQueue(label: "be.macbit.pangolingit.fsevents", qos: .utility)
    
    private var pendingPaths = Set<String>()
    private var debounceWorkItem: DispatchWorkItem?
    private let debounceInterval: DispatchTimeInterval = .milliseconds(400)
    
    init(path: String, onChange: @escaping ChangeHandler) {
        self.path = path
        self.onChange = onChange
    }
    
    func start() {
        stop()
        
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passRetained(self).toOpaque(),
            retain: nil,
            release: { info in
                guard let info = info else { return }
                Unmanaged<FSEventsWatcher>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        
        let callback: FSEventStreamCallback = { (streamRef, clientCallBackInfo, numEvents, eventPaths, eventFlags, eventIds) in
            guard let clientCallBackInfo = clientCallBackInfo else { return }
            let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(clientCallBackInfo).takeUnretainedValue()
            
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            watcher.enqueuePaths(paths)
        }
        
        let pathsToWatch = [path] as CFArray
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.1, // 100ms latency coalescing (Plan 2.2)
            flags
        ) else {
            PangolinLog.cache.error("Failed to create FSEventStream for \(self.path)")
            return
        }
        
        self.streamRef = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        PangolinLog.cache.info("Started FSEventsWatcher with 100ms coalescing for \(self.path)")
    }
    
    private func enqueuePaths(_ paths: [String]) {
        queue.async { [weak self] in
            guard let self = self else { return }
            for p in paths { self.pendingPaths.insert(p) }
            
            self.debounceWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                let pathsToFlush = Array(self.pendingPaths)
                self.pendingPaths.removeAll()
                if !pathsToFlush.isEmpty {
                    self.onChange(pathsToFlush)
                }
            }
            self.debounceWorkItem = workItem
            self.queue.asyncAfter(deadline: .now() + self.debounceInterval, execute: workItem)
        }
    }
    
    func stop() {
        if let stream = streamRef {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            streamRef = nil
            debounceWorkItem?.cancel()
            pendingPaths.removeAll()
            PangolinLog.cache.info("Stopped FSEventsWatcher for \(self.path)")
        }
    }
    
    deinit {
        stop()
    }
}
