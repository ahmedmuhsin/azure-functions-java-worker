<#
.SYNOPSIS
One time bootstrap. Tags already published versions that have no canonical <artifactId>-<x.y.z> tag.

.DESCRIPTION
For each version, finds the first-parent commit that set the module pom to that version and proposes
the canonical tag. Nothing is pushed unless -Push is given. Review the proposed commits first, because
the commit that bumped the version is not always the commit that was built and published.
Use -Commit to override the detected commit for a single version.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepoPath,
    [Parameter(Mandatory)][string]$ArtifactId,
    [Parameter(Mandatory)][string[]]$Versions,
    [string]$ModulePath = '.',
    [string]$Ref = 'origin/dev',
    [string]$Commit,
    [switch]$Push
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ReleaseTools.psm1') -Force

if ($Commit -and $Versions.Count -ne 1) { throw '-Commit can only be used with a single version.' }
$pom = if ($ModulePath -eq '.') { 'pom.xml' } else { "$ModulePath/pom.xml" }
$existing = @(Invoke-Git $RepoPath tag --list)

foreach ($version in $Versions) {
    $tag = Get-CanonicalTag -ArtifactId $ArtifactId -Version $version
    if ($existing -contains $tag) { Write-Host "$tag already exists. Skipping."; continue }

    $sha = if ($Commit) { (Invoke-Git $RepoPath rev-parse "$Commit^{commit}").Trim() } else { Find-VersionCommit -RepoPath $RepoPath -PomPath $pom -Version $version -Ref $Ref }
    if (-not $sha) { Write-Warning "$tag. No commit on $Ref sets $pom to $version. Pass -Commit."; continue }

    $subject = (Invoke-Git $RepoPath log -1 --format=%s $sha).Trim()
    Write-Host "$tag -> $sha  $subject"
    if ($Push) {
        Invoke-Git $RepoPath tag -a $tag $sha -m "$ArtifactId $version (baseline)" | Out-Null
        Invoke-Git $RepoPath push origin "refs/tags/$tag" | Out-Null
    }
}
if (-not $Push) { Write-Host 'Dry run. Re-run with -Push to create and push these tags.' }
