--- Тесты разбора письма: заголовки, части, кодировки и чужие привычки.

local t = require('luatest')
local utf8 = require('utf8')

local g = t.group('tnt.mail.parse')

local helper = dofile('test/helper.lua')

---@type any
local parse

---@type any
local message

g.before_each(function()
    parse = helper.load('tnt.mail.parse')
    message = helper.module('tnt.mail.message')
end)

g.after_each(function()
    helper.unload()
end)

--- Письмо из строк: так его и видно в протоколе.
---@param lines string[]
---@return string
local function raw(lines)
    return table.concat(lines, '\r\n')
end

g.test_simple_letter_is_taken_apart = function()
    local letter = parse.of(raw({
        'From: tarantool@example.org',
        'To: duty@example.org',
        'Subject: Отчёт',
        'Content-Type: text/plain; charset=UTF-8',
        '',
        'Тело письма',
    }))

    t.assert_equals(letter.from, 'tarantool@example.org')
    t.assert_equals(letter.to, 'duty@example.org')
    t.assert_equals(letter.subject, 'Отчёт')
    t.assert_equals(letter.text, 'Тело письма')
end

g.test_our_own_letter_survives_the_round_trip = function()
    -- Самая важная проверка разбора: то, что мы собрали, мы же обязаны
    -- прочитать обратно — включая кириллицу и точку на своей строке.
    local built = message.build({
        from = { name = 'Узел', address = 'tarantool@example.org' },
        to = 'duty@example.org',
        subject = 'Реплика отстала',
        text = 'Первая строка\r\n.\r\nПоследняя строка',
    }, 1789041300)

    local letter = parse.of(built)

    t.assert_equals(letter.subject, 'Реплика отстала')
    t.assert_equals(letter.text, 'Первая строка\r\n.\r\nПоследняя строка')
    t.assert_str_contains(letter.from, 'Узел')
end

g.test_multipart_letter_gives_both_bodies = function()
    local built = message.build({
        from = 'a@b',
        to = 'c@d',
        text = 'Простой текст',
        html = '<p>Разметка</p>',
    }, 1789041300)

    local letter = parse.of(built)

    t.assert_equals(letter.text, 'Простой текст')
    t.assert_equals(letter.html, '<p>Разметка</p>')
    t.assert_equals(#letter.parts, 2)
end

g.test_quoted_printable_body_is_read = function()
    -- Так шлёт половина мира, и разобрать это надо не хуже своего.
    local letter = parse.of(raw({
        'Subject: =?UTF-8?Q?=D0=9F=D1=80=D0=BE=D0=B2=D0=B5=D1=80=D0=BA=D0=B0?=',
        'Content-Type: text/plain; charset=utf-8',
        'Content-Transfer-Encoding: quoted-printable',
        '',
        '=D0=A2=D0=B5=D0=BB=D0=BE',
    }))

    t.assert_equals(letter.subject, 'Проверка')
    t.assert_equals(letter.text, 'Тело')
end

g.test_folded_header_is_glued_back = function()
    -- Длинный заголовок переносится с отступа, и склеить его обязан
    -- разборщик: иначе адрес получателя обрывается на середине.
    local letter = parse.of(raw({
        'To: first@example.org,',
        '\tsecond@example.org',
        '',
        'тело',
    }))

    t.assert_equals(letter.to, 'first@example.org, second@example.org')
end

g.test_headers_split_by_any_line_break_are_read = function()
    -- Чужие программы переводят строку как придётся: `\r\n`, `\n` или
    -- одиноким `\r`, — и строка за любым из них — новый заголовок.
    local letter = parse.of('From: a@example.org\rTo: b@example.org\nSubject: Отчёт\r\n\r\nтело')

    t.assert_equals(letter.from, 'a@example.org')
    t.assert_equals(letter.to, 'b@example.org')
    t.assert_equals(letter.subject, 'Отчёт')
    t.assert_equals(letter.text, 'тело')
end

g.test_header_names_are_case_insensitive = function()
    -- Регистр в именах заголовков не значит ничего, а сравнивать
    -- `Content-Type` с `content-type` рано или поздно забывают.
    local letter = parse.of(raw({ 'SUBJECT: Тема', 'content-TYPE: text/plain', '', 'тело' }))

    t.assert_equals(letter.subject, 'Тема')
    t.assert_equals(letter.headers['content-type'], 'text/plain')
end

g.test_letter_without_a_body_is_still_a_letter = function()
    local letter = parse.of('Subject: Пусто')

    t.assert_equals(letter.subject, 'Пусто')
    t.assert_equals(letter.text, '')
end

g.test_unknown_encoding_is_left_as_it_came = function()
    -- Показать сырое тело честнее, чем выбросить письмо целиком.
    local letter = parse.of(raw({
        'Content-Transfer-Encoding: 8bit',
        'Content-Type: text/plain',
        '',
        'сырой текст',
    }))

    t.assert_equals(letter.text, 'сырой текст')
end

g.test_broken_boundary_does_not_lose_the_letter = function()
    -- Граница объявлена, а частей нет: письмо пришло оборванным.
    -- Разбор обязан отдать то, что есть, а не упасть.
    local letter = parse.of(raw({
        'Content-Type: multipart/alternative; boundary="край"',
        '',
        'ничего похожего на части',
    }))

    t.assert_equals(letter.parts, {})
    t.assert_equals(letter.text, nil)
end

g.test_nested_parts_are_taken_apart = function()
    -- Текст с вложением, внутри — текст и разметка: обычное письмо
    -- из почтовой программы.
    local letter = parse.of(raw({
        'Content-Type: multipart/mixed; boundary="внешняя"',
        '',
        '--внешняя',
        'Content-Type: multipart/alternative; boundary="внутренняя"',
        '',
        '--внутренняя',
        'Content-Type: text/plain',
        '',
        'простой',
        '--внутренняя',
        'Content-Type: text/html',
        '',
        '<b>разметка</b>',
        '--внутренняя--',
        '--внешняя--',
    }))

    t.assert_equals(letter.text, 'простой')
    t.assert_equals(letter.html, '<b>разметка</b>')
end

g.test_identifier_and_date_are_kept = function()
    local letter = parse.of(raw({
        'Message-ID: <ключ@узел>',
        'Date: Thu, 10 Sep 2026 11:55:00 +0000',
        '',
        'тело',
    }))

    t.assert_equals(letter.message_id, '<ключ@узел>')
    t.assert_equals(letter.date, 'Thu, 10 Sep 2026 11:55:00 +0000')
end

g.test_letter_without_headers_is_all_body = function()
    -- Письмо начинается с пустой строки: заголовков нет вовсе. Так шлют
    -- самодельные отправители, и тело у такого письма всё равно есть.
    local letter = parse.of(raw({ '', '', 'одно тело' }))

    t.assert_equals(letter.subject, nil)
    t.assert_equals(letter.text, 'одно тело')
end

g.test_empty_line_inside_the_body_stays_in_the_body = function()
    -- Делить надо по первой пустой строке: абзацы в теле — обычное дело,
    -- и по последней пустой строке половина письма уехала бы в заголовки.
    local letter = parse.of(raw({
        'Subject: Абзацы',
        '',
        'первый абзац',
        '',
        'второй абзац',
    }))

    t.assert_equals(letter.subject, 'Абзацы')
    t.assert_equals(letter.text, 'первый абзац\r\n\r\nвторой абзац')
end

g.test_line_without_a_name_is_not_a_header = function()
    -- Строка, начинающаяся с двоеточия, — мусор, а не заголовок с пустым
    -- именем: заводить под неё ключ значит однажды найти его в письме.
    local letter = parse.of(raw({ ': ничей', 'Subject: Тема', '', 'тело' }))

    t.assert_equals(letter.subject, 'Тема')
    t.assert_equals(letter.headers[''], nil)
end

g.test_header_without_a_space_after_the_colon_is_read = function()
    -- Пробел после двоеточия необязателен, и кто-нибудь его не поставит.
    local letter = parse.of(raw({ 'Subject:Без пробела', '', 'тело' }))

    t.assert_equals(letter.subject, 'Без пробела')
end

g.test_type_that_starts_with_a_semicolon_falls_back_to_plain_text = function()
    -- У типа отъели начало: читать письмо как простой текст честнее,
    -- чем считать, что типа нет и тело двоичное.
    local letter = parse.of(raw({ 'Content-Type: ; charset=UTF-8', '', 'тело' }))

    t.assert_equals(letter.text, 'тело')
    t.assert_equals(letter.parts, {})
end

g.test_options_of_the_type_are_read_without_spaces = function()
    -- Пробел после точки с запятой тоже необязателен.
    local letter = parse.of(raw({
        'Content-Type: multipart/alternative;boundary="край"',
        '',
        '--край',
        'Content-Type: text/plain',
        '',
        'часть',
        '--край--',
    }))

    t.assert_equals(letter.text, 'часть')
end

g.test_option_without_a_value_is_not_a_value = function()
    -- `charset=` без значения — не пустая кодировка, а её отсутствие.
    local letter = parse.of(raw({ 'Content-Type: text/plain; charset=', '', 'тело' }))

    t.assert_equals(letter.text, 'тело')
    t.assert_equals(parse.of(raw({ 'Content-Type: text/plain; charset=', '', '' })).text, '')
end

g.test_option_name_may_carry_a_dash = function()
    -- Имя свойства с дефисом: так выглядит `boundary` у части с вложением
    -- и почти все свойства, придуманные почтовыми программами.
    local letter = parse.of(raw({
        'Content-Type: multipart/mixed; x-part-boundary=нет; boundary="край"',
        '',
        '--край',
        'Content-Type: text/plain',
        '',
        'часть',
        '--край--',
    }))

    t.assert_equals(letter.text, 'часть')
end

g.test_last_part_without_a_closing_boundary_is_kept_whole = function()
    -- Письмо оборвано на полуслове: закрывающей границы нет. Последняя
    -- часть обязана дойти целиком, вместе с последним знаком.
    local letter = parse.of(raw({
        'Content-Type: multipart/alternative; boundary="край"',
        '',
        '--край',
        'Content-Type: text/plain',
        '',
        'оборванный текст!',
    }))

    t.assert_equals(letter.text, 'оборванный текст!')
end

g.test_tail_after_the_closing_boundary_is_not_a_part = function()
    -- После закрывающей границы почтовые серверы дописывают своё:
    -- частью письма это не становится.
    local letter = parse.of(raw({
        'Content-Type: multipart/alternative; boundary="край"',
        '',
        '--край',
        'Content-Type: text/plain',
        '',
        'настоящая часть',
        '--край--',
        'приписка сервера',
    }))

    t.assert_equals(#letter.parts, 1)
    t.assert_equals(letter.text, 'настоящая часть')
end

g.test_type_without_a_subtype_is_not_multipart = function()
    -- `multipart` без подтипа — не многочастное письмо, а испорченный
    -- заголовок: резать по границе такое тело нечего.
    local letter = parse.of(raw({
        'Content-Type: multipart; boundary="край"',
        '',
        '--край',
        'Content-Type: text/plain',
        '',
        'часть',
        '--край--',
    }))

    t.assert_equals(letter.parts, {})
    t.assert_str_contains(letter.headers['content-type'], 'multipart')
end

g.test_plain_text_with_a_boundary_is_still_plain_text = function()
    -- Граница объявлена у простого текста: тип главнее свойства,
    -- и тело обязано прочитаться как текст.
    local letter = parse.of(raw({ 'Content-Type: text/plain; boundary="край"', '', 'тело' }))

    t.assert_equals(letter.text, 'тело')
    t.assert_equals(letter.parts, {})
end

g.test_fourth_level_of_nesting_stays_raw = function()
    -- Предел глубины: три уровня разбираются, дальше часть остаётся
    -- сырым текстом. Кольцевая граница иначе положила бы узел.
    local letter = parse.of(raw({
        'Content-Type: multipart/mixed; boundary="один"',
        '',
        '--один',
        'Content-Type: multipart/mixed; boundary="два"',
        '',
        '--два',
        'Content-Type: multipart/alternative; boundary="три"',
        '',
        '--три',
        'Content-Type: text/plain',
        '',
        'самый глубокий',
        '--три--',
        '--два--',
        '--один--',
    }))

    t.assert_equals(letter.text, nil, 'четвёртый уровень не разбирается')

    local first = helper.at(letter.parts, 1)
    local second = helper.at(first.parts, 1)

    t.assert_equals(second.kind, 'multipart/alternative')
    t.assert_str_contains(second.body, 'самый глубокий')
    t.assert_equals(second.parts, {})
end

g.test_markup_does_not_become_the_plain_text = function()
    -- Разметка идёт первой частью: текстом письма она не становится,
    -- иначе дежурный получит в уведомлении угловые скобки.
    local letter = parse.of(raw({
        'Content-Type: multipart/alternative; boundary="край"',
        '',
        '--край',
        'Content-Type: text/html',
        '',
        '<b>разметка</b>',
        '--край',
        'Content-Type: text/plain',
        '',
        'простой текст',
        '--край--',
    }))

    t.assert_equals(letter.text, 'простой текст')
    t.assert_equals(letter.html, '<b>разметка</b>')
end

g.test_calendar_part_is_neither_text_nor_markup = function()
    -- Часть незнакомого типа остаётся в разметке письма и никуда больше:
    -- приглашение в календарь — не текст письма и не его разметка.
    local letter = parse.of(raw({
        'Content-Type: multipart/mixed; boundary="край"',
        '',
        '--край',
        'Content-Type: text/calendar',
        '',
        'BEGIN:VCALENDAR',
        '--край--',
    }))

    t.assert_equals(letter.text, nil)
    t.assert_equals(letter.html, nil)
    t.assert_equals(helper.at(letter.parts, 1).kind, 'text/calendar')
end

g.test_part_keeps_the_options_of_its_type = function()
    -- Свойства типа нужны дальше нашего разбора: по `name` видно имя
    -- вложения, а свойство с дефисом в имени — самое обычное дело.
    local letter = parse.of(raw({
        'Content-Type: multipart/mixed; boundary="край"',
        '',
        '--край',
        'Content-Type: text/plain; x-mail-part=третий; charset=UTF-8',
        '',
        'тело части',
        '--край--',
    }))

    local part = helper.at(letter.parts, 1)

    t.assert_equals(part.options['x-mail-part'], 'третий')
    t.assert_equals(part.charset, 'UTF-8')
end

g.test_option_without_a_name_is_not_an_option = function()
    -- Свойство без имени — испорченный заголовок, а не свойство с пустым
    -- именем: ключ под него завёлся бы ровно один раз и навсегда.
    local letter = parse.of(raw({
        'Content-Type: multipart/mixed; boundary="край"',
        '',
        '--край',
        'Content-Type: text/plain; =безымянное; charset=UTF-8',
        '',
        'тело части',
        '--край--',
    }))

    local part = helper.at(letter.parts, 1)

    t.assert_equals(part.options[''], nil)
    t.assert_equals(part.charset, 'UTF-8')
end

g.test_empty_option_value_is_no_value_at_all = function()
    -- `charset=` без значения — не пустая кодировка, а её отсутствие:
    -- иначе письмо объявляет кодировку, которой нет.
    local letter = parse.of(raw({ 'Content-Type: text/plain; charset=', '', 'тело' }))

    t.assert_equals(letter.charset, nil)
    t.assert_equals(letter.text, 'тело')
end

g.test_charset_of_the_letter_is_visible = function()
    local letter = parse.of(raw({ 'Content-Type: text/plain; charset=KOI8-R', '', 'тело' }))

    t.assert_equals(letter.charset, 'KOI8-R')
end

g.test_our_letter_with_attachments_survives_the_round_trip = function()
    -- Вложения возвращаются в том же виде, в каком их отдали
    -- на отправку: забранное письмо можно переслать дальше как есть.
    local attachments = {
        { name = 'report.csv', type = 'text/csv', content = 'a,b\r\n1,2\r\n' },
        { name = 'отчёт "за день".bin', type = 'application/octet-stream', content = ('\0\255'):rep(5) },
    }

    local built = assert(message.build({
        from = 'a@b',
        to = 'c@d',
        text = 'см. вложение',
        html = '<p>см. вложение</p>',
        attachments = attachments,
    }, 1789041300))

    local letter = parse.of(built)

    t.assert_equals(letter.text, 'см. вложение')
    t.assert_equals(letter.html, '<p>см. вложение</p>')
    t.assert_equals(letter.attachments, attachments)
    t.assert_equals(#letter.parts, 3)
    t.assert_equals(helper.at(letter.parts, 2).disposition, 'attachment')
    t.assert_equals(helper.at(letter.parts, 2).name, 'report.csv')
end

g.test_letter_without_attachments_has_an_empty_list = function()
    local letter = parse.of(raw({ 'Content-Type: text/plain', '', 'тело' }))

    t.assert_equals(letter.attachments, {})
    t.assert_equals(letter.parts, {})
end

g.test_attached_text_is_not_the_text_of_the_letter = function()
    -- Приложенный журнал — тоже текст, но не то, что человек написал
    -- в письме: текстом остаётся часть без имени, даже если она вторая.
    local letter = parse.of(raw({
        'Content-Type: multipart/mixed; boundary="край"',
        '',
        '--край',
        'Content-Type: text/plain',
        'Content-Disposition: attachment; filename="node.log"',
        '',
        'строка журнала',
        '--край',
        'Content-Type: text/plain',
        '',
        'само письмо',
        '--край--',
    }))

    t.assert_equals(letter.text, 'само письмо')
    t.assert_equals(
        letter.attachments,
        { { name = 'node.log', type = 'text/plain', content = 'строка журнала' } }
    )
end

g.test_inline_part_with_a_name_is_an_attachment = function()
    -- Так вложения шлёт рок smtp: `inline` с именем файла и хвостовой
    -- точкой с запятой. Имя решает, и терять файл из-за слова незачем.
    local letter = parse.of(raw({
        'Content-Type: multipart/mixed; boundary=MULTIPART-MIXED-BOUNDARY;',
        '',
        '--MULTIPART-MIXED-BOUNDARY',
        'Content-Type: text/plain; charset=UTF-8;',
        '',
        'Привет',
        '--MULTIPART-MIXED-BOUNDARY',
        'Content-Type: text/csv; charset=UTF-8;',
        'Content-Disposition: inline; filename="report.csv";',
        'Content-Transfer-Encoding: base64',
        '',
        'YSxiCjEsMgo=',
        '--MULTIPART-MIXED-BOUNDARY--',
    }))

    t.assert_equals(letter.text, 'Привет')
    t.assert_equals(letter.attachments, { { name = 'report.csv', type = 'text/csv', content = 'a,b\n1,2\n' } })
    t.assert_equals(helper.at(letter.parts, 2).disposition, 'inline')
end

g.test_name_is_taken_from_the_type_when_the_disposition_has_none = function()
    -- Старые программы пишут имя в тип содержимого: `name=`,
    -- а размещения не пишут вовсе.
    local letter = parse.of(raw({
        'Content-Type: multipart/mixed; boundary="край"',
        '',
        '--край',
        'Content-Type: application/pdf; name="act.pdf"',
        '',
        '%PDF',
        '--край--',
    }))

    t.assert_equals(letter.attachments, { { name = 'act.pdf', type = 'application/pdf', content = '%PDF' } })
    t.assert_equals(helper.at(letter.parts, 1).disposition, nil)
end

g.test_attachment_without_a_name_is_still_an_attachment = function()
    -- Размещение названо, имени нет: файл всё равно приложен,
    -- просто безымянный.
    local letter = parse.of(raw({
        'Content-Type: multipart/mixed; boundary="край"',
        '',
        '--край',
        'Content-Type: image/png',
        'Content-Disposition: attachment',
        '',
        'PNG',
        '--край--',
    }))

    t.assert_equals(letter.attachments, { { type = 'image/png', content = 'PNG' } })
end

g.test_extended_name_wins_and_is_decoded = function()
    -- По RFC 2231 имя вне ASCII едет как `filename*=UTF-8''%D0...`,
    -- и оно главнее обычного `filename`, которое пишут рядом для старых
    -- программ. Имя в UTF-8 переводить незачем, язык отбрасывается.
    local letter = parse.of(raw({
        'Content-Type: multipart/mixed; boundary="край"',
        '',
        '--край',
        'Content-Type: text/csv',
        'Content-Disposition: attachment; filename="report.csv"; '
            .. "filename*=UTF-8'ru'%D0%9E%D1%82%D1%87%D1%91%D1%82.csv",
        '',
        'a,b',
        '--край--',
    }))

    t.assert_equals(helper.at(letter.attachments, 1).name, 'Отчёт.csv')
end

g.test_extended_name_without_apostrophes_is_taken_whole = function()
    -- Звёздочка есть, апострофов нет: не расширенный вид, а просто
    -- имя со звёздочкой — берётся целиком, но пары всё равно разбираются.
    local letter = parse.of(raw({
        'Content-Type: multipart/mixed; boundary="край"',
        '',
        '--край',
        'Content-Type: text/csv',
        'Content-Disposition: attachment; filename*=plain%20name.csv',
        '',
        'a,b',
        '--край--',
    }))

    t.assert_equals(helper.at(letter.attachments, 1).name, 'plain name.csv')
end

g.test_multipart_marked_as_attachment_is_not_an_attachment_itself = function()
    -- Размещение на многочастном письме — про письмо, а не про файл:
    -- вложения ищутся внутри, а само письмо в них не попадает.
    local letter = parse.of(raw({
        'Content-Type: multipart/mixed; boundary="край"',
        'Content-Disposition: attachment; filename="whole.eml"',
        '',
        '--край',
        'Content-Type: text/plain',
        '',
        'тело',
        '--край',
        'Content-Type: text/plain',
        'Content-Disposition: attachment; filename="inner.txt"',
        '',
        'внутри',
        '--край--',
    }))

    t.assert_equals(letter.text, 'тело')
    t.assert_equals(letter.attachments, { { name = 'inner.txt', type = 'text/plain', content = 'внутри' } })
end

--- «Привет» в cp1251 и в koi8-r: по байту на букву.
local CP1251_HELLO = '\207\240\232\226\229\242'
local KOI8_HELLO = '\240\210\201\215\197\212'

--- Строка в UTF-8 ли: так её видит всякий, кто считает строку UTF-8.
---@param text any
---@return boolean
local function readable(text)
    return type(text) == 'string' and utf8.len(text) ~= nil
end

g.test_windows_letter_is_read_in_utf8 = function()
    -- Письмо из Windows: тема и тело в cp1251, тело восьмибитное как есть.
    -- Дальше его читают `str.upper`, панель и журнал — им нужен UTF-8.
    local letter = parse.of(raw({
        'Subject: =?windows-1251?B?z/Do4uXy?=',
        'Content-Type: text/plain; charset=windows-1251',
        'Content-Transfer-Encoding: 8bit',
        '',
        CP1251_HELLO,
    }))

    t.assert_equals(letter.subject, 'Привет')
    t.assert_equals(letter.text, 'Привет')
    t.assert(readable(letter.text), 'текст письма — UTF-8')
    t.assert_equals(
        letter.charset,
        'windows-1251',
        'объявленная кодировка видна как была'
    )
    t.assert_equals(letter.charset_error, nil)
end

g.test_koi8_letter_in_quoted_printable_is_read_in_utf8 = function()
    local letter = parse.of(raw({
        'Subject: =?koi8-r?Q?=EF=D4=DE=A3=D4_=CF_=D3=C2=CF=C5?=',
        'Content-Type: text/plain; charset="KOI8-R"',
        'Content-Transfer-Encoding: quoted-printable',
        '',
        '=F4=C5=CC=CF =D0=C9=D3=D8=CD=C1',
    }))

    t.assert_equals(letter.subject, 'Отчёт о сбое')
    t.assert_equals(letter.text, 'Тело письма')
end

g.test_windows_letter_in_base64_is_read_in_utf8 = function()
    -- Сначала снимается base64, потом кодировка: байты cp1251 лежат
    -- внутри base64, а не наоборот.
    local letter = parse.of(raw({
        'Content-Type: text/plain; charset=cp1251',
        'Content-Transfer-Encoding: base64',
        '',
        '0uXr7iDv6PH87OA=',
    }))

    t.assert_equals(letter.text, 'Тело письма')
end

g.test_charset_with_a_trailing_space_is_still_understood = function()
    -- `charset=windows-1251 ;` — разбор свойств оставляет пробел,
    -- а письмо от этого не перестаёт быть письмом в cp1251.
    local letter = parse.of(raw({
        'Content-Type: text/plain; charset=windows-1251 ; format=flowed',
        '',
        CP1251_HELLO,
    }))

    t.assert_equals(letter.text, 'Привет')
end

g.test_letter_in_an_unknown_charset_keeps_its_bytes_and_says_why = function()
    -- Разбор терпелив: письмо не отвергается и не бросает, текст остаётся
    -- байтами как пришёл, а причина видна рядом.
    local letter = parse.of(raw({
        'Content-Type: text/plain; charset=x-unknown',
        '',
        CP1251_HELLO,
    }))

    t.assert_equals(letter.text, CP1251_HELLO)
    t.assert_equals(letter.charset_error, 'кодировка «x-unknown» неизвестна')
end

g.test_letter_with_bytes_not_of_its_charset_keeps_them = function()
    -- 0x98 в cp1251 не назначен: письмо битое, и перевести его целиком
    -- нельзя — половина перевода хуже честных байтов.
    local letter = parse.of(raw({
        'Content-Type: text/plain; charset=windows-1251',
        '',
        'a\152' .. CP1251_HELLO,
    }))

    t.assert_equals(letter.text, 'a\152' .. CP1251_HELLO)
    t.assert_equals(
        letter.charset_error,
        'в тексте есть байты не из кодировки windows-1251'
    )
end

g.test_letter_in_utf8_is_not_touched = function()
    -- Битый байт в письме UTF-8 остаётся на месте, как и прежде:
    -- переводить здесь нечего, и отказа перевода тоже нет.
    for _, charset in ipairs({ 'UTF-8', 'utf8' }) do
        local letter = parse.of(raw({ 'Content-Type: text/plain; charset=' .. charset, '', 'Привет\255' }))

        t.assert_equals(letter.text, 'Привет\255', charset)
        t.assert_equals(letter.charset_error, nil, charset)
    end
end

g.test_letter_without_a_charset_is_not_touched = function()
    -- Без объявленной кодировки гадать не из чего: байты как пришли.
    local letter = parse.of(raw({ 'Content-Type: text/plain', '', CP1251_HELLO }))

    t.assert_equals(letter.text, CP1251_HELLO)
    t.assert_equals(letter.charset_error, nil)
end

g.test_every_text_part_is_read_in_its_own_charset = function()
    -- Текст из Windows, разметка из старого почтовика, приглашение
    -- в календарь — каждая часть в своей кодировке, и каждая `text/*`.
    local letter = parse.of(raw({
        'Content-Type: multipart/mixed; boundary="край"',
        '',
        '--край',
        'Content-Type: text/plain; charset=windows-1251',
        '',
        CP1251_HELLO,
        '--край',
        'Content-Type: text/html; charset=koi8-r',
        '',
        '<p>' .. KOI8_HELLO .. '</p>',
        '--край',
        'Content-Type: text/calendar; charset=windows-1251',
        '',
        'SUMMARY:' .. CP1251_HELLO,
        '--край--',
    }))

    t.assert_equals(letter.text, 'Привет')
    t.assert_equals(letter.html, '<p>Привет</p>')
    t.assert_equals(helper.at(letter.parts, 3).body, 'SUMMARY:Привет')
    t.assert_equals(letter.charset_error, nil)
end

g.test_what_is_not_text_is_not_recoded = function()
    -- Кодировка у нетекстовой части — не повод трогать её байты;
    -- `text` без подтипа — испорченный тип, а не текст.
    local letter = parse.of(raw({
        'Content-Type: multipart/mixed; boundary="край"',
        '',
        '--край',
        'Content-Type: application/json; charset=windows-1251',
        '',
        CP1251_HELLO,
        '--край',
        'Content-Type: text; charset=windows-1251',
        '',
        CP1251_HELLO,
        '--край--',
    }))

    t.assert_equals(helper.at(letter.parts, 1).body, CP1251_HELLO)
    t.assert_equals(helper.at(letter.parts, 2).body, CP1251_HELLO)
end

g.test_reason_of_a_part_reaches_the_part_and_the_letter = function()
    -- У многочастного письма причина видна и у самой части, и у письма:
    -- по письму видно, что показанный текст — байты, по части — какой.
    local letter = parse.of(raw({
        'Content-Type: multipart/alternative; boundary="край"',
        '',
        '--край',
        'Content-Type: text/plain; charset=x-unknown',
        '',
        'сырое',
        '--край',
        'Content-Type: text/html; charset=windows-1251',
        '',
        'a\152b',
        '--край--',
    }))

    t.assert_equals(letter.text, 'сырое')
    t.assert_equals(letter.html, 'a\152b')
    t.assert_equals(helper.at(letter.parts, 1).charset_error, 'кодировка «x-unknown» неизвестна')
    t.assert_equals(
        helper.at(letter.parts, 2).charset_error,
        'в тексте есть байты не из кодировки windows-1251'
    )
    t.assert_equals(
        letter.charset_error,
        'кодировка «x-unknown» неизвестна',
        'остаётся первая причина'
    )
end

g.test_reason_of_the_markup_alone_reaches_the_letter = function()
    -- Текст перевёлся, разметка нет: письмо всё равно говорит, что
    -- в показанном есть байты.
    local letter = parse.of(raw({
        'Content-Type: multipart/alternative; boundary="край"',
        '',
        '--край',
        'Content-Type: text/plain; charset=windows-1251',
        '',
        CP1251_HELLO,
        '--край',
        'Content-Type: text/html; charset=x-unknown',
        '',
        '<p>сырое</p>',
        '--край--',
    }))

    t.assert_equals(letter.text, 'Привет')
    t.assert_equals(letter.charset_error, 'кодировка «x-unknown» неизвестна')
end

g.test_attached_file_keeps_its_bytes_but_its_name_is_read = function()
    -- Вложение — файл: выгрузка для Excel в cp1251 должна доехать cp1251,
    -- иначе Excel откроет кашу. А имя — текст, и оно переводится.
    local letter = parse.of(raw({
        'Content-Type: multipart/mixed; boundary="край"',
        '',
        '--край',
        'Content-Type: text/plain; charset=windows-1251',
        '',
        CP1251_HELLO,
        '--край',
        'Content-Type: text/csv; charset=windows-1251',
        "Content-Disposition: attachment; filename*=windows-1251''%CE%F2%F7%B8%F2.csv",
        '',
        CP1251_HELLO,
        '--край',
        'Content-Type: text/plain; charset=koi8-r',
        "Content-Disposition: attachment; filename*=koi8-r'ru'%EF%D4%DE%A3%D4.txt",
        '',
        KOI8_HELLO,
        '--край--',
    }))

    t.assert_equals(letter.text, 'Привет')
    t.assert_equals(letter.attachments, {
        { name = 'Отчёт.csv', type = 'text/csv', content = CP1251_HELLO },
        { name = 'Отчёт.txt', type = 'text/plain', content = KOI8_HELLO },
    })
    t.assert_equals(helper.at(letter.parts, 2).charset_error, nil)
end

g.test_windows_name_in_the_type_is_read = function()
    -- Outlook пишет имя вложения в тип закодированным куском RFC 2047:
    -- заголовок разбирается целиком, и имя приходит уже в UTF-8.
    local letter = parse.of(raw({
        'Content-Type: multipart/mixed; boundary="край"',
        '',
        '--край',
        'Content-Type: application/pdf; name="=?windows-1251?B?zvL3uPIuY3N2?="',
        '',
        '%PDF',
        '--край--',
    }))

    t.assert_equals(helper.at(letter.attachments, 1).name, 'Отчёт.csv')
end

g.test_name_in_an_unknown_charset_gives_way_to_the_plain_one = function()
    -- `filename` рядом с `filename*` пишут для тех, кто расширенного
    -- не понял, — и это ровно наш случай.
    local letter = parse.of(raw({
        'Content-Type: multipart/mixed; boundary="край"',
        '',
        '--край',
        'Content-Type: text/csv',
        'Content-Disposition: attachment; filename="report.csv"; filename*=x-unknown\'\'%CE%F2.csv',
        '',
        'a,b',
        '--край',
        'Content-Type: text/csv; name="act.csv"',
        "Content-Disposition: attachment; filename*=windows-1251''%98.csv",
        '',
        'a,b',
        '--край--',
    }))

    t.assert_equals(helper.at(letter.attachments, 1).name, 'report.csv')
    t.assert_equals(helper.at(letter.attachments, 2).name, 'act.csv')
end

g.test_name_that_cannot_be_read_stays_as_it_came = function()
    -- Уступить некому: имя остаётся записью, как пришла, — ASCII
    -- с кодировкой впереди честнее байтов чужой кодировки.
    local letter = parse.of(raw({
        'Content-Type: multipart/mixed; boundary="край"',
        '',
        '--край',
        'Content-Type: text/csv',
        "Content-Disposition: attachment; filename*=x-unknown''%CE%F2.csv",
        '',
        'a,b',
        '--край--',
    }))

    t.assert_equals(helper.at(letter.attachments, 1).name, "x-unknown''%CE%F2.csv")
end

g.test_name_without_a_charset_is_taken_as_it_came = function()
    -- Кодировку по RFC 2231 можно не называть, но апострофы остаются:
    -- гадать о ней не из чего, и байты берутся как есть.
    local letter = parse.of(raw({
        'Content-Type: multipart/mixed; boundary="край"',
        '',
        '--край',
        'Content-Type: text/csv',
        "Content-Disposition: attachment; filename*=''%D0%9E.csv",
        '',
        'a,b',
        '--край--',
    }))

    t.assert_equals(helper.at(letter.attachments, 1).name, 'О.csv')
end
