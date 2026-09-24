--- Получение писем: разговор по IMAP.
---
--- В отличие от POP3, здесь письма не забирают, а смотрят: они остаются
--- на сервере, у них есть папки, флаги и устойчивые номера `UID`. Это
--- и нужно узлу, который читает ящик не в одиночку: забрать письмо
--- по POP3 значит отнять его у человека, который читает тот же ящик.
---
--- Протокол теговый: каждая команда начинается с придуманной нами метки,
--- и ответ на неё кончается строкой с той же меткой. Всё, что приходит
--- между, помечено звёздочкой — это данные, и их может быть сколько
--- угодно. Кто читает одну строку на команду, тот на первом же письме
--- начинает читать чужие ответы.
---
--- Длинные куски — письмо целиком, например — приходят литералом: строка
--- кончается длиной в фигурных скобках, а следом идёт ровно столько
--- байт. Читать их построчно нельзя: внутри письма есть и переводы
--- строк, и строки, похожие на ответы сервера.
---
--- Письма читаются `BODY.PEEK[]`, а не `BODY[]`: второй ставит отметку
--- «прочитано» самим фактом чтения, и узел, заглянувший в ящик, отнимает
--- у человека признак непрочитанного письма.

local digest = require('digest')

local transport = require('tnt.mail.transport')

local Module = {}

--- Способы входа сверх `LOGIN`: имя в настройке `auth` — механизм SASL.
--- XOAUTH2 — вход по токену OAuth 2.0 (Gmail, Microsoft 365).
Module.METHODS = { xoauth2 = 'XOAUTH2' }

---@class TntMailImapRequest
---@field folder string|nil Какую папку смотреть; по умолчанию INBOX
---@field limit integer|nil Сколько писем забрать
---@field unseen boolean|nil Только непрочитанные
---@field mark_seen boolean|nil Пометить прочитанными
---@field delete boolean|nil Пометить удалёнными и стереть

--- Метка команды: у каждой своя, иначе ответы не различить.
---@param counter integer
---@return string
local function tag_of(counter)
    return ('a%04d'):format(counter)
end

--- Читает ответ до строки с нашей меткой.
---
--- Возвращает состояние (OK, NO, BAD), все строки и литералы в порядке
--- прихода: разбирать их — дело вызывающего, он один знает, что просил.
---@param link table
---@param tag string
---@return string|nil state
---@return table lines Строки ответа
---@return table literals Литералы в порядке прихода
local function response(link, tag)
    local lines = {}
    local literals = {}

    while true do
        local line, err = link.read_line()

        if line == nil then
            return nil, { tostring(err) }, literals
        end

        local size = line:match('{(%d+)}$')

        if size ~= nil then
            local chunk, chunk_error = link.read_chunk(tonumber(size))

            if chunk == nil then
                return nil, { tostring(chunk_error) }, literals
            end

            table.insert(literals, chunk)
        end

        table.insert(lines, line)

        -- Продолжение `+` ждёт от нас строки: читать дальше значило бы
        -- стоять до срока. Данные сервера начинаются со звёздочки,
        -- а ответ на команду — с метки, и с `+` не начинается ни то, ни другое.
        if line:find('^%+') ~= nil then
            return '+', lines, literals
        end

        local state = line:match('^' .. tag .. ' (%u+)')

        if state ~= nil then
            return state, lines, literals
        end
    end
end

--- Разговор с сервером: метки, команды, ответы.
---@param link table
---@return table
local function talker(link)
    local counter = 0

    --- Пишет строку и читает ответ до продолжения либо до метки.
    ---@param text string
    ---@param tag string
    ---@return string|nil state OK, NO, BAD либо `+`
    ---@return table lines
    ---@return table literals
    local function exchange(text, tag)
        local written, err = link.write(text .. transport.CRLF)

        if not written then
            return nil, { tostring(err) }, {}
        end

        return response(link, tag)
    end

    return {
        --- Пересаживает разговор на другое соединение.
        ---
        --- Нужно после STARTTLS: сокет тот же, но говорить с ним теперь
        --- надо через шифрование. Счёт меток при этом продолжается —
        --- сервер различает ответы по ним, и начать заново значило бы
        --- получить ответ на метку, которую мы уже использовали.
        ---@param replacement table
        attach = function(replacement)
            link = replacement
        end,

        --- Говорит команду и ждёт ответа на неё.
        ---@param command string
        ---@return boolean ok
        ---@return table lines
        ---@return table literals
        say = function(command)
            counter = counter + 1

            local tag = tag_of(counter)
            local state, lines, literals = exchange(('%s %s'):format(tag, command), tag)

            return state == 'OK', lines, literals
        end,

        --- Вход SASL: команда, начальный ответ после продолжения, итог.
        ---
        --- Начальный ответ идёт строкой после продолжения, а не в самой
        --- команде: так его понимает всякий сервер, а не только тот,
        --- что объявил SASL-IR (RFC 4959). Отказ XOAUTH2 сервер отдаёт
        --- продолжением с причиной в base64 и ждёт пустой строки, чтобы
        --- ответить окончательным NO.
        ---@param mechanism string
        ---@param initial string Начальный ответ в base64
        ---@return boolean ok
        ---@return table lines
        ---@return string|nil reason Причина отказа из продолжения
        authenticate = function(mechanism, initial)
            counter = counter + 1

            local tag = tag_of(counter)
            local state, lines = exchange(('%s AUTHENTICATE %s'):format(tag, mechanism), tag)
            local reason

            if state == '+' then
                state, lines = exchange(initial, tag)
            end

            if state == '+' then
                reason = digest.base64_decode(lines[#lines]:match('^%+ ?(.*)$'))
                state, lines = exchange('', tag)
            end

            return state == 'OK', lines, reason
        end,
    }
end

--- Строка команды в кавычках.
---
--- Кавычка и обратная косая внутри экранируются обратной косой (RFC 3501,
--- quoted): без этого пароль с кавычкой обрывает строку, сервер читает
--- остаток новыми словами команды и отказывает во входе с верным паролем.
--- Управляющих знаков сюда не доходит: CR и LF в кавычках не экранируются
--- ничем, и значение с ними отвергает `unsafe` до разговора.
---@param value any
---@return string
local function quoted(value)
    return ('"%s"'):format((tostring(value):gsub('[\\"]', '\\%0')))
end

--- Чем плохи имя, пароль и папка для строки команды: причина либо `nil`.
---
--- Литерал `{n}` пронёс бы и перевод строки, но ради него разговор ждёт
--- продолжения сервера на каждое значение, а настоящих имён, паролей
--- и папок с управляющим знаком не бывает: такой знак — след подложенной
--- команды, и отказ честнее доставки.
---@param settings table Настройки с паролем строкой
---@param opts TntMailImapRequest
---@return string|nil refusal
local function unsafe(settings, opts)
    return transport.unsafe(settings) or transport.tainted('папка', opts.folder)
end

--- Последняя строка ответа: в ней причина отказа.
---@param lines table
---@return string
local function reason(lines)
    return tostring(lines[#lines] or 'сервер промолчал')
end

--- Поднимает шифрование до входа.
---
--- В IMAP переход просят тегованной командой, и делать это надо
--- до `LOGIN`: имя и пароль идут в нём одной строкой, и открытым
--- текстом отдаются целиком.
---@param link table
---@param talk table Разговор с метками
---@param settings table
---@return table|nil link Защищённое соединение
---@return string|nil err
local function raise_tls(link, talk, settings)
    local ready, lines = talk.say('STARTTLS')

    if not ready then
        return nil, ('переход на шифрование: %s'):format(reason(lines))
    end

    local secured, secure_error = transport.secure(link, settings)

    if secured == nil then
        return nil, ('переход на шифрование: %s'):format(tostring(secure_error))
    end

    return secured
end

--- Сам вход: XOAUTH2 по настройке `auth`, иначе имя и пароль.
---@param talk table Разговор с метками
---@param settings table
---@return boolean ok
---@return table lines Ответ сервера
---@return string|nil cause Причина отказа XOAUTH2 из продолжения
local function login(talk, settings)
    if settings.auth == 'xoauth2' then
        local accepted, answer, cause = talk.authenticate('XOAUTH2', transport.xoauth2(settings))

        return accepted, answer, cause
    end

    -- Имя и пароль берутся в кавычки: в них бывают пробелы, а команда
    -- разбирается пробелами. Литералов у ответа на LOGIN нет, и третьим
    -- значением отдаётся пустота, а не они.
    local entered, lines = talk.say(('LOGIN %s %s'):format(quoted(settings.username), quoted(settings.password)))

    return entered, lines
end

--- Входит под учётной записью.
---
--- Третьим значением отдаётся соединение, на котором вход остановился, —
--- в любом исходе: после STARTTLS это защищённое, и отказ входа
--- прощается и закрывается на нём, а не на прежнем.
---@param link table
---@param talk table
---@param settings table
---@return boolean ok
---@return string|nil err
---@return table last Соединение, на котором остановился вход
local function enter(link, talk, settings)
    local greeting, greeting_error = link.read_line()

    if greeting == nil then
        return false, ('приветствие: %s'):format(tostring(greeting_error)), link
    end

    if settings.tls == 'starttls' then
        local secured, secure_error = raise_tls(link, talk, settings)

        if secured == nil then
            return false, secure_error, link
        end

        talk.attach(secured)
        link = secured
    end

    local entered, lines, cause = login(talk, settings)

    if not entered then
        local detail = cause and ('; причина: %s'):format(cause) or ''

        return false, ('вход: %s%s'):format(reason(lines), detail), link
    end

    return true, nil, link
end

--- Какие папки есть в ящике.
---@param given table Настройки ящика; пароль — строка либо поставщик
---@return string[]|nil folders
---@return string|nil err
function Module.folders(given)
    local settings, refusal = transport.credentials(given)

    if settings == nil then
        return nil, refusal
    end

    -- Отказ до соединения, как у хода за письмами: будить сервер ради
    -- отказа незачем.
    refusal = transport.unsafe(settings)

    if refusal ~= nil then
        return nil, refusal
    end

    local link, err = transport.connect(settings)

    if link == nil then
        return nil, err
    end

    local talk = talker(link)

    -- Вход отдаёт то соединение, на котором закончил, и при отказе тоже:
    -- после STARTTLS это защищённое, прежнее к тому мигу негодно.
    -- Закрывать надо именно его, иначе SSL и SSL_CTX останутся висеть.
    local entered, enter_error, last = enter(link, talk, settings)

    link = last

    if not entered then
        link.close()

        return nil, enter_error
    end

    local listed, lines = talk.say('LIST "" "*"')
    local found = {}

    if listed then
        for _, line in ipairs(lines) do
            -- Имя папки — всё, что осталось после флагов и разделителя
            -- иерархии. Кавычки снимаются отдельно: сервер ставит их
            -- не всегда, а имя с пробелом внутри — без них и не пришлёт.
            local name = line:match('^%*%s+LIST%s+%b()%s+%S+%s+(.+)$')

            if name ~= nil then
                table.insert(found, (name:gsub('^"(.*)"$', '%1')))
            end
        end
    end

    talk.say('LOGOUT')
    link.close()

    if not listed then
        return nil, ('список папок: %s'):format(reason(lines))
    end

    return found
end

--- Весь разговор: вход, выбор папки, поиск, чтение, пометки.
---
--- Третьим значением отдаётся соединение, на котором шёл разговор, —
--- в любом исходе, а не только в удачном: после STARTTLS это защищённое,
--- и прощаться и закрывать надо его.
---@param link table
---@param settings table
---@param opts table
---@return table[]|nil letters
---@return string|nil err
---@return table last Соединение, на котором шёл разговор
function Module.take(link, settings, opts)
    -- Отказ до приветствия: из разговора, в котором папка или пароль
    -- несут вторую команду, серверу не говорится ни слова.
    local refusal = unsafe(settings, opts)

    if refusal ~= nil then
        return nil, refusal, link
    end

    local talk = talker(link)
    local entered, enter_error, secured = enter(link, talk, settings)

    if not entered then
        return nil, enter_error, secured
    end

    local folder = opts.folder or 'INBOX'
    local selected, select_lines = talk.say(('SELECT %s'):format(quoted(folder)))

    if not selected then
        return nil, ('папка %s: %s'):format(folder, reason(select_lines)), secured
    end

    local found, search_lines = talk.say(opts.unseen and 'SEARCH UNSEEN' or 'SEARCH ALL')

    if not found then
        return nil, ('поиск: %s'):format(reason(search_lines)), secured
    end

    local numbers = {}

    for _, line in ipairs(search_lines) do
        -- Номера идут одной строкой после слова SEARCH, а пустой ответ
        -- (`* SEARCH` и ничего больше) означает, что писем нет. Слово,
        -- слипшееся с числом, — не ответ поиска: читать письма
        -- по номерам, которых сервер не называл, хуже, чем не читать.
        local rest = line:match('^%*%s+SEARCH(.*)$')

        if rest ~= nil and (rest == '' or rest:find('^%s') ~= nil) then
            -- Номер — слово из одних цифр. Прочие слова (`(MODSEQ 917162500)`
            -- у CONDSTORE) номерами не считаются, а `tonumber` без проверки
            -- взял бы и `0x10`, и `inf`. Слова делит `split`: у обхода
            -- образцом `%d+` мутант `%d*` добавлял только пустые слова,
            -- и `tonumber` их отбрасывал — убить его было нечем.
            for _, word in ipairs(rest:split()) do
                if word:find('%D') == nil then
                    table.insert(numbers, tonumber(word))
                end
            end
        end
    end

    local limit = opts.limit or 10
    local letters = {}

    for index = #numbers, math.max(1, #numbers - limit + 1), -1 do
        local number = numbers[index]
        local taken, lines, literals = talk.say(('FETCH %d (UID BODY.PEEK[])'):format(number))

        if not taken then
            return nil, ('письмо %d: %s'):format(number, reason(lines)), secured
        end

        local uid

        for _, line in ipairs(lines) do
            uid = uid or line:match('UID%s+(%d+)')
        end

        table.insert(letters, { number = number, id = uid, raw = literals[1] or '' })

        if opts.mark_seen then
            talk.say(('STORE %d +FLAGS (\\Seen)'):format(number))
        end

        if opts.delete then
            talk.say(('STORE %d +FLAGS (\\Deleted)'):format(number))
        end
    end

    if opts.delete then
        -- Помеченные письма стираются только здесь: пометка без этой
        -- команды переживает соединение и однажды удивит человека.
        talk.say('EXPUNGE')
    end

    return letters, nil, secured
end

--- Забирает письма из папки.
---
--- Свежие первыми: номера растут со временем, и нужны обычно последние.
--- Письма не помечаются прочитанными — узел здесь наблюдатель, а не
--- читатель.
Module.fetch = transport.fetcher(Module.take, function(link)
    talker(link).say('LOGOUT')
end, unsafe)

return Module
