<#
.SYNOPSIS
The script can overlay JPG image files with text derived from GPS information in the image's EXIF data.
It can also rename files according to place and date information.

.DESCRIPTION
JPG images can contain extended information (so-called EXIF data). This data may contain GPS information such as the geographical position where the picture was taken.
The GPS location (latitude and longitude) can be used to look up the correspondig place name.
Using this script, the location text can be placed on the image itself.
Also, the filename can be changed to reflect date, location, or both.

The lookup of GPS information is done via the free Openstreetmap API, which is limited to about one request per second.
Depending on the place names, data may be given in non-Latin characters, e.g. 北京 instead of Beijing.
You can use a translation file to map such names to characters and languages of your choice

The script can be used in three different ways:
1) process all images immediately
2) extract GPS information and create a text file mapping image names to GPS data.
   This file can be edited before actually writing data into the images
3) apply a translation file to the GPS file
4) apply the previously created GPS file and write the data into the images

As new user, be sure to check the descriptions of all parameters.
    
.PARAMETER source
Path of the source files.
If you give the destination path as well, GPS data is written directly into the images.
If you give the gpsFile path, a GPS file is created.
See also -gpsFile and -translationFile parameters.

.PARAMETER destination
Path for the processed images, it MUST be different from the source folder.
If the source path is given as well, GPS data is written directly into the images.
If you give the gpsFile path, a GPS file is created.
See also -gpsFile and -translationFile parameters.

.PARAMETER translationFile
Place names are returned by the API in local script and language, e.g. 北京 or Roma.
A text file mapping may be used to map these into your desired script and language.
The file format is <originalname>;<translatedname>, e.g.
北京;Beijing
Roma;Rome
If the source, gpsFile and translationFile parameters are given but no translation file exists, a new file is created containing all detected place names.
If the translation file exists, new lines will be added for names that are not yet contained in the file.
You may then edit this file and later apply GPS and translation files to your images.
If only the gpsFile and translation file parameters are given, the translation file is applied to the GPS file, i.e. all workds appearing in the translation file will be replaced by their translations.

.PARAMETER gpsFile
A text file mapping image path and name to GPS data.
This file is created when the source and gpsFile parameters are specified, and its data is written into the images, when the gpsFile and destination parameters are specified.
After creation, the file can be edited with any text editor. The format is
<path>;<filename>;<date>;<orientation>;<latitude>;<longitude>;<altitude>;<country>;<city>, e.g.
C:\pictures;IMG0001.JPG;2023:06:23 14:33:32;1;39.9067224;116.39936;44.2;中国;北京
C:\pictures;IMG0055.JPG;2025:01:30 12:17:28;1;41.9019961;12.4565473;133,30;Italia;Roma

.PARAMETER textFormat
Specifies the format in which the GPS date will be written onto the image. The following placeholders will be replaced by the actual values, all other text will be written as specified:
    !file       filename of the image
    !date       date picture was taken in the format YYYY-MM-DD
    !orien      orientation as given in EXIF data
    !lat        latitude in degrees, minutes, and seconds, followed by N or S
    !lon        longitude in degrees, minutes, and seconds, followed by W or E
    !alt        altitude in metres
    !country    name of country corresponding to GPS location
    !place      name of village, town, city corresponding to GPS location
    !monthyear  date picture was taken in the format <monthname>-YYYY
    !time       time picture was taken

Example: the value '!place (!country) !monthyear' will result in '北京(中国) 2023-06-23' and 'Roma (Italia) 2025-01-30'

.PARAMETER maxTextPercent
Maximum width of the text in percent of the image width. If text would be longer than specified, the font size will be reduced. The default value is 75.

.PARAMETER renameFormat
When this parameter is NOT given, the destination file name is the same as the source file name.
If this parameter is given,the file name is defined by the specified place holders. Note that the resulting string must not contain characters which are forbidden in file names!
Allowed placeholders are:
    !year    year (four digits)
    !yy      year (last two digits)
    !month   month (two digits)
    !day     day (two digits)
    !place   placename (see above comment on forbidden characters)
    !country country (see above comment on forbidden characters)
    A four-digit counter is added to any filename thus generated.

Example: the renameFormat '!yy-!month-' results in filenames like '23-06-0001.jpg' and '25-01-0001.jpg'

.PARAMETER recurse
Process all pictures in the current directory and all its subdirectories

.EXAMPLE
Imagine we have many pictures taken over time, and some are from places which use a different script or language. We want the pictures to be annotated with place, and date, the place names should be in Latin script in English language.
We then need to fulfil three steps:
1) extract GPS information and create a text file mapping picture names to GPS
   data, and also a translation file containing all place names.
2) manually edit the translation file
3) apply GPS and translation files to the pictures, creating annotated copies of the pictures
   This file can be edited before actually writing data into the images

First, call script to create GPS and translation file. This may take considerable time, because we use the free Openstreetmap API to resolve the place names. The free API is limited to approximately one query per second:
Add-GpsToImages -source c:\source\*.jpg -gpsFile c:\source\gps.txt -translationFile c:\source\translate.txt

Now, edit the translation.txt file, e.g. changing an entry like "北京;北京" to "北京;Beijing" or "Roma;Roma" to "Roma;Rome"

Finally, call script again to apply GPS and translation files to the pictures.
We want the picture annotations to have the format "placename (country), monthname year", e.g. "Rome (Italy), January 2025", and they shall not occupy more than 60% of the picture's width.
Furthermore, we want the images to be named like <country>-<year><month>-####.jpg, #### being a counter
Add-GpsToImages -gpsFile c:\source\gps.txt -translationFile c:\source\translate.txt -destination c:\destination -textFormat '!place (!country), !monthyear -maxTextPercent 60 -renameFormat '!country-!year!month-'
#>

[CmdletBinding()]
Param (
    [Parameter(ParameterSetName="CreateGpsFile", Mandatory, HelpMessage="Images to process")]
    [Parameter(ParameterSetName="AddGpsLocationDirect", Mandatory, HelpMessage="Images to process")]
    [SupportsWildcards()]
    [string] $source,

    [Parameter(ParameterSetName="AddGpsLocationDirect", Mandatory, HelpMessage="destination folder for processed files")]
    [Parameter(ParameterSetName="ApplyGpsFile", Mandatory, HelpMessage="destination folder for processed files")]
    [string] $destination,

    [Parameter(ParameterSetName="CreateGpsFile", HelpMessage="translation file name")]
    [Parameter(ParameterSetName="AddGpsLocationDirect", HelpMessage="translation file name")]
    [Parameter(ParameterSetName="ApplyGpsFile", HelpMessage="translation file name")]
    [Parameter(ParameterSetName="ApplyTranslationToGpsFile", Mandatory, HelpMessage="translation file name")]
    [string] $translationFile,

    [Parameter(ParameterSetName="CreateGpsFile", Mandatory, HelpMessage="Images to process")]
    [Parameter(ParameterSetName="ApplyGpsFile", Mandatory, HelpMessage="Images to process")]
    [Parameter(ParameterSetName="ApplyTranslationToGpsFile", Mandatory, HelpMessage="translation file name")]
    [string] $gpsFile,

    [Parameter(ParameterSetName="AddGpsLocationDirect", HelpMessage="use any of the following placeholders: !file !date !orien !lat !lon !alt !country !place !monthyear !time")]
    [Parameter(ParameterSetName="ApplyGpsFile", HelpMessage="use any of the following placeholders: !file !date !orien !lat !lon !alt !country !place !monthyear !time")]
    [string] $textFormat = '',

    [Parameter(ParameterSetName="AddGpsLocationDirect", HelpMessage="max text size in % of image width")]
    [Parameter(ParameterSetName="ApplyGpsFile", HelpMessage="max text size in % of image width")]
    [int] $maxTextPercent = 75,

    [Parameter(ParameterSetName="AddGpsLocationDirect", `
        HelpMessage="rename file, use y,m,d,p,c as placeholders for year, month, day, place, country. Do not include characters not valid for filenames")]
    [Parameter(ParameterSetName="ApplyGpsFile", `
        HelpMessage="rename file, use y,m,d,p,c as placeholders for year, month, day, place, country. Do not include characters not valid for filenames")]
    [string] $renameFormat,

    [Parameter(ParameterSetName="CreateGpsFile", HelpMessage="also process subdirectories")]
    [Parameter(ParameterSetName="AddGpsLocationDirect", HelpMessage="also process subdirectories")]
    [switch] $recurse
)

# a record of the GPS data which we get as EXIF information in usable format
class GpsData {
    [double] $lat
    [double] $lon
    [double] $alt
    [string] $country
    [string] $place
    [string] $date
    [string] $monthYear
    [string] $time
    [int]    $orientation
    GpsData([double]$lat, [double]$lon, [double]$alt, [string]$country, [string]$place, [string]$date, [int]$orientation) {
        lat     = $lat
        lon     = $lon
        alt	    = $alt
        country	= $country
        place	= $place
        date	= $date
        orientation	= $orientation
        try {
            $dt = [DateTime]::ParseExact($date, 'yyyy:MM:dd HH:mm:ss',$null)
            monthYear   = $dt.ToString('MMMM yyyy')   
            time        = $dt.ToShortTimeString()
        }
        catch {
            date = ''
            monthYear   = ''
            time        = ''
        }
    }
    #   Ctor splitting a string into data fields 
    #   A string read from a GPS file has the following format:
    #   path;filename;date;orientation;latitude;longitude;altitude;country;place;height;width
    #     0     1       2     3         4         5         6       7        8      9    10
    GpsData([string]$dataString) {
        $data = $dataString -split ';'
        $this.lat	    = [double]::Parse($data[4])
        $this.lon	    = [double]::Parse($data[5])
        $this.alt	    = [double]::Parse($data[6])
        $this.country	= $data[7]
        $this.place	    = $data[8]
        try {
            $dt = [DateTime]::ParseExact($data[2], 'yyyy:MM:dd HH:mm:ss',$null)
            $this.date	    = $data[2]
            $this.monthYear = $dt.ToString('MMMM yyyy')   
            $this.time      = $dt.ToShortTimeString()
        }
        catch {
            $this.date	    = ''
            $this.monthYear = ''
            $this.time      = ''
        }
        $this.orientation = [int]::Parse($data[3])
<# height and width written into file but ignored for reading
        $this.height      = $data[9]
        $this.width       = $data[10]
#>
    }
}

# a record of GPS data as read from a picture's EXIF record
class ExifDataSet {
    [string] $path
    [double] $lat
    [double] $lon
    [double] $alt
    [string] $country
    [string] $place
    [string] $date
    [string] $monthYear
    [string] $time
    [int]    $orientation
    [int]    $height
    [int]    $width
    [bool]   $validLocation
    [string] $fileHash

    # initializer setting object to a defined state in case no EXIF data was found
    hidden InitError() {
        $this.path          = ''
        $this.lat           = 0
        $this.lon           = 0
        $this.alt           = 0
        $this.country       = ''
        $this.place         = ''
        $this.date          = ''
        $this.monthYear     = ''
        $this.time          = ''
        $this.orientation   = 0
        $this.height        = 0
        $this.width         = 0
        $this.fileHash      = ''
        $this.validLocation = $false
    }
    # default Ctor
    ExifDataSet () {
        $this.InitError()
    }
    # Ctor initializing object with EXIF data already given as fields
    ExifDataSet ( [string]$path, [double]$lat, [double]$lon, [double]$alt, [string]$country, [string]$place, [string]$date, [string]$monthYear, [string]$time, [int]$orientation, [int]$pxHeight, [int]$pxWidth, [string]$fileHash ) {
        try {
            $this.path          = $path
            $this.lat           = $lat
            $this.lon           = $lon
            $this.alt           = $alt
            $this.country       = $country
            $this.place         = $place
            $this.date          = $date
            $this.monthYear     = $monthYear
            $this.time          = $time
            $this.orientation   = $orientation
            $this.height        = $pxHeight
            $this.width         = $pxWidth
            $this.fileHash      = $fileHash
            $this.validLocation = $true
        }
        catch {
            # reset object in case any conversion goes wrong,
            # because that means that the data is invalid
            $this.InitError()
        }
    }
    # Ctor initializing object with EXIF data given as semicolon-separated string
    ExifDataSet ( [string]$line ) {
        try {
            $data = @($line -split ';')
            $this.path          = $data[0]
            $this.lat           = [double]::Parse($data[3])
            $this.lon           = [double]::Parse($data[4])
            $this.alt           = [double]::Parse($data[5])
            $this.country       = $data[6]
            $this.place         = $data[7]
            $this.fileHash      = $data[10]
            try {
                $this.date = $data[1]-replace '-',':'  -replace '\.',':' # either - or . may be used as separator, here we expect ':'
                $dt = [DateTime]::ParseExact($this.date, 'yyyy:MM:dd HH:mm:ss',$null)
                $this.monthYear = $dt.ToString('MMMM yyyy')
                $this.time      = $dt.ToShortTimeString()
            }
            catch {
                $this.date	    = ''
                $this.monthYear = ''
                $this.time      = ''
            }
            $this.orientation   = [int]::Parse($data[3])
            $this.validLocation = ($this.lat -ne 0 -or $this.lon -ne 0)
        }
        catch {
            # reset object in case any conversion goes wrong,
            # because that means that the data is invalid
            $this.InitZero
        }
    }    
  # Ctor initializing object with only fileDateTime given
    ExifDataSet ( [string]$path, [string]$date ) {
        try {
            $this.path         = $path
            $this.lat          = 0
            $this.lon          = 0
            $this.alt          = 0
            $this.country      = ''
            $this.place        = ''
            $this.date         = $date
            if ('' -ne $this.date) {
                $this.monthYear    = $date.ToString('MMMM yyyy')   
                $this.time         = $date.ToShortTimeString()
            } else {
                $this.monthYear    = ''   
                $this.time         = ''
            }
            $this.orientation  = 0
            $this.validLocation = $false
            $this.fileHash = ''
        }
        catch {
            # reset object in case any conversion goes wrong,
            # because that means that the data is invalid
            $this.InitError()
        }
    }
 }

# read EXIF data from a picture file
# parameters:
#   imagePath   path and filename of the picture to read from
# returns EXIF data from picture. If EXIF data is not found or invalid,
# the field validLocation will be $false
function Get-ExifData ([string]$path) {
    # try to load image 
    try {
        Write-Verbose "try to load $path"
        $image = New-Object -ComObject Wia.ImageFile
        $image.LoadFile($path)
        $fileHash = (Get-FileHash -Path $path).Hash
    }
    catch {
        Write-Warning "ERROR loading image from $path, error message was`r`n $($_.Exception.Message)"
        return $null
    }
    # check whether file contains EXIF properties
    if ($null -ne ($image.Properties | Where-Object -Property Name -eq 'DateTime').Value) {
        try {
            $orientation = ($image.properties | Where-Object -Property Name -eq 'Orientation').Value       
            $GPSLat = @(($image.Properties | Where-Object -Property Name -eq 'GpsLatitude').Value)
            $GPSLon = @(($image.Properties | Where-Object -Property Name -eq 'GpsLongitude').Value)
            $GPSAlt = @(($image.Properties | Where-Object -Property Name -eq 'GpsAltitude').Value)
            $dtString = @(($image.Properties | Where-Object -Property Name -eq 'DateTime').Value)
            $lat = $GPSLat[0].Value + $GPSLat[1].Value/60 + $GPSLat[2].Value/3600
            $lon = $GPSLon[0].Value + $GPSLon[1].Value/60 + $GPSLon[2].Value/3600
            if (@(($image.Properties | Where-Object -Property Name -eq 'GpsLatitudeRef').Value) -eq 'S') {
                $lat = -$lat
            }
            if (@(($image.Properties | Where-Object -Property Name -eq 'GpsLongitudeRef').Value) -eq 'W') {
                $lon = -$lon
            }
            try {
                $date = [DateTime]::ParseExact($dtString, 'yyyy:MM:dd HH:mm:ss',$null)
                $dateStr   = $date.ToString('yyyy-MM-dd HH:mm:ss')
                $monthYear = $date.ToString('MMMM yyyy')   
                $time      = $date.ToShortTimeString()
            }
            catch {
                $dateStr   = ''
                $monthYear = ''
                $time      = ''
            }
            if ($Lat -ne 0 -and $Lon -ne 0) { # EXIF data contains GPS location
                $r=Invoke-WebRequest -uri "https://nominatim.openstreetmap.org/reverse?lat=$lat&lon=$lon&format=json&namedetails=1"
                $locInfo = $r.RawContent -split '\r\n' | Where-Object ({$_ -like '{*'}) | ConvertFrom-Json
                $address = ''
                if ($null -ne $locInfo.address.amenity) {
                    $address = $locInfo.address.amenity
                } elseif ($null -ne $locInfo.address.city) {
                    $address = $locInfo.address.city
                } elseif  ($null -ne $locInfo.address.town) {
                    $address = $locInfo.address.town
                } elseif  ($null -ne $locInfo.address.village) {
                    $address = $locInfo.address.village
                } elseif  ($null -ne $locInfo.address.hamlet) {
                    $address = $locInfo.address.hamlet
                } elseif  ($null -ne $locInfo.address.suburb) {
                    $address = $locInfo.address.suburb
                } elseif  ($null -ne $locInfo.address.municipality) {
                    $address = $locInfo.address.municipality
                } elseif  ($null -ne $locInfo.address.road) {
                    $address = $locInfo.address.road
                } elseif  ($null -ne $locInfo.address.state) {
                    $address = $locInfo.address.state
                } else {
                    # there is no geo information for these coordinates
                    $address = "{0}, {1}" -f (DecimalToDegree $lat 'B'), (DecimalToDegree $lon 'L')
                } 
                Write-Verbose "location for lat=$lat, lon=$lon is $address"
              return [ExifDataSet]::new($path, $lat, $lon, $GPSAlt[0].Value, (CheckTranslate $locInfo.address.country), (CheckTranslate $address), $dateStr, $monthYear, $time, $orientation, ($image.height), ($image.width), $fileHash)
            } else {
                Write-Verbose "EXIF data dpresenet, but no location data"
                return [ExifDataSet]@{
                    path          = $path
                    lat           = 0
                    lon           = 0
                    alt           = 0
                    country       = ''
                    place         = ''
                    date          = $dateStr
                    monthYear     = $monthYear
                    time          = $time
                    orientation   = 0
                    height        = $image.height
                    width         = $image.width
                    validLocation = $false
                    fileHash      = $fileHash
                }
            }
        } # try to read and convert EXIF data
        catch {
            Write-Warning "ERROR converting EXIF data from $imagePath, error message was`r`n $($_.Exception.Message)"
        }
    } else {
        # image doesn't contain EXIF data, so use file create date
        try {
            $fileCreationDate = (Get-item -Path $path).CreationTime
            $dateStr   = $fileCreationDate.ToString('yyyy-MM-dd HH:mm:ss')
            $monthYear = $fileCreationDate.ToString('MMMM yyyy')   
            $time      = $fileCreationDate.ToShortTimeString()
        } 
        catch {
            $dateStr   = ''
            $monthYear = ''   
            $time      = ''
        }
        return [ExifDataSet]@{
            path          = $path
            lat           = 0
            lon           = 0
            alt           = 0
            country       = ''
            place         = ''
            date          = $dateStr
            monthYear     = $monthYear
            time          = $time
            orientation   = 0
            height        = $image.height
            width         = $image.width
            validLocation = $false
            fileHash      = $fileHash
        }
    }
}

# create a semicolon-separated text file containing GPS date and location information for all processed pictures
# if the translationFile script parameter is given but the translation file does not yet exist,
# also creates this file, so that the user can later edit it
# parameters:
#   sourcePath      path containing the picture files to analyze
#   inputFiles      array of filenames of the files to be analyzed
#   gpsFile         name of the file mapping file names to GPS information read from their EXIF data
#   translationFile name of translation file if specified
# returns nothing, but writes a text file, and optionally a translation file
function WriteGpsFile ([ExifDataSet[]]$imageData, [string]$gpsFile, [string]$translationFile) {
    if (-not $script:newGpsEntries -or '' -eq $gpsFile) {
        Write-Verbose "GPS file unchanged or not given, so skip"
        return
    }
    $count = 0 # for progress bar
    '#path;date;orientation;latitude;longitude;altitude;country;place;pxheight;pxwidth;fileHash' | Out-File $gpsFile -Force -Encoding utf8
    # iterate through all images' EXIF data,
    $imageData | Sort-Object path | ForEach-Object {
        $count++
        Write-Progress -Id 1 -PercentComplete $($count * 100 / $imageData.Count) -Status "$imageFileName ($count of $($imageData.Count))" -Activity 'creating GPS file'
        Write-Verbose "Creating GPS file entry for $($_.path)"
        # write entry into text file, the file contains the following fields:
        #   path;date;orientation;latitude;longitude;altitude;country;place;imageheight;imagewidth;fileHash
        #     0       1       2     3         4         5         6       7        8       9        10
        $_.path,$_.date,$_.orientation,$_.lat,$_.lon,$_.alt,$_.country,$_.place,$_.height,$_.width, $_.fileHash -join ";" | Out-File $gpsFile -Append -Encoding utf8
    }
    Write-Progress -Id 1 -Activity 'creating GPS file' -Completed
}
function WriteTranslationFile ([string]$translationFile) {
    # only wrte file if we have new entries
    if (-not $script:translation.containsvalue('«new»')) {
        return
    }
    # write the original entries first, sorted alphabetically
    # the second <placename> may then be edited by the user
    '#GPS name;translated name' | Out-File $translationFile -Force -Encoding utf8
    foreach ($original in ($translation.Keys | Sort-Object)) {
        if ($script:translation[$original] -ne '«new»') {
            "$original;$($script:translation[$original])" | Out-File $translationFile -Append -Encoding utf8
        }
    }
    # now write the new entries in the format <placename>;<placename>
    # the second <placename> may then be edited by the user
    "#new entries created $(Get-Date)" | Out-File $translationFile -Append -Encoding utf8
    foreach ($original in ($script:translation.Keys | Sort-Object)) {
        if ($script:translation[$original] -eq '«new»') {
            "$original;$original" | Out-File $translationFile -Append -Encoding utf8
        }
    }
}    

# read all JPG files in a given folder and collect their EXIF data into an array
# if a file doesn't have EXIF data, use the OS file creation date
# reads GPS file if given and skips double entries
function GetSourceFileData ([string] $sourceFolder, [string] $gpsFile, [bool] $recurse) {
    $ExifData = @{}  # hashtable of EXIF data, indexed by file hash
    $count = 0             # for progress bar
    # names of files to extract EXIF data
    if ($recurse) {
        Write-Verbose "reading files from folder $sourceFolder and subfolders"
        $sourceFileNames = (Get-ChildItem $sourceFolder\* -Recurse -File -Include '*.jpeg','*.jpg' | Select-Object -Property FullName).FullName | Where-Object -FilterScript {$_ -like '*.jpg' -or $_ -like '*.jpeg'}
    } else {
        $sourceFileNames = (Get-ChildItem $sourceFolder\* -File -Include '*.jpeg','*.jpg' | Select-Object -Property FullName).FullName | Where-Object -FilterScript {$_ -like '*.jpg' -or $_ -like '*.jpeg'}
    }
    Write-Verbose "$($sourceFileNames.count) file names read."
    $script:newGpsEntries = $false
    # check if GPS file given and existing
    if ('' -ne $gpsFile -and (Test-Path $gpsFile)) {
        # yes, so pre-populate hashtable with data from pictures
        # which we have read in a previous run
        $gpsLines = Get-Content -Path $gpsFile -Encoding utf8
        $gpsLines | ForEach-Object {
            if ($_ -ne '' -and $_[0] -ne '#') {
                $data = @($_ -split ';')
                $path = $data[0]
                $exifLine = $data[1..9] -join ';'
                $hash = $data[10]

                if ('' -ne $hash) {
                    Write-Verbose "[$hash] <-- $exifLine (existing)"
                    $ExifData["$hash"] = [ExifDataSet]::new("$path;$exifLine;$hash")
                }
            }
        }
    }
    # now iterate all image files, except those whith existing entries
    $changedCounter = 0
    $sourceFileNames | ForEach-Object {
        $count++
        $changedCounter++
        Write-Verbose "analysing $count ($_)"
        if ($changedCounter % 100 -eq 0) {
            # dump tranlation and GPS files every 100 images
            # to preserve some data in case the script is aborted
            Write-Verbose "dumping data at count $count"
            WriteGpsFile $ExifData.Values $gpsFile $script:translationFile
            WriteTranslationFile $script:translationFile
        }
        $hash = (Get-FileHash -Path $_).Hash
        if ($ExifData.Keys -notcontains $hash) {
            if ($_.Length -ge 50) {
                $displayString = '...' + $_.Substring($_.Length-47)
            } else {
                $displayString = $_
            }
            Write-Progress -Id 1 -PercentComplete $($count * 100 / $sourceFileNames.Count) -Status " from $displayString ($count of $($sourceFileNames.Count))" -Activity 'getting EXIF data'
            $imageExifData = (Get-ExifData $_)
            if ($null -ne $imageExifData) {
                $script:newGpsEntries = $true
                Write-Verbose "[$_] <-- $_;$imageExifData"
                $ExifData[$hash] += $imageExifData
            }
        }
    }
    Write-Progress -Id 1 -Activity 'getting EXIF data' -Completed
    return $ExifData.Values | Sort-Object -Property date
}

# if a translation file exists, load it into a hash table
function LoadTranslationFile ([string] $translationFile) {
    if (Test-Path $translationFile) {
        foreach ($line in Get-Content -Path $translationFile -Encoding utf8) {
            if ('' -ne $line -and $line[0] -ne '#') {
                try {
                    $orig, $trans = $line -split ';'
                    $script:translation[$orig] = $trans
                }
                catch {
                    throw "error in translation file '$translationFile'. Line '$line' must be in format original;translation, e.g. '中国;China'."
                }
            }
        }
    } else {
        $script:translation = @{}
    }
}

# translate a string according to the translation table
# parameters:
#   text    the text to be translated
# returns translated text, or unchanged text if there is no entry for it
# if there is no entry in the translation table, create one
function CheckTranslate ([string] $text) {
    if ($text -eq '') {return}
    # check whether entry exists, is not a new entry
    $transText = $script:translation[$text];
    if ($null -ne $transText -and $transText -ne '«new»') {
        return $transText
    } else {
        # add entry if not already result of a translation
        if ($script:translation.Values -notcontains $text) {
            $script:translation[$text] = '«new»'
        }
        return $text
    }
}

# the script may give auto-generated names for files, which are based on data fields like
# date, place names, etc. These names are then appended with a four-digit counter
# to make them unique
# parameters:
#   exifData        the data set which is used to calculate the new filename
#   renameFormat    a string with field placeholders. Characters not being placeholders
#                   will appear in the filename
# returns new filename, preserving path and extension
function RenamedFilePath ([ExifDataSet] $exifData, [string] $renameFormat, [string] $destinationPath) {
    if ($renameFormat -match ',|;|\*|\"|\/|\\|\<|\>|\:|\||\?') {
        throw ("illegal character in renameFormat $renameFormat. Use only characters allowed in file names")
    }
    # construct strings for the -f operator, e.g if we want a filename like 'year-place', then the format string should
    # be '{0}-{4}'
    $replaceTable = @{
        '!year'    = '{0}'
        '!yy'      = '{1}'
        '!month'   = '{2}'
        '!day'     = '{3}'
        '!place'   = '{4}'
        '!country' = '{5}'
    }

    $textFormatString = $renameFormat
    $replaceTable.GetEnumerator() | ForEach-Object {
        $textFormatString = $textFormatString -replace $_.Key,$_.Value
    }
     # preserve the extension
    $ext = Split-Path $exifData.path -Extension
    # create file name classifier (e.g. '2025-Rome', taking above example)
    if ('' -ne $exifData.date) {
        $filename = $textFormatString -f `
            $exifData.date.Substring(0,4), `
            $exifData.date.Substring(2,2), `
            $exifData.date.Substring(5,2), `
            $exifData.date.Substring(8,2), `
            $exifData.place, $exifData.country
    } else {
        $filename = $textFormatString -f `
            '', `
            '', `
            '', `
            '', `
            $exifData.place, $exifData.country
    }
    # now, generate a counter. Counters start at 1 for each individual file name classifier
    if ($script:renameCounterTable.Keys -contains $filename) {
        # another filename with this classifier already exists, so increment counter
        $script:renameCounterTable[$filename]++
    } else {
        # we have not yet seen a filename with this classifier, so start with 1
        $script:renameCounterTable[$filename] = 1
    }
    # add the counter the filename as four-digit zero-padded value
    $filename += "{0:d3}" -f ($script:renameCounterTable[$filename])
    $filename = $filename -replace '-{2,}','-'
    Write-Verbose "renaming $originalPath to $filename.$ext using format $renameFormat"
    # return filename including path and extension
    return "$destinationPath\$filename$ext"
}

# EXIF data gives us decimal values, e.g. 41.9019961, but we want
# to display degrees, minutes, and seconds, e.g. 41°54'7" N
# EXIF gives negative values for western longitudes and southern latitudes 
# parameters:
#   angle       latitude or longitude as decimal
#   orientation 'B' for latitude, 'L' for longitude. This is necessary
#               to add the correct quadrant letter (one of N E S W)
# returns string with degrees, minutes, seconds, and quadrant letter
function DecimalToDegree([double] $angle, [char] $orientation = ' ') {
    $s = $angle
    $angle = [math]::Abs($angle)
    $deg = [math]::Floor($angle)
    $angle -= $deg
    $angle *= 60
    $min = [math]::Floor($angle)
    $angle -= $min
    $angle *= 60
    $sec = [math]::Floor($angle)
    $val = "{0}°{1}'{2}""" -f $deg,$min,$sec
    switch ($orientation) {
        'B'  {
            if ($s -gt 0) {
                $val += 'N'
            } else {
                $val += 'S'
            }
        }
        'L'  {
            if ($s -gt 0) {
                $val += 'E'
            } else {
                $val += 'W'
            }
        }
    }
    return $val
}

# user wants only certain portions of the EXIF data written into the picture
# parameters:
#   exifData    the date read from the picture file
#   textFormat  a string detailing which parts of the EXIF data and other letters
#               should constitute the text written into the picture file
# returns a string where placeholders in the textformat string are replaced by the
# actual data while other parts are preserved unchanged, e.g. a string like
# 'Place:!place-!country(c) by Me' returns a string like 'Place:Roma-Italy(c) by Me'
# note that textFormat may be empty, or that the exif location date may be invalid
function ExifToText ([ExifDataSet] $exifData, [string] $textFormat) {
    # textFormat may be empty, i.e. user does not want to add text,
    # but maybe the file should be renamed, so process this file anyway
    if ('' -eq $textFormat) {
        return ''
    }
    # prepare format string
    $replaceTable = @{
        '!file'      = '{0}'
        '!date'      = '{1}'
        '!orien'     = '{2}'
        '!lat'       = '{3}'
        '!lon'       = '{4}'
        '!alt'       = '{5}'
        '!country'   = '{6}'
        '!place'     = '{7}'
        '!monthyear' = '{8}'
        '!time'      = '{9}'
    }
    # the last 'replace' deals with special case: user may have used a format like "...!date (!place)...",
    # resulting in a string like "03.03.2025 ()", so we remove possible empty parentheses
    $textFormatString = $textFormat
    $replaceTable.GetEnumerator() | ForEach-Object {
        $textFormatString = $textFormatString -replace $_.Key,$_.Value
    }
    $text = $textFormatString -f `
                (Split-Path -Path $exifData.path -Leaf), `
                ($exifData.date.Substring(0, 10) -replace ':','-') , `
                $exifData.orientation, `
                (DecimalToDegree $exifData.lat 'B'), `
                (DecimalToDegree $exifData.lon 'L'), `
                ([int] $exifData.alt), `
                $exifData.country, `
                $exifData.place, `
                $exifData.monthYear, `
                $exifData.time
    return ($text -replace '\(\)','')

}

# writes a text string into a picture file
# parameters:
#   sourceImageFileName name of the picture file
#   exifData            data extracted from the picture file
#   destinationFolder   folder where the annotated picture will be placed
#   textFormat          string specifying which EXIF data will be written into the picture.
#   maxTextPercent      maximal length of the text in relation to the picture width
# returns nothing, but writes a picture file into the destination folder
# if the textformat or the resulting text are empty, nothing is added to the image
#function AddExifDataToImage ([string] $sourceImageFolder, [string] $sourceImageFileName, [ExifDataSet] $exifData, [string] $destinationFolder, [string] $textFormat, [int] $maxTextPercent) {
function AddExifDataToImage ([ExifDataSet] $exifData, [string] $destinationFolder, [string] $textFormat, [int] $maxTextPercent) {
    if ('' -ne $textFormat) {
        $text = ExifToText $exifData $textFormat
    } else {
        $text = ''
    }
    # ignore if file does not exist
    if (-not (Test-Path $exifData.path)) {
        Write-Verbose "AddExifDataToImage skipped as source $($exifData.path) does not exist"
        return
    }
    Write-Verbose "AddExifDataToImage for $($exifData.path) text=$textformat..."
    if ($renameFormat -ne '') {
        $destinationImagePath = RenamedFilePath $exifData $renameFormat $destinationFolder
        Write-Verbose "file $($exifData.path) will be renamed to $destinationImagePath"
    }
    try {
        $bitmap = [System.Drawing.Bitmap]::FromFile($exifData.path)
    }
    catch {
        Write-Verbose "bitmap creation failed with exception`r`n $($_.Exception.Message)"
        return
    }
    if ('' -ne $text) {
        Write-Verbose "writing $text on file $($exifData.path) with destination $destinationImagePath"
        # Create a graphics object
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)

        # Define font, text, and position
        $fontSize = 100 # initial value
        $font = New-Object System.Drawing.Font("Arial", $fontSize, [System.Drawing.FontStyle]::Bold)
        $imageWidth = $graphics.VisibleClipBounds.Width
        $textWidth = ($graphics.MeasureString($text, $font, 100000)).Width
        #redefine font with adjusted size    
        if ($textWidth -gt ($maxTextPercent * $imageWidth / 100)) {
            $fontSize = [math]::Floor($maxTextPercent * $imageWidth / $textWidth)
        }
        $font = New-Object System.Drawing.Font("Arial", $fontSize, [System.Drawing.FontStyle]::Bold)
        $brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::Yellow)
        $position = New-Object System.Drawing.PointF($0, 0)

        # Draw the information text on the image
        $graphics.DrawString($text, $font, $brush, $position)
        $graphics.Dispose()
    } else {
        Write-Verbose "no text to add"
    }
    try {
        # Save the modified image
        Write-Verbose "writing file $($exfData.path) to $destinationImagePath"
        $bitmap.Save($destinationImagePath, [System.Drawing.Imaging.ImageFormat]::Jpeg)
    }
    catch {
        "image $destinationImagePath could not be saved, probably source and destination folders are the same, error message was`r`n $($_.Exception.Message)"
        return
    }
    finally {
        $bitmap.Dispose()
    }
}

# if the user has edited the translation file, then it can be run against the GPS file,
# replacing all place names with their translated versions
function ApplyTranslationToGpsFile ([string] $gpsFile, [string] $translationFile) {
    $translatedGpsText = @()
    foreach ($line in (Get-Content -Path $gpsFile -Encoding utf8)) {
        $exifData = ($line -split ';')
        $exifData[7] = CheckTranslate $exifData[7] # country
        $exifData[8] = CheckTranslate $exifData[8] # place
        $translatedGpsText += ($exifData -join ';')
    }
    $translatedGpsText | Out-File $gpsFile -Force  -Encoding utf8
}

# apply the data in the GPS file to the picture files
# parameters:
#   gpsFilePath         path and name of GPS file
#   destinationFolder   folder where the annotated picture is written to
#   textFormat          template specifying the format of the text which will
#                       be written into the picture
#   maxTextPercent      max width of the text in relation to the picture width
# returns   nothing, but writes a picture file into the destination folder
function ApplyGpsFile ([string] $gpsFilePath, [string] $destinationFolder, [string] $textFormat, [int] $maxTextPercent) {
    $count = 0
    $exifData = @()
    try {
        foreach ($line in (Get-Content -Path $gpsFilePath -Encoding utf8)) {
            if ($line -ne '' -and $line[0] -ne '#') {
                $exifData += [ExifDataSet]::new("$line")
            } # if line not empty
        }
        Write-Verbose "GPS file read. EXIF data contains $($exifData.count) records."
    }
    catch {
        "GPS file $gpsFilePath not found, aborting program" | Out-Host
        exit
    }
    $exifData | Sort-Object -Property date | ForEach-Object {
        $count++
        Write-Progress -Id 1 -PercentComplete $($count * 100 / $exifData.count) -Status "processing $($_.path) ($count of $($exifData.count))" -Activity 'processing GPS file'
        Write-Verbose "processing image $($_.path) ($count)"
        AddExifDataToImage $_ $destinationFolder $textFormat $maxTextPercent
    }
    Write-Progress -Id 1 -Activity 'processing GPS file' -Completed
    Write-Verbose "$count images processed."
}

# write EXIF data from pictures into the pictures directly, not using a GPS file
function Add-GpsLocationDirect ([string] $sourcePath, [ExifDataSet[]] $imageData, [string] $translationFile, [string] $destination, [string] $textFormat, [int] $maxTextPercent) {
    $count = 0
    $imageData | ForEach-Object {
        $count++
        Write-Progress -Id 1 -PercentComplete $($count * 100 / $imageData.Count) -Status "$_.path ($count of $($imageData.Count))" -Activity 'adding EXIF data to image'
        AddExifDataToImage $_ $destination $textFormat $maxTextPercent
    }
    Write-Progress -Id 1 -Activity 'adding EXIF data to image' -Completed
}

###############################################################################
#
# BEGIN MAIN
#
Add-Type -Assembly System.Drawing

# global variables
$translation = @{}
$newGpsEntries = $false
#[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'existModuleName', Justification = 'variable is used in another scope')]
$renameCounterTable = @{}

# initialize translation table
if ('' -ne $translationFile) {
    LoadTranslationFile $translationFile
}
# initialize the table we may need if we want to generate filenames automatically

Write-Verbose $PSCmdlet.ParameterSetName

switch ($PSCmdlet.ParameterSetName) {
    'CreateGpsFile' {
        LoadTranslationFile $translationFile
        $sourceFileData = GetSourceFileData $source $gpsFile $recurse
        Write-Verbose "Create GPS file $gpsFile from source $sourcePath, $($sourceFiles.Count) files to process"
        WriteTranslationFile $translationFile
        WriteGpsFile $sourceFileData $gpsFile $translationFile
        break
    }
    'ApplyTranslationToGpsFile' {
        LoadTranslationFile $translationFile
        Write-verbose "Apply translation file $translationFile to GPS file $gpsfile"
        ApplyTranslationToGpsFile $gpsFile $translationFile
        break
    }
    'ApplyGpsFile' {
        LoadTranslationFile $translationFile
        Write-verbose "Apply GPS file $gpsfile and translation file $translationFile, writing images to $destination"
        ApplyGpsFile $gpsFile $destination $textFormat $maxTextPercent
        break
    }
    'AddGpsLocationDirect' {
        $sourceFileData = GetSourceFileData $source '' $recurse
        Add-GpsLocationDirect $source $sourceFileData $translationFile $destination $textFormat $maxTextPercent
        break
    }
}
