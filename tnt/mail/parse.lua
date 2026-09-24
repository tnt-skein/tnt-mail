--- Разбор письма.
---
--- Письмо составляем не только мы: то, что приходит по POP3 и IMAP,
--- собрано чужими программами и по чужим привычкам. Поэтому разбор
--- терпелив: неизвестная кодировка, оборванная граница, заголовок
--- без значения — всё это не повод отказаться от письма целиком.
--- Непонятая часть остаётся сырой строкой, и её видно.
---
--- Заголовки складываются в таблицу по нижнему регистру имени: регистр
--- в них не значит ничего, а сравнивать `Content-Type` с `content-type`
--- рано или поздно забывают.
---
--- Вложения — части с именем файла или с `Content-Disposition:
--- attachment`. Они не становятся текстом письма, даже если это текст:
--- приложенный журнал — не то, что человек написал в письме.
---
--- Текст частей типа text любого подтипа переводится в UTF-8
--- по объявленной кодировке: письма из Windows приходят в cp1251, и байты
--- её дальше портит всякий, кто считает строку UTF-8. Вложения
--- не переводятся: файл — это байты, и выгрузка для Excel в cp1251 должна
--- доехать cp1251. Не вышло перевести — текст остаётся байтами, а причина
--- ложится в часть: письмо из-за кодировки не отвергается, как и из-за
--- всего остального.

local encode = require('tnt.mail.encode')

local Module = {}

--- Сколько уровней вложенности разбирать.
---
--- Письмо с частями внутри частей — обычное дело (текст плюс вложение,
--- внутри — текст и HTML). Глубже трёх уровней встречается разве что
--- в письмах, пересланных пять раз подряд, а бесконечная рекурсия
--- на кольцевой границе положила бы узел.
local DEPTH = 3

--- Склеивает продолжения заголовков и сводит переводы строк к `\n`.
---
--- Длинный заголовок переносится на следующую строку с отступа —
--- и только так: строка без отступа уже новый заголовок. Перевод строки
--- в чужом письме бывает любым из трёх (`\r\n`, `\n`, одинокий `\r`),
--- и после сведения строки делятся одним разделителем.
---@param text string
---@return string
local function unfold(text)
    local joined = text:gsub('\r?\n[ \t]+', ' ')

    return (joined:gsub('\r\n?', '\n'))
end

--- Делит письмо на заголовки и тело.
---
--- По первой пустой строке, а не по последней: пустые строки в теле —
--- обычное дело, и жадный шаблон отдал бы половину письма в заголовки.
--- Письмо без пустой строки — это письмо из одних заголовков: чаще
--- всего так выглядит часть, у которой тело оборвано по дороге.
---@param raw string
---@return string headers
---@return string body
local function split(raw)
    local text = tostring(raw)
    local head, body = text:match('^(.-)\r?\n\r?\n(.*)$')

    if head == nil then
        return text, ''
    end

    return head, body or ''
end

--- Разбирает заголовки в таблицу.
---@param text string
---@return table<string, string>
local function headers_of(text)
    local headers = {}

    -- Делением, а не обходом образцом `[^\r\n]+`: у образца мутант `*`
    -- добавлял только пустые строки, а их и так отсеивает разбор имени.
    for _, line in ipairs(unfold(text):split('\n')) do
        local name, value = line:match('^([%w%-]+):%s*(.*)$')

        if name ~= nil then
            headers[name:lower()] = encode.unheader(value or '')
        end
    end

    return headers
end

--- Значение и его свойства: `text/plain; charset=UTF-8` → тип и таблица.
---@param value string|nil
---@return string kind
---@return table<string, string> options
local function typed(value)
    local text = tostring(value or 'text/plain')
    local kind = text:match('^%s*([^;]+)')
    local options = {}

    -- Звёздочка в имени свойства — расширенный вид по RFC 2231
    -- (`filename*`): так кодируют имя вложения не из ASCII.
    for name, option in text:gmatch(';%s*([%w%-%*]+)%s*=%s*"?([^";]+)"?') do
        options[name:lower()] = option
    end

    return (kind or 'text/plain'):lower(), options
end

--- Снимает с текста запись `%XX`.
---@param text string
---@return string
local function unpercent(text)
    return (
        text:gsub('%%(%x%x)', function(pair)
            local code = tonumber(pair, 16)

            ---@cast code integer

            return string.char(code)
        end)
    )
end

--- Разбирает значение свойства по RFC 2231: `UTF-8''%D0%9E%D1%82...`.
---
--- Кодировка — до первого апострофа, и имя переводится из неё в UTF-8:
--- из Windows оно приходит `windows-1251''%CE%F2...`. Язык до второго
--- апострофа отбрасывается. Свойство без апострофов — не расширенное,
--- а просто с звёздочкой в имени, и берётся целиком, без перевода.
---@param value string
---@return string|nil Имя в UTF-8; `nil`, если его не перевести
local function extended(value)
    local charset, text = value:match("^([^']*)'[^']*'(.*)$")

    if charset == nil then
        return unpercent(value)
    end

    -- Совпал образец — есть и хвост после второго апострофа, хотя бы
    -- пустой; вывод типов о связи двух захватов не знает.
    ---@cast text string

    return (encode.recode(unpercent(text), charset))
end

--- Имя вложения: расширенное `filename*` первым, затем `filename`,
--- затем `name` из типа содержимого — так его пишут старые программы.
---
--- Расширенное имя, которое не перевести в UTF-8, уступает обычному:
--- `filename` рядом с `filename*` пишут ровно для тех, кто расширенного
--- не понял. Нет и его — имя остаётся записью как пришла: ASCII-строка
--- с кодировкой в начале честнее байтов чужой кодировки.
---@param disposition table<string, string>
---@param options table<string, string>
---@return string|nil
local function name_of(disposition, options)
    local wide = disposition['filename*']

    if wide ~= nil then
        local name = extended(wide)

        if name ~= nil then
            return name
        end
    end

    return disposition.filename or options.name or wide
end

--- Раскодирует тело по указанной кодировке.
---@param body string
---@param encoding string|nil
---@return string
local function decoded(body, encoding)
    local kind = tostring(encoding or ''):lower()

    if kind == 'base64' then
        return encode.unbody(body)
    end

    if kind == 'quoted-printable' then
        return encode.unquoted(body)
    end

    return body
end

--- Режет многочастное тело по границе.
---@param body string
---@param edge string
---@return string[]
local function pieces(body, edge)
    local found = {}
    local mark = '--' .. edge

    -- Обход от найденной границы к следующей: поиск с начала тела идёт
    -- без номера места, у которого мутанты `0` и `1-1` нашли бы то же.
    local start = body:find(mark, nil, true)

    while start ~= nil do
        local after = start + #mark

        -- Закрывающая граница кончается двумя дефисами: всё, что после
        -- неё, — не часть письма, а хвост, который иногда дописывают
        -- почтовые серверы.
        if body:sub(after, after + 1) == '--' then
            break
        end

        local next_start = body:find(mark, after, true)

        -- Без границы впереди часть тянется до конца тела: так выглядит
        -- письмо, оборванное на полуслове, и терять последнюю часть
        -- из-за недописанной границы незачем.
        local piece = next_start ~= nil and body:sub(after, next_start - 1) or body:sub(after)

        table.insert(found, (piece:gsub('^\r?\n', ''):gsub('\r?\n$', '')))

        start = next_start
    end

    return found
end

--- Вложение ли эта часть.
---
--- Вложение — то, что положили рядом с письмом: часть, объявленная
--- вложением, либо часть с именем файла. Имя решает и для `inline`:
--- так вложения шлёт рок smtp, и терять их из-за слова незачем.
---@param part table
---@return boolean
local function attached(part)
    return part.body ~= nil and (part.disposition == 'attachment' or part.name ~= nil)
end

--- Разбирает письмо или его часть.
---
--- Уровень вложенности передаётся всегда: умолчание здесь означало бы,
--- что где-то есть вызов без него, и предел глубины считался бы от него
--- заново.
---@param raw string
---@param depth integer
---@return table
local function parse(raw, depth)
    local head, body = split(raw)

    -- Через промежуточную ссылку: заголовки приходят из чужого письма,
    -- и вывод типов знает о них ровно столько же, сколько мы, — ничего.
    ---@type any
    local headers = headers_of(head)
    local kind, options = typed(headers['content-type'])

    -- Размещение разбирается тем же разборщиком, что и тип: у них
    -- одна форма — слово и свойства через точку с запятой.
    local disposition, marks = nil, {}

    if headers['content-disposition'] ~= nil then
        disposition, marks = typed(headers['content-disposition'])
    end

    local part = {
        headers = headers,
        kind = kind,
        charset = options.charset,
        disposition = disposition,
        name = name_of(marks, options),

        -- Свойства типа едут целиком: кодировка нужна всем, а имя
        -- вложения (`name`) и граница (`boundary`) — тому, кто станет
        -- разбирать письмо дальше нашего.
        options = options,
        parts = {},
    }

    if kind:find('^multipart/') ~= nil and options.boundary ~= nil and depth < DEPTH then
        for _, piece in ipairs(pieces(body, options.boundary)) do
            table.insert(part.parts, parse(piece, depth + 1))
        end

        return part
    end

    part.body = decoded(body, headers['content-transfer-encoding'])

    -- Переводится только текст: вложение — файл, и его байты доезжают
    -- как пришли (см. шапку). Отказ перевода оставляет байты и кладёт
    -- причину рядом: разбор терпелив и письма из-за неё не теряет.
    if kind:find('^text/') ~= nil and not attached(part) then
        local text, err = encode.recode(part.body, part.charset)

        part.body = text or part.body
        part.charset_error = err
    end

    return part
end

--- Кладёт тело части в письмо под названным полем.
---
--- Причина, по которой текст остался байтами, поднимается в письмо:
--- у письма из одной части её иначе не найти — сама эта часть в `parts`
--- не попадает. Остаётся первая встреченная; у каждой части своя
--- видна в `parts`.
---@param letter table
---@param field string `text` или `html`
---@param part table
local function show(letter, field, part)
    letter[field] = part.body
    letter.charset_error = letter.charset_error or part.charset_error
end

--- Собирает текст, HTML и вложения из разобранных частей.
---@param part table
---@param letter table
local function collect(part, letter)
    if attached(part) then
        table.insert(letter.attachments, { name = part.name, type = part.kind, content = part.body })
    elseif part.kind == 'text/plain' and letter.text == nil then
        show(letter, 'text', part)
    elseif part.kind == 'text/html' and letter.html == nil then
        show(letter, 'html', part)
    end

    for _, inner in ipairs(part.parts) do
        collect(inner, letter)
    end
end

--- Разбирает письмо целиком.
---
--- Отдаёт то, что нужно вызывающему: от кого, кому, о чём, когда и что
--- внутри. Полная разметка остаётся в `parts` — она нужна редко,
--- но когда нужна, без неё не обойтись.
---@param raw string Письмо как оно пришло
---@return table
function Module.of(raw)
    local part = parse(raw, 1)
    ---@type any
    local headers = part.headers

    local letter = {
        headers = headers,

        -- Кодировка письма: по ней видно, чем пришло тело, — и видно
        -- же, что её не объявили вовсе. Сам текст уже в UTF-8, а если
        -- перевести не вышло — причина в `charset_error`, её кладёт
        -- сбор текста.
        charset = part.charset,
        from = headers.from,
        to = headers.to,
        cc = headers.cc,
        subject = headers.subject,
        date = headers.date,
        message_id = headers['message-id'],
        parts = part.parts,

        -- Вложения в том же виде, в каком их отдают на отправку:
        -- забранное письмо можно переслать дальше как есть.
        attachments = {},
    }

    collect(part, letter)

    return letter
end

return Module
