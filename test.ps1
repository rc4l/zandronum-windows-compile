# Test script for basic functionality
param(
    [switch]$TestOnly
)

$ScriptRoot = $PSScriptRoot
Write-Host "Testing Zandronum build system..." -ForegroundColor Green
Write-Host "Script root: $ScriptRoot"

# Test basic directory creation
$testDirs = @("deps", "src", "build", "tools")
foreach ($dir in $testDirs) {
    $path = Join-Path $ScriptRoot $dir
    if (-not (Test-Path $path)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
        Write-Host "Created: $path" -ForegroundColor Yellow
    } else {
        Write-Host "Exists: $path" -ForegroundColor Green
    }
}

# Test network connectivity
try {
    $response = Invoke-WebRequest -Uri "https://github.com/TorrSamaho/zandronum" -UseBasicParsing -TimeoutSec 10
    if ($response.StatusCode -eq 200) {
        Write-Host "✓ GitHub repository accessible" -ForegroundColor Green
    }
} catch {
    Write-Host "✗ GitHub repository not accessible: $_" -ForegroundColor Red
}

# Test PowerShell version
$psVersion = $PSVersionTable.PSVersion
Write-Host "PowerShell version: $psVersion"
if ($psVersion.Major -ge 5) {
    Write-Host "✓ PowerShell version is compatible" -ForegroundColor Green
} else {
    Write-Host "✗ PowerShell version too old (need 5.1+)" -ForegroundColor Red
}

Write-Host "Basic test completed!" -ForegroundColor Green
