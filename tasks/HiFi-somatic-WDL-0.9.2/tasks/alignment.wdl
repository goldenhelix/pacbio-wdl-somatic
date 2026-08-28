version 1.0

workflow align_all_bams {

    input {
        String patient
        Array[File] bam_files
        File ref_fasta
        File ref_fasta_index
        # Callers should override this with the agent's real core count. The old
        # default of 64 was silently wrong on the 48-core agents this runs on:
        # miniwdl clamps runtime.cpu to the host, but "-j 64" still reached pbmm2.
        Int pbmm2_threads = 32
        Int merge_bam_threads = 8
        Int samtools_threads = 8
        Boolean skip_align = false
        Boolean strip_kinetics = false
        String additional_pbmm2_args = "-A 2"
    }

     if(!skip_align && length(bam_files) > 1){
      scatter (bam in bam_files) {
        call Align as align_multiple_bams {
          input:
            sample_name = patient,
            bam_file = bam,
            ref_fasta = ref_fasta,
            ref_fasta_index = ref_fasta_index,
            additional_args = additional_pbmm2_args,
            strip_kinetics = strip_kinetics,
            threads = pbmm2_threads
        }
      }

      call MergeBams as MergeAlignBams {
          input:
            sample_name = patient,
            bam_files = align_multiple_bams.aligned_bam,
            threads = merge_bam_threads
        }
     }

     # If one bam, align it without merging
     if (!skip_align && length(bam_files) == 1) {
        call Align as align_single_bam {
          input:
            sample_name = patient,
            bam_file = bam_files[0],
            ref_fasta = ref_fasta,
            ref_fasta_index = ref_fasta_index,
            additional_args = additional_pbmm2_args,
            strip_kinetics = strip_kinetics,
            threads = pbmm2_threads
        }
     }

      # If skip align, merge if more than one BAM
      if (skip_align && length(bam_files) > 1) {
        call MergeBams as MergeSkipAlignBams {
          input:
            sample_name = patient,
            bam_files = bam_files,
            threads = merge_bam_threads
        }
      }

      # If skip align and one bam, index the bam
      if (skip_align && length(bam_files) == 1) {
        call IndexBam as indexTumorBam {
          input:
            bam = bam_files[0],
            threads = samtools_threads
        }
      }

    output {
      File bam_final = if (skip_align) then select_first([indexTumorBam.out_bam, MergeSkipAlignBams.merged_aligned_bam]) else select_first([MergeAlignBams.merged_aligned_bam, align_single_bam.aligned_bam])
      File bam_final_index = if (skip_align) then select_first([indexTumorBam.out_bam_index, MergeSkipAlignBams.merged_aligned_bam_index]) else select_first([MergeAlignBams.merged_aligned_bam_index, align_single_bam.aligned_bam_index])
    }
}

# Align using pbmm2. If prefer to use a different version, change the SHA in the runtime section, e.g.:
# Version 1.12 (minimap2 2.17) SHA: d16e5df5bfab75ff2defd2984ec6cb7665473e383045e2a075ea1261ae188861
# Version 1.14.99 (minimap2 2.26) SHA: 19ca8f306b0c1c61aad0bf914c2a291b9ea9b8437e28dbdb5d76f93b81a0dbdf
# Version 1.16.0 (minimap2 2.26) SHA: 4a01f9a3ede68cd018d8d2e79f8773f331f21b35c764ac48b8595709dbd417f7
task Align {
  input {
    File bam_file
    File ref_fasta
    File ref_fasta_index
    String sample_name
    String? additional_args
    Boolean strip_kinetics
    Int threads
  }

  # Strip the extension, then append -- rather than substituting ".bam$" directly.
  # When two inputs share a basename, miniwdl disambiguates by appending a hash
  # ("reads.bam-1265f13b53264fd1"), which no longer matches "\\.bam$". The old
  # substitution then left ofile_name identical to the input name and pbmm2 died
  # with 'Unknown file suffix'. Stripping tolerates the suffix, and if the regex
  # matches nothing the name still differs from the input, so input != output holds.
  String base_name = basename(bam_file)
  String stripped_name = sub(base_name, "\\.bam(-[A-Za-z0-9]+)?$", "")
  String ofile_name = stripped_name + ".aligned.bam"
  String ofile_name_index = stripped_name + ".aligned.bam.bai"
  Float file_size = ceil(size(bam_file, "GB") * 2 + size(ref_fasta, "GB") + 20)
  
  command <<<
  set -euxo pipefail

  echo "Aligning ~{bam_file} and ~{ref_fasta} for ~{sample_name} using pbmm2 into ~{ofile_name}"
  
  pbmm2 --version

  # Log to stderr and tee to pbmm2.log, rather than using --log-file.
  # pbmm2 buffers --log-file through pbcopper's async logger and flushes on clean
  # shutdown only, so an abort() discards the buffer -- every failed run left a
  # 0-byte pbmm2.log and no error message. Piping through tee keeps the message on
  # stderr (captured by miniwdl) AND on disk, and bash waits for tee to drain.
  # pipefail is set above, so pbmm2's exit status still propagates through the pipe.
  pbmm2 align \
    ~{ref_fasta} \
    ~{bam_file} \
    ~{ofile_name} \
    --sample ~{sample_name} \
    --sort -j ~{threads} \
    --unmapped \
    --preset HIFI \
    --log-level INFO \
    ~{if(strip_kinetics) then "--strip" else ""} \
    ~{additional_args} 2>&1 | tee pbmm2.log
  >>>

  output {
    File aligned_bam = ofile_name
    File aligned_bam_index = ofile_name_index
    File align_log = "pbmm2.log"
  }

  runtime {
    docker: "quay.io/pacbio/pbmm2:1.17.0_build1"
    cpu: threads
    # 2 GB/thread, not 4. At the previous 4x, a 64-thread request asked for 256 GB;
    # miniwdl clamped it to the 96 GB host limit and logged a warning, while the
    # command line still shipped "-j 64" into a 48-CPU container. Callers should
    # pass pbmm2_threads = the agent's actual core count so -j matches reality.
    memory: "~{threads * 2} GB"
    disk: file_size + " GB"
    # A truncated or malformed input fails identically every time, so retries just
    # multiply the wall-clock cost of a deterministic failure. Inputs are validated
    # up front by the calling task; keep one retry for genuinely transient faults.
    maxRetries: 1
    preemptible: 1
  }
}

# Merge bams using pbmerge
task MergeBams {
  input {
    String sample_name
    Array[File] bam_files
    Int threads
  }

  Float file_size = ceil(size(bam_files, "GB") * 2 + 20)
  
  command <<<
    set -euxo pipefail
    echo "merging ~{sep=' ' bam_files} into ~{sample_name + ".aligned.bam"}"
    
    samtools --version

    samtools merge -@~{threads} \
      -o ~{sample_name + ".aligned.bam"} \
      ~{sep=' ' bam_files}

    samtools index -@~{threads} ~{sample_name + ".aligned.bam"}
  >>>

  output {
    File merged_aligned_bam = sample_name + ".aligned.bam"
    File merged_aligned_bam_index = sample_name + ".aligned.bam.bai"
  }

  runtime {
    docker: "quay.io/biocontainers/samtools:1.17--hd87286a_1"
    cpu: threads
    memory: "~{threads * 4} GB"
    disk: file_size + " GB"
    maxRetries: 2
    preemptible: 1
  }
}

task IndexBam {
  input {
    File bam
    Int threads
  }

  Float file_size = ceil(size(bam, "GB") + 20)
  
  command <<<
    set -euxo pipefail
    echo "indexing ~{bam}"
    
    samtools --version

    samtools index -@~{threads} ~{bam} \
      -o ~{basename(bam) + ".bai"}
  >>>

  output {
    File out_bam = bam
    File out_bam_index = basename(bam) + ".bai"
  }

  runtime {
    docker: "quay.io/biocontainers/samtools:1.17--hd87286a_1"
    cpu: threads
    memory: "~{threads * 4} GB"
    disk: file_size + " GB"
    maxRetries: 2
    preemptible: 1
  }
}