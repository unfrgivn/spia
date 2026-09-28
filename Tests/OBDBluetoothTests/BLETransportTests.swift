import OBDBluetooth
import Foundation
import Testing

@Test func chunksRespectMaximumLength() {
    #expect(
        BLETransportLogic.chunks([1, 2, 3, 4, 5], maximumLength: 2) == [[1, 2], [3, 4], [5]])
}

@Test func strongestSightingWins() {
    let weak = BLESighting(name: "weak", identifier: UUID(), rssi: -80)
    let strong = BLESighting(name: "strong", identifier: UUID(), rssi: -40)
    #expect(BLETransportLogic.strongest([weak, strong]) == strong)
}
