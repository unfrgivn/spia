import ArgumentParser
import Foundation
import OBDCore

struct Probe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Identify the adapter, then look for a vehicle and list what it supports.")

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await Connection.with(global) { connection in
            let session = connection.session

            print("Adapter:   \(connection.adapterIdentity)")
            if let firmware = try await session.identifySTN() {
                print("Firmware:  \(firmware)")
                print("Device:    \(try await session.send("STDI"))")
            }
            if let volts = try await session.voltage() {
                print("Battery:   \(String(format: "%.1f", volts)) V")
            } else {
                print("Battery:   not detected (adapter is on USB power only)")
            }

            print("Searching for a vehicle...")
            let responses: [ECUResponse]
            do {
                responses = try await session.request(OBDRequest(service: .currentData, pid: 0x00))
            } catch ELM327Error.adapter(let message) {
                print("No vehicle: \(message). Is the adapter in the car with the ignition on?")
                return
            }

            let described = try await session.describeProtocol()
            let number = try await session.protocolNumber()
            print("Protocol:  \(described) [\(number)]")

            for response in responses {
                printSupportedPIDs(response)
            }
        }
    }

    private func printSupportedPIDs(_ response: ECUResponse) {
        let ecu = String(response.ecu, radix: 16, uppercase: true)
        guard case .currentData(_, .supported(let pids)) = ServiceResponse.decode(response.payload)
        else {
            print("ECU \(ecu): unexpected reply \(PIDValue.raw(response.payload).formatted)")
            return
        }
        print("ECU \(ecu): \(pids.count) PIDs supported in 01-20")
        for pid in pids.sorted() {
            print("  \(String(format: "%02X", pid))  \(PIDDescriptor.named(pid))")
        }
    }
}
