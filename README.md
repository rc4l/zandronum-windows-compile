# Zandronum EZ Windows Compilation

![Build Status](https://img.shields.io/github/actions/workflow/status/rc4l/zandronum-windows-compile/manual-build-latest.yml?label=build%20status)
![Last Build Date](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/rc4l/zandronum-windows-compile/badges/build-date-badge.json)
![Zandronum Version](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/rc4l/zandronum-windows-compile/badges/zandronum-version-badge.json)

## Overview
This project gives you a super easy way to build the [Zandronum source port](https://www.youtube.com/watch?v=cR5GJCW8S9Q) on Windows. You don't need to install anything by hand or mess with complicated setup. Just download this, run one script, and everything you need gets downloaded and built for you. If you want to play with the code or make your own version, it's all ready—no headaches, no weird steps. Just clone, run, and go!

## Features
- **Just run one script**: You only need to run `build.ps1` and everything else happens for you.
- **No manual installs**: The script grabs and sets up all the tools and libraries you need.
- **Works anywhere**: You can put this folder anywhere on your PC and it will still work.
- **Fast rebuilds**: Stuff you download once is saved in `deps/` so you don't have to re-download it every time.
- **Use your favorite IDE**: Edit code in any IDE you like—VS Code, Visual Studio, CLion, or anything else. You never have to set up build tasks or mess with project files: just keep rerunning `build.ps1` to compile your changes, no matter what editor you use. It's impossible to mess up—just edit and rerun the script!
- **No Doom needed**: You don't need to own Doom to test or play. Freedoom (a free game data pack) is included automatically, so Zandronum will run out of the box.

## Requirements
1. **Windows Windows 11 (x64)**: Older versions may work if they have PowerShell 5.1+ and can run the required dependencies, but are not officially tested.
2. **Git**: Needed to clone Zandronum for the initial setup and future version control. Make sure your PowerShell can run git commands.

## How to Use
1. **Open PowerShell**: Search for "PowerShell" in the Start menu and launch "Windows PowerShell".
2. **Clone this repository**: In PowerShell, run:
   ```powershell
   git clone https://github.com/rc4l/zandronum-windows-compile.git
   cd zandronum-windows-compile
   ```
3. **Run the build script**: 
   ```powershell
   ./build.ps1
   ```
   - This will download all dependencies, fetch the Zandronum source, and build everything in the `build/` folder.
   - You can run your build inside `build/Release/Zandronum.exe`.
   - A copy of Freedoom is automatically placed in the Release folder, so you can launch and test Zandronum right away.
4. **Edit code in**: `src/zandronum` (never in `build/`)
5. **Re-run the script** after making changes to rebuild.

## Output
- `build/`: This is where your compiled Zandronum program and all the files it needs to run will appear. If you want to play or test, look here for Zandronum.exe in `build/Release`.
- `deps/`: This folder holds all the stuff the script downloads to make the build work (compilers, libraries, tools). You almost never need to touch this.
- `src/zandronum`: The Zandronum source code (edit your code here).

## When to rerun `/build.ps1`
- Do you want to make a new build to test your changes? Don't delete anything and rerun it.
- Do you want to wipe everything clean including code changes? Delete `/deps`, `/build`, and `/src/zandronum` and then rerun it.
- Do you just want to do a clean reinstall but keep your code changes? Delete `/deps` and `/build` and then rerun it.

## Dependency Table
| Dependency                | Version      | Source/URL                                                                 | Installation Type | What do? (Why is it needed?)                                                                                 | Notes / Portability                |
|---------------------------|-------------|----------------------------------------------------------------------------|-------------------|--------------------------------------------------------------------------------------------------------------|------------------------------------|
| CMake                     | 3.28.1      | https://github.com/Kitware/CMake/releases                                  | Portable          | Tells your computer how to build Zandronum from the source code.                                              | Downloaded/extracted to deps/      |
| NASM                      | 2.16.01     | https://www.nasm.us/pub/nasm/releasebuilds/                                | Portable          | Builds some low-level parts of Zandronum (fast math, sound, etc).                                             | Downloaded/extracted to deps/      |
| Python (embedded)         | 3.12.1      | https://www.python.org/ftp/python/                                         | Portable          | Runs helper scripts during the build (not for playing the game).                                              | Downloaded/extracted to deps/      |
| FMOD Ex                   | 4.44.64     | https://zdoom.org/files/fmod/                                              | Portable          | Lets Zandronum play music and sound effects.                                                                  | Downloaded/extracted to deps/      |
| OpenSSL                   | 3.5.1       | https://download.firedaemon.com/FireDaemon-OpenSSL/                        | Portable          | Lets Zandronum connect to servers securely (for multiplayer over the internet).                               | Downloaded/extracted to deps/      |
| Opus                      | 1.5.2       | https://downloads.xiph.org/releases/opus/ (committed in tools/opus/)       | Portable          | Lets Zandronum use voice chat in multiplayer games.                                                           | Committed source archive, built during setup |
| 7-Zip (7z.exe)            | Any         | (Committed in tools/7z/ or system)                                         | Portable          | Unpacks all the downloaded files and tools.                                                                   | Must exist in tools/7z/            |
| Visual Studio Build Tools | 2022        | https://visualstudio.microsoft.com/visual-cpp-build-tools/                 | System            | Actually compiles (builds) the Zandronum program from the code.                                               | Auto-installs via winget if needed |
| Windows SDK (DirectX)     | 10.x        | (From local system, via Visual Studio/Windows SDK)                         | System            | Gives Zandronum the files it needs to use graphics and sound on Windows.                                      | Extracted from system, not bundled |
| Git                       | Any         | https://git-scm.com/                                                       | System            | Downloads the Zandronum source code and lets you update it later.                                             | User must install                  |
| Freedoom WADs             | Latest      | https://freedoom.github.io/ (mirrored in tools/freedoom/)                  | Portable          | Free game data so you can run and test Zandronum even if you don't own Doom.                                  | Placed in build/Release            |

## License
This build system is provided as-is for convenience. Zandronum and all third-party dependencies retain their original licenses. See their respective sites for details.

---

Enjoy portable, hassle-free Zandronum development on Windows!
