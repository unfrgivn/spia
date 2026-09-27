import Foundation
import ImageIO
import PDFKit
import SwiftUI

#if os(macOS)
    import AppKit
#endif

enum PlatformColor {
    #if os(macOS)
        static let controlBackground = Color(nsColor: .controlBackgroundColor)
        static let textBackground = Color(nsColor: .textBackgroundColor)
    #else
        static let controlBackground = Color(uiColor: .secondarySystemBackground)
        static let textBackground = Color(uiColor: .systemBackground)
    #endif
}

enum PlatformText {
    #if os(macOS)
        static let onDeviceSection = "On this Mac"
        static let nothingLeaves = "Nothing leaves this Mac."
        static let staysOnDevice = "Stays on this Mac"
    #else
        static let onDeviceSection = "On this device"
        static let nothingLeaves = "Nothing leaves this device."
        static let staysOnDevice = "Stays on this device"
    #endif
}

enum ImageLoader {
    static func load(url: URL, maxPixelSize: Int) async -> CGImage? {
        await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }.value
    }
}

extension View {
    @ViewBuilder func platformSubtitle(_ value: String) -> some View {
        #if os(macOS)
            navigationSubtitle(value)
        #else
            self
        #endif
    }

    @ViewBuilder func platformBorderlessMenu() -> some View {
        #if os(macOS)
            menuStyle(.borderlessButton)
        #else
            self
        #endif
    }

    @ViewBuilder func platformWindowFrame() -> some View {
        #if os(macOS)
            frame(minWidth: 900, minHeight: 600)
        #else
            self
        #endif
    }

    @ViewBuilder func platformCheckboxToggle() -> some View {
        #if os(macOS)
            toggleStyle(.checkbox)
        #else
            self
        #endif
    }

    @ViewBuilder func platformLinkButton() -> some View {
        #if os(macOS)
            buttonStyle(.link)
        #else
            self
        #endif
    }

    @ViewBuilder func platformSheetFrame(
        width: CGFloat, height: CGFloat? = nil,
        idealWidth: CGFloat? = nil, minHeight: CGFloat? = nil, idealHeight: CGFloat? = nil
    ) -> some View {
        #if os(macOS)
            if let height {
                frame(width: width, height: height)
            } else {
                frame(
                    minWidth: width, idealWidth: idealWidth, minHeight: minHeight,
                    idealHeight: idealHeight)
            }
        #else
            self
        #endif
    }
}

struct PlatformIcon: View {
    let size: CGFloat
    var body: some View {
        Image("AppMark").resizable().scaledToFit().frame(width: size, height: size)
    }
}

@MainActor private func makePDFView(url: URL) -> PDFView {
    let view = PDFView()
    view.autoScales = true
    view.document = PDFDocument(url: url)
    return view
}

@MainActor private func show(_ url: URL, in view: PDFView) {
    if view.document?.documentURL != url { view.document = PDFDocument(url: url) }
}

#if os(macOS)
    struct PDFDocumentView: NSViewRepresentable {
        let url: URL
        func makeNSView(context: Context) -> PDFView { makePDFView(url: url) }
        func updateNSView(_ view: PDFView, context: Context) { show(url, in: view) }
    }
#else
    struct PDFDocumentView: UIViewRepresentable {
        let url: URL
        func makeUIView(context: Context) -> PDFView { makePDFView(url: url) }
        func updateUIView(_ view: PDFView, context: Context) { show(url, in: view) }
    }
#endif
