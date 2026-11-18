<#
.SYNOPSIS
Adds the files Maven Central requires for each library drop and copies them to a flat publish folder.

.DESCRIPTION
For each drop folder under -DropRoot (one per library id), writes <OutputRoot>/<id>/ and signs every pom and jar with GPG (.asc) and
writes .md5 and .sha1. Run this after ESRP jar signing, because GPG must sign the final bytes.
With -VerifyJarSignature, fails when a jar is not signed, so a skipped ESRP step cannot go unnoticed.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$DropRoot,
    [Parameter(Mandatory)][string]$OutputRoot,
    [Parameter(Mandatory)][string]$GpgKeyFile,
    [string]$GpgPassphrase = $env:GPG_PASSPHRASE,
    [switch]$VerifyJarSignature
)
$ErrorActionPreference = 'Stop'

$gnupgHome = Join-Path ([System.IO.Path]::GetTempPath()) "gnupg-$([guid]::NewGuid().ToString('n'))"
New-Item -ItemType Directory -Path $gnupgHome -Force | Out-Null
$env:GNUPGHOME = $gnupgHome
try {
    & gpg --batch --import $GpgKeyFile 2>&1 | Write-Host
    if ($LASTEXITCODE -ne 0) { throw 'gpg import failed.' }

    foreach ($drop in Get-ChildItem $DropRoot -Directory) {
        $manifestPath = Join-Path $drop.FullName 'release.json'
        if (-not (Test-Path $manifestPath)) { continue }
        $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
        $target = Join-Path $OutputRoot $drop.Name
        New-Item -ItemType Directory -Path $target -Force | Out-Null

        $artifacts = Get-ChildItem $drop.FullName -File | Where-Object { $_.Extension -in '.jar', '.pom' }
        foreach ($file in $artifacts) {
            if ($VerifyJarSignature -and $file.Extension -eq '.jar') {
                $verify = & jarsigner -verify $file.FullName 2>&1
                if ($LASTEXITCODE -ne 0 -or ($verify -join ' ') -notmatch 'jar verified') { throw "$($file.Name) is not jar signed. $verify" }
            }
            $dest = Join-Path $target $file.Name
            Copy-Item $file.FullName $dest -Force
            $gpgArgs = @('--batch', '--yes', '--pinentry-mode', 'loopback', '--armor', '--detach-sign', '--output', "$dest.asc")
            if ($GpgPassphrase) { $gpgArgs += @('--passphrase', $GpgPassphrase) }
            & gpg @gpgArgs $dest
            if ($LASTEXITCODE -ne 0) { throw "gpg sign failed for $($file.Name)." }
            & gpg --batch --verify "$dest.asc" $dest 2>$null
            if ($LASTEXITCODE -ne 0) { throw "gpg verify failed for $($file.Name)." }
            foreach ($algorithm in 'MD5', 'SHA1') {
                (Get-FileHash $dest -Algorithm $algorithm).Hash.ToLowerInvariant() |
                    Set-Content "$dest.$($algorithm.ToLowerInvariant())" -NoNewline -Encoding ascii
            }
        }
        Write-Host "$($manifest.artifactId) $($manifest.version): $((Get-ChildItem $target).Count) files ready."
    }
}
finally {
    & gpgconf --kill gpg-agent 2>$null
    Remove-Item $gnupgHome -Recurse -Force -ErrorAction SilentlyContinue
}
