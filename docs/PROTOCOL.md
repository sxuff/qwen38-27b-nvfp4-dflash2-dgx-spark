# Experimental protocol

This repository reports one paired operational sweep on one NVIDIA GB10.

- Target: exact stock `RadixArk/Qwen3.8-27B-NVFP4` revision in `manifests/target.json`.
- Treatment: the same runtime, target, prompts, sampler, request order, and launch settings, adding only DFlash2 and its pinned draft.
- Order: no-spec first, DFlash2 second, one fresh model load per arm.
- Repetitions: three per fixture, 27 rows per arm.
- Metrics: streaming TTFT, whole-request completion tok/s, finish reason, output hash, quality result, host memory, and swap growth. Whole-request tok/s includes prefill and first-token latency because SSE chunks can contain multiple speculative tokens.
- Safety: at least 15 GiB `MemAvailable`; at most 512 MiB swap growth from the study baseline.
- Exact parity is reported separately from executable/semantic quality.
- This is a single sweep, not a multi-day performance estimate.
- The fixed no-spec then DFlash2 order is disclosed. It does not isolate thermal or run-order drift.

The machine-readable frozen contract is [`protocol.json`](../protocol.json).
