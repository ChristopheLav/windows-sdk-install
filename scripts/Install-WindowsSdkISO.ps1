[CmdletBinding()]
param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$buildNumber,

    [Parameter(Mandatory=$true, Position=1)]
    [string]$features
)

# Ensure the error action preference is set to the default for PowerShell3, 'Stop'
$ErrorActionPreference = 'Stop'

if (-not $IsWindows) {
    Write-Host "ERROR: this action is only compatible with Windows!"
    Write-Host
    Exit 1
}

# Generate the features array
$WindowsSDKOptions = $features -split ',' -replace '^\s+|\s+$' | ForEach-Object { "$_" }
if ($WindowsSDKOptions.Length -le 0) {
    Write-Host "ERROR: you need to specify one or more features to install!"
    Write-Host
    Exit 1
}

# Constants
$WindowsSDKRegPath = "HKLM:\Software\WOW6432Node\Microsoft\Windows Kits\Installed Roots"
$WindowsSDKRegRootKey = "KitsRoot10"
$WindowsSDKVersion = "10.0.$buildNumber.0"
$WindowsSDKInstalledRegPath = "$WindowsSDKRegPath\$WindowsSDKVersion\Installed Options"
$StrongNameRegPath = "HKLM:\SOFTWARE\Microsoft\StrongName\Verification"
$PublicKeyTokens = @("31bf3856ad364e35")

if ($buildNumber -notmatch "^\d{5,}$")
{
    Write-Host "ERROR: '$buildNumber' doesn't look like a windows build number"
    Write-Host
    Exit 1
}

function Download-File
{
    param ([string] $outDir,
           [string] $downloadUrl,
           [string] $downloadName)

    $downloadPath = Join-Path $outDir "$downloadName.download"
    $downloadDest = Join-Path $outDir $downloadName
    $downloadDestTemp = Join-Path $outDir "$downloadName.tmp"

    Write-Host -NoNewline "Downloading $downloadName..."

    $retries = 10
    $downloaded = $false
    while (-not $downloaded)
    {
        try
        {
            $webclient = new-object System.Net.WebClient
            $webclient.DownloadFile($downloadUrl, $downloadPath)
            $downloaded = $true
        }
        catch [System.Net.WebException]
        {
            Write-Host
            Write-Warning "Failed to fetch updated file from $downloadUrl : $($error[0])"
            if (!(Test-Path $downloadDest))
            {
                if ($retries -gt 0)
                {
                    Write-Host "$retries retries left, trying download again"
                    $retries--
                    start-sleep -Seconds 10
                }
                else
                {
                    throw "$downloadName was not found at $downloadDest"
                }
            }
            else
            {
                Write-Warning "$downloadName may be out of date"
            }
        }
    }

    Unblock-File $downloadPath

    $downloadDestTemp = $downloadPath;

    # Delete and rename to final dest
    Write-Host "testing $downloadDest"
    if (Test-Path $downloadDest)
    {
        Write-Host "Deleting: $downloadDest"
        Remove-Item $downloadDest -Force
    }

    Move-Item -Force $downloadDestTemp $downloadDest
    Write-Host "Done"

    return $downloadDest
}

function Get-ISODriveLetter
{
    param ([string] $isoPath)

    $diskImage = Get-DiskImage -ImagePath $isoPath
    if ($diskImage)
    {
        $volume = Get-Volume -DiskImage $diskImage

        if ($volume)
        {
            $driveLetter = $volume.DriveLetter
            if ($driveLetter)
            {
                $driveLetter += ":"
                return $driveLetter
            }
        }
    }

    return $null
}

function Mount-ISO
{
    param ([string] $isoPath)

    # Check if image is already mounted
    $isoDrive = Get-ISODriveLetter $isoPath

    if (!$isoDrive)
    {
        Mount-DiskImage -ImagePath $isoPath -StorageType ISO | Out-Null
    }

    $isoDrive = Get-ISODriveLetter $isoPath
    Write-Verbose "$isoPath mounted to ${isoDrive}:"
}

function Dismount-ISO
{
    param ([string] $isoPath)

    $isoDrive = (Get-DiskImage -ImagePath $isoPath | Get-Volume).DriveLetter

    if ($isoDrive)
    {
        Write-Verbose "$isoPath dismounted"
        Dismount-DiskImage -ImagePath $isoPath | Out-Null
    }
}

function Disable-StrongName
{
    param ([string] $publicKeyToken = "*")

    reg ADD "HKLM\SOFTWARE\Microsoft\StrongName\Verification\*,$publicKeyToken" /f | Out-Null
    if ($env:PROCESSOR_ARCHITECTURE -eq "AMD64")
    {
        reg ADD "HKLM\SOFTWARE\Wow6432Node\Microsoft\StrongName\Verification\*,$publicKeyToken" /f | Out-Null
    }
}

function Test-Admin
{
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal $identity
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-RegistryPathAndValue
{
    param (
        [parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string] $path,
        [parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string] $value)

    try
    {
        if (Test-Path $path)
        {
            Get-ItemProperty -Path $path | Select-Object -ExpandProperty $value -ErrorAction Stop | Out-Null
            return $true
        }
    }
    catch
    {
    }

    return $false
}

function Test-InstallWindowsSDK
{
    $retval = $true

    if (Test-RegistryPathAndValue -Path $WindowsSDKRegPath -Value $WindowsSDKRegRootKey)
    {
        # A Windows SDK is installed
        # Is an SDK of our version installed with the options we need?
        $allRequiredSdkOptionsInstalled = $true
        foreach($sdkOption in $WindowsSDKOptions)
        {
            if (!(Test-RegistryPathAndValue -Path $WindowsSDKInstalledRegPath -Value $sdkOption))
            {
                $allRequiredSdkOptionsInstalled = $false
            }
        }

        if($allRequiredSdkOptionsInstalled)
        {
            # It appears we have what we need. Double check the disk
            $sdkRoot = Get-ItemProperty -Path $WindowsSDKRegPath | Select-Object -ExpandProperty $WindowsSDKRegRootKey
            if ($sdkRoot)
            {
                if (Test-Path $sdkRoot)
                {
                    $refPath = Join-Path $sdkRoot "References\$WindowsSDKVersion"
                    if (Test-Path $refPath)
                    {
                        $umdPath = Join-Path $sdkRoot "UnionMetadata\$WindowsSDKVersion"
                        if (Test-Path $umdPath)
                        {
                            # Pretty sure we have what we need
                            $retval = $false
                        }
                    }
                }
            }
        }
    }

    return $retval
}

function Test-InstallStrongNameHijack
{
    foreach($publicKeyToken in $PublicKeyTokens)
    {
        $key = "$StrongNameRegPath\*,$publicKeyToken"
        if (!(Test-Path $key))
        {
            return $true
        }
    }

    return $false
}

Write-Host -NoNewline "Checking for installed Windows SDK $WindowsSDKVersion..."
$InstallWindowsSDK = Test-InstallWindowsSDK
if ($InstallWindowsSDK)
{
    Write-Host "Installation required"
}
else
{
    Write-Host "INSTALLED"
}

#$StrongNameHijack = $false
$StrongNameHijack = Test-InstallStrongNameHijack
Write-Host -NoNewline "Checking if StrongName bypass required..."

if ($StrongNameHijack)
{
    Write-Host "REQUIRED"
}
else
{
    Write-Host "Done"
}

if ($StrongNameHijack -or $InstallWindowsSDK)
{
    if (!(Test-Admin))
    {
        Write-Host
        throw "ERROR: Elevation required"
    }
}

if ($InstallWindowsSDK)
{
    # Static(ish) link for Windows SDK
    # Note: there is a delay from Windows SDK announcements to availability via the static link
    # Note: stable version of the SDK have dedicated links (https://developer.microsoft.com/en-us/windows/downloads/sdk-archive/)
    switch ($buildNumber)
    {
        10240 { throw "The Windows SDK $buildNumber is not available in ISO format. Can't be installed." }
        10586 { throw "The Windows SDK $buildNumber is not available in ISO format. Can't be installed." }
        14393 { throw "The Windows SDK $buildNumber is not available in ISO format. Can't be installed." }
        15063 { throw "The Windows SDK $buildNumber is not available in ISO format. Can't be installed." }
        16299 { throw "The Windows SDK $buildNumber is not available in ISO format. Can't be installed." }
        17134 { throw "The Windows SDK $buildNumber is not available in ISO format. Can't be installed." }
        17763 { $uri = "https://go.microsoft.com/fwlink/p/?LinkID=2033686" }
        18362 { $uri = "https://go.microsoft.com/fwlink/?linkid=2083448" }
        19041 { $uri = "https://go.microsoft.com/fwlink/?linkid=2120735" }
        20348 { $uri = "https://go.microsoft.com/fwlink/?linkid=2164360" }
        22000 { $uri = "https://go.microsoft.com/fwlink/?linkid=2173746" }
        22621 { $uri = "https://go.microsoft.com/fwlink/?linkid=2249825" }
        26100 { $uri = "https://go.microsoft.com/fwlink/?linkid=2286663" }
        default { $uri = "https://software-download.microsoft.com/download/sg/Windows_InsiderPreview_SDK_en-us_$($buildNumber)_1.iso" }
    }

    if ($env:TEMP -eq $null)
    {
        $env:TEMP = Join-Path $env:SystemDrive 'temp'
    }

    $winsdkTempDir = Join-Path (Join-Path $env:TEMP ([System.IO.Path]::GetRandomFileName())) "WindowsSDK"

    if (![System.IO.Directory]::Exists($winsdkTempDir))
    {
        [void][System.IO.Directory]::CreateDirectory($winsdkTempDir)
    }

    $file = "winsdk_$buildNumber.iso"

    Write-Verbose "Getting WinSDK from $uri"
    $downloadFile = Download-File $winsdkTempDir $uri $file
    Write-Verbose "File is at $downloadFile"
    $downloadFileItem = Get-Item $downloadFile
    
    # Check to make sure the file is at least 10 MB.
    if ($downloadFileItem.Length -lt 10*1024*1024)
    {
        Write-Host
        Write-Host "ERROR: Downloaded file doesn't look large enough to be an ISO. The requested version may not be on microsoft.com yet."
        Write-Host
        Exit 1
    }

    # TODO Check if zip, exe, iso, etc.
    try
    {
        Write-Host -NoNewline "Mounting ISO $file..."
        Mount-ISO $downloadFile
        Write-Host "Done"

        $isoDrive = Get-ISODriveLetter $downloadFile

        if (Test-Path $isoDrive)
        {
            Write-Host -NoNewLine "Installing WinSDK..."

            $setupPath = Join-Path "$isoDrive" "WinSDKSetup.exe"
            $setupLog = Join-Path $winsdkTempDir "WinSDKSetup_$buildNumber.log"
            Start-Process -Wait $setupPath "/features $WindowsSDKOptions /l $setupLog /q"
            Write-Host "Done"

            # Validate if the SDK was properly installed
            if (Test-InstallWindowsSDK)
            {
                throw "Windows SDK $WindowsSDKVersion was not properly installed. See $setupLog for details."
            }
        }
        else
        {
            throw "Could not find mounted ISO at ${isoDrive}"
        }
    }
    finally
    {
        Write-Host -NoNewline "Dismounting ISO $file..."
        Dismount-ISO $downloadFile
        Write-Host "Done"
    }
}

if ($StrongNameHijack)
{
    Write-Host -NoNewline "Disabling StrongName for Windows SDK..."

    foreach($key in $PublicKeyTokens)
    {
        Disable-StrongName $key
    }

    Write-Host "Done"
}