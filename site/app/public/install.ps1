#!/usr/bin/env pwsh
param(
  [String]$Version = "latest",
  # Forces installing the baseline build regardless of what CPU you are actually using.
  [Switch]$ForceBaseline = $false,
  # Skips adding the zx.exe directory to the user's %PATH%
  [Switch]$NoPathUpdate = $false,
  # Skips adding the zx to the list of installed programs
  [Switch]$NoRegisterInstallation = $false,
  # Skips installing powershell completions to your profile
  [Switch]$NoCompletions = $true,

  # Debugging: Always download with 'Invoke-RestMethod' instead of 'curl.exe'
  [Switch]$DownloadWithoutCurl = $false
);

# filter out 32 bit + ARM
if (-not ((Get-CimInstance Win32_ComputerSystem)).SystemType -match "x64-based") {
  Write-Output "Install Failed:"
  Write-Output "Ziex for Windows is currently only available for x86 64-bit Windows.`n"
  return 1
}

# This corresponds to .win10_rs5 in build.zig
$MinBuild = 17763;
$MinBuildName = "Windows 10 1809 / Windows Server 2019"

$WinVer = [System.Environment]::OSVersion.Version
if ($WinVer.Major -lt 10 -or ($WinVer.Major -eq 10 -and $WinVer.Build -lt $MinBuild)) {
  Write-Warning "Ziex requires at ${MinBuildName} or newer.`n`nThe install will still continue but it may not work.`n"
  return 1
}

$ErrorActionPreference = "Stop"

# These three environment functions are roughly copied from https://github.com/prefix-dev/pixi/pull/692
# They are used instead of `SetEnvironmentVariable` because of unwanted variable expansions.
function Publish-Env {
  if (-not ("Win32.NativeMethods" -as [Type])) {
    Add-Type -Namespace Win32 -Name NativeMethods -MemberDefinition @"
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
public static extern IntPtr SendMessageTimeout(
    IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam,
    uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
"@
  }
  $HWND_BROADCAST = [IntPtr] 0xffff
  $WM_SETTINGCHANGE = 0x1a
  $result = [UIntPtr]::Zero
  [Win32.NativeMethods]::SendMessageTimeout($HWND_BROADCAST,
    $WM_SETTINGCHANGE,
    [UIntPtr]::Zero,
    "Environment",
    2,
    5000,
    [ref] $result
  ) | Out-Null
}

function Write-Env {
  param([String]$Key, [String]$Value)

  $RegisterKey = Get-Item -Path 'HKCU:'

  $EnvRegisterKey = $RegisterKey.OpenSubKey('Environment', $true)
  if ($null -eq $Value) {
    $EnvRegisterKey.DeleteValue($Key)
  } else {
    $RegistryValueKind = if ($Value.Contains('%')) {
      [Microsoft.Win32.RegistryValueKind]::ExpandString
    } elseif ($EnvRegisterKey.GetValue($Key)) {
      $EnvRegisterKey.GetValueKind($Key)
    } else {
      [Microsoft.Win32.RegistryValueKind]::String
    }
    $EnvRegisterKey.SetValue($Key, $Value, $RegistryValueKind)
  }

  Publish-Env
}

function Get-Env {
  param([String] $Key)

  $RegisterKey = Get-Item -Path 'HKCU:'
  $EnvRegisterKey = $RegisterKey.OpenSubKey('Environment')
  $EnvRegisterKey.GetValue($Key, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
}

# The installation of zx is it's own function so that in the unlikely case the $IsBaseline check fails, we can do a recursive call.
# There are also lots of sanity checks out of fear of anti-virus software or other weird Windows things happening.
function Install-Ziex {
  param(
    [string]$Version,
    [bool]$ForceBaseline = $False
  );

  # if a semver is given, we need to adjust it to this format: zx-v0.0.0
  if ($Version -match "^\d+\.\d+\.\d+$") {
    $Version = "zx-v$Version"
  }
  elseif ($Version -match "^v\d+\.\d+\.\d+$") {
    $Version = "zx-$Version"
  }

  $Arch = "x64"
  $IsBaseline = $ForceBaseline
  if (!$IsBaseline) {
    $IsBaseline = !( `
      Add-Type -MemberDefinition '[DllImport("kernel32.dll")] public static extern bool IsProcessorFeaturePresent(int ProcessorFeature);' `
        -Name 'Kernel32' -Namespace 'Win32' -PassThru `
    )::IsProcessorFeaturePresent(40);
  }

  $ZxRoot = if ($env:ZX_INSTALL) { $env:ZX_INSTALL } else { "${Home}\.zx" }
  $ZxBin = mkdir -Force "${ZxRoot}\bin"

  try {
    Remove-Item "${ZxBin}\zx.exe" -Force
  } catch [System.Management.Automation.ItemNotFoundException] {
    # ignore
  } catch [System.UnauthorizedAccessException] {
    $openProcesses = Get-Process -Name zx | Where-Object { $_.Path -eq "${ZxBin}\zx.exe" }
    if ($openProcesses.Count -gt 0) {
      Write-Output "Install Failed - An older installation exists and is open. Please close open Ziex processes and try again."
      return 1
    }
    Write-Output "Install Failed - An unknown error occurred while trying to remove the existing installation"
    Write-Output $_
    return 1
  } catch {
    Write-Output "Install Failed - An unknown error occurred while trying to remove the existing installation"
    Write-Output $_
    return 1
  }

  $Target = "zx-windows-$Arch"
  # if ($IsBaseline) {
  #   $Target = "zx-windows-$Arch-baseline"
  # }
  $BaseURL = "https://github.com/ziex-dev/ziex/releases"
  $URL = "$BaseURL/$(if ($Version -eq "latest") { "latest/download" } else { "download/$Version" })/$Target.zip"

  $ZipPath = "${ZxBin}\$Target.zip"

  $DisplayVersion = $(
    if ($Version -eq "latest") { "Ziex" }
    elseif ($Version -eq "canary") { "Ziex Canary" }
    elseif ($Version -match "^zx-v\d+\.\d+\.\d+$") { "Ziex $($Version.Substring(4))" }
    else { "Ziex tag='${Version}'" }
  )

  $null = mkdir -Force $ZxBin
  Remove-Item -Force $ZipPath -ErrorAction SilentlyContinue

  # curl.exe is faster than PowerShell 5's 'Invoke-WebRequest'
  # note: 'curl' is an alias to 'Invoke-WebRequest'. so the exe suffix is required
  if (-not $DownloadWithoutCurl) {
    curl.exe "-#SfLo" "$ZipPath" "$URL" 
  }
  if ($DownloadWithoutCurl -or ($LASTEXITCODE -ne 0)) {
    Write-Warning "The command 'curl.exe $URL -o $ZipPath' exited with code ${LASTEXITCODE}`nTrying an alternative download method..."
    try {
      # Use Invoke-RestMethod instead of Invoke-WebRequest because Invoke-WebRequest breaks on
      # some machines, see 
      Invoke-RestMethod -Uri $URL -OutFile $ZipPath
    } catch {
      Write-Output "Install Failed - could not download $URL"
      Write-Output "The command 'Invoke-RestMethod $URL -OutFile $ZipPath' exited with code ${LASTEXITCODE}`n"
      return 1
    }
  }

  if (!(Test-Path $ZipPath)) {
    Write-Output "Install Failed - could not download $URL"
    Write-Output "The file '$ZipPath' does not exist. Did an antivirus delete it?`n"
    return 1
  }

  try {
    $lastProgressPreference = $global:ProgressPreference
    $global:ProgressPreference = 'SilentlyContinue';
    Expand-Archive "$ZipPath" "$ZxBin" -Force
    $global:ProgressPreference = $lastProgressPreference
    
    # The zip contains the binary directly as zx-windows-x64.exe (not in a subdirectory)
    if (Test-Path "${ZxBin}\$Target.exe") {
      Move-Item "${ZxBin}\$Target.exe" "${ZxBin}\zx.exe" -Force
    }
    elseif (Test-Path "${ZxBin}\$Target\zx.exe") {
      # Legacy structure: binary in subdirectory
      Move-Item "${ZxBin}\$Target\zx.exe" "${ZxBin}\zx.exe" -Force
      Remove-Item "${ZxBin}\$Target" -Recurse -Force
    }
    else {
      throw "The file '${ZxBin}\$Target.exe' does not exist. Download is corrupt or intercepted Antivirus?`n"
    }
  } catch {
    Write-Output "Install Failed - could not unzip $ZipPath"
    Write-Error $_
    return 1
  }

  Remove-Item $ZipPath -Force

  $ZxRevision = "$(& "${ZxBin}\zx.exe" version)"
  if ($LASTEXITCODE -eq 1073741795) { # STATUS_ILLEGAL_INSTRUCTION
    if ($IsBaseline) {
      Write-Output "Install Failed - zx.exe (baseline) is not compatible with your CPU.`n"
      Write-Output "Please open a GitHub issue with your CPU model:`nhttps://github.com/ziex-dev/ziex/issues/new/choose`n"
      return 1
    }

    Write-Output "Install Failed - zx.exe is not compatible with your CPU. This should have been detected before downloading.`n"
    Write-Output "Attempting to download zx.exe (baseline) instead.`n"

    Install-Ziex -Version $Version -ForceBaseline $True
    return 1
  }
  # '-1073741515' was spotted in the wild, but not clearly documented as a status code:
  # https://discord.com/channels/876711213126520882/1149339379446325248/1205194965383250081
  # http://community.sqlbackupandftp.com/t/error-1073741515-solved/1305
  if (($LASTEXITCODE -eq 3221225781) -or ($LASTEXITCODE -eq -1073741515)) # STATUS_DLL_NOT_FOUND
  { 
    Write-Output "Install Failed - You are missing a DLL required to run zx.exe"
    Write-Output "This can be solved by installing the Visual C++ Redistributable from Microsoft:`nSee https://learn.microsoft.com/cpp/windows/latest-supported-vc-redist`nDirect Download -> https://aka.ms/vs/17/release/vc_redist.x64.exe`n`n"
    Write-Output "The error above should be unreachable as Ziex does not depend on this library. Please open a issue.`n`n"
    Write-Output "The command '${ZxBin}\zx.exe --revision' exited with code ${LASTEXITCODE}`n"
    return 1
  }
  if ($LASTEXITCODE -ne 0) {
    Write-Output "Install Failed - could not verify zx.exe"
    Write-Output "The command '${ZxBin}\zx.exe --revision' exited with code ${LASTEXITCODE}`n"
    return 1
  }

  try {
    $env:IS_ZX_AUTO_UPDATE = "1"
    # TODO: When powershell completions are added, make this switch actually do something
    if ($NoCompletions) {
      $env:ZX_NO_INSTALL_COMPLETIONS = "1"
    }
    # This completions script in general will install some extra stuff, mainly the `zxx` link.
    # It also installs completions.
    $output = "$(& "${ZxBin}\zx.exe" completions 2>&1)"
    # if ($LASTEXITCODE -ne 0) {
    #   Write-Output $output
    #   Write-Output "Install Failed - could not finalize installation"
    #   Write-Output "The command '${ZxBin}\zx.exe completions' exited with code ${LASTEXITCODE}`n"
    #   return 1
    # }
  } catch {
    # it is possible on powershell 5 that an error happens, but it is probably fine?
  }
  $env:IS_ZX_AUTO_UPDATE = $null
  $env:ZX_NO_INSTALL_COMPLETIONS = $null

  $DisplayVersion = if ($ZxRevision -like "*-canary.*") {
    "${ZxRevision}"
  } else {
    "$(& "${ZxBin}\zx.exe" version)"
  }

  $C_RESET = [char]27 + "[0m"
  $C_GREEN = [char]27 + "[1;32m"

  Write-Output "${C_GREEN}Ziex ${DisplayVersion} was installed successfully!${C_RESET}"
  Write-Output "The binary is located at ${ZxBin}\zx.exe`n"

  $hasExistingOther = $false;
  try {
    $existing = Get-Command zx -ErrorAction
    if ($existing.Source -ne "${ZxBin}\zx.exe") {
      Write-Warning "Note: Another zx.exe is already in %PATH% at $($existing.Source)`nTyping 'zx' in your terminal will not use what was just installed.`n"
      $hasExistingOther = $true;
    }
  } catch {}

  if (-not $NoRegisterInstallation) {
    $rootKey = $null
    try {
      $RegistryKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\ZX"  
      $rootKey = New-Item -Path $RegistryKey -Force
      New-ItemProperty -Path $RegistryKey -Name "DisplayName" -Value "Ziex" -PropertyType String -Force | Out-Null
      New-ItemProperty -Path $RegistryKey -Name "InstallLocation" -Value "${ZxRoot}" -PropertyType String -Force | Out-Null
      New-ItemProperty -Path $RegistryKey -Name "DisplayIcon" -Value $ZxBin\zx.exe -PropertyType String -Force | Out-Null
      New-ItemProperty -Path $RegistryKey -Name "UninstallString" -Value "powershell -c `"& `'$ZxRoot\uninstall.ps1`' -PauseOnError`" -ExecutionPolicy Bypass" -PropertyType String -Force | Out-Null
    } catch {
      if ($rootKey -ne $null) {
        Remove-Item -Path $RegistryKey -Force
      }
    }
  }

  if(!$hasExistingOther) {
    # Only try adding to path if there isn't already a zx.exe in the path
    $Path = (Get-Env -Key "Path") -split ';'
    if ($Path -notcontains $ZxBin) {
      if (-not $NoPathUpdate) {
        $Path += $ZxBin
        Write-Env -Key 'Path' -Value ($Path -join ';')
        $env:PATH = $Path -join ';'
      } else {
        Write-Output "Skipping adding '${ZxBin}' to the user's %PATH%`n"
      }
    }

    Write-Output "To get started, restart your terminal/editor, then type `"zx`"`n"
  }

  $LASTEXITCODE = 0;
}

Install-Ziex -Version $Version -ForceBaseline $ForceBaseline