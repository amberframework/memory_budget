/* Validates the public SDK layout consumed by the Darwin adapter. */
#include <stddef.h>
#include <mach/task_info.h>
#include <sys/resource.h>
_Static_assert(offsetof(task_vm_info_data_t, phys_footprint) == 144, "physical footprint ABI changed");
_Static_assert(offsetof(task_vm_info_data_t, ledger_phys_footprint_peak) == 168, "lifetime peak ABI changed");
_Static_assert(offsetof(struct rusage_info_v4, ri_phys_footprint) == 72, "external footprint ABI changed");
_Static_assert(offsetof(struct rusage_info_v4, ri_lifetime_max_phys_footprint) == 240, "external lifetime peak ABI changed");
int main(void) { return 0; }
