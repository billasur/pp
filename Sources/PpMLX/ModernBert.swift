import Foundation
import MLX
import MLXNN

public class ModernBertEmbeddings: Module {
    public let tok_embeddings: Embedding
    public let norm: LayerNorm

    public init(_ config: ModernBertConfig) {
        self.tok_embeddings = Embedding(embeddingCount: config.vocabSize, dimensions: config.hiddenSize)
        self.norm = LayerNorm(dimensions: config.hiddenSize, eps: config.normEps, affine: true, bias: config.normBias)
    }

    public func callAsFunction(_ inputIds: MLXArray) -> MLXArray {
        norm(tok_embeddings(inputIds))
    }
}

public class ModernBertRotaryEmbedding {
    let invFreqFull: MLXArray
    let invFreqSliding: MLXArray
    let headDim: Int

    public init(_ config: ModernBertConfig) {
        self.headDim = config.headDim
        let dim = Float(config.headDim)
        let arangeVals = stride(from: 0, to: config.headDim, by: 2).map { Float($0) }
        let arange = MLXArray(arangeVals)

        let fullBase = config.ropeThetaFull
        let slidingBase = config.ropeThetaSliding

        self.invFreqFull = 1.0 / (pow(MLXArray(fullBase), arange / dim))
        self.invFreqSliding = 1.0 / (pow(MLXArray(slidingBase), arange / dim))
    }

    public func computeCosSin(positionIds: MLXArray, isSliding: Bool) -> (cos: MLXArray, sin: MLXArray) {
        let invFreq = isSliding ? invFreqSliding : invFreqFull
        let pos = positionIds.reshaped([-1, positionIds.dim(-1), 1]).asType(.float32)
        let freqs = matmul(pos, invFreq.reshaped([1, 1, -1]))
        let emb = concatenated([freqs, freqs], axis: -1)
        return (cos(emb), sin(emb))
    }

    public static func rotateHalf(_ x: MLXArray) -> MLXArray {
        let halfDim = x.dim(-1) / 2
        let x1 = x[0..., 0..., 0..., ..<halfDim]
        let x2 = x[0..., 0..., 0..., halfDim...]
        return concatenated([-x2, x1], axis: -1)
    }

    public func applyRoPE(x: MLXArray, cos: MLXArray, sin: MLXArray) -> MLXArray {
        let cosExpanded = cos.expandedDimensions(axis: 1).asType(x.dtype)
        let sinExpanded = sin.expandedDimensions(axis: 1).asType(x.dtype)
        return (x * cosExpanded) + (Self.rotateHalf(x) * sinExpanded)
    }
}

public class ModernBertAttention: Module {
    public let Wqkv: Linear
    public let Wo: Linear
    public let numHeads: Int
    public let headDim: Int
    public let hiddenSize: Int
    public let scale: Float
    public let isSliding: Bool
    public let slidingWindow: Int

    public init(_ config: ModernBertConfig, isSliding: Bool) {
        self.numHeads = config.numAttentionHeads
        self.headDim = config.headDim
        self.hiddenSize = config.hiddenSize
        self.scale = 1.0 / sqrt(Float(config.headDim))
        self.isSliding = isSliding
        self.slidingWindow = config.slidingWindow
        self.Wqkv = Linear(config.hiddenSize, 3 * config.hiddenSize, bias: config.attentionBias)
        self.Wo = Linear(config.hiddenSize, config.hiddenSize, bias: config.attentionBias)
    }

    public func callAsFunction(
        _ hiddenStates: MLXArray,
        mask: MLXArray?,
        rope: (cos: MLXArray, sin: MLXArray),
        rotary: ModernBertRotaryEmbedding
    ) -> MLXArray {
        let B = hiddenStates.dim(0)
        let L = hiddenStates.dim(1)

        let qkv = Wqkv(hiddenStates)
        let qkvReshaped = qkv.reshaped([B, L, 3, numHeads, headDim])

        let q = qkvReshaped[0..., 0..., 0, 0..., 0...].transposed(0, 2, 1, 3)
        let k = qkvReshaped[0..., 0..., 1, 0..., 0...].transposed(0, 2, 1, 3)
        let v = qkvReshaped[0..., 0..., 2, 0..., 0...].transposed(0, 2, 1, 3)

        let qRot = rotary.applyRoPE(x: q, cos: rope.cos, sin: rope.sin)
        let kRot = rotary.applyRoPE(x: k, cos: rope.cos, sin: rope.sin)

        var scores = matmul(qRot, kRot.transposed(0, 1, 3, 2)) * scale
        if let mask = mask {
            scores = scores + mask
        }

        let weights = softmax(scores.asType(.float32), axis: -1).asType(q.dtype)
        let output = matmul(weights, v)
        let outputPermuted = output.transposed(0, 2, 1, 3).reshaped([B, L, hiddenSize])
        return Wo(outputPermuted)
    }
}

public class ModernBertMLP: Module {
    public let Wi: Linear
    public let Wo: Linear
    public let intermediateSize: Int

    public init(_ config: ModernBertConfig) {
        self.intermediateSize = config.intermediateSize
        self.Wi = Linear(config.hiddenSize, 2 * config.intermediateSize, bias: config.mlpBias)
        self.Wo = Linear(config.intermediateSize, config.hiddenSize, bias: config.mlpBias)
    }

    public func callAsFunction(_ hiddenStates: MLXArray) -> MLXArray {
        let projected = Wi(hiddenStates)
        let input = projected[0..., 0..., ..<intermediateSize]
        let gate = projected[0..., 0..., intermediateSize...]
        let activated = gelu(input) * gate
        return Wo(activated)
    }
}

public class ModernBertEncoderLayer: Module {
    public let attn_norm: LayerNorm?
    public let attn: ModernBertAttention
    public let mlp_norm: LayerNorm
    public let mlp: ModernBertMLP
    public let isSliding: Bool

    public init(_ config: ModernBertConfig, layerIndex: Int) {
        self.isSliding = config.layerTypes[layerIndex] == "sliding_attention"
        if layerIndex == 0 {
            self.attn_norm = nil
        } else {
            self.attn_norm = LayerNorm(dimensions: config.hiddenSize, eps: config.normEps, affine: true, bias: config.normBias)
        }
        self.attn = ModernBertAttention(config, isSliding: isSliding)
        self.mlp_norm = LayerNorm(dimensions: config.hiddenSize, eps: config.normEps, affine: true, bias: config.normBias)
        self.mlp = ModernBertMLP(config)
    }

    public func callAsFunction(
        _ hiddenStates: MLXArray,
        mask: MLXArray?,
        rope: (cos: MLXArray, sin: MLXArray),
        rotary: ModernBertRotaryEmbedding
    ) -> MLXArray {
        let normStates = attn_norm?(hiddenStates) ?? hiddenStates
        let attnOut = attn(normStates, mask: mask, rope: rope, rotary: rotary)
        var h = hiddenStates + attnOut
        let mlpOut = mlp(mlp_norm(h))
        h = h + mlpOut
        return h
    }
}

public class ModernBertModel: Module {
    public let embeddings: ModernBertEmbeddings
    public let layers: [ModernBertEncoderLayer]
    public let final_norm: LayerNorm
    public let rotary: ModernBertRotaryEmbedding
    public let config: ModernBertConfig

    public init(_ config: ModernBertConfig) {
        self.config = config
        self.embeddings = ModernBertEmbeddings(config)
        self.layers = (0..<config.numHiddenLayers).map { i in
            ModernBertEncoderLayer(config, layerIndex: i)
        }
        self.final_norm = LayerNorm(dimensions: config.hiddenSize, eps: config.normEps, affine: true, bias: config.normBias)
        self.rotary = ModernBertRotaryEmbedding(config)
    }

    public static func buildAttentionMasks(
        batchSize: Int,
        seqLen: Int,
        attentionMask: MLXArray?,
        slidingWindow: Int
    ) -> (fullMask: MLXArray?, slidingMask: MLXArray?) {
        // Compute 2D position indices for distance check
        let qIdx = MLXArray(0..<seqLen).reshaped([1, 1, seqLen, 1])
        let kIdx = MLXArray(0..<seqLen).reshaped([1, 1, 1, seqLen])
        let dist = abs(qIdx - kIdx) // [1, 1, seqLen, seqLen]

        let slidingAllowed = (dist .<= MLXArray(slidingWindow))

        if let attMask = attentionMask {
            // attMask is [B, L], 1 for valid, 0 for pad
            let attMaskExpanded = attMask.reshaped([batchSize, 1, 1, seqLen])
            let validFull = (attMaskExpanded .== MLXArray(1))
            let fullAdditive = which(validFull, MLXArray(Float(0.0)), MLXArray(Float(-1e4)))

            let validSliding = slidingAllowed .&& validFull
            let slidingAdditive = which(validSliding, MLXArray(Float(0.0)), MLXArray(Float(-1e4)))

            return (fullAdditive, slidingAdditive)
        } else {
            let slidingAdditive = which(slidingAllowed, MLXArray(Float(0.0)), MLXArray(Float(-1e4)))
            return (nil, slidingAdditive)
        }
    }

    public func callAsFunction(inputIds: MLXArray, attentionMask: MLXArray? = nil) -> MLXArray {
        var h = embeddings(inputIds)
        let B = inputIds.dim(0)
        let L = inputIds.dim(1)

        let posIds = MLXArray(0..<L).reshaped([1, L])
        let ropeFull = rotary.computeCosSin(positionIds: posIds, isSliding: false)
        let ropeSliding = rotary.computeCosSin(positionIds: posIds, isSliding: true)

        let (fullMask, slidingMask) = Self.buildAttentionMasks(
            batchSize: B,
            seqLen: L,
            attentionMask: attentionMask,
            slidingWindow: config.slidingWindow
        )

        for layer in layers {
            let mask = layer.isSliding ? slidingMask : fullMask
            let rope = layer.isSliding ? ropeSliding : ropeFull
            h = layer(h, mask: mask, rope: rope, rotary: rotary)
        }

        return final_norm(h)
    }
}
