<#
.SYNOPSIS
    Creates a new managed data disk, attaches it to an Azure VM, and formats it inside Windows.

.DESCRIPTION
    - Authenticates via Ivanti Automation Manager Service Principal
    - Finds the VM by name (no resource group input required)
    - Creates a new managed disk with selected SKU (Standard SSD or Premium SSD)
    - Attaches the disk to the VM on the next available LUN
    - Initializes, partitions, and formats the disk in-guest using RunCommand
    - Assigns a consultant-provided drive letter

    One disk per execution. Provide one request per server.

.NOTES
    Error Codes:
        1000 - Input validation failed (VMName)
        1002 - Input validation failed (NewSizeGB)
        1003 - Input validation failed (DiskType)
        1004 - Input validation failed (DiskName)
        1005 - Input validation failed (DriveLetter)
        2000 - Azure login failed
        3000 - VM lookup failed
        3001 - VM name is ambiguous in subscription
        3002 - No available LUN found
        5002 - Disk already exists
        7002 - Azure disk creation failed
        7003 - Azure disk attachment failed
        7004 - Azure disk attachment verification failed
        8002 - Guest initialization failed (RunCommand)
        8003 - Guest initialization returned no data
        8004 - Guest initialization returned invalid data
        9000 - Unexpected error
#>
# Azure-CreateAndAttachDataDisk.ps1
# Version: 2026.06.16.2
# Copyright (c) 2026 Joppe Schelvis. All rights reserved.

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
$vmName            = "$[VMName]"
$newSizeGB         = "$[NewSizeGB]"
$diskType          = "$[DiskType]"
$diskName          = "$[DiskName]"
$driveLetterInput  = "$[DriveLetter]"

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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

function Resolve-DiskSkuName {
    param(
        [string]$InputValue
    )

    $normalized = $InputValue.Trim().ToLowerInvariant()
    switch ($normalized) {
        'standard ssd' { return 'StandardSSD_LRS' }
        'standardssd' { return 'StandardSSD_LRS' }
        'standardssd_lrs' { return 'StandardSSD_LRS' }
        'standardssd-lrs' { return 'StandardSSD_LRS' }
        'premium ssd' { return 'Premium_LRS' }
        'premiumssd' { return 'Premium_LRS' }
        'premium_lrs' { return 'Premium_LRS' }
        'premium-lrs' { return 'Premium_LRS' }
        default { return $null }
    }
}

function Get-NextAvailableLun {
    param(
        [object[]]$DataDisks
    )

    $usedLuns = @($DataDisks | ForEach-Object { [int]$_.Lun })
    for ($lun = 0; $lun -le 63; $lun++) {
        if ($usedLuns -notcontains $lun) {
            return $lun
        }
    }

    return $null
}

try {
    # ============================
    # Step 1: Input validation
    # ============================
    if ([string]::IsNullOrWhiteSpace($vmName)) {
        Exit-WithError -Code 1000 -Step "InputValidation" -Message "VMName is required."
    }
    $vmName = $vmName.Trim()

    if ([string]::IsNullOrWhiteSpace($diskName)) {
        Exit-WithError -Code 1004 -Step "InputValidation" -Message "DiskName is required."
    }
    $diskName = $diskName.Trim()

    $newSizeGB = $newSizeGB.Trim()
    if ($newSizeGB -notmatch '^\d+$' -or [int]$newSizeGB -lt 4 -or [int]$newSizeGB -gt 65536) {
        Exit-WithError -Code 1002 -Step "InputValidation" -Message "NewSizeGB must be an integer between 4 and 65536. Got: '$newSizeGB'"
    }
    [int]$newSizeGB = [int]$newSizeGB

    if ([string]::IsNullOrWhiteSpace($diskType)) {
        Exit-WithError -Code 1003 -Step "InputValidation" -Message "DiskType is required. Use 'Standard SSD' or 'Premium SSD'."
    }
    $diskSkuName = Resolve-DiskSkuName -InputValue $diskType
    if ([string]::IsNullOrWhiteSpace($diskSkuName)) {
        Exit-WithError -Code 1003 -Step "InputValidation" -Message "DiskType '$diskType' is invalid. Use 'Standard SSD' or 'Premium SSD'."
    }

    if ([string]::IsNullOrWhiteSpace($driveLetterInput)) {
        Exit-WithError -Code 1005 -Step "InputValidation" -Message "DriveLetter is required. Provide a single letter, for example 'F'."
    }
    $driveLetterInput = $driveLetterInput.Trim().ToUpperInvariant()
    if ($driveLetterInput -notmatch '^[A-Z]$') {
        Exit-WithError -Code 1005 -Step "InputValidation" -Message "DriveLetter '$driveLetterInput' is invalid. Provide a single letter A-Z."
    }
    if ($driveLetterInput -eq 'C') {
        Exit-WithError -Code 1005 -Step "InputValidation" -Message "DriveLetter 'C' is reserved for OS volume. Choose another letter."
    }

    # ============================
    # Step 2: Azure login
    # ============================
    Write-Output "Connecting to Azure using Service Principal..."
    try {
        $secureSecret = ConvertTo-SecureString $clientSecretVal -AsPlainText -Force
        $credential = New-Object System.Management.Automation.PSCredential($appId, $secureSecret)

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
    # Step 3: Find VM and compute LUN
    # ============================
    Write-Output "Searching for VM '$vmName'..."
    try {
        $vms = @(Get-AzVM | Where-Object { $_.Name -eq $vmName })
    }
    catch {
        Exit-WithError -Code 3000 -Step "FindVM" -Message "Error querying VMs: $($_.Exception.Message)"
    }

    if ($vms.Count -eq 0) {
        Exit-WithError -Code 3000 -Step "FindVM" -Message "VM '$vmName' not found in subscription '$subscriptionId'."
    }

    if ($vms.Count -gt 1) {
        $rgList = ($vms | ForEach-Object { $_.ResourceGroupName } | Sort-Object -Unique) -join ', '
        Exit-WithError -Code 3001 -Step "FindVM" -Message "Multiple VMs named '$vmName' found. Resource groups: $rgList"
    }

    $vm = $vms[0]
    $vmRG = $vm.ResourceGroupName
    $vmLocation = $vm.Location

    Write-Output "Found VM '$vmName' in resource group '$vmRG'."

    $nextLun = Get-NextAvailableLun -DataDisks $vm.StorageProfile.DataDisks
    if ($null -eq $nextLun) {
        Exit-WithError -Code 3002 -Step "FindNextLun" -Message "No available LUN (0-63) found on VM '$vmName'."
    }

    # ============================
    # Step 4: Create managed disk
    # ============================
    Write-Output "Checking whether disk '$diskName' already exists in resource group '$vmRG'..."
    $existingDisk = $null
    try {
        $existingDisk = Get-AzDisk -ResourceGroupName $vmRG -DiskName $diskName -ErrorAction SilentlyContinue
    }
    catch {
        $existingDisk = $null
    }

    if ($existingDisk) {
        Exit-WithError -Code 5002 -Step "CreateDisk" -Message "A disk named '$diskName' already exists in resource group '$vmRG'."
    }

    Write-Output ""
    Write-Output "========== CREATE + ATTACH PREVIEW =========="
    Write-Output "VM Name:              $vmName"
    Write-Output "Resource Group:       $vmRG"
    Write-Output "Location:             $vmLocation"
    Write-Output "Disk Name:            $diskName"
    Write-Output "Disk SKU:             $diskSkuName"
    Write-Output "Disk Size:            $newSizeGB GB"
    Write-Output "LUN:                  $nextLun"
        Write-Output "Drive Letter:         ${driveLetterInput}:"
    Write-Output "Host Caching:         None"
    Write-Output "============================================="
    Write-Output ""

    Write-Output "Creating managed disk '$diskName'..."
    try {
        $diskConfig = New-AzDiskConfig `
            -Location $vmLocation `
            -CreateOption Empty `
            -DiskSizeGB $newSizeGB `
            -SkuName $diskSkuName

        $newDisk = New-AzDisk -ResourceGroupName $vmRG -DiskName $diskName -Disk $diskConfig -ErrorAction Stop
    }
    catch {
        Exit-WithError -Code 7002 -Step "CreateDisk" -Message "Failed to create managed disk '$diskName': $($_.Exception.Message)"
    }

    # ============================
    # Step 5: Attach disk to VM
    # ============================
    Write-Output "Attaching disk '$diskName' to VM '$vmName' on LUN $nextLun..."
    try {
        $vm = Get-AzVM -ResourceGroupName $vmRG -Name $vmName -ErrorAction Stop
        $vm = Add-AzVMDataDisk `
            -VM $vm `
            -Name $diskName `
            -CreateOption Attach `
            -ManagedDiskId $newDisk.Id `
            -Lun $nextLun

        # Null out OsProfile so the ARM API does not reject the request with
        # PropertyChangeNotAllowed. Get-AzVM returns the full VM model including
        # OsProfile; Update-AzVM would send it back even though nothing changed.
        $vm.OSProfile = $null

        Update-AzVM -ResourceGroupName $vmRG -VM $vm -ErrorAction Stop | Out-Null
    }
    catch {
        Exit-WithError -Code 7003 -Step "AttachDisk" -Message "Failed to attach disk '$diskName' to VM '$vmName': $($_.Exception.Message). The disk was created and may need manual cleanup if not attached."
    }

    try {
        $vmVerify = Get-AzVM -ResourceGroupName $vmRG -Name $vmName -ErrorAction Stop
        $attachedDisk = $vmVerify.StorageProfile.DataDisks | Where-Object { $_.ManagedDisk.Id -eq $newDisk.Id } | Select-Object -First 1
    }
    catch {
        Exit-WithError -Code 7004 -Step "VerifyAttach" -Message "Disk attachment verification failed: $($_.Exception.Message)"
    }

    if (-not $attachedDisk) {
        Exit-WithError -Code 7004 -Step "VerifyAttach" -Message "Disk '$diskName' was not found on VM '$vmName' after update."
    }

    # ============================
    # Step 6: Initialize and format disk in guest
    # ============================
    Write-Output "Initializing and formatting disk inside the VM..."

    $guestScript = @"
`$ErrorActionPreference = 'Stop'
`$targetLun = $nextLun
`$targetDriveLetter = '$driveLetterInput'
`$label = '$diskName'

# Capture output and errors together for diagnostics
`$diagnostics = @()

try {
    `$diagnostics += "Starting disk initialization for LUN `$targetLun"
    `$diagnostics += "Requested drive letter: `$targetDriveLetter"
    
    # Wait for disk to appear in guest OS (may take a few seconds after attachment)
    `$disk = `$null
    `$diagnostics += "Searching for data disk with LUN `$targetLun..."
    for (`$attempt = 0; `$attempt -lt 20; `$attempt++) {
        try { Update-HostStorageCache -ErrorAction SilentlyContinue | Out-Null } catch { }

        `$disk = Get-Disk -ErrorAction SilentlyContinue |
            Where-Object {
                `$_.Location -match "(?i)LUN\s+`$targetLun(\D|`$)" -and
                -not `$_.IsBoot -and
                -not `$_.IsSystem
            } |
            Select-Object -First 1

        if (`$disk) {
            `$diagnostics += "Disk found at attempt `$attempt, disk number `$(`$disk.Number), location `$(`$disk.Location)"
            break 
        }

        if (`$attempt % 4 -eq 0) { `$diagnostics += "Attempt `$attempt - disk not yet visible" }
        Start-Sleep -Milliseconds 500
    }

    if (-not `$disk) {
        `$allDisks = Get-Disk -ErrorAction SilentlyContinue | ForEach-Object { "Disk `$(`$_.Number): Location='`$(`$_.Location)', IsBoot=`$(`$_.IsBoot), IsSystem=`$(`$_.IsSystem), Style=`$(`$_.PartitionStyle), SizeGB=`$([math]::Round(`$_.Size / 1GB, 2))" }
        throw "Data disk for LUN `$targetLun not found after 10 seconds. Available disks: `n`$(`$allDisks -join '; ')"
    }

    `$diagnostics += "Disk status: Online=`$(-not `$disk.IsOffline), ReadOnly=`$(`$disk.IsReadOnly), Style=`$(`$disk.PartitionStyle), Size=`$(`$disk.Size / 1GB) GB"
    
    # Bring disk online and remove read-only flag if needed
    if (`$disk.IsOffline) {
        `$diagnostics += "Bringing disk online..."
        Set-Disk -Number `$disk.Number -IsOffline `$false -ErrorAction Stop
        Start-Sleep -Milliseconds 1000
        `$disk = Get-Disk -Number `$disk.Number -ErrorAction Stop
    }
    
    if (`$disk.IsReadOnly) {
        `$diagnostics += "Removing read-only flag..."
        Set-Disk -Number `$disk.Number -IsReadOnly `$false -ErrorAction Stop
        Start-Sleep -Milliseconds 500
    }

    # Initialize and format disk if RAW
    `$diagnostics += "Partition style before init: `$(`$disk.PartitionStyle)"
    if (`$disk.PartitionStyle -eq 'RAW') {
        `$diagnostics += "Initializing disk with GPT..."
        Initialize-Disk -Number `$disk.Number -PartitionStyle GPT -ErrorAction Stop | Out-Null
        Start-Sleep -Milliseconds 1000
        
        `$diagnostics += "Creating partition..."
        `$newPartition = New-Partition -DiskNumber `$disk.Number -UseMaximumSize -ErrorAction Stop
        Set-Partition -DiskNumber `$disk.Number -PartitionNumber `$newPartition.PartitionNumber -NewDriveLetter `$targetDriveLetter -ErrorAction Stop
        `$diagnostics += "Partition created, drive letter set to `$targetDriveLetter"
        
        Start-Sleep -Milliseconds 1500
        `$diagnostics += "Formatting volume with NTFS..."
        Format-Volume -Partition `$newPartition -FileSystem NTFS -NewFileSystemLabel `$label -Confirm:`$false -Force -ErrorAction Stop | Out-Null
        `$diagnostics += "Format completed"
    } else {
        `$diagnostics += "Disk is not RAW (style: `$(`$disk.PartitionStyle)), checking for existing partition..."
    }

    # Retrieve final partition and volume info
    Start-Sleep -Milliseconds 500
    `$partition = Get-Partition -DiskNumber `$disk.Number -ErrorAction Stop | Where-Object { `$_.Type -ne 'Reserved' } | Select-Object -First 1
    if (-not `$partition) {
        throw "No usable partition found on disk number `$(`$disk.Number)."
    }

    if (`$partition.DriveLetter -ne `$targetDriveLetter) {
        `$diagnostics += "Setting drive letter to `$targetDriveLetter"
        Set-Partition -DiskNumber `$disk.Number -PartitionNumber `$partition.PartitionNumber -NewDriveLetter `$targetDriveLetter -ErrorAction Stop
        Start-Sleep -Milliseconds 500
        `$partition = Get-Partition -DiskNumber `$disk.Number -PartitionNumber `$partition.PartitionNumber -ErrorAction Stop
    }

    `$diagnostics += "Partition found, size `$(`$partition.Size / 1GB) GB"

    `$volume = Get-Volume -DriveLetter `$targetDriveLetter -ErrorAction Stop
    `$diagnostics += "Volume state: DriveLetter=`$(`$volume.DriveLetter), FileSystem=`$(`$volume.FileSystem)"
    
    if (-not `$volume.DriveLetter) {
        throw "No drive letter assigned to volume."
    }

    `$diagnostics += "Disk initialization complete!"
    
    [pscustomobject]@{
        Success     = `$true
        Lun         = `$targetLun
        DiskNumber  = `$disk.Number
        DriveLetter = `$targetDriveLetter
        SizeGB      = [math]::Round(`$partition.Size / 1GB, 2)
        Diagnostics = `$diagnostics
    } | ConvertTo-Json -Depth 5
}
catch {
    `$diagnostics += "ERROR: `$_"
    [pscustomobject]@{
        Success     = `$false
        Error       = "`$_"
        Diagnostics = `$diagnostics
    } | ConvertTo-Json -Depth 5
}
"@

    try {
        $run = Invoke-AzVMRunCommand -ResourceGroupName $vmRG -Name $vmName -CommandId 'RunPowerShellScript' -ScriptString $guestScript
        $guestJson = ($run.Value | Select-Object -First 1).Message
    }
    catch {
        Exit-WithError -Code 8002 -Step "GuestInitialize" -Message "RunCommand failed: $($_.Exception.Message). Azure disk '$diskName' is attached at LUN $nextLun; initialize it manually in Disk Management."
    }

    if (-not $guestJson) {
        Exit-WithError -Code 8003 -Step "GuestInitialize" -Message "RunCommand returned no data. Azure disk '$diskName' is attached at LUN $nextLun; initialize it manually in Disk Management."
    }

    try {
        $guestResult = $guestJson | ConvertFrom-Json
    }
    catch {
        Exit-WithError -Code 8004 -Step "GuestInitialize" -Message "Invalid RunCommand output. Azure disk '$diskName' is attached at LUN $nextLun; initialize it manually in Disk Management. Raw output: $guestJson"
    }

    # Check if guest script succeeded
    if (-not $guestResult.Success) {
        $diagText = if ($guestResult.Diagnostics) { "`n`nDiagnostics:`n$($guestResult.Diagnostics -join "`n")" } else { "" }
        Exit-WithError -Code 8002 -Step "GuestInitialize" -Message "Guest disk initialization failed: $($guestResult.Error)$diagText Azure disk '$diskName' is attached at LUN $nextLun; initialize it manually in Disk Management."
    }

    # Write diagnostics for visibility
    if ($guestResult.Diagnostics) {
        Write-Output ""
        Write-Output "--- Guest Diagnostics ---"
        $guestResult.Diagnostics | ForEach-Object { Write-Output $_ }
        Write-Output "------------------------"
    }

    # ============================
    # Final report
    # ============================
    Write-Output ""
    Write-Output "========== RESULT =========="
    Write-Output "Status:              SUCCESS"
    Write-Output "VM:                  $vmName ($vmRG)"
    Write-Output "Azure Disk:          $diskName ($diskSkuName)"
    Write-Output "Disk Size:           $newSizeGB GB"
    Write-Output "LUN:                 $nextLun"
    
    $driveLetter = if ($guestResult.PSObject.Properties.Name -contains 'DriveLetter') { "$($guestResult.DriveLetter):" } else { "N/A" }
    $volumeSize = if ($guestResult.PSObject.Properties.Name -contains 'SizeGB') { "$($guestResult.SizeGB) GB" } else { "N/A" }
    
    Write-Output "Drive Letter:        $driveLetter"
    Write-Output "Guest Volume Size:   $volumeSize"
    Write-Output "============================="
}
catch {
    if ($_.Exception.Message -match '^\[\d+\]\s') {
        throw
    }
    Exit-WithError -Code 9000 -Step "Unexpected" -Message $_.Exception.Message
}
