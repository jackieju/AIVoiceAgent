import Foundation

public struct TranscriptCorrector {
    public struct Rule {
        public let variants: [String]
        public let canonical: String

        public init(variants: [String], canonical: String) {
            self.variants = variants
            self.canonical = canonical
        }
    }

    private let compiled: [(regex: NSRegularExpression, replacement: String)]

    public init(rules: [Rule]) {
        var out: [(NSRegularExpression, String)] = []
        for rule in rules {
            for variant in rule.variants {
                let escaped = NSRegularExpression.escapedPattern(for: variant)
                // \b is unreliable across scripts; anchor on alnum edges to match a standalone phrase.
                let pattern = "(?i)(?<![A-Za-z0-9])\(escaped)(?![A-Za-z0-9])"
                guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
                out.append((re, rule.canonical))
            }
        }
        self.compiled = out
    }

    public static let defaultRules: [Rule] = [
        Rule(variants: ["open cold", "open coat", "open code", "opencold", "opencode"],
             canonical: "OpenCode"),
    ]

    /// Canonical terms (de-duplicated) to prime whisper's initial prompt; correction is the fallback.
    public static func canonicalTerms(from rules: [Rule]) -> [String] {
        var seen = Set<String>()
        var terms: [String] = []
        for rule in rules where seen.insert(rule.canonical).inserted {
            terms.append(rule.canonical)
        }
        return terms
    }

    public func correct(_ text: String) -> String {
        var result = text
        for (re, replacement) in compiled {
            let range = NSRange(result.startIndex..., in: result)
            result = re.stringByReplacingMatches(in: result, range: range, withTemplate: replacement)
        }
        return result
    }
}
