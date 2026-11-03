; ПРИМЕЧАНИЕ: 13+13 мс - кандидат минимума по СРЕДНЕЙ загрузке UART.
; Точное начало двух передач в один момент физически невозможно.
; Файл демонстрирует очередь событий, но не доказывает 4-тактовую точность UART.

; ATmega8, AVR Assembler (AVRA 1.4.2)
; SimulIDE: 16 МГц, монитор UART1, USART 9600 8N1
; 
; СРЕДНЯЯ СЛОЖНОСТЬ: тест передачи на границе возможностей USART.
; Каждый таймер вызывает прерывание раз в 1 мс (режим CTC).
; Интервалы задаются в миллисекундах.
; Прерывания отмечают события, а главный цикл отправляет строки.
; Проверка загрузки USART. Строгие 4 такта для начала передачи не гарантируются.

.device ATmega8

.equ TIMER1_INTERVAL = 13       ; период ping, миллисекунды (1..65535)
.equ TIMER2_INTERVAL = 13       ; период pong, миллисекунды (1..65535)

; Адреса регистров ввода-вывода ATmega8
.equ SPL    = 0x3D
.equ SPH    = 0x3E
.equ SREG   = 0x3F
.equ UBRRL  = 0x09
.equ UBRRH  = 0x20
.equ UCSRA  = 0x0B
.equ UCSRB  = 0x0A
.equ UCSRC  = 0x20
.equ UDR    = 0x0C
.equ OCR2   = 0x23
.equ TCNT2  = 0x24
.equ TCCR2  = 0x25
.equ OCR1AL = 0x2A
.equ OCR1AH = 0x2B
.equ TCNT1L = 0x2C
.equ TCNT1H = 0x2D
.equ TCCR1B = 0x2E
.equ TCCR1A = 0x2F
.equ TIFR   = 0x38
.equ TIMSK  = 0x39
.equ RAMEND = 0x045F

.dseg
.org 0x0060
left1_l:   .byte 1
left1_h:   .byte 1
left2_l:   .byte 1
left2_h:   .byte 1
pending1:  .byte 1
pending2:  .byte 1

.cseg
.org 0x0000
    rjmp reset
.org 0x0003             ; вектор прерывания Timer2 по совпадению
    rjmp timer2_comp
.org 0x0006             ; вектор прерывания Timer1 по совпадению
    rjmp timer1_comp
.org 0x0013             ; программа начинается после таблицы прерываний

reset:
    ; Настраиваем стек
    ldi r16, high(RAMEND)
    out SPH, r16
    ldi r16, low(RAMEND)
    out SPL, r16

    ; Заполняем счетчики, которые будут уменьшаться каждые 1 мс.
    ldi r16, low(TIMER1_INTERVAL)
    sts left1_l, r16
    ldi r16, high(TIMER1_INTERVAL)
    sts left1_h, r16
    ldi r16, low(TIMER2_INTERVAL)
    sts left2_l, r16
    ldi r16, high(TIMER2_INTERVAL)
    sts left2_h, r16
    clr r16
    sts pending1, r16
    sts pending2, r16

    ; USART: 9600 бод, 8 бит данных, 1 стоп-бит
    out UBRRH, r16              ; старший байт делителя скорости равен 0
    ldi r16, 103
    out UBRRL, r16
    ldi r16, 0x08              ; разрешаем передатчик USART
    out UCSRB, r16
    ldi r16, 0x86              ; выбираем регистр UCSRC и формат 8 бит
    out UCSRC, r16

    ; Timer1: совпадение каждые 1 мс
    clr r16
    out TCCR1A, r16
    out TCCR1B, r16
    out TCNT1H, r16
    out TCNT1L, r16
    out OCR1AH, r16
    ldi r16, 249
    out OCR1AL, r16

    ; Timer2: тоже совпадение каждые 1 мс
    clr r16
    out TCCR2, r16
    out TCNT2, r16
    ldi r16, 249
    out OCR2, r16

    ; Сбрасываем флаги сравнения и разрешаем прерывания.
    ldi r16, 0x90              ; флаги совпадения обоих таймеров
    out TIFR, r16
    out TIMSK, r16             ; разрешения прерываний обоих таймеров

    ; Запускаем оба таймера и разрешаем прерывания.
    ldi r16, 0x0B              ; Timer1 в режиме CTC, делитель 64
    out TCCR1B, r16
    ldi r16, 0x0C              ; Timer2 в режиме CTC, делитель 64
    out TCCR2, r16
    sei

main_loop:
    ; Проверяем, есть ли событие. Запрет прерываний очень короткий.
    cli
    lds r16, pending1
    tst r16
    breq check_timer2
    dec r16
    sts pending1, r16
    sei
    ldi r31, high(TIMER1_STR * 2)
    ldi r30, low(TIMER1_STR * 2)
    rcall send_flash_string
    rjmp main_loop

check_timer2:
    lds r16, pending2
    tst r16
    breq no_events
    dec r16
    sts pending2, r16
    sei
    ldi r31, high(TIMER2_STR * 2)
    ldi r30, low(TIMER2_STR * 2)
    rcall send_flash_string
    rjmp main_loop

no_events:
    sei
    rjmp main_loop

; Передаем строку из FLASH. Z указывает на очередной символ.
send_flash_string:
send_next:
    lpm r16, Z+
    tst r16
    breq send_done
wait_udre:
    sbis UCSRA, 5              ; ждем, пока регистр передачи USART освободится
    rjmp wait_udre
    out UDR, r16
    rjmp send_next
send_done:
    ret

; Прерывание Timer1 вызывается каждую миллисекунду.
timer1_comp:
    push r16
    in r16, SREG
    push r16
    push r17
    push r18

    lds r16, left1_l
    lds r17, left1_h
    subi r16, 1
    sbci r17, 0
    sts left1_l, r16
    sts left1_h, r17
    mov r18, r16
    or r18, r17
    brne timer1_exit

    ; Если период закончился, снова запускаем отсчет и добавляем ping.
    ldi r16, low(TIMER1_INTERVAL)
    ldi r17, high(TIMER1_INTERVAL)
    sts left1_l, r16
    sts left1_h, r17
    lds r18, pending1
    cpi r18, 255               ; не даем счетчику переполниться через 255
    breq timer1_exit
    inc r18
    sts pending1, r18

timer1_exit:
    pop r18
    pop r17
    pop r16
    out SREG, r16
    pop r16
    reti

; Прерывание Timer2 вызывается каждую миллисекунду.
timer2_comp:
    push r16
    in r16, SREG
    push r16
    push r17
    push r18

    lds r16, left2_l
    lds r17, left2_h
    subi r16, 1
    sbci r17, 0
    sts left2_l, r16
    sts left2_h, r17
    mov r18, r16
    or r18, r17
    brne timer2_exit

    ; Период закончился: снова запускаем отсчет и добавляем pong.
    ldi r16, low(TIMER2_INTERVAL)
    ldi r17, high(TIMER2_INTERVAL)
    sts left2_l, r16
    sts left2_h, r17
    lds r18, pending2
    cpi r18, 255
    breq timer2_exit
    inc r18
    sts pending2, r18

timer2_exit:
    pop r18
    pop r17
    pop r16
    out SREG, r16
    pop r16
    reti

; Строки хранятся в памяти программы (FLASH).
TIMER1_STR:
    .db "ping", 13, 10, 0, 0
TIMER2_STR:
    .db "pong", 13, 10, 0, 0
