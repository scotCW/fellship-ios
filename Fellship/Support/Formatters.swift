import Foundation

enum Format {
    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    static func ago(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        // Only a *recent past* moment is "just now" — future dates must
        // format as "in 2 hr" etc.
        if seconds >= 0 && seconds < 5 { return "just now" }
        return relative.localizedString(for: date, relativeTo: Date())
    }

    private static let grouped: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f
    }()

    static func distance(_ meters: Double, units: DistanceUnits) -> String {
        switch units {
        case .metric:
            if meters < 1000 { return String(format: "%.0f m", meters) }
            let km = meters / 1000
            if km < 100 { return String(format: "%.1f km", km) }
            return "\(grouped.string(from: NSNumber(value: km.rounded())) ?? "\(Int(km))") km"
        case .imperial:
            let feet = meters * 3.28084
            if feet < 1000 { return String(format: "%.0f ft", feet) }
            let miles = feet / 5280
            if miles < 100 { return String(format: "%.1f mi", miles) }
            return "\(grouped.string(from: NSNumber(value: miles.rounded())) ?? "\(Int(miles))") mi"
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

/// Maps a 0…1 slider position onto a value range logarithmically, so one
/// slider stays precise from 50 m all the way to 10,000 mi.
enum LogScale {
    static func value(at t: Double, min: Double, max: Double) -> Double {
        guard min > 0, max > min else { return min }
        let clamped = Swift.min(Swift.max(t, 0), 1)
        return min * pow(max / min, clamped)
    }

    static func position(of value: Double, min: Double, max: Double) -> Double {
        guard min > 0, max > min else { return 0 }
        let clamped = Swift.min(Swift.max(value, min), max)
        return log(clamped / min) / log(max / min)
    }
}
