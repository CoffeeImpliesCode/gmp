/* Allocation accounting for GMP's own allocator, used by the ownership tests
   only.

   GMP allocates its limb arrays and returned strings through
   `gmp_allocate_func`, which defaults to `malloc`. Nothing in this package
   installs allocator hooks, so the tests need a way to see whether those
   allocations are actually released, and whether they are released with the
   information GMP's contract asks for. This file is therefore linked into the
   test binary alone, never into the library.

   Two things are observed. The first is how many blocks are live. The second
   is whether a release reported the size of the block it was releasing: GMP
   documents `free_function` as receiving a pointer that "is always a previously
   allocated block of SIZE bytes", and a replaceable allocator may rely on that
   size, so a release that passes a placeholder is a real defect even when the
   default `free` ignores its argument.

   The counters are thread local and only run while a test has enabled them,
   so a test cannot be confused by allocations made elsewhere.

   Installing the hooks is not this file's job. `mp_set_memory_functions` has
   to be called on whichever GMP the test binary is talking to, which in a
   runtime-loading build is the provider rather than a linked archive, so the
   call is made from `alloc_probe.zig` through the package's own published
   setter. What this file owns is the accounting and the three functions GMP
   calls once they are installed. */

#include <stddef.h>
#include <stdlib.h>
#include <string.h>

static __thread int gmp_probe_counting;
static __thread unsigned long gmp_probe_live;
static __thread unsigned long gmp_probe_free_size_mismatch_count;

/* The size each live block was allocated with. The table is small on purpose:
   the tests keep only a handful of blocks alive at a time, and a full table
   stops recording rather than pretending to know. */
#define PROBE_MAX_BLOCKS 64
static __thread struct probe_block
{
  void *ptr;
  size_t size;
} gmp_probe_blocks[PROBE_MAX_BLOCKS];

/* Remember `ptr` as a live block of `size` bytes, or, with `live` zero, check
   the size a release claims and drop the record. Returns 1 when the block is
   tracked. */
static int
probe_record (void *ptr, size_t size, int live)
{
  int free_slot;
  int i;

  if (ptr == NULL)
    return 0;

  free_slot = -1;
  for (i = 0; i < PROBE_MAX_BLOCKS; i++)
    {
      if (gmp_probe_blocks[i].ptr == ptr)
	{
	  if (live)
	    gmp_probe_blocks[i].size = size;
	  else
	    {
	      if (gmp_probe_blocks[i].size != size)
		gmp_probe_free_size_mismatch_count++;
	      gmp_probe_blocks[i].ptr = NULL;
	      gmp_probe_blocks[i].size = 0;
	    }
	  return 1;
	}
      if (free_slot < 0 && gmp_probe_blocks[i].ptr == NULL)
	free_slot = i;
    }

  if (!live || free_slot < 0)
    return 0;

  gmp_probe_blocks[free_slot].ptr = ptr;
  gmp_probe_blocks[free_slot].size = size;
  return 1;
}

/* Drop the record of a block without judging a size, for the path where a
   realloc replaces it. */
static void
probe_forget (void *ptr)
{
  int i;

  for (i = 0; i < PROBE_MAX_BLOCKS; i++)
    if (gmp_probe_blocks[i].ptr == ptr)
      {
	gmp_probe_blocks[i].ptr = NULL;
	gmp_probe_blocks[i].size = 0;
	return;
      }
}

void
gmp_probe_free (void *ptr, size_t size)
{
  if (ptr != NULL && gmp_probe_counting)
    {
      gmp_probe_live--;
      probe_record (ptr, size, 0);
    }
  free (ptr);
}

void *
gmp_probe_alloc (size_t size)
{
  void *ptr = malloc (size);

  if (ptr != NULL && gmp_probe_counting)
    {
      gmp_probe_live++;
      probe_record (ptr, size, 1);
    }
  return ptr;
}

/* GMP hands the realloc implementation both sizes, so a failed growth is
   visible as one extra live allocation. A successful resize is not: the block
   count is unchanged, only the size the block was taken with. */
void *
gmp_probe_realloc (void *ptr, size_t old_size, size_t new_size)
{
  void *result;

  if (ptr == NULL)
    return gmp_probe_alloc (new_size);

  if (new_size == 0)
    {
      gmp_probe_free (ptr, old_size);
      return NULL;
    }

  if (gmp_probe_counting)
    probe_forget (ptr);

  result = realloc (ptr, new_size);

  if (result != NULL && gmp_probe_counting)
    probe_record (result, new_size, 1);

  return result;
}

/* Clear the bookkeeping and start counting on this thread.

   Installing the hooks is `alloc_probe.zig`'s job, not this file's: it goes
   through GMP's `mp_set_memory_functions`, and in a runtime-loading build that
   call has to reach the provider through the generated dispatch rather than
   through a link-time symbol. */
void
gmp_probe_reset (void)
{
  memset (gmp_probe_blocks, 0, sizeof gmp_probe_blocks);
  gmp_probe_free_size_mismatch_count = 0;
  gmp_probe_live = 0;
  gmp_probe_counting = 1;
}

/* Stop counting. The hooks stay installed until the caller puts GMP's own
   back, which it does the same way it took them out. */
void
gmp_probe_stop (void)
{
  gmp_probe_counting = 0;
}

/* Number of live allocations made by this thread since `gmp_probe_reset`. */
unsigned long
gmp_probe_live_allocations (void)
{
  return gmp_probe_live;
}

/* Number of releases since `gmp_probe_reset` that reported a size other than
   the one their block was allocated with. */
unsigned long
gmp_probe_free_size_mismatches (void)
{
  return gmp_probe_free_size_mismatch_count;
}
