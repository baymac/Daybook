#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
python3 "$ROOT/install_bridge.py" --browser brave
echo "Press Return to close."
read -r
