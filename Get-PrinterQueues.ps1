[CmdletBinding(DefaultParameterSetName = 'default')]

Param (
    [Parameter(ParameterSetName="default", Mandatory, Position=0)] [string] $computerFilter,
    [Parameter(ParameterSetName="default", Position=1)] [switch] $details,
    [Parameter(ParameterSetName="default", Position=2)] [switch] $ping,
    [Parameter(ParameterSetName="default", Position=3)] [string] $outFile,
    [Parameter(ParameterSetName="help")] [Alias("h")] [switch] $help
)

if ($help) {
    "Purpose:"
    "    Lists all printer queues on all computers matching the filter."
    "    The <filter> can be a computer name but also include wildcards"
    "    The output will be for the each printer on the matching computer(s),"
    "    name of computer, printer, driver, and printer IP address."
    ""
    "Usage:"
    "    Get-PrinterQueues -computerFilter <filter> [-details] [-ping] [-outFile <outfilename>]"
    "    -computerFilter"
    "        name(s) of computer(s) whose queues shall be displayed. Filter may contain wildcards"
    ""
    "    -details"
    "        Give additional details for each printer: name of shared printer, location,"
    "        comment, and port name"
    ""
    "    -ping"
    "        will try to ping each printer and output an additional field 'IsLive'"
    ""
    "    -outFile"
    "        if given, exports result into a semicolon-separated CSV file"
    ""
    exit
}

$computerNames = (Get-ADComputer -Filter ("Name -like '*" + $computerFilter +"*'")).Name
if (-not $computerNames.GetType().IsArray) {
    $computerNames = ,$computerNames
}

if ($outFile) { Remove-Item -Path $outFile -Force -ErrorAction SilentlyContinue -WarningAction SilentlyContinue }

$countC = 0
foreach ($computerName in $computerNames) {
    $countC++
    Write-Progress -Id 1 -PercentComplete $($countC * 100 / $computerNames.count) -Status 'iterating through computers' -Activity "analyzing printers on computer $countC of $($computernames.count)"
    $printers = Get-Printer -ComputerName $computerName -ErrorAction SilentlyContinue
    $printerPorts = Get-PrinterPort -ComputerName $computerName -ErrorAction SilentlyContinue
    foreach ($printer in $printers) {
        $portName = $printer.PortName
        $printerPort = $printerPorts | Where-Object -Property Name -EQ $portName

        if ($printerQueue.Shared) {
            $shareName = $printerQueue.ShareName
        } else {
            $shareName = "---"
        }
        if ($printerPort) {
            $portName        = $printerPort.Name
            $portDescription = $printerPort.Description
            $printerAddress  = $printerPort.printerHostAddress
        } else {
            $portName        = ''
            $portDescription = ''
            $printerAddress  = ''
        }

        if ($details) {
            $result = [PSCustomObject]@{
                ComputerName   = $printer.ComputerName
                PrinterName    = $printer.Name
                ShareName      = $shareName
                Type           = $printer.Type
                Location       = $printer.Location
                Comment        = $printer.Comment
                DriverName     = $printer.DriverName
                PortName       = $portName
                PrinterAddress = $printerAddress
            }
        } else {
            $result = [PSCustomObject]@{
                ComputerName   = $printer.ComputerName
                PrinterName    = $printer.Name
                DriverName     = $printer.DriverName
                PrinterAddress = $printerAddress
            }
        }
        if ($ping) {
            $isLive = (Test-NetConnection $printerAddress -ErrorAction SilentlyContinue -WarningAction SilentlyContinue).PingSucceeded
            $result | Add-Member -MemberType NoteProperty -Name 'IsLive' -Value $isLive
        }

        if ($outFile) {
            $result | Export-Csv -Delimiter ";" -Path $outFile -NoTypeInformation -Append
        } else {
            $result
        }
    }
}
