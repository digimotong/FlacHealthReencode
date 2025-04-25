# FLAC Health Check & Reencode Script

A bash script for scanning and repairing FLAC audio files with encoding errors.

## Features

- **Full Library Scan**: Checks all FLAC files in a directory for encoding errors
- **Incremental Scan**: Only checks files modified since last scan
- **Smart Reporting**: 
  - Only creates CSV reports when errors found
  - Includes metadata about each scan
  - Tracks scan history in `.flac_scan_metadata`
- **Safe Reencoding**:
  - Creates local backups before modifying files
  - Preserves original timestamps
  - Generates detailed logs

## Usage

1. Clone this repository
2. Make the script executable:
   ```bash
   chmod +x flac_health_reencode.sh
   ```
3. Run the script:
   ```bash
   ./flac_health_reencode.sh
   ```

### Menu Options

1. **Full scan music library**  
   Scans all FLAC files in the specified directory

2. **Reencode problematic FLAC files**  
   Uses the latest CSV report to reencode files with errors

3. **Scan new/changed files only**  
   Only scans files modified since last scan (faster)

4. **Quit**  
   Exits the script

## Output Files

- `flac_scan_YYYY-MM-DD_HH-MM-SS.csv` - Error reports (only created when errors found)
- `.flac_scan_metadata` - JSON file tracking scan history
- `reencode_log_YYYY-MM-DD_HH-MM-SS.txt` - Reencoding operation logs

## Requirements

- `flac` - For testing and reencoding files
- `jq` - For metadata file handling

Install on Debian/Ubuntu:
```bash
sudo apt-get install flac jq
```

## Backup Behavior

Before reencoding any file, the script:
1. Creates a `backup_FLAC_originals` folder in the file's directory
2. Copies the original file there
3. Only then attempts to reencode the file

## License

MIT License - Free to use and modify
