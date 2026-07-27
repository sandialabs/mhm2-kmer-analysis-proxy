#pragma once

// Lightweight, opt-in per-function wall-clock timing for the kcount pipeline.
//
// Enable at runtime with:  export KCOUNT_TIME_FUNCS=1
// When disabled the only cost per timed scope is a single boolean branch, so the
// macros are safe to leave in place in the shipping code.
//
// Each instrumented pipeline function accumulates INCLUSIVE wall time (all time
// spent inside the function, including nested timed callees) and a call count.
// Accumulators are reported (rank 0) and reset at two points:
//   1. end of HashTableInserter::flush_inserts   — per insert pass (read / ctg)
//   2. end of HashTableInserter::insert_into_local_hashtable — compact step
// The same header is used by the GPU/Kokkos path (kcount_gpu.cpp + kcount-kokkos/
// or kcount-gpu/) and the host path (kcount_cpu.cpp) so their output is directly
// comparable. Device/__global__/KOKKOS_FUNCTION kernels are not timed individually;
// their host launch wrappers (e.g. gpu_insert_supermer_block, insert_supermer_block)
// capture wall time around the launch.

#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <iomanip>
#include <iostream>
#include <map>
#include <sstream>
#include <string>

namespace kcount_timing {

// Cached once: reading the env var on every scope entry would be wasteful in the
// hot per-supermer / per-read functions.
inline bool enabled() {
  static const bool on = (std::getenv("KCOUNT_TIME_FUNCS") != nullptr);
  return on;
}

struct Accum {
  double seconds = 0.0;
  uint64_t calls = 0;
};

// std::map is node-based, so element addresses stay valid across later insertions.
// That lets each call site cache a pointer to its accumulator after one lookup.
inline std::map<std::string, Accum> &table() {
  static std::map<std::string, Accum> t;
  return t;
}

inline Accum *slot_for(const char *name) { return &table()[name]; }

class ScopedTimer {
  Accum *slot;
  std::chrono::steady_clock::time_point t0;
  bool active;

 public:
  explicit ScopedTimer(Accum *s)
      : slot(s)
      , active(enabled()) {
    if (active) t0 = std::chrono::steady_clock::now();
  }
  ~ScopedTimer() {
    if (!active) return;
    slot->seconds += std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
    slot->calls++;
  }
};

// Fold a manually-timed span into a named accumulator (used by the reporting
// function so it can include itself before printing).
inline void add(const char *name, std::chrono::steady_clock::time_point t0) {
  if (!enabled()) return;
  Accum *slot = slot_for(name);
  slot->seconds += std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
  slot->calls++;
}

inline std::string report_and_reset(const std::string &label) {
  std::ostringstream os;
  os << std::fixed;
  os << "[kcount func timing] " << label << " (rank 0, inclusive per-function wall time):\n";
  double total = 0.0;
  for (auto &kv : table()) {
    total += kv.second.seconds;
    os << "  " << std::setw(34) << std::left << kv.first << std::right << std::setw(11) << std::setprecision(4)
       << kv.second.seconds << " s  " << std::setw(12) << kv.second.calls << " calls\n";
  }
  os << "  " << std::setw(34) << std::left << "(sum of above)" << std::right << std::setw(11) << std::setprecision(4)
     << total << " s\n";
  table().clear();
  return os.str();
}

}  // namespace kcount_timing

// Place at the very top of a pipeline function body. Times the enclosing scope
// (i.e. the whole function) and attributes it to the function's name.
#define KCOUNT_PIPELINE_TIMER()                                                   \
  static ::kcount_timing::Accum *_kct_slot = ::kcount_timing::slot_for(__func__); \
  ::kcount_timing::ScopedTimer _kct_timer(_kct_slot)

// Same as KCOUNT_PIPELINE_TIMER but with an explicit label. Use this when __func__
// would collide across nested wrappers (e.g. HashTableInserter::insert_supermer vs
// HashTableGPUDriver::insert_supermer both reduce to "insert_supermer").
#define KCOUNT_PIPELINE_TIMER_NAMED(name)                                       \
  static ::kcount_timing::Accum *_kct_slot = ::kcount_timing::slot_for(name);    \
  ::kcount_timing::ScopedTimer _kct_timer(_kct_slot)
