import Foundation

/// Optional structured project facts (issue #20). Stored values are always
/// canonical metric (millimetres, counts per 10 cm); imperial is display-only
/// conversion, so switching units never rewrites or rounds stored values.
/// The same shape serves project-level defaults and piece-level overrides:
/// a piece field that is `nil` falls back to the project value.
public struct ProjectDetails: Codable, Equatable, Sendable {
    public static let maximumTextLength = 120
    public static let maximumMeasurementMM = 100_000.0

    public var material: String
    public var colorway: String
    public var selectedSize: String
    public var toolSizeMM: Double?
    public var gaugeStitchesPer10CM: Double?
    public var gaugeRowsPer10CM: Double?
    public var measurementMM: Double?

    public init(material: String = "", colorway: String = "", selectedSize: String = "",
                toolSizeMM: Double? = nil, gaugeStitchesPer10CM: Double? = nil,
                gaugeRowsPer10CM: Double? = nil, measurementMM: Double? = nil) {
        self.material = material; self.colorway = colorway; self.selectedSize = selectedSize
        self.toolSizeMM = toolSizeMM; self.gaugeStitchesPer10CM = gaugeStitchesPer10CM
        self.gaugeRowsPer10CM = gaugeRowsPer10CM; self.measurementMM = measurementMM
    }

    public var isEmpty: Bool { self == ProjectDetails() }

    /// Text within bound; numbers finite and in `(0, maximumMeasurementMM]`.
    public var isValid: Bool {
        let texts = [material, colorway, selectedSize]
        guard texts.allSatisfy({ $0.count <= Self.maximumTextLength }) else { return false }
        return [toolSizeMM, gaugeStitchesPer10CM, gaugeRowsPer10CM, measurementMM].allSatisfy { value in
            guard let value else { return true }
            return value.isFinite && value > 0 && value <= Self.maximumMeasurementMM
        }
    }

    /// Piece override applied on top of project defaults, field by field.
    public func overriding(_ base: ProjectDetails) -> ProjectDetails {
        ProjectDetails(
            material: material.isEmpty ? base.material : material,
            colorway: colorway.isEmpty ? base.colorway : colorway,
            selectedSize: selectedSize.isEmpty ? base.selectedSize : selectedSize,
            toolSizeMM: toolSizeMM ?? base.toolSizeMM,
            gaugeStitchesPer10CM: gaugeStitchesPer10CM ?? base.gaugeStitchesPer10CM,
            gaugeRowsPer10CM: gaugeRowsPer10CM ?? base.gaugeRowsPer10CM,
            measurementMM: measurementMM ?? base.measurementMM)
    }

    public static let millimetresPerInch = 25.4
    public static func inches(fromMM mm: Double) -> Double { mm / millimetresPerInch }
    public static func mm(fromInches inches: Double) -> Double { inches * millimetresPerInch }
    /// Counts per 10 cm to counts per 4 in (the common imperial gauge swatch).
    public static func countPer4Inches(fromPer10CM value: Double) -> Double { value * (4 * millimetresPerInch) / 100 }
    public static func countPer10CM(fromPer4Inches value: Double) -> Double { value * 100 / (4 * millimetresPerInch) }

    /// VoiceOver-friendly one-line summary. Display rounding happens here
    /// only; the stored canonical values are never altered.
    public func summaryText(isImperial: Bool) -> String {
        var parts: [String] = []
        let yarn = [material, colorway].filter { !$0.isEmpty }.joined(separator: " · ")
        if !yarn.isEmpty { parts.append(yarn) }
        if !selectedSize.isEmpty { parts.append("Size \(selectedSize)") }
        if let toolSizeMM {
            parts.append(isImperial
                ? "Tool \(Self.round2(Self.inches(fromMM: toolSizeMM))) in"
                : "Tool \(Self.round2(toolSizeMM)) mm")
        }
        if let stitches = gaugeStitchesPer10CM {
            if isImperial {
                parts.append("\(Self.round2(Self.countPer4Inches(fromPer10CM: stitches))) sts per 4 in")
            } else {
                parts.append("\(Self.round2(stitches)) sts per 10 cm")
            }
        }
        if let rows = gaugeRowsPer10CM {
            parts.append(isImperial
                ? "\(Self.round2(Self.countPer4Inches(fromPer10CM: rows))) rows per 4 in"
                : "\(Self.round2(rows)) rows per 10 cm")
        }
        if let measurementMM {
            parts.append(isImperial
                ? "\(Self.round2(Self.inches(fromMM: measurementMM))) in"
                : "\(Self.round2(measurementMM)) mm")
        }
        return parts.isEmpty ? "No details yet" : parts.joined(separator: " · ")
    }

    private static func round2(_ value: Double) -> Double { (value * 100).rounded() / 100 }
}
