[CmdletBinding(DefaultParameterSetName = 'default')]

Param (
    [Parameter(ParameterSetName="default", Mandatory, Position=0)] [string] $subscriptionFilter,
    [Parameter(ParameterSetName="default", Position=1)] [switch] $disks,
    [Parameter(ParameterSetName="default", Position=2)] [switch] $aggregate,
    [Parameter(ParameterSetName="default", Position=3)] [string] $outFile = '',
    [Parameter(ParameterSetName="help")] [Alias("h")] [switch] $help
)

if ($help) {
    "NAME"
    "    Get-VirtualMachineSizes"
    ""
    "SYNTAX"
    "    Get-VirtualMachineSizes -subscriptionFilter <filterexpression> [-disks [-aggregate]] [-outFile <filename>]"
    ""
    "    Returns a list of all subscriptions, virtual machines, their SKU, IP addresses,"
    "    and SKUs of attached disks in subscriptions matching the filter"
    ""
    "    -disks     also shows the disk SKUs"
    "    -aggregate returns disk count grouped by SKUs, requires -disks"
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
        $SkuName = "[$tier]" # something else
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
#
#
if ($subscriptionFilter -ne '*') {
    $subscriptionFilter = "*$subscriptionFilter*"
}

$subscriptions = Get-AzSubscription | Where-Object {$_.Name -like $subscriptionFilter} | Sort-Object -Property Name
    
$countS = 0 # used for progress bar

# the result for each VM is returned as a PSCustomObject
# we want all results in an array, so that we later process or export them
$result = $(
    foreach ($subscription in $subscriptions) {
        Select-AzSubscription $subscription | Out-Null
        $countS++
        Write-Progress -Id 1 -PercentComplete $($countS * 100 / $subscriptions.count) -Status 'iterating through subscriptions' -Activity "analyzing subscription $countS of $($subscriptions.count)"
        $VMs =Get-AzVM | Sort-Object -Property Name
        $countVM = 0
        foreach ($VM in $VMs) {
            # we want a conside output, so delete the 'Standard_' part from the Sku
            $VmSku = ($vm | select -ExpandProperty HardwareProfile).VmSize -replace 'Standard_'
            $item = [PSCustomObject] @{
                    Subscription = $($subscription.Name)
                    Name         = $($VM.Name)
                    Sku          = $VmSku
                }
            if ($disks -or $aggregate) {
                $countVM++
                Write-Progress -Id 2 -ParentId 1 -PercentComplete $($countVM * 100 / $VMs.count) -Status 'iterating through VMs' -Activity "analyzing disks for VM $countVM of $($VMs.count)"
                # we want to display information about the VM attached disks as well
                # first get info about OS disk
                $OsDisk = Get-AzDisk -DiskName $vm.StorageProfile.OsDisk.Name
                $DiskType = $OsDisk.Sku.Name
                $DiskSize = $OsDisk.DiskSizeGB
                $Sku = (DiskSkuToSkuName $DiskType $DiskSize)
                # add thi sinformation as additional member to the object created above
                $item | Add-Member -MemberType NoteProperty -Name 'OsDisk' -Value $Sku

                # now, get info about data disks
                $vmDisks = $vm.StorageProfile.DataDisks

                if ($aggregate) {
                    # we don't want data for each disk individually, but just the different SKUs and their count
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
                    # return all disk SKUs in an array
                    $diskSkus = @()
                    foreach ($disk in $VmDisks) {
                        $DataDisk = Get-AzDisk -DiskName $disk.Name
                        $DiskType = $DataDisk.Sku.Name
                        $DiskSize = $DataDisk.DiskSizeGB
                        $diskSkus += (DiskSkuToSkuName $DiskType $DiskSize)
                    }
                    $item | Add-Member -MemberType NoteProperty -Name 'DataDisks' -Value $diskSkus
                }
                Write-Progress -Id 2 -ParentId 1 -PercentComplete 0 -Status 'iterating through VMs' -Activity 'analyzing VM disks'
            }
            $item
        }
    }
    Write-Progress -Id 1 -Completed -Activity 'Subscriptions'
)

if (-not $outFile) {
    # Output to stdout as object
    # The property 'DataDisks' is itself an array, and we want to see ALL its elements in the output
    $enumLimit = $Global:FormatEnumerationLimit
    $Global:FormatEnumerationLimit = -1
    # Output --> stdout
    $result
    # Restore standard enum limit
    $Global:FormatEnumerationLimit = $enumLimit
} else {
    # we want the output to go to a file.
    # The "DataDisks" member is an array, but we want that to be expanded
    # so we need to do some manual magic here
    $(
        "Subscription;Name;Sku;OsDisk;DataDisks"
        foreach ($item in $result) {
            $line = ''
            foreach ($memberName in ($item.psobject.properties | select -ExpandProperty Name)) {
                # iterate through the properties of the $item object
                $member = $item.$memberName
                if ($member.GetType().IsArray) {
                    # if the property is an array (i.e. the 'DataDisks' property), iterate through its elements
                    # and add them to the $line string
                    foreach ($element in $member) {
                        if ($line -ne '') { $line += ';' }
                        $line += $element
                    }
                } else {
                    # otherwise add the property value to the $line string
                    if ($line -ne '') { $line += ';' }
                    $line += $member
                }
            }
            $line
        }
    ) | Out-File $outFile
}
