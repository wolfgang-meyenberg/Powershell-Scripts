[CmdletBinding(DefaultParameterSetName = 'default')]

Param (
    [Parameter(ParameterSetName="default", Mandatory, Position=0)] [string] $subscriptionFilter,
    [Parameter(ParameterSetName="default", Position=1)] [switch] $details,
    [Parameter(ParameterSetName="default", Position=2)] [switch] $excludeSubnets,
    [Parameter(ParameterSetName="default", Position=3)] [string] $outFile = '',
    [Parameter(ParameterSetName="help")] [Alias("h")] [switch] $help
)

if ($help) {
    "NAME"
    "    Get-VirtualNetworks"
    ""
    "SYNTAX"
    "    Get-VirtualNetworks -subscriptionFilter <filterexpression> [-details] [-excludeSubnets] [-outFile <filepath>]"
    ""
    "-subscriptionFilter"
    "    mandatory parameter. Lists all VNets and subnet names with IP address"
    "    range for the subscriptions matching the filter"
    ""
    "-details"
    "    additionally lists max number of hosts, netmask, minimum and maximum"
    "    available IP addresses for each network"
    ""
    "-excludeSubnets"
    "    list only VNets rather than VNets including their subnets"
    ""
    "-outFile"
    "    if given, exports result into a semicolon-separated CSV file"
    ""
    exit
}

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

if ($subscriptionFilter -ne '*') {
    $subscriptionFilter = "*$subscriptionFilter*"
}

$subscriptions = Get-AzSubscription | Where-Object {$_.Name -like $subscriptionFilter}


$result = $(
    foreach ($subscription in $subscriptions) {
        Select-AzSubscription $subscription | Out-Null
        $VNets = Get-AzVirtualNetwork
        foreach ($VNet in $VNets) {
            $addressRanges = ''
            foreach ($addrPrefix in $VNet.AddressSpace.AddressPrefixes) {
                $addressPrefix = $addrPrefix.Replace('{','').replace('}','')
                $network       = AddressPrefixToNet ($addressPrefix)
                $prefix        = AddressPrefixToPrefix($addressPrefix)
                $netmask       = Int64ToIPString(AddressPrefixToMask ($prefix))
                $int64Address  = IPStringToInt64($network)
                $hostMin       = Int64ToIPString($int64Address + 1)
                $numhosts      = [bigint]::Pow(2, 32-$prefix) - 2
                $hostmax       = Int64ToIPString($int64Address + $numhosts)
                if ($details) {
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
            if (-not $excludeSubnets) {
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
) | Sort-Object -Property Subscription, VNet, Subnet

if ($outFile) {
    $result | Export-Csv -Delimiter ";" -Path $outFile -NoTypeInformation
} else {
    $result
}
