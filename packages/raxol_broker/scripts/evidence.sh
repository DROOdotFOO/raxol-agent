#!/bin/bash
# Compile/gate first. Ordinary Mix task discovery may print compiler output.
set -euo pipefail
package_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$package_dir"
# This read-only, precompiled entry point must coexist with a running Mix VM.
export MIX_OS_CONCURRENCY_LOCK=0
exec mix run --no-start --no-compile --no-deps-check -e 'Mix.Tasks.Raxol.Broker.Evidence.run(System.argv())' -- "$@"
