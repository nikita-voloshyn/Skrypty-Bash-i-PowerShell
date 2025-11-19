# Skrypty-Bash-i-PowerShell

Projekt zawiera dwa skrypty (`project.sh` dla Linux/macOS oraz `project.ps1` dla Windows), które pobierają dane z usług Nominatim (OpenStreetMap) oraz IMGW-PIB, wyszukują najbliższą stację synoptyczną względem wskazanego miasta i wypisują bieżące parametry pogodowe.

## Wspólne funkcje
- **Argumenty CLI** – wszystkie parametry działania przekazywane są przez argumenty (`--city/ -c`, `--cache-dir`, `--config`, `--debug/--verbose`, `--no-color`, `--help`).
- **Pamięć podręczna** – zapytania do Nominatim, dane stacji IMGW oraz ostatnio pobrane wyniki są przechowywane w `~/.cache/mymeteo` (lub katalogu wskazanym w parametrach/plikach rc).
- **Plik rc** – ustawienia domyślne (np. `city=Poznań`, `cache_dir=...`, `color=no`) można zapisać w `~/.mymeteorc`.
- **Ograniczenia API** – wywołania Nominatim są automatycznie ograniczone (min. 2 s odstępu) i zawsze zawierają nagłówek `User-Agent` zgodny z regulaminem.
- **Algorytm najbliższej stacji** – współrzędne stacji są wyznaczane lokalnie (również przy użyciu Nominatim) i zapisywane w cache; dystans obliczany jest z użyciem wzoru Haversine.
- **Bajery** – wyniki są kolorowane, a w trybie debug pokazywane są szczegółowe logi.

## `project.sh` (Bash)
```bash
./project.sh --city "Poznań"
./project.sh --city "Kórnik" --debug --cache-dir /tmp/mymeteo
./project.sh --help
```
Do działania wymagane są `curl`, `jq` oraz `awk`.

## `project.ps1` (PowerShell)
```powershell
pwsh ./project.ps1 -City "Poznań"
./project.ps1 -City "Kraków" -Debug -CacheDir C:\\Temp\\mymeteo
./project.ps1 -Help
```
Skrypt został przygotowany pod Windows PowerShell 5.1 oraz PowerShell 7+. Domyślny katalog cache zależy od systemu (na Windows: `%LOCALAPPDATA%\\mymeteo`).

## Autor
Mateusz Meteo
