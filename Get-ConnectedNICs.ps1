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
#
#
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

# the result for each VM is returned as a PSCustomObject
# we want all results in an array, so that we later process or export them
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
                    # the 'Id' member has the format
                    # /subscriptions/<guid>/resourceGroups/<rgname>/providers/Microsoft.Network/networkInterfaces/<nicname>/ipConfigurations/<configname>
                    # we split that by the slashes and are only interested in the parts <rgname> and <nicname>, which are the parts 4 and 8, respectively
                    $IpId = ($IpConfiguration.Id) -split '/'
                    # get the NIC using its name and resource group
                    $Nic = Get-AzNetworkInterface -ResourceGroupName $IpId[4] -Name $IpId[8] -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
                    if ($Nic -eq $null -or $Nic.VirtualMachine -eq $null) {
                        # there may be no NIC, or the NIC may not be attached to a VM
                        continue
                    }
                    $NicCount++
                    # the NIC has a reference to the VM it is attached to, the reference has a member 'Id', the of which is
                    # /subscriptions/<guid>/resourceGroups/<rgname>/providers/Microsoft.Compute/virtualMachines/<vmname>,
                    # and we are only interested in the <vmname>, which is part 8
                    $VmName = ($nic.VirtualMachine.Id -split '/')[8]
                    # try top see whether this VM is known to DNS
                    $DnsRec=Resolve-DnsName $VmName -QuickTimeout -ErrorAction Ignore
                    If ($DnsRec -ne $null) {
                        $DnsName = $DnsRec.Name
                    } else {
                        $DnsName = '(none)'
                    }
                    foreach ($NicIpCfg in $Nic.IpConfigurations) {
                        # a NIC may have more than one IP address, so iterate
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
                            # we don't want to PING, so skip that member
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
