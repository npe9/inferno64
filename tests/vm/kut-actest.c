/* #AC at CPL 3, outside any VMX/SVM guest: QEMU TCG's alignment check */
#include "libcflat.h"
#include "processor.h"
#include "usermode.h"

static uint64_t aligned_store(void)
{
	asm volatile("subq $16, %%rsp; movq $0, 8(%%rsp); addq $16, %%rsp" ::: "memory");
	return 0;
}

static uint64_t unaligned_store(void)
{
	asm volatile("subq $16, %%rsp; movq $0, 4(%%rsp); addq $16, %%rsp" ::: "memory");
	return 0;
}

static uint64_t unaligned_movups(void)
{
	asm volatile("subq $32, %%rsp; movups %%xmm0, 4(%%rsp); addq $32, %%rsp" ::: "memory");
	return 0;
}

int main(void)
{
	bool hit;

	write_cr4(read_cr4() | X86_CR4_OSFXSR);
	write_cr0((read_cr0() & ~X86_CR0_EM) | X86_CR0_MP | X86_CR0_AM);
	write_rflags(read_rflags() | X86_EFLAGS_AC);
	run_in_user(generate_usermode_ac, AC_VECTOR, 0, 0, 0, 0, &hit);
	report(hit, "8-byte store to a 4-byte boundary at CPL 3 raises #AC");
	run_in_user(unaligned_store, AC_VECTOR, 0, 0, 0, 0, &hit);
	report(hit, "8-byte store to a 4-byte boundary in scratch space raises #AC");
	run_in_user(aligned_store, AC_VECTOR, 0, 0, 0, 0, &hit);
	report(!hit, "aligned 8-byte store raises no #AC");
	run_in_user(unaligned_movups, AC_VECTOR, 0, 0, 0, 0, &hit);
	report(!hit, "unaligned MOVUPS raises no #AC");
	write_rflags(read_rflags() & ~X86_EFLAGS_AC);
	run_in_user(unaligned_store, AC_VECTOR, 0, 0, 0, 0, &hit);
	report(!hit, "with EFLAGS.AC clear, no #AC");
	return report_summary();
}
