param (
    $cygwinDir = $( Read-Host "Path to setup directory (c:\cygwin)" ),
    $listenAddress = $( Read-Host "Interface to listen on (0.0.0.0)" ),
    $port = $( Read-Host "Port to listen on (22)" )
)

$currentDir = split-path $SCRIPT:MyInvocation.MyCommand.Path -parent
Import-Module (Join-Path $currentDir '..\..\common\openshift-common.psd1') -DisableNameChecking

$cygwinDir = Get-NotEmpty $cygwinDir "c:\cygwin"
$listenAddress = Get-NotEmpty $listenAddress "0.0.0.0"
$port = Get-NotEmpty $port "22"

$usersGroupSID = Get-NoneGroupSID

Write-Host 'Using setup dir: ' -NoNewline
Write-Host $cygwinDir -ForegroundColor Yellow

$cygwinSetupProgramURL = 'http://cygwin.com/setup-x86_64.exe'
$setupPackage = Join-Path $env:TEMP "setup-x86_64.exe"

if ((Test-Path $setupPackage) -eq $true)
{
    rm $setupPackage -Force > $null
}

Write-Host "Downloading the setup program from here: " -NoNewline
Write-Host $cygwinSetupProgramURL -ForegroundColor Yellow

if ([string]::IsNullOrWhiteSpace($env:osiProxy))
{
    Invoke-WebRequest $cygwinSetupProgramURL -OutFile $setupPackage
}
else
{
    Invoke-WebRequest $cygwinSetupProgramURL -OutFile $setupPackage -Proxy $env:osiProxy
}

if ((Test-Path $cygwinDir) -eq $true)
{
    rmdir $cygwinDir -Recurse -Force > $null
}

mkdir $cygwinDir > $null

$packageDir = Join-Path $cygwinDir "packages"
$installationDir = Join-Path $cygwinDir "installation"

mkdir $packageDir > $null
mkdir $installationDir > $null


if ((Test-Path $setupPackage) -ne $true)
{
    Write-Host "Can't find Cygwin setup program. Aborting." -ForegroundColor red
    exit 1
}

$packages = "openssh", "cygrunsrv", "git"

$site = "http://mirrors.kernel.org/sourceware/cygwin/"

$packagesArg = [string]::Join(',', $packages)

$arguments = "-d -n -N -q -r -s `"$site`" -a x86_64 -l `"$packageDir`" -R `"$installationDir`" -P `"$packagesArg`""

if ([string]::IsNullOrWhiteSpace($env:osiProxy) -eq $false)
{
    $proxyHost = ([system.uri]${env:osiProxy}).Host
    $proxyPort = ([system.uri]${env:osiProxy}).Port
    $arguments = "${arguments} -p ${proxyHost}:${proxyPort}"
}

Write-Host "Setting up cygwin with the following arguments: " -NoNewline
Write-Host $arguments -ForegroundColor Yellow

Start-Process $setupPackage $arguments -Wait > c:\openshift\setup_logs\cygwin_install.log

Write-Host "Cygwin setup complete." -ForegroundColor Green

Write-Host "Erasing 'passwd' file."

$passwdFile = Join-Path $cygwinDir 'installation\etc\passwd'
echo '' | Out-File $passwdFile -Encoding Ascii

$groupFile = Join-Path $cygwinDir 'installation\etc\group'
Write-Host "Setting up groups file."
$gid = $usersGroupSID.Split('-')[-1]
echo "None:${usersGroupSID}:${gid}:" | Out-File $groupFile -Encoding Ascii

Write-Host "Creating host keys ..."

$keygenBinary = Join-Path $installationDir 'bin\ssh-keygen.exe'

$rsaKeyFile = Join-Path $installationDir 'etc\ssh_host_rsa_key'
$dsaKeyFile = Join-Path $installationDir 'etc\ssh_host_dsa_key'
$ecdsaKeyFile = Join-Path $installationDir 'etc\ssh_host_ecdsa_key'

rm $rsaKeyFile -Force -ErrorAction SilentlyContinue > $null
rm $dsaKeyFile -Force -ErrorAction SilentlyContinue > $null
rm $ecdsaKeyFile -Force -ErrorAction SilentlyContinue > $null

$env:CYGWIN = 'nodosfilewarning'

Write-Host "Creating RSA key ..."
Start-Process $keygenBinary "-t rsa -q -f '$rsaKeyFile' -C '' -N ''" -NoNewWindow
Write-Host "Creating DSA key ..."
Start-Process $keygenBinary "-t dsa -q -f '$dsaKeyFile' -C '' -N ''" -NoNewWindow
Write-Host "Creating ECDSA key ..."
Start-Process $keygenBinary "-t ecdsa -q -f '$ecdsaKeyFile' -C '' -N ''" -NoNewWindow

Write-Host "Host keys created." -ForegroundColor Green 

Write-Host "Configuring sshd ..."

Write-Template (Join-Path $currentDir 'sshd_config.template') (Join-Path $installationDir 'etc\sshd_config') @{
   port = $port
   listenAddress = $listenAddress
}

Write-Host "Setting file permissions ..."

$passwdFileAcl = Get-Acl -Path $passwdFile
$accessRule = new-object System.Security.AccessControl.FileSystemAccessRule(".\Administrators","FullControl","Allow")
$passwdFileAcl.AddAccessRule($accessRule)
Set-Acl -Path $passwdFile -AclObject $passwdFileAcl


powershell -executionpolicy bypass -file (Join-Path $currentDir 'configure-sshd.ps1')  -targetDirectory $installationDir -user 'administrator' -windowsUser 'administrator' -userHomeDir (Join-Path $cygwinDir 'admin_home') -userShell '/bin/bash'

Write-Host "Opening firewall port ${port} ..."

$firewallPort = New-Object -ComObject HNetCfg.FWOpenPort
$firewallPort.Port = $port
$firewallPort.Name = 'Openshift SSHD Port'
$firewallPort.Enabled = $true

$fwMgr = New-Object -ComObject HNetCfg.FwMgr
$profile = $fwMgr.LocalPolicy.CurrentProfile
$profile.GloballyOpenPorts.Add($firewallPort)