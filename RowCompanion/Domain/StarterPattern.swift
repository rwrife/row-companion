import Foundation

/// A bundled, fully offline starter pattern (issue #22 slice 1).
///
/// Catalog content is *authored Swift data*, never a network resource, so
/// first launch works in airplane mode and no permission surface exists. A
/// pattern is a value type snapshot: starting a project copies its pieces,
/// repeat settings, written instructions, and reminders into ordinary durable
/// records with fresh IDs. No project ever stores a live reference back to a
/// catalog entry, so shipping a revised pattern can never silently change an
/// existing user's project or progress.
public struct StarterPattern: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let version: Int
    public let title: String
    public let craft: Craft
    public let difficulty: String
    public let summary: String
    /// Human-readable finished dimensions (never used for row arithmetic).
    public let finishedDimensions: String
    public let materials: String
    /// Gauge guidance including units. Informational only — the app never
    /// rewrites a user's own values from it.
    public let gauge: String?
    public let yarnEstimate: String?
    public let terminology: String
    /// Complete written instructions, one section per paragraph, in order.
    public let instructions: [String]
    public let pieces: [StarterPieceSpec]
    /// Exact asset-catalog name of the generated finished-project preview, or
    /// nil when no reviewed preview exists yet.
    public let previewImageName: String?
    /// Alt text for the preview, explicitly labelling it as a generated
    /// illustration rather than a photograph of a test-made item.
    public let previewAltText: String?
    /// Review state is part of the content contract, not UI copy: unreviewed
    /// patterns are presented as drafts and can still be started (the maker
    /// edits freely), but the app never calls them tested.
    public let reviewState: StarterPatternReviewState
    public let author: String
    public let license: String
    /// Human-readable provenance for the preview image (model + date), kept
    /// with the content it describes.
    public let previewProvenance: String?

    public enum Craft: String, Codable, CaseIterable, Sendable {
        case knitting = "Knitting"
        case crochet = "Crochet"
    }

    public enum StarterPatternReviewState: String, Codable, Sendable {
        /// Authored in-repo; no independent technical review and no test-make.
        case draftUnreviewed
        /// Checked by a knowledgeable maker against stitch arithmetic,
        /// terminology, shaping, and gauge.
        case technicallyReviewed
        /// The reviewed pattern was actually made to completion.
        case testMade
    }

    public init(
        id: String,
        version: Int,
        title: String,
        craft: Craft,
        difficulty: String,
        summary: String,
        finishedDimensions: String,
        materials: String,
        gauge: String?,
        yarnEstimate: String?,
        terminology: String,
        instructions: [String],
        pieces: [StarterPieceSpec],
        previewImageName: String?,
        previewAltText: String?,
        reviewState: StarterPatternReviewState,
        author: String,
        license: String,
        previewProvenance: String?
    ) {
        self.id = id
        self.version = version
        self.title = title
        self.craft = craft
        self.difficulty = difficulty
        self.summary = summary
        self.finishedDimensions = finishedDimensions
        self.materials = materials
        self.gauge = gauge
        self.yarnEstimate = yarnEstimate
        self.terminology = terminology
        self.instructions = instructions
        self.pieces = pieces
        self.previewImageName = previewImageName
        self.previewAltText = previewAltText
        self.reviewState = reviewState
        self.author = author
        self.license = license
        self.previewProvenance = previewProvenance
    }
}

/// One piece definition inside a bundled pattern. `startingRows` stays 0 in
/// every shipped pattern — starting a project never fabricates progress.
public struct StarterPieceSpec: Codable, Equatable, Sendable {
    public let name: String
    public let repeatLength: Int?
    /// Written instructions shown for this piece (its full instructions; the
    /// maker edits them like any note).
    public let instructions: String
    public let reminders: [StarterReminderSpec]

    public init(name: String, repeatLength: Int?, instructions: String, reminders: [StarterReminderSpec]) {
        self.name = name
        self.repeatLength = repeatLength
        self.instructions = instructions
        self.reminders = reminders
    }
}

/// Milestone instruction seeded into the started project. Reuses the exact
/// shape of piece-scoped shaping reminders (issue #15): `.once` fires at one
/// row, `.every` recurs. No timers, no notifications.
public struct StarterReminderSpec: Codable, Equatable, Sendable {
    public let instruction: String
    public let interval: Int?
    public let startRow: Int
    public let endRow: Int?

    public init(instruction: String, interval: Int?, startRow: Int, endRow: Int?) {
        self.instruction = instruction
        self.interval = interval
        self.startRow = startRow
        self.endRow = endRow
    }
}

/// Pure validation + search rules for the bundled catalog. The host tests run
/// these rules over the shipped content, so malformed or over-limit pattern
/// data fails Linux CI *before* it can ever be presented or started.
public enum StarterCatalogRules {
    public static let maximumInstructions = 24
    public static let maximumInstructionCharacters = 4_000
    public static let maximumIdCharacters = 64

    public static func validationProblems(for pattern: StarterPattern) -> [String] {
        var problems: [String] = []
        let idCharacters = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-")
        if pattern.id.trimmingCharacters(in: .whitespaces).isEmpty
            || pattern.id.count > maximumIdCharacters
            || pattern.id.unicodeScalars.contains(where: { !idCharacters.contains($0) }) {
            problems.append("Pattern id must be 1-\(maximumIdCharacters) characters from [A-Za-z0-9.-].")
        }
        if pattern.version < 1 { problems.append("Pattern version must be at least 1.") }
        if pattern.title.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("Pattern needs a title.") }
        if pattern.summary.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("Pattern needs a summary.") }
        if pattern.difficulty.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("Pattern needs a difficulty.") }
        if pattern.finishedDimensions.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("Pattern needs finished dimensions.") }
        if pattern.materials.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("Pattern needs materials.") }
        if pattern.terminology.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("Pattern needs a terminology key.") }
        if pattern.author.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("Pattern needs authorship.") }
        if pattern.license.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("Pattern needs a license.") }
        if pattern.instructions.isEmpty || pattern.instructions.count > maximumInstructions {
            problems.append("Pattern needs 1-\(maximumInstructions) instruction sections.")
        }
        for section in pattern.instructions where section.trimmingCharacters(in: .whitespaces).isEmpty
            || section.count > maximumInstructionCharacters {
            problems.append("Each instruction section needs text and at most \(maximumInstructionCharacters) characters.")
        }
        if pattern.pieces.isEmpty { problems.append("Pattern needs at least one piece definition.") }
        var names = Set<String>()
        for piece in pattern.pieces {
            if piece.name.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("Every piece needs a name.") }
            if !names.insert(piece.name).inserted { problems.append("Piece names must be unique: \(piece.name).") }
            if !RowArithmetic.isValid(repeatLength: piece.repeatLength) {
                problems.append("Piece \(piece.name) repeat length must be absent or 1 to \(RowArithmetic.maximumRepeatLength).")
            }
            if piece.instructions.trimmingCharacters(in: .whitespaces).isEmpty
                || piece.instructions.count > maximumInstructionCharacters {
                problems.append("Piece \(piece.name) needs written instructions within the size bound.")
            }
            for reminder in piece.reminders {
                let problemsFor = ReminderRules.validationProblems(for: ShapingReminderRecord(
                    pieceID: UUID(),
                    instruction: reminder.instruction,
                    interval: reminder.interval,
                    startRow: reminder.startRow,
                    endRow: reminder.endRow
                ))
                problems.append(contentsOf: problemsFor.map { "Piece \(piece.name): \($0)" })
            }
        }
        let hasImage = pattern.previewImageName?.isEmpty == false
        let hasAlt = pattern.previewAltText?.trimmingCharacters(in: .whitespaces).isEmpty == false
        if hasImage, !hasAlt { problems.append("A preview image needs alt text.") }
        if hasAlt, !hasImage { problems.append("Preview alt text without an image is meaningless.") }
        if hasImage, pattern.previewProvenance?.trimmingCharacters(in: .whitespaces).isEmpty != false {
            problems.append("A generated preview needs recorded provenance.")
        }
        if hasAlt, pattern.previewAltText?.contains("illustration") != true {
            problems.append("Preview alt text must say the image is an illustration, not a photo.")
        }
        return problems
    }

    /// Case-insensitive search across the fields a maker would type:
    /// title, craft, difficulty, summary, and materials.
    public static func matches(_ pattern: StarterPattern, search: String) -> Bool {
        let needle = search.trimmingCharacters(in: .whitespaces)
        if needle.isEmpty { return true }
        let haystack = [
            pattern.title, pattern.craft.rawValue, pattern.difficulty,
            pattern.summary, pattern.materials,
        ]
        return haystack.contains { $0.localizedStandardContains(needle) }
    }

    /// Honest one-line review label. Never claims "tested" unless the content
    /// actually records a test-make.
    public static func reviewLabel(for pattern: StarterPattern) -> String {
        switch pattern.reviewState {
        case .draftUnreviewed: return "Draft pattern — not yet reviewed or test-made"
        case .technicallyReviewed: return "Reviewed by a maker — not yet test-made"
        case .testMade: return "Reviewed and test-made"
        }
    }
}

/// The offline catalog shipped with the app. Adding a pattern means adding
/// one value here (plus, optionally, an imageset); host CI revalidates every
/// entry with `StarterCatalogRules`, so the shipped set is always well-formed.
public enum StarterCatalog {
    public static let patterns: [StarterPattern] = [
        StarterPattern(
            id: "garter-scarf",
            version: 1,
            title: "First Garter Scarf",
            craft: .knitting,
            difficulty: "Beginner",
            summary: "A knit-every-stitch scarf: the two-row repeat keeps right and wrong sides honest while you work to any length.",
            finishedDimensions: "About 18 cm wide; length to fit",
            materials: "About 200 g (400 m) worsted-weight yarn; 5 mm needles; tapestry needle",
            gauge: "About 16 sts and 32 rows per 10 cm in garter stitch, after washing",
            yarnEstimate: "About 400 m; varies with length, gauge, and yarn",
            terminology: "US terms — k: knit. RS: right side. WS: wrong side.",
            instructions: [
                "Cast on 30 sts using a stretchy cast-on.",
                "Row 1 (RS): k to end.",
                "Row 2 (WS): k to end. These two rows are the whole fabric and the app's 2-row repeat; the repeat tracks RS/WS alternation, not shaping.",
                "Repeat Rows 1 and 2 until the scarf is your chosen length, leaving yarn for a loose bind-off.",
                "Bind off loosely in k. Weave in ends, then wash and dry flat per the yarn label.",
                "Accessibility text alternative: no chart — every row is knit. Gauge target: about 16 sts and 32 rows per 10 cm in garter stitch after washing.",
            ],
            pieces: [
                StarterPieceSpec(
                    name: "Scarf",
                    repeatLength: 2,
                    instructions: """
                    FIRST GARTER SCARF — draft v1, original Row Companion authored content, MIT license.
                    US terms. Cast on 30 sts with a stretchy cast-on.
                    Row 1 (RS): knit all. Row 2 (WS): knit all. The 2-row repeat marks RS/WS only.
                    Repeat Rows 1–2 until your desired length, leaving yarn for a loose bind-off.
                    Bind off loosely in knit. Weave ends; wash and dry flat per yarn label.
                    Gauge target: about 16 sts and 32 rows per 10 cm in garter stitch after washing — swatch first and adjust needle size; finished width about 18 cm at that gauge. Yarn: about 200 g (400 m) worsted.
                    DRAFT: no independent review or test-make yet — verify gauge and stitch counts yourself.
                    """,
                    reminders: []
                ),
            ],
            previewImageName: "StarterGarterScarf",
            previewAltText: "Generated illustration of a folded blue garter-stitch scarf. This is an illustration, not a photo of a test-made item; appearance changes with yarn, gauge, and technique.",
            reviewState: .draftUnreviewed,
            author: "Row Companion authors (original content)",
            license: "MIT",
            previewProvenance: "Preview generated 2026-10-18 by OpenAI Images API gpt-image-2.5-flare from this pattern's written specification; not yet checked by a maker."
        ),
        StarterPattern(
            id: "garter-dishcloth",
            version: 1,
            title: "Garter Square Dishcloth",
            craft: .knitting,
            difficulty: "Beginner",
            summary: "A ridged cotton square that forgives dropped stitches and shows your gauge honestly.",
            finishedDimensions: "About 20 cm square at sample gauge",
            materials: "About 50 g (100 m) DK cotton; 4 mm needles; tapestry needle",
            gauge: "About 20 sts and 40 rows per 10 cm in garter stitch, after washing",
            yarnEstimate: "About 100 m; varies with gauge",
            terminology: "US terms — k: knit; RS: right side; WS: wrong side.",
            instructions: [
                "Cast on 40 sts.",
                "Work garter stitch (knit every row) until 80 rows are complete; the 2-row repeat tracks right and wrong sides.",
                "Check the piece against a ruler at the 40-row halfway reminder — garter squares want to stay square.",
                "Bind off in pattern and weave ends. Wash and block flat per yarn label.",
                "Accessibility text alternative: no chart — every row is knit; 40 sts and 80 rows make about 20 cm at sample gauge.",
            ],
            pieces: [
                StarterPieceSpec(
                    name: "Square",
                    repeatLength: 2,
                    instructions: """
                    GARTER SQUARE DISHCLOTH — draft v1, original Row Companion authored content, MIT license.
                    US terms. Cotton DK, about 50 g (100 m); 4 mm needles.
                    Cast on 40 sts. Knit every row (garter) until 80 rows are complete.
                    Bind off in pattern. Weave ends; wash and block flat.
                    Gauge target: about 20 sts and 40 rows per 10 cm in garter after washing; swatch first — 40 sts and 80 rows should give roughly a 20 cm square.
                    The 2-row repeat marks RS/WS alternation only; there is no shaping.
                    DRAFT: no independent review or test-make yet — verify gauge and stitch counts yourself.
                    """,
                    reminders: [
                        StarterReminderSpec(instruction: "Halfway: check the square's width against a ruler", interval: nil, startRow: 40, endRow: nil)
                    ]
                ),
            ],
            previewImageName: "StarterGarterDishcloth",
            previewAltText: "Generated illustration of a sage-green garter-stitch square dishcloth. This is an illustration, not a photo of a test-made item; appearance changes with yarn, gauge, and technique.",
            reviewState: .draftUnreviewed,
            author: "Row Companion authors (original content)",
            license: "MIT",
            previewProvenance: "Preview generated 2026-10-18 by OpenAI Images API gpt-image-2.5-flare from this pattern's written specification; not yet checked by a maker."
        ),
        StarterPattern(
            id: "row-coaster",
            version: 1,
            title: "One-Row Coaster",
            craft: .crochet,
            difficulty: "Beginner",
            summary: "One repeated stitch count, sixteen across: a pocket-sized crochet square you can finish in an evening.",
            finishedDimensions: "About 10 cm square at sample gauge",
            materials: "About 25 g (35 m) worsted-weight cotton; 4 mm hook; tapestry needle",
            gauge: "About 16 sc and 18 rows per 10 cm",
            yarnEstimate: "About 35 m; varies with tension",
            terminology: "US terms — ch: chain; sc: single crochet; sl st: slip stitch; turn ch: turning chain.",
            instructions: [
                "Chain 17.",
                "Row 1: sc in second ch from hook and in each ch across — 16 sc. Ch 1, turn (the turning chain does not count as a stitch).",
                "Rows 2-17: sc in each of 16 sts — 16 sc each row. Ch 1, turn after each row.",
                "Row 18: sc in each of 16 sts. Do not chain; fasten off.",
                "Weave in ends and wash per the yarn label. The one-row repeat means every counted row is a full 16-sc row.",
                "Accessibility text alternative: no chart — every row is 16 single crochet stitches worked into the previous row.",
            ],
            pieces: [
                StarterPieceSpec(
                    name: "Coaster",
                    repeatLength: 1,
                    instructions: """
                    ONE-ROW COASTER — draft v1, original Row Companion authored content, MIT license.
                    US terms. Worsted cotton, about 25 g (35 m); 4 mm hook.
                    Chain 17. Row 1: sc in second ch from hook and each ch across (16 sc); ch 1, turn (turning ch does not count as a stitch).
                    Rows 2-17: sc in each of 16 sts (16 sc); ch 1, turn. Row 18: sc in each of 16 sts; fasten off without a turning chain.
                    Weave ends; wash per yarn label. Gauge target: about 16 sc and 18 rows per 10 cm — swatch first; that makes about a 10 cm square.
                    The 1-row repeat means every counted row is a full 16-sc row.
                    DRAFT: no independent review or test-make yet — verify gauge and stitch counts yourself.
                    """,
                    reminders: [
                        StarterReminderSpec(instruction: "One row left, then fasten off", interval: nil, startRow: 17, endRow: nil)
                    ]
                ),
            ],
            previewImageName: "StarterCottonCoaster",
            previewAltText: "Generated illustration of a cream cotton single-crochet coaster. This is an illustration, not a photo of a test-made item; appearance changes with yarn, gauge, and technique.",
            reviewState: .draftUnreviewed,
            author: "Row Companion authors (original content)",
            license: "MIT",
            previewProvenance: "Preview generated 2026-10-18 by OpenAI Images API gpt-image-2.5-flare from this pattern's written specification; not yet checked by a maker."
        ),
    ]
}
