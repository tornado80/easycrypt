/* -------------------------------------------------------------------- */
#include <caml/mlvalues.h>
#include <caml/memory.h>
#include <caml/unixsupport.h>

#include <unistd.h>

/* -------------------------------------------------------------------- */
CAMLprim value caml_eunix_setpgid(value pid, value pgid) {
  CAMLparam2(pid, pgid);
  if (setpgid(Int_val(pid), Int_val(pgid)) != 0)
    uerror("setpgid", Nothing);
  CAMLreturn(Val_unit);
}

/* -------------------------------------------------------------------- */
#include <time.h>
#include <caml/alloc.h>

CAMLprim value caml_eunix_monotonic(value unit) {
  CAMLparam1(unit);
  struct timespec ts;
  if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0)
    uerror("clock_gettime", Nothing);
  CAMLreturn(caml_copy_double((double) ts.tv_sec + (double) ts.tv_nsec * 1e-9));
}
