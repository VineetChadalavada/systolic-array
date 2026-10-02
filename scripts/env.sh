#!/usr/bin/env bash
# Put the open-source EDA tools on the PATH.
# Set OSS_CAD_SUITE if the suite is not in ~/oss-cad-suite.
OSS_CAD_SUITE="${OSS_CAD_SUITE:-$HOME/oss-cad-suite}"
if [ -d "$OSS_CAD_SUITE/bin" ]; then
    export PATH="$OSS_CAD_SUITE/bin:$PATH"
fi
