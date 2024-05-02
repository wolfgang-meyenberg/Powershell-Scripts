[CmdletBinding(DefaultParameterSetName = 'default')]

Param (
    [Parameter(ParameterSetName="default", Mandatory, Position=0)] [string] $subscriptionFilter,
    [Parameter(ParameterSetName="default", Position=1)] [switch] $disks,
    [Parameter(ParameterSetName="default", Position=2)] [switch] $aggregate,
    [Parameter(ParameterSetName="default", Position=3)] [switch] $asString,
    [Parameter(ParameterSetName="default", Position=4)] [string] $outFile = '',
    [Parameter(ParameterSetName="help")] [Alias("h")] [switch] $help
)

if ($help) {
    "NAME"
    "    Get-VirtualMachineSizes"
    ""
    "SYNTAX"
    "    Get-VirtualMachineSizes -subscriptionFilter <filterexpression> [-disks [-aggregate | -asString]]"
    ""
    "    Returns a list of all subscriptions, virtual machines, their SKU, IP addresses,"
    "    and SKUs of attached disks in subscriptions matching the filter"
    ""
    "    -disks     also shows the disk SKUs"
    "    -aggregate aggregates disks by SKUs, requires -disks"
    "    -asString  aggregates disks by SKUs and order, requires -disks"
    "    -outFile   if given, exports result into a semicolon-separated CSV file"
    ""
    exit
}

function DiskSkuToSkuName ($tier, $size)
{
    if ($tier -eq $null) {
        $SkuName = "X"  # we can't identify the tier
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

$result = $(
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
                # get info about OS disk
                $OsDisk = Get-AzDisk -DiskName $vm.StorageProfile.OsDisk.Name
                $DiskType = $OsDisk.Sku.Name
                $DiskSize = $OsDisk.DiskSizeGB
                $Sku = (DiskSkuToSkuName $DiskType $DiskSize)

<#        
                $DiskType = $vm.StorageProfile.OsDisk.ManagedDisk.StorageAccountType
                $DiskSize = $vm.StorageProfile.OsDisk.DiskSizeGB
                $Sku = (DiskSkuToSkuName $DiskType $DiskSize)
#>

                $item | Add-Member -MemberType NoteProperty -Name 'OsDisk' -Value $Sku

                # get info about data disks
                $vmDisks = $vm.StorageProfile.DataDisks

                if ($aggregate) {
                    $lastSku = ''
                    $diskSkuCount = 0
                    foreach ($disk in $VmDisks) {
<#

                        $DiskType = $disk.ManagedDisk.StorageAccountType
                        $DiskSize = $disk.DiskSizeGB
#>
                        $DataDisk = Get-AzDisk -DiskName $disk.Name
                        $DiskType = $DataDisk.Sku.Name
                        $DiskSize = $DataDisk.DiskSizeGB

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
                } elseif ($asString) {
                    $lastSku = ''
                    $diskString = ''
                    foreach ($disk in $VmDisks) {
                        $DataDisk = Get-AzDisk -DiskName $disk.Name
                        $DiskType = $DataDisk.Sku.Name
                        $DiskSize = $DataDisk.DiskSizeGB
                        $Sku = (DiskSkuToSkuName $DiskType $DiskSize)
                        if ($Sku -eq $lastSku) {
                            $diskCount++
                        } else {
                            if ($diskString -ne '') { $diskString += " + " }
                            if ($lastSku -ne '') { $diskString += $($diskCount.ToString() + 'x' + $lastSku) }
                            $diskCount = 1
                            $lastSku = $Sku
                        }
                    }
                    if ($diskString -ne '') { $diskString += " + " }
                    if ($lastSku -ne '') { $diskString += $($diskCount.ToString() + 'x' + $lastSku) }
                    $item | Add-Member -MemberType NoteProperty -Name "Disks" -Value $diskString
                } else {
                    $diskSkus = @()
                    foreach ($disk in $VmDisks) {
                        $DataDisk = Get-AzDisk -DiskName $disk.Name
                        $DiskType = $DataDisk.Sku.Name
                        $DiskSize = $DataDisk.DiskSizeGB
                        $diskSkus += (DiskSkuToSkuName $DiskType $DiskSize)
                    }
                    $item | Add-Member -MemberType NoteProperty -Name 'DataDisks' -Value $diskSkus
                }
            }
            $item
        }
    }
)

if ($outFile) {
    # the "DataDisks" member is an array, but we want that to be expanded
    # so we need to do some manual magic here
    $(
        "Subscription;Name;Sku;OsDisk;DataDisks"
        foreach ($item in $result) {
            $line = ''
            foreach ($memberName in ($item.psobject.properties | select -ExpandProperty Name)) {
                $member = $item.$memberName

                if ($member.GetType().IsArray) {
                    foreach ($element in $member) {
                        if ($line -ne '') { $line += ';' }
                        $line += $element
                    }
                } else {
                    if ($line -ne '') { $line += ';' }
                    $line += $member
                }
            }
            $line
        }
    ) | Out-File $outFile
} else {
    $enumLimit = $Global:FormatEnumerationLimit
    $Global:FormatEnumerationLimit = -1
    $result
    $Global:FormatEnumerationLimit = $enumLimit
}
