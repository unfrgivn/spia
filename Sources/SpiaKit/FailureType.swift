import Foundation

/// What the third byte of a UDS trouble code says about how the part failed.
///
/// SAE J2012-DA (and ISO 14229-1) define the byte and its categories. That table is SAE's and
/// is not reproduced here. What follows is Spia's own description of the few dozen failure
/// types cars commonly report, written for the owner reading the board, with the usual
/// physical cause where one is worth naming. A byte that isn't listed is shown as a byte and
/// left to the model's interpretation, which is told so.
public enum FailureType {
    /// The meaning of `byte` in Spia's words, or nil when Spia doesn't describe it.
    public static func meaning(of byte: UInt8) -> String? {
        meanings[byte]
    }

    /// "1B: resistance in the circuit is too high…", or "1B" alone when it isn't described.
    public static func label(for byte: UInt8) -> String {
        let hex = String(format: "%02X", byte)
        return meanings[byte].map { "\(hex): \($0)" } ?? hex
    }

    /// Everything Spia says about a failure type, keyed by the byte.
    public static let meanings: [UInt8: String] = [
        0x00: "no further detail from the module",
        0x01: "an electrical fault, not narrowed down further",
        0x02: "a signal fault, not narrowed down further",
        0x04: "a fault inside the module itself",

        // Circuits: wiring, connectors, and the part at the end of them.
        0x11: "the circuit is shorted to ground",
        0x12: "the circuit is shorted to battery voltage",
        0x13: "the circuit is open: a break, an unplugged connector, or a broken wire",
        0x14: "the circuit is shorted to ground or open",
        0x15: "the circuit is shorted to battery voltage or open",
        0x16: "voltage in the circuit is too low",
        0x17: "voltage in the circuit is too high",
        0x1A: "resistance in the circuit is too low, which usually means a short",
        0x1B:
            "resistance in the circuit is too high, which usually means a corroded, loose, or partly broken connection",
        0x1C: "voltage in the circuit is outside the expected range",
        0x1E: "resistance in the circuit is outside the expected range",
        0x1F: "the circuit fault comes and goes",

        // Signals: what a sensor or switch reports.
        0x21: "the signal is weaker than it can validly be",
        0x22: "the signal is stronger than it can validly be",
        0x23: "the signal is stuck low",
        0x24: "the signal is stuck high",
        0x29: "the signal is not valid",
        0x2F: "the signal is erratic",
        0x31: "there is no signal at all",

        // Inside the module.
        0x49: "an electronic fault inside the module",
        0x4B: "the module or component ran too hot",
        0x62: "two readings that should agree don't",
        0x64: "the signal isn't plausible given everything else the module sees",

        // Actuators and the network.
        0x71: "the actuator is stuck",
        0x72: "the actuator is stuck open",
        0x73: "the actuator is stuck closed",
        0x87: "an expected message from another module never arrived",
        0x88: "the module dropped off the bus",

        // General operation.
        0x92: "the part is performing poorly or operating incorrectly",
        0x96: "a fault inside the component",
    ]
}
