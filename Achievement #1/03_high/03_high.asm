; ======================================================================
; ВЫСОКАЯ СЛОЖНОСТЬ. ATmega8, AVR Assembler, AVRA 1.4.2, 16 МГц
; ======================================================================
; Два таймера, передача строк и команды через USART (9600, 8N1).
;
; Команды (в конце нажать Enter):
;   T1=100       установить интервал ping = 100 мс
;   T2=160       установить интервал pong = 160 мс
;   S1=hello     заменить текст ping на hello
;   S2=world     заменить текст pong на world
;   RESET        начать отсчет интервалов заново
;
; Ответ: OK или ERR, затем перевод строки.
; Строки: от 0 до 8 печатных символов ASCII + \r\n.
; Интервалы: от 1 до 255 миллисекунд, но действует проверка нагрузки.
;
; ПРОВЕРКА: новый интервал должен быть >= 2*длина_текста + 5 мс.
; Объяснение: один байт USART при 9600 бод занимает примерно 1.04 мс.
; С \r\n сообщение содержит (длина+2) байта. Формула дает каждому
; потоку меньше половины пропускной способности USART.
; Это понятное, специально осторожное правило. Не точный общий минимум
; для произвольных разных интервалов. При ping/pong по 4 символа
; получается минимальное по правилу значение: 13 + 13 = 26 мс.
;
; Таймеры во время проверки команд НЕ выключаются. Они продолжают
; выдавать прерывания. Главная программа только обрабатывает команды
; и отправляет готовые сообщения.
;
; ВАЖНО: точность фактического старта USART до 4 тактов НЕ гарантируется:
; один UART не способен отправить две строки одновременно.
; ======================================================================

.device ATmega8

; Константы - начальные значения. Команды меняют их КОПИИ в ОЗУ.
.equ TIMER1_INTERVAL = 100
.equ TIMER2_INTERVAL = 160

; Адреса регистров ATmega8 (простые числовые определения без include).
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

; В ОЗУ лежат данные, которые могут меняться во время работы.
.dseg
.org 0x0060
period1:    .byte 1   ; текущий период первого таймера (мс)
period2:    .byte 1   ; текущий период второго таймера (мс)
left1:      .byte 1   ; сколько миллисекунд осталось до ping
left2:      .byte 1   ; сколько миллисекунд осталось до pong
pending1:   .byte 1   ; сколько ping ожидают отправки
pending2:   .byte 1   ; сколько pong ожидают отправки
len1:       .byte 1   ; длина первого текста
len2:       .byte 1   ; длина второго текста
text1:      .byte 8   ; первый текст, максимум 8 символов
text2:      .byte 8   ; второй текст, максимум 8 символов
rx_line:    .byte 16  ; полученная команда (15 символов + нулевой байт)
rx_len:     .byte 1   ; количество символов команды
rx_ready:   .byte 1   ; команда получена целиком
rx_error:   .byte 1   ; команда слишком длинная

.cseg
; Таблица векторов прерываний ATmega8.
.org 0x0000
    rjmp reset
.org 0x0003
    rjmp timer2_irq         ; совпадение Timer2
.org 0x0006
    rjmp timer1_irq         ; совпадение Timer1
.org 0x000B
    rjmp uart_rx_irq        ; пришел символ через USART
.org 0x0013

; ======================================================================
; 1. НАСТРОЙКА МИКРОКОНТРОЛЛЕРА
; ======================================================================
reset:
    ; Настроить стек, иначе вызовы подпрограмм не работают.
    ldi r16, high(RAMEND)
    out SPH, r16
    ldi r16, low(RAMEND)
    out SPL, r16

    ; Сначала задаем периоды.
    ldi r16, TIMER1_INTERVAL
    sts period1, r16
    sts left1, r16
    ldi r16, TIMER2_INTERVAL
    sts period2, r16
    sts left2, r16

    ; Пока отправлять нечего и команд нет.
    clr r16
    sts pending1, r16
    sts pending2, r16
    sts rx_len, r16
    sts rx_ready, r16
    sts rx_error, r16

    ; Скопируем начальные строки из памяти программы в ОЗУ.
    ldi r30, low(TIMER1_STR*2)
    ldi r31, high(TIMER1_STR*2)
    ldi r26, low(text1)
    ldi r27, high(text1)
    ldi r18, 4
copy_start1:
    lpm r16, Z+
    st X+, r16
    dec r18
    brne copy_start1

    ldi r30, low(TIMER2_STR*2)
    ldi r31, high(TIMER2_STR*2)
    ldi r26, low(text2)
    ldi r27, high(text2)
    ldi r18, 4
copy_start2:
    lpm r16, Z+
    st X+, r16
    dec r18
    brne copy_start2

    ldi r16, 4
    sts len1, r16
    sts len2, r16

    ; USART: 16 МГц / (16*(103+1)) = 9615 бод (близко к 9600).
    clr r16
    out UBRRH, r16
    ldi r16, 103
    out UBRRL, r16
    ldi r16, 0x98           ; RXCIE=1, RXEN=1, TXEN=1
    out UCSRB, r16
    ldi r16, 0x86           ; URSEL=1 и 8 бит данных, 1 стоп-бит
    out UCSRC, r16

    ; Timer1: прерывание каждые 1 мс.
    ; 16 000 000 / 64 / (249+1) = 1000 прерываний в секунду.
    clr r16
    out TCCR1A, r16
    out TCCR1B, r16
    out TCNT1H, r16
    out TCNT1L, r16
    out OCR1AH, r16
    ldi r16, 249
    out OCR1AL, r16

    ; Timer2: независимо выдает второе прерывание каждые 1 мс.
    clr r16
    out TCCR2, r16
    out TCNT2, r16
    ldi r16, 249
    out OCR2, r16

    ; Разрешить оба таймерных прерывания и запустить таймеры.
    ldi r16, 0x90
    out TIFR, r16
    out TIMSK, r16
    ldi r16, 0x0B
    out TCCR1B, r16        ; Timer1, CTC, делитель 64
    ldi r16, 0x0C
    out TCCR2, r16         ; Timer2, CTC, делитель 64
    sei                    ; теперь можно обрабатывать прерывания

; ======================================================================
; 2. ГЛАВНЫЙ ЦИКЛ
; ======================================================================
main_loop:
    ; Сперва проверить: не поступила ли команда с компьютера?
    lds r16, rx_ready
    tst r16
    breq check_ping

    lds r16, rx_error
    tst r16
    brne reply_error

    rcall process_command  ; r24 = 0 (OK) или 1 (ERR)
    tst r24
    brne reply_error

    ldi r30, low(MSG_OK*2)
    ldi r31, high(MSG_OK*2)
    rcall send_flash
    rjmp clear_input

reply_error:
    ldi r30, low(MSG_ERR*2)
    ldi r31, high(MSG_ERR*2)
    rcall send_flash

clear_input:
    ; Несколько команд для очистки буфера. Аппаратные таймеры
    ; продолжают считать: мы НЕ выключаем TCCR1B/TCCR2.
    cli
    clr r16
    sts rx_len, r16
    sts rx_ready, r16
    sts rx_error, r16
    sei
    rjmp main_loop

check_ping:
    ; pending1 изменяется в прерывании, поэтому читаем под cli.
    cli
    lds r16, pending1
    tst r16
    breq check_pong
    dec r16
    sts pending1, r16
    sei
    ldi r26, low(text1)
    ldi r27, high(text1)
    lds r18, len1
    rcall send_ram_line
    rjmp main_loop

check_pong:
    lds r16, pending2
    tst r16
    breq no_events
    dec r16
    sts pending2, r16
    sei
    ldi r26, low(text2)
    ldi r27, high(text2)
    lds r18, len2
    rcall send_ram_line
    rjmp main_loop

no_events:
    sei
    rjmp main_loop

; ======================================================================
; 3. ОТПРАВКА В USART
; ======================================================================
; В r16 лежит байт. Ждем, пока USART освободится.
; Прерывания при ожидании разрешены, таймеры не стоят.
send_byte:
    sbis UCSRA, 5          ; UDRE = 1, регистр готов
    rjmp send_byte
    out UDR, r16
    ret

; Указатель Z (r31:r30) ведет в FLASH, строка заканчивается нулем.
send_flash:
flash_next:
    lpm r16, Z+
    tst r16
    breq flash_done
    rcall send_byte
    rjmp flash_next
flash_done:
    ret

; Указатель X (r27:r26) ведет в ОЗУ; r18 содержит длину текста.
; Отправляет текст и \r\n (перевод строки).
send_ram_line:
ram_next:
    tst r18
    breq send_crlf
    ld r16, X+
    rcall send_byte
    dec r18
    rjmp ram_next
send_crlf:
    ldi r16, 13
    rcall send_byte
    ldi r16, 10
    rcall send_byte
    ret

; ======================================================================
; 4. РАЗБОР КОМАНД
; ======================================================================
; r24 = 0 означает OK; r24 = 1 означает ERR.
process_command:
    lds r16, rx_line
    cpi r16, 'T'
    brne command_try_s
    rjmp command_timer
command_try_s:
    cpi r16, 'S'
    brne command_try_r
    rjmp command_string
command_try_r:
    cpi r16, 'R'
    brne command_unknown
    rjmp command_reset
command_unknown:
    rjmp command_bad

; Команда RESET - просто проверяем каждую букву.
command_reset:
    lds r16, rx_line+1
    cpi r16, 'E'
    breq bad_skip_1
    rjmp command_bad
bad_skip_1:
    lds r16, rx_line+2
    cpi r16, 'S'
    breq bad_skip_2
    rjmp command_bad
bad_skip_2:
    lds r16, rx_line+3
    cpi r16, 'E'
    breq bad_skip_3
    rjmp command_bad
bad_skip_3:
    lds r16, rx_line+4
    cpi r16, 'T'
    breq bad_skip_4
    rjmp command_bad
bad_skip_4:
    lds r16, rx_line+5
    tst r16
    breq bad_skip_5
    rjmp command_bad
bad_skip_5:

    ; Это именно перезапуск: сбросим аппаратные счетчики
    ; и программные счетчики времени. Их тактирование не отключаем.
    cli
    clr r16
    out TCNT1H, r16
    out TCNT1L, r16
    out TCNT2, r16
    lds r16, period1
    sts left1, r16
    lds r16, period2
    sts left2, r16
    clr r16
    sts pending1, r16
    sts pending2, r16
    ldi r16, 0x90
    out TIFR, r16          ; убрать старые флаги сравнения
    sei
    rjmp command_good

; ----------------------------------------------------------------------
; Команда T1=число или T2=число.
; ----------------------------------------------------------------------
command_timer:
    lds r16, rx_line+1
    cpi r16, '1'
    breq timer_is_1
    cpi r16, '2'
    breq timer_is_2
    rjmp command_bad

timer_is_1:
    ldi r22, 1            ; запоминаем номер таймера
    rjmp timer_equal

timer_is_2:
    ldi r22, 2

timer_equal:
    lds r16, rx_line+2
    cpi r16, '='
    breq timer_digits_start
    rjmp command_bad

timer_digits_start:
    ldi r30, low(rx_line+3)
    ldi r31, high(rx_line+3)
    clr r20               ; r20 = число, которое набираем
    clr r23               ; число введенных цифр

timer_digit_loop:
    ld r16, Z+
    tst r16
    breq timer_number_done
    cpi r16, '0'
    brsh bad_skip_6
    rjmp command_bad
bad_skip_6:
    cpi r16, 58
    brlo bad_skip_7
    rjmp command_bad
bad_skip_7:

    inc r23
    ; Перед умножением на 10 проверим, не получится ли > 255.
    cpi r20, 26
    brlo bad_skip_8
    rjmp command_bad
bad_skip_8:
    subi r16, '0'        ; символ '7' превратится в число 7
    mov r21, r20
    lsl r20               ; r20 = число * 2
    lsl r21
    lsl r21
    lsl r21               ; r21 = число * 8
    add r20, r21          ; r20 = число * 10
    brcc bad_skip_9
    rjmp command_bad
bad_skip_9:
    add r20, r16          ; добавить очередную цифру
    brcc bad_skip_10
    rjmp command_bad
bad_skip_10:
    rjmp timer_digit_loop

timer_number_done:
    tst r23               ; была хотя бы одна цифра?
    brne bad_skip_11
    rjmp command_bad
bad_skip_11:
    tst r20               ; интервал не может равняться 0
    brne bad_skip_12
    rjmp command_bad
bad_skip_12:

    ; Теперь проверим правило 2*длина+5.
    cpi r22, 1
    breq validate_t1
    lds r21, len2
    rjmp validate_interval
validate_t1:
    lds r21, len1
validate_interval:
    lsl r21               ; длина * 2
    ldi r17, 5
    add r21, r17          ; длина * 2 + 5
    cp r20, r21
    brsh timer_value_ok
    rjmp command_bad     ; слишком маленький интервал

timer_value_ok:
    cpi r22, 1
    breq set_t1
    ; Изменить значение второго таймера.
    cli                    ; запретим ISR только на пару записей
    sts period2, r20
    sts left2, r20
    sei
    rjmp command_good
set_t1:
    cli
    sts period1, r20
    sts left1, r20
    sei
    rjmp command_good

; ----------------------------------------------------------------------
; Команда S1=текст или S2=текст.
; ----------------------------------------------------------------------
command_string:
    lds r16, rx_line+1
    cpi r16, '1'
    breq string_is_1
    cpi r16, '2'
    breq string_is_2
    rjmp command_bad
string_is_1:
    ldi r22, 1
    rjmp string_equal
string_is_2:
    ldi r22, 2
string_equal:
    lds r16, rx_line+2
    cpi r16, '='
    breq string_count_start
    rjmp command_bad

string_count_start:
    ldi r30, low(rx_line+3)
    ldi r31, high(rx_line+3)
    clr r20               ; будущая длина строки

string_count_loop:
    ld r16, Z+
    tst r16
    breq string_count_done
    ; Разрешаем только обычные видимые символы ASCII и пробел.
    cpi r16, 32
    brsh bad_skip_13
    rjmp command_bad
bad_skip_13:
    cpi r16, 127
    brlo bad_skip_14
    rjmp command_bad
bad_skip_14:
    inc r20
    cpi r20, 9
    brlo bad_skip_15    ; больше 8 символов нельзя
    rjmp command_bad
bad_skip_15:
    rjmp string_count_loop

string_count_done:
    ; До изменения ОЗУ проверяем, достаточен ли текущий период.
    mov r21, r20
    lsl r21
    ldi r17, 5
    add r21, r17          ; минимальный интервал новой строки
    cpi r22, 1
    breq string_check_t1
    lds r16, period2
    rjmp string_check_period
string_check_t1:
    lds r16, period1
string_check_period:
    cp r16, r21
    brsh string_can_copy
    rjmp command_bad

string_can_copy:
    ldi r30, low(rx_line+3)
    ldi r31, high(rx_line+3)
    mov r19, r20           ; сколько символов копировать
    cpi r22, 1
    breq copy_string1
    ldi r26, low(text2)
    ldi r27, high(text2)
    rjmp copy_string_loop
copy_string1:
    ldi r26, low(text1)
    ldi r27, high(text1)
copy_string_loop:
    tst r19
    breq string_copy_done
    ld r16, Z+
    st X+, r16
    dec r19
    rjmp copy_string_loop
string_copy_done:
    cpi r22, 1
    breq update_len1
    sts len2, r20
    rjmp command_good
update_len1:
    sts len1, r20
    rjmp command_good

command_bad:
    ldi r24, 1
    ret
command_good:
    clr r24
    ret

; ======================================================================
; 5. ПРЕРЫВАНИЯ ОТ ДВУХ ТАЙМЕРОВ
; ======================================================================
; КАЖДЫЙ таймер вызывает свое прерывание 1000 раз в секунду.
; Если счетчик left стал нулем - увеличить число ожидающих строк.
; Никакой передачи в USART из обработчика не делаем.

timer1_irq:
    push r16
    in r16, SREG
    push r16
    push r17
    lds r16, left1
    dec r16
    brne timer1_save
    lds r16, period1
    lds r17, pending1
    cpi r17, 255
    breq timer1_save
    inc r17
    sts pending1, r17

timer1_save:
    sts left1, r16
    pop r17
    pop r16
    out SREG, r16
    pop r16
    reti

timer2_irq:
    push r16
    in r16, SREG
    push r16
    push r17
    lds r16, left2
    dec r16
    brne timer2_save
    lds r16, period2
    lds r17, pending2
    cpi r17, 255
    breq timer2_save
    inc r17
    sts pending2, r17

timer2_save:
    sts left2, r16
    pop r17
    pop r16
    out SREG, r16
    pop r16
    reti

; ======================================================================
; 6. ПРЕРЫВАНИЕ ПРИЕМА USART
; ======================================================================
; Один байт пришел от терминала - добавим его в команду.
; Enter (CR или LF) завершает команду. Пустые строки игнорируем.
; Когда команда готова, новые байты временно не принимаем.
; Это рассчитано на ручной ввод команд, а не большой поток данных.
uart_rx_irq:
    push r16
    in r16, SREG
    push r16
    push r17
    push r18
    push r30
    push r31

    in r16, UDR             ; прочитать пришедший байт
    lds r17, rx_ready
    tst r17
    brne uart_rx_done
    cpi r16, 13             ; CR
    breq uart_end_line
    cpi r16, 10             ; LF
    breq uart_end_line

    lds r17, rx_len
    cpi r17, 15
    brsh uart_too_long
    ; Z = адрес начала буфера + длина текущей команды.
    ldi r30, low(rx_line)
    ldi r31, high(rx_line)
    add r30, r17
    ldi r18, 0            ; LDI не сбрасывает флаг переноса C
    adc r31, r18
    st Z, r16
    inc r17
    sts rx_len, r17
    rjmp uart_rx_done

uart_too_long:
    ldi r17, 1
    sts rx_error, r17
    rjmp uart_rx_done

uart_end_line:
    lds r17, rx_len
    tst r17
    breq uart_rx_done     ; пустой перевод строки после CR
    ; Записать нуль в конец команды для удобства разбора.
    ldi r30, low(rx_line)
    ldi r31, high(rx_line)
    add r30, r17
    ldi r18, 0            ; LDI не сбрасывает флаг переноса C
    adc r31, r18
    clr r16
    st Z, r16
    ldi r17, 1
    sts rx_ready, r17

uart_rx_done:
    pop r31
    pop r30
    pop r18
    pop r17
    pop r16
    out SREG, r16
    pop r16
    reti

; ======================================================================
; 7. НАЧАЛЬНЫЕ ТЕКСТЫ И ОТВЕТЫ
; ======================================================================
; Эти константы во FLASH. Изменяемые копии лежат в text1 и text2.
TIMER1_STR:
    .db "ping"
TIMER2_STR:
    .db "pong"
MSG_OK:
    .db "OK", 13, 10, 0, 0
MSG_ERR:
    .db "ERR", 13, 10, 0
