[CmdletBinding(DefaultParameterSetName = 'default')]

Param (
    [Parameter(ParameterSetName="default", Mandatory, Position=0)] [string[]] $subscriptionFilter,
    [Parameter(ParameterSetName="default")] [string] $billingPeriod = '',
    [Parameter(ParameterSetName="default")] [switch] $noUnits,
    [Parameter(ParameterSetName="default")] [switch] $noScale,
        [Parameter(ParameterSetName="help", Mandatory)] [Alias("h")] [switch] $help,
    [switch] $WhatIf
)

# necessary modules:
# Azure

#######################
# display usage help and exit
#
if ($help) {
    "NAME"
    "    Get-StorageAccountCost"
    ""
    "SYNTAX"
    ""
    "    -subscriptionFilter Single filter or comma-separated list of filters. All subscriptions whose name"
    "                        contain the filter expression will be analysed."
    "    -billingPeriod      Collect cost for given billing period, format is 'yyyyMMdd',"
    "                        default is the last month."
    "    -noUnits            Usually the first object returned is a list of units & scales, as the metrics"
    "                        come in 1s, 10000s, or so. This switch will omit the units object, so that only"
    "                        the actual metrics are output."
    "    -noScale            Return metrics unscaled (i.e. as units of 1)."
    ""
    exit
}

# ################# BEGIN MAIN #################
#
#

# always use wildcards for subscription filters
for ($i = 0; $i -lt $subscriptionFilter.Count; $i++) {
    if ($subscriptionFilter[$i] -ne '*') {
        $subscriptionFilter[$i] = '*' + $subscriptionFilter[$i] + '*'
    }
}

# user may have given more than one filter
# we collect all subscription names matching any of the filter expressions
$subscriptionNames = @{}
foreach ($filter in $subscriptionFilter) {
    foreach ($subscription in $(Get-AzSubscription | Where-Object {$_.Name -like "*$filter*" -and $_.State -eq 'Enabled'})) {
        $subscriptionNames[$subscription.Name] = 0
    }
}

if ($billingPeriod -eq '') {
    $billingPeriod = $((Get-Date (Get-Date).AddMonths(-1) -Format "yyyyMM") + '01')
}

# next command may fail if we haven't logged on to Azure first
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

$countS = 0 # used for progress bar

# initialize collector arrays
$allStorageAccountNames =@()
$StorageCostItems = @{}
$nonZeroCostItems = @{}
$units = @{}

foreach ($subscription in $subscriptions) {
    Select-AzSubscription $subscription | Out-Null
    $countS++ # count for 1st level progress bar
    Write-Progress -Id 1 -PercentComplete $($countS * 100 / $subscriptions.count) -Status "analyzing subscription $countS of $($subscriptions.count) ($($subscription.Name))" -Activity 'iterating through subscriptions'
    $StorageAccounts = @(Get-AzStorageAccount)
    if ($StorageAccounts.Count -ne 0) {
        $countSA = 0    # count for 2nd level progress bar
        foreach ($StorageAccount in $StorageAccounts) {
            $countSA++
            Write-Progress -Id 2 -ParentId 1 -PercentComplete $(100*$countSA / $StorageAccounts.Count) -Status "analyzing $($countSA) of $($StorageAccounts.Count) storage accounts" -Activity 'analyzing storage accounts'
            $allStorageAccountNames += $StorageAccount.StorageAccountName
            $ApiDelay = 10 # used in catch block
            do {
                try {
                    $ThisResourceConsumption = Get-AzConsumptionUsageDetail -BillingPeriod $billingPeriod -InstanceId $StorageAccount.Id -Expand MeterDetails -WarningAction Stop -ErrorAction Stop
                    $ApiDelay = 0   # we use the 0 value as flag that call was successful
                                    # comparing $ThisResourceConsumption wiht $null doesn't work, because even
                                    # a successful API call may return null
                }
                catch {
                    # API call failed. usually the reason is the error "too many API calls"...
                    Write-Warning "$($_.Exception.Message) while querying billing details for storage account '$($StorageAccount.StorageAccountName)' in subscription '$($subscription.Name)', Delaying next try for $ApiDelay seconds."
                    # ...so we will wait for a while...
                    start-sleep $ApiDelay
                    Write-Warning ""
                    # ... and increase the delay in case the call fails again
                    $ApiDelay = $ApiDelay * 1.5
                }
                # looping until call is successful or API delay becomes too large
            } until (($ApiDelay -eq 0) -or ($ApiDelay -gt 600))
            if ($ApiDelay -ne 0) {
                # we use 0 to indicate a successful call, otherwise the loop above was aborted because it took too long
                Write-Error "Get-AzConsumptionUsageDetail did not return a value for storage account $StorageAccount.StorageAccountName after repeated tries, aborting script."
                exit
            }
            #  Get-AzConsumptionUsageDetail returns per-day values, but we want the sum over the billing period (=month)
            $ThisResourceConsumption | Group-Object -Property Product | ForEach-Object {
                # cost for this product (=cost metric) aggregated
                $Cost = ($_.Group | Measure-Object -property PretaxCost -Sum).Sum
                # usage field, also aggregated
                $Usage =  ($ThisResourceConsumption | Where-Object -Property Product -EQ $_.Name | Measure-Object -Property UsageQuantity -Sum).Sum
                $unit = ($ThisResourceConsumption | Where-Object -Property Product -eq $_.Name).Meterdetails.Unit[0]
                $units[$_.Name] = $unit
                if ($Cost -ne 0) {
                    # we only want non-zero cost items
                    $StorageCostItems[$StorageAccount.StorageAccountName + 'Cost'] += @{$_.Name = $Cost}
                    $StorageCostItems[$StorageAccount.StorageAccountName + 'Usage'] += @{$_.Name = $Usage}
                    # after all resources have been analysed, we will report only the metrics where 
                    # at least one resource has a non-zero value, so add its name to a hash table
                    $nonZeroCostItems[$_.Name] = ''
                }
            } # foreach-object
        } # foreach storage account
        Write-Progress -Id 2 -ParentId 1 -Activity 'analyzing storage accounts' -Completed
    } # if there are any storage accounts
} # foreach subscription

# as the metrics have different scales (1s, 10000s, etc), we want to have the units as first object
# if you export to a CSV file, the units will form a second header line  
# return the units as first object
$item = [PSCustomObject] @{
    # dummy entry for the first member
    Name = 'units'
}

foreach ($CostItem in $nonZeroCostItems.Keys | Sort-Object) {
    $unit = $units[$costitem]
    if ($noScale) {
        # we don't want scaled metrics, so return usage in an unscaled manner, 
        # hence we need to adjust some scales here
        switch ($units[$costitem]) {    
            '1 GB'       { $unit = 'GB' }
            '1 GB/Month' { $unit = 'GB/mon' }
            '1/Hour'     { $unit = 'GB/h' }
            '10K'        { $unit = 'unit' }
            default      {}
        }
    }
    $item | Add-Member -MemberType NoteProperty -Name $($CostItem + ' Cost') -Value $((Get-Culture).NumberFormat.CurrencySymbol)
    $item | Add-Member -MemberType NoteProperty -Name $($CostItem + ' Usage') -Value $unit
}
if (-not $noUnits) {
    $item
} 

foreach ($StorageAccountName in $allStorageAccountNames) {
    # some properties of the storage account
    $item = [PSCustomObject] @{
        Name        = $StorageAccountName
    }
    foreach ($CostItem in $nonZeroCostItems.Keys | Sort-Object) {
        # collect all values of all metrics of all storage accounts
        # note that above we have filtered out metrics that are zero across ALL resources,
        # but some metrics may still be zero for some resources
        # in that case, these values are not present in $StorageCostItems
        if ( ($null -ne $($StorageCostItems[$StorageAccountName + 'Cost'])) -and
            ($null -ne $($StorageCostItems[$StorageAccountName + 'Cost'][$CostItem])) ) {
            $cost = $StorageCostItems[$StorageAccountName + 'Cost'][$CostItem]
            $usage = $StorageCostItems[$StorageAccountName + 'Usage'][$CostItem]
            if ($noScale) {
                # we don't want scaled metrics, so return usage in an unscaled manner
                switch ($units[$costitem]) {    
                    '1 GB'       {}
                    '1 GB/Month' {}
                    '1/Hour'     {}
                    '10K'        { $usage *= 10000 }
                    default      {}
                }
            }
        } else {
            $cost = 0
            $usage = 0
        }
        # record the metric unit, it is used to compose the names of the
        # members of the PSCustomObjects that will be returned to the caller
        # add these metrics & values to the $item object
        $item | Add-Member -MemberType NoteProperty -Name $($CostItem + ' Cost') -Value ([math]::Round($Cost,2))
        $item | Add-Member -MemberType NoteProperty -Name $($CostItem + ' Usage') -Value $usage
    } # foreach cost item
    $item # output item
} #foreach storage account
