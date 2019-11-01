#Import needed modules
Import-Module Rubrik
Import-Module SQLServer

# Check for CLEANUP variable, and set it to false if not found
if($null -eq $env:CLEANUP) { $env:CLEANUP = $false }

$sleep = 60
$clusterip = "192.168.150.121"
$vmname = "DEMO-WIN-ME"
$azid = "70b05bfa-7ea1-4412-809b-648306a624d7"
$aznsg = "/subscriptions/2d689783-3072-4fb2-b518-cf95cfbb6279/resourceGroups/tm-usw2-cloudon-rg/providers/Microsoft.Network/networkSecurityGroups/tm-usw2-cloudon-nsg"
$azvn = "/subscriptions/2d689783-3072-4fb2-b518-cf95cfbb6279/resourceGroups/tm-vpn-usw2-rg/providers/Microsoft.Network/virtualNetworks/tm-10.1.0.0-usw2-vnet"
$azrg = "/subscriptions/2d689783-3072-4fb2-b518-cf95cfbb6279/resourceGroups/tm-usw2-cloudon-rg"

# Connect to Rubrik cluster, retrieve VM and snapshot info
Connect-Rubrik -Server $clusterip -Token $env:KEY | Out-Null

$vm = Get-RubrikVM -Name $vmname -DetailedObject -PrimaryClusterID local

if ($vm.count -gt 1) {
    Throw "More than one VM returned"
} elseif ($vm.count -eq 0) {
    Throw "No VMs named $($vmname) found"
}

Write-Output "Using $($vm.name) with ID $($vm.id) as source VM"

$snapshot = Get-RubrikSnapshot -id $vm.id -Latest

if ($snapshot.cloudState -ne 3 -and $snapshot.cloudState -ne 6) {
    Throw "Latest snapshot is not archived to cloud"
}

Write-Output "Using Snapshot ID $($snapshot.id)"

# Initiate cloud mount using specified values
$body = @{
    "snappableId" = $vm.id
    "snapshotId" = $snapshot.id
    "instantiateLocationId" = $azid
    "instanceType" = "Standard_A2m_v2"
    "source" = "Snapshot"
    "subnet" = "default"
    "securityGroup" = $aznsg
    "virtualNetwork" = $azvn
    "resourceGroup" = $azrg
}

Write-Output "Attempting to Cloud Mount $($vm.name)"
$cloudmount = Invoke-RubrikRESTCall -endpoint "cloud_on/azure/instance" -Method POST -Body $body -api internal 
$url = $cloudmount.links.href
$endpoint = $url -replace "^.*?(cloud_on\/azure\/request\/.*?)$", '$1'

# Monitor Cloud Mount status and wait for completion
$cloudmounttask = Invoke-RubrikRESTCall -Endpoint $endpoint -Method GET -api internal
Write-Output "Cloud Mount Status: $($cloudmounttask.status)"

Start-Sleep 10
$counter = 0

while($cloudmounttask.status -ne "SUCCEEDED")
{
    Write-Output "Cloud Mount status: $($cloudmounttask.status) - $($cloudmounttask.progress)% Complete"
    $cloudmounttask = Invoke-RubrikRESTCall -Endpoint $endpoint -Method GET -api internal
    $counter += 1
    Start-Sleep 10
    if($counter -eq 30) { throw "Cloud Mount took too long" }
}

Write-Output "Cloud Mount Status: $($cloudmounttask.status)"

# Verify Cloud Mount and connectivity
$azmounts = Invoke-RubrikRESTCall -Endpoint "cloud_on/azure/instance" -Method GET -api internal
if($azmounts.count -eq 0 ) { throw "No Azure Cloud Mounts Found" }
$azvm = ($azmounts.data | Where-Object { $_.snappableId -eq $vm.id} )
if($null -eq $azvm) { throw "Could not find Cloud Mount for $($vm.name)" }

Write-Output "Cloud Mount IP: $($azvm.privateIpAddress)"
$conntest = $false
$counter = 0

while($conntest -eq $false) {
    if(Test-Connection -TargetName $azvm.privateIpAddress -Quiet) {
        Write-Output "Ping test successful"
        $conntest = $true
    }
    $counter += 1
    if($conntest -eq $false) { Start-Sleep 10 }
    if($counter -eq 30) { throw "Connection test failed"}
}

# After connectivity is verified, sleep for a bit to give SQL Server time to start
Write-Output "Sleeping $($sleep) seconds to allow services to start"
Start-Sleep $sleep

# Run dbcc checkdb
$User = "sa"
$PWord = ConvertTo-SecureString -String "Rubrik123!" -AsPlainText -Force
$Creds = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $User, $PWord

Write-Output "Running dbcc checkdb on $($vm.name) Cloud Mount - $($azvm.privateIpAddress)"
$results = Invoke-Sqlcmd -Query "dbcc checkdb(); select @@spid as SessionID;" -ServerInstance $azvm.privateIpAddress -Database "AdventureWorks2014" -Credential $Creds
$spid = "spid" + $results.sessionID
$logresults = Get-SqlErrorLog -ServerInstance $azvm.privateIpAddress -Credential $Creds | where-object { $_.Source -eq $spid } | `
Sort-Object -Property Date -Descending | Select-Object -First 1

Write-Output "Results of dbcc checkdb"
Write-Output "================================================================"
Write-Output $logresults.Text
Write-Output "================================================================"

# If environment variable CLEANUP = TRUE, shut down and terminate cloud mount
If($env:CLEANUP) {
    Write-Output "Powering off Cloud Mount"

    $urlid = [System.Web.HttpUtility]::UrlEncode($azvm.id)
    try {
        $poweroff = Invoke-RubrikRESTCall -endpoint "cloud_on/azure/instance/$($urlid)/cloud_vm" -Method PATCH -Body @{"powerStatus" = "OFF"} -api internal 
    }
    catch {
        Write-Output "Cloud Mount is slow to shut down"
        $azvm = Invoke-RubrikRESTCall -endpoint "cloud_on/azure/instance/$($urlid)" -Method GET -api internal 
        Write-Output "VM Status: $($azvm.powerStatus)"

        $counter = 0

        while($azvm.powerStatus -ne "stopped")
        {
            Start-Sleep 10
            $azvm = Invoke-RubrikRESTCall -endpoint "cloud_on/azure/instance/$($urlid)" -Method GET -api internal
            $counter += 1
            if($counter -eq 30) { throw "Error stopping VM" }
            Write-Output "VM Status: $($azvm.powerStatus)"
        }
    }

    Write-Output "Terminating Cloud Mount"

    $poweroff = Invoke-RubrikRESTCall -endpoint "cloud_on/azure/instance/$($urlid)/cloud_vm" -Method DELETE -api internal 
    Start-Sleep 10
    $url = $poweroff.links.href
    $endpoint = $url -replace "^.*?(cloud_on\/azure\/request\/.*?)$", '$1'

    $powerofftask = Invoke-RubrikRESTCall -Endpoint $endpoint -Method GET -api internal
    Write-Output "Termination status: $($powerofftask.status)"

    $counter = 0

    while($powerofftask.status -ne "SUCCEEDED")
    {
        Write-Output "Termination status: $($powerofftask.status)"
        Start-Sleep 10
        $powerofftask = Invoke-RubrikRESTCall -Endpoint $endpoint -Method GET -api internal
        $counter += 1
        if($counter -eq 30) { throw "Error terminating VM" }
    }

    Write-Output "Hasta la vista, baby"
}
