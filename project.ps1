Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

param(
    [Alias('c')][string]$City,
    [string]$CacheDir,
    [string]$Config = "$HOME/.mymeteorc",
    [switch]$Debug,
    [switch]$Verbose,
    [switch]$NoColor,
    [switch]$Help
)

$script:Author = 'Mateusz Meteo'
$script:Version = '1.0.0'
$script:UserAgent = "mymeteo-powershell/$Version (kontakt@example.com)"
$script:NominatimUrl = 'https://nominatim.openstreetmap.org/search'
$script:ImgwUrl = 'https://danepubliczne.imgw.pl/api/data/synop'
$script:DebugEnabled = ($Debug -or $Verbose)
$script:ColorEnabled = -not $NoColor

function Show-Help {
    @"
mymeteo PowerShell $Version
Autor: $Author

Przykład:
  .\project.ps1 -City "Kraków"

Parametry:
  -City / -c     Nazwa miejscowości.
  -CacheDir      Własna ścieżka pamięci podręcznej.
  -Config        Ścieżka do pliku rc (domyślnie ~/.mymeteorc).
  -Debug/-Verbose Wyświetlanie dodatkowych informacji.
  -NoColor       Wyłączenie kolorowania wyników.
  -Help          To okno pomocy.
"@
}

if ($Help) {
    Show-Help
    exit 0
}

function Write-DebugLog {
    param([string]$Message)
    if ($script:DebugEnabled) {
        Write-Host "[DEBUG] $Message" -ForegroundColor DarkGray
    }
}

function Expand-PathValue {
    param([string]$Value)
    if (-not $Value) { return $Value }
    if ($Value.StartsWith('~')) {
        return $Value -replace '^~', $HOME
    }
    return $Value
}

function Get-DefaultCacheDir {
    if ($env:XDG_CACHE_HOME) { return Join-Path $env:XDG_CACHE_HOME 'mymeteo' }
    if ($IsWindows) {
        if ($env:LOCALAPPDATA) { return Join-Path $env:LOCALAPPDATA 'mymeteo' }
        return Join-Path $HOME 'AppData/Local/mymeteo'
    }
    return Join-Path $HOME '.cache/mymeteo'
}

if (-not $CacheDir) { $CacheDir = Get-DefaultCacheDir }
$CacheDir = Expand-PathValue $CacheDir
$Config = Expand-PathValue $Config

function Read-RcFile {
    param([string]$Path)
    $result = @{}
    if (-not (Test-Path $Path)) { return $result }
    foreach ($line in Get-Content $Path) {
        if ($line -match '^\s*(#|$)') { continue }
        $parts = $line -split '=',2
        if ($parts.Count -ne 2) { continue }
        $key = $parts[0].Trim().ToLowerInvariant()
        $value = $parts[1].Trim()
        $result[$key] = $value
    }
    return $result
}

$rcValues = Read-RcFile -Path $Config
if (-not $City -and $rcValues.ContainsKey('city')) { $City = $rcValues['city'] }
if ($rcValues.ContainsKey('cache_dir') -and -not $PSBoundParameters.ContainsKey('CacheDir')) {
    $CacheDir = Expand-PathValue $rcValues['cache_dir']
}
if ($rcValues.ContainsKey('color') -and -not $PSBoundParameters.ContainsKey('NoColor')) {
    $ColorValue = $rcValues['color'].ToLowerInvariant()
    if ($ColorValue -in 'no','false','0') { $script:ColorEnabled = $false }
}

if (-not $City) {
    Write-Error 'Parametr -City jest wymagany.'
    exit 1
}

$placesDir = Join-Path $CacheDir 'places'
$stationsDir = Join-Path $CacheDir 'stations'
$weatherDir = Join-Path $CacheDir 'weather'
New-Item -ItemType Directory -Path @($CacheDir,$placesDir,$stationsDir,$weatherDir) -Force | Out-Null

function Get-Slug {
    param([string]$Text)
    return ($Text.ToLowerInvariant() -replace '[^a-z0-9]', '-')
}

function Wait-ForNominatim {
    $file = Join-Path $CacheDir '.nominatim_last_call'
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    if (Test-Path $file) {
        $last = [int64](Get-Content $file)
        $delta = $now - $last
        if ($delta -lt 2) {
            $wait = 2 - $delta
            if ($wait -gt 0) {
                Write-DebugLog "Czekam $wait s na kolejny request do Nominatim"
                Start-Sleep -Seconds $wait
            }
        }
    }
    Set-Content -Path $file -Value $now -Encoding ascii
}

function Get-PlaceCoordinates {
    param([string]$Query)
    $slug = Get-Slug $Query
    $cacheFile = Join-Path $placesDir "$slug.json"
    if (Test-Path $cacheFile) {
        try {
            $cached = Get-Content $cacheFile -Raw | ConvertFrom-Json
            if ($cached.lat -and $cached.lon) { return $cached }
        } catch {}
    }
    Wait-ForNominatim
    $encoded = [uri]::EscapeDataString("$Query, Polska")
    $uri = "$NominatimUrl?format=json&limit=1&countrycodes=pl&q=$encoded"
    Write-DebugLog "Zapytanie do Nominatim: $Query"
    $response = Invoke-RestMethod -Method Get -Uri $uri -Headers @{ 'User-Agent' = $UserAgent; 'Accept-Language' = 'pl' }
    if (-not $response) { throw "Brak danych z Nominatim dla $Query" }
    $lat = [double]$response[0].lat
    $lon = [double]$response[0].lon
    $payload = [pscustomobject]@{ lat = $lat; lon = $lon; raw = $response }
    $payload | ConvertTo-Json -Depth 4 | Set-Content -Path $cacheFile -Encoding utf8
    return $payload
}

function Get-ImgwDataset {
    Write-DebugLog 'Pobieram dane IMGW'
    return Invoke-RestMethod -Method Get -Uri $ImgwUrl -Headers @{ 'User-Agent' = $UserAgent }
}

function Ensure-StationMetadata {
    $file = Join-Path $CacheDir 'stations.json'
    if (Test-Path $file) {
        try { return Get-Content $file -Raw | ConvertFrom-Json } catch {}
    }
    Write-Host 'Generuję bazę współrzędnych stacji IMGW (to może chwilę potrwać)...' -ForegroundColor Yellow
    $dataset = Get-ImgwDataset
    $stations = @()
    $seen = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($entry in $dataset) {
        if (-not $entry.stacja) { continue }
        if ($seen.Add($entry.stacja)) {
            $coords = Get-PlaceCoordinates -Query $entry.stacja
            $stationObject = [pscustomobject]@{
                id = $entry.id_stacji
                name = $entry.stacja
                lat = [double]$coords.lat
                lon = [double]$coords.lon
            }
            $stations += $stationObject
        }
    }
    $result = [pscustomobject]@{
        generated_at = (Get-Date).ToString('s')
        stations = $stations
    }
    $result | ConvertTo-Json -Depth 4 | Set-Content -Path $file -Encoding utf8
    return $result
}

function Get-DistanceKm {
    param([double]$Lat1,[double]$Lon1,[double]$Lat2,[double]$Lon2)
    $rad = [Math]::PI / 180
    $dLat = ($Lat2 - $Lat1) * $rad
    $dLon = ($Lon2 - $Lon1) * $rad
    $a = [Math]::Sin($dLat/2) * [Math]::Sin($dLat/2) + [Math]::Cos($Lat1*$rad) * [Math]::Cos($Lat2*$rad) * [Math]::Sin($dLon/2) * [Math]::Sin($dLon/2)
    $c = 2 * [Math]::Atan2([Math]::Sqrt($a), [Math]::Sqrt(1-$a))
    return 6371 * $c
}

function Find-NearestStation {
    param($CityCoords, $Stations)
    $closest = $null
    $min = [double]::MaxValue
    foreach ($station in $Stations) {
        $dist = Get-DistanceKm -Lat1 $CityCoords.lat -Lon1 $CityCoords.lon -Lat2 $station.lat -Lon2 $station.lon
        if ($dist -lt $min) {
            $min = $dist
            $closest = [pscustomobject]@{
                id = $station.id
                name = $station.name
                distance = $dist
            }
        }
    }
    return $closest
}

function Ensure-WeatherCache {
    $file = Join-Path $weatherDir 'latest.json'
    if (Test-Path $file) {
        try {
            $cached = Get-Content $file -Raw | ConvertFrom-Json
            $age = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [int64]$cached.fetched_at
            if ($age -lt 1800) { return $cached }
        } catch {}
    }
    $dataset = Get-ImgwDataset
    $payload = [pscustomobject]@{
        fetched_at = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        data = $dataset
    }
    $payload | ConvertTo-Json -Depth 5 | Set-Content -Path $file -Encoding utf8
    return $payload
}

function Get-StationMeasurement {
    param([string]$StationId, $Weather)
    foreach ($row in $Weather.data) {
        if ($row.id_stacji -eq $StationId) { return $row }
    }
    return $null
}

$cityCoords = Get-PlaceCoordinates -Query $City
Write-DebugLog "Miasto $City: $($cityCoords.lat),$($cityCoords.lon)"

$stationsMeta = Ensure-StationMetadata
$nearest = Find-NearestStation -CityCoords $cityCoords -Stations $stationsMeta.stations
if (-not $nearest) {
    Write-Error 'Nie udało się znaleźć najbliższej stacji.'
    exit 1
}
Write-DebugLog "Najbliższa stacja: $($nearest.name)"

$weather = Ensure-WeatherCache
$measurement = Get-StationMeasurement -StationId $nearest.id -Weather $weather
if (-not $measurement) {
    Write-Error "Brak danych dla stacji $($nearest.name)"
    exit 1
}

function Get-ValueOrDefault {
    param($Value)
    if ($null -eq $Value -or "$Value" -eq '') { return 'brak' }
    return $Value
}

function Write-Color {
    param([string]$Label, [string]$Value, [string]$Unit, [ConsoleColor]$Color)
    if (-not $script:ColorEnabled) {
        Write-Host ("{0,-18} {1,10} {2}" -f ($Label + ':'), $Value, $Unit)
    }
    else {
        Write-Host ("{0,-18}" -f ($Label + ':')) -ForegroundColor $Color -NoNewline
        Write-Host (" {0,10} {1}" -f $Value, $Unit)
    }
}

$timestamp = "$($measurement.data_pomiaru) $($measurement.godzina_pomiaru)"
Write-Host "`n$($nearest.name) [$($nearest.id)] — $timestamp ($( [math]::Round($nearest.distance,1)) km)" -ForegroundColor Cyan
Write-Color -Label 'Temperatura' -Value (Get-ValueOrDefault $measurement.temperatura) -Unit '°C' -Color 'DarkYellow'
Write-Color -Label 'Prędkość wiatru' -Value (Get-ValueOrDefault $measurement.predkosc_wiatru) -Unit 'm/s' -Color 'Cyan'
Write-Color -Label 'Kierunek wiatru' -Value (Get-ValueOrDefault $measurement.kierunek_wiatru) -Unit '°' -Color 'Gray'
Write-Color -Label 'Wilgotność wzgl.' -Value (Get-ValueOrDefault $measurement.wilgotnosc_wzgledna) -Unit '%' -Color 'Magenta'
Write-Color -Label 'Suma opadu' -Value (Get-ValueOrDefault $measurement.suma_opadu) -Unit 'mm' -Color 'Blue'
Write-Color -Label 'Ciśnienie' -Value (Get-ValueOrDefault $measurement.cisnienie) -Unit 'hPa' -Color 'Green'
Write-Host "`nDane: IMGW-PIB (https://danepubliczne.imgw.pl/)" -ForegroundColor DarkGray
