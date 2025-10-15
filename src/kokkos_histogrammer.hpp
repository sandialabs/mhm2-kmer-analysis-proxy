#pragma once

/* Derived from MetaHipMer2 histogrammer
*/

#include <Kokkos_Core.hpp>
#include <string>
#include <vector> // Include vector for storing k-mer counts
#include "alignments.hpp"
#include <chrono> // Include for timestamp generation
#include <iomanip> // Include for formatting

class Histogrammer {
    int expected_ins_avg;
    int expected_ins_stddev;
    int max_expected_ins_size;
    std::string dump_large_alns_fname;
    std::string csv_output_fname; // Member variable for CSV output

public:
    int ins_avg;
    int ins_stddev;

    // Constructor that generates a timestamped CSV filename
    Histogrammer(int expected_ins_avg, int expected_ins_stddev)
        : expected_ins_avg(expected_ins_avg)
        , expected_ins_stddev(expected_ins_stddev)
        , max_expected_ins_size(expected_ins_avg + 8 * expected_ins_stddev)
        , dump_large_alns_fname("") 
    {
        // Generate timestamp
        auto now = std::chrono::system_clock::now();
        auto in_time_t = std::chrono::system_clock::to_time_t(now);
        std::tm buf;
        localtime_s(&buf, &in_time_t); // Use localtime_r for thread safety

        // Format the timestamp
        std::ostringstream oss;
        oss << std::put_time(&buf, "%Y-%m-%d_%H_%M");
        std::string timestamp = oss.str();

        // Set the CSV output filename
        csv_output_fname = "mhm2_kmer_histogram_" + timestamp + ".csv";
    }

    void calculate_insert_size(Alns &alns);
    void output_kmer_histogram(const std::vector<int>& kmer_counts); // Method for CSV output
};
