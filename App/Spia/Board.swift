import SpiaKit
import SpiaStore
import SwiftUI

extension [ModulePreset] {
    /// The modules the board names, in the owner's order. A preset whose IDs were edited into
    /// something that isn't one module is left out.
    var boardModules: [SessionBoard.Module] {
        compactMap { preset in
            preset.target.map { SessionBoard.Module(label: preset.label, target: $0) }
        }
    }
}

extension DiagnosticSession {
    /// What this session's results say about the car. `live` is the connected adapter's status,
    /// newer than any saved adapter check.
    func board(live: AdapterStatus? = nil) -> SessionBoard {
        let results = timeline.compactMap { entry in
            entry.result.map { SessionBoard.Result(date: entry.date, payload: $0.payload) }
        }
        return SessionBoard(
            modules: vehicle?.orderedModules.boardModules ?? [], results: results, live: live)
    }

    /// The lamp a list of sessions shows beside this one: the colour of its most urgent problem,
    /// green once everything is read and clear, and none while there's nothing to say.
    var lamp: Tone? {
        let rows = board().rows
        if let problem = rows.first(where: {
            [.fault, .codes, .low, .high, .noAnswer].contains($0.status)
        }) {
            return problem.status.tone
        }
        return rows.allSatisfy { $0.status == .clear || $0.status == .ok } ? .good : nil
    }
}

/// How much room the board has: one line per row on a Mac or an iPad held sideways, stacked on
/// an iPhone or beside the assistant.
enum BoardLayout {
    case wide, compact

    /// The wide board's columns need about 980 points, padding included.
    init(width: CGFloat) { self = width < 980 ? .compact : .wide }
}

/// The top of a session: when it was opened and where it stands, what the car said, in one
/// sentence and then in brief, and what the owner noticed.
struct BoardHeader: View {
    @Bindable var session: DiagnosticSession
    let board: SessionBoard
    let layout: BoardLayout

    var body: some View {
        let wide = layout == .wide
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if wide {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(context)
                        Text("·")
                        statusMenu
                    }
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(context)
                        statusMenu
                    }
                }
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Palette.tertiary)
            Text(board.headline)
                .font(.system(size: wide ? 46 : 32, weight: .bold))
                .tracking(wide ? -1 : -0.6)
                .foregroundStyle(Palette.primary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, wide ? 14 : 10)
            Text(board.summary)
                .font(.system(size: wide ? 19 : 16))
                .lineSpacing(wide ? 4 : 2)
                .foregroundStyle(Palette.secondary)
                .frame(maxWidth: 820, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("You noticed")
                    .fontWeight(.semibold)
                    .foregroundStyle(Palette.primary)
                TextField(
                    "What happens, when, and what you've noticed", text: $session.problem,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .foregroundStyle(Palette.secondary)
                .lineLimit(1...6)
            }
            .font(.system(size: 14.5))
            .padding(.top, 16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// On a Mac the toolbar already names the car, so the line starts with when.
    private var context: String {
        var parts = ["Opened \(Self.opened(session.startedAt))"]
        #if os(iOS)
            if let vehicle = session.vehicle {
                parts.insert(vehicle.isDemo ? "\(vehicle.name) · Demo" : vehicle.name, at: 0)
            }
        #endif
        return parts.joined(separator: " · ")
    }

    static func opened(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(date) { return "today at \(time)" }
        if Calendar.current.isDateInYesterday(date) { return "yesterday at \(time)" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private var statusMenu: some View {
        Menu {
            Picker("Status", selection: $session.status) {
                ForEach(SessionStatus.allCases, id: \.self) { status in
                    Text(status.rawValue.capitalized).tag(status)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            // One Text, so a Mac menu doesn't lift the chevron out as the label's icon.
            Text("\(session.status.rawValue.capitalized) \(Image(systemName: "chevron.down"))")
                .foregroundStyle(Palette.accent)
                .imageScale(.small)
        }
        .menuIndicator(.hidden)
        .platformBorderlessMenu()
        .fixedSize()
        .accessibilityLabel("Status: \(session.status.rawValue.capitalized)")
    }
}

/// One line per part of the car, most urgent first, like a departures board. A part nobody has
/// read yet offers to read it.
struct SessionBoardView: View {
    let board: SessionBoard
    let layout: BoardLayout
    /// Nil while a check runs.
    let read: ((SessionBoard.Subject) -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            Hairline()
            ForEach(board.rows) { row in
                Group {
                    switch layout {
                    case .wide: wide(row)
                    case .compact: compact(row)
                    }
                }
                .accessibilityElement(children: .combine)
                Hairline()
            }
        }
    }

    private func wide(_ row: SessionBoard.Row) -> some View {
        HStack(spacing: 16) {
            StatusWord(row: row, size: 31)
                .frame(width: 124, alignment: .leading)
            name(row)
                .frame(width: 236, alignment: .leading)
            reading(row, size: 16)
                .frame(width: 190, alignment: .leading)
            HStack(spacing: 14) {
                if row.status != .notRead, row.detail != placeholder(row) { detail(row, size: 14) }
                action(row)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            stamp(row)
                .frame(width: 64, alignment: .trailing)
        }
        .frame(minHeight: 60)
    }

    private func compact(_ row: SessionBoard.Row) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            StatusWord(row: row, size: 25)
                .frame(width: 92, alignment: .leading)
            VStack(alignment: .leading, spacing: 5) {
                name(row)
                if !row.codes.isEmpty || row.value != nil { reading(row, size: 14.5) }
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    if row.status != .notRead { detail(row, size: 13) }
                    action(row)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 13)
    }

    private func name(_ row: SessionBoard.Row) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(row.name)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Palette.primary)
            if let short = row.shortName, layout == .wide {
                Text(short)
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(Palette.tertiary)
            }
        }
    }

    /// The codes, or the measurement, in the row's colour. Without either, what's missing.
    @ViewBuilder private func reading(_ row: SessionBoard.Row, size: CGFloat) -> some View {
        let mono = Font.system(size: size, weight: .semibold, design: .monospaced)
        if !row.codes.isEmpty {
            HStack(spacing: 14) {
                ForEach(row.codes, id: \.self) { Text($0) }
            }
            .font(mono)
            .foregroundStyle(row.status.tone.color)
            .textSelection(.enabled)
        } else if let value = row.value {
            Text(value)
                .font(mono)
                .foregroundStyle(row.status == .ok ? Palette.primary : row.status.tone.color)
        } else {
            Text(placeholder(row))
                .font(.system(size: size - 1.5))
                .foregroundStyle(Palette.tertiary)
        }
    }

    private func placeholder(_ row: SessionBoard.Row) -> String {
        switch row.status {
        case .notRead: "No result yet"
        case .noAnswer: "No answer"
        default: "No codes"
        }
    }

    private func detail(_ row: SessionBoard.Row, size: CGFloat) -> some View {
        Text(row.detail)
            .font(.system(size: size))
            .foregroundStyle(layout == .wide ? Palette.secondary : Palette.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func action(_ row: SessionBoard.Row) -> some View {
        if row.status == .notRead, let read {
            Button("Read") { read(row.subject) }
                .buttonStyle(OutlineButtonStyle())
                .accessibilityLabel("Read \(row.name)")
        }
    }

    @ViewBuilder private func stamp(_ row: SessionBoard.Row) -> some View {
        Group {
            if row.live {
                Text("Live").foregroundStyle(Palette.working)
            } else if let date = row.date {
                Text(date, format: .dateTime.hour().minute()).foregroundStyle(Palette.tertiary)
            }
        }
        .font(.system(size: 12.5, weight: .medium))
        .monospacedDigit()
    }
}

/// A row's status the way a lit display shows it: condensed capitals in the lamp's colour,
/// glowing a little at night.
struct StatusWord: View {
    let row: SessionBoard.Row
    let size: CGFloat
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let lit = row.status.tone != .neutral
        let color = lit ? row.status.tone.color : Palette.tertiary
        Text(row.word)
            .font(.system(size: size, weight: .heavy).width(.compressed))
            .textCase(.uppercase)
            .foregroundStyle(color)
            .shadow(
                color: lit && scheme == .dark ? color.opacity(0.5) : .clear, radius: size * 0.45
            )
            .fixedSize()
    }
}

/// Every check, in one menu. The board offers the check that's missing; this offers them all.
struct RunMenu: View {
    let vehicle: Vehicle?
    let workbench: Workbench
    let run: (DiagnosticJob) -> Void
    let connect: () -> Void
    let editModules: () -> Void

    var body: some View {
        if workbench.connection.status == nil {
            Button(action: connect) { PrimaryPill(title: "Connect", menu: false) }
                .buttonStyle(.plain)
                .help("Connect the adapter to run checks")
        } else {
            Menu {
                ForEach([VehicleRequirement.ignitionOn, .none], id: \.self) { requirement in
                    Section(requirement.label) {
                        ForEach(Self.jobs.filter { $0.requirement == requirement }, id: \.title) {
                            job in
                            Button(job.title) { run(job) }
                        }
                        // Module reads always need the ignition on.
                        if requirement == .ignitionOn { modules }
                    }
                }
            } label: {
                PrimaryPill(title: "Run", menu: true)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(workbench.activity != nil)
            .help("Run a check")
        }
    }
}

extension RunMenu {
    private static let jobs: [DiagnosticJob] = [.genericScan, .vehicleInfo, .adapterCheck]

    private var modules: some View {
        Menu("Read module trouble codes") {
            ForEach(vehicle?.orderedModules ?? []) { module in
                if let target = module.target {
                    Button(module.confirmed ? module.label : "\(module.label) (unconfirmed)") {
                        run(.moduleDTCs(target))
                    }
                }
            }
            Divider()
            Button("Edit Modules…", action: editModules)
        }
    }
}

extension VehicleRequirement {
    /// What a check needs from the car, as the Run menu groups them.
    var label: String {
        switch self {
        case .none: "No car needed"
        case .ignitionOn: "Ignition on"
        }
    }
}

/// A screen's one primary action, drawn in the accent colour even in a toolbar, which would
/// otherwise flatten a menu to plain text.
struct PrimaryPill: View {
    let title: String
    var menu = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
            if menu {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
            }
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(Palette.onAccent)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(
            Palette.accent.opacity(isEnabled ? 1 : 0.4),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

/// The adapter's lamp: the one place a session shows the connection. It opens the connection
/// assistant.
struct AdapterIndicator: View {
    let workbench: Workbench
    let open: () -> Void

    var body: some View {
        let summary = ConnectionSummary(adapter: workbench.adapter, state: workbench.connection)
        let tone = workbench.activity == nil ? summary.tone : .working
        Button(action: open) {
            HStack(spacing: 7) {
                Circle()
                    .fill(tone.color)
                    .frame(width: 7, height: 7)
                    .shadow(color: tone == .neutral ? .clear : tone.color, radius: 4)
                Text(workbench.activity == nil ? summary.title : "Reading")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.secondary)
                    .lineLimit(1)
            }
            .fixedSize()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(summary.detail)
        .accessibilityLabel("Adapter: \(summary.title)")
    }
}

/// A hairline rule between rows.
struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(Palette.hairline)
            .frame(height: 1)
    }
}

/// A small outlined button in the accent colour, for an action inside a row.
struct OutlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        OutlineButton(configuration: configuration)
    }

    private struct OutlineButton: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Palette.accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Palette.accent.opacity(0.45))
                )
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .opacity(!isEnabled ? 0.4 : configuration.isPressed ? 0.6 : 1)
        }
    }
}
