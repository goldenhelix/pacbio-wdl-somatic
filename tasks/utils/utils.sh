#!/bin/bash

# Common utility functions for PacBio WDL Somatic tasks
# This file contains shared functions used across multiple task files

# Function to format file sizes using shell arithmetic
# Usage: format_file_size <file_path> [unit]
# If unit is provided, it will format in that specific unit (KB, MB, GB)
# If unit is not provided, it will auto-select the appropriate unit
format_file_size() {
    local file_path="$1"
    local unit="$2"  # Optional: "KB", "MB", or "GB"
    local file_size=$(stat -c%s "$file_path" 2>/dev/null || echo "0")
    
    # If specific unit is requested, format in that unit
    if [ -n "$unit" ]; then
        case "$unit" in
            "KB")
                local size_kb=$((file_size / 1024))
                local remainder_bytes=$((file_size % 1024))
                local decimal_part=$((remainder_bytes * 100 / 1024))
                echo "${size_kb}.${decimal_part}"
                ;;
            "MB")
                local size_mb=$((file_size / 1024 / 1024))
                local remainder_kb=$(((file_size % (1024 * 1024)) / 1024))
                local decimal_part=$((remainder_kb * 100 / 1024))
                echo "${size_mb}.${decimal_part}"
                ;;
            "GB")
                local size_gb=$((file_size / 1024 / 1024 / 1024))
                local remainder_mb=$(((file_size % (1024 * 1024 * 1024)) / 1024 / 1024))
                local decimal_part=$((remainder_mb * 100 / 1024))
                echo "${size_gb}.${decimal_part}"
                ;;
            *)
                echo "0.0"
                ;;
        esac
    else
        # Auto-select appropriate unit
        if [ $file_size -ge 1073741824 ]; then
            # >= 1GB, show in GB
            local size_gb=$((file_size / 1024 / 1024 / 1024))
            local remainder_mb=$(((file_size % (1024 * 1024 * 1024)) / 1024 / 1024))
            local decimal_part=$((remainder_mb * 100 / 1024))
            echo "${size_gb}.${decimal_part} GB"
        elif [ $file_size -ge 1048576 ]; then
            # >= 1MB, show in MB
            local size_mb=$((file_size / 1024 / 1024))
            local remainder_kb=$(((file_size % (1024 * 1024)) / 1024))
            local decimal_part=$((remainder_kb * 100 / 1024))
            echo "${size_mb}.${decimal_part} MB"
        elif [ $file_size -ge 1024 ]; then
            # >= 1KB, show in KB
            local size_kb=$((file_size / 1024))
            local remainder_bytes=$((file_size % 1024))
            local decimal_part=$((remainder_bytes * 100 / 1024))
            echo "${size_kb}.${decimal_part} KB"
        else
            # < 1KB, show in bytes
            echo "${file_size} bytes"
        fi
    fi
}

# Function to handle miniwdl failure
# Usage: handle_miniwdl_failure <exit_code>
handle_miniwdl_failure() {
    local exit_code=$1
    echo "MiniWDL run failed with exit code $exit_code"
    echo "Capturing debug information..."
    bash "$TASK_DIR/utils/miniwdl-debug-capture.sh" /scratch/_LAST "$output_folder" "$TASK_NAME"
    exit $exit_code
}

# Function to copy files with progress bar, size reporting, and disk space monitoring
# Usage: copy_with_progress <dest_dir> <file1> [file2] [file3] ...
copy_with_progress() {
    local dest_dir="$1"
    shift
    local files=("$@")
    local total_files=${#files[@]}
    local current_file=0
    local total_size_copied=0
    
    # Calculate total input size before copying
    local total_input_size=0
    for file in "${files[@]}"; do
        total_input_size=$((total_input_size + $(stat -c%s "$file" 2>/dev/null || echo "0")))
    done
    # Calculate GB using shell arithmetic (more reliable than bc)
    local total_input_gb=$((total_input_size / 1024 / 1024 / 1024))
    local total_input_mb=$((total_input_size / 1024 / 1024))
    local remainder_mb=$(((total_input_size % (1024 * 1024 * 1024)) / 1024 / 1024))
    
    echo "Copying $total_files files (${total_input_gb}.${remainder_mb} GB) to $dest_dir..."
    echo "================================================"
    
    for file in "${files[@]}"; do
        current_file=$((current_file + 1))
        local filename=$(basename "$file")
        local dest_path="$dest_dir/$filename"
        
        # Get file size using stat
        local file_size=$(stat -c%s "$file" 2>/dev/null || echo "0")
        local file_size_mb=$((file_size / 1024 / 1024))
        local file_size_kb=$(((file_size % (1024 * 1024)) / 1024))
        
        echo "[$current_file/$total_files] Copying: $filename (${file_size_mb}.${file_size_kb} MB)"
        
        # Copy with progress bar using pv
        if command -v pv >/dev/null 2>&1; then
            pv "$file" > "$dest_path"
        else
            # Fallback to cp if pv is not available
            cp "$file" "$dest_path"
        fi
        
        # Verify copy and get actual copied size
        local copied_size=$(stat -c%s "$dest_path" 2>/dev/null || echo "0")
        local copied_size_mb=$((copied_size / 1024 / 1024))
        local copied_size_kb=$(((copied_size % (1024 * 1024)) / 1024))
        total_size_copied=$((total_size_copied + copied_size))
        
        echo "✓ Copied: $filename (${copied_size_mb}.${copied_size_kb} MB)"
        echo "----------------------------------------"
    done
    
    # Calculate total size in MB and GB using shell arithmetic
    local total_mb=$((total_size_copied / 1024 / 1024))
    local total_gb=$((total_size_copied / 1024 / 1024 / 1024))
    local remainder_mb=$(((total_size_copied % (1024 * 1024 * 1024)) / 1024 / 1024))
    
    echo "================================================"
    echo "✓ All files copied successfully!"
    echo "Total size copied: ${total_mb} MB (${total_gb}.${remainder_mb} GB)"
    
    # Show remaining disk space
    if command -v df >/dev/null 2>&1; then
        local dest_mount=$(df "$dest_dir" | tail -1 | awk '{print $1}')
        local available_space=$(df -h "$dest_dir" | tail -1 | awk '{print $4}')
        local used_percent=$(df "$dest_dir" | tail -1 | awk '{print $5}')
        echo "Remaining disk space on $dest_mount: $available_space ($used_percent used)"
    fi
    echo "================================================"
}
