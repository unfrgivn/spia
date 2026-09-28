import ArgumentParser
import OBDSerial
import OBDBluetooth

struct Ports: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List serial ports, or Bluetooth LE adapters with --ble.")

    @Flag(name: .long, help: "Scan for Bluetooth LE adapters.")
    var ble = false

    @Option(name: .long, help: "Bluetooth scan duration in seconds.")
    var seconds = 10.0

    mutating func validate() throws {
        guard seconds > 0, seconds <= 60 else {
            throw ValidationError("--seconds must be between 0 and 60")
        }
    }

    func run() async throws {
        if ble {
            let sightings = try await BLETransport.discover(
                for: .milliseconds(Int64(seconds * 1_000)))
            if sightings.isEmpty {
                print("no Bluetooth LE adapters found")
                return
            }
            for sighting in sightings {
                print("\(sighting.name)  \(sighting.identifier.uuidString)  RSSI \(sighting.rssi)")
            }
            return
        }
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
