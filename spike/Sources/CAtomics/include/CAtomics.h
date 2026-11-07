#ifndef CATOMICS_H
#define CATOMICS_H
#include <stdint.h>

/// Relaxed atomic helpers on plain aligned integers. Needed because Swift's Synchronization.Atomic
/// requires macOS 15, while the app targets macOS 14.2 (see REPORT.md).
static inline void vm_store_u32(uint32_t *p, uint32_t v) { __atomic_store_n(p, v, __ATOMIC_RELAXED); }
static inline uint32_t vm_load_u32(const uint32_t *p) { return __atomic_load_n(p, __ATOMIC_RELAXED); }
static inline void vm_add_u64(uint64_t *p, uint64_t v) { __atomic_fetch_add(p, v, __ATOMIC_RELAXED); }
static inline uint64_t vm_load_u64(const uint64_t *p) { return __atomic_load_n(p, __ATOMIC_RELAXED); }
#endif
