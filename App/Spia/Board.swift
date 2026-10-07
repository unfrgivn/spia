import SpiaAssist
import SpiaKit
import SpiaStore
import SwiftUI

extension DiagnosticSession {
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

    @MainActor func openQuestionCount(in interpretations: VehicleInterpretations) -> Int {
        interpretations.openQuestions(for: .problem(id)).count
            + messages.reduce(0) { count, message in
                count
                    + message.toolCalls.filter {
                        $0.name == "ask_user" && message.resolutions[$0.id] == .pending
                    }.count
            }
    }
}

extension SessionBoard.Row {
    var target: ModuleTarget? {
        if case .module(let target) = subject {
            return target
        }
        return nil
    }
}

/// How much room the board has: one line per row on a Mac or an iPad held sideways, stacked on
/// an iPhone or beside the assistant.
enum BoardLayout {
    case wide, compact

    /// The wide board's columns need about 980 points, padding included.
    init(width: CGFloat) { self = width < 980 ? .compact : .wide }
}

extension View {
    /// Keeps `width` at this view's width. On a scroll view that's the room its content has,
    /// rather than the content's own width, which depends on the layout the width picks.
    func readingWidth(_ width: Binding<CGFloat>) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { width.wrappedValue = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, newWidth in width.wrappedValue = newWidth }
            }
        }
    }
}

/// The top of a session: when it was opened and where it stands, what the car said, in one
/// sentence and then in brief, and what the owner noticed.
struct BoardHeader: View {
    @Bindable var session: DiagnosticSession
    let board: SessionBoard
    let layout: BoardLayout
    let connectionKind: ConnectionKind?

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
                let suffix: String?
                if vehicle.isDemo {
                    suffix = "Demo"
                } else if connectionKind == .replay {
                    suffix = "Recordings"
                } else {
                    suffix = nil
                }
                parts.insert(
                    suffix.map { "\(vehicle.name) · \($0)" } ?? vehicle.name, at: 0)
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

struct BoardHeadline: View {
    let headline: String
    let summary: String
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(headline)
                .font(.system(size: compact ? 32 : 46, weight: .bold))
                .tracking(compact ? -0.6 : -1)
                .foregroundStyle(Palette.primary)
                .fixedSize(horizontal: false, vertical: true)
            Text(summary)
                .font(.system(size: compact ? 16 : 19))
                .lineSpacing(compact ? 2 : 4)
                .foregroundStyle(Palette.secondary)
                .frame(maxWidth: 820, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
        }
    }
}

/// One line per part of the car, most urgent first, like a departures board. A part nobody has
/// read yet offers to read it.
struct SessionBoardView: View {
    let board: SessionBoard
    let layout: BoardLayout
    /// Nil while a check runs.
    let read: ((SessionBoard.Subject) -> Void)?
    /// The row a running check is filling in, and what it's doing right now.
    var reading: (subject: SessionBoard.Subject, step: String?, cancel: () -> Void)?
    /// Rows lit for the bulb check that plays when the adapter connects.
    var checking: Set<SessionBoard.Subject> = []
    /// Unread rows that can't be read with this adapter, and why, shown instead of Read.
    var unreadable: [SessionBoard.Subject: String] = [:]
    /// The assistant's answers, under the rows they're about.
    var notes: [SessionBoard.Subject: BoardNote] = [:]
    var interpretations: VehicleInterpretations?
    var scope: ReviewScope = .car
    var answer: ((UUID, String) -> Void)?
    var runCheck: ((StoredCheck) -> Void)?
    var askMore: ((String) -> Void)?
    /// Opens the reading history for a row.
    var open: ((SessionBoard.Row) -> Void)?
    var openAssistant: (() -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            Hairline()
            ForEach(board.rows) { row in
                VStack(alignment: .leading, spacing: 0) {
                    switch layout {
                    case .wide: wide(row)
                    case .compact: compact(row)
                    }
                    if hasQuestions(row) {
                        Chip(text: "Needs your answer", color: Palette.caution)
                            .padding(.leading, layout == .wide ? 140 : 104)
                            .padding(.top, -4)
                    }
                    if !row.codes.isEmpty, row.subject != reading?.subject {
                        CodeNamesView(
                            row: row, interpretations: interpretations, askMore: askMore,
                            scope: scope, answer: answer
                        )
                        .padding(.leading, layout == .wide ? 140 : 104)
                        .padding(.bottom, 12)
                    }
                    if let note = notes[row.subject] {
                        BoardNoteView(note: note, open: openAssistant)
                            .padding(.leading, layout == .wide ? 140 : 104)
                            .padding(.bottom, 14)
                    }
                }
                // Opaque, so a row sliding to its new place covers the rows it passes.
                .background(Palette.base)
                .accessibilityElement(children: .combine)
                Hairline()
            }
        }
        // Rows re-sort by urgency as results arrive; they slide to their new place.
        .animation(reduceMotion ? nil : .snappy(duration: 0.4), value: board.rows.map(\.id))
    }

    private func hasQuestions(_ row: SessionBoard.Row) -> Bool {
        guard let interpretations else { return false }
        if !interpretations.openQuestions(about: row.subject, code: nil, scope: scope).isEmpty {
            return true
        }
        return row.printedCodes.contains {
            !interpretations.openQuestions(about: row.subject, code: $0, scope: scope).isEmpty
        }
    }

    private func word(_ row: SessionBoard.Row, size: CGFloat) -> StatusWord {
        if row.subject == reading?.subject {
            return StatusWord(word: "Reading", tone: .working, size: size, pulsing: true)
        }
        if checking.contains(row.subject) {
            return StatusWord(word: "Check", tone: .working, size: size)
        }
        return StatusWord(row: row, size: size)
    }

    /// While Spia reads the row: what it's asking for, and a way to stop.
    @ViewBuilder private func progress(_ row: SessionBoard.Row) -> some View {
        if let reading, reading.subject == row.subject {
            Text(reading.step ?? "Starting")
                .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                .foregroundStyle(Palette.secondary)
                .lineLimit(1)
            Button("Cancel", action: reading.cancel)
                .buttonStyle(OutlineButtonStyle())
        }
    }

    private func wide(_ row: SessionBoard.Row) -> some View {
        HStack(spacing: 16) {
            word(row, size: 31)
                .frame(width: 124, alignment: .leading)
            name(row)
                .frame(width: 236, alignment: .leading)
            reading(row, size: 16)
                .frame(width: 190, alignment: .leading)
            HStack(spacing: 14) {
                if row.subject == reading?.subject {
                    progress(row)
                } else {
                    if row.status != .notRead, row.detail != placeholder(row) {
                        detail(row, size: 14)
                    }
                    action(row)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            stamp(row)
                .frame(width: 64, alignment: .trailing)
        }
        .frame(minHeight: 60)
    }

    private func compact(_ row: SessionBoard.Row) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            word(row, size: 25)
                .frame(width: 92, alignment: .leading)
            VStack(alignment: .leading, spacing: 5) {
                name(row)
                if !row.codes.isEmpty || row.value != nil { reading(row, size: 14.5) }
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    if row.subject == reading?.subject {
                        progress(row)
                    } else {
                        if row.status != .notRead { detail(row, size: 13) }
                        action(row)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 13)
    }

    private func name(_ row: SessionBoard.Row) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Group {
                if let open, row.date != nil {
                    Button {
                        open(row)
                    } label: {
                        HStack(spacing: 7) {
                            Text(row.name)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Palette.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Show history")
                } else {
                    Text(row.name)
                }
            }
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
                ForEach(row.printedCodes, id: \.self) { Text($0) }
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
        if row.status == .notRead, let reason = unreadable[row.subject] {
            Text(reason)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Palette.tertiary)
        } else if row.status == .notRead, let read {
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
/// glowing a little at night. A new word flips up into place, like a departures board, and
/// `pulsing` breathes while Spia reads the row. With Reduce Motion the word simply changes.
struct StatusWord: View {
    let word: String
    let tone: Tone
    let size: CGFloat
    var pulsing = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(word: String, tone: Tone, size: CGFloat, pulsing: Bool = false) {
        self.word = word
        self.tone = tone
        self.size = size
        self.pulsing = pulsing
    }

    init(row: SessionBoard.Row, size: CGFloat) {
        self.init(word: row.word, tone: row.status.tone, size: size)
    }

    var body: some View {
        let lit = tone != .neutral
        let color = lit ? tone.color : Palette.tertiary
        ZStack(alignment: .leading) {
            Text(word)
                .font(.system(size: size, weight: .heavy).width(.compressed))
                .textCase(.uppercase)
                .foregroundStyle(color)
                .shadow(
                    color: lit && scheme == .dark ? color.opacity(0.5) : .clear, radius: size * 0.45
                )
                .fixedSize()
                .modifier(Breathing(active: pulsing && !reduceMotion))
                .id(word)
                .transition(
                    reduceMotion
                        ? .opacity
                        : .asymmetric(
                            insertion: .offset(y: size * 0.55).combined(with: .opacity),
                            removal: .offset(y: -size * 0.55).combined(with: .opacity)))
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.35), value: word)
    }
}

/// What a row's codes are called, one line each, under the row: the printed code, then the
/// public title where SAE defines one, else why there isn't one.
private struct CodeNamesView: View {
    let row: SessionBoard.Row
    let interpretations: VehicleInterpretations?
    let askMore: ((String) -> Void)?
    let scope: ReviewScope
    let answer: ((UUID, String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(zip(row.printedCodes, row.names).enumerated()), id: \.offset) {
                _, item in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(item.0)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(Palette.secondary)
                        Text(Self.title(for: item.1))
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let failureType = item.1?.failureTypeLabel {
                            Text(failureType)
                                .font(.system(size: 12.5))
                                .foregroundStyle(Palette.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if let interpretation = interpretations?.interpretation(
                        for: row.subject, code: item.0)
                    {
                        interpretationView(interpretation, catalogTitle: Self.title(for: item.1))
                    }
                    ForEach(questions(for: item.0), id: \.id) { question in
                        QuestionView(question: question, answer: answer)
                    }
                }
            }
            if let target = row.target, let module = interpretations?.interpretation(for: target),
                row.name == target.fallbackLabel
            {
                Text("\(module.provider.displayName): likely the \(module.name); \(module.role)")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.secondary)
            }
            ForEach(moduleQuestions, id: \.id) { question in
                QuestionView(question: question, answer: answer)
            }
            if let question = row.question, let askMore,
                interpretations?.codes.contains(where: { $0.target == row.target }) == true
            {
                Button("Ask more") { askMore(question) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Palette.accent)
            }
            if let target = row.target, interpretations?.inFlight.contains(target) == true {
                Text("Looking up…")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.tertiary)
                    .modifier(Breathing(active: true))
            } else if row.target == nil, interpretations?.inFlight.contains(nil) == true {
                Text("Looking up…")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.tertiary)
                    .modifier(Breathing(active: true))
            }
        }
        .frame(maxWidth: 720, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func questions(for code: String) -> [StoredQuestion] {
        interpretations?.questions(about: row.subject, code: code, scope: scope).filter {
            $0.codes.count == 1
        } ?? []
    }

    private var moduleQuestions: [StoredQuestion] {
        interpretations?.questions(about: row.subject, code: nil, scope: scope).filter {
            $0.codes.count != 1
        } ?? []
    }

    private func interpretationView(
        _ interpretation: StoredCodeInterpretation, catalogTitle: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if interpretation.name.caseInsensitiveCompare(catalogTitle) != .orderedSame {
                Text(interpretation.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.primary)
            }
            Text(interpretation.meaning)
                .font(.system(size: 13))
                .foregroundStyle(Palette.secondary)
            Text("Check first: \(interpretation.firstCheck)")
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.secondary)
            Text(stamp(interpretation))
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.tertiary)
        }
    }

    private func stamp(_ interpretation: StoredCodeInterpretation) -> String {
        let confidence =
            interpretation.confidence == "high"
            ? "" : ", \(interpretation.confidence) confidence"
        return
            "Interpretation · \(interpretation.provider.displayName) · \(interpretation.date.formatted(date: .abbreviated, time: .omitted))\(confidence)"
    }

    private static func title(for name: CodeName?) -> String {
        guard let name else { return "Not a standard code" }
        if let entry = CodeCatalog.bundledCatalog?.entry(for: name) { return entry.title }
        return name.isGeneric
            ? "Not in the public code list" : "Manufacturer-specific; no public description"
    }
}

private struct QuestionView: View {
    let question: StoredQuestion
    let answer: ((UUID, String) -> Void)?
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Q: \(question.text)")
                .font(.system(size: 13.5))
                .foregroundStyle(Palette.primary)
            if let response = question.answer {
                Text("A: \(response)")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.tertiary)
            } else if let answer {
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Your answer", text: $text, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...4)
                        .padding(8)
                        .background(Palette.card, in: RoundedRectangle(cornerRadius: 8))
                    Button("Answer") { answer(question.id, text) }
                        .buttonStyle(OutlineButtonStyle())
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(.top, 5)
    }
}

/// The assistant's answer about a board row, or the one it's writing.
struct BoardNote: Equatable {
    let text: String
    /// The provider's name: "Claude".
    let by: String?
    let pending: Bool
}

/// An answer under the row it's about: the assistant's words beside an accent rule, the way a
/// note sits in a case file's margin, and the way into the whole conversation.
private struct BoardNoteView: View {
    let note: BoardNote
    let open: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(Palette.accent)
                .frame(width: 3)
                .modifier(Breathing(active: note.pending))
            VStack(alignment: .leading, spacing: 6) {
                Text(heading)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.accent)
                if !note.text.isEmpty {
                    Text(ReplyBlock.preview(note.text))
                        .font(.system(size: 14))
                        .lineSpacing(2)
                        .foregroundStyle(Palette.secondary)
                        .lineLimit(6)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if !note.pending, let open {
                    Button("Continue in the assistant", action: open)
                        .buttonStyle(.plain)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Palette.accent)
                }
            }
        }
        .frame(maxWidth: 720, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var heading: String {
        let name = note.by ?? "The assistant"
        return note.pending ? "\(name) is answering…" : name
    }
}

struct ReviewView: View {
    let review: StoredReview?
    let inFlight: Bool
    let untaggedQuestions: [StoredQuestion]
    let moduleLabels: [ModuleTarget: String]
    let answer: (UUID, String) -> Void
    let checks: [(StoredCheck, Bool)]
    let run: (StoredCheck) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(Palette.accent)
                    .frame(width: 3)
                    .modifier(Breathing(active: inFlight))
                VStack(alignment: .leading, spacing: 6) {
                    Text(heading)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.accent)
                    if let review, !inFlight {
                        Text(review.reading)
                            .font(.system(size: 14))
                            .lineSpacing(2)
                            .foregroundStyle(Palette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Read \(review.date, format: .dateTime.month().day().year())")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.tertiary)
                    }
                }
            }
            ForEach(untaggedQuestions, id: \.id) { question in
                QuestionView(question: question, answer: answer)
            }
            ForEach(Array(checks.enumerated()), id: \.offset) { _, item in
                let check = item.0
                if item.1 {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("Would read: \(label(for: check)), \(check.reason)")
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.secondary)
                        Button("Read") { run(check) }
                            .buttonStyle(OutlineButtonStyle())
                    }
                }
            }
        }
        .frame(maxWidth: 720, alignment: .leading)
    }

    private var heading: String {
        if inFlight {
            return "\(review?.provider.displayName ?? "The assistant") is reading the board…"
        }
        return review.map { "\($0.provider.displayName)'s reading" } ?? ""
    }

    private func label(for check: StoredCheck) -> String {
        if let module = check.module, let label = moduleLabels[module] { return label }
        return check.kind.rawValue.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

/// Fades in and out while something is at work.
private struct Breathing: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        if active {
            content.phaseAnimator([false, true]) { view, dim in
                view.opacity(dim ? 0.45 : 1)
            } animation: { _ in
                .easeInOut(duration: 0.8)
            }
        } else {
            content
        }
    }
}

/// Every check, in one menu. The board offers the check that's missing; this offers them all.
struct RunMenu: View {
    let vehicle: Vehicle?
    let workbench: Workbench
    let run: (DiagnosticJob) -> Void
    let survey: (() -> Void)?
    let connect: () -> Void
    let editModules: () -> Void

    var body: some View {
        if workbench.connection.status == nil {
            Button(action: connect) { PrimaryPill(title: "Connect", menu: false) }
                .buttonStyle(.plain)
                .fixedSize()
                .help("Connect the adapter to run checks")
        } else {
            Menu {
                ForEach([VehicleRequirement.ignitionOn, .none], id: \.self) { requirement in
                    Section(requirement.label) {
                        ForEach(Self.jobs.filter { $0.requirement == requirement }, id: \.title) {
                            job in
                            Button(job.menuTitle) { run(job) }
                        }
                        if requirement == .ignitionOn, vehicle != nil {
                            // Off for the demo, and for saved recordings without this survey.
                            Button("Survey This Car") { survey?() }
                                .disabled(survey == nil)
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
    static let jobs: [DiagnosticJob] = [.genericScan, .vehicleInfo, .adapterCheck]

    private var modules: some View {
        Menu("Read Module Trouble Codes") {
            ForEach(vehicle?.orderedModules ?? []) { module in
                if let target = module.target {
                    let job = DiagnosticJob.moduleDTCs(target)
                    Button(module.confirmed ? module.label : "\(module.label) (unconfirmed)") {
                        run(job)
                    }
                    // Only the demo can't: nobody recorded some of its modules.
                    .disabled(!workbench.canRun(job))
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
                Lamp(tone: tone)
                Text(
                    workbench.activity == nil
                        ? (workbench.adapter.kind == .replay ? "Saved recordings" : summary.title)
                        : "Reading"
                )
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

/// A section's heading, the way the case file has it: its name, a count or a note in grey, and
/// its actions on the right in the accent colour, or under the name when they don't fit.
struct SectionHeading<Actions: View>: View {
    let title: String
    let note: String?
    let actions: Actions

    init(_ title: String, note: String? = nil, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.note = note
        self.actions = actions()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                name
                Spacer(minLength: 16)
                buttons
            }
            VStack(alignment: .leading, spacing: 6) {
                name
                buttons
            }
        }
    }

    private var name: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Palette.primary)
            if let note {
                Text(note)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.tertiary)
            }
        }
    }

    private var buttons: some View {
        HStack(spacing: 16) { actions }
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Palette.accent)
    }
}

extension SectionHeading where Actions == EmptyView {
    init(_ title: String, note: String? = nil) {
        self.init(title, note: note) { EmptyView() }
    }
}

/// A small lamp, lit in its tone's colour and glowing a little, or a faint disc when it's off.
/// A neutral tone lights grey, without the glow.
struct Lamp: View {
    let tone: Tone?
    var size: CGFloat = 7

    var body: some View {
        Circle()
            .fill(tone?.color ?? Palette.hairline)
            .frame(width: size, height: size)
            .shadow(
                color: tone.flatMap { $0 == .neutral ? nil : $0.color } ?? .clear, radius: size / 2
            )
            .accessibilityHidden(true)
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
