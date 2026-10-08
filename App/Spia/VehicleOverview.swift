import SpiaKit
import SpiaReference
import SpiaStore
import SwiftUI

/// The car's dashboard, followed by its problems, references, and particulars.
struct VehicleOverview: View {
    @Environment(AppModel.self) private var model
    let vehicle: Vehicle
    let references: VehicleReferences
    let show: (WorkspaceSection) -> Void
    let browse: (ReferencesView.Shelf) -> Void
    let newSession: () -> Void

    @State private var runner: DiagnosticRunCoordinator?
    @State private var editing = false
    @State private var editingModules = false
    @State private var uploadingCover = false
    @State private var problem: String?
    @State private var width: CGFloat = 1_000
    @State private var interpretationDismissed = false

    var body: some View {
        let compact = BoardLayout(width: width) == .compact
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero(compact: compact)
                if !vehicle.isDemo && vehicle.modules.isEmpty {
                    ScanCard(
                        compact: compact, disabled: workbench?.activity != nil, action: scan
                    )
                    .padding(.top, compact ? 18 : 24)
                }
                BoardHeadline(headline: board.headline, summary: board.summary, compact: compact)
                    .padding(.top, compact ? 18 : 28)
                if ScanSuggestion.shouldSuggestDeepScan(for: vehicle) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(
                            "Spia knows no modules for this make. A Deep Scan can find them (about two minutes, engine off)."
                        )
                        Button("Deep Scan…") { runner?.scan(deep: true) }
                    }
                    .font(.callout)
                    .foregroundStyle(Palette.secondary)
                    .padding(.top, 10)
                }
                if interpretations.review(for: .car) != nil
                    || interpretations.reviewInFlight.contains(.car)
                {
                    ReviewView(
                        review: interpretations.review(for: .car),
                        inFlight: interpretations.reviewInFlight.contains(.car),
                        untaggedQuestions: interpretations.review(for: .car)?.questions.filter {
                            $0.module == nil && $0.codes.isEmpty
                        } ?? [],
                        moduleLabels: moduleLabels,
                        answer: answer,
                        checks: reviewChecks(for: interpretations.review(for: .car)),
                        run: { runner?.run($0) }
                    )
                    .padding(.top, compact ? 18 : 24)
                }
                if shouldShowInterpretationConsent {
                    InterpretationConsentCard(
                        compact: compact, board: board, vehicle: vehicle,
                        interpretations: interpretations,
                        allow: {
                            interpretations.allow(model.assistant.settings.defaultProvider)
                            Task {
                                await model.interpreter.refresh(
                                    vehicle, adapter: workbench?.liveStatus)
                            }
                        }, dismiss: { interpretationDismissed = true }
                    )
                    .padding(.top, compact ? 18 : 24)
                }
                if let workbench, let activity = workbench.activity,
                    activity.vehicleID == vehicle.id,
                    activity.prompt != nil || SessionBoard.Subject(job: activity.job) == nil
                {
                    ActivityPanel(activity: activity, workbench: workbench)
                        .padding(.top, 24)
                }
                SessionBoardView(
                    board: board, layout: BoardLayout(width: width), read: runner?.reader,
                    reading: runner?.reading,
                    unreadable: runner?.unreadable(for: board) ?? [:],
                    interpretations: interpretations,
                    scope: .car,
                    answer: answer,
                    open: { runner?.historySubject = $0.subject }
                )
                .padding(.top, compact ? 18 : 22)
                if let error = interpretations.lastError {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(Palette.secondary)
                        Button("Try again") {
                            Task {
                                await model.interpreter.refresh(
                                    vehicle, adapter: workbench?.liveStatus)
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Palette.accent)
                    }
                    .padding(.top, 8)
                }
                SessionLedger(
                    vehicle: vehicle, interpretations: interpretations, compact: compact,
                    open: { show(.session($0.id)) },
                    newSession: newSession
                )
                .padding(.top, compact ? 30 : 40)
                VStack(alignment: .leading, spacing: 14) {
                    SectionHeading("References")
                    VehicleBoard(
                        readouts: [recalls, bulletins, complaints].compactMap { $0 },
                        compact: compact
                    )
                }
                .padding(.top, compact ? 30 : 40)
                referenceStatus
                    .padding(.top, 12)
                Particulars(vehicle: vehicle, identity: references.identity, compact: compact)
                    .padding(.top, compact ? 30 : 40)
            }
            .padding(.horizontal, compact ? 16 : 40)
            .padding(.vertical, compact ? 16 : 32)
            .frame(maxWidth: 1_120, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .readingWidth($width)
        .background(Palette.base)
        .navigationTitle(vehicle.name)
        .platformSubtitle("Overview")
        .platformInlineTitle()
        .toolbar { overviewToolbar }
        .task(id: vehicle.id) {
            runner = DiagnosticRunCoordinator(vehicle: vehicle, session: nil, model: model)
            await model.interpreter.refresh(vehicle, adapter: workbench?.liveStatus)
            #if DEBUG
                if Fixture.screen == .onboarding { runner?.scan() }
                if Fixture.screen == .surveyResults || Fixture.screen == .surveyResultsMissing
                    || Fixture.screen == .surveyResultsSearched,
                    let entry = vehicle.entries.sorted(by: { $0.date < $1.date }).last,
                    case .survey(let report) = entry.result?.payload
                {
                    runner?.reviewReport = report
                }
            #endif
        }
        .onChange(of: runner?.workbench?.connection) { _, state in
            if case .ready = state { runner?.startPendingScanIfReady() }
        }
        .sheet(isPresented: $editing) { VehicleSettings(vehicle: vehicle, references: references) }
        .sheet(isPresented: $editingModules) { ModulesEditor(vehicle: vehicle) }
        .sheet(isPresented: connectionPresentation) {
            if let workbench {
                ConnectionAssistant(
                    vehicle: vehicle, workbench: workbench,
                    purpose: runner?.isScanPending == true
                        ? "Connect the adapter, and Spia will scan the car." : nil
                ) { runner?.refresh($0) }
            }
        }
        .surveyReview(runner: runner, vehicle: vehicle)
        .readingHistory(runner: runner, vehicle: vehicle)
        .fileImporter(isPresented: $uploadingCover, allowedContentTypes: [.image]) { result in
            switch result {
            case .success(let url):
                let problems = model.garage.addImages(from: [url], to: vehicle, asCover: true)
                if !problems.isEmpty { problem = problems.joined(separator: "\n") }
            case .failure(let error):
                problem = error.localizedDescription
            }
        }
        .errorAlert($problem)
    }

    // MARK: - The bay

    private func scan() {
        runner?.scan()
    }

    private var workbench: Workbench? { runner?.workbench }

    private var connectionPresentation: Binding<Bool> {
        Binding(
            get: { runner?.connectRequested == true },
            set: { isPresented in
                if !isPresented {
                    runner?.connectRequested = false
                    runner?.cancelPendingScanIfDisconnected()
                }
            })
    }

    private func requestConnection() { runner?.connectRequested = true }

    @ToolbarContentBuilder private var overviewToolbar: some ToolbarContent {
        #if os(macOS)
            ToolbarItemGroup(placement: .primaryAction) {
                if let workbench {
                    AdapterIndicator(workbench: workbench) { requestConnection() }
                    ScanMenu(
                        vehicle: vehicle, workbench: workbench, run: { runner?.run($0) },
                        scan: { runner?.scan() }, deepScan: { runner?.scan(deep: true) },
                        deepScanMessage: runner?.deepScanMessage(),
                        connect: requestConnection,
                        editModules: { editingModules = true })
                }
            }
        #else
            ToolbarItemGroup(placement: .bottomBar) {
                if let workbench {
                    AdapterIndicator(workbench: workbench) { requestConnection() }
                    Spacer()
                    ScanMenu(
                        vehicle: vehicle, workbench: workbench, run: { runner?.run($0) },
                        scan: { runner?.scan() }, deepScan: { runner?.scan(deep: true) },
                        deepScanMessage: runner?.deepScanMessage(),
                        connect: requestConnection,
                        editModules: { editingModules = true })
                }
            }
        #endif
    }

    private var board: SessionBoard { vehicle.board(live: workbench?.liveStatus) }
    private var interpretations: VehicleInterpretations {
        model.interpreter.interpretations(for: vehicle)
    }

    private var moduleLabels: [ModuleTarget: String] {
        Dictionary(
            uniqueKeysWithValues: vehicle.orderedModules.compactMap { module in
                module.target.map { ($0, module.label) }
            })
    }

    private func answer(_ id: UUID, _ text: String) {
        Task {
            await model.interpreter.answer(
                vehicle, questionID: id, text: text, adapter: workbench?.liveStatus)
        }
    }

    private func reviewChecks(for review: StoredReview?) -> [(StoredCheck, Bool)] {
        review?.checks.compactMap { check in
            guard let job = check.job, runner?.workbench?.canRun(job) == true else { return nil }
            let read = board.rows.contains { row in
                switch (check.kind, check.module, row.subject) {
                case (.moduleCodes, let module?, .module(let target)): module == target
                case (.genericScan, _, .engine), (.vehicleInfo, _, .engine),
                    (.adapterCheck, _, .battery):
                    true
                default: false
                }
            }
            return (check, !read)
        } ?? []
    }
    private var shouldShowInterpretationConsent: Bool {
        !interpretationDismissed && !board.rows.allSatisfy { $0.codes.isEmpty }
            && model.assistant.settings.defaultProvider.isCloud && interpretations.consent == nil
    }
    /// The car as the garage shows it, always drawn dark: beside its photo when there's room,
    /// under it when there isn't, so the name never sits on the car.
    private func hero(compact: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: compact ? 18 : 22, style: .continuous)
        return Group {
            if compact {
                VStack(alignment: .leading, spacing: 0) {
                    ShowroomPhoto(vehicle: vehicle, references: references, fadesIn: false)
                        .frame(height: 210)
                        .overlay(alignment: .bottom) {
                            LinearGradient(
                                colors: [.clear, Palette.base], startPoint: .top,
                                endPoint: .bottom
                            )
                            .frame(height: 70)
                        }
                        .overlay(alignment: .topTrailing) { credit }
                    nameplate(compact: true)
                        .padding(.horizontal, 18)
                        .padding(.bottom, 18)
                }
            } else {
                nameplate(compact: false)
                    .frame(width: 480, alignment: .leading)
                    .padding(32)
                    .frame(maxWidth: .infinity, alignment: .bottomLeading)
                    .frame(height: 300, alignment: .bottomLeading)
                    .background(alignment: .trailing) {
                        ShowroomPhoto(vehicle: vehicle, references: references)
                            .frame(width: 760)
                    }
                    .overlay(alignment: .bottomTrailing) { credit }
            }
        }
        .background(Palette.base)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Palette.hairline))
        .environment(\.colorScheme, .dark)
    }

    private func nameplate(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(vehicle.name)
                .font(.system(size: compact ? 26 : 36, weight: .bold))
                .tracking(compact ? -0.4 : -0.7)
                .foregroundStyle(Palette.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if !heroDetail.isEmpty {
                Text(heroDetail)
                    .font(.system(size: compact ? 13 : 14))
                    .foregroundStyle(Palette.secondary)
                    .lineLimit(2)
                    .padding(.top, compact ? 4 : 6)
            }
            HStack(spacing: 16) {
                if vehicle.isDemo { Chip(text: "Demo") }
                Button("Edit Vehicle…") { editing = true }
                Button("Change Cover…") { uploadingCover = true }
                    .help("Use a photo of your car instead of the reference photo")
            }
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Palette.accent)
            .padding(.top, 14)
        }
    }

    @ViewBuilder private var credit: some View {
        if let photo = references.cover(for: vehicle)?.reference {
            PhotoCredit(photo: photo)
                .foregroundStyle(Palette.tertiary)
                .padding(12)
        }
    }

    private var heroDetail: String { vehicle.detail(identity: references.identity) }

    // MARK: - The board

    private var recalls: Readout {
        let title = references.identity?.title ?? "this model"
        guard let recalls = references.safety?.recalls else {
            if vehicle.vin == nil {
                return Readout(
                    id: "recalls", word: "No VIN", tone: .neutral, name: "Recalls",
                    detail:
                        "Add the VIN, or read vehicle information from the Overview, to look up recalls and service bulletins.",
                    actions: [.init("Edit Vehicle…") { editing = true }])
            }
            return Readout(
                id: "recalls", word: references.isRefreshing ? "Looking" : "Unknown",
                tone: .neutral, name: "Recalls",
                detail: references.isRefreshing
                    ? "Looking them up with NHTSA." : "They couldn't be looked up yet.",
                actions: [])
        }
        guard !recalls.isEmpty else {
            return Readout(
                id: "recalls", word: "None", tone: .good, name: "Recalls",
                detail: "No safety recalls filed for the \(title).", actions: [])
        }
        var actions: [Readout.Action] = [.init("See Recalls") { browse(.recalls) }]
        if let vin = vehicle.vin, let url = NHTSA.recallLookupURL(vin: vin) {
            actions.append(.init("Check This VIN", url: url))
        }
        let pronoun = recalls.count == 1 ? "it" : "them"
        return Readout(
            id: "recalls", word: "\(recalls.count)", tone: .attention,
            name: recalls.count == 1 ? "Recall" : "Recalls",
            detail:
                "Filed for the \(title). A dealer may already have done \(pronoun); nhtsa.gov knows which are still open for this VIN.",
            actions: actions)
    }

    private var bulletins: Readout? {
        guard let count = references.safety?.bulletins.count else { return nil }
        return Readout(
            id: "bulletins", word: "\(count)", tone: .neutral, name: "Service bulletins",
            detail: "Filed with NHTSA for this model, not for this car in particular.",
            actions: count > 0 ? [.init("Browse") { browse(.bulletins) }] : [])
    }

    private var complaints: Readout? {
        guard let count = references.safety?.complaints.count else { return nil }
        return Readout(
            id: "complaints", word: "\(count)", tone: .neutral, name: "Owner complaints",
            detail: "Reported to NHTSA by other owners of this model.",
            actions: count > 0 ? [.init("Browse") { browse(.complaints) }] : [])
    }

    private var referenceStatus: some View {
        HStack(spacing: 8) {
            if references.isRefreshing {
                ProgressView().controlSize(.small)
                Text("Looking up references…")
            } else if let snapshot = references.snapshot {
                if snapshot.problems.isEmpty {
                    Text(
                        "From NHTSA and Wikimedia Commons, updated \(snapshot.fetchedAt, format: .relative(presentation: .named))."
                    )
                } else {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(Palette.caution)
                    Text(snapshot.problems.joined(separator: " · "))
                        .lineLimit(2)
                }
            }
            Spacer()
            if vehicle.vin != nil {
                Button("Refresh") {
                    Task { await references.refresh(vehicle.referenceInput) }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.accent)
                .disabled(references.isRefreshing)
            }
        }
        .font(.system(size: 12.5))
        .foregroundStyle(Palette.tertiary)
    }

}

/// One line of the vehicle's board: a reading in the board's condensed type, what it's about,
/// what it means, and where to go from it.
private struct Readout: Identifiable {
    struct Action: Identifiable {
        let title: String
        var url: URL?
        var perform: (() -> Void)?

        var id: String { title }

        init(_ title: String, url: URL) {
            self.title = title
            self.url = url
        }

        init(_ title: String, perform: @escaping () -> Void) {
            self.title = title
            self.perform = perform
        }
    }

    let id: String
    let word: String
    let tone: Tone
    var pulsing = false
    let name: String
    let detail: String
    let actions: [Action]
}

/// The vehicle's lines, laid out like the session's board so the two read the same way.
private struct VehicleBoard: View {
    let readouts: [Readout]
    let compact: Bool

    var body: some View {
        VStack(spacing: 0) {
            Hairline()
            ForEach(readouts) { readout in
                Group {
                    if compact { stacked(readout) } else { wide(readout) }
                }
                .accessibilityElement(children: .combine)
                Hairline()
            }
        }
    }

    private func wide(_ readout: Readout) -> some View {
        HStack(spacing: 16) {
            StatusWord(word: readout.word, tone: readout.tone, size: 31, pulsing: readout.pulsing)
                .frame(width: 124, alignment: .leading)
            Text(readout.name)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Palette.primary)
                .lineLimit(2)
                .frame(width: 236, alignment: .leading)
            Text(readout.detail)
                .font(.system(size: 14))
                .foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            actions(readout)
        }
        .padding(.vertical, 14)
        .frame(minHeight: 60)
    }

    private func stacked(_ readout: Readout) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            StatusWord(word: readout.word, tone: readout.tone, size: 25, pulsing: readout.pulsing)
                .frame(width: 92, alignment: .leading)
            VStack(alignment: .leading, spacing: 5) {
                Text(readout.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Palette.primary)
                Text(readout.detail)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                actions(readout)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 13)
    }

    private func actions(_ readout: Readout) -> some View {
        HStack(spacing: 14) {
            ForEach(readout.actions) { action in
                Group {
                    if let url = action.url {
                        Link(action.title, destination: url)
                    } else {
                        Button(action.title) { action.perform?() }
                            .buttonStyle(.plain)
                    }
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.accent)
            }
        }
        .fixedSize()
    }
}

/// Every session on the car, newest first, like the case file's lines: its lamp, what it's
/// about, what its board says, and when it was last touched.
private struct SessionLedger: View {
    let vehicle: Vehicle
    let interpretations: VehicleInterpretations
    let compact: Bool
    let open: (DiagnosticSession) -> Void
    let newSession: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeading("Problems", note: count) {
                Button("New Problem", action: newSession)
            }
            .padding(.bottom, 10)
            Hairline()
            if vehicle.sessions.isEmpty {
                Text("Start a problem to work on this car.")
                    .font(.callout)
                    .foregroundStyle(Palette.secondary)
                    .padding(.vertical, 12)
            }
            ForEach(vehicle.orderedSessions) { session in
                Button {
                    open(session)
                } label: {
                    line(session)
                }
                .buttonStyle(.plain)
                Hairline()
            }
        }
    }

    private var count: String? {
        switch vehicle.sessions.count {
        case 0: nil
        case 1: "1 problem"
        case let count: "\(count) problems"
        }
    }

    private func line(_ session: DiagnosticSession) -> some View {
        let summary = session.entries.isEmpty ? session.problem : session.board().headline
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            Lamp(tone: session.lamp, size: 8)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(session.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.primary)
                    if session.status == .resolved {
                        Text("Resolved")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Palette.pass)
                    }
                }
                if !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: 13.5))
                        .foregroundStyle(Palette.secondary)
                        .lineLimit(compact ? 2 : 1)
                }
                let questions = session.openQuestionCount(in: interpretations)
                if questions > 0 {
                    Text(questions == 1 ? "1 question" : "\(questions) questions")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Palette.caution)
                }
            }
            Spacer(minLength: 8)
            Text(session.updatedAt, format: .relative(presentation: .named))
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.tertiary)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.tertiary)
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

/// What the car is, from the VIN and the owner: what it is in one group, what drives it in
/// another.
private struct Particulars: View {
    let vehicle: Vehicle
    let identity: VehicleIdentity?
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeading("Particulars")
            if compact {
                VStack(alignment: .leading, spacing: 22) { groups }
            } else {
                HStack(alignment: .top, spacing: 48) { groups }
            }
            ForEach(identity?.decoderNotes ?? [], id: \.self) { note in
                Label(note, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.caution)
            }
            if !vehicle.notes.isEmpty {
                Text(vehicle.notes)
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var groups: some View {
        group(
            "Identity",
            [
                ("VIN", vehicle.vin, true), ("Model", identity?.title, false),
                ("Trim", vehicle.trim ?? identity?.trim, false),
                ("Platform", identity?.series, false), ("Body", identity?.bodyClass, false),
                ("Built in", identity?.plantCountry?.capitalized, false),
                ("Colour", vehicle.colorName ?? vehicle.color?.displayName, false),
            ])
        group(
            "Powertrain",
            [
                ("Engine", identity?.engine, false),
                ("Transmission", identity?.transmission, false),
                ("Drive", identity?.driveType, false), ("Fuel", identity?.fuel, false),
            ])
    }

    private func group(_ title: String, _ facts: [(String, String?, Bool)]) -> some View {
        let known = facts.compactMap { label, value, mono in value.map { (label, $0, mono) } }
        return VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.tertiary)
            if known.isEmpty {
                Text("Not known yet")
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.tertiary)
            }
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
                ForEach(known, id: \.0) { label, value, mono in
                    GridRow {
                        Text(label)
                            .foregroundStyle(Palette.tertiary)
                        Text(value)
                            .font(mono ? .system(size: 14, design: .monospaced) : .system(size: 14))
                            .foregroundStyle(Palette.primary)
                            .textSelection(.enabled)
                    }
                    .font(.system(size: 14))
                }
            }
        }
    }
}
