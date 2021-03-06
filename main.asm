/* Mini forth interpreter based on eForth with simplifications

   Overview
   ========
   This is a forth interpreter inspired by eForth, with simplifications.
   Its goal is to be as compact as possible so it's possible to assemble itself from Forth.
   The following simplifications have be made with respect to the usual eForth implementations:
   Memory map simplifications: just a 1K param stack, and a RAM zone with dic and data
     growing from the low addresses and the return stack growing from the high addresses
   No USER pointer, only one user is supported
   Only a single word list, no vocabularies for each user.
   Favor F2012 words and semantics over the older standards if different.
   
   Builtin words are stored in RODATA. They cant be changed, but can be
   overriden by user entries.
   
   Hardware Registers
   ------------------

   The forth interpreter uses registers for its internal use.
   SP is used as parameter stack pointer.
   Y  is used as return stack pointer.
   X and D can be used for calculations.

   Data structures
   ===============

   Interpreter variables
   ---------------------
   
   The state of the interpreter is described in several variables, stored in the internal HC11 RAM.
   Here is a description of what each variable does.
   IP   - The instruction pointer. Points to the next instruction to execute.
   HEREP - pointer to the next free byte in the Data Space
   LASTP - pointer to the last definition. Initialized to the last builtin word definition.
   STATP - pointer containing 0x0000 when interpreting and 0xFFFF when compiling.
   BASE - Contains the value of the current number conversion base
   
   Dictionary and Data space
   -------------------------

   The data space is used to store new word definitions and user data structures.
   It grows from low addresses (0100h) to upper addresses in the external memory.

   User definitions are allocated in the data space. The definitions are added
   one after the other, linking the new one to the previous one. The pointer to
   the last definition is maintained in LAST. This pointer is initialized to the
   last entry in the builtin dictionary.

   Dictionary entry
   ----------------

   Each entry has the following structure:
   2 bytes: pointer to previous entry
   N bytes: the word itself, NULL terminated. Only ASCII values 32-127 are allowed.
   1 byte:  flags. It seems that we need 2 flags:
            - immediate: word has to be executed even while compiling.
            - compile only: word cannot be executed (control structures?).
   (NOTE: to save one byte per word, the flags can be set in the terminator itself
   if the name is terminated by a byte having the most significant bit set instead of zero.)
   The 3 previous bytes form the word header. It is only inspected when searching for words.
   2 bytes: code pointer (ITC) - address of native code that implements this routine. Special value ENTER
            is used to handle compiled forth definitions.
   A forth word pointer, as used in user definitions, is a pointer to the code pointer for the word.
   
   Parameter stack
   ---------------
   The parameter stack is used to store temporary data items. It shoud not grow
   to an extremely large value, so it size is fixed when the interpreter is
   initialized.
   The stack grows down, it starts at the end of the RAM, and the storage
   PUSH is post-decrement, push LSB first.
   POP  is pre-increment, pull MSB first.
   The stack pointer always point at the next free location in the stack.
   For the moment underflow and overflows are not detected.

   The parameter stack is also used using push/rts to simplify the inner interpreter.
   This means that we need one more item to jump to the next forth opcode. This is important:
   if the forth stack underflows, we still need the stack to work for one more item.
   This will not work if a word produces a double underflow.

   Return stack
   ------------
   The return stack is used to push return addresses when nesting word
   executions. It is also used to manage control flow structures. Since this
   space is used a lot by complex programs, it is expected that limiting its
   size might prevent large programs from executing. Its size is only limited
   by the growth of the data space. It is initialized just below the maximum
   span of the parameter stack (7C00h), and it can grows down until the return stack
   pointer hits HERE.
   
   To push to the return stack, we store at 0,Y then dey dey (post-decrement)
   To pop from return stack, we increment Y by 2 with ldab #2 aby then load at 0,y (pre-increment)
   Top of stack can be peeked by index addressing using an offset of 2.
   For the moment underflow and overflows are not detected.

   Interpreter
   -----------
   The intepreter receives chars from the input device until an end of line is
   reached. The compiler is then executed, which translates input to an unnamed
   word. The unnamed word is then executed.

   Compilation
   -----------
   Each word is recognized and replaced by the address of its code pointer.
   Note this is not the address of the definition but the code pointer itself.
   The last code pointer entry of a compiled word is a RETURN, which pops an
   address from the return stack and use it as new instruction pointer.

   The compiler uses all the CPU registers, so the previous contents of the
   forth registers is saved before compilation and restored after.

*/

	/* System definitions */
	.equ INIT , 0x3D
	/* Serial definitions */
	.equ BAUD , 0x2B
	.equ SCCR1, 0x2C
	.equ SCCR2, 0x2D
	.equ SCSR , 0x2E
	.equ SCDR , 0x2F
	.equ SCSR_RDRF     ,0x20 /* Receive buffer full */
	.equ SCSR_TDRE     ,0x80 /* Transmit buffer empty */

	/* Forth memory map */
	.equ	SP_ZERO  , 0x8000-5	/* End of RAM (address of first free byte) */
	.equ	RP_ZERO  , 0x7C00-2	/* 1K before param stack (address of first free word)*/
	.equ	HERE_ZERO, 0x0100	/* Start of user data space */

	/* Forth config */
	.equ	TIB_LEN, 80
	.equ	USE_RTS, 1		/* slightly smaller code using RTS to opcode jmp */
	.equ	USE_MUL, 1		/* use HC11 multiplier instead of eforth UM* routine */
	.equ	USE_DIV, 1		/* use HC11 divider instead of eforth UM/MOD routine */

	.equ	USE_SPI, 1		/* Enable words for SPI master transactions (specific to sys11) */
	.equ	USE_BLOCK, 0		/* Enable words for SPI master transactions (specific to sys11) */

	/* Word flags - added to length, so word length is encoded on 6 bits*/
	.equ	WORD_IMMEDIATE   , 0x80
	.equ	WORD_COMPILEONLY , 0x40
	.equ	WORD_LENMASK     , 0x3F

	/* Define variables in internal HC11 RAM */
	.data
IP:	.word	0	/* Instruction pointer */
HEREP:	.word	0	/* Pointer to HERE, the address of next free byte in dic/data space */
LASTP:	.word	0	/* Pointer to the last defined word entry */
TXVEC:	.word	0	/* Pointer to the word implementing EMIT */
RXVEC:	.word	0	/* Pointer to the word implementing ?KEY */
BASEP:	.word	0	/* Value of the base used for number parsing */
HOLDP:	.word	0	/* Pointer used for numeric output */
STATP:  .word   0       /* Pointer to word implementing the current behaviour: compile/interpret */
HANDP:	.word	0	/* Exception handler pointer */
CURDP:	.word	0	/* Pointer to the word currently being defined. Stored in word : */
LSTCRP:	.word	0	/* Pointer to the last created action word (used by DOES>) */
CSPP:	.word	0	/* Storage for stack pointer value used for checks */

	/* Input text buffering */

pTEMP:	.space	6	/* Temp variable used in LPARSE, UM* and UM/MOD */
TOINP:	.word	0	/* Parse position in the input buffer */
NTIBP:	.word	0	/* Number of received characters in current line */
STIBP:	.word	0	/* Size of the tib */
TIBP:   .word	0	/* Address of the actual input buffer, to allow switching to other buffers */
TIBBUF:	.space	TIB_LEN	/* Space for Default Input buffer */

/*===========================================================================*/
/* Structure of a compiled word: We have a suite of code pointers. Each code pointer has to be executed in turn.
 * The last code pointer of the list has to be "exit", which returns to the caller, or a loop.
 * +---+------------+------+------+------+-----+------+
 * |HDR| code_ENTER | PTR1 | PTR2 | PTR3 | ... | EXIT |
 * +---+------------+------+------+------+-----+------+
 *                     ^      ^           
 *                     IP    nxtIP=IP+2    
 * IP ONLY POINTS AT WORD ADDRESSES! Never to asm code addresses. Thats why
   words implemented in assembly are only made of a code pointer.
 */

	.text
/*===========================================================================*/
/* Startup code */
/*===========================================================================*/
	.globl _start
_start:

	/* Map registers in zero page */
	clra
	staa	INIT+0x1000

	/* Setup the runtime environment */
	lds	#SP_ZERO	/* Parameter stack at end of RAM. HC11 pushes byte per byte. */
	ldy	#RP_ZERO	/* Return stack 1K before end of RAM. We push word per word. */
	ldx	#BOOT		/* load pointer to startup code, skipping the native ENTER pointer! */
	bra	NEXT2		/* Start execution */

/*===========================================================================*/
/* Core routines for word execution */
/*===========================================================================*/

/*---------------------------------------------------------------------------*/
/* Execute the next word. IP is incremented, stored back, and the cell pointed
 * by IP is loaded. It contains a code address, which is jumped at.
 * This is not a forth word.
 */
	.text
	.globl PUSHD /* ensure GNU as makes this symbol visible */
PUSHD:
	pshb			/* We can use this instead of next to push a result before ending a word */
	psha
NEXT:
	ldx	*IP		/* Get the instruction pointer */
NEXT2:				/* We can call here if X already has the value for IP */
	inx			/* Increment IP to look at next word */
	inx
	stx	*IP		/* Save IP for next execution round */
	dex			/* Redecrement, because we need the original IP */
	dex			/* Now X contains pointer to pointer to code (aka IP, pointer to forth opcode) */
	ldx	0,X		/* Now X contains pointer to code (forth opcode == address of first cell in any word) */
doEXECUTE:
	ldd	0,X		/* Now D contains the code address to execute opcode (a code_THING value) */
.if USE_RTS
	pshb
	psha
	rts			/* X contains new IP, D contains code_ address, pushed on stack. */
.else
	xgdx
	jmp	0,X		/* D contains new IP, X contains code_ address */
.endif

/*---------------------------------------------------------------------------*/
/* Starts execution of a compiled word. The current IP is pushed on the return stack, then we jump */
/* This function is always called by the execution of NEXT. */
code_ENTER:
	/* This is called with the address of instruction being run (aka forth opcode) in D*/
.if USE_RTS
	/* Preserve X that contains new IP */
	ldd	*IP
	std	0,Y		/* Push the next IP to be executed after return from this thread */
.else
	/* Preserve D that contains new IP */
	ldx	*IP
	stx	0,Y		/* Push the next IP to be executed after return from this thread */
.endif
	dey			/* Post-Decrement Y by 2 to push */
	dey
.if USE_RTS
.else
	/* IP was in D, transfer in X */
	xgdx
.endif
	inx			/* Increment, now X is the address of the first word in the list */
	inx
	bra	NEXT2		/* Manage next opcode address */

/*---------------------------------------------------------------------------*/
/* CORE 6.1.1380 EXIT ( -- ) End the execution of a word. The previous IP is on the return stack, so we pull it. */
	.section .rodata
word_RETURN:
    .word   0
    .byte   4
    .ascii  "EXIT"
RETURN:
	.word	code_RETURN
	.text
code_RETURN:
	ldab	#2
	aby			/* Pre-Increment Y by 2 to pop */
	ldx	0,Y		/* Pop previous value for IP from top of return stack */
	bra	NEXT2

/*===========================================================================*/
/* Internal words */
/* These words have no header because they cannot be executed by the user.
 * However, they are used to implement compiled routines.
 */
/*===========================================================================*/

/*---------------------------------------------------------------------------*/
/* Do litteral: Next cell in thread is an immediate litteral value to be pushed. */
	.section .rodata
IMM:
	.word	code_IMM
	.text
code_IMM:
	ldx	*IP	/* Load next word in D */
	ldd	0,X
	inx		/* Increment IP to look at next word */
	inx
	stx	*IP	/* IP+1->IP Save IP for next execution */
	bra	PUSHD

/*---------------------------------------------------------------------------*/
/* Load next word in IP */
	.section .rodata
BRANCH:
	.word	code_BRANCH
	.text
code_BRANCH:
	ldx	*IP	/* Load next word in X */
	ldx	0,X
	bra	NEXT2

/*---------------------------------------------------------------------------*/
/* Pull a value. If zero, load next word in IP */
	.section .rodata
BRANCHZ:
	.word	code_BRANCHZ
	.text
code_BRANCHZ:
	ldx	*IP	/* Load next word in D */
	ldd	0,X	/* D contains branch destination */
	inx
	inx
	stx	*IP	/* Make IP look at next word after branch address */

	pulx		/* Get flag */
	cpx	#0x0000 /* TODO make it more efficient  - not certain if possible */
	beq	qbranch1
	bra	NEXT	/* Not zero */

qbranch1: /* Pulled value was zero, do the branch */
	xgdx /* store branch destination (D) in X, then execute at this point */
	bra	NEXT2

/*---------------------------------------------------------------------------*/
/* Pull a value from R stack. If zero, skip, else decrement and jump to inline target */
	.section .rodata
JNZD:
	.word	code_JNZD
	.text
code_JNZD:
	ldd	2,y		/* get counter on return stack */
	beq	.Lbranch	/* index is zero -> loop is complete */
	subd	#1		/* no, bump the counter */
	std	2,y		/* and replace on stack */
	bra	code_BRANCH	/* branch to target using existing code that load target from next word */
.Lbranch:
	ldab	#2		/* Remove counter from return stack. code efficiency similar to aby,aby */
	aby
	ldx	*IP		/* get the IP */
	inx
	inx			/* and get addr past branch target */
	bra	NEXT2		/* and go do next word */

/*===========================================================================*/
/* Native words */
/*===========================================================================*/

/*---------------------------------------------------------------------------*/
/* PROPRIETARY ( -- ) init HC11 SCI */
/* The first time we use the dic section, make sure this section is loaded */
	.section .dic,"a",@progbits
word_IOINIT:
	.word	word_RETURN
	.byte	6
	.ascii	"IOINIT"
IOINIT:
	.word	code_IOINIT
	.text
code_IOINIT:
	ldaa	#0x30	/* 9600 bauds at 8 MHz */
	staa	*BAUD
	ldaa	#0x0C
	staa	*SCCR2
	bra	NEXT

/*---------------------------------------------------------------------------*/
/* PROPRIETARY ( txbyte -- ) - Transmit byte on HC11 SCI */
	.section .dic
word_IOTX:
	.word	word_IOINIT
	.byte	5
	.ascii	"IOTX!"
IOTX:
	.word	code_IOTX
	.text
code_IOTX:
	pula
	pulb
.Ltx:
	brclr	*SCSR #SCSR_TDRE, .Ltx
	stab	*SCDR
	bra	NEXT

/*---------------------------------------------------------------------------*/
/* PROPRIETARY ( -- rxbyte TRUE | FALSE ) - Receive byte from HC11 SCI */
	.section .dic
word_IORX:
	.word	word_IOTX
	.byte	5
	.ascii	"?IORX"
IORX:
	.word	code_IORX
	.text
code_IORX:
	clra
	brclr	*SCSR #SCSR_RDRF, norx	/* RX buffer not full: skip to return FALSE */
	ldab	*SCDR
	pshb
	psha
	/* Push the TRUE flag */
	coma		/* Turn 00 into FF in just one byte! */
	tab		/* copy FF from A to B, now we have FFFF in D, which is TRUE */
	bra	PUSHD
norx:
	clrb		/* Finish FALSE cell */
	bra	PUSHD

/*---------------------------------------------------------------------------*/
/* CORE 6.1.1370 (... ca -- ...) Execute the word whose address is on the stack */
	.section .dic
word_EXECUTE:
	.word	word_IORX
	.byte	7
	.ascii	"EXECUTE"
EXECUTE:
	.word	code_EXECUTE

	.text
code_EXECUTE:
	pulx		/* Retrieve a word address from stack. This address contains a code pointer */
	bra	doEXECUTE


/*---------------------------------------------------------------------------*/
/* CORE 6.1.0010 (d a -- ) Store a cell at address*/
	.section .dic
word_STORE:
	.word	word_EXECUTE
	.byte	1
	.ascii	"!"
STORE:
	.word	code_STORE

	.text
code_STORE:
	pulx	/* TOS contains address */
	pula	/* PREV contains data */
	pulb
	std	0,X
	bra	NEXT

/*---------------------------------------------------------------------------*/
/* CORE 6.1.0850 (c a -- ) Store a char at address */
	.section .dic
word_CSTORE:
	.word	word_STORE
	.byte	2
	.ascii	"C!"
CSTORE:
	.word	code_CSTORE

	.text
code_CSTORE:
	pulx	/* TOS contains address */
	pula	/* PREV contains data, A = MSB, discarded */
	pulb	/* B = LSB */
	stab	0,X
	bra	NEXT

/*---------------------------------------------------------------------------*/
/* CORE 6.1.0650 (a -- d) Load a cell at given address*/
	.section .dic
word_LOAD:
	.word	word_CSTORE
	.byte	1
	.ascii	"@"
LOAD:
	.word	code_LOAD

	.text
code_LOAD:
	pulx
	ldd	0,X
	bra	PUSHD

/*---------------------------------------------------------------------------*/
/* CORE 6.1.0870 (a -- d) Load a cell at given address*/
	.section .dic
word_CLOAD:
	.word	word_LOAD
	.byte	2
	.ascii	"C@"
CLOAD:
	.word	code_CLOAD

	.text
code_CLOAD:
	pulx
	clra
	ldab	0,X
	bra	PUSHD

/*---------------------------------------------------------------------------*/
/* CORE 6.1.2060 R> ( -- x ) ( R: x -- ) */
	.section .dic
word_RFROM:
	.word word_CLOAD
	.byte	2 + WORD_COMPILEONLY
	.ascii	"R>"
RFROM:
	.word code_RFROM

	.text
code_RFROM:
	ldab	#2	/* Preinc Y to pull from Return Stack */
	aby
	ldd	0,Y
	bra	PUSHD

/*---------------------------------------------------------------------------*/
/* CORE 6.1.0580 >R ( -- x ) ( R: x -- ) */
	.section .dic
word_TOR:
	.word	word_RFROM
	.byte	2 + WORD_COMPILEONLY
	.ascii	">R"
TOR:
	.word	code_TOR

	.text
code_TOR:
	pula
	pulb
	std	0,Y
	dey		/* Postdec Y to push on Return Stack */
	dey
	bra	NEXT

/*---------------------------------------------------------------------------*/
/* CORE 6.1.2070 R@ ( -- x ) ( R: x -- x ) */
	.section .dic
word_RLOAD:
	.word	word_TOR
	.byte	2
	.ascii	"R@"
RLOAD:
	.word	code_RLOAD

	.text
code_RLOAD:
	ldd	2,Y
	bra	PUSHD

/*---------------------------------------------------------------------------*/
/* PROPRIETARY */
	.section .dic
word_SPLOAD:
	.word	word_RLOAD
	.byte	3
	.ascii	"SP@"
SPLOAD:
	.word	code_SPLOAD
	.text
code_SPLOAD:
	tsx
	dex
	pshx
	bra	NEXT

/*---------------------------------------------------------------------------*/
	.section .dic
word_SPSTORE:
	.word	word_SPLOAD
	.byte	3
	.ascii	"SP!"
SPSTORE:
	.word	code_SPSTORE
	.text
code_SPSTORE:
	pulx
	inx
	txs
	bra	NEXT

/*---------------------------------------------------------------------------*/
	.section .dic
word_RPLOAD:
	.word	word_SPSTORE
	.byte	3
	.ascii	"RP@"
RPLOAD:
	.word	code_RPLOAD
	.text
code_RPLOAD:
	pshy
	bra	NEXT

/*---------------------------------------------------------------------------*/
	.section .dic
word_RPSTORE:
	.word	word_RPLOAD
	.byte	3 + WORD_COMPILEONLY
	.ascii	"RP!"
RPSTORE:
	.word	code_RPSTORE
	.text
code_RPSTORE:
	puly
	bra	NEXT

/*---------------------------------------------------------------------------*/
/* CORE 6.1.1290 DUP ( u -- u u ) */
	.section .dic
word_DUP:
	.word	word_RPSTORE
	.byte	3
	.ascii	"DUP"
DUP:
	.word	code_DUP

	.text
code_DUP:
	tsx			/* Get stack pointer +1 in X */
	ldd	0,X		/* Load top of stack in D */
	bra	PUSHD		/* This will push top of stack again */

/*---------------------------------------------------------------------------*/
/* CORE 6.1.1990 OVER ( u1 u2 -- u1 u2 u1 ) */
	.section .dic
word_OVER:
	.word	word_DUP
	.byte	4
	.ascii	"OVER"
OVER:
	.word	code_OVER

	.text
code_OVER:
	tsx			/* Get stack pointer +1 in X */
	ldd	2,X		/* Load value before top of stack */
	bra	PUSHD

/*---------------------------------------------------------------------------*/
/* CORE 6.1.2260 SWAP ( u v -- v u ) */
	.section .dic
word_SWAP:
	.word	word_OVER
	.byte	4
	.ascii	"SWAP"
SWAP:
	.word	code_SWAP

	.text
code_SWAP:
	pulx
	pula
	pulb
	pshx
	bra	PUSHD		/* This will push top of stack again */

/*---------------------------------------------------------------------------*/
/* CORE 6.1.1260 DROP ( u -- ) */
	.section .dic
word_DROP:
	.word	word_SWAP
	.byte	4
	.ascii	"DROP"
DROP:
	.word	code_DROP

	.text
code_DROP:
	pulx			/* Get a parameter and discard it */
	bra	NEXT		/* This will push top of stack again */

/*===========================================================================*/
/* Math */
/*===========================================================================*/

/*---------------------------------------------------------------------------*/
/* PROPRIETARY UM+ ( u v -- u+v cy ) - Add two cells, return sum and carry flag */
	.section .dic
word_UPLUS:
	.word	word_DROP
	.byte	3
	.ascii	"UM+"
UPLUS:
	.word	code_UPLUS

	.text
code_UPLUS:
	pula
	pulb		/*pull TOS*/
	tsx
	addd	0,X	/*add to new TOS, sets N,Z,C,V */
	std	0,X	/*Replace TOS, does not affect carry, clears V, changes N and Z */
	ldab	#0	/*CLRB clears carry, LDAB leaves it.*/
	rolb		/*Get carry flag in B0 (D.LSB)*/
	clra		/*Clear A (D.MSB)*/
	bra	PUSHD	/* Push second return item and do next word */

/*---------------------------------------------------------------------------*/
/* CORE 6.1.0120 + ( u v -- u+v ) - Add two cells */
/* We do a native version for speed */
	.section .dic
word_PLUS:
	.word	word_UPLUS
	.byte	1
	.ascii	"+"
PLUS:
	.word	code_PLUS

	.text
code_PLUS:
	pula
	pulb
	tsx
	addd	0,X
	std	0,X
	bra	NEXT

/*---------------------------------------------------------------------------*/
/* CORE 6.1.2490 XOR ( u v -- u^v ) */
	.section .dic
word_XOR:
	.word	word_PLUS
	.byte	3
	.ascii	"XOR"
XOR:
	.word	code_XOR

	.text
code_XOR:
	pula
	pulb
	tsx
	eora	0,X
	eorb	1,X
	pulx
	bra	PUSHD

/*---------------------------------------------------------------------------*/
/* CORE 6.1.0720 AND ( u v -- u&v ) */
	.section .dic
word_AND:
	.word	word_XOR
	.byte	3
	.ascii	"AND"
AND:
	.word	code_AND

	.text
code_AND:
	pula
	pulb
	tsx
	anda	0,X
	andb	1,X
	pulx
	bra	PUSHD

/*---------------------------------------------------------------------------*/
/* CORE 6.1.1980 OR ( u v -- u|v ) */
	.section .dic
word_OR:
	.word	word_AND
	.byte	2
	.ascii	"OR"
OR:
	.word	code_OR

	.text
code_OR:
	pula
	pulb
	tsx
	oraa	0,X
	orab	1,X
	pulx
	bra	PUSHD

/*---------------------------------------------------------------------------*/
/* CORE 6.1.0250 0< ( u -- u<0 ) push true if pull negative */
	.section .dic
word_ZLESS:
	.word	word_OR
	.byte	2
	.ascii	"0<"
ZLESS:
	.word	code_ZLESS

	.text
code_ZLESS:
	pula
	pulb
	tsta		/* check high bit of MSB */
	bmi	.Ltrue	/* branch if negative */
	ldd     #0x0000
	bra	PUSHD
.Ltrue:
	ldd     #0xFFFF
	bra	PUSHD

/*===========================================================================*/
/* Other forth words implemented in forth.
 * These words are pre-compiled lists, they are all executed by code_ENTER.
 * The following words can only be pointers to cells containing references to
 * other words. Direct pointers to cells containing code addresses are not
 * possible.
 */
/*===========================================================================*/

/*===========================================================================*/
/* Basic ops */
/*===========================================================================*/

/*---------------------------------------------------------------------------*/
/* PROPRIETARY ( wordptr -- ) Execute the forth word whose address is stored in the passed pointer */
	.section .dic
word_LOADEXEC:
	.word	word_ZLESS
	.byte	5
	.ascii	"@EXEC"
LOADEXEC:
	.word	code_ENTER	/* ptr */
	.word	LOAD		/* word */
	.word	DUP		/* word word */
	.word	BRANCHZ, noexec /* word, exit if null */
	.word	EXECUTE		/* Execute the loaded forth word.*/
noexec:
	.word	RETURN		/* Nothing is stored. just return. */

/*---------------------------------------------------------------------------*/
/* CORE 6.1.1320 EMIT ( c -- ) - Write char on output device */
	.section .dic
word_EMIT:
	.word	word_LOADEXEC
	.byte	4
	.ascii	"EMIT"
EMIT:
	.word	code_ENTER
	.word	IMM,TXVEC
	.word	LOADEXEC
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* FACILITY 10.6.1.1755 ?KEY ( -- c t | f ) - return input character and true, or a false if no input. */
	.section .dic
word_QKEY:
	.word	word_EMIT
	.byte	4
	.ascii	"?KEY"
QKEY:
	.word	code_ENTER
	.word	IMM,RXVEC
	.word	LOADEXEC
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* CORE 6.1.1750 KEY ( -- c ) - wait for a character on input device and return it */
	.section .dic
word_KEY:
	.word	word_QKEY
	.byte	3
	.ascii	"KEY"
KEY:
	.word	code_ENTER
key1:
	.word	QKEY
	.word	BRANCHZ,key1
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* PROPRIETARY nuf? ( -- t ) - return false if no input, else pause and if cr return true. */
	.section .dic
word_NUFQ:
	.word	word_KEY
	.byte	4
	.ascii	"NUF?"
NUFQ:
	.word	code_ENTER
	.word	QKEY
	.word	DUP
	.word	BRANCHZ, nufq1
	.word	DDROP
	.word	KEY
	.word	IMM,0x0D
	.word	EQUAL
nufq1:
	.word	RETURN


/*---------------------------------------------------------------------------*/
/* PROPRIETARY SP0 ( -- a) - initial value of parameter stack pointer */
	.section .dic
word_SPZERO:
	.word	word_NUFQ
	.byte	3
	.ascii	"SP0"
SPZERO:
	.word	code_ENTER
	.word	IMM,SP_ZERO
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* PROPRIETARY SP0 ( -- a) - initial value of return stack pointer */
	.section .dic
word_RPZERO:
	.word	word_SPZERO
	.byte	3
	.ascii	"RP0"
RPZERO:
	.word	code_ENTER
	.word	IMM,RP_ZERO
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* CORE 6.1.1200 DEPTH ( -- n )  return the depth of the data stack. */
	.section .dic
word_DEPTH:
	.word	word_RPZERO
	.byte	5
	.ascii	"DEPTH"
DEPTH:
	.word	code_ENTER
	.word	SPLOAD,SPZERO,SWAP,SUB
	.word	IMM,2,SLASH
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* CORE_EXT 6.2.2030 PICK ( ... +n -- ... w ) - copy the nth stack item to tos. */
	.section .dic
word_PICK:
	.word	word_DEPTH
	.byte	4
	.ascii	"PICK"
PICK:
	.word	code_ENTER
	.word	INC,CELLS
	.word	INC
	.word	SPLOAD,PLUS,LOAD
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* CORE 6.1.0380 2DUP ( u1 u2 -- u1 u2 u1 u2 ) */
	.section .dic
word_DDUP:
	.word	word_PICK
	.byte	4
	.ascii	"2DUP"
DDUP:
	.word	code_ENTER
	.word	OVER
	.word	OVER
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* CORE 6.1.0370 2DROP ( x x -- ) */
	.section .dic
word_DDROP:
	.word	word_DDUP
	.byte	5
	.ascii	"2DROP"
DDROP:
	.word	code_ENTER
	.word	DROP
	.word	DROP
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* CORE 6.1.0630 ?DUP ( u -- u u if u NOT zero ) */
	.section .dic
word_DUPNZ:
	.word	word_DDROP
	.byte	4
	.ascii	"?DUP"
DUPNZ:
	.word	code_ENTER
	.word	DUP		/* Dup first, to allow testing */
	.word	BRANCHZ,DUPNZ2	/* if zero, no dup happens (this consumes the first dupe) */
	.word	DUP		/* Not zero: Dup the value and leave on stack */
DUPNZ2:
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* CORE 6.1.2160 ROT ( a b c -- b c a ) */
	.section .dic
word_ROT:
	.word	word_DUPNZ
	.byte	3
	.ascii	"ROT"
ROT:
	.word	code_ENTER
	.word	TOR
	.word	SWAP
	.word	RFROM
	.word	SWAP
	.word	RETURN

/*===========================================================================*/
/* Math and logical */
/*===========================================================================*/

/*---------------------------------------------------------------------------*/
/* CORE 6.1.1720 INVERT ( n -- n ) - invert all bits */
	.section .dic
word_NOT:
	.word	word_ROT
	.byte	6
	.ascii	"INVERT"
NOT:
	.word	code_ENTER
	.word	IMM, 0xFFFF
	.word	XOR
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* CORE 6.1.1910 NEGATE ( n -- -n ) - Twos complement */
	.section .dic
word_NEGATE:
	.word	word_NOT
	.byte	6
	.ascii	"NEGATE"
NEGATE:
	.word	code_ENTER
	.word	NOT
	.word	IMM, 1
	.word	PLUS
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* DOUBLE 8.6.1.1230 DNEGATE ( d -- -d ) - Twos complement */
	.section .dic
word_DNEGATE:
	.word	word_NEGATE
	.byte	7
	.ascii	"DNEGATE"
DNEGATE:
	.word	code_ENTER
	.word	NOT,TOR,NOT
	.word	IMM,1,UPLUS
	.word	RFROM,PLUS
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* CORE 6.1.0160 - ( a b -- a-b ) - could be assembly to improve performance a bit */
	.section .dic
word_SUB:
	.word word_DNEGATE
	.byte	1
	.ascii	"-"
SUB:
	.word	code_ENTER
	.word	NEGATE
	.word	PLUS
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* CORE 6.1.0690 ABS ( n -- |n| ) - absolute value */
	.section .dic
word_ABS:
	.word	word_SUB
	.byte	3
	.ascii	"ABS"
ABS:
	.word	code_ENTER
	.word	DUP
	.word	ZLESS
	.word	BRANCHZ,abspos
	.word	NEGATE	
abspos:
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* CORE 6.1.2360 UM* ( u v -- uvlo uvhi ) - long 16x32 multiplication */
	.section .dic
word_UMSTAR:
	.word	word_ABS
	.byte	3
	.ascii	"UM*"
UMSTAR:
.if USE_MUL
	.word	code_UMSTAR
	.text
code_UMSTAR:
    /* Multiplication input: 2 16-bit cells on TOS */
    tsx
    /* At this point the operands are at 0,X and 2,X
       These can be accessed bytewise in A and B to be used immediately in MUL.
       The result for MUL is in D. Accumulations are needed, we use a 4 byte pTEMP
       Data layout:
     @X +0 +1 +2 +3
        AH AL BH BL
       Mul algorithm:
             AH AL
      x      BH BL
      ------------
             AL BL
          AH BL
          AL BH
       AH BH
      ------------
       hi(AHBH) , lo(AHBH) + hi(ALBH) + hi(AHBL) , lo(ALBH) + lo(AHBL) + hi(ALBL) , L(ALBL)

$1234 x $5678
 12 34
 56 78

34 x 78 = 0x00001860
34 x 56 = 0x00117800
--------------------
sum       0x00119060
12 x 78 = 0x00087000
--------------------
sum       0x001a0060
12 x 56 = 0x060c0000
--------------------
sum       0x06260060

      We will compute right to left.
      */

    /* pre-clear the zone that will only be accessed by additions */
    clra
    clrb
    std   *(pTEMP)

    /* low bytes */
    ldaa    1,X         /* AL */
    ldab    3,X         /* BL */
    mul                 /* ALBL in D */
    std     *(pTEMP+2)

    /* first middle pair */
    ldaa    0,x         /* AH */
    ldab    3,x         /* BL */
    mul                 /* AHBL in D */
    addd    *(pTEMP+1)
    std     *(pTEMP+1)
    bcc     step3
    /* carry set -> propagate */
    inc     pTEMP
step3:
    /* second middle pair */
    ldaa  1,x           /* AL */
    ldab  2,x           /* BH */
    mul                 /* ALBH in D */
    addd    *(pTEMP+1)
    std     *(pTEMP+1)
    bcc     step4
    /* carry set -> propagate */
    inc     pTEMP
step4:
    /* high pair */
    ldaa  0,x           /* AH */
    ldab  2,x           /* BH */
    mul                 /* AHBH in D */
    addd    *pTEMP
    std     *pTEMP
    /* done, store result as a dual cell value, high word pushed first.
       We just replace the two cells at TOS */
    ldd     *pTEMP
    std     0,X
    ldd     *(pTEMP+2)
    std     2,X

    bra     NEXT

.else
	.word	code_ENTER
	.word	IMM,0,SWAP,IMM,15,TOR
umst1:	.word	DUP,UPLUS,TOR,TOR
	.word	DUP,UPLUS,RFROM,PLUS,RFROM
	.word	BRANCHZ,umst2
	.word	TOR,OVER,UPLUS,RFROM,PLUS
umst2:	.word	JNZD,umst1
	.word	ROT,DROP
	.word	RETURN
.endif

/*---------------------------------------------------------------------------*/
/* CORE 6.1.0090 * ( u v -- u*v ) - short 16x16 multiplication with result same size as operands. we just drop half of the result bits */
	.section .dic
word_STAR:
	.word	word_UMSTAR
	.byte	1
	.ascii	"*"
STAR:
	.word	code_ENTER
	.word	UMSTAR
	.word	DROP		/*Forget the Most Significant word */
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* CORE 6.1.1810 M* ( n n -- d ) signed multiply. return double product. */
word_MSTAR:
	.word	word_STAR
	.byte	2
	.ascii	"M*"
MSTAR:
	.word	code_ENTER
	.word	DDUP,XOR,ZLESS,TOR
	.word	ABS,SWAP,ABS,UMSTAR
	.word	RFROM
	.word	BRANCHZ,msta1
	.word	DNEGATE
msta1:
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* CORE 6.1.2370 UM/MOD ( ul0 uh0 un -- ur uq ) - 32/16 division and modulo */
/*TODO native implementation since hc11 has a divider*/
	.section .dic
word_UMMOD:
	.word	word_MSTAR
	.byte	6
	.ascii	"UM/MOD"
UMMOD:
.if USE_DIV
/* Native implementation of UM/MOD using HC11 divider.
   HC11 divides 16 by 16 to produce a 16-bit quotient and remainder (IDIV) or 16-bit left-shifted 16 by 16 (FDIV).
   We need to extend that to a 32/16 divide.

Example in base 10: divide 19 by 8
19 | 8        To divide 19 by 8 we first divide 10 by 8
10 |---       This yields 1 and remains 2 (FDIV)
 2 | 1        But we divided 10 instead of 19
 9 |          So we add the last digit to the remainder. Total is 11.
11 |          This is larger than the base 10, there was a carry.
10 | 1        So we have to divide again. Using hig digit we divide 10 by 8 and get 1 remains 2. (FDIV)
 2 |          But we divided 10 instead of 11.
 3 |          So we add the last digit to the remainder (IDIV). This is 3.
Now the remainder is smaller than the divisor, process is complete.

With Forth cells, the process is the same but we divide in base 65536.
The first steps of the division are done with FDIV which divides D<<65536/X
The last step is a HC11 IDIV since we divide a single digit with a single digit.

0x12345678 = 0x5678 * 0x35E5 + 0x2520
 305419896 =  22136 *  13797 +   9504

Divide 0x12340000 by 0x5678 using FDIV, quotient is 0x35E4, remainder 0x2520

Now add low digit: 0x5678 + 0x2520 = 0x7B98 without carry generated
So the second FDIV step can be skipped.

Final division 
0x7B98 / 0x5678 = 0x5678 * 0x0001 + 0x2520

Summary: Remainder is 0x2520, quotient is 0x35E4 + 1 = 0x35E5

1 - udh(D) FDIV u(X), result is Q0 (X), R(D)
2 - add R(D) with udl, result in D
3 - if no carry goto 6
4 - D FDIV u(X), result is Q1 (X), R(D)
5 - add R(D) with udl, result in D
6 - D FDIV u(X), result is Q2 (X), R(D)
7 - final remainder is D, quotient is Q0+Q1+Q2

udh is used once, it is used to accumulate the quotient

To improve code performance we dont load D and X from stack directly (would need expensive opcodes involving Y index)
We just pull the operands into pTEMP and access them from here in direct addressing mode.
*/
	.word	code_UMMOD
	.text
code_UMMOD:
	pulx
	stx	*pTEMP		/* n */
	pulx
	stx	*(pTEMP+2)	/* h0 */
	pulx
	stx	*(pTEMP+4)	/* l0 */

	ldd	*(pTEMP+2)	/* load h0 word */
	ldx	*pTEMP		/* load n */	

	fdiv

	addd	*(pTEMP+4)	/* add udl to remainder */
	std	*(pTEMP+4)	/* save in back for later, keeps C */
	stx	*(pTEMP+2)	/* overwrite udh with quotient accumulator, keeps C */
	bcc	skipdiv2	/* no overflow so second fdiv is not required */

	ldd	#0x0001		/* load H1, which is always one here. */
	ldx	*pTEMP		/* load divisor, D is still alive, contains remainder+udl */

	fdiv

	addd	*(pTEMP+4)	/* add remainder to L1 */
	xgdx			/* now D contains new quotient, X gets L1+R1 */
	addd	*(pTEMP+2)	/* acc quotient */
	std	*(pTEMP+2)	/* store sum quotient*/
	xgdx			/* now D contains R1+L1, X is quotient sum*/

skipdiv2:
	ldx	*pTEMP		/* Final divisor load */
	idiv			/* D contains final remainder */
	xgdx			/* Remainder in X, D contains quotient to accumulate */
	pshx			/* We're done with the remainder. */
	addd	*(pTEMP+2)	/* Acc the quotient */
	bra	PUSHD		/* Use common code to push it */
    
.else
	.word	code_ENTER
	.word	DDUP
	.word	ULESS
	.word	BRANCHZ,umm4
	.word	NEGATE
	.word	IMM,15
	.word	TOR
umm1:
	.word	TOR
	.word	DUP
	.word	UPLUS
	.word	TOR,TOR,DUP,UPLUS
	.word	RFROM,PLUS,DUP
	.word	RFROM,RLOAD,SWAP,TOR
	.word	UPLUS,RFROM,OR
	.word	BRANCHZ,umm2
	.word	TOR,DROP,INC,RFROM
	.word	BRANCH,umm3
umm2:
	.word	DROP
umm3:
	.word	RFROM
	.word	JNZD,umm1
	.word	DROP,SWAP,RETURN
umm4:
	.word	DROP,DDROP
	.word	IMM,-1,DUP		/* overflow, return max*/
	.word	RETURN
.endif

/*---------------------------------------------------------------------------*/
/* CORE 6.1.1561 FM/MOD ( d n -- r q ) - signed floored divide of double by single. return mod and quotient. */
	.section .dic
word_FMSMOD:
	.word	word_UMMOD
	.byte	6
	.ascii	"FM/MOD"
FMSMOD:
	.word	code_ENTER
	.word	DUP,ZLESS,DUP,TOR
	.word	BRANCHZ,mmod1
	.word	NEGATE,TOR,DNEGATE,RFROM

mmod1:
	.word	TOR,DUP,ZLESS
	.word	BRANCHZ,mmod2
	.word	RLOAD,PLUS
mmod2:
	.word	RFROM,UMMOD,RFROM
	.word	BRANCHZ,mmod3
	.word	SWAP,NEGATE,SWAP
mmod3:
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* CORE 6.1.0240 /MOD ( n n -- r q ) signed divide. return mod and quotient. */
	.section .dic
word_SLMOD:
	.word	word_FMSMOD
	.byte	4
	.ascii	"/MOD"
SLMOD:
	.word	code_ENTER
	.word	OVER
	.word	ZLESS
	.word	SWAP
	.word	FMSMOD
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* CORE 6.1.1890 MOD ( n n -- r ) signed divide. return mod only. */
	.section .dic
word_MOD:
	.word	word_SLMOD
	.byte	3
	.ascii	"MOD"
MOD:
	.word	code_ENTER
	.word	SLMOD
	.word	DROP
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* CORE 6.1.0230 / ( n n -- q ) signed divide. return quotient only. */
	.section .dic
word_SLASH:
	.word	word_MOD
	.byte	1
	.ascii	"/"
SLASH:
	.word	code_ENTER
	.word	SLMOD
	.word	SWAP
	.word	DROP
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* CORE 6.1.0880 CELL+ ( u -- u+2 ) */
	.section .dic
word_CELLP:
	.word	word_SLASH
	.byte	5
	.ascii "CELL+"
CELLP:
	.word	code_ENTER
	.word	IMM,2
	.word	PLUS
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* CORE 6.1.0897 CHAR+ ( u -- u+1 ) */
	.section .dic
word_CHARP:
	.word	word_CELLP
	.byte	5
	.ascii "CHAR+"
CHARP:
	.word	code_ENTER
	.word	IMM,1
	.word	PLUS
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* CORE 6.1.0290 1+ (n -- n) */
/* This is similar to CHARP. It would be more complex to define an alias
 * mechanism than to duplicate the implementation
 */
	.section .dic
word_INC:
	.word	word_CHARP
	.byte	2
	.ascii	"1+"
INC:
	.word	code_ENTER
	.word	IMM,1
	.word	PLUS
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* CORE 6.1.0300 1- (n -- n) */
	.section .dic
word_DEC:
	.word	word_INC
	.byte	2
	.ascii	"1-"
DEC:
	.word	code_ENTER
	.word	IMM,-1
	.word	PLUS
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* CORE 6.1.0890 CELLS ( u -- u*2 ) - compute bytes required to store u cells */
	.section .dic
word_CELLS:
	.word	word_DEC
	.byte	5
	.ascii "CELLS"
CELLS:
	.word	code_ENTER
	.word	DUP
	.word	PLUS
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* CORE 6.1.0130 +! (val adr -- ) add val to the contents of adr */
	.section .dic
word_PLUS_STORE:
	.word	word_CELLS
	.byte	2
	.ascii	"+!"
PLUS_STORE:
	.word	code_ENTER
	.word	SWAP		/* adr val */
	.word	OVER		/* adr val adr */
	.word	LOAD		/* adr val *adr */
	.word	PLUS		/* adr val+*adr */
	.word	SWAP		/* val+*adr adr */
	.word	STORE		/*empty*/
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* CORE 6.1.2340 U< ( u v -- u<v ) unsigned compare of top two items. */
	.section .dic
word_ULESS:
	.word	word_PLUS_STORE
	.byte	2
	.ascii	"U<"
ULESS:
	.word	code_ENTER
	.word	DDUP		/* (u) (v) (u)     (v) */
	.word	XOR		/* (u) (v) (u^v)      */
	.word	ZLESS		/* (u) (v) ((u^v)<0) */
	.word	BRANCHZ, ULESS1
	.word	SWAP		/* (v) (u) */
	.word	DROP		/* (v)    */
	.word	ZLESS		/* (v<0) */
	.word	RETURN
ULESS1:
	.word	SUB		/* (u-v) */
	.word	ZLESS		/* ((u-v)<0) */
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* CORE 6.1.0480 < ( n1 n2 -- t ) - signed compare of top two items. */
	.section .dic
word_LESS:
	.word	word_ULESS
	.byte	1
	.ascii	"<"
LESS:
	.word	code_ENTER
	.word	DDUP
	.word	XOR
	.word	ZLESS
	.word	BRANCHZ,less1
	.word	DROP
	.word	ZLESS
	.word	RETURN
less1:
	.word	SUB
	.word	ZLESS
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* CORE 6.1.1870 MAX ( n n -- n ) - return the greater of two top stack items. */
word_MAX:
	.word	word_LESS
	.byte	3
	.ascii	"MAX"
MAX:
	.word	code_ENTER
	.word	DDUP
	.word	LESS
	.word	BRANCHZ,max1
	.word	SWAP
max1:
	.word	DROP
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* CORE 6.1.1880 MIN ( n n -- n ) - return the smaller of two top stack items. */
word_MIN:
	.word	word_MAX
	.byte	3
	.ascii	"MIN"
MIN:
	.word	code_ENTER
	.word	DDUP
	.word	SWAP
	.word	LESS
	.word	BRANCHZ,min1
	.word	SWAP
min1:
	.word	DROP
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* CORE_EXT 6.2.2440 WITHIN ( u ul uh -- ul <= u < uh ) */
	.section .dic
word_WITHIN:
	.word	word_MIN
	.byte	6
	.ascii	"WITHIN"
WITHIN:
	.word	code_ENTER
	.word	OVER		/*u ul uh ul*/
	.word	SUB		/*u ul (uh-ul) */
	.word	TOR		/*u ul R: (uh-ul) */
	.word	SUB		/*(u-ul) R: (uh-ul) */
	.word	RFROM		/* (u-ul) (uh-ul) */
	.word	ULESS		/* ((u-ul) < (uh-ul)) */
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* CORE 6.1.0530 = ( w w -- t ) equality flag FFFF if both value are the same (xor would return zero for equality)*/
word_EQUAL:
	.word	word_WITHIN
	.byte	1
	.ascii	"="
EQUAL:
	.word	code_ENTER
	.word	XOR
	.word	BRANCHZ,equtrue
	.word	IMM,0
	.word	RETURN
equtrue:
	.word	IMM,0xFFFF	/* True is -1 ! */
	.word	RETURN

/*===========================================================================*/
/* Strings */
/*===========================================================================*/

/*---------------------------------------------------------------------------*/
/* CORE 6.1.0980 COUNT ( cstradr -- bufadr len ) Return the buf addr and len of a pointed counted string */
	.section .dic
word_COUNT:
	.word	word_EQUAL
	.byte	5
	.ascii	"COUNT"
COUNT:
	.word	code_ENTER
	.word	DUP		/* cstradr cstradr */
	.word	CHARP		/* cstradr cstradr+1*/
	.word	SWAP		/* bufadr cstradr */
	.word	CLOAD		/* bufadr len */
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* STRING 17.6.1.0910 CMOVE (src dest count --) - memcpy */
	.section .dic
word_CMOVE:
	.word	word_COUNT
	.byte	5
	.ascii	"CMOVE"
CMOVE:
	.word	code_ENTER
	.word	TOR		/*src dest | R:count*/
	.word	BRANCH,cmov2	/**/
cmov1:
	.word	TOR		/*src | R:count dest*/
	.word	DUP		/*src src | R: count dest*/
	.word	CLOAD		/*src data | R: count dest*/
	.word	RLOAD		/*src data dest | R: count dest*/
	.word	CSTORE		/*src | R: count dest*/
	.word	CHARP		/*src+1 | R: count dest*/
	.word	RFROM		/*src+1 dest | R: count */
	.word	CHARP		/*src+1->src dest+1->dest | R: count*/
cmov2:
	.word	JNZD, cmov1	/*src dest | if count>0, count--, goto cmov1 */
	.word	DDROP		/*-- R: -- */
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* PROPRIETARY (buf len dest -- dest) Create a counted string in dest from len chars at buf */
	.section .dic
word_PACKS:
	.word	word_CMOVE
	.byte	5
	.ascii	"PACK$"
PACKS:
	.word	code_ENTER
	/*Save count */
	.word	DUP		/*buf len dest dest */
	.word	TOR		/*buf len dest | R: dest*/
	.word	DDUP		/*buf len dest len dest | R: dest*/
	.word	CSTORE		/*buf len dest | R: dest*/
	/*Copy string after count */
	.word	CHARP		/*buf len (dest+1) | R:dest*/
	.word	SWAP		/*buf (dest+1) len | R:dest*/
	.word	CMOVE		/*R:dest*/
	.word	RFROM		/*dest*/
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* PROPRIETARY csame (ptra ptrb len -- flag ) - compare strings on len bytes */
	.section .dic
word_CSAME:
	.word	word_PACKS
	.byte	6
	.ascii	"CSAME?"
CSAME:
	.word	code_ENTER
	.word	TOR		/*ptra ptrb | R:len*/
	.word	BRANCH,csame2
csame0:
	.word	OVER		/*ptra ptrb ptra | R:len*/
	.word	CLOAD		/*ptra ptrb chra | R:len*/
	.word	OVER		/*ptra ptrb chra ptrb | R:len*/
	.word	CLOAD		/*ptra ptrb chra chrb | R:len*/
	.word	SUB		/*ptra ptrb chrdiff | R:len*/
	.word	DUP		/*ptra ptrb chrdiff chrdiff | R:len*/
	.word	BRANCHZ,csame1	/*ptra ptrb chrdiff | R:len*/
	/* chars are different, we're done */
	.word	RFROM		/*ptra ptrb chrdiff len */
	.word	DROP		/*ptra ptrb chrdiff */
	.word	TOR		/*ptra ptrb | R: chrdiff*/
	.word	DDROP		/*R: chrdiff*/
	.word	RFROM		/*chrdiff*/
	.word	RETURN

csame1:
	/*both chars are similar. Increment pointers and loop - ptra ptrb chrdiff | R:len*/
	.word	DROP		/*ptra ptrb | R:len*/
	.word	CHARP		/*ptra+1 | R: len*/
	.word	SWAP
	.word	CHARP		/*ptra+1 ptrb+1 | R: len*/
	.word	SWAP

csame2:
	.word	JNZD, csame0	/*ptra+1 ptrb+1 | R: len if not null, else --*/
	/* If we reached this point then both strings are same */
	.word	DDROP
	.word	IMM,0
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* internal_ccompare (cstra cstrb lena lenb -- flag ) - return 0 if match */
/* Internal comparison code for both CCOMPARE and NAMECOMPARE.
   TODO rewrite the full chain of words FINDONE,FIND,TOKEN,WORD to
   work with direct (buf,len) pairs instead of counted strings. The goal is to avoid
   the useless copy made by PACK$ */
	.section .dic
internal_compare:
	.word	code_ENTER
	/*Compare lengths. not equal? not same strings.*/
	.word	OVER		/*cstra cstrb lena lenb lena */
	.word	SUB		/*cstra cstrb lena (lenb-lena)*/
	.word	SWAP		/*cstra cstrb lendiff lena*/
	.word	TOR		/*cstra cstrb lendiff | R:lena*/
	.word	BRANCHZ, ccoeq	/*cstra cstrb */
	/* Different lengths */
	.word	DDROP
	.word	RFROM	/* lena if not zero serves as difference marker */
	.word	RETURN
ccoeq:
	/*Length match. Compare chars */
	.word	CHARP
	.word	SWAP
	.word	CHARP
	.word	RFROM		/*bufb bufa len*/
	.word	CSAME		/*result */
	.word	RETURN


/*---------------------------------------------------------------------------*/
/* ccompare (cstr cstr -- flag ) - return 0 if match */
/* Generic version of string compare that does not mask the length bits */
	.section .dic
word_CCOMPARE:
	.word	word_CSAME
	.byte	8
	.ascii	"CCOMPARE"
CCOMPARE:
	.word	code_ENTER
	.word	OVER		/*cstra cstrb cstra*/
	.word	CLOAD		/*cstra cstrb lena*/
	.word	OVER		/*cstra cstrb lena cstrb*/
	.word	CLOAD		/*cstra cstrb lena lenb*/
	.word	internal_compare
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* namecompare (cstr cstr -- flag ) - return 0 if match */
/* Specific version of string compare that masks the length bits so the IMM and COMP bits are discarded */
	.section .dic
word_NAMECOMPARE:
	.word	word_CCOMPARE
	.byte	11
	.ascii	"NAMECOMPARE"
NAMECOMPARE:
	.word	code_ENTER
	.word	OVER		/*cstra cstrb cstra*/
	.word	CLOAD		/*cstra cstrb lena*/
	.word	IMM, WORD_LENMASK
	.word	AND
	.word	OVER		/*cstra cstrb lena cstrb*/
	.word	CLOAD		/*cstra cstrb lena lenb*/
	.word	IMM, WORD_LENMASK
	.word	AND
	.word	internal_compare
	.word	RETURN

/*---------------------------------------------------------------------------*/
/*   STRING 17.6.1.0935 COMPARE ( buf1 len1 buf2 len2 -- flag ) */
/*   compare strings up to the length of the shorter string. zero if match */
/* TODO */

/*---------------------------------------------------------------------------*/
/* INTERNAL DOSTR Common code from inline string extraction. MUST BE used by another word,
   since the string is loaded from the previous-previous entry */
	.section .dic
/* NO NAME */
DOSTR:
	.word	code_ENTER
	.word	RFROM
	.word	RLOAD
	.word	RFROM
	.word	COUNT
	.word	PLUS
	.word	TOR
	.word	SWAP
	.word	TOR
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* INTERNAL IMMSTR ( -- adr )
 * This is a runtime-only routine. It is compiled by S" but not accessible otherwise.
 */
	.section .dic
IMMSTR:
	.word	code_ENTER
	.word	DOSTR
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* INTERNAL SHOWSTR 
 * This is a runtime-only routine. It is compiled by ." but not accessible otherwise.
 */
	.section .dic
SHOWSTR:
	.word	code_ENTER
	.word	DOSTR
	.word	COUNT
	.word	TYPE
	.word	RETURN

/*===========================================================================*/
/* Numeric output */
/*===========================================================================*/

/*---------------------------------------------------------------------------*/
/* CORE_EXT 6.2.2000 PAD ( -- a ) - return the address of a temporary buffer. */
/* Note: this returns the END of a 80 byte buffer right after the current colon definition.
   The buffer is filled in reverse using a div/mod by base algorithm.
   No overflow because numeric output is never overlapping compilation. PAD is always used
   in the context defined by <# and #> */
	.section .dic
word_PAD:
	.word	word_NAMECOMPARE
	.byte	3
	.ascii	"PAD"
PAD:
	.word	code_ENTER
	.word	HERE
	.word	IMM,80
	.word	PLUS
	.word	RETURN


/*---------------------------------------------------------------------------*/
/*CORE 6.1.0490 <# ( -- ) */
	.section .dic
word_BDIGS:
	.word	word_PAD
	.byte	2
	.ascii	"<#"
BDIGS:
	.word	code_ENTER
	.word	PAD
	.word	IMM,HOLDP
	.word	STORE
	.word	RETURN

/*---------------------------------------------------------------------------*/
/*  CORE 6.1.0040 #> ( w -- b u ) - prepare the output string to be type'd. */
	.section .dic
word_EDIGS:
	.word	word_BDIGS
	.byte	2
	.ascii	"#>"
EDIGS:
	.word	code_ENTER
	.word	DROP
	.word	IMM,HOLDP
	.word	LOAD
	.word	PAD
	.word	OVER
	.word	SUB
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* CORE 6.1.1670 HOLD ( c -- ) - insert a character into the numeric output string. Storage is predecremented. */
	.section .dic
word_HOLD:
	.word	word_EDIGS
	.byte	4
	.ascii	"HOLD"
HOLD:
	.word	code_ENTER
	.word	IMM,HOLDP
	.word	LOAD
	.word	DEC
	.word	DUP
	.word	IMM,HOLDP
	.word	STORE
	.word	CSTORE
	.word	RETURN
	
/*---------------------------------------------------------------------------*/
/* PROPRIETARY DIGIT ( u -- c ) - convert digit u to a character.*/
	.section .dic
word_DIGIT:
	.word	word_HOLD
	.byte	5
	.ascii	"DIGIT"
DIGIT:
	.word	code_ENTER
	.word	IMM,9
	.word	OVER
	.word	LESS
	.word	IMM,7
	.word	AND
	.word	PLUS
	.word	IMM,'0'
	.word	PLUS
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* PROPRIETARY EXTRACT ( n base -- n c ) - extract the least significant digit from n. */
	.section .dic
word_EXTRACT:
	.word	word_DIGIT
	.byte	7
	.ascii	"EXTRACT"
EXTRACT:
	.word	code_ENTER
	.word	IMM,0
	.word	SWAP
	.word	UMMOD
	.word	SWAP
	.word	DIGIT
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* CORE 6.1.0030 # ( u -- u ) - extract one digit from u and append the digit to output string. */
	.section .dic
word_DIG:
	.word	word_EXTRACT
	.byte	1
	.ascii	"#"
DIG:
	.word	code_ENTER
	.word	BASE
	.word	LOAD
	.word	EXTRACT
	.word	HOLD
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* CORE 6.1.0050 #S ( u -- 0 ) - convert u until all digits are added to the output string. */
	.section .dic
word_DIGS:
	.word	word_DIG
	.byte	2
	.ascii	"#S"
DIGS:
	.word	code_ENTER
digs1:
	.word	DIG
	.word	DUP
	.word	BRANCHZ,digs2
	.word	BRANCH,digs1
digs2:
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* CORE 6.1.2210 SIGN ( n -- ) - add a minus sign to the numeric output string. */
	.section .dic
word_SIGN:
	.word	word_DIGS
	.byte	4
	.ascii	"SIGN"
SIGN:
	.word	code_ENTER
	.word	ZLESS
	.word	BRANCHZ,sign1
	.word	IMM,'-'
	.word	HOLD
sign1:
	.word	RETURN


/*---------------------------------------------------------------------------*/
/* PROPRIETARY STR       ( n -- b u ) - convert a signed integer to a numeric string. */
	.section .dic
word_STR:
	.word	word_SIGN
	.byte	3
	.ascii	"STR"
STR:
	.word	code_ENTER
	.word	DUP		/* n n */
	.word	TOR		/* n | R: n */
	.word	ABS		/* absn | R:n */
	.word	BDIGS		/* absn | R:n */
	.word	DIGS
	.word	RFROM
	.word	SIGN
	.word	EDIGS
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* CORE_EXT 6.2.2330 U.R ( u +n -- ) - display an unsigned integer in n column, right justified. */
	.section .dic
word_UDOTR:
	.word	word_STR
	.byte	3
	.ascii	"U.R"
UDOTR:
	.word	code_ENTER
	.word	TOR,BDIGS,DIGS,EDIGS
	.word	RFROM,OVER,SUB
	.word	SPACES,TYPE
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* CORE 6.2.0210 .R ( n +n -- ) - display an integer in a field of n columns, right justified. */
	.section .dic
word_DOTR:
	.word	word_UDOTR
	.byte	2
	.ascii	".R"
DOTR:
	.word	code_ENTER
	.word	TOR,STR,RFROM,OVER,SUB
	.word	SPACES,TYPE
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* CORE 6.1.2320 U. ( u -- ) - display an unsigned integer in free format. */
	.section .dic
word_UDOT:
	.word	word_DOTR
	.byte	2
	.ascii	"U."
UDOT:
	.word	code_ENTER
	.word	SPACE
	.word	BDIGS
	.word	DIGS
	.word	EDIGS
	.word	TYPE
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* CORE 6.1.0180 . ( w -- ) display an integer in free format, preceeded by a space. */
	.section .dic
word_DOT:
	.word	word_UDOT
	.byte	1
	.ascii	"."
DOT:
	.word	code_ENTER
	.word	BASE
	.word	LOAD
	.word	IMM,10
	.word	XOR
	.word	BRANCHZ,dot1
	/* Not decimal: display unsigned */
	.word	UDOT
	.word	RETURN
dot1:
	/* Decimal: display signed */
	.word	SPACE
	.word	STR
	.word	TYPE
	.word	RETURN

/*===========================================================================*/
/* Numeric input */
/*===========================================================================*/

/*---------------------------------------------------------------------------*/
/* CORE 6.1.0750 BASE ( -- a ) - push address of current numeric base */
	.section .dic
word_BASE:
	.word	word_DOT
	.byte	4
	.ascii	"BASE"
BASE:
	.word	code_ENTER
	.word	IMM,BASEP
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* CORE_EXT 6.2.1660 HEX ( -- ) */
	.section .dic
word_HEX:
	.word	word_BASE
	.byte	3
	.ascii	"HEX"
HEX:
	.word	code_ENTER
	.word	IMM,16
	.word	BASE
	.word	STORE
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* CORE 6.1.1170 DECIMAL ( -- ) */
	.section .dic
word_DECIMAL:
	.word	word_HEX
	.byte	7
	.ascii	"DECIMAL"
DECIMAL:
	.word	code_ENTER
	.word	IMM,10
	.word	BASE
	.word	STORE
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* INTERNAL DIGIT? ( c base -- u t ) convert ascii to digit with success flag*/
	.section .dic
word_DIGITQ:
	.word	word_DECIMAL
	.byte	6
	.ascii	"DIGIT?"
DIGITQ:
	.word	code_ENTER
	.word	TOR
	.word	IMM,'0'
	.word	SUB

	.word	IMM,9
	.word	OVER
	.word	LESS

	.word	BRANCHZ,dgtq1

	.word	IMM,7
	.word	SUB

	.word	DUP
	.word	IMM,10
	.word	LESS
	.word	OR

dgtq1:
	.word	DUP
	.word	RFROM
	.word	ULESS
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* PROPRIETARY NUMBER? ( cstr -- n t | a f ) - convert a number counted string to integer. push a flag on tos. */
/* F2012 instead requires CORE 6.1.0570 >NUMBER (ud1 c-addr u1 -- ud2 c-addr2 u2) */
	.section .dic
word_NUMBERQ:
	.word	word_DIGITQ
	.byte	7
	.ascii	"NUMBER?"
NUMBERQ:
	.word	code_ENTER
	.word	BASE		/*cstr &base */
	.word	LOAD		/*cstr base*/
	.word	TOR		/*cstr | R:base*/
	.word	IMM,0		/*cstr 0 | R:base*/
	.word	OVER		/*cstr 0 cstr | R:base*/
	.word	COUNT		/*cstr 0 strptr strlen | R:base*/

	.word	OVER		/*cstr 0 strptr strlen strptr | R:base*/
	.word	CLOAD		/*cstr 0 strptr strlen strptr[0] | R:base*/
	.word	IMM,'$'		/*cstr 0 strptr strlen strptr[0] $ | R:base*/
	.word	EQUAL		/*cstr 0 strptr strlen (1 if strptr[0]==$) | R:base*/
	.word	BRANCHZ,numq1	/*cstr 0 strptr strlen | R: base, jump if first buffer char is not $*/

	/* Equal returns 0 for FALSE (not equal). here we deal with $123 hex strings. */
	.word	HEX		/*cstr 0 strptr strlen | R:base */
	.word	SWAP		/*cstr 0 strlen strptr | R:base*/
	.word	CHARP		/*cstr 0 strlen strptr+1 | R:base*/
	.word	SWAP		/*cstr 0 strptr+1 strlen | R:base*/
	.word	DEC		/*cstr 0 strptr+1 strlen-1 | R:base*/

numq1:	/* Buffer doesnt start with a $ sign. Check for initial minus sign. */
	.word	OVER		/*cstr 0 strptr strlen strbuf | R: base*/
	.word	CLOAD		/*cstr 0 strptr strlen strchar | R:base*/
	.word	IMM,'-'		/*cstr 0 strptr strlen strchar '-' | R:base*/
	.word	EQUAL		/*cstr 0 strptr strlen strchar=='-' */
	.word	TOR		/*cstr 0 strptr strlen | R:base -1_if_negative*/

	.word	SWAP		/*cstr 0 strlen strbuf | R:base -1_if_negative*/
	.word	RLOAD		/*cstr 0 strlen strbuf -1_if_neg | R:base -1_if_negative*/
	.word	SUB		/*cstr 0 strlen strbuf+1 | R:base -1_if_negative*/
	.word	SWAP		/*cstr 0 strbuf+1 strlen | R:base -1_if_negative*/
	.word	RLOAD		/*cstr 0 strbuf+1 strlen -1_if_neg | R:base -1_if_negative*/
	.word	PLUS		/*cstr 0 strbuf+1 strlen-1 | R:base -1_if_negative*/
	.word	DUPNZ		/*cstr 0 strbuf+1 strlen-1 [strlen-1 if not zero] | R:base -1_if_negative*/
	.word	BRANCHZ,numq6	/*jump to end if new len is zero*/

	.word	DEC		/*cstr 0 strptr strlen-1 (for JNZD) | R:base -1_if_negative*/
	.word	TOR		/*cstr 0 strptr | R:base -1_if_negative strlen-1*/

numq2:
	.word	DUP		/*cstr 0 strptr strptr | R:base -1_if_negative strlen-1*/
	.word	TOR		/*cstr 0 strptr | R:base -1_if_negative strlen-1 strptr*/
	.word	CLOAD		/*cstr 0 strchar | R:base -1_if_negative strlen-1 strptr*/
	.word	BASE		/*cstr 0 strchar &base | R:base -1_if_negative strlen-1 strptr */
	.word	LOAD		/*cstr 0 strchar base | R:base -1_if_negative strlen-1 strptr */
	.word	DIGITQ		/*cstr 0 digit flag | R:base -1_if_negative strlen-1 strptr*/
	.word	BRANCHZ,numq4	/*cstr 0 digit - if failed (false) goto numq4 | R:base -1_if_negative strlen-1 strptr*/

	.word	SWAP
	.word	BASE
	.word	LOAD
	.word	STAR
	.word	PLUS
	.word	RFROM
	.word	INC
	.word	JNZD,numq2

	.word	RLOAD
	.word	SWAP
	.word	DROP
	.word	BRANCHZ,numq3

	.word	NEGATE

numq3:
	.word	SWAP
	.word	BRANCH,numq5

numq4:	/*invalid digit 	  cstr 0 digit | R:base -1_if_negative strlen-1 strptr*/
	.word	RFROM		/*cstr 0 digit strptr | R:base -1_if_negative strlen-1*/
	.word	RFROM		/*cstr 0 digit strptr strlen-1 | R:base -1_if_negative*/
	.word	DDROP		/*cstr 0 digit | R:base -1_if_negative*/
	.word	DDROP		/*cstr | R:base -1_if_negative*/
	.word	IMM,0		/*cstr 0 | R:base -1_if_negative*/
numq5:
	.word	DUP		/*cstr 0 0 |R:base is_negative*/
numq6:	/* Process String End	  cstr 0 strbuf | R:base is_negative */
	.word	RFROM		/*cstr 0 strbuf is_negative | R:base*/
	.word	DDROP		/*cstr 0 | R:base*/
	.word	RFROM		/*cstr 0 base */
	.word	BASE		/*cstr 0 base &BASE*/
	.word	STORE		/*cstr 0 */
	.word	RETURN

/*===========================================================================*/
/* Memory management */
/*===========================================================================*/

/*---------------------------------------------------------------------------*/
/* CORE 6.1.1650 HERE ( -- a) Push the address of the next free byte */
word_HERE:
	.word	word_NUMBERQ
	.byte	4
	.ascii	"HERE"
HERE:
	.word	code_ENTER
	.word	IMM, HEREP		/* (HEREP=&HERE) */
	.word	LOAD		/* (HERE) */ 
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* CORE_EXT 6.2.2395 UNUSED ( -- u ) */
/* Return the amount of free bytes in the data space */
word_UNUSED:
	.word	word_HERE
	.byte	6
	.ascii	"UNUSED"
UNUSED:
	.word	code_ENTER
	.word	RPLOAD
	.word	HERE
	.word	SUB
	.word	RETURN

/*===========================================================================*/
/* Terminal */
/*===========================================================================*/

/*---------------------------------------------------------------------------*/
/* PROPRIETARY BS ( -- 8 ) */
	.section .dic
word_BS:
	.word	word_UNUSED
	.byte	2
	.ascii	"BS"
BS:
	.word	code_ENTER
	.word	IMM,8
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* CORE 6.1.0770 BL ( -- 32 ) */
	.section .dic
word_BL:
	.word	word_BS
	.byte	2
	.ascii	"BL"
BL:
	.word	code_ENTER
	.word	IMM, 32
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* CORE 6.1.2220 SPACE ( -- ) Emit a blank char */
	.section .dic
word_SPACE:
	.word	word_BL
	.byte	5
	.ascii	"SPACE"
SPACE:
	.word	code_ENTER
	.word	BL
	.word	EMIT
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* CORE 6.1.2230 SPACES ( n -- ) Emit blank chars */
	.section .dic
word_SPACES:
	.word	word_SPACE
	.byte	6
	.ascii	"SPACES"
SPACES:
	.word	code_ENTER
	.word	IMM,0
	.word	MAX
	.word	TOR
	.word	BRANCH,spcend
spcloop:
	.word	SPACE
spcend:
	.word	JNZD,spcloop
spcdone:
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* CORE 6.1.0990 CR ( -- ) Emit a carriage return */
	.section .dic
word_CR:
	.word	word_SPACES
	.byte	2
	.ascii	"CR"
CR:
	.word	code_ENTER
	.word	IMM, 13
	.word	EMIT
	.word	IMM, 10
	.word	EMIT
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* PROPRIETARY ( buf bufend ptr -- buf bufend ptr  )  if ptr == buf */
/* ( buf bufend ptr -- buf bufend ptr-1)  if ptr  > buf */
/* Do a backspace: if not a bufstart, remove char from buf, then back, space, back */
	.section .dic
word_BKSP:
	.word	word_CR
	.byte	4
	.ascii	"BKSP"
BKSP:
	.word	code_ENTER
	/* check beginning of buffer */
	.word	TOR		/* buf bufend R: ptr */
	.word	OVER		/* buf bufend buf R: ptr */
	.word	RFROM		/* buf bufend buf ptr */
	.word	SWAP		/* buf bufend ptr buf */
	.word	OVER		/* buf bufend ptr buf ptr */
	.word	XOR		/* buf bufend ptr (buf == ptr) */
	.word	BRANCHZ,bksp1	/* buf bufend ptr */

	/* Remove char from buf */
	.word	IMM, 1		/* buf bufend ptr 1 */
	.word	SUB		/* buf bufend (ptr-1) */
	
	/* Send chars to erase output */
	.word	BS,EMIT
	.word	BL,EMIT		/* should replace emit by vectorable echo */
	.word	BS,EMIT
bksp1:
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* PROPRIETARY TAP ( buf bufend ptr c -- buf bufend (ptr+1) ) accumulate character in buffer - no bounds checking */
	.section .dic
word_TAP:
	.word	word_BKSP
	.byte	3
	.ascii	"TAP"
TAP:
	.word	code_ENTER
	.word	DUP	/* buf bufend ptr c c */
	.word	EMIT	/* buf bufend ptr c | shoud be vectored to allow disable echo */
	.word	OVER	/* buf bufend ptr c ptr */
	.word	CSTORE	/* buf bufend ptr */
	.word	CHARP	/* buf bufend (ptr+1) */
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* PROPRIETARY TTAP (buf bufend ptr c -- buf bufend ptr) */
	.section .dic
word_TTAP:
	.word	word_TAP
	.byte	4
	.ascii	"TTAP"
TTAP:
	.word	code_ENTER
	.word	DUP		/*buf bufend ptr c c*/
	.word	IMM,13		/*buf bufend ptr c c 13*/
	.word	XOR		/*buf bufend ptr c (c==13)*/
	.word	BRANCHZ, ktap2	/*buf bufend ptr c | manage end of buf*/
	.word	BS		/*buf bufend ptr c 8*/
	.word	XOR		/*buf bufend ptr (c==8)*/
	.word	BRANCHZ, ktap1	/*buf bufend ptr | manage backspace*/
	.word	BL		/*buf bufend ptr 32 | replace other non-printable by spaces */
	.word	TAP		/*buf bufend ptr*/
	.word	RETURN
ktap1:	.word	BKSP		/*buf bufend ptr*/
	.word	RETURN
ktap2:	.word	DROP		/*buf bufend ptr*/
	.word	SWAP		/*buf ptr bufend*/
	.word	DROP		/*buf ptr */
	.word	DUP		/*buf ptr ptr*/
	.word	RETURN


/*---------------------------------------------------------------------------*/
/* CORE 6.1.0695 ACCEPT ( buf len -- count) Read up to len or EOL into buf.
   Returns char count */
	.section .dic
word_ACCEPT:
	.word	word_TTAP
	.byte	6
	.ascii	"ACCEPT"
ACCEPT:
	.word	code_ENTER
	.word	OVER		/*buf len buf*/
	.word	PLUS		/*buf bufend*/
	.word	OVER		/*buf bufend bufcur , setup start, end, cur*/
ACCEPT1:
	.word	DDUP		/*buf bufend bufcur bufend bufcur*/
	.word	XOR		/*buf bufend bufcur (bufend==bufcur)*/
	.word	BRANCHZ,ACCEPT4	/*buf bufend bufcur              if buf reached bufend, finish word*/
	.word	KEY		/*buf bufend bufcur key */
	.word	DUP		/*buf bufend bufcur key key */
	.word	BL		/*buf bufend bufcur key key 32*/
	.word	IMM,127		/*buf bufend bufcur key key 32 127*/
	.word	WITHIN		/*buf bufend bufcur key (key is printable?)*/
	.word	BRANCHZ,ACCEPT2	/*buf bufend bufcur key , if not printable do ttap and loop again */
	.word	TAP		/*buf bufend bufcur , print and save printable key*/
	.word	BRANCH,ACCEPT1	/*buf bufend bufcur , again */
ACCEPT2:
	.word	TTAP		/*buf bufend bufcur , manage non printable key */
	.word	BRANCH,ACCEPT1	/*buf bufend bufcur , again */
ACCEPT4:
	.word	DROP		/*buf bufend - bufend has been replaced by bufcur in TTAP*/
	.word	SWAP		/*bufend buf*/
	.word	SUB		/*len */
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* CORE 6.1.2310 TYPE ( buf len -- ) Emit len chars starting at buf. */
	.section .dic
word_TYPE:
	.word	word_ACCEPT
	.byte	4
	.ascii	"TYPE"
TYPE:
	.word	code_ENTER
	.word	TOR		/* buf | R: len */
	.word	BRANCH,type2
type1:
	.word	DUP		/* buf buf | R: len */
	.word	CLOAD		/* buf char | R: len */
	.word	EMIT		/* buf */
	.word	CHARP		/* buf+1 */
type2:	.word	JNZD,type1	/* if @R (==len) > 0 then manage next char */
	.word	DROP		/* remove buf from stack */
	.word	RETURN

/*---------------------------------------------------------------------------*/
/*PROPRIETARY >CHAR ( char -- char ) - filter non printable chars */
word_TCHAR:
	.word	word_TYPE
	.byte	5
	.ascii	">CHAR"
TCHAR:
	.word	code_ENTER
	.word	IMM,0x7F,AND,DUP /* mask msb */
	.word	IMM,127,BL,WITHIN	/* check for printable */
	.word	BRANCHZ,tcha1		/* branch if printable */
	.word	DROP,IMM,'_'		/* literal underscore */
tcha1:
	.word	RETURN

/*===========================================================================*/
/* Parsing */
/*===========================================================================*/

/*---------------------------------------------------------------------------*/
/* PROPRIETARY (buf buflen delim -- buf len deltabuf) skip spaces, find word that ends at delim*/
	.section .dic
word_LPARSE:
	.word	word_TCHAR
	.byte	5
	.ascii	"parse"
LPARSE:
	.word	code_ENTER	/**/
	.word	IMM,pTEMP	/*buf buflen delim &TEMP */
	.word	STORE		/*buf buflen - TEMP contains delim */

	.word	OVER		/*buf buflen bufinit */
	.word	TOR		/*buf buflen | R: bufinit */
	.word	DUP		/*buf buflen buflen | R: bufinit */
	.word	BRANCHZ,pars8	/*buf buflen | R:bufinit if(buflen==0) goto pars8 */

	/* Buflen not zero */
	.word	DEC		/*buf len-1 | R:bufinit*/
	.word	IMM,pTEMP	/*buf len-1 &TEMP | R:bufinit*/
	.word	LOAD		/*buf len-1 delim | R:bufinit*/
	.word	BL		/*buf len-1 delim blank | R:bufinit*/
	.word	EQUAL		/*buf len-1 (delim==blank) | R:bufinit could it be simple xor?*/
	.word	BRANCHZ, pars3  /*buf len-1 jump to pars3 if delim is blank, else (delim not blank): continue */
	.word	TOR		/*buf | R: bufinit len-1*/
pars1:
	/* skip leading blanks only */
	.word	BL		/*buf blank | R: bufinit len-1 */
	.word	OVER		/*buf blank buf | R: bufinit len-1*/
	.word	CLOAD		/*buf blank curchar | R: bufinit len-1 */
	.word	SUB		/*buf curchar-bl | R: bufinit len-1 */
	.word	ZLESS		/*buf (curchar<blank) | R: bufinit len-1*/
	.word	NOT		/*buf (curchar>=blank) | R: bufinit len-1*/
	.word	BRANCHZ,pars2   /*buf | R: bufinit len-1 */

	/*curchar is below blank ->not printable, try next */
	.word	IMM, 1		/*buf 1 | R: bufinit len-1 */
	.word	PLUS		/*buf+1->buf | R: bufinit len-1*/
	.word	JNZD,pars1	/*buf | R: bufinit len-2 and goto pars1 or buf | R: bufinit continue if len-1 is null*/
	/*all chars parsed */
	.word	RFROM		/*buf len-1 */
	.word	DROP		/*buf */
	.word	IMM, 0		/*buf 0*/
	.word	DUP		/*buf 0 0*/
	.word	RETURN		/* all delim */

pars2:	/*Curchar >=delim */
	.word	RFROM		/*buf len-1*/

pars3:	/*Initial situation, delim is blank*/
	.word	OVER		/*buf len-1 buf*/
	.word	SWAP		/*buf buf len-1*/
	.word	TOR		/*buf buf | R:len-1*/

pars4:	/* scan for delimiter, beginning of a for loop */
	.word	IMM,pTEMP	/*buf buf &TEMP */
	.word	LOAD		/*buf buf delim */
	.word	OVER		/*buf buf delim buf */
	.word	CLOAD		/*buf buf delim curchar */
	.word	SUB		/*buf buf (delim-curchar) */

	.word	IMM,pTEMP	/*buf buf (delim-curchar) &TEMP */
	.word	LOAD		/*buf buf (delim-curchar) delim */
	.word	BL		/*buf buf (delim-curchar) delim blank */
	.word	EQUAL		/*buf buf (delim-curchar) (delim==blank) */
	.word	BRANCHZ,pars5	/*buf buf (delim-curchar) if(delim==blank) goto pars5 */
	.word	ZLESS		/*buf buf (delim<curchar)*/

pars5:	/* delim is blank */
	.word	BRANCHZ,pars6	/*buf buf if(delim<curchar) then goto par6 */
	.word	CHARP		/*buf (buf+1)*/
	.word	JNZD,pars4	/*buf (buf+1) and loop to pars4 if (len-1)>0*/
	.word	DUP		/*buf (buf+1) (buf+1)*/
	.word	TOR		/*buf (buf+1) | R:(buf+1)*/
	.word	BRANCH,pars7	

pars6:	/*delim<curchar*/
	.word	RFROM
	.word	DROP
	.word	DUP
	.word	CHARP
	.word	TOR

pars7:
	.word	OVER
	.word	SUB
	.word	RFROM
	.word	RFROM
	.word	SUB
	.word	RETURN

pars8:	/* Empty buffer case */	/*buf 0 | R:bufinit */
	.word	OVER		/*buf 0 buf | R:bufinit*/
	.word	RFROM		/*buf 0 buf bufinit*/
	.word	SUB		/*buf 0 0*/
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* CORE_EXT 6.2.2008 PARSE (delim "ccc<delim>" -- buf len) parse TIB at current pos and return delim spaced word */
	.section .dic
word_PARSE:
	.word	word_LPARSE
	.byte	5
	.ascii	"PARSE"
PARSE:
	.word	code_ENTER
	/* Compute current input buffer pointer */
	.word	TOR		/* -- | R: delim*/
	.word	IMM, TIBP	/* &tib */
	.word	LOAD		/* tib */
	.word	TOIN		/* tib &done_count */
	.word	LOAD		/* tib done_count */
	.word	PLUS		/* buf */
	/* Compute remaining count */
	.word	IMM,NTIBP	/* buf &ntib */
	.word	LOAD		/* buf ntib */
	.word	TOIN		/* buf ntib &done_count */
	.word	LOAD		/* buf ntib done_count */
	.word	SUB		/* buf remaining_count */
	.word	RFROM		/* buf remaining_count delim */
	/* Call low level word */
	.word	LPARSE		/* buf wordlen delta */
	.word	TOIN		/* buf wordlen delta &done_count */
	.word	PLUS_STORE	/* buf wordlen */
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* CORE_EXT 6.2.2020 PARSE-NAME ( "<spaces>name<space>" -- c-addr u ) TODO */
/* Goal is to avoid the use of PACKS that unnecessarily copies the string.
   As a consequence, this method also
   - avoids polluting HERE to save the compiled string
   - avoids the need for NAMECOMPARE and internal_compare
   However this is usually not a problem since the PACKed string is put in the
   right place to create new colon definitions.
*/

/* WORD and TOKEN. Create a counted string at HERE, which
   is used as temp memory. HERE pointer is not modified so each parsed word
   is stored at the same address (in unused data space). If an executed or
   compiled word manipulates HERE, then it is no problem: the user data will
   overwrite the word that was parsed and the next word will be stored a bit
   farther. It does not matter since this buffer is only used to FIND the code
   pointer for this word, usually. Another advantage of storing the word at
   HERE is that it helps compiling new word definitions! */

/*---------------------------------------------------------------------------*/
/* CORE 6.1.2450 WORD (delim "<delims>ccc,delim>" -- cs) */
/* Exceptional F2012 incompatibility: 6.1.2450 originally skip initial DELIMITERS
   while this implementation only skips initial SPACES only. */
	.section .dic
word_WORD:
	.word	word_PARSE
	.byte	4
	.ascii	"WORD"
WORD:
	.word	code_ENTER
	.word	PARSE		/*buf len*/
	.word	HERE		/*buf len dest*/
	.word	PACKS		/*dest*/
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* PROPRIETARY TOKEN ( -- cs) */
	.section .dic
word_TOKEN:
	.word	word_WORD
	.byte	5
	.ascii	"TOKEN"
TOKEN:
	.word	code_ENTER
	.word	BL
	.word	WORD
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* PROPRIETARY (Parse-word')' -- ) Display a string while compiling. Could be removed to save mem. */
	.section .dic
word_DOTPAR:
	.word	word_TOKEN
	.byte	2 + WORD_IMMEDIATE
	.ascii	".("
DOTPAR:
	.word	code_ENTER
	.word	IMM,')'
	.word	PARSE
	.word	TYPE
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* CORE 6.1.0080 ( ("ccc)" -- ) Inline comment, nop */
	.section .dic
word_PAR:
	.word	word_DOTPAR
	.byte	1 + WORD_IMMEDIATE
	.ascii	"("
PAR:
	.word	code_ENTER
	.word	IMM,')'
	.word	PARSE
	.word	DDROP
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* CORE_EXT 6.2.2535 \ ( "ccc<eol>" -- ) Line comment , discard the rest of the input buffer */
/* BLOCK 7.6.2.2535 \ ( "ccc<eol>" -- ) */
	.section .dic
word_BSLASH:
	.word	word_PAR
	.byte	1 + WORD_IMMEDIATE
	.ascii	"\\"
BSLASH:
	.word	code_ENTER
	.word	IMM, NTIBP
	.word	LOAD
	.word	TOIN
	.word	STORE
	.word	RETURN

/*===========================================================================*/
/* Dic search */
/*===========================================================================*/

/*---------------------------------------------------------------------------*/
/* INTERNAL TRWL_FIND ( req 0 ] cur -- flag ) */
/* callback for TRAVERSE-WORDLIST that finds words. */
/* req : name that is searched for
 * cur : word currently TRAVERSEd
 * Strategy: TRAVERSE-WORDLIST does not put items on the stack before calling
 * its callback, so the previous items are available to the callback.
 * FIND pushes a zero before browsing the list.
 * if a word is found, TRWL_FIND will replace this zero with the code pointer
 * of the found word and stop the search.
 * After the list if traversed, we can inspect this item and determine if a
 * word was found. The FIND word itself with then load the flags and determine
 * immediate or not.
 */

	.section .dic
TRWL_FIND:
	.word	code_ENTER
	/*compare cstr to current name stored at voc*/
	/* In compilation mode, we do not have to avoid compile-only words */
	.word	STATE			/* req 0 cur 0[interpret]/-1[compile] */
	.word	NOT			/* req 0 cur -1[interpret]/0[compile] */
	.word	BRANCHZ,compiling	/* req 0 cur  if compile then dont check CONLY flag */

	/* We are in interpretation mode. we have to check the compile only flag */
	/* Check flags within name. If word is compile only, skip it without even comparing name*/
	.word	DUP			/*req 0 cur cur*/
	.word	CLOAD			/*req 0 cur namelen+flags */
	.word	IMM,WORD_COMPILEONLY	/*req 0 cur namelen+flags COMPILEONLY*/
	.word	AND			/*req 0 cur NZ_IF_COMPILE_ONLY */
	.word	BRANCHZ,compiling	/*req 0 cur , if not compile only then compare names*/
	/* word is compile only : finish iteration*/
	.word	RETURN			/*req 0 cur -> not zero so try again with next word */

compiling:
	.word	ROT			/*0 cur req */
	.word	DDUP			/*0 cur req cur req*/
	.word	NAMECOMPARE		/*0 cur req equal_flag*/
	.word	BRANCHZ,found		/*0 cur req jump_if_equal*/

	/* Strings are different / word is compile only, look at next word */
	.word	ROT			/*cur req 0 */
	.word	ROT			/*req 0 cur */
	.word	RETURN			/* req 0 cur -> not zero so try agn with next word */

found:
	/* Push a one if immediate, -1 if not immediate. now req is useless */
	.word	DROP		/*0 cur */
	.word	DUP		/*0 cur cur */
	.word	CLOAD		/*0 cur namelen+FLAGS */
	.word	DUP		/*0 cur namelen+FLAGS namelen+FLAGS*/
	.word	IMM,WORD_LENMASK/*0 cur namelen+flags namelen+FLAGS 0x3F */
	.word	AND		/*0 cur namelen+flags namelen */
	.word	CHARP		/*0 cur namelen+flags namelen+1 */
	.word	ROT		/*0 namelen+flags namelen+1 cur*/
	.word	PLUS		/*0 namelen+flags codeptr */
	.word	SWAP		/*0 codeptr namelen+flags*/
	.word	ROT		/*codeptr namelen+flags 0 */
	.word	DROP		/*codeptr namelen+flags */
	.word	IMM,WORD_IMMEDIATE
	.word	AND		/*codeptr NZ_IF_IMMEDIATE */
	.word	IMM,-1		/*codeptr NZ_IF_IMM -1 (not imm by default) */
	.word	SWAP		/*codeptr -1 NZ_IF_IMM */
	.word	BRANCHZ,fnotimm /*codeptr -1 jump if name is not imm - will return -1*/
	.word	NEGATE		/*codeptr 1 will return 1 for immediate */
fnotimm:
	.word	IMM,0		/* codeptr +-1 0 Flag to terminate the traversal */
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* CORE 6.1.1550 FIND ( cstr -- codeaddr 1 [immediate] | codeaddr -1 [normal] | cstr 0 ) ? */
/* Check ALL vocabularies for a matching word and return code and name address, else same cstr and zero*/

	.section .dic
word_FIND:
	.word	word_BSLASH
	.byte	4
	.ascii	"FIND"
FIND:
	.word	code_ENTER	/*req - is a cstr */
	.word	IMM,0		/*req 0 - This setups the return state if nothing is found */
	.word	IMM,TRWL_FIND	/*req 0 cb */
	.word	IMM,LASTP	/*req 0 cb [pointer containing the address of the last word] */
	.word	LOAD		/*req 0 cb voc[address of last word entry] */
	.word	TRWL		/*Browse all words. The search stops when the required word is found */
        /* Search complete. What do we find on the stack? */
	/* If no word was found: the zero previously pushed will be found */
	/* req 0 [if nothing found] codeptr +-1 [if found] */
	.word	RETURN

/*===========================================================================*/
/* Error handling */
/*===========================================================================*/

/*---------------------------------------------------------------------------*/
/* PROPRIETARY HANDLER ( -- a ) Return address of current exception handler */
    .section .dic
word_HANDLER:
	.word	word_FIND
	.byte	7
	.ascii	"HANDLER"
HANDLER:
	.word	code_ENTER
	.word	IMM,HANDP
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* PROPRIETARY CATCH ( xt -- err#\0 ) setup frame to handle errors thrown while executing xt */
/* TODO make it use int codes instead of strings to comply with EXCEPTION 9.6.1.0875 */
	.section .dic
word_CATCH:
	.word	word_HANDLER
	.byte	5
	.ascii	"CATCH"
CATCH:
	.word	code_ENTER
	/* save error frame */
	.word	SPLOAD
	.word	TOR
	.word	HANDLER
	.word	LOAD
	.word	TOR
	/* Execute */
	.word	RPLOAD
	.word	HANDLER
	.word	STORE
	.word	EXECUTE
	/* Restore error frame */
	.word	RFROM
	.word	HANDLER
	.word	STORE
	/* No error */
	.word	RFROM
	.word	DROP
	.word	IMM,0
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* PROPRIETARY THROW  ( err# -- err# ) return from the encapsulating catch with an error code */
/* TODO make it use int codes to comply with EXCEPTION 9.6.1.2275 */
	.section .dic
word_THROW:
	.word	word_CATCH
	.byte	5
	.ascii	"THROW"
THROW:
	.word	code_ENTER
	/* restore return stack */
	.word	HANDLER
	.word	LOAD
	.word	RPSTORE
	/* restore handler frame */
	.word	RFROM
	.word	HANDLER
	.word	STORE
	/* restore data stack */
	.word	RFROM
	.word	SWAP
	.word	TOR
	.word	SPSTORE
	.word	DROP
	.word	RFROM
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* CORE 6.1.0670 ABORT ( -- ) Jump to quit */
/* TODO use int codes to comply with EXCEPTION_EXT 9.6.2.0670 */
	.section .dic
word_ABORT:
	.word	word_THROW
	.byte	5
	.ascii	"ABORT"
ABORT:
	.word	code_ENTER
	.word	IMMSTR
	.byte	7
	.ascii	" abort!"
	.word	THROW

/*---------------------------------------------------------------------------*/
/* PROPRIETARY ABORT" ( f -- ) run time routine of abort" . abort with a message. */
	.section .dic
word_ABORTNZ:
	.word	word_ABORT
	.byte	6 + WORD_COMPILEONLY
	.ascii	"abort\""
ABORTNZ:
	.word	code_ENTER
	.word	BRANCHZ,abor1
	.word	DOSTR
	.word	THROW
abor1:	/* Cancel abort if TOS was zero*/
	.word	DOSTR
	.word	DROP
	.word	RETURN

/*===========================================================================*/
/* System state (interpret/compile) */
/*===========================================================================*/

/*---------------------------------------------------------------------------*/
/* CORE 6.1.2250 STATE ( -- state ) - Return 0 if interpreting and -1 if compiling */
word_STATE:
	.word	word_ABORTNZ
	.byte	5
	.ascii	"STATE"
STATE:
	.word	code_ENTER
	.word	IMM,STATP
	.word	LOAD
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* PROPRIETARY Set the system state to interpretation */
/* TODO use STATE instead and comply with CORE 6.1.2500 */
	.section .dic
word_INTERP:
	.word	word_STATE
	.byte	1 + WORD_IMMEDIATE
	.ascii	"["
INTERP:
	.word	code_ENTER
	.word	IMM,0
	.word	IMM,STATP
	.word	STORE
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* Set the system state to compilation */
/* TODO use STATE instead and comply with CORE 6.1.2540 */
	.section .dic
word_COMPIL:
	.word	word_INTERP
	.byte	1 + WORD_IMMEDIATE
	.ascii	"]"
COMPIL:
	.word	code_ENTER
	.word	IMM,0xFFFF
	.word	IMM,STATP
	.word	STORE
	.word	RETURN

/*===========================================================================*/
/* Compiler */
/*===========================================================================*/

/*---------------------------------------------------------------------------*/
/* CORE 6.1.0070 ' ( "<spaces>name" -- ca ) - search context vocabularies for the next word in input stream. */
	.section .dic
word_TICK:
	.word	word_COMPIL
	.byte	1
	.ascii	"'"
TICK:
	.word	code_ENTER
	.word	TOKEN
	.word	FIND
	.word	BRANCHZ,tick1
	.word	RETURN
tick1:
	.word	THROW

/*---------------------------------------------------------------------------*/
/* CORE 6.1.0710 ALLOT ( n -- ) - allocate n bytes to the code dictionary. */
	.section .dic
word_ALLOT:
	.word	word_TICK
	.byte	5
	.ascii	"ALLOT"
ALLOT:
	.word	code_ENTER
	.word	IMM,HEREP
	.word	PLUS_STORE
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* CORE 6.1.0150 , (u -- ) Pop a word and save it HERE, then make HERE point to the next cell */
	.section .dic
word_COMMA:
	.word	word_ALLOT
	.byte	1
	.ascii	","
COMMA:
	.word	code_ENTER
	.word	HERE		/* (VALUE) (HERE) */
	.word	DUP		/* (VALUE) (HERE) (HERE) */
	.word	CELLP		/* (VALUE) (HERE) (HERE+2) */
	.word	IMM, HEREP	/* (VALUE) (HERE) (HERE+2) (HEREP=&HERE) */
	.word	STORE		/* (VALUE) (HERE) */
	.word	STORE		/* Empty */
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* CORE 6.1.0860 C, (u -- ) Pop a word and the LSB char it HERE, then make HERE point to the next char */
	.section .dic
word_CCOMMA:
	.word	word_COMMA
	.byte	2
	.ascii	"C,"
CCOMMA:
	.word	code_ENTER
	.word	HERE		/* (VALUE) (HERE) */
	.word	DUP		/* (VALUE) (HERE) (HERE) */
	.word	CHARP		/* (VALUE) (HERE) (HERE+1) */
	.word	IMM, HEREP	/* (VALUE) (HERE) (HERE+1) (HP=&HERE) */
	.word	STORE		/* (VALUE) (HERE) */
	.word	CSTORE		/* Empty */
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* POSTPONE ( "<spaces>ccc<space>" -- ) - compile the next immediate word into code dictionary. */
	.section .dic
word_POSTPONE:
	.word	word_CCOMMA
	.byte	8 + WORD_IMMEDIATE
	.ascii	"POSTPONE"
POSTPONE:
	.word	code_ENTER
	.word	TICK
	.word	COMMA
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* INTERNAL compile ( -- ) - compile the next address in colon list to code dictionary. */
/* This is a short hand for IMM,VALUE,COMMA. Only goal is to save ROM space (one word saved per use wrt to direct IMM). */
/* TODO rename COMPILE_IMM */
COMPILE_IMM:
	.word	code_ENTER
	.word	RFROM
	.word	DUP
	.word	LOAD
	.word	COMMA
	.word	CELLP
	.word	TOR
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* CORE 6.1.1780 LITERAL ( w -- ) - compile tos to code dictionary as an integer literal. */

	.section .dic
word_LITERAL:
	.word	word_POSTPONE
	.byte	7 + WORD_IMMEDIATE
	.ascii	"LITERAL"
LITERAL:
	.word	code_ENTER
	.word	COMPILE_IMM,IMM
	.word	COMMA
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* PROPRIETARY $,"       ( -- ) - compile a literal string up to next " */
word_SCOMPQ:
	.word	word_LITERAL
	.byte	3
	.ascii	"$,\""
SCOMPQ:
	.word	code_ENTER
	.word	IMM,'"'
	.word	WORD		/* Clever! Use HERE as storage temporary, cstring is already put at the right place! */
	/* Compute the new value for HERE */
	.word	CLOAD
	.word	CHARP
	.word	HERE
	.word	PLUS
	.word	IMM,HEREP
	.word	STORE
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* PROPRIETARY for ( -- a ) - start a for-next loop structure in a colon deND:nition. */
/* This word pushes the current address on the data stack for later jump back*/
	.section .dic
word_FOR:
	.word	word_SCOMPQ
	.byte	3 + WORD_COMPILEONLY + WORD_IMMEDIATE
	.ascii	"FOR"
FOR:
	.word	code_ENTER
	.word	COMPILE_IMM,TOR
	.word	HERE
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* PROPRIETARY next ( a -- ) - terminate a for-next loop structure. */
/* This word USES the loop-start address that was pushed on the stack by FOR */
	.section .dic
word_NEXT:
	.word	word_FOR
	.byte	4 + WORD_COMPILEONLY + WORD_IMMEDIATE
	.ascii	"NEXT"
NXT:
	.word	code_ENTER
	.word	COMPILE_IMM,JNZD
	.word	COMMA
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* PROPRIETARY AFT ( a -- a a ) - jump to then in a for-aft-then-next loop the first time through. */
	.section .dic
word_AFT:
	.word	word_NEXT
	.byte	3 + WORD_COMPILEONLY + WORD_IMMEDIATE
	.ascii	"AFT"
AFT:
	.word	code_ENTER
	.word	DROP
	.word	AHEAD
	.word	BEGIN
	.word	SWAP
	.word	RETURN


/*---------------------------------------------------------------------------*/
/* CORE 6.1.0760 BEGIN ( -- a ) - start an infinite or indefinite loop structure. */
/* This word pushes the current address on the data stack for later jump back*/

	.section .dic
word_BEGIN:
	.word	word_AFT
	.byte	5 + WORD_COMPILEONLY + WORD_IMMEDIATE
	.ascii	"BEGIN"
BEGIN:
	.word	code_ENTER
	.word	HERE
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* CORE 6.1.2390 UNTIL ( a -- ) - terminate a begin-until indefinite loop structure. */
/* This word USES the loop-start address that was pushed on the stack by BEGIN */
	.section .dic
word_UNTIL:
	.word	word_BEGIN
	.byte	5 + WORD_COMPILEONLY + WORD_IMMEDIATE
	.ascii	"UNTIL"
UNTIL:
	.word	code_ENTER
	.word	COMPILE_IMM,BRANCHZ
	.word	COMMA
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* CORE_EXT 6.2.0700 AGAIN ( a -- ) - terminate a begin-again infinite loop structure. */
/* This word USES the loop-start address that was pushed on the stack by BEGIN */
	.section .dic
word_AGAIN:
	.word	word_UNTIL
	.byte	5 + WORD_COMPILEONLY + WORD_IMMEDIATE
	.ascii	"AGAIN"
AGAIN:
	.word	code_ENTER
	.word	COMPILE_IMM,BRANCH
	.word	COMMA
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* CORE 6.1.1700 IF ( -- a ) - begin a conditional branch structure. */
/* This word pushes the address where the forward jump address will have to be stored by THEN or ELSE */
	.section .dic
word_IF:
	.word	word_AGAIN
	.byte	2 + WORD_COMPILEONLY + WORD_IMMEDIATE
	.ascii	"IF"
IF:
	.word	code_ENTER
	.word	COMPILE_IMM,BRANCHZ
	.word	HERE			/* Push the address of the forward ref on the stack */
	.word	IMM,0,COMMA		/* Reserve a cell to subsequent definition by THEN */
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* TOOLS 15.6.2.0702 AHEAD ( -- a ) - compile a forward branch instruction. */
section .dic
word_AHEAD:
	.word	word_IF
	.byte	5 + WORD_COMPILEONLY + WORD_IMMEDIATE
	.ascii	"AHEAD"
AHEAD:
	.word	code_ENTER
	.word	COMPILE_IMM,BRANCH
	.word	HERE
	.word	IMM,0
	.word	COMMA
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* CORE 6.1.2140 REPEAT ( a a -- ) - terminate a begin-while-repeat indefinite loop. */
	.section .dic
word_REPEAT:
	.word	word_AHEAD
	.byte	6 + WORD_COMPILEONLY + WORD_IMMEDIATE
	.ascii	"REPEAT"
REPEAT:
	.word	code_ENTER
	.word	AGAIN
	.word	HERE
	.word	SWAP
	.word	STORE
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* CORE 6.1.2270 THEN ( a -- ) - terminate a conditional branch structure. */
	.section .dic
word_THEN:
	.word	word_REPEAT
	.byte	4 + WORD_COMPILEONLY + WORD_IMMEDIATE
	.ascii	"THEN"
THEN:
	.word	code_ENTER
	.word	HERE
	.word	SWAP
	.word	STORE
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* CORE 6.1.1310 ELSE ( a -- a ) - start the false clause in an if-else-then structure. */
	.section .dic
word_ELSE:
	.word	word_THEN
	.byte	4 + WORD_COMPILEONLY + WORD_IMMEDIATE
	.ascii	"ELSE"
ELSE:
	.word	code_ENTER
	.word	AHEAD
	.word	SWAP
	.word	THEN
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* CORE 6.1.2430 WHILE ( a -- a a ) - conditional branch out of a begin-while-repeat loop. */
	.section .dic
word_WHILE:
	.word	word_ELSE
	.byte	5 + WORD_COMPILEONLY + WORD_IMMEDIATE
	.ascii	"WHILE"
WHILE:
	.word	code_ENTER
	.word	IF
	.word	SWAP
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* ABORT" */
/* Words that need a string literal after them have an immediate word for compilation and a runtime word that is actually compiled. */
/* TODO make compliant with CORE 6.1.0680 and EXCEPTION_EXT 9.6.2.0680 */
	.section .dic
word_ABORTQ:
	.word	word_WHILE
	.byte	6 + WORD_COMPILEONLY + WORD_IMMEDIATE
	.ascii	"ABORT\""
ABORTQ:
	.word	code_ENTER
	.word	COMPILE_IMM,ABORTNZ
	.word	SCOMPQ
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* CORE 6.1.2165 S" - compile an inline string literal. 
   COMPILE TIME: ( "ccc<quote>" -- ) -> STRQ, executes common string litteral definition SCOMPQ
   RUN TIME:     ( -- c-addr u )     -> IMMSTR, reads following string litteral defined by SCOMPQ
 */
/* Words that need a string literal after them have an immediate word for compilation and a runtime word that is actually compiled. */
	.section .dic
word_STRQ:
	.word	word_ABORTQ
	.byte	2 + WORD_COMPILEONLY + WORD_IMMEDIATE
	.ascii	"S\""
STRQ:
	.word	code_ENTER
	.word	COMPILE_IMM,IMMSTR
	.word	SCOMPQ
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* CORE 6.1.0190 ." - compile an inline string literal to be typed out at run time.
   COMPILE TIME: ( "ccc<quote>" -- ) -> DOTQ, executes common string litteral definition SCOMPQ
   RUN TIME:     ( -- )              -> SHOWSTR, reads following string litteral defined by SCOMPQ
 */
/* Words that need a string literal after them have an immediate word for compilation and a runtime word that is actually compiled. */
word_DOTQ:
	.word	word_STRQ
	.byte	2 + WORD_COMPILEONLY + WORD_IMMEDIATE
	.ascii	".\""
DOTQ:
	.word	code_ENTER
	.word	COMPILE_IMM,SHOWSTR
	.word	SCOMPQ
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* PROPRIETARY $,N ( na -- ) - build a new dictionary name using the string at na. */
	.section .dic
word_SNAME:
	.word	word_DOTQ
	.byte	3
	.ascii	"$,N"
SNAME:
	.word	code_ENTER
	/* Store a pointer to the current definition */
	.word	HERE
	.word	IMM,CURDP
	.word	STORE
	/* Store the pointer to the previous definition in the prev link */	
	.word	IMM,LASTP
	.word	LOAD		/* Load pointer to last name */
	.word	COMMA		/* save prev address */
	/* Parse word name and store at HERE */
	.word	TOKEN		/* cstr | save name string at HERE */
	.word	DUP		/* cstr cstr*/
	.word	FIND		/* cstr code name | cstr name 0*/
	.word	BRANCHZ,sn2	/* cstr code | cstr name */
	/* not zero: name exists, warn user */
	.word	SHOWSTR
	.byte	7
	.ascii	"  redef"
sn2:
	/* goto end of token */
	.word	DROP		/* cstr */
	.word	CLOAD		/* len */
	.word	CHARP		/* len+1 */
	.word	HERE		/* len+1 here */
	.word	PLUS		/* here_after_str */
	.word	IMM,HEREP	/* here_after_str herep */
	.word	STORE		/* -- Update HERE after the word name */
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* CORE 6.1.0450 : ( "<spaces>ccc<space>" -- ) - start a new colon definition using next word as its name. */
	.section .dic
word_COLON:
	.word	word_SNAME
	.byte	1
	.ascii	":"
COLON:
	.word	code_ENTER
	.word	SNAME
	.word	COMPILE_IMM,code_ENTER	/* save codeptr to execute the definition */
	.word	COMPIL			/* Enter compilation mode */
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* PROPRIETARY OVERT ( -- ) Link last word in current vocabulary */
word_OVERT:
	.word	word_COLON
	.byte	5
	.ascii	"OVERT"
OVERT:
	.word	code_ENTER
	/* Update LAST to the current def */
	.word	IMM,CURDP
	.word	LOAD
	.word	IMM,LASTP
	.word	STORE
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* CORE 6.1.0460 ; ( -- ) - terminate a colon definition.*/
	.section .dic
word_SEMICOL:
	.word	word_OVERT
	.byte	1 + WORD_COMPILEONLY + WORD_IMMEDIATE
	.ascii	";"
SEMICOL:
	.word	code_ENTER
	.word	COMPILE_IMM,RETURN	/* Write the final RETURN */
	.word	OVERT		/* Save new LAST */
	.word	INTERP		/* Back to interpreter mode */
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* CORE 6.1.1710 IMMEDIATE ( -- ) */
	.section .dic
word_IMMEDIATE:
	.word	word_SEMICOL
	.byte	9
	.ascii	"IMMEDIATE"
IMMEDIATE:
	.word	code_ENTER
	.word	IMM,CURDP		/*curdp = &cur_def_ptr*/
	.word	LOAD			/*cur_def_ptr*/
	.word	CELLP			/*cstr*/
	.word	DUP			/*cstr cstr*/
	.word	CLOAD			/*cstr name_len_and_flags*/
	.word	IMM,WORD_IMMEDIATE	/*cstr name_len_and_flags IMM*/
	.word	OR			/*cstr name_len_and_flags|IMM*/
	.word	SWAP			/*name_len_and_flags|IMM cstr*/
	.word	CSTORE			/*--*/
	.word	RETURN
 
/*---------------------------------------------------------------------------*/
/* INTERNAL DOVAR ( -- a ) - run time routine for variable and create. */
/* Before DOVAR is called the return stack receives the address right after
   the dovar word itself. This value is popped from the return stack, so when
   returning from DOVAR with RETURN, execution is transferred not to the word
   that called dovar, but to its parent. This means that the word that uses dovar
   is interrupted. The parent continues to execute with the address of the word
   that follows dovar on the stack.*/
	.section .dic
DOVAR:
	.word	code_ENTER
	.word	RFROM
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* CORE 6.1.1000 CREATE ( "<spaces>ccc<space>" -- ) - compile a new array entry without allocating code space.*/
/* CREATE returns the address of the byte just after the DOVAR word. Using
   ALLOT after CREATE is a method to reserve memory, and the name created by CREATE would
   push the address of this reserved memory on the stack, simulating a buffer or variable.
   But it is interesting to replace DOVAR by some other word address, which is used to
   implement DOES> (later) */
	.section .dic
word_CREATE:
	.word	word_IMMEDIATE
	.byte	6
	.ascii	"CREATE"
CREATE:
	.word	code_ENTER
	.word	SNAME
	.word	OVERT
	.word	IMM,code_ENTER	/* save code to execute the definition */
	.word	COMMA
	/* Store the current address so DOES can replace the DOVAR if called. */
	.word	HERE
	.word	IMM,LSTCRP
	.word	STORE
	/* Now emit the DOVAR, this word can be replaced later by DOES>*/
	.word	COMPILE_IMM,DOVAR
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* CORE 6.1.2410 VARIABLE  ( -- ; <string> ) - compile a new variable initialized to 0. */
/* VARIABLE uses CREATE and follows this by a call to COMMA that stores zero
   in the cell right after DOVAR, then increments HERE by a cell. This has the
   effect to return the address of this cell when the name is invoked.*/
	.section .dic
word_VARIABLE:
	.word	word_CREATE
	.byte	8
	.ascii	"VARIABLE"
VARIABLE:
	.word	code_ENTER
	.word	CREATE		/* parse the name that follows in the input stream and link in in the dict*/
	.word	IMM,0
	.word	COMMA		/* Store a zero after create's DOVAR and increment HERE by a cell */
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* CORE 6.1.1250 DOES>
   [when a definition calls DOES>]
   COMPILE TIME:   ( -- ) Execute the run time semantics (immediate word)
   RUN TIME:       ( -- ) Replaces the action of the last CREATEd definition by the code that follows DOES>.
   [when the definition that called DOES> is executed]
   INITIATION TIME:( ... -- ... a ) Place the address of the CREATEd definition data field on the stack.
   EXECUTION TIME: ( ... -- ... ) Execute the action that is described by the words that follow DOES>.
 */
/* Change the behaviour of CREATE with custom code */
/* When a word is created with CREATE NAME, the structure assembled at HERE is:
   .word	LAST
   .byte	NAME_LENGTH
   .ascii	NAME
   .word	code_ENTER
   .word	DOVAR

CREATE in interpretation mode

When executed, this word RFROM the return address of DOVAR towards the created name.
This is in fact the address of the word that follows DOVAR, which is the address of
the datafield for the word. DOVAR then executes a RETURN, that will not end the
execution of DOVAR (since the return address was pulled) but will instead end the
execution of the CREATEd word.
When CREATE is executed, HERE also points to the address after the DOVAR containing cell.

An allocation word that increments HERE can then be used to create a data field after the
DOVAR word, that can be used for data storage.

CREATE in compilation mode

It is possible to compile a colon definition that uses CREATE. When such a definition is
executed, it will parse the next TOKEN from the input buffer and use that for CREATE. This
is what is used by VARIABLE:
: VARIABLE CREATE 0 , ;

When used like this:
VARIABLE LEN
The execution of variable will call CREATE, create will parse LEN and create a definition.
After this, zero is pushed on the stack and stored at HERE, then HERE in incremented by a cell.
This is a defining word: It creates a new word.
When LEN is executed, the DOVAR word of CREATE will be executed, and that will push the address
of the datafield on the stack. LEN can then be used with @ and ! to hold a value.

CREATE in compilation mode with appended DOES>

At execution of the colon definition that contains create/does, 
1 - CREATE will parse the input buffer and create a definition, then execute any allocation word that follows.
2 - DOES> will start compiling a new unnamed executable word (by compiling a code_ENTER) and replace the DOVAR word in the newly CREATEd definition by the address of the code_ENTER that was just stored.

This is easy because one can just save the address of the DOVAR word before leaving create.
The following words are compiled right next after DOES>, so this creates an unnamed word that will be executed by the newly CREATEd definition.

Summary
DOES> is an immediate word. when found in a colon definition (compilation state) the following happens:
-compiles a STORE of the next next address
-compile a RETURN
(this is the address that was stored in create's DOVAR
-prepare a new unnamed word (compile code_ENTER)
-compile the words that follow DOES>

when a colon definition that contains DOES is executed
-create and the allocation words up to DOES are executed
-STORE of the unnamed code that follows is stored in created DOVAR
-done

when the word defined by create and modified by DOES is executed
-code that was installed by DOES> is executed
-data field of created definition is pushed
-user words after DOES are executed

Example for assembler:
 : INHERENT          ( Defines the name of the class)
     CREATE          ( this will create an instance)
         C,          ( store the parameter for each instance)
     DOES>           ( this is the class' common action)
         C@          ( get each instance's parameter)
         C,          ( the assembly action, as above)
     ;               ( End of definition)

 HEX
 12  INHERENT NOP,   ( Defines an instance NOP, of class INHERENT, with parameter 12H.)

sys11 forth ver 1.00
: INH CREATE C, DOES> C@ C, ;  ok
42 INH NOP  ok
$100 64 DUMP
 100  F2 9C  3 49 4E 48 E0 2B EF FD ED D1 E1 57  1 1A  r__INH`+o}mQaW__
 110  E1 57  0 54 E1 9B E1 8E E1 55 E0 2B E1 A9 E1 A2  aW_Ta_a_aU`+a)a"
 120  ED D1 E1 55  1  0  3 4E 4F 50 E0 2B  1 1A 26  4  mQaU___NOP`+__&_
 130  44 55 4D 50 50 4D 41 4C  1 2D  4 50 4C 4F 50 E0  DUMPPMAL_-_PLOP`
 140  2B EF EE  5 41  0 2E 31 34 31  0 33 31 2E 30 30  +on_A_.141_31.00  ok

100	F29C	PREV
102	3	LEN
103	INH	NAME
106	E02B	code_ENTER
108	EFFD	CREATE
10A	EDD1	C,
10C	E157	IMM
10E	011A
110	E157	IMM
112	0054	LASTCRP
114	E19B	LOAD
116	E18E	STORE
118	E155	RETURN
------------------------------- start of action
11A	E02B	code_ENTER
11C	E1A9	RFROM
11E	E1A2	C@
120	EDD1	C,
122	E155	RETURN
------------------------------- end of action
124	0100
126	3
127	NOP
12A	E02B	code_ENTER
12C	011A 	action_for_INH
12E	26 	data zone for NOP

*/
word_DOES:
	.word	word_VARIABLE
	.byte	5 + WORD_COMPILEONLY + WORD_IMMEDIATE
	.ascii	"DOES>"
DOES:
	.word	code_ENTER
	/* When called, we are compiling a word.*/
	/* Now, we have to define a new unnamed word. The address
	of the unnamed word is HERE. this value must be stored in place of
	the DOVAR that was defined by the previous CREATE*/
	.word	COMPILE_IMM,IMM
	.word	HERE
	.word	IMM,6,CELLS,PLUS	/* Compute the address of the code that replaces DOVAR in the created def */
	.word	COMMA
	.word	COMPILE_IMM,IMM
	.word	COMPILE_IMM,LSTCRP	/* The cell pointed by this address contains the address of the DOVAR for the last CREATE */
	.word	COMPILE_IMM,LOAD	/* Get the address that contains DOVAR */
	.word	COMPILE_IMM,STORE		/* This actually stores the SAME code pointer (after the definition end) in each created instance. */
	/* The code executed by the definition stops here. Next compiled words will be the DOES action. */
	.word	COMPILE_IMM, RETURN

	/*Start the code that will be executed by the CREATEd definition */
	.word	COMPILE_IMM,code_ENTER
	.word	COMPILE_IMM,RFROM	/* Just before executing the DOES action, we compile code that acts like the original DOVAR to get the CREATEd data field */
	.word	RETURN		/* DOES> has finished preparing the mem. next compiled words are added. */

/*---------------------------------------------------------------------------*/
/* CORE_EXT 6.2.1850 MARKER ( <spaces>name<spaces> -- ) */
/* Create a definition that, when executed, will delete itself and all words
   that were defined later. We do that by saving/restoring HERE and LAST */
/* Example:
sys11 forth ver 1.00
MARKER base  ok
$100 31 DUMP
 100  F2 A2  4 62 61 73 65 E0 21 E1 BE F2 A2 E1 BE  0  r"_base`!a>r"a>_
 110  44 E2  1 E1 BE  1  0 E1 BE  0 42 E2  1 E1 BC  4  Db_a>__a>_Bb_a<_  ok

100	F2A2	PREV
102	4 str -> base
107	E021	code_ENTER
109	E1BE	IMM
10B	F2A2	prev
10D	E1BE	IMM
10F	0044	LASTP
111	E201	STORE

113	E1BE	IMM
115	0100	HERE_START
117	E1BE	IMM
119	0042	HEREP
11B	E201	STORE
11D	E1BC	RETURN
*/
	.section .dic
word_MARKER:
	.word	word_DOES
	.byte	6
	.ascii	"MARKER"
MARKER:
	.word	code_ENTER
	.word	HERE		/* here_before | Save HERE - this is the restore point*/
	.word	CREATE		/* here_before | Create a DOVAR definition, eating the next token */
	.word	IMM,LSTCRP	/* here_before &lstptr */
	.word	LOAD		/* here_before listptr */
	.word	IMM,HEREP	/* here_before listptr &here Rewind HERE to overwrite the DOVAR with COMMA */
	.word	STORE		/* here_before -- */
	/* Now TOS contains the pointer to this code's word. */
	/* We can replace DOVAR by some code that will restore HERE and LASTP.*/
	/*After create, loading at here_before will retrieve the ptr to the prev word */
	.word	DUP		/* here_before here_before */

	.word	LOAD		/* here_before prev_before */

	.word	LITERAL		/* here_before Generate code to push prev_before */
	.word	IMM,LASTP	/* here_before LASTP */
	.word	LITERAL		/* here_before Generate code to push LASTP */
	.word	COMPILE_IMM,STORE/*Generate code to store prev_before into LAST */

	.word	LITERAL		/* Generate code to push here_before */
	.word	IMM,HEREP	/* HEREP */
	.word	LITERAL		/* Generate code to push the address of here */
	.word	COMPILE_IMM,STORE

	.word	COMPILE_IMM,RETURN
	.word	RETURN

/*===========================================================================*/
/* Shell */
/*===========================================================================*/

/*---------------------------------------------------------------------------*/
	.section .dic
word_TOIN:
	.word	word_MARKER
	.byte	3
	.ascii	">IN"
TOIN:
	.word	code_ENTER
	.word	IMM,TOINP
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* PROPRIETARY PROMPT ( -- ) */
	.section .dic
word_PROMPT:
	.word	word_TOIN
	.byte	6
	.ascii	"PROMPT"
PROMPT:
	/* Test if we are in compilation mode */
	.word	code_ENTER
	.word	STATE
	.word	NOT
	.word	BRANCHZ,compilmode	/* state not zero: jump to compilation behaviour (just cr)*/
	/* No: interpretation: show OK */
	.word	SHOWSTR
	.byte	4
	.ascii	"  ok"
compilmode:
	.word	CR
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* PROPRIETARY ?STACK ( -- ) abort if the data stack underflows. */
	.section .dic
word_QSTACK:
	.word	word_PROMPT
	.byte	6
	.ascii	"?STACK"
QSTACK:
	.word	code_ENTER
	.word	DEPTH
	.word	ZLESS
	.word	ABORTNZ
	.byte	10
	.ascii	"underflow!"
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* INTERNAL eval ( -- ) */
/* Used by EVALUATE nd QUIT. Evaluate all words in input buffer.
 * Each word is interpreted or compiled according to current behaviour
 */
	.section .dic
EVAL:
	.word	code_ENTER
eval1:
	.word	TOKEN			/* tokcstr */
	.word	DUP			/* tokcstr tokcstr */
	.word	CLOAD			/* tokcstr toklen | input stream empty?*/
	.word	BRANCHZ, evalfinish	/* tokcstr Could not parse: finish execution of buffer */

	.word	FIND			/*code TRUE || codeimm 1 || cstr false */
	.word	DUPNZ			/* Duplicate only if 1 or -1 */
	.word	BRANCHZ,evnum		/* code +-1 | cstr if not name then evnum */

	/*Name is found. Execute in all cases (immediate or not) */
	.word	STATE			/* code +-1 state */
	.word	BRANCHZ,evinterp	/* code +-1 */

	/* In compilation mode. Check if word is immediate */
	.word	IMM,1			/* code +-1 1 */
	.word	XOR			/* code zero_if_imm */
	.word	BRANCHZ, evinterp2	/* code */

	/* Word is not immediate -> compile */
	.word	COMMA
	.word	BRANCH,evnext

evinterp:
	.word	DROP			/* code */
evinterp2:
	/* Interpret word - because interpreting or compiling an immediate word.*/
	.word	EXECUTE
	.word	BRANCH, evnext	/* Manage next token */

evnum:
	.word	NUMBERQ
	.word	BRANCHZ,notfound	/*consume the OK flag and leaves the number on the stack for later use*/
	/* Valid number*/
	.word	STATE		/* tokstr state */
	.word	BRANCHZ, evnext	/* If interpreting, the number just stays on the stack and look at next token */
	.word	LITERAL		/* If compiling, the number left on stack is instead compiled as an IMM */
	.word	BRANCH, evnext	/* Manage next token */

notfound:
	.word	THROW	/* Throw the failed name as exception, to be caught in QUIT */

evnext:
	.word	QSTACK		/*TODO Check stack underflow */
	.word	BRANCH, eval1	/* Do next token */

evalfinish:
	.word	DROP		/*--*/
	.word	PROMPT		/**/
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* PROPRIETARY HAND ( -- ) Reset the input buffer to its default storage and size. */
word_HAND:
	.word	word_QSTACK
	.byte	4
	.ascii	"HAND"
HAND:
	.word	code_ENTER
	.word	IMM, TIB_LEN
	.word	IMM, STIBP
	.word	STORE
	.word	IMM, TIBBUF
	.word	IMM, TIBP
	.word	STORE
	.word	IMM,0
	.word	IMM,NTIBP
	.word	STORE
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* CORE 6.1.2216 SOURCE ( -- buf len ) */
/* Return the current input buffer address and length */
word_SOURCE:
	.word	word_HAND
	.byte	6
	.ascii	"SOURCE"
SOURCE:
	.word	code_ENTER
	.word	IMM,TIBP
	.word	LOAD
	.word	IMM,STIBP
	.word	LOAD
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* CORE_EXT 6.2.2148 ( -- STIB NTIB IN TIB 4 ) */
word_SAVEINPUT:
	.word	word_SOURCE
	.byte	10
	.ascii	"SAVE-INPUT"
SAVEINPUT:
	.word	code_ENTER
	.word	IMM,STIBP	/* buf len &tib_size */
	.word	LOAD		/* buf */
	.word	IMM,NTIBP	/* buf len &tib_received */
	.word	LOAD		/* buf */
	.word	TOIN		/* >IN */
	.word	LOAD		/* -- */
	.word	IMM,TIBP	/* buf &tib */
	.word	LOAD		/* -- */
	.word	IMM,4
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* CORE_EXT 6.2.2148 ( STIB NTIB IN TIB 4 -- flag ) */
word_RESTOREINPUT:
	.word	word_SAVEINPUT
	.byte	13
	.ascii	"RESTORE-INPUT"
RESTOREINPUT:
	.word	code_ENTER
	.word	IMM,4
	.word	XOR
	.word	BRANCHZ,restore
	.word	IMM,1		/* cannot restore - stack problem */
	.word	RETURN
restore:
	.word	IMM,TIBP	/* buf &tib */
	.word	STORE		/* -- */
	.word	TOIN		/* >IN */
	.word	STORE		/* -- */
	.word	IMM,NTIBP	/* buf len &tib_received */
	.word	STORE		/* buf */
	.word	IMM,STIBP	/* buf len &tib_size */
	.word	STORE		/* buf */
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* CORE 6.1.1360 EVALUATE ( ... buf len -- ... ) */
/* BLOCK 7.6.1.1360 EVALUATE */
/* Make the buffer pointed by buf and len the TIB, evaluate, then restore the
 * original console TIB. */
word_EVALUATE:
	.word	word_RESTOREINPUT
	.byte	8
	.ascii	"EVALUATE"
EVALUATE:
	.word	code_ENTER
	.word	SAVEINPUT
	.word	TOR,TOR,TOR,TOR,TOR
	.word	DUP
	.word	IMM,STIBP	/* buf len &tib_size */
	.word	STORE		/* buf */
	.word	IMM,NTIBP	/* buf len &tib_received */
	.word	STORE		/* buf */
	.word	IMM,TIBP	/* buf &tib */
	.word	STORE		/* -- */
	.word	IMM,0		/* 0 */
	.word	TOIN		/* >IN */
	.word	STORE		/* -- */
	.word	EVAL		/* Evaluate input */
	.word	RFROM,RFROM,RFROM,RFROM,RFROM
	.word	RESTOREINPUT	/* Restore input source */
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* PROPRIETARY CONSOLE ( -- ) Make IO vectors point at the default serial implementations */
word_CONSOLE:
	.word	word_EVALUATE
	.byte	7
	.ascii	"CONSOLE"
CONSOLE:
	.word	code_ENTER
	.word	IMM, IOTX
	.word	IMM, TXVEC
	.word	STORE
	.word	IMM, IORX
	.word	IMM, RXVEC
	.word	STORE
	.word	HAND
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* CORE 6.1.2050 QUIT ( -- ) Main forth interactive interpreter loop */
/* TODO check compliance with F2012 */
    .section .dic
word_QUIT:
	.word	word_CONSOLE
	.byte	4
	.ascii	"QUIT"
QUIT:
	.word	code_ENTER
QUIT0:
	.word	INTERP	/* Force interpretation mode in case catch aborts during compilation */

QUIT1:
	/* Load the terminal input buffer */
	.word	IMM, TIBP
	.word	LOAD
	.word	IMM, STIBP
	.word	LOAD
	.word	ACCEPT

	/* Save the length of the received buffer */
	.word	IMM, NTIBP
	.word	STORE
    
	/* Reset input buffer pointer to start of buffer */
	.word	IMM,0
	.word	TOIN
	.word	STORE

	/* Execute the line */
	.word	IMM,EVAL	/* Function to be caught */
	.word	CATCH		/* returns zero if no error */
	.word	DUPNZ		/* Does nothing if no error */
	.word	BRANCHZ, QUIT1	/* Consume catch return code. If thats zero, no error, loop again */

	/* CATCH caught an error, DUPNZ left the error that was thrown on the stack */
	.word	CONSOLE
	.word	SHOWSTR
	.byte	7
	.ascii	"  err: "
	.word	COUNT,TYPE	/* Display error message from throw */
	.word	CR
	/* TODO PRESET reinit data stack to top */
	.word	BRANCH,QUIT0	/* Interpret again */

/*===========================================================================*/
/* Tools */
/*===========================================================================*/

/*---------------------------------------------------------------------------*/
/* PROPRIETARY _type ( b u -- ) - display a string. filter non-printing characters. */
	.section .dic
word_UTYPE:
	.word	word_QUIT
	.byte	5
	.ascii	"_TYPE"
UTYPE:
	.word	code_ENTER
	.word	TOR			/* start count down loop */
	.word	BRANCH,utyp2		/* skip first pass */
utyp1:
	.word	DUP,CLOAD,TCHAR,EMIT	/* display only printable */
	.word	CHARP			/* increment address */
utyp2:
	.word	JNZD,utyp1		/* loop till done */
	.word	DROP
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* PROPRIETARY dm+ ( a u -- a ) - dump u bytes from , leaving a+u on the stack. */
	.section .dic
word_DMP:
	.word	word_UTYPE
	.byte	3
	.ascii	"dm+"
DMP:
	.word	code_ENTER
	.word	OVER,IMM,4,UDOTR	/* display address */
	.word	SPACE,TOR		/* start count down loop */
	.word	BRANCH,pdum2		/* skip first pass */
pdum1:
	.word	DUP,CLOAD,IMM,3,UDOTR	/* display numeric data */
	.word	INC			/* increment address */
pdum2:
	.word	JNZD,pdum1		/* loop till done */
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* TOOLS 15.6.1.1280 DUMP ( a u -- ) - dump u bytes from a, in a formatted manner. */
	.section .dic
word_DUMP:
	.word	word_DMP
	.byte	4
	.ascii	"DUMP"
DUMP:
	.word	code_ENTER
	.word	BASE,LOAD,TOR,HEX	/* save radix, set hex */
	.word	IMM,16,SLASH		/* change count to lines*/
	.word	TOR			/* start count down loop */
dump1:
	.word	CR,IMM,16,DDUP,DMP
	.word	ROT,ROT
	.word	SPACE,SPACE,UTYPE	/* display printable characters */
	.word	NUFQ,NOT		/* user control */
	.word	BRANCHZ,dump2
	.word	JNZD,dump1		/* loop till done */
	.word	BRANCH,dump3
dump2:
	.word	RFROM,DROP		/* cleanup loop stack, early exit */
dump3:
	.word	DROP,RFROM,BASE,STORE	/* restore radix */
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* TOOLS 15.6.1.0220 .S ( -- ) - display the contents of the data stack. */
word_DOTS:
	.word	word_DUMP
	.byte	2
	.ascii	".S"
DOTS:
	.word	code_ENTER
	.word	CR,DEPTH	/* stack depth */
	.word	TOR		/* start count down loop */
	.word	BRANCH,dots2	/* skip first pass */
dots1:
	.word	RLOAD,PICK,DOT
dots2:
	.word	JNZD,dots1	/* loop till done */
	.word	SHOWSTR
	.byte	4
	.ascii	" <sp"
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* PROPRIETARY !csp ( -- ) - save stack pointer in csp for error checking. */
word_CSPSTORE:
	.word	word_DOTS
	.byte	4
	.ascii	"!CSP"
CSPSTORE:
	.word	code_ENTER
	.word	SPLOAD
	.word	IMM,CSPP
	.word	STORE
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* PROPRIETARY ?csp ( -- ) - abort if stack pointer differs from that saved in csp. */
word_CSPCHECK:
	.word	word_CSPSTORE
	.byte	4
	.ascii	"?CSP"
CSPCHECK:
	.word	code_ENTER
	.word	SPLOAD
	.word	IMM,CSPP
	.word	LOAD
	.word	XOR
	.word	ABORTNZ
	.byte	6
	.ascii	"stack!"
	.word	RETURN

/*---------------------------------------------------------------------------*/

/*---------------------------------------------------------------------------*/
/* TOOLS_EXT 15.6.2.2297 TRAVERSE-WORDLIST ( ... codeptr voc -- ... ) */
/* TRAVERSE-WORDLIST-CALLBACK ( ... namecstr -- ... flag ) */
/* Execute codeptr for each word in voc passing name ptr, stop when flag returns zero.
 * When callback is executed the stack does not have anything,
 * so previous items can be accessed.
 */
word_TRWL:
	.word	word_CSPCHECK
	.byte	17
	.ascii	"TRAVERSE-WORDLIST"
TRWL:
	.word   code_ENTER
wldo:
	.word	DUP		/* cbcodeptr voc voc */
	.word	LOAD		/* cbcodeptr voc prev */
	.word	TOR		/* cbcodeptr voc | R:prev*/
	.word	OVER		/* cbcodeptr voc cbcodeptr | R:prev*/
	.word	TOR		/* cbcodeptr voc | R: prev cbcodeptr */
	.word	CELLP		/* cbcodeptr nameptr | R:prev cbcodeptr*/
	.word	SWAP		/* nameptr cbcodeptr | R:prev cbcodeptr*/
	.word	EXECUTE		/* flag | R:prev cbcodeptr*/
	.word	BRANCHZ,wlabrt	/* jump if callback has returned false | R:prev cbcodeptr*/
	.word	RFROM		/*cbcodeptr */
	.word	RFROM		/*cbcodeptr prev */
	.word	DUPNZ		/*cbcodeptr prev prev | cbcodeptr 0*/
	.word	BRANCHZ,wlend	/*cbcodeptr prev | cbcodeptr, jmp if prev null*/

	/* previous is not null, look at prev word */
	.word	BRANCH,wldo	/*cbcodeptr prev*/
wlabrt:
	.word	RFROM		/*cbcodeptr |R:prev */
	.word	RFROM		/*cbcodeptr prev*/
	.word	DROP		/*cbcodeptr*/
wlend:
	.word	DROP		/*--*/
	.word   RETURN

/*---------------------------------------------------------------------------*/
/* INTERNAL routine to print each word enumerated by TRAVERSE-WORDLIST */
/* (namecstr -- 0 [abort] | !0 [continue]) */
TRWL_TYPE:
	.word	code_ENTER
	.word	DUP		/* namecstr nameptr - keep a nameptr on list to continue enum*/
	.word   COUNT		/* namecstr nameptr+1 len+flags */
	.word	IMM,WORD_LENMASK/* namecstr nameptr namelen+flags 0x3F*/
	.word	AND		/* namecstr nameptr namelen*/
	.word	SPACE
	.word   TYPE		/* namecstr - this is a true flag to continue enum */
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* TOOLS 15.6.1.2465 WORDS ( -- ) */
/* Display the names in the context vocabulary. */
word_WORDS:
	.word	word_TRWL
	.byte	5
	.ascii	"WORDS"
WORDS:
	.word	code_ENTER
	.word	CR
	.word	IMM,TRWL_TYPE
	.word	IMM,LASTP	/*cstr [pointer containing the address of the last word] */
	.word	LOAD		/*cstr voc[address of last word entry] */
	.word	TRWL		/* Run this word on all words of the list */
	.word   RETURN

/*===========================================================================*/
/* Boot */
/*===========================================================================*/

/*---------------------------------------------------------------------------*/
/* PROPRIETARY CLEAR ( -- ) */
/* ERASE in F2012 is a memclr */
/* Delete all added definitions. */
word_CLEAR:
	.word	word_WORDS
	.byte	5
	.ascii	"CLEAR"
CLEAR:
	.word	code_ENTER
	.word	IMM, HERE_ZERO
	.word	IMM, HEREP
	.word	STORE
.if USE_SPI
	.word	IMM, word_SPITRAN
.else
	.word	IMM, word_hi
.endif
	.word	IMM,LASTP
	.word	STORE
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* PROPRIETARY VER ( -- u ) */
	.section .dic
word_VER:
	.word	word_CLEAR
	.byte	3
	.ascii	"VER"
VER:
	.word	code_ENTER
	.word	IMM, 0x100
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* PROPRIETARY hi ( -- ) */
	.section .dic
word_hi:
	.word	word_VER
	.byte	2
	.ascii	"hi"
hi:
	.word	code_ENTER
	.word	CR
	.word	SHOWSTR
	.byte	16
	.ascii	"sys11 forth ver "
	.word	BASE,LOAD,TOR
	.word	HEX,VER,BDIGS,DIG,DIG,IMM,'.',HOLD,DIG,EDIGS,TYPE
	.word	RFROM,BASE,STORE
	.word	CR
	.word	RETURN

.if USE_SPI
/*===========================================================================*/
/* SPI Bus */
/*===========================================================================*/

/*---------------------------------------------------------------------------*/
/* ( -- ) */
word_SPIINIT:
	.word	word_hi
	.byte	7
	.ascii	"SPIINIT"
SPIINIT:
	.word	code_SPIINIT
	.text
code_SPIINIT:
	bra	NEXT

/*---------------------------------------------------------------------------*/
/* ( n -- ) */
	.section .dic
word_SPISEL:
	.word	word_SPIINIT
	.byte	6
	.ascii	"SPISEL"
SPISEL:
	.word	code_SPISEL
	.text
code_SPISEL:
	bra	NEXT

/*---------------------------------------------------------------------------*/
/* ( tx -- rx ) */
	.section .dic
word_SPIEXCH:
	.word	word_SPISEL
	.byte	7
	.ascii	"SPIEXCH"
SPIEXCH:
	.word	code_SPIEXCH
	.text
code_SPIEXCH:
	bra	NEXT

/*---------------------------------------------------------------------------*/
/* ( n adrtx adrrx -- ) */
	.section .dic
word_SPITXRX:
	.word	word_SPIEXCH
	.byte	7
	.ascii	"SPITXRX"
SPITXRX:
	.word	code_SPITXRX
	.text
code_SPITXRX:
	bra	NEXT

/*---------------------------------------------------------------------------*/
/* ( n adr --) 0 SPITXRX*/
	.section .dic
word_SPISEND:
	.word	word_SPITXRX
	.byte	7
	.ascii	"SPISEND"
SPISEND:
	.word	code_ENTER
	.word	IMM,0
	.word	SPITXRX
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* ( n adr --) 0 SWAP SPITXRX*/
	.section .dic
word_SPIRECV:
	.word	word_SPISEND
	.byte	7
	.ascii	"SPIRECV"
SPIRECV:
	.word	code_ENTER
	.word	IMM,0
	.word	SWAP
	.word	SPITXRX
	.word	RETURN

/*---------------------------------------------------------------------------*/
/* ( n adr --) DUP SPITXRX*/
	.section .dic
word_SPITRAN:
	.word	word_SPIRECV
	.byte	7
	.ascii	"SPITRAN"
SPITRAN:
	.word	code_ENTER
	.word	DUP
	.word	SPITXRX
	.word	RETURN
.endif

	.if USE_BLOCK
/*===========================================================================*/
/* F2012 BLOCK word set */
/* This extension uses an SPI EEPROM through the SPI words */
/*===========================================================================*/

/*---------------------------------------------------------------------------*/
/* BLOCK 7.6.1.0790 BLK ( -- addr ) */
/*---------------------------------------------------------------------------*/
/* BLOCK 7.6.1.0800 BLOCK ( u -- addr ) */
/*---------------------------------------------------------------------------*/
/* BLOCK 7.6.1.0820 BUFFER ( u -- addr ) */
/*---------------------------------------------------------------------------*/
/* BLOCK 7.6.1.1559 FLUSH ( -- ) */
/*---------------------------------------------------------------------------*/
/* BLOCK 7.6.1.1790 LOAD ( ... u -- ... ) */
/*---------------------------------------------------------------------------*/
/* BLOCK 7.6.1.2180 SAVE-BUFFERS ( -- ) */
/*---------------------------------------------------------------------------*/
/* BLOCK 7.6.1.2400 UPDATE ( -- ) */
/*---------------------------------------------------------------------------*/
/* BLOCK 7.6.2.1330 EMPTY-BUFFERS ( -- ) */
/*---------------------------------------------------------------------------*/
/* BLOCK 7.6.2.1770 LIST ( u -- ) */
/*---------------------------------------------------------------------------*/
/* BLOCK 7.6.2.2125 REFILL ( -- flag ) */
/*---------------------------------------------------------------------------*/
/* BLOCK 7.6.2.2190 SCR ( -- addr ) */
/*---------------------------------------------------------------------------*/
/* BLOCK 7.6.2.2280 THRU ( ... first last -- ... ) */
/*---------------------------------------------------------------------------*/
.endif

/*---------------------------------------------------------------------------*/
/* Main forth interactive interpreter loop */
/* There is no header and no code pointer. This is not really a valid word. */
	.section .rodata
BOOT:
	.word	IOINIT		/* Setup HC11 uart */
	.word	CONSOLE		/* Setup IO vectors */
	.word	DECIMAL		/* Setup environment */
	.word	CLEAR		/* Setup HERE and LAST*/
	.word	hi		/* Show a startup banner */

	.word	QUIT

