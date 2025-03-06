<#
.SYNOPSIS
Lists printer queues on computers

.DESCRIPTION
Lists all printer queues on computers, displaying the computer and printer names, and the decription.
More details can be listed using the -details switch

.PARAMETER Filter
Mandatory. List printers on computers matching the filter. The filter may contain wildcards.

.PARAMETER details
For printers, rather than giving just name and description, list details like type, location, comment, driver and port names and IP address.

.PARAMETER ping
Assess whether a printer is responsind to pings

.PARAMETER outFile
Write the output to a semicolon-separated CSV file

.EXAMPLE

#>

[CmdletBinding(DefaultParameterSetName = 'default')]

Param (
    [Parameter(ParameterSetName="default", Mandatory, Position=0)] [string] $Filter,
    [Parameter(ParameterSetName="default", Position=1)] [switch] $details,
    [Parameter(ParameterSetName="default", Position=2)] [switch] $ping,
    [Parameter(ParameterSetName="default", Position=3)] [string] $outFile
)

$computerNames = (Get-ADComputer -Filter ("Name -like '$Filter'")).Name
if ($null -ne $computerNames -and -not $computerNames.GetType().IsArray) {
    $computerNames = ,$computerNames
} else {
    "no computer found for this filter"
    exit
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
                portDescription= $portDescription                
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
            if ($null -ne $printerAddress) {
                $isLive = Test-NetConnection $printerAddress -InformationLevel Quiet -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
            } else {
                $isLive = $false
            }
            $result | Add-Member -MemberType NoteProperty -Name 'IsLive' -Value $isLive
        }

        if ($outFile) {
            $result | Export-Csv -Delimiter ";" -Path $outFile -NoTypeInformation -Append
        } else {
            $result
        }
    }
}
