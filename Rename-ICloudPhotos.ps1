<#
.SYNOPSIS
    Renames iCloud photos & videos using GPS location + date-taken metadata.

.DESCRIPTION
    1. Reads EXIF / metadata from every image and video via ExifTool.
    2. Reverse-geocodes GPS coordinates → Country, City, etc.
    3. Files without GPS inherit location from the nearest file in time (gap-fill).
    4. Renames to:  {Country}_{City}_{yyyy-MM-dd}_{HH-mm-ss-fff}.ext
    5. Converts HEIC files to JPG, moves originals to heic/ backup folder.
    6. Fixes file Created / Modified timestamps to DateTimeOriginal.

.NOTES
    Requires:  ExifTool       (https://exiftool.org)
    Requires:  ImageMagick    (https://imagemagick.org)  — for HEIC→JPG conversion
    Config:    config.json  /  config.local.json  (local overrides, git-ignored)

.EXAMPLE
    .\Rename-ICloudPhotos.ps1                         # dry-run (default)
    .\Rename-ICloudPhotos.ps1 -Apply                   # actually rename + convert
    .\Rename-ICloudPhotos.ps1 -InputFolder "D:\pics"   # override folder
    .\Rename-ICloudPhotos.ps1 -SkipGeocoding           # skip reverse geocoding
#>

[CmdletBinding()]
param(
    [string]$InputFolder,
    [string]$ConfigPath,
    [switch]$Apply,
    [switch]$SkipGeocoding,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ─────────────────────────────────────────────
# CONFIGURATION
# ─────────────────────────────────────────────
# PS 5.1 does not have ConvertFrom-Json -AsHashtable, so we convert manually
function ConvertTo-Hashtable {
    param([Parameter(ValueFromPipeline)]$InputObject)
    process {
        if ($null -eq $InputObject) { return @{} }
        if ($InputObject -is [System.Collections.Hashtable]) { return $InputObject }
        if ($InputObject -is [string] -or $InputObject -is [ValueType]) { return $InputObject }
        $ht = @{}
        foreach ($prop in $InputObject.PSObject.Properties) {
            $val = $prop.Value
            if ($null -eq $val -or $val -is [string] -or $val -is [ValueType]) {
                # primitives — keep as-is
            } elseif ($val -is [PSCustomObject]) {
                $val = $val | ConvertTo-Hashtable
            } elseif ($val -is [System.Collections.IEnumerable]) {
                $val = @($val | ForEach-Object {
                    if ($_ -is [PSCustomObject]) { $_ | ConvertTo-Hashtable } else { $_ }
                })
            }
            $ht[$prop.Name] = $val
        }
        return $ht
    }
}

function Load-Config {
    $scriptDir = $PSScriptRoot
    $default   = Join-Path $scriptDir 'config.json'
    $local     = Join-Path $scriptDir 'config.local.json'

    $cfg = @{}
    if (Test-Path $default) {
        $cfg = Get-Content $default -Raw | ConvertFrom-Json | ConvertTo-Hashtable
    }
    if (Test-Path $local) {
        $override = Get-Content $local -Raw | ConvertFrom-Json | ConvertTo-Hashtable
        foreach ($k in $override.Keys) { $cfg[$k] = $override[$k] }
    }
    # Remove comment keys
    @($cfg.Keys | Where-Object { $_ -like '//*' }) | ForEach-Object { $cfg.Remove($_) }
    return $cfg
}

$cfg = Load-Config

# CLI overrides
if ($InputFolder)  { $cfg['inputFolder']  = $InputFolder }
if ($ConfigPath)   { $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json | ConvertTo-Hashtable }
if ($Apply)        { $cfg['dryRun'] = $false }

# Defaults for anything missing
if (-not $cfg.ContainsKey('dryRun'))                { $cfg['dryRun'] = $true }
if (-not $cfg.ContainsKey('exiftoolPath'))          { $cfg['exiftoolPath'] = 'exiftool' }
if (-not $cfg.ContainsKey('imageMagickPath'))       { $cfg['imageMagickPath'] = 'magick' }
if (-not $cfg.ContainsKey('nominatimEmail'))         { $cfg['nominatimEmail'] = 'user@example.com' }
if (-not $cfg.ContainsKey('nominatimDelaySec'))      { $cfg['nominatimDelaySec'] = 1.1 }
if (-not $cfg.ContainsKey('geocodeCache'))           { $cfg['geocodeCache'] = $true }
if (-not $cfg.ContainsKey('nameTemplate'))           { $cfg['nameTemplate'] = '{country}_{city}_{date}_{time}' }
if (-not $cfg.ContainsKey('dateFormat'))             { $cfg['dateFormat'] = 'yyyy-MM-dd' }
if (-not $cfg.ContainsKey('timeFormat'))             { $cfg['timeFormat'] = 'HH-mm-ss-fff' }
if (-not $cfg.ContainsKey('unknownLocation'))        { $cfg['unknownLocation'] = 'Unknown' }
if (-not $cfg.ContainsKey('gapFillMaxMinutes'))      { $cfg['gapFillMaxMinutes'] = 180 }
if (-not $cfg.ContainsKey('fixTimestamps'))          { $cfg['fixTimestamps'] = $true }
if (-not $cfg.ContainsKey('organizeIntoSubfolders')) { $cfg['organizeIntoSubfolders'] = $false }
if (-not $cfg.ContainsKey('subfolderTemplate'))      { $cfg['subfolderTemplate'] = '{country}\{city}' }
if (-not $cfg.ContainsKey('sanitizeChars'))          { $cfg['sanitizeChars'] = $true }
if (-not $cfg.ContainsKey('convertHeicToJpg'))       { $cfg['convertHeicToJpg'] = $true }
if (-not $cfg.ContainsKey('heicBackupFolder'))       { $cfg['heicBackupFolder'] = 'heic' }
if (-not $cfg.ContainsKey('jpgQuality'))             { $cfg['jpgQuality'] = 95 }
if (-not $cfg.ContainsKey('imageExtensions'))        {
    $cfg['imageExtensions'] = @('.jpg','.jpeg','.png','.heic','.heif','.tiff','.tif','.gif','.bmp','.webp','.cr2','.cr3','.arw','.dng','.raf','.nef','.orf','.rw2')
}
if (-not $cfg.ContainsKey('videoExtensions'))        {
    $cfg['videoExtensions'] = @('.mov','.mp4','.m4v','.avi','.3gp','.mts')
}

$allExtensions = $cfg['imageExtensions'] + $cfg['videoExtensions']
$heicExtensions = @('.heic', '.heif')

# Validate input folder
if (-not $cfg['inputFolder'] -or -not (Test-Path $cfg['inputFolder'])) {
    Write-Error "Input folder not found: '$($cfg['inputFolder'])'.`nSet 'inputFolder' in config.local.json or pass -InputFolder."
    return
}

$inputDir = (Resolve-Path $cfg['inputFolder']).Path
Write-Host "`n=== iCloud Photo Renamer ===" -ForegroundColor Cyan
Write-Host "Folder : $inputDir"
Write-Host "Mode   : $(if ($cfg['dryRun']) { 'DRY-RUN  (preview only - use -Apply to execute)' } else { 'APPLY  (will rename, convert, and move!)' })"
Write-Host ""

# ─────────────────────────────────────────────
# TOOL CHECKS
# ─────────────────────────────────────────────
function Test-ExifTool {
    try {
        $null = & $cfg['exiftoolPath'] -ver 2>&1
        return $true
    } catch {
        Write-Error @"
ExifTool not found.  Please:
  1. Download from https://exiftool.org
  2. Rename exiftool(-k).exe -> exiftool.exe
  3. Place it next to this script  OR  add to PATH.
  Or set 'exiftoolPath' in config.local.json to the full path.
"@
        return $false
    }
}

function Test-ImageMagick {
    try {
        $null = & $cfg['imageMagickPath'] --version 2>&1
        return $true
    } catch {
        Write-Warning @"
ImageMagick not found - HEIC to JPG conversion will be skipped.
  Install:  choco install imagemagick
  Or download from https://imagemagick.org
  Or set 'imageMagickPath' in config.local.json to the full path.
"@
        return $false
    }
}

if (-not (Test-ExifTool)) { return }

$canConvertHeic = $false
if ($cfg['convertHeicToJpg']) {
    $canConvertHeic = Test-ImageMagick
}

# ─────────────────────────────────────────────
# STEP COUNTER
# ─────────────────────────────────────────────
$totalSteps = if ($cfg['dryRun']) { 6 } else { 9 }
$currentStep = 0
function Write-Step {
    param([string]$Message)
    $script:currentStep++
    Write-Host "  [$script:currentStep/$script:totalSteps] $Message" -ForegroundColor Cyan
}

Write-Step 'Checking tools...'
Write-Host ""

Write-Step 'Reading metadata with ExifTool (this may take a moment)...'

# ─────────────────────────────────────────────
# EXIFTOOL  — bulk-read metadata as JSON
# ─────────────────────────────────────────────

# Build file list
$files = @(Get-ChildItem -Path $inputDir -File -Recurse | Where-Object {
    $allExtensions -contains $_.Extension.ToLower()
})

if ($files.Count -eq 0) {
    Write-Warning "No supported files found in $inputDir"
    return
}
Write-Host "Found $($files.Count) file(s).`n"

# Run ExifTool once for ALL files -> JSON  (fast!)
$exifArgs = @(
    '-json'
    '-n'                           # numeric GPS values
    '-DateTimeOriginal'
    '-CreateDate'
    '-MediaCreateDate'
    '-ModifyDate'
    '-GPSLatitude'
    '-GPSLongitude'
    '-FileName'
    '-Directory'
    '-FileModifyDate'
    '-SubSecDateTimeOriginal'
    '-SubSecCreateDate'
    '-OffsetTimeOriginal'
    '-r'                           # recursive
    $inputDir
)

$rawJson = & $cfg['exiftoolPath'] @exifArgs 2>$null
$exifData = @($rawJson | ConvertFrom-Json)

# ─────────────────────────────────────────────
# PARSE & BUILD FILE-INFO OBJECTS
# ─────────────────────────────────────────────
function Parse-ExifDate {
    param([string]$raw)
    if (-not $raw -or $raw -eq '-') { return $null }
    # ExifTool formats: "2025:12:30 13:06:38" or "2025:12:30 13:06:38.448" or with offset
    $clean = $raw -replace '(\d{4}):(\d{2}):(\d{2})', '$1-$2-$3'
    $formats = @(
        'yyyy-MM-dd HH:mm:ss.fffzzz',
        'yyyy-MM-dd HH:mm:ss.fff',
        'yyyy-MM-dd HH:mm:sszzz',
        'yyyy-MM-dd HH:mm:ss',
        'yyyy-MM-ddTHH:mm:ss.fffzzz',
        'yyyy-MM-ddTHH:mm:sszzz'
    )
    foreach ($fmt in $formats) {
        $dt = [datetime]::MinValue
        if ([datetime]::TryParseExact($clean, $fmt, [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::None, [ref]$dt)) {
            return $dt
        }
    }
    try { return [datetime]::Parse($clean) } catch { return $null }
}

$fileInfos = [System.Collections.Generic.List[hashtable]]::new()

foreach ($item in $exifData) {
    $fullPath = Join-Path $item.Directory $item.FileName

    # Best date: SubSecDateTimeOriginal > DateTimeOriginal > CreateDate > MediaCreateDate > ModifyDate > FileModifyDate
    $dateTaken = $null
    foreach ($field in @('SubSecDateTimeOriginal','DateTimeOriginal','CreateDate','MediaCreateDate','ModifyDate','FileModifyDate')) {
        $fieldVal = $null
        try { $fieldVal = $item.PSObject.Properties[$field].Value } catch {}
        if ($fieldVal) {
            $dateTaken = Parse-ExifDate $fieldVal
            if ($dateTaken) { break }
        }
    }

    # GPS (safe access for strict mode)
    $gpsLat = $null; $gpsLon = $null
    try { $gpsLat = $item.PSObject.Properties['GPSLatitude'].Value } catch {}
    try { $gpsLon = $item.PSObject.Properties['GPSLongitude'].Value } catch {}
    $hasGps = ($null -ne $gpsLat) -and ($null -ne $gpsLon) -and
              ($gpsLat -ne 0 -or $gpsLon -ne 0) -and
              ($gpsLat -ne '') -and ($gpsLon -ne '')

    $lat = if ($hasGps) { [double]$gpsLat } else { $null }
    $lon = if ($hasGps) { [double]$gpsLon } else { $null }

    $fi = @{
        FullPath   = $fullPath
        FileName   = $item.FileName
        Directory  = $item.Directory
        Extension  = [System.IO.Path]::GetExtension($item.FileName).ToLower()
        DateTaken  = $dateTaken
        HasGps     = $hasGps
        Latitude   = $lat
        Longitude  = $lon
        Country    = $null
        State      = $null
        City       = $null
        Suburb     = $null
        Road       = $null
        GapFilled  = $false
        IsHeic     = $heicExtensions -contains ([System.IO.Path]::GetExtension($item.FileName).ToLower())
        NewName    = $null
        NewDir     = $null
        NewPath    = $null
        JpgPath    = $null
        Status     = 'pending'
    }
    $fileInfos.Add($fi)
}

# Sort by date for gap-fill later
$fileInfos = [System.Collections.Generic.List[hashtable]]($fileInfos | Sort-Object { $_.DateTaken })

$gpsCount    = @($fileInfos | Where-Object { $_.HasGps }).Count
$noGpsCount  = $fileInfos.Count - $gpsCount
$noDateCount = @($fileInfos | Where-Object { $null -eq $_.DateTaken }).Count
$heicCount   = @($fileInfos | Where-Object { $_.IsHeic }).Count

Write-Host "  With GPS       : $gpsCount"
Write-Host "  Without GPS    : $noGpsCount  (will gap-fill)"
Write-Host "  Without Date   : $noDateCount"
Write-Host "  HEIC files     : $heicCount  $(if ($canConvertHeic) { '(will convert to JPG)' } else { '(conversion skipped - no ImageMagick)' })"
Write-Host ""

Write-Step 'Reverse geocoding...'

# ─────────────────────────────────────────────
# REVERSE GEOCODING  (Nominatim / OpenStreetMap)
# ─────────────────────────────────────────────
$geocodeCache = @{}
$cacheFile = Join-Path $PSScriptRoot 'geocode-cache.json'
if ($cfg['geocodeCache'] -and (Test-Path $cacheFile)) {
    try {
        $geocodeCache = Get-Content $cacheFile -Raw | ConvertFrom-Json | ConvertTo-Hashtable
    } catch { $geocodeCache = @{} }
}

function Invoke-ReverseGeocode {
    param([double]$Lat, [double]$Lon)

    # Round to ~111 m precision for caching (3 decimal places)
    $key = "$([Math]::Round($Lat,3)),$([Math]::Round($Lon,3))"
    if ($geocodeCache.ContainsKey($key)) { return $geocodeCache[$key] }

    $url = "https://nominatim.openstreetmap.org/reverse?lat=$Lat&lon=$Lon&format=jsonv2&accept-language=en&zoom=14&email=$($cfg['nominatimEmail'])"

    try {
        $resp = Invoke-RestMethod -Uri $url -Headers @{ 'User-Agent' = "icloud-photo-renamer/1.0 ($($cfg['nominatimEmail']))" }
        Start-Sleep -Seconds $cfg['nominatimDelaySec']   # respect Nominatim rate-limit

        $addr = $resp.address

        # Safe property access — Nominatim doesn't always return every field
        $safeGet = { param($obj, [string]$prop)
            $p = $obj.PSObject.Properties[$prop]
            if ($p) { $p.Value } else { $null }
        }

        $country = & $safeGet $addr 'country'
        $state   = & $safeGet $addr 'state'
        $cityVal = @(
            (& $safeGet $addr 'city'),
            (& $safeGet $addr 'town'),
            (& $safeGet $addr 'village'),
            (& $safeGet $addr 'municipality'),
            (& $safeGet $addr 'county')
        ) | Where-Object { $_ } | Select-Object -First 1
        $suburb  = @(
            (& $safeGet $addr 'suburb'),
            (& $safeGet $addr 'neighbourhood'),
            (& $safeGet $addr 'quarter')
        ) | Where-Object { $_ } | Select-Object -First 1
        $road    = & $safeGet $addr 'road'

        $result = @{
            Country = if ($country) { $country -replace '\s+', ' ' } else { $null }
            State   = if ($state)   { $state   -replace '\s+', ' ' } else { $null }
            City    = if ($cityVal) { $cityVal  -replace '\s+', ' ' } else { $null }
            Suburb  = if ($suburb)  { $suburb   -replace '\s+', ' ' } else { $null }
            Road    = if ($road)    { $road     -replace '\s+', ' ' } else { $null }
        }
        $geocodeCache[$key] = $result
        return $result
    } catch {
        Write-Warning "Geocode failed for ($Lat, $Lon): $_"
        return @{ Country = $null; State = $null; City = $null; Suburb = $null; Road = $null }
    }
}

if (-not $SkipGeocoding) {
    # Collect unique GPS coordinates to geocode
    $uniqueCoords = @{}
    foreach ($fi in $fileInfos) {
        if ($fi.HasGps) {
            $key = "$([Math]::Round($fi.Latitude,3)),$([Math]::Round($fi.Longitude,3))"
            if (-not $uniqueCoords.ContainsKey($key)) {
                $uniqueCoords[$key] = @{ Lat = $fi.Latitude; Lon = $fi.Longitude }
            }
        }
    }

    $total = $uniqueCoords.Count
    $i = 0
    Write-Host "Reverse-geocoding $total unique location(s)..." -ForegroundColor Yellow
    foreach ($kv in $uniqueCoords.GetEnumerator()) {
        $i++
        Write-Progress -Activity "Geocoding" -Status "$i / $total" -PercentComplete (($i / [Math]::Max($total,1)) * 100)
        $null = Invoke-ReverseGeocode -Lat $kv.Value.Lat -Lon $kv.Value.Lon
    }
    Write-Progress -Activity "Geocoding" -Completed

    # Save cache
    if ($cfg['geocodeCache']) {
        $geocodeCache | ConvertTo-Json -Depth 5 | Set-Content $cacheFile -Encoding UTF8
    }

    # Apply geocode results to file infos
    foreach ($fi in $fileInfos) {
        if ($fi.HasGps) {
            $geo = Invoke-ReverseGeocode -Lat $fi.Latitude -Lon $fi.Longitude
            $fi.Country = $geo.Country
            $fi.State   = $geo.State
            $fi.City    = $geo.City
            $fi.Suburb  = $geo.Suburb
            $fi.Road    = $geo.Road
        }
    }
}

# ─────────────────────────────────────────────
# GAP-FILL  — files without GPS inherit from nearest neighbour in time
# ─────────────────────────────────────────────
Write-Step 'Gap-filling locations for files without GPS...'

$maxGap = [TimeSpan]::FromMinutes($cfg['gapFillMaxMinutes'])

# Build a sorted array of ONLY GPS-tagged files with valid dates for binary search
$gpsSorted = @($fileInfos | Where-Object { $_.HasGps -and $null -ne $_.DateTaken } | Sort-Object { $_.DateTaken })
$gpsDates  = @($gpsSorted | ForEach-Object { $_.DateTaken.Ticks })

$gapFillTotal = @($fileInfos | Where-Object { -not $_.HasGps -and $null -ne $_.DateTaken }).Count
$gapFillIdx = 0

foreach ($fi in $fileInfos) {
    if ($fi.HasGps -or $null -eq $fi.DateTaken) { continue }

    $gapFillIdx++
    if ($gapFillIdx % 500 -eq 0) {
        Write-Progress -Activity "Gap-filling" -Status "$gapFillIdx / $gapFillTotal" -PercentComplete (($gapFillIdx / [Math]::Max($gapFillTotal,1)) * 100)
    }

    # Binary search for the closest GPS-tagged file by date
    $targetTicks = $fi.DateTaken.Ticks
    $lo = 0; $hi = $gpsDates.Count - 1
    if ($hi -lt 0) { continue }

    while ($lo -lt $hi) {
        $mid = [Math]::Floor(($lo + $hi) / 2)
        if ($gpsDates[$mid] -lt $targetTicks) { $lo = $mid + 1 } else { $hi = $mid }
    }

    # Check the nearest 1-2 candidates (the one at $lo and the one before it)
    $bestDelta = [TimeSpan]::MaxValue
    $bestMatch = $null
    foreach ($idx in @($lo, ($lo - 1))) {
        if ($idx -lt 0 -or $idx -ge $gpsSorted.Count) { continue }
        $delta = ($fi.DateTaken - $gpsSorted[$idx].DateTaken).Duration()
        if ($delta -lt $bestDelta -and $delta -le $maxGap) {
            $bestDelta = $delta
            $bestMatch = $gpsSorted[$idx]
        }
    }

    if ($bestMatch) {
        $fi.Country   = $bestMatch.Country
        $fi.State     = $bestMatch.State
        $fi.City      = $bestMatch.City
        $fi.Suburb    = $bestMatch.Suburb
        $fi.Road      = $bestMatch.Road
        $fi.Latitude  = $bestMatch.Latitude
        $fi.Longitude = $bestMatch.Longitude
        $fi.GapFilled = $true
    }
}
Write-Progress -Activity "Gap-filling" -Completed

$gapFilledCount = @($fileInfos | Where-Object { $_.GapFilled }).Count
Write-Host "  Gap-filled: $gapFilledCount file(s)`n"

# ─────────────────────────────────────────────
# BUILD NEW FILE NAMES
# ─────────────────────────────────────────────
Write-Step 'Building new file names...'

function Sanitize-FileName {
    param([string]$name)
    $illegal = [System.IO.Path]::GetInvalidFileNameChars()
    foreach ($c in $illegal) { $name = $name.Replace([string]$c, '') }
    $name = $name -replace '[_\s]{2,}', '_'
    $name = $name.Trim('_', ' ')
    return $name
}

$usedNames = @{}

foreach ($fi in $fileInfos) {
    $template = $cfg['nameTemplate']

    # Location tokens
    $country = if ($fi.Country) { $fi.Country } else { $cfg['unknownLocation'] }
    $city    = if ($fi.City)    { $fi.City }    else { $cfg['unknownLocation'] }
    $state   = if ($fi.State)   { $fi.State }   else { $cfg['unknownLocation'] }
    $suburb  = if ($fi.Suburb)  { $fi.Suburb }  else { '' }
    $road    = if ($fi.Road)    { $fi.Road }    else { '' }

    # Date/time tokens
    if ($fi.DateTaken) {
        $dateStr = $fi.DateTaken.ToString($cfg['dateFormat'])
        $timeStr = $fi.DateTaken.ToString($cfg['timeFormat'])
    } else {
        $fsDate = (Get-Item $fi.FullPath).LastWriteTime
        $dateStr = $fsDate.ToString($cfg['dateFormat'])
        $timeStr = $fsDate.ToString($cfg['timeFormat'])
    }

    # Replace tokens
    $newBase = $template `
        -replace '\{country\}', $country `
        -replace '\{state\}',   $state `
        -replace '\{city\}',    $city `
        -replace '\{suburb\}',  $suburb `
        -replace '\{road\}',    $road `
        -replace '\{date\}',    $dateStr `
        -replace '\{time\}',    $timeStr

    $newBase = $newBase -replace '_{2,}', '_'
    $newBase = $newBase.Trim('_')

    if ($cfg['sanitizeChars']) { $newBase = Sanitize-FileName $newBase }

    # Keep original extension for renaming step
    $ext = $fi.Extension
    $candidate = "$newBase$ext"
    $dir = if ($cfg['organizeIntoSubfolders']) {
        $sub = $cfg['subfolderTemplate'] `
            -replace '\{country\}', $country `
            -replace '\{city\}',    $city `
            -replace '\{state\}',   $state
        Join-Path $inputDir (Sanitize-FileName $sub)
    } else {
        $fi.Directory
    }

    # Handle duplicates by appending _01, _02 etc.
    $fullCandidate = Join-Path $dir $candidate
    $counter = 1
    while ($usedNames.ContainsKey($fullCandidate.ToLower()) -or
          ((Test-Path $fullCandidate) -and $fullCandidate -ne $fi.FullPath)) {
        $suffix = "_{0:D2}" -f $counter
        $candidate = "$newBase$suffix$ext"
        $fullCandidate = Join-Path $dir $candidate
        $counter++
    }
    $usedNames[$fullCandidate.ToLower()] = $true

    $fi.NewName = $candidate
    $fi.NewDir  = $dir
    $fi.NewPath = $fullCandidate

    # Pre-compute the JPG path if this is a HEIC file that will be converted
    if ($fi.IsHeic -and $canConvertHeic) {
        $jpgName = [System.IO.Path]::ChangeExtension($candidate, '.jpg')
        $fi.JpgPath = Join-Path $dir $jpgName
        $usedNames[($fi.JpgPath).ToLower()] = $true
    }
}

# ─────────────────────────────────────────────
# PREVIEW
# ─────────────────────────────────────────────
$logEntries = [System.Collections.Generic.List[psobject]]::new()

Write-Step 'Generating rename plan...'
Write-Host "─── Rename Plan ───" -ForegroundColor Cyan
foreach ($fi in $fileInfos) {
    $isSame = ($fi.FullPath -eq $fi.NewPath)
    $action = if ($isSame)           { 'SKIP' }
              elseif ($cfg['dryRun']) { 'DRY-RUN' }
              else                    { 'RENAME' }

    $locationNote = if ($fi.GapFilled) { ' [gap-filled]' }
                    elseif (-not $fi.HasGps -and -not $fi.GapFilled) { ' [no GPS]' }
                    else { '' }

    $heicNote = ''
    if ($fi.IsHeic -and $canConvertHeic -and -not $isSame) {
        $heicNote = "  ->  $([System.IO.Path]::GetFileName($fi.JpgPath))  [HEIC->JPG]"
    }

    $color = switch ($action) {
        'SKIP'    { 'DarkGray' }
        'DRY-RUN' { 'Yellow' }
        'RENAME'  { 'Green' }
    }

    Write-Host ("  {0,-10} {1}" -f $action, $fi.FileName) -ForegroundColor $color -NoNewline
    Write-Host "  ->  $($fi.NewName)$locationNote" -NoNewline
    if ($heicNote) { Write-Host $heicNote -ForegroundColor Magenta -NoNewline }
    Write-Host ""

    $logEntries.Add([pscustomobject]@{
        Action       = $action
        OriginalName = $fi.FileName
        NewName      = $fi.NewName
        JpgName      = if ($fi.JpgPath) { [System.IO.Path]::GetFileName($fi.JpgPath) } else { '' }
        DateTaken    = $fi.DateTaken
        Country      = $fi.Country
        City         = $fi.City
        GapFilled    = $fi.GapFilled
        HasGPS       = $fi.HasGps
        Latitude     = $fi.Latitude
        Longitude    = $fi.Longitude
    })
}

# ─────────────────────────────────────────────
# EXECUTE:  RENAME -> CONVERT HEIC -> FIX TIMESTAMPS
# ─────────────────────────────────────────────
if (-not $cfg['dryRun']) {

    # ── STEP 7: Rename all files ──
    Write-Step 'Renaming files...'
    $renamed = 0; $skipped = 0; $errors = 0

    foreach ($fi in $fileInfos) {
        if ($fi.FullPath -eq $fi.NewPath) { $skipped++; continue }

        try {
            if (-not (Test-Path $fi.NewDir)) {
                New-Item -ItemType Directory -Path $fi.NewDir -Force | Out-Null
            }
            Move-Item -LiteralPath $fi.FullPath -Destination $fi.NewPath -Force:$Force
            $fi.Status = 'renamed'
            $renamed++
        } catch {
            Write-Warning "  FAILED rename: $($fi.FileName) -> $_"
            $fi.Status = 'error'
            $errors++
        }
    }

    Write-Host "  Renamed : $renamed"
    Write-Host "  Skipped : $skipped"
    if ($errors -gt 0) { Write-Host "  Errors  : $errors" -ForegroundColor Red }

    # ── STEP 8: Convert HEIC -> JPG, move originals to backup ──
    if ($canConvertHeic) {
        $heicFiles = @($fileInfos | Where-Object { $_.IsHeic -and $_.Status -eq 'renamed' -and $_.JpgPath })
        if ($heicFiles.Count -gt 0) {
            Write-Step "Converting $($heicFiles.Count) HEIC file(s) to JPG..."

            # Create backup folder
            $heicBackupDir = Join-Path $inputDir $cfg['heicBackupFolder']
            if (-not (Test-Path $heicBackupDir)) {
                New-Item -ItemType Directory -Path $heicBackupDir -Force | Out-Null
            }

            $converted = 0; $convErrors = 0
            $totalHeic = @($heicFiles).Count
            $heicIdx = 0
            foreach ($fi in $heicFiles) {
                $heicIdx++
                Write-Progress -Activity "Converting HEIC to JPG" -Status "$heicIdx / $totalHeic  $($fi.NewName)" -PercentComplete (($heicIdx / $totalHeic) * 100)
                try {
                    # Convert with ImageMagick
                    $magickArgs = @(
                        'convert'
                        $fi.NewPath
                        '-quality', "$($cfg['jpgQuality'])"
                        $fi.JpgPath
                    )
                    $output = & $cfg['imageMagickPath'] @magickArgs 2>&1
                    if ($LASTEXITCODE -ne 0) {
                        throw "ImageMagick exit code $LASTEXITCODE : $output"
                    }

                    # Copy ALL EXIF metadata from the original HEIC to the new JPG
                    $exifCopyArgs = @(
                        '-TagsFromFile', $fi.NewPath
                        '-all:all'
                        '-overwrite_original'
                        $fi.JpgPath
                    )
                    & $cfg['exiftoolPath'] @exifCopyArgs 2>$null | Out-Null

                    # Move original HEIC to backup folder
                    $heicBackupPath = Join-Path $heicBackupDir ([System.IO.Path]::GetFileName($fi.NewPath))
                    Move-Item -LiteralPath $fi.NewPath -Destination $heicBackupPath -Force:$Force

                    $fi.Status = 'converted'
                    $converted++
                } catch {
                    Write-Warning "  FAILED convert: $($fi.NewName) -> $_"
                    $convErrors++
                }
            }
            Write-Progress -Activity "Converting HEIC to JPG" -Completed

            Write-Host "  Converted : $converted"
            if ($convErrors -gt 0) { Write-Host "  Errors    : $convErrors" -ForegroundColor Red }
        } else {
            Write-Step 'No HEIC files to convert.'
        }
    } else {
        Write-Step 'HEIC conversion skipped (ImageMagick not available).'
    }

    # ── STEP 3: Fix timestamps ──
    if ($cfg['fixTimestamps']) {
        Write-Step 'Fixing file timestamps...'
        $fixed = 0
        foreach ($fi in $fileInfos) {
            if ($null -eq $fi.DateTaken) { continue }

            $targetPaths = @()
            if ($fi.Status -eq 'converted' -and $fi.JpgPath -and (Test-Path $fi.JpgPath)) {
                $targetPaths += $fi.JpgPath
                # Also fix the HEIC backup
                $heicBackupPath = Join-Path (Join-Path $inputDir $cfg['heicBackupFolder']) ([System.IO.Path]::GetFileName($fi.NewPath))
                if (Test-Path $heicBackupPath) { $targetPaths += $heicBackupPath }
            } elseif ($fi.Status -eq 'renamed' -and (Test-Path $fi.NewPath)) {
                $targetPaths += $fi.NewPath
            }

            foreach ($tp in $targetPaths) {
                try {
                    $item = Get-Item -LiteralPath $tp
                    $item.CreationTime   = $fi.DateTaken
                    $item.LastWriteTime  = $fi.DateTaken
                    $fixed++
                } catch {
                    Write-Warning "  FAILED timestamp fix: $tp -> $_"
                }
            }
        }
        Write-Host "  Timestamps fixed: $fixed file(s)"
    } else {
        Write-Step 'Timestamp fix skipped (disabled in config).'
    }

} else {
    # ── DRY-RUN summary ──
    Write-Host ""
    Write-Host "  ==========================================================" -ForegroundColor Yellow
    Write-Host "   DRY-RUN STATISTICS                                        " -ForegroundColor Yellow
    Write-Host "  ==========================================================" -ForegroundColor Yellow
    Write-Host ""

    # --- File type breakdown ---
    $imageFiles = @($fileInfos | Where-Object { $cfg['imageExtensions'] -contains $_.Extension })
    $videoFiles = @($fileInfos | Where-Object { $cfg['videoExtensions'] -contains $_.Extension })
    $heicFiles  = @($fileInfos | Where-Object { $_.IsHeic })

    Write-Host "  FILE TYPES" -ForegroundColor Cyan
    Write-Host "    Total files        : $($fileInfos.Count)"
    Write-Host "    Images             : $($imageFiles.Count)"
    Write-Host "    Videos             : $($videoFiles.Count)"
    if ($heicFiles.Count -gt 0) {
        Write-Host "    HEIC/HEIF          : $($heicFiles.Count)  $(if ($canConvertHeic) { '(will convert to JPG)' } else { '(no ImageMagick - skipping conversion)' })" -ForegroundColor Magenta
    }

    # Extension breakdown
    Write-Host ""
    Write-Host "    By extension:" -ForegroundColor DarkGray
    $fileInfos | Group-Object Extension | Sort-Object Count -Descending | ForEach-Object {
        Write-Host "      $($_.Name.PadRight(8)) : $($_.Count)" -ForegroundColor DarkGray
    }
    Write-Host ""

    # --- Date coverage ---
    $withDate    = @($fileInfos | Where-Object { $null -ne $_.DateTaken })
    $withoutDate = @($fileInfos | Where-Object { $null -eq $_.DateTaken })

    Write-Host "  DATE COVERAGE" -ForegroundColor Cyan
    Write-Host "    With date-taken    : $($withDate.Count)"
    Write-Host "    Without date-taken : $($withoutDate.Count)  (will use file modified date)" -ForegroundColor $(if ($withoutDate.Count -gt 0) { 'Yellow' } else { 'White' })

    if ($withDate.Count -gt 0) {
        $earliest = ($withDate | Sort-Object { $_.DateTaken } | Select-Object -First 1).DateTaken.ToString('yyyy-MM-dd')
        $latest   = ($withDate | Sort-Object { $_.DateTaken } | Select-Object -Last 1).DateTaken.ToString('yyyy-MM-dd')
        Write-Host "    Date range         : $earliest  to  $latest"
    }
    Write-Host ""

    # --- GPS & Geocoding ---
    $withGps       = @($fileInfos | Where-Object { $_.HasGps })
    $withoutGps    = @($fileInfos | Where-Object { -not $_.HasGps })
    $gapFilled     = @($fileInfos | Where-Object { $_.GapFilled })
    $stillNoLoc    = @($fileInfos | Where-Object { -not $_.HasGps -and -not $_.GapFilled })

    Write-Host "  GPS & LOCATION" -ForegroundColor Cyan
    Write-Host "    With GPS coords    : $($withGps.Count)  ($([Math]::Round(($withGps.Count / [Math]::Max($fileInfos.Count,1)) * 100, 1))%)"
    Write-Host "    Without GPS        : $($withoutGps.Count)"
    Write-Host "    Gap-filled         : $($gapFilled.Count)  (inherited location from nearest file in time)" -ForegroundColor $(if ($gapFilled.Count -gt 0) { 'Green' } else { 'White' })
    Write-Host "    Still no location  : $($stillNoLoc.Count)  (will be named '$($cfg['unknownLocation'])')" -ForegroundColor $(if ($stillNoLoc.Count -gt 0) { 'Yellow' } else { 'White' })
    Write-Host ""

    # --- Location distribution ---
    $locatedFiles = @($fileInfos | Where-Object { $_.Country })
    if ($locatedFiles.Count -gt 0) {
        Write-Host "  LOCATIONS FOUND" -ForegroundColor Cyan

        # Country breakdown
        $countries = $locatedFiles | Group-Object { $_.Country } | Sort-Object Count -Descending
        Write-Host "    Countries:" -ForegroundColor DarkGray
        foreach ($c in $countries) {
            $pct = [Math]::Round(($c.Count / $locatedFiles.Count) * 100, 1)
            Write-Host "      $($c.Name.PadRight(25)) : $("$($c.Count)".PadLeft(6))  ($pct%)" -ForegroundColor DarkGray
        }
        Write-Host ""

        # Top cities
        $cities = $locatedFiles | Group-Object { "$($_.Country) > $($_.City)" } | Sort-Object Count -Descending | Select-Object -First 20
        Write-Host "    Top cities (up to 20):" -ForegroundColor DarkGray
        foreach ($c in $cities) {
            Write-Host "      $($c.Name.PadRight(40)) : $("$($c.Count)".PadLeft(6))" -ForegroundColor DarkGray
        }
        Write-Host ""
    }

    # --- Rename actions ---
    $willRename = @($fileInfos | Where-Object { $_.FullPath -ne $_.NewPath })
    $willSkip   = @($fileInfos | Where-Object { $_.FullPath -eq $_.NewPath })
    $heicPreview = @($fileInfos | Where-Object { $_.IsHeic -and $_.FullPath -ne $_.NewPath })

    Write-Host "  ACTIONS PLANNED" -ForegroundColor Cyan
    Write-Host "    Will rename        : $($willRename.Count)"
    Write-Host "    Already correct    : $($willSkip.Count)"
    if ($heicPreview.Count -gt 0 -and $canConvertHeic) {
        Write-Host "    HEIC -> JPG        : $($heicPreview.Count)  (originals moved to '$($cfg['heicBackupFolder'])/' folder)" -ForegroundColor Magenta
    }
    if ($cfg['fixTimestamps']) {
        $tsFixable = @($fileInfos | Where-Object { $null -ne $_.DateTaken -and $_.FullPath -ne $_.NewPath }).Count
        Write-Host "    Timestamps to fix  : $tsFixable"
    }
    Write-Host ""

    Write-Host "  ==========================================================" -ForegroundColor Yellow
    Write-Host "   No files were changed.  Re-run with  -Apply  to execute.  " -ForegroundColor Yellow
    Write-Host "  ==========================================================" -ForegroundColor Yellow
    Write-Host ""
}

# ─────────────────────────────────────────────
# WRITE LOG CSV
# ─────────────────────────────────────────────
$logName = "rename-log_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
$logPath = Join-Path $PSScriptRoot $logName
$logEntries | Export-Csv -Path $logPath -NoTypeInformation -Encoding UTF8
Write-Host "Log written: $logPath`n" -ForegroundColor DarkGray
