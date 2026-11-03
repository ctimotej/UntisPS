# Installation

UntisPS has no required dependencies.

## Try it without installing

```powershell
Import-Module ./UntisPS/UntisPS.psd1
Get-Command -Module UntisPS
```

## Install for the current user

Copy the module into a folder named `UntisPS` inside one of your module paths. It then loads automatically.

PowerShell 7 on Windows:

```powershell
$target = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell/Modules/UntisPS'
Copy-Item ./UntisPS $target -Recurse
```

Windows PowerShell 5.1:

```powershell
$target = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell/Modules/UntisPS'
Copy-Item ./UntisPS $target -Recurse
```

Linux and macOS:

```powershell
$target = Join-Path $HOME '.local/share/powershell/Modules/UntisPS'
Copy-Item ./UntisPS $target -Recurse
```

If Windows blocks the files after a download, run `Get-ChildItem ./UntisPS -Recurse | Unblock-File`.

## Check the installation

```powershell
Import-Module UntisPS
Get-Module UntisPS
Test-UntisConnection -Server example.webuntis.com -School ExampleSchool -Detailed
```

Without a login, the last command checks DNS and HTTPS, and reports authentication as skipped.

## Optional: secure credential storage

```powershell
Install-Module Microsoft.PowerShell.SecretManagement, Microsoft.PowerShell.SecretStore -Scope CurrentUser
Register-SecretVault -Name LocalVault -ModuleName Microsoft.PowerShell.SecretStore -DefaultVault
```

## Optional: run the tests

```powershell
Install-Module Pester -MinimumVersion 5.3 -Scope CurrentUser -Force
./tests/Invoke-Tests.ps1
```

## Uninstall

```powershell
Remove-UntisCredential
Reset-UntisConfiguration
Remove-Item (Get-Module UntisPS -ListAvailable).ModuleBase -Recurse
```
