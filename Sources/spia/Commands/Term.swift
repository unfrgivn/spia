import ArgumentParser
import Foundation
import OBDCore

struct Term: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Raw terminal. Type AT, ST, or hex OBD commands; Ctrl-D or 'quit' exits.")

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await Connection.with(global) { connection in
            print("Connected to \(connection.adapterIdentity). Echo is off, headers are on.")
            while true {
                print("> ", terminator: "")
                guard let line = readLine() else {
                    print()
                    return
                }
                let command = line.trimmingCharacters(in: .whitespaces)
                if command.isEmpty {
                    continue
                }
                if command.lowercased() == "quit" {
                    return
                }
                do {
                    let reply = try await connection.session.send(command, timeout: .seconds(10))
                    print(reply.replacingOccurrences(of: "\r", with: "\n"))
                } catch let error as ELM327Error {
                    print("error: \(error)")
                }
            }
        }
    }
}
