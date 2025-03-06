<#
.SYNOPSIS
Provides count and size statistics about file extensions and ages on file storages.

.DESCRIPTION
Displays information about size and count of files on a given file share.
Statistics are given grouped by file age and/or file extension.

.PARAMETER ServerName
Mandatory. Collect statistics of files on the given server.

.PARAMETER ShareName
Analyzes files on the given share. If omitted, analyzes data on all non-hidden shares of the given server.

.PARAMETER onAccess
For determining file age, use the LastAccess property. The default behaviour is to use the lastWrite property.

.PARAMETER noAges
Do not group files by age, just group by file extension.

.PARAMETER noExtensions
Do not group files byextension, just group by file age.

.PARAMETER Priority
Starts process with given priority. Use with care.

.EXAMPLE
Get-FileAccesses -ServerName <myserver> -ShareName <myshare> | ft -Property *
List file count and size, grouped by extension and age, based on last written date

.EXAMPLE
Get-FileAccesses -ServerName <myserver> -ShareName <myshare> -onAccess -noExtensions
List file count and size, grouped  by age, based on last accessed date, and formatted as table

#>

Param (
    [Parameter(ParameterSetName='default', Mandatory, Position=1)] [string] $ServerName,
    [Parameter(ParameterSetName='default', Position=2)] [string] $ShareName = '*', 
    [Parameter(ParameterSetName='default', Position=3)] [switch] $onAccess,
    [Parameter(ParameterSetName='default', Position=4)] [switch] $noExtensions,
    [Parameter(ParameterSetName='default', Position=5)] [switch] $noAges,
    [Parameter(ParameterSetName='default', Position=6)][ValidateSet('BelowNormal', 'Normal', 'AboveNormal', 'High', 'Realtime')] [string] $Priority = 'Normal'
)

if ($Priority -ne 'Normal') {
    [System.Threading.Thread]::CurrentThread.Priority = $Priority
}

# group files by these intervals:
$SPAN_DAY = 0
$SPAN_WEEK = 1
$SPAN_MONTH = 2
$SPAN_YEAR = 3
$SPAN_2YEARS = 4
$SPAN_3YEARS = 5
$SPAN_5YEARS = 6
$SPAN_10YEARS = 7
$SPAN_15YEARS = 8
$SPAN_OLDER = 9
function SpanToText ([int] $span)
{
    if ($span -eq $SPAN_DAY) { return '1d' }
    if ($span -eq $SPAN_WEEK) { return '1w' }
    if ($span -eq $SPAN_MONTH) { return '1m' }
    if ($span -eq $SPAN_YEAR) { return '1y' }
    if ($span -eq $SPAN_2YEARS) { return '2y' }
    if ($span -eq $SPAN_3YEARS) { return '3y' }
    if ($span -eq $SPAN_5YEARS) { return '5y' }
    if ($span -eq $SPAN_10YEARS) { return '10y' }
    if ($span -eq $SPAN_15YEARS) { return '15y' }
    if ($span -eq $SPAN_OLDER) { return 'older' }
}

# 2-dimensional arrays
# 1st index = age
# 2nd index = extension
$accessFileCounts =  @(@{},@{},@{},@{},@{},@{},@{},@{},@{},@{})
$accessFileSizesMB =  @(@{},@{},@{},@{},@{},@{},@{},@{},@{},@{})
$allExtensions = @()

if ($shareName -eq '*') {
    $shares = (net view "\\$serverName" | Where-Object { ($_ -match '\sDisk\s') -or ($_ -match '\sPlatte\s') }) -replace '\s\s+', ',' | ForEach-Object{ ($_ -split ',')[0] }
} else {
    $shares = ,$shareName     # the leading comma makes this a (one-item) array
}

$countSh = 0 # for progress bar

foreach ($share in $Shares) {
    $accessFileCounts =  @(@{},@{},@{},@{},@{},@{},@{},@{},@{},@{})
    $accessFileSizesMB =  @(@{},@{},@{},@{},@{},@{},@{},@{},@{},@{})
    $countSh++

    Write-Progress -Id 1 -PercentComplete $($countSh * 100 / $Shares.count) -Status 'iterating through shares on server $Servername' -Activity "analyzing share $share ($countSh of $($Shares.count))"
    
    Get-ChildItem -Path "\\$Servername\$share" -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        if (! $_.PSIsContainer) {
            # skip directories, count only files
            # determine file extension
            $ext = $_.Extension
            if ($noExtensions) { $ext = '' }
            if ($ext -notin $allExtensions) { $allExtensions += $ext }
                # count files based on last WRITE or ACCESS

            if ($onAccess) {
                $dd = [math]::Floor( (New-TimeSpan -Start ($_.LastAccessTimeUtc.Date) -End (Get-Date)).TotalDays )
            } else {
                $dd = [math]::Floor( (New-TimeSpan -Start ($_.LastWriteTimeUtc.Date) -End (Get-Date)).TotalDays )
            }
            if ($noAges) { $dd = 0 }
                # calculate index for files depending on age
            if ($dd -lt 1) {
                $age = $SPAN_DAY
            } elseif ($dd -lt 7) {
                $age = $SPAN_WEEK
            } elseif ($dd -lt 30) {
                $age = $SPAN_MONTH
            } elseif ($dd -lt 365) {
                $age = $SPAN_YEAR
            } elseif ($dd -lt 730) {
                $age = $SPAN_2YEARS
            } elseif ($dd -lt 1096) {
                $age = $SPAN_3YEARS
            } elseif ($dd -lt 1826) {
                $age = $SPAN_5YEARS
            } elseif ($dd -lt 3652) {
                $age = $SPAN_10YEARS
            } elseif ($dd -lt 5479) {
                $age = $SPAN_15YEARS
            } else {
                $age = $SPAN_OLDER
            }
                # increase file count
            $accessFileCounts[$age][$ext] ++
                # add file size in MBytes
            $accessFileSizesMB[$age][$ext] += [math]::Floor($_.Length / 1048576)
        } # if not folder
    } # for each child of current share
    ForEach ($extension in ($allExtensions | Sort-Object)) {
        $result = [PSCustomObject]@{
                Share     = "\\$serverName\$Share"
                Extension = $extension
            }
        if (-not $noAges) {
            For ($age=0; $age -le $SPAN_OLDER; $age++) {
                if ($null -eq $accessFileCounts[$age][$extension] -or $accessFileCounts[$age][$extension] -eq 0) {
                    $result | Add-Member -MemberType NoteProperty -Name $('num ' + $(SpanToText $age)) -Value 0
                } else {
                    $result | Add-Member -MemberType NoteProperty -Name $('num ' + $(SpanToText $age)) -Value $accessFileCounts[$age][$extension]
                }
            }
            For ($age=0; $age -le $SPAN_OLDER; $age++) {
                if ($null -eq $accessFileSizesMB[$age][$extension] -or $accessFileSizesMB[$age][$extension]-eq 0) {
                    $result | Add-Member -MemberType NoteProperty -Name $('MB ' + $(SpanToText $age)) -Value 0
                } else {
                    $result | Add-Member -MemberType NoteProperty -Name $('MB ' + $(SpanToText $age)) -Value $accessFileSizesMB[$age][$extension]
                }
            }
        } else {
            if ($null -eq $accessFileCounts[0][$extension] -or $accessFileCounts[$age][$extension] -eq 0) {
                $result | Add-Member -MemberType NoteProperty -Name $('num') -Value 0
            } else {
                $result | Add-Member -MemberType NoteProperty -Name $('num') -Value $accessFileCounts[0][$extension]
            }

            if ($null -eq $accessFileSizesMB[0][$extension] -or $accessFileCounts[$age][$extension] -eq 0) {
                $result | Add-Member -MemberType NoteProperty -Name $('MB') -Value 0
            } else {
                $result | Add-Member -MemberType NoteProperty -Name $('MB') -Value $accessFileSizesMB[0][$extension]
            }
        }
        $result
    }
} # for each share
Write-Progress -Id 1 -Activity "analyzing shares" -Completed
