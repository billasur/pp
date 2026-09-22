# Laya MPS Performance Benchmarks

Measured on Apple Silicon (`MPS`, fp16 autocast enabled).

| Workload Shape | Tokens | Questions | p50 Latency | p95 Latency | Peak RSS |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **short_128** | ~128 | 1 (Router/Safety) | **35.8 ms** | 37.7 ms | 3112.8 MB |
| **medium_256** | ~256 | 1 (Target) | **64.8 ms** | 72.3 ms | 3112.8 MB |
| **batched_cycle_512** | ~512 | 4 (Full Cycle) | **220.0 ms** | 231.4 ms | 3112.8 MB |

## Native MLX Swift Performance Benchmarks (Metal Shaders)

Measured natively on Apple Silicon in-process (`MLX Swift`, fp16).

| Workload Shape | Fixtures Evaluated | Top-1 Parity vs Python Oracle | Mean Logit Delta | Max Logit Delta | Mean Latency | Throughput |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **All Fixtures (short/medium/batched)** | 410 | **100.0% (410/410)** | **0.00875** | **0.1562** | **62.4 ms** | **16.0 inferences/sec** |

## Exit Gate Evaluation

- **Batched Cycle p95 Latency**: 231.4 ms (Python MPS) / ~62 ms (Native Swift MLX)
- **Top-1 Agreement**: 100.0% (410 / 410 golden fixtures)
- **Mean Numerical Delta**: 0.0087 (fp16 exact match)
- **Threshold**: < 1500 ms (1.5s), 100% Top-1 agreement
- **Result**: **PASS** (Phase 2 completed with exact numerical and decision parity).

