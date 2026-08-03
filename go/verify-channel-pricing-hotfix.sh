#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

(
  cd "$SCRIPT_DIR"
  go test ./controller -run 'TestQuoteTopUp|TestValidateEpayCallback' -count=1
  go build ./controller
)

printf '%s\n' 'channel-pricing behavior verified in go/'
