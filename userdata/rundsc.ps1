function Run-RemoteDesiredStateConfig {
  param (
    [string] $url
  )
  # terminate any running dsc process
  $dscpid = (Get-WmiObject msft_providers | ? {$_.provider -like 'dsccore'} | Select-Object -ExpandProperty HostProcessIdentifier)
  if ($dscpid) {
    Get-Process -Id $dscpid | Stop-Process -f
  }
  $config = [IO.Path]::GetFileNameWithoutExtension($url)
  $target = ('{0}\{1}.ps1' -f $env:Temp, $config)
  (New-Object Net.WebClient).DownloadFile(('{0}?{1}' -f $url, [Guid]::NewGuid()), $target)
  Unblock-File -Path $target
  . $target
  $mof = ('{0}\{1}' -f $env:Temp, $config)
  Invoke-Expression "$config -OutputPath $mof"
  Start-DscConfiguration -Path "$mof" -Wait -Verbose -Force
}
function Remove-LegacyStuff {
  param (
    [string[]] $users = @('cltbld'),
    [string[]] $paths = @(
      ('{0}\etc' -f $env:SystemDrive),
      ('{0}\opt' -f $env:SystemDrive),
      ('{0}\mozilla-buildbuildbotve' -f $env:SystemDrive),
      ('{0}\mozilla-buildpython27' -f $env:SystemDrive),
      ('{0}\PuppetLabs' -f $env:ProgramData),
      ('{0}\puppetagain' -f $env:ProgramData),
      ('{0}\installersource' -f $env:SystemDrive)
    ),
    [string[]] $services = @(
      'puppet',
      'uvnc_service'
    ),
    [string[]] $scheduledTasks = @(
      'enabel-userdata-execution',
      'Make sure userdata runs',
      'timesync'
    )
  )
  foreach ($user in $users) {
    if (@(Get-WMiObject -class Win32_UserAccount | Where { $_.Name -eq $user }).length -gt 0) {
      Start-Process 'logoff' -ArgumentList @((((quser /server:. | ? { $_ -match $user }) -split ' +')[2]), '/server:.') -Wait -NoNewWindow -PassThru -RedirectStandardOutput ('{0}\log\{1}.net-user-{2}-logoff.stdout.log' -f $env:SystemDrive, [DateTime]::Now.ToString("yyyyMMddHHmmss"), $user) -RedirectStandardError ('{0}\log\{1}.net-user-{2}-logoff.stderr.log' -f $env:SystemDrive, [DateTime]::Now.ToString("yyyyMMddHHmmss"), $user)
      Start-Process 'net' -ArgumentList @('user', $user, '/DELETE') -Wait -NoNewWindow -PassThru -RedirectStandardOutput ('{0}\log\{1}.net-user-{2}-delete.stdout.log' -f $env:SystemDrive, [DateTime]::Now.ToString("yyyyMMddHHmmss"), $user) -RedirectStandardError ('{0}\log\{1}.net-user-{2}-delete.stderr.log' -f $env:SystemDrive, [DateTime]::Now.ToString("yyyyMMddHHmmss"), $user)
    }
    if (Test-Path -Path ('{0}\Users\{1}' -f $env:SystemDrive, $user) -ErrorAction SilentlyContinue) {
      Remove-Item ('{0}\Users\{1}' -f $env:SystemDrive, $user) -confirm:$false -recurse:$true -force -ErrorAction SilentlyContinue
    }
  }
  foreach ($path in $paths) {
    Remove-Item $path -confirm:$false -recurse:$true -force -ErrorAction SilentlyContinue
  }
  # presence of python27 indicates old mozilla-build
  if (Test-Path -Path ('{0}\mozilla-build\python27' -f $env:SystemDrive) -ErrorAction SilentlyContinue) {
    Remove-Item ('{0}\mozilla-build' -f $env:SystemDrive) -confirm:$false -recurse:$true -force -ErrorAction SilentlyContinue
  }
  foreach ($service in $services) {
    try {
      Get-Service -Name $service | Stop-Service -PassThru
      (Get-WmiObject -Class Win32_Service -Filter "Name='$service'").delete()
    }
    catch {
      # todo: give a damn
    }
  }
  foreach ($scheduledTask in $scheduledTasks) {
    try {
      Start-Process 'schtasks.exe' -ArgumentList @('/Delete', '/tn', $scheduledTask, '/F') -Wait -NoNewWindow -PassThru -RedirectStandardOutput ('{0}\log\{1}.schtask-{2}-delete.stdout.log' -f $env:SystemDrive, [DateTime]::Now.ToString("yyyyMMddHHmmss"), $scheduledTask) -RedirectStandardError ('{0}\log\{1}.schtask-{2}-delete.stderr.log' -f $env:SystemDrive, [DateTime]::Now.ToString("yyyyMMddHHmmss"), $scheduledTask)
    }
    catch {
      # todo: give a damn
    }
  }
}

# set up a log folder, an execution policy that enables the dsc run and a winrm envelope size large enough for the dynamic dsc.
$logFile = ('{0}\log\{1}.userdata-run.log' -f $env:SystemDrive, [DateTime]::Now.ToString("yyyyMMddHHmmss"))
New-Item -ItemType Directory -Force -Path ('{0}\log' -f $env:SystemDrive)
Set-ExecutionPolicy RemoteSigned -force | Tee-Object -filePath $logFile -append
& winrm @('set', 'winrm/config', '@{MaxEnvelopeSizekb="8192"}')

# if importing releng amis, do a little housekeeping
switch -wildcard ((Get-WmiObject -class Win32_OperatingSystem).Caption) {
  'Microsoft Windows 10*' {
    $workerType = 'win10'
    Remove-LegacyStuff
    $renameInstance = $true
  }
  'Microsoft Windows 7*' {
    $workerType = 'win7'
    Remove-LegacyStuff
    $renameInstance = $true
  }
  default {
    $workerType = 'win2012'
    $renameInstance = $false
  }
}

# install recent powershell (required by DSC) (requires reboot)
if ($PSVersionTable.PSVersion.Major -lt 4) {
  & sc.exe @('config', 'wuauserv', 'start=', 'demand')
  & net @('start', 'wuauserv')
  switch -wildcard ((Get-WmiObject -class Win32_OperatingSystem).Caption) {
    'Microsoft Windows 7*' {
      (New-Object Net.WebClient).DownloadFile('https://download.microsoft.com/download/2/C/6/2C6E1B4A-EBE5-48A6-B225-2D2058A9CEFB/Win7-KB3134760-x86.msu', ('{0}\Temp\Win7-KB3134760-x86.msu' -f $env:SystemRoot))
      & wusa @('/install', ('{0}\Temp\Win7-KB3134760-x86.msu' -f $env:SystemRoot), '/quiet', '/norestart')
    }
  }
  #$rebootReasons += 'powershell upgraded'
}

# rename the instance if it's based on a releng ami
$instanceId = ((New-Object Net.WebClient).DownloadString('http://169.254.169.254/latest/meta-data/instance-id'))
if ($renameInstance -and ([bool]($instanceId)) -and (-not ([System.Net.Dns]::GetHostName() -ieq $instanceId))) {
  (Get-WmiObject Win32_ComputerSystem).Rename($instanceId)
  $rebootReasons += 'host renamed'
}

if ($rebootReasons.length) {
  & shutdown @('-r', '-t', '0', '-c', [string]::Join(', ', $rebootReasons), '-f', '-d', 'p:4:1') | Out-File -filePath $logFile -append
} else {
  Start-Transcript -Path $logFile -Append
  Run-RemoteDesiredStateConfig -url 'https://raw.githubusercontent.com/MozRelOps/OpenCloudConfig/master/userdata/DynamicConfig.ps1'
  Stop-Transcript
  if (((Get-Content $logFile) | % { (($_ -match 'requires a reboot') -or ($_ -match 'reboot is required')) }) -contains $true) {
    & shutdown @('-r', '-t', '0', '-c', 'a package installed by dsc requested a restart', '-f', '-d', 'p:4:1') | Out-File -filePath $logFile -append
  } else {
    # symlink mercurial to ec2 region config. todo: find a way to do this in the manifest (cmd)
    # if the hg call is NOT wrapped by python (hg.exe), the ini file below is used
    $hgini = ('{0}\python\Scripts\mercurial.ini' -f $env:MozillaBuild)
    if (Test-Path -Path ([IO.Path]::GetDirectoryName($hgini)) -ErrorAction SilentlyContinue) {
      if (Test-Path -Path $hgini -ErrorAction SilentlyContinue) {
        & del $hgini # use cmd del (not ps remove-item) here in order to preserve targets
      }
      $ec2region = ((New-Object Net.WebClient).DownloadString('http://169.254.169.254/latest/meta-data/placement/availability-zone') -replace '.$')
      & cmd @('/c', 'mklink', $hgini, ($hgini.Replace('.ini', ('.{0}.ini' -f $ec2region))))
      # also replace built in (MozillaBuild) mercurial.ini
      # if the hg call is wrapped by python (python.exe hg), the ini file below is used
      $mbhgini = ('{0}\python\mercurial.ini' -f $env:MozillaBuild)
      if (Test-Path -Path $mbhgini -ErrorAction SilentlyContinue) {
        & del $mbhgini # use cmd del (not ps remove-item) here in order to preserve targets
      }
      & cmd @('/c', 'mklink', $mbhgini, ($hgini.Replace('.ini', ('.{0}.ini' -f $ec2region))))
    }

    # archive dsc logs
    Get-ChildItem -Path ('{0}\log' -f $env:SystemDrive) | ? { !$_.PSIsContainer -and $_.Name.EndsWith('.log') -and $_.Length -eq 0 } | % { Remove-Item -Path $_.FullName -Force }
    New-ZipFile -ZipFilePath $logFile.Replace('.log', '.zip') -Item @(Get-ChildItem -Path ('{0}\log' -f $env:SystemDrive) | ? { !$_.PSIsContainer -and $_.Name.EndsWith('.log') -and $_.FullName -ne $logFile } | % { $_.FullName })
    Get-ChildItem -Path ('{0}\log' -f $env:SystemDrive) | ? { !$_.PSIsContainer -and $_.Name.EndsWith('.log') -and $_.FullName -ne $logFile } | % { Remove-Item -Path $_.FullName -Force }
    if ((Get-ChildItem -Path ('{0}\log' -f $env:SystemDrive) | ? { $_.Name.EndsWith('.userdata-run.zip') }).Count -eq 1) {
      & shutdown @('-s', '-t', '0', '-c', 'dsc run complete', '-f', '-d', 'p:4:1') | Out-File -filePath $logFile -append
    } elseif (Test-Path -Path 'C:\generic-worker\run-generic-worker.bat' -ErrorAction SilentlyContinue) {
      Start-Sleep -seconds 30 # give g-w a moment to fire up, if it doesn't, boot loop.
      if (@(Get-Process | ? { $_.ProcessName -eq 'generic-worker' }).length -eq 0) {
        #& shutdown @('-r', '-t', '0', '-c', 'restarting to rouse the generic worker', '-f', '-d', 'p:4:1') | Out-File -filePath $logFile -append
      }
    }
  }
}