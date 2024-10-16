<#
.SYNOPSIS
	collects cost and usage information for Azure resources, optionally exports them into one or more CSV files

.DESCRIPTION
	Collects cost data and optionally usage data for the resources in the subscriptions matching the filter and resource type.
	If an output file name is given, a separate CSV file is created for each resource type, because the 
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
	Collect cost for given billing period, format is "yyyyMMdd", default is the last month.

.PARAMETER noUnits
	Usually the first object returned is a list of units & scales, as the metrics come in 1s, 10000s,or so.
    This switch will omit the units object, so that only the actual metrics are output.

.PARAMETER showUsage
	Display usage information for each cost item additionally to the cost.

.PARAMETER showZeroCostItems
	Display cost items that are zero. Normally, these items are omitted from the output.

.PARAMETER outFile
	Write output to a set of CSV files. Without this switch, results are written to standard output as objects.
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
Get-ResourceCostDetails.ps1 -subscriptionFilter * -resourceTypes virtualMachines,storageAccounts -billingPeriod 20240501 -outFile result.csv
	Analyze virtual machines and storage accounts in the all accessible subscriptions and write result to a set of CSV files.
    For the two resource types, two separate files will be created named "result-virtualMachines.csv" and "result-storageAccounts.csv"
#>

[CmdletBinding(DefaultParameterSetName = 'default')]
Param (
    [Parameter(HelpMessage="one or more partial subsciption names", Mandatory, Position=0)]
    [SupportsWildcards()]
    [string[]] $subscriptionFilter,

    [Parameter(HelpMessage="resource types to include, last part of hierarchical name is sufficient (e.g. 'virtualmachines')")]
    [SupportsWildcards()]
    [string[]] $resourceTypes = @('*'),

    [Parameter(HelpMessage="resource types to exclude, last part of hierarchical name is sufficient (e.g. 'storageaccounts')")]
    [SupportsWildcards()]
    [string[]] $excludeTypes = @(), 

    [Parameter(HelpMessage="billing period in the format DDMMYYYY")]
    [string] $billingPeriod = '',

    [switch] $showUsage,
    
    [switch] $showZeroCostItems,

    [switch] $noUnits,

    [Parameter(ParameterSetName="default", HelpMessage="first part of filename for output CSV file (resource type will be added to filename(s))")]
    [Parameter(ParameterSetName="outputToFile", HelpMessage="first part of filename for output CSV file (resource type will be added to filename(s))", Mandatory)]
    [string] $outFile,

    [Parameter(ParameterSetName="outputToFile", HelpMessage="character to be used as delimiter")]
    [string] [ValidateLength(1,1)] $delimiter,

    [switch] $WhatIf,

    [switch] $help
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
        if ( ($inclusion -ne '*') -and ($value -like "*$inclusion") ) {
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

# write the values of an PSObject's members to a file akin to an export to a CSV file
# the -force switch creates or overwrites a file, if it is missing, output will be appended
# to an existing file
function Write-ObjectToFile ([PSObject] $object, [string]$filePath, [string]$delimiter, [switch]$force) {
    $lineToWrite = $(
        foreach($object_properties in $object.PsObject.Properties) {
            $object_properties.Value
        }
    ) -join $delimiter 
    if ($force) {
        $lineToWrite | Out-File -FilePath $filePath -Encoding ansi -Force
    } else {
        $lineToWrite | Out-File -FilePath $filePath -Encoding ansi -Append
    }
}

# ################# BEGIN MAIN #################
#
#

# preload a variable with the resource types which will be excluded by default
$defaultexcludeTypes = @(
    'activityLogAlerts',
    'applicationSecurityGroups',
    'automations',
    'automationAccounts',
    'components',
    'connections',
    'dataCollectionRules',
    'disks',
    'virtualMachines/extensions',
    'maintenanceConfigurations',
    'namespaces',
    'networkWatchers',
    'networkInterfaces',
    'networkSecurityGroups',
    'userAssignedIdentities',
    'templateSpecs',
    'restorePointCollections',
    'routeTables',
    'smartDetectorAlertRules',
    'snapshots',
    'solutions',
    'storageSyncServices',
    'userAssignedIdentities',
    'virtualNetworkLinks',
    'virtualNetworks',
    'workflows'
)

#########################################
# before beginning the processing, do some parameter magic first
# 

# if user hasn't given a billing period, we assume the previous month
if ($billingPeriod -eq '') {
    $billingPeriod = $((Get-Date (Get-Date).AddMonths(-1) -Format "yyyyMM") + '01')
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

# determine the subscription(s) which match the subscription filter
#this command will fail if we haven't logged on to Azure first
try {
    $subscriptions = $(Get-AzSubscription -ErrorAction SilentlyContinue -WarningAction SilentlyContinue | Where-Object {$_.Name -in $($subscriptionNames.Keys)}) | Sort-Object -Property Name
}
catch {
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
    "types excluded by default: $defaultexcludeTypes"
   exit
}

#####################################
# OK, finally the main processing will begin
#

$countS = 0 # used for progress bar

# set default for CSV field separator if needed
if (('' -ne $outFile) -and ($delimiter -eq '')) {
    $delimiter = (Get-Culture).textinfo.ListSeparator
}

# define an array and a hash table which we need later
$ResourceCostItems = @{}    # a two-dimensional hash table, i.e. a string-indexed hash table with values that are
                            # string-indexed hash tables with numeric values. Imagine
                            # <table>[<resourcename>Usage][<costitem>] = <usage> and
                            # <table>[<resourcename>Cost][<costitem>]  = <cost>
                            # for each resources and each Cost Item. 
                            # A Cost Item is any metric of a resource which may generate cost.
                            # As example, for resource 'mystore' and Cost Item 'read actions', entries could be
                            # $ResourceCostItems['mystoreUsage']['read actions'] = 120000
                            # $ResourceCostItems['mystoreCost']['read actions'] = 0.123
$nonZeroResources = @()     # all resources that have generated nonzero cost. In the sequel, we ignore resources
                            # which don't generate any cost
foreach ($subscription in $subscriptions) {
    # initialize collector array
    $Resources = @()            # all resources in current subscription
    $units = @{}

    Select-AzSubscription $subscription | Out-Null
    $countS++ # count for 1st level progress bar
    Write-Progress -Id 1 -PercentComplete $($countS * 100 / $subscriptions.count) -Status "$countS of $($subscriptions.count) ($($subscription.Name))" -Activity 'analysing subscriptions'
    # get all resources matching the filters
    foreach ($resource in Get-AzResource) {
        if ( MatchFilter $resource.ResourceType $resourceTypes ($excludeTypes + $defaultexcludeTypes)) {
            $Resources += $resource
        }
    }
    # get consumption data for all these resources
    if ($Resources.Count -ne 0) {
        $countRes = 0    # count for 2nd level progress bar
        foreach ($Resource in $Resources | Sort-Object -Property ResourceType) {
            $countRes++
            Write-Progress -Id 2 -ParentId 1 -PercentComplete $(100*$countRes / $Resources.Count) -Status "$(($Resource.resourceType).Split('/')[-1]) ($($resource.Name), $($countRes) of $($Resources.Count) resources)" -Activity 'analysing resources'
            $ApiDelay = 10 # used in catch block
            do {
                try {
                    $ThisResourceConsumption = Get-AzConsumptionUsageDetail -BillingPeriod $billingPeriod -InstanceId $resource.Id -Expand MeterDetails -WarningAction Stop -ErrorAction Stop
                    $ApiDelay = 0   # we use the 0 value as flag that call was successful
                                    # comparing $ThisResourceConsumption with $null doesn't work, because even
                                    # a successful API call may return null
                }
                catch {
                    # API call failed. usually the reason is the error "too many API calls"...
                    Write-Warning "$($_.Exception.Message) while querying billing details for resource '$($resource.Name)' in subscription '$($subscription.Name)', Delaying next try for $ApiDelay seconds."
                    # ...so we will wait for a while...
                    start-sleep $ApiDelay
                    # ... and increase the delay in case the call fails again
                    $ApiDelay = $ApiDelay * 1.5
                }
                # looping until call is successful or API delay becomes too large
            } until (($ApiDelay -eq 0) -or ($ApiDelay -gt 600))
            if ($ApiDelay -ne 0) {
                # we use 0 to indicate a successful call, otherwise the loop above was aborted because it took too long
                Write-Error "Get-AzConsumptionUsageDetail did not return a value for resource $resource.Name after repeated tries, aborting script."
                exit
            }
            # let's first check whether this resource generated any cost at all. If not, we will skip it
            if (($null -ne $ThisResourceConsumption -and ($ThisResourceConsumption | Measure-Object -Property PretaxCost -Sum).Sum -ne 0) ) {
                    #  Get-AzConsumptionUsageDetail returns per-day values, but we want the sum over the billing period (=month)
                $Resource | Add-Member -MemberType NoteProperty -Name 'SubscriptionName' -Value $subscription.Name
                $nonZeroResources += $Resource
                $ThisResourceConsumption | Group-Object -Property Product | ForEach-Object {
                    # each $_ refers to a cost metric of the current resource under review
                    # cost for this product (=cost metric) aggregated
                    $Cost = ($_.Group | Measure-Object -property PretaxCost -Sum).Sum
                    # usage field, also aggregated
                    if ($showUsage) {
                        $Usage = ($ThisResourceConsumption | Where-Object -Property Product -EQ $_.Name | Measure-Object -Property UsageQuantity -Sum).Sum
                        $unit  = ($ThisResourceConsumption | Where-Object -Property Product -EQ $_.Name).Meterdetails.Unit[0]
                        $units[$_.Name] = $unit
                    }
                    if ( ($Cost -ne 0) -or $showZeroCostItems ) {
                        # we only want non-zero cost items
                        $ResourceCostItems[$resource.Name + 'Cost'] += @{$_.Name = $Cost}
                        if ($showUsage) {
                            $ResourceCostItems[$resource.Name + 'Usage'] += @{$_.Name = $Usage}
                        }
                    }
                } # foreach-object
            } # foreach resource
        } # if there are any cost
        Write-Progress -Id 2 -ParentId 1 -Activity 'analysing resources' -Completed
    } # if there are any resources
} # foreach subscription
Write-Progress -Id 1 -Activity 'analysing subscriptions' -Completed

# now convert all entries into [PSCustomObject] objects which are then output, ordered by resource type
$countRes = 0 # for progress bar
foreach ($resourceType in ($nonZeroResources | Group-Object -Property ResourceType).Name) {
    # we want to see only metrics that generated any cost at all
    # and we will also prepare a header line in case user wants to have that
    
    if ('' -ne $outFile) {
        # user wants output to a file. For each resource type, we will generate a separate file
        # because each resource type has different cost titems
        $outFileName = (($outFile.split('.')[0..($outFile.Count-1)])[0]).ToString() + '-' + $resourceType.Split('/')[-1] + '.' + $outFile.Split('.')[-1]
    }

    # at first, find out which cost items did generate any cost at all
    $nonZeroCostItems = @{}
    foreach ($resource in ($nonZeroResources | Where-Object -Property ResourceType -EQ $resourceType)) {
        if ($null -ne $($ResourceCostItems[$resource.Name+'Cost'])) {
            foreach ($costItem in ($ResourceCostItems[$resource.Name+'Cost']).Keys | Sort-Object) {
                # after all resources have been analysed, we will report only the metrics where 
                # at least one resource has a non-zero value, so add its name to a hash table
                if ($null -ne $($ResourceCostItems[$resource.Name+'Cost'][$CostItem])) {
                    $nonZeroCostItems[$CostItem] = ''
                }
            }
        }
    }
    if ('' -ne $outFile) {
        # if we want to output to a file, write a header
        $item = [PSCustomObject] @{
            # dummy entries for the first two members
            column1 = 'Subscription'
            column2 = 'Name'
            column3 = 'Resource Type'
        }
        $count = 4
        if ($showUsage) {
            foreach ($metricName in $nonZeroCostItems.Keys | Sort-Object) {
                $item | Add-Member -MemberType NoteProperty -Name "column$($count)" -Value ($metricName + " Usage")
                $count++
            }
        }
        foreach ($metricName in $nonZeroCostItems.Keys | Sort-Object) {
            $item | Add-Member -MemberType NoteProperty -Name "column$($count)" -Value ($metricName + " Cost")
            $count++
        }
        Write-ObjectToFile $item $outFileName $delimiter -force
    }
    # as the metrics have different scales (1s, 10000s, etc), we want to have the units as first object
    # if you export to a CSV file, the units will form a second header line  
    # return the units as first object "$item"
    $item = [PSCustomObject] @{
        # dummy entries for the first members (=fields of the header line)
        Subscription = ''
        Name         = ''
        ResourceType = 'units'
    }
    # prepare the $item (i.e. the headline for output):
    if ($showUsage) {
        foreach ($CostItem in $nonZeroCostItems.Keys | Sort-Object) {
            $unit = $units[$costitem]
            $item | Add-Member -MemberType NoteProperty -Name $($CostItem + ' Usage') -Value $unit
        }
    }
    foreach ($CostItem in $nonZeroCostItems.Keys | Sort-Object) {
        $item | Add-Member -MemberType NoteProperty -Name $($CostItem + ' Cost') -Value $((Get-Culture).NumberFormat.CurrencySymbol)
    }

    # here we output the headline stating the metrics units unless the -noUnits switch is given
    if (-not $noUnits) {
        if ('' -eq $outFile) {
            $item
        } else {
            Write-ObjectToFile $item $outFileName $delimiter
        }
    }
    # now let's output the actual data
    foreach ($resource in ($nonZeroResources | Where-Object -Property ResourceType -EQ $resourceType)) {
        $countRes++
        Write-Progress -Id 1 -PercentComplete $($countRes * 100 / $nonZeroResources.count) -Status "$countRes of $($nonZeroResources.count)" -Activity 'exporting data'
        # some properties of the resource
        $item = [PSCustomObject] @{
            Subscription = $resource.SubscriptionName
            Name         = $resource.Name
            ResourceType = $resource.ResourceType
        }
        if ($showUsage) {        
            foreach ($CostItem in $nonZeroCostItems.Keys | Sort-Object) {
                # collect all usage values of all resources
                # note that above we have filtered out metrics that are zero across ALL resources,
                # but some metrics may still be zero for some resources
                # in that case, these values are not present in $ResourceCostItems
                if ( ($null -ne $($ResourceCostItems[$resource.Name + 'Cost'])) -and
                    ($null -ne $($ResourceCostItems[$resource.Name + 'Cost'][$CostItem])) ) {
                    $usage = $ResourceCostItems[$resource.Name + 'Usage'][$CostItem]
                } else {
                    $usage = 0
                }
                # record the metric unit, it is used to compose the names of the
                # members of the PSCustomObjects that will be returned to the caller
                # add these metrics & values to the $item object
                $item | Add-Member -MemberType NoteProperty -Name $($CostItem + ' Usage') -Value $usage
            } # foreach cost item
        }
        foreach ($CostItem in $nonZeroCostItems.Keys | Sort-Object) {
            if ( ($null -ne $($ResourceCostItems[$resource.Name + 'Cost'])) -and
                ($null -ne $($ResourceCostItems[$resource.Name + 'Cost'][$CostItem])) ) {
                $cost = $ResourceCostItems[$resource.Name + 'Cost'][$CostItem]
            } else {
                $cost = 0
            }
            # record the metric unit, it is used to compose the names of the
            # members of the PSCustomObjects that will be returned to the caller
            # add these metrics & values to the $item object
            $item | Add-Member -MemberType NoteProperty -Name $($CostItem + ' Cost') -Value $Cost
        } # foreach cost item
        if ('' -eq $outFile) {
            $item
        } else {
            Write-ObjectToFile $item $outFileName $delimiter
        }
    } # foreach resource
} # foreach resource type

Write-Progress -Id 1 -Activity 'exporting data' -Completed
