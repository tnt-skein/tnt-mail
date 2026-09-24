--- Тесты сборки письма: заголовки, адреса, дата, части.

local t = require('luatest')

local g = t.group('tnt.mail.message')

local helper = dofile('test/helper.lua')

---@type any
local message

---@type any
local encode

--- Время, на которое собираются письма в проверках.
local AT = 1789041300

g.before_each(function()
    message = helper.load('tnt.mail.message')
    encode = helper.module('tnt.mail.encode')
end)

g.after_each(function()
    helper.unload()
end)

--- Значение заголовка собранного письма.
---@param letter string
---@param name string
---@return string|nil
local function header_of(letter, name)
    return letter:match(('\r\n?%s: ([^\r\n]*)'):format(name)) or letter:match(('^%s: ([^\r\n]*)'):format(name))
end

g.test_letter_has_the_headers_a_server_expects = function()
    local letter = message.build({
        from = 'tarantool@example.org',
        to = 'duty@example.org',
        subject = 'Отчёт',
        text = 'Тело',
    }, AT)

    t.assert_equals(header_of(letter, 'From'), 'tarantool@example.org')
    t.assert_equals(header_of(letter, 'To'), 'duty@example.org')
    t.assert_equals(header_of(letter, 'MIME%-Version'), '1.0')
    t.assert_str_contains(header_of(letter, 'Content%-Type'), 'text/plain; charset=UTF-8')
    t.assert_str_contains(header_of(letter, 'Message%-ID'), '@')
end

g.test_subject_with_russian_is_encoded = function()
    local letter = message.build({ from = 'a@b', to = 'c@d', subject = 'Реплика отстала' }, AT)

    local subject = assert(header_of(letter, 'Subject'), 'заголовка темы нет')

    t.assert_str_contains(subject, '=?UTF-8?B?')
    t.assert_equals(encode.unheader(subject), 'Реплика отстала')
end

g.test_date_is_english_whatever_the_locale = function()
    -- Имена дней и месяцев зависят от локали процесса, и на узле
    -- с русской локалью письмо уехало бы с датой, которую не разберёт
    -- никто.
    t.assert_equals(message.date(AT), 'Thu, 10 Sep 2026 11:55:00 +0000')
end

g.test_name_of_the_sender_is_encoded_and_the_address_stays_bare = function()
    local letter = message.build({
        from = { name = 'Узел storage-001-a', address = 'tarantool@example.org' },
        to = 'duty@example.org',
    }, AT)

    local from = header_of(letter, 'From')

    t.assert_str_contains(from, '=?UTF-8?B?')
    t.assert_str_contains(from, '<tarantool@example.org>')
end

g.test_several_recipients_are_listed_and_returned = function()
    local letter = {
        from = 'a@b',
        to = { 'first@example.org', { name = 'Второй', address = 'second@example.org' } },
        cc = 'third@example.org',
        bcc = 'hidden@example.org',
    }

    t.assert_equals(message.recipients(letter), {
        'first@example.org',
        'second@example.org',
        'third@example.org',
        'hidden@example.org',
    })
end

g.test_hidden_recipients_stay_out_of_the_headers = function()
    -- Скрытые получатели на то и скрытые: в конверт протокола они
    -- попадут, а в заголовки — нет.
    local letter = message.build({ from = 'a@b', to = 'c@d', bcc = 'hidden@example.org' }, AT)

    t.assert_equals(letter:find('hidden@example.org', 1, true), nil)
    t.assert_str_contains(header_of(letter, 'To'), 'c@d')
end

g.test_copy_recipients_are_named_in_the_headers = function()
    local letter = message.build({ from = 'a@b', to = 'c@d', cc = 'watch@example.org' }, AT)

    t.assert_equals(header_of(letter, 'Cc'), 'watch@example.org')
end

g.test_bare_address_drops_the_name = function()
    -- В конверте протокола имени не бывает: там ровно адрес.
    t.assert_equals(message.bare('Дежурный <duty@example.org>'), 'duty@example.org')
    t.assert_equals(message.bare({ name = 'Дежурный', address = 'duty@example.org' }), 'duty@example.org')
    t.assert_equals(message.bare('duty@example.org'), 'duty@example.org')
end

g.test_html_letter_carries_both_parts = function()
    -- Почтовые программы показывают последнюю часть, которую умеют,
    -- а те, что не умеют ничего, — первую.
    local letter = message.build({
        from = 'a@b',
        to = 'c@d',
        text = 'Простой текст',
        html = '<p>Разметка</p>',
    }, AT)

    t.assert_str_contains(header_of(letter, 'Content%-Type'), 'multipart/alternative')
    t.assert_str_contains(letter, 'text/plain; charset=UTF-8')
    t.assert_str_contains(letter, 'text/html; charset=UTF-8')

    local kind = assert(header_of(letter, 'Content%-Type'), 'заголовка типа нет')
    local boundary = kind:match('boundary="([^"]+)"')

    t.assert_not_equals(boundary, nil)
    t.assert_str_contains(letter, ('--%s--'):format(boundary))
end

g.test_own_headers_are_added = function()
    local letter = message.build({
        from = 'a@b',
        to = 'c@d',
        headers = { ['X-Cluster'] = 'storage-001' },
    }, AT)

    t.assert_equals(header_of(letter, 'X%-Cluster'), 'storage-001')
end

g.test_own_identifier_and_date_win = function()
    -- Письмо, собранное заранее и отправленное позже, не должно менять
    -- ни дату, ни опознаватель: по ним его узнают у получателя.
    local letter = message.build({
        from = 'a@b',
        to = 'c@d',
        date = 'Mon, 01 Jan 2001 00:00:00 +0000',
        message_id = '<свой@узел>',
    }, AT)

    t.assert_equals(header_of(letter, 'Date'), 'Mon, 01 Jan 2001 00:00:00 +0000')
    t.assert_equals(header_of(letter, 'Message%-ID'), '<свой@узел>')
end

g.test_addresses_of_a_single_table_stay_single = function()
    t.assert_equals(
        message.addresses({ name = 'Один', address = 'one@example.org' }),
        '=?UTF-8?B?0J7QtNC40L0=?= <one@example.org>'
    )
end

g.test_address_without_a_name_is_written_bare = function()
    -- Адрес, у которого имени нет вовсе: писать «<a@b>» незачем.
    t.assert_equals(message.address({ address = 'duty@example.org' }), 'duty@example.org')
end

g.test_identifier_of_the_letter_has_the_usual_shape = function()
    -- Message-ID — угловые скобки, ULID, собака и узел. По нему письма
    -- сшивают в переписку, и форма здесь не украшение.
    local letter = message.build({ from = 'a@b', to = 'c@d' }, AT)
    local id = assert(header_of(letter, 'Message%-ID'), 'опознавателя нет')

    -- Сразу после скобки идёт ULID: лишний знак между ними сервер вправе
    -- счесть испорченным опознавателем.
    t.assert_str_matches(id, '<' .. ('[0-9A-HJKMNP-TV-Z]'):rep(26) .. '@tarantool>')
    t.assert_equals(helper.module('tnt.id').is_ulid(id:sub(2, 27)), true)

    local named = message.build({ from = 'a@b', to = 'c@d', origin = 'storage-001-a' }, AT)

    t.assert_str_matches(assert(header_of(named, 'Message%-ID')), '<%w+@storage%-001%-a>')
end

g.test_identifier_of_the_letter_is_a_ulid_of_the_moment_it_was_built = function()
    -- Время в старших знаках — миг сборки, а не время письма: письмо,
    -- собранное заранее, получает дату составления, а идентификатор
    -- по-прежнему идёт в порядке выдачи. Следующее письмо той же
    -- миллисекунды — следующий ULID, а не тот же.
    helper.module('tnt.id')._set_source({
        now = function()
            return 1789237800123
        end,
        random = function(count)
            return string.rep('\0', count)
        end,
    })

    local first = message.build({ from = 'a@b', to = 'c@d' }, AT)
    local second = message.build({ from = 'a@b', to = 'c@d', origin = 'узел' }, AT)

    t.assert_equals(header_of(first, 'Message%-ID'), '<01M2BE4B5V0000000000000000@tarantool>')
    t.assert_equals(header_of(second, 'Message%-ID'), '<01M2BE4B5V0000000000000001@узел>')
end

g.test_boundary_is_marked_as_ours = function()
    -- Граница начинается с `tnt-`: увидев её в чужом письме, человек
    -- должен понять, чья это программа.
    local letter = message.build({
        from = 'a@b',
        to = 'c@d',
        text = 'текст',
        html = '<p>разметка</p>',
    }, AT)

    local kind = assert(header_of(letter, 'Content%-Type'), 'заголовка типа нет')
    local boundary = assert(kind:match('boundary="([^"]+)"'), 'границы нет')

    t.assert_equals(boundary:sub(1, 4), 'tnt-')
    t.assert_str_contains(letter, ('--%s'):format(boundary))
end

g.test_several_recipients_go_in_one_header = function()
    -- Получателей несколько: они едут одной строкой через запятую,
    -- а не теряются по дороге.
    local letter = message.build({
        from = 'a@b',
        to = { 'first@example.org', { name = 'Второй', address = 'second@example.org' } },
    }, AT)

    local to = assert(header_of(letter, 'To'), 'получателей нет')

    t.assert_str_contains(to, 'first@example.org')
    t.assert_str_contains(to, 'second@example.org')
    t.assert_str_contains(to, ', ')
end

g.test_address_in_angle_brackets_is_taken_whole = function()
    -- Из «Имя <адрес>» берётся ровно то, что внутри скобок, целиком:
    -- адрес со знаком равенства — обычный адрес, а не половина адреса.
    t.assert_equals(message.bare('Служба <robot=daily@example.org>'), 'robot=daily@example.org')
    t.assert_equals(message.bare('Странный <a<b@example.org>'), 'a<b@example.org')
end

g.test_empty_angle_brackets_are_not_an_address = function()
    -- «Имя <>» — не адрес: подставлять вместо него пустоту значит
    -- отправить письмо в никуда и не узнать об этом.
    t.assert_equals(message.bare('Никто <>'), 'Никто <>')
end

--- Части собранного письма по внешней границе, без заголовков письма.
---@param letter string
---@return string[]
local function parts_of(letter)
    local kind = assert(header_of(letter, 'Content%-Type'), 'заголовка типа нет')
    local edge = assert(kind:match('boundary="([^"]+)"'), 'границы нет')
    local found = {}
    local mark = ('\r\n--%s'):format(edge)
    local from = assert(letter:find(mark, 1, true), 'первой границы нет')

    -- Границы ищутся как текст, а не как образец: в них дефисы,
    -- а дефис в образце Lua значит повтор.
    while true do
        local start = from + #mark + 2
        local next_start = letter:find(mark, start, true)

        if next_start == nil then
            return found
        end

        table.insert(found, letter:sub(start, next_start - 1))

        from = next_start
    end
end

g.test_attachment_makes_the_letter_mixed = function()
    -- Вложение — отдельная часть `multipart/mixed`: первой едет само
    -- письмо, дальше файл с именем в размещении и в base64.
    local letter = assert(message.build({
        from = 'a@b',
        to = 'c@d',
        text = 'см. вложение',
        attachments = { { name = 'report.csv', type = 'text/csv', content = 'a,b\r\n1,2\r\n' } },
    }, AT))

    t.assert_str_contains(header_of(letter, 'Content%-Type'), 'multipart/mixed; boundary="tnt-')
    t.assert_equals(header_of(letter, 'MIME%-Version'), '1.0')

    local parts = parts_of(letter)

    t.assert_equals(#parts, 2)
    t.assert_equals(
        parts[1],
        'Content-Type: text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: base64\r\n\r\n'
            .. encode.body('см. вложение')
    )
    t.assert_equals(
        parts[2],
        'Content-Type: text/csv\r\n'
            .. 'Content-Disposition: attachment; filename="report.csv"\r\n'
            .. 'Content-Transfer-Encoding: base64\r\n\r\n'
            .. 'YSxiDQoxLDINCg=='
    )

    local edge = assert(assert(header_of(letter, 'Content%-Type')):match('boundary="([^"]+)"'))

    t.assert_equals(letter:sub(-#edge - 4), ('--%s--'):format(edge))
end

g.test_markup_with_attachments_nests_alternative_inside_mixed = function()
    -- Текст с разметкой и вложением: снаружи mixed, внутри первой частью
    -- alternative с обоими видами текста, вложения — рядом с ним,
    -- а не внутри: иначе почтовая программа показала бы вложение
    -- вместо разметки.
    local letter = assert(message.build({
        from = 'a@b',
        to = 'c@d',
        text = 'текст',
        html = '<p>разметка</p>',
        attachments = {
            { name = 'one.txt', type = 'text/plain', content = '1' },
            { name = 'two.txt', type = 'text/plain', content = '2' },
        },
    }, AT))

    t.assert_str_contains(header_of(letter, 'Content%-Type'), 'multipart/mixed')

    local parts = parts_of(letter)

    t.assert_equals(#parts, 3)
    t.assert_str_contains(parts[1], 'Content-Type: multipart/alternative; boundary="tnt-')
    t.assert_str_contains(parts[1], 'Content-Type: text/plain; charset=UTF-8')
    t.assert_str_contains(parts[1], 'Content-Type: text/html; charset=UTF-8')
    t.assert_str_contains(parts[2], 'filename="one.txt"')
    t.assert_str_contains(parts[3], 'filename="two.txt"')

    local inner = assert(assert(parts[1]):match('boundary="([^"]+)"'))

    t.assert_str_contains(parts[1], ('--%s--'):format(inner))
    t.assert_not_equals(inner, assert(header_of(letter, 'Content%-Type')):match('boundary="([^"]+)"'))
end

g.test_attachment_without_a_type_is_octets = function()
    -- Тип не назвали — октеты без толкования: почтовая программа
    -- предложит сохранить файл, а не покажет его как текст.
    local letter = assert(message.build({
        from = 'a@b',
        to = 'c@d',
        attachments = { { name = 'dump.bin', content = '\0\255\0' } },
    }, AT))

    t.assert_str_contains(letter, 'Content-Type: application/octet-stream\r\n')
    t.assert_str_contains(letter, '\r\n\r\nAP8A\r\n')
end

g.test_attachment_is_wrapped_by_lines_like_the_body = function()
    -- Длинное вложение режется на строки по 76 знаков: строку длиннее
    -- 998 байт почтовый сервер вправе обрезать.
    local letter = assert(message.build({
        from = 'a@b',
        to = 'c@d',
        attachments = { { name = 'long.bin', content = ('x'):rep(200) } },
    }, AT))

    local packed = assert(assert(parts_of(letter)[2]):match('\r\n\r\n(.*)$'))

    t.assert_equals(packed, encode.body(('x'):rep(200)))
    t.assert_equals(#assert(packed:match('^[^\r\n]+')), 76)
end

g.test_attachment_name_outside_ascii_goes_by_rfc_2231 = function()
    -- Кириллица в имени не вставляется как есть и не кодируется словом
    -- RFC 2047 в кавычках: имя свойства — по RFC 2231, где каждый байт
    -- вне букв и цифр записан шестнадцатеричной парой.
    local letter = assert(message.build({
        from = 'a@b',
        to = 'c@d',
        attachments = { { name = 'отчёт за день.csv', content = '' } },
    }, AT))

    t.assert_str_contains(
        letter,
        "Content-Disposition: attachment; filename*=UTF-8''"
            .. '%D0%BE%D1%82%D1%87%D1%91%D1%82%20%D0%B7%D0%B0%20%D0%B4%D0%B5%D0%BD%D1%8C.csv\r\n'
    )

    -- Буквы, цифры, точка, дефис и подчёркивание остаются собой,
    -- всё прочее — включая плюс — уходит парой: `+` в ссылках значит
    -- пробел, и имя с ним прочли бы иначе.
    local mixed = assert(message.build({
        from = 'a@b',
        to = 'c@d',
        attachments = { { name = 'за 2026-09-14_v2+final(1).csv', content = '' } },
    }, AT))

    t.assert_str_contains(mixed, "filename*=UTF-8''%D0%B7%D0%B0%202026-09-14_v2%2Bfinal%281%29.csv\r\n")
end

g.test_quote_in_the_name_leaves_the_quotes = function()
    -- Кавычка и обратная косая в имени из ASCII разорвали бы кавычки
    -- свойства: такое имя тоже уходит расширенным видом.
    local letter = assert(message.build({
        from = 'a@b',
        to = 'c@d',
        attachments = {
            { name = 'say "hi".txt', content = '' },
            { name = 'back\\slash.txt', content = '' },
            { name = 'plain-name_1.txt', content = '' },
        },
    }, AT))

    t.assert_str_contains(letter, "filename*=UTF-8''say%20%22hi%22.txt\r\n")
    t.assert_str_contains(letter, "filename*=UTF-8''back%5Cslash.txt\r\n")
    t.assert_str_contains(letter, 'filename="plain-name_1.txt"\r\n')
end

g.test_line_break_in_the_name_does_not_become_a_header = function()
    -- Перевод строки в имени — попытка дописать заголовок: он уезжает
    -- шестнадцатеричной парой, и заголовка из него не выходит.
    local letter = assert(message.build({
        from = 'a@b',
        to = 'c@d',
        attachments = { { name = 'x.txt\r\nX-Evil: 1', content = '' } },
    }, AT))

    t.assert_equals(letter:find('\r\nX-Evil', 1, true), nil)
    t.assert_str_contains(letter, "filename*=UTF-8''x.txt%0D%0AX-Evil%3A%201\r\n")
end

g.test_attachments_that_are_not_a_list_are_refused = function()
    -- Не список — отказ парой до сборки, а не письмо без вложения:
    -- получатель ждёт отчёт, а не письмо о том, что отчёт был.
    local letter, err = message.build({ from = 'a@b', to = 'c@d', attachments = 'report.csv' }, AT)

    t.assert_equals(letter, nil)
    t.assert_equals(err, 'вложения должны быть списком, а не string')

    local second, second_err = message.build({ from = 'a@b', to = 'c@d', attachments = { 'report.csv' } }, AT)

    t.assert_equals(second, nil)
    t.assert_equals(second_err, 'вложение №1 должно быть таблицей, а не string')
end

g.test_attachment_without_a_name_or_content_is_refused = function()
    local refusals = {
        {
            { { name = 'ok.txt', content = 'x' }, { content = 'x' } },
            'вложение №2: имя не задано',
        },
        { { { name = '', content = 'x' } }, 'вложение №1: имя не задано' },
        { { { name = 7, content = 'x' } }, 'вложение №1: имя не задано' },
        {
            { { name = 'ok.txt' } },
            'вложение №1: содержимое должно быть строкой, а не nil',
        },
        {
            { { name = 'ok.txt', content = 42 } },
            'вложение №1: содержимое должно быть строкой, а не number',
        },
    }

    for _, case in ipairs(refusals) do
        local letter, err = message.build({ from = 'a@b', to = 'c@d', attachments = case[1] }, AT)

        t.assert_equals(letter, nil)
        t.assert_equals(err, case[2])
    end
end

g.test_attachment_type_must_look_like_a_media_type = function()
    -- Тип уходит в заголовок как есть: без косой это не тип,
    -- а с переводом строки — ещё один заголовок, которого никто
    -- не писал. В причине управляющие знаки показаны точкой.
    local refusals = {
        { 'csv', 'вложение №1: тип «csv» не похож на тип содержимого' },
        {
            'text/plain\r\nX-Evil: 1',
            'вложение №1: тип «text/plain..X-Evil: 1» не похож на тип содержимого',
        },
        { '', 'вложение №1: тип «» не похож на тип содержимого' },
        { '/plain', 'вложение №1: тип «/plain» не похож на тип содержимого' },
        { 'text/', 'вложение №1: тип «text/» не похож на тип содержимого' },
        {
            '\ttext/plain',
            'вложение №1: тип «.text/plain» не похож на тип содержимого',
        },
    }

    for _, case in ipairs(refusals) do
        local letter, err = message.build({
            from = 'a@b',
            to = 'c@d',
            attachments = { { name = 'x', content = '', type = case[1] } },
        }, AT)

        t.assert_equals(letter, nil)
        t.assert_equals(err, case[2])
    end

    local letter = assert(message.build({
        from = 'a@b',
        to = 'c@d',
        attachments = { { name = 'x', content = '', type = 'text/csv; charset=UTF-8' } },
    }, AT))

    t.assert_str_contains(letter, 'Content-Type: text/csv; charset=UTF-8\r\nContent-Disposition')
end

g.test_control_character_in_a_verbatim_field_is_refused = function()
    -- Адреса, опознаватель, дата и свои заголовки уходят как есть,
    -- а адреса — ещё и в команды разговора: перевод строки в адресе
    -- получателя стал бы новой командой серверу, в заголовке — новым
    -- заголовком. Адрес часто приходит из формы, от человека, поэтому
    -- это отказ до сборки. В причине управляющие знаки показаны точкой.
    local refusals = {
        {
            { to = 'duty@example.org\r\nRCPT TO:<evil@example.org>' },
            'адрес в поле to: управляющий знак в «duty@example.org..RCPT TO:<evil@example.org>»',
        },
        {
            { cc = { 'one@example.org', { name = 'Два', address = 'two@example.org\nBcc: evil@example.org' } } },
            'адрес в поле cc: управляющий знак в «two@example.org.Bcc: evil@example.org»',
        },
        {
            { from = { address = 'a@b\r' } },
            'адрес в поле from: управляющий знак в «a@b.»',
        },
        {
            { bcc = { '\tevil@example.org' } },
            'адрес в поле bcc: управляющий знак в «.evil@example.org»',
        },
        {
            { headers = { ['X-Node'] = 'storage\r\nX-Evil: 1' } },
            'заголовок X-Node: управляющий знак в «storage..X-Evil: 1»',
        },
        {
            { headers = { ['X-Evil\nBcc'] = 'x' } },
            'имя заголовка: управляющий знак в «X-Evil.Bcc»',
        },
        { { message_id = '<id@node>\r\n' }, 'поле message_id: управляющий знак в «<id@node>..»' },
        { { date = 'Mon\n' }, 'поле date: управляющий знак в «Mon.»' },
        { { origin = 'storage\0' }, 'поле origin: управляющий знак в «storage.»' },
    }

    for _, case in ipairs(refusals) do
        local given = { from = 'a@b', to = 'c@d', text = 'тело' }

        for key, value in pairs(case[1]) do
            given[key] = value
        end

        local letter, err = message.build(given, AT)

        t.assert_equals(letter, nil, case[2])
        t.assert_equals(err, case[2])
    end

    -- Имя человека, тема и текст кодируются и перевода строки не пронесут:
    -- их проверка не касается.
    local letter = assert(message.build({
        from = { name = 'Узел\r\nBcc: x', address = 'a@b' },
        to = { { address = 'c@d' }, 'Дежурный <e@f>' },
        subject = 'Тема\r\nBcc: x',
        text = 'строка\r\nещё строка',
        headers = { ['X-Node'] = 'storage-001' },
    }, AT))

    t.assert_equals(header_of(letter, 'To'), 'c@d, Дежурный <e@f>')
    t.assert_equals(header_of(letter, 'X%-Node'), 'storage-001')
end

g.test_empty_list_of_attachments_leaves_the_letter_simple = function()
    -- Пустой список — то же, что его отсутствие: письмо остаётся
    -- простым, без обёртки mixed ради ничего.
    local letter = assert(message.build({ from = 'a@b', to = 'c@d', text = 'тело', attachments = {} }, AT))

    t.assert_str_contains(header_of(letter, 'Content%-Type'), 'text/plain; charset=UTF-8')
    t.assert_equals(letter:find('multipart', 1, true), nil)
end
