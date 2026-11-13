#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
map_vault="$(mktemp -d /tmp/corridor-map-verify.XXXXXX)"
trap 'rm -rf "$map_vault"' EXIT
moon check --target native --deny-warn
moon test --target native
moon build --target native cli mcp web
scripts/platform_smoke.sh
python3 scripts/dep_audit.py
python3 scripts/e2e.py
python3 scripts/page_lifecycle_e2e.py
python3 scripts/source_deletion_e2e.py
python3 scripts/evidence_source_e2e.py
python3 scripts/memory_e2e.py
python3 scripts/impact_e2e.py
python3 scripts/inbox_e2e.py
python3 scripts/topics_e2e.py
python3 scripts/unregistered_e2e.py
python3 scripts/lifecycle_e2e.py
python3 scripts/revocation_lifecycle_e2e.py
python3 scripts/concurrent_e2e.py
python3 scripts/tamper_e2e.py
python3 scripts/page_history_e2e.py
python3 scripts/read_source_e2e.py
python3 scripts/embedding_e2e.py
python3 scripts/dream_e2e.py
python3 scripts/dream_work_e2e.py
python3 scripts/dream_retro_e2e.py
python3 scripts/rsi_driver_e2e.py
python3 scripts/evo_e2e.py
python3 scripts/evo_outcome_e2e.py
python3 scripts/evo_proactive_e2e.py
python3 scripts/evo_expression_e2e.py
python3 scripts/evo_daemon_e2e.py
python3 scripts/evo_schedule_e2e.py
python3 scripts/evo_night_e2e.py
python3 scripts/nlp_adapter_e2e.py
python3 scripts/evo_knowledge_bridge_e2e.py
python3 scripts/provider_e2e.py
python3 scripts/provider_jobs_e2e.py
python3 scripts/authoring_e2e.py
python3 scripts/quality_gate_e2e.py
python3 scripts/record_validation_e2e.py
python3 scripts/lint_predicates_e2e.py
python3 scripts/retrieval_e2e.py
python3 scripts/adversarial_e2e.py
python3 scripts/web_e2e.py
python3 scripts/reading_fixture.py "$map_vault" --with-map
python3 scripts/session_e2e.py
python3 scripts/mcp_e2e.py
python3 scripts/progress_e2e.py
python3 scripts/pack_e2e.py
python3 scripts/release_e2e.py
python3 scripts/interop_e2e.py
python3 scripts/quality_eval.py
python3 scripts/multidomain_eval.py
python3 scripts/model_quality_eval.py
python3 scripts/office_e2e.py
python3 scripts/extraction_e2e.py
python3 scripts/htmldoc_e2e.py
python3 scripts/ocr_e2e.py
python3 scripts/redundancy_e2e.py
moon check views/library.mbt.md --deny-warn
moon build --target wasm wasm
moon build --target wasm wasipure
moon build --target wasm-gc wasm
"${NODE_BINARY:-node}" scripts/wasm_e2e.mjs
"${NODE_BINARY:-node}" scripts/wasm_session_e2e.mjs
"${NODE_BINARY:-node}" scripts/wasm_web_storage_e2e.mjs
"${WASM_PYTHON:-python3}" scripts/wasm_service_e2e.py
"${WASM_PYTHON:-python3}" scripts/wasipure_e2e.py
# second-runtime face: the same direct-run suite under WasmEdge (skip when absent)
WASI_RUNTIME=wasmedge "${WASM_PYTHON:-python3}" scripts/wasipure_e2e.py
# embedded WasmEdge host (corridor-wedge): build + run the same suite through
# the embedded binary; skipped without WASMEDGE_PREFIX dev files
if [ -n "${WASMEDGE_PREFIX:-}" ]; then
  sh scripts/build_wedge_host.sh
  WASI_RUNTIME=wasmedge WASMEDGE_BIN="$PWD/_build/wedge/corridor-wedge" \
    "${WASM_PYTHON:-python3}" scripts/wasipure_e2e.py
else
  echo "SKIP corridor-wedge face: set WASMEDGE_PREFIX to WasmEdge >=0.18 dev files (scripts/build_wedge_host.sh)"
fi
python3 scripts/source_audit.py
python3 scripts/mutation_check.py
