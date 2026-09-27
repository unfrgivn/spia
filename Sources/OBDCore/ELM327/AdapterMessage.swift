/// Status and error strings the ELM327/STN firmware prints instead of, or alongside, data.
public enum ELM327AdapterMessage: Equatable, Sendable, CustomStringConvertible {
    case ok
    case unknownCommand
    case noData
    case canError
    case busInitError
    case busBusy
    case busError
    case unableToConnect
    case stopped
    case bufferFull
    case dataError
    case feedbackError
    case lowVoltageReset
    case activityAlert
    case receiveError

    public init?(line: String) {
        switch line {
        case "OK": self = .ok
        case "?": self = .unknownCommand
        case "NO DATA": self = .noData
        case "CAN ERROR": self = .canError
        case "BUS BUSY": self = .busBusy
        case "BUS ERROR": self = .busError
        case "UNABLE TO CONNECT": self = .unableToConnect
        case "STOPPED": self = .stopped
        case "BUFFER FULL": self = .bufferFull
        case "DATA ERROR", "<DATA ERROR": self = .dataError
        case "FB ERROR": self = .feedbackError
        case "LV RESET": self = .lowVoltageReset
        case "ACT ALERT": self = .activityAlert
        case "<RX ERROR": self = .receiveError
        default:
            if line.hasPrefix("BUS INIT:") && line.hasSuffix("ERROR") {
                self = .busInitError
            } else {
                return nil
            }
        }
    }

    public var description: String {
        switch self {
        case .ok: return "OK"
        case .unknownCommand: return "adapter did not understand the command"
        case .noData: return "no response from the vehicle"
        case .canError: return "CAN bus error"
        case .busInitError: return "bus initialisation failed"
        case .busBusy: return "bus busy"
        case .busError: return "bus error"
        case .unableToConnect: return "unable to connect to the vehicle"
        case .stopped: return "operation interrupted"
        case .bufferFull: return "adapter receive buffer overflowed"
        case .dataError: return "data error"
        case .feedbackError: return "adapter feedback error (transmit not seen on bus)"
        case .lowVoltageReset: return "adapter reset due to low voltage"
        case .activityAlert: return "bus activity detected while idle"
        case .receiveError: return "adapter receive error"
        }
    }
}
