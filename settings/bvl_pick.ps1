Add-Type -AssemblyName System.Windows.Forms
Set-Location -LiteralPath $PSScriptRoot
$d = New-Object System.Windows.Forms.SaveFileDialog
$d.Filter = 'BovineLooty lists (*.txt)|*.txt|All files (*.*)|*.*'
$d.Title = 'Save BovineLooty list'
$d.InitialDirectory = (Resolve-Path (Join-Path $PSScriptRoot '..\bovinelooty')).Path
$d.FileName = 'bovinelist.txt'
$d.OverwritePrompt = $true
$d.AddExtension = $true
$d.DefaultExt = 'txt'
$out = Join-Path $PSScriptRoot 'bvl_save.result'
if ($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
  Set-Content -Path $out -Value $d.FileName
} else { Set-Content -Path $out -Value '' }
