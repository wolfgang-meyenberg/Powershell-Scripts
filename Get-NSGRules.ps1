<#
.SYNOPSIS
 Lists the effects of NSG rules in the given subscriptions in a summarized or detailed way

.DESCRIPTION
Lists the effects of NSG rules in the given subscriptions in a summarized or detailed way.
By default, overlapping rules, IP ranges and ports are merged, so the output will provide an overview about ports that are open within the subscription, regardless of subnets.
This is useful to see e.g. whether ANY-ANY rules exist or critical ports are open at all.
For a further analysis, use the -details switch, which will list individual rules

.PARAMETER subscriptionFilter
Mandatory. Analyse NSGs in given subscription(s).

.PARAMETER briefDetails
Display open ports, aggregated by source and destination network.

.PARAMETER details
Display open ports for each individual NSG rule.
#>

[CmdletBinding(DefaultParameterSetName = 'BriefDetails')]

Param (
    [Parameter(ParameterSetName="NoDetails", Mandatory=$true, Position=0)]
    [Parameter(ParameterSetName="BriefDetails", Mandatory=$true, Position=0)]
    [Parameter(ParameterSetName="AllDetails", Mandatory=$true, Position=0)]
    [string] $subscriptionFilter,

    [Parameter(ParameterSetName="BriefDetails", Position=1)]
    [switch] $briefDetails,

    [Parameter(ParameterSetName="AllDetails", Position=1)]
    [switch] $details
)

# ============  CLASS DEFINITIONS ============

# some NSG rules may be overlapping, so we need a structure to collect
# and possibly consolidate such port intervals

############
# a class that defines an interval of integers
# a single integer is represented by an interval where upper and lower bounds are equal
# the assumption is that lower bound < upper bound is always true, otherwise results are undefined
#
class Int32Interval {
    [Int32] $lowerBound
    [Int32] $upperBound

    # instantiate empty Interval
    Int32Interval() {
        $this.lowerBound = 0
        $this.upperBound = -1
    }

    # instantiate Interval with given bounds
    Int32Interval([Int32]$LowerBound, [Int32]$Upperbound) {
        $this.lowerBound = $LowerBound
        $this.upperBound = $UpperBound
    }

    # instantiate Interval with bounds given by a string in format <lowerbound>-<upperbound>
    # e.g. Int32Interval('10-12')
    Int32Interval([string]$Bounds) {
        $i = $Bounds.IndexOf('-')
        [Int32]$lb = 0
        [Int32]$ub = 0
        if ($i -ge 0) {
            [Int32]::TryParse($Bounds.Substring(0, $i), [ref]$lb) | Out-Null
            [Int32]::TryParse($Bounds.Substring($i+1), [ref]$ub) | Out-Null
        } else {
            [Int32]::TryParse($Bounds, [ref]$lb) | Out-Null
            [Int32]::TryParse($Bounds, [ref]$ub) | Out-Null
        }
        $this.lowerBound = $lb
        $this.upperBound = $ub
    }

    # returns the lower bound of the Interval
    [Int32Interval]min([Int32Interval]$interval) {
        if ($this.upperBound -le $interval.lowerBound) {
            return $this
        } else {
            return $interval
        }
    }

    # returns the upper bound of the Interval
    [Int32Interval]max([Int32Interval]$interval) {
        if ($this.upperBound -ge $interval.lowerBound) {
            return $this
        } else {
            return $interval
        }
    }

    # checks whether intervals overlap or are adjacent
    # e.g. the intervals '10-12' and '13-18' would be "adjacent", because 12 and 13 are neighbours
    [bool]IsAdjacent([Int32Interval]$interval) {

        [Int32Interval]$lower  = $this.min($interval)
        [Int32Interval]$upper  = $this.max($interval)
        return $lower.upperBound+1 -ge $upper.lowerbound # lower's upper bound is adjacent to or higher than upper's lower bound
    }

    # return lower bound
    [Int32]LowerBound() { return $this.lowerBound }

    # return upper bound
    [Int32]UpperBound() { return $this.upperBound }

    # checks whether a value is inside Interval
    [bool]Contains([Int32]$x) { return ($x -ge $this.lowerBound) -and ($x -le $this.upperBound) }

    # checks whether another Interval is fully contained in this Interval
    [bool]Contains([Int32Interval]$interval) { return ($interval.lowerbound -ge $this.lowerBound) -and ($interval.upperbound -le $this.upperBound) }
    
    # returns the Interval in a string of format <lowerbound>-<upperbound>
    [string]ToString() {
        if ($this.lowerBound -eq $this.upperBound) {
            return $this.lowerBound
        } else {
            return $this.lowerBound.ToString() + "-" + $this.upperBound.ToString()
        }
    }

    # expands Interval if both Intervals partially coincide or are immediate neighbours
    # returns true if this is the case
    # if not, false is returned and the Interval is not changed
    # examples:
    #     [10-12] + [13-18] --> [10-18]
    #     [10-12] + [14-18] --> false
    [bool] Expand([Int32Interval]$interval) {
        if ( $this.IsAdjacent($interval) ) {
            if ($interval.lowerBound -lt $this.lowerBound) {$this.lowerBound = $interval.lowerBound }
            if ($interval.upperBound -gt $this.upperBound) {$this.upperBound = $interval.upperBound }
            return $true
        } else {
            return $false
        }
    }
}

############
# a class that defines a list of integer Intervals
# a specialty is the memberfunction "add".
# If a new Interval is added, and this overlaps or coincides with, or is an immediate neighbour
# of any existing interval(s), then all these matches are merged into one Interval
# In any case, the list is sorted
# examples:
#    [10-12], [15-18] + [2-4] --> [2-4], [10-12], [15-18]  (no overlaps)
#    [10-12], [15-18] + [19-20] --> [10-12], [15-20]       (2nd and 3rd interval are adjacent and hence merged)
#    [10-12], [15-18] + [13-14] --> [10-18]                (all intervals are adjacent and hence merged)
#
class Int32IntervalList {
    [Int32Interval[]] $theList

    Int32IntervalList() { $this.theList = [Int32Interval[]]@() }

    [void]Add([Int32Interval]$newInterval) {
        # add element to list
        $this.theList += $newInterval
        # sort list by lower bounds
        $this.theList = $this.theList | Sort-Object -Property lowerBound
        # now consolidate Intervals
        $i = 0 # points to Interval we try to expand
        $j = 1 # iterates through intervals (j>i) that we try to merge into Interval #i

        [Int32Interval[]] $newList = [Int32Interval[]]@()
        do {
            if ( ($j -lt $this.theList.Count) -and
                 ( $this.theList[$i].Expand($this.theList[$j]) ) ) {
                # "Expand" returned $true, so item #j was successfully merged into item #i
                # we then proceed to try the next larger interval
                $j++
            } else {
                # Expand returned $false, so merge was not successful and Interval #i was not changed
                # so add Interval #i into the new list and proceed with the next Interval in the original list
                $newList += $this.theList[$i]
                $i = $j
                $j++
            }
        } while ($i -lt $this.theList.Count) 
        $this.theList = $newList
    }

    # return an element of this list
    [Int32Interval]Element([int]$i) { return $this.theList[$i] }

    # return all intervals separated by given separator.
    [string]ToString([char] $separator) {
        [string]$ret = ''
        foreach ($interval in $this.theList) {
            if ($ret -ne '') { $ret += $separator }
            $ret += $interval.ToString()
        }
        return $ret
    }

    # return all intervals separated by comma and enclosed in {}
    [string]ToString() {
        [string]$ret = '{'
        foreach ($interval in $this.theList) {
            if ($ret -ne '{') { $ret += ',' }
            $ret += $interval.ToString()
        }
        return $ret + '}'
    }
}

# convert a list of ranges in the format of e.g. '10-12,3,53,100-110, 4-7' into an Interval List [3-7],[10-12],[100-110]
function Rangelist2IntervalList([array]$rangeList, [bool]$reset, [Int32IntervalList]$intervalList) {
    if ($reset) {
        $intervalList = [Int32IntervalList]::new()
    }
    foreach ($range in $rangeList) {
        [Int32Interval]$interval = [Int32Interval]::new($range)
        $intervalList.Add($interval)
    }
    $intervalList
}

# ============ BEGIN MAIN PROGRAM ============
#
#
$subscriptions = Get-AzSubscription | Where-Object {$_.Name -like "*$subscriptionFilter*"}

foreach ($subscription in $subscriptions) {
    Select-AzSubscription $subscription | Out-Null
    $NSGs = Get-AzNetworkSecurityGroup
    if (-not $details) {
        # we need this variable for consolidation of rules only, not for details
        $protocolPorts = @{}
    }
    if ($details) {
        $sourcePorts = [Int32IntervalList]::new()
        $destinationPorts = [Int32IntervalList]::new()
        foreach ($nsg in ($NSGs | Sort-Object -Property Name)) {
            foreach ($rule in ($nsg.SecurityRules | Sort-Object -Property Direction, Priority)) {
                if ($rule.SourcePortRange[0] -ne '*') {
                    $sourcePorts = Rangelist2IntervalList $rule.SourcePortRange $details $sourcePorts
                } else {
                    $sourcePorts.Add('1-65535')
                }
                if ($rule.DestinationPortRange[0] -ne '*') {
                    $destinationPorts = Rangelist2IntervalList $rule.DestinationPortRange $details $destinationPorts
                } else {
                    $DestinationPorts.Add('1-65535')
                }
                [PSCustomObject] @{
                    Subscription = $subscription.Name
                    NSGName = $rule.Name
                    Source = $rule.SourceAddressPrefix
                    Destination = $rule.DestinationAddressPrefix
                    SourcePorts = $sourcePorts
                    DestinationPorts = $destinationPorts
                    Protocol = $rule.Protocol
                    Priority = $rule.Priority
                    Access = $rule.Access
                    Direction = $rule.Direction
                }
            }
        }
    } elseif ($briefDetails) {
        # first, collect and consolidate all source/destination networks
        foreach ($nsg in $NSGs) {
            foreach ($rule in $nsg.SecurityRules) {
                # we will consolidate rules by source, destination, protocol, and access(allow/deny)
                # so we use this as index in $protocolPorts, which is an associative array (=hash table)
                $index = $rule.SourceAddressPrefix[0] + '|' + $rule.destinationAddressPrefix[0] + '|' + $rule.Protocol.ToLower() + '|' + $rule.Access
                # use $portIntervals as an intermediate variable
                $portIntervals = $protocolPorts[$index]
                if ($null -eq $portIntervals) {
                    # $protocolPorts doesn't yet have an entry for this source-destination-protocol combination
                    $portIntervals = [Int32IntervalList]::new()
                }
                # add this rule's ports to $protocolPorts
                if ($rule.DestinationPortRange[0] -ne '*') {
                    $portIntervals = Rangelist2IntervalList $rule.DestinationPortRange $details $portIntervals
                } else {
                    $portIntervals.Add('1-65535')
                }
                $protocolPorts[$index] = $portIntervals
            }
        }

        # now, let us output the collected data
        foreach ($index in ($protocolPorts.Keys | Sort-Object)) {
            $indexFields = $index.split('|')
            [PSCustomObject] @{
                Source = $indexFields[0]
                Destination = $indexFields[1]
                Protocol = $indexFields[2]
                Ports = $protocolPorts[$index].ToString(',')
                Access = $indexFields[3]
            }
        }
    } else {
        # neither -details nor -briefDetails were given, so collect and consolidate data across all NSG rules
        # note that we ignore source and destination network, we just collect all open ports
        foreach ($nsg in $NSGs) {
            foreach ($rule in $nsg.SecurityRules) {
                # here, we use only the protocol and access (allow/deny) as index for $protocolPorts, which is an associative array (=hash table)
                $index = $rule.Protocol.ToLower() + "|" + $rule.Access
                $portIntervals = $protocolPorts[$index]
                if ($null -eq $portIntervals) {
                    # $protocolPorts doesn't yet have an entry for this protocol
                    $portIntervals = [Int32IntervalList]::new()
                }
                if ($rule.DestinationPortRange[0] -ne '*') {
                    $portIntervals = Rangelist2IntervalList $rule.DestinationPortRange $details $portIntervals
                } else {
                    $portIntervals.Add('1-65535')
                }

                $protocolPorts[$index] = $portIntervals
            }
        }
        # now, let us output the collected data
        foreach ($index in $protocolPorts.Keys) {
            $fields = $index.split('|')
            [PSCustomObject] @{
                Subscription = $subscription.Name
                Ports = $protocolPorts[$index].ToString(',')
                Protocol = $fields[0]
                Access = $fields[1]
            }
        }

    }
}
