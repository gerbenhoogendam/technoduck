import AppKit
import SwiftUI

/// The home folder. `TECHNODUCK_HOME` moves it, and all of Technoduck's data with it, for demos and screenshots.
let homeDir = ProcessInfo.processInfo.environment["TECHNODUCK_HOME"] ?? NSHomeDirectory()
let isDemo = ProcessInfo.processInfo.environment["TECHNODUCK_HOME"] != nil

/// Colour themes after Panic's Nova: deep slate canvases, a tinted sidebar and a two-colour accent gradient.
/// `system` leaves every colour to macOS.
enum Theme: String, CaseIterable, Identifiable {
    case system, midnight, daylight, pond
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .midnight: "Nova Midnight"
        case .daylight: "Nova Daylight"
        case .pond: "Neon Pond"
        }
    }
    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .daylight: NSAppearance(named: .aqua)
        case .midnight, .pond: NSAppearance(named: .darkAqua)
        }
    }
    var accent: Color {
        switch self {
        case .system: .accentColor
        case .midnight: Color(hex: 0xFF4F9A)
        case .daylight: Color(hex: 0x6C5CE7)
        case .pond: Color(hex: 0x2EF2C8)
        }
    }
    /// The far end of the accent gradient.
    var accent2: Color {
        switch self {
        case .system: .accentColor
        case .midnight: Color(hex: 0xFF9F43)
        case .daylight: Color(hex: 0x00B5D8)
        case .pond: Color(hex: 0xB6FF3B)
        }
    }
    /// Text and symbols drawn on the accent colour.
    var onAccent: Color { self == .pond ? Color(hex: 0x06211C) : .white }
    var gradient: LinearGradient { LinearGradient(colors: [accent, accent2], startPoint: .leading, endPoint: .trailing) }

    // nil keeps the system colour.
    var canvas: Color? { [.midnight: Color(hex: 0x161925), .daylight: Color(hex: 0xFCFBF9), .pond: Color(hex: 0x0A1315)][self] }
    var bar: Color? { [.midnight: Color(hex: 0x1F2335), .daylight: Color(hex: 0xF1EEF6), .pond: Color(hex: 0x0F1F21)][self] }
    var sidebar: Color? { [.midnight: Color(hex: 0x11131D), .daylight: Color(hex: 0xEAE5F3), .pond: Color(hex: 0x071012)][self] }
    var strip: Color? { [.midnight: Color(hex: 0x1A1D2C), .daylight: Color(hex: 0xF5F2F8), .pond: Color(hex: 0x0C191B)][self] }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

extension View {
    /// A themed background, or the system one when the theme has none.
    @ViewBuilder func themeBackground(_ color: Color?, _ fallback: some ShapeStyle) -> some View {
        if let color { background(color) } else { background(fallback) }
    }
}
