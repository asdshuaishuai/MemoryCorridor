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
moon check views/library.mbt.md --deny-warn
moon build --target wasm wasm
moon build --target wasm-gc wasm
"${NODE_BINARY:-node}" scripts/wasm_e2e.mjs
"${NODE_BINARY:-node}" scripts/wasm_session_e2e.mjs
"${NODE_BINARY:-node}" scripts/wasm_web_storage_e2e.mjs
python3 scripts/source_audit.py
python3 scripts/mutation_check.py
