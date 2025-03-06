<#
.SYNOPSIS
Returns information and usage/load metrics for resources of one or more types in selected subscription(s)

.DESCRIPTION
Returns information and usage/load metrics for resources of one or more of these resource types:
VMs, SQL servers, SQL Databases, Storage Accounts, Snapshots
May also return the count and cumulated cost of all resources in given subscription(s), see -ResourceList switch

NOTE:
The script can easily be adjusted to add or remove metrics that shall be reported.
you may adjust this script e.g. to add or remove metrics.
These parts of the code are marked with # >>>>> and # <<<<<. Refer to the comments inside the code for further information.

.PARAMETER subscriptionFilter
Mandatory. Single filter or comma-separated list of filters. All subscriptions whose names contain the filter expression will be analysed.
You can use the -WhatIf switch to find out which subscriptions would be analyzed.

.PARAMETER VM
show virtual machines' properties

.PARAMETER SqlServer
show SQL server VM properties

.PARAMETER DbAas
show Azure SQL databases' (databases as-a-service) properties

.PARAMETER Storage
show storage accounts' properties

.PARAMETER Snapshot
show snapshots' properties

.PARAMETER all
all of the above switches

.PARAMETER lastHours
collect metrics within the given time period, default is 24 hours

.PARAMETER ResourceList
show count of resource types in subscription(s) and cumulative cost

.PARAMETER details
to be used with -ResourceList. Show details for each resource rather than count and cumulative cost

.PARAMETER billingPeriod
collect resource cost for given billing period, default is the last month. The format for the billing period is 'yyyymm'

.PARAMETER outFile
if given, exports result into a CSV file
                            NOTE: separate files will be created for different resource types.
                            Two characters will be added to the file names to make them different.
.PARAMETER separator
separator for items in CSV file, default is semicolon

.PARAMETER WhatIf
Just display the names of the subscriptions which would be analysed

#>

[CmdletBinding(DefaultParameterSetName = 'default')]

Param (
    [Parameter(ParameterSetName="default", Mandatory, Position=0)]
    [Parameter(ParameterSetName="WhatIf", Mandatory, Position=0)]
    [Parameter(ParameterSetName="defaultAll", Mandatory, Position=0)] [string[]] $subscriptionFilter,
    [Parameter(ParameterSetName="default")] [switch] $VM,
    [Parameter(ParameterSetName="default")] [switch] $SqlServer,
    [Parameter(ParameterSetName="default")] [switch] $DbAas,
    [Parameter(ParameterSetName="default")] [switch] $Storage,
    [Parameter(ParameterSetName="default")] [switch] $Snapshot,
    [Parameter(ParameterSetName="default")]
    [Parameter(ParameterSetName="defaultAll")] [switch] $all,
    [Parameter(ParameterSetName="default")]
    [Parameter(ParameterSetName="defaultAll")] [switch] $ResourceList,
    [Parameter(ParameterSetName="default")]
    [Parameter(ParameterSetName="defaultAll")] [switch] $details,
    [Parameter(ParameterSetName="default")]
    [Parameter(ParameterSetName="defaultAll")] [string] $billingPeriod = '',
    [Parameter(ParameterSetName="default")]
    [Parameter(ParameterSetName="defaultAll")] [Int32] $lastHours = 24,
    [Parameter(ParameterSetName="default")]
    [Parameter(ParameterSetName="defaultAll")] [string] $outFile,
    [Parameter(ParameterSetName="default")]
    [Parameter(ParameterSetName="defaultAll")] [string] $separator = ';',
    [switch] $WhatIf
)

# necessary modules:
# Azure
# SQLServer


########
# some values which we use as scales.
class scale {
    static [Int64] $unit = 1
    static [Int64] $kilo = 1024
    static [Int64] $mega = 1048576
    static [Int64] $giga = 1073741824
}

################################
# some function definitions first.
# for main program, see further down

#######
# extract some data from an array of VM metrics and add them to a PSObject
# The metric reults will be added as new properties to an existing object 
# of type PSCustomObject.
# For each metric, the maximum and average values of the last <lasthours> hours will be added.
#
# parameters:
#    $psObject      Object of type PSCustomObject. The metric results will be added
#                   as additional properties to that object
#    $resourceId    ID of the resource of which the metrics will be collected
#    $metric        The metric to be collected. If the metric collection fails,
#                   a warning will be issued and the metric values will be 'n/a'
#    $propertyName  The base name of the property to be added.
#                   As for each metric, max and average values will be added, *two* properties
#                   will be added having the names Max<propertyName> and Avg<propertyName>
#    $scale         Optional. Scale factor for metric, reported value will be divided by <scale>,
#                   which e.g. makes sense for memory reported in bytes to be output as GB.
#                   Default is 1
#    $maxThreshold  Optional. If given, reports the percentage of data points where the metric
#                   value is larger than <maxThreshold> % of the absolute <lasthours> maximum
#    $totals        report the Totals value. Some metrics don't come with meaningful max or avg values,
#                   but totals should be used.
#    $timeGrain     Optional. Granularity for taking the metric. Default is 00:01:00 (1 minute).
#                   Some metrics may support different time grains.
#
function AddMetrics ([ref] $psObject, [string]$resourceId, [string] $metric, [string]$propertyName, [Int64]$scale = 1, [Int64]$maxThreshold = 0, [bool]$totals = $false, [string]$timeGrain = '00:01:00') {
    # use data points within given period
    $endTime=Get-Date
    $startTime=$endTime.AddHours(-$lastHours)
    try {
        $data = $(Get-AzMetric -ResourceId $resourceId -StartTime $startTime -EndTime $endTime -TimeGrain $timeGrain -WarningAction SilentlyContinue -ErrorAction Stop -AggregationType Maximum -MetricName $metric).Data 2>$null
        if ($null -eq $data -or $data.Count -eq 0) {
            # metric calls may fail because metric doesn't exist for this resource, insufficent credentials, and other reasons
            throw "metric exists but returned no data"
        }
        # data will contain the max values with one-minute granularity.
        # we also want to know the absolute maximum within the given time period
        $max = $($data | Measure-Object -Property Maximum -Maximum).Maximum
        # add the value as new property to the object
        $psObject.Value | Add-Member -MemberType NoteProperty -Name "Max$propertyName" -Value $([math]::Truncate($max / $scale))
        if ($maxThreshold -ne 0) {
            # determine percentage of events (=minutes) where the max load 
            # was larger than <maxThreshold> within given time period
            $overThreshold = [math]::Truncate(100 * $($data | Where-Object -Property Maximum -GE ($maxThreshold * $max / 100) | Select-Object -Property Maximum).Count / $data.Count)
            $psObject.Value | Add-Member -MemberType NoteProperty -Name "MaxPct$propertyName" -Value $overThreshold
        }
        # average
        $data = $(Get-AzMetric -ResourceId $resourceId -StartTime $startTime -EndTime $endTime -TimeGrain $timeGrain -WarningAction SilentlyContinue -ErrorAction Stop -AggregationType Average -MetricName $metric).Data 2>$null
        $avg = $($data | Measure-Object -Property Average -Average).Average
        $psObject.Value | Add-Member -MemberType NoteProperty -Name "Avg$propertyName" -Value $([math]::Truncate($avg / $scale))
        if ($totals) {
            $data = $(Get-AzMetric -ResourceId $resourceId -StartTime $startTime -EndTime $endTime -TimeGrain $timeGrain -WarningAction SilentlyContinue -ErrorAction Stop -AggregationType Total -MetricName $metric).Data 2>$null
            $total = $($data | Measure-Object -Property Total -Sum).Sum
            $psObject.Value | Add-Member -MemberType NoteProperty -Name "Total$propertyName" -Value $([math]::Truncate($total / $scale))
        }
    }
    catch {
        Write-Warning $("collecting the metrics ""$metric"" for resource ""$($(Get-AzResource -ResourceId $resourceId).Name)""" + `
                        " generated an error. Possibly the metric doesn't exist for this type of resource, check name and spelling.`n" + `
                        "The error was ""$($_.Exception.InnerException.Body.Message)""." )
            # add dummy values. some queries may fail only for some resources, in that case, still all objects should have the same properties
        $psObject.Value | Add-Member -MemberType NoteProperty -Name "Max$propertyName" -Value 'n/a' -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
        if ($maxThreshold -ne 0) {
            $psObject.Value | Add-Member -MemberType NoteProperty -Name "MaxPct$propertyName" -Value 'n/a' -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
        }
        $psObject.Value | Add-Member -MemberType NoteProperty -Name "Avg$propertyName" -Value 'n/a' -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
        if ($totals) {
            $psObject.Value | Add-Member -MemberType NoteProperty -Name "Total$propertyName" -Value 'n/a' -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
        }
    }
}

#############
# display progress information while collecting metrics
function DisplayMetricProgress ([Int64] $item, [Int64] $total) {
    if ($item -gt 0) {
        Write-Progress -Id 3 -ParentId 2 -PercentComplete $(100*$item/$total) -Status "analyzing metric $item of $total" -Activity 'analyzing metrics'
    } else {
        Write-Progress -Id 3 -ParentId 2 -Activity 'analyzing metrics' -Completed
    }
}

# ################# BEGIN MAIN #################
#
#


# do some magic with the switch parameters
#

# the -all switch includes all details except ResourceList
if ($all) {,
    $VM = $true
    $SqlServer = $true
    $DbAas = $true
    $Storage = $true
    $Snapshot = $true
}

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
    $billingPeriod = (Get-Date (Get-Date).AddMonths(-1) -Format "yyyyMM")
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

# check -WhatIf switch. This would only display the names of the subscriptions
# which would be analysed
if ($whatIf) {
    $endTime=Get-Date
    $startTime=$endTime.AddHours(-$lastHours)
    $subscriptions | Select-Object -Property Name
    "collect metrics between $($startTime.ToString((Get-Culture).DateTimeFormat.FullDateTimePattern)) and $($endTime.ToString((Get-Culture).DateTimeFormat.FullDateTimePattern))"
    if ($ResourceList) {
        "Resource cost collected for billing period $billingPeriod"
    }
    exit
}

$countS = 0 # used for progress bar

# initialize collector arrays
$VM_Result       = @()
$SQL_Result      = @()
$DBaaS_Result    = @()
$Storage_Result  = @()
$Resource_Result = @()

# We iterate through all subscriptions:
# In the inner loop(s), we iterate through a specific resource type, and possible some dependent resources (e.g. VMs and then their disks).
# In the inner loops, note the lines reading:  $xyz_Result += $( ... )
# The data for each individual resource (sizes, metrics, etc.) are collected into objects of type [PSCustomObject].
# The output of the script shall be a list of these objects, so that the script output can be piped into some further process.
# As these objects will have properties which depend on the object type, we collect the objects of a certain type first.
# The objects will be generated inside the $(...) block and then stored in the $xyz_result variable, which will be an array of objects. 
#
foreach ($subscription in $subscriptions) {
    Select-AzSubscription $subscription | Out-Null
    $countS++ # count for 1st level progress bar
    Write-Progress -Id 1 -PercentComplete $($countS * 100 / $subscriptions.count) -Status "analyzing subscription $countS of $($subscriptions.count) ($($subscription.Name))" -Activity 'iterating through subscriptions'
    if ($VM) {
        $VM_Result += $( 
            $VMResources = @(Get-AzVM | Sort-Object -Property Name)
            $countVM = 0 # count for 2nd level progress bar
            foreach ($VMResource in $VMResources) {
                $countVM++
                Write-Progress -Id 2 -ParentId 1 -PercentComplete $($countVM * 100 / $VMResources.count) -Status "analyzing VM $countVM of $($VMResources.count) ($($VMResource.Name))" -Activity 'analyzing VMs'
                # make SKU names a little shorter, so delete the 'Standard_' part from the SKU
                $VmSku = ($VMResource | Select-Object -ExpandProperty HardwareProfile).VmSize -replace 'Standard_'
                # we also want CPU count and RAM size
                $VmSize = Get-AzVMSize -VMName $VMResource.Name -ResourceGroupName $VMResource.ResourceGroupName | Where-Object -p Name -EQ $VMResource.HardwareProfile.VmSize
                # collect info about data disks
                $vmDisks = $VMResource.StorageProfile.DataDisks | Measure-Object -Property DiskSizeGB -Sum
                # create a PSCustomObject
                # if we need to report more details (see 'AddMetrics' statements below), then the object will be extended as necessary
                $item = [PSCustomObject] @{
                        Subscription   = $($subscription.Name)
                        Name           = $($VMResource.Name)
                        Sku            = $VmSku
                        CPUs           = $($VmSize.NumberOfCores)
                        MemGB          = [Math]::Truncate($($VmSize.MemoryInMB) / 1024)
                        OsType         = $($VMResource.StorageProfile.OsDisk.OsType)
                        OsVersion      = $($VMResource.StorageProfile.ImageReference.Offer)
                        OsExactVersion = $($VMResource.StorageProfile.ImageReference.ExactVersion)
                        OsDiskSize     = $(Get-AzDisk -DiskName $VMResource.StorageProfile.OsDisk.Name).DiskSizeGB
                        MaxDisks       = $($VmSize.MaxDataDiskCount)
                        DataDisks      = $($VmDisks).Count
                        DataDisksSize  = $($VmDisks).Sum
                    }

                # get VM Performance metrics
# >>>>> THIS SECTION CAN EASILY CHANGED IN CASE YOU NEED DIFFERENT METRICS 
# >>>>> Collecting metrics takes some time, so you may use the DisplayMetricProgress function
# >>>>> This is however fully optional, you can also delete all calls to DisplayMetricProgress
                DisplayMetricProgress 1 5

# >>>>> To add a metric to a resource, call the AddMetrics function.
# >>>>> See there  for a detailed description of the parameters.
# >>>>> The next line collects the 'Percentage CPU' metric and adds the MaxCPU and AvgCPU properties to the $item object
# >>>>> the scale factor is one, and the '80' indicates that we also want a property (named MaxPctCPU) that shows how many
# >>>>> minutes of the day the CPU load was higher than 80% of the day's maximal load
                AddMetrics ([ref]$item) $VMResource.Id 'Percentage CPU' 'CPU' ([scale]::unit) 80

# >>>>> Here, we collect the 'Available Memory Bytes' and add the MaxMemMB and AvgMemMB properties, scaled as MiBytes,
                DisplayMetricProgress 2 5
                AddMetrics ([ref]$item) $VMResource.Id 'Available Memory Bytes' 'MemMB' ([scale]::mega)

                DisplayMetricProgress 3 5
                AddMetrics ([ref]$item) $VMResource.Id 'Data Disk Queue Depth' 'DiskQ' ([scale]::unit)
                DisplayMetricProgress 4 5
                AddMetrics ([ref]$item) $VMResource.Id 'Network In Total' 'NwInMB' ([scale]::mega)
                DisplayMetricProgress 5 5
                AddMetrics ([ref]$item) $VMResource.Id 'Network Out Total' 'NwOutMB' ([scale]::mega)
# <<<<<
                # now return the created object with its properties
                # as we are inside a $( statements... ) block, the returned object will be caught by the
                # $result += $(...) statement and be added to the $result array
                $item

                DisplayMetricProgress 0 5
            } # foreach VMResource
        )
    } # if VMs

    if ($SqlServer) {
        $SqlServerVMs = @(Get-AzSqlVM) # if there is only one, then Get-AzSqlVM returns one server, but we always want an array
        if ($SqlServerVMs.Count -ne 0) {
            Write-Progress -Id 2 -ParentId 1 -PercentComplete 50 -Status "analyzing $($SqlServerVMs.Count) SQL Server VMs" -Activity 'analyzing SQL Server VMs'
            $SQL_Result += $(
                foreach ($SqlServerVM in $SqlServerVMs) {
                    $item = [PSCustomObject] @{
                            Subscription      = $($subscription.Name)
                            SqlVMName         = $SqlServerVM.Name
                            LicenseType       = $SqlServerVM.LicenseType
                            Sku               = $SqlServerVM.Sku
                            SqlManagementType = $SqlServerVM.SqlManagementType
                    }
                    $item
                } # foreach SQL server VM
            )
        } # if there are any VMs
    } # if SQL server

    if ($DbAas) {
        $DBaaS_Result += $(
            $AzSqlServers = @(Get-AzSqlServer)
            foreach ($AzSqlServer in $AzSqlServers) {
                Write-Progress -Id 2 -ParentId 1 -PercentComplete 50 -Status "analyzing $($AzSqlServers.Count) Azure SQL Servers" -Activity 'Azure aaS-Databases'
                $SqlDatabases = @(Get-AzSqlDatabase -ServerName $AzSqlServer.ServerName -ResourceGroupName $AzSqlServer.ResourceGroupName)
                foreach ($SqlDatabase in $SqlDatabases) {
                    $item = [PSCustomObject] @{
                            Subscription  = $($subscription.Name)
                            SqlServerName = $SqlDatabase.ServerName
                            DatabaseName  = $SqlDatabase.DatabaseName
                            SkuName       = $SqlDatabase.SkuName
                            Collation     = $SqlDatabase.CollationName
                            MaxSizeGB     = $SqlDatabase.MaxSizeBytes / 1048576
                            Status        = $SqlDatabase.Status
                            Capacity      = $SqlDatabase.Capacity
                    }
                    DisplayMetricProgress 1 5
                    AddMetrics ([ref]$item) $SqlDatabase.ResourceId 'cpu_percent' 'CPUpct' ([scale]::unit)
                    DisplayMetricProgress 2 5
                    AddMetrics ([ref]$item) $SqlDatabase.ResourceId 'dtu_consumption_percent' 'DTUpct' ([scale]::unit)
                    DisplayMetricProgress 3 5
                    AddMetrics ([ref]$item) $SqlDatabase.ResourceId 'dtu_used' 'usedDTU' ([scale]::unit)
                    DisplayMetricProgress 4 5
                    AddMetrics ([ref]$item) $SqlDatabase.ResourceId 'storage' 'usedStorGB' ([scale]::giga)
                    DisplayMetricProgress 5 5
                    AddMetrics ([ref]$item) $SqlDatabase.ResourceId 'storage_percent' 'Storpct' ([scale]::unit)
                    $item
                } # foreach database
            } # foreach Azure SQL server
        )
    } # if DB aaS

    if ($Storage) {
        $StorageAccounts = @(Get-AzStorageAccount)
        if ($StorageAccounts.Count -ne 0) {
            $countSA = 0
            $Storage_Result += $(
                foreach ($StorageAccount in $StorageAccounts) {
                    $countSA++
                    Write-Progress -Id 2 -ParentId 1 -PercentComplete $(100*$countSA / $StorageAccounts.Count) -Status "analyzing $($countSA) of $($StorageAccounts.Count) Storage Accounts" -Activity 'analyzing Storage Accounts'
                    $item = [PSCustomObject] @{
                            Subscription = $($subscription.Name)
                            Name        = $StorageAccount.StorageAccountName
                            Sku         = $StorageAccount.Sku.Name
                            Tier        = $StorageAccount.AccessTier
                            Kind        = $StorageAccount.Kind
                            Public      = $StorageAccount.AllowBlobPublicAccess
                        }
                    $item
                } # foreach storage account
            )
        } # if there are any storage accounts
    } # if Storage

    if ($Snapshot) {
        $Snapshots = @(Get-AzSnapshot)
        if ($Snapshots.Count -ne 0) {
            Write-Progress -Id 2 -ParentId 1 -PercentComplete 50 -Status "analyzing $($Snapshots.Count) Snapshots" -Activity 'analyzing Snapshots'
            $Snapshot_Result += $(
                foreach ($Snap in $Snapshots) {
                    $countSS++
                    $item = [PSCustomObject] @{
                        Type        = "Snapshot"
                        Subscription= $($subscription.Name)
                        Name        = $Snap.Name
                        Created     = $Snap.TimeCreated
                        OsType      = $Snap.Ostype
                        DiskSizeGB  = $Snap.DiskSizeGB
                        Incremental = $Snap.Incremental
                    }
                    $item
                } # foreach snapshot
            )
            Write-Progress -Id 2 -ParentId 1 -Activity 'analyzing Snapshots' -Completed
        } # if there are any snapshots
    } # if Snapshot

    if ($ResourceList) {
        $Resources = @(Get-AzResource)
        if ($Resources.Count -ne 0) {
            $countRes = 0
            if (-not $details) {
                $resourceCount = @{}
                $totalResourceCost = @{}
            }
            try {
                $allResourceCost = Get-AzConsumptionUsageDetail -BillingPeriodName $billingPeriod -ErrorAction Stop -WarningAction Stop
            }
            catch {
                Write-Warning ("Resource cost for subscription ""$($subscription.Name)"" and billing period ""$billingPeriod"" resulted in an error.`n" + `
                              "The error was ""$($_.Exception.Message)"".")
                $allResourceCost = $null
            }
            $Resource_Result += $(
                foreach ($Resource in $Resources) {
                    $countRes++
                    Write-Progress -Id 2 -ParentId 1 -PercentComplete $($countRes * 100 / $Resources.count) -Status "analyzing $($Resources.Count) Resources" -Activity 'analyzing Resources'
                    # get resource cost for previous month
                    if ($null -ne $allResourceCost) {
                        $resourceCost = $($allResourceCost | Where-Object -Property InstanceId -EQ $Resource.ResourceId | Measure-Object -Property PretaxCost -Sum).Sum
                    } else {
                        $resourceCost = $null
                    }
                    if ($details) {
                        # we want to see every resource
                        if ($null -eq $resourceCost -or $resourceCost -eq 0) { $resourceCost = 'n/a' }
                        $item = [PSCustomObject] @{
                                Subscription      = $($subscription.Name)
                                Type              = $Resource.ResourceType
                                ResourceName      = $Resource.Name
                                ResourceGroupName = $Resource.ResourceGroupName
                                Cost              = $resourceCost
                        }
                    } else {
                        # we want to see just the count of resources by type
                        $resourceType = $Resource.ResourceType
                        $resourceCount[$resourceType]++
                        if ($null -ne $resourceCost) {
                            $totalResourceCost[$resourceType] += $resourceCost
                        }
                    }
                    if ($details) {
                        # output one item per resource
                        $item
                    }
                } # foreach Resource
                if (-not $details) {
                    # output one item per resource type
                    foreach ($resourceType in $resourceCount.Keys) {
                        if ($totalResourceCost[$resourceType] -eq 0) { $totalResourceCost[$resourceType] = 'n/a' }
                        [PSCustomObject] @{
                            Subscription      = $($subscription.Name)
                            Type              = $resourceType
                            ResourceCount     = $resourceCount[$resourceType]
                            Cost              = $totalResourceCost[$resourceType]
                        }
                    }
                }
            )
        } # if count -ne 0
    } # if $ResourceList
} # foreach subscription
Write-Progress -Id 1 -Completed -Activity 'Subscriptions'

if (-not $outFile) {
    # Output to stdout as object

    if ($VM) {
        $VM_Result
    }

    if ($SqlServer) {
        $SQL_Result
    }

    if ($DbAas) {
        $DBaaS_Result
    }

    if ($Storage) {
        $Storage_Result
    }

    if ($Snapshot) {
        $Snapshot_Result
    }

    if ($ResourceList) {
        $Resource_Result | Sort-Object -Property @{Expression="Subscription";Descending=$false},@{Expression="ResourceCount";Descending=$true}
    }
} else {
    if (-not $outFile.Contains('.')) {
        $outFile += '.csv'
    }

    if ($VM -and $VM_Result) {
        $VM_Result | Export-Csv -Path $($outFile -replace '\.', '_VM.') -Delimiter $separator -NoTypeInformation
    }
    if ($SqlServer -and $SQL_Result) {
        $SQL_Result | Export-Csv -Path $($outFile -replace '\.', '_SQL.') -Delimiter $separator -NoTypeInformation
    }

    if ($DbAas -and $DBaaS_Result) {
        $DBaaS_Result | Export-Csv -Path $($outFile -replace '\.', '_DB.') -Delimiter $separator -NoTypeInformation
    }

    if ($Storage -and $Storage_Result) {
        $Storage_Result | Export-Csv -Path $($outFile -replace '\.', '_SA.') -Delimiter $separator -NoTypeInformation
    }
    if ($Snapshot -and $Snapshot_Result) {
        $Snapshot_Result | Export-Csv -Path $($outFile -replace '\.', '_SS.') -Delimiter $separator -NoTypeInformation
    }
    if ($ResourceList -and $Resource_Result) {
        $Resource_Result | `
            Sort-Object -Property @{Expression="Subscription";Descending=$false},@{Expression="ResourceCount";Descending=$true} | `
            Export-Csv -Path $($outFile -replace '\.', '_RL.') -Delimiter $separator -NoTypeInformation
    }
}
