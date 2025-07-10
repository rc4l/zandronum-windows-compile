# Zandronum EZ Windows Compilation

![Build Status](https://img.shields.io/github/actions/workflow/status/rc4l/zandronum-windows-compile/manual-build-latest.yml?label=build%20status)
![Last Build Date](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/rc4l/zandronum-windows-compile/badges/build-date-badge.json)
![Zandronum Version](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/rc4l/zandronum-windows-compile/badges/zandronum-version-badge.json)

# Tl;dr
This project gives you a super easy way to develop the [Zandronum source port](https://www.youtube.com/watch?v=cR5GJCW8S9Q) on Windows 10/11. You'll need a working PowerShell with Mercurial (`winget install Mercurial.Mercurial -e`) and Git (`winget install --id Git.Git -e --source winget`) installed.

## How to Use
1. In PowerShell, run:
   ```powershell
   git clone https://github.com/rc4l/zandronum-windows-compile.git
   cd zandronum-windows-compile
   ```
2. Then run: `./build.ps1` to setup everything. This'll take 5-8 minutes for the first time. You should see a runnable game in `build/Release`.
3. You can now make code changes in `src/zandronum` (never in `build/`) and rerun `./build.ps1` to update your game.

# Technical Details

## When to rerun `/build.ps1`
- Do you want to make a new build to test your changes? Don't delete anything and rerun it.
- Do you want to wipe everything clean including code changes? Delete `/deps`, `/build`, and `/src/zandronum` and then rerun it.
- Do you just want to do a clean reinstall but keep your code changes? Delete `/deps` and `/build` and then rerun it.

## Output
- `build/`: This is where your compiled Zandronum program and all the files it needs to run will appear. If you want to play or test, look here for Zandronum.exe in `build/Release`.
- `deps/`: This folder holds all the stuff the script downloads to make the build work (compilers, libraries, etc). You almost never need to touch this.
- `src/zandronum`: The Zandronum source code (edit your code here).

## Dependency Table
| Dependency                | Version      | Source/URL                                                                 | Installation Type | What do? (Why is it needed?)                                                                                 | Notes / Portability                |
|---------------------------|-------------|----------------------------------------------------------------------------|-------------------|--------------------------------------------------------------------------------------------------------------|------------------------------------|
| CMake                     | 3.28.1      | https://github.com/Kitware/CMake/releases                                  | Portable          | Tells your computer how to build Zandronum from the source code.                                              | Downloaded/extracted to deps/      |
| NASM                      | 2.16.01     | https://www.nasm.us/pub/nasm/releasebuilds/                                | Portable          | Builds some low-level parts of Zandronum (fast math, sound, etc).                                             | Downloaded/extracted to deps/      |
| Python (embedded)         | 3.12.1      | https://www.python.org/ftp/python/                                         | Portable          | Runs helper scripts during the build (not for playing the game).                                              | Downloaded/extracted to deps/      |
| Strawberry Perl Portable  | 5.40.0.1    | https://github.com/StrawberryPerl/Perl-Dist-Strawberry/releases           | Portable          | Required to configure and build OpenSSL from source code.                                                     | Downloaded/extracted to deps/      |
| FMOD Ex                   | 4.44.64     | https://zdoom.org/files/fmod/                                              | Portable          | Lets Zandronum play music and sound effects.                                                                  | Downloaded/extracted to deps/      |
| OpenSSL                   | 3.5.1       | https://www.openssl.org/source/ (built from source)                        | Portable          | Lets Zandronum connect to servers securely (for multiplayer over the internet).                               | Built statically from source to avoid DLL dependencies |
| Opus                      | 1.5.2       | https://downloads.xiph.org/releases/opus/ (committed in tools/opus/)       | Portable          | Lets Zandronum use voice chat in multiplayer games.                                                           | Committed source archive, built during setup |
| 7-Zip (7z.exe)            | Any         | (Committed in tools/7z/ or system)                                         | Portable          | Unpacks all the downloaded files and tools.                                                                   | Must exist in tools/7z/            |
| Visual Studio Build Tools | 2022        | https://visualstudio.microsoft.com/visual-cpp-build-tools/                 | System            | Actually compiles (builds) the Zandronum program from the code.                                               | Auto-installs via winget if needed |
| Windows SDK (DirectX)     | 10.x        | (From local system, via Visual Studio/Windows SDK)                         | System            | Gives Zandronum the files it needs to use graphics and sound on Windows.                                      | Extracted from system, not bundled |
| Git                       | Any         | https://git-scm.com/                                                       | System            | Downloads this repository and manages version control for this build system.                                  | User must install                  |
| Mercurial                 | Any         | https://www.mercurial-scm.org/install                                      | System            | Downloads the Zandronum source code from the official repository.                                             | User must install                  |
| Freedoom WADs             | Latest      | https://freedoom.github.io/ (mirrored in tools/freedoom/)                  | Portable          | Free game data so you can run and test Zandronum even if you don't own Doom.                                  | Placed in build/Release            |

## License
This build system is provided as-is for convenience. Zandronum and all third-party dependencies retain their original licenses. See their respective sites for details.

---

Enjoy portable, hassle-free Zandronum development on Windows!
