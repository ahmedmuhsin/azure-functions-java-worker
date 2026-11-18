<#
.SYNOPSIS
Collects the Maven files for one library into a flat drop folder with a release manifest.

.DESCRIPTION
The drop holds <artifactId>-<version>.pom, .jar, -sources.jar, -javadoc.jar, release.json and
release-notes.md. Signing and publishing stages only read this folder.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepoPath,
    [Parameter(Mandatory)][string]$GitHubRepo,
    [Parameter(Mandatory)][string]$GroupId,
    [Parameter(Mandatory)][string]$ArtifactId,
    [Parameter(Mandatory)][string]$Version,
    [Parameter(Mandatory)][string]$OutputPath,
    [string]$ModulePath = '.',
    [string]$NotesFile,
    [bool]$MakeLatest = $true
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ReleaseTools.psm1') -Force

$module = Join-Path $RepoPath $ModulePath
$pomPath = Join-Path $module 'pom.xml'
$pom = [xml]::new()
$pom.PreserveWhitespace = $true
$pom.Load($pomPath)
$pomGroup = if ($pom.project.groupId) { $pom.project.groupId } else { $pom.project.parent.groupId }
if ($pom.project.artifactId -ne $ArtifactId -or $pomGroup -ne $GroupId -or $pom.project.version -ne $Version) {
    throw "pom is ${pomGroup}:$($pom.project.artifactId):$($pom.project.version). Expected ${GroupId}:${ArtifactId}:${Version}."
}

# Builds resolve through the internal CFS feed. Consumers cannot reach it, so the published pom drops those repositories.
$internal = "//*[(local-name()='repository' or local-name()='pluginRepository') and *[local-name()='url' and contains(., 'pkgs.dev.azure.com')]]"
foreach ($node in @($pom.SelectNodes($internal))) {
    $container = $node.ParentNode
    [void]$container.RemoveChild($node)
    if (-not $container.SelectSingleNode('*')) { [void]$container.ParentNode.RemoveChild($container) }
}
if ($pom.OuterXml -match 'pkgs\.dev\.azure\.com') { throw 'pom still references an internal feed after cleanup.' }

$base = "$ArtifactId-$Version"
$files = @{
    "$base.jar"         = Join-Path $module "target/$base.jar"
    "$base-sources.jar" = Join-Path $module "target/$base-sources.jar"
    "$base-javadoc.jar" = Join-Path $module "target/$base-javadoc.jar"
}
$missing = @($files.Values | Where-Object { -not (Test-Path $_) })
if ($missing) { throw "Missing build outputs: $($missing -join ', ')" }

New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
foreach ($name in $files.Keys) { Copy-Item $files[$name] (Join-Path $OutputPath $name) -Force }
$pom.Save((Join-Path $OutputPath "$base.pom"))
if ($NotesFile) { Copy-Item $NotesFile (Join-Path $OutputPath 'release-notes.md') -Force }

$commit = (Invoke-Git $RepoPath rev-parse 'HEAD^{commit}').Trim()
[ordered]@{
    gitHubRepo = $GitHubRepo
    groupId    = $GroupId
    artifactId = $ArtifactId
    version    = $Version
    commit     = $commit
    tag        = Get-CanonicalTag -ArtifactId $ArtifactId -Version $Version
    makeLatest = $MakeLatest
} | ConvertTo-Json | Set-Content (Join-Path $OutputPath 'release.json') -Encoding utf8

Get-ChildItem $OutputPath | ForEach-Object { Write-Host "  $($_.Name)  $($_.Length) bytes" }
