$root = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $root -ErrorAction Stop

if ($env:STOPCODE_PYTHON) {
    $candidates = @(@{ Name = $env:STOPCODE_PYTHON; Arguments = @() })
} else {
    $candidates = @(
        @{ Name = 'py.exe'; Arguments = @('-3') }
        @{ Name = 'python3.exe'; Arguments = @() }
        @{ Name = 'python.exe'; Arguments = @() }
    )
}

$python = $null
$pythonArgs = @()
foreach ($candidate in $candidates) {
    $commands = @(Get-Command -Name $candidate.Name -CommandType Application -All -ErrorAction SilentlyContinue)
    foreach ($command in $commands) {
        $prefix = @($candidate.Arguments)
        $global:LASTEXITCODE = 1
        & $command.Source @prefix -c 'import sys; sys.exit(not (3, 7) <= sys.version_info[:2] < (4, 0))' *> $null
        if ($LASTEXITCODE -eq 0) {
            $python = $command.Source
            $pythonArgs = $prefix
            break
        }
    }
    if ($python) { break }
}

if (-not $python) {
    [Console]::Error.WriteLine('Commit blocked: Python 3.7 or newer is required. Install it or set STOPCODE_PYTHON to its executable.')
    exit 1
}

Write-Host ('Running tests with {0} before commit...' -f $python)
$env:PYTHONDONTWRITEBYTECODE = '1'
$global:LASTEXITCODE = 1
& $python @pythonArgs (Join-Path $root 'tests\run_tests.py')
if ($LASTEXITCODE -ne 0) {
    [Console]::Error.WriteLine('Commit blocked: the test suite failed.')
    exit 1
}
exit 0
