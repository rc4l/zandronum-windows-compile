# Test script to verify build.ps1 parameter handling
param(
    [switch]$TestDynamic
)

Write-Host "=== Testing build.ps1 parameter handling ==="

if ($TestDynamic) {
    Write-Host "Testing dynamic linking mode..."
    .\build.ps1 -TestDynamicLinking -WhatIf
} else {
    Write-Host "Testing normal (static linking) mode..."
    .\build.ps1 -WhatIf
}

Write-Host "`nDone!"
