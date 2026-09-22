import Foundation

/// Fast native Swift ByteLevel BPE Tokenizer for ModernBERT and Laya models.
public final class BPETokenizer: SequenceTokenizer, Sendable {
    public let clsTokenId: Int
    public let sepTokenId: Int
    public let padTokenId: Int
    public let maskTokenId: Int
    public let maskToken: String

    private let vocab: [String: Int]
    private let invVocab: [Int: String]
    private let bpeRanks: [String: Int]
    private let byteToChar: [UInt8: Character]

    public init(
        vocab: [String: Int],
        merges: [String],
        clsTokenId: Int = 50281,
        sepTokenId: Int = 50282,
        padTokenId: Int = 50283,
        maskTokenId: Int = 50284,
        maskToken: String = "[MASK]"
    ) {
        self.vocab = vocab
        var inv: [Int: String] = [:]
        for (k, v) in vocab {
            inv[v] = k
        }
        self.invVocab = inv

        var ranks: [String: Int] = [:]
        for (i, m) in merges.enumerated() {
            ranks[m] = i
        }
        self.bpeRanks = ranks

        self.clsTokenId = clsTokenId
        self.sepTokenId = sepTokenId
        self.padTokenId = padTokenId
        self.maskTokenId = maskTokenId
        self.maskToken = maskToken

        // Build bytes_to_unicode mapping table
        var b2c: [UInt8: Character] = [:]
        var bs: [Int] = Array(33...126) + Array(161...172) + Array(174...255)
        var cs = bs
        var n = 0
        for b in 0..<256 {
            if !bs.contains(b) {
                bs.append(b)
                cs.append(256 + n)
                n += 1
            }
        }
        for (b, c) in zip(bs, cs) {
            if let scalar = UnicodeScalar(c) {
                b2c[UInt8(b)] = Character(scalar)
            }
        }
        self.byteToChar = b2c
    }

    public static func load(from directoryUrl: URL) throws -> BPETokenizer {
        let tokUrl = directoryUrl.appendingPathComponent("tokenizer.json")
        let data = try Data(contentsOf: tokUrl)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = json["model"] as? [String: Any],
              let vocab = model["vocab"] as? [String: Int],
              let merges = model["merges"] as? [String] else {
            throw NSError(domain: "BPETokenizer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid tokenizer.json format"])
        }

        return BPETokenizer(vocab: vocab, merges: merges)
    }

    private func byteEncode(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        for byte in text.utf8 {
            if let c = byteToChar[byte] {
                result.append(c)
            }
        }
        return result
    }

    private func bpe(_ token: String) -> [String] {
        if token.count <= 1 {
            return [token]
        }

        var word = token.map { String($0) }
        while word.count > 1 {
            // Find the lowest ranked pair
            var minRank: Int = Int.max
            var bestPair: (String, String)? = nil

            for i in 0..<(word.count - 1) {
                let pairStr = "\(word[i]) \(word[i + 1])"
                if let rank = bpeRanks[pairStr], rank < minRank {
                    minRank = rank
                    bestPair = (word[i], word[i + 1])
                }
            }

            guard let pair = bestPair else {
                break
            }

            // Merge occurrences of bestPair
            var newWord: [String] = []
            var i = 0
            while i < word.count {
                if i < word.count - 1 && word[i] == pair.0 && word[i + 1] == pair.1 {
                    newWord.append(pair.0 + pair.1)
                    i += 2
                } else {
                    newWord.append(word[i])
                    i += 1
                }
            }
            word = newWord
        }
        return word
    }

    public func encode(_ text: String) -> [Int] {
        guard !text.isEmpty else { return [] }

        // Regex pattern for GPT-2 / ModernBERT ByteLevel BPE:
        // 's|'t|'re|'ve|'m|'ll|'d| ?\p{L}+| ?\p{N}+| ?[^\s\p{L}\p{N}]+|\s+(?!\S)|\s+
        let pattern = "'s|'t|'re|'ve|'m|'ll|'d| ?\\p{L}+| ?\\p{N}+| ?[^\\s\\p{L}\\p{N}]+|\\s+(?!\\S)|\\s+"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        let nsString = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsString.length))

        var tokenIds: [Int] = []
        tokenIds.reserveCapacity(matches.count * 2)

        for match in matches {
            let part = nsString.substring(with: match.range)
            let bytePart = byteEncode(part)
            let bpeTokens = bpe(bytePart)
            for tok in bpeTokens {
                if let id = vocab[tok] {
                    tokenIds.append(id)
                } else if let unk = vocab["<unk>"] {
                    tokenIds.append(unk)
                }
            }
        }

        return tokenIds
    }
}
