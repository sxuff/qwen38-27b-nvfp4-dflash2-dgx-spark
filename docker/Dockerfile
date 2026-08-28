FROM lmsysorg/sglang@sha256:febfb971c7352570fc445c466ebd6ffc9d896024958e544a60f2137fd85856b1

LABEL org.opencontainers.image.title="Qwen3.8-27B stock NVFP4 DFlash2 for DGX Spark"
LABEL io.sxuff.sglang.base_commit="c4271c3fe1262fc2adbd162c33b25de5255251c5"
LABEL io.sxuff.dflash.donor_commit="c14312a66420b75ca9a11bf1817c4db1fa26b097"
LABEL io.sxuff.dflash.compat_overlay_commit="c90d8c34cf795185ee8de736b7ded9bca3fe0de1"
LABEL io.sxuff.target_revision="52d1adc5f38aa5ebf099c29ed7025ba34cfbb854"
LABEL io.sxuff.draft_revision="50307d4c4cde6860d4eee73e2547cd786fe8e8a4"

COPY overlay/sglang/srt/models/qwen3_5_mtp.py /sgl-workspace/sglang/python/sglang/srt/models/qwen3_5_mtp.py
COPY overlay/sglang/kernels/ops/speculative/dflash.py /sgl-workspace/sglang/python/sglang/kernels/ops/speculative/dflash.py
COPY overlay/sglang/srt/models/dflash.py /sgl-workspace/sglang/python/sglang/srt/models/dflash.py
COPY overlay/sglang/srt/model_executor/model_runner_components/spec_aux_hidden_state.py /sgl-workspace/sglang/python/sglang/srt/model_executor/model_runner_components/spec_aux_hidden_state.py
COPY overlay/sglang/srt/speculative/dflash_utils.py /sgl-workspace/sglang/python/sglang/srt/speculative/dflash_utils.py
COPY overlay/sglang/srt/speculative/dflash_worker_v2.py /sgl-workspace/sglang/python/sglang/srt/speculative/dflash_worker_v2.py

RUN python3 -m py_compile \
  /sgl-workspace/sglang/python/sglang/srt/models/qwen3_5_mtp.py \
  /sgl-workspace/sglang/python/sglang/kernels/ops/speculative/dflash.py \
  /sgl-workspace/sglang/python/sglang/srt/models/dflash.py \
  /sgl-workspace/sglang/python/sglang/srt/model_executor/model_runner_components/spec_aux_hidden_state.py \
  /sgl-workspace/sglang/python/sglang/srt/speculative/dflash_utils.py \
  /sgl-workspace/sglang/python/sglang/srt/speculative/dflash_worker_v2.py
