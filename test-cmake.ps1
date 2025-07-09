function Test-CMakeDownload {
    $DepsDir = Join-Path (Get-Location) "deps"
    $cmakeDir = Join-Path $DepsDir "cmake"
    $cmakeExe = Join-Path $cmakeDir "bin\cmake.exe"
    
    Write-Host "Testing CMake download..." -ForegroundColor Green
    Write-Host "Target directory: $cmakeDir"
    
    if (Test-Path $cmakeExe) {
        Write-Host "CMake already exists at: $cmakeExe" -ForegroundColor Yellow
        return $cmakeExe
    }
    
    $cmakeUrl = "https://github.com/Kitware/CMake/releases/download/v3.28.1/cmake-3.28.1-windows-x86_64.zip"
    $cmakeZip = Join-Path $DepsDir "cmake.zip"
    
    Write-Host "Downloading CMake from: $cmakeUrl"
    
    try {
        if (-not (Test-Path $DepsDir)) {
            New-Item -ItemType Directory -Path $DepsDir -Force | Out-Null
        }
        
        # Download CMake
        $webClient = New-Object System.Net.WebClient
        $webClient.DownloadFile($cmakeUrl, $cmakeZip)
        Write-Host "Downloaded to: $cmakeZip"
        
        # Extract CMake
        Write-Host "Extracting CMake..."
        Expand-Archive -Path $cmakeZip -DestinationPath $DepsDir -Force
        
        # Move to final location
        $extractedPath = Join-Path $DepsDir "cmake-3.28.1-windows-x86_64"
        if (Test-Path $extractedPath) {
            Move-Item $extractedPath $cmakeDir -Force
            Write-Host "Moved to: $cmakeDir"
        }
        
        # Cleanup
        Remove-Item $cmakeZip -Force -ErrorAction SilentlyContinue
        
        if (Test-Path $cmakeExe) {
            Write-Host "✓ CMake ready at: $cmakeExe" -ForegroundColor Green
            
            # Test CMake
            $version = & $cmakeExe --version
            Write-Host "CMake version: $($version[0])" -ForegroundColor Cyan
            
            return $cmakeExe
        } else {
            throw "CMake executable not found after extraction"
        }
        
    } catch {
        Write-Host "✗ Failed to setup CMake: $_" -ForegroundColor Red
        throw
    }
}

# Run the test
try {
    Test-CMakeDownload
    Write-Host "CMake download test completed successfully!" -ForegroundColor Green
} catch {
    Write-Host "CMake download test failed: $_" -ForegroundColor Red
}
