#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
RUNNER="$SCRIPT_DIR/run.sh"

sh "$RUNNER" smoke all
sh "$RUNNER" server space-age
sh "$RUNNER" fixture base security
sh "$RUNNER" mod-fixture base all
sh "$RUNNER" mod-fixture space-age space-age-planets
sh "$RUNNER" ai-e2e base
