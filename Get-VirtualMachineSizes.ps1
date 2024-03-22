[CmdletBinding(DefaultParameterSetName = 'default')]

Param (
    [Parameter(ParameterSetName="default", Mandatory, Position=0)] [string] $subscriptionFilter,
    [Parameter(ParameterSetName="default", Position=1)] [switch] $disks,
    [Parameter(ParameterSetName="default", Position=2)] [switch] $aggregate,
    [Parameter(ParameterSetName="help")] [Alias("h")] [switch] $help
)

if ($help) {
    "NAME"
    "    Get-VirtualMachineSizes"
    ""
    "SYNTAX"
    "    Get-VirtualMachineSizes -subscriptionFilter <filterexpression> [-disks [-aggregate]]"
    ""
    "    Returns a list of all subscriptions, virtual machines, their SKU, IP addresses, and SKUs of attached disks"
    "    in subscriptions matching the filter"
    ""
    "    -disks     also shows the disk SKUs"
    "    -aggregate aggregates disks by SKUs, requires -disks"
    exit
}

function DiskSkuToSkuName ($tier, $size)
{
    if ($tier -eq $null) {
        $SkuName = "X"
    } elseif ($tier.substring(0,7) -eq "Premium") {
        $SkuName = "P"
    } elseif ($tier.substring(0,5) -eq "Ultra")  {
        $SkuName = "U"
    } elseif($tier.substring(0,8) -eq "Standard") {
        $SkuName = "E"
    } else {
        $SkuName = "[$tier]"
    }
    if ($size -le 4) {
        $SkuName += "1"
    } elseif ($size -le 8) {
        $SkuName += "2"
    } elseif ($size -le 16) {
        $SkuName += "3"
    } elseif ($size -le 32) {
        $SkuName += "4"
    } elseif ($size -le 64) {
        $SkuName += "6"
    } elseif ($size -le 128) {
        $SkuName += "10"
    } elseif ($size -le 256) {
        $SkuName += "15"
    } elseif ($size -le 512) {
        $SkuName += "20"
    } elseif ($size -le 1024) {
        $SkuName += "30"
    } elseif ($size -le 2048) {
        $SkuName += "40"
    } elseif ($size -le 4096) {
        $SkuName += "50"
    } elseif ($size -le 16384) {
        $SkuName += "60"
    } elseif ($size -le 32768) {
        $SkuName += "70"
    } else {
        $SkuName += "80"
    }

    $SkuName
}


# ========== BEGIN MAIN ================
if ($subscriptionFilter -ne '*') {
    $subscriptionFilter = "*$subscriptionFilter*"
}

$subscriptions = Get-AzSubscription | Where-Object {$_.Name -like $subscriptionFilter} | Sort-Object -Property Name

foreach ($subscription in $subscriptions) {
    Select-AzSubscription $subscription | Out-Null
    foreach ($VM in $(Get-AzVM | Sort-Object -Property Name)) {
        $VmSku = ($vm | select -ExpandProperty HardwareProfile).VmSize -replace "Standard_"
        $item = [PSCustomObject] @{
                Subscription = $($subscription.Name)
                Name         = $($VM.Name)
                Sku          = $VmSku
            }
        if ($disks) {
            $vmDisks = ($vm|select -ExpandProperty StorageProfile).DataDisks

            $DiskType = $vm.StorageProfile.OsDisk.ManagedDisk.StorageAccountType
            $DiskSize = $vm.StorageProfile.OsDisk.DiskSizeGB
            $Sku = (DiskSkuToSkuName $DiskType $DiskSize)
            $item | Add-Member -MemberType NoteProperty -Name 'OsDisk' -Value $Sku

            if ($aggregate) {
                $lastSku = ''
                $diskSkuCount = 0
                foreach ($disk in $VmDisks) {
                    $DiskType = $disk.ManagedDisk.StorageAccountType
                    $DiskSize = $disk.DiskSizeGB
                    $Sku = (DiskSkuToSkuName $DiskType $DiskSize)
                    if ($Sku -ne $lastSku) {
                        $diskSkuCount++
                        $diskCount = 1
                        $diskPropertyName = 'DataDiskSku' + $diskSkuCount
                        $item | Add-Member -MemberType NoteProperty -Name $diskPropertyName -Value $($diskCount.ToString() + 'x' + $Sku)
                        $lastSku = $Sku
                    } else {
                        $diskCount++
                        $item.$diskPropertyName = $($diskCount.ToString() + 'x' + $Sku)
                    }
                }
            } else {
                $diskSkus = @()
                foreach ($disk in $VmDisks) {
                    $DiskType = $disk.ManagedDisk.StorageAccountType
                    $DiskSize = $disk.DiskSizeGB
                    $diskSkus += (DiskSkuToSkuName $DiskType $DiskSize)
                }
                $item | Add-Member -MemberType NoteProperty -Name 'DataDisks' -Value $diskSkus
            }
        }
        $item
    }
}
