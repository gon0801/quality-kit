$qualityKitDir = Split-Path -Parent $PSScriptRoot
$files = @(Get-ChildItem -LiteralPath $qualityKitDir -Filter '*.ps1' -File | ForEach-Object { $_.FullName })
$files += (Join-Path $qualityKitDir 'tests/run-tests.ps1')
$hadError = $false
foreach ($f in $files) {
    $errors = $null
    $null = [System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw -LiteralPath $f), [ref]$errors)
    if ($errors.Count -gt 0) {
        $hadError = $true
        Write-Host "FAIL: $f"
        $errors | ForEach-Object { Write-Host "  $($_.Message)" }
    } else {
        Write-Host "OK: $f"
    }
}
if ($hadError) { exit 1 } else { exit 0 }
