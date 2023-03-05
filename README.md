# Windows SDK Install action

This action allows to locally install the Windows SDK if needed.

This action is based on a script available in the Windows Community Toolkit [here](https://github.com/CommunityToolkit/WindowsCommunityToolkit/blob/main/build/Install-WindowsSdkISO.ps1).

## Requirements

- A Windows runner

## What's new

Refer [here](CHANGELOG.md) to the changelog.

## Inputs

| Input | Required | Example | Default Value | Description |
|-|-|-|-|-|
| `version-sdk`          | Yes | 22621  | | Version of the Windows SDK to install |
| `features`          | Yes | "OptionId.UWPCPP,OptionId.DesktopCPParm64"  | | Features of the Windows SDK to install (corresponding of the `WinSDKSetup.exe /features` switch) separated by a comma |

The available features of the Windows 10/11 SDK are:
- OptionId.WindowsPerformanceToolkit
- OptionId.WindowsDesktopDebuggers
- OptionId.AvrfExternal
- OptionId.NetFxSoftwareDevelopmentKit
- OptionId.WindowsSoftwareLogoToolkit
- OptionId.IpOverUsb
- OptionId.MSIInstallTools
- OptionId.SigningTools
- OptionId.UWPManaged
- OptionId.UWPCPP
- OptionId.UWPLocalized
- OptionId.DesktopCPPx86
- OptionId.DesktopCPPx64
- OptionId.DesktopCPParm
- OptionId.DesktopCPParm64

## Usage

<!-- start usage -->
```yaml
- uses: ChristopheLav/windows-sdk-install@v1
  with:
    version-sdk: 22621
    features: "OptionId.UWPCPP,OptionId.DesktopCPParm64"
```
<!-- end usage -->

## License

The scripts and documentation in this project are released under the [MIT License](LICENSE)