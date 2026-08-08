# build-local.ps1 - 本地编译 GBA 核心（与 CI 完全相同的 Docker 环境）
#
# 前置条件：
#   1. Docker Desktop 已启动
#   2. 已拉取镜像: docker pull raetro/quartus:21.1
#   3. Python 3 可用（用于 bitstream 反转）
#
# 用法（在仓库根目录）:
#   powershell -ExecutionPolicy Bypass -File build-local.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $root

Write-Host "[1/3] Quartus compile (docker raetro/quartus:21.1) ..." -ForegroundColor Cyan
docker run --rm -v "${PWD}:/build" -w /build raetro/quartus:21.1 quartus_sh -t generate.tcl
if ($LASTEXITCODE -ne 0) { throw "Quartus compile failed (exit $LASTEXITCODE)" }

Write-Host "[2/3] Reverse bitstream ..." -ForegroundColor Cyan
python scripts/reverse_bitstream.py src/fpga/build/output_files/ap_core.rbf pkg/Cores/mincer_ray.GBA/bitstream.rbf_r
if ($LASTEXITCODE -ne 0) { throw "reverse_bitstream failed (exit $LASTEXITCODE)" }

Write-Host "[3/3] Package zip ..." -ForegroundColor Cyan
$VERSION = (Get-Content pkg/Cores/mincer_ray.GBA/core.json | ConvertFrom-Json).core.metadata.version
$ZIP = "mincer_ray.GBA_local_${VERSION}.zip"
Push-Location pkg
Compress-Archive -Path * -DestinationPath "..\$ZIP" -Force
Pop-Location

Write-Host "Done: $ZIP" -ForegroundColor Green
Write-Host "Install: copy Cores/ Platforms/ Assets/ to the SD card root." -ForegroundColor Yellow
