#!/bin/bash

# process-outputs.sh
# Reusable script to process output.json files from miniwdl tasks
# Usage: ./process-outputs.sh <output_folder> <sample_id>

set -euo pipefail

# Check arguments
if [ $# -ne 2 ]; then
    echo "Usage: $0 <output_folder> <sample_id>"
    exit 1
fi

output_folder="$1"
sample_id="$2"

mkdir -p "$output_folder"

# Parse output.json and handle each output appropriately
if [ -f "/scratch/_LAST/outputs.json" ]; then
    echo "Processing outputs from outputs.json..."
    # TODO: Remove this once we are not debugging
    echo "Contents of outputs.json:"
    cat /scratch/_LAST/outputs.json
    
    # Use jq to iterate through each output and handle files vs non-files
    jq -r 'to_entries[] | "\(.key)\t\(.value | type)\t\(.value)"' /scratch/_LAST/outputs.json | while IFS=$'\t' read -r output_key value_type output_value; do
        
        if [ "$value_type" = "array" ]; then
            # Handle array values - extract each item and process it
            echo "Processing array output: $output_key"
            # Use a different approach to extract array items with proper escaping
            jq -r --arg key "$output_key" '.[$key][]?' /scratch/_LAST/outputs.json | while read -r array_item; do
                echo "Array item: '$array_item'"
                if [[ "$array_item" == /scratch* ]] && [ -f "$array_item" ]; then
                    echo "Copying file from array: $array_item to $output_folder"
                    cp "$array_item" "$output_folder"
                elif [ -n "$array_item" ]; then
                    # It's a non-file value in an array, append to a file
                    output_filename="$output_folder/${sample_id}.${output_key}"
                    echo "Writing array item to: $output_filename"
                    echo "$array_item" >> "$output_filename"
                fi
            done
        else
            # Handle single values
            if [[ "$output_value" == /scratch* ]] && [ -f "$output_value" ]; then
                echo "Copying file: $output_value to $output_folder"
                cp "$output_value" "$output_folder"
            else
                # It's not a file, write the value to a file
                output_filename="$output_folder/${sample_id}.${output_key}"
                echo "Writing non-file value to: $output_filename"
                echo "$output_value" > "$output_filename"
            fi
        fi
    done
else
    echo "Warning: outputs.json not found at /scratch/_LAST/outputs.json"
fi