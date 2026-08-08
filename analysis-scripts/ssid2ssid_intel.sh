#!/bin/bash
# Thin wrapper: ssid2ssid_intel's single definition lives in
# ssid_intel_functions.sh, shared with the batch pipeline.
#
# The previous version defined the function but never called it (and had no
# shebang), so running it populated nothing -- ssid_intel stayed empty and every
# later pass had no rows to work on.
source ./analysis-scripts/ssid_intel_functions.sh
ssid2ssid_intel
