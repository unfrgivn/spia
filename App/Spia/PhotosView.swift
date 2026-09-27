import SpiaReference
import SpiaStore
import SwiftUI

/// The owner's photos of the car and reference photos of the model, trim, and colour. Any of
/// them can be the cover.
struct PhotosView: View {
    @Environment(AppModel.self) private var model
    let vehicle: Vehicle
    let references: VehicleReferences

    @State private var importing = false
    @State private var editing = false
    @State private var removing: VehicleImage?
    @State private var problem: String?

    private let columns = [GridItem(.adaptive(minimum: 220), spacing: 16)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                ownPhotos
                referencePhotos
            }
            .padding(24)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(vehicle.name)
        .platformSubtitle("Photos")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    importing = true
                } label: {
                    Label("Add Photos", systemImage: "plus")
                }
                .help("Add photos of your car")
            }
        }
        .fileImporter(
            isPresented: $importing, allowedContentTypes: [.image], allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls): add(urls)
            case .failure(let error): problem = error.localizedDescription
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            add(urls)
            return true
        }
        .sheet(isPresented: $editing) { VehicleSettings(vehicle: vehicle, references: references) }
        .confirmationDialog(
            "Remove this photo?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            presenting: removing
        ) { image in
            Button("Remove", role: .destructive) { remove(image) }
        } message: { _ in
            Text("It's deleted from Spia's library on this Mac. The original file isn't touched.")
        }
        .errorAlert($problem)
    }

    // MARK: - Sections

    private var ownPhotos: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your photos").font(.title2.weight(.semibold))
            Text(
                "Photos of your car. Once you add one, it's the cover instead of the reference photo. Drop images here or add them; they're resized and stripped of location data."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                ForEach(vehicle.orderedImages) { image in
                    let file = model.garage.files.url(for: image.path)
                    let isCover = file == coverFile
                    PhotoTile(file: file, isCover: isCover) {
                        if !isCover {
                            Button("Use as Cover") { setCover(image) }
                            Divider()
                        }
                        Button("Remove…", role: .destructive) { removing = image }
                    } footer: {
                        HStack {
                            Text(image.addedAt, format: .dateTime.year().month().day())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            if !isCover {
                                Button("Use as Cover") { setCover(image) }
                                    .controlSize(.small)
                            }
                        }
                    }
                }
                Button {
                    importing = true
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "photo.badge.plus")
                            .font(.system(size: 28))
                            .foregroundStyle(.tint)
                        Text("Add Photos…").font(.headline)
                    }
                    .frame(maxWidth: .infinity, minHeight: 150)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(
                                Color.primary.opacity(0.18),
                                style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var referencePhotos: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Reference photos").font(.title2.weight(.semibold))
                Spacer()
                if references.isRefreshing {
                    ProgressView().controlSize(.small)
                }
                Button("Change Trim or Color…") { editing = true }
                Button("Search Again") {
                    Task { await references.refresh(vehicle.referenceInput) }
                }
                .disabled(references.isRefreshing)
            }
            Text(searchDescription)
                .font(.callout)
                .foregroundStyle(.secondary)
            if references.photos.isEmpty, !references.isRefreshing {
                Text("None found yet.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 20)
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                ForEach(references.photos, id: \.photo.id) { entry in
                    PhotoTile(file: entry.file, isCover: entry.file == coverFile) {
                        Link("Open on Wikimedia Commons", destination: entry.photo.pageURL)
                    } footer: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.photo.caption)
                                .font(.caption)
                                .lineLimit(2)
                            PhotoCredit(photo: entry.photo)
                        }
                    }
                }
            }
        }
    }

    /// The photo standing for the vehicle right now, chosen or automatic.
    private var coverFile: URL? { references.cover(for: vehicle)?.file }

    private var searchDescription: String {
        let query = vehicle.referenceInput.photoQuery(identity: references.identity)
        var text = "Freely licensed photos from Wikimedia Commons matching \(query.summary)"
        if vehicle.coverImage == nil {
            text += ". The best match is the cover until you add your own"
        }
        if vehicle.color == nil && vehicle.colorName == nil {
            text += ". Add your car's colour to see ones that look like it"
        }
        return text + "."
    }

    // MARK: - Actions

    private func add(_ urls: [URL]) {
        let problems = model.garage.addImages(from: urls, to: vehicle)
        if !problems.isEmpty {
            problem = "Some photos couldn't be added:\n" + problems.joined(separator: "\n")
        }
    }

    private func remove(_ image: VehicleImage) {
        do { try model.garage.delete(image) } catch { problem = String(describing: error) }
    }

    private func setCover(_ image: VehicleImage) {
        do { try model.garage.setCover(image) } catch { problem = String(describing: error) }
    }
}

/// A photo with its actions in a menu (also on right-click) and a cover badge.
private struct PhotoTile<Actions: View, Footer: View>: View {
    let file: URL
    let isCover: Bool
    @ViewBuilder let actions: Actions
    @ViewBuilder let footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LocalImage(url: file)
                .aspectRatio(3 / 2, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if isCover {
                        Label("Cover", systemImage: "star.fill")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.thinMaterial, in: Capsule())
                            .padding(8)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    Menu {
                        actions
                    } label: {
                        Image(systemName: "ellipsis.circle.fill")
                            .font(.title3)
                            .symbolRenderingMode(.hierarchical)
                    }
                    .platformBorderlessMenu()
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .padding(8)
                    .accessibilityLabel("Photo actions")
                }
                .contextMenu { actions }
            footer
        }
    }
}
