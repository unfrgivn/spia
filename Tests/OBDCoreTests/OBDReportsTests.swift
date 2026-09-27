import OBDCore
import Testing

@Suite("Generic OBD reports")
struct OBDReportsTests {
    @Test("scan keeps ECUs separate and positive empty is not healthy inference")
    func scanReport() {
        let result = OBDReportBuilder.scan(observations: [
            OBDObservation(
                request: OBDRequest(service: .storedDTCs), ecu: 0x7E8,
                outcome: .response(.dtcs(service: .storedDTCs, codes: []))),
            OBDObservation(
                request: OBDRequest(service: .storedDTCs), ecu: 0x7E9,
                outcome: .response(
                    .dtcs(service: .storedDTCs, codes: [DTC(code: "P0133")].compactMap { $0 }))),
        ])
        #expect(result.count == 2)
        #expect(result[0].stored == .positive([]))
        #expect(result[1].stored == .positive([DTC(code: "P0133")].compactMap { $0 }))
        #expect(result[0].pending == .unavailable("not requested"))
    }

    @Test("plans are bounded and freeze frame DTC comes first")
    func plans() {
        #expect(
            OBDScanPlan.standard.requests.map(\.hex) == [
                "0100", "0101", "03", "07", "0A",
            ])
        #expect(OBDScanPlan.freezeFrameDTC.hex == "020200")
        #expect(OBDScanPlan.freezeFrameSupport.hex == "020000")
        #expect(
            OBDInfoPlan.standard.requests.map(\.hex) == ["0900", "0902", "0904", "0906", "090A"])
    }

    @Test("service counts reject truncation")
    func truncation() {
        #expect(
            ServiceResponse.decode([0x43, 0x02, 0x01, 0x33])
                == .unrecognized([0x43, 0x02, 0x01, 0x33]))
        #expect(
            ServiceResponse.decode([0x49, 0x04, 0x02] + Array(repeating: 0, count: 16))
                == .unrecognized([0x49, 0x04, 0x02] + Array(repeating: 0, count: 16)))
        #expect(ServiceResponse.decode([0x42, 0x02, 0x00]) == .unrecognized([0x42, 0x02, 0x00]))
        #expect(
            ServiceResponse.decode([0x42, 0x02, 0x00, 0x00, 0x00])
                == .freezeFrameDTC(frame: 0, dtc: nil))
        #expect(
            ServiceResponse.decode([0x43, 0x00, 0x01, 0x33])
                == .unrecognized([0x43, 0x00, 0x01, 0x33]))
        #expect(
            ServiceResponse.decode([0x47, 0x01, 0x00, 0x00])
                == .unrecognized([0x47, 0x01, 0x00, 0x00]))
        #expect(
            ServiceResponse.decode([0x47, 0x01, 0x01, 0x71, 0x00, 0x00])
                == .dtcs(service: .pendingDTCs, codes: [DTC(code: "P0171")].compactMap { $0 }))
        #expect(
            ServiceResponse.decode([0x7F, 0x03, 0x11, 0x00])
                == .unrecognized([0x7F, 0x03, 0x11, 0x00]))
    }

    @Test("request context prevents one optional response from overwriting another")
    func requestContext() {
        let vin = OBDRequest(service: .vehicleInfo, pid: 0x02)
        let cal = OBDRequest(service: .vehicleInfo, pid: 0x04)
        let result = OBDReportBuilder.info(observations: [
            OBDObservation(request: vin, ecu: 0x7E8, outcome: .response(.vin("VIN"))),
            OBDObservation(
                request: cal, ecu: 0x7E8,
                outcome: .response(.unrecognized([0x49, 0x04, 0x02, 0x00]))),
            OBDObservation(
                request: vin, ecu: 0x7E9,
                outcome: .response(.negative(service: .vehicleInfo, code: .conditionsNotCorrect))),
        ])
        #expect(result[0].vin == .positive("VIN"))
        #expect(result[0].calibrationIDs == .unknown([0x49, 0x04, 0x02, 0x00]))
        #expect(result[1].vin == .unavailable("negative response: conditions not correct"))
        #expect(result[0].formatted.contains("VIN: VIN"))
        #expect(result[0].formatted.contains("CAL IDs: unknown"))
    }

    @Test("freeze-frame followups require a real frame DTC and are deduplicated")
    func freezeFrameFollowups() {
        let support = ServiceResponse.freezeFrameSupportForTest
        let observations = [
            OBDObservation(
                request: OBDScanPlan.freezeFrameDTC, ecu: 0x7E8,
                outcome: .response(.freezeFrameDTC(frame: 0, dtc: nil))),
            OBDObservation(
                request: OBDScanPlan.freezeFrameDTC, ecu: 0x7E9,
                outcome: .response(.freezeFrameDTC(frame: 0, dtc: DTC(code: "P0133")))),
            OBDObservation(
                request: OBDScanPlan.freezeFrameSupport, ecu: 0x7E9, outcome: .response(support)),
        ]
        #expect(
            OBDScanPlan.freezeFrameFollowUpRequests(observations: observations).map(\.hex) == [
                "020500", "020C00",
            ])
    }

    @Test("wrong response services and adapter absence stay on the requested field")
    func directedOutcomes() {
        let pending = OBDRequest(service: .pendingDTCs)
        let readiness = OBDRequest(service: .currentData, pid: 0x01)
        let report = OBDReportBuilder.scan(observations: [
            OBDObservation(
                request: OBDRequest(service: .storedDTCs), ecu: 0x7E8,
                outcome: .response(.dtcs(service: .pendingDTCs, codes: []))),
            OBDObservation(request: pending, ecu: 0x7E8, outcome: .adapter(.noData)),
            OBDObservation(request: readiness, ecu: 0x7E8, outcome: .malformed([0x41, 0x01])),
            OBDObservation(
                request: OBDScanPlan.freezeFrameDTC, ecu: 0x7E8, outcome: .adapter(.noData)),
        ]).first
        #expect(report?.stored == .unknown([0x47]))
        #expect(report?.pending == .unavailable("no response"))
        #expect(report?.readiness == .unknown([0x41, 0x01]))
        #expect(report?.freezeFrameDTC == .unavailable("no response"))
    }

    @Test("finalization materializes per-ECU missing requests")
    func partialECU() {
        let vin = OBDRequest(service: .vehicleInfo, pid: 0x02)
        let observations = [
            OBDObservation(request: vin, ecu: 0x7E8, outcome: .response(.vin("VIN")))
        ]
        let finalized = OBDReportBuilder.finalizeObservations(
            observations, requests: [vin], ecus: [0x7E8, 0x7E9])
        let reports = OBDReportBuilder.info(observations: finalized)
        #expect(reports[0].vin == .positive("VIN"))
        #expect(reports[1].vin == .unavailable("no response"))
    }
}

private extension ServiceResponse {
    static var freezeFrameSupportForTest: ServiceResponse {
        .freezeFrame(pid: 0, frame: 0, value: .supported([0x05, 0x0C]))
    }
}
