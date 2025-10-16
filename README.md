# PacBio Somatic WDL Analysis

This repository contains workflows for PacBio HiFi (High-Fidelity) somatic variant analysis based on the [PacificBiosciences/HiFi-somatic-WDL](https://github.com/PacificBiosciences/HiFi-somatic-WDL) pipeline. This comprehensive pipeline provides end-to-end analysis of PacBio HiFi reads for somatic variant detection, including alignment, variant calling, structural variant detection, phasing, and methylation analysis.

## Prerequisite

**IMPORTANT**: Before running any workflows, you must first run the **Download PacBio Somatic WDL Reference Data Resources** task to download and prepare the required reference data bundle. This task downloads the GRCh38 reference genome and associated files from Zenodo and configures the necessary mapping files.

Before downloading, use [Workspace Settings](./manage/settings) to specify the target location with the `RESOURCES_PATH` variable.

## Overview

This repository provides a comprehensive PacBio HiFi somatic analysis workflow that includes:

1. **Alignment**: PacBio HiFi read alignment using pbmm2
2. **Batch Parameter Generation**: Automatic pairing of tumor and normal samples
3. **Depth of Coverage**: Mosdepth for coverage analysis
4. **Somatic Variant Calling**: DeepSomatic for somatic variant detection
5. **Haplotype Phasing**: HiPhase for variant phasing and haplotagging
6. **Alignment Statistics**: Comprehensive alignment metrics
7. **Structural Variant Detection**: Severus, Wakhan, and CNVKit for structural variants
8. **CpG Methylation Analysis**: CpG pileup and differential methylation analysis

### Workflow Parameters

- **uBAM Base Folder**: Directory containing unaligned BAM (uBAM) files to process
- **Output Folder**: Directory where all results will be stored
- **Cache Udocker Image**: Option to cache Docker images for faster subsequent runs

### Input Requirements

The workflow expects PacBio HiFi unaligned BAM (uBAM) files in the input directory. Files should follow the naming pattern `*/*.bam` where the sample identifier is extracted from the filename. The workflow automatically pairs tumor and normal samples based on catalog information.

### Output Structure

The workflow generates a comprehensive set of outputs including:
- Aligned BAM files with quality metrics
- Somatic variant call files (VCF) from DeepSomatic
- Structural variant calls from Severus, Wakhan, and CNVKit
- Haplotagged BAM files from HiPhase
- CpG methylation analysis results
- Coverage statistics from Mosdepth
- Comprehensive alignment statistics

## Individual Tasks

The repository also provides individual tasks that can be run independently:

### Core Analysis Tasks
- **alignment.task.yaml**: PacBio HiFi read alignment
- **deepsomatic.task.yaml**: Somatic variant calling
- **hiphase.task.yaml**: Variant phasing and haplotagging
- **structural_variants.task.yaml**: Structural variant detection

### Specialized Analysis Tasks
- **mosdepth.task.yaml**: Coverage analysis
- **alignment_stats.task.yaml**: Alignment statistics
- **cpg_dmr.task.yaml**: CpG methylation analysis

### Utility Tasks
- **generate_batch_parameter_file.task.yaml**: Sample pairing and batch file generation

## Resource Requirements

The workflow is resource-intensive and requires:
- **CPU**: Up to 48 cores for the most demanding steps
- **Memory**: Up to 96 GB RAM for the most demanding steps
- **Storage**: Significant scratch storage space for intermediate files

## Reference Data

The workflow uses the GRCh38 reference genome and associated files that are downloaded by the prerequisite task. These include:
- GRCh38 reference genome FASTA
- Genome interval BED files
- Reference mapping files
- Model files for various analysis tools

## Getting Started

1. **Set up resources**: Configure `RESOURCES_PATH` in Workspace Settings
2. **Download reference data**: Run the "Download PacBio Somatic WDL Reference Data Resources" task
3. **Prepare input data**: Ensure your PacBio HiFi uBAM files are in the expected directory structure
4. **Run the workflow**: Execute the PacBio WGS Somatic workflow with appropriate parameters

## Notes

- The workflow calls the individual WDL steps from the PacBio Somatic WDL workflow
- Sample pairing is automatically handled based on catalog information
- The workflow supports both tumor-normal pairs and tumor-only analysis
