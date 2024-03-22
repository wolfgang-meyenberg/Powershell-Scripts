Param (
    [Parameter(ParameterSetName="VirtualMachine", Mandatory=$true)] [string] $VMType,
    [Parameter(ParameterSetName="VirtualMachine")] [int] $Reservation = -1,
    [Parameter(ParameterSetName="VirtualMachine")] [switch] $AHB,

    [Parameter(ParameterSetName="DiskStorage", Mandatory=$true)] [string] $DiskType,
    [Parameter(ParameterSetName="DiskStorage")] [string] $Redundancy = "LRS",

    [string] $Currency = "EUR",

    [Parameter(ParameterSetName="help", Mandatory=$true)] [Alias("h")] [switch] $help
)

if (($VMType.Length + $DiskType.Length -eq 0) -or ($help)) {
    ""
    ""
    "usage:"
    "Get-AzurePrice -VMType <vmtype> [-Reservation <reservation>] [-AHB] [-Currency <currency>]"
    "Get-AzurePrice -DiskType <disktype> [-Redundancy <redundancy>]  [-Currency <currency>]"
    ""
    "    Get-AzurePrice -VMType [...] displays estimated monthly fee for a given VM type"
    "    <vmtype>      must be written exactly as in the price table, including proper capitalization."
    "                  the space may be replaced by an underscore, e.g. use ""D4s v4"" or ""D4s_v5"""
    "    <reservation> is 0, 1, or 3 (years). If omitted, all three values will be reported, separated by semicolons"
    "    <currency>    can be any valid three-letter currency code, default value is EUR"
    ""
    "    If the -AHB switch is given, prices are given without Windows license (i.e. using Azure Hybrid Benefit)"
    ""
    "    Get-AzurePrice -VMType [...] displays estimated monthly fee for a given disk type"
    "    <disktype>     must be written exactly as in the price table, including proper capitalization, e.g. ""E10"" or ""S20"""
    "    <redundancy>   is either LRS or ZRS, default is LRS"
    "    <currency>     can be any valid three-letter currency code, default value is EUR"
    ""
    exit
}

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
        if ($disk -eq $null) {
            "Disk Type ""$DiskType"" not found, please check spelling and capitalization. Only S, E, and P types are supported."
            exit
        }

        '{0,7:f2} {1}' -f [math]::Round($disk.unitPrice, 2), $Currency
    }
 }
