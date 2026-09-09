$qualityKitDir = Split-Path -Parent $PSScriptRoot
$files = @(
    (Join-Path $qualityKitDir 'init-repo.ps1'),
    (Join-Path $qualityKitDir 'heal-repo.ps1'),
    (Join-Path $qualityKitDir 'cross-review.ps1'),
    (Join-Path $qualityKitDir 'install-ai-rules.ps1'),
    (Join-Path $qualityKitDir 'uninstall-ai-rules.ps1'),
    (Join-Path $qualityKitDir 'install-docs-groom.ps1'),
    (Join-Path $qualityKitDir 'uninstall-docs-groom.ps1'),
    # Faltaba, y es el unico script del kit que corre en CADA SessionStart: un
    # error de sintaxis aca se descubre en el arranque siguiente, no aca.
    (Join-Path $qualityKitDir 'saikit-gate-heal.ps1'),
    (Join-Path $qualityKitDir 'tests\run-tests.ps1')
)
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
