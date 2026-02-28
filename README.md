# 📸 iCloud Photo Renamer

Rename iCloud photos & videos using **GPS location** and **date-taken** metadata.

**Before:**  `IMG_3847.HEIC`
**After:**   `Thailand_Siriraj_2025-12-30_13-06-38-448.heic`

## Features

| Feature | Description |
|---------|-------------|
| 📍 GPS → Location names | Reverse-geocodes GPS coordinates via [Nominatim/OpenStreetMap](https://nominatim.openstreetmap.org/) |
| 🕳️ Gap-fill | Files without GPS inherit the location of the nearest file in time (configurable window) |
| 📅 Date-taken | Uses EXIF `DateTimeOriginal` (with sub-seconds when available) |
| 🕐 Timestamp fix | Sets file Created & Modified dates to match date-taken |
| 🔒 Dry-run by default | Preview everything before committing |
| 📋 CSV log | Every run writes a log of all actions |
| ⚡ Fast | Reads all metadata in one ExifTool call |

## Prerequisites

| Tool | How to get it |
|------|---------------|
| **PowerShell 7+** | `winget install Microsoft.PowerShell` or [download](https://github.com/PowerShell/PowerShell/releases) |
| **ExifTool** | [exiftool.org](https://exiftool.org) — download the Windows executable |

### ExifTool setup

1. Download the **Windows Executable** from https://exiftool.org
2. Extract and rename `exiftool(-k).exe` → `exiftool.exe`
3. **Either** place it next to `Rename-ICloudPhotos.ps1` **or** add its folder to your `PATH`

## Quick Start

```powershell
# 1 — Clone the repo
git clone https://github.com/YOUR_USERNAME/icloud-photo-renamer.git
cd icloud-photo-renamer

# 2 — Create your local config (git-ignored)
Copy-Item config.json config.local.json

# 3 — Edit config.local.json — set your inputFolder and email
notepad config.local.json

# 4 — Dry-run (preview only, no changes)
.\Rename-ICloudPhotos.ps1

# 5 — Execute for real
.\Rename-ICloudPhotos.ps1 -Execute
```

## Configuration

Edit **`config.local.json`** (copy of `config.json`, git-ignored):

| Key | Default | Description |
|-----|---------|-------------|
| `inputFolder` | — | Path to your iCloud photos folder |
| `dryRun` | `true` | Preview mode — set to `false` or use `-Execute` |
| `nameTemplate` | `{country}_{city}_{date}_{time}` | Tokens: `{country}`, `{state}`, `{city}`, `{suburb}`, `{road}`, `{date}`, `{time}` |
| `dateFormat` | `yyyy-MM-dd` | .NET date format string |
| `timeFormat` | `HH-mm-ss-fff` | .NET time format string (fff = milliseconds) |
| `gapFillMaxMinutes` | `60` | How far to look for a GPS-tagged neighbour |
| `fixTimestamps` | `true` | Update file Created & Modified to match date-taken |
| `nominatimEmail` | — | **Required** by Nominatim usage policy ([details](https://operations.osmfoundation.org/policies/nominatim/)) |
| `geocodeCache` | `true` | Cache geocode results to `geocode-cache.json` |
| `organizeIntoSubfolders` | `false` | Move files into `{country}\{city}` subfolders |
| `unknownLocation` | `Unknown` | Placeholder when no location is found |

## CLI Parameters

```powershell
.\Rename-ICloudPhotos.ps1
    [-InputFolder <path>]     # Override inputFolder from config
    [-Execute]                # Actually rename (disables dry-run)
    [-SkipGeocoding]          # Skip reverse geocoding (use existing cache)
    [-Force]                  # Overwrite existing files on collision
    [-ConfigPath <path>]      # Use a specific config file
```

## How It Works

```
┌─────────────┐     ┌──────────────┐     ┌───────────────┐
│  ExifTool   │────▶│  Parse EXIF  │────▶│ Reverse Geo-  │
│  (bulk JSON)│     │  GPS + Dates │     │ code (Nominatim)│
└─────────────┘     └──────────────┘     └───────┬───────┘
                                                  │
       ┌──────────────────────────────────────────┘
       ▼
┌─────────────┐     ┌──────────────┐     ┌───────────────┐
│  Gap-fill   │────▶│ Build new    │────▶│ Rename + fix  │
│  (no GPS)   │     │ file names   │     │ timestamps    │
└─────────────┘     └──────────────┘     └───────────────┘
```

## Opening Your Photos Folder in VS Code

To let VS Code (and Copilot) see your photos folder alongside this project:

### Option A — Add folder to workspace
1. Open this project in VS Code
2. **File → Add Folder to Workspace…**
3. Navigate to your iCloud photos folder and click **Add**
4. VS Code will show both folders in the Explorer sidebar

### Option B — Open both folders
```
code "C:\path\to\icloud-photo-renamer" "C:\Users\YOU\Pictures\iCloud Photos"
```

### Option C — Create a `.code-workspace` file
Create `renamer.code-workspace`:
```json
{
  "folders": [
    { "path": "." },
    { "path": "C:\\Users\\YOU\\Pictures\\iCloud Photos", "name": "📸 iCloud Photos" }
  ]
}
```
Then **File → Open Workspace from File…** and select it.

## Supported File Types

**Images:** JPG, JPEG, PNG, HEIC, HEIF, TIFF, GIF, BMP, WebP, CR2, CR3, ARW, DNG, RAF, NEF, ORF, RW2

**Videos:** MOV, MP4, M4V, AVI, 3GP, MTS

## License

MIT
