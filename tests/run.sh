#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
sandbox=$(mktemp -d)
trap 'rm -rf "$sandbox"' EXIT
export XDG_CONFIG_HOME="$sandbox/config" XDG_DATA_HOME="$sandbox/data"
export XDG_STATE_HOME="$sandbox/state" XDG_CACHE_HOME="$sandbox/cache"
export FZF_PACK_TEST_ROOT="$root" FZF_PACK_TEST_TMP="$sandbox"
export NVIM_LOG_FILE="$sandbox/nvim.log"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset GIT_CONFIG GIT_CONFIG_SYSTEM GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
mkdir -p "$XDG_CONFIG_HOME/nvim"
nvim --headless -u NONE -i NONE -l "$root/tests/integration.lua"
