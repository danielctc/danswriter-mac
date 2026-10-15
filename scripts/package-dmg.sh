#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/package.sh
bash scripts/create-dmg.sh
