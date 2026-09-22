import Foundation

public struct SpecialTokensConfig: Codable, Sendable {
    public let clsTokenId: Int
    public let sepTokenId: Int
    public let padTokenId: Int
    public let maskTokenId: Int

    enum CodingKeys: String, CodingKey {
        case clsTokenId = "cls_token_id"
        case sepTokenId = "sep_token_id"
        case padTokenId = "pad_token_id"
        case maskTokenId = "mask_token_id"
    }

    public init(
        clsTokenId: Int = 50281,
        sepTokenId: Int = 50282,
        padTokenId: Int = 50283,
        maskTokenId: Int = 50284
    ) {
        self.clsTokenId = clsTokenId
        self.sepTokenId = sepTokenId
        self.padTokenId = padTokenId
        self.maskTokenId = maskTokenId
    }
}

public struct ModernBertConfig: Codable, Sendable {
    public let modelId: String
    public let architecture: String
    public let vocabSize: Int
    public let hiddenSize: Int
    public let intermediateSize: Int
    public let numHiddenLayers: Int
    public let numAttentionHeads: Int
    public let headDim: Int
    public let normEps: Float
    public let normBias: Bool
    public let attentionBias: Bool
    public let mlpBias: Bool
    public let maxPositionEmbeddings: Int
    public let localAttention: Int
    public let slidingWindow: Int
    public let globalAttnEveryNLayers: Int
    public let ropeThetaFull: Float
    public let ropeThetaSliding: Float
    public let layerTypes: [String]
    public let headLayers: Int
    public let headDModel: Int
    public let headNHead: Int
    public let headDimFeedforward: Int
    public let headActivation: String
    public let maxLen: Int
    public let headMaxLen: Int
    public let specialTokens: SpecialTokensConfig
    public let temperatureByOptions: [String: Float]
    public let defaultTemperature: [Float]

    enum CodingKeys: String, CodingKey {
        case modelId = "model_id"
        case architecture
        case vocabSize = "vocab_size"
        case hiddenSize = "hidden_size"
        case intermediateSize = "intermediate_size"
        case numHiddenLayers = "num_hidden_layers"
        case numAttentionHeads = "num_attention_heads"
        case headDim = "head_dim"
        case normEps = "norm_eps"
        case normBias = "norm_bias"
        case attentionBias = "attention_bias"
        case mlpBias = "mlp_bias"
        case maxPositionEmbeddings = "max_position_embeddings"
        case localAttention = "local_attention"
        case slidingWindow = "sliding_window"
        case globalAttnEveryNLayers = "global_attn_every_n_layers"
        case ropeThetaFull = "rope_theta_full"
        case ropeThetaSliding = "rope_theta_sliding"
        case layerTypes = "layer_types"
        case headLayers = "head_layers"
        case headDModel = "head_d_model"
        case headNHead = "head_nhead"
        case headDimFeedforward = "head_dim_feedforward"
        case headActivation = "head_activation"
        case maxLen = "max_len"
        case headMaxLen = "head_max_len"
        case specialTokens = "special_tokens"
        case temperatureByOptions = "temperature_by_options"
        case defaultTemperature = "default_temperature"
    }

    public static func load(from url: URL) throws -> ModernBertConfig {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ModernBertConfig.self, from: data)
    }

    public static var layaDefault: ModernBertConfig {
        ModernBertConfig(
            modelId: "convaiinnovations/laya",
            architecture: "modernbert_laya",
            vocabSize: 50368,
            hiddenSize: 1024,
            intermediateSize: 2624,
            numHiddenLayers: 28,
            numAttentionHeads: 16,
            headDim: 64,
            normEps: 1e-05,
            normBias: false,
            attentionBias: false,
            mlpBias: false,
            maxPositionEmbeddings: 8192,
            localAttention: 128,
            slidingWindow: 64,
            globalAttnEveryNLayers: 3,
            ropeThetaFull: 160000.0,
            ropeThetaSliding: 10000.0,
            layerTypes: (0..<28).map { i in
                i % 3 == 0 ? "full_attention" : "sliding_attention"
            },
            headLayers: 2,
            headDModel: 1024,
            headNHead: 16,
            headDimFeedforward: 4096,
            headActivation: "relu",
            maxLen: 512,
            headMaxLen: 192,
            specialTokens: SpecialTokensConfig(),
            temperatureByOptions: [
                "choice:2": 1.9063563,
                "choice:3-5": 1.7601519,
                "choice:6-10": 1.0000159,
                "choice:11+": 0.1005828,
                "noul:2": 1.9833995,
                "score:3-5": 1.2514300,
            ],
            defaultTemperature: [1.636903, 1.251430, 1.983400]
        )
    }
}
