/// The generic OBD read sequences, shared by the CLI and the app so the two cannot drift apart.
///
/// Requests go out one at a time in plan order. `NO DATA` for one request is an answer ("nobody
/// has this") and is recorded against that request. Every other adapter or transport error
/// stops the run, because the session can no longer be trusted to be in step with the adapter.
public enum GenericOBDWorkflow {
    public enum Event: Sendable, Equatable {
        case requesting(OBDRequest)
        case noResponse(OBDRequest)
    }

    public enum Failure: Error, Equatable, Sendable, CustomStringConvertible {
        /// Nothing answered the first request of the plan. Either no ECU is on this bus or the
        /// ignition is not on; the caller decides whether to ask the user and retry.
        case noVehicleResponse(ELM327AdapterMessage)

        public var description: String {
            switch self {
            case .noVehicleResponse(let message):
                return "no ECU answered (\(message)); is the ignition on?"
            }
        }
    }

    public typealias EventHandler = @Sendable (Event) -> Void

    /// Stored, pending and permanent DTCs, readiness, and freeze frame 0 for every ECU that
    /// answers. Freeze-frame values are only requested when an ECU reports a freeze-frame DTC.
    public static func scan(
        on session: ELM327Session, onEvent: @escaping EventHandler = { _ in }
    ) async throws -> [ECUReport] {
        var run = Collector(session: session, onEvent: onEvent)
        for (index, request) in OBDScanPlan.standard.requests.enumerated() {
            try await run.send(request, mustAnswer: index == 0)
        }
        try await run.send(OBDScanPlan.freezeFrameDTC)
        if OBDScanPlan.hasFreezeFrameDTC(run.observations) {
            try await run.send(OBDScanPlan.freezeFrameSupport)
            for request in OBDScanPlan.freezeFrameFollowUpRequests(observations: run.observations) {
                try await run.send(request)
            }
        }
        return OBDReportBuilder.scan(observations: run.finalized)
    }

    /// VIN, calibration IDs, CVNs and ECU names for every ECU that answers.
    public static func info(
        on session: ELM327Session, onEvent: @escaping EventHandler = { _ in }
    ) async throws -> [ECUInfoReport] {
        var run = Collector(session: session, onEvent: onEvent)
        for (index, request) in OBDInfoPlan.standard.requests.enumerated() {
            try await run.send(request, mustAnswer: index == 0)
        }
        return OBDReportBuilder.info(observations: run.finalized)
    }

    private struct Collector {
        let session: ELM327Session
        let onEvent: EventHandler
        var observations: [OBDObservation] = []
        var requested: [OBDRequest] = []
        var ecus = Set<UInt32>()

        mutating func send(_ request: OBDRequest, mustAnswer: Bool = false) async throws {
            requested.append(request)
            onEvent(.requesting(request))
            let responses: [ECUResponse]
            do {
                responses = try await session.request(request)
            } catch ELM327Error.adapter(let message)
                where message == .noData || (mustAnswer && message == .unableToConnect)
            {
                if mustAnswer { throw Failure.noVehicleResponse(message) }
                onEvent(.noResponse(request))
                return
            }
            for response in responses {
                ecus.insert(response.ecu)
                observations.append(
                    OBDObservation(
                        request: request, ecu: response.ecu,
                        outcome: .response(ServiceResponse.decode(response.payload))))
            }
        }

        var finalized: [OBDObservation] {
            OBDReportBuilder.finalizeObservations(observations, requests: requested, ecus: ecus)
        }
    }
}

extension OBDScanPlan {
    /// True when any ECU answered freeze frame 0 with a DTC, i.e. a freeze frame is stored.
    public static func hasFreezeFrameDTC(_ observations: [OBDObservation]) -> Bool {
        observations.contains { observation in
            guard observation.request == freezeFrameDTC,
                case .response(.freezeFrameDTC(frame: 0, dtc: let dtc)) = observation.outcome
            else { return false }
            return dtc != nil
        }
    }
}
