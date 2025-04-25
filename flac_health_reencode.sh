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

# Ensure the 'flac' command is available.
if ! command -v flac &>/dev/null; then
    echo "Error: The 'flac' command is not installed. Please install it (e.g., sudo apt-get install flac) and try again."
    exit 1
fi

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

    # Write CSV header.
    echo "filepath" > "$csv_output"

    echo "Scanning FLAC files in: $library_dir"
    error_count=0
    total_count=0

    # Recursively find .flac files (using -print0 to handle spaces).
    while IFS= read -r -d '' flac_file; do
        total_count=$((total_count + 1))
        # Test the FLAC file.
        if ! flac -t "$flac_file" &>/dev/null; then
            # Log problematic file (enclosing the path in quotes for CSV safety).
            echo "\"${flac_file}\"" >> "$csv_output"
            error_count=$((error_count + 1))
            echo "Error detected in: $flac_file"
        fi
    done < <(find "$library_dir" -type f -iname "*.flac" -print0)

    echo "Scan complete. Total FLAC files scanned: $total_count. Errors found: $error_count."
    echo "CSV report generated: $csv_output"
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
    echo "1) Scan music library"
    echo "2) Reencode problematic FLAC files (with local backups)"
    echo "3) Quit"
    echo "======================================"
    read -rp "Enter your selection (1, 2, or 3): " selection

    case "$selection" in
        1) scan_library ;;
        2) reencode_library ;;
        3) echo "Exiting..."; exit 0 ;;
        *) echo "Invalid selection. Exiting." ; exit 1 ;;
    esac
}

# Start the script by displaying the main menu.
main_menu
