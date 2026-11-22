import Foundation

enum DateFormatters {
    static let apiDay: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = .current
        return df
    }()

    static let apiHour: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:00"
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = .current
        return df
    }()

    static let monthDay: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "MM/dd"
        df.locale = Locale(identifier: "zh_CN")
        return df
    }()

    static let hourLabel: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:00"
        df.locale = Locale(identifier: "en_US_POSIX")
        return df
    }()

    static let fullDate: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy年MM月dd日"
        df.locale = Locale(identifier: "zh_CN")
        return df
    }()

    static let shortTime: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        df.locale = Locale(identifier: "en_US_POSIX")
        return df
    }()

    static func parseTrendDate(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let formats = [
            "yyyy-MM-dd",
            "yyyy-MM-dd HH:mm",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
            "yyyy-MM-dd'T'HH:mm:ss"
        ]
        for format in formats {
            let df = DateFormatter()
            df.dateFormat = format
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = .current
            if let date = df.date(from: trimmed) {
                return date
            }
        }
        let iso = ISO8601DateFormatter()
        return iso.date(from: trimmed)
    }
}

enum ValueFormatter {
    static func currency(_ amount: Double, currency: DisplayCurrency, compact: Bool = false) -> String {
        let safeAmount = amount.isFinite ? amount : 0
        if compact && abs(safeAmount) >= 10_000 {
            return "\(currency.symbol)\(String(format: "%.1f万", safeAmount / 10_000))"
        }
        if currency == .jpy {
            return "\(currency.symbol)\(String(format: "%.0f", safeAmount))"
        }
        if abs(safeAmount) > 0 && abs(safeAmount) < 0.01 {
            return "\(currency.symbol)\(String(format: "%.4f", safeAmount))"
        }
        return "\(currency.symbol)\(String(format: "%.2f", safeAmount))"
    }

    static func usd(_ amount: Double) -> String {
        let safeAmount = amount.isFinite ? amount : 0
        if abs(safeAmount) > 0 && abs(safeAmount) < 0.01 {
            return "$\(String(format: "%.4f", safeAmount))"
        }
        return "$\(String(format: "%.2f", safeAmount))"
    }

    static func rate(_ rate: Double) -> String {
        let safe = rate.isFinite ? rate : 0
        if safe.truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "%.0f", safe)
        }
        var formatted = String(format: "%.6f", safe)
        while formatted.hasSuffix("0") {
            formatted.removeLast()
        }
        if formatted.hasSuffix(".") {
            formatted.removeLast()
        }
        return formatted
    }

    static func tokens(_ count: Int64) -> String {
        let value = Double(max(0, count))
        switch value {
        case 1_000_000_000...:
            return String(format: "%.2fB", value / 1_000_000_000)
        case 1_000_000...:
            return String(format: "%.2fM", value / 1_000_000)
        case 1_000...:
            return String(format: "%.1fK", value / 1_000)
        default:
            return "\(count)"
        }
    }

    static func requests(_ count: Int64) -> String {
        let value = Double(max(0, count))
        if value >= 1_000_000 {
            return String(format: "%.2fM", value / 1_000_000)
        } else if value >= 10_000 {
            return String(format: "%.1fK", value / 1_000)
        }
        return NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal)
    }

    static func percent(_ share: Double) -> String {
        let clamped = max(0, min(1, share.isFinite ? share : 0))
        return String(format: "%.1f%%", clamped * 100)
    }
}
