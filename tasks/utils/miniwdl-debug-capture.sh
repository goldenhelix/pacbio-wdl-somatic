#!/bin/bash

# miniwdl Debug Capture Script
# Usage: ./miniwdl-debug-capture.sh <workflow_run_directory> [output_directory] [task_name]

set -euo pipefail

WORKFLOW_DIR="${1:-}"
OUTPUT_DIR="${2:-$(pwd)/miniwdl-debug-$(date +%Y%m%d_%H%M%S)}"
task_name="${3:-}"

if [[ -z "$WORKFLOW_DIR" ]] || [[ ! -d "$WORKFLOW_DIR" ]]; then
    echo "Error: Please provide a valid workflow directory"
    echo "Usage: $0 <workflow_run_directory> [output_directory] [task_name]"
    exit 1
fi

# Create output directory structure
if [[ -n "$task_name" ]]; then
    # Create task-specific subdirectory structure
    mkdir -p "$OUTPUT_DIR/$task_name"/{logs,errors,configs,work_samples}
    TASK_OUTPUT_DIR="$OUTPUT_DIR/$task_name"
    echo "Created task-specific directory structure: $TASK_OUTPUT_DIR"
else
    # Create standard directory structure
    mkdir -p "$OUTPUT_DIR"/{logs,errors,configs,work_samples}
    TASK_OUTPUT_DIR="$OUTPUT_DIR"
fi


cd "$WORKFLOW_DIR"

# 1. Copy all error.json files
echo "Searching for error.json files in: $WORKFLOW_DIR"
error_files=$(find . -name "error.json" 2>/dev/null)
if [[ -n "$error_files" ]]; then
    echo "Found error.json files:"
    # Create temporary error summary file
    temp_error_summary=$(mktemp)
    echo "$error_files" | while read error_file; do
        echo "  - $error_file"
        cp "$error_file" "$TASK_OUTPUT_DIR/errors/"
        error_dir=$(dirname "$error_file")
        task_name=$(basename "$error_dir")
        echo "Found error in: $task_name" >> "$temp_error_summary"
    done
    # Copy the complete error summary to output directory
    if [[ -f "$temp_error_summary" ]]; then
        cp "$temp_error_summary" "$TASK_OUTPUT_DIR/errors/error_summary.txt"
        rm "$temp_error_summary"
    fi
else
    echo "No error.json files found in: $WORKFLOW_DIR"
fi


# 2. Collect all log files 
echo "Searching for log files in: $WORKFLOW_DIR"
log_files=$(find . \( -name "*.log" -o -name "*.txt" \) 2>/dev/null)
if [[ -n "$log_files" ]]; then
    echo "Found log files:"
    echo "$log_files" | while read logfile; do
        echo "  - $logfile"
        # Create subdirectory structure in logs
        rel_path=$(realpath --relative-to="$WORKFLOW_DIR" "$logfile")
        log_dir="$TASK_OUTPUT_DIR/logs/$(dirname "$rel_path")"
        mkdir -p "$log_dir"
        cp "$logfile" "$log_dir/"
    done
else
    echo "No log files found in: $WORKFLOW_DIR"
fi


# 3. Copy all JSON configuration files
echo "Searching for JSON files in: $WORKFLOW_DIR"
json_files=$(find . -name "*.json" 2>/dev/null)
if [[ -n "$json_files" ]]; then
    echo "Found JSON files:"
    echo "$json_files" | while read jsonfile; do
        echo "  - $jsonfile"
        # Create subdirectory structure in configs
        rel_path=$(realpath --relative-to="$WORKFLOW_DIR" "$jsonfile")
        config_dir="$TASK_OUTPUT_DIR/configs/$(dirname "$rel_path")"
        mkdir -p "$config_dir"
        cp "$jsonfile" "$config_dir/"
    done
else
    echo "No JSON files found in: $WORKFLOW_DIR"
fi


# 4. Create a summary of failed tasks with their exit codes
{
    echo "=== Failed Tasks Summary ==="
    echo "Generated: $(date)"
    if [[ -n "$task_name" ]]; then
        echo "Task Name: $task_name"
    fi
    echo ""
    
    error_files=$(find . -name "error.json" 2>/dev/null)
    if [[ -n "$error_files" ]]; then
        echo "$error_files" | while read error_file; do
            echo "Error in: $(dirname "$error_file")"
            if command -v jq >/dev/null 2>&1; then
                echo "Exit status: $(jq -r '.cause.exit_status // "unknown"' "$error_file" 2>/dev/null)"
                echo "Command: $(jq -r '.cause.command // "unknown"' "$error_file" 2>/dev/null)"
                echo "Stderr file: $(jq -r '.cause.stderr_file // "unknown"' "$error_file" 2>/dev/null)"
                echo "Stdout file: $(jq -r '.cause.stdout_file // "unknown"' "$error_file" 2>/dev/null)"
            else
                echo "Contents:"
                cat "$error_file"
            fi
            echo "---"
        done
    else
        echo "No error.json files found to analyze."
    fi
} > "$TASK_OUTPUT_DIR/failed_tasks_summary.txt"

# 8. For failed tasks, capture a sample of work directory contents
find . -name "error.json" | while read error_file; do
    task_dir=$(dirname "$error_file")
    task_name=$(basename "$task_dir")
    work_dir="$task_dir/work"
    
    if [[ -d "$work_dir" ]]; then
        sample_dir="$TASK_OUTPUT_DIR/work_samples/$task_name"
        mkdir -p "$sample_dir"
        
        # Create directory listing using temporary file
        temp_dir_structure=$(mktemp)
        echo "=== Work directory structure for $task_name ===" > "$temp_dir_structure"
        find "$work_dir" -type f -exec ls -lh {} \; >> "$temp_dir_structure" 2>/dev/null || true
        # Copy the complete directory structure to output directory
        cp "$temp_dir_structure" "$sample_dir/directory_structure.txt"
        rm "$temp_dir_structure"
        
        # Copy small files that might be useful
        find "$work_dir" -maxdepth 2 -type f \( -name "*.txt" -o -name "*.log" -o -name "*.json" \) -size -1M | head -20 | while read small_file; do
            cp --parents "$small_file" "$sample_dir/" 2>/dev/null || true
        done
    fi
done

# 9. Create overall workflow summary
{
    echo "=== Workflow Debug Summary ==="
    echo "Workflow directory: $WORKFLOW_DIR"
    if [[ -n "$task_name" ]]; then
        echo "Task Name: $task_name"
    fi
    echo "Capture time: $(date)"
    echo "Captured by: $(whoami)@$(hostname)"
    echo ""
    
    echo "=== Directory structure ==="
    tree "$WORKFLOW_DIR" -L 4 2>/dev/null || find "$WORKFLOW_DIR" -type d
    echo ""

    echo "=== Disk usage ==="
    echo "Total workflow directory size:"
    du -sh "$WORKFLOW_DIR" 2>/dev/null || echo "Unable to calculate directory size"
    echo ""
    
    echo "=== Failed tasks ==="
    error_dirs=$(find . -name "error.json" -exec dirname {} \; | sort)
    if [[ -n "$error_dirs" ]]; then
        echo "$error_dirs"
    else
        echo "No error.json files found"
    fi
    echo ""
    
    echo "=== Log files captured ==="
    find "$TASK_OUTPUT_DIR/logs" -name "*.txt" -o -name "*.log" | wc -l
    echo ""
    
    echo "=== Configuration files captured ==="
    find "$TASK_OUTPUT_DIR/configs" -name "*.json" | wc -l
    
} > "$TASK_OUTPUT_DIR/capture_summary.txt"

echo ""
echo "Output directory: $OUTPUT_DIR"
if [[ -n "$task_name" ]]; then
    echo "Task-specific directory: $TASK_OUTPUT_DIR"
fi
echo ""
echo "Key files to examine:"
echo "  - $TASK_OUTPUT_DIR/capture_summary.txt (overall summary)"
echo "  - $TASK_OUTPUT_DIR/failed_tasks_summary.txt (failed task details)"
echo "  - $TASK_OUTPUT_DIR/errors/ (error.json files)"
echo "  - $TASK_OUTPUT_DIR/logs/ (all log files)"
