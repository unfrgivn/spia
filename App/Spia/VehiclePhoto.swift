import SpiaReference
import SpiaStore
import SwiftUI

/// The vehicle's cover (the owner's pick, else the best reference photo), filling its frame, or
/// a quiet placeholder: just the paint colour while photos are looked up, then a car's outline.
struct VehiclePhoto: View {
    let vehicle: Vehicle
    let references: VehicleReferences

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [paint.opacity(0.45), paint.opacity(0.1)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            if let cover = references.cover(for: vehicle) {
                LocalImage(url: cover.file)
            } else if !references.isRefreshing {
                GeometryReader { proxy in
                    Image(systemName: "car.side")
                        .font(.system(size: min(44, proxy.size.width * 0.34), weight: .light))
                        .foregroundStyle(.secondary)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
        }
    }

    private var paint: Color { vehicle.color?.swatch ?? .accentColor }
}

/// A vehicle's photo coming out of the dark, as in the garage: darkened at the top, where a
/// stranger's background usually is, and eased in from the left edge so the fade has no seam.
/// Meant as a background, so its size never decides its container's.
struct ShowroomPhoto: View {
    let vehicle: Vehicle
    let references: VehicleReferences
    /// Eased in a little, to say the photo's container can be opened.
    var raised = false
    /// Fade in from the left, for a photo behind text on the left.
    var fadesIn = true

    var body: some View {
        VehiclePhoto(vehicle: vehicle, references: references)
            .scaleEffect(raised ? 1.025 : 1)
            .animation(.easeOut(duration: 0.3), value: raised)
            .overlay {
                LinearGradient(
                    stops: [
                        .init(color: Palette.base.opacity(0.85), location: 0),
                        .init(color: .clear, location: 0.4),
                    ],
                    startPoint: .top, endPoint: .bottom)
            }
            .clipped()
            .mask {
                if fadesIn {
                    LinearGradient(
                        stops: [
                            .init(color: .black.opacity(0), location: 0),
                            .init(color: .black.opacity(0.08), location: 0.2),
                            .init(color: .black.opacity(0.35), location: 0.38),
                            .init(color: .black.opacity(0.75), location: 0.55),
                            .init(color: .black, location: 0.7),
                        ],
                        startPoint: .leading, endPoint: .trailing)
                } else {
                    Rectangle()
                }
            }
    }
}

/// Credit for a Commons photo, linking to its page with the full license.
struct PhotoCredit: View {
    let photo: ReferencePhoto

    var body: some View {
        Link(destination: photo.pageURL) {
            Text("Photo: \(photo.credit)")
                .font(.caption2)
                .lineLimit(1)
        }
        .help("\(photo.caption), Wikimedia Commons")
    }
}

extension Vehicle {
    /// `S Q4 · M157 · 3.0 L V6 (M156B) · AWD · Black`: the owner's trim and colour first, then
    /// what the VIN decoded to.
    func detail(identity: VehicleIdentity?) -> String {
        let parts: [String?] = [
            trim ?? identity?.trim, identity?.series, identity?.engine, identity?.driveType,
            colorName ?? color?.displayName,
        ]
        return parts.compactMap { $0 }.joined(separator: " · ")
    }
}

extension PaintColor {
    var swatch: Color {
        switch self {
        case .black: return Color(white: 0.1)
        case .white: return Color(white: 0.96)
        case .silver: return Color(white: 0.75)
        case .gray: return Color(white: 0.45)
        case .blue: return Color(red: 0.12, green: 0.3, blue: 0.7)
        case .red: return Color(red: 0.75, green: 0.1, blue: 0.12)
        case .green: return Color(red: 0.12, green: 0.45, blue: 0.25)
        case .brown: return Color(red: 0.42, green: 0.27, blue: 0.16)
        case .beige: return Color(red: 0.86, green: 0.8, blue: 0.66)
        case .gold: return Color(red: 0.78, green: 0.63, blue: 0.3)
        case .yellow: return Color(red: 0.95, green: 0.8, blue: 0.15)
        case .orange: return Color(red: 0.93, green: 0.45, blue: 0.1)
        case .purple: return Color(red: 0.42, green: 0.2, blue: 0.55)
        }
    }
}

/// The paint colour, chosen from swatches, and the maker's name for it.
struct PaintPicker: View {
    @Binding var color: PaintColor?
    @Binding var name: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Color") {
                HStack(spacing: 6) {
                    ForEach(PaintColor.allCases) { paint in
                        Button {
                            color = color == paint ? nil : paint
                        } label: {
                            Circle()
                                .fill(paint.swatch)
                                .frame(width: 18, height: 18)
                                .overlay(Circle().strokeBorder(Color.primary.opacity(0.25)))
                                .overlay {
                                    if color == paint {
                                        Circle().strokeBorder(Color.accentColor, lineWidth: 2.5)
                                            .padding(-4)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .help(paint.displayName)
                        .accessibilityLabel(paint.displayName)
                        .accessibilityAddTraits(color == paint ? .isSelected : [])
                    }
                }
            }
            TextField(
                "Paint name", text: $name,
                prompt: Text(
                    color.map {
                        "Optional, e.g. the maker's name for \($0.displayName.lowercased())"
                    }
                        ?? "Optional, e.g. Blu Emozione"))
            Text(
                "VINs don't record the colour. It helps Spia find reference photos that look like your car."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

extension Garage {
    /// Adds picked or dropped image files as the owner's photos of the vehicle, in Finder's name
    /// order (pickers and drops hand them over in any order). Returns what couldn't be added.
    func addImages(from urls: [URL], to vehicle: Vehicle, asCover: Bool = false) -> [String] {
        let sorted = urls.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        var problems: [String] = []
        for (index, url) in sorted.enumerated() {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                try addImage(Data(contentsOf: url), to: vehicle, asCover: asCover && index == 0)
            } catch {
                problems.append("\(url.lastPathComponent): \(error)")
            }
        }
        return problems
    }
}
/// An image file from the app's storage, filling its frame.
struct LocalImage: View {
    let url: URL
    @State private var image: CGImage?

    var body: some View {
        GeometryReader { proxy in
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
            }
        }
        .task(id: url) { image = await ImageLoader.load(url: url, maxPixelSize: 1600) }
        .accessibilityHidden(true)
    }
}
