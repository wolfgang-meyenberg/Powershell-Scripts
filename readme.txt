Get-AzurePrice
==============
Purpose:
Lists the price for a specified VM or managed disk

Usage:
Get-AzurePrice -VMType <vmtype> [-Reservation <reservation>] [-AHB] [-Currency <currency>]
Get-AzurePrice -DiskType <disktype> [-Redundancy <redundancy>] [-Currency <currency>]

Get-AzurePrice -VMType [...] displays estimated monthly fee for a given VM type
-VMType		must be written exactly as in the price table, including proper capitalization.
			The space may be replaced by an underscore,
			e.g. use "D4s v4" or "D4s_v5"
-Reservation	is 0, 1, or 3 (years). If omitted, all three values will be reported, separated by semicolons
-Currency		can be any valid three-letter currency code, default value is EUR
-AHB			gives prices without Windows license (i.e. using Azure Hybrid Benefit)

Get-AzurePrice -VMType [...] displays estimated monthly fee for a given disk type
-Disktype		must be written exactly as in the price table, including proper capitalization, e.g. "E10" or "S20"
-Redundancy	is either LRS or ZRS, default is LRS
-Currency		can be any valid three-letter currency code, default value is EUR

-------------------------------------------------------------------------------

Get-ConnectedNICs
=================
Purpose:
List network interfaces in given subscriptions with IP address, VNet name, network address and DNS record, also tests whether NIC is responding to pings

Usage:
Get-ConnectedNICs [-subscriptionFilter <filterexpression>] [-outFile <outfilename>] [-noPing]
-subscriptionFilter	mandatory parameter, list NICs in subscriptions matching the filter
-outFile	writes results to a semicolon-separated CSV format if this parameter is given
-noPing	skips testing whether the NIC is responding to a ping

-------------------------------------------------------------------------------

Get-NSGRules
============
Purpose:
Lists the NSG rules in the given subscriptions in a summarized or detailed way

Usage:
Get-NSGRules -subscriptionFilter <filterexpression> [-details | -briefDetails] 
-subscriptionfilter	mandatory parameter, list NSGs in subscriptions matching the filter
-details			list all rules in order of their priority
-briefDetails		list every rule, but fewer details
				if neither "details" switch is present, then all open ports are listed,
				regardless of the actual source and target networks. Since this mixes rules,
				it gives you an overview of ports but no reliable information about security

-------------------------------------------------------------------------------

Get-VirtualMachineSizes
=======================
Purpose:
Lists the VMs, their SKU and their disks

Usage:
Get-VirtualMachineSizes -subscriptionFilter <filterexpression> [-disks [-aggregate]]

-subscriptionFilter	list VMs in matching subscriptions
-disks			also shows disk information
-aggregate			aggregates disks by SKUs, requires -disks

-------------------------------------------------------------------------------

Get-VirtualNetworks
===================
Purpose:
Lists all virtual networks, subnets, IP addresses and -ranges for the specified subscription(s)

Usage:
Get-VirtualNetworks -subscriptionFilter <filterexpression> [-outFile <outfilename>] [-excludeSubnets]

-subscriptionFilter	mandatory. Lists networks in subscriptions matching the filter
-outFile			writes output into semicolon-separated CSV format
-excludeSubnets		will only list VNets, not subnets

