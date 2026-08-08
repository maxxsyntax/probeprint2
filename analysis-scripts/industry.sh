#!/bin/bash
# Flag SSIDs matching the engagement's list of organizations or projects.
#
# lists/industry.txt is gitignored and engagement-specific: one term per line,
# blank lines and #-comments ignored. See industry_functions.sh for why blank
# lines used to be destructive and how matching works.
[ -f .env ] && source .env
source ./analysis-scripts/industry_functions.sh

check_industry "${1:-lists/industry.txt}"
