--- Сборка письма.
---
--- Письмо — это заголовки, пустая строка и тело. Вся сложность в том,
--- что заголовки читают почтовые серверы, а тело — человек, и правила
--- у них разные: в заголовке не бывает не-ASCII без кодирования,
--- а в теле не бывает строк длиннее 998 байт.
---
--- Дата собирается вручную, а не `os.date('%a, %d %b %Y')`: имена дней
--- и месяцев зависят от локали процесса, и на узле с русской локалью
--- письмо уедет с датой «Чт, 01 янв 2026», которую не разберёт никто.
---
--- Идентификатор письма ставится всегда. Без него почтовые серверы
--- выдумывают его сами, и два письма, отправленные одним узлом в одну
--- секунду, слипаются в цепочку у получателя.
---
--- Идентификатор — ULID из `tnt-id`, а не `uuid` четвёртой версии: время
--- в старших знаках, и письма узла по нему идут в порядке сборки, а сам он
--- на десять знаков короче. Время, которое ULID выдаёт, тайной не бывает:
--- оно и так стоит в заголовке `Date`. Граница частей, наоборот, остаётся
--- четвёртой версией — почему, сказано у неё.
---
--- Вложения едут частями `multipart/mixed`: первой — само письмо
--- (текст либо текст с разметкой), дальше по части на вложение. Каждое
--- вложение — base64 с именем в `Content-Disposition`; имя не из ASCII
--- кодируется по RFC 2231, а не вставляется как есть: перевод строки
--- в имени иначе стал бы новым заголовком.

local uuid = require('uuid')

local id = require('tnt.id')

local encode = require('tnt.mail.encode')

local Module = {}

--- Дни недели и месяцы по RFC 5322: только по-английски и только так.
local DAYS = { 'Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat' }
local MONTHS = {
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
}

--- Дата в виде, который понимают почтовые серверы.
---
--- Время берётся в UTC и подписывается `+0000`: местный сдвиг
--- на узле в контейнере всё равно нулевой, а перевод часов на сервере
--- не должен менять вид письма.
---@param at number|nil Время в секундах эпохи
---@return string
function Module.date(at)
    local moment = os.date('!*t', at or os.time())

    return ('%s, %02d %s %04d %02d:%02d:%02d +0000'):format(
        DAYS[moment.wday],
        moment.day,
        MONTHS[moment.month],
        moment.year,
        moment.hour,
        moment.min,
        moment.sec
    )
end

--- Адрес в виде «Имя <адрес>» или просто «адрес».
---@param address string|{ name: string|nil, address: string }
---@return string
function Module.address(address)
    if type(address) ~= 'table' then
        return tostring(address)
    end

    if address.name == nil then
        return tostring(address.address)
    end

    return ('%s <%s>'):format(encode.header(address.name), tostring(address.address))
end

--- Список адресов через запятую.
---@param addresses any
---@return string
function Module.addresses(addresses)
    if type(addresses) ~= 'table' or addresses.address ~= nil then
        return Module.address(addresses)
    end

    local parts = {}

    for _, address in ipairs(addresses) do
        table.insert(parts, Module.address(address))
    end

    return table.concat(parts, ', ')
end

--- Только сам адрес, без имени.
---
--- Нужен протоколу: в конверте (`MAIL FROM`, `RCPT TO`) имени не бывает,
--- там ровно адрес в угловых скобках.
---@param address string|{ address: string }
---@return string
function Module.bare(address)
    if type(address) == 'table' then
        return tostring(address.address)
    end

    -- Имя отрезается по угловым скобкам: «Дежурный <duty@example.org>»
    -- в конверте означает адрес, а не строку целиком.
    local inside = tostring(address):match('<([^>]+)>')

    return inside or tostring(address)
end

--- Все адреса получателей списком, без имён.
---@param letter table
---@return string[]
function Module.recipients(letter)
    local found = {}

    for _, field in ipairs({ 'to', 'cc', 'bcc' }) do
        local value = letter[field]

        if type(value) == 'table' and value.address == nil then
            for _, address in ipairs(value) do
                table.insert(found, Module.bare(address))
            end
        elseif value ~= nil then
            table.insert(found, Module.bare(value))
        end
    end

    return found
end

--- Граница частей многочастного письма.
---
--- Случайная: граница, встретившаяся в теле, разрезала бы письмо
--- посередине, и вероятность этого должна быть не «маленькой»,
--- а никакой.
---
--- Поэтому четвёртая версия, а не ULID, как у идентификатора письма.
--- Порядок границе не нужен, а угадать её должно быть нечем: у ULID
--- время известно, а соседний в ту же миллисекунду отличается шагом
--- не больше 2³², тогда как у четвёртой версии неизвестны все 122 бита.
---@return string
local function boundary()
    return ('tnt-%s'):format(uuid.str())
end

--- Одна часть многочастного письма.
---@param kind string Тип содержимого
---@param text string
---@return string
local function part(kind, text)
    return table.concat({
        ('Content-Type: %s; charset=UTF-8'):format(kind),
        'Content-Transfer-Encoding: base64',
        '',
        encode.body(text),
    }, '\r\n')
end

--- Тип вложения, когда его не назвали.
---
--- Октеты без толкования: почтовая программа предложит сохранить файл,
--- а не станет показывать его как текст.
local DEFAULT_TYPE = 'application/octet-stream'

--- Имя вложения в виде свойства заголовка `Content-Disposition`.
---
--- Печатное ASCII без кавычки и обратной косой идёт в кавычках как есть.
--- Всё остальное — по RFC 2231 (`filename*=UTF-8''...`), где каждый байт
--- вне букв и цифр записан шестнадцатеричной парой: кириллица доезжает
--- именем, а перевод строки не становится новым заголовком.
---@param name string
---@return string
local function filename_of(name)
    if encode.plain(name) and name:find('["\\]') == nil then
        return ('filename="%s"'):format(name)
    end

    local escaped = name:gsub('[^A-Za-z0-9%.%-_]', function(char)
        return ('%%%02X'):format(char:byte())
    end)

    return ("filename*=UTF-8''%s"):format(escaped)
end

--- Часть с вложением.
---
--- Base64 всегда, как и тело: вложение — чаще всего не текст, а у текста
--- всё равно нашлась бы строка длиннее 998 байт или точка в начале.
---@param attachment { name: string, type: string|nil, content: string }
---@return string
local function attachment_part(attachment)
    return table.concat({
        ('Content-Type: %s'):format(attachment.type or DEFAULT_TYPE),
        ('Content-Disposition: attachment; %s'):format(filename_of(attachment.name)),
        'Content-Transfer-Encoding: base64',
        '',
        encode.body(attachment.content),
    }, '\r\n')
end

--- Похоже ли значение на тип содержимого: без управляющих знаков,
--- с косой не с краю. Строже не нужно — тип уходит в заголовок как есть,
--- и проверка здесь от чужого заголовка, а не от опечатки.
---@param value string
---@return boolean
local function media_type(value)
    return value:find('%c') == nil and value:find('^.+/.') ~= nil
end

--- Проверяет вложения письма и отдаёт их списком.
---
--- Проверка до сборки, а не по ходу: письмо с негодным вложением
--- не должно уехать без него — получатель ждёт отчёт, а не письмо
--- о том, что отчёт был.
---@param letter table
---@return table[]|nil attachments
---@return string|nil err
local function attachments_of(letter)
    local given = letter.attachments

    if given == nil then
        return {}
    end

    if type(given) ~= 'table' then
        return nil, ('вложения должны быть списком, а не %s'):format(type(given))
    end

    for index, attachment in ipairs(given) do
        if type(attachment) ~= 'table' then
            return nil,
                ('вложение №%d должно быть таблицей, а не %s'):format(
                    index,
                    type(attachment)
                )
        end

        if type(attachment.name) ~= 'string' or attachment.name == '' then
            return nil, ('вложение №%d: имя не задано'):format(index)
        end

        if type(attachment.content) ~= 'string' then
            return nil,
                ('вложение №%d: содержимое должно быть строкой, а не %s'):format(
                    index,
                    type(attachment.content)
                )
        end

        -- Тип уходит в заголовок как есть, поэтому вид проверяется
        -- заранее: без косой это не тип, а с управляющим знаком —
        -- ещё один заголовок, которого никто не писал. В причине
        -- управляющие знаки показаны точкой: строка причины идёт
        -- в журнал, и рвать его тем же переводом строки незачем.
        if attachment.type ~= nil and not media_type(tostring(attachment.type)) then
            return nil,
                ('вложение №%d: тип «%s» не похож на тип содержимого'):format(
                    index,
                    (tostring(attachment.type):gsub('%c', '.'))
                )
        end
    end

    return given
end

--- Что из письма уходит в заголовки и в команды разговора как есть.
---
--- Адреса, опознаватель, дата, подпись опознавателя и свои заголовки
--- не кодируются: в них и так должен стоять печатный ASCII. Имена людей,
--- тема, текст и вложения сюда не входят — они кодируются и перевода
--- строки не пронесут.
---@param letter table
---@return any[][] Пары «что это — значение»
local function verbatim(letter)
    local found = {}

    for _, field in ipairs({ 'from', 'to', 'cc', 'bcc' }) do
        local value = letter[field]
        local list = value

        if type(value) ~= 'table' or value.address ~= nil then
            list = { value }
        end

        for _, address in ipairs(list) do
            local text = type(address) == 'table' and address.address or address

            table.insert(found, { 'адрес в поле ' .. field, text })
        end
    end

    for name, value in pairs(letter.headers or {}) do
        table.insert(found, { 'имя заголовка', name })
        table.insert(found, { ('заголовок %s'):format(tostring(name)), value })
    end

    for _, field in ipairs({ 'message_id', 'date', 'origin' }) do
        table.insert(found, { 'поле ' .. field, letter[field] })
    end

    return found
end

--- Первое значение, которое уйдёт как есть и несёт управляющий знак.
---
--- Перевод строки в адресе получателя — это новая команда серверу,
--- в заголовке — новый заголовок, которого никто не писал. Адрес часто
--- приходит от человека, из формы, поэтому это отказ до сборки, а не
--- починка: исправленный адрес — уже не тот, что дали. В причине
--- управляющие знаки показаны точкой: она идёт в журнал.
---@param letter table
---@return string|nil refusal
local function tainted(letter)
    for _, pair in ipairs(verbatim(letter)) do
        local text = tostring(pair[2])

        if text:find('%c') ~= nil then
            return ('%s: управляющий знак в «%s»'):format(pair[1], (text:gsub('%c', '.')))
        end
    end

    return nil
end

--- Заголовки письма по порядку.
---@param letter table
---@param at number|nil
---@return string[][]
local function headers_of(letter, at)
    local fields = {
        { 'From', Module.addresses(letter.from) },
        { 'To', Module.addresses(letter.to) },
    }

    if letter.cc ~= nil then
        table.insert(fields, { 'Cc', Module.addresses(letter.cc) })
    end

    -- Скрытых получателей в заголовках нет намеренно: они на то
    -- и скрытые, а в конверт протокола попадут.
    table.insert(fields, { 'Subject', encode.header(letter.subject or '') })
    table.insert(fields, { 'Date', letter.date or Module.date(at) })
    table.insert(fields, {
        'Message-ID',
        letter.message_id or ('<%s@%s>'):format(id.ulid(), letter.origin or 'tarantool'),
    })
    table.insert(fields, { 'MIME-Version', '1.0' })

    for name, value in pairs(letter.headers or {}) do
        table.insert(fields, { tostring(name), tostring(value) })
    end

    return fields
end

--- Содержание письма без вложений: строки от типа до тела.
---
--- Тело кодируется base64 всегда: оно ничего не ломает, тогда как
--- восьмибитный текст на пути через чужой сервер превращается
--- в вопросительные знаки, а quoted-printable разрывает строки там,
--- где ему удобно.
---@param letter table
---@return string[]
local function content_of(letter)
    if letter.html == nil then
        return {
            'Content-Type: text/plain; charset=UTF-8',
            'Content-Transfer-Encoding: base64',
            '',
            encode.body(letter.text or ''),
        }
    end

    -- Две части, и простая первой: почтовые программы показывают
    -- последнюю, которую умеют, а те, что не умеют ничего, — первую.
    local edge = boundary()
    local opening = ('--%s'):format(edge)
    local closing = ('--%s--'):format(edge)

    return {
        ('Content-Type: multipart/alternative; boundary="%s"'):format(edge),
        '',
        opening,
        part('text/plain', letter.text or ''),
        opening,
        part('text/html', letter.html),
        closing,
    }
end

--- Собирает письмо целиком.
---
--- С вложениями письмо становится `multipart/mixed`: первой частью —
--- всё письмо, каким оно было бы без них, дальше по части на вложение.
--- Негодное вложение — отказ парой: письмо без него не собирается.
--- Так же отказом встречается управляющий знак в том, что уходит как
--- есть: в адресе, опознавателе, дате и своих заголовках.
---@param letter table
---@param at number|nil Когда письмо составлено
---@return string|nil
---@return string|nil err
function Module.build(letter, at)
    local attachments, err = attachments_of(letter)

    if attachments == nil then
        return nil, err
    end

    local refusal = tainted(letter)

    if refusal ~= nil then
        return nil, refusal
    end

    local lines = {}

    for _, field in ipairs(headers_of(letter, at)) do
        table.insert(lines, ('%s: %s'):format(field[1], field[2]))
    end

    local content = content_of(letter)

    if #attachments == 0 then
        for _, line in ipairs(content) do
            table.insert(lines, line)
        end

        return table.concat(lines, '\r\n')
    end

    local edge = boundary()

    table.insert(lines, ('Content-Type: multipart/mixed; boundary="%s"'):format(edge))
    table.insert(lines, '')
    table.insert(lines, ('--%s'):format(edge))
    table.insert(lines, table.concat(content, '\r\n'))

    for _, attachment in ipairs(attachments) do
        table.insert(lines, ('--%s'):format(edge))
        table.insert(lines, attachment_part(attachment))
    end

    table.insert(lines, ('--%s--'):format(edge))

    return table.concat(lines, '\r\n')
end

return Module
