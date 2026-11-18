<#
.SYNOPSIS
Creates the tag and GitHub release for one published library. Safe to re-run.

.DESCRIPTION
1. Optionally waits until the artifact is visible on Maven Central.
2. Creates <artifactId>-<version> at -Commit, or verifies an existing tag points at -Commit.
3. Creates the GitHub release if it does not exist. An existing release is left unchanged.
Uses the gh CLI. Set GH_TOKEN to a token with contents: write on the repository.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$GitHubRepo,
    [Parameter(Mandatory)][string]$GroupId,
    [Parameter(Mandatory)][string]$ArtifactId,
    [Parameter(Mandatory)][string]$Version,
    [Parameter(Mandatory)][string]$Commit,
    [Parameter(Mandatory)][string]$NotesFile,
    [bool]$MakeLatest = $true,
    [int]$WaitForCentralMinutes = 0,
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ReleaseTools.psm1') -Force

function Invoke-GhJson {
    param([string[]]$GhArgs, [switch]$AllowNotFound)
    $out = & gh api @GhArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        if ($AllowNotFound -and ($out -join ' ') -match 'HTTP 404|Not Found') { return $null }
        throw "gh api $($GhArgs -join ' ') failed. $out"
    }
    ($out -join "`n") | ConvertFrom-Json
}

$tag = Get-CanonicalTag -ArtifactId $ArtifactId -Version $Version
$title = "$ArtifactId $Version"
if ($Commit -notmatch '^[0-9a-f]{40}$') { throw "-Commit must be a full SHA. Got '$Commit'." }

$pomUrl = "https://repo1.maven.org/maven2/$($GroupId.Replace('.', '/'))/$ArtifactId/$Version/$ArtifactId-$Version.pom"
$deadline = (Get-Date).AddMinutes($WaitForCentralMinutes)
while ($true) {
    try { Invoke-WebRequest -Uri $pomUrl -Method Head -UseBasicParsing | Out-Null; Write-Host "On Maven Central: $pomUrl"; break }
    catch {
        if ((Get-Date) -ge $deadline) {
            if ($DryRun) { Write-Warning "Not on Maven Central yet: $pomUrl"; break }
            throw "Not on Maven Central after $WaitForCentralMinutes minutes: $pomUrl"
        }
        Start-Sleep -Seconds 60
    }
}

$ref = Invoke-GhJson -GhArgs @("repos/$GitHubRepo/git/ref/tags/$tag") -AllowNotFound
if ($ref) {
    $target = $ref.object.sha
    if ($ref.object.type -eq 'tag') { $target = (Invoke-GhJson -GhArgs @("repos/$GitHubRepo/git/tags/$target")).object.sha }
    if ($target -ne $Commit) { throw "Tag $tag already points at $target, not $Commit. Tags are never moved. Investigate before re-running." }
    Write-Host "Tag $tag already at $Commit."
}
elseif ($DryRun) { Write-Host "[dry run] Would create tag $tag at $Commit." }
else {
    $tagObject = Invoke-GhJson -GhArgs @("repos/$GitHubRepo/git/tags", '-f', "tag=$tag", '-f', "message=$title", '-f', "object=$Commit", '-f', 'type=commit')
    Invoke-GhJson -GhArgs @("repos/$GitHubRepo/git/refs", '-f', "ref=refs/tags/$tag", '-f', "sha=$($tagObject.sha)") | Out-Null
    Write-Host "Created tag $tag at $Commit."
}

$release = Invoke-GhJson -GhArgs @("repos/$GitHubRepo/releases/tags/$tag") -AllowNotFound
if ($release) { Write-Host "Release already exists: $($release.html_url)"; return }

$latest = if ($MakeLatest) { 'true' } else { 'false' }
if ($DryRun) {
    Write-Host "[dry run] Would create release '$title' on $GitHubRepo (make_latest=$latest) with notes:"
    Get-Content $NotesFile -Raw | Write-Host
    return
}
$created = Invoke-GhJson -GhArgs @("repos/$GitHubRepo/releases", '-f', "tag_name=$tag", '-f', "name=$title", '-F', "body=@$NotesFile", '-f', "make_latest=$latest")
Write-Host "Created release: $($created.html_url)"
