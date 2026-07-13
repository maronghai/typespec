[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$typespec = 'E:\26\6\typespec\zig-typespec\zig-out\bin\typespec.exe'
$inputFile = 'E:\26\6\typespec\test_input.txt'
$sqlFile = 'E:\26\6\typespec\test_output.sql'
$tpsFile = 'E:\26\6\typespec\test_output.tps'

# Forward: .tps -> SQL
& $typespec $inputFile | Out-File -Encoding utf8 $sqlFile

# Reverse: SQL -> .tps
& $typespec reverse $sqlFile | Out-File -Encoding utf8 $tpsFile

Write-Host "=== Original TPS ==="
Get-Content $inputFile
Write-Host "`n=== SQL ==="
Get-Content $sqlFile
Write-Host "`n=== Reversed TPS ==="
Get-Content $tpsFile
Write-Host "`n=== Diff ==="
if ((Get-Content $inputFile -Raw) -eq (Get-Content $tpsFile -Raw)) {
    Write-Host "PASS: Files are identical"
} else {
    Write-Host "FAIL: Files differ"
}
