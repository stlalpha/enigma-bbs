param(
    [string[]]$TargetPlatforms,
    [string]$NodeVersion,
    [switch]$SkipCompleted,
    [switch]$ForceRebuild
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scoopCandidates = @()
if ($env:SCOOP) {
    $scoopCandidates += (Join-Path $env:SCOOP 'shims')
}
$scoopCandidates += (Join-Path $env:USERPROFILE 'scoop\\shims')
foreach ($candidate in $scoopCandidates) {
    if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
    if (-not (Test-Path $candidate)) { continue }
    $currentPaths = $env:PATH -split ';'
    if ($currentPaths -notcontains $candidate) {
        $env:PATH = "$candidate;$env:PATH"
    }
}

function Write-Step($Message) {
    Write-Host "[STEP] $Message" -ForegroundColor Cyan
}

function Write-Info($Message) {
    Write-Host "[INFO] $Message" -ForegroundColor Green
}

function Write-Warn($Message) {
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Abort($Message) {
    Write-Host "[ERROR] $Message" -ForegroundColor Red
    throw $Message
}

function Ensure-Command($Command) {
    if (-not (Get-Command $Command -ErrorAction SilentlyContinue)) {
        Abort "Missing required command: $Command"
    }
}

function Sync-Directory {
    param(
        [string]$Source,
        [string]$Destination,
        [string[]]$ExcludeDirectories = @()
    )
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    $arguments = @($Source, $Destination, '/MIR', '/NDL', '/NFL', '/NJH', '/NJS', '/NP')
    if ($ExcludeDirectories -and $ExcludeDirectories.Count -gt 0) {
        $arguments += '/XD'
        $arguments += $ExcludeDirectories
    }
    & robocopy @arguments | Out-Null
    $exitCode = $LASTEXITCODE
    if ($exitCode -gt 7) {
        Abort "robocopy failed with exit code $exitCode while syncing $Source to $Destination"
    }
}

function Copy-ProjectSources($RootDir, $StageDir) {
    New-Item -ItemType Directory -Force -Path $StageDir | Out-Null
    $paths = @(
        'art',
        'config',
        'core',
        'docs',
        'gopher',
        'misc',
        'mods',
        'util',
        'www',
        'autoexec.sh',
        'LICENSE.TXT',
        'CONTRIBUTING.md',
        'UPGRADE.md',
        'main.js',
        'oputil.js',
        'package.json',
        'package-lock.json',
        'README.md',
        'TROUBLESHOOTING.md',
        'WHATSNEW.md'
    )

    foreach ($entry in $paths) {
        $sourcePath = Join-Path $RootDir $entry
        if (Test-Path $sourcePath) {
            $destPath = Join-Path $StageDir $entry
            if ((Get-Item $sourcePath).PSIsContainer) {
                Sync-Directory -Source $sourcePath -Destination $destPath -ExcludeDirectories @('node_modules')
            } else {
                New-Item -ItemType Directory -Force -Path (Split-Path $destPath -Parent) | Out-Null
                Copy-Item -Path $sourcePath -Destination $destPath -Force
            }
        }
    }

    $scriptsDir = Join-Path $StageDir 'scripts'
    New-Item -ItemType Directory -Force -Path $scriptsDir | Out-Null
    $postInstallSource = Join-Path $RootDir 'scripts/postinstall.js'
    if (Test-Path $postInstallSource) {
        Copy-Item -Path $postInstallSource -Destination (Join-Path $scriptsDir 'postinstall.js') -Force
    }

    Get-ChildItem -Path $StageDir -Filter 'node_modules' -Directory -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-Item -Path $_.FullName -Recurse -Force
    }
}

function Sanitize-PackageJson($PackagePath) {
    if (-not (Test-Path $PackagePath)) {
        return
    }

    $content = Get-Content -Path $PackagePath -Raw
    if (-not $content) {
        return
    }

    $json = $content | ConvertFrom-Json
    if ($null -ne $json.scripts -and $json.scripts.prepare -eq 'husky') {
        $json.scripts.PSObject.Properties.Remove('prepare')
        ($json | ConvertTo-Json -Depth 100) + "`n" | Set-Content -Path $PackagePath -Encoding UTF8
    }
}

function Map-NpmPlatform($Os) {
    switch ($Os) {
        'linux' { return 'linux' }
        'darwin' { return 'darwin' }
        'windows' { return 'win32' }
        default { return $Os }
    }
}

function Map-NpmArch($Arch) {
    switch ($Arch) {
        'amd64' { return 'x64' }
        'arm64' { return 'arm64' }
        'armv7' { return 'arm' }
        default { return $Arch }
    }
}

function Find-NodeBinary($RuntimeDir) {
    $candidates = @(
        Join-Path $RuntimeDir 'bin/node',
        Join-Path $RuntimeDir 'bin/node.exe',
        Join-Path $RuntimeDir 'node',
        Join-Path $RuntimeDir 'node.exe'
    )
    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) {
            return (Resolve-Path $candidate).Path
        }
    }
    return $null
}

function Find-NpmCli($RuntimeDir) {
    $candidates = @(
        (Join-Path $RuntimeDir 'lib/node_modules/npm/bin/npm-cli.js')
        (Join-Path $RuntimeDir 'node_modules/npm/bin/npm-cli.js')
    )
    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) {
            return (Resolve-Path $candidate).Path
        }
    }
    return $null
}

function Get-ModulesPresent($StageDir, $Modules) {
    $present = @()
    foreach ($module in $Modules) {
        $modulePath = Join-Path $StageDir ("node_modules/$module")
        if (Test-Path $modulePath) {
            $present += $module
        }
    }
    return $present
}

function Invoke-WithEnvironment($Variables, [scriptblock]$Action) {
    $original = @{}
    foreach ($key in $Variables.Keys) {
        $original[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
        [Environment]::SetEnvironmentVariable($key, $Variables[$key], 'Process')
    }
    try {
        & $Action
    } finally {
        foreach ($key in $Variables.Keys) {
            if ($null -eq $original[$key]) {
                [Environment]::SetEnvironmentVariable($key, $null, 'Process')
            } else {
                [Environment]::SetEnvironmentVariable($key, $original[$key], 'Process')
            }
        }
    }
}

function Get-HostPlatform() {
    $architecture = $env:PROCESSOR_ARCHITECTURE
    if ([string]::IsNullOrWhiteSpace($architecture)) {
        Abort 'Unable to determine host processor architecture'
    }

    if ($architecture -eq 'x86' -and $env:PROCESSOR_ARCHITEW6432) {
        $architecture = $env:PROCESSOR_ARCHITEW6432
    }

    switch ($architecture.ToLowerInvariant()) {
        'amd64' { return 'windows/amd64' }
        'arm64' { return 'windows/arm64' }
        default { Abort "Unsupported host processor architecture: $architecture" }
    }
}

function Ensure-HostNodeVersion($Expected, $CacheDir) {
    $nodeCommand = Get-Command node -ErrorAction SilentlyContinue
    $expectedTag = "v$Expected"

    if ($nodeCommand) {
        $version = (& $nodeCommand.Source -v).Trim()
        if ($version -ne $expectedTag) {
            Write-Warn "Host Node version $version differs from expected $expectedTag; builds may fail"
        }
        return $nodeCommand.Source
    }

    $hostPlatform = Get-HostPlatform
    $runtimeDirName = "host-node-v$Expected-$($hostPlatform -replace '/', '-')"
    $runtimeDir = Join-Path $CacheDir $runtimeDirName
    $nodePath = Find-NodeBinary $runtimeDir

    if ($nodePath) {
        Write-Info "Using cached portable Node runtime for host environment: $(Split-Path $nodePath -Leaf)"
    } else {
        Write-Info 'Host Node.js not found in PATH; fetching portable runtime'
        $archive = Download-NodeRuntime -NodeVersion $Expected -CacheDir $CacheDir -Platform $hostPlatform
        Expand-Zip -ArchivePath $archive -Destination $runtimeDir
        $nodePath = Find-NodeBinary $runtimeDir
    }

    if (-not $nodePath) {
        Abort "Unable to locate Node.js binary for host platform $hostPlatform"
    }

    $resolvedVersion = (& $nodePath -v).Trim()
    if ($resolvedVersion -ne $expectedTag) {
        Write-Warn "Portable Node version $resolvedVersion differs from expected $expectedTag; builds may fail"
    }

    return $nodePath
}

function Download-NodeRuntime($NodeVersion, $CacheDir, $Platform) {
    $osArch = $Platform.Split('/')
    $os = $osArch[0]
    $arch = $osArch[1]
    switch ($os) {
        'windows' {
            switch ($arch) {
                'amd64' { $archive = "node-v$NodeVersion-win-x64.zip" }
                'arm64' { $archive = "node-v$NodeVersion-win-arm64.zip" }
                default { Abort "Unsupported windows arch: $arch" }
            }
        }
        default { Abort "download_node_runtime not implemented for $Platform" }
    }

    $url = "https://nodejs.org/dist/v$NodeVersion/$archive"
    $destination = Join-Path $CacheDir $archive
    if (-not (Test-Path $destination)) {
        Write-Step "Downloading Node.js v$NodeVersion for $Platform"
        Invoke-WebRequest -Uri $url -OutFile $destination -UseBasicParsing
    } else {
        Write-Info "Using cached Node runtime: $archive"
    }
    return $destination
}

function Expand-Zip($ArchivePath, $Destination) {
    if (Test-Path $Destination) {
        Remove-Item -Path $Destination -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    $tempDir = New-Item -ItemType Directory -Path (Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString()))
    try {
        Expand-Archive -Path $ArchivePath -DestinationPath $tempDir.FullName -Force
        $extracted = Get-ChildItem -Path $tempDir.FullName | Where-Object { $_.PSIsContainer } | Select-Object -First 1
        if (-not $extracted) {
            Abort "Unable to locate extracted Node directory for $ArchivePath"
        }
        Sync-Directory -Source $extracted.FullName -Destination $Destination
    } finally {
        Remove-Item -Path $tempDir.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Run-NpmCiWindows($Platform, $StageDir, $NodeVersion, $CacheDir) {
    $runtimeDir = Join-Path $StageDir 'runtime'
    $npmPlatform = Map-NpmPlatform($Platform.Split('/')[0])
    $npmArch = Map-NpmArch($Platform.Split('/')[1])
    $hostNodePath = Ensure-HostNodeVersion -Expected $NodeVersion -CacheDir $CacheDir
    $npmCli = Find-NpmCli $runtimeDir
    if (-not $npmCli) {
        Abort "npm CLI not found for $Platform"
    }

    Write-Step "Installing npm dependencies for $Platform"
    $clComponents = @()
    if ($env:CL) {
        $clComponents += $env:CL
    }
    $clComponents += '/Zc:gotoScope-'
    $clComponents += '/wd2362'
    $clFlags = ($clComponents | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ' '

    $envVars = @{
        'npm_config_platform' = $npmPlatform
        'npm_config_arch' = $npmArch
        'HUSKY' = '0'
        'PATH' = "$runtimeDir;$runtimeDir\bin;$env:PATH"
        'GYP_MSVS_VERSION' = '2022'
        'npm_config_msvs_version' = '2022'
        'msvs_version' = '2022'
        'CL' = $clFlags
    }

    Invoke-WithEnvironment $envVars {
        Push-Location $StageDir
        try {
            & $hostNodePath $npmCli 'ci' '--omit=dev'
            if ($LASTEXITCODE -ne 0) {
                Abort "npm ci failed for $Platform"
            }
        } finally {
            Pop-Location
        }
    }

    $nativeModules = @('sqlite3', 'node-pty', 'sharp', 'ssh2')
    $present = Get-ModulesPresent -StageDir $StageDir -Modules $nativeModules
    if ($present.Count -gt 0) {
        Invoke-WithEnvironment $envVars {
            foreach ($module in $present) {
                Push-Location $StageDir
                try {
                    & $hostNodePath $npmCli 'rebuild' $module '--build-from-source'
                    if ($LASTEXITCODE -ne 0) {
                        Abort "npm rebuild $module failed for $Platform"
                    }
                } finally {
                    Pop-Location
                }
            }
        }
    }
}

function Create-ReleaseArchive($StageDir, $OutFile) {
    Write-Step "Creating payload archive: $(Split-Path $OutFile -Leaf)"
    if (Test-Path $OutFile) {
        Remove-Item $OutFile -Force
    }
    $outDir = Split-Path $OutFile -Parent
    if (-not (Test-Path $outDir)) {
        New-Item -ItemType Directory -Force -Path $outDir | Out-Null
    }
    & tar -czf $OutFile -C $StageDir .
    if ($LASTEXITCODE -ne 0) {
        Abort "Failed to create archive $OutFile"
    }
}

function Installer-Filename($Platform) {
    $osArch = $Platform.Split('/')
    $os = $osArch[0]
    $arch = $osArch[1]
    $name = "enigma-installer-$os-$arch"
    if ($os -eq 'windows') {
        $name += '.exe'
    }
    return $name
}

function Build-InstallerBinary($Platform, $Payload, $RootDir, $DistRoot, $GoBin, $LdFlagsBase, $VersionLabel, $BuildDate, $GitCommit) {
    $osArch = $Platform.Split('/')
    $os = $osArch[0]
    $arch = $osArch[1]
    $outputName = Installer-Filename $Platform

    $goEnv = @{
        'GOOS' = $os
        'GOARCH' = $arch
        'CGO_ENABLED' = '0'
        'GOTOOLCHAIN' = 'local'
    }

    if ($os -eq 'linux' -and $arch -eq 'armv7') {
        $goEnv['GOARCH'] = 'arm'
        $goEnv['GOARM'] = '7'
    }

    $installerDir = Join-Path $RootDir 'cmd/installer'
    $payloadTarget = Join-Path $installerDir 'release-data.tar.gz'
    Copy-Item -Path $Payload -Destination $payloadTarget -Force

    $ldflags = "$LdFlagsBase -X main.version=$VersionLabel -X main.buildDate=$BuildDate -X main.gitCommit=$GitCommit"

    Invoke-WithEnvironment $goEnv {
        Push-Location $installerDir
        try {
            & $GoBin 'build' '-ldflags' $ldflags '-o' (Join-Path $DistRoot $outputName)
            if ($LASTEXITCODE -ne 0) {
                Abort "go build failed for $Platform"
            }
        } finally {
            Pop-Location
        }
    }

    Remove-Item -Path $payloadTarget -Force -ErrorAction SilentlyContinue
}

function Create-Checksums($TargetDir) {
    $checksumFile = Join-Path $TargetDir 'SHA256SUMS'
    if (Test-Path $checksumFile) {
        Remove-Item $checksumFile -Force
    }
    $entries = Get-ChildItem -Path $TargetDir -Filter 'enigma-installer-*'
    foreach ($entry in $entries) {
        if ($entry.PSIsContainer) { continue }
        $hash = Get-FileHash -Path $entry.FullName -Algorithm SHA256
        "$($hash.Hash.ToLower())  $($entry.Name)" | Add-Content -Path $checksumFile -Encoding UTF8
    }
}

if (-not $TargetPlatforms -or $TargetPlatforms.Count -eq 0) {
    if ($env:TARGET_PLATFORMS) {
        $TargetPlatforms = $env:TARGET_PLATFORMS -split '\s+'
    } else {
        $TargetPlatforms = @('windows/amd64')
    }
}

if (-not $NodeVersion) {
    if ($env:NODE_VERSION) {
        $NodeVersion = $env:NODE_VERSION
    } else {
        $NodeVersion = '22.2.0'
    }
}

$skipCompletedValue = if ($PSBoundParameters.ContainsKey('SkipCompleted')) { [bool]$SkipCompleted } elseif ($env:SKIP_COMPLETED) { [int]$env:SKIP_COMPLETED -ne 0 } else { $true }
$forceRebuildValue = if ($PSBoundParameters.ContainsKey('ForceRebuild')) { [bool]$ForceRebuild } elseif ($env:FORCE_REBUILD) { [int]$env:FORCE_REBUILD -ne 0 } else { $false }

$rootDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$distRoot = Join-Path $rootDir 'dist'
$cacheDir = if ($env:DIST_CACHE) { $env:DIST_CACHE } else { Join-Path $rootDir '.cache\build' }
$workRoot = Join-Path $rootDir '.tmp\build'
$ldFlagsBase = '-s -w'

Ensure-Command 'git'
Ensure-Command 'go'
Ensure-Command 'tar'
Ensure-Command 'robocopy'
Ensure-Command 'Expand-Archive'
Ensure-Command 'Invoke-WebRequest'

New-Item -ItemType Directory -Force -Path $distRoot | Out-Null
New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null

if (Test-Path $workRoot) {
    Remove-Item -Path $workRoot -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $workRoot | Out-Null

$buildDate = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
try {
    $versionLabel = (git describe --exact-match --tags).Trim()
} catch {
    $branch = (git rev-parse --abbrev-ref HEAD).Trim()
    $commit = (git rev-parse --short HEAD).Trim()
    $versionLabel = "$branch-$commit"
}
$gitCommit = (git rev-parse --short HEAD).Trim()
$goBin = (Get-Command go).Source

foreach ($platform in $TargetPlatforms) {
    if ($platform -notmatch '^windows/') {
        Write-Warn "Platform $platform is not currently supported by the PowerShell builder; skipping"
        continue
    }

    Write-Step "Preparing payload for $platform"
    $outputName = Installer-Filename $platform
    $finalArtifact = Join-Path $distRoot $outputName

    if (-not $forceRebuildValue -and $skipCompletedValue -and (Test-Path $finalArtifact)) {
        Write-Info "Skipping $platform; $outputName already exists"
        continue
    }

    $stageDir = Join-Path $workRoot ("release-$($platform -replace '/', '-')")
    if (Test-Path $stageDir) {
        Remove-Item -Path $stageDir -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $stageDir | Out-Null

    Copy-ProjectSources -RootDir $rootDir -StageDir $stageDir
    Sanitize-PackageJson -PackagePath (Join-Path $stageDir 'package.json')

    $tarball = Download-NodeRuntime -NodeVersion $NodeVersion -CacheDir $cacheDir -Platform $platform
    $runtimeDir = Join-Path $stageDir 'runtime'
    Expand-Zip -ArchivePath $tarball -Destination $runtimeDir

    Run-NpmCiWindows -Platform $platform -StageDir $stageDir -NodeVersion $NodeVersion -CacheDir $cacheDir

    $payloadName = "release-data-$($platform -replace '/', '-')"
    $payload = Join-Path $workRoot ($payloadName + '.tar.gz')
    Create-ReleaseArchive -StageDir $stageDir -OutFile $payload
    Build-InstallerBinary -Platform $platform -Payload $payload -RootDir $rootDir -DistRoot $distRoot -GoBin $goBin -LdFlagsBase $ldFlagsBase -VersionLabel $versionLabel -BuildDate $buildDate -GitCommit $gitCommit
}

Create-Checksums -TargetDir $distRoot
Write-Info "Installers ready in $distRoot"
