#!/bin/bash
# flac_health_reencode.sh
# -------------------------------------------
# This script provides two options:
#  1) Scan a music library for FLAC encoding errors.
#     - Prompts the user for the library directory.
#     - Recursively scans all .flac files using "flac -t".
#     - Files with encoding errors are logged into a CSV file in the library directory.
#
#  2) Reencode files that were flagged as problematic.
#     - Prompts for the directory containing the CSV file (typically the music library).
#     - Finds the latest CSV report, confirms with the user,
#       then reencodes each file using FLAC with:
#         --verify
#         --compression-level-0
#         --decode-through-errors
#         --preserve-modtime
#         --silent
#         -o <output>
#
#     - **Backup Behavior Update:** Before overwriting the original file,
#       the script creates (if needed) a backup folder in the same directory as the file
#       (e.g., within the album folder) and copies the original file there.
#
# Best practices used:
#  - Dependency checking
#  - Robust error handling
#  - Handling spaces in filenames safely
#  - Inline documentation and log file generation for transparency
#
# Further improvements:
#  - Add command-line options for non-interactive/cron jobs.
#  - Include progress indicators for large music libraries.
# -------------------------------------------

# Exit when a command fails, when a variable is unset, and catch errors in pipelines.
set -o errexit
set -o nounset
set -o pipefail

# Ensure required commands are available.
for cmd in flac jq; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Error: The '$cmd' command is not installed. Please install it (e.g., sudo apt-get install $cmd) and try again."
        exit 1
    fi
done

########################################
# FUNCTION: scan_library
# Prompts for a music library directory, then recursively scans all FLAC files using 'flac -t'.
# Any file that fails the test is recorded (with quotes) in a CSV file stored in the library directory.
########################################
scan_library() {
    read -rp "Enter the full path to your music library directory: " library_dir

    # Validate the directory.
    if [ ! -d "$library_dir" ]; then
        echo "Error: The directory '$library_dir' does not exist."
        exit 1
    fi

    # Generate a CSV filename with a timestamp.
    timestamp=$(date +%F_%H-%M-%S)
    csv_output="${library_dir}/flac_scan_${timestamp}.csv"

    echo "Scanning FLAC files in: $library_dir"
    error_count=0
    total_count=0

    # Recursively find .flac files (using -print0 to handle spaces).
    while IFS= read -r -d '' flac_file; do
        total_count=$((total_count + 1))
        # Test the FLAC file.
        if ! flac -t "$flac_file" &>/dev/null; then
            # Create CSV file if first error
            if [ $error_count -eq 0 ]; then
                echo "# Scan Metadata: $(date -u +%FT%TZ) | Files: $total_count | Errors: | Type: full" > "$csv_output"
                echo "filepath" >> "$csv_output"
            fi
            # Log problematic file
            echo "\"${flac_file}\"" >> "$csv_output"
            error_count=$((error_count + 1))
            echo "Error detected in: $flac_file"
        fi
    done < <(find "$library_dir" -type f -iname "*.flac" -print0)

    # Update error count in metadata if CSV was created
    if [ $error_count -gt 0 ]; then
        sed -i "s/| Errors: /| Errors: $error_count/" "$csv_output"
        echo "Scan complete. Found $error_count errors in $total_count files."
        echo "CSV report generated: $csv_output"
    else
        echo "Scan complete. No errors found in $total_count files."
        rm -f "$csv_output"  # Remove empty CSV
    fi

    # Update metadata file
    local metadata_file="${library_dir}/.flac_scan_metadata"
    jq -n \
        --arg full "$(date -u +%FT%TZ)" \
        --arg incremental "$(date -u +%FT%TZ)" \
        '{last_full_scan: $full, last_incremental_scan: $incremental, scan_version: "1.0"}' > "$metadata_file"
    echo "Scan metadata updated: $metadata_file"
}

########################################
# FUNCTION: reencode_library
# Locates the latest scan CSV file from the supplied directory,
# confirms with the user, and processes each problematic file for reencoding.
#
# Backup Behavior:
#   For each file, a backup folder is created within its directory (if not already present)
#   and the original file is backed up there before it is replaced by the reencoded version.
########################################
reencode_library() {
    # Ask for the directory containing your FLAC scan CSV files.
    read -rp "Enter the directory containing your FLAC scan CSV files (typically your music library): " library_dir

    if [ ! -d "$library_dir" ]; then
        echo "Error: The directory '$library_dir' does not exist."
        exit 1
    fi

    # Locate the latest CSV file (by modification time).
    latest_csv=$(find "$library_dir" -maxdepth 1 -type f -iname "flac_scan_*.csv" -printf "%T@ %p\n" \
                 | sort -n \
                 | tail -1 \
                 | cut -d' ' -f2-)

    if [ -z "$latest_csv" ]; then
        echo "No CSV file found in '$library_dir'. Please run a scan first."
        exit 1
    fi

    echo "Latest scan CSV file found: $latest_csv"
    read -rp "Type 'Y' to confirm using this CSV file for reencoding: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "User did not confirm. Aborting reencoding process."
        exit 1
    fi

    # Generate a log file for the reencoding process.
    log_file="${library_dir}/reencode_log_$(date +%F_%H-%M-%S).txt"
    echo "Reencoding started at $(date)" > "$log_file"

    total_files=0
    success_count=0
    fail_count=0

    # Process each problematic file listed in the CSV (skip header).
    while IFS=, read -r flac_file; do
        # Remove any surrounding quotes.
        flac_file=${flac_file//\"/}
        # Skip header row.
        if [[ "$flac_file" == "filepath" ]]; then
            continue
        fi

        total_files=$((total_files + 1))
        echo "Processing file: $flac_file"

        # Determine the file's directory and file name.
        file_dir=$(dirname "$flac_file")
        base=$(basename "$flac_file")
        temp_file="${file_dir}/tmp_${base}"

        # Reencode the file using the specified FLAC parameters.
        if flac --verify --compression-level-0 --decode-through-errors --preserve-modtime --silent -o "$temp_file" "$flac_file"; then
            # Create a backup folder in the same directory as the file.
            backup_folder="${file_dir}/backup_FLAC_originals"
            mkdir -p "$backup_folder"
            backup_target="${backup_folder}/${base}"

            if cp "$flac_file" "$backup_target"; then
                echo "Backup created for: $flac_file -> $backup_target"
            else
                echo "WARNING: Failed to backup $flac_file. Skipping reencode for this file." | tee -a "$log_file"
                rm -f "$temp_file"
                fail_count=$((fail_count + 1))
                continue
            fi

            # Replace the original file with the reencoded version.
            if mv "$temp_file" "$flac_file"; then
                success_count=$((success_count + 1))
                echo "SUCCESS: $flac_file reencoded successfully." | tee -a "$log_file"
            else
                echo "FAILURE: Could not overwrite $flac_file with the reencoded file." | tee -a "$log_file"
                fail_count=$((fail_count + 1))
            fi
        else
            echo "FAILURE: Reencoding failed for $flac_file" | tee -a "$log_file"
            [ -f "$temp_file" ] && rm "$temp_file"
            fail_count=$((fail_count + 1))
        fi
    done < "$latest_csv"

    echo "Reencoding complete at $(date)" | tee -a "$log_file"
    echo "Total files processed: $total_files" | tee -a "$log_file"
    echo "Successful reencodes: $success_count" | tee -a "$log_file"
    echo "Failed reencodes: $fail_count" | tee -a "$log_file"
    echo "Detailed log saved as: $log_file"
}

########################################
# MAIN MENU
# Displays a simple menu to select either scanning or reencoding.
########################################
main_menu() {
    echo "======================================"
    echo " FLAC Health Check & Reencode Script"
    echo "======================================"
    echo "1) Full scan music library"
    echo "2) Reencode problematic FLAC files (with local backups)"
    echo "3) Scan new/changed files only"
    echo "4) Quit"
    echo "======================================"
    read -rp "Enter your selection (1, 2, or 3): " selection

    case "$selection" in
        1) scan_library ;;
        2) reencode_library ;;
        3) scan_incremental ;;
        4) echo "Exiting..."; exit 0 ;;
        *) echo "Invalid selection. Exiting." ; exit 1 ;;
    esac
}

########################################
# FUNCTION: scan_incremental
# Scans only FLAC files that have been modified since the last scan,
# or files that have never been scanned before.
########################################
scan_incremental() {
    read -rp "Enter the full path to your music library directory: " library_dir

    # Validate the directory
    if [ ! -d "$library_dir" ]; then
        echo "Error: The directory '$library_dir' does not exist."
        exit 1
    fi

    # Check for existing metadata file
    local metadata_file="${library_dir}/.flac_scan_metadata"
    local last_scan="1970-01-01T00:00:00Z"  # Default to epoch if no metadata
    
    if [ -f "$metadata_file" ]; then
        last_scan=$(jq -r '.last_full_scan // "1970-01-01T00:00:00Z"' "$metadata_file")
        echo "Found previous scan from: $last_scan"
    else
        echo "No previous scan found - will scan all files"
    fi

    # Generate CSV filename with timestamp
    local timestamp=$(date +%F_%H-%M-%S)
    local csv_output="${library_dir}/flac_scan_${timestamp}.csv"

    echo "Scanning new/changed FLAC files in: $library_dir"
    local error_count=0
    local total_count=0
    local scanned_count=0

    # Find and scan files modified since last scan
    while IFS= read -r -d '' flac_file; do
        total_count=$((total_count + 1))
        if ! flac -t "$flac_file" &>/dev/null; then
            # Create CSV file if first error
            if [ $error_count -eq 0 ]; then
                echo "# Scan Metadata: $(date -u +%FT%TZ) | Files: $total_count | Errors: | Type: incremental" > "$csv_output"
                echo "filepath" >> "$csv_output"
            fi
            echo "\"${flac_file}\"" >> "$csv_output"
            error_count=$((error_count + 1))
            echo "Error detected in: $flac_file"
        fi
        scanned_count=$((scanned_count + 1))
    done < <(find "$library_dir" -type f -iname "*.flac" -newermt "$last_scan" -print0)

    # Update error count in metadata if CSV was created
    if [ $error_count -gt 0 ]; then
        sed -i "s/| Errors: /| Errors: $error_count/" "$csv_output"
        echo "Incremental scan complete. Found $error_count errors in $scanned_count files scanned ($total_count total files)."
        echo "CSV report generated: $csv_output"
    else
        echo "Incremental scan complete. No errors found in $scanned_count files scanned ($total_count total files)."
        rm -f "$csv_output"  # Remove empty CSV
    fi

    # Update metadata file
    jq -n \
        --arg full "$(date -u +%FT%TZ)" \
        --arg incremental "$(date -u +%FT%TZ)" \
        '{last_full_scan: $full, last_incremental_scan: $incremental, scan_version: "1.0"}' > "$metadata_file"
}

# Start the script by displaying the main menu.
main_menu
