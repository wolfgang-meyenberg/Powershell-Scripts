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
If the source, gpsFile and translationFile parameters are given but no translation file exists, a new file is created containing all detected place names. If the translation file exists, it will not be changed.
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

Example: the default value '!place (!country) !monthyear' will result in '北京(中国) 2023-06-23' and 'Roma (Italia) 2025-01-30'

.PARAMETER maxTextPercent
Maximum width of the text in percent of the image width. If text would be longer than specified, the font size will be reduced. The default value is 75.

.PARAMETER renameFormat
When this parameter is NOT given, the destination file name is the same as the source file name.
If this parameter is given,the file name is defined by the specified place holders. Note that the resulting string must not contain characters which are forbidden in file names!
Allowed placeholders are:
    y   year (four digits)
    m   month (two digits)
    d   day (two digits)
    p   placename (see above comment on forbidden characters)
    c   country (see above comment on forbidden characters)
    A four-digit counter is added to any filename thus generated.

Example: the renameFormat 'y-m-' results in filenames like '2023-06-0001.jpg' and '2025-01-0001.jpg'

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
The picture annotations have the format "placename (country), monthname year", e.g. "Rome (Italy), January 2025", and they shall not occupy more than 60% of the picture's width.
Furthermore, we want the images to be named like <country>-<year><month>-####.jpg, #### being a counter
Add-GpsToImages -gpsFile c:\source\gps.txt -translationFile c:\source\translate.txt -destination c:\destination -textFormat '!place (!country), !monthyear -maxTextPercent 60 -renameFormat 'c-m-'

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
    [string] $textFormat = '!place (!country) !monthyear',

    [Parameter(ParameterSetName="AddGpsLocationDirect", HelpMessage="max text size in % of image width")]
    [Parameter(ParameterSetName="ApplyGpsFile", HelpMessage="max text size in % of image width")]
    [int] $maxTextPercent = 75,

    [Parameter(ParameterSetName="AddGpsLocationDirect", `
        HelpMessage="rename file, use y,m,d,p,c as placeholders for year, month, day, place, country. Do not include characters not valid for filenames")]
    [Parameter(ParameterSetName="ApplyGpsFile", `
        HelpMessage="rename file, use y,m,d,p,c as placeholders for year, month, day, place, country. Do not include characters not valid for filenames")]
    [string] $renameFormat
)

# a record of the GPS data which we get as EXIF information in usable format
class GpsData {
    [double]    $lat
    [double]    $lon
    [double]    $alt
    [string]    $country
    [string]    $place
    [datetime]  $date
    [string]    $monthYear
    [string]    $time
    [int]       $orientation
    GpsData([double]$lat, [double]$lon, [double]$alt, [string]$country, [string]$place, [datetime]$date, [int]$orientation) {
        lat	= $lat
        lon	= $lon
        alt	= $alt
        country	= $country
        place	= $place
        date	= $date
        $dt = [datetime]::ParseExact($date, 'yyyy:MM:dd HH:mm:ss',$null)
        monthYear   = $dt.ToString('MMMM yyyy')   
        time        = $dt.ToShortTimeString()
        orientation	= $orientation
    }
        #   Ctor splitting a string into data fields 
        #   A string read from a GPS file has the following format:
        #   path;filename;date;orientation;latitude;longitude;altitude;country;place
        #     0     1       2     3         4         5         6       7        8
        GpsData([string] $dataString) {
        $data = $dataString -split ';'
        $dateValue      = $data[2]
        $this.lat	    = [double]::Parse($data[4])
        $this.lon	    = [double]::Parse($data[5])
        $this.alt	    = [double]::Parse($data[6])
        $this.country	= $data[7]
        $this.place	    = $data[8]
        $dt = [datetime]::ParseExact($dateValue, 'yyyy:MM:dd HH:mm:ss',$null)
        $this.date	    = $dt
        $this.monthYear = $dt.ToString('MMMM yyyy')   
        $this.time      = $dt.ToShortTimeString()
        $this.orientation = [int]::Parse($data[3])
    }
}

# a record of GPS data as read from a picture's EXIF record
class ExifDataSet {
    [string] $fileName
    [double] $lat
    [double] $lon
    [double] $alt
    [string] $country
    [string] $place
    [string] $date
    [string] $monthYear
    [string] $time
    [int]    $orientation
    [bool]   $isValid

    # initializer setting object to a defined state in case no EXIF data was found
    hidden InitError() {
        $this.fileName    = ''
        $this.lat         = 0
        $this.lon         = 0
        $this.alt         = 0
        $this.country     = 'unknown'
        $this.place       = 'unknown'
        $this.date        = ''
        $this.monthYear   = ''
        $this.time        = ''
        $this.orientation = 0
        $this.isValid     = $false

    }
    # default Ctor
    ExifDataSet () {
        $this.InitError()
    }
    # Ctor initializing object with EXIF data already given as fields
    ExifDataSet ( [string] $fileName, [double] $lat, [double] $lon, [double] $alt, [string] $country, [string] $place, [string] $date, [string] $monthYear, [string] $time, [int] $orientation ) {
        try {
            $this.fileName    = $fileName
            $this.lat         = $lat
            $this.lon         = $lon
            $this.alt         = $alt
            $this.country     = $country
            $this.place       = $place
            $this.date        = $date
            $this.monthYear   = $monthYear
            $this.time        = $time
            $this.orientation = $orientation
            $this.isValid     = $true
        }
        catch {
            # reset object in case any conversion goes wrong,
            # because that means that the data is invalid
            $this.InitError()
        }
    }
    # Ctor initializing object with EXIF data given as semicolon-separated string
    ExifDataSet ( [string] $line ) {
        try {
            $data = @($line -split ';')
            $this.fileName    = $data[0]
            $this.lat         = [double]::Parse($data[3])
            $this.lon         = [double]::Parse($data[4])
            $this.alt         = [double]::Parse($data[5])
            $this.country     = $data[6]
            $this.place        = $data[7]
            $dt = [datetime]::ParseExact($data[1], 'yyyy:MM:dd HH:mm:ss',$null)
            $this.date        = $dt.ToString('yyyy-MM-dd')
            $this.monthYear   = $dt.ToString('MMMM yyyy')   
            $this.time        = $dt.ToShortTimeString()
            $this.orientation = [int]::Parse($data[2])
            $this.isValid     = $true
        }
        catch {
            # reset object in case any conversion goes wrong,
            # because that means that the data is invalid
            $this.InitZero
        }
    }    
}

# if a translation file exists, load it into a hash table
function LoadTranslationFile ([string] $translationFile) {
    if (-not (Test-Path $translationFile)) {
        return
    }
    foreach ($line in Get-Content -Path $translationFile) {
        if ('' -ne $line ) {
            try {
                $orig, $trans = $line -split ';'
                $script:translation[$orig] = $trans
            }
            catch {
                throw "error in translation file '$translationFile'. Line '$line' must be in format original;translation, e.g. '中国;China'."
            }
        }
    }
}

# translate a string according to the translation table
# parameters:
#   text    the text to be translated
# returns translated text, or unchanged text if there is no entry for it
function CheckTranslate ([string] $text) {
    $transText = $script:translation[$text];
    if ($null -ne $transText) {
        return $transText
    } else {
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
function RenamedFilePath ([ExifDataSet] $exifData, [string] $renameFormat, [string] $originalPath) {
    if ($renameFormat -match ',|;|\*|\"|\/|\\|\<|\>|\:|\||\?') {
        throw ("illegal character in renameFormat $renameFormat. Use only characters allowed in file names")
    }
    # construct strings for the -f operator, e.g if we want a filename like 'year-place', then the format string should
    # be '{0}-{3}'
    $textFormatString = $renameFormat -replace 'y','{0}' -replace 'm','{1}' -replace 'd','{2}'-replace 'p','{3}'-replace 'c','{4}'
    # preserve the file directory and extension
    $path = Split-Path $originalPath -Parent
    $ext = Split-Path $originalPath -Extension
    # create file name classifier (e.g. '2025-Rome', taking above example)
    $filename = $textFormatString -f `
        $exifData.date.Substring(0,4), `
        $exifData.date.Substring(5,2), `
        $exifData.date.Substring(8,2), `
        $exifData.place, $exifData.country
    # now, generate a counter. Counters start at 1 for each individual file name classifier
    if ($renameCounterTable.Keys -contains $filename) {
        # another filename with this classifier already exists, so increment counter
        $renameCounterTable[$fileName]++
    } else {
        # we have not yet seen a filename with this classifier, so start with 1
        $renameCounterTable[$fileName] = 1
    }
    # add the counter the filename as four-digit zero-padded value
    $filename += "{0:d3}" -f ($renameCounterTable[$fileName])
    Write-Verbose "renaming $originalPath to $filename using format $renameFormat"
    # return filename including path and extension
    return "$path\$filename$ext"
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
                $val += ' N'
            } else {
                $val += ' S'
            }
        }
        'L'  {
            if ($s -gt 0) {
                $val += ' E'
            } else {
                $val += ' W'
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
function ExifToText ([ExifDataSet] $exifData, [string] $textFormat) {
    # prepare format string
    $textFormatString = $textFormat -replace '!file','{0}' -replace '!date','{1}' -replace '!orien','{2}' `
                            -replace '!lat','{3}' -replace '!lon','{4}' -replace '!alt','{5}' `
                            -replace '!country','{6}' -replace '!place','{7}' -replace '!monthyear','{8}' `
                            -replace '!time','{9}'
    $text = $textFormatString -f `
                $exifData.fileName, `
                $exifData.date, `
                $exifData.orientation, `
                (DecimalToDegree $exifData.lat 'B'), `
                (DecimalToDegree $exifData.lon 'L'), `
                ([int] $exifData.alt), `
                $exifData.country, `
                $exifData.place, `
                $exifData.monthYear, `
                $exifData.time
    return $text
}

# writes a text string into a picture file
# parameters:
#   sourceImageFolder   folder where the picture file is located
#   sourceImageFileName name of the picture file
#   exifData            data extracted from the picture file
#   destinationFolder   folder where the annotated picture will be placed
#   textFormat          string specifying which EXIF data will be written into the picture.
#   maxTextPercent      maximal length of the text in relation to the picture width
# returns nothing, but writes a picture file into the destination folder
function AddExifDataToImage ([string] $sourceImageFolder, [string] $sourceImageFileName, [ExifDataSet] $exifData, [string] $destinationFolder, [string] $textFormat, [int] $maxTextPercent) {
    $text = ExifToText $exifData $textFormat
    $sourceImagePath = "$sourceImageFolder\$sourceImageFileName"
    $destinationImagePath = "$destinationFolder\$sourceImageFileName"
    try {
        $bitmap = [System.Drawing.Bitmap]::FromFile($sourceImagePath)
    }
    catch {
        return
    }
    Write-Verbose "writing $text on file $sourceImageFileName with destination $destinationFolder"
    # Create a graphics object
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)

    # Define font, text, and position
    $fontSize = 100 # initial value
    $font = New-Object System.Drawing.Font("Arial", $fontSize, [System.Drawing.FontStyle]::Bold)
    $imageWidth = $graphics.VisibleClipBounds.Width
    #$textWidth = ($graphics.MeasureString($text, $font, $imageWidth)).Width
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

    if ($renameFormat -ne '') {
        $destinationImagePath = RenamedFilePath $exifData $renameFormat $destinationImagePath
    }
    try {
        # Save the modified image
        $bitmap.Save($destinationImagePath, [System.Drawing.Imaging.ImageFormat]::Jpeg)
    }
    catch {
        "image $destinationImagePath could not be saved, probably source and destination folders are the same."
        exit
    }
    finally {
        # Dispose of graphics and bitmap objects
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

# read EXIF data from a picture file
# parameters:
#   imagePath   path and filename of the picture to read from
# returns EXIF data from picture. If EXIF data is not found or invalid,
# the field isValid will be $false
function Get-ExifData ([string] $imagePath) {
    try {
        $image = New-Object -ComObject Wia.ImageFile
        $image.LoadFile($imagePath)
        $orientation = ($image.properties | Where-Object -Property Name -eq 'Orientation').Value       
        $GPSLat = @(($image.Properties | Where-Object -Property Name -eq 'GpsLatitude').Value)
        $GPSLon = @(($image.Properties | Where-Object -Property Name -eq 'GpsLongitude').Value)
        $GPSAlt = @(($image.Properties | Where-Object -Property Name -eq 'GpsAltitude').Value)
        $DtString = @(($image.Properties | Where-Object -Property Name -eq 'DateTime').Value)
        $lat = $GPSLat[0].Value + $GPSLat[1].Value/60 + $GPSLat[2].Value/3600
        $lon = $GPSLon[0].Value + $GPSLon[1].Value/60 + $GPSLon[2].Value/3600
        $dt = [datetime]::ParseExact($DtString, 'yyyy:MM:dd HH:mm:ss',$null)
        if (@(($image.Properties | Where-Object -Property Name -eq 'GpsLatitudeRef').Value) -eq 'S') {
            $lat = -$lat
        }
        if (@(($image.Properties | Where-Object -Property Name -eq 'GpsLongitudeRef').Value) -eq 'W') {
            $lon = -$lon
        }
        if ($Lat -ne 0 -and $Lon -ne 0) {
            $r=Invoke-WebRequest -uri "https://nominatim.openstreetmap.org/reverse?lat=$lat&lon=$lon&format=json&namedetails=1"
            $locInfo = $r.RawContent -split '\r\n' | Where-Object ({$_ -like '{*'}) | ConvertFrom-Json
#        if ($null -eq $locInfo.error) {
            $address = ''
            if ($null -ne $locInfo.address.city) {
                $address = $locInfo.address.city
            } elseif  ($null -ne $locInfo.address.town) {
                $address = $locInfo.address.town
            } elseif  ($null -ne $locInfo.address.village) {
                $address = $locInfo.address.village
            } elseif  ($null -ne $locInfo.address.suburb) {
                $address = $locInfo.address.suburb
            } elseif ($null -ne $locInfo.error) {
                # there is no geo information for these coordinates
                $address = "{0}, {1}" -f (DecimalToDegree $lat 'B'), (DecimalToDegree $lon 'L')
            }
            Write-Verbose "location for lat=$lat, lon=$lon is $address"
            return [ExifDataSet]@{
                fileName    = ($imagePath -split '\\')[-1]
                lat         = $lat
                lon         = $lon
                alt         = $GPSAlt[0].Value
                country     = CheckTranslate $locInfo.address.country
                place       = CheckTranslate $address
                date        = $DtString[0]
                monthYear   = $dt.ToString('MMMM yyyy')
                time        = $dt.ToShortTimeString()
                orientation = $orientation
                isValid     = $true
            }
        }
        else {
            return [ExifDataSet]::new()
        }
    }
    catch {
        return [ExifDataSet]::new()
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
function CreateGpsFile ([string] $sourcePath, [string[]] $inputFiles, [string] $gpsFile, [string] $translationFile) {
    $count = 0 # for progress bar
    # write the header
    '#path;filename;date;orientation;latitude;longitude;altitude;country;place' | Out-File $gpsFile -Force

    # check whether we should also create a translation file
    $createTranslationFile = ($translationFile -ne '' -and -not (Test-Path $translationFile))
    if ($createTranslationFile) {
        Write-Verbose "translation file is speficied but does not exist, creating $translationFile"
        $translation = @{}
    }
    # iterate through all source pictures
    foreach ($imageFileName in $inputFiles) {
        $count++
        Write-Progress -Id 1 -PercentComplete $($count * 100 / $inputFiles.Count) -Status "$imageFileName ($count of $($inputFiles.Count))" -Activity 'getting EXIF data'
        $exifData = Get-ExifData "$sourcePath\$imageFileName"
        if ($exifData.isValid) {
            Write-Verbose "Creating GPS file entry for $imageFileName"
            # write entry into text file, the file contains the following fields:
            #   folder;filename;date;orientation;latitude;longitude;altitude;country;place
            #       0       1       2     3         4         5         6       7        8
            $sourcePath,$imageFileName,$exifData.date,$exifData.orientation,$exifData.lat,$exifData.lon,$exifData.alt,$exifData.country,$exifData.place -join ";" | Out-File $gpsFile -Append
            if ($createTranslationFile) {
                # record exactly one entry for each place name in a hashtable
                if (($exifData.country -ne '') -and ($translation.Keys -notcontains $exifData.country)) {
                    $translation[$exifData.country] = $exifData.country
                }
                if (($exifData.place -ne '') -and ($translation.Keys -notcontains $exifData.place)) {
                    $translation[$exifData.place] = $exifData.place
                }
            }
        } else {
            Write-Warning -message "$imageFileName - no EXIF data"             
        }
    }
    if ($createTranslationFile) {
        foreach ($entry in ($translation.Keys | Sort-Object)) {
            # write lines in the format <placename>;<placename> into the translation file.
            # the second <placename> may then be edited by the user
            "$entry;$entry" | Out-File $translationFile -Append
        } 
    }
    Write-Progress -Id 1 -Activity 'getting EXIF data' -Completed
}

# if the user has edited the translation file, then it can be run against the GPS file,
# replacing all place names with their translated versions
function ApplyTranslationToGpsFile ([string] $gpsFile, [string] $translationFile) {
    $translatedGpsText = @()
    foreach ($line in (Get-Content -Path $gpsFile)) {
        foreach ($key in $translation.Keys) {
            $line = $line -replace $key,$translation[$key]
        }
        $translatedGpsText += $line
    }
    $translatedGpsText | Out-File $gpsFile -Force
}

# apply the data in the GPS file to the picture files
# parameters:
#   gpsFilePath         path and name of source file
#   destinationFolder   folder where the annotated picture is written to
#   textFormat          template specifying the format of the text which will
#                       be written into the picture
#   maxTextPercent      max width of the text in relation to the picture width
# returns   nothing, but writes a picture file into the destination folder
function ApplyGpsFile ([string] $gpsFilePath, [string] $destinationFolder, [string] $textFormat, [int] $maxTextPercent) {
    try {
        $lineCount = (Get-Content $gpsFilePath -ErrorAction Stop | Measure-Object -Line).Lines
    }
    catch {
        "GPS file $gpsFilePath not found, aborting program" | Out-Host
        exit
    }
    $count = 0
    foreach ($line in (Get-Content -Path $gpsFilePath)) {
        $count++
        if ($line -ne '' -and $line[0] -ne '#') {
            $folder, $filename, $exifLine = $line -split ';', 3
            Write-Progress -Id 1 -PercentComplete $($count * 100 / $lineCount) -Status "$filename ($count of $lineCount))" -Activity 'processing GPS file'
            $exifLine = "$filename;$exifLine"
            $exifData = [ExifDataSet]::new($exifLine)
            if ($exifData.isValid) {
                Write-Verbose "applying GPS file entry: $line"
                AddExifDataToImage $folder $filename $exifData $destinationFolder $textFormat $maxTextPercent
            } else {
                Write-Warning -message "$imageFileName - no EXIF data" 
            }
        } # if line not empty
    }
    Write-Progress -Id 1 -Activity 'processing GPS file' -Completed
}

# write EXIF data from pictures into the pictures directly, not using a GPS file
function AddGpsLocationDirect ([string] $sourcePath, [string[]] $sourceFiles, [string] $translationFile, [string] $destination, [string] $textFormat, [int] $maxTextPercent) {
    $count = 0
    foreach ($imageFileName in $sourceFiles) {
        $count++
        Write-Progress -Id 1 -PercentComplete $($count * 100 / $sourceFiles.Count) -Status "$imageFileName ($count of $($sourceFiles.Count))" -Activity 'adding EXIF data to image'
        $exifData = Get-ExifData "$sourcePath\$imageFileName"
        if ($exifData.lat -ne 0) {
            AddExifDataToImage $sourcePath $imageFileName $exifData $destination $textFormat $maxTextPercent
        }
    }
    Write-Progress -Id 1 -Activity 'adding EXIF data to image' -Completed
}

###############################################################################
#
# BEGIN MAIN
#

Add-Type -Assembly System.Drawing

# initialize translation table
$translation = @{}
if ('' -ne $translationFile) {
    LoadTranslationFile $translationFile
}
# initialize the table we may need if we want to generate filenames automatically
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'existModuleName', Justification = 'variable is used in another scope')]
$renameCounterTable = @{}

Write-Verbose $PSCmdlet.ParameterSetName

switch ($PSCmdlet.ParameterSetName) {
    'CreateGpsFile' {
        $sourcePath = Split-Path $source -Parent | Resolve-Path
        $sourceFiles = (Get-ChildItem $sourcePath -File | Select-Object -Property Name).Name | Where-Object -FilterScript {$_ -like '*.jpg' -or $_ -like '*.jpeg'}
        CreateGpsFile $sourcePath $sourceFiles $gpsFile $translationFile
        break
    }
    'ApplyTranslationToGpsFile' {
        ApplyTranslationToGpsFile $gpsFile $translationFile
        break
    }
    'ApplyGpsFile' {
        ApplyGpsFile $gpsFile $destination $textFormat $maxTextPercent
        break
    }
    'AddGpsLocationDirect' {
        $sourcePath = Split-Path $source -Parent | Resolve-Path
        $sourceFiles = (Get-ChildItem $sourcePath -File | Select-Object -Property Name).Name
        AddGpsLocationDirect $sourcePath $sourceFiles $translationFile $destination $textFormat $maxTextPercent
        break
    }
}
"DONE."