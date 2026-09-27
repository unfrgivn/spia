import AppKit
import SpiaReference
import SpiaStore
import SwiftUI

/// The vehicle's first reference photo, filling its frame, or a quiet placeholder.
struct VehiclePhoto: View {
    let references: VehicleReferences
    var isDemo = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.accentColor.opacity(0.35), Color.accentColor.opacity(0.08)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            if let first = references.photos.first {
                LocalImage(url: first.file)
            } else {
                Image(systemName: isDemo ? "play.rectangle" : "car.side")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// An image file from the app's storage, filling its frame.
struct LocalImage: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        GeometryReader { proxy in
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
            }
        }
        .task(id: url) { image = NSImage(contentsOf: url) }
        .accessibilityHidden(true)
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
