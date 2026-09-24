--- Получение писем: разговор по POP3.
---
--- POP3 устроен как почтовый ящик у подъезда: письма лежат по номерам,
--- их можно забрать и выбросить — и всё. Ни папок, ни флагов, ни поиска;
--- номера живут только до конца соединения, а между соединениями письмо
--- опознаётся по `UIDL`.
---
--- Для узла, который забирает ответы на свои же уведомления, этого
--- хватает. Где нужны папки и отметки о прочтении — там IMAP, он рядом.
---
--- Удаление отложенное: `DELE` только помечает, а стирает всё `QUIT`.
--- Поэтому оборванное соединение — это «ничего не удалено», и повтор
--- заберёт те же письма. Забирать дважды лучше, чем потерять однажды.
---
--- Многострочный ответ кончается строкой из одной точки, а точки
--- в начале строк письма удвоены — их надо вернуть обратно. Без этого
--- письмо, начинающееся с точки, приезжает испорченным.

local digest = require('digest')

local transport = require('tnt.mail.transport')

local Module = {}

--- Способы входа сверх `USER` и `PASS`: имя в настройке `auth` — имя
--- в разговоре с сервером. XOAUTH2 — вход по токену OAuth 2.0 (Gmail,
--- Microsoft 365): пароля у такого ящика нет.
Module.METHODS = { xoauth2 = 'XOAUTH2' }

--- Ответ сервера: удача или отказ.
---@param link table
---@return boolean ok
---@return string text
local function answer(link)
    local line, err = link.read_line()

    if line == nil then
        return false, tostring(err)
    end

    if line:startswith('+OK') then
        return true, line:sub(5)
    end

    return false, line
end

--- Говорит команду и читает однострочный ответ.
---@param link table
---@param command string
---@return boolean ok
---@return string text
local function say(link, command)
    local written, err = link.write(command .. transport.CRLF)

    if not written then
        return false, tostring(err)
    end

    return answer(link)
end

--- Читает многострочный ответ до строки с одной точкой.
---@param link table
---@return string|nil text
---@return string|nil err
local function multiline(link)
    local lines = {}

    while true do
        local line, err = link.read_line()

        if line == nil then
            return nil, tostring(err)
        end

        if line == '.' then
            return table.concat(lines, transport.CRLF)
        end

        -- Удвоенная точка возвращается на место: это не часть письма,
        -- а способ протокола не спутать её с концом.
        table.insert(lines, (line:gsub('^%.%.', '.')))
    end
end

--- Вход XOAUTH2 (RFC 5034): просьба, продолжение, ответ.
---
--- Начальный ответ идёт отдельной строкой после продолжения `+`, а не
--- в самой команде: команда POP3 не длиннее 255 байт (RFC 5034, §4),
--- а токен Microsoft 365 — больше килобайта. Отказ сервер отдаёт
--- продолжением с причиной в base64 и ждёт пустой строки, чтобы ответить
--- окончательным `-ERR`: без неё разговор стоял бы до срока.
---@param link table
---@param settings table
---@return boolean ok
---@return string|nil err
local function xoauth2(link, settings)
    local _, offered = say(link, 'AUTH XOAUTH2')

    -- Продолжение — строка с `+`, но не `+OK`: `answer` отдаёт её целиком
    -- неудачей, а удачу — без `+OK`.
    if offered:find('^%+') == nil then
        return false, ('вход: %s'):format(offered)
    end

    local entered, verdict = say(link, transport.xoauth2(settings))

    if entered then
        return true
    end

    local encoded = verdict:match('^%+ ?(.*)$')

    if encoded == nil then
        return false, ('вход: %s'):format(verdict)
    end

    local _, final = say(link, '')

    return false, ('вход: %s; причина: %s'):format(final, digest.base64_decode(encoded))
end

--- Входит под учётной записью.
---
--- Третьим значением отдаётся соединение, на котором вход остановился, —
--- в любом исходе: после STLS это защищённое, и отказ имени или пароля
--- прощается и закрывается на нём, а не на прежнем.
---@param link table
---@param settings table
---@return boolean ok
---@return string|nil err
---@return table last Соединение, на котором остановился вход
local function enter(link, settings)
    local greeted, greeting = answer(link)

    if not greeted then
        return false, ('приветствие: %s'):format(greeting), link
    end

    if settings.tls == 'starttls' then
        -- В POP3 переход называется STLS и делается до входа: имя
        -- и пароль идут отдельными командами, и отправить их открытым
        -- текстом «пока договариваемся» — значит отдать их целиком.
        local ready, text = say(link, 'STLS')

        if not ready then
            return false, ('переход на шифрование: %s'):format(text), link
        end

        local secured, secure_error = transport.secure(link, settings)

        if secured == nil then
            return false, ('переход на шифрование: %s'):format(tostring(secure_error)), link
        end

        link = secured
    end

    if settings.auth == 'xoauth2' then
        local entered, reason = xoauth2(link, settings)

        return entered, reason, link
    end

    local named, name_text = say(link, 'USER ' .. tostring(settings.username))

    if not named then
        return false, ('имя: %s'):format(name_text), link
    end

    local entered, secret_text = say(link, 'PASS ' .. tostring(settings.password))

    if not entered then
        return false, ('пароль: %s'):format(secret_text), link
    end

    return true, nil, link
end

--- Сколько писем лежит в ящике.
---@param link table
---@return number|nil count
---@return string|nil err
local function count_of(link)
    local ok, text = say(link, 'STAT')

    if not ok then
        return nil, ('состояние ящика: %s'):format(text)
    end

    local digits = text:match('^(%d+)')

    if digits == nil then
        return nil, ('состояние ящика не разобрано: %s'):format(text)
    end

    return tonumber(digits)
end

--- Опознаватели писем: номер в ящике → устойчивое имя.
---
--- Номера живут до конца соединения, и по ним нельзя сказать, видели ли
--- мы это письмо вчера. `UIDL` даёт имя, которое сервер обещает не
--- менять, — по нему и запоминают прочитанное.
---@param link table
---@param count number
---@return table<integer, string>
local function identifiers(link, count)
    local found = {}

    -- Пустому ящику имён не нужно: лишняя команда здесь не безобидна,
    -- сервер вправе ответить на неё отказом. А сервер без UIDL имён
    -- не даёт, и письма забираются по номерам. Выход у обоих случаев
    -- один: у отдельного выхода пустого ящика мутант `return nil` был
    -- неотличим — пустой ящик имён не читает.
    if count == 0 or not say(link, 'UIDL') then
        return found
    end

    local text = multiline(link)

    -- Строки склеены через CRLF, и деление по нему — ровно обратный ход.
    for _, line in ipairs(tostring(text):split(transport.CRLF)) do
        local number, id = line:match('^(%d+)%s+(%S+)$')

        if number ~= nil then
            found[tonumber(number)] = id
        end
    end

    return found
end

--- Весь разговор: вход, чтение, пометки на удаление.
---
--- Третьим значением отдаётся соединение, на котором шёл разговор, —
--- в любом исходе, а не только в удачном: после STLS это защищённое,
--- и прощаться и закрывать надо его.
---@param link table
---@param settings table
---@param opts table
---@return table[]|nil letters
---@return string|nil err
---@return table last Соединение, на котором шёл разговор
function Module.take(link, settings, opts)
    -- Имя и пароль идут в `USER` и `PASS` без кавычек: перевод строки
    -- в них — вторая команда серверу. Отказ до приветствия: из такого
    -- разговора серверу не говорится ни слова.
    local refusal = transport.unsafe(settings)

    if refusal ~= nil then
        return nil, refusal, link
    end

    -- Вход отдаёт то соединение, на котором закончил: после STLS это
    -- защищённое, а прежнее негодно — читать из него нельзя, писать тоже.
    local entered, enter_error, talking = enter(link, settings)

    if not entered then
        return nil, enter_error, talking
    end

    link = talking

    local count, count_error = count_of(link)

    if count == nil then
        return nil, count_error, talking
    end

    local ids = identifiers(link, count)
    local limit = opts.limit or 10
    local letters = {}

    -- С конца нумерации: у сервера, который ведёт номера по приходу, там
    -- свежие письма. RFC 1939 порядка не задаёт, и сервер с обратной
    -- нумерацией отдаст по пределу старейшие — это записано в документе,
    -- а не угадывается по `Date`: чтобы узнать даты, пришлось бы читать
    -- заголовки всего ящика, от чего и бережёт предел, а `Date` пишет
    -- отправитель, и одно письмо с датой из будущего перевернуло бы
    -- порядок и там, где номера идут по приходу.
    for number = count, math.max(1, count - limit + 1), -1 do
        local ok, text = say(link, 'RETR ' .. number)

        if not ok then
            return nil, ('письмо %d: %s'):format(number, text), talking
        end

        local raw, raw_error = multiline(link)

        if raw == nil then
            return nil, ('письмо %d: %s'):format(number, tostring(raw_error)), talking
        end

        table.insert(letters, { number = number, id = ids[number], raw = raw })

        if opts.delete then
            say(link, 'DELE ' .. number)
        end
    end

    return letters, nil, talking
end

--- Забирает письма из ящика.
---
--- Письма идут с конца нумерации: у сервера, который нумерует по приходу,
--- это свежие, а нужны обычно последние. Предел обязателен — ящик,
--- в который никто не заглядывал месяц, иначе приедет на узел целиком.
---
--- Прощание не формальность: удаление вступает в силу только на нём.
Module.fetch = transport.fetcher(Module.take, function(link)
    say(link, 'QUIT')
end, transport.unsafe)

return Module
