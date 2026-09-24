--- Кодировки почты: то, чем письмо отличается от текста.
---
--- Письмо ходит по протоколам, придуманным для семибитного ASCII, а пишут
--- в нём по-русски. Отсюда два слоя кодирования, и оба нужны в обе
--- стороны: письма мы и составляем, и читаем — чужие в том числе,
--- а чужие приходят кодированными как попало.
---
--- Заголовки кодируются по RFC 2047: `=?UTF-8?B?...?=`. Тело — целиком
--- base64 или quoted-printable. Base64 мы выбираем для своих писем: он
--- ничего не ломает, тогда как quoted-printable рвёт строки там, где ему
--- удобно, а строку длиннее 998 байт почтовый сервер вправе обрезать.
--- Разбирать же приходится оба: quoted-printable шлёт половина мира.
---
--- Третий слой — кодировка знаков. Свои письма мы пишем в UTF-8, а из
--- Windows приходят cp1251, из старых почтовиков — koi8-r. Разобранное
--- переводится в UTF-8 по объявленной кодировке: байты cp1251 дальше
--- портит всякий, кто считает строку UTF-8, — `str.upper` отдаёт U+FFFD
--- вместо букв, `slug` пуст, в панели и журнале каша.

local digest = require('digest')

local str = require('tnt.str')

local Module = {}

--- Длина строки base64 в теле письма.
---
--- Семьдесят шесть — то, что предписывает RFC 2045, и то, что ждут
--- разборщики на другой стороне.
Module.LINE = 76

--- Похож ли текст на base64.
---
--- Проверка нужна потому, что `digest.base64_decode` на чужом мусоре
--- не отказывает, а молча отдаёт другой мусор: письмо с непонятным
--- заголовком после такого «разбора» становится письмом из нечитаемых
--- байт, и понять, что случилось, уже нельзя.
---@param text string
---@return boolean
local function base64_like(text)
    return text:find('^[%w%+/=%s]*$') ~= nil
end

--- Кодировки, текст в которых переводить незачем: он уже UTF-8.
---
--- Обе записи из жизни: `utf8` без дефиса пишут самодельные отправители.
local UNICODE = { ['utf-8'] = true, ['utf8'] = true }

--- Переводит текст из объявленной кодировки в UTF-8.
---
--- Без кодировки текст остаётся как пришёл: гадать о ней не из чего,
--- а по RFC 2045 необъявленная — это ASCII, которому переводить нечего.
--- Пробелы по краям имени снимаются: разбор свойств оставляет их
--- от `charset=windows-1251 ;`, а ядро имени с пробелом не знает.
---
--- Отказ — пара `nil, err` от `str.decode`: незнакомая кодировка
--- и байты не из неё — случаи из жизни, а не ошибка программиста.
---@param bytes string
---@param charset string|nil Имя кодировки из письма
---@return string|nil
---@return string|nil err
function Module.recode(bytes, charset)
    local name = (charset or ''):match('^%s*(.-)%s*$')

    -- Образец совпадает с любой строкой, пустой тоже, но знает об этом
    -- только он сам.
    ---@cast name string

    if name == '' or UNICODE[name:lower()] then
        return bytes
    end

    return str.decode(bytes, name)
end

--- Есть ли в тексте что-нибудь, кроме печатного ASCII.
---@param text string
---@return boolean
function Module.plain(text)
    return tostring(text):find('[^\32-\126]') == nil
end

--- Разбивает длинную строку на строки нужной длины.
---@param text string
---@param limit integer|nil
---@return string
function Module.wrap(text, limit)
    local width = limit or Module.LINE
    local lines = {}

    for index = 1, #text, width do
        table.insert(lines, text:sub(index, index + width - 1))
    end

    return table.concat(lines, '\r\n')
end

--- Кодирует значение заголовка, если в нём есть не-ASCII.
---
--- Целиком, а не по словам: разбиение по словам требует помнить
--- про границы букв UTF-8, а выигрыш от него — несколько байт.
---@param value string
---@return string
function Module.header(value)
    local text = tostring(value)

    if Module.plain(text) then
        return text
    end

    return ('=?UTF-8?B?%s?='):format(digest.base64_encode(text, { nowrap = true }))
end

--- Закодированный кусок заголовка: он весь, кодировка, вид и содержимое.
local ENCODED_WORD = '(=%?([%w%-]+)%?([BbQq])%?(.-)%?=)'

--- Разбирает содержимое одного закодированного куска.
---
--- Кусок, который не разобрать, — не base64 либо текст не перевести
--- в UTF-8 (незнакомая кодировка, байты не из неё), — остаётся целиком
--- как пришёл (RFC 2047, 6.2, вариант «а»): ASCII-запись куска честна
--- и никого дальше не портит, а байты чужой кодировки превратили бы
--- тему в кашу.
---@param word string Кусок целиком, `=?...?=`
---@param charset string
---@param kind string `B` или `Q` в любом регистре
---@param payload string
---@return string
local function unword(word, charset, kind, payload)
    local bytes

    if kind:lower() ~= 'b' then
        -- В заголовках quoted-printable подчёркивание означает
        -- пробел: единственное место, где эта кодировка отличается
        -- от себя же в теле письма.
        bytes = Module.unquoted(payload:gsub('_', ' '))
    elseif base64_like(payload) then
        bytes = digest.base64_decode(payload)
    else
        -- Проверка формы вместо перехвата отказа: декодер на мусоре
        -- не отказывает, а молча отдаёт другой мусор, — ловить тут
        -- нечего, отсеивать надо до него.
        return word
    end

    return Module.recode(bytes, charset) or word
end

--- Разбирает закодированное значение заголовка.
---
--- Понимает оба вида: base64 (`?B?`) и quoted-printable (`?Q?`), —
--- и отдаёт текст в UTF-8, в какой кодировке ни пришёл кусок:
--- `=?windows-1251?B?...?=` из Windows читается так же, как свой. Куски,
--- которые разобрать не вышло, остаются как есть: показать сырой
--- заголовок честнее, чем выбросить его.
---
--- Пробел между двумя закодированными кусками — не часть текста
--- (RFC 2047, 6.2): так длинный заголовок разбивают по словам, и склеивать
--- их надо обратно без пробела, иначе тема приезжает с двойным. Пробел
--- между куском и обычным словом — часть текста и остаётся.
---@param value string
---@return string
function Module.unheader(value)
    local text = tostring(value)

    -- Промежуток захватывается вместе с куском, а решает о нём то, что
    -- стоит следом. Отдельная склейка промежутков заранее
    -- (`gsub('%?=%s+=%?', '?==?')`) была неотличима от себя же с `%s*`:
    -- пустой промежуток она заменяла им же.
    local decoded = text:gsub(ENCODED_WORD .. '(%s*)()', function(word, charset, kind, payload, gap, after)
        if text:find('^' .. ENCODED_WORD, after) ~= nil then
            gap = ''
        end

        return unword(word, charset, kind, payload) .. gap
    end)

    return decoded
end

--- Кодирует тело письма в base64 строками нужной длины.
---@param text string
---@return string
function Module.body(text)
    return Module.wrap(digest.base64_encode(tostring(text), { nowrap = true }))
end

--- Разбирает тело, закодированное base64.
---
--- Переводы строк выбрасываются до разбора: base64 в письме разбит
--- на строки, а разборщику они не нужны.
---@param text string
---@return string
function Module.unbody(text)
    local packed = tostring(text):gsub('%s', '')

    if not base64_like(packed) then
        return tostring(text)
    end

    return digest.base64_decode(packed)
end

--- Разбирает quoted-printable.
---
--- Сначала снимаются мягкие переносы — знак равенства в конце строки,
--- которым кодировка разрывает длинные строки, — потом разбираются
--- сами восьмеричные пары.
---@param text string
---@return string
function Module.unquoted(text)
    local joined = tostring(text):gsub('=\r?\n', '')

    return (
        joined:gsub('=(%x%x)', function(pair)
            local code = tonumber(pair, 16)

            -- Приведение ради вывода типов: шаблон уже требует двух
            -- шестнадцатеричных знаков, и ничего, кроме числа, здесь
            -- не получится, — но знает об этом только шаблон.
            ---@cast code integer

            return string.char(code)
        end)
    )
end

return Module
