[CmdletBinding(DefaultParameterSetName = 'default')]

Param (
    [Parameter(ParameterSetName="default", Mandatory, Position=0)] [string] $subscriptionFilter,
    [Parameter(ParameterSetName="default", Position=1)] [switch] $noDisks,
    [Parameter(ParameterSetName="default", Position=2)] [string] $outFile,
    [Parameter(ParameterSetName="default", Position=3)] [switch] $append,
    [Parameter(ParameterSetName="help")] [Alias("h")] [switch] $help
)

if ($help) {
    "NAME"
    "    Get-VirtualMachineSizes"
    ""
    "SYNTAX"
    "    Get-VirtualMachineSizes -subscriptionFilter <filterexpression> [-noDisks] [-outFile <outFilename> [-append]]"
    ""
    "    Returns a list of all subscriptions, virtual machines, their SKU, IP addresses, and SKUs of attached disks"
    "    in subscriptions matching the filter"
    ""
    "    -noDisks   show only the VM names and SKUs, not the disks"
    "    -outFile   exports result into a semicolon-separated CSV file"
    "    -append    appends rather than overwrite CSV file, requires -outFile"
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

if ($subscriptionFilter -ne '*') {
    $subscriptionFilter = "*$subscriptionFilter*"
}

# ========== BEGIN MAIN ================

$subscriptions = Get-AzSubscription | Where-Object {$_.Name -like $subscriptionFilter} | Sort-Object -Property Name

$result = $(
    foreach ($subscription in $subscriptions) {
        Select-AzSubscription $subscription | Out-Null
        foreach ($VM in $(Get-AzVM | Sort-Object -Property Name)) {
            $VmSku = ($vm | select -ExpandProperty HardwareProfile).VmSize

            if (-not $noDisks) {
                $vmDisks = ($vm|select -ExpandProperty StorageProfile).DataDisks

                $DiskCount = @()
                $DiskSku = @()

                $DiskType = $vm.StorageProfile.OsDisk.ManagedDisk.StorageAccountType
                $DiskSize = $vm.StorageProfile.OsDisk.DiskSizeGB
                $Sku = (DiskSkuToSkuName $DiskType $DiskSize)
                $DiskCount += @(1)
                $DiskSku += $Sku

                $lastSku = ''
                foreach ($disk in $VmDisks) {
                    $DiskType = $disk.ManagedDisk.StorageAccountType
                    $DiskSize = $disk.DiskSizeGB
                    $Sku = (DiskSkuToSkuName $DiskType $DiskSize)
                    if ($Sku -ne $lastSku) {
                        $DiskCount += @(1)
                        $DiskSku += $Sku
                        $lastSku = $Sku
                    } else {
                        $DiskCount[-1] += 1
                    }
                }
                $disks = ''
                for ($i=0; $i -lt $DiskCount.Count; $i++) {
                    if ($i -gt 0) { $disks += " + " }
                    $disks += $DiskCount[$i].ToString() + '×' + $DiskSku[$i]
                }
                [PSCustomObject] @{
                    Subscription = $($subscription.Name)
                    Name         = $($VM.Name)
                    Sku          = $VmSku -replace "Standard_"
                    Disks        = $disks
                }
            } else {
                [PSCustomObject] @{
                    Subscription = $($subscription.Name)
                    Name         = $($VM.Name)
                    Sku          = $VmSku -replace "Standard_"
                }
            }
        }
    }
)

if ($outFile) {
    if ($append) {
        $result | Export-Csv -Delimiter ";" -Path $outFile -NoTypeInformation -Encoding UTF8 -Append
    } else {
        $result | Export-Csv -Delimiter ";" -Path $outFile -NoTypeInformation -Encoding UTF8
    }
} else {
    $result
}
