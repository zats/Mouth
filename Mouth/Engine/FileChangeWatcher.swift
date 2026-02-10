import Foundation

final class FileChangeWatcher {
    typealias EventHandler = (DispatchSource.FileSystemEvent) -> Void

    private let url: URL
    private var fd: Int32 = -1
    private var source: DispatchSourceFileSystemObject?

    init(url: URL) {
        self.url = url
    }

    deinit {
        stop()
    }

    func start(queue: DispatchQueue, handler: @escaping EventHandler) throws {
        stop()

        let path = (url as NSURL).fileSystemRepresentation
        let fd = open(path, O_EVTONLY)
        if fd < 0 {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "open(O_EVTONLY) failed for \(url.path): \(String(cString: strerror(errno)))"]
            )
        }

        self.fd = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .extend, .attrib, .link, .revoke],
            queue: queue
        )

        source.setEventHandler { [weak self] in
            guard self != nil else { return }
            handler(source.data)
        }

        source.setCancelHandler { [fd] in
            close(fd)
        }

        self.source = source
        source.resume()
    }

    func stop() {
        if let source {
            source.cancel()
            self.source = nil
        }
        fd = -1
    }
}
