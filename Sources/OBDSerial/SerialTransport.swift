import Darwin
import Foundation
import OBDCore

/// POSIX serial port transport for macOS. Raw mode, 8N1, no flow control.
public actor SerialTransport: Transport {
    private static let speeds: [Int: speed_t] = [
        9600: speed_t(B9600),
        19200: speed_t(B19200),
        38400: speed_t(B38400),
        57600: speed_t(B57600),
        115200: speed_t(B115200),
        230400: speed_t(B230400),
    ]

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
        guard let speed = Self.speeds[baud] else {
            throw SerialError.unsupportedBaud(baud)
        }
        let fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else {
            throw SerialError.open(path: path, errno: errno, message: Self.message(errno))
        }
        do {
            try configure(fd, speed: speed)
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

    private func configure(_ fd: Int32, speed: speed_t) throws {
        guard fcntl(fd, F_SETFL, 0) == 0 else {
            throw SerialError.configure(path: path, errno: errno, message: Self.message(errno))
        }
        var settings = termios()
        guard tcgetattr(fd, &settings) == 0 else {
            throw SerialError.configure(path: path, errno: errno, message: Self.message(errno))
        }
        cfmakeraw(&settings)
        cfsetspeed(&settings, speed)
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

    private static func message(_ code: Int32) -> String {
        String(cString: strerror(code))
    }
}
