param(
    [Parameter(Mandatory = $false, Position = 0)]
    [string[]]$TargetPlatforms,
    [Parameter(Mandatory = $false)]
    [string]$NodeVersion,
    [switch]$ForceRebuild,
    [switch]$SkipCompleted
)

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$buildScript = Join-Path -Path $scriptDir -ChildPath 'scripts/build/build-dist.ps1'

if (-not (Test-Path $buildScript)) {
    throw "Unable to locate build script at $buildScript"
}

& $buildScript @PSBoundParameters
