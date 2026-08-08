#!/bin/bash
# Fill ssid.vendor from the IEEE OUI list.
#
# The implementation lives in vendor_functions.sh, shared with
# ssid_intel_functions.sh. This file previously carried its own copy that called
# a `mysql_escape` helper defined nowhere in the repo, so every UPDATE it built
# was a syntax error. Its "load the csv into an associative array once" approach
# was the right idea and is what vendor_functions.sh now does.
source ./analysis-scripts/vendor_functions.sh

mac2vendor
