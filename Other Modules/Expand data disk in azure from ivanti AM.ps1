<#
.SYNOPSIS
    Expands a non-OS data disk on an Azure VM and extends the Windows volume inside the guest.
    Runs as an Ivanti Automation Manager

.DESCRIPTION
    - Finds the VM by name (no resource group input required)
    - Maps the requested drive letter to the backing Azure Managed Disk via in-guest discovery
    - Hard-blocks OS disk expansion (non-OS disks only)
    - Shows a preview of the planned change before executing
    - Resizes the Azure Managed Disk
    - For Premium SSD v2 / Ultra disks: automatically calculates and applies the maximum
      IOPS and Throughput for the new size (no manual performance input needed)
    - Extends the Windows partition to use the newly available space

    One disk per execution. Provide one request per server.

.NOTES
    Error Codes:
        1000 - Input validation failed (VMName)
        1001 - Input validation failed (DriveLetter)
        1002 - Input validation failed (NewSizeGB)
        2000 - Azure login failed
        3000 - VM not found
        4000 - Guest discovery failed (RunCommand returned no data)
        4001 - OS disk detected (blocked)
        4002 - LUN could not be determined
        5000 - Azure data disk not found for LUN
        5001 - Azure disk metadata retrieval failed
        6000 - Validation: new size not larger than current
        7000 - Azure disk resize failed
        7001 - Azure disk resize verification failed
        8000 - Guest volume extension failed (RunCommand returned no data)
        8001 - Guest volume extension command error
        9000 - Unexpected error
#>
# Azure-ExpandDataDisk.ps1
# Version: 2026.05.08.2
# Copyright (c) 2026 Joppe Schelvis. All rights reserved.
#
# ============================
# Ivanti Automation Manager variables (injected at runtime)
# ============================
$tenantId        = "^[Id.Tenant]"
$subscriptionId  = "^[Id.Subscription]"
$appId           = "^[App.IAM.Application.Id]"
$clientSecretId  = "^[App.IAM.Client.Secret.Id]"
$clientSecretVal = "^[App.IAM.Client.Secret.Value]"

# ============================
# Consultant input variables (injected by Ivanti AM)
# ============================
$vmName             = "$[VMName]"
$driveLetter        = "$[DriveLetter]"
$newSizeGB          = "$[NewSizeGB]"

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ============================
# Helper: structured error exit
# ============================
function Exit-WithError {
    param(
        [int]$Code,
        [string]$Step,
        [string]$Message
    )
    Write-Output ""
    Write-Output "========== ERROR =========="
    Write-Output "Error Code:   $Code"
    Write-Output "Step:         $Step"
    Write-Output "Message:      $Message"
    Write-Output "==========================="
    throw "[$Code] $Step - $Message"
}

# ============================
# Step 1: Input validation
# ============================
if ([string]::IsNullOrWhiteSpace($vmName)) {
    Exit-WithError -Code 1000 -Step "InputValidation" -Message "VMName is required."
}

$driveLetter = $driveLetter.Trim().TrimEnd(':').ToUpperInvariant()
if ($driveLetter -notmatch '^[A-Z]$') {
    Exit-WithError -Code 1001 -Step "InputValidation" -Message "DriveLetter must be a single letter (A-Z). Got: '$driveLetter'"
}

$newSizeGB = $newSizeGB.Trim()
if ($newSizeGB -notmatch '^\d+$' -or [int]$newSizeGB -lt 1 -or [int]$newSizeGB -gt 65536) {
    Exit-WithError -Code 1002 -Step "InputValidation" -Message "NewSizeGB must be an integer between 1 and 65536. Got: '$newSizeGB'"
}
[int]$newSizeGB = [int]$newSizeGB

# ============================
# Step 2: Azure login (Service Principal)
# ============================
Write-Output "Connecting to Azure using Service Principal..."
try {
    $secureSecret = ConvertTo-SecureString $clientSecretVal -AsPlainText -Force
    $credential   = New-Object System.Management.Automation.PSCredential($appId, $secureSecret)

    Connect-AzAccount -ServicePrincipal `
                      -Tenant $tenantId `
                      -Credential $credential `
                      -Subscription $subscriptionId -ErrorAction Stop

    Write-Output "Connected to Azure."
}
catch {
    Exit-WithError -Code 2000 -Step "AzureLogin" -Message "Failed to connect to Azure: $($_.Exception.Message)"
}

# ============================
# Step 3: Find VM by name
# ============================
Write-Output "Searching for VM '$vmName'..."
try {
    $vm = Get-AzVM | Where-Object { $_.Name -eq $vmName }
}
catch {
    Exit-WithError -Code 3000 -Step "FindVM" -Message "Error querying VMs: $($_.Exception.Message)"
}

if (-not $vm) {
    Exit-WithError -Code 3000 -Step "FindVM" -Message "VM '$vmName' not found in subscription '$subscriptionId'."
}

$vmRG = $vm.ResourceGroupName
Write-Output "Found VM '$vmName' in resource group '$vmRG'."

# ============================
# Step 4: Guest discovery (drive letter -> disk number -> OS/LUN)
# ============================
Write-Output "Discovering guest disk mapping for drive $($driveLetter):..."

$guestDiscoveryScript = @"
`$ErrorActionPreference = 'Stop'
`$drive = '$driveLetter'

`$part = Get-Partition -DriveLetter `$drive
`$diskNumber = `$part.DiskNumber

`$isOsDisk = (Get-Partition -DiskNumber `$diskNumber | Where-Object { `$_.IsBoot -or `$_.IsSystem } | Measure-Object).Count -gt 0

`$lun = `$null
try {
    `$dd = Get-CimInstance Win32_DiskDrive | Where-Object { `$_.Index -eq `$diskNumber } | Select-Object -First 1
    if (`$dd) { `$lun = `$dd.SCSILogicalUnit }
} catch { }

`$supported = Get-PartitionSupportedSize -DriveLetter `$drive
`$volSizeGB = [math]::Round((Get-Partition -DriveLetter `$drive).Size / 1GB, 2)

[pscustomobject]@{
    DriveLetter     = `$drive
    DiskNumber      = `$diskNumber
    IsOsDisk        = `$isOsDisk
    Lun             = `$lun
    VolumeSizeGB    = `$volSizeGB
} | ConvertTo-Json -Depth 5
"@

try {
    $run = Invoke-AzVMRunCommand -ResourceGroupName $vmRG -Name $vmName -CommandId 'RunPowerShellScript' -ScriptString $guestDiscoveryScript
    $json = ($run.Value | Select-Object -First 1).Message
}
catch {
    Exit-WithError -Code 4000 -Step "GuestDiscovery" -Message "RunCommand failed: $($_.Exception.Message). Ensure the VM is running and the VM Agent is healthy."
}

if (-not $json) {
    Exit-WithError -Code 4000 -Step "GuestDiscovery" -Message "RunCommand returned no data. Ensure the VM is running, the VM Agent is healthy, and drive $($driveLetter): exists."
}

$guest = $json | ConvertFrom-Json

# Hard-block OS disk
if ($guest.IsOsDisk -eq $true) {
    Exit-WithError -Code 4001 -Step "GuestDiscovery" -Message "Drive $($driveLetter): is the OS disk. This script only supports non-OS (data) disk expansion."
}

if ($null -eq $guest.Lun) {
    Exit-WithError -Code 4002 -Step "GuestDiscovery" -Message "Could not determine the LUN for drive $($driveLetter):. The disk may not be a standard SCSI-attached data disk."
}

# ============================
# Step 5: Resolve Azure Managed Disk
# ============================
$dataDisk = $vm.StorageProfile.DataDisks | Where-Object { $_.Lun -eq [int]$guest.Lun } | Select-Object -First 1
if (-not $dataDisk) {
    Exit-WithError -Code 5000 -Step "ResolveDisk" -Message "No Azure data disk found with LUN $($guest.Lun) for drive $($driveLetter):."
}

$diskId = $dataDisk.ManagedDisk.Id
$diskIdParts = $diskId.Trim('/') -split '/'
$diskRG   = $diskIdParts[3]
$diskName = $diskIdParts[-1]

try {
    $azDisk = Get-AzDisk -ResourceGroupName $diskRG -DiskName $diskName -ErrorAction Stop
}
catch {
    Exit-WithError -Code 5001 -Step "ResolveDisk" -Message "Failed to retrieve disk '$diskName' in RG '$diskRG': $($_.Exception.Message)"
}

$currentSizeGB      = [int]$azDisk.DiskSizeGB
$currentIops        = $azDisk.DiskIOPSReadWrite
$currentThroughput  = $azDisk.DiskMBpsReadWrite
$diskSku            = $azDisk.Sku.Name

$isPremiumV2 = $diskSku -eq "PremiumV2_LRS"
$isUltra     = $diskSku -eq "UltraSSD_LRS"

# ============================
# Step 6: Validate constraints
# ============================
if ($newSizeGB -le $currentSizeGB) {
    Exit-WithError -Code 6000 -Step "Validation" -Message "Requested size ($newSizeGB GB) is not larger than current disk size ($currentSizeGB GB). Azure disks can only grow."
}

# ============================
# Auto-calculate performance for Premium SSD v2 / Ultra
# ============================
$newIops = $null
$newThroughputMBps = $null

if ($isPremiumV2) {
    $newIops = [math]::Min(80000, 3000 + [math]::Max(0, ($newSizeGB - 6)) * 500)
    $newThroughputMBps = [math]::Min(2000, [int]($newIops * 0.25))
    Write-Output "Auto-calculated performance for Premium SSD v2 (max for $newSizeGB GB): $newIops IOPS, $newThroughputMBps MB/s"
}
elseif ($isUltra) {
    $newIops = [math]::Min(400000, $newSizeGB * 1000)
    $newThroughputMBps = [math]::Min(10000, [int]($newIops * 0.25))
    Write-Output "Auto-calculated performance for Ultra disk (max for $newSizeGB GB): $newIops IOPS, $newThroughputMBps MB/s"
}

# ============================
# Preview
# ============================
$plannedIops       = if ($newIops)       { $newIops }            else { "(unchanged) $currentIops" }
$plannedThroughput = if ($newThroughputMBps) { "$newThroughputMBps MB/s" } else { "(unchanged) $currentThroughput MB/s" }

Write-Output ""
Write-Output "========== DISK EXPANSION PREVIEW =========="
Write-Output "VM Name:              $vmName"
Write-Output "Resource Group:       $vmRG"
Write-Output "Drive Letter:         $($driveLetter):"
Write-Output "Current Volume Size:  $($guest.VolumeSizeGB) GB"
Write-Output "---"
Write-Output "Azure Disk Name:      $diskName"
Write-Output "Disk SKU:             $diskSku"
Write-Output "Current Disk Size:    $currentSizeGB GB"
Write-Output "New Disk Size:        $newSizeGB GB  (+$($newSizeGB - $currentSizeGB) GB)"
if ($isPremiumV2 -or $isUltra) {
    Write-Output "Current IOPS:         $currentIops"
    Write-Output "New IOPS:             $plannedIops"
    Write-Output "Current Throughput:   $currentThroughput MB/s"
    Write-Output "New Throughput:       $plannedThroughput"
}
Write-Output "============================================"
Write-Output ""

# ============================
# Step 7: Resize Azure disk
# ============================
Write-Output "Resizing Azure disk '$diskName' from $currentSizeGB GB to $newSizeGB GB..."

$updateParams = @{ DiskSizeGB = $newSizeGB }
if ($newIops)           { $updateParams['DiskIOPSReadWrite'] = $newIops }
if ($newThroughputMBps) { $updateParams['DiskMBpsReadWrite'] = $newThroughputMBps }

try {
    $diskUpdate = New-AzDiskUpdateConfig @updateParams
    Update-AzDisk -ResourceGroupName $diskRG -DiskName $diskName -DiskUpdate $diskUpdate | Out-Null
}
catch {
    Exit-WithError -Code 7000 -Step "ResizeAzureDisk" -Message "Failed to resize disk '$diskName': $($_.Exception.Message)"
}

try {
    $azDisk = Get-AzDisk -ResourceGroupName $diskRG -DiskName $diskName -ErrorAction Stop
}
catch {
    Exit-WithError -Code 7001 -Step "ResizeAzureDisk" -Message "Disk resize may have succeeded but verification failed: $($_.Exception.Message)"
}
Write-Output "Azure disk resized successfully. New size: $($azDisk.DiskSizeGB) GB"

# ============================
# Step 8: Extend guest volume
# ============================
Write-Output "Extending Windows volume $($driveLetter): inside the VM..."

$guestExtendScript = @"
`$ErrorActionPreference = 'Stop'
`$drive = '$driveLetter'

try { Update-HostStorageCache | Out-Null } catch { }

`$before = (Get-Partition -DriveLetter `$drive).Size
`$supported = Get-PartitionSupportedSize -DriveLetter `$drive
Resize-Partition -DriveLetter `$drive -Size `$supported.SizeMax | Out-Null
`$after = (Get-Partition -DriveLetter `$drive).Size

[pscustomobject]@{
    DriveLetter  = `$drive
    BeforeSizeGB = [math]::Round(`$before / 1GB, 2)
    AfterSizeGB  = [math]::Round(`$after / 1GB, 2)
    ExtendedByGB = [math]::Round((`$after - `$before) / 1GB, 2)
} | ConvertTo-Json -Depth 5
"@

try {
    $run2 = Invoke-AzVMRunCommand -ResourceGroupName $vmRG -Name $vmName -CommandId 'RunPowerShellScript' -ScriptString $guestExtendScript
    $json2 = ($run2.Value | Select-Object -First 1).Message
}
catch {
    Exit-WithError -Code 8001 -Step "ExtendGuestVolume" -Message "RunCommand failed: $($_.Exception.Message). The Azure disk WAS resized to $newSizeGB GB. Extend the volume manually via Disk Management."
}

if (-not $json2) {
    Exit-WithError -Code 8000 -Step "ExtendGuestVolume" -Message "RunCommand returned no data. The Azure disk WAS resized to $newSizeGB GB. Extend the volume manually via Disk Management."
}

$guest2 = $json2 | ConvertFrom-Json

# ============================
# Final report
# ============================
Write-Output ""
Write-Output "========== RESULT =========="
Write-Output "Status:              SUCCESS"
Write-Output "VM:                  $vmName ($vmRG)"
Write-Output "Drive:               $($driveLetter):"
Write-Output "Azure Disk:          $diskName ($diskSku)"
Write-Output "Disk Size:           $currentSizeGB GB -> $($azDisk.DiskSizeGB) GB"
Write-Output "Volume Size:         $($guest2.BeforeSizeGB) GB -> $($guest2.AfterSizeGB) GB"
Write-Output "Extended By:         $($guest2.ExtendedByGB) GB"
if ($isPremiumV2 -or $isUltra) {
    Write-Output "IOPS:                $currentIops -> $($azDisk.DiskIOPSReadWrite)"
    Write-Output "Throughput:          $currentThroughput -> $($azDisk.DiskMBpsReadWrite) MB/s"
}
Write-Output "============================"
