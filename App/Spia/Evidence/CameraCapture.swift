#if os(iOS)
    import PhotosUI
    import SwiftUI
    import UniformTypeIdentifiers
    import UIKit

    struct CameraCapture: UIViewControllerRepresentable {
        enum Capture {
            case photo(Data)
            case clip(URL)
        }

        let captured: (Capture) -> Void
        let cancelled: () -> Void

        static var isAvailable: Bool {
            UIImagePickerController.isSourceTypeAvailable(.camera)
        }

        func makeCoordinator() -> Coordinator { Coordinator(self) }

        func makeUIViewController(context: Context) -> UIImagePickerController {
            let picker = UIImagePickerController()
            picker.sourceType = .camera
            picker.mediaTypes = [UTType.image.identifier, UTType.movie.identifier]
            picker.videoMaximumDuration = 60
            picker.videoQuality = .typeHigh
            picker.cameraCaptureMode = .photo
            picker.delegate = context.coordinator
            return picker
        }

        func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

        final class Coordinator: NSObject, UIImagePickerControllerDelegate,
            UINavigationControllerDelegate
        {
            let parent: CameraCapture

            init(_ parent: CameraCapture) { self.parent = parent }

            func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
                parent.cancelled()
            }

            func imagePickerController(
                _ picker: UIImagePickerController,
                didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
            ) {
                if let image = info[.originalImage] as? UIImage,
                    let data = image.jpegData(compressionQuality: 0.9)
                {
                    parent.captured(.photo(data))
                    return
                }
                if let source = info[.mediaURL] as? URL {
                    let destination = FileManager.default.temporaryDirectory
                        .appendingPathComponent("spia-\(UUID().uuidString).\(source.pathExtension)")
                    do {
                        try FileManager.default.copyItem(at: source, to: destination)
                        parent.captured(.clip(destination))
                    } catch {
                        parent.cancelled()
                    }
                }
            }
        }
    }
#endif
