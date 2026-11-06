import Foundation

// Server numbers are untrusted. `Int(someDouble)` traps on NaN, infinity and anything past Int's range (3.4e38 from a
// float sensor, 1e30 from a typo), and a trap kills the app or the widget. Every Double → Int in HomelabKit goes
// through `Int(clamping:)` (scripts/lint checks for bare conversions), and every number from a server is put into
// its range when it is decoded (`ServerNumber`).

extension Int {
    /// `value` rounded by `rule` and clamped into `range`, without the trap `Int(_:)` hits on NaN, infinity or a
    /// Double past Int's range. NaN gives 0 (clamped into `range`).
    public init(clamping value: Double, in range: ClosedRange<Int> = Int.min...Int.max,
                rounding rule: FloatingPointRoundingRule = .toNearestOrAwayFromZero) {
        guard !value.isNaN else {
            self = Swift.min(Swift.max(0, range.lowerBound), range.upperBound)
            return
        }
        let r = value.rounded(rule)
        if r <= Double(range.lowerBound) {
            self = range.lowerBound
        } else if r >= Double(range.upperBound) {
            self = range.upperBound
        } else {
            // In range: strictly between two Ints that are themselves in Int's range.
            self = Swift.min(Swift.max(Int(r), range.lowerBound), range.upperBound)   // lint:allow
        }
    }
}

/// The ranges server numbers are put into when they are decoded, so nothing downstream sees NaN, infinity or a value
/// no real machine has.
public enum ServerNumber {
    /// Whole numbers from a server (counts, minutes, steps): far past anything real, far from overflowing when added
    /// or multiplied by 60.
    public static let intRange = -1_000_000_000...1_000_000_000
    /// °C. Outside is a broken sensor: dropped, not clamped (a "200°C" would be a false alarm).
    public static let tempRange = -100.0...200.0
    /// Load average. Clamped.
    public static let loadRange = 0.0...10_000.0
    /// Percentages (RAM, disks). Clamped.
    public static let percentRange = 0.0...100.0
    /// A progress share. Clamped.
    public static let progressRange = 0.0...1.0

    /// `value` clamped into `range`; nil for nil and NaN or infinity.
    public static func clamp(_ value: Double?, _ range: ClosedRange<Double>) -> Double? {
        guard let value, value.isFinite else { return nil }
        return Swift.min(Swift.max(value, range.lowerBound), range.upperBound)
    }

    /// A temperature inside `tempRange`, else nil.
    public static func temp(_ value: Double?) -> Double? {
        guard let value, value.isFinite, tempRange.contains(value) else { return nil }
        return value
    }

    /// A percentage as a whole number 0…100; nil for NaN or infinity.
    public static func percent(rounding value: Double) -> Int? {
        clamp(value, percentRange).map { Int(clamping: $0, in: 0...100) }
    }

    /// Whole numbers 0…100 (a server that sends an Int percent, or an already rounded one).
    public static func percent(_ value: Int) -> Int { Swift.min(Swift.max(value, 0), 100) }
}
