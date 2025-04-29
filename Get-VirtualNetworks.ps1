<#
.SYNOPSIS
Lists Azure VNets

.DESCRIPTION
Lists virtual networks in Azure subscriptions, optionally with list of subnets, netmask, and available IP addresses

.PARAMETER subscriptionFilter
Mandatory. Lists VNets range for the subscriptions matching the filter, may be a list of comma-separated values

.PARAMETER details
additionally lists max number of hosts, netmask, minimum and maximum available IP addresses for each network

.PARAMETER includeSubnets"
list all subnets for each VNet

.PARAMETER outFile"
if given, export result into a semicolon-separated CSV file rather than a list of objects
.PARAMETER delimiter	<separator>
Separator character for the CSV file. Default is the list separator for the current culture.
Requires the -outFile parameter. 

#>

[CmdletBinding(DefaultParameterSetName = 'default')]
Param (
    [Parameter(Mandatory, Position=0)] [string[]] $subscriptionFilter,
    [switch] $details,
    [switch] $includeSubnets,
    [Parameter(Mandatory, ParameterSetName="outfile")] [string] $outFile = '',
    [Parameter(ParameterSetName="outfile")] [string] $delimiter = ';'
)

# convert a binary (=64 bit integer) IP address to a string of four dot-separated octets
function Int64ToIPString ([int64] $value)
{
    $ret = ''
    for ($i = 3; $i -ge 0; $i--) {
        if ($ret -ne '') {$ret += '.'}
        $ret += ($value -shr ($i*8) -band 0xFF)
    }
    $ret
}

# convert an IP address given as a dot-separated string of for octets to a binary (int64) value
function IPStringToInt64 ([string] $ipString) {
    $ret = [int64] 0
    $addr = $ipString.Split('.')
    for ($i = 0; $i -le 3; $i++) {
        $ret = (256*$ret) + [Convert]::ToInt64($addr[$i])
    }
    $ret
}

#the Azure API gives us a network in the format {a.b.c.d/mask}, and we just want the mask
function AddressPrefixToPrefix ([string] $prefix)
{
    $($prefix.Replace('{','').replace('}','') -split '/')[1]
}
#the Azure API gives us a network in the format {a.b.c.d/mask}, and we just want the part a.b.c.d
function AddressPrefixToNet ($prefix)
{
    $($prefix.Replace('{','').replace('}','') -split '/')[0]
}

# network prefix is given as an integer (e.g. 28), and we want the binary mask (e.g. 0xFFFFFF00)
function AddressPrefixToMask ([Int32] $prefix)
{
    [Int64]0xFFFFFFFF -shl (32 - $prefix) -band 0xFFFFFFFF
}

# ========== BEGIN MAIN ================
#
#

# set default for CSV field separator if needed
if (-not $PSBoundParameters.ContainsKey('delimiter')) {
    $delimiter = (Get-Culture).textinfo.ListSeparator
}

# user may have given more than one filter
# we collect all subscription names matching any of the filter expressions
$subscriptionNames = @{}
foreach ($filter in $subscriptionFilter) {
    foreach ($subscription in $(Get-AzSubscription | Where-Object {$_.Name -like "*$filter*" -and $_.State -eq 'Enabled'})) {
        $subscriptionNames[$subscription.Name] = 0
    }
}
$subscriptions = $(Get-AzSubscription -ErrorAction SilentlyContinue -WarningAction SilentlyContinue | Where-Object {$_.Name -in $($subscriptionNames.Keys)}) | Sort-Object -Property Name
$countS = 0 # used for progress bar

# the result for each subscription and VNet is returned as a PSCustomObject
# we want all results in an array, so that we later process or export them
$result = $(
    foreach ($subscription in $subscriptions) {
        Select-AzSubscription $subscription | Out-Null
        $countS++
        Write-Progress -Id 1 -PercentComplete $($countS * 100 / $subscriptions.count) -Status "analyzing $countS of $($subscriptions.count) ($($subscription.name))" -Activity 'iterating subscriptions'
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
    Write-Progress -Id 1 -Activity 'iterating subscriptions' -Completed
) | Sort-Object -Property Subscription, VNet, Subnet

if ($outFile) {
    $result | Export-Csv -Delimiter $delimiter -Path $outFile -NoTypeInformation
} else {
    $result
}
