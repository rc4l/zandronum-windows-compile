#Requires -Version 5.1
<#
.SYNOPSIS
    Self-contained Zandronum Windows build system
    
.DESCRIPTION
    A fully automated, touchless build system for Zandronum on Windows.
    Downloads all dependencies locally, builds everything from source,
    and automatically installs Visual Studio Build Tools if not found.
    Includes runtime dependencies like FMOD DLLs and Freedoom WADs.
    No manual setup or terminal restarts required.
    
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

# Script-level variables for tool paths
$script:CMakeExe = $null
$script:NASMExe = $null
$script:PythonExe = $null
$script:FMODDir = $null
$script:OpenSSLDir = $null

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
        Url = "https://www.openssl.org/source/openssl-3.5.1.tar.gz"
        ExtractPath = "openssl-3.5.1"
    }
    StrawberryPerl = @{
        Version = "5.38.2.2"
        Url = "https://github.com/StrawberryPerl/Perl-Dist-Strawberry/releases/download/SP_53822_64bit/strawberry-perl-5.38.2.2-64bit-portable.zip"
        ExtractPath = "strawberry-perl"
    }
    Python = @{
        Version = "3.12.1"
        Url = "https://www.python.org/ftp/python/3.12.1/python-3.12.1-embed-amd64.zip"
        ExtractPath = "python"
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
        & $script:SevenZipExe x $ArchivePath "-o$DestinationPath" -y | Out-Host
        if ($LASTEXITCODE -eq 0) { return }
    }
    
    # Fallback to system 7-Zip if available
    $sevenZip = Get-Command "7z.exe" -ErrorAction SilentlyContinue
    if ($sevenZip) {
        & $sevenZip.Source x $ArchivePath "-o$DestinationPath" -y | Out-Host
        if ($LASTEXITCODE -eq 0) { return }
    }
    
    throw "Failed to extract $ArchivePath"
}

function Refresh-Environment {
    Write-Status "Refreshing environment variables..."
    
    # Refresh environment variables from registry
    $envVars = @('PATH', 'PATHEXT', 'TEMP', 'TMP')
    foreach ($var in $envVars) {
        $machineValue = [System.Environment]::GetEnvironmentVariable($var, 'Machine')
        $userValue = [System.Environment]::GetEnvironmentVariable($var, 'User')
        
        if ($var -eq 'PATH') {
            # Combine machine and user PATH
            $combinedPath = (@($machineValue, $userValue) | Where-Object { $_ }) -join ';'
            [System.Environment]::SetEnvironmentVariable($var, $combinedPath, 'Process')
            $env:PATH = $combinedPath
        } elseif ($machineValue) {
            [System.Environment]::SetEnvironmentVariable($var, $machineValue, 'Process')
        } elseif ($userValue) {
            [System.Environment]::SetEnvironmentVariable($var, $userValue, 'Process')
        }
    }
    
    Write-Host "Environment variables refreshed."
}

function Install-VisualStudioBuildTools {
    Write-Status "Installing Visual Studio Build Tools via Winget..."
    
    # Check if winget is available
    if (-not (Test-CommandExists "winget")) {
        Write-Warning "Winget is not available. Please install winget or manually install Visual Studio Build Tools."
        return $false
    }
    
    Write-Host "Installing Microsoft Visual Studio Build Tools 2022..."
    
    # Install Visual Studio Build Tools with C++ workload
    $wingetArgs = @(
        "install"
        "Microsoft.VisualStudio.2022.BuildTools"
        "--silent"
        "--override"
        "--add Microsoft.VisualStudio.Workload.VCTools --add Microsoft.VisualStudio.Component.VC.Tools.x86.x64 --add Microsoft.VisualStudio.Component.Windows10SDK.20348"
        "--accept-package-agreements"
        "--accept-source-agreements"
    )
    
    Write-Host "Running: winget $($wingetArgs -join ' ')"
    & winget @wingetArgs
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Visual Studio Build Tools installation completed successfully!"
        
        # Refresh environment to pick up new installations
        Refresh-Environment
        
        # Give the installer a moment to complete file operations
        Write-Host "Waiting for installation to finalize..."
        Start-Sleep -Seconds 10
        
        return $true
    } else {
        Write-Warning "Visual Studio Build Tools installation failed with exit code $LASTEXITCODE"
        return $false
    }
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
    
    Write-Warning "Visual Studio Build Tools not found."
    Write-Status "Automatically installing Visual Studio Build Tools 2022..."
    
    $installSuccess = Install-VisualStudioBuildTools
    if ($installSuccess) {
        Write-Host "Installation completed. Checking for Visual Studio again..."
        
        # Retry finding Visual Studio after installation
        if (Test-Path $vswhere) {
            $vsInstallations = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
            if ($vsInstallations) {
                $vsPath = $vsInstallations[0]
                Write-Host "Successfully found Visual Studio at: $vsPath"
                return $vsPath
            }
        }
        
        Write-Warning "Visual Studio Build Tools were installed but cannot be detected yet."
        Write-Host "This may require a terminal restart to take full effect."
        Write-Host "Continuing with build attempt..."
        return $null
    } else {
        Write-Warning "Automatic installation failed. Please manually install Visual Studio 2022 Build Tools."
        Write-Host "You can install it manually with:"
        Write-Host "  winget install Microsoft.VisualStudio.2022.BuildTools --silent --override ""--add Microsoft.VisualStudio.Workload.VCTools --add Microsoft.VisualStudio.Component.VC.Tools.x86.x64 --add Microsoft.VisualStudio.Component.Windows10SDK.20348"""
        Write-Warning "You can continue, but the build may fail."
        return $null
    }
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

function Get-StrawberryPerl {
    $perlDir = Join-Path $DepsDir "strawberry-perl"
    $perlExe = Join-Path $perlDir "perl\bin\perl.exe"
    
    if (Test-Path $perlExe) {
        Write-Host "Strawberry Perl already exists at: $perlDir"
        return $perlDir
    }
    
    Write-Status "Setting up Strawberry Perl Portable..."
    $perlZip = Join-Path $DepsDir "strawberry-perl.zip"
    
    Invoke-Download $Dependencies.StrawberryPerl.Url $perlZip
    
    Write-Host "Extracting Strawberry Perl (this may take a while due to many small files)..."
    Expand-Archive7Zip $perlZip $perlDir
    
    Remove-Item $perlZip -Force -ErrorAction SilentlyContinue
    
    if (Test-Path $perlExe) {
        Write-Host "Strawberry Perl ready at: $perlDir"
        return $perlDir
    } else {
        throw "Failed to setup Strawberry Perl"
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
            
            # Copy DLL files to fmod/bin directory
            $fmodBinDir = Join-Path $fmodDir "bin"
            if (-not (Test-Path $fmodBinDir)) {
                New-Item -ItemType Directory -Path $fmodBinDir -Force | Out-Null
            }
            
            # Look for DLL files in the extracted content
            $dllFiles = Get-ChildItem $tempExtractDir -Recurse -Filter "*.dll"
            foreach ($dll in $dllFiles) {
                Copy-Item $dll.FullName $fmodBinDir -Force
                Write-Host "Copied FMOD DLL: $($dll.Name) to bin directory"
            }
            
        } else {
            # Fallback: look for any include/lib directories and DLL files
            Write-Host "API directory not found, searching for inc/lib directories and DLL files..."
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
            
            # Copy all DLL files found anywhere in the extraction
            $fmodBinDir = Join-Path $fmodDir "bin"
            if (-not (Test-Path $fmodBinDir)) {
                New-Item -ItemType Directory -Path $fmodBinDir -Force | Out-Null
            }
            
            $dllFiles = Get-ChildItem $tempExtractDir -Recurse -Filter "*.dll"
            foreach ($dll in $dllFiles) {
                Copy-Item $dll.FullName $fmodBinDir -Force
                Write-Host "Copied FMOD DLL: $($dll.Name) to bin directory"
            }
            
            if (-not $includeSearch -and -not $libSearch -and $dllFiles.Count -eq 0) {
                Write-Warning "Could not find FMOD include, library, or DLL files in extracted content"
                Write-Host "Available directories:"
                Get-ChildItem $tempExtractDir -Recurse -Directory | ForEach-Object {
                    Write-Host "  $($_.FullName)"
                }
                Write-Host "Available files:"
                Get-ChildItem $tempExtractDir -Recurse -File | ForEach-Object {
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
    
    # Check for static libraries specifically
    $libCryptoStatic = Join-Path $opensslLibDir "libcrypto.lib"
    $libSslStatic = Join-Path $opensslLibDir "libssl.lib"
    
    if ((Test-Path $libCryptoStatic) -and (Test-Path $libSslStatic)) {
        # Verify these are large static libraries, not small import libs
        $cryptoSize = (Get-Item $libCryptoStatic).Length
        $sslSize = (Get-Item $libSslStatic).Length
        
        if ($cryptoSize -gt 1MB -and $sslSize -gt 1MB) {
            Write-Host "Static OpenSSL libraries already exist at: $opensslDir"
            Write-Host "  libcrypto.lib: $([math]::Round($cryptoSize / 1MB, 2)) MB"
            Write-Host "  libssl.lib: $([math]::Round($sslSize / 1MB, 2)) MB"
            return $opensslDir
        } else {
            Write-Warning "Found small .lib files (import libs), rebuilding as static..."
            Remove-Item $opensslDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    
    # Check for pre-built OpenSSL libraries in tools/openssl/openssl-3.5.1-static-libs.zip
    $toolsOpenSSLZip = Join-Path $ScriptRoot "tools\openssl\openssl-3.5.1-static-libs.zip"
    
    if (Test-Path $toolsOpenSSLZip) {
        Write-Status "Using pre-built static OpenSSL libraries from tools/openssl/"
        
        # Extract ZIP to deps/openssl/
        if (-not (Test-Path $opensslDir)) {
            New-Item -ItemType Directory -Path $opensslDir -Force | Out-Null
        }
        
        Write-Host "Extracting pre-built OpenSSL libraries..."
        try {
            Expand-Archive7Zip $toolsOpenSSLZip $opensslDir
            
            # Verify the extraction worked and libraries exist
            if ((Test-Path $libCryptoStatic) -and (Test-Path $libSslStatic)) {
                $cryptoSize = (Get-Item $libCryptoStatic).Length
                $sslSize = (Get-Item $libSslStatic).Length
                
                Write-Host "Pre-built static OpenSSL libraries extracted:"
                Write-Host "  libcrypto.lib: $([math]::Round($cryptoSize / 1MB, 2)) MB"
                Write-Host "  libssl.lib: $([math]::Round($sslSize / 1MB, 2)) MB"
                
                # Check for version file
                $versionFile = Join-Path $opensslDir "VERSION.txt"
                if (Test-Path $versionFile) {
                    $version = Get-Content $versionFile -Raw
                    Write-Host "Pre-built OpenSSL version: $($version.Trim())"
                }
                
                Write-Host "Pre-built static OpenSSL ready at: $opensslDir"
                return $opensslDir
            } else {
                Write-Warning "Pre-built OpenSSL libraries not found after extraction"
                Remove-Item $opensslDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        } catch {
            Write-Warning "Failed to extract pre-built OpenSSL: $_"
            Remove-Item $opensslDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    } else {
        Write-Host "No pre-built OpenSSL ZIP found at tools/openssl-static-libs.zip"
        Write-Host "Building static OpenSSL from source (this will take several minutes)..."
    }
    
    # Ensure we have Strawberry Perl
    $perlDir = Get-StrawberryPerl
    $perlExe = Join-Path $perlDir "perl\bin\perl.exe"
    
    if (-not (Test-Path $perlExe)) {
        throw "Perl not found at: $perlExe"
    }
    
    # Download OpenSSL source
    $opensslTarGz = Join-Path $DepsDir "openssl-3.5.1.tar.gz"
    if (-not (Test-Path $opensslTarGz)) {
        Write-Host "Downloading OpenSSL 3.5.1 source..."
        Invoke-Download $Dependencies.OpenSSL.Url $opensslTarGz
        Write-Host "OpenSSL source download successful!"
    } else {
        Write-Host "Using existing OpenSSL source: $opensslTarGz"
    }
    
    # Extract OpenSSL source using 7-Zip (two-step for .tar.gz)
    Write-Host "Extracting OpenSSL source..."
    $tempExtractDir = Join-Path $DepsDir "openssl_source_temp"
    
    try {
        # Clean up any previous extraction
        if (Test-Path $tempExtractDir) {
            Remove-Item $tempExtractDir -Recurse -Force
        }
        
        # First extract the .gz to get the .tar file
        & $script:SevenZipExe x $opensslTarGz "-o$tempExtractDir" -y
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to extract .gz file"
        }
        
        # Find the .tar file
        $tarFile = Join-Path $tempExtractDir "openssl-3.5.1.tar"
        if (-not (Test-Path $tarFile)) {
            throw "Could not find extracted .tar file at: $tarFile"
        }
        
        # Now extract the .tar file
        & $script:SevenZipExe x $tarFile "-o$tempExtractDir" -y
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to extract .tar file"
        }
        
        # Clean up the .tar file
        Remove-Item $tarFile -Force -ErrorAction SilentlyContinue
        
        # Find the extracted OpenSSL directory
        $opensslSourceDir = Join-Path $tempExtractDir "openssl-3.5.1"
        if (-not (Test-Path $opensslSourceDir)) {
            throw "Could not find extracted OpenSSL source directory at: $opensslSourceDir"
        }
        
        Write-Host "Found OpenSSL source at: $opensslSourceDir"
        
        # Set up environment for building
        $oldLocation = Get-Location
        $oldPath = $env:PATH
        $oldLcAll = $env:LC_ALL
        $oldLang = $env:LANG
        
        try {
            # Add Strawberry Perl and NASM to PATH
            $perlBinDir = Join-Path $perlDir "perl\bin"
            $nasmDir = Join-Path $DepsDir "nasm"
            $env:PATH = "$perlBinDir;$nasmDir;$env:PATH"
            
            # Suppress Perl locale warnings by using C locale
            $env:LC_ALL = "C"
            $env:LANG = "C"
            
            # Change to OpenSSL source directory
            Set-Location $opensslSourceDir
            
            # Find Visual Studio installation and vcvars64.bat
            $vcvarsPath = Get-VCVarsPath
            if (-not $vcvarsPath) {
                throw "vcvars64.bat not found. Please ensure Visual Studio 2022 is installed with C++ development tools."
            }
            
            Write-Host "Configuring OpenSSL for static linking..."
            
            # Configure OpenSSL with no-shared to build static libraries only
            $configureArgs = @(
                "Configure"
                "VC-WIN64A"
                "no-shared"
                "no-dynamic-engine"
                "--prefix=$opensslDir"
                "--openssldir=$opensslDir"
            )
            
            Write-Host "Running: $perlExe $($configureArgs -join ' ')"
            & $perlExe @configureArgs
            
            if ($LASTEXITCODE -ne 0) {
                throw "OpenSSL configure failed with exit code $LASTEXITCODE"
            }
            
            Write-Host "Building OpenSSL (this will take several minutes)..."
            
            # Create a batch file to run nmake with proper environment
            $buildBat = Join-Path $opensslSourceDir "build_openssl.bat"
            $buildScript = @"
@echo off
call "$vcvarsPath"
nmake
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%
nmake install_sw
"@
            Set-Content -Path $buildBat -Value $buildScript
            
            # Run the build
            & cmd.exe /c $buildBat
            
            if ($LASTEXITCODE -ne 0) {
                throw "OpenSSL build failed with exit code $LASTEXITCODE"
            }
            
            Write-Host "OpenSSL build completed successfully!"
            
            # Verify the static libraries were created
            if ((Test-Path $libCryptoStatic) -and (Test-Path $libSslStatic)) {
                $cryptoSize = (Get-Item $libCryptoStatic).Length
                $sslSize = (Get-Item $libSslStatic).Length
                
                Write-Host "Static OpenSSL libraries created:"
                Write-Host "  libcrypto.lib: $([math]::Round($cryptoSize / 1MB, 2)) MB"
                Write-Host "  libssl.lib: $([math]::Round($sslSize / 1MB, 2)) MB"
                
                if ($cryptoSize -lt 1MB -or $sslSize -lt 1MB) {
                    throw "Generated libraries are too small - they may not be static"
                }
            } else {
                throw "Static libraries not found after build"
            }
            
        } finally {
            # Restore environment
            Set-Location $oldLocation
            $env:PATH = $oldPath
            $env:LC_ALL = $oldLcAll
            $env:LANG = $oldLang
        }
        
        # Clean up temporary files
        Remove-Item $tempExtractDir -Recurse -Force -ErrorAction SilentlyContinue
        
        if (Test-Path $opensslIncludeDir) {
            Write-Host "Static OpenSSL ready at: $opensslDir"
            return $opensslDir
        } else {
            throw "Failed to build static OpenSSL libraries"
        }
        
    } catch {
        # Clean up on failure
        Remove-Item $tempExtractDir -Recurse -Force -ErrorAction SilentlyContinue
        Set-Location $oldLocation -ErrorAction SilentlyContinue
        $env:PATH = $oldPath
        $env:LC_ALL = $oldLcAll
        $env:LANG = $oldLang
        throw "Failed to build OpenSSL: $_"
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
    
    # Check for committed Opus file
    $opusToolsDir = Join-Path $ScriptRoot "tools\opus"
    $committedOpus = $null
    if (Test-Path $opusToolsDir) {
        # Look for any compressed file in tools/opus directory
        $compressedFiles = Get-ChildItem $opusToolsDir -File | Where-Object { $_.Extension -in @('.tar.gz', '.zip', '.7z', '.tar', '.gz') }
        if ($compressedFiles) {
            $committedOpus = $compressedFiles[0].FullName
            Write-Host "Found committed Opus archive: $($compressedFiles[0].Name)"
        }
    }
    
    if (-not $committedOpus) {
        throw "Opus archive not found in tools/opus/ directory. Please place an Opus source archive (opus-*.tar.gz) in tools/opus/ before running the build."
    }
    
    # Use committed file
    $opusArchive = Join-Path $DepsDir (Split-Path $committedOpus -Leaf)
    Copy-Item $committedOpus $opusArchive -Force
    Write-Host "Using committed Opus archive: $opusArchive"
    
    # Extract Opus using 7-Zip
    Write-Host "Extracting Opus using 7-Zip..."
    $tempExtractDir = Join-Path $DepsDir "opus_temp"
    
    try {
        # Clean up any previous extraction
        if (Test-Path $tempExtractDir) {
            Remove-Item $tempExtractDir -Recurse -Force
        }
        
        # Extract the archive (tar.gz format - requires two-step extraction)
        Write-Host "Extracting tar.gz file using 7-Zip..."
        
        # First extract the .gz to get the .tar file
        & $script:SevenZipExe x $opusArchive "-o$tempExtractDir" -y
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to extract .gz file"
        }
        
        # Find the .tar file
        $tarFile = Join-Path $tempExtractDir "opus-1.5.2.tar"
        if (-not (Test-Path $tarFile)) {
            throw "Could not find extracted .tar file at: $tarFile"
        }
        
        # Now extract the .tar file
        & $script:SevenZipExe x $tarFile "-o$tempExtractDir" -y
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to extract .tar file"
        }
        
        # Clean up the .tar file
        Remove-Item $tarFile -Force -ErrorAction SilentlyContinue
        
        # Find the extracted Opus directory
        $extractedOpusDir = Get-ChildItem $tempExtractDir -Directory | Where-Object { $_.Name -like "opus*" } | Select-Object -First 1
        if (-not $extractedOpusDir) {
            throw "Could not find extracted Opus directory"
        }
        
        $opusSourceDir = $extractedOpusDir.FullName
        Write-Host "Found Opus source at: $opusSourceDir"
        
        # Check for CMakeLists.txt (modern Opus uses CMake)
        $opusCMakeLists = Join-Path $opusSourceDir "CMakeLists.txt"
        if (-not (Test-Path $opusCMakeLists)) {
            throw "Could not find Opus CMakeLists.txt at: $opusCMakeLists"
        }
        
        Write-Host "Building Opus with CMake..."
        
        # Find MSBuild (we'll need it for building the generated solution)
        $msBuildPath = Get-MSBuildPath
        if (-not $msBuildPath) {
            throw "MSBuild not found. Please ensure Visual Studio is installed."
        }
        
        # Create build directory for Opus
        $opusBuildDir = Join-Path $opusSourceDir "build"
        if (Test-Path $opusBuildDir) {
            Remove-Item $opusBuildDir -Recurse -Force
        }
        New-Item -ItemType Directory -Path $opusBuildDir -Force | Out-Null
        
        # Generate Visual Studio solution with CMake
        $cmakeArgs = @(
            "-G", "Visual Studio 17 2022"
            "-A", "x64"
            "-T", "v143"
            "-B", $opusBuildDir
            "-S", $opusSourceDir
            "-DCMAKE_BUILD_TYPE=Release"
        )
        
        Write-Host "Running CMake for Opus: $($script:CMakeExe) $($cmakeArgs -join ' ')"
        & $script:CMakeExe @cmakeArgs
        
        if ($LASTEXITCODE -ne 0) {
            throw "Opus CMake generation failed with exit code $LASTEXITCODE"
        }
        
        # Build Opus using CMake
        $buildArgs = @(
            "--build", $opusBuildDir
            "--config", "Release"
            "--target", "opus"
        )
        
        Write-Host "Building Opus: $($script:CMakeExe) $($buildArgs -join ' ')"
        & $script:CMakeExe @buildArgs
        
        if ($LASTEXITCODE -ne 0) {
            throw "Opus build failed with exit code $LASTEXITCODE"
        }
        
        Write-Host "Opus build successful!"
        
        # Find the built library
        $builtLibPath = Join-Path $opusBuildDir "Release\opus.lib"
        if (-not (Test-Path $builtLibPath)) {
            # Try alternative path
            $builtLibPath = Join-Path $opusBuildDir "opus\Release\opus.lib"
            if (-not (Test-Path $builtLibPath)) {
                # List what's in the build directory to help debug
                Write-Host "Build directory contents:"
                Get-ChildItem $opusBuildDir -Recurse -Filter "*.lib" | ForEach-Object {
                    Write-Host "  $($_.FullName)"
                }
                throw "Built Opus library not found. Expected at: $builtLibPath"
            }
        }
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
        Remove-Item $opusArchive -Force -ErrorAction SilentlyContinue
        
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
    # Use vswhere.exe to find MSBuild - the portable, official way
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) {
        $vswhere = "${env:ProgramFiles}\Microsoft Visual Studio\Installer\vswhere.exe"
    }
    
    if (-not (Test-Path $vswhere)) {
        Write-Warning "vswhere.exe not found. Please ensure Visual Studio 2017 or later is installed."
        return $null
    }
    
    try {
        # Find the latest VS installation with MSBuild component
        $vsInstallPath = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild -property installationPath | Select-Object -First 1
        
        if ([string]::IsNullOrWhiteSpace($vsInstallPath)) {
            Write-Warning "No Visual Studio installation with MSBuild found."
            return $null
        }
        
        # Construct MSBuild path
        $msBuildPath = Join-Path $vsInstallPath "MSBuild\Current\Bin\MSBuild.exe"
        
        if (Test-Path $msBuildPath) {
            Write-Host "Found MSBuild via vswhere at: $msBuildPath"
            return $msBuildPath
        } else {
            Write-Warning "MSBuild.exe not found at expected location: $msBuildPath"
            return $null
        }
        
    } catch {
        Write-Warning "vswhere failed: $_"
        return $null
    }
}

function Get-VCVarsPath {
    # Use vswhere.exe to find Visual Studio installation and locate vcvars64.bat
    $vswhereExe = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    
    if (-not (Test-Path $vswhereExe)) {
        Write-Warning "vswhere.exe not found. Please ensure Visual Studio is installed."
        return $null
    }
    
    try {
        # Find the latest VS installation with C++ component
        $vsInstallPath = & $vswhereExe -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath | Select-Object -First 1
        
        if (-not $vsInstallPath) {
            Write-Warning "No Visual Studio installation with C++ tools found."
            return $null
        }
        
        # Construct vcvars64.bat path
        $vcvarsPath = Join-Path $vsInstallPath "VC\Auxiliary\Build\vcvars64.bat"
        
        if (Test-Path $vcvarsPath) {
            Write-Host "Found vcvars64.bat at: $vcvarsPath"
            return $vcvarsPath
        } else {
            Write-Warning "vcvars64.bat not found at expected location: $vcvarsPath"
            return $null
        }
        
    } catch {
        Write-Warning "vswhere failed while looking for vcvars64.bat: $_"
        return $null
    }
}

function Initialize-Dependencies {
    # Always download source code regardless of SkipDeps
    Get-ZandronumSource
    
    if ($SkipDeps) {
        Write-Status "Skipping dependency setup (SkipDeps specified)"
        Write-Status "Source code download completed!"
        
        # Initialize script variables to prevent null reference errors
        # Try to find existing dependencies if they exist
        $cmakeDir = Join-Path $DepsDir "cmake"
        $script:CMakeExe = if (Test-Path (Join-Path $cmakeDir "bin\cmake.exe")) { 
            Join-Path $cmakeDir "bin\cmake.exe" 
        } else { 
            $null 
        }
        
        $nasmDir = Join-Path $DepsDir "nasm"  
        $script:NASMExe = if (Test-Path (Join-Path $nasmDir "nasm.exe")) { 
            Join-Path $nasmDir "nasm.exe" 
        } else { 
            $null 
        }
        
        $pythonDir = Join-Path $DepsDir "python"
        $script:PythonExe = if (Test-Path (Join-Path $pythonDir "python.exe")) { 
            Join-Path $pythonDir "python.exe" 
        } else { 
            $null 
        }
        
        $fmodDir = Join-Path $DepsDir "fmod"
        $script:FMODDir = if (Test-Path $fmodDir) { 
            $fmodDir 
        } else { 
            $null 
        }
        
        $opensslDir = Join-Path $DepsDir "openssl"
        $script:OpenSSLDir = if (Test-Path $opensslDir) { 
            $opensslDir 
        } else { 
            $null 
        }
        
        $opusDir = Join-Path $DepsDir "opus"
        $script:OpusDir = if (Test-Path $opusDir) { 
            $opusDir 
        } else { 
            $null 
        }
        
        Write-Host "Using existing dependencies if available:"
        Write-Host "  CMake: $($script:CMakeExe)"
        Write-Host "  NASM: $($script:NASMExe)"
        Write-Host "  Python: $($script:PythonExe)"
        Write-Host "  FMOD: $($script:FMODDir)"
        Write-Host "  OpenSSL: $($script:OpenSSLDir)"
        Write-Host "  Opus: $($script:OpusDir)"
        
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
        $script:OpenSSLDir = Get-OpenSSL  # This will now build static libraries
        
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
        $fmodLib = Join-Path $fmodDir "lib\fmodex64_vc.lib"
        if ((Test-Path $fmodInclude) -and (Test-Path $fmodLib)) {
            $cmakeArgs += "-DFMOD_INCLUDE_DIR=$fmodInclude"
            $cmakeArgs += "-DFMOD_LIBRARY=$fmodLib"
            Write-Host "Added FMOD paths to CMake - Include: $fmodInclude, Library: $fmodLib"
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
            $cmakeArgs += "-DOPENSSL_USE_STATIC_LIBS=ON"
            Write-Host "Added OpenSSL paths to CMake (forcing static linking)"
        }
    }
    
    $opusDir = Join-Path $DepsDir "opus"
    if (Test-Path $opusDir) {
        $opusInclude = Join-Path $opusDir "include"
        $opusLib = Join-Path $opusDir "lib\opus.lib"
        if ((Test-Path $opusInclude) -and (Test-Path $opusLib)) {
            $cmakeArgs += "-DOPUS_INCLUDE_DIR=$opusInclude"
            $cmakeArgs += "-DOPUS_LIBRARIES=$opusLib"
            Write-Host "Added Opus paths to CMake - Include: $opusInclude, Library: $opusLib"
        }
    }
    
    # Add Windows SDK path if available
    $windowsSDKDir = Join-Path $DepsDir "WindowsSDK"
    if (Test-Path $windowsSDKDir) {
        $cmakeArgs += "-DWINDOWS_SDK_DIR=$windowsSDKDir"
        Write-Host "Added Windows SDK path to CMake"
    }
    
    # Set Python executable if portable Python is available
    # This ensures CMake finds the correct Python when no system Python is installed
    if ($script:PythonExe -and (Test-Path $script:PythonExe)) {
        $cmakeArgs += "-DPYTHON_EXECUTABLE=$($script:PythonExe)"
        Write-Host "Added Python executable to CMake: $($script:PythonExe)"
    }
    
    # Set configuration-specific options
    $cmakeArgs += "-DCMAKE_BUILD_TYPE=$Configuration"
    
    # Ensure CMake is available
    if (-not $script:CMakeExe -or -not (Test-Path $script:CMakeExe)) {
        $cmakeDir = Join-Path $DepsDir "cmake"
        $script:CMakeExe = Join-Path $cmakeDir "bin\cmake.exe"
        if (-not (Test-Path $script:CMakeExe)) {
            throw "CMake not found. Please run without -SkipDeps first to download dependencies."
        }
        Write-Host "Found CMake at: $script:CMakeExe"
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
    
    # Validate required variables
    if ([string]::IsNullOrWhiteSpace($BuildDir)) {
        throw "BuildDir is not set or empty"
    }
    if ([string]::IsNullOrWhiteSpace($Configuration)) {
        throw "Configuration is not set or empty"
    }
    
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
    
    # Copy FMOD DLLs to output directory
    $outputDir = Join-Path $BuildDir $Configuration
    
    # Debug output for FMOD directory
    Write-Host "Debug: script:FMODDir = '$($script:FMODDir)'"
    Write-Host "Debug: FMODDir exists = $(if ($script:FMODDir) { Test-Path $script:FMODDir } else { 'null/empty' })"
    
    if (![string]::IsNullOrWhiteSpace($script:FMODDir) -and (Test-Path $script:FMODDir)) {
        $fmodBinDir = Join-Path $script:FMODDir "bin"
        
        if ((Test-Path $fmodBinDir) -and (Test-Path $outputDir)) {
            Write-Status "Copying FMOD DLLs to output directory..."
            $dllFiles = Get-ChildItem $fmodBinDir -Filter "*.dll"
            
            # Copy only the essential FMOD DLLs
            $essentialDlls = @("fmodex64.dll", "fmodex.dll", "fmodexL64.dll", "fmodexL.dll")
            foreach ($dll in $dllFiles) {
                if ($essentialDlls -contains $dll.Name) {
                    $destPath = Join-Path $outputDir $dll.Name
                    Copy-Item $dll.FullName $destPath -Force
                    Write-Host "Copied FMOD DLL: $($dll.Name) to output directory"
                }
            }
        } elseif (-not (Test-Path $fmodBinDir)) {
            Write-Warning "FMOD bin directory not found: $fmodBinDir"
        } elseif (-not (Test-Path $outputDir)) {
            Write-Warning "Output directory not found: $outputDir"
        }
    } else {
        Write-Warning "FMOD directory not set or not found. FMOD DLLs not copied."
        Write-Host "Debug: FMOD directory value: '$($script:FMODDir)'"
    }
    
    # Copy Freedoom WAD files to output directory if they don't exist
    if ([string]::IsNullOrWhiteSpace($ToolsDir)) {
        Write-Warning "ToolsDir is not set. Skipping Freedoom WAD copy."
    } else {
        $freedoomSourceDir = Join-Path $ToolsDir "freedoom"
        $freedoom2Source = Join-Path $freedoomSourceDir "freedoom2.wad"
        $freedoom1Source = Join-Path $freedoomSourceDir "freedoom1.wad"
        
        if (Test-Path $outputDir) {
            $freedoom2Dest = Join-Path $outputDir "freedoom2.wad"
            $freedoom1Dest = Join-Path $outputDir "freedoom1.wad"
            
            # Copy freedoom2.wad if source exists and destination doesn't
            if ((Test-Path $freedoom2Source) -and (-not (Test-Path $freedoom2Dest))) {
                Copy-Item $freedoom2Source $freedoom2Dest -Force
                Write-Host "Copied freedoom2.wad to output directory"
            } elseif (-not (Test-Path $freedoom2Source)) {
                Write-Warning "Freedoom2.wad not found at: $freedoom2Source"
            } elseif (Test-Path $freedoom2Dest) {
                Write-Host "freedoom2.wad already exists in output directory"
            }
            
            # Copy freedoom1.wad if source exists and destination doesn't
            if ((Test-Path $freedoom1Source) -and (-not (Test-Path $freedoom1Dest))) {
                Copy-Item $freedoom1Source $freedoom1Dest -Force
                Write-Host "Copied freedoom1.wad to output directory"
            } elseif (-not (Test-Path $freedoom1Source)) {
                Write-Warning "Freedoom1.wad not found at: $freedoom1Source"
            } elseif (Test-Path $freedoom1Dest) {
                Write-Host "freedoom1.wad already exists in output directory"
            }
        }
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