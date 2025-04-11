<#
.SYNOPSIS
Lists Azure VNets

.DESCRIPTION
Lists virtual networks in Azure subscriptions, optionally with list of subnets, netmask, and available IP addresses

.PARAMETER subscriptionFilter
Mandatory. Lists VNets range for the subscriptions matching the filter

.PARAMETER details
additionally lists max number of hosts, netmask, minimum and maximum available IP addresses for each network

.PARAMETER includeSubnets"
list all subnets for each VNet

.PARAMETER outFile"
if given, export result into a semicolon-separated CSV file rather than a list of objects
#>

[CmdletBinding()]

Param (
    [Parameter(Mandatory, Position=0)] [string] $subscriptionFilter,
    [switch] $details,
    [switch] $includeSubnets,
    [string] $outFile = ''
)


function Int64ToIPString ([int64] $value)
{
    $ret = ''
    for ($i = 3; $i -ge 0; $i--) {
        if ($ret -ne '') {$ret += '.'}
        $ret += ($value -shr ($i*8) -band 0xFF)
    }
    $ret
}

function IPStringToInt64 ([string] $ipString) {
    $ret = [int64] 0
    $addr = $ipString.Split('.')
    for ($i = 0; $i -le 3; $i++) {
        $ret = (256*$ret) + [Convert]::ToInt64($addr[$i])
    }
    $ret
}

function AddressPrefixToPrefix ([string] $prefix)
{
    $($prefix.Replace('{','').replace('}','') -split '/')[1]
}

function AddressPrefixToMask ([Int32] $prefix)
{
    [Int64]0xFFFFFFFF -shl (32 - $prefix) -band 0xFFFFFFFF
}

function AddressPrefixToNet ($prefix)
{
    $($prefix.Replace('{','').replace('}','') -split '/')[0]
}

# ========== BEGIN MAIN ================
#
#

if ($subscriptionFilter -ne '*') {
    $subscriptionFilter = "*$subscriptionFilter*"
}

$subscriptions = Get-AzSubscription | Where-Object {$_.Name -like $subscriptionFilter}

$countS = 0 # used for progress bar

# the result for each subscription and VNet is returned as a PSCustomObject
# we want all results in an array, so that we later process or export them
$result = $(
    foreach ($subscription in $subscriptions) {
        Select-AzSubscription $subscription | Out-Null
        $countS++
        Write-Progress -Id 1 -PercentComplete $($countS * 100 / $subscriptions.count) -Status 'iterating through subscriptions' -Activity "analyzing subscription $countS of $($subscriptions.count)"
        $VNets = Get-AzVirtualNetwork
        foreach ($VNet in $VNets) {
            foreach ($addrPrefix in $VNet.AddressSpace.AddressPrefixes) {
                # get some basic informationabout each VNet
                $addressPrefix = $addrPrefix.Replace('{','').replace('}','')
                $network       = AddressPrefixToNet ($addressPrefix)
                $prefix        = AddressPrefixToPrefix($addressPrefix)
                $int64Address  = IPStringToInt64($network)
                if ($details) {
                    $netmask       = Int64ToIPString(AddressPrefixToMask ($prefix))
                    $hostMin       = Int64ToIPString($int64Address + 1)
                    $numhosts      = [bigint]::Pow(2, 32-$prefix) - 2
                    $hostmax       = Int64ToIPString($int64Address + $numhosts)
                    [PSCustomObject]@{
                        Subscription = $($subscription.Name)
                        VNet     = $($VNet.Name)
                        Subnet   = '*'
                        Network	 = $network
                        Prefix   = $prefix
                        NumHosts = $numhosts
                        Netmask	 = $netmask
                        HostMin	 = $hostmin
                        HostMax	 = $hostmax
                    }
                } else {
                    [PSCustomObject]@{
                        Subscription = $($subscription.Name)
                        VNet    = $($VNet.Name)
                        Subnet  = '*'
                        Network	= $network
                        Prefix  = $prefix
                    }
                }
            }
            if ($includeSubnets) {
                foreach ($subnet in $VNet.Subnets) {
                    $addressPrefix = $subnet.AddressPrefix.Replace('{','').replace('}','')
                    $network = AddressPrefixToNet ($addressPrefix)
                    $prefix  = AddressPrefixToPrefix($addressPrefix)
                    $netmask = Int64ToIPString(AddressPrefixToMask ($prefix))
                    if ($details) {
                        $hostMin  = Int64ToIPString($int64Address + 1)
                        $numhosts = [bigint]::Pow(2, 32-$prefix) - 2
                        $hostmax  = Int64ToIPString($int64Address + $numhosts)
                    }
                    if ($details) {
                        [PSCustomObject]@{
                            Subscription = $($subscription.Name)
                            VNet         = $($VNet.Name)
                            Subnet       = $($subnet.Name)
                            Network	     = $network
                            Prefix       = $prefix
                            NumHosts     = $numhosts
                            Netmask	     = $netmask
                            HostMin	     = $hostmin
                            HostMax	     = $hostmax
                        }
                    } else {
                        [PSCustomObject]@{
                            Subscription = $($subscription.Name)
                            VNet         = $($VNet.Name)
                            Subnet       = $($subnet.Name)
                            Network	     = $network
                            Prefix       = $prefix
                        }
                    }
                }
            }
        }
    }
    Write-Progress -Id 1 -Activity "analyzing subscription" -Completed
) | Sort-Object -Property Subscription, VNet, Subnet

if ($outFile) {
    $result | Export-Csv -Delimiter ";" -Path $outFile -NoTypeInformation
} else {
    $result
}
