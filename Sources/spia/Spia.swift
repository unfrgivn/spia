import ArgumentParser
import OBDCore

@main
struct Spia: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "spia",
        abstract: "OBD-II scan tool for ELM327/STN adapters such as the Vgate vLinker FS.",
        subcommands: [Ports.self, Probe.self, Term.self])
}

struct GlobalOptions: ParsableArguments {
    @Option(name: .long, help: "Serial device. Defaults to the first /dev/cu.usbserial* port.")
    var port: String?

    @Option(name: .long, help: "Serial baud rate.")
    var baud: Int = 115200

    @Option(
        name: .long, help: "ELM protocol digit for ATSP (0 = automatic, 6 = CAN 11-bit 500k).")
    var `protocol`: ELM327Protocol = .automatic

    @Option(name: .long, help: "Record every byte in both directions to this transcript file.")
    var record: String?

    @Flag(name: .long, help: "Print every command and reply to stderr.")
    var verbose = false
}

extension ELM327Protocol: ExpressibleByArgument {
    public init?(argument: String) {
        self.init(commandDigit: argument)
    }

    public static var allValueStrings: [String] {
        allCases.map(\.commandDigit)
    }
}
