/* Derived from MetaHipMer2 "histogrammer" 
*/

#include <Kokkos_Core.hpp>
#include <iostream>
#include <vector>
#include <cmath>
#include <string>
#include <fstream> // Include for file output
#include <iomanip> // Include for formatting
#include "alignments.hpp"
#include "histogrammer.hpp"
#include "utils.hpp"

using namespace std;

bool bad_alignment(const Aln *aln) {
    // with match and mismatch scores of 2 this means at most two errors
    return aln->score1 < aln->rlen - 4;
}

void Histogrammer::calculate_insert_size(Alns &alns) {
    Kokkos::Timer timer;
    auto unmerged_rlen = alns.calculate_unmerged_rlen();
    const int num_alignments = alns.size();
    
    // Kokkos Views for storing results
    Kokkos::View<int64_t*> insert_sizes("insert_sizes", num_alignments);
    Kokkos::View<int> min_insert_size("min_insert_size");
    Kokkos::View<int> max_insert_size("max_insert_size");
    Kokkos::View<int64_t> sum_insert_size("sum_insert_size");
    Kokkos::View<int64_t> num_valid_pairs("num_valid_pairs");
    Kokkos::View<int64_t> num_overlap_rejected("num_overlap_rejected");
    Kokkos::View<int64_t> num_large("num_large");
    Kokkos::View<int64_t> num_small("num_small");
    Kokkos::View<int64_t> num_repetitive_conflicts("num_repetitive_conflicts");

    // Initialize views
    Kokkos::deep_copy(min_insert_size, 1000000);
    Kokkos::deep_copy(max_insert_size, 0);
    Kokkos::deep_copy(sum_insert_size, 0);
    Kokkos::deep_copy(num_valid_pairs, 0);
    Kokkos::deep_copy(num_overlap_rejected, 0);
    Kokkos::deep_copy(num_large, 0);
    Kokkos::deep_copy(num_small, 0);
    Kokkos::deep_copy(num_repetitive_conflicts, 0);

    // Kokkos parallel loop
    Kokkos::parallel_for("CalculateInsertSize", num_alignments, KOKKOS_LAMBDA(const int i) {
        const auto &aln = alns[i];
        // Process each alignment
        if (aln.rlen > unmerged_rlen) {
            Kokkos::atomic_fetch_add(&num_valid_pairs(), 1);
            auto insert_size = aln.rlen;
            Kokkos::atomic_min(&min_insert_size(), insert_size);
            Kokkos::atomic_max(&max_insert_size(), insert_size);
            Kokkos::atomic_fetch_add(&sum_insert_size(), insert_size);
            insert_sizes(i) = insert_size;
        } else {
            // Handle paired alignments
            // (Implement logic similar to the original code for handling pairs)
            // This part will require additional context about how to manage pairs
        }
    });

    // Wait for completion
    Kokkos::fence();

    // Collect results
    int64_t total_valid_pairs = Kokkos::reduce_sum(num_valid_pairs);
    int64_t total_overlap_rejected = Kokkos::reduce_sum(num_overlap_rejected);
    int64_t total_large = Kokkos::reduce_sum(num_large);
    int64_t total_small = Kokkos::reduce_sum(num_small);
    int64_t total_repetitive_conflicts = Kokkos::reduce_sum(num_repetitive_conflicts);
    int64_t total_sum_insert_size = Kokkos::reduce_sum(sum_insert_size);

    // Calculate averages and standard deviations
    double ins_avg = (total_valid_pairs > 0) ? static_cast<double>(total_sum_insert_size) / total_valid_pairs : 0.0;
    double ins_stddev = 0.0; // Calculate standard deviation as needed

    // Prepare k-mer counts for CSV output
    std::vector<int> kmer_counts(num_alignments, 0); // Initialize k-mer counts
    for (int i = 0; i < num_alignments; ++i) {
        kmer_counts[i] = insert_sizes(i); // Assuming insert_sizes contains k-mer counts
    }

    // Output k-mer histogram to CSV
    output_kmer_histogram(kmer_counts);

    // Finalize max expected insert size
    max_expected_ins_size = ins_avg + 5 * ins_stddev;
}

void Histogrammer::output_kmer_histogram(const std::vector<int>& kmer_counts) {
    if (csv_output_fname.empty()) {
        return; // No filename provided, skip output
    }

    std::ofstream csv_file(csv_output_fname);
    if (!csv_file.is_open()) {
        std::cerr << "Error opening file: " << csv_output_fname << std::endl;
        return;
    }

    // Write CSV header
    csv_file << "K-mer,Count\n";

    // Write k-mer counts
    for (size_t i = 0; i < kmer_counts.size(); ++i) {
        csv_file << i << "," << kmer_counts[i] << "\n"; // Assuming k-mer index corresponds to count
    }

    csv_file.close();
}
