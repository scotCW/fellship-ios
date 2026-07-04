import Foundation

enum Format {
    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    static func ago(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 5 { return "just now" }
        return relative.localizedString(for: date, relativeTo: Date())
    }

    static func distance(_ meters: Double, units: DistanceUnits) -> String {
        switch units {
        case .metric:
            if meters < 1000 { return String(format: "%.0f m", meters) }
            return String(format: "%.1f km", meters / 1000)
        case .imperial:
            let feet = meters * 3.28084
            if feet < 1000 { return String(format: "%.0f ft", feet) }
            return String(format: "%.1f mi", feet / 5280)
        }
    }

    static func interval(_ seconds: Double) -> String {
        if seconds < 60 { return String(format: "%.0f s", seconds) }
        if seconds < 3600 {
            let minutes = seconds / 60
            return minutes == minutes.rounded()
                ? String(format: "%.0f min", minutes)
                : String(format: "%.1f min", minutes)
        }
        return String(format: "%.1f h", seconds / 3600)
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    static func voltage(milliVolts: UInt16) -> String {
        String(format: "%.2f V", Double(milliVolts) / 1000)
    }

    /// Rough LiPo percentage from voltage — good enough for a dashboard.
    static func batteryPercent(milliVolts: UInt16) -> Int {
        let v = Double(milliVolts) / 1000
        let fraction = (v - 3.3) / (4.2 - 3.3)
        return Int((min(max(fraction, 0), 1) * 100).rounded())
    }

    static func coordinate(_ c: Coordinate) -> String {
        String(format: "%.5f, %.5f", c.latitude, c.longitude)
    }
}
