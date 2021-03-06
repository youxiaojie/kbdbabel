; ---------------------------------------------------------------------
; Sun to AT/PS2 keyboard transcoder for 8051 type processors.
;
; $Id: kbdbabel_sun_ps2_8051.asm,v 1.7 2008/04/16 21:30:38 akurz Exp $
;
; Clock/Crystal: 11.0592MHz.
; alternatively 18.432MHz and 14.7456 may be used.
; 3.6864MHz or 7.3728 will be too slow to drive the AT/PS2 timer.
;
; Sun Keyboard connect:
; Inverted signal using transistors and 4.7k resistors
; is connected to the serial port lines
; RxD - p3.0 (Pin 10 on DIL40, Pin 2 on AT89C2051 PDIP20)
; TxD - p3.1 (Pin 11 on DIL40, Pin 3 on AT89C2051 PDIP20)
;
; AT Host connect:
; DATA - p3.5	(Pin 15 on DIL40, Pin 9 on AT89C2051 PDIP20)
; CLOCK - p3.3	(Pin 13 on DIL40, Pin 7 on AT89C2051 PDIP20, Int 1)
;
; LED-Output connect:
; LEDs are connected with 220R to Vcc
; ScrollLock	- p1.7	(Pin 8 on DIL40, Pin 19 on AT89C2051 PDIP20)
; CapsLock	- p1.6	(Pin 7 on DIL40, Pin 18 on AT89C2051 PDIP20)
; NumLock	- p1.5	(Pin 6 on DIL40, Pin 17 on AT89C2051 PDIP20)
; ?		- p1.4
; ?		- p1.3
; AT TX Communication abort	- p1.2
; AT RX Communication abort	- p1.1
; TX buffer full		- p1.0
;
; Build using the macroassembler by Alfred Arnold
; $ asl -L kbdbabel_sun_ps2_8051.asm -o kbdbabel_sun_ps2_8051.p
; $ p2bin -l \$ff -r 0-\$7ff kbdbabel_sun_ps2_8051
; write kbdbabel_sun_ps2_8051.bin on an empty 27C256 or AT89C2051
;
; Copyright 2006, 2007 by Alexander Kurz
;
; This is free software.
; You may copy and redistibute this software according to the
; GNU general public license version 3 or any later verson.
;
; ---------------------------------------------------------------------

	cpu 8052
	include	stddef51.inc
	include kbdbabel_intervals.inc

;----------------------------------------------------------
; Variables / Memory layout
;----------------------------------------------------------
;------------------ octets
B20		sfrb	20h	; bit adressable space
B21		sfrb	21h
B22		sfrb	22h
SunLEDBuf	sfrb	23h	; must be bit-adressable
KbBitBufL	equ	24h
KbBitBufH	equ	25h
KbClockMin	equ	26h
KbClockMax	equ	27h
ATBitCount	equ	28h	; AT scancode TX counter
RawBuf		equ	30h	; raw input scancode
OutputBuf	equ	31h	; AT scancode
TXBuf		equ	32h	; AT scancode TX buffer
RingBufPtrIn	equ	33h	; Ring Buffer write pointer, starting with zero
RingBufPtrOut	equ	34h	; Ring Buffer read pointer, starting with zero
ATRXBuf		equ	35h	; AT host-to-dev buffer
ATRXCount	equ	36h
ATRXResendBuf	equ	37h	; for AT resend feature
;KbClockIntBuf	equ	33h

;------------------ bits
MiscRXCompleteF	bit	B20.1	; full and correct byte-received
ATTXBreakF	bit	B20.3	; Release/Break-Code flag
ATTXMasqF	bit	B20.4	; TX-AT-Masq-Char-Bit (send two byte scancode)
ATTXParF	bit	B20.5	; TX-AT-Parity bit
ATTFModF	bit	B20.6	; Timer modifier: alarm clock or clock driver
MiscSleepT0F	bit	B20.7	; sleep timer active flag
ATCommAbort	bit	B21.0	; AT communication aborted
ATHostToDevIntF	bit	B21.1	; host-do-device init flag triggered by ex1 / unused.
ATHostToDevF	bit	B21.2	; host-to-device flag for timer
ATTXActiveF	bit	B21.3	; AT TX active
ATCmdReceivedF	bit	B21.4	; full and correct AT byte-received
ATCmdResetF	bit	B21.5	; reset
ATCmdLedF	bit	B21.6	; AT command processing: set LED
ATCmdScancodeF	bit	B21.7	; AT command processing: set scancode
ATKbdDisableF	bit	B22.0	; Keyboard disable
SunSetLedF	bit	B22.1	; send SetLed Command to sun keyboard: argunent
SunCtrlLedF	bit	B22.2	; send SetLed Command to sun keyboard: control code

;------------------ arrays
RingBuf		equ	40h
RingBufSizeMask	equ	0fh	; 16 byte ring-buffer size

;------------------ stack
StackBottom	equ	50h	; the stack

;----------------------------------------------------------
; start
;----------------------------------------------------------
	org	0	; cold start
	ljmp	Start
;----------------------------------------------------------
; interrupt handlers
;----------------------------------------------------------
;----------------------------
;	org	03h	; external interrupt 0
;	ljmp	HandleInt0
;----------------------------
	org	0bh	; handle TF0
	ljmp	HandleTF0
;----------------------------
;	org	13h	; Int 1
;	ljmp	HandleInt1
;----------------------------
;	org	1bh	; handle TF1
;	ljmp	HandleTF1
;----------------------------
;	org	23h	; RI/TI
;	ljmp	HandleRITI
;----------------------------
;	org	2bh	; handle TF2
;	ljmp	HandleTF2

	org	033h

;----------------------------------------------------------
; int1 handler:
; trigger on host-do-device transmission signal
;----------------------------------------------------------
;HandleInt1:
;	setb	ATHostToDevIntF
;	reti

;----------------------------------------------------------
; timer 0 int handler used for different purposes
; depending on ATTFModF and ATHostToDevF
;
; ATTFModF=0:
; timer is used as 16-bit alarm clock.
; Stop the timer after overflow, cleanup RX buffers
; and clear MiscSleepT0F
;
; ATTFModF=1:
; timer is used in 8-bit-auto-reload-mode to generate
; the AT scancode clock timings.
;
; ATTFModF=1, ATHostToDevF=0:
; device-to-host communication: send datagrams on the AT line.
; Each run in this mode will take 36 processor cycles.
; Extra nops between Data and Clock bit assignment for signal stabilization.
;
; ATTFModF=1, ATHostToDevF=1:
; host-do-device communication: receive datagrams on the AT line.
;----------------------------------------------------------
HandleTF0:
	jb	ATTFModF,timerAsClockTimer	; 2,2

; --------------------------- timer is used as 16-bit alarm clock
timerAsAlarmClock:
; -- stop timer 0
	clr	tr0
	clr	MiscSleepT0F
	reti

; --------------------------- AT clock driver, RX or TX
timerAsClockTimer:
	push	acc			; 2,4
	push	psw			; 2,6
	jb	ATHostToDevF,timerHostToDev	; 2,8

; --------------------------- device-to-host communication
timerDevToHost:
; -- switch on bit-number
; -----------------
	mov	dptr,#timerDevToHostJT		; 2,10
	mov	a,ATBitCount			; 1,11
	rl	a				; 1,12
	jmp	@a+dptr				; 2,14

timerDevToHostJT:
	sjmp	timerTXStartBit		; 2,16
	sjmp	timerTXDataBit
	sjmp	timerTXDataBit
	sjmp	timerTXDataBit
	sjmp	timerTXDataBit
	sjmp	timerTXDataBit
	sjmp	timerTXDataBit
	sjmp	timerTXDataBit
	sjmp	timerTXDataBit
	sjmp	timerTXParityBit
	sjmp	timerTXStopBit
	sjmp	timerTXStop		; safety

; -----------------
timerTXStartBit:
; -- set start bit (0) and pull down clock line
	jnb	p3.3,timerTXClockBusy	; 2
	nop
	clr	p3.5			; 1	; Data Startbit
	call	ATTX_delay_clk
	clr	p3.3			; 1	; Clock
	sjmp	timerTXClockRelease	; 2

; -----------------
timerTXDataBit:
; -- set data bit 0-7 and pull down clock line
	mov	a,TXBuf			; 1
	rrc	a			; 1	; next data bit to c
	mov	p3.5,c			; 2
	mov	TXBuf,a			; 1
	call	ATTX_delay_clk
	clr	p3.3			; 1	; Clock
	sjmp	timerTXClockRelease	; 2

; -----------------
timerTXParityBit:
; -- set parity bit from ATTXParF and pull down clock line
	nop
	mov	c,ATTXParF		; 1	; parity bit
	mov	p3.5,c			; 2
	call	ATTX_delay_clk
	clr	p3.3			; 1	; Clock
	sjmp	timerTXClockRelease	; 2

; -----------------
timerTXStopBit:
; -- set stop bit (1) and pull down clock line
	nop
	nop
	nop
	setb	p3.5			; 1	; Data Stopbit
	call	ATTX_delay_clk
	clr	p3.3			; 1	; Clock
	sjmp	timerTXClockRelease	; 2

; -----------------
timerTXClockRelease:
; -- release clock line
	call	ATTX_delay_release
	mov	a,ATBitCount		; 1
	cjne	a,#10,timerTXCheckBusy	; 2
	setb	p3.3			; 1
	setb	p1.2			; diag: data send
	; end of TX sequence, not time critical
	sjmp	timerTXStop

timerTXCheckBusy:
; -- check if clock is released, but not after the stop bit.
; -- Host may pull down clock to abort communication at any time.
	setb	p3.3			; 1
	jb	p3.3,timerTXEnd

timerTXClockBusy:
; -- clock is busy, abort communication
	setb	ATCommAbort		; AT communication aborted flag
	clr	p1.2			; diag: data not send
;	sjmp	timerTXStop

; -----------------
timerTXStop:
; -- stop timer auto-reload
	clr	ATTFModF
	clr	tr0
	setb	p3.5			; just for safety, clean up data line state
;	sjmp	timerTXEnd

; --------------------------- done
timerTXEnd:				; total 7
; -- done
	inc	ATBitCount		; 1
	pop	psw			; 2
	pop	acc			; 2
	reti				; 2

; --------------------------- host-to-device communication
timerHostToDev:
; -- switch on bit-number
; -----------------
	mov	dptr,#timerHostToDevJT		; 2,10
	mov	a,ATBitCount			; 1,11
	rl	a				; 1,12
	jmp	@a+dptr				; 2,14
timerHostToDevJT:
	sjmp	timerRXStartBit		; 2,16
	sjmp	timerRXDataBit
	sjmp	timerRXDataBit
	sjmp	timerRXDataBit
	sjmp	timerRXDataBit
	sjmp	timerRXDataBit
	sjmp	timerRXDataBit
	sjmp	timerRXDataBit
	sjmp	timerRXDataBit
	sjmp	timerRXParityBit
	sjmp	timerRXACKBit
	sjmp	timerRXCleanup
	sjmp	timerRXClockBusy	; safety

; -----------------
timerRXStartBit:
; -- check start bit, must be zero
	jb	p3.5,timerRXClockBusy

	; pull down clock line
	clr	p3.3			; 1	; Clock
	sjmp	timerRXClockRelease

; -----------------
timerRXDataBit:
; -- read bit 1-8 pull down clock line
; -- new data bit
	mov	a,ATRXBuf
	mov	c,p3.5
	rrc	a
	mov	ATRXBuf,a

; -- pull down clock line
	clr	p3.3			; 1	; Clock
	sjmp	timerRXClockRelease

; -----------------
timerRXParityBit:
; -- read and check parity bit 9 and pull down clock line
; -- check parity
	mov	a,ATRXBuf
	jb	p,timerRXParityBitPar
	jnb	p3.5,timerRXClockBusy		; parity error
; -- pull down clock line
	clr	p3.3			; 1	; Clock
	sjmp	timerRXClockRelease

timerRXParityBitPar:
	jb	p3.5,timerRXClockBusy		; parity error
; -- pull down clock line
	clr	p3.3			; 1	; Clock
	sjmp	timerRXClockRelease

; -----------------
timerRXAckBit:
; -- check bit 10, stop-bit, must be 1.
; -- write ACK-bit and pull down clock line
	jnb	p3.5,timerRXClockBusy

	; ACK-Bit
	clr	p3.5			; 1
	call	ATTX_delay_clk
	clr	p3.3			; 1	; Clock
	sjmp	timerRXClockRelease	; 2

; -----------------
timerRXCleanup:
; -- end of RX clock sequence after 12 clock pulses
	clr	ATTFModF

; -- release the data line
	setb	p3.5

; -- datagram received, stop timer auto-reload
	setb	ATCmdReceivedF			; full message received
	clr	tr0
	sjmp	timerRXEnd

; -----------------
timerRXClockRelease:
; -- release clock line
	call	ATTX_delay_release
	mov	a,ATBitCount		; 1
	cjne	a,#10,timerRXCheckBusy
	setb	p3.3			; 1
	setb	p1.1			; diag: host-do-dev ok
	sjmp	timerRXEnd

timerRXCheckBusy:
; -- check if clock is released, but not after the last bit.
; -- Host may pull down clock to abort communication at any time.
	setb	p3.3			; 1
	jb	p3.3,timerRXEnd

timerRXClockBusy:
; -- clock is busy, abort communication
	setb	ATCommAbort		; AT communication aborted flag
	clr	p1.1			; diag: host-do-dev abort

	clr	ATTFModF
	clr	tr0
	setb	p3.5			; just for safety, clean up data line state
;	sjmp	timerRXEnd

; -----------------
timerRXEnd:				; total 7
; -- done
	inc	ATBitCount		; 1
	pop	psw			; 2
	pop	acc			; 2
	reti				; 2

;----------------------------------------------------------
; Sun to AT translaton table
;----------------------------------------------------------

Sun2ATxlt0	DB	  0h, 028h, 021h,  00h, 032h,  05h,  06h,  09h,   04h, 078h,  0ch,  07h,  03h, 011h,  0bh,  00h
Sun2ATxlt1	DB	083h,  0ah,  01h, 011h, 075h, 077h, 07fh, 07eh,  06bh,  00h,  00h, 072h, 074h, 076h, 016h, 01eh
Sun2ATxlt2	DB	026h, 025h, 02eh, 036h, 03dh, 03eh, 046h, 045h,  04eh, 055h,  0eh, 066h, 070h, 023h, 04ah, 07ch
Sun2ATxlt3	DB	037h,  00h, 071h,  00h, 06ch,  0dh, 015h, 01dh,  024h, 02dh, 02ch, 035h, 03ch, 043h, 044h, 04dh
Sun2ATxlt4	DB	054h, 05bh, 071h,  00h, 06ch, 075h, 07dh, 07bh,   00h,  00h, 069h,  00h, 014h, 01ch, 01bh, 023h
Sun2ATxlt5	DB	02bh, 034h, 033h, 03bh, 042h, 04bh, 04ch, 052h,  05dh, 05ah, 05ah, 06bh, 073h, 074h, 070h,  00h
Sun2ATxlt6	DB	07dh,  00h, 077h, 012h, 01ah, 022h, 021h, 02ah,  032h, 031h, 03ah, 041h, 049h, 04ah, 059h,  00h
Sun2ATxlt7	DB	069h, 072h, 07ah,  00h,  00h,  00h,  00h, 058h,  02fh, 029h, 027h, 07ah, 061h, 079h,  00h,  00h

;----------------------------------------------------------
; Sun to AT translaton table
; Bit-Table for two-byte-AT-Scancodes
; Note: even in the small 89c2051 there is enough program memory space for
;	this space-consuming lookup table. Does not look nice,
;	but it is easy to read and will execute fast.
;----------------------------------------------------------
Sun2ATxlte0	DB	 00h,  01h,  01h,  00h,  01h,  00h,  00h,  00h,   00h,  00h,  00h,  00h,  00h,  01h,  00h,  00h
Sun2ATxlte1	DB	 00h,  00h,  00h,  00h,  01h,  01h,  00h,  00h,   01h,  00h,  00h,  01h,  01h,  00h,  00h,  00h
Sun2ATxlte2	DB	 00h,  00h,  00h,  00h,  00h,  00h,  00h,  00h,   00h,  00h,  00h,  00h,  01h,  01h,  01h,  00h
Sun2ATxlte3	DB	 01h,  00h,  00h,  00h,  01h,  00h,  00h,  00h,   00h,  00h,  00h,  00h,  00h,  00h,  00h,  00h
Sun2ATxlte4	DB	 00h,  00h,  01h,  00h,  00h,  00h,  00h,  00h,   00h,  00h,  01h,  00h,  00h,  00h,  00h,  00h
Sun2ATxlte5	DB	 00h,  00h,  00h,  00h,  00h,  00h,  00h,  00h,   00h,  00h,  01h,  00h,  00h,  00h,  00h,  00h
Sun2ATxlte6	DB	 01h,  00h,  00h,  00h,  00h,  00h,  00h,  00h,   00h,  00h,  00h,  00h,  00h,  00h,  00h,  00h
Sun2ATxlte7	DB	 00h,  00h,  00h,  00h,  00h,  00h,  00h,  00h,   01h,  00h,  01h,  01h,  00h,  00h,  00h,  00h

;----------------------------------------------------------
; ring buffer insertion helper. Input Data comes in r2
;----------------------------------------------------------
RingBufCheckInsert:
	; check for ring buffer overflow
	mov	a,RingBufPtrOut
	setb	c
	subb	a,RingBufPtrIn
	anl	a,#RingBufSizeMask
	jz	RingBufFull

	; some space left, insert data
	mov	a,RingBufPtrIn
	add	a,#RingBuf
	mov	r0,a
	mov	a,r2
	mov	@r0,a

	; increment pointer
	inc	RingBufPtrIn
	anl	RingBufPtrIn,#RingBufSizeMask
	ret

RingBufFull:
	; error routine
	clr	p1.0
	ret

;----------------------------------------------------------
; Get received data and translate it into the ring buffer
;----------------------------------------------------------
TranslateToBufSun:
	; translate from Sun to AT scancode
	mov	a,RawBuf

	; save make/break bit 7
	mov	c,acc.7
	mov	ATTXBreakF,c

	; ignore make/break bit 7
	anl	a,#7fh

	; check 2-byte scancodes
	mov	r4,a
	mov	dptr,#Sun2ATxlte0
	movc	a,@a+dptr
	mov	c,acc.0
	mov	ATTXMasqF,c
	mov	a,r4

	; get AT scancode
	mov	dptr,#Sun2ATxlt0
	movc	a,@a+dptr

	; save AT scancode
	mov	OutputBuf,a

	; clear received data flag
	clr	MiscRXCompleteF

	; keyboard disabled?
	jb	ATKbdDisableF,TranslateToBufSunEnd

	; check for 0xE0 escape code
	jnb	ATTXMasqF,TranslateToBufSunNoEsc
	mov	r2,#0E0h
	call	RingBufCheckInsert

TranslateToBufSunNoEsc:
	; check for 0xF0 release / break code
	jnb	ATTXBreakF,TranslateToBufSunNoRelease
	mov	r2,#0F0h
	call	RingBufCheckInsert

TranslateToBufSunNoRelease:
	; normal data byte
	mov	r2, OutputBuf
	call	RingBufCheckInsert

TranslateToBufSunEnd:
	ret

;----------------------------------------------------------
; Send data from the ring buffer
;----------------------------------------------------------
	; -- send ring buffer contents
BufTX:
	; check if data is present in the ring buffer
	clr	c
	mov	a,RingBufPtrIn
	subb	a,RingBufPtrOut
	anl	a,#RingBufSizeMask
	jz	BufTXEnd

	; inter-character delay 0.13ms
	call	timer0_130u_init
BufTXWaitDelay:
	jb	MiscSleepT0F,BufTXWaitDelay

	; -- get data from buffer
	mov	a,RingBufPtrOut
	add	a,#RingBuf
	mov	r0,a
	mov	a,@r0

	; -- send data
	mov	TXBuf,a		; 8 data bits
	mov	c,p
	cpl	c
	mov	ATTXParF,c	; odd parity bit
	clr	ATHostToDevF	; timer in TX mode
	setb	ATTXActiveF	; diag: TX is active
;	clr	ex0		; may diable input interrupt here, better is, better dont.
;	clr	ex1
	call	timer0_init

	; -- wait for completion
BufTXWaitSent:
	jb	ATTFModF,BufTXWaitSent
;	setb	ex1		; enable external interupt 1
;	setb	ex0		; enable external interupt 0
	clr	ATTXActiveF		; diag
	jb	ATCommAbort,BufTXEnd	; check on communication abort

;	; diag: send also on serial line
;	mov	a,@r0
;	mov	sbuf,a
;	clr	ti
;BufTXWaitDiagSend:
;	jnb	ti,BufTXWaitDiagSend

	; -- store last transmitted word for resend-feature
	mov	a,@r0
	mov	ATRXResendBuf,a

	; -- increment output pointer
	inc	RingBufPtrOut
	anl	RingBufPtrOut,#RingBufSizeMask

BufTXEnd:
	ret

;----------------------------------------------------------
; check and respond to received AT commands
; used bits: internal: ATCmdLedF, ATCmdScancodeF external ATCmdResetF
;----------------------------------------------------------
ATCmdProc:
	; -- check for new data
	jb	ATCmdReceivedF,ATCPGo
	ljmp	ATCPDone

ATCPGo:
;	; -- diag: send received AT command via serial line
;	mov	sbuf,ATRXBuf
;	clr	ti
;ATCPWait:
;	jnb	ti,ATCPWait

	; -- get received AT command
	mov	a,ATRXBuf
	clr	ATCmdReceivedF

	; -- argument for 0xed command: set keyboard LED
	jnb	ATCmdLedF,ATCPNotLEDarg
	clr	ATCmdLedF
	mov	SunLEDBuf,#0

	; -- process Sun-Keyboard LED data
	; CapsLock: Sun-LED-Bit 3
	mov	c,acc.2
	mov	SunLEDBuf.3,c
	; NumLock: Sun-LED-Bit 0
	mov	c,acc.1
	mov	SunLEDBuf.0,c
	; ScrollLock: Sun-LED-Bit 2
	mov	c,acc.0
	mov	SunLEDBuf.2,c
	; will send data later. not every PS2-Device will tolerate 2ms serial delay before the ACK.
	setb	SunCtrlLedF
	setb	SunSetLedF

	; -- set build-in LEDs
	; NumLock
	mov	c,acc.1
	cpl	c
	mov	p1.5,c
	; CapsLock
	mov	c,acc.2
	cpl	c
	mov	p1.6,c
	; ScrollLock
	mov	c,acc.0
	cpl	c
	mov	p1.7,c

	ljmp	ATCPSendAck

ATCPNotLEDarg:
	; -- argument for 0xf0 command: set scancode.
	jnb	ATCmdScancodeF,ATCPNotF0Arg
	clr	ATCmdScancodeF
	jnz	ATCPSendAck
	; -- Argument 0x0: send ACK and scancode
	mov	r2,#0FAh
	call	RingBufCheckInsert
	; send 0x02, the default scancode
	mov	r2,#02h
	call	RingBufCheckInsert
	sjmp	ATCPDone
ATCPNotF0Arg:
	; -- command 0xed: set keyboard LED command. set bit for next argument processing and send ACK
	cjne	a,#0edh,ATCPNotED
	setb	ATCmdLedF
	sjmp	ATCPSendAck
ATCPNotED:
	; -- command 0xee: echo command. send 0xee
	cjne	a,#0EEh,ATCPNotEE
	mov	r2,#0EEh
	call	RingBufCheckInsert
	sjmp	ATCPDone
ATCPNotEE:
	; -- command 0xf0: scan code set. set bit for next argument processing and send ACK
	cjne	a,#0f0h,ATCPNotF0
	setb	ATCmdScancodeF
	sjmp	ATCPSendAck
ATCPNotF0:
	cjne	a,#0f1h,ATCPNotF1
	sjmp	ATCPSendAck
ATCPNotF1:
	; -- command 0xf2: keyboard model detection. send ACK,xab,x83
	cjne	a,#0f2h,ATCPNotF2
	mov	r2,#0FAh
	call	RingBufCheckInsert
	mov	r2,#0ABh
	call	RingBufCheckInsert
	mov	r2,#083h
	call	RingBufCheckInsert
	sjmp	ATCPDone
ATCPNotF2:
	; -- command 0xf3: typematic repeat rate. send ACK and ignore
	cjne	a,#0f3h,ATCPNotF3
	sjmp	ATCPSendAck
ATCPNotF3:
	; -- command 0xf4: keyboard enable. clear TX buffer, send ACK
	cjne	a,#0f4h,ATCPNotF4
	mov	RingBufPtrIn,#0
	mov	RingBufPtrOut,#0
	clr	ATKbdDisableF
	sjmp	ATCPSendAck
ATCPNotF4:
	; -- command 0xf5: keyboard disable. send ACK and set ATKbdDisableF
	cjne	a,#0f5h,ATCPNotF5
	setb	ATKbdDisableF
	sjmp	ATCPSendAck
ATCPNotF5:
	; -- command 0xf6: keyboard enable. clear TX buffer, send ACK
	cjne	a,#0f6h,ATCPNotF6
	mov	RingBufPtrIn,#0
	mov	RingBufPtrOut,#0
	clr	ATKbdDisableF
	sjmp	ATCPSendAck
ATCPNotF6:
	; -- command 0xfe: resend last word
	cjne	a,#0feh,ATCPNotFE
	mov	r2,ATRXResendBuf
	call	RingBufCheckInsert
	sjmp	ATCPDone
ATCPNotFE:
	; -- command 0xff: keyboard reset
	cjne	a,#0ffh,ATCPNotFF
	mov	RingBufPtrIn,#0
	mov	RingBufPtrOut,#0
	setb	ATCmdResetF
	clr	ATKbdDisableF
	sjmp	ATCPSendAck
ATCPNotFF:
	sjmp	ATCPSendAck

ATCPSendAck:
	mov	r2,#0FAh
	call	RingBufCheckInsert
;	sjmp	ATCPDone

ATCPDone:
	ret

;----------------------------------------------------------
; check if there is AT data to send
;----------------------------------------------------------
ATTX:
; -- Device-to-Host communication
	; -- check if there is data to send, send data
	call	BufTX

	; -- keyboard reset/cold start: send AAh after some delay
	jnb	ATCmdResetF,ATTXWaitDelayEnd
	clr	ATCmdResetF
	; -- optional delay after faked cold start
	; yes, some machines will not boot without this, e.g. IBM PS/ValuePoint 433DX/D
	call	timer0_20ms_init
ATTXResetDelay:
	jb	MiscSleepT0F,ATTXResetDelay
	; -- send "self test passed"
	mov	r2,#0AAh
	call	RingBufCheckInsert
ATTXWaitDelayEnd:
	ret

;----------------------------------------------------------
; helper: delay clock line status change for 10 microseconds
; FIXME: this is X-tal frequency dependant
;----------------------------------------------------------
ATTX_delay_clk:
	nop
	nop
	nop
	nop

	ret

;----------------------------------------------------------
; helper: delay clock release
; FIXME: this is X-tal frequency dependant
;----------------------------------------------------------
ATTX_delay_release:
	nop
	nop
	nop
	nop

	nop
	nop
	nop
	nop
	nop

	nop
	nop
	nop
	nop
	nop

	nop
	nop
	nop
	nop
	nop

	nop
	nop
	nop
	nop
	nop

	ret

;----------------------------------------------------------
; init uart with timer 2 as baudrate generator
; note: this timer is not present on the AT89C2051
;----------------------------------------------------------
;uart_timer2_init:
;	mov	scon, #050h	; uart mode 1 (8 bit), single processor
;
;	orl	t2con, #34h	; Timer 2: internal baudrate generate mode RX/TX
;	mov	rcap2h, #uart_t2h_9600_18432k
;	mov	rcap2l, #uart_t2l_9600_18432k
;	clr	es		; disable serial interrupt
;
;	ret

;----------------------------------------------------------
; init uart with timer 1 as baudrate generator
; need 1200BPS
;----------------------------------------------------------
uart_timer1_init:
	mov	scon, #050h	; uart mode 1 (8 bit), single processor
	orl	tmod, #020h	; M0,M1, bit4,5 in TMOD, timer 1 in mode 2, 8bit-auto-reload
	orl	pcon, #080h	; SMOD, bit 7 in PCON
	mov	th1, #uart_t1_1200_11059_2k
	mov	tl1, #uart_t1_1200_11059_2k
	clr	es		; disable serial interrupt
	setb	tr1

	clr	ri
	setb	ti

	ret

;----------------------------------------------------------
; init timer 0 for interval timing (fast 8 bit reload)
; need 75-85mus intervals
;----------------------------------------------------------
timer0_init:
	clr	tr0
	anl	tmod, #0f0h	; clear all lower bits
	orl	tmod, #02h;	; 8-bit Auto-Reload Timer, mode 2
	mov	th0, #interval_t0_85u_11059_2k
	mov	tl0, #interval_t0_85u_11059_2k
	setb	et0		; (IE.1) enable timer 0 interrupt
	setb	ATTFModF	; see timer 0 interrupt code
	clr	ATCommAbort	; communication abort flag
	mov	ATBitCount,#0
	setb	tr0		; go
	ret

;----------------------------------------------------------
; init timer 0 in 16 bit mode for inter-char delay of 0.13ms
;----------------------------------------------------------
timer0_130u_init:
	clr	tr0
	anl	tmod, #0f0h	; clear all lower bits
	orl	tmod, #01h;	; M0,M1, bit0,1 in TMOD, timer 0 in mode 1, 16bit
	mov	th0, #interval_th_130u_11059_2k
	mov	tl0, #interval_tl_130u_11059_2k
	setb	et0		; (IE.1) enable timer 0 interrupt
	clr	ATTFModF	; see timer 0 interrupt code
	setb	MiscSleepT0F
	setb	tr0		; go
	ret

;----------------------------------------------------------
; init timer 0 in 16 bit mode for faked POST delay of of 20ms
;----------------------------------------------------------
timer0_20ms_init:
	clr	tr0
	anl	tmod, #0f0h	; clear all upper bits
	orl	tmod, #01h;	; M0,M1, bit0,1 in TMOD, timer 0 in mode 1, 16bit
	mov	th0, #interval_th_20m_11059_2k
	mov	tl0, #interval_tl_20m_11059_2k
	setb	et0		; (IE.1) enable timer 0 interrupt
	clr	ATTFModF	; see timer 0 interrupt code
	setb	MiscSleepT0F
	setb	tr0		; go
	ret

;----------------------------------------------------------
; Id
;----------------------------------------------------------
RCSId	DB	"$KbdBabel: kbdbabel_sun_ps2_8051.asm,v 1.10 2007/11/10 21:30:02 akurz Exp $"

;----------------------------------------------------------
; main
;----------------------------------------------------------
Start:
	; -- init the stack
	mov	sp,#StackBottom
	; -- init UART and timer0/1
;	acall	uart_timer2_init
	acall	uart_timer1_init

	; -- enable interrupts int0
	setb	ea

	; -- clear all flags
	mov	B20,#0
	mov	B21,#0
	mov	B22,#0

	; -- init the ring buffer
	mov	RingBufPtrIn,#0
	mov	RingBufPtrOut,#0

	; -- cold start flag
	setb	ATCmdResetF

; ----------------
Loop:
	; -- check input receive status
	jb	RI,LoopProcessSunData

	; -- check on new AT data received
	jb	ATCmdReceivedF,LoopProcessATcmd

	; -- check if AT communication active.
	jb	ATTFModF,Loop

	; -- check AT line status, clock line must not be busy
	jnb	p3.3,Loop

	; -- check for AT RX data
	jnb	p3.5,LoopATRX

	; -- send data, if data is present
	call	ATTX

	; -- check if commands may be sent to Sun Keyboard
	jb	SunSetLedF,LoopSunLED

	sjmp	loop

;----------------------------------------------------------
; helpers for the main loop
;----------------------------------------------------------
; ----------------
LoopProcessSunData:
; -- input data received, process the received scancode into output ring buffer
	mov	a,sbuf
	mov	RawBuf,a
	clr	RI
	cjne	a,#07fh,LoopProcessSunDataNot7f	; ignore sun 7f scancodes
	sjmp	Loop

LoopProcessSunDataNot7f:
	jb	ATCmdResetF, Loop
	setb	MiscRXCompleteF
	call	TranslateToBufSun
	sjmp	Loop

; -----------------
LoopProcessATcmd:
; -- AT command processing
	call	ATCmdProc
	sjmp	loop

; ----------------
LoopATRX:
; -- Host-do-Device communication
	; -- diag: host-do-dev ok
	setb	p1.1

	; -- receive data on the AT line
	mov	ATRXCount,#0
	mov	ATRXBuf,#0
;	clr     ATHostToDevIntF
	setb	ATHostToDevF
	call	timer0_init

	; wait for completion
LoopTXWaitSent:
	jb	ATTFModF,LoopTXWaitSent
LoopCheckATEnd:
	ljmp	Loop

; ----------------
LoopSunLED:
; -- set sun keyboard LEDs
	; sending two bytes of LED control code takes about 2ms due to 2 bytes @ 1200bps.
	; some PS2-to-USB-adaptors do not tolerate this delay in AT communication.

	; -- return if flag not set
	jnb	SunSetLedF,LoopSunLEDEnd

	; -- return if serial transmission is active
	jnb	ti,LoopSunLEDEnd

	; -- check control-code-or-argument-bit
	jnb	SunCtrlLedF,LoopSunLEDSendArg

	; -- send control code
	clr	p1.4
	clr	ti
	mov	sbuf,#0eh
	clr	SunCtrlLedF
	sjmp	LoopSunLEDEnd

LoopSunLEDSendArg:
	; -- send argument
	clr	p1.4
	clr	ti
	mov	sbuf,SunLEDBuf
	clr	SunSetLedF

LoopSunLEDEnd:
	setb	p1.4
	ljmp	Loop

;----------------------------------------------------------
; Still space on the ROM left for the license?
;----------------------------------------------------------
LIC01	DB	"   Copyright 2006, 2007 by Alexander Kurz"
LIC02	DB	"   "
GPL01	DB	"   This program is free software; you can redistribute it and/or modify"
GPL02	DB	"   it under the terms of the GNU General Public License as published by"
GPL03	DB	"   the Free Software Foundation; either version 3, or (at your option)"
GPL04	DB	"   any later version."
GPL05	DB	"   "
GPL06	DB	"   This program is distributed in the hope that it will be useful,"
GPL07	DB	"   but WITHOUT ANY WARRANTY; without even the implied warranty of"
GPL08	DB	"   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the"
GPL09	DB	"   GNU General Public License for more details."
GPL10	DB	"   "
; ----------------
	end
