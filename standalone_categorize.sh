#!/bin/bash
# Thin wrapper over the single definitions in ssid_intel_functions.sh (which
# declares the `categories` table and sources .env). Runs the categorization
# group in order: flag anomalies, mark common SSIDs (5a filter), script-based
# language, then keyword categorization. check_common runs here per decision #1.
source ./ssid_intel_functions.sh
check_anomalies
check_common
check_language
categorize
