[CmdletBinding(DefaultParameterSetName="Standard")]
Param(
    [ValidateNotNullOrEmpty()]
    [string]$MasterIP,
    [ValidateNotNullOrEmpty()]
    [string]$AgentPrivateIP,
    [ValidateNotNullOrEmpty()]
    [string]$BootstrapUrl,
    [AllowNull()]
    [switch]$isPublic = $false,
    [AllowNull()]
    [string]$MesosDownloadDir,
    [AllowNull()]
    [string]$MesosInstallDir,
    [AllowNull()]
    [string]$MesosLaunchDir,
    [AllowNull()]
    [string]$MesosWorkDir,
    [AllowNull()]
    [string]$customAttrs
)

$ErrorActionPreference = "Stop"

$UPSTREAM_INIT_SCRIPT = "http://dcos-win.westus.cloudapp.azure.com/dcos-windows/stable/DCOSWindowsAgentSetup.ps1"
$CONFIG_WINRM_SCRIPT = "https://raw.githubusercontent.com/ansible/ansible/v2.5.0a1/examples/scripts/ConfigureRemotingForAnsible.ps1"


function Start-ExecuteWithRetry {
    Param(
        [Parameter(Mandatory=$true)]
        [ScriptBlock]$ScriptBlock,
        [int]$MaxRetryCount=10,
        [int]$RetryInterval=3,
        [string]$RetryMessage,
        [array]$ArgumentList=@()
    )
    $currentErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $retryCount = 0
    while ($true) {
        try {
            $res = Invoke-Command -ScriptBlock $ScriptBlock `
                                  -ArgumentList $ArgumentList
            $ErrorActionPreference = $currentErrorActionPreference
            return $res
        } catch [System.Exception] {
            $retryCount++
            if ($retryCount -gt $MaxRetryCount) {
                $ErrorActionPreference = $currentErrorActionPreference
                throw
            } else {
                if($RetryMessage) {
                    Write-Output $RetryMessage
                } elseif($_) {
                    Write-Output $_.ToString()
                }
                Start-Sleep $RetryInterval
            }
        }
    }
}

try {
    #
    # Enable the SMB firewall rule needed when collecting logs
    #
    Set-NetFirewallRule -Name 'FPS-SMB-In-TCP' -Enabled True

    #
    # Configure WinRM
    #
    $configWinRMScript = Join-Path $env:SystemDrive "AzureData\ConfigureWinRM.ps1"
    Start-ExecuteWithRetry -ScriptBlock { Invoke-WebRequest -UseBasicParsing -Uri $CONFIG_WINRM_SCRIPT -OutFile $configWinRMScript } `
                           -MaxRetryCount 30 -RetryInterval 3 -RetryMessage "Failed to download ConfigureWinRM.ps1 script. Retrying"
    & $configWinRMScript
    if($LASTEXITCODE -ne 0) {
        Throw "Failed to configure WinRM"
    }

    #
    # Enable Docker debug logging and capture stdout and stderr to a file.
    # We're using the updated service wrapper for this.
    #
    $serviceName = "Docker"
    $dockerHome = Join-Path $env:ProgramFiles "Docker"
    $wrapperUrl = "http://dcos-win.westus.cloudapp.azure.com/downloads/service-wrapper.exe"
    Stop-Service $serviceName
    sc.exe delete $serviceName
    if($LASTEXITCODE) {
        Throw "Failed to delete service: $serviceName"
    }
    Start-ExecuteWithRetry -ScriptBlock { Invoke-WebRequest -UseBasicParsing -Uri $wrapperUrl -OutFile "${dockerHome}\service-wrapper.exe" } `
                           -MaxRetryCount 30 -RetryInterval 3 -RetryMessage "Failed to download service-wrapper.exe. Retrying"
    $binPath = ("`"${dockerHome}\service-wrapper.exe`" " +
                "--service-name `"$serviceName`" " +
                "--exec-start-pre `"powershell.exe if(Test-Path '${env:ProgramData}\docker\docker.pid') { Remove-Item -Force '${env:ProgramData}\docker\docker.pid' }`" " +
                "--log-file `"$dockerHome\dockerd.log`" " +
                "`"$dockerHome\dockerd.exe`" -D")
    New-Service -Name $serviceName -StartupType "Automatic" -Confirm:$false `
                -DisplayName "Docker Windows Agent" -BinaryPathName $binPath
    sc.exe failure $serviceName reset=5 actions=restart/1000
    if($LASTEXITCODE) {
        Throw "Failed to set $serviceName service recovery options"
    }
    sc.exe failureflag $serviceName 1
    if($LASTEXITCODE) {
        Throw "Failed to set $serviceName service recovery options"
    }
    Start-Service $serviceName

    #
    # Call upstream script before doing any CI specific steps
    #
    $stableInitScript = Join-Path $env:SystemDrive "AzureData\Stable-DCOSWindowsAgentSetup.ps1"
    Start-ExecuteWithRetry -ScriptBlock { Invoke-WebRequest -UseBasicParsing -Uri $UPSTREAM_INIT_SCRIPT -OutFile $stableInitScript } `
                           -MaxRetryCount 30 -RetryInterval 3 -RetryMessage "Failed to download stable DCOSWindowsAgentSetup.ps1 script. Retrying"
    & $stableInitScript -MasterIP $MasterIP `
                        -AgentPrivateIP $AgentPrivateIP `
                        -BootstrapUrl $BootstrapUrl `
                        -isPublic:$isPublic `
                        -MesosDownloadDir $MesosDownloadDir `
                        -MesosInstallDir $MesosInstallDir `
                        -MesosLaunchDir $MesosLaunchDir `
                        -MesosWorkDir $MesosWorkDir `
                        -customAttrs $customAttrs
    if($LASTEXITCODE -ne 0) {
        Throw "The upstream DCOS init script failed"
    }
} catch {
    Write-Output $_.ToString()
    Write-Output $_.ScriptStackTrace
    Write-Output "Failed to initialize the DCOS node for CI"
    exit 1
}
exit 0
