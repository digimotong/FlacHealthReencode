#!/bin/bash
# flac_health_reencode.sh

# Configuration file path
CONFIG_FILE="$(dirname "$(realpath "$0")")/flac_health_config.json"

# Terminal colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Progress tracking
PROGRESS_WIDTH=50
# -------------------------------------------
# This script provides two main functions:
#  1) Full library scan for FLAC encoding errors
#     - Scans all FLAC files using "flac -t"
#     - Only creates CSV output when errors found
#     - Tracks basic scan metadata
#
#  2) Reencode problematic files
#     - Uses latest CSV report of problematic files
#     - Creates local backups before reencoding
#     - Preserves original file timestamps
#
# Features:
#  - Safe backup handling (creates backup_FLAC_originals folders)
#  - Detailed error reporting and logging
#  - Handles filenames with spaces
#
# Dependencies: flac
# -------------------------------------------

# Exit when a command fails, when a variable is unset, and catch errors in pipelines.
set -o errexit
set -o nounset
set -o pipefail

########################################
# FUNCTION: load_config
# Loads configuration from file or creates default
########################################
load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        jq -n '{library_path: "", version: "1.0"}' > "$CONFIG_FILE"
    fi
    config=$(cat "$CONFIG_FILE")
    echo "$config"
}

########################################
# FUNCTION: save_config
# Saves configuration to file
# Arguments:
#   $1 - New library path
########################################
save_config() {
    local new_path="$1"
    config=$(jq --arg path "$new_path" '.library_path = $path' "$CONFIG_FILE")
    echo "$config" > "$CONFIG_FILE"
}

# Ensure required commands are available.
for cmd in flac; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Error: The '$cmd' command is not installed. Please install it (e.g., sudo apt-get install $cmd) and try again."
        exit 1
    fi
done

########################################
# FUNCTION: count_flac_files
# Counts all FLAC files in a directory
########################################
count_flac_files() {
    local dir="$1"
    find "$dir" -type f -iname "*.flac" | wc -l
}

########################################
# FUNCTION: show_progress
# Displays a progress bar
# Arguments:
#   $1 - Current count
#   $2 - Total count
#   $3 - Error count
########################################
show_progress() {
    local current=$1
    local total=$2
    local errors=$3
    local percent=$((current * 100 / total))
    local filled=$((percent * PROGRESS_WIDTH / 100))
    local empty=$((PROGRESS_WIDTH - filled))
    
    printf "\r["
    printf "%${filled}s" | tr ' ' '█'
    printf "%${empty}s" | tr ' ' '░'
    printf "] %3d%% (%d/%d) | Errors: %d" "$percent" "$current" "$total" "$errors"
}

########################################
# FUNCTION: scan_library
# Prompts for a music library directory, then recursively scans all FLAC files using 'flac -t'.
# Any file that fails the test is recorded (with quotes) in a CSV file stored in the library directory.
########################################
scan_library() {
    config=$(load_config)
    library_path=$(echo "$config" | jq -r '.library_path')
    
    if [ -z "$library_path" ] || [ "$library_path" == "null" ]; then
        read -rp "Enter the full path to your music library directory: " library_path
        save_config "$library_path"
    fi

    library_dir="$library_path"
    
    # Validate the directory.
    if [ ! -d "$library_dir" ]; then
        echo "Error: The directory '$library_dir' does not exist."
        exit 1
    fi

    # Create scan data directory structure
    scan_data_dir="${library_dir}/.flac_scan_data"
    mkdir -p "${scan_data_dir}/reports" "${scan_data_dir}/logs"
    
    # Generate CSV filename with timestamp
    timestamp=$(date +%F_%H-%M-%S)
    csv_output="${scan_data_dir}/reports/flac_scan_${timestamp}.csv"

    echo "Scanning FLAC files in: $library_dir"
    echo "Counting FLAC files..."
    total_files=$(count_flac_files "$library_dir")
    echo "Found $total_files FLAC files to scan"
    
    error_count=0
    processed_count=0
    start_time=$(date +%s)
    last_update=0

    # Recursively find .flac files (using -print0 to handle spaces).
    while IFS= read -r -d '' flac_file; do
        processed_count=$((processed_count + 1))
        # Update progress every 50 files or 1% progress
        if (( processed_count % 50 == 0 || processed_count * 100 / total_files > last_update )); then
            show_progress "$processed_count" "$total_files" "$error_count"
            last_update=$((processed_count * 100 / total_files))
        fi

        # Test the FLAC file
        if ! flac -t "$flac_file" &>/dev/null; then
            # Create CSV file if first error
            if [ $error_count -eq 0 ]; then
                echo "# Scan Report: $(date -u +%FT%TZ) | Files: $total_files | Errors: " > "$csv_output"
                echo "filepath" >> "$csv_output"
            fi
            # Log problematic file
            echo "\"${flac_file}\"" >> "$csv_output"
            error_count=$((error_count + 1))
            printf "\n${RED}Error detected in:${NC} $flac_file\n"
            show_progress "$processed_count" "$total_files" "$error_count"
        fi
    done < <(find "$library_dir" -type f -iname "*.flac" -print0)

    # Clear progress line
    printf "\r%${COLUMNS}s\r" ""
    
    # Update error count in metadata if CSV was created
    if [ $error_count -gt 0 ]; then
        sed -i "s/| Errors: /| Errors: $error_count/" "$csv_output"
        end_time=$(date +%s)
        duration=$((end_time - start_time))
        printf "${GREEN}Scan complete.${NC}\n"
        printf "Scanned ${YELLOW}%d${NC} files in ${YELLOW}%d${NC} seconds\n" "$processed_count" "$duration"
        printf "Found ${RED}%d${NC} errors\n" "$error_count"
        printf "CSV report generated: ${YELLOW}%s${NC}\n" "$csv_output"
    else
        end_time=$(date +%s)
        duration=$((end_time - start_time))
        printf "${GREEN}Scan complete.${NC}\n"
        printf "Scanned ${YELLOW}%d${NC} files in ${YELLOW}%d${NC} seconds\n" "$processed_count" "$duration"
        printf "${GREEN}No errors found.${NC}\n"
        rm -f "$csv_output"  # Remove empty CSV
    fi

    echo "Scan complete. Report saved to: $csv_output"
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
    config=$(load_config)
    library_path=$(echo "$config" | jq -r '.library_path')
    
    if [ -z "$library_path" ] || [ "$library_path" == "null" ]; then
        read -rp "Enter the directory containing your FLAC scan CSV files (typically your music library): " library_path
        save_config "$library_path"
    fi

    library_dir="$library_path"
    
    if [ ! -d "$library_dir" ]; then
        echo "Error: The directory '$library_dir' does not exist."
        exit 1
    fi

    # Locate the latest CSV file in reports directory (by modification time).
    scan_data_dir="${library_dir}/.flac_scan_data/reports"
    latest_csv=$(find "$scan_data_dir" -type f -iname "flac_scan_*.csv" -printf "%T@ %p\n" \
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

    # Create scan data directory if needed
    scan_data_dir="${library_dir}/.flac_scan_data"
    mkdir -p "${scan_data_dir}/logs"
    
    # Generate a log file for the reencoding process.
    log_file="${scan_data_dir}/logs/reencode_log_$(date +%F_%H-%M-%S).txt"
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
# FUNCTION: set_library_path
# Allows user to set or update the default library path
########################################
set_library_path() {
    config=$(load_config)
    current_path=$(echo "$config" | jq -r '.library_path')
    
    if [ -z "$current_path" ] || [ "$current_path" == "null" ]; then
        echo "No library path is currently configured."
    else
        echo "Current library path: $current_path"
    fi
    
    read -rp "Enter new library path (leave blank to keep current): " new_path
    if [ -n "$new_path" ]; then
        save_config "$new_path"
        echo "Library path updated to: $new_path"
    else
        echo "Library path remains unchanged."
    fi
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
    echo "3) Set/Update default library path"
    echo "4) Quit"
    echo "======================================"
    read -rp "Enter your selection (1-4): " selection

    case "$selection" in
        1) scan_library ;;
        2) reencode_library ;;
        3) set_library_path ;;
        4) echo "Exiting..."; exit 0 ;;
        *) echo "Invalid selection. Exiting." ; exit 1 ;;
    esac
}


# Start the script by displaying the main menu.
main_menu
