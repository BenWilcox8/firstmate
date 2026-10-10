#!/usr/bin/env bash
# Regression for the live foreign session-lock owner and non-owner Stop loop.
# The executable reproduction runs the real auto-arm and turn-end guard paths.
set -eu

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found (the turn-end reproduction is a Python program)"; exit 0; }

python3 "$(dirname "${BASH_SOURCE[0]}")/fm-turnend-foreign-owner-repro.py"
