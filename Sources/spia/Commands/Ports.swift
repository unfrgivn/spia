import ArgumentParser
import OBDSerial

struct Ports: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List serial ports. The default adapter port is marked with *.")

    func run() async throws {
        let ports = SerialTransport.availablePorts()
        let preferred = SerialTransport.defaultPort()
        if ports.isEmpty {
            print("no serial ports found")
            return
        }
        for port in ports {
            print(port == preferred ? "* \(port)" : "  \(port)")
        }
    }
}
