import Darwin
import Foundation
import OBDCore

/// POSIX serial port transport for macOS. Raw mode, 8N1, no flow control.
public actor SerialTransport: Transport {
    /// `IOSSIOSPEED` from `<IOKit/serial/ioss.h>`: `_IOW('T', 2, speed_t)`. Swift cannot import
    /// the macro, so it is assembled here: IOC_OUT | sizeof(speed_t) << 16 | 'T' << 8 | 2.
    /// It sets any rate the USB-serial chip can generate, not just the termios `B*` constants,
    /// and must be applied after `tcsetattr`, which would otherwise reset it.
    private static let iossiospeed: UInt =
        0x8000_0000 | UInt(MemoryLayout<speed_t>.size & 0x1FFF) << 16 | UInt(UInt8(ascii: "T")) << 8
        | 2

    private let path: String
    private let baud: Int
    private var descriptor: Int32?

    public init(path: String, baud: Int = 115200) {
        self.path = path
        self.baud = baud
    }

    /// Every `/dev/cu.*` callout device except the two macOS always creates.
    public static func availablePorts() -> [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return
            entries
            .filter { $0.hasPrefix("cu.") }
            .filter { $0 != "cu.Bluetooth-Incoming-Port" && $0 != "cu.debug-console" }
            .map { "/dev/" + $0 }
            .sorted()
    }

    /// The first port that looks like a USB serial adapter.
    public static func defaultPort() -> String? {
        availablePorts().first { $0.contains("usbserial") || $0.contains("usbmodem") }
    }

    public func open() async throws {
        guard descriptor == nil else {
            return
        }
        guard baud > 0 else {
            throw SerialError.unsupportedBaud(baud)
        }
        let fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else {
            throw SerialError.open(path: path, errno: errno, message: Self.message(errno))
        }
        do {
            try configure(fd)
            try applySpeed(fd, baud: baud)
        } catch {
            Darwin.close(fd)
            throw error
        }
        descriptor = fd
    }

    public func close() async {
        if let fd = descriptor {
            Darwin.close(fd)
            descriptor = nil
        }
    }

    public func write(_ bytes: [UInt8]) async throws {
        guard let fd = descriptor else {
            throw SerialError.notOpen
        }
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { buffer in
                Darwin.write(fd, buffer.baseAddress, buffer.count)
            }
            guard written > 0 else {
                throw SerialError.io(errno: errno, message: Self.message(errno))
            }
            offset += written
        }
    }

    /// Switches the host rate and discards anything received at the old one, which is garbage
    /// by definition once the adapter has switched too.
    public func setBaud(_ baud: Int) async throws {
        guard let fd = descriptor else {
            throw SerialError.notOpen
        }
        try applySpeed(fd, baud: baud)
        tcflush(fd, TCIFLUSH)
    }

    public func read(timeout: Duration) async throws -> [UInt8] {
        guard let fd = descriptor else {
            throw SerialError.notOpen
        }
        var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let milliseconds = Int32(clamping: Int((timeout / .milliseconds(1)).rounded(.up)))
        let ready = poll(&poller, 1, max(0, milliseconds))
        guard ready >= 0 else {
            throw SerialError.io(errno: errno, message: Self.message(errno))
        }
        guard ready > 0 else {
            return []
        }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        guard count >= 0 else {
            throw SerialError.io(errno: errno, message: Self.message(errno))
        }
        return Array(buffer.prefix(count))
    }

    private func configure(_ fd: Int32) throws {
        guard fcntl(fd, F_SETFL, 0) == 0 else {
            throw SerialError.configure(path: path, errno: errno, message: Self.message(errno))
        }
        var settings = termios()
        guard tcgetattr(fd, &settings) == 0 else {
            throw SerialError.configure(path: path, errno: errno, message: Self.message(errno))
        }
        cfmakeraw(&settings)
        settings.c_cflag |= tcflag_t(CLOCAL | CREAD)
        settings.c_cflag &= ~tcflag_t(CSIZE | PARENB | CSTOPB | CRTSCTS)
        settings.c_cflag |= tcflag_t(CS8)
        withUnsafeMutablePointer(to: &settings.c_cc) { controlChars in
            controlChars.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { chars in
                chars[Int(VMIN)] = 0
                chars[Int(VTIME)] = 0
            }
        }
        guard tcsetattr(fd, TCSANOW, &settings) == 0 else {
            throw SerialError.configure(path: path, errno: errno, message: Self.message(errno))
        }
        tcflush(fd, TCIOFLUSH)
    }

    private func applySpeed(_ fd: Int32, baud: Int) throws {
        var speed = speed_t(baud)
        guard ioctl(fd, Self.iossiospeed, &speed) == 0 else {
            throw SerialError.unsupportedBaud(baud)
        }
    }

    private static func message(_ code: Int32) -> String {
        String(cString: strerror(code))
    }
}
