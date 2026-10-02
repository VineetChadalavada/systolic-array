# Run the OpenLane 2 RTL-to-GDS flow on sa_core (SKY130A, sky130_fd_sc_hd).
#
#   powershell -File scripts\openlane.ps1 [-Period 10.0] [-Rows 4] [-Cols 4]
#
# Uses the OpenLane Docker image directly.  The flow runs on the container's
# own Linux filesystem (a Windows bind mount is far too slow for the tens of
# thousands of files it writes); the SKY130 PDK lives in the Docker volume
# "openlane-pdk", so it is downloaded only once.  At the end the reports, the
# final metrics and the GDS are copied back to syn/openlane/results/<tag>/.
param(
    [double]$Period = 10.0,
    [int]$Rows = 4,
    [int]$Cols = 4
)
$ErrorActionPreference = "Stop"
$root  = Split-Path -Parent $PSScriptRoot
$image = "ghcr.io/efabless/openlane2:2.3.10"
$tag   = "${Rows}x${Cols}_p" + ($Period -replace '\.', '_')

# per-size copy of the config (the image has no sed, and embedded quotes do
# not survive the trip PowerShell -> docker -> bash)
$cfg = Get-Content "$root\syn\openlane\config.json" -Raw
$cfg = $cfg -replace 'ROWS=\d+', "ROWS=$Rows" -replace 'COLS=\d+', "COLS=$Cols"
[IO.File]::WriteAllText("$root\syn\openlane\config_$tag.json", $cfg)

$inner = @"
set -e
mkdir -p /tmp/p/syn
cp -r /work/rtl /tmp/p/rtl
cp -r /work/syn/openlane /tmp/p/syn/openlane
rm -rf /tmp/p/syn/openlane/runs /tmp/p/syn/openlane/results
cd /tmp/p/syn/openlane
openlane --run-tag $tag --overwrite -c CLOCK_PERIOD=$Period config_$tag.json
out=/work/syn/openlane/results/$tag
rm -rf `$out; mkdir -p `$out
cp runs/$tag/final/metrics.json `$out/ 2>/dev/null || true
cp runs/$tag/final/metrics.csv  `$out/ 2>/dev/null || true
cp -r runs/$tag/final/gds       `$out/ 2>/dev/null || true
find runs/$tag -path '*reports*' \( -name '*.rpt' -o -name '*summary*' \) -exec cp --parents {} `$out/ \; 2>/dev/null || true
cp runs/$tag/resolved.json `$out/ 2>/dev/null || true
echo DONE
"@

docker run --rm `
    -v "${root}:/work" `
    -v "openlane-pdk:/root/.volare" `
    $image `
    bash -c $inner
