Set-StrictMode -Version Latest

function ConvertTo-ReleaseVersion {
    param([Parameter(Mandatory)][string]$Value)
    if ($Value -match '^\d+\.\d+\.\d+$') { return [version]$Value }
    return $null
}

function Get-CanonicalTag {
    param([Parameter(Mandatory)][string]$ArtifactId, [Parameter(Mandatory)][string]$Version)
    "$ArtifactId-$Version"
}

function Invoke-Git {
    param([Parameter(Mandatory)][string]$RepoPath, [Parameter(Mandatory, ValueFromRemainingArguments)][string[]]$GitArgs)
    $output = & git -C $RepoPath @GitArgs
    if ($LASTEXITCODE -ne 0) { throw "git $($GitArgs -join ' ') failed with exit code $LASTEXITCODE" }
    $output
}

# Returns the newest release tag for the artifact that is older than $Version.
# Canonical tags are <artifactId>-<x.y.z>. $LegacyTagPattern is a regex with one capture group for
# the version, used only to read older tags that predate the canonical format. Tags are never moved.
function Get-PreviousReleaseTag {
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$ArtifactId,
        [Parameter(Mandatory)][string]$Version,
        [string]$LegacyTagPattern
    )
    $current = ConvertTo-ReleaseVersion $Version
    if (-not $current) { throw "Version '$Version' must be x.y.z." }

    $canonical = '^' + [regex]::Escape($ArtifactId) + '-(\d+\.\d+\.\d+)$'
    $candidates = foreach ($tag in @(Invoke-Git $RepoPath tag --list)) {
        foreach ($pattern in @($canonical, $LegacyTagPattern)) {
            if ($pattern -and $tag -match $pattern) {
                $v = ConvertTo-ReleaseVersion $Matches[1]
                if ($v -and $v -lt $current) {
                    [pscustomobject]@{ Tag = $tag; Version = $v; Canonical = ($pattern -eq $canonical) }
                }
                break
            }
        }
    }
    # Prefer the canonical tag when a version has both.
    $candidates | Sort-Object -Property @{ Expression = 'Version'; Descending = $true }, @{ Expression = 'Canonical'; Descending = $true } |
        Select-Object -First 1
}

# Finds the first-parent commit that set the module pom version to $Version.
# Used only to bootstrap tags for versions that were published without one.
function Find-VersionCommit {
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$PomPath,
        [Parameter(Mandatory)][string]$Version,
        [string]$Ref = 'HEAD'
    )
    $needle = "<version>$Version</version>"
    $commits = @(Invoke-Git $RepoPath log $Ref --first-parent --format=%H -S $needle -- $PomPath)
    foreach ($sha in $commits) {
        $pom = Invoke-Git $RepoPath show "${sha}:$PomPath"
        [xml]$xml = $pom -join "`n"
        if ($xml.project.version -eq $Version) { return $sha }
    }
    $null
}

# Release versions the module pom held between two refs, other than the one being released.
# Each one was most likely published without a tag, so notes from $FromRef would span two releases.
function Find-UntaggedVersion {
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$PomPath,
        [Parameter(Mandatory)][string]$FromRef,
        [Parameter(Mandatory)][string]$ToRef,
        [Parameter(Mandatory)][version]$FromVersion,
        [Parameter(Mandatory)][version]$Version
    )
    $found = foreach ($sha in @(Invoke-Git $RepoPath log "$FromRef..$ToRef" --first-parent --format=%H -- $PomPath)) {
        $content = & git -C $RepoPath show "${sha}:$PomPath" 2>$null
        if ($LASTEXITCODE -ne 0) { continue }
        $v = ConvertTo-ReleaseVersion ([xml]($content -join "`n")).project.version
        if ($v -and $v -gt $FromVersion -and $v -lt $Version) { $v }
    }
    @($found | Sort-Object -Unique)
}

function Get-ReleaseChange {
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$FromRef,
        [Parameter(Mandatory)][string]$ToRef,
        [Parameter(Mandatory)][string[]]$Paths
    )
    $us = [char]0x1f
    $records = @(Invoke-Git $RepoPath log "$FromRef..$ToRef" --first-parent --reverse '--format=%H%x1f%s%x1f%b%x1f%an%x1e' -- @Paths)
    foreach ($record in (($records -join "`n") -split [char]0x1e)) {
        $record = $record.Trim()
        if (-not $record) { continue }
        $sha, $subject, $body, $author = $record -split $us
        $pr = $null
        $title = $subject.Trim()
        if ($title -match '^Merge pull request #(\d+) from ') {
            $pr = [int]$Matches[1]
            $firstBodyLine = $body -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 1
            if ($firstBodyLine) { $title = $firstBodyLine.Trim() }
        }
        elseif ($title -match '^(.*?)\s*\(#(\d+)\)$') {
            $title = $Matches[1]
            $pr = [int]$Matches[2]
        }
        [pscustomobject]@{ Sha = $sha; Title = $title; PullRequest = $pr; Author = "$author".Trim() }
    }
}

function Format-ReleaseNotes {
    param(
        [Parameter(Mandatory)][string]$GitHubRepo,
        [Parameter(Mandatory)][string]$GroupId,
        [Parameter(Mandatory)][string]$ArtifactId,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$Commit,
        [string]$PreviousTag,
        [string[]]$Paths,
        [object[]]$Changes,
        [string]$Highlights
    )
    $lines = [System.Collections.Generic.List[string]]::new()
    if ($Highlights) { $lines.Add($Highlights.Trim()); $lines.Add('') }

    $lines.Add("## What's changed")
    if ($Changes) {
        foreach ($c in $Changes) {
            $ref = if ($c.PullRequest) { "#$($c.PullRequest)" } else { $c.Sha.Substring(0, 7) }
            $lines.Add("- $($c.Title) ($ref)")
        }
    }
    else {
        $lines.Add('- No source changes in this module since the previous release.')
    }
    $lines.Add('')
    $lines.Add('## Maven')
    $lines.Add('```xml')
    $lines.Add('<dependency>')
    $lines.Add("  <groupId>$GroupId</groupId>")
    $lines.Add("  <artifactId>$ArtifactId</artifactId>")
    $lines.Add("  <version>$Version</version>")
    $lines.Add('</dependency>')
    $lines.Add('```')

    if ($PreviousTag) {
        $lines.Add('')
        $lines.Add("**Full changelog**: https://github.com/$GitHubRepo/compare/$PreviousTag...$Commit")
        if ($Paths -and ($Paths -notcontains '.')) {
            $lines.Add('')
            $lines.Add('This repository holds several libraries. The list above only includes changes under ' + (($Paths | ForEach-Object { "``$_``" }) -join ', ') + '.')
        }
    }
    ($lines -join "`n") + "`n"
}

Export-ModuleMember -Function ConvertTo-ReleaseVersion, Get-CanonicalTag, Invoke-Git, Get-PreviousReleaseTag, Find-VersionCommit, Find-UntaggedVersion, Get-ReleaseChange, Format-ReleaseNotes
