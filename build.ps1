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
    SevenZip = @{
        Version = "25.00"
        Url = "https://www.7-zip.org/a/7z2500-x64.zip"
        ExtractPath = "7zip"
    }
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
    
    # Ensure output directory exists
    $outputDir = Split-Path $OutputPath -Parent
    if (-not (Test-Path $outputDir)) {
        New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    }
    
    # Configure security protocols and settings
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls
    [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
    [Net.ServicePointManager]::CheckCertificateRevocationList = $false
    
    $attempts = @(
        {
            Write-Host "Trying BITS transfer..."
            Start-BitsTransfer -Source $Url -Destination $OutputPath -ErrorAction Stop
        },
        {
            Write-Host "Trying Invoke-WebRequest with modern settings..."
            $webRequest = Invoke-WebRequest -Uri $Url -OutFile $OutputPath -UseBasicParsing -UserAgent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" -TimeoutSec 300
        },
        {
            Write-Host "Trying Invoke-WebRequest with relaxed SSL..."
            $webRequest = Invoke-WebRequest -Uri $Url -OutFile $OutputPath -UseBasicParsing -UserAgent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" -SkipCertificateCheck -TimeoutSec 300 2>$null
        },
        {
            Write-Host "Trying WebClient with custom headers..."
            $webClient = New-Object System.Net.WebClient
            $webClient.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36")
            $webClient.DownloadFile($Url, $OutputPath)
        },
        {
            Write-Host "Trying curl if available..."
            if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
                & curl.exe -L -o $OutputPath $Url --tlsv1.2 --ssl-allow-beast --user-agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
                if ($LASTEXITCODE -ne 0) { throw "curl failed" }
            } else {
                throw "curl not available"
            }
        }
    )
    
    foreach ($attempt in $attempts) {
        try {
            & $attempt
            if (Test-Path $OutputPath) {
                $fileSize = (Get-Item $OutputPath).Length
                if ($fileSize -gt 0) {
                    Write-Host "Successfully downloaded $([math]::Round($fileSize / 1MB, 2)) MB to: $OutputPath"
                    return
                } else {
                    Remove-Item $OutputPath -Force -ErrorAction SilentlyContinue
                    throw "Downloaded file is empty"
                }
            } else {
                throw "File not created"
            }
        } catch {
            Write-Warning "Download attempt failed: $_"
            Remove-Item $OutputPath -Force -ErrorAction SilentlyContinue
            continue
        }
    }
    
    throw "All download methods failed for $Url"
}

function Expand-Archive7Zip {
    param(
        [string]$ArchivePath,
        [string]$DestinationPath
    )
    
    if (-not (Test-Path $DestinationPath)) {
        New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
    }
    
    # Use our portable 7-Zip first (supports more formats than built-in)
    if ($script:SevenZipExe -and (Test-Path $script:SevenZipExe)) {
        Write-Host "Using 7zr.exe to extract: $ArchivePath"
        & $script:SevenZipExe x $ArchivePath "-o$DestinationPath" -y
        if ($LASTEXITCODE -eq 0) { 
            Write-Host "7zr.exe extraction successful"
            return 
        } else {
            Write-Warning "7zr.exe extraction failed with exit code: $LASTEXITCODE"
        }
    }
    
    # Try using built-in Expand-Archive for simple ZIP files as fallback
    if ($ArchivePath -like "*.zip") {
        try {
            Write-Host "Trying built-in Expand-Archive as fallback"
            Expand-Archive -Path $ArchivePath -DestinationPath $DestinationPath -Force
            return
        } catch {
            Write-Warning "Built-in Expand-Archive failed: $_"
        }
    }
    
    # Fallback to system 7-Zip if available
    $sevenZip = Get-Command "7z.exe" -ErrorAction SilentlyContinue
    if ($sevenZip) {
        Write-Host "Trying system 7z.exe as last resort"
        & $sevenZip.Source x $ArchivePath "-o$DestinationPath" -y
        if ($LASTEXITCODE -eq 0) { return }
    }
    
    throw "Failed to extract $ArchivePath - all extraction methods failed"
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

function Get-SevenZip {
    $sevenZipDir = Join-Path $DepsDir "7zip"
    $sevenZipExe = Join-Path $sevenZipDir "7z.exe"
    
    if (Test-Path $sevenZipExe) {
        Write-Host "7-Zip already exists at: $sevenZipExe"
        return $sevenZipExe
    }
    
    Write-Status "Setting up 7-Zip (full version for NSIS support)..."
    
    # Create directory for 7-Zip
    if (-not (Test-Path $sevenZipDir)) {
        New-Item -ItemType Directory -Path $sevenZipDir -Force | Out-Null
    }
    
    # Download full 7-Zip for NSIS support
    $sevenZipZip = Join-Path $DepsDir "7zip.zip"
    $sevenZipUrl = "https://www.7-zip.org/a/7z2500-x64.zip"
    
    Invoke-Download $sevenZipUrl $sevenZipZip
    Expand-Archive -Path $sevenZipZip -DestinationPath $sevenZipDir -Force
    Remove-Item $sevenZipZip -Force -ErrorAction SilentlyContinue
    
    if (Test-Path $sevenZipExe) {
        Write-Host "7-Zip ready at: $sevenZipExe"
        return $sevenZipExe
    } else {
        throw "Failed to setup 7-Zip"
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

function Get-FMOD {
    $fmodDir = Join-Path $DepsDir "fmod"
    $fmodIncludeDir = Join-Path $fmodDir "include"
    $fmodLibDir = Join-Path $fmodDir "lib"
    
    if (Test-Path $fmodIncludeDir) {
        Write-Host "FMOD already exists at: $fmodDir"
        return $fmodDir
    }
    
    Write-Status "Setting up FMOD..."
    $fmodInstaller = Join-Path $DepsDir "fmodapi44464win-installer.exe"
    
    # Always try to download FMOD - no compromises!
    if (-not (Test-Path $fmodInstaller)) {
        Write-Host "Downloading FMOD Ex 4.44.64 installer..."
        Invoke-Download $Dependencies.FMOD.Url $fmodInstaller
        Write-Host "FMOD download successful!"
    } else {
        Write-Host "Using existing FMOD installer: $fmodInstaller"
    }
    
    # Create extraction directory
    if (-not (Test-Path $fmodDir)) {
        New-Item -ItemType Directory -Path $fmodDir -Force | Out-Null
    }
    
    # Extract FMOD installer using 7-Zip
    Write-Host "Extracting FMOD using 7-Zip..."
    $tempExtractDir = Join-Path $DepsDir "fmod_temp"
    
    try {
        # Clean up any previous extraction attempts
        if (Test-Path $tempExtractDir) {
            Remove-Item $tempExtractDir -Recurse -Force
        }
        
        # Extract the installer
        Write-Host "Running 7-Zip extraction..."
        Expand-Archive7Zip $fmodInstaller $tempExtractDir
        
        Write-Host "Extraction completed. Looking for FMOD API files..."
        
        # List contents to see what we got
        if (Test-Path $tempExtractDir) {
            Write-Host "Extracted contents:"
            Get-ChildItem $tempExtractDir -Recurse | ForEach-Object {
                Write-Host "  $($_.FullName.Replace($tempExtractDir, ''))"
            }
        }
        
        # Find the FMOD API files in the extracted content
        # FMOD installers typically have a structure like api/inc and api/lib
        $apiDir = Get-ChildItem $tempExtractDir -Recurse -Directory -Name "api" | Select-Object -First 1
        if ($apiDir) {
            $fullApiPath = Join-Path $tempExtractDir $apiDir
            Write-Host "Found API directory at: $fullApiPath"
            
            # Copy include files
            $incDir = Join-Path $fullApiPath "inc"
            if (Test-Path $incDir) {
                Copy-Item $incDir $fmodIncludeDir -Recurse -Force
                Write-Host "Copied FMOD headers from: $incDir"
            }
            
            # Copy library files  
            $libDir = Join-Path $fullApiPath "lib"
            if (Test-Path $libDir) {
                Copy-Item $libDir $fmodLibDir -Recurse -Force
                Write-Host "Copied FMOD libraries from: $libDir"
            }
        } else {
            # Fallback: look for any include/lib directories
            Write-Host "API directory not found, searching for inc/lib directories..."
            $includeSearch = Get-ChildItem $tempExtractDir -Recurse -Directory | Where-Object { $_.Name -like "*inc*" } | Select-Object -First 1
            $libSearch = Get-ChildItem $tempExtractDir -Recurse -Directory | Where-Object { $_.Name -like "*lib*" } | Select-Object -First 1
            
            if ($includeSearch) {
                Copy-Item $includeSearch.FullName $fmodIncludeDir -Recurse -Force
                Write-Host "Copied FMOD headers from: $($includeSearch.FullName)"
            }
            if ($libSearch) {
                Copy-Item $libSearch.FullName $fmodLibDir -Recurse -Force
                Write-Host "Copied FMOD libraries from: $($libSearch.FullName)"
            }
            
            if (-not $includeSearch -and -not $libSearch) {
                Write-Warning "Could not find FMOD include or library directories in extracted content"
                Write-Host "Available directories:"
                Get-ChildItem $tempExtractDir -Recurse -Directory | ForEach-Object {
                    Write-Host "  $($_.FullName)"
                }
            }
        }
        
        # Clean up temporary files
        Remove-Item $tempExtractDir -Recurse -Force -ErrorAction SilentlyContinue
        
        if (Test-Path $fmodIncludeDir) {
            Write-Host "FMOD ready at: $fmodDir"
            return $fmodDir
        } else {
            throw "Failed to extract FMOD include files"
        }
        
    } catch {
        # Clean up on failure
        Remove-Item $tempExtractDir -Recurse -Force -ErrorAction SilentlyContinue
        throw "Failed to setup FMOD: $_"
    }
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
    $script:SevenZipExe = Get-SevenZip
    $script:CMakeExe = Get-CMake
    $script:NASMExe = Get-NASM
    $script:PythonExe = Get-Python
    $script:WindowsSDK = Get-WindowsSDK
    $script:FMODDir = Get-FMOD
    
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
    if ((Test-Path variable:script:FMODDir) -and $script:FMODDir -and (Test-Path $script:FMODDir)) {
        $fmodInclude = Join-Path $script:FMODDir "include"
        $fmodLib = Join-Path $script:FMODDir "lib"
        if ((Test-Path $fmodInclude) -and (Test-Path $fmodLib)) {
            $cmakeArgs += "-DFMOD_INCLUDE_DIR=$fmodInclude"
            $cmakeArgs += "-DFMOD_LIBRARY=$fmodLib"
            Write-Host "Added FMOD paths: $fmodInclude, $fmodLib"
        }
    }
    
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
