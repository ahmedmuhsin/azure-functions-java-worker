<#
.SYNOPSIS
Writes GitHub release notes for one library from the commits that touched its paths.

.DESCRIPTION
The previous release is the newest <artifactId>-<x.y.z> tag below -Version, or a legacy tag matched by
-LegacyTagPattern. If neither exists, run New-BaselineTag.ps1 first or pass -PreviousRef.
Curated highlights in <ModulePath>/release-notes/<Version>.md are placed above the generated list.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepoPath,
    [Parameter(Mandatory)][string]$GitHubRepo,
    [Parameter(Mandatory)][string]$GroupId,
    [Parameter(Mandatory)][string]$ArtifactId,
    [Parameter(Mandatory)][string]$Version,
    [string]$Commit = 'HEAD',
    [string]$ModulePath = '.',
    [string[]]$NotesPaths,
    [string]$LegacyTagPattern,
    [string]$PreviousRef,
    [string]$OutFile
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ReleaseTools.psm1') -Force

if (-not $NotesPaths) { $NotesPaths = @($ModulePath) }
$sha = (Invoke-Git $RepoPath rev-parse "$Commit^{commit}").Trim()

if (-not $PreviousRef) {
    $previous = Get-PreviousReleaseTag -RepoPath $RepoPath -ArtifactId $ArtifactId -Version $Version -LegacyTagPattern $LegacyTagPattern
    if (-not $previous) {
        throw "No previous release tag for $ArtifactId below $Version. Run New-BaselineTag.ps1 for the last published version, or pass -PreviousRef."
    }
    $PreviousRef = $previous.Tag

    # A version published without a tag would make the notes span two releases. Fail instead.
    $pom = if ($ModulePath -eq '.') { 'pom.xml' } else { "$ModulePath/pom.xml" }
    $untagged = Find-UntaggedVersion -RepoPath $RepoPath -PomPath $pom -FromRef $PreviousRef -ToRef $sha `
        -FromVersion $previous.Version -Version (ConvertTo-ReleaseVersion $Version)
    if ($untagged) {
        throw "Version $($untagged -join ', ') was set in $pom after $PreviousRef but has no tag. Run New-BaselineTag.ps1 for it first, or pass -PreviousRef."
    }
}

$highlightsFile = Join-Path $RepoPath (Join-Path $ModulePath "release-notes/$Version.md")
$highlights = if (Test-Path $highlightsFile) { Get-Content $highlightsFile -Raw } else { $null }

$changes = @(Get-ReleaseChange -RepoPath $RepoPath -FromRef $PreviousRef -ToRef $sha -Paths $NotesPaths)
$notes = Format-ReleaseNotes -GitHubRepo $GitHubRepo -GroupId $GroupId -ArtifactId $ArtifactId -Version $Version `
    -Commit $sha -PreviousTag $PreviousRef -Paths $NotesPaths -Changes $changes -Highlights $highlights

Write-Host "Previous release: $PreviousRef. Changes listed: $($changes.Count)."
if ($OutFile) { Set-Content -Path $OutFile -Value $notes -NoNewline -Encoding utf8 } else { $notes }
