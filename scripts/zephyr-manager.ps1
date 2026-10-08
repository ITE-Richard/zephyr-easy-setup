[CmdletBinding()]
param(
    [ValidateSet('Online', 'Pack', 'Offline', 'Uninstall', 'Shell')][string]$Mode,
    [string]$SourceWorkspace, [string]$SdkPath,
    [string]$InstallDir,
    [string]$Board, [string]$Qualifier, [string]$Toolchain, [string]$Revision,
    [switch]$CacheOnly, [switch]$CheckOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-DirectoryPath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    if ($full -eq [IO.Path]::GetPathRoot($full)) { return $full }
    return $full.TrimEnd('\')
}

$PackageRoot = Get-DirectoryPath (Join-Path $PSScriptRoot '..')
$Root = $PackageRoot
$Workspace = Join-Path $Root 'zephyrproject'
$Cache = Join-Path $Root 'installers'
$Tools = @(
    @{ Id = 'Python.Python.3.12'; Name = 'python'; Extension = '.exe'; Type = '' },
    @{ Id = 'Git.Git'; Name = 'git'; Extension = '.exe'; Type = '' },
    @{ Id = 'Kitware.CMake'; Name = 'cmake'; Extension = '.msi'; Type = '' },
    @{ Id = '7zip.7zip'; Name = '7z'; Extension = '.exe'; Type = '' },
    @{ Id = 'Ninja-build.Ninja'; Name = 'ninja'; Extension = '.zip'; Type = 'zip' },
    @{ Id = 'oss-winget.gperf'; Name = 'gperf'; Extension = '.zip'; Type = 'zip' },
    @{ Id = 'oss-winget.dtc'; Name = 'dtc'; Extension = '.zip'; Type = 'zip' }
)

function Invoke-Checked([string]$Exe, [string[]]$Arguments) {
    & $Exe @Arguments | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "$Exe failed (exit $LASTEXITCODE)." }
}

function Assert-Within([string]$Path, [string]$Parent) {
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $base = [IO.Path]::GetFullPath($Parent).TrimEnd('\')
    if (-not $full.StartsWith($base + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path is outside the expected directory: $full"
    }
    return $full
}

function Get-RelativeBundlePath([string]$Path, [string]$Parent) {
    $checked = Assert-Within $Path $Parent
    $prefix = [IO.Path]::GetFullPath($Parent).TrimEnd('\') + '\'
    return $checked.Substring($prefix.Length)
}

function Get-ToolsDirectory {
    # Keep portable tools owned by this workspace when the base is a drive root.
    if ($Root -eq [IO.Path]::GetPathRoot($Root)) { return Join-Path $Workspace '.host-tools' }
    return Join-Path $Root 'tools'
}

function Assert-NoLinks([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Linked path is not supported: $Path" }
    # Reject junctions/symlinks before descending into them.
    if ($item.PSIsContainer) {
        foreach ($child in Get-ChildItem -LiteralPath $Path -Force) {
            if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Linked path is not supported: $($child.FullName)" }
            if ($child.PSIsContainer) { Assert-NoLinks $child.FullName }
        }
    }
}

function Remove-Local([string]$Path, [string]$Parent) {
    $checked = Assert-Within $Path $Parent
    if (Test-Path -LiteralPath $checked) {
        Assert-NoLinks $checked
        Remove-Item -LiteralPath $checked -Recurse -Force
    }
}

function Save-Json($Value, [string]$Path) {
    $Value | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Get-Settings([string]$Source) {
    $path = Join-Path $Source '.zephyr-setup.json'
    $settings = [pscustomobject]@{ Board = 'it51xxx_evb'; Qualifier = 'it51xxx_evb/it51526aw'; Toolchain = 'riscv64-zephyr-elf' }
    if (Test-Path -LiteralPath $path) { $settings = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json }
    if ($Board) { $settings.Board = $Board; $settings.Qualifier = '' }
    if ($Qualifier) { $settings.Qualifier = $Qualifier }
    if ($Toolchain) { $settings.Toolchain = $Toolchain }
    return $settings
}

function Refresh-Path {
    $env:Path += ';' + [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
    $known = @(
        "$env:ProgramFiles\CMake\bin", "$env:ProgramFiles\Git\cmd", "$env:ProgramFiles\7-Zip",
        "$env:LOCALAPPDATA\Programs\Git\cmd", "$env:LOCALAPPDATA\Programs\Python\Python312",
        "$env:ProgramFiles\Python312", "$env:LOCALAPPDATA\Microsoft\WinGet\Links", "$env:ProgramFiles\WinGet\Links"
    )
    foreach ($path in $known) { if (Test-Path -LiteralPath $path) { $env:Path = $path + ';' + $env:Path } }
    foreach ($parent in @("$env:LOCALAPPDATA\Microsoft\WinGet\Packages", "$env:ProgramFiles\WinGet\Packages", (Get-ToolsDirectory))) {
        if (Test-Path -LiteralPath $parent) {
            foreach ($exe in Get-ChildItem -LiteralPath $parent -Filter '*.exe' -Recurse -File) {
                if ($exe.BaseName -in @('ninja', 'dtc', 'gperf')) { $env:Path += ';' + $exe.DirectoryName }
            }
        }
    }
    $env:Path = (@($env:Path -split ';' | Where-Object { $_ } | Select-Object -Unique) -join ';')
}

function Get-Python312 {
    foreach ($python in @("$env:LOCALAPPDATA\Programs\Python\Python312\python.exe", "$env:ProgramFiles\Python312\python.exe")) {
        if (Test-Path -LiteralPath $python) {
            & $python -c "import sys,struct; sys.exit(0 if sys.version_info[:2] == (3,12) and struct.calcsize('P') == 8 else 1)" 2>$null
            if ($LASTEXITCODE -eq 0) { return $python }
        }
    }
    $launcher = Get-Command py.exe -ErrorAction SilentlyContinue
    if ($launcher) {
        $path = & $launcher.Source -3.12 -c "import sys,struct; assert struct.calcsize('P') == 8; print(sys.executable)" 2>$null
        if ($LASTEXITCODE -eq 0) { return [string]$path }
    }
    throw 'Python 3.12 x64 is required. Check its installation.'
}

function Test-HostTools {
    $python = Get-Python312
    $env:Path = (Split-Path $python) + ';' + $env:Path
    foreach ($tool in $Tools) {
        $command = Get-Command ($tool.Name + '.exe') -ErrorAction SilentlyContinue
        if (-not $command) { throw "Missing host tool: $($tool.Name)" }
        $argument = '--version'
        if ($tool.Name -eq '7z') { $argument = 'i' }
        Invoke-Checked $command.Source @($argument)
    }
}

function Save-HostPaths {
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $known = @(([Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + $userPath) -split ';' | ForEach-Object { [Environment]::ExpandEnvironmentVariables($_).TrimEnd('\') })
    $updated = $userPath
    foreach ($tool in $Tools) {
        $directory = Split-Path (Get-Command ($tool.Name + '.exe') -ErrorAction Stop).Source
        if ($known -notcontains $directory) {
            $updated = ($updated + ';' + $directory).Trim(';')
            $known += $directory
        }
    }
    if ($updated -cne $userPath) { [Environment]::SetEnvironmentVariable('Path', $updated, 'User') }
}

function Find-Sdk([string]$Source, [string]$Explicit, [string]$TargetToolchain) {
    $candidates = @()
    if ($Explicit) { $candidates = @((Get-Item -LiteralPath $Explicit).FullName) }
    else {
        $candidates = @(Get-ChildItem -LiteralPath $Source -Directory -Filter 'zephyr-sdk-*' | Select-Object -ExpandProperty FullName)
        if ($candidates.Count -eq 0) {
            if ($env:ZEPHYR_SDK_INSTALL_DIR) { $candidates += $env:ZEPHYR_SDK_INSTALL_DIR }
            $stored = Get-Settings $Source
            if ($stored.PSObject.Properties.Name -contains 'SdkDirectory') {
                $storedSdk = $stored.SdkDirectory
                if (-not [IO.Path]::IsPathRooted($storedSdk)) { $storedSdk = Join-Path $Source $storedSdk }
                $candidates += $storedSdk
            }
            $registryPath = 'HKCU:\Software\Kitware\CMake\Packages\Zephyr-sdk'
            if (Test-Path -LiteralPath $registryPath) {
                $key = Get-Item -LiteralPath $registryPath
                foreach ($name in $key.GetValueNames()) {
                    $path = [string]$key.GetValue($name)
                    if ($path) { $candidates += $path; $candidates += Split-Path $path }
                }
            }
            $candidates += @(Get-ChildItem -LiteralPath $env:USERPROFILE -Directory -Filter 'zephyr-sdk-*' | Select-Object -ExpandProperty FullName)
        }
    }
    $valid = @($candidates | Select-Object -Unique | Where-Object { Test-Path -LiteralPath (Join-Path $_ 'sdk_version') })
    $requiredVersionFile = Join-Path $Source 'zephyr\SDK_VERSION'
    if (-not $Explicit -and $valid.Count -gt 1 -and (Test-Path -LiteralPath $requiredVersionFile)) {
        $requiredVersion = (Get-Content -LiteralPath $requiredVersionFile -Raw).Trim()
        $matching = @($valid | Where-Object { (Get-Content -LiteralPath (Join-Path $_ 'sdk_version') -Raw).Trim() -eq $requiredVersion })
        if ($matching.Count -eq 1) { $valid = $matching }
    }
    if ($valid.Count -ne 1) { throw 'Specify exactly one installed SDK using -SdkPath; no complete SDK or multiple SDKs found.' }
    $sdk = [IO.Path]::GetFullPath($valid[0]).TrimEnd('\')
    $compilers = @(Get-ChildItem -LiteralPath $sdk -Filter ($TargetToolchain + '-gcc.exe') -File -Recurse)
    if ($compilers.Count -eq 0) { throw "SDK does not contain the $TargetToolchain compiler." }
    Invoke-Checked $compilers[0].FullName @('--version')
    if (-not (Test-Path -LiteralPath (Join-Path $sdk 'cmake\zephyr_sdk_export.cmake'))) { throw 'SDK CMake export script is missing.' }
    return $sdk
}

function Use-Workspace([string]$Source) {
    $env:Path = (Join-Path $Source '.venv\Scripts') + ';' + $env:Path
    $env:VIRTUAL_ENV = Join-Path $Source '.venv'
    $env:ZEPHYR_BASE = Join-Path $Source 'zephyr'
    $env:ZEPHYR_TOOLCHAIN_VARIANT = 'zephyr'
    Set-Location -LiteralPath $Source
}

function Complete-Setup($Settings, [string]$Sdk) {
    $python = Join-Path $Workspace '.venv\Scripts\python.exe'
    $env:ZEPHYR_SDK_INSTALL_DIR = $Sdk
    Invoke-Checked $python @('-m', 'pip', 'check')
    Invoke-Checked $python @('-m', 'west', 'zephyr-export')
    Invoke-Checked 'cmake.exe' @('-P', (Join-Path $Sdk 'cmake\zephyr_sdk_export.cmake'))
    $savedSdk = $Sdk
    if ($Sdk.StartsWith($Workspace + '\', [StringComparison]::OrdinalIgnoreCase)) { $savedSdk = $Sdk.Substring($Workspace.Length + 1) }
    $Settings | Add-Member -NotePropertyName SdkDirectory -NotePropertyValue $savedSdk -Force
    Save-Json $Settings (Join-Path $Workspace '.zephyr-setup.json')
    $sample = Join-Path $Workspace 'app\blinky'
    if (-not (Test-Path -LiteralPath $sample)) {
        New-Item -ItemType Directory -Path (Split-Path $sample) -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $Workspace 'zephyr\samples\basic\blinky') -Destination $sample -Recurse
    }
    Assert-NoLinks $sample
    $build = Assert-Within (Join-Path $sample 'build') $sample
    & $python -m west build -p always -b $Settings.Board -d $build $sample | Out-Host
    if ($LASTEXITCODE -ne 0 -and $Settings.Qualifier) {
        & $python -m west build -p always -b $Settings.Qualifier -d $build $sample | Out-Host
    }
    if ($LASTEXITCODE -ne 0) { throw 'Sample build failed. Setup verification is incomplete.' }
    Write-Host "[SUCCESS] Setup and sample build completed: $build\zephyr"
    Write-Host 'Run zephyr-env.cmd to open the development shell.'
}

function Select-InstallDirectory {
    $destination = $InstallDir
    if (-not $destination) {
        $default = $PackageRoot
        $answer = Read-Host "Installation directory [$default]"
        $destination = $answer.Trim().Trim('"')
        if (-not $destination) { $destination = $default }
    }
    $selected = Get-DirectoryPath $destination
    if ($selected -match '\s') { throw 'The installation directory must not contain spaces.' }
    if (Test-Path -LiteralPath $selected -PathType Leaf) { throw "Installation directory is a file: $selected" }
    # Inspect existing ancestors before writing through the selected path.
    $ancestor = $selected
    while ($ancestor) {
        if (Test-Path -LiteralPath $ancestor) {
            if ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Linked installation path is not supported: $ancestor" }
        }
        $ancestor = Split-Path $ancestor -Parent
    }
    $script:Root = $selected
    $script:Workspace = Join-Path $selected 'zephyrproject'
    $script:Cache = Join-Path $selected 'installers'
    Write-Host "Installation directory: $Root"
    Write-Host "Zephyr workspace:       $Workspace"
}

function Copy-InstallerPackage {
    if ($Root -ieq $PackageRoot) { return }
    $files = @('zephyr-easy-setup.bat', 'zephyr-pack-offline.bat', 'zephyr-offline-install.bat', 'zephyr-uninstall.bat', 'zephyr-env.cmd', 'README.md', 'scripts\zephyr-manager.ps1', 'tests\verify-workflows.ps1')
    foreach ($relative in $files) {
        if (-not (Test-Path -LiteralPath (Join-Path $PackageRoot $relative) -PathType Leaf)) { throw "Incomplete installer package: $relative" }
    }
    foreach ($relative in $files) {
        $destination = Assert-Within (Join-Path $Root $relative) $Root
        $parent = Split-Path $destination
        if (Test-Path -LiteralPath $parent) {
            $item = Get-Item -LiteralPath $parent -Force
            if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Invalid installer directory: $parent" }
        }
        if (Test-Path -LiteralPath $destination -PathType Container) { throw "Installer file path is a directory: $destination" }
        Assert-NoLinks $destination
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $PackageRoot $relative) -Destination $destination -Force
    }
}

function Install-Online {
    Select-InstallDirectory
    if ($CheckOnly) { Write-Host '[OK] Installation path check complete; no installation performed.'; return }
    Copy-InstallerPackage
    $settings = Get-Settings $Workspace
    Refresh-Path
    foreach ($tool in $Tools) {
        Write-Host "Installing/checking $($tool.Id)..."
        & winget.exe install --id $tool.Id -e --source winget --architecture x64 --silent --accept-package-agreements --accept-source-agreements --disable-interactivity | Out-Host
        # winget also returns nonzero when an installed package has no upgrade.
        Refresh-Path
        if (-not (Get-Command ($tool.Name + '.exe') -ErrorAction SilentlyContinue)) { throw "Installation failed: $($tool.Id)" }
    }
    Test-HostTools
    Save-HostPaths
    Invoke-Checked 'git.exe' @('config', '--global', 'core.longpaths', 'true')
    $python = Get-Python312
    New-Item -ItemType Directory -Path $Workspace -Force | Out-Null
    $venvPython = Join-Path $Workspace '.venv\Scripts\python.exe'
    if (-not (Test-Path -LiteralPath $venvPython)) { Invoke-Checked $python @('-m', 'venv', (Join-Path $Workspace '.venv')) }
    Invoke-Checked $venvPython @('-c', "import sys,struct; assert sys.version_info[:2] == (3,12) and struct.calcsize('P') == 8")
    Use-Workspace $Workspace
    Invoke-Checked $venvPython @('-m', 'pip', 'install', '--upgrade', 'pip', 'west')
    if (-not (Test-Path -LiteralPath (Join-Path $Workspace '.west'))) {
        $initArgs = @('-m', 'west', 'init', '-m', 'https://github.com/zephyrproject-rtos/zephyr')
        if ($Revision) { $initArgs += @('--mr', $Revision) }
        Invoke-Checked $venvPython ($initArgs + @('.'))
    } elseif ($Revision) { throw 'Revision applies to a new workspace only. Existing workspace was preserved.' }
    Invoke-Checked $venvPython @('-m', 'west', 'update')
    $packagesWrapper = Join-Path $Workspace 'zephyr\scripts\utils\west-packages-pip-install.cmd'
    if (Test-Path -LiteralPath $packagesWrapper) {
        Invoke-Checked 'cmd.exe' @('/c', $packagesWrapper)
    } elseif (Test-Path -LiteralPath (Join-Path $Workspace 'zephyr\scripts\west_commands\packages.py')) {
        Invoke-Checked $venvPython @('-m', 'west', 'packages', 'pip', '--install')
    } else {
        Invoke-Checked $venvPython @('-m', 'pip', 'install', '-r', (Join-Path $Workspace 'zephyr\scripts\requirements.txt'))
    }
    # -b is the base directory; -d would rename the SDK to the workspace itself.
    if ($SdkPath) { $sdk = Find-Sdk $Workspace $SdkPath $settings.Toolchain }
    else {
        Invoke-Checked $venvPython @('-m', 'west', 'sdk', 'install', '-b', $Workspace, '-t', $settings.Toolchain)
        $sdk = Find-Sdk $Workspace '' $settings.Toolchain
    }
    Complete-Setup $settings $sdk
}

function Copy-Tree([string]$Source, [string]$Destination, [string[]]$Excluded = @()) {
    Assert-NoLinks $Source
    $copyArgs = @($Source, $Destination, '/E', '/COPY:DAT', '/DCOPY:DAT', '/R:1', '/W:1', '/NFL', '/NDL', '/NJH', '/NJS', '/NP')
    if ($Excluded.Count) { $copyArgs += @('/XD') + $Excluded }
    & robocopy.exe @copyArgs | Out-Host
    if ($LASTEXITCODE -ge 8) { throw "Copy failed: $Source (robocopy exit $LASTEXITCODE)" }
}

function Get-Installer([string]$Directory, [string]$Extension) {
    $files = @(Get-ChildItem -LiteralPath $Directory -File -Recurse | Where-Object { $_.Extension -eq $Extension })
    if ($files.Count -ne 1) { throw "Expected one $Extension installer in $Directory; found $($files.Count)." }
    return $files[0]
}

function New-Bundle {
    if (-not $SourceWorkspace) { $SourceWorkspace = $Workspace }
    $source = (Resolve-Path -LiteralPath $SourceWorkspace).Path.TrimEnd('\')
    if ($source -match '\s') { throw 'The source workspace path must not contain spaces.' }
    if (($Root.TrimEnd('\') + '\').StartsWith($source + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Source workspace cannot contain the packaging project.' }
    $settings = Get-Settings $source
    $python = Join-Path $source '.venv\Scripts\python.exe'
    if (-not (Test-Path -LiteralPath $python)) { throw "Missing source virtual environment: $python" }
    if (-not (Test-Path -LiteralPath (Join-Path $source '.west\config'))) { throw 'Source is not an initialized west workspace.' }
    Refresh-Path
    Use-Workspace $source
    Invoke-Checked $python @('-c', "import sys,struct; assert sys.version_info[:2] == (3,12) and struct.calcsize('P') == 8")
    Invoke-Checked $python @('-m', 'pip', 'check')
    Invoke-Checked $python @('-m', 'west', 'list')
    # Check all active project paths; do not silently omit un-cloned modules.
    $projectPaths = @(& $python -m west list -f '{abspath}')
    if ($LASTEXITCODE -ne 0) { throw 'Cannot list west project paths.' }
    foreach ($projectPath in $projectPaths) {
        $null = Assert-Within $projectPath $source
        $gitPath = Join-Path $projectPath '.git'
        if (-not (Test-Path -LiteralPath $gitPath -PathType Container)) { throw "Missing repository or nonportable Git worktree: $projectPath. Use standalone clones and run west update first." }
        if (Test-Path -LiteralPath (Join-Path $gitPath 'objects\info\alternates')) { throw "External Git objects cannot be bundled: $projectPath" }
    }
    $sdk = Find-Sdk $source $SdkPath $settings.Toolchain
    $sevenZip = (Get-Command '7z.exe' -ErrorAction Stop).Source
    $wheels = Join-Path $Cache 'wheels'
    New-Item -ItemType Directory -Path $wheels -Force | Out-Null
    $frozen = @(& $python -m pip freeze --all)
    if ($LASTEXITCODE -ne 0) { throw 'pip freeze failed.' }
    foreach ($line in $frozen) {
        if ($line -notmatch '^[A-Za-z0-9_.-]+==[^\s]+$') { throw "Cannot reproduce local/editable dependency offline: $line" }
    }
    if (-not ($frozen -match '^west==')) { throw 'west is not installed in the source environment.' }
    $requirements = Join-Path $Cache 'requirements-frozen.txt'
    $frozen | Set-Content -LiteralPath $requirements -Encoding ASCII
    $downloadArgs = @('-m', 'pip', 'download', '--only-binary=:all:', '--find-links', $wheels, '-d', $wheels, '-r', $requirements)
    if ($CacheOnly) { $downloadArgs += '--no-index' }
    Invoke-Checked $python $downloadArgs
    $hostEntries = @()
    foreach ($tool in $Tools) {
        $directory = Join-Path $Cache ('tools\' + $tool.Id)
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        $existing = @(Get-ChildItem -LiteralPath $directory -File -Recurse | Where-Object { $_.Extension -eq $tool.Extension })
        if ($existing.Count -eq 0) {
            if ($CacheOnly) { throw "Missing cached installer: $($tool.Id). Run packaging with network once." }
            # EXE/MSI are file extensions; WinGet may classify them as inno/burn/wix.
            $hostDownloadArgs = @('download', '--id', $tool.Id, '-e', '--source', 'winget', '--architecture', 'x64', '--download-directory', $directory, '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
            if ($tool.Type) { $hostDownloadArgs += @('--installer-type', $tool.Type) }
            Invoke-Checked 'winget.exe' $hostDownloadArgs
        }
        $installer = Get-Installer $directory $tool.Extension
        $hostEntries += @{ Id = $tool.Id; Name = $tool.Name; Path = (Get-RelativeBundlePath $installer.FullName $Root); Sha256 = (Get-FileHash -LiteralPath $installer.FullName -Algorithm SHA256).Hash }
    }
    # A clean venv proves wheel closure without contacting PyPI.
    $stage = Join-Path $Root ('offline_bundle\' + [guid]::NewGuid().ToString('N'))
    $testVenv = Join-Path $stage 'wheel-test'
    $bundle = Join-Path $stage 'bundle'
    $partial = Join-Path $stage 'zephyr-offline-bundle.zip'
    try {
        New-Item -ItemType Directory -Path $bundle -Force | Out-Null
        Invoke-Checked $python @('-m', 'venv', $testVenv)
        $testPython = Join-Path $testVenv 'Scripts\python.exe'
        Invoke-Checked $testPython @('-m', 'pip', '--isolated', 'install', '--no-index', '--find-links', $wheels, '-r', $requirements)
        Invoke-Checked $testPython @('-m', 'pip', 'check')
        if (Test-Path -LiteralPath (Join-Path $source 'zephyr\scripts\west_commands\packages.py')) {
            $requirementLines = @(& $python -m west packages pip)
            if ($LASTEXITCODE -ne 0) { throw 'Cannot collect Zephyr/module requirements.' }
            $requiredArgs = @()
            foreach ($line in $requirementLines) {
                if ($line -match '^\s*-r\s+(.+?)\s*$') {
                    $requirementPath = $Matches[1].Trim('"', "'")
                    $null = Assert-Within $requirementPath $source
                    $requiredArgs += @('-r', $requirementPath)
                } elseif ($line.Trim()) { throw "Unexpected west packages output: $line" }
            }
            if (-not $requiredArgs.Count) { throw 'No Zephyr requirements were found.' }
        } else { $requiredArgs = @('-r', (Join-Path $source 'zephyr\scripts\requirements.txt')) }
        Invoke-Checked $testPython (@('-m', 'pip', '--isolated', 'install', '--dry-run', '--no-index', '--find-links', $wheels, '-c', $requirements) + $requiredArgs)
        foreach ($file in @('zephyr-offline-install.bat', 'zephyr-uninstall.bat', 'zephyr-env.cmd', 'README.md')) {
            Copy-Item -LiteralPath (Join-Path $Root $file) -Destination $bundle
        }
        Copy-Tree $PSScriptRoot (Join-Path $bundle 'scripts')
        Copy-Tree $Cache (Join-Path $bundle 'installers')
        $targetWorkspace = Join-Path $bundle 'zephyrproject'
        Copy-Tree $source $targetWorkspace @((Join-Path $source '.venv'), (Join-Path $source 'app\blinky\build'))
        $sdkName = 'zephyr-sdk-' + (Get-Content -LiteralPath (Join-Path $sdk 'sdk_version') -Raw).Trim()
        if ($sdkName -notmatch '^zephyr-sdk-[0-9]+\.[0-9]+\.[0-9]+[A-Za-z0-9_.-]*$') { throw 'Invalid SDK version.' }
        $targetSdk = Join-Path $targetWorkspace $sdkName
        if (Test-Path -LiteralPath $targetSdk) { Remove-Local $targetSdk $targetWorkspace }
        Copy-Tree $sdk $targetSdk
        $settings | Add-Member -NotePropertyName SdkDirectory -NotePropertyValue $sdkName -Force
        Save-Json $settings (Join-Path $targetWorkspace '.zephyr-setup.json')
        $files = @(Get-ChildItem -LiteralPath $bundle -Recurse -Force -File | ForEach-Object {
            @{ Path = (Get-RelativeBundlePath $_.FullName $bundle); Sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
        })
        Save-Json @{ Format = 1; Python = '3.12'; Architecture = 'x64'; Sdk = 'zephyrproject\' + $sdkName; Settings = $settings; HostTools = $hostEntries; Files = $files } (Join-Path $bundle 'bundle-manifest.json')
        Push-Location -LiteralPath $bundle
        try { Invoke-Checked $sevenZip @('a', '-tzip', $partial, '.\*'); Invoke-Checked $sevenZip @('t', $partial) }
        finally { Pop-Location }
        Move-Item -LiteralPath $partial -Destination (Join-Path $Root 'zephyr-offline-bundle.zip') -Force
        Write-Host "[SUCCESS] Created $Root\zephyr-offline-bundle.zip"
    } finally { if (Test-Path -LiteralPath $stage) { Remove-Local $stage (Join-Path $Root 'offline_bundle') } }
}

function Test-Bundle {
    $manifest = Get-Content -LiteralPath (Join-Path $Root 'bundle-manifest.json') -Raw | ConvertFrom-Json
    if ($manifest.Format -ne 1 -or $manifest.Python -ne '3.12' -or $manifest.Architecture -ne 'x64') { throw 'Unsupported bundle format/platform.' }
    foreach ($entry in $manifest.Files) {
        $path = Assert-Within (Join-Path $Root $entry.Path) $Root
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $entry.Sha256) { throw "Bundle file is damaged or modified: $($entry.Path)" }
    }
    foreach ($required in @('zephyrproject\.west\config', 'zephyrproject\zephyr\scripts\requirements.txt', 'installers\requirements-frozen.txt')) {
        if (-not (Test-Path -LiteralPath (Join-Path $Root $required))) { throw "Incomplete bundle: $required" }
    }
    $null = Assert-Within (Join-Path $Root $manifest.Sdk) $Workspace
    if (-not (Test-Path -LiteralPath (Join-Path $Root ($manifest.Sdk + '\sdk_version')))) { throw 'Bundle SDK version file is missing.' }
    if (@(Get-ChildItem -LiteralPath (Join-Path $Cache 'wheels') -Filter '*.whl' -File).Count -eq 0) { throw 'Bundle contains no Python wheels.' }
    foreach ($tool in $Tools) {
        $entry = @($manifest.HostTools | Where-Object { $_.Id -eq $tool.Id })
        if ($entry.Count -ne 1) { throw "Bundle is missing installer metadata: $($tool.Id)" }
        $path = Assert-Within (Join-Path $Root $entry[0].Path) $Cache
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $entry[0].Sha256) { throw "Installer checksum failed: $($tool.Id)" }
    }
    Write-Host '[OK] Bundle checksums and installer inventory verified.'
    return $manifest
}

function Start-Installer([string]$Path, [string]$Arguments, [switch]$Msi) {
    $exe = $Path
    if ($Msi) { $exe = 'msiexec.exe'; $Arguments = '/i "' + $Path + '" ' + $Arguments }
    $process = Start-Process -FilePath $exe -ArgumentList $Arguments -WindowStyle Hidden -Wait -PassThru
    if ($process.ExitCode -eq 3010) { throw 'Installer requires a Windows restart. Restart and run offline installation again.' }
    if ($process.ExitCode -ne 0) { throw "Installer failed: $Path (exit $($process.ExitCode))" }
}

function Install-Offline {
    $manifest = Test-Bundle
    if ($CheckOnly) { return }
    Refresh-Path
    foreach ($tool in $Tools) {
        $entry = @($manifest.HostTools | Where-Object { $_.Id -eq $tool.Id })[0]
        $installer = Join-Path $Root $entry.Path
        if ($tool.Extension -eq '.zip') {
            $destination = Join-Path (Get-ToolsDirectory) $tool.Name
            New-Item -ItemType Directory -Path $destination -Force | Out-Null
            Invoke-Checked '7z.exe' @('x', '-y', ('-o' + $destination), $installer)
        } elseif ($tool.Name -eq 'python') {
            try { $null = Get-Python312 } catch { Start-Installer $installer '/quiet InstallAllUsers=0 PrependPath=1 Include_pip=1 Include_launcher=1' }
        } elseif (-not (Get-Command ($tool.Name + '.exe') -ErrorAction SilentlyContinue)) {
            switch ($tool.Name) {
                'git' { Start-Installer $installer '/VERYSILENT /NORESTART /SP-' }
                'cmake' { Start-Installer $installer '/qn /norestart ADD_CMAKE_TO_PATH=System' -Msi }
                '7z' { Start-Installer $installer '/S' }
            }
        }
        Refresh-Path
    }
    Test-HostTools
    Save-HostPaths
    Invoke-Checked 'git.exe' @('config', '--global', 'core.longpaths', 'true')
    $python = Get-Python312
    $venvPython = Join-Path $Workspace '.venv\Scripts\python.exe'
    if (-not (Test-Path -LiteralPath $venvPython)) { Invoke-Checked $python @('-m', 'venv', (Join-Path $Workspace '.venv')) }
    Invoke-Checked $venvPython @('-c', "import sys,struct; assert sys.version_info[:2] == (3,12) and struct.calcsize('P') == 8")
    Use-Workspace $Workspace
    Invoke-Checked $venvPython @('-m', 'pip', '--isolated', 'install', '--no-index', '--find-links', (Join-Path $Cache 'wheels'), '-r', (Join-Path $Cache 'requirements-frozen.txt'))
    $settings = Get-Settings $Workspace
    $sdk = Find-Sdk $Workspace (Assert-Within (Join-Path $Root $manifest.Sdk) $Workspace) $settings.Toolchain
    Complete-Setup $settings $sdk
}

function Clear-Registration {
    foreach ($package in @('Zephyr', 'Zephyr-sdk')) {
        $keyPath = 'HKCU:\Software\Kitware\CMake\Packages\' + $package
        if (Test-Path -LiteralPath $keyPath) {
            $key = Get-Item -LiteralPath $keyPath
            foreach ($name in $key.GetValueNames()) {
                $value = [string]$key.GetValue($name)
                if ($value.Replace('/', '\').StartsWith($Workspace + '\', [StringComparison]::OrdinalIgnoreCase)) {
                    Remove-ItemProperty -LiteralPath $keyPath -Name $name
                }
            }
        }
    }
    $sdkVariable = [Environment]::GetEnvironmentVariable('ZEPHYR_SDK_INSTALL_DIR', 'User')
    foreach ($name in @('ZEPHYR_BASE', 'ZEPHYR_SDK_INSTALL_DIR')) {
        $value = [Environment]::GetEnvironmentVariable($name, 'User')
        if ($value -and $value.Replace('/', '\').StartsWith($Workspace + '\', [StringComparison]::OrdinalIgnoreCase)) {
            [Environment]::SetEnvironmentVariable($name, $null, 'User')
        }
    }
    if ($sdkVariable -and $sdkVariable.Replace('/', '\').StartsWith($Workspace + '\', [StringComparison]::OrdinalIgnoreCase)) {
        [Environment]::SetEnvironmentVariable('ZEPHYR_TOOLCHAIN_VARIANT', $null, 'User')
    }
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($userPath) {
        $toolsPrefix = (Get-ToolsDirectory).TrimEnd('\') + '\'
        $kept = @($userPath -split ';' | Where-Object {
            $expanded = [Environment]::ExpandEnvironmentVariables($_).TrimEnd('\')
            -not ($expanded.StartsWith($Workspace + '\', [StringComparison]::OrdinalIgnoreCase) -or $expanded.StartsWith($toolsPrefix, [StringComparison]::OrdinalIgnoreCase))
        })
        if (($kept -join ';') -cne $userPath) { [Environment]::SetEnvironmentVariable('Path', ($kept -join ';'), 'User') }
    }
}

function Uninstall-Zephyr {
    Write-Host "Remove sources, modules, SDK and .venv ONLY from: $Workspace"
    Write-Host "Preserve applications in: $Workspace\app"
    Write-Host 'Offline installers and bundle ZIP are retained. Close build tools before continuing.'
    if ((Read-Host 'Remove this Zephyr installation? (y/N)').Trim() -ine 'y') { Write-Host 'Cancelled. No changes made.'; return }
    $removeTools = (Read-Host 'Also uninstall shared Python, Git, CMake, Ninja, dtc, gperf and 7-Zip? (y/N)').Trim() -ieq 'y'
    $project = Assert-Within $Workspace $Root
    $localTools = Get-ToolsDirectory
    Assert-NoLinks $project
    Assert-NoLinks $localTools
    if (Test-Path -LiteralPath $project) {
        foreach ($child in Get-ChildItem -LiteralPath $project -Force) {
            if ($child.Name -ine 'app') { Remove-Local $child.FullName $project }
        }
    }
    Remove-Local $localTools $Root
    Clear-Registration
    if ($removeTools) {
        Refresh-Path
        $winget = (Get-Command winget.exe -ErrorAction Stop).Source
        $failed = @()
        foreach ($tool in $Tools) {
            & $winget uninstall --id $tool.Id -e --silent --accept-source-agreements --disable-interactivity | Out-Host
            # APP_NOT_INSTALLED is acceptable for portable/offline tools.
            if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne -1978335184) { $failed += $tool.Id }
        }
        if ($failed.Count) { throw "Workspace removed, but shared tool removal failed: $($failed -join ', ')" }
    }
    Write-Host '[SUCCESS] Zephyr removed; app and offline installation cache preserved.'
}

function Open-DevelopmentShell {
    Refresh-Path
    $settings = Get-Settings $Workspace
    if (-not (Test-Path -LiteralPath (Join-Path $Workspace '.venv\Scripts\python.exe'))) { throw 'Run setup before opening the development shell.' }
    $selectedSdk = ''
    if ($settings.PSObject.Properties.Name -contains 'SdkDirectory') {
        $selectedSdk = $settings.SdkDirectory
        if (-not [IO.Path]::IsPathRooted($selectedSdk)) { $selectedSdk = Join-Path $Workspace $selectedSdk }
    }
    $env:ZEPHYR_SDK_INSTALL_DIR = Find-Sdk $Workspace $selectedSdk $settings.Toolchain
    Use-Workspace $Workspace
    Write-Host "Workspace: $Workspace"
    Write-Host "SDK: $env:ZEPHYR_SDK_INSTALL_DIR"
    Write-Host "Build: west build -p always -b $($settings.Board) app\blinky"
    Invoke-Checked 'cmd.exe' @('/k')
}

try {
    if (-not [Environment]::Is64BitProcess -or $env:PROCESSOR_ARCHITECTURE -ne 'AMD64') { throw 'Run on Windows x64 using 64-bit PowerShell.' }
    if ($InstallDir -and $Mode -ne 'Online') { throw '-InstallDir applies to online installation only. Run the other launchers from the selected installation directory.' }
    if ($Mode -notin @('Uninstall', 'Online') -and $Root -match '\s') { throw 'Move this project to a path without spaces before installation or packaging.' }
    switch ($Mode) {
        'Online' { Install-Online }
        'Pack' { New-Bundle }
        'Offline' { Install-Offline }
        'Uninstall' { Uninstall-Zephyr }
        'Shell' { Open-DevelopmentShell }
        default { throw 'Specify -Mode Online, Pack, Offline or Uninstall.' }
    }
    exit 0
} catch { Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red; exit 1 }
