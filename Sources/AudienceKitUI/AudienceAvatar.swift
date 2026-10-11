#if canImport(SwiftUI)
import SwiftUI
import Foundation

/// A shared profile image for people and venues, with an accessible fallback.
public struct AudienceAvatar: View {
    private let url: URL?
    private let name: String
    private let size: CGFloat
    private let isVenue: Bool

    public init(url: URL?, name: String, size: CGFloat = 32, isVenue: Bool = false) {
        self.url = url
        self.name = name
        self.size = size
        self.isVenue = isVenue
    }

    public var body: some View {
        AsyncImage(url: url) { image in image.resizable().scaledToFill() }
            placeholder: { Image(systemName: isVenue ? "building.2.fill" : "person.fill").foregroundStyle(.secondary) }
            .frame(width: size, height: size)
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: isVenue ? size / 4 : size / 2))
            .accessibilityLabel(name)
    }
}
#endif
