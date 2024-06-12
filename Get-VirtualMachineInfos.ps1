[CmdletBinding(DefaultParameterSetName = 'default')]

Param (
    [Parameter(ParameterSetName="default", Mandatory, Position=0)] [string] $subscriptionFilter,
    [Parameter(ParameterSetName="default")] [switch] $all,
    [Parameter(ParameterSetName="default", Position=1)] [switch] $disks,
    [Parameter(ParameterSetName="default", Position=2)] [switch] $asString,
    [Parameter(ParameterSetName="default", Position=3)] [switch] $aggregatedString,
    [Parameter(ParameterSetName="default", Position=4)] [switch] $ipAddresses,
    [Parameter(ParameterSetName="default", Position=5)] [switch] $ping,
    [Parameter(ParameterSetName="default", Position=6)] [string] $outFile = '',
    [Parameter(ParameterSetName="default", Position=7)] [string] $separator = ';',
    [Parameter(ParameterSetName="help")] [Alias("h")] [switch] $help
)

#######################
# display usage help amnd exit
#
if ($help) {
    "NAME"
    "    Get-VirtualMachineInfos"
    ""
    "SYNTAX"
    "    Get-VirtualMachineInfos -subscriptionFilter <filterexpression> [-disks [-asString] | [-aggregate]] [-ipAddresses] [-ping] [-outFile <filename> [-separator <separator>]]"
    "    Get-VirtualMachineInfos -subscriptionFilter <filterexpression> -all [-outFile <filename>]"
    ""
    "    Returns a list of all subscriptions, virtual machines, their SKU, IP addresses,"
    "    and SKUs of attached disks in subscriptions matching the filter"
    ""
    "    -all               includes -disks, -ipAddresses, -ping"
    "    -disks             show OS and data disk SKUs"
    "    -asString          shows the disks in string format"
    "    -aggregatedString  shows the disks in an aggregated string format"
    "    -ipAddresses       show IP address(es)"
    "    -ping              ping VM to see whether it is live"
    "    -outFile           if given, exports result into a CSV file"
    "    -separator         separator for items in CSV file, default is semicolon"
    ""
    exit
}

##################
# convert a tier and size to a SKU like used in the Azure portal
# (e.g. standard SSD with 128 GB is an E10 disk)
#
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

# the -all switch includes all details
if ($all) {,
    $disks = $true
    $ipAddresses = $true
    $ping = $true
}

# check correct argument usage
if (-not $disks -and ($asString -or $aggregatedString)) {
    Write-Error "InvalidArgument: -asString and -aggregatedString require -disks"
    exit
}
if ($asString -and $aggregatedString) {
    Write-Error "InvalidArgument: use only one of -asString and -aggregatedString"
    exit
}

# always use wildcards for subscriptions
if ($subscriptionFilter -ne '*') {
    $subscriptionFilter = "*$subscriptionFilter*"
}

try {
    $subscriptions = Get-AzSubscription -ErrorAction SilentlyContinue -WarningAction SilentlyContinue | Where-Object {$_.Name -like $subscriptionFilter} | Sort-Object -Property Name
}
catch {
    if ($PSItem.Exception.Message -like '*Connect-AzAccount*') {
        throw "you are not logged on to Azure. Run Connect-AzAccount before running this script."
    } else {
        throw $PSItem.Exception
    }
}

if ($subscriptions -eq $null) {
    "no subscriptions matching this filter found."
    exit
}

$countS = 0 # used for progress bar

# the result for each VM is returned as a PSCustomObject
# we want all results in an array, so that we later process or export them
# hence we generate output first and then catch it in a single variable
$result = $(
    foreach ($subscription in $subscriptions) {
        Select-AzSubscription $subscription | Out-Null
        $countS++
        Write-Progress -Id 1 -PercentComplete $($countS * 100 / $subscriptions.count) -Status "analyzing subscription $countS of $($subscriptions.count) ($($subscription.Name))" -Activity 'iterating through subscriptions'
        $VMs =Get-AzVM | Sort-Object -Property Name
        $countVM = 0
        foreach ($VM in $VMs) {
            # we want a concise output, so delete the 'Standard_' part from the SKU
            $VmSku = ($vm | select -ExpandProperty HardwareProfile).VmSize -replace 'Standard_'
            # create a PSCustomObject
            # if we need to report more details (see 'if' statements below), then the object will be extended as necessary
            $item = [PSCustomObject] @{
                    Subscription = $($subscription.Name)
                    Name         = $($VM.Name)
                    Sku          = $VmSku
                }
            if ($disks) {
                # we also want to have details of the disks, no just about the VM
                $countVM++
                Write-Progress -Id 2 -ParentId 1 -PercentComplete $($countVM * 100 / $VMs.count) -Status "analyzing disks for VM $countVM of $($VMs.count) ($($VM.Name), $($vm.StorageProfile.DataDisks.Count) disks)" -Activity 'analyzing VM disks'
                # we want to display information about the VM attached disks as well
                # first get info about OS disk
                $OsDisk = Get-AzDisk -DiskName $vm.StorageProfile.OsDisk.Name
                $DiskType = $OsDisk.Sku.Name
                $DiskSize = $OsDisk.DiskSizeGB
                $Sku = (DiskSkuToSkuName $DiskType $DiskSize)
                # add this information as additional member to the PSCustomObject created above
                $item | Add-Member -MemberType NoteProperty -Name 'OsDisk' -Value $Sku

                # now, get info about data disks
                $vmDisks = $vm.StorageProfile.DataDisks

                # return all disk SKUs in an array
                $diskSkus = @()
                foreach ($disk in $VmDisks) {
                    $DataDisk = Get-AzDisk -DiskName $disk.Name
                    $DiskType = $DataDisk.Sku.Name
                    $DiskSize = $DataDisk.DiskSizeGB
                    $diskSkus += (DiskSkuToSkuName $DiskType $DiskSize)
                }
                if ($asString) {
                    # gather diskSkus and convert into a string
                    # format will be like "E10 + E10 + E6 +..."
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
                } elseif ($aggregatedString) {
                    # aggregate diskSkus and convert into an aggegated string, sorted by SKU sizes
                    # format will be like "2xE6 + 4xE10 + 1xE20 +..."
                    $aggregatedDisks = @{}
                    foreach ($diskSku in $diskSkus) {
                        if ($aggregatedDisks.ContainsKey($diskSku)) {
                            $aggregatedDisks[$diskSku] ++
                        } else {
                            $aggregatedDisks[$diskSku] = 1
                        }
                    }
                    $diskString = ''
                    # the sort expression sorts SKUs by letter and then by number.
                    # The -f expression ensures that e.g. 6 comes before 10 (i.e. sorted as 06),
                    # otherwise string sort would apply, and 10 would come before 6
                    foreach ($diskSku in ($aggregatedDisks.Keys | Sort-Object -property {$_[0] + "{0:d2}" -f [Int32]$_.Substring(1)} )) {
                        if ($diskString -ne '') { $diskString += " + " }
                        $diskString += $aggregatedDisks[$diskSku].ToString() + "x" + $diskSku
                    }
                    $item | Add-Member -MemberType NoteProperty -Name 'DataDisks' -Value $diskString

                } else {
                    $item | Add-Member -MemberType NoteProperty -Name 'DataDisks' -Value $diskSkus
                }
            }
            if ($ipAddresses) {
                # we want to know the IP addresses on the VMs
                # a VM might have more than one NIC,
                # and a NIC might have more than one IP address
                $nicIds = $VM.NetworkProfile.NetworkInterfaces | select Id
                $nicString = ''
                foreach ($nicId in $nicIds) {
                    $nic = Get-AzNetworkInterface -ResourceId $nicId.Id
                    foreach ($ipConfiguration in $nic.IpConfigurations) {
                        if ($nicString -ne '') { $nicString += "," }
                        $nicString += $ipConfiguration.PrivateIpAddress
                    }
                }
                $item | Add-Member -MemberType NoteProperty -Name 'IpAddresses' -Value $nicString
                if ($ping) {
                    $Live = (Test-NetConnection $NicIP -ErrorAction SilentlyContinue -WarningAction SilentlyContinue).PingSucceeded
                    $item | Add-Member -MemberType NoteProperty -Name 'IsLive' -Value $Live
                }
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
        # output header
        "Subscription${separator}Name${separator}Sku${separator}OsDisk${separator}DataDisks"
        foreach ($item in $result) {
            # construct one line per item in the $result array
            $line = ''
            foreach ($memberName in ($item.psobject.properties | select -ExpandProperty Name)) {
                # iterate through the properties of the $item object
                $member = $item.$memberName
                if ($member.GetType().IsArray) {
                    # if the property is an array (e.g. the 'DataDisks' property), iterate through its elements
                    # and add each elöement to the $line string
                    foreach ($element in $member) {
                        if ($line -ne '') { $line += $separator }
                        $line += $element
                    }
                } else {
                    # otherwise add the property value directly to the $line string
                    if ($line -ne '') { $line += $separator }
                    $line += $member
                }
            }
            $line
        }
    ) | Out-File $outFile
}
