<#
.SYNOPSIS
	collects cost and usage information for Azure resources, optionally exports them into one or more CSV files

.DESCRIPTION
    Collects cost data and optionally usage data for the resources in the subscriptions matching the filter and resource type.
    If an output file name is given, a separate CSV file is created for each resource type, because the column count and headers are type dependent.
    NOTE:
    Some resource types are excluded by default unless being explicitly included using the -resourceTypes parameter.
    To get a list of default exclusions, call the script with the -WhatIf switch.
    
.PARAMETER subscriptionFilter
	Single filter or comma-separated list of filters. All subscriptions whose name contains the filter expression will be analysed.
    To match all accessible subscriptions, "*" can be specifed.

.PARAMETER resourceTypes
	Single filter or comma-separated list of filters. Only resources with matching types will be analysed.
	Only the last part of the type name needs to be given (e.g. "virtualmachines" for "Microsoft.Compute/virtualMachines"). To match all types, parameter can be omitted or "*" can be used.
	Some resource types which typically don't generate cost are excluded by default, they can be included by explicitly specifying them, i.e. they are not included by "*"

.PARAMETER excludeTypes
	Comma-separated list of resource types, evaluation of these types will be skipped.

.PARAMETER billingPeriod
	Collect cost for given billing period, format is "yyyyMM", default is the last month.

.PARAMETER totals
    Display the total cost per resource as last column, i.e. the sum of all cost metrics.

.PARAMETER overview
Create an additional report with a matrix of subscriptions, resources, and cost

.PARAMETER showUsage
	Display usage information for each cost item additionally to the cost.

.PARAMETER showUnits
    Display the units for usages and cost as second header line.
    This is useful with the -usage switch, as the metrics come in 1s, 10000s, or so.

.PARAMETER outFile
	Mandatory. Write output to a set of CSV files. Without this switch, results are written to standard output as objects.
    Since the results have a different format for each resource type, results are not written to a single CSV file,
    but to separate files, one for each resource type.
    For each file, the resource type will be inserted into the name before the final dot.

.PARAMETER delimiter
	Separator character for the CSV file. Default is the list separator for the current culture.

.PARAMETER WhatIf
	Don't evaluate costs but show a list of resources and resource types which would be evaluated. Also show list of resource types which are excluded by default.

.EXAMPLE
Get-ResourceCostDetails.ps1 -subscriptionFilter mySubs001,mySubs003 -resourceTypes virtualMachines,storageAccounts
	Analyze virtual machines and storage accounts in the two given subscriptions and write result as objects to standard output

.EXAMPLE
Get-ResourceCostDetails.ps1 -subscriptionFilter mySubs002 -resourceTypes *,routeTables -excludeTypes privateDnsZones -showUsage
	Analyze resource of all types(*) in given subscription, except private DNS zones, but include route tables which are otherwise excluded by default.
    To see which resource types are excluded by default (unless specifically listed in -resourceTypes parameter), call script with -WhatIf parameter.

.EXAMPLE
Get-ResourceCostDetails.ps1 -subscriptionFilter * -resourceTypes virtualMachines,storageAccounts -billingPeriod 202405 -outFile result.csv
	Analyze virtual machines and storage accounts for billing period May 2024 in all accessible subscriptions and write result to a set of CSV files.
    For the two resource types, two separate files will be created named "result-virtualMachines.csv" and "result-storageAccounts.csv"
#>

Param (
    [Parameter(Mandatory, HelpMessage="one or more partial subsciption names", Position=0)]
    [SupportsWildcards()]
    [string[]] $subscriptionFilter,

    [Parameter(Mandatory, HelpMessage="first part of filename for output CSV file (resource type will be added to filename(s))", Position=1)]
    [string] $outFile,

    [Parameter(HelpMessage="resource types to include, last part of hierarchical name is sufficient (e.g. 'virtualmachines')")]
    [SupportsWildcards()]
    [string[]] $resourceTypes = @('*'),

    [Parameter(HelpMessage="resource types to exclude, last part of hierarchical name is sufficient (e.g. 'storageaccounts')")]
    [SupportsWildcards()]
    [string[]] $excludeTypes = @(), 

    [Parameter(HelpMessage="billing period for which data is collected, format is 'yyyymm'")]
    [string] $billingPeriod = '',

    [Parameter(HelpMessage="display total cost per resource as last column")]
    [switch] $totals,

    [Parameter(HelpMessage="create an additional report with a matrix of subscriptions, resources, and cost")]
    [switch] $consolidate,

    [Parameter(HelpMessage="display usage metrics additional to cost")]
    [switch] $showUsage,

    [Parameter(HelpMessage="show the units and scale for the metrics")]
    [switch] $showUnits,

    [Parameter(HelpMessage="character to be used as delimiter")]
    [string] [ValidateLength(1,1)] $delimiter,

    [Parameter(HelpMessage="display all subscriptions and resorces that would be analysed. Also displays the resource types which are excludedd by default")]
    [switch] $WhatIf
)

# necessary modules:
# Azure


###############################################
# some helper functions first
#

# returns true if the value matches any of the filters in includeFilters
# and is not present in excludeFilters
# inclusion filters are prepended with '*', because in this script we filter for the
# last part of a resource type (e.g. Microsoft.Compute/virtualMachines matches *virtualMachines)
# exclusion filters are enclosed with '*', so a type will be excluded if any part matches the filter
# inclusion and exclusion filters may also be given as '*', which matches all types
# order of evaluation is: inclusions except '*', exclusions, '*' inclusions
# some values are always excluded unless they are specifically included
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
        $hashTable[$subscription][$resourceType] += $cost
    } else { # hashTable does not yet contain a key for the subscription
        $hashTable[$subscription] = @{$resourceType = $cost}
    }
}

# ################# BEGIN MAIN #################
#
#

# preload a variable with the resource types which will be excluded by default
$defaultexcludeTypes = @(
    'applicationSecurityGroups',
    'automationAccounts',
    'automations',
    'components',
    'connections',
    'dataCollectionRules',
    'disks',
    'maintenanceConfigurations',
    'namespaces',
    'networkInterfaces',
    'networkSecurityGroups',
    'networkWatchers',
    'privateDnsZones',
    'privateendpoints',
    'restorePointCollections',
    'routeTables',
    'smartDetectorAlertRules',
    'snapshots',
    'solutions',
    'storageSyncServices',
    'templateSpecs',
    'userAssignedIdentities',
    'userAssignedIdentities',
    'virtualMachines/extensions',
    'virtualNetworkLinks',
    'virtualNetworks',
    'workflows',
    'activityLogAlerts'
)

#########################################
# before beginning the processing, do some parameter magic first
# 

# set default for CSV field separator if needed
if (-not $PSBoundParameters.ContainsKey('delimiter')) {
    $delimiter = (Get-Culture).textinfo.ListSeparator
}

# if user hasn't given a billing period, we assume the previous month
if ($billingPeriod -eq '') {
    $billingPeriod = (Get-Date (Get-Date).AddMonths(-1) -Format "yyyyMM")
}

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

# determine the subscription(s) which match the subscription filter
#this command will fail if we haven't logged on to Azure first
try {
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
if ($null -eq $subscriptions) {
    "no subscriptions matching this filter found."
    exit
}

# we won't run through an analysis but will only show the user
# which subscriptions and resources we would analyse
if ($WhatIf) {
    "analyse the cost items for the resources for billing period $($billingPeriod):"
    foreach ($subscription in $subscriptions) {
        Select-AzSubscription $subscription | Out-Null
        foreach ($resource in Get-AzResource) {
            if ( ($null -eq $resourceTypes) -or ( MatchFilter $resource.ResourceType $resourceTypes ($excludeTypes + $defaultexcludeTypes) ) ) {
                [PSCustomObject]@{
                    subscription = $subscription.Name
                    type         = $resource.ResourceType
                    resource     = $resource.Name
                }
            }
        }
    }
    "types excluded by default:"
    $defaultexcludeTypes | Join-String -Separator $delimiter
   exit
}

#####################################
# OK, finally the main processing will begin
#

$countS = 0 # used for progress bar

$thisSubscriptionsConsumptions = @()    # all resource consumptions from all subscriptions
$ConsumptionData = @()                  # all resources that have generated nonzero cost. In the sequel, we ignore resources
                                        # which don't generate any cost
$header = @{}                           # hash table (resource-names --> hash table (metric-names --> units) )
$consolidatedData = @{}                 # 2D hash table for overview

foreach ($subscription in $subscriptions) {
    Write-Verbose "analyzing subscription $($subscription.Name)"
    Select-AzSubscription $subscription | Out-Null
    $countS++ # count for 1st level progress bar
    Write-Progress -Id 1 -PercentComplete $($countS * 100 / $subscriptions.count) -Status " $countS of $($subscriptions.count) ($($subscription.Name))" -Activity 'collecting data via API from subscription'

    #==============================================================
    # first, get consumption data for ALL resources in the current subscription
    Write-Verbose "calling Get-AzConsumptionUsage Detail..."    
    $thisSubscriptionsConsumptions = ($(Get-AzConsumptionUsageDetail -BillingPeriod $billingPeriod -Expand MeterDetails) | `
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
        $cost = ($_.Group | measure-object -Property PretaxCost -Sum).Sum
        $usage = ($_.Group | measure-object -Property UsageQuantity -Sum).Sum
        $countU++
        Write-Progress -Id 2 -PercentComplete $($countU * 100 / $thisSubscriptionsConsumptions.Count) -Status "collecting resource data $countU of $($thisSubscriptionsConsumptions.count) ($($_.Group[0].InstanceName))" -Activity 'analyzing resource data'
        if ( ($cost -ge 0.01) -and `
             ( ($null -eq $resourceTypes) -or ( MatchFilter $_.Group[0].Type $resourceTypes ($excludeTypes + $defaultexcludeTypes) ) )
           ) {
            $newUsage = [PSCustomObject]@{
                Subscription = $subscription.Name
                ResourceType = $_.Group[0].Type
                Product      = $_.Group[0].Product
                ResourceName = $_.Group[0].InstanceName
                Cost = $Cost
                Usage = $usage
                Meter = $_.Group[0].meterName + " (" + $_.Group[0].MeterSubCategory + ")"
                MeterCategory = $_.Group[0].MeterCategory
                MeterSubCategory = $_.Group[0].MeterSubCategory
                Unit =  $_.Group[0].Unit
                }
                
            Write-Verbose "adding cost record: $newUsage"
            $ConsumptionData += $newUsage
            try {
                Write-Verbose "adding meter $($newUsage.Meter) with unit $($_.Group[0].Unit) for resource type $($newUsage.ResourceType)"
                $header[$newUsage.ResourceType] += @{$newUsage.Meter = $_.Group[0].Unit} 
            }
            catch {} # ignore error if we try to create a duplicate entry
        } #if cost -ne 0 & resource type matches filter
    } # foreach resource consumption in this subscription
    Write-Progress -Id 2 -Activity 'analyzing resource data' -Completed
} # for all subscriptions
Write-Progress -Id 1 -Activity 'collecting data via API from subscription' -Completed
Write-Verbose "analyzed all subscriptions. Consolidated consumption data has $($ConsumptionData.Count) records"

##############
# Now let's output the actual data. We need to iterate through the resources by resource typpe,
# because we write separate output for each resource type.
# A resource typically has multiple entries, one for each meter which generated cost, 
# so we iterate through the grouped resources only.

$allResourceTypes = ($ConsumptionData|Group-Object -Property ResourceType -NoElement).Name
Write-Verbose "consolidating data for the resource types: $allResourceTypes..."
$countRT = 0 # for progress bar
foreach  ($resourceType in $allResourceTypes) {
    $countRT++      # for progress bar
    $results = @()  # array storing the results. We need that because at the end we will output the
                    # results ordered by subscription and resource name
    $headers = @()  # collector for header(s)

    Write-Progress -Id 1 -PercentComplete $($countRT * 100 / $allResourceTypes.count) -Status "type $countRT of $($allResourceTypes.count) ($resourceType)" -Activity 'collecting resources'
    # all resources of the current type
    $resourcesOfThisType = ($ConsumptionData | Where-Object -Property ResourceType -eq -Value $ResourceType)
    # all meters for all resources of the current type
    $meterNames = $header[$resourceType].keys
    Write-Verbose "there are $($resourcesOfThisType.count) resources of type $resourceType"
    Write-Verbose "meters for resource type $resourceType are: $meterNames)"
    # for the output, we will generate a separate file
    # because each resource type has different cost titems
    # The user gave us a file name like 'xyz.csv', and each csv file will get a special name like 'xyz-<resourcetype>.csv'
    $outFileName = (($outFile.split('.')[0..($outFile.Count-1)])[0]).ToString() + '-' + $resourceType.Split('/')[-1] + '.' + $outFile.Split('.')[-1]        # First output the header line.
    Write-Verbose "writing header to $outFileName"        
    # The header lists optionally the usages first and then the cost
    $item = [PSCustomObject] @{
        # dummy entries for the first two members
        column1 = 'Subscription'
        column2 = 'Name'
        column3 = 'Resource Type'
    }
    $count = 4
    # add usage header items if user wants to see that
    if ($showUsage) {
        foreach ($meterName in $meterNames | Sort-Object) {
            $item | Add-Member -MemberType NoteProperty -Name "column$($count)" -Value ($meterName + " Usage")
            $count++
        }
    }
    foreach ($meterName in $meterNames | Sort-Object) {
        $item | Add-Member -MemberType NoteProperty -Name "column$($count)" -Value ($meterName + " Cost")
        $count++
    }
    # add 'totals' column header in case user wants to see totals
    if ($totals) {
        $item | Add-Member -MemberType NoteProperty -Name "column$($count)" -Value ("Total Cost")
        $count++
    }
    # now write the header
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
            ResourceType = 'units'
        }
        # add the header items for the usage metrics
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
        if ($totals) {
            $item | Add-Member -MemberType NoteProperty -Name $('Total Cost') -Value $((Get-Culture).NumberFormat.CurrencySymbol)
            $count++
        }
        # now write the 2nd header line
        $results += $item
    } # if -showUnits

    # Now let's write the actual data for the resources of the given type
    $countR = 0 # for progress bar
    $totalCount = ($resourcesOfThisType | Group-Object -Property ResourceName -NoElement).count # for progress bar
    foreach ($resourceName in ($resourcesOfThisType | Group-Object -Property ResourceName -NoElement).Name) { 
        $countR++
        $resourceUnderReview = ($resourcesOfThisType | Where-Object -Property ResourceName -EQ -Value $resourceName)
        $totalResourceCost = 0
        Write-Progress -Id 2 -PercentComplete $($countR * 100 / $totalCount) -Status "$countR of $($totalCount) of resource $resourceName" -Activity 'collecting resource details'
        Write-Verbose "collect data for resource $resourceName"        
        # some properties of the resource
        $item = [PSCustomObject] @{
            Subscription = $resourceUnderReview[0].Subscription
            Name         = $resourceName
            ResourceType = $ResourceType
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
                $item | Add-Member -MemberType NoteProperty -Name $($meterName + ' Cost') -Value $costItem.Cost
                $totalResourceCost += $costItem.Cost
            } else {
                $item | Add-Member -MemberType NoteProperty -Name $($meterName + ' Cost') -Value 0
            }
        }
        if ($totals) {
            # add datza for 'totals' column
            $item | Add-Member -MemberType NoteProperty -Name $('Total Cost') -Value $totalResourceCost
        }
        if ($consolidate) {
            AddToOverview $consolidatedData $item.Subscription $item.ResourceType $totalResourceCost
        }
        $results += $item
    } # foreach resource name

    Write-Progress -Id 2 -Activity 'collecting resource details' -Completed
    # write output for this resource type to the file
    foreach($item in $headers) {
        $(
            foreach($property in $item.PsObject.Properties) {
                $property.Value
            }
        ) -join $delimiter | Out-File -FilePath $outfilename -Encoding ansi -Force
    }
    foreach( $item in ($results | Sort-Object -Property Subscription, Name) ) {
        $(
            foreach($property in $item.PsObject.Properties) {
                $property.Value
            }
        ) -join $delimiter | Out-File -FilePath $outfilename -Encoding ansi -Append
    }
} # foreach resource type
Write-Progress -Id 2 -Activity 'collecting resource details' -Completed

if ($consolidate) {
    $outFileName = (($outFile.split('.')[0..($outFile.Count-1)])[0]).ToString() + '-consolidated.' + $outFile.Split('.')[-1]
    # output resource types as header line
    "subscription" + $delimiter + ($allResourceTypes -join $delimiter) | Out-File $outFileName -Force
    # now, write all resource totals, one line per subscription
    foreach ($subscription in $subscriptions) {
        $outLine = $subscription.Name
        foreach  ($resourceType in $allResourceTypes) {
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

Write-Progress -Id 1 -Activity 'collecting resources' -Completed
Write-Verbose "script finished"
