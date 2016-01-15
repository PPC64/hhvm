#ifndef incl_ETCH_HELPERS_H
#define incl_ETCH_HELPERS_H

#if defined(__CYGWIN__) || defined(__MINGW__) || defined(_MSC_VER)
#define CFI(x)            .cfi_##x
#define CFI2(x, y)        .cfi_##x y
#define CFI3C(x, y, z)    .cfi_##x y##, z
#define ETCH_ALIGN16      .align 16
#define ETCH_ALIGN8       .align 8
#define ETCH_ALIGN4       .align 4
#define ETCH_SECTION(x)   .section .text.x
#define ETCH_SIZE(x)      /* Not used with PE/COFF on windows */
#define ETCH_NAME(x)      x
#define ETCH_LABEL(x)     .L##x
#define ETCH_TYPE(x, y)   /* Not used on Windows */
#define ETCH_NAME_REL(x)  $ x
#define ETCH_ARG1         %rcx
#define ETCH_ARG2         %rdx
#define ETCH_ARG3         %r8
#define ETCH_ARG4         %r9
#define ETCH_ARG5         %r10  /* Use r10 here */
#define ETCH_ARG6         %r11  /* Use r11 here */
/* Borrow scratch registers for the 5th and 6th args
 * since Windows only has four registers args in its ABI */
#define ETCH_GET_ARG5     mov 0x28(%rsp), %r10
#define ETCH_GET_ARG6     mov 0x30(%rsp), %r11
#define ETCH_RET1         %rax
/* VM Registers must match definition on abi-x64.h */
#define ETCH_VMFP         %rbp
#define ETCH_VMSP         %rbx
#define ETCH_VMTL         %r12
/* Service Request Registers must match svcreq_args list on abi-x64.cpp */
#define ETCH_SVCREQ_REQ   %rdi
#define ETCH_SVCREQ_STUB  %r10
#define ETCH_SVCREQ_ARG1  %rsi
#define ETCH_SVCREQ_ARG2  %rdx
#define ETCH_SVCREQ_ARG3  %rcx
#define ETCH_SVCREQ_ARG4  %r8

#elif defined(__APPLE__)
#define CFI(x)            .cfi_##x
#define CFI2(x, y)        .cfi_##x y
#define CFI3C(x, y, z)    .cfi_##x y##, z
#define ETCH_ALIGN16      .align 4 // on OSX this is 2^value
#define ETCH_ALIGN8       .align 3
#define ETCH_ALIGN4       .align 2
#define ETCH_SECTION(x)   .text
#define ETCH_SIZE(x)      /* not used on OSX */
#define ETCH_NAME(x)      _##x
#define ETCH_LABEL(x)     .L##_##x
#define ETCH_TYPE(x, y)   /* not used on OSX */
#define ETCH_NAME_REL(x)  _##x@GOTPCREL(%rip)
#define ETCH_ARG1         %rdi
#define ETCH_ARG2         %rsi
#define ETCH_ARG3         %rdx
#define ETCH_ARG4         %rcx
#define ETCH_ARG5         %r8
#define ETCH_ARG6         %r9
#define ETCH_GET_ARG5     /* not used */
#define ETCH_GET_ARG6     /* not used */
#define ETCH_RET1         %rax
/* VM Registers must match definition on abi-x64.h */
#define ETCH_VMFP         %rbp
#define ETCH_VMSP         %rbx
#define ETCH_VMTL         %r12
/* Service Request Registers must match svcreq_args list on abi-x64.cpp */
#define ETCH_SVCREQ_REQ   %rdi
#define ETCH_SVCREQ_STUB  %r10
#define ETCH_SVCREQ_ARG1  %rsi
#define ETCH_SVCREQ_ARG2  %rdx
#define ETCH_SVCREQ_ARG3  %rcx
#define ETCH_SVCREQ_ARG4  %r8

#elif defined(__powerpc64__)
#define CFI(x)            .cfi_##x
#define CFI2(x, y)        .cfi_##x y
#define CFI3C(x, y, z)    .cfi_##x y##, z
#define ETCH_ALIGN16      .align 16
#define ETCH_ALIGN8       .align 8
#define ETCH_ALIGN4       .align 4
#define ETCH_SECTION(x)   .section .text.x,"ax"
#define ETCH_SIZE(x)      .size x, .-x
#define ETCH_NAME(x)      x
#define ETCH_LABEL(x)     .L##x
#define ETCH_TYPE(x, y)   .type x, y
#define ETCH_NAME_REL(x)  $ x
#define ETCH_ARG1         %r3
#define ETCH_ARG2         %r4
#define ETCH_ARG3         %r5
#define ETCH_ARG4         %r6
#define ETCH_ARG5         %r7
#define ETCH_ARG6         %r8
#define ETCH_RET1         %r3
/* VM Registers must match definition on abi-ppc64.h */
#define ETCH_V_ONE        1
#define ETCH_R_ONE        %r28
#define ETCH_VMFP         %r31
#define ETCH_VMSP         %r29
#define ETCH_VMTL         %r30
/* Service Request Registers must match svcreq_args list on abi-ppc64.cpp */
#define ETCH_SVCREQ_REQ   %r3
#define ETCH_SVCREQ_STUB  %r8
#define ETCH_SVCREQ_ARG1  %r4
#define ETCH_SVCREQ_ARG2  %r5
#define ETCH_SVCREQ_ARG3  %r6
#define ETCH_SVCREQ_ARG4  %r7

#else /* Other x86 (e.g. linux) */
#define CFI(x)            .cfi_##x
#define CFI2(x, y)        .cfi_##x y
#define CFI3C(x, y, z)    .cfi_##x y##, z
#define ETCH_ALIGN16      .align 16
#define ETCH_ALIGN8       .align 8
#define ETCH_ALIGN4       .align 4
#define ETCH_SECTION(x)   .section .text.x,"ax"
#define ETCH_SIZE(x)      .size x, .-x
#define ETCH_NAME(x)      x
#define ETCH_LABEL(x)     .L##x
#define ETCH_TYPE(x, y)   .type x, y
#define ETCH_NAME_REL(x)  $ x
#define ETCH_ARG1         %rdi
#define ETCH_ARG2         %rsi
#define ETCH_ARG3         %rdx
#define ETCH_ARG4         %rcx
#define ETCH_ARG5         %r8
#define ETCH_ARG6         %r9
#define ETCH_GET_ARG5     /* not used */
#define ETCH_GET_ARG6     /* not used */
#define ETCH_RET1         %rax
/* VM Registers must match definition on abi-x64.h */
#define ETCH_VMFP         %rbp
#define ETCH_VMSP         %rbx
#define ETCH_VMTL         %r12
/* Service Request Registers must match svcreq_args list on abi-x64.cpp */
#define ETCH_SVCREQ_REQ   %rdi
#define ETCH_SVCREQ_STUB  %r10
#define ETCH_SVCREQ_ARG1  %rsi
#define ETCH_SVCREQ_ARG2  %rdx
#define ETCH_SVCREQ_ARG3  %rcx
#define ETCH_SVCREQ_ARG4  %r8
#endif

#endif // incl_ETCH_HELPERS_H
