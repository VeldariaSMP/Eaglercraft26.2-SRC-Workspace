[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitOperatingSystem -or -not [Environment]::Is64BitProcess) {
    throw 'Run this offline test on 64-bit Windows x64 in 64-bit PowerShell.'
}

$scriptDir = $PSScriptRoot
$bootstrapPath = Join-Path $scriptDir 'bootstrap-windows-x86_64.ps1'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('eagler-bootstrap-win-test-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($tempRoot) | Out-Null
$fixtures = Join-Path $tempRoot 'fixtures'
[IO.Directory]::CreateDirectory($fixtures) | Out-Null

function Assert-EaglerTest {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "FAIL: $Message" }
}

function New-TestZip {
    param([string]$Path, [string]$RootName, [hashtable]$Files)
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Create, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $zip = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create, $false)
    try {
        foreach ($relative in $Files.Keys) {
            $entry = $zip.CreateEntry(($RootName + '/' + $relative))
            $writer = [IO.StreamWriter]::new($entry.Open(), [Text.UTF8Encoding]::new($false))
            try { $writer.Write([string]$Files[$relative]) } finally { $writer.Dispose() }
        }
    } finally {
        $zip.Dispose()
        $stream.Dispose()
    }
}

function Get-TestHash {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Write-TestVendorData {
    param([string]$Root, [bool]$Traversal = $false)
    $j17Name = 'OpenJDK17U-jdk_x64_windows_hotspot_17.0.20.1_1.zip'
    $j25Name = 'OpenJDK25U-jdk_x64_windows_hotspot_25.0.4.1_1.zip'
    $nodeName = 'node-v24.21.0-win-x64.zip'
    $j17Path = Join-Path $Root $j17Name
    $j25Path = Join-Path $Root $j25Name
    $nodePath = Join-Path $Root $nodeName
    New-TestZip -Path $j17Path -RootName 'jdk-17.0.20.1+1' -Files @{
        'bin/java.exe' = 'fixture-java-17'
        'bin/javac.exe' = 'fixture-javac-17'
    }
    New-TestZip -Path $j25Path -RootName 'jdk-25.0.4.1+1' -Files @{
        'bin/java.exe' = 'fixture-java-25'
        'bin/javac.exe' = 'fixture-javac-25'
    }
    if ($Traversal) {
        Add-Type -AssemblyName System.IO.Compression
        $stream = [IO.File]::Open($nodePath, [IO.FileMode]::Create, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        $zip = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create, $false)
        try {
            $entry = $zip.CreateEntry('node-v24.21.0-win-x64/../../../../escape.txt')
            $writer = [IO.StreamWriter]::new($entry.Open())
            try { $writer.Write('should never escape') } finally { $writer.Dispose() }
            $entry = $zip.CreateEntry('node-v24.21.0-win-x64/node.exe')
            $writer = [IO.StreamWriter]::new($entry.Open())
            try { $writer.Write('fixture-node-24') } finally { $writer.Dispose() }
        } finally { $zip.Dispose(); $stream.Dispose() }
    } else {
        New-TestZip -Path $nodePath -RootName 'node-v24.21.0-win-x64' -Files @{
            'node.exe' = 'fixture-node-24'
            'node_modules/npm/bin/npm-cli.js' = 'fixture-npm-cli'
        }
    }

    $sha17 = Get-TestHash $j17Path
    $sha25 = Get-TestHash $j25Path
    $shaNode = Get-TestHash $nodePath
    $releaseRoot17 = 'https://github.com/adoptium/temurin17-binaries/releases/download/jdk-17.0.20.1%2B1/'
    $releaseRoot25 = 'https://github.com/adoptium/temurin25-binaries/releases/download/jdk-25.0.4.1%2B1/'
    $entry17 = [PSCustomObject]@{
        vendor = 'eclipse'; version = [PSCustomObject]@{ openjdk_version = '17.0.20.1+1'; semver = '17.0.20+101' }; release_name = 'jdk-17.0.20.1+1'
        binary = [PSCustomObject]@{
            architecture = 'x64'; image_type = 'jdk'; jvm_impl = 'hotspot'; os = 'windows'
            package = [PSCustomObject]@{
                checksum = $sha17; checksum_link = ($releaseRoot17 + $j17Name + '.sha256.txt')
                link = ($releaseRoot17 + $j17Name); name = $j17Name
            }
        }
    }
    $entry25 = [PSCustomObject]@{
        vendor = 'eclipse'; version = [PSCustomObject]@{ openjdk_version = '25.0.4.1+1-LTS'; semver = '25.0.4+101.0.LTS' }; release_name = 'jdk-25.0.4.1+1'
        binary = [PSCustomObject]@{
            architecture = 'x64'; image_type = 'jdk'; jvm_impl = 'hotspot'; os = 'windows'
            package = [PSCustomObject]@{
                checksum = $sha25; checksum_link = ($releaseRoot25 + $j25Name + '.sha256.txt')
                link = ($releaseRoot25 + $j25Name); name = $j25Name
            }
        }
    }
    [IO.File]::WriteAllText((Join-Path $Root 'java17.json'), (ConvertTo-Json -InputObject @($entry17) -Depth 8))
    [IO.File]::WriteAllText((Join-Path $Root 'java25.json'), (ConvertTo-Json -InputObject @($entry25) -Depth 8))
    [IO.File]::WriteAllText((Join-Path $Root 'node-index.json'), (ConvertTo-Json -InputObject @([PSCustomObject]@{
        version = 'v24.21.0'; date = '2026-09-07'; files = @('win-x64-zip'); npm = '11.19.0'; lts = 'Krypton'
    }) -Depth 4))
    [IO.File]::WriteAllText((Join-Path $Root ($j17Name + '.sha256.txt')), "$sha17  $j17Name`n")
    [IO.File]::WriteAllText((Join-Path $Root ($j25Name + '.sha256.txt')), "$sha25  $j25Name`n")
    [IO.File]::WriteAllText((Join-Path $Root 'node-SHASUMS256.txt'), "$shaNode  $nodeName`n")
}

. $bootstrapPath

function Invoke-EaglerHttpsDownload {
    param([string]$Url, [string]$Destination)
    $source = $null
    switch -Regex ($Url) {
        '^https://api\.adoptium\.net/.*/17/' { $source = Join-Path $script:MockFixtureRoot 'java17.json'; break }
        '^https://api\.adoptium\.net/.*/25/' { $source = Join-Path $script:MockFixtureRoot 'java25.json'; break }
        '^https://nodejs\.org/dist/index\.json$' { $source = Join-Path $script:MockFixtureRoot 'node-index.json'; break }
        'temurin17-binaries/releases/download/.+\.zip\.sha256\.txt$' { $source = Join-Path $script:MockFixtureRoot ([IO.Path]::GetFileName($Url)); break }
        'temurin25-binaries/releases/download/.+\.zip\.sha256\.txt$' { $source = Join-Path $script:MockFixtureRoot ([IO.Path]::GetFileName($Url)); break }
        'nodejs\.org/dist/v24\.21\.0/SHASUMS256\.txt$' { $source = Join-Path $script:MockFixtureRoot 'node-SHASUMS256.txt'; break }
        'temurin17-binaries/releases/download/.+\.zip$' { $source = Join-Path $script:MockFixtureRoot ([IO.Path]::GetFileName($Url)); break }
        'temurin25-binaries/releases/download/.+\.zip$' { $source = Join-Path $script:MockFixtureRoot ([IO.Path]::GetFileName($Url)); break }
        'nodejs\.org/dist/v24\.21\.0/node-v24\.21\.0-win-x64\.zip$' { $source = Join-Path $script:MockFixtureRoot 'node-v24.21.0-win-x64.zip'; break }
        default { throw "Unexpected mocked URL: $Url" }
    }
    if ($script:MockTamperNode -and $Url -match 'node-v24\.21\.0-win-x64\.zip$') {
        [IO.File]::WriteAllText($Destination, 'tampered fixture archive')
        return
    }
    Copy-Item -LiteralPath $source -Destination $Destination -Force
}

function Get-EaglerJavaMajorVersion {
    param([string]$JavaPath)
    $payload = [IO.File]::ReadAllText($JavaPath)
    if ($payload -match 'fixture-java-(17|25)') { return [int]$Matches[1] }
    throw "Unexpected mock Java fixture: $JavaPath"
}

function Get-EaglerNodeVersion {
    param([string]$NodePath)
    if ([IO.File]::ReadAllText($NodePath) -eq 'fixture-node-24') { return 'v24.21.0' }
    throw "Unexpected mock Node fixture: $NodePath"
}

function Test-EaglerNpmCli {
    param([string]$NodePath, [string]$NpmPath)
    return (([IO.File]::ReadAllText($NodePath) -eq 'fixture-node-24') -and
        ([IO.File]::ReadAllText($NpmPath) -eq 'fixture-npm-cli'))
}

try {
    $script:MockFixtureRoot = $fixtures
    $script:MockTamperNode = $false
    Write-TestVendorData -Root $fixtures
    $app = Join-Path $tempRoot 'app = with space'

    $lockPath = Join-Path (Join-Path $tempRoot 'lock-test') '.bootstrap.lock'
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($lockPath)) | Out-Null
    $firstLock = Open-EaglerBootstrapLock -LockPath $lockPath -TimeoutSeconds 0
    $lockRejected = $false
    try {
        try { $secondLock = Open-EaglerBootstrapLock -LockPath $lockPath -TimeoutSeconds 0; $secondLock.Dispose() }
        catch { $lockRejected = $true }
    } finally { $firstLock.Dispose() }
    Assert-EaglerTest $lockRejected 'exclusive lock allowed a second writer'

    $manifestPath = Invoke-EaglerWindowsBootstrap -ApplicationDirectory $app
    Assert-EaglerTest (Test-Path -LiteralPath $manifestPath -PathType Leaf) 'toolchain.properties was not published'
    $manifest = Get-EaglerManifest $manifestPath
    Assert-EaglerTest ($manifest['platform'] -eq 'windows-x86_64') 'platform identity is missing'
    $emptyManifestPath = Join-Path $tempRoot 'empty-tool-path.properties'
    [IO.File]::WriteAllText($emptyManifestPath, "format=1`nplatform=windows-x86_64`njava17=`n")
    Assert-EaglerTest (-not (Test-EaglerManifestUsable -ManifestPath $emptyManifestPath -ToolRoot (Join-Path $app '.toolchain'))) 'empty cached tool path was accepted or aborted recovery'
    foreach ($key in @('java17', 'java25', 'node', 'npm')) {
        Assert-EaglerTest ($manifest.ContainsKey($key)) "manifest key $key is missing"
        Assert-EaglerTest (Test-EaglerPathUnder -Path $manifest[$key] -Root (Join-Path $app '.toolchain')) "$key did not remain app-local"
    }
    Assert-EaglerTest ($manifest['npm'].EndsWith('/node_modules/npm/bin/npm-cli.js')) 'npm did not point to npm-cli.js'
    Assert-EaglerTest (([IO.File]::ReadAllBytes($manifestPath)[0] -ne 0xEF)) 'manifest unexpectedly has a UTF-8 BOM'
    $stageResidue = @(Get-ChildItem -LiteralPath (Join-Path $app '.toolchain') -Directory -Filter '.bootstrap.*')
    Assert-EaglerTest ($stageResidue.Count -eq 0) 'successful install left a staging directory'

    $notLtsFixtures = Join-Path $tempRoot 'not-lts-fixtures'
    [IO.Directory]::CreateDirectory($notLtsFixtures) | Out-Null
    [IO.File]::WriteAllText((Join-Path $notLtsFixtures 'node-index.json'), '[{"version":"v24.21.0","files":["win-x64-zip"],"npm":"11.19.0","lts":false}]')
    $script:MockFixtureRoot = $notLtsFixtures
    $notLtsRejected = $false
    try { Get-EaglerNodeRelease -StageDirectory $tempRoot | Out-Null }
    catch { $notLtsRejected = $_.Exception.Message -match 'did not list a stable Node.js 24 LTS' }
    Assert-EaglerTest $notLtsRejected 'Node release with lts:false was accepted'
    $script:MockFixtureRoot = $fixtures

    $replaceApp = Join-Path $tempRoot 'manifest-replace'
    [IO.Directory]::CreateDirectory($replaceApp) | Out-Null
    [IO.File]::WriteAllText((Join-Path $replaceApp 'toolchain.properties'), 'old=contents')
    Publish-EaglerManifest -AppDirectory $replaceApp -Content "new=contents`n"
    Assert-EaglerTest ([IO.File]::ReadAllText((Join-Path $replaceApp 'toolchain.properties')) -eq "new=contents`n") 'manifest replacement was not atomic or complete'
    Assert-EaglerTest (@(Get-ChildItem -LiteralPath $replaceApp -Filter '.toolchain.properties.tmp.*').Count -eq 0) 'manifest replacement left a temporary file'

    $originalDownloader = (Get-Command Invoke-EaglerHttpsDownload -CommandType Function).ScriptBlock
    function Invoke-EaglerHttpsDownload {
        param([string]$Url, [string]$Destination)
        $script:MockDownloadCount++
        & $script:OriginalDownloader $Url $Destination
    }
    $script:OriginalDownloader = $originalDownloader
    $script:MockDownloadCount = 0
    Invoke-EaglerWindowsBootstrap -ApplicationDirectory $app | Out-Null
    Assert-EaglerTest ($script:MockDownloadCount -eq 0) 'valid cached tools triggered additional downloads'

    $badApp = Join-Path $tempRoot 'tampered-app'
    $script:MockTamperNode = $true
    $tamperRejected = $false
    try { Invoke-EaglerWindowsBootstrap -ApplicationDirectory $badApp | Out-Null }
    catch { $tamperRejected = $_.Exception.Message -match 'SHA-256 mismatch' }
    $script:MockTamperNode = $false
    Assert-EaglerTest $tamperRejected 'tampered archive was accepted'
    Assert-EaglerTest (-not (Test-Path -LiteralPath (Join-Path $badApp 'toolchain.properties'))) 'checksum failure published a manifest'
    Assert-EaglerTest (@(Get-ChildItem -LiteralPath (Join-Path $badApp '.toolchain') -Directory -Filter '.bootstrap.*' -ErrorAction SilentlyContinue).Count -eq 0) 'checksum failure left staging files'

    $traversalFixtures = Join-Path $tempRoot 'traversal-fixtures'
    [IO.Directory]::CreateDirectory($traversalFixtures) | Out-Null
    Write-TestVendorData -Root $traversalFixtures -Traversal $true
    $script:MockFixtureRoot = $traversalFixtures
    $traversalApp = Join-Path $tempRoot 'traversal-app'
    $traversalRejected = $false
    try { Invoke-EaglerWindowsBootstrap -ApplicationDirectory $traversalApp | Out-Null }
    catch { $traversalRejected = $_.Exception.Message -match 'Unsafe path component|ZIP entry escaped' }
    Assert-EaglerTest $traversalRejected 'ZIP path traversal was accepted'
    Assert-EaglerTest (-not (Test-Path -LiteralPath (Join-Path $traversalApp 'escape.txt'))) 'ZIP entry escaped the application tool directory'
    Assert-EaglerTest (-not (Test-Path -LiteralPath (Join-Path $traversalApp 'toolchain.properties'))) 'unsafe ZIP published a manifest'
    Assert-EaglerTest (@(Get-ChildItem -LiteralPath (Join-Path $traversalApp '.toolchain') -Directory -Filter '.bootstrap.*' -ErrorAction SilentlyContinue).Count -eq 0) 'unsafe ZIP failure left staging files'

    Write-Host 'PASS: mocked Adoptium/Node metadata, SHA-256 checks, safe ZIP extraction, app-local manifest, cache reuse, and exclusive lock.'
} finally {
    Remove-Item Function:\Invoke-EaglerHttpsDownload -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
