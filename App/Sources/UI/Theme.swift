import Foundation
import SwiftUI

/// Visual language: quiet, high-contrast, one accent. The app is a reading surface
/// first — long answers have to be comfortable on an OLED phone at night.
public enum Theme {

    public enum Palette {
        public static let background = Color(red: 0.055, green: 0.059, blue: 0.071)
        public static let surface = Color(red: 0.098, green: 0.106, blue: 0.122)
        public static let surfaceRaised = Color(red: 0.137, green: 0.145, blue: 0.165)
        public static let hairline = Color.white.opacity(0.08)
        public static let textPrimary = Color(red: 0.937, green: 0.945, blue: 0.957)
        public static let textSecondary = Color(red: 0.647, green: 0.671, blue: 0.706)
        public static let textTertiary = Color(red: 0.451, green: 0.478, blue: 0.518)
        public static let accent = Color(red: 0.478, green: 0.796, blue: 0.639)
        public static let accentDim = Color(red: 0.290, green: 0.478, blue: 0.384)
        public static let warning = Color(red: 0.949, green: 0.725, blue: 0.400)
        public static let danger = Color(red: 0.914, green: 0.443, blue: 0.416)
    }

    public enum Metrics {
        public static let corner: CGFloat = 14
        public static let cornerSmall: CGFloat = 8
        public static let gutter: CGFloat = 16
        public static let bubbleMaxWidth: CGFloat = 560
    }

    public enum Type {
        public static let answer = Font.system(size: 16.5, weight: .regular, design: .default)
        public static let question = Font.system(size: 15.5, weight: .medium)
        public static let caption = Font.system(size: 12, weight: .regular)
        public static let mono = Font.system(size: 12.5, weight: .regular, design: .monospaced)
        public static let title = Font.system(size: 17, weight: .semibold)
        public static let sectionHeader = Font.system(size: 11.5, weight: .semibold)
    }
}

public struct Hairline: View {
    public init() {}
    public var body: some View {
        Rectangle()
            .fill(Theme.Palette.hairline)
            .frame(height: 1)
    }
}

public struct PillLabel: View {
    let text: String
    var tint: Color = Theme.Palette.textSecondary

    public init(_ text: String, tint: Color = Theme.Palette.textSecondary) {
        self.text = text
        self.tint = tint
    }

    public var body: some View {
        Text(text)
            .font(Theme.Type.caption)
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Theme.Palette.surfaceRaised)
            )
    }
}
