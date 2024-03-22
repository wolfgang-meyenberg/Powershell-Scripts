[CmdletBinding(DefaultParameterSetName = 'default')]

Param (
    [Parameter(ParameterSetName="default", Mandatory, Position=0)] [string] $subscriptionFilter,
    [Parameter(ParameterSetName="default", Position=1)] [string] $outFile = '',
    [Parameter(ParameterSetName="default", Position=2)] [switch] $noPing,
    [Parameter(ParameterSetName="help")] [Alias("h")] [switch] $help
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

function OutputSubnetInfo ([string] $addressPrefix)
{
    $network = AddressPrefixToNet ($addressPrefix)
    $prefix = AddressPrefixToPrefix($addressPrefix)
    $netmask = Int64ToIPString(AddressPrefixToMask ($prefix))

    $int64Address = IPStringToInt64($network)
    $hostMin = Int64ToIPString($int64Address + 1)

    $numhosts = [bigint]::Pow(2, 32-$prefix) - 2
    $hostmax = Int64ToIPString($int64Address + $numhosts)
    "$network;/$prefix;$numhosts;$netmask;$hostMin;$hostmax"
}

# ========== BEGIN MAIN ================


if ($help) {
    "NAME"
    "    Get-ConnectedNICs"
    ""
    "SYNTAX"
    "    Get-ConnectedNICs -subscriptionFilter <filterexpression> [-outFile <outfilename>] [-noPing]"
    ""
    "    Lists network interfaces with IP address, VNet name, network address and DNS record,"
    "    also tests whether NIC is responding to pings"
    "    -subscriptionFilter  mandatory parameter, list NICs in subscriptions matching the filter"
    "    -outFile             writes results to a semicolon-separated CSV format if this parameter is given"
    "    -noPing              skips testing whether the NIC is responding to a ping"
    ""
    exit
}

if ($subscriptionFilter -ne '*') {
    $subscriptionFilter = "*$subscriptionFilter*"
}

$subscriptions = Get-AzSubscription | Where-Object {$_.Name -like $subscriptionFilter}

$result = $(
    foreach ($subscription in $subscriptions | Sort-Object -Property Name) {
        Select-AzSubscription $subscription | Out-Null
        $VNets = Get-AzVirtualNetwork
        foreach ($VNet in $VNets) {
            foreach ($subnet in $VNet.Subnets) {
                $addressPrefix = $subnet.AddressPrefix.Replace('{','').replace('}','')
                $network = AddressPrefixToNet ($addressPrefix)
                $prefix = AddressPrefixToPrefix($addressPrefix)
                $NicCount = 0
                foreach ($IpConfiguration in $subnet.IpConfigurations) {
                    $IpId = ($IpConfiguration.Id) -split '/'
                    $Nic = Get-AzNetworkInterface -ResourceGroupName $IpId[4] -Name $IpId[8] -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
                    if ($Nic -eq $null -or $Nic.VirtualMachine -eq $null) {
                        continue
                    }
                    $NicCount++
                    $VmName = ($nic.VirtualMachine.Id -split '/')[8]
                    $DnsRec=Resolve-DnsName $VmName -QuickTimeout -ErrorAction Ignore
                    If ($DnsRec -ne $null) {
                        $DnsName = $DnsRec.Name
                    } else {
                        $DnsName = '(none)'
                    }
                    foreach ($NicIpCfg in $Nic.IpConfigurations) {
                        $NicIP = $NicIpCfg.PrivateIPAddress
                        if (-not $noPing) {
                            $Live = (Test-NetConnection $NicIP -ErrorAction SilentlyContinue -WarningAction SilentlyContinue).PingSucceeded
                            [PSCustomObject]@{
                                Subscription = $($subscription.Name)
                                VNet = $($VNet.Name)
                                Subnet = $($subnet.Name)
                                Network	= $network
                                Prefix = $prefix
                                VmName = $VmName
                                IP = $NicIP
                                DnsName = $DnsName
                                IsLive = $Live
                            }
                        } else {
                            [PSCustomObject]@{
                                Subscription = $($subscription.Name)
                                VNet = $($VNet.Name)
                                Subnet = $($subnet.Name)
                                Network	= $network
                                Prefix = $prefix
                                VmName = $VmName
                                IP = $NicIP
                                DnsName = $DnsName
                            }
                        }
                    }
                }
            }
        }
    }
)

if ($outFile) {
    $result | Export-Csv -Delimiter ";" -Path $outFile -NoTypeInformation
} else {
    $result
}
