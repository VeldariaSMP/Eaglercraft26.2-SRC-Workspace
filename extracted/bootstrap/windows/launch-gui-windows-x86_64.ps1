Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$appDir = [IO.Path]::GetFullPath($PSScriptRoot)
$guiJarName = 'eaglercraft-26.2-u1-patcher-gui.jar'
$bootstrap = Join-Path $PSScriptRoot 'bootstrap-windows-x86_64.ps1'
for ($depth = 0; $depth -le 4; $depth++) {
    $candidateJar = Join-Path $appDir $guiJarName
    if (Test-Path -LiteralPath $candidateJar -PathType Leaf) { break }
    $parent = [IO.Directory]::GetParent($appDir)
    if ($null -eq $parent) { $appDir = $null; break }
    $appDir = $parent.FullName
}
if ([string]::IsNullOrWhiteSpace($appDir) -or -not (Test-Path -LiteralPath (Join-Path $appDir $guiJarName) -PathType Leaf)) {
    Write-Error "Could not find $guiJarName in this directory or its package parents." -ErrorAction Continue
    exit 2
}
$guiJar = Join-Path $appDir $guiJarName
$manifestPath = Join-Path $appDir 'toolchain.properties'

if (-not (Test-Path -LiteralPath $guiJar -PathType Leaf)) {
    Write-Error "GUI JAR is missing: $guiJar" -ErrorAction Continue
    exit 2
}
if (-not (Test-Path -LiteralPath $bootstrap -PathType Leaf)) {
    Write-Error "Windows bootstrap is missing: $bootstrap" -ErrorAction Continue
    exit 2
}

try {
    & $bootstrap -AppDir $appDir
    if ($LASTEXITCODE -ne 0) { throw "Windows bootstrap failed (exit $LASTEXITCODE)" }

    $values = @{}
    foreach ($line in [IO.File]::ReadAllLines($manifestPath, [Text.Encoding]::UTF8)) {
        $split = $line.IndexOf('=')
        if ($split -gt 0) { $values[$line.Substring(0, $split)] = $line.Substring($split + 1) }
    }
    if (-not $values.ContainsKey('java17')) { throw 'toolchain.properties has no java17 entry' }
    $java17 = $values['java17'].Replace('/', '\')
    if (-not (Test-Path -LiteralPath $java17 -PathType Leaf)) { throw "App-local Java 17 is missing: $java17" }
    & $java17 -jar $guiJar @args
    exit $LASTEXITCODE
} catch {
    Write-Error ("ERROR: " + $_.Exception.Message) -ErrorAction Continue
    exit 2
}
