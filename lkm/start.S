/* start.S — nolibc process startup stub for aarch64.
 *
 * On execve the kernel places the startup block on the stack:
 *   [sp+0]  argc
 *   [sp+8]  argv[0] ... argv[argc-1] [NULL]
 *   ...     envp[] [NULL]  auxv[] ...
 * and enters the ELF entry with x0 = 0 (not argc). So a C `_start(argc,
 * argv)` reading registers gets argc=0. This stub reads argc/argv from
 * the stack per the ABI and passes them in x0/x1 to su_main.
 */
	.text
	.global _start
	.type _start, %function
_start:
	ldr	x0, [sp]		/* x0 = argc */
	add	x1, sp, #8		/* x1 = argv */
	bl	su_main			/* su_main(argc, argv) */
	/* if su_main ever returns, exit(1) */
	mov	x0, #1
	mov	x8, #93			/* __NR_exit */
	svc	#0
	.size _start, .-_start
