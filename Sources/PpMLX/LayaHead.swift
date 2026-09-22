import Foundation
import MLX
import MLXNN

public class LayaTransformerEncoderLayer: Module {
    public let norm1: LayerNorm
    public let self_attn: LayaSelfAttention
    public let norm2: LayerNorm
    public let linear1: Linear
    public let linear2: Linear

    public init(dModel: Int = 1024, nHead: Int = 16, dimFeedforward: Int = 4096) {
        self.norm1 = LayerNorm(dimensions: dModel, eps: 1e-5, affine: true, bias: true)
        self.self_attn = LayaSelfAttention(dModel: dModel, nHead: nHead)
        self.norm2 = LayerNorm(dimensions: dModel, eps: 1e-5, affine: true, bias: true)
        self.linear1 = Linear(dModel, dimFeedforward, bias: true)
        self.linear2 = Linear(dimFeedforward, dModel, bias: true)
    }

    public func callAsFunction(_ x: MLXArray, paddingMask: MLXArray?) -> MLXArray {
        // Pre-norm: x = x + self_attn(norm1(x))
        let n1 = norm1(x)
        let attnOut = self_attn(n1, paddingMask: paddingMask)
        var h = x + attnOut

        // Pre-norm: x = x + linear2(relu(linear1(norm2(x))))
        let n2 = norm2(h)
        let ff = linear2(relu(linear1(n2)))
        h = h + ff
        return h
    }
}

public class LayaSelfAttention: Module {
    public let in_proj_weight: MLXArray
    public let in_proj_bias: MLXArray
    public let out_proj: Linear
    public let dModel: Int
    public let nHead: Int
    public let headDim: Int
    public let scale: Float

    public init(dModel: Int = 1024, nHead: Int = 16) {
        self.dModel = dModel
        self.nHead = nHead
        self.headDim = dModel / nHead
        self.scale = 1.0 / sqrt(Float(headDim))
        self.in_proj_weight = MLXRandom.normal([3 * dModel, dModel], scale: 0.02)
        self.in_proj_bias = MLXArray.zeros([3 * dModel])
        self.out_proj = Linear(dModel, dModel, bias: true)
    }

    public func callAsFunction(_ x: MLXArray, paddingMask: MLXArray?) -> MLXArray {
        let B = x.dim(0)
        let L = x.dim(1)

        let qkv = matmul(x, in_proj_weight.T) + in_proj_bias // [B, L, 3 * dModel]
        let qkvReshaped = qkv.reshaped([B, L, 3, nHead, headDim])

        let q = qkvReshaped[0..., 0..., 0, 0..., 0...].transposed(0, 2, 1, 3) // [B, nHead, L, headDim]
        let k = qkvReshaped[0..., 0..., 1, 0..., 0...].transposed(0, 2, 1, 3)
        let v = qkvReshaped[0..., 0..., 2, 0..., 0...].transposed(0, 2, 1, 3)

        var scores = matmul(q, k.transposed(0, 1, 3, 2)) * scale // [B, nHead, L, L]

        if let paddingMask = paddingMask {
            // paddingMask: [B, L], true for padding, false for valid
            // In PyTorch: src_key_padding_mask is [B, S], True means value is masked
            let maskExpanded = paddingMask.reshaped([B, 1, 1, L])
            scores = which(maskExpanded, MLXArray(Float(-1e4)), scores)
        }

        let weights = softmax(scores.asType(.float32), axis: -1).asType(q.dtype)
        let output = matmul(weights, v) // [B, nHead, L, headDim]
        let outputPermuted = output.transposed(0, 2, 1, 3).reshaped([B, L, dModel])
        return out_proj(outputPermuted)
    }
}

public class LayaScorer: Module {
    public let norm: LayerNorm  // scorer.0
    public let dense: Linear    // scorer.1
    public let out: Linear      // scorer.3

    public init(dModel: Int = 1024) {
        self.norm = LayerNorm(dimensions: dModel, eps: 1e-5, affine: true, bias: true)
        self.dense = Linear(dModel, dModel, bias: true)
        self.out = Linear(dModel, 1, bias: true)
    }

    public func callAsFunction(_ x: MLXArray) -> MLXArray {
        let n = norm(x)
        let d = gelu(dense(n))
        return out(d).squeezed(axis: -1) // [B, num_markers]
    }
}

public class LayaHead: Module {
    public let type_emb: Embedding
    public let layers: [LayaTransformerEncoderLayer]
    public let scorer: LayaScorer

    public init(config: ModernBertConfig) {
        self.type_emb = Embedding(embeddingCount: 3, dimensions: config.hiddenSize)
        self.layers = (0..<config.headLayers).map { _ in
            LayaTransformerEncoderLayer(
                dModel: config.headDModel,
                nHead: config.headNHead,
                dimFeedforward: config.headDimFeedforward
            )
        }
        self.scorer = LayaScorer(dModel: config.headDModel)
    }

    public func callAsFunction(
        hiddenStates: MLXArray,
        attentionMask: MLXArray?,
        markerPositions: [[Int]],
        questionType: Int
    ) -> MLXArray {
        let B = hiddenStates.dim(0)
        let H = hiddenStates.dim(2)

        // Add type embedding
        let qtypeArray = MLXArray([Int32(questionType)])
        let typeEmbedding = type_emb(qtypeArray).reshaped([1, 1, H])
        var h = hiddenStates + typeEmbedding

        // Padding mask for head attention: ~attention_mask
        let paddingMask: MLXArray?
        if let attMask = attentionMask {
            paddingMask = (attMask .== MLXArray(0))
        } else {
            paddingMask = nil
        }

        for layer in layers {
            h = layer(h, paddingMask: paddingMask)
        }

        // Gather marker representations
        let maxMarkers = markerPositions.map { $0.count }.max() ?? 1
        var markerRepsList: [MLXArray] = []

        for b in 0..<B {
            let positions = markerPositions[b]
            var batchMarkers: [MLXArray] = []
            for p in positions {
                let clampedP = max(0, min(p, h.dim(1) - 1))
                batchMarkers.append(h[b, clampedP].reshaped([1, H]))
            }
            // Pad if necessary
            while batchMarkers.count < maxMarkers {
                batchMarkers.append(MLXArray.zeros([1, H]))
            }
            markerRepsList.append(concatenated(batchMarkers, axis: 0).reshaped([1, maxMarkers, H]))
        }

        let markerTensor = concatenated(markerRepsList, axis: 0) // [B, maxMarkers, H]
        let logits = scorer(markerTensor) // [B, maxMarkers]
        return logits
    }
}
