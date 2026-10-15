#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --product WriteOnLauncher
swift run WriteOnCoreChecks
swift run WriteOnAIChecks
swift run WriteOnResearchChecks
swift run WriteOnUpdateChecks
swift run DansWriter --self-check
echo WRITE_ON_CHECKS_VERIFIED
