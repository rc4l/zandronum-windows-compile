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
        Version = "3.5.1"
        Url = "https://download.firedaemon.com/FireDaemon-OpenSSL/openssl-3.5.1.zip"
        ExtractPath = "openssl-3.5.1"
    }
    Python = @{
        Version = "3.12.1"
        Url = "https://www.python.org/ftp/python/3.12.1/python-3.12.1-embed-amd64.zip"
        ExtractPath = "python"
    }
    Opus = @{
        Version = "1.3.1"
        Url = "https://ftp.osuosl.org/pub/xiph/releases/opus/opus-1.3.1-win32.zip"
        ExtractPath = "opus-1.3.1"
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
    
    # Try using built-in Expand-Archive first for simple ZIP files
    if ($ArchivePath -like "*.zip") {
        try {
            Expand-Archive -Path $ArchivePath -DestinationPath $DestinationPath -Force
            return
        } catch {
            Write-Warning "Built-in Expand-Archive failed, trying 7-Zip"
        }
    }
    
    # Use our portable 7-Zip
    if ($script:SevenZipExe -and (Test-Path $script:SevenZipExe)) {
        & $script:SevenZipExe x $ArchivePath "-o$DestinationPath" -y
        if ($LASTEXITCODE -eq 0) { return }
    }
    
    # Fallback to system 7-Zip if available
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

function Get-SevenZip {
    # Use committed 7z.exe instead of downloading
    $sevenZipExe = Join-Path $ScriptRoot "tools\7z\7z.exe"
    
    if (Test-Path $sevenZipExe) {
        Write-Host "Using committed 7z.exe at: $sevenZipExe"
        # Test that it works
        try {
            & $sevenZipExe | Select-Object -First 2 | Out-Null
            Write-Host "7z.exe is working and ready for NSIS extraction!"
            $script:SevenZipExe = $sevenZipExe
            return $sevenZipExe
        } catch {
            Write-Warning "7z.exe test failed: $_"
            throw "Committed 7z.exe is not working"
        }
    } else {
        throw "7z.exe not found at $sevenZipExe - please ensure 7z.exe is committed to the tools/7z/ directory"
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

function Get-OpenSSL {
    $opensslDir = Join-Path $DepsDir "openssl"
    $opensslIncludeDir = Join-Path $opensslDir "include"
    $opensslLibDir = Join-Path $opensslDir "lib"
    
    if (Test-Path $opensslIncludeDir) {
        Write-Host "OpenSSL already exists at: $opensslDir"
        return $opensslDir
    }
    
    Write-Status "Setting up OpenSSL..."
    $opensslZip = Join-Path $DepsDir "openssl-3.5.1.zip"
    
    # Download OpenSSL
    if (-not (Test-Path $opensslZip)) {
        Write-Host "Downloading OpenSSL 3.5.1..."
        Invoke-Download $Dependencies.OpenSSL.Url $opensslZip
        Write-Host "OpenSSL download successful!"
    } else {
        Write-Host "Using existing OpenSSL archive: $opensslZip"
    }
    
    # Extract OpenSSL using 7-Zip
    Write-Host "Extracting OpenSSL using 7-Zip..."
    $tempExtractDir = Join-Path $DepsDir "openssl_temp"
    
    try {
        # Clean up any previous extraction attempts
        if (Test-Path $tempExtractDir) {
            Remove-Item $tempExtractDir -Recurse -Force
        }
        
        # Extract the archive
        Write-Host "Running 7-Zip extraction..."
        Expand-Archive7Zip $opensslZip $tempExtractDir
        
        Write-Host "Extraction completed. Looking for OpenSSL x64 files..."
        
        # Create final OpenSSL directory
        if (-not (Test-Path $opensslDir)) {
            New-Item -ItemType Directory -Path $opensslDir -Force | Out-Null
        }
        
        # Look for the x64 directory in the extracted content (FireDaemon structure)
        $x64Dir = Get-ChildItem $tempExtractDir -Recurse -Directory | Where-Object { $_.Name -eq "x64" } | Select-Object -First 1
        
        if ($x64Dir) {
            $x64Path = $x64Dir.FullName
            Write-Host "Found x64 directory at: $x64Path"
            
            # Copy include files from x64 directory
            $srcIncludeDir = Join-Path $x64Path "include"
            if (Test-Path $srcIncludeDir) {
                Copy-Item $srcIncludeDir $opensslDir -Recurse -Force
                Write-Host "Copied OpenSSL headers from: $srcIncludeDir"
            }
            
            # Copy library files from x64 directory
            $srcLibDir = Join-Path $x64Path "lib"
            if (Test-Path $srcLibDir) {
                Copy-Item $srcLibDir $opensslDir -Recurse -Force
                Write-Host "Copied OpenSSL libraries from: $srcLibDir"
            }
            
            # Copy binary files from x64 directory
            $srcBinDir = Join-Path $x64Path "bin"
            if (Test-Path $srcBinDir) {
                Copy-Item $srcBinDir $opensslDir -Recurse -Force
                Write-Host "Copied OpenSSL binaries from: $srcBinDir"
            }
        } else {
            # Fallback: look for include/lib directories anywhere in the structure
            Write-Host "x64 directory not found, searching for include/lib directories..."
            
            $includeFound = $false
            $libFound = $false
            
            Get-ChildItem $tempExtractDir -Recurse -Directory | ForEach-Object {
                if ($_.Name -eq "include" -and (Test-Path (Join-Path $_.FullName "openssl"))) {
                    $srcIncludeDir = $_.FullName
                    Copy-Item $srcIncludeDir $opensslDir -Recurse -Force
                    Write-Host "Copied OpenSSL headers from: $srcIncludeDir"
                    $includeFound = $true
                }
                if ($_.Name -eq "lib" -and ($_.GetFiles("*.lib").Count -gt 0)) {
                    $srcLibDir = $_.FullName
                    Copy-Item $srcLibDir $opensslDir -Recurse -Force
                    Write-Host "Copied OpenSSL libraries from: $srcLibDir"
                    $libFound = $true
                }
            }
            
            if (-not ($includeFound -and $libFound)) {
                throw "Could not find OpenSSL include or lib directories in extracted content"
            }
        }
        
        # Clean up temporary files
        Remove-Item $tempExtractDir -Recurse -Force -ErrorAction SilentlyContinue
        
        if (Test-Path $opensslIncludeDir) {
            Write-Host "OpenSSL ready at: $opensslDir"
            return $opensslDir
        } else {
            throw "Failed to extract OpenSSL include files"
        }
        
    } catch {
        # Clean up on failure
        Remove-Item $tempExtractDir -Recurse -Force -ErrorAction SilentlyContinue
        throw "Failed to setup OpenSSL: $_"
    }
}

function Get-Opus {
    $opusDir = Join-Path $DepsDir "opus"
    $opusIncludeDir = Join-Path $opusDir "include"
    $opusLibDir = Join-Path $opusDir "lib"
    $opusLibFile = Join-Path $opusLibDir "opus.lib"
    
    if (Test-Path $opusLibFile) {
        Write-Host "Opus already exists at: $opusDir"
        return $opusDir
    }
    
    Write-Status "Setting up Opus..."
    $opusZip = Join-Path $DepsDir "opus.zip"
    
    # Download Opus source
    if (-not (Test-Path $opusZip)) {
        Write-Host "Downloading Opus 1.4 source..."
        Invoke-Download $Dependencies.Opus.Url $opusZip
        Write-Host "Opus download successful!"
    } else {
        Write-Host "Using existing Opus archive: $opusZip"
    }
    
    # Extract Opus using 7-Zip
    Write-Host "Extracting Opus using 7-Zip..."
    $tempExtractDir = Join-Path $DepsDir "opus_temp"
    
    try {
        # Clean up any previous extraction
        if (Test-Path $tempExtractDir) {
            Remove-Item $tempExtractDir -Recurse -Force
        }
        
        # Extract the archive
        Expand-Archive7Zip $opusZip $tempExtractDir
        
        # Find the extracted Opus directory
        $extractedOpusDir = Get-ChildItem $tempExtractDir -Directory | Where-Object { $_.Name -like "opus*" } | Select-Object -First 1
        if (-not $extractedOpusDir) {
            throw "Could not find extracted Opus directory"
        }
        
        $opusSourceDir = $extractedOpusDir.FullName
        Write-Host "Found Opus source at: $opusSourceDir"
        
        # Check for Visual Studio solution
        $opusSolution = Join-Path $opusSourceDir "win32\VS2015\opus.sln"
        if (-not (Test-Path $opusSolution)) {
            throw "Could not find Opus Visual Studio solution at: $opusSolution"
        }
        
        Write-Host "Building Opus with MSBuild..."
        
        # Find MSBuild
        $msBuildPath = Get-MSBuildPath
        if (-not $msBuildPath) {
            throw "MSBuild not found. Please ensure Visual Studio is installed."
        }
        
        # Build Opus (Release configuration, x64 platform)
        $buildArgs = @(
            $opusSolution
            "/p:Configuration=Release"
            "/p:Platform=x64"
            "/p:PlatformToolset=v143"
            "/m"
        )
        
        Write-Host "Running: $msBuildPath $($buildArgs -join ' ')"
        & $msBuildPath @buildArgs
        
        if ($LASTEXITCODE -ne 0) {
            throw "Opus build failed with exit code $LASTEXITCODE"
        }
        
        Write-Host "Opus build successful!"
        
        # Copy built library and includes to our deps structure
        $builtLibPath = Join-Path $opusSourceDir "win32\VS2015\x64\Release\opus.lib"
        $opusIncludeSourceDir = Join-Path $opusSourceDir "include"
        
        if (-not (Test-Path $builtLibPath)) {
            throw "Built Opus library not found at: $builtLibPath"
        }
        
        if (-not (Test-Path $opusIncludeSourceDir)) {
            throw "Opus include directory not found at: $opusIncludeSourceDir"
        }
        
        # Create our Opus directory structure
        if (-not (Test-Path $opusDir)) {
            New-Item -ItemType Directory -Path $opusDir -Force | Out-Null
        }
        if (-not (Test-Path $opusIncludeDir)) {
            New-Item -ItemType Directory -Path $opusIncludeDir -Force | Out-Null
        }
        if (-not (Test-Path $opusLibDir)) {
            New-Item -ItemType Directory -Path $opusLibDir -Force | Out-Null
        }
        
        # Copy the built library
        Copy-Item $builtLibPath $opusLibFile -Force
        Write-Host "Copied Opus library to: $opusLibFile"
        
        # Copy include files
        Copy-Item "$opusIncludeSourceDir\*" $opusIncludeDir -Recurse -Force
        Write-Host "Copied Opus headers to: $opusIncludeDir"
        
        # Clean up temporary files
        Remove-Item $tempExtractDir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $opusZip -Force -ErrorAction SilentlyContinue
        
        if (Test-Path $opusLibFile) {
            Write-Host "Opus ready at: $opusDir"
            return $opusDir
        } else {
            throw "Failed to setup Opus library"
        }
        
    } catch {
        # Clean up on failure
        Remove-Item $tempExtractDir -Recurse -Force -ErrorAction SilentlyContinue
        throw "Failed to setup Opus: $_"
    }
}

function Get-MSBuildPath {
    # Try to find MSBuild in common locations
    $msBuildPaths = @(
        "${env:ProgramFiles}\Microsoft Visual Studio\2022\Enterprise\MSBuild\Current\Bin\MSBuild.exe",
        "${env:ProgramFiles}\Microsoft Visual Studio\2022\Professional\MSBuild\Current\Bin\MSBuild.exe",
        "${env:ProgramFiles}\Microsoft Visual Studio\2022\Community\MSBuild\Current\Bin\MSBuild.exe",
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2022\Enterprise\MSBuild\Current\Bin\MSBuild.exe",
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2022\Professional\MSBuild\Current\Bin\MSBuild.exe",
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2022\Community\MSBuild\Current\Bin\MSBuild.exe",
        "${env:ProgramFiles}\Microsoft Visual Studio\2019\Enterprise\MSBuild\Current\Bin\MSBuild.exe",
        "${env:ProgramFiles}\Microsoft Visual Studio\2019\Professional\MSBuild\Current\Bin\MSBuild.exe",
        "${env:ProgramFiles}\Microsoft Visual Studio\2019\Community\MSBuild\Current\Bin\MSBuild.exe",
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2019\Enterprise\MSBuild\Current\Bin\MSBuild.exe",
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2019\Professional\MSBuild\Current\Bin\MSBuild.exe",
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2019\Community\MSBuild\Current\Bin\MSBuild.exe"
    )
    
    foreach ($path in $msBuildPaths) {
        if (Test-Path $path) {
            Write-Host "Found MSBuild at: $path"
            return $path
        }
    }
    
    # Try using vswhere to find MSBuild
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $vswhere) {
        try {
            $vsInstallPath = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild -property installationPath | Select-Object -First 1
            if ($vsInstallPath) {
                $msBuildPath = Join-Path $vsInstallPath "MSBuild\Current\Bin\MSBuild.exe"
                if (Test-Path $msBuildPath) {
                    Write-Host "Found MSBuild via vswhere at: $msBuildPath"
                    return $msBuildPath
                }
            }
        } catch {
            Write-Warning "vswhere failed: $_"
        }
    }
    
    return $null
}

function Initialize-Dependencies {
    # Always download source code regardless of SkipDeps
    Get-ZandronumSource
    
    if ($SkipDeps) {
        Write-Status "Skipping dependency setup (SkipDeps specified)"
        Write-Status "Source code download completed!"
    } else {
        Write-Status "Setting up dependencies..."
        
        # Setup core dependencies
        Get-SevenZip
        $script:CMakeExe = Get-CMake
        $script:NASMExe = Get-NASM
        $script:PythonExe = Get-Python
        Get-WindowsSDK
        
        # Setup optional dependencies
        $script:FMODDir = Get-FMOD
        $script:OpenSSLDir = Get-OpenSSL
        
        # Try to setup Opus, but don't fail the build if it doesn't work
        try {
            $script:OpusDir = Get-Opus
        } catch {
            Write-Warning "Failed to setup Opus: $_"
            Write-Warning "Continuing without Opus support"
            $script:OpusDir = $null
        }
        
        Write-Status "Dependencies setup completed!"
    }
}

function Invoke-CMakeGenerate {
    Write-Status "Generating build files with CMake..."
    
    $cmakeArgs = @()
    
    # Set generator and toolset
    $cmakeArgs += "-G", "Visual Studio 17 2022"
    $cmakeArgs += "-A", $Platform
    $cmakeArgs += "-T", "v143"
    
    # Set build directory
    $cmakeArgs += "-B", $BuildDir
    
    # Set source directory
    $sourceDir = Join-Path $SrcDir "zandronum"
    $cmakeArgs += "-S", $sourceDir
    
    # Add dependency paths if they exist
    $fmodDir = Join-Path $DepsDir "fmod"
    if (Test-Path $fmodDir) {
        $fmodInclude = Join-Path $fmodDir "include"
        $fmodLib = Join-Path $fmodDir "lib"
        if ((Test-Path $fmodInclude) -and (Test-Path $fmodLib)) {
            $cmakeArgs += "-DFMOD_INCLUDE_DIR=$fmodInclude"
            $cmakeArgs += "-DFMOD_LIBRARY_DIR=$fmodLib"
            Write-Host "Added FMOD paths to CMake"
        }
    }
    
    $opensslDir = Join-Path $DepsDir "openssl"
    if (Test-Path $opensslDir) {
        $opensslInclude = Join-Path $opensslDir "include"
        $opensslLib = Join-Path $opensslDir "lib"
        if ((Test-Path $opensslInclude) -and (Test-Path $opensslLib)) {
            $cmakeArgs += "-DOPENSSL_ROOT_DIR=$opensslDir"
            $cmakeArgs += "-DOPENSSL_INCLUDE_DIR=$opensslInclude"
            $cmakeArgs += "-DOPENSSL_LIBRARIES_DIR=$opensslLib"
            Write-Host "Added OpenSSL paths to CMake"
        }
    }
    
    $opusDir = Join-Path $DepsDir "opus"
    if (Test-Path $opusDir) {
        $opusInclude = Join-Path $opusDir "include"
        $opusLib = Join-Path $opusDir "lib"
        if ((Test-Path $opusInclude) -and (Test-Path $opusLib)) {
            $cmakeArgs += "-DOPUS_INCLUDE_DIR=$opusInclude"
            $cmakeArgs += "-DOPUS_LIBRARY_DIR=$opusLib"
            Write-Host "Added Opus paths to CMake"
        }
    }
    
    # Add Windows SDK path if available
    $windowsSDKDir = Join-Path $DepsDir "WindowsSDK"
    if (Test-Path $windowsSDKDir) {
        $cmakeArgs += "-DWINDOWS_SDK_DIR=$windowsSDKDir"
        Write-Host "Added Windows SDK path to CMake"
    }
    
    # Set configuration-specific options
    $cmakeArgs += "-DCMAKE_BUILD_TYPE=$Configuration"
    
    # Ensure CMake is available
    if (-not $script:CMakeExe) {
        $cmakeDir = Join-Path $DepsDir "cmake"
        $script:CMakeExe = Join-Path $cmakeDir "bin\cmake.exe"
        if (-not (Test-Path $script:CMakeExe)) {
            throw "CMake not found. Please run without -SkipDeps first to download dependencies."
        }
    }
    
    Write-Host "Running CMake with arguments:"
    Write-Host "  $($cmakeArgs -join ' ')"
    
    # Run CMake
    & $script:CMakeExe @cmakeArgs
    if ($LASTEXITCODE -ne 0) {
        throw "CMake generation failed with exit code $LASTEXITCODE"
    }
    
    Write-Status "CMake generation completed successfully!"
}

function Invoke-Build {
    Write-Status "Building Zandronum..."
    
    # Use CMake to build
    $buildArgs = @(
        "--build", $BuildDir,
        "--config", $Configuration,
        "--parallel"
    )
    
    Write-Host "Running CMake build with arguments:"
    Write-Host "  $($buildArgs -join ' ')"
    
    & $script:CMakeExe @buildArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Build failed with exit code $LASTEXITCODE"
    }
    
    Write-Status "Build completed successfully!"
}

function Show-Results {
    Write-Status "Build Results:"
    
    $outputDir = Join-Path $BuildDir $Configuration
    if (Test-Path $outputDir) {
        Write-Host "Output directory: $outputDir"
        
        $zandronumExe = Join-Path $outputDir "zandronum.exe"
        if (Test-Path $zandronumExe) {
            $fileInfo = Get-Item $zandronumExe
            Write-Host "  zandronum.exe: $($fileInfo.Length) bytes, modified $($fileInfo.LastWriteTime)"
        } else {
            Write-Warning "zandronum.exe not found in output directory"
        }
        
        $zandronumPk3 = Join-Path $outputDir "zandronum.pk3"
        if (Test-Path $zandronumPk3) {
            $fileInfo = Get-Item $zandronumPk3
            Write-Host "  zandronum.pk3: $($fileInfo.Length) bytes, modified $($fileInfo.LastWriteTime)"
        } else {
            Write-Warning "zandronum.pk3 not found in output directory"
        }
        
        # List other files in output directory
        $otherFiles = Get-ChildItem $outputDir -File | Where-Object { $_.Name -notin @("zandronum.exe", "zandronum.pk3") }
        if ($otherFiles) {
            Write-Host "  Other files:"
            foreach ($file in $otherFiles) {
                Write-Host "    $($file.Name): $($file.Length) bytes"
            }
        }
    } else {
        Write-Warning "Output directory not found: $outputDir"
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
