import SpiaKit
import SpiaReference
import SpiaStore
import SwiftUI

/// Public records for the vehicle's make, model, and year, from NHTSA: recalls first, since
/// they can be about safety, then service bulletins and owner complaints. One search looks
/// through all three, and each shelf's count says how many of its records match.
struct ReferencesView: View {
    enum Shelf: CaseIterable, Identifiable {
        case recalls, bulletins, complaints

        var id: Self { self }

        var title: String {
            switch self {
            case .recalls: "Recalls"
            case .bulletins: "Service bulletins"
            case .complaints: "Owner complaints"
            }
        }
    }

    let vehicle: Vehicle
    let references: VehicleReferences
    @Binding var shelf: Shelf

    @State private var query = ""
    /// The component whose complaints are showing, picked in the chart.
    @State private var component: String?
    @State private var openDocument: OpenDocument?
    @State private var editing = false
    @State private var problem: String?
    @State private var width: CGFloat = 1_000

    struct OpenDocument: Identifiable {
        let bulletin: Bulletin
        let file: URL
        var id: Int { bulletin.id }
    }

    var body: some View {
        let compact = BoardLayout(width: width) == .compact
        Group {
            if let safety = references.safety {
                page(compact: compact) { shelves(safety.matching(query), compact: compact) }
                    .searchable(
                        text: $query, placement: .toolbar,
                        prompt: "Search records")
            } else {
                page(compact: compact) { unavailable(compact: compact) }
            }
        }
        .background(Palette.base)
        .navigationTitle(vehicle.name)
        .platformSubtitle("References")
        .platformInlineTitle()
        .sheet(item: $openDocument) { document in
            BulletinDocumentView(bulletin: document.bulletin, file: document.file)
        }
        .sheet(isPresented: $editing) { VehicleSettings(vehicle: vehicle, references: references) }
        .errorAlert($problem)
        #if DEBUG
            .task {
                switch Fixture.screen {
                case .bulletins: shelf = .bulletins
                case .complaints: shelf = .complaints
                default: break
                }
                if let query = Fixture.query { self.query = query }
                component = Fixture.component
            }
        #endif
    }

    /// A reading width: records are prose, and every shelf lines up on the same right edge.
    private func page<Content: View>(compact: Bool, @ViewBuilder content: () -> Content)
        -> some View
    {
        ScrollView {
            VStack(alignment: .leading, spacing: 0, content: content)
                .padding(.horizontal, compact ? 16 : 40)
                .padding(.vertical, compact ? 16 : 32)
                .frame(maxWidth: 940, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .readingWidth($width)
    }

    @ViewBuilder private func shelves(_ found: SafetyRecord, compact: Bool) -> some View {
        Text(
            "Filed with NHTSA for every \(references.identity?.title ?? "car of this model"), not this car in particular."
        )
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(Palette.tertiary)
        .fixedSize(horizontal: false, vertical: true)
        ShelfPicker(shelf: $shelf, found: found, compact: compact)
            .padding(.top, compact ? 14 : 18)
        switch shelf {
        case .recalls:
            RecallShelf(
                recalls: found.recalls, vin: vehicle.vin, searching: searching, compact: compact)
        case .bulletins:
            BulletinShelf(
                bulletins: found.bulletins, opening: references.openingBulletin,
                searching: searching, compact: compact, open: open)
        case .complaints:
            ComplaintShelf(
                complaints: found.complaints, byComponent: found.complaintsByComponent,
                component: $component, searching: searching, compact: compact)
        }
    }

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Before there are records: looking them up, no VIN to look them up with, or a lookup that
    /// failed, said the way the board says things.
    private func unavailable(compact: Bool) -> some View {
        let looking = references.isRefreshing
        return HStack(alignment: .firstTextBaseline, spacing: compact ? 12 : 16) {
            StatusWord(
                word: looking ? "Looking" : vehicle.vin == nil ? "No VIN" : "Unknown",
                tone: looking ? .working : .neutral, size: compact ? 30 : 40, pulsing: looking)
            VStack(alignment: .leading, spacing: 10) {
                Text(unavailableDetail)
                    .font(.system(size: 15))
                    .foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !looking {
                    Group {
                        if vehicle.vin == nil {
                            Button("Edit Vehicle…") { editing = true }
                        } else {
                            Button("Look Up Again") {
                                Task { await references.refresh(vehicle.referenceInput) }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.accent)
                }
            }
        }
        .padding(.top, 8)
    }

    private var unavailableDetail: String {
        let records =
            "the recalls, service bulletins, and owner complaints filed with NHTSA for this model"
        if references.isRefreshing { return "Looking up \(records)." }
        if vehicle.vin == nil {
            return
                "Add the VIN, or read vehicle information in a session, and Spia looks up \(records)."
        }
        let problems = references.snapshot?.problems ?? []
        return problems.isEmpty
            ? "They haven't been looked up yet." : problems.joined(separator: "\n")
    }

    private func open(_ bulletin: Bulletin) {
        Task {
            do {
                openDocument = OpenDocument(
                    bulletin: bulletin, file: try await references.document(for: bulletin))
            } catch {
                problem = "Couldn't open \(bulletin.number): \(error)"
            }
        }
    }
}

/// The shelves, the way a trip computer shows its pages: each one's count, big, in the board's
/// type, and the one showing underlined. While searching, the counts are the matches.
private struct ShelfPicker: View {
    @Binding var shelf: ReferencesView.Shelf
    let found: SafetyRecord
    let compact: Bool
    @Namespace private var underline
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom, spacing: compact ? 22 : 48) {
                ForEach(ReferencesView.Shelf.allCases) { item in
                    Button {
                        shelf = item
                    } label: {
                        counter(item)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(item.title), \(count(item))")
                    .accessibilityAddTraits(item == shelf ? .isSelected : [])
                }
            }
            Hairline()
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: shelf)
    }

    private func counter(_ item: ReferencesView.Shelf) -> some View {
        let showing = item == shelf
        return VStack(alignment: .leading, spacing: compact ? 2 : 4) {
            StatusWord(word: "\(count(item))", tone: tone(item), size: compact ? 30 : 40)
            Text(item.title)
                .font(.system(size: compact ? 12.5 : 13.5, weight: .semibold))
                .foregroundStyle(showing ? Palette.primary : Palette.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.bottom, compact ? 10 : 12)
        .overlay(alignment: .bottom) {
            if showing {
                Rectangle()
                    .fill(Palette.accent)
                    .frame(height: 2)
                    .matchedGeometryEffect(id: "underline", in: underline)
            }
        }
        .contentShape(Rectangle())
    }

    private func count(_ item: ReferencesView.Shelf) -> Int {
        switch item {
        case .recalls: found.recalls.count
        case .bulletins: found.bulletins.count
        case .complaints: found.complaints.count
        }
    }

    /// Recalls light amber, since they're about the car's safety; the rest are only counts.
    private func tone(_ item: ReferencesView.Shelf) -> Tone {
        item == .recalls && count(item) > 0 ? .attention : .neutral
    }
}

/// The recalls, newest first, after a way to find out which are still open on this car.
private struct RecallShelf: View {
    let recalls: [Recall]
    let vin: String?
    let searching: Bool
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let vin, let url = NHTSA.recallLookupURL(vin: vin), !recalls.isEmpty {
                lookup(url)
                Hairline()
            }
            if recalls.isEmpty {
                ShelfNote(
                    text: searching
                        ? "No recalls match."
                        : "No recalls are on file for this model and year.")
            }
            ForEach(recalls) { recall in
                RecallEntry(recall: recall, compact: compact)
                Hairline()
            }
        }
    }

    private func lookup(_ url: URL) -> some View {
        let text = Text(
            "A dealer may already have done these. nhtsa.gov knows which are still open on this car."
        )
        .foregroundStyle(Palette.secondary)
        let link = Link("Check This VIN", destination: url)
            .fontWeight(.semibold)
            .foregroundStyle(Palette.accent)
        return Group {
            if compact {
                VStack(alignment: .leading, spacing: 6) {
                    text
                    link
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    text
                    Spacer(minLength: 0)
                    link
                }
            }
        }
        .font(.system(size: 14))
        .padding(.vertical, 14)
    }
}

/// A recall with its lamp lit: amber, or red when NHTSA says not to drive the car, or to park it
/// outside. What could happen leads, since that's what an owner weighs, then the remedy.
private struct RecallEntry: View {
    let recall: Recall
    let compact: Bool
    @State private var expanded = false

    var body: some View {
        Group {
            if compact {
                VStack(alignment: .leading, spacing: 8) {
                    stamp
                    content
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    stamp.frame(width: 140, alignment: .leading)
                    content
                }
            }
        }
        .padding(.vertical, compact ? 14 : 18)
    }

    /// The lamp, and when the recall was filed; on compact, its campaign number too.
    private var stamp: some View {
        HStack(spacing: 10) {
            Lamp(tone: recall.parkIt || recall.parkOutside ? .bad : .attention, size: 8)
            Text(recall.reportDate.map { $0.formatted(.recordDate) } ?? "Undated")
            if compact { Text("· \(recall.id)") }
        }
        .font(.system(size: 12.5, weight: .medium, design: .monospaced))
        .foregroundStyle(Palette.tertiary)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(recall.components.map(NHTSA.sentenceCase).joined(separator: " · "))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Palette.primary)
                if !compact {
                    Spacer(minLength: 8)
                    Text(recall.id)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(Palette.tertiary)
                }
            }
            if let advice { StatusWord(word: advice, tone: .bad, size: 17) }
            if !recall.consequence.isEmpty {
                Text(recall.consequence)
                    .font(.system(size: 15))
                    .foregroundStyle(Palette.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !recall.remedy.isEmpty {
                Text(
                    "\(Text("Remedy").fontWeight(.semibold).foregroundStyle(Palette.primary))  \(recall.remedy)"
                )
                .lineLimit(expanded ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)
            }
            if expanded {
                Text(recall.summary)
                    .fixedSize(horizontal: false, vertical: true)
                if let campaign = recall.manufacturerCampaign {
                    Text("The maker's campaign \(campaign)")
                        .foregroundStyle(Palette.tertiary)
                }
            }
            MoreButton(expanded: $expanded)
        }
        .font(.system(size: 14))
        .foregroundStyle(Palette.secondary)
        .textSelection(.enabled)
    }

    private var advice: String? {
        if recall.parkIt { return "Don't drive it until it's repaired" }
        if recall.parkOutside { return "Park it outside until it's repaired" }
        return nil
    }
}

/// The maker's bulletins as a ledger, newest first, or best match first while searching.
private struct BulletinShelf: View {
    let bulletins: [Bulletin]
    let opening: Int?
    let searching: Bool
    let compact: Bool
    let open: (Bulletin) -> Void

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            if bulletins.isEmpty {
                ShelfNote(
                    text: searching
                        ? "No bulletins match."
                        : "No service bulletins are on file for this model and year.")
            }
            ForEach(bulletins) { bulletin in
                BulletinEntry(
                    bulletin: bulletin, isOpening: opening == bulletin.id, compact: compact
                ) { open(bulletin) }
                Hairline()
            }
        }
    }
}

private struct BulletinEntry: View {
    let bulletin: Bulletin
    let isOpening: Bool
    let compact: Bool
    let open: () -> Void

    var body: some View {
        Group {
            if compact {
                VStack(alignment: .leading, spacing: 5) {
                    date
                    text
                    action
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    date.frame(width: 140, alignment: .leading)
                    text.frame(maxWidth: .infinity, alignment: .leading)
                    action.padding(.leading, 20)
                }
            }
        }
        .padding(.vertical, compact ? 12 : 14)
    }

    private var date: some View {
        Text(bulletin.date.map { $0.formatted(.recordDate) } ?? "Undated")
            .font(.system(size: 12.5, weight: .medium, design: .monospaced))
            .foregroundStyle(Palette.tertiary)
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(bulletin.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.primary)
                .fixedSize(horizontal: false, vertical: true)
            if !bulletin.detail.isEmpty {
                Text(bulletin.detail)
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.secondary)
                    .lineLimit(2)
            }
            Text(meta)
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.tertiary)
        }
        .textSelection(.enabled)
    }

    /// The maker's number, and what it's about.
    private var meta: String {
        ([bulletin.number] + bulletin.components.filter(isInformative).map(NHTSA.sentenceCase))
            .joined(separator: " · ")
    }

    @ViewBuilder private var action: some View {
        if bulletin.documentCount > 0 {
            if isOpening {
                ProgressView().controlSize(.small)
            } else {
                Button("Open PDF", action: open)
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.accent)
                    .accessibilityLabel("Open \(bulletin.number)")
            }
        }
    }
}

/// What owners reported: how many about each component, then the reports, newest first. Picking
/// a component in the chart shows just its reports.
private struct ComplaintShelf: View {
    let complaints: [Complaint]
    let byComponent: [(component: String, count: Int)]
    @Binding var component: String?
    let searching: Bool
    let compact: Bool

    var body: some View {
        let components = byComponent.filter { isInformative($0.component) }.prefix(8)
        // A search can leave the picked component without reports; then all of them show.
        let chosen = component.flatMap { name in
            components.contains { $0.component == name } ? name : nil
        }
        let shown = chosen.map { name in complaints.filter { $0.components.contains(name) } }
        VStack(alignment: .leading, spacing: 0) {
            if complaints.isEmpty {
                ShelfNote(
                    text: searching
                        ? "No complaints match."
                        : "No owner complaints are on file for this model and year.")
            } else {
                SectionHeading("By component", note: "Pick one to see just its reports")
                    .padding(.top, compact ? 18 : 24)
                ComponentChart(components: Array(components), chosen: chosen, compact: compact) {
                    name in
                    component = name == chosen ? nil : name
                }
                .padding(.top, 10)
                .padding(.bottom, compact ? 22 : 28)
                header(count: (shown ?? complaints).count, chosen: chosen)
                    .padding(.bottom, 10)
                Hairline()
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(shown ?? complaints) { complaint in
                        ComplaintEntry(complaint: complaint, compact: compact)
                        Hairline()
                    }
                }
            }
        }
    }

    private func header(count: Int, chosen: String?) -> some View {
        SectionHeading(
            "Reports",
            note: chosen.map { "\(count) about \(NHTSA.sentenceCase($0).lowercased())" }
                ?? "\(count), newest first"
        ) {
            if chosen != nil {
                Button("Show All") { component = nil }
            }
        }
    }
}

/// Complaints per component as bars, most first. Each bar shows its component's reports when
/// pressed, and stays lit while they're showing.
private struct ComponentChart: View {
    let components: [(component: String, count: Int)]
    let chosen: String?
    let compact: Bool
    let choose: (String) -> Void

    var body: some View {
        let most = max(components.first?.count ?? 1, 1)
        VStack(alignment: .leading, spacing: 2) {
            ForEach(components, id: \.component) { entry in
                let name = NHTSA.sentenceCase(entry.component)
                Button {
                    choose(entry.component)
                } label: {
                    bar(name: name, count: entry.count, most: most, lit: entry.component == chosen)
                }
                .buttonStyle(.plain)
                .help(
                    entry.component == chosen
                        ? "Show every report" : "Show the reports about \(name.lowercased())"
                )
                .accessibilityLabel("\(name), \(entry.count)")
                .accessibilityAddTraits(entry.component == chosen ? .isSelected : [])
            }
        }
    }

    private func bar(name: String, count: Int, most: Int, lit: Bool) -> some View {
        let dimmed = chosen != nil && !lit
        return HStack(spacing: 12) {
            Text(name)
                .font(.system(size: 13.5, weight: lit ? .semibold : .regular))
                .foregroundStyle(
                    lit ? Palette.primary : dimmed ? Palette.tertiary : Palette.secondary
                )
                .lineLimit(1)
                .frame(width: compact ? 156 : 200, alignment: .leading)
            GeometryReader { proxy in
                Capsule()
                    .fill(lit ? Palette.accent : Palette.secondary.opacity(dimmed ? 0.16 : 0.38))
                    .frame(width: max(6, proxy.size.width * CGFloat(count) / CGFloat(most)))
            }
            .frame(height: 10)
            Text("\(count)")
                .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(lit ? Palette.accent : Palette.tertiary)
                .frame(width: 28, alignment: .trailing)
        }
        .frame(height: 26)
        .contentShape(Rectangle())
    }
}

/// One owner's report: when it was filed, what it's about, anything that went badly (a crash, a
/// fire, injuries), and the owner's account.
private struct ComplaintEntry: View {
    let complaint: Complaint
    let compact: Bool
    @State private var expanded = false

    var body: some View {
        Group {
            if compact {
                VStack(alignment: .leading, spacing: 6) {
                    date
                    content
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    date.frame(width: 140, alignment: .leading)
                    content
                }
            }
        }
        .padding(.vertical, compact ? 12 : 14)
    }

    private var date: some View {
        Text(complaint.dateFiled.map { $0.formatted(.recordDate) } ?? "Undated")
            .font(.system(size: 12.5, weight: .medium, design: .monospaced))
            .foregroundStyle(Palette.tertiary)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(about)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.primary)
                ForEach(outcomes, id: \.self) { StatusWord(word: $0, tone: .bad, size: 15) }
            }
            Text(NHTSA.sentenceCase(complaint.description))
                .font(.system(size: 14))
                .foregroundStyle(Palette.secondary)
                .lineLimit(expanded ? nil : 3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            MoreButton(expanded: $expanded)
        }
    }

    private var about: String {
        let names = complaint.components.filter(isInformative).map(NHTSA.sentenceCase)
        return names.isEmpty ? "Other" : names.joined(separator: " · ")
    }

    private var outcomes: [String] {
        var words: [String] = []
        if complaint.crash { words.append("Crash") }
        if complaint.fire { words.append("Fire") }
        if complaint.injuries > 0 {
            words.append(complaint.injuries == 1 ? "1 injured" : "\(complaint.injuries) injured")
        }
        return words
    }
}

private struct MoreButton: View {
    @Binding var expanded: Bool

    var body: some View {
        Button(expanded ? "Less" : "More") {
            withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
        }
        .buttonStyle(.plain)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(Palette.accent)
    }
}

private struct ShelfNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 14))
            .foregroundStyle(Palette.secondary)
            .padding(.vertical, 16)
    }
}

extension FormatStyle where Self == Date.FormatStyle {
    /// NHTSA dates are calendar dates at midnight UTC; shown in local time they'd slip a day.
    static var recordDate: Date.FormatStyle {
        var style = Date.FormatStyle(date: .abbreviated, time: .omitted)
        style.timeZone = .gmt
        return style
    }
}

/// NHTSA's catch-all component says nothing, so it isn't shown.
private func isInformative(_ component: String) -> Bool { component != "UNKNOWN OR OTHER" }

/// A bulletin's PDF, downloaded from NHTSA.
private struct BulletinDocumentView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let bulletin: Bulletin
    let file: URL

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(bulletin.number).font(.headline)
                    Text(bulletin.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                #if os(macOS)
                    Button("Open in Preview") { openURL(file) }
                #else
                    ShareLink(item: file) { Label("Share PDF", systemImage: "square.and.arrow.up") }
                #endif
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
            Divider()
            PDFDocumentView(url: file)
        }
        .platformSheetFrame(width: 720, idealWidth: 820, minHeight: 640, idealHeight: 860)
    }
}
