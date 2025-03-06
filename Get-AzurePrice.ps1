<#
.SYNOPSIS
Gets the price of an Azure VM or disk by querying the Azure price API

.DESCRIPTION
Queries the Azure price API for a VM or disk type.
For a VM, the reservation period and/or the use of Azure Hybrid Benefits can be specified
For disks, the redundancy type can be specified.

.PARAMETER VMType
Type of the VM for which the price is sought. The resource type must be written exactly as in the price table, including proper capitalization.
Some types contain spaces, these can by replaced by an underscore, e.g. use "D4s v4" or "D4s_v5" gives the same result.

.PARAMETER Reservation
Give price for pay as you go, 1 or 3 years reservation.
If specified, must be 0, 1, or 3. If omitted, price for all three scenarios are given, separated by semicolons.

.PARAMETER AHB
Give price using Azure Hybrid Benefits, i.e. without Windows license price

.PARAMETER DiskType
Type of the disk for which the price is sought. The resource type must be written exactly as in the price table, including proper capitalization, e.g. "E10".

.PARAMETER Redundancy
Either LRS (local redundant storage) or ZRS (zone redundant storage). Default is LRS.
.PARAMETER Currency
Display price in the given currency, default is EUR.

.EXAMPLE
Get-AzurePrice -VMType D4ds_v5 -Reservation 3 -AHB
Displays the price for a D4ds v5 VM with a three-year reservation and use of Azue Hybrid Benefits

.EXAMPLE    
Get-AzurePrice -DiskType S30
Displays the price of an S30 disk with local redundant storage

#>

Param (
    [Parameter(ParameterSetName="VirtualMachine", Mandatory=$true)] [string] $VMType,
    [Parameter(ParameterSetName="VirtualMachine")] [int] $Reservation = -1,
    [Parameter(ParameterSetName="VirtualMachine")] [switch] $AHB,

    [Parameter(ParameterSetName="DiskStorage", Mandatory=$true)] [string] $DiskType,
    [Parameter(ParameterSetName="DiskStorage")] [string] $Redundancy = "LRS",

    [string] $Currency = "EUR"
)

switch ($PsCmdlet.ParameterSetName) {
    "VirtualMachine" {
        # we also accept a VM type ending in ' Linux'. in that case, we look up the price with AHB
        if ($VMType -like '*Linux') {
            $VMtype = $VMType -replace(' ?Linux','')
            $AHB = $true
        }

        # we use the armSkuName attribute, which uses underscores rather than spaces and always begins with "Standard_"
        $VMType = "Standard_" + $VMType.Replace(' ', '_')

        $uri = 'https://prices.azure.com/api/retail/prices?currencyCode=''' + $Currency + '''&$filter=serviceName eq ''Virtual Machines'' and armregionName eq ''westeurope'' and armSkuName eq ''' + $VMType + ''''

        $vms = $(Invoke-RestMethod $uri).Items | Where-Object {$_.type -in 'Consumption','Reservation' -and $_.meterName -notlike '*Spot*' -and $_.meterName -notlike '*Low*'}

        if ($vms.count -eq 0) {
            "VM Type ""$VMType"" not found, please check correct type, spelling and capitalization."
            exit
        }

        #that typically gives us four entries: no reservation with windows, no reservation AHB, 1 year AHB, 3 year AHB

        $WIN_0 = $vms | Where-Object productName -Like '*Windows*'
        $AHB_0 = $vms | Where-Object {$_.productName -NotLike '*Windows*' -and $_.reservationTerm -eq $null}
        $AHB_1 = $vms | Where-Object {$_.productName -NotLike '*Windows*' -and $_.reservationTerm -like '*1*'}
        $AHB_3 = $vms | Where-Object {$_.productName -NotLike '*Windows*' -and $_.reservationTerm -like '*3*'}

        $WIN_0_MRC = $AHB_0.unitPrice * 730 # unit price is per 1 hour
        $WIN_1_MRC = $AHB_1.unitPrice / 12  # unit price is per 1 year
        $WIN_3_MRC = $AHB_3.unitPrice / 36  # unit price is per 3 years

        if (-not $AHB) {
                # need to add Windows license price to MRCs
            $WIN_LIC_MRC = ($WIN_0.unitPrice - $AHB_0.unitPrice) * 730 # unit prices are per 1 hour, 1 month = 730 hours
            $WIN_0_MRC = $WIN_0_MRC + $WIN_LIC_MRC
            $WIN_1_MRC = $WIN_1_MRC + $WIN_LIC_MRC
            $WIN_3_MRC = $WIN_3_MRC + $WIN_LIC_MRC
        }

        switch ($Reservation) {
            0 {'{0,7:f2} {1}' -f [math]::Round($WIN_0_MRC, 2), $Currency }
            1 {'{0,7:f2} {1}' -f [math]::Round($WIN_1_MRC, 2), $Currency }
            3 {'{0,7:f2} {1}' -f [math]::Round($WIN_3_MRC, 2), $Currency }
            -1 {
                'no res.;1 year;3 years'
                '{0,7:f2} {3};{1,7:f2} {3};{2,7:f2} {3}' -f [math]::Round($WIN_0_MRC, 2), [math]::Round($WIN_1_MRC, 2), [math]::Round($WIN_3_MRC, 2), $Currency
            }
        } 
    }
    "DiskStorage" {
        $uri = 'https://prices.azure.com/api/retail/prices?currencyCode=''' + $Currency + '''&$filter=serviceName eq ''Storage'' and armregionName eq ''westeurope'' and skuName eq ''' + $DiskType + ' ' + $Redundancy + ''''
        if ($DiskType.Substring(0,1) -ne 'P') { # premium disks have price items different from HDDs and SSDs
            $disk = $(Invoke-RestMethod $uri).Items | Where-Object {$_.type -eq 'Consumption' -and $_.productname -like '*Managed Disks' -and $_.meterName -like '*Disk'}
        } else {
            $disk = $(Invoke-RestMethod $uri).Items | Where-Object {$_.type -eq 'Consumption' -and $_.productname -eq 'Premium SSD Managed Disks' -and $_.metername -eq ('' + $DiskType + ' ' + $Redundancy + ' Disk') }
        }
        if ($null -eq $disk) {
            "Disk Type ""$DiskType"" not found, please check spelling and capitalization. Only S, E, and P types are supported."
            exit
        }

        '{0,7:f2} {1}' -f [math]::Round($disk.unitPrice, 2), $Currency
    }
 }
