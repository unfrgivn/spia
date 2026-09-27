import AppKit
import PDFKit
import SpiaReference
import SpiaStore
import SwiftUI

/// Public records for the vehicle's make, model, and year, and photos of the model.
struct ReferencesView: View {
    let vehicle: Vehicle
    let references: VehicleReferences

    enum Tab: String, CaseIterable, Identifiable {
        case bulletins = "Service Bulletins"
        case recalls = "Recalls"
        case complaints = "Complaints"
        case photos = "Photos"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .bulletins
    @State private var query = ""
    @State private var openDocument: OpenDocument?
    @State private var problem: String?

    struct OpenDocument: Identifiable {
        let bulletin: Bulletin
        let file: URL
        var id: Int { bulletin.id }
    }

    var body: some View {
        Group {
            if let safety = references.safety {
                content(safety)
            } else if references.isRefreshing {
                ProgressView("Looking up references…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label("No references yet", systemImage: "books.vertical")
                } description: {
                    Text(
                        vehicle.vin == nil
                            ? "Add the VIN to the vehicle, or run “Read vehicle information” in a session. Spia then looks up the model's recalls, service bulletins, and owner complaints with NHTSA."
                            : (references.snapshot?.problems.joined(separator: "\n")
                                ?? "They haven't been looked up yet.")
                    )
                } actions: {
                    if vehicle.vin != nil {
                        Button("Look Up Again") {
                            Task { await references.refresh(vin: vehicle.vin, name: vehicle.name) }
                        }
                    }
                }
            }
        }
        .navigationTitle(vehicle.name)
        .navigationSubtitle("References")
        .sheet(item: $openDocument) { document in
            BulletinDocumentView(bulletin: document.bulletin, file: document.file)
        }
        .errorAlert($problem)
    }

    private func content(_ safety: SafetyRecord) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Show", selection: $tab) {
                    ForEach(Tab.allCases) { tab in
                        Text(label(tab, safety)).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(
                    "Filed with NHTSA for every \(references.identity?.title ?? "car of this model"), not this car in particular. Photos from Wikimedia Commons."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            Divider()
            switch tab {
            case .bulletins: bulletins(safety.bulletins)
            case .recalls: recalls(safety.recalls)
            case .complaints: complaints(safety)
            case .photos: photos
            }
        }
    }

    private func label(_ tab: Tab, _ safety: SafetyRecord) -> String {
        switch tab {
        case .bulletins: return "\(tab.rawValue) (\(safety.bulletins.count))"
        case .recalls: return "\(tab.rawValue) (\(safety.recalls.count))"
        case .complaints: return "\(tab.rawValue) (\(safety.complaints.count))"
        case .photos: return "\(tab.rawValue) (\(references.photos.count))"
        }
    }

    // MARK: - Bulletins

    private func bulletins(_ all: [Bulletin]) -> some View {
        let shown =
            query.trimmingCharacters(in: .whitespaces).isEmpty
            ? all : BulletinSearch.search(query, in: all, limit: all.count)
        return List(shown) { bulletin in
            BulletinRow(
                bulletin: bulletin, isOpening: references.openingBulletin == bulletin.id
            ) { open(bulletin) }
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Search bulletins")
        .overlay {
            if shown.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
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

    // MARK: - Recalls

    private func recalls(_ recalls: [Recall]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let vin = vehicle.vin, let url = NHTSA.recallLookupURL(vin: vin) {
                    HStack {
                        Text("Which of these are still open on this car?")
                        Link("Check the VIN on nhtsa.gov", destination: url)
                    }
                    .font(.callout)
                }
                if recalls.isEmpty {
                    Text("No recalls are on file for this model and year.")
                        .foregroundStyle(.secondary)
                }
                ForEach(recalls) { recall in RecallCard(recall: recall) }
            }
            .padding(20)
            .frame(maxWidth: 860, alignment: .leading)
        }
    }

    // MARK: - Complaints

    private func complaints(_ safety: SafetyRecord) -> some View {
        List {
            if !safety.complaints.isEmpty {
                Section("By component") {
                    let counts = safety.complaintsByComponent
                    let top = counts.first?.count ?? 1
                    ForEach(counts.prefix(8), id: \.component) { entry in
                        HStack {
                            Text(entry.component.capitalized)
                                .frame(width: 200, alignment: .leading)
                                .lineLimit(1)
                            GeometryReader { proxy in
                                Capsule()
                                    .fill(Color.accentColor.opacity(0.5))
                                    .frame(
                                        width: proxy.size.width * CGFloat(entry.count)
                                            / CGFloat(top))
                            }
                            .frame(height: 8)
                            Text("\(entry.count)")
                                .monospacedDigit()
                                .frame(width: 30, alignment: .trailing)
                        }
                        .font(.callout)
                    }
                }
            }
            Section("Reports") {
                ForEach(safety.complaints) { complaint in ComplaintRow(complaint: complaint) }
            }
        }
    }

    // MARK: - Photos

    private var photos: some View {
        ScrollView {
            if references.photos.isEmpty {
                Text("No photos found for this model.")
                    .foregroundStyle(.secondary)
                    .padding(40)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 16)], spacing: 16) {
                ForEach(references.photos, id: \.photo.id) { entry in
                    VStack(alignment: .leading, spacing: 6) {
                        LocalImage(url: entry.file)
                            .aspectRatio(3 / 2, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        Text(entry.photo.caption)
                            .font(.caption)
                            .lineLimit(2)
                        PhotoCredit(photo: entry.photo)
                    }
                }
            }
            .padding(20)
        }
    }
}

private struct BulletinRow: View {
    let bulletin: Bulletin
    let isOpening: Bool
    let open: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(bulletin.number)
                        .font(.caption.monospaced().weight(.medium))
                        .foregroundStyle(.secondary)
                    if let date = bulletin.date {
                        Text(date, format: .recordDate)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(bulletin.title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                if !bulletin.detail.isEmpty {
                    Text(bulletin.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                HStack(spacing: 6) {
                    ForEach(bulletin.components.filter(isInformative), id: \.self) { component in
                        Chip(text: component.capitalized)
                    }
                }
            }
            Spacer(minLength: 8)
            if bulletin.documentCount > 0 {
                if isOpening {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Open PDF", action: open)
                        .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 6)
    }
}

private struct RecallCard: View {
    let recall: Recall

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(recall.id)
                    .font(.callout.monospaced().weight(.semibold))
                if let date = recall.reportDate {
                    Text(date, format: .recordDate)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if recall.parkIt { Chip(text: "Don't drive until repaired", color: .red) }
                if recall.parkOutside { Chip(text: "Park outside", color: .red) }
            }
            HStack(spacing: 6) {
                ForEach(recall.components, id: \.self) {
                    Chip(text: $0.capitalized, color: .orange)
                }
            }
            Text(recall.summary)
            if !recall.consequence.isEmpty {
                Text("**Risk:** \(recall.consequence)").font(.callout)
            }
            if !recall.remedy.isEmpty {
                Text("**Remedy:** \(recall.remedy)").font(.callout)
            }
        }
        .textSelection(.enabled)
        .card()
    }
}

private struct ComplaintRow: View {
    let complaint: Complaint
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                if let date = complaint.dateFiled {
                    Text(date, format: .recordDate)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(complaint.components.filter(isInformative), id: \.self) {
                    Chip(text: $0.capitalized)
                }
                if complaint.crash { Chip(text: "Crash", color: .red) }
                if complaint.fire { Chip(text: "Fire", color: .red) }
            }
            Text(complaint.description.capitalizedSentences)
                .font(.callout)
                .lineLimit(expanded ? nil : 3)
                .textSelection(.enabled)
            Button(expanded ? "Less" : "More") { expanded.toggle() }
                .buttonStyle(.link)
                .font(.caption)
        }
        .padding(.vertical, 4)
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

/// NHTSA's catch-all component says nothing, so it isn't shown as a chip.
private func isInformative(_ component: String) -> Bool { component != "UNKNOWN OR OTHER" }

extension String {
    /// NHTSA stores complaint narratives in capitals; this reads more easily.
    fileprivate var capitalizedSentences: String {
        guard self == uppercased() else { return self }
        var result = ""
        var startOfSentence = true
        for character in lowercased() {
            if startOfSentence, character.isLetter {
                result.append(contentsOf: character.uppercased())
                startOfSentence = false
            } else {
                result.append(character)
            }
            if ".!?".contains(character) { startOfSentence = true }
        }
        return result
    }
}

/// A bulletin's PDF, downloaded from NHTSA.
private struct BulletinDocumentView: View {
    @Environment(\.dismiss) private var dismiss
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
                Button("Open in Preview") { NSWorkspace.shared.open(file) }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
            Divider()
            PDFDocumentView(url: file)
        }
        .frame(minWidth: 720, idealWidth: 820, minHeight: 640, idealHeight: 860)
    }
}

private struct PDFDocumentView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = PDFDocument(url: url)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url { view.document = PDFDocument(url: url) }
    }
}
