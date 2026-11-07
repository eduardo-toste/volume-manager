#ifndef CSYSTEMSHIMS_H
#define CSYSTEMSHIMS_H

#include <sys/types.h>

/// Read-only query: which process is "responsible" for a given PID.
/// The only private API allowed in the project (SPEC 12.9.2). Declared
/// weak_import so the app still loads if the symbol disappears.
extern pid_t responsibility_get_pid_responsible_for_pid(pid_t pid)
    __attribute__((weak_import));

#endif /* CSYSTEMSHIMS_H */
