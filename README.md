# FLAC Health Check & Re-encode Utility

A robust Bash script for scanning and repairing FLAC audio files while preserving metadata and creating backups.

## Features

- ✅ Recursive scanning of FLAC files for corruption
- 🔄 Safe re-encoding of problematic files with backup preservation
- 📊 Detailed CSV reports and operation logs
- 🎨 Color-coded terminal output with progress tracking
- ⚙️ Persistent configuration via JSON file
- 🗑️ Backup cleanup utility

## Installation

1. Ensure you have the required dependencies:
   ```bash
   sudo apt-get install flac jq  # Debian/Ubuntu
   brew install flac jq         # macOS
   ```

2. Download the script:
   ```bash
   git clone https://github.com/digimotong/FlacHealthReencode.git
   cd FlacHealthReencode
   ```

3. Make the script executable:
   ```bash
   chmod +x flac_health_reencode.sh
   ```

## Usage

Run the script and follow the interactive menu:
```bash
./flac_health_reencode.sh
```

### Menu Options:
1. **Full scan music library** - Checks all FLAC files for errors
2. **Reencode problematic FLAC files** - Fixes corrupted files (creates backups)
3. **Set/Update default library path** - Configure your music library location
4. **Clean up FLAC backups** - Remove backup files after verification
5. **Quit**

## Configuration

The script automatically creates a configuration file (`flac_health_config.json`) in its directory. You can:
- Set the default library path through the menu
- Manually edit the JSON file:
  ```json
  {
    "library_path": "/path/to/your/music",
    "version": "1.0"
  }
  ```

## File Structure

The script creates the following structure in your music library:
```
.music_library/
└── .flac_scan_data/
    ├── reports/         # CSV scan reports
    └── logs/            # Operation logs
```

For each re-encoded file, a backup is stored in:
```
album_folder/
└── backup_FLAC_originals/
    └── original_file.flac
```
