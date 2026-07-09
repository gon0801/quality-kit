$files = @(
    'C:\Users\ehven\quality-kit\init-repo.ps1',
    'C:\Users\ehven\quality-kit\heal-repo.ps1',
    'C:\Users\ehven\quality-kit\cross-review.ps1',
    'C:\Users\ehven\quality-kit\install-ai-rules.ps1',
    'C:\Users\ehven\quality-kit\uninstall-ai-rules.ps1',
    'C:\Users\ehven\quality-kit\install-docs-groom.ps1',
    'C:\Users\ehven\quality-kit\uninstall-docs-groom.ps1',
    'C:\Users\ehven\quality-kit\tests\run-tests.ps1'
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
