#!/bin/bash
# Thin wrapper: check_common's single definition lives in
# ssid_intel_functions.sh. Its 5a filter excludes embedded/trailing 00 bytes.
source ./analysis-scripts/ssid_intel_functions.sh
check_common
