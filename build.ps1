#Requires -Version 5.1
<#
.SYNOPSIS
    Self-contained Zandronum Windows build system
    
.DESCRIPTION
    A touchless, portable build system for Zandronum on Windows.
    Downloads all dependencies locally, builds everything from source,
    and requires no global installations (except VS Build Tools if not found).
    
.PARAMETER Platform
    Target platform: Win32 or x64 (default: Win32)
    
.PARAMETER Configuration
    Build configuration: Debug or Release (default: Release)
    
.PARAMETER Clean
    Clean build directories before building
    
.PARAMETER SkipDeps
    Skip dependency download/verification (faster for rebuilds)
    
.EXAMPLE
    .\build.ps1
    .\build.ps1 -Platform x64 -Configuration Debug
    .\build.ps1 -Clean
#>

param(
    [ValidateSet("x64")]
    [string]$Platform = "x64",
    
    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Release",
    
    [switch]$Clean,
    [switch]$SkipDeps
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Script constants
$ScriptRoot = $PSScriptRoot
$DepsDir = Join-Path $ScriptRoot "deps"
$SrcDir = Join-Path $ScriptRoot "src"
$BuildDir = Join-Path $ScriptRoot "build"
$ToolsDir = Join-Path $ScriptRoot "tools"

# Dependency versions and URLs
$Dependencies = @{
    CMake = @{
        Version = "3.28.1"
        Url = "https://github.com/Kitware/CMake/releases/download/v3.28.1/cmake-3.28.1-windows-x86_64.zip"
        ExtractPath = "cmake-3.28.1-windows-x86_64"
    }
    NASM = @{
        Version = "2.16.01"
        Url = "https://www.nasm.us/pub/nasm/releasebuilds/2.16.01/win64/nasm-2.16.01-win64.zip"
        ExtractPath = "nasm-2.16.01"
    }
    FMOD = @{
        Version = "4.44.64"
        Url = "https://zdoom.org/files/fmod/fmodapi44464win-installer.exe"
        ExtractPath = "fmod"
    }
    OpenSSL = @{
        Version = "3.2.0"
        Url = "https://slproweb.com/download/Win32OpenSSL-3_2_0.msi"
        ExtractPath = "openssl"
    }
    Python = @{
        Version = "3.12.1"
        Url = "https://www.python.org/ftp/python/3.12.1/python-3.12.1-embed-amd64.zip"
        ExtractPath = "python"
    }
    Opus = @{
        Version = "1.4"
        Url = "https://downloads.xiph.org/releases/opus/opus-1.4.tar.gz"
        ExtractPath = "opus"
    }
}

# Logging functions
function Write-Status {
    param([string]$Message)
    Write-Host "==> $Message" -ForegroundColor Green
}

function Write-Warning {
    param([string]$Message)
    Write-Host "WARNING: $Message" -ForegroundColor Yellow
}

function Write-Error {
    param([string]$Message)
    Write-Host "ERROR: $Message" -ForegroundColor Red
}

# Utility functions
function Test-CommandExists {
    param([string]$Command)
    try {
        if (Get-Command $Command -ErrorAction SilentlyContinue) {
            return $true
        }
    } catch {
        return $false
    }
    return $false
}

function Invoke-Download {
    param(
        [string]$Url,
        [string]$OutputPath
    )
    
    Write-Status "Downloading: $Url"
    try {
        $webClient = New-Object System.Net.WebClient
        $webClient.DownloadFile($Url, $OutputPath)
        Write-Host "Downloaded to: $OutputPath"
    } catch {
        throw "Failed to download $Url`: $_"
    }
}

function Expand-Archive7Zip {
    param(
        [string]$ArchivePath,
        [string]$DestinationPath
    )
    
    if (-not (Test-Path $DestinationPath)) {
        New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
    }
    
    # Try using built-in Expand-Archive first
    try {
        Expand-Archive -Path $ArchivePath -DestinationPath $DestinationPath -Force
        return
    } catch {
        Write-Warning "Built-in Expand-Archive failed, trying alternative methods"
    }
    
    # Try 7-Zip if available
    $sevenZip = Get-Command "7z.exe" -ErrorAction SilentlyContinue
    if ($sevenZip) {
        & $sevenZip.Source x $ArchivePath "-o$DestinationPath" -y
        if ($LASTEXITCODE -eq 0) { return }
    }
    
    throw "Failed to extract $ArchivePath"
}

function Find-VisualStudio {
    Write-Status "Looking for Visual Studio installation..."
    
    # Try to find vswhere.exe
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) {
        $vswhere = "${env:ProgramFiles}\Microsoft Visual Studio\Installer\vswhere.exe"
    }
    
    if (Test-Path $vswhere) {
        $vsInstallations = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
        if ($vsInstallations) {
            $vsPath = $vsInstallations[0]
            Write-Host "Found Visual Studio at: $vsPath"
            
            # Check for v140 toolset availability (may be installed separately)
            $v140Path = Join-Path $vsPath "VC\Tools\MSVC"
            if (Test-Path $v140Path) {
                return $vsPath
            }
            
            # Return path even if v140 not found - it might still work
            return $vsPath
        }
    }
    
    Write-Warning "Visual Studio with v140 toolset not found. Please install Visual Studio 2022 with v140 toolset."
    Write-Warning "You can continue, but the build may fail."
    return $null
}

function Initialize-Directories {
    Write-Status "Initializing directory structure..."
    
    @($DepsDir, $SrcDir, $BuildDir, $ToolsDir) | ForEach-Object {
        if (-not (Test-Path $_)) {
            New-Item -ItemType Directory -Path $_ -Force | Out-Null
            Write-Host "Created: $_"
        }
    }
}

function Get-CMake {
    $cmakeDir = Join-Path $DepsDir "cmake"
    $cmakeExe = Join-Path $cmakeDir "bin\cmake.exe"
    
    if (Test-Path $cmakeExe) {
        Write-Host "CMake already exists at: $cmakeExe"
        return $cmakeExe
    }
    
    Write-Status "Setting up CMake..."
    $cmakeZip = Join-Path $DepsDir "cmake.zip"
    
    Invoke-Download $Dependencies.CMake.Url $cmakeZip
    Expand-Archive7Zip $cmakeZip $DepsDir
    
    $extractedPath = Join-Path $DepsDir $Dependencies.CMake.ExtractPath
    if (Test-Path $extractedPath) {
        Move-Item $extractedPath $cmakeDir -Force
    }
    
    Remove-Item $cmakeZip -Force -ErrorAction SilentlyContinue
    
    if (Test-Path $cmakeExe) {
        Write-Host "CMake ready at: $cmakeExe"
        return $cmakeExe
    } else {
        throw "Failed to setup CMake"
    }
}

function Get-NASM {
    $nasmDir = Join-Path $DepsDir "nasm"
    $nasmExe = Join-Path $nasmDir "nasm.exe"
    
    if (Test-Path $nasmExe) {
        Write-Host "NASM already exists at: $nasmExe"
        return $nasmExe
    }
    
    Write-Status "Setting up NASM..."
    $nasmZip = Join-Path $DepsDir "nasm.zip"
    
    Invoke-Download $Dependencies.NASM.Url $nasmZip
    Expand-Archive7Zip $nasmZip $DepsDir
    
    $extractedPath = Join-Path $DepsDir $Dependencies.NASM.ExtractPath
    if (Test-Path $extractedPath) {
        Move-Item $extractedPath $nasmDir -Force
    }
    
    Remove-Item $nasmZip -Force -ErrorAction SilentlyContinue
    
    if (Test-Path $nasmExe) {
        Write-Host "NASM ready at: $nasmExe"
        return $nasmExe
    } else {
        throw "Failed to setup NASM"
    }
}

function Get-Python {
    $pythonDir = Join-Path $DepsDir "python"
    $pythonExe = Join-Path $pythonDir "python.exe"
    
    if (Test-Path $pythonExe) {
        Write-Host "Python already exists at: $pythonExe"
        return $pythonExe
    }
    
    Write-Status "Setting up Python..."
    $pythonZip = Join-Path $DepsDir "python.zip"
    
    Invoke-Download $Dependencies.Python.Url $pythonZip
    Expand-Archive7Zip $pythonZip $pythonDir
    
    Remove-Item $pythonZip -Force -ErrorAction SilentlyContinue
    
    if (Test-Path $pythonExe) {
        Write-Host "Python ready at: $pythonExe"
        return $pythonExe
    } else {
        throw "Failed to setup Python"
    }
}

function Get-WindowsSDK {
    Write-Status "Setting up DirectX headers from Windows SDK..."
    
    # Create a DirectX SDK-like structure using Windows SDK files
    $dxDir = Join-Path $DepsDir "directx-from-winsdk"
    $dxIncludeDir = Join-Path $dxDir "Include"
    $dxLibDir = Join-Path $dxDir "Lib"
    
    if (Test-Path (Join-Path $dxIncludeDir "d3d9.h")) {
        Write-Host "DirectX SDK structure already exists at: $dxDir"
        $env:DXSDK_DIR = $dxDir
        return $dxDir
    }
    
    # Find Windows SDK
    $windowsKitsPath = "${env:ProgramFiles(x86)}\Windows Kits\10"
    if (-not (Test-Path $windowsKitsPath)) {
        $windowsKitsPath = "${env:ProgramFiles}\Windows Kits\10"
    }
    
    if (-not (Test-Path $windowsKitsPath)) {
        Write-Warning "Could not find Windows SDK. Please ensure Visual Studio 2022 with Windows SDK is installed."
        return $null
    }
    
    $includePath = Join-Path $windowsKitsPath "Include"
    $libPath = Join-Path $windowsKitsPath "Lib"
    
    # Find the latest SDK version
    $versions = Get-ChildItem $includePath -Directory | Where-Object { $_.Name -match "^\d+\.\d+\.\d+\.\d+$" } | Sort-Object Name -Descending
    
    if (-not $versions) {
        Write-Warning "Could not find Windows SDK versions."
        return $null
    }
    
    $latestVersion = $versions[0].Name
    $sdkIncludePathUm = Join-Path $includePath "$latestVersion\um"
    $sdkIncludePathShared = Join-Path $includePath "$latestVersion\shared"
    $sdkLibPath = Join-Path $libPath "$latestVersion\um\x64"
    
    # Check if DirectX headers exist
    $d3d9Header = Join-Path $sdkIncludePathShared "d3d9.h"
    $xinputHeader = Join-Path $sdkIncludePathUm "xinput.h"
    
    if (-not ((Test-Path $d3d9Header) -and (Test-Path $xinputHeader))) {
        Write-Warning "Could not find DirectX headers in Windows SDK $latestVersion."
        return $null
    }
    
    Write-Host "Found Windows SDK $latestVersion with DirectX headers"
    Write-Host "Creating DirectX SDK-like structure at: $dxDir"
    
    # Create directory structure
    New-Item -ItemType Directory -Path $dxIncludeDir -Force | Out-Null
    New-Item -ItemType Directory -Path $dxLibDir -Force | Out-Null
    
    # Copy DirectX headers to the expected structure
    Copy-Item "$sdkIncludePathShared\d3d*.h" $dxIncludeDir -Force
    Copy-Item "$sdkIncludePathUm\xinput.h" $dxIncludeDir -Force
    
    # Copy DirectX libraries
    $sdkLibFiles = @("dxguid.lib", "dinput8.lib", "d3d9.lib", "xinput.lib")
    foreach ($libFile in $sdkLibFiles) {
        $libSource = Join-Path $sdkLibPath $libFile
        if (Test-Path $libSource) {
            Copy-Item $libSource $dxLibDir -Force
            Write-Host "Copied library: $libFile"
        } else {
            Write-Warning "Library not found: $libFile"
        }
    }
    
    # Set environment variable to point to our DirectX SDK structure
    $env:DXSDK_DIR = $dxDir
    
    Write-Host "DirectX SDK structure ready at: $dxDir"
    return $dxDir
}

function Get-ZandronumSource {
    $zanSrcDir = Join-Path $SrcDir "zandronum"
    
    if (Test-Path $zanSrcDir) {
        Write-Host "Zandronum source already exists at: $zanSrcDir"
        return $zanSrcDir
    }
    
    Write-Status "Cloning Zandronum source code..."
    
    # Try Git first (preferred)
    if (Test-CommandExists "git") {
        try {
            Set-Location $SrcDir
            & git clone https://github.com/TorrSamaho/zandronum.git
            if ($LASTEXITCODE -eq 0 -and (Test-Path $zanSrcDir)) {
                Write-Host "Successfully cloned from Git repository"
                return $zanSrcDir
            }
        } catch {
            Write-Warning "Git clone failed: $_"
        }
    }
    
    # Fallback to downloading zip
    Write-Status "Downloading Zandronum source as ZIP..."
    $zipPath = Join-Path $SrcDir "zandronum.zip"
    try {
        Invoke-Download "https://github.com/TorrSamaho/zandronum/archive/refs/heads/master.zip" $zipPath
        Expand-Archive7Zip $zipPath $SrcDir
        
        $extractedPath = Join-Path $SrcDir "zandronum-master"
        if (Test-Path $extractedPath) {
            Move-Item $extractedPath $zanSrcDir -Force
        }
        
        Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
        
        if (Test-Path $zanSrcDir) {
            Write-Host "Zandronum source ready at: $zanSrcDir"
            return $zanSrcDir
        }
    } catch {
        throw "Failed to download Zandronum source: $_"
    }
    
    throw "Failed to obtain Zandronum source code"
}

function Initialize-Dependencies {
    Write-Status "Setting up dependencies..."
    
    # Always get source code 
    $script:ZandronumSrc = Get-ZandronumSource
    
    if ($SkipDeps) {
        Write-Status "Skipping tool dependency setup as requested"
        
        # Try to find existing tools
        $cmakeExe = Join-Path $DepsDir "cmake\bin\cmake.exe"
        if (Test-Path $cmakeExe) {
            $script:CMakeExe = $cmakeExe
            Write-Host "Using existing CMake at: $cmakeExe"
        } else {
            $script:CMakeExe = Get-CMake
        }
        
        return
    }
    
    # Get essential tools
    $script:CMakeExe = Get-CMake
    $script:NASMExe = Get-NASM
    $script:PythonExe = Get-Python
    $script:WindowsSDK = Get-WindowsSDK
    
    if (-not $script:WindowsSDK) {
        Write-Warning "Windows SDK with DirectX headers not found. Build may fail."
    }
    
    Write-Status "Dependencies setup complete!"
}

function Invoke-CMakeGenerate {
    Write-Status "Generating build files with CMake..."
    
    $buildPlatformDir = Join-Path $BuildDir $Platform
    if (-not (Test-Path $buildPlatformDir)) {
        New-Item -ItemType Directory -Path $buildPlatformDir -Force | Out-Null
    }
    
    if ($Clean -and (Test-Path $buildPlatformDir)) {
        Write-Status "Cleaning build directory..."
        Remove-Item "$buildPlatformDir\*" -Recurse -Force
    }
    
    Set-Location $buildPlatformDir
    
    $generator = "Visual Studio 17 2022"
    $architecture = "x64"
    
    $cmakeArgs = @(
        "-G", $generator
        "-A", $architecture
        "-T", "v143"
        "-DCMAKE_BUILD_TYPE=$Configuration"
    )
    
    # Add dependency paths when available
    # For now, we'll configure basic CMake generation
    # TODO: Add FMOD, OpenSSL, etc. paths when those dependencies are implemented
    
    $cmakeArgs += $script:ZandronumSrc
    
    Write-Host "Running: $script:CMakeExe $($cmakeArgs -join ' ')"
    
    try {
        & $script:CMakeExe @cmakeArgs
        if ($LASTEXITCODE -ne 0) {
            throw "CMake generation failed with exit code $LASTEXITCODE"
        }
        Write-Host "CMake generation successful!"
    } catch {
        throw "CMake generation failed: $_"
    }
}

function Invoke-Build {
    Write-Status "Building Zandronum..."
    
    $buildPlatformDir = Join-Path $BuildDir $Platform
    Set-Location $buildPlatformDir
    
    $buildArgs = @(
        "--build", "."
        "--config", $Configuration
        "--parallel"
    )
    
    Write-Host "Running: $script:CMakeExe $($buildArgs -join ' ')"
    
    try {
        & $script:CMakeExe @buildArgs
        if ($LASTEXITCODE -ne 0) {
            throw "Build failed with exit code $LASTEXITCODE"
        }
        Write-Host "Build successful!"
    } catch {
        throw "Build failed: $_"
    }
}

function Show-Results {
    Write-Status "Build completed!"
    
    $buildPlatformDir = Join-Path $BuildDir $Platform
    $outputDir = Join-Path $buildPlatformDir $Configuration
    
    if (Test-Path $outputDir) {
        Write-Host ""
        Write-Host "Output directory: $outputDir" -ForegroundColor Cyan
        
        $exeFiles = Get-ChildItem $outputDir -Filter "*.exe" -ErrorAction SilentlyContinue
        if ($exeFiles) {
            Write-Host "Built executables:" -ForegroundColor Cyan
            $exeFiles | ForEach-Object {
                $size = [math]::Round($_.Length / 1MB, 2)
                Write-Host "  $($_.Name) ($size MB)" -ForegroundColor White
            }
        }
        
        $pk3Files = Get-ChildItem $buildPlatformDir -Filter "*.pk3" -ErrorAction SilentlyContinue
        if ($pk3Files) {
            Write-Host "Game data files:" -ForegroundColor Cyan
            $pk3Files | ForEach-Object {
                $size = [math]::Round($_.Length / 1MB, 2)
                Write-Host "  $($_.Name) ($size MB)" -ForegroundColor White
            }
        }
    }
}

# Main execution
function Main {
    try {
        Write-Status "Starting Zandronum build process..."
        Write-Host "Platform: $Platform, Configuration: $Configuration"
        Write-Host "Script root: $ScriptRoot"
        
        Initialize-Directories
        Find-VisualStudio
        Initialize-Dependencies
        Invoke-CMakeGenerate
        Invoke-Build
        Show-Results
        
        Write-Status "Build process completed successfully!"
        
    } catch {
        Write-Error "Build failed: $_"
        Write-Host $_.ScriptStackTrace -ForegroundColor Red
        exit 1
    } finally {
        Set-Location $ScriptRoot
    }
}

# Run main function
Main
