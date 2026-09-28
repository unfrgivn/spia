import ArgumentParser
import OBDCore
import Foundation

@main
struct Spia: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "spia",
        abstract: "OBD-II scan tool for ELM327/STN adapters such as the Vgate vLinker FS.",
        subcommands: [
            Ports.self, Probe.self, Term.self, Capture.self, Discover.self, Scan.self, Info.self,
            Inspect.self, Live.self,
            UDS.self,
        ])
}

struct GlobalOptions: ParsableArguments {
    @Option(name: .long, help: "Serial device. Defaults to the first /dev/cu.usbserial* port.")
    var port: String?

    @Option(name: .long, help: "Serial baud rate, ignored for Bluetooth.")
    var baud: Int = 115200

    @Flag(name: .long, help: "Use the Bluetooth LE adapter instead of a serial port.")
    var ble = false

    @Option(name: .long, help: "Bluetooth peripheral identifier (implies --ble).")
    var bleID: String?

    @Option(
        name: .long, help: "ELM protocol digit for ATSP (0 = automatic, 6 = CAN 11-bit 500k).")
    var `protocol`: ELM327Protocol = .automatic

    @Option(name: .long, help: "Record every byte in both directions to this transcript file.")
    var record: String?

    @Flag(name: .long, help: "Print every command and reply to stderr.")
    var verbose = false

    mutating func validate() throws {
        if ble || bleID != nil, port != nil {
            throw ValidationError("--ble/--ble-id cannot be used with --port")
        }
        if let bleID, UUID(uuidString: bleID) == nil {
            throw ValidationError("--ble-id must be a valid UUID")
        }
    }
}

extension ELM327Protocol: ExpressibleByArgument {
    public init?(argument: String) {
        self.init(commandDigit: argument)
    }

    public static var allValueStrings: [String] {
        allCases.map(\.commandDigit)
    }
}

extension CANBus: ExpressibleByArgument {}
