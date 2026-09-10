# Current recipe comparison

- Historical original SGLang + BF16 DFlash2 D=8: **57.11 tok/s** median whole-request completion rate
- Current SGLang + calibrated Maurienne NVFP4 DFlash2 D=16: **71.50 tok/s**
- Recipe-version increase: **25.19%**
- Frozen request payload matches: **27/27**
- Frozen quality: **24/27 historical**, **24/27 current**
- Exact visible outputs: **21/27**
- Runtime errors: **0** in both versions
- Maximum host swap growth: **0 bytes** in both versions

The comparison uses the same target revision, hardware class, 27 frozen request payloads, sampler, FP8 KV, BF16 recurrent state, and `mem_fraction_static=0.70`. It was collected in separate sessions and several deployment variables changed together, so it is a measured recipe-version result rather than a single-variable ablation or variance estimate. MiaAI-Lab established the related single-GB10 SGLang scaffold and concurrency-aware GDN/Mamba pool pattern; its current main profile uses native MTP/EAGLE rather than this repository's calibrated DFlash2 path.

See `evidence/recipe-refresh-gb10.json` for exact rates and all 27 output-hash comparisons.

# Historical measured comparison

- no-spec median end-to-end completion rate: **12.34 tok/s**
- DFlash2 median end-to-end completion rate: **57.11 tok/s**
- aggregate median ratio: **4.63x**
- median paired row ratio: **4.63x**
- exact outputs: **15/27**
- quality: **24/27 no-spec**, **24/27 DFlash2**
- operational completion: **True**
- safety eligible: **True**
- frozen quality gate complete: **False**
- minimum MemAvailable: **29.66 GiB no-spec**, **27.59 GiB DFlash2**
- maximum swap growth: **0 bytes no-spec**, **0 bytes DFlash2**
- DFlash2 final acceptance: **3.95 tokens**, **0.42142857142857143 rate**

## Per-fixture median end-to-end completion tok/s

| Fixture | No spec | DFlash2 | Ratio |
|---|---:|---:|---:|
| code | 12.43 | 67.56 | 5.43x |
| copy_json | 12.42 | 73.16 | 5.89x |
| copy_python | 12.42 | 70.29 | 5.66x |
| json | 11.76 | 31.34 | 2.66x |
| literal | 7.76 | 4.28 | 0.55x |
| math | 12.33 | 49.70 | 4.03x |
| prose | 12.24 | 20.97 | 1.71x |
| reasoning | 12.31 | 46.59 | 3.78x |
| tool | 11.81 | 38.22 | 3.24x |

The frozen lexical prose checker failed all three prose rows in both arms. This shared failure remains a quality-gate failure; post-hoc inspection does not relabel it.

One paired three-repetition operational sweep on one NVIDIA GB10. Results are workload-specific. Exact parity and quality are separate outcomes. The fixed no-spec then DFlash2 order does not isolate run-order drift.
