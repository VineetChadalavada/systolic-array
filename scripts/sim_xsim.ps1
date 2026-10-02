# Run the self-checking testbench on the Vivado simulator (xsim).
#
#   powershell -File scripts\sim_xsim.ps1 [-Rows 4] [-Cols 4] [-Seed 1]
#
# xsim is 4-state (X/Z), so it also catches X-propagation problems that a
# 2-state simulator like Verilator cannot see.
param([int]$Rows = 4, [int]$Cols = 4, [int]$Seed = 1)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$bin  = "C:\Xilinx\Vivado\2021.1\bin"
$work = "$root\build\xsim_${Rows}x${Cols}_s$Seed"
New-Item -ItemType Directory -Force $work | Out-Null
Push-Location $work
try {
    $src = @("rtl\sa_pe.sv", "rtl\sa_array.sv", "rtl\sa_core.sv", "tb\sa_props.sv", "tb\tb_sa_core.sv") |
           ForEach-Object { "$root\$_" }
    # options go through a file: the .bat wrappers split arguments at '='
    $opts = @("-sv", "-d", "ROWS=$Rows", "-d", "COLS=$Cols", "-d", "SEED=$Seed") +
            ($src | ForEach-Object { '"' + $_ + '"' })
    Set-Content -Path xvlog.f -Value ($opts -join "`n") -Encoding ascii
    & "$bin\xvlog.bat" -f xvlog.f | Out-Null
    if ($LASTEXITCODE -ne 0) { Get-Content xvlog.log; exit 1 }
    & "$bin\xelab.bat" tb_sa_core -s tb_snap -timescale 1ns/1ps | Out-Null
    if ($LASTEXITCODE -ne 0) { Get-Content elaborate.log; exit 1 }
    & "$bin\xsim.bat" tb_snap -R | Where-Object { $_ -match "PASS|FAIL|MISMATCH|Error|phase|busy|coverage|tiles|==" }
} finally {
    Pop-Location
}
