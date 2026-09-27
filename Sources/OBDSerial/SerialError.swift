public enum SerialError: Error, Sendable, CustomStringConvertible {
    case unsupportedBaud(Int)
    case open(path: String, errno: Int32, message: String)
    case configure(path: String, errno: Int32, message: String)
    case notOpen
    case io(errno: Int32, message: String)

    public var description: String {
        switch self {
        case .unsupportedBaud(let baud):
            return "unsupported baud rate \(baud)"
        case .open(let path, let errno, let message):
            return "could not open \(path): \(message) (errno \(errno))"
        case .configure(let path, let errno, let message):
            return "could not configure \(path): \(message) (errno \(errno))"
        case .notOpen:
            return "serial port is not open"
        case .io(let errno, let message):
            return "serial I/O failed: \(message) (errno \(errno))"
        }
    }
}
