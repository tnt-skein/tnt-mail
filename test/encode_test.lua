--- Тесты кодировок: заголовки, тело, quoted-printable.

local t = require('luatest')

local g = t.group('tnt.mail.encode')

local helper = dofile('test/helper.lua')

---@type any
local encode

g.before_each(function()
    encode = helper.load('tnt.mail.encode')
end)

g.after_each(function()
    helper.unload()
end)

g.test_ascii_header_is_left_alone = function()
    -- Кодировать нечего: лишнее кодирование делает заголовок нечитаемым
    -- в почтовых программах, которые показывают сырой текст.
    t.assert_equals(encode.header('Replication lag'), 'Replication lag')
end

g.test_russian_header_is_encoded_and_read_back = function()
    local encoded = encode.header('Реплика отстала')

    t.assert_str_contains(encoded, '=?UTF-8?B?')
    t.assert_equals(encode.unheader(encoded), 'Реплика отстала')
end

g.test_header_with_several_encoded_pieces_is_read_back = function()
    -- Чужие письма приходят разбитыми по словам: каждое слово своим
    -- куском, и разобрать надо все.
    local value = '=?UTF-8?B?0KDQtdC/0LvQuNC60LA=?= =?UTF-8?B?INC+0YLRgdGC0LDQu9Cw?='

    t.assert_equals(encode.unheader(value), 'Реплика отстала')
end

g.test_space_around_an_encoded_piece_and_a_plain_word_stays = function()
    -- Выбрасывается только пробел между двумя закодированными кусками:
    -- пробел рядом с обычным словом — часть текста.
    t.assert_equals(encode.unheader('Re: =?UTF-8?B?0KDQtdC/0LvQuNC60LA=?= lag'), 'Re: Реплика lag')
    t.assert_equals(encode.unheader('=?UTF-8?B?0KDQtdC/0LvQuNC60LA=?=  '), 'Реплика  ')
end

g.test_space_before_a_broken_piece_stays = function()
    -- Кусок без кодировки не разбирается и остаётся текстом, а пробел
    -- между куском и текстом — часть заголовка.
    t.assert_equals(encode.unheader('=?UTF-8?B?0KDQtdC/0LvQuNC60LA=?= =??B?eA==?='), 'Реплика =??B?eA==?=')
end

g.test_quoted_printable_header_is_read_back = function()
    -- Половина мира шлёт заголовки quoted-printable, и подчёркивание
    -- в них означает пробел.
    t.assert_equals(
        encode.unheader('=?UTF-8?Q?=D0=94=D0=B2=D0=B0_=D1=81=D0=BB=D0=BE=D0=B2=D0=B0?='),
        'Два слова'
    )
end

g.test_broken_encoding_stays_as_it_came = function()
    -- Показать сырой заголовок честнее, чем выбросить его: письмо
    -- с непонятной темой всё равно письмо. Кусок остаётся целиком,
    -- с кодировкой, — по нему видно, что именно не разобралось.
    local value = '=?UTF-8?B?не base64?='

    t.assert_equals(encode.unheader(value), value)
    t.assert_equals(encode.unheader('Тема: ' .. value .. ' хвост'), 'Тема: ' .. value .. ' хвост')
end

--- «Привет» в cp1251 и в koi8-r: по байту на букву.
local CP1251_HELLO = '\207\240\232\226\229\242'
local KOI8_HELLO = '\240\210\201\215\197\212'

g.test_text_is_recoded_from_the_declared_charset = function()
    -- Письма из Windows приходят в cp1251, из старых почтовиков —
    -- в koi8-r: одни и те же буквы, разные байты.
    t.assert_equals(encode.recode(CP1251_HELLO, 'windows-1251'), 'Привет')
    t.assert_equals(encode.recode(KOI8_HELLO, 'KOI8-R'), 'Привет')
    t.assert_equals(encode.recode('', 'cp1251'), '')
end

g.test_text_without_a_charset_stays_as_it_came = function()
    -- Гадать о кодировке не из чего: необъявленная — это ASCII,
    -- и переводить нечего, даже если байты с ним не согласны.
    t.assert_equals(encode.recode(CP1251_HELLO, nil), CP1251_HELLO)
    t.assert_equals(encode.recode(CP1251_HELLO, ''), CP1251_HELLO)
    t.assert_equals(encode.recode(CP1251_HELLO, '  '), CP1251_HELLO)
end

g.test_utf8_text_is_not_recoded_at_all = function()
    -- UTF-8 и так то, что нужно: его байты не проверяются и не правятся,
    -- как и прежде, — битый байт остаётся на месте, а не становится
    -- отказом перевода. Обе записи имени из жизни, регистр любой.
    for _, charset in ipairs({ 'utf-8', 'UTF-8', 'utf8', 'UTF8', ' utf-8 ' }) do
        t.assert_equals({ encode.recode('Привет\255', charset) }, { 'Привет\255' }, charset)
    end
end

g.test_spaces_around_the_charset_are_dropped = function()
    -- `charset=windows-1251 ;` разбор свойств отдаёт с пробелом,
    -- а ядро имени с пробелом не знает.
    t.assert_equals(encode.recode(CP1251_HELLO, ' windows-1251 '), 'Привет')
    t.assert_equals(encode.recode(CP1251_HELLO, 'windows-1251\t'), 'Привет')
end

g.test_unknown_charset_is_a_refusal_in_a_pair = function()
    -- Незнакомая кодировка в чужом письме — случай из жизни, а не ошибка
    -- программиста: пара, а не исключение, и имя названо без пробелов.
    t.assert_equals(
        { encode.recode('abc', 'x-unknown') },
        { nil, 'кодировка «x-unknown» неизвестна' }
    )
    t.assert_equals(
        { encode.recode('abc', ' x-unknown ') },
        { nil, 'кодировка «x-unknown» неизвестна' }
    )
end

g.test_bytes_that_the_charset_does_not_have_are_a_refusal = function()
    -- 0x98 в cp1251 не назначен: письмо с ним — не cp1251 либо битое.
    t.assert_equals(
        { encode.recode('a\152b', 'windows-1251') },
        { nil, 'в тексте есть байты не из кодировки windows-1251' }
    )
end

g.test_windows_header_is_read_in_utf8 = function()
    -- Тема из Windows: base64 от байтов cp1251, а не от UTF-8.
    t.assert_equals(encode.unheader('=?windows-1251?B?z/Do4uXy?='), 'Привет')
    t.assert_equals(encode.unheader('=?Windows-1251?b?z/Do4uXy?='), 'Привет')
    t.assert_equals(encode.unheader('Re: =?windows-1251?B?z/Do4uXy?= lag'), 'Re: Привет lag')
end

g.test_koi8_header_in_quoted_printable_is_read_in_utf8 = function()
    t.assert_equals(encode.unheader('=?koi8-r?Q?=F0=D2=C9=D7=C5=D4?='), 'Привет')
    t.assert_equals(encode.unheader('=?koi8-r?Q?=EF=D4=DE=A3=D4_=CF_=D3=C2=CF=C5?='), 'Отчёт о сбое')
end

g.test_pieces_in_different_charsets_are_glued_together = function()
    -- Каждый кусок читается в своей кодировке, и склеиваются они уже
    -- текстом: пробел между кусками по-прежнему не часть текста.
    t.assert_equals(
        encode.unheader('=?windows-1251?B?z/Do4uXy?= =?koi8-r?B?IPDSydfF1A==?= =?UTF-8?B?INCf0YDQuNCy0LXRgg==?='),
        'Привет Привет Привет'
    )
end

g.test_piece_in_an_unknown_charset_stays_as_it_came = function()
    -- Байты незнакомой кодировки превратили бы тему в кашу, а запись
    -- куска — ASCII, честна и никого дальше не портит (RFC 2047, 6.2).
    local piece = '=?x-unknown?B?z/Do4uXy?='

    t.assert_equals(encode.unheader(piece), piece)
    t.assert_equals(encode.unheader('Re: ' .. piece .. ' lag'), 'Re: ' .. piece .. ' lag')
    t.assert_equals(encode.unheader('=?x-unknown?Q?=CF=F0?='), '=?x-unknown?Q?=CF=F0?=')
end

g.test_piece_with_bytes_not_of_its_charset_stays_as_it_came = function()
    -- 0x98 в cp1251 не назначен: кусок битый, и соседний кусок от этого
    -- не страдает.
    t.assert_equals(
        encode.unheader('=?windows-1251?B?z/Do4uXy?= =?windows-1251?B?mA==?='),
        'Привет=?windows-1251?B?mA==?='
    )
end

g.test_body_is_wrapped_to_lines = function()
    -- Строка длиннее 998 байт — то, что почтовый сервер вправе обрезать,
    -- и обрежет ровно в письме с длинным текстом.
    local encoded = encode.body(string.rep('а', 500))

    for line in (encoded .. '\r\n'):gmatch('([^\r\n]*)\r\n') do
        t.assert_le(#line, 76)
    end
end

g.test_body_is_read_back_whole = function()
    local text =
        'Первая строка\r\nВторая строка\r\nи точка на своей строке:\r\n.\r\n'

    t.assert_equals(encode.unbody(encode.body(text)), text)
end

g.test_unreadable_body_stays_as_it_came = function()
    t.assert_equals(encode.unbody('это не base64 %%%'), 'это не base64 %%%')
end

g.test_quoted_printable_body_is_read_back = function()
    t.assert_equals(encode.unquoted('=D0=9F=D1=80=D0=B8=D0=B2=D0=B5=D1=82'), 'Привет')
end

g.test_soft_line_breaks_are_removed = function()
    -- Мягкий перенос — знак равенства в конце строки: он не часть текста,
    -- а способ кодировки уложиться в ширину строки.
    t.assert_equals(encode.unquoted('длин=\r\nная'), 'длинная')
    t.assert_equals(encode.unquoted('одна=\nдва'), 'однадва')
end

g.test_plain_text_is_recognised = function()
    t.assert_equals(encode.plain('simple text'), true)
    t.assert_equals(encode.plain('кириллица'), false)
    t.assert_equals(encode.plain('перевод\nстроки'), false)
end

g.test_wrapping_respects_the_width = function()
    t.assert_equals(encode.wrap('abcdef', 2), 'ab\r\ncd\r\nef')
end

g.test_body_of_spaces_alone_is_empty = function()
    -- Тело из одних пробелов в base64 — это пустое тело: переводы строк
    -- внутри кодировки не значат ничего, и разбирать их как байты нельзя.
    t.assert_equals(encode.unbody('   \r\n  '), '')
end

g.test_encoded_header_goes_in_one_line = function()
    -- Заголовок нельзя разбивать по строкам кодировщика: перенос внутри
    -- значения заголовка — это уже следующий заголовок для сервера.
    local header = encode.header(string.rep('длинная тема ', 12))

    t.assert_str_contains(header, '=?UTF-8?B?')
    t.assert_equals(header:find('\n'), nil)
    t.assert_equals(header:find('\r'), nil)
end

g.test_body_is_wrapped_by_seventy_six = function()
    -- Строки тела ровно по семьдесят шесть знаков: столько предписывает
    -- RFC 2045, и столько ждёт разборщик на другой стороне.
    local body = encode.body(string.rep('тело письма ', 40))
    local lines = {}

    for line in (body .. '\r\n'):gmatch('([^\r\n]*)\r\n') do
        table.insert(lines, line)
    end

    t.assert_gt(#lines, 2)

    for index = 1, #lines - 1 do
        t.assert_equals(#lines[index], 76, ('строка %d не той длины'):format(index))
    end

    t.assert_equals(encode.unbody(body), string.rep('тело письма ', 40))
end

g.test_encoded_word_without_a_charset_stays_raw = function()
    -- `=??B?...?=` — кодированное слово без кодировки: разбирать его
    -- нечем, и показать сырым честнее, чем выдать байты за текст.
    local raw = '=??B?0KLQtdC80LA=?='

    t.assert_equals(encode.unheader(raw), raw)
end
