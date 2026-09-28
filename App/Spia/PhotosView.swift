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
    @State private var width: CGFloat = 1_000

    var body: some View {
        let compact = BoardLayout(width: width) == .compact
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ownPhotos(compact: compact)
                referencePhotos(compact: compact)
                    .padding(.top, compact ? 32 : 48)
            }
            .padding(.horizontal, compact ? 16 : 40)
            .padding(.vertical, compact ? 16 : 32)
            .frame(maxWidth: 1_120, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .readingWidth($width)
        .background(Palette.base)
        .navigationTitle(vehicle.name)
        .platformSubtitle("Photos")
        .platformInlineTitle()
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
            Text(
                "It's deleted from Spia's library on \(PlatformText.thisDevice). The original file isn't touched."
            )
        }
        .errorAlert($problem)
    }

    // MARK: - Sections

    /// Two photos across an iPhone, three on an iPad held upright, and four or more on a Mac.
    private func grid(compact: Bool) -> [GridItem] {
        let minimum: CGFloat = width < 600 ? 150 : width < 980 ? 190 : 230
        return [GridItem(.adaptive(minimum: minimum), spacing: compact ? 12 : 18)]
    }

    private func ownPhotos(compact: Bool) -> some View {
        let count = vehicle.orderedImages.count
        return VStack(alignment: .leading, spacing: 0) {
            SectionHeading(
                "Your photos", note: count == 0 ? nil : count == 1 ? "1 photo" : "\(count) photos")
            Text(
                "Photos of your car. Once you add one, it's the cover instead of the reference photo. They're resized, and their location is removed."
            )
            .font(.system(size: 14))
            .foregroundStyle(Palette.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 6)
            LazyVGrid(
                columns: grid(compact: compact), alignment: .leading, spacing: compact ? 14 : 20
            ) {
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
                        HStack(alignment: .firstTextBaseline) {
                            Text(image.addedAt, format: .dateTime.year().month().day())
                                .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                                .foregroundStyle(Palette.tertiary)
                            Spacer(minLength: 8)
                            if !isCover {
                                Button("Use as Cover") { setCover(image) }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundStyle(Palette.accent)
                            }
                        }
                    }
                }
                AddPhotoTile { importing = true }
            }
            .padding(.top, 16)
        }
    }

    private func referencePhotos(compact: Bool) -> some View {
        let count = references.photos.count
        return VStack(alignment: .leading, spacing: 0) {
            SectionHeading(
                "Reference photos",
                note: count == 0 ? nil : count == 1 ? "1 photo" : "\(count) photos"
            ) {
                if references.isRefreshing { ProgressView().controlSize(.small) }
                Button("Change Trim or Colour…") { editing = true }
                Button("Search Again") {
                    Task { await references.refresh(vehicle.referenceInput) }
                }
                .disabled(references.isRefreshing)
            }
            Text(searchDescription)
                .font(.system(size: 14))
                .foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            if references.photos.isEmpty, !references.isRefreshing {
                Text("None found yet.")
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.tertiary)
                    .padding(.vertical, 20)
            }
            LazyVGrid(
                columns: grid(compact: compact), alignment: .leading, spacing: compact ? 14 : 20
            ) {
                ForEach(references.photos, id: \.photo.id) { entry in
                    PhotoTile(file: entry.file, isCover: entry.file == coverFile) {
                        Link("Open on Wikimedia Commons", destination: entry.photo.pageURL)
                    } footer: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.photo.caption)
                                .font(.system(size: 12.5))
                                .foregroundStyle(Palette.secondary)
                                .lineLimit(2)
                            PhotoCredit(photo: entry.photo)
                                .foregroundStyle(Palette.tertiary)
                        }
                    }
                }
            }
            .padding(.top, 16)
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

/// A photo with its actions in a menu (also on a right-click or a long press), and a mark on
/// the cover.
private struct PhotoTile<Actions: View, Footer: View>: View {
    let file: URL
    let isCover: Bool
    @ViewBuilder let actions: Actions
    @ViewBuilder let footer: Footer

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(alignment: .leading, spacing: 8) {
            LocalImage(url: file)
                .aspectRatio(3 / 2, contentMode: .fit)
                .clipShape(shape)
                .overlay(shape.strokeBorder(Palette.hairline))
                .overlay(alignment: .topLeading) {
                    if isCover {
                        Text("Cover")
                            .font(.system(size: 12, weight: .heavy).width(.compressed))
                            .textCase(.uppercase)
                            .tracking(0.6)
                            .foregroundStyle(Palette.primary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Palette.scrim, in: Capsule())
                            .padding(8)
                            .environment(\.colorScheme, .dark)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    Menu {
                        actions
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Palette.primary)
                            .frame(width: 28, height: 28)
                            .background(Palette.scrim, in: Circle())
                            .environment(\.colorScheme, .dark)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
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

/// Where the owner's next photo goes: a dashed bay, like the garage's add rows.
private struct AddPhotoTile: View {
    let action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: "photo.badge.plus")
                    .font(.system(size: 24))
                    .foregroundStyle(Palette.accent)
                Text("Add Photos…")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.primary)
                #if os(macOS)
                    Text("or drop them here")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.tertiary)
                #endif
            }
            // About a photo's height: an aspect ratio would size to the text, not the column.
            .frame(maxWidth: .infinity, minHeight: 120)
            .background(
                shape.strokeBorder(
                    Palette.tertiary.opacity(0.45), style: StrokeStyle(lineWidth: 1.2, dash: [5]))
            )
            .contentShape(shape)
        }
        .buttonStyle(.plain)
    }
}
