[CmdletBinding()]
param(
    [string]$AppDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:EaglerBootstrapRoot = $PSScriptRoot
$script:EaglerBootstrapWasDotSourced = ($MyInvocation.InvocationName -eq '.')

function Write-EaglerStatus {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host $Message
}

function Invoke-EaglerHttpsDownload {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $uri = [Uri]$Url
    if (-not $uri.IsAbsoluteUri -or $uri.Scheme -ne 'https' -or -not [string]::IsNullOrEmpty($uri.UserInfo)) {
        throw "Refusing a non-HTTPS download URL: $Url"
    }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    try {
        $redirects = 0
        while ($true) {
            if ($uri.Scheme -ne 'https' -or -not [string]::IsNullOrEmpty($uri.UserInfo)) {
                throw "Refusing a non-HTTPS or credential-bearing redirect: $uri"
            }
            $request = [Net.HttpWebRequest]::Create($uri)
            $request.Method = 'GET'
            $request.AllowAutoRedirect = $false
            $request.Timeout = 1800000
            $request.ReadWriteTimeout = 1800000
            $request.UserAgent = 'Eaglercraft-26.2-u1-patcher-bootstrap/1'
            $response = $null
            try {
                try {
                    $response = $request.GetResponse()
                } catch [Net.WebException] {
                    if ($null -eq $_.Exception.Response) { throw }
                    $response = $_.Exception.Response
                }
                $statusCode = [int]$response.StatusCode
                if ($statusCode -ge 300 -and $statusCode -lt 400) {
                    $location = $response.Headers['Location']
                    if ([string]::IsNullOrWhiteSpace($location) -or $redirects -ge 8) {
                        throw "Vendor URL returned an invalid or excessive redirect: $uri"
                    }
                    $uri = [Uri]::new($uri, $location)
                    $redirects++
                    continue
                }
                if ($statusCode -ne 200) { throw "Vendor URL returned HTTP $statusCode: $uri" }
                if ($response.ContentLength -gt 1500000000) { throw "Vendor response is larger than the 1.5 GB download limit: $uri" }

                $inputStream = $response.GetResponseStream()
                $outputStream = $null
                try {
                    $outputStream = [IO.File]::Open($Destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                    $buffer = New-Object byte[] 65536
                    [long]$total = 0
                    while (($read = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                        $total += $read
                        if ($total -gt 1500000000) { throw "Vendor response exceeded the 1.5 GB download limit: $uri" }
                        $outputStream.Write($buffer, 0, $read)
                    }
                } finally {
                    $inputStream.Dispose()
                    if ($null -ne $outputStream) { $outputStream.Dispose() }
                }
                return
            } finally {
                if ($null -ne $response) { $response.Dispose() }
            }
        }
    } catch {
        if (Test-Path -LiteralPath $Destination -PathType Leaf) {
            Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        }
        throw
    }
}

function Assert-EaglerWindowsX64 {
    if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitOperatingSystem -or -not [Environment]::Is64BitProcess) {
        throw 'Unsupported platform or architecture. This bootstrap supports 64-bit Windows x64 running 64-bit PowerShell only; ARM64 and 32-bit PowerShell are unsupported. No files were changed.'
    }
    $nativeArchitecture = $env:PROCESSOR_ARCHITEW6432
    if ([string]::IsNullOrWhiteSpace($nativeArchitecture)) { $nativeArchitecture = $env:PROCESSOR_ARCHITECTURE }
    try {
        $machineArchitectures = @(Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Select-Object -ExpandProperty Architecture -Unique)
        if ($machineArchitectures.Count -gt 0) {
            if ($machineArchitectures -contains 12) { $nativeArchitecture = 'ARM64' }
            elseif ($machineArchitectures -contains 9) { $nativeArchitecture = 'AMD64' }
            else { $nativeArchitecture = "WMI-$($machineArchitectures -join ',')" }
        }
    } catch {
        # Keep the architecture reported by the native process environment.
    }
    if ($nativeArchitecture -ne 'AMD64') {
        throw "Unsupported native Windows architecture '$nativeArchitecture'. This bootstrap supports x64 only; ARM64 and other architectures are unsupported. No files were changed."
    }
    if ($PSVersionTable.PSVersion.Major -lt 5 -or
        ($PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -lt 1)) {
        throw 'Windows PowerShell 5.1 or newer is required. No files were changed.'
    }

    $windowsVersion = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $build = 0
    if (-not [int]::TryParse([string]$windowsVersion.CurrentBuildNumber, [ref]$build) -or
        ($build -ne 19045 -and $build -lt 22000) -or
        [string]$windowsVersion.ProductName -match '(?i)server|iot') {
        throw "Unsupported Windows release. Use Windows 10 22H2 (build 19045) or Windows 11 x64; Windows Server and older client releases are unsupported. No files were changed."
    }

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this app-local installer without an elevated Administrator token. It does not need elevation and makes no system changes.'
    }
}

function Get-EaglerFullPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    if ([StringComparer]::OrdinalIgnoreCase.Equals($full, $root)) { return $full }
    return $full.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
}

function Test-EaglerPathUnder {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root
    )
    $fullPath = Get-EaglerFullPath $Path
    $fullRoot = Get-EaglerFullPath $Root
    $prefix = $fullRoot + [IO.Path]::DirectorySeparatorChar
    return $fullPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-EaglerNoReparsePoints {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$StopAt
    )
    $current = Get-EaglerFullPath $Path
    $stop = if ($StopAt) { Get-EaglerFullPath $StopAt } else { $null }
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Refusing to use a managed path containing a junction or symbolic link: $current"
            }
        }
        if ($stop -and [StringComparer]::OrdinalIgnoreCase.Equals($current, $stop)) { break }
        $parent = [IO.Directory]::GetParent($current)
        if ($null -eq $parent) { break }
        $current = $parent.FullName
    }
}

function Assert-EaglerAppDirectory {
    param([Parameter(Mandatory = $true)][string]$Candidate)
    if ($Candidate.StartsWith('\\')) {
        throw 'Choose a local drive directory for this package; network and UNC paths are not supported.'
    }

    $full = Get-EaglerFullPath $Candidate
    if ($full -notmatch '^[A-Za-z]:\\') {
        throw 'The application directory must be on a local drive with a drive-letter path.'
    }
    if ([StringComparer]::OrdinalIgnoreCase.Equals($full, [IO.Path]::GetPathRoot($full))) {
        throw 'Choose a package directory below the drive root.'
    }

    $protected = @(
        $env:windir,
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)},
        $env:ProgramData
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    foreach ($protectedRoot in $protected) {
        $rootPath = Get-EaglerFullPath $protectedRoot
        if ([StringComparer]::OrdinalIgnoreCase.Equals($full, $rootPath) -or
            $full.StartsWith(($rootPath + '\'), [StringComparison]::OrdinalIgnoreCase)) {
            throw "The app-local bootstrap will not write under a protected system directory: $rootPath"
        }
    }

    if (-not (Test-Path -LiteralPath $full -PathType Container)) {
        New-Item -ItemType Directory -Path $full -Force | Out-Null
    }
    Assert-EaglerNoReparsePoints -Path $full

    $probe = Join-Path $full ('.eagler-write-test-' + [Guid]::NewGuid().ToString('N'))
    $stream = $null
    try {
        $stream = [IO.File]::Open($probe, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    } catch {
        throw "The current user cannot write to the application directory: $full"
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
        if (Test-Path -LiteralPath $probe -PathType Leaf) { Remove-Item -LiteralPath $probe -Force }
    }
    return $full
}

function Open-EaglerBootstrapLock {
    param(
        [Parameter(Mandatory = $true)][string]$LockPath,
        [ValidateRange(0, 3600)][int]$TimeoutSeconds = 1800
    )
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        try {
            return [IO.File]::Open($LockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        } catch [IO.IOException] {
            if ($timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                throw "Another bootstrap is holding the app-local toolchain lock: $LockPath"
            }
            Start-Sleep -Milliseconds 500
        }
    }
}

function Get-EaglerManifest {
    param([Parameter(Mandatory = $true)][string]$Path)
    $values = @{}
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $values }
    foreach ($line in [IO.File]::ReadAllLines($Path, [Text.Encoding]::UTF8)) {
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#') -or $line.StartsWith('!')) { continue }
        $split = $line.IndexOf('=')
        if ($split -le 0) { continue }
        $values[$line.Substring(0, $split)] = $line.Substring($split + 1)
    }
    return $values
}

function Invoke-EaglerProcessCapture {
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][string]$Arguments,
        [ValidateRange(1, 300)][int]$TimeoutSeconds = 30
    )
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $Executable
    $startInfo.Arguments = $Arguments
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw "Could not start $Executable" }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill() } catch { }
            throw "Tool version check timed out: $Executable"
        }
        $process.WaitForExit()
        $text = $stdoutTask.Result + "`n" + $stderrTask.Result
        if ($process.ExitCode -ne 0) { throw "Tool validation command failed for $Executable (exit $($process.ExitCode)): $text" }
        return $text.Trim()
    } finally {
        $process.Dispose()
    }
}

function Get-EaglerJavaMajorVersion {
    param([Parameter(Mandatory = $true)][string]$JavaPath)
    $text = Invoke-EaglerProcessCapture -Executable $JavaPath -Arguments '-version'
    if ($text -notmatch '(?im)\bversion\s+"(\d+)') {
        throw "Could not parse the Java version reported by $JavaPath"
    }
    return [int]$Matches[1]
}

function Get-EaglerNodeVersion {
    param([Parameter(Mandatory = $true)][string]$NodePath)
    return (Invoke-EaglerProcessCapture -Executable $NodePath -Arguments '--version').Trim()
}

function Test-EaglerNpmCli {
    param(
        [Parameter(Mandatory = $true)][string]$NodePath,
        [Parameter(Mandatory = $true)][string]$NpmPath
    )
    if (-not (Test-Path -LiteralPath $NpmPath -PathType Leaf)) { return $false }
    $quotedPath = '"' + $NpmPath.Replace('"', '\"') + '"'
    $output = Invoke-EaglerProcessCapture -Executable $NodePath -Arguments ($quotedPath + ' --version')
    return $output -match '^\d+\.\d+\.\d+'
}

function Test-EaglerJdkRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][int]$Major
    )
    $java = Join-Path $Root 'bin\java.exe'
    $javac = Join-Path $Root 'bin\javac.exe'
    if (-not (Test-Path -LiteralPath $java -PathType Leaf) -or -not (Test-Path -LiteralPath $javac -PathType Leaf)) { return $false }
    try { return ((Get-EaglerJavaMajorVersion -JavaPath $java) -eq $Major) } catch { return $false }
}

function Test-EaglerNodeRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$ExpectedVersion
    )
    $node = Join-Path $Root 'node.exe'
    $npm = Join-Path $Root 'node_modules\npm\bin\npm-cli.js'
    if (-not (Test-Path -LiteralPath $node -PathType Leaf) -or -not (Test-Path -LiteralPath $npm -PathType Leaf)) { return $false }
    try {
        return ((Get-EaglerNodeVersion -NodePath $node) -eq $ExpectedVersion -and (Test-EaglerNpmCli -NodePath $node -NpmPath $npm))
    } catch { return $false }
}

function Test-EaglerManifestUsable {
    param(
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)][string]$ToolRoot
    )
    $manifest = Get-EaglerManifest $ManifestPath
    if ($manifest['format'] -ne '1' -or $manifest['platform'] -ne 'windows-x86_64') { return $false }
    foreach ($key in @('java17', 'java25', 'node', 'npm')) {
        if (-not $manifest.ContainsKey($key) -or [string]::IsNullOrWhiteSpace([string]$manifest[$key])) { return $false }
        if (-not (Test-EaglerPathUnder -Path $manifest[$key] -Root $ToolRoot)) { return $false }
        Assert-EaglerNoReparsePoints -Path $manifest[$key] -StopAt $ToolRoot
    }
    $java17 = $manifest['java17']
    $java25 = $manifest['java25']
    $node = $manifest['node']
    $npm = $manifest['npm']
    $nodeVersion = $manifest['node_version']
    if ($nodeVersion -notmatch '^v24\.\d+\.\d+$') { return $false }
    if ([IO.Path]::GetFileName($java17) -ne 'java.exe' -or
        [IO.Path]::GetFileName($java25) -ne 'java.exe' -or
        [IO.Path]::GetFileName($node) -ne 'node.exe' -or
        [IO.Path]::GetFileName($npm) -ne 'npm-cli.js') { return $false }
    $expectedNpm = Join-Path ([IO.Path]::GetDirectoryName($node)) 'node_modules\npm\bin\npm-cli.js'
    if (-not [StringComparer]::OrdinalIgnoreCase.Equals((Get-EaglerFullPath $npm), (Get-EaglerFullPath $expectedNpm))) { return $false }
    if (-not (Test-Path -LiteralPath $java17 -PathType Leaf) -or
        -not (Test-Path -LiteralPath $java25 -PathType Leaf) -or
        -not (Test-Path -LiteralPath $node -PathType Leaf) -or
        -not (Test-Path -LiteralPath $npm -PathType Leaf)) { return $false }
    try {
        $java17Root = [IO.Path]::GetDirectoryName([IO.Path]::GetDirectoryName($java17))
        $java25Root = [IO.Path]::GetDirectoryName([IO.Path]::GetDirectoryName($java25))
        $nodeRoot = [IO.Path]::GetDirectoryName($node)
        return ((Test-EaglerJdkRoot -Root $java17Root -Major 17) -and
            (Test-EaglerJdkRoot -Root $java25Root -Major 25) -and
            (Test-EaglerNodeRoot -Root $nodeRoot -ExpectedVersion $nodeVersion))
    } catch { return $false }
}

function Assert-EaglerSha256 {
    param(
        [Parameter(Mandatory = $true)][string]$Digest,
        [Parameter(Mandatory = $true)][string]$Label
    )
    if ($Digest -notmatch '^[0-9a-fA-F]{64}$') { throw "Vendor metadata contained an invalid SHA-256 for $Label" }
}

function Get-EaglerAdoptiumRelease {
    param(
        [Parameter(Mandatory = $true)][ValidateSet(17, 25)][int]$Major,
        [Parameter(Mandatory = $true)][string]$MetadataPath
    )
    $url = "https://api.adoptium.net/v3/assets/latest/$Major/hotspot?architecture=x64&image_type=jdk&os=windows&vendor=eclipse"
    Write-EaglerStatus "Fetching Eclipse Adoptium Java $Major release metadata..."
    Invoke-EaglerHttpsDownload -Url $url -Destination $MetadataPath
    $entries = @([IO.File]::ReadAllText($MetadataPath, [Text.Encoding]::UTF8) | ConvertFrom-Json)
    $entry = $entries | Where-Object {
        $_.vendor -eq 'eclipse' -and $_.binary.architecture -eq 'x64' -and
        $_.binary.image_type -eq 'jdk' -and $_.binary.jvm_impl -eq 'hotspot' -and $_.binary.os -eq 'windows'
    } | Select-Object -First 1
    if ($null -eq $entry) { throw "Adoptium returned no Windows x64 HotSpot JDK $Major package" }
    $releaseName = [string]$entry.release_name
    $version = [string]$entry.version.openjdk_version -replace '-LTS$', ''
    $package = $entry.binary.package
    $sha = [string]$package.checksum
    $archiveUrl = [string]$package.link
    $checksumUrl = [string]$package.checksum_link
    $archiveName = [string]$package.name
    Assert-EaglerSha256 -Digest $sha -Label "Java $Major"
    if ($releaseName -ne "jdk-$version" -or $version -notmatch "^$Major\.\d+\.\d+(?:\.\d+)?\+\d+$") {
        throw "Adoptium returned an unexpected Java $Major release identity: $releaseName / $version"
    }
    $versionForArchiveName = $version -replace '\+', '_'
    $archivePattern = "^OpenJDK${Major}U-jdk_x64_windows_hotspot_$([Regex]::Escape($versionForArchiveName))\.zip$"
    $releaseUrlName = [Regex]::Escape("jdk-$version".Replace('+', '%2B'))
    if ($archiveName -notmatch $archivePattern -or $archiveUrl -notmatch "^https://github\.com/adoptium/temurin$Major-binaries/releases/download/$releaseUrlName/$([Regex]::Escape($archiveName))$") {
        throw "Adoptium returned an archive outside the expected official Windows x64 Java $Major release"
    }
    if ($checksumUrl -notmatch "^https://github\.com/adoptium/temurin$Major-binaries/releases/download/$releaseUrlName/$([Regex]::Escape($archiveName))\.sha256\.txt$") {
        throw "Adoptium returned a checksum URL outside the official Java $Major release"
    }
    return [PSCustomObject]@{
        Major = $Major; Version = $version; ReleaseName = $releaseName; ArchiveName = $archiveName
        ArchiveUrl = $archiveUrl; ChecksumUrl = $checksumUrl; Sha256 = $sha
    }
}

function Get-EaglerNodeRelease {
    param([Parameter(Mandatory = $true)][string]$StageDirectory)
    $indexPath = Join-Path $StageDirectory 'node-index.json'
    Write-EaglerStatus 'Fetching the official Node.js release index...'
    Invoke-EaglerHttpsDownload -Url 'https://nodejs.org/dist/index.json' -Destination $indexPath
    $index = @([IO.File]::ReadAllText($indexPath, [Text.Encoding]::UTF8) | ConvertFrom-Json)
    $release = $index | Where-Object {
        $_.version -match '^v24\.\d+\.\d+$' -and
        ($_.lts -is [string]) -and -not [string]::IsNullOrWhiteSpace([string]$_.lts) -and
        $_.npm -match '^\d+\.\d+\.\d+$' -and
        $_.files -contains 'win-x64-zip'
    } | Select-Object -First 1
    if ($null -eq $release) { throw 'nodejs.org did not list a stable Node.js 24 LTS win-x64 ZIP release' }
    $version = [string]$release.version
    $archiveName = "node-$version-win-x64.zip"
    return [PSCustomObject]@{
        Version = $version; NpmVersion = [string]$release.npm; ArchiveName = $archiveName
        ArchiveUrl = "https://nodejs.org/dist/$version/$archiveName"
        ChecksumUrl = "https://nodejs.org/dist/$version/SHASUMS256.txt"
    }
}

function Get-EaglerChecksumFromSidecar {
    param(
        [Parameter(Mandatory = $true)][string]$SidecarPath,
        [Parameter(Mandatory = $true)][string]$ArchiveName,
        [Parameter(Mandatory = $true)][string]$Label
    )
    $name = [Regex]::Escape($ArchiveName)
    foreach ($line in [IO.File]::ReadAllLines($SidecarPath, [Text.Encoding]::UTF8)) {
        if ($line -match "^\s*([0-9a-fA-F]{64})\s+\*?$name\s*$") {
            return $Matches[1].ToLowerInvariant()
        }
    }
    throw "The official SHA-256 sidecar did not contain $ArchiveName ($Label)"
}

function Get-EaglerVerifiedArchive {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$ChecksumUrl,
        [Parameter(Mandatory = $true)][string]$ArchiveName,
        [Parameter(Mandatory = $true)][string]$Destination,
        [string]$ExpectedMetadataSha256,
        [Parameter(Mandatory = $true)][string]$Label
    )
    $sidecar = $Destination + '.sha256.txt'
    Invoke-EaglerHttpsDownload -Url $ChecksumUrl -Destination $sidecar
    $sidecarSha = Get-EaglerChecksumFromSidecar -SidecarPath $sidecar -ArchiveName $ArchiveName -Label $Label
    if ($ExpectedMetadataSha256) {
        Assert-EaglerSha256 -Digest $ExpectedMetadataSha256 -Label $Label
        if ($sidecarSha -ne $ExpectedMetadataSha256.ToLowerInvariant()) {
            throw "Adoptium API SHA-256 and release sidecar disagree for $Label"
        }
    }
    Write-EaglerStatus "Downloading and verifying $Label..."
    Invoke-EaglerHttpsDownload -Url $Url -Destination $Destination
    $actual = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $sidecarSha) {
        throw "SHA-256 mismatch for $ArchiveName: expected $sidecarSha, got $actual"
    }
    return $actual
}

function Expand-EaglerVerifiedZip {
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$Destination
    )
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Directory]::CreateDirectory($Destination) | Out-Null
    $destinationRoot = Get-EaglerFullPath $Destination
    $zip = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    $names = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    [long]$totalExpanded = 0
    try {
        if ($zip.Entries.Count -gt 200000) { throw 'Vendor ZIP has an unreasonable number of entries' }
        foreach ($entry in $zip.Entries) {
            $raw = [string]$entry.FullName
            if ([string]::IsNullOrWhiteSpace($raw) -or $raw.Contains([char]0) -or $raw.StartsWith('/') -or $raw.StartsWith('\') -or $raw -match '^[A-Za-z]:') {
                throw "Unsafe absolute or empty path in vendor ZIP: $raw"
            }
            $normalized = $raw.Replace('\', '/')
            $isDirectory = $normalized.EndsWith('/')
            if ($isDirectory) { $normalized = $normalized.TrimEnd('/') }
            $parts = $normalized.Split('/')
            if ($parts.Count -lt 1) { throw "Unsafe path in vendor ZIP: $raw" }
            foreach ($part in $parts) {
                if ([string]::IsNullOrEmpty($part) -or $part -eq '.' -or $part -eq '..' -or $part.Contains(':') -or
                    $part.EndsWith('.') -or $part.EndsWith(' ') -or $part -match '[\x00-\x1f<>"|?*]' -or
                    $part -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?$') {
                    throw "Unsafe path component in vendor ZIP: $raw"
                }
            }
            if (-not $names.Add($normalized)) { throw "Duplicate or conflicting case-insensitive ZIP path: $raw" }

            $unixType = ([int]$entry.ExternalAttributes -shr 16) -band 0xF000
            $windowsAttributes = [int]$entry.ExternalAttributes -band 0xFFFF
            if ($unixType -eq 0xA000 -or (($windowsAttributes -band [int][IO.FileAttributes]::ReparsePoint) -ne 0)) {
                throw "Symbolic link or reparse entry is not allowed in vendor ZIP: $raw"
            }
            if ($unixType -ne 0 -and $unixType -ne 0x8000 -and $unixType -ne 0x4000) {
                throw "Unsupported special-file entry in vendor ZIP: $raw"
            }

            $target = Get-EaglerFullPath (Join-Path $destinationRoot ($normalized.Replace('/', [IO.Path]::DirectorySeparatorChar)))
            if (-not (Test-EaglerPathUnder -Path $target -Root $destinationRoot)) { throw "ZIP entry escaped its extraction directory: $raw" }
            if ($isDirectory -or $unixType -eq 0x4000) {
                [IO.Directory]::CreateDirectory($target) | Out-Null
                continue
            }
            $totalExpanded += [long]$entry.Length
            if ($entry.Length -gt 2147483648 -or $totalExpanded -gt 8589934592) {
                throw 'Vendor ZIP expands beyond the configured 8 GiB safety limit'
            }
            $parent = [IO.Path]::GetDirectoryName($target)
            [IO.Directory]::CreateDirectory($parent) | Out-Null
            $inputStream = $entry.Open()
            $outputStream = $null
            try {
                $outputStream = [IO.File]::Open($target, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                $inputStream.CopyTo($outputStream)
            } finally {
                $inputStream.Dispose()
                if ($null -ne $outputStream) { $outputStream.Dispose() }
            }
        }
    } finally {
        $zip.Dispose()
    }

    $roots = @(Get-ChildItem -LiteralPath $destinationRoot -Force)
    if ($roots.Count -ne 1 -or -not $roots[0].PSIsContainer) {
        throw 'Vendor ZIP must contain one top-level directory and no root-level files'
    }
    Assert-EaglerNoReparsePoints -Path $roots[0].FullName -StopAt $destinationRoot
    return $roots[0].FullName
}

function Install-EaglerManagedDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$ExtractedRoot,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][ValidateSet('java17', 'java25', 'node')][string]$Kind,
        [Parameter(Mandatory = $true)][string]$Version
    )
    if (Test-Path -LiteralPath $Destination) {
        $valid = switch ($Kind) {
            'java17' { Test-EaglerJdkRoot -Root $Destination -Major 17 }
            'java25' { Test-EaglerJdkRoot -Root $Destination -Major 25 }
            'node' { Test-EaglerNodeRoot -Root $Destination -ExpectedVersion $Version }
        }
        if (-not $valid) { throw "Existing app-managed $Kind directory is invalid; refusing to overwrite: $Destination" }
        return $Destination
    }
    [IO.Directory]::Move($ExtractedRoot, $Destination)
    return $Destination
}

function Publish-EaglerManifest {
    param(
        [Parameter(Mandatory = $true)][string]$AppDirectory,
        [Parameter(Mandatory = $true)][string]$Content
    )
    $manifestPath = Join-Path $AppDirectory 'toolchain.properties'
    $temporaryPath = Join-Path $AppDirectory ('.toolchain.properties.tmp.' + [Guid]::NewGuid().ToString('N'))
    $encoding = [Text.UTF8Encoding]::new($false)
    try {
        [IO.File]::WriteAllText($temporaryPath, $Content, $encoding)
        if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
            [IO.File]::Replace($temporaryPath, $manifestPath, $null)
        } else {
            [IO.File]::Move($temporaryPath, $manifestPath)
        }
    } finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-EaglerWindowsBootstrap {
    param([string]$ApplicationDirectory)
    Assert-EaglerWindowsX64
    if ([string]::IsNullOrWhiteSpace($ApplicationDirectory)) {
        $ApplicationDirectory = Join-Path $script:EaglerBootstrapRoot '..\..'
    }
    $app = Assert-EaglerAppDirectory -Candidate $ApplicationDirectory
    $toolRoot = Join-Path $app '.toolchain'
    if (-not (Test-Path -LiteralPath $toolRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $toolRoot | Out-Null
    }
    Assert-EaglerNoReparsePoints -Path $toolRoot -StopAt $app
    $toolRoot = Get-EaglerFullPath $toolRoot
    $lockPath = Join-Path $toolRoot '.bootstrap.lock'
    $lock = Open-EaglerBootstrapLock -LockPath $lockPath
    $stage = $null
    try {
        $manifestPath = Join-Path $app 'toolchain.properties'
        if (Test-EaglerManifestUsable -ManifestPath $manifestPath -ToolRoot $toolRoot) {
            Write-EaglerStatus 'App-local Java 17, Java 25, Node.js 24, and npm are already installed.'
            return $manifestPath
        }

        Write-EaglerStatus 'Preparing verified app-local tools for Windows x64.'
        $stage = Join-Path $toolRoot ('.bootstrap.' + [Guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory($stage) | Out-Null

        $java17Release = Get-EaglerAdoptiumRelease -Major 17 -MetadataPath (Join-Path $stage 'temurin17.json')
        $java25Release = Get-EaglerAdoptiumRelease -Major 25 -MetadataPath (Join-Path $stage 'temurin25.json')
        $nodeRelease = Get-EaglerNodeRelease -StageDirectory $stage

        $java17Archive = Join-Path $stage $java17Release.ArchiveName
        $java25Archive = Join-Path $stage $java25Release.ArchiveName
        $nodeArchive = Join-Path $stage $nodeRelease.ArchiveName
        $java17Sha = Get-EaglerVerifiedArchive -Url $java17Release.ArchiveUrl -ChecksumUrl $java17Release.ChecksumUrl -ArchiveName $java17Release.ArchiveName -Destination $java17Archive -ExpectedMetadataSha256 $java17Release.Sha256 -Label 'Temurin Java 17 x64'
        $java25Sha = Get-EaglerVerifiedArchive -Url $java25Release.ArchiveUrl -ChecksumUrl $java25Release.ChecksumUrl -ArchiveName $java25Release.ArchiveName -Destination $java25Archive -ExpectedMetadataSha256 $java25Release.Sha256 -Label 'Temurin Java 25 x64'
        $nodeSha = Get-EaglerVerifiedArchive -Url $nodeRelease.ArchiveUrl -ChecksumUrl $nodeRelease.ChecksumUrl -ArchiveName $nodeRelease.ArchiveName -Destination $nodeArchive -Label "Node.js $($nodeRelease.Version) x64"

        Write-EaglerStatus 'Safely extracting the verified vendor ZIP files...'
        $java17Root = Expand-EaglerVerifiedZip -ArchivePath $java17Archive -Destination (Join-Path $stage 'unpack-java17')
        $java25Root = Expand-EaglerVerifiedZip -ArchivePath $java25Archive -Destination (Join-Path $stage 'unpack-java25')
        $nodeRoot = Expand-EaglerVerifiedZip -ArchivePath $nodeArchive -Destination (Join-Path $stage 'unpack-node')
        if (-not (Test-EaglerJdkRoot -Root $java17Root -Major 17)) { throw 'Extracted Temurin archive failed Java 17 / javac validation' }
        if (-not (Test-EaglerJdkRoot -Root $java25Root -Major 25)) { throw 'Extracted Temurin archive failed Java 25 / javac validation' }
        if (-not (Test-EaglerNodeRoot -Root $nodeRoot -ExpectedVersion $nodeRelease.Version)) { throw 'Extracted Node.js archive failed Node/npm validation' }

        $java17Tag = $java17Sha.Substring(0, 12)
        $java25Tag = $java25Sha.Substring(0, 12)
        $nodeTag = $nodeSha.Substring(0, 12)
        $java17SafeVersion = $java17Release.Version -replace '[^A-Za-z0-9.+_-]', '_'
        $java25SafeVersion = $java25Release.Version -replace '[^A-Za-z0-9.+_-]', '_'
        $java17Dir = Join-Path $toolRoot "temurin17-$java17SafeVersion-$java17Tag"
        $java25Dir = Join-Path $toolRoot "temurin25-$java25SafeVersion-$java25Tag"
        $nodeDir = Join-Path $toolRoot "node-$($nodeRelease.Version)-win-x64-$nodeTag"
        $java17Dir = Install-EaglerManagedDirectory -ExtractedRoot $java17Root -Destination $java17Dir -Kind java17 -Version $java17Release.Version
        $java25Dir = Install-EaglerManagedDirectory -ExtractedRoot $java25Root -Destination $java25Dir -Kind java25 -Version $java25Release.Version
        $nodeDir = Install-EaglerManagedDirectory -ExtractedRoot $nodeRoot -Destination $nodeDir -Kind node -Version $nodeRelease.Version

        $java17Path = Join-Path $java17Dir 'bin\java.exe'
        $java25Path = Join-Path $java25Dir 'bin\java.exe'
        $nodePath = Join-Path $nodeDir 'node.exe'
        $npmPath = Join-Path $nodeDir 'node_modules\npm\bin\npm-cli.js'
        foreach ($candidate in @($java17Path, $java25Path, $nodePath, $npmPath)) {
            if (-not (Test-EaglerPathUnder -Path $candidate -Root $toolRoot)) { throw "Tool path is outside the app-local directory: $candidate" }
            Assert-EaglerNoReparsePoints -Path $candidate -StopAt $toolRoot
        }
        if ((Get-EaglerJavaMajorVersion -JavaPath $java17Path) -ne 17 -or
            (Get-EaglerJavaMajorVersion -JavaPath $java25Path) -ne 25 -or
            (Get-EaglerNodeVersion -NodePath $nodePath) -ne $nodeRelease.Version -or
            -not (Test-EaglerNpmCli -NodePath $nodePath -NpmPath $npmPath)) {
            throw 'Installed tool validation failed before manifest publication'
        }

        $manifest = @(
            'format=1'
            'platform=windows-x86_64'
            ('java17=' + $java17Path.Replace('\', '/'))
            ('java25=' + $java25Path.Replace('\', '/'))
            ('node=' + $nodePath.Replace('\', '/'))
            ('npm=' + $npmPath.Replace('\', '/'))
            ('java17_version=' + $java17Release.Version)
            ('java17_archive_sha256=' + $java17Sha)
            ('java25_version=' + $java25Release.Version)
            ('java25_archive_sha256=' + $java25Sha)
            ('node_version=' + $nodeRelease.Version)
            ('node_archive_sha256=' + $nodeSha)
            ('npm_version=' + $nodeRelease.NpmVersion)
            ''
        ) -join "`n"
        Publish-EaglerManifest -AppDirectory $app -Content $manifest
        if (-not (Test-EaglerManifestUsable -ManifestPath $manifestPath -ToolRoot $toolRoot)) {
            throw 'Published toolchain.properties failed its post-publication validation'
        }

        Write-EaglerStatus 'App-local toolchain is ready.'
        Write-EaglerStatus "Tool paths: $manifestPath"
        return $manifestPath
    } finally {
        if ($stage -and (Test-Path -LiteralPath $stage -PathType Container)) {
            Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($null -ne $lock) { $lock.Dispose() }
    }
}

if (-not $script:EaglerBootstrapWasDotSourced) {
    try {
        $null = Invoke-EaglerWindowsBootstrap -ApplicationDirectory $AppDir
        exit 0
    } catch {
        Write-Error ("ERROR: " + $_.Exception.Message) -ErrorAction Continue
        exit 2
    }
}
