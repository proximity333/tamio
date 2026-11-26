//
//  AssistantImages.swift
//  Tamio (macOS)
//
//  Turns a picked, dropped or pasted image into bounded JPEG data for the
//  assistant. Vision APIs cap pixels and bytes, and a screenshot straight
//  from Retina is often several times over both.
//

import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated enum AssistantImageError: LocalizedError {
    case unreadable
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .unreadable:
            String(localized: "Could not read that image.")
        case .tooLarge:
            String(localized: "That image is too large.")
        }
    }
}

nonisolated enum AssistantImageProcessor {
    /// What the vision APIs comfortably take, and what keeps a conversation
    /// folder small enough to back up without pain.
    static let maxDimension = 2048
    static let maxBytes = 8 * 1024 * 1024
    static let maxImagesPerMessage = 4

    static func prepare(contentsOf url: URL, fileName: String? = nil) throws -> AssistantAttachmentDraft {
        let data = try Data(contentsOf: url)
        return try prepare(data: data, fileName: fileName ?? url.lastPathComponent)
    }

    static func prepare(data: Data, fileName: String) throws -> AssistantAttachmentDraft {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw AssistantImageError.unreadable
        }

        var dimension = maxDimension
        var quality = 0.8
        var encoded: Data?
        var pixelSize = CGSize.zero

        for _ in 0 ..< 5 {
            guard let image = thumbnail(from: source, maxDimension: dimension),
                  let flattened = flatten(image),
                  let jpeg = encodeJPEG(flattened, quality: quality)
            else { throw AssistantImageError.unreadable }

            encoded = jpeg
            pixelSize = CGSize(width: flattened.width, height: flattened.height)
            if jpeg.count <= maxBytes {
                break
            }

            if quality > 0.5 {
                quality -= 0.15
            } else {
                dimension = max(1024, dimension * 3 / 4)
                quality = 0.7
            }
        }

        guard let jpeg = encoded, jpeg.count <= maxBytes else {
            throw AssistantImageError.tooLarge
        }

        let attachment = AssistantAttachment(
            fileName: fileName,
            mediaType: "image/jpeg",
            byteCount: jpeg.count,
            width: Int(pixelSize.width),
            height: Int(pixelSize.height)
        )
        return AssistantAttachmentDraft(attachment: attachment, data: jpeg)
    }

    /// Whether the clipboard has an image or an image file, without decoding it.
    static var pasteboardHasImage: Bool {
        let pasteboard = NSPasteboard.general
        if pasteboard.availableType(from: [.png, .tiff]) != nil {
            return true
        }
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] {
            return urls.contains { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
        }
        return false
    }

    /// The image on the pasteboard, as a file copied there or raw pixels.
    static func fromPasteboard() -> AssistantAttachmentDraft? {
        let pasteboard = NSPasteboard.general
        if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff),
           let draft = try? prepare(data: data, fileName: "Pasted Image.png")
        {
            return draft
        }
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
           let url = urls.first(where: { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }),
           let draft = try? prepare(contentsOf: url)
        {
            return draft
        }
        return nil
    }

    // MARK: - ImageIO

    private static func thumbnail(from source: CGImageSource, maxDimension: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// JPEG has no alpha; draw transparent pixels onto white instead of the
    /// black a plain conversion would leave behind.
    private static func flatten(_ image: CGImage) -> CGImage? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              )
        else { return nil }

        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func encodeJPEG(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: quality,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
