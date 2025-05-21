<#
.SYNOPSIS
    collects cost and usage information for Azure resources and optionally export all details into one or more CSV files

.DESCRIPTION
    Collects cost data and optionally usage data for the resources in the subscriptions matching the filter and resource type.
    For each resource type, a separate CSV file is created, because the column count and headers are type dependent.
    
.PARAMETER subscriptionFilter
    Mandatory. Single filter or comma-separated list of filters. All subscriptions whose name contains the filter expression will be analysed.
    To match all accessible subscriptions, "*" can be specifed.

.PARAMETER outFile
    Mandatory if the -details switch is used. Write output to a CSV file (or a set of CSV files if -details switch is used)

.PARAMETER delimiter
    Separator character for the CSV file. Default is the list separator for the current culture.

.PARAMETER resourceTypes
    Single filter or comma-separated list of filters. Only resources with matching types will be analysed.
    Only the last part of the type name needs to be given (e.g. "virtualmachines" for "Microsoft.Compute/virtualMachines").
    To match all types, parameter can be omitted or "*" can be used.

.PARAMETER excludeTypes
    Comma-separated list of resource types, evaluation of these types will be skipped.

.PARAMETER billingPeriod
    Collect cost for given billing period, format is "yyyyMM", default is the last month.

.PARAMETER details
    Creates CSV files for each resource type with detailed cost and optionally usage information.
    Since the detailed results have a different format for each resource type, results are not written to a single CSV file,
    but to separate files, one for each resource type. For these files, the resource type will be inserted into the name before the final dot.
    Requires -outFile

.PARAMETER showUsage
    Display usage information for each cost item additionally to the cost.
    Requires -details.

.PARAMETER showUnits
    Display the units for usages and cost as second header line.
    This is useful with the -usage switch, as the metrics come in 1s, 10000s, or so.
    Requires -details

.PARAMETER count
    Create an additional file displaying the resource count per subscription and type.
    Requires -outFile

.PARAMETER WhatIf
    Don't evaluate costs but show a list of resources and resource types which would be evaluated.

.EXAMPLE
Get-ResourceCostDetails.ps1 -subscriptionFilter mySubs002 -resourceTypes *,routeTables -excludeTypes snapshots -showUsage
    Analyze resource of all types(*) in given subscription, except snapshots.

.EXAMPLE
Get-ResourceCostDetails.ps1 -subscriptionFilter * -resourceTypes virtualMachines,storageAccounts -billingPeriod 202405 -outFile result.csv
    Analyze virtual machines and storage accounts for billing period May 2024 in all accessible subscriptions and write result to a set of CSV files.
    For the two resource types, two separate files will be created named "result-virtualMachines.csv" and "result-storageAccounts.csv"
#>

[CmdletBinding(DefaultParameterSetName = 'default')]
Param (
    [Parameter(ParameterSetName="default", Mandatory, HelpMessage="one or more partial subsciption names", Position=0)]
    [Parameter(ParameterSetName="WhatIf", HelpMessage="one or more partial subsciption names", Position=0)]
    [SupportsWildcards()]
    [string[]] $subscriptionFilter,

    [Parameter(ParameterSetName="default", Mandatory, HelpMessage="first part of filename for output CSV file (resource type will be added to filename(s))", Position=1)]
    [string] $outFile,

    [Parameter(ParameterSetName="default", HelpMessage="character to be used as delimiter. Default is culture-specific.")]
    [string] [ValidateLength(1,1)] $delimiter,

    [SupportsWildcards()]
    [string[]] $resourceTypes = @('*'),

    [SupportsWildcards()]
    [string[]] $excludeTypes = @(), 

    [Parameter(ParameterSetName="default", HelpMessage="billing period for which data is collected, format is 'yyyymm'")]
    [string] $billingPeriod = '',

    [Parameter(ParameterSetName="default", HelpMessage="display total cost per resource as last column")]
    [switch] $totals,

    [Parameter(ParameterSetName="default", HelpMessage="create an additional report with a matrix of subscriptions, resources, and cost")]
    [switch] $consolidate,

    [Parameter(ParameterSetName="default", HelpMessage="Create a report ONLY with a matrix of subscriptions, resources, and cost.")]
    [switch] $consolidateOnly,

    [Parameter(ParameterSetName="default", HelpMessage="display usage metrics additional to cost")]
    [switch] $showUsage,

    [Parameter(ParameterSetName="default", HelpMessage="show the units and scale for the metrics")]
    [switch] $showUnits,

    [Parameter(ParameterSetName="default", HelpMessage="Create an additional file displaying the resource count per subscription and type")]
    [switch] $count,

    [Parameter(ParameterSetName="WhatIf", HelpMessage="display all subscriptions and resources that would be analysed. Also displays the resource types which are excludedd by default")]
    [switch] $WhatIf
)

# necessary modules:
# Azure


###############################################
# some helper functions first
#

# returns true if the value matches any of the filters in includeFilters and is not present in excludeFilters
#
# inclusion filters are prepended with '*', because in this script we filter for the
# last part of a resource type (e.g. Microsoft.Compute/virtualMachines matches *virtualMachines)
#
# exclusion filters are enclosed with '*', so a type will be excluded if any part matches the filter
#
# inclusion and exclusion filters may also be given as '*', which matches all types
# order of evaluation is: inclusions except '*', exclusions, '*' inclusions
function MatchFilter ([string] $value, [string[]]$includeFilters, [string[]]$excludeFilters)
{
    foreach ($inclusion in $includeFilters) {
        if ( ($inclusion -ne '*') -and ($value -like "*$inclusion*") ) {
            return $true # this value is included
        }
    }
    foreach ($exclusion in $excludeFilters) {
        if ( ($exclusion -eq '*') -or ($value -like "*$exclusion*") ) {
            return $false # this value is excluded
         }
    }
    foreach ($inclusion in $includeFilters) {
        if ($inclusion -eq '*') {
            return $true # a '*' filter matches every type
        }
    }
    return $false # not found in inclusion list
}

# we later need a two-dimensional hash table of float values indexed by <subsciption> and <resource type>
# we use that to sum up the total cost per subscription and resource type
function AddToOverview ([hashtable]$hashTable, [string]$subscription, [string]$resourceType, [float]$cost) {
    if ($null -ne $hashTable[$subscription]) {
        Write-Verbose "adding cost to hashtable: $cost"
        $hashTable[$subscription][$resourceType] += $cost
    } else {    # hashTable does not yet contain a key for the subscription,
                # so create one
        $hashTable[$subscription] = @{$resourceType = $cost}
    }
}

## ##############################################
## ################# BEGIN MAIN #################
##
##

# (before beginning the actual processing, do some parameter magic first)

# set default for CSV field separator if needed
if (-not $PSBoundParameters.ContainsKey('delimiter')) {
    $delimiter = (Get-Culture).textinfo.ListSeparator
}

# if user hasn't given a billing period, we assume the previous month
if ($billingPeriod -eq '') {
    $billingPeriod = (Get-Date (Get-Date).AddMonths(-1) -Format "yyyyMM")
}

# now we are ready...

# we collect all subscription names matching any of the filter expressions
# (user may have given more than one filter)
$subscriptionNames = @{}
foreach ($filter in $subscriptionFilter) {
    if (-not $filter.Contains('*')) {
        $filter = '*' + $filter + '*'
    }
    foreach ($subscription in $(Get-AzSubscription | Where-Object {$_.Name -like "$filter" -and $_.State -eq 'Enabled'})) {
        $subscriptionNames[$subscription.Name] = 0
    }
}
Write-Verbose "we will analyse these subscriptions: $($subscriptionNames.Keys | Join-String -Separator ',')"

try {
    # determine the subscription(s) which match the subscription filter
    #this command throw an exception if we haven't logged on to Azure first
    Write-Verbose "call to Get-AzSubscription..."
    $subscriptions = $(Get-AzSubscription -ErrorAction SilentlyContinue -WarningAction SilentlyContinue | Where-Object {$_.Name -in $($subscriptionNames.Keys)}) | Sort-Object -Property Name
}
catch {
    Write-Verbose "call to get-AzSubscription threw an exception as you are not logged on to Azure."
    if ($PSItem.Exception.Message -like '*Connect-AzAccount*') {
        throw "you are not logged on to Azure. Run Connect-AzAccount before running this script."
    } else {
        # something else was in the way
        throw $PSItem.Exception
    }
}

if (-not $WhatIf) {
    # in the standard (non-WhatIf) case, we need to analyse at least one subscription
    if ($null -eq $subscriptions) {
        "no subscriptions matching this filter found."
        exit
    }
}

if ($WhatIf) {
    # we won't run through an analysis but will only show the user
    # which subscriptions and resources we would analyse
    "analyse the cost items for the resources for billing period $($billingPeriod):"
    foreach ($subscription in $subscriptions) {
        Select-AzSubscription $subscription | Out-Null
        foreach ($resource in Get-AzResource) {
            if ( ($null -eq $resourceTypes) -or ( MatchFilter $resource.resourceType $resourceTypes $excludeTypes ) ) {
                [PSCustomObject]@{
                    subscription = $subscription.Name
                    type         = $resource.resourceType
                    resource     = $resource.Name
                }
            }
        }
    }
   exit
}

if ($count) {
    $resourceCount = @{}     # 2D hash table forresource count, indexed by subscription and resource type
}

#####################################
# OK, finally the main processing will begin
#

$countS = 0 # used for progress bar

$thisSubscriptionsConsumptions = @()    # all resource consumptions from all subscriptions as provided by the API
$ConsumptionData = @()                  # all resources that have generated nonzero cost. In the sequel, we ignore resources
                                        # which don't generate any cost
$header = @{}                           # hash table (resource-names --> hash table (metric-names --> units) )
$consolidatedData = @{}                 # 2D hash table for overview, indexed by subscription and resource type

foreach ($subscription in $subscriptions) {
    Write-Verbose "analyzing subscription $($subscription.Name)"
    Select-AzSubscription $subscription | Out-Null
    $countS++ # count for 1st level progress bar
    Write-Progress -Id 1 -PercentComplete $($countS * 100 / $subscriptions.count) -Status "subscription $countS of $($subscriptions.count) ($($subscription.Name))" -Activity 'collecting data via API'

    #==============================================================
    # first, get consumption data for ALL resources in the current subscription
    Write-Verbose "calling Get-AzConsumptionUsage Detail..."    
    $thisSubscriptionsConsumptions = ($(Get-AzConsumptionUsageDetail -BillingPeriod $billingPeriod -Expand MeterDetails) | `
    # we only want some data metrics for subsequent analysis.
    Select-Object @{l='Type';e={$_.InstanceId.split('/')[-2]}}, `
    InstanceName, Product, PretaxCost, UsageQuantity, `
        @{l='meterName';e={($_|Select-Object -ExpandProperty MeterDetails | Select-Object meterName).meterName }}, `
        @{l='MeterCategory';e={($_|Select-Object -ExpandProperty MeterDetails | Select-Object MeterCategory).MeterCategory }}, `
        @{l='MeterSubCategory';e={($_|Select-Object -ExpandProperty MeterDetails | Select-Object MeterSubCategory).MeterSubCategory }}, `
        @{l='Unit';e={($_|Select-Object -ExpandProperty MeterDetails | Select-Object Unit).Unit }} | `
    Group-Object -Property InstanceName, Product)
    Write-Verbose "API call returned $($thisSubscriptionsConsumptions.Count) cost records"
    # accumulate usage and cost for the selected billing period and resource types
    $countU = 0 # for progress bar
    $thisSubscriptionsConsumptions | foreach-object {
        # thisSubscriptionsConsumptions will contain multiple cost entries for each resource and metric, typically one per day,
        # so we sum them up here
        $cost = ($_.Group | measure-object -Property PretaxCost -Sum).Sum
        $usage = ($_.Group | measure-object -Property UsageQuantity -Sum).Sum
        $countU++
        Write-Progress -Id 2 -PercentComplete $($countU * 100 / $thisSubscriptionsConsumptions.Count) -Status "collecting resource data $countU of $($thisSubscriptionsConsumptions.count) ($($_.Group[0].InstanceName))" -Activity 'analyzing resource data'
        # collect cost for each resource. A resource typically has several cost metrics
        if ( ($cost -ge 0.01) -and `
             ( ($null -eq $resourceTypes) -or ( MatchFilter $_.Group[0].Type $resourceTypes $excludeTypes ) )
           ) {
            $newUsage = [PSCustomObject]@{
                Subscription = $subscription.Name
                resourceType = $_.Group[0].Type
                Product      = $_.Group[0].Product
                ResourceName = $_.Group[0].InstanceName
                Cost = $Cost
                Usage = $usage
                Meter = $_.Group[0].meterName + " (" + $_.Group[0].MeterSubCategory + ")"
                MeterCategory = $_.Group[0].MeterCategory
                MeterSubCategory = $_.Group[0].MeterSubCategory
                Unit =  $_.Group[0].Unit
                }
            if ($newUsage.ResourceName -eq 'MSSQLSERVER') {
                # with MSSQLserver (DB aaS) resources, the resource name is always given
                # as 'MSSQLSERVER' while the type is some GUID - we swap that so that we see MSSQLSERVER as type
                # and the GUID as name
                $newUsage.resourceName = $newUsage.ResourceType
                $newUsage.resourceType = 'mssqlserver'
            }
            Write-Verbose "adding cost record to consumptiondata: $newUsage"
            $ConsumptionData += $newUsage
            try {
                Write-Verbose "adding meter $($newUsage.Meter) with unit $($_.Group[0].Unit) for resource type $($newUsage.resourceType)"
                $header[$newUsage.resourceType] += @{$newUsage.Meter = $_.Group[0].Unit} 
            }
            catch {} # ignore error if we try to create a duplicate entry
        } #if cost -ne 0 & resource type matches filter
    } # foreach resource consumption in this subscription
    Write-Progress -Id 2 -Activity 'analyzing resource data' -Completed
} # for all subscriptions
Write-Progress -Id 1 -Activity 'collecting data via API' -Completed
Write-Verbose "analyzed all subscriptions. Consolidated consumption data has $($ConsumptionData.Count) records"

##############
# Now let's output the actual data. We need to iterate through the resources by resource typpe,
# because we write separate output for each resource type.
# A resource typically has multiple entries, one for each meter which generated cost, 
# so we iterate through the grouped resources only.

$allresourceTypes = ($ConsumptionData|Group-Object -Property resourceType -NoElement).Name
Write-Verbose "consolidating data for the resource types: $allresourceTypes..."
$countRT = 0 # for progress bar
foreach  ($resourceType in $allresourceTypes) {
    $countRT++      # for progress bar
    $results = @()  # array storing the results. We need that because at the end we will output the
                    # results ordered by subscription and resource name
    $headers = @()  # collector for header(s)

    Write-Progress -Id 1 -PercentComplete $($countRT * 100 / $allresourceTypes.count) -Status "type $countRT of $($allresourceTypes.count) ($resourceType)" -Activity 'collecting resources'
    # all resources of the current type
    $resourcesOfThisType = ($ConsumptionData | Where-Object -Property resourceType -eq -Value $resourceType)
    # all meters for all resources of the current type
    $meterNames = $header[$resourceType].keys
    Write-Verbose "there are $($resourcesOfThisType.count) resources of type $resourceType"
    Write-Verbose "meters for resource type $resourceType are: $meterNames)"
    # for the output, we will generate a separate file
    # because each resource type has different cost titems
    # The user gave us a file name like 'xyz.csv', and each csv file will get a special name like 'xyz-<resourceType>.csv'
    $outFileName = (($outFile.split('.')[0..($outFile.Count-1)])[0]).ToString() + '-' + $resourceType.Split('/')[-1] + '.' + $outFile.Split('.')[-1]        # First output the header line.
    Write-Verbose "writing header to $outFileName"        
    # The header lists optionally the usages first and then the cost
    $item = [PSCustomObject] @{
        # dummy entries for the first three columns
        column1 = "Subscription (billing period $($billingPeriod.Substring(0,4))-$($billingPeriod.substring(4,2)))"
        column2 = 'Resource Name'
        column3 = 'Resource Type'
    }
    $columnCount = 4
    # add 'totals' column header in case user wants to see totals
    if ($totals) {
        $item | Add-Member -MemberType NoteProperty -Name "column$($columnCount)" -Value ("Total Cost")
        $columnCount++
    }
    # add usage header items if user wants to see that
    if ($showUsage) {
        foreach ($meterName in $meterNames | Sort-Object) {
            $item | Add-Member -MemberType NoteProperty -Name "column$($columnCount)" -Value ($meterName + " Usage")
            $columnCount++
        }
    }
    foreach ($meterName in $meterNames | Sort-Object) {
        $item | Add-Member -MemberType NoteProperty -Name "column$($columnCount)" -Value ($meterName + " Cost")
        $columnCount++
    }
    # now write the header
    Write-Verbose "adding  item to headers: $item"
    $headers += $item

    # in case the -showUnits switch is given, add a second header line displaying the units
    if ($showUnits) {
        # as the metrics have different scales (1s, 10000s, etc), we want to have the units as first object
        # if you export to a CSV file, the units will form a second header line  
        # return the units as first object "$item"
        Write-Verbose "writing units header to $outFileName"        
        $item = [PSCustomObject] @{
            # dummy entries for the first members (=fields of the header line)
            Subscription = ''
            Name         = ''
            resourceType = 'units'
        }
        if ($totals) {
            $item | Add-Member -MemberType NoteProperty -Name $('Total Cost') -Value $((Get-Culture).NumberFormat.CurrencySymbol)
        }
        # add the header items for the usage metrics, if we want to see that
        if ($showUsage) {
            foreach ($meterName in $meterNames) {
                $unit = $header[$resourceType][$meterName]
                $item | Add-Member -MemberType NoteProperty -Name $($meterName + ' Usage') -Value $unit
            }
        }
        # add the current currency symbol as cost metric
        foreach ($meterName in $meterNames) {
            $item | Add-Member -MemberType NoteProperty -Name $($meterName + ' Cost') -Value $((Get-Culture).NumberFormat.CurrencySymbol)
        }
        # now write the 2nd header line
        $results += $item
    } # if -showUnits

    # Now let's write the actual data for the resources of the given type
    $countR = 0 # for progress bar
    $totalCount = ($resourcesOfThisType | Group-Object -Property ResourceName -NoElement).count # for progress bar
    Write-Verbose "collect data for $totalCount resources of type $resourceType"
    foreach ($resourceName in ($resourcesOfThisType | Group-Object -Property ResourceName -NoElement).Name) { 
        $countR++
        $resourceUnderReview = ($resourcesOfThisType | Where-Object -Property ResourceName -EQ -Value $resourceName)
        $totalResourceCost = 0
        Write-Progress -Id 2 -PercentComplete $($countR * 100 / $totalCount) -Status "$countR of $($totalCount) ($resourceName)" -Activity 'collecting resource details'
        # some properties of the resource
        $item = [PSCustomObject] @{
            Subscription = $resourceUnderReview[0].Subscription
            Name         = $resourceName
            resourceType = $resourceType
        }
        if ($totals) {
            # prepare 'totals' property
            $item | Add-Member -MemberType NoteProperty -Name $('Total Cost') -Value 0
        }
        # add data for all meters which were discovered (some resources may not have data for all meters present)
        # In that case, use 0 if some meter is not present for the current resource
        # first add usage data if required, then the cost data
        if ($showUsage) {        
                foreach ($meterName in $meterNames) {
                $usageItem = ($resourceUnderReview | Where-Object -Property Meter -EQ -Value $meterName)
                if ($null -ne $usageItem) {
                    $item | Add-Member -MemberType NoteProperty -Name $($meterName + ' Usage') -Value $costItem.Usage
                } else {
                    $item | Add-Member -MemberType NoteProperty -Name $($meterName + ' Usage') -Value 0
                }
            }
        } # if showusage 
        foreach ($meterName in $meterNames) {
            $costItem =  ($resourceUnderReview | Where-Object -Property Meter -EQ -Value $meterName)
            if ($null -ne $costItem) {
                $cost = ($costItem | Measure-Object -Property Cost -Sum).Sum
                $item | Add-Member -MemberType NoteProperty -Name $($meterName + ' Cost') -Value $Cost
                Write-Verbose "adding cost item to totalResourceCost: $($Cost)"
                $totalResourceCost += $Cost
            } else {
                $item | Add-Member -MemberType NoteProperty -Name $($meterName + ' Cost') -Value 0
            }
        }  # for each meter name
        Write-Verbose "collecting data for $totalCount resources of type $resourceType finished."
        if ($totals) {
            # add data for 'totals' column
            $item."Total Cost" = $totalResourceCost
        }
        if ($consolidate -or $consolidateOnly) {
            AddToOverview $consolidatedData $item.Subscription $item.resourceType $totalResourceCost
        }
        Write-Verbose "adding item to results: $item"
        $results += $item
    } # foreach resource name
    $countR = 0 # for progress bar
    $totalCount = $results.count # for progress bar
    if (-not $consolidateOnly) {
        # write output for this resource type to the file
        foreach($item in $headers) {
            $(
                foreach($property in $item.PsObject.Properties) {
                    $property.Value
                }
            ) -join $delimiter | Out-File -FilePath $outfilename -Encoding ansi -Force
        }
        foreach( $item in ($results | Sort-Object -Property Subscription, Name) ) {
            $countR++
            Write-Progress -Id 2 -PercentComplete $($countR * 100 / $totalCount) -Status "$countR of $($totalCount) ($resourceName)" -Activity 'collecting resource details'
       
            $(
                foreach($property in $item.PsObject.Properties) {
                    $property.Value
                }
            ) -join $delimiter | Out-File -FilePath $outfilename -Encoding ansi -Append
        }
    }
    if ($count) {
        $results | Group-Object -Property Subscription | ForEach-Object {
            AddToOverview $resourceCount $_.Name $resourceType $_.Count
        }
    }
} # foreach resource type
Write-Progress -Id 2 -Activity 'collecting resource details' -Completed

if ($consolidate -or $consolidateOnly) {
    $outFileName = (($outFile.split('.')[0..($outFile.Count-1)])[0]).ToString() + '-consolidated.' + $outFile.Split('.')[-1]
    # output resource types as header line
    "billing period $($billingPeriod.Substring(0,4))-$($billingPeriod.substring(4,2))" + $delimiter + ($allresourceTypes -join $delimiter) | Out-File $outFileName -Force
    # now, write all resource totals, one line per subscription
    foreach ($subscription in $subscriptions) {
        $outLine = $subscription.Name
        foreach  ($resourceType in $allresourceTypes) {
            if ($null -ne $consolidatedData[$($subscription.Name)]) {
                $thisCost = $consolidatedData[$($subscription.Name)][$resourceType] 
                if ($null -eq $thisCost) { $thisCost = 0 }
            } else {
                $thisCost = 0
            } 
            $outLine += $delimiter + $thisCost.ToString()
        }
        $outline | Out-File $outFileName -Append
    }
} # if overview

if ($count) {
    $countFileName = (($outFile.split('.')[0..($outFile.Count-1)])[0]).ToString() + '-count.' + $outFile.Split('.')[-1]        # First output the header line.
    'Subscription','Resource Type','Count' -join $delimiter | Out-File -FilePath $countFileName -Encoding ansi -Force
    foreach ($subscription in $resourceCount.Keys) {
        foreach ($resourceType in ($resourceCount[$subscription]).Keys) {
            $subscription,$resourceType,$resourceCount[$subscription][$resourceType] -join $delimiter | Out-File -FilePath $countFileName -Encoding ansi -Append
        }
    }
} # if count

Write-Progress -Id 1 -Activity 'collecting resources' -Completed
Write-Verbose "script finished"
