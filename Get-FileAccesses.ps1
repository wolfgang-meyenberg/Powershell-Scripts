Param (
    [Parameter(ParameterSetName='default', Mandatory, Position=1)] [string] $ServerName,
    [Parameter(ParameterSetName='default', Position=2)] [string] $ShareName = '*', 
    [Parameter(ParameterSetName='default', Position=3)] [switch] $onAccess,
    [Parameter(ParameterSetName='default', Position=4)] [switch] $noExtensions,
    [Parameter(ParameterSetName='default', Position=5)] [switch] $noAges,
    [Parameter(ParameterSetName='default', Position=6)][ValidateSet('BelowNormal', 'Normal', 'AboveNormal', 'High', 'Realtime')] [string] $Priority = 'Normal',
    [Parameter(ParameterSetName='help')] [Alias('h')] [switch] $help
)

if ($help) {
    'NAME'
    'Get-FileAccesses'
    ''
    'PURPOSE'
    'provides count and size statistics about file extensions and ages on file storages'
    ''
    'USAGE'
    'Get-FileAccesses -ServerName <servername> [-ShareName <sharename>] [-onAccess] [-noAges] [-noExtensions] [-Priority (BelowNormal | Normal | AboveNormal | High | Realtime)]'
    '    -ServerName   Mandatory, evaluates data on given share(s) of <servername>'
    '    -ShareName    Analyzes files on the given share.'
    '                  If omitted, analyzes data on all non-hidden shares of the given server.'
    '    -onAccess     Uses lastAccess for age calculation.'
    '                  If omitted, uses lastWrite for age calculation'
    '    -noAges       Ignores file age, lists by extensions only (if -noExtensions is not given)'
    '    -noExtensions Ignores extensions, lists by age only (if -noAge is not given)'
    '                  If BOTH -no... switches are given, script only returns total'
    '                  file count and size'
    '    -Priority     Starts process with given priority. Use with care.'
    '                  Possible values are BelowNormal | Normal | AboveNormal | High | Realtime'
    ''
    'EXAMPLES'
    'to list file count and size by age, based on last accessed date'
    'Get-FileAccesses -ServerName myserver -ShareName myshare -onAccess -noExtensions'
    ''
    'to see all properties in table format, use ft -Property *'
    'Get-FileAccesses -ServerName myserver -ShareName myshare | ft -Property *'
    ''
    exit
}

if ($Priority -ne 'Normal') {
    [System.Threading.Thread]::CurrentThread.Priority = $Priority
}

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

if ($ShareName -eq '*') {
    $Shares = (net view $ServerName | Where-Object { ($_ -match '\sDisk\s') -or ($_ -match '\sPlatte\s') }) -replace '\s\s+', ',' | ForEach-Object{ ($_ -split ',')[0] }
} else {
    $Shares = ,$ShareName     # the leading comma makes this a (one-item) array
}

foreach ($share in $Shares) {
    $accessFileCounts =  @(@{},@{},@{},@{},@{},@{},@{},@{},@{},@{})
    $accessFileSizesMB =  @(@{},@{},@{},@{},@{},@{},@{},@{},@{},@{})
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
            if ($dd -lt 1) {
                $age = $SPAN_DAY
            } elseif ($dd -lt 7) {
                $age = $SPAN_WEEK
            } elseif ($dd -lt 30) {
                $age = $SPAN_MONTH
            } elseif ($dd -lt 365) {
                $age = $SPAN_YEAR
            } elseif ($dd -lt 730) {
                $age = $SPAN_2YEARS
            } elseif ($dd -lt 1096) {
                $age = $SPAN_3YEARS
            } elseif ($dd -lt 1826) {
                $age = $SPAN_5YEARS
            } elseif ($dd -lt 3652) {
                $age = $SPAN_10YEARS
            } elseif ($dd -lt 5479) {
                $age = $SPAN_15YEARS
            } else {
                $age = $SPAN_OLDER
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
                if ($accessFileCounts[$age][$extension] -eq $null -or $accessFileCounts[$age][$extension] -eq 0) {
                    $result | Add-Member -MemberType NoteProperty -Name $('num ' + $(SpanToText $age)) -Value 0
                } else {
                    $result | Add-Member -MemberType NoteProperty -Name $('num ' + $(SpanToText $age)) -Value $accessFileCounts[$age][$extension]
                }
            }
            For ($age=0; $age -le $SPAN_OLDER; $age++) {
                if ($accessFileSizesMB[$age][$extension] -eq $null -or $accessFileSizesMB[$age][$extension]-eq 0) {
                    $result | Add-Member -MemberType NoteProperty -Name $('MB ' + $(SpanToText $age)) -Value 0
                } else {
                    $result | Add-Member -MemberType NoteProperty -Name $('MB ' + $(SpanToText $age)) -Value $accessFileSizesMB[$age][$extension]
                }
            }
        } else {
            if ($accessFileCounts[0][$extension] -eq $null -or $accessFileCounts[$age][$extension] -eq 0) {
                $result | Add-Member -MemberType NoteProperty -Name $('num') -Value 0
            } else {
                $result | Add-Member -MemberType NoteProperty -Name $('num') -Value $accessFileCounts[0][$extension]
            }

            if ($accessFileSizesMB[0][$extension] -eq $null -or $accessFileCounts[$age][$extension] -eq 0) {
                $result | Add-Member -MemberType NoteProperty -Name $('MB') -Value 0
            } else {
                $result | Add-Member -MemberType NoteProperty -Name $('MB') -Value $accessFileSizesMB[0][$extension]
            }
        }
        $result
    }
} # for each share
