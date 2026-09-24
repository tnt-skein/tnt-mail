--- Отправка письма: разговор по SMTP.
---
--- Протокол простой до скуки: сервер здоровается, мы представляемся,
--- называем отправителя, получателей, отдаём письмо и прощаемся. Вся
--- сложность в мелочах, каждая из которых портит письмо молча.
---
--- Ответ сервера бывает многострочным: `250-РАСШИРЕНИЕ` продолжается,
--- `250 РАСШИРЕНИЕ` заканчивает. Кто читает одну строку, тот на втором
--- письме прочитает хвост первого и не поймёт ни одного ответа.
---
--- Точка в начале строки тела удваивается. Одинокая точка на строке
--- означает конец письма, и текст с такой строкой без удвоения обрывает
--- письмо посередине, а остаток уходит серверу как команды.
---
--- Ошибки делятся на две породы, и путать их нельзя: 4xx — «попробуйте
--- позже» (сервер занят, ящик переполнен), 5xx — «не пробуйте больше»
--- (адреса нет, отказано навсегда). Повторять 5xx значит слать один
--- и тот же отказ до конца света.

local crypto = require('crypto')
local digest = require('digest')

local message = require('tnt.mail.message')
local transport = require('tnt.mail.transport')

local Module = {}

--- Приветствие сервера.
Module.READY = 220

--- Всё хорошо.
Module.OK = 250

--- Сервер готов принять письмо после DATA.
Module.DATA_READY = 354

--- Сервер готов к разговору дальше: так он отвечает на AUTH и STARTTLS.
Module.CONTINUE = 334

--- Аутентификация прошла.
Module.AUTHENTICATED = 235

--- Разбирает ответ сервера.
---
--- Многострочный ответ читается до строки, где после кода стоит пробел,
--- а не дефис. Текст склеивается: в нём приходят и список расширений,
--- и причина отказа.
---@param link table Соединение
---@return number|nil code
---@return string text
local function answer(link)
    local lines = {}

    while true do
        local line, err = link.read_line()

        if line == nil then
            return nil, tostring(err)
        end

        table.insert(lines, line)

        local code, separator = line:match('^(%d%d%d)([ %-]?)')

        if code == nil then
            return nil, ('непонятный ответ сервера: %s'):format(line)
        end

        if separator ~= '-' then
            return tonumber(code), table.concat(lines, '\n')
        end
    end
end

--- Говорит команду и читает ответ.
---@param link table
---@param command string|nil
---@return number|nil code
---@return string text
local function say(link, command)
    if command ~= nil then
        local written, err = link.write(command .. transport.CRLF)

        if not written then
            return nil, tostring(err)
        end
    end

    return answer(link)
end

--- Ждёт от сервера именно этого кода.
---@param link table
---@param command string|nil
---@param expected integer
---@param step string Что мы делали — попадёт в причину отказа
---@return boolean ok
---@return string text Ответ сервера либо причина отказа
local function expect(link, command, expected, step)
    local code, text = say(link, command)

    if code == nil then
        return false, ('%s: %s'):format(step, text)
    end

    if code ~= expected then
        return false, ('%s: сервер ответил %d — %s'):format(step, code, text)
    end

    return true, text
end

--- Какие расширения назвал сервер.
---
--- Имена приводятся к верхнему регистру: сервер вправе писать их как
--- угодно, а сравнивать их будут с постоянными. Расширение без хвоста
--- (`250-STARTTLS`) — тоже расширение: у половины из них параметров нет.
---@param text string Ответ на EHLO
---@return table<string, string>
function Module.extensions(text)
    local found = {}

    -- Строки ответа склеены через `\n`, и деление по нему — обратный ход:
    -- у обхода образцом `[^\n]*` мутант `+` терял только пустые строки,
    -- которые и так не расширения.
    for _, line in ipairs(text:split('\n')) do
        local name, rest = line:match('^%d%d%d[ %-]([%w%-]+)%s*(.*)$')

        if name ~= nil then
            found[name:upper()] = rest
        end
    end

    return found
end

--- Удваивает точку в начале строки.
---
--- Тот самый dot-stuffing: без него строка из одной точки обрывает
--- письмо, и остаток текста уходит серверу как набор команд.
---@param body string
---@return string
function Module.stuff(body)
    local text = tostring(body):gsub('\r?\n', transport.CRLF)

    return (transport.CRLF .. text):gsub(transport.CRLF .. '%.', transport.CRLF .. '..'):sub(#transport.CRLF + 1)
end

--- Представляется серверу.
---
--- Сначала EHLO: он же спрашивает, что сервер умеет. Древний сервер,
--- не знающий EHLO, отвечает отказом — тогда HELO, но без расширений,
--- то есть без AUTH и STARTTLS.
---@param link table
---@param name string Имя, которым представляемся
---@return table|nil extensions
---@return string|nil err
local function greet(link, name)
    local ready, greeting = expect(link, nil, Module.READY, 'приветствие')

    if not ready then
        return nil, greeting
    end

    local code, text = say(link, 'EHLO ' .. name)

    if code == Module.OK then
        return Module.extensions(text)
    end

    local simple, plain = expect(link, 'HELO ' .. name, Module.OK, 'представление')

    if not simple then
        return nil, plain
    end

    return {}
end

--- Поднимает шифрование посреди разговора.
---
--- STARTTLS устроен так: сервер объявляет расширение в ответе на EHLO,
--- клиент просит перейти, сервер отвечает готовностью — и с этого места
--- по тому же сокету идёт TLS. После перехода **обязательно** здороваться
--- заново: список расширений до и после шифрования разный, и AUTH сервер
--- объявляет как раз после него. Старый список к тому же приходил
--- открытым текстом — верить ему нельзя, его мог переписать тот, кто
--- сидит в середине.
---
--- Соединение отдаётся первым всегда — то, на котором разговор
--- остановился: до рукопожатия это прежнее, после — защищённое, даже
--- если представиться под шифрованием не вышло. Прощаться и закрывать
--- надо именно его: прежнее после перехода негодно.
---@param link table Начатый разговор
---@param settings table Настройки соединения
---@param extensions table Что сервер назвал до шифрования
---@return table link Соединение, на котором остановился разговор
---@return table|nil extensions Новый список расширений; nil — шифрование не поднялось
---@return string|nil err Причина, по которой шифрование не поднялось
local function raise_tls(link, settings, extensions)
    if extensions.STARTTLS == nil then
        return link, nil, 'сервер не предлагает STARTTLS'
    end

    local ready, text = expect(link, 'STARTTLS', Module.READY, 'переход на шифрование')

    if not ready then
        return link, nil, text
    end

    local secured, secure_error = transport.secure(link, settings)

    if secured == nil then
        return link, nil, tostring(secure_error)
    end

    local code, greeting = say(secured, 'EHLO ' .. (settings.helo or 'tarantool'))

    if code ~= Module.OK then
        return secured,
            nil,
            ('представление после шифрования: %s'):format(tostring(greeting))
    end

    return secured, Module.extensions(greeting)
end

--- Способы входа: имя в настройке `auth` — имя в разговоре с сервером.
---
--- PLAIN и LOGIN отдают пароль почти открытым текстом: base64
--- не шифрование, а способ уложить байты в семь бит. CRAM-MD5 пароль
--- не отдаёт вовсе — сервер шлёт вызов, клиент отвечает HMAC-MD5 от него,
--- и подслушавший увидит отзыв, а не пароль. XOAUTH2 — вход по токену
--- OAuth 2.0 (Gmail, Microsoft 365): пароля у такой учётной записи нет,
--- а токен живёт час, и в `password` при нём кладут поставщика токена —
--- функцию, которая отдаёт живой токен (`tnt.mail.transport.credentials`).
Module.METHODS = {
    ['cram-md5'] = 'CRAM-MD5',
    plain = 'PLAIN',
    login = 'LOGIN',
    xoauth2 = 'XOAUTH2',
}

--- В каком порядке пробовать способы, когда `auth` не задан.
---
--- CRAM-MD5 первым: он единственный не отдаёт пароль, и сервер,
--- который его объявил, готов его проверить. XOAUTH2 сам собой
--- не выбирается никогда: в `password` при нём лежит токен, а не пароль,
--- и угадать это по списку расширений нельзя.
local PREFERRED = { 'CRAM-MD5', 'PLAIN', 'LOGIN' }

--- Какие способы входа предлагает сервер: множество имён.
---
--- Сравниваются слова целиком, а не подстроки: сервер, предлагающий
--- `AUTH XOAUTH2`, не предлагает ни PLAIN, ни LOGIN, — а поиск подстрокой
--- нашёл бы в `PLAIN-CLIENTTOKEN` привычный PLAIN и заговорил бы с ним
--- не тем языком. Знак равенства после AUTH (`250-AUTH=CRAM-MD5 PLAIN`)
--- отбрасывается: так писали старые серверы, и smtp4dev пишет до сих пор.
---
--- Слова режет `split()` Tarantool без разделителя: он делит по любым
--- пробельным промежуткам и пустых слов не даёт. Шаблон Lua здесь
--- не годится: мутант его повтора `%S*` находит те же имена, и строку
--- пришлось бы исключать из проверки целиком — вместе с `%S-`, при
--- котором не находится ни одного способа.
---@param extensions table Что назвал сервер в ответе на EHLO
---@return table<string, boolean> Имена способов, как их называет сервер
local function offered(extensions)
    local words = (extensions.AUTH or ''):gsub('^=', ''):upper()
    local names = {}

    for _, word in ipairs(words:split()) do
        names[word] = true
    end

    return names
end

--- Каким способом входить.
---
--- Заданный способ — единственный: если сервер его не предлагает, это
--- отказ, а не повод молча перейти на другой. Иначе пароль, который
--- обещали не отдавать, уехал бы открытым текстом. Неизвестное имя
--- способа — ошибка того, кто настраивал: фасад отсеивает его при
--- настройке, а здесь оно останавливает прямой вызов — с местом в коде,
--- чтобы было видно, откуда пришло.
---@param settings table
---@param extensions table
---@return string|nil method Имя способа в разговоре с сервером
---@return string|nil err
local function choose(settings, extensions)
    local names = offered(extensions)

    if settings.auth ~= nil then
        local wanted = Module.METHODS[settings.auth]

        if wanted == nil then
            error(('неизвестный способ входа: %s'):format(tostring(settings.auth)))
        end

        if not names[wanted] then
            return nil, ('сервер не предлагает AUTH %s'):format(wanted)
        end

        return wanted
    end

    for _, method in ipairs(PREFERRED) do
        if names[method] then
            return method
        end
    end

    return nil, 'сервер не предлагает ни AUTH CRAM-MD5, ни AUTH PLAIN, ни AUTH LOGIN'
end

--- Строка в base64 одной строкой.
---
--- Перенос строки посреди команды AUTH — конец команды для сервера,
--- а `base64_encode` по умолчанию переносит после 76 знаков.
---@param text string
---@return string
local function packed(text)
    return digest.base64_encode(text, { nowrap = true })
end

--- Что сервер прислал после кода ответа, раскодированное из base64.
---
--- В `334` сервер шлёт вызов CRAM-MD5 либо причину отказа XOAUTH2 —
--- и то и другое в base64. Пустой хвост раскодируется в пустую строку.
--- Код в начале есть всегда: без него `answer` ответа не возвращает.
---@param text string Ответ сервера с кодом
---@return string
local function unpacked(text)
    local encoded = text:match('^%d%d%d%s*(%S*)')
    ---@cast encoded string

    return digest.base64_decode(encoded)
end

--- Способы входа: разговор каждого от AUTH до 235.
---@type table<string, fun(link: table, settings: table): boolean, string|nil>
local ways = {}

ways.PLAIN = function(link, settings)
    local secret = packed(('\0%s\0%s'):format(settings.username, settings.password or ''))

    local ok, text = expect(link, 'AUTH PLAIN ' .. secret, Module.AUTHENTICATED, 'вход')

    if not ok then
        return false, text
    end

    return true
end

ways.LOGIN = function(link, settings)
    local started, text = expect(link, 'AUTH LOGIN', Module.CONTINUE, 'вход')

    if not started then
        return false, text
    end

    local named, named_text = expect(link, packed(settings.username), Module.CONTINUE, 'вход: имя')

    if not named then
        return false, named_text
    end

    local ok, secret_text =
        expect(link, packed(settings.password or ''), Module.AUTHENTICATED, 'вход: пароль')

    if not ok then
        return false, secret_text
    end

    return true
end

--- CRAM-MD5 по RFC 2195: сервер шлёт вызов, мы отвечаем именем
--- и шестнадцатеричным HMAC-MD5 от вызова на ключе-пароле.
ways['CRAM-MD5'] = function(link, settings)
    local started, text = expect(link, 'AUTH CRAM-MD5', Module.CONTINUE, 'вход')

    if not started then
        return false, text
    end

    local challenge = unpacked(text)

    if challenge == '' then
        return false, 'вход: сервер не прислал вызов CRAM-MD5'
    end

    -- HMAC есть в самом Tarantool, но не в описании его типов: проверке
    -- типов о поле crypto.hmac знать неоткуда.
    ---@diagnostic disable-next-line: undefined-field
    local signature = crypto.hmac.md5_hex(settings.password or '', challenge)
    local reply = ('%s %s'):format(settings.username, signature)

    local ok, reply_text = expect(link, packed(reply), Module.AUTHENTICATED, 'вход: отзыв')

    if not ok then
        return false, reply_text
    end

    return true
end

--- XOAUTH2, как его описывает Google: имя и токен одной строкой сразу
--- в команде. Отказ сервер отдаёт не сразу: сначала `334` с причиной
--- в base64 (JSON со статусом), и ждёт пустой строки, чтобы ответить
--- окончательным `535`. Кто пустую строку не шлёт, тот читает `535`
--- вместо ответа на MAIL FROM и не понимает, что случилось. Причина
--- приписывается к окончательному ответу, каким бы он ни был, — и к
--- молчанию сервера тоже.
ways.XOAUTH2 = function(link, settings)
    local code, text = say(link, 'AUTH XOAUTH2 ' .. transport.xoauth2(settings))

    if code == Module.CONTINUE then
        local reason = unpacked(text)
        local finished, final_text = expect(link, '', Module.AUTHENTICATED, 'вход')

        if not finished then
            return false, ('%s; причина: %s'):format(final_text, reason)
        end

        return true
    end

    if code == nil then
        return false, ('вход: %s'):format(text)
    end

    if code ~= Module.AUTHENTICATED then
        return false, ('вход: сервер ответил %d — %s'):format(code, text)
    end

    return true
end

--- Входит под учётной записью.
---
--- Способ выбирает сервер списком расширений, а вызывающий — настройкой
--- `auth`, если хочет ровно один. Пароль по открытому каналу виден всем,
--- у кого есть сеть, — поэтому вызывающий обязан либо поднять TLS, либо
--- признать это явно; решается это не здесь, а в `tnt.mail`.
---@param link table
---@param settings table
---@param extensions table
---@return boolean ok
---@return string|nil err
local function authenticate(link, settings, extensions)
    if settings.username == nil then
        return true
    end

    local method, err = choose(settings, extensions)

    if method == nil then
        return false, err
    end

    return ways[method](link, settings)
end

--- Отдаёт письмо серверу.
---@param link table
---@param letter table
---@param body string
---@return boolean ok
---@return string|nil err
local function deliver(link, letter, body)
    local sender = message.bare(letter.from)
    local from_ok, from_text = expect(link, ('MAIL FROM:<%s>'):format(sender), Module.OK, 'отправитель')

    if not from_ok then
        return false, from_text
    end

    local recipients = message.recipients(letter)

    if #recipients == 0 then
        return false, 'получателей нет: письмо некому отдать'
    end

    for _, address in ipairs(recipients) do
        local to_ok, to_text =
            expect(link, ('RCPT TO:<%s>'):format(address), Module.OK, 'получатель ' .. address)

        if not to_ok then
            return false, to_text
        end
    end

    local ready, ready_text = expect(link, 'DATA', Module.DATA_READY, 'начало письма')

    if not ready then
        return false, ready_text
    end

    local sent, sent_text = expect(link, Module.stuff(body) .. transport.CRLF .. '.', Module.OK, 'письмо')

    if not sent then
        return false, sent_text
    end

    return true
end

--- Отправляет письмо.
---
--- Соединение закрывается в любом исходе: сервер, которому не сказали
--- QUIT, держит его до своего срока, а таких соединений у него сотня.
---@param given table Куда и под кем ходить; пароль — строка либо поставщик
---@param letter table Письмо
---@param body string Готовый текст письма
---@return boolean ok
---@return string|nil err
function Module.send(given, letter, body)
    -- Пароль-поставщик зовётся до соединения: без токена будить сервер
    -- незачем.
    local settings, refusal = transport.credentials(given)

    if settings == nil then
        return false, refusal
    end

    local link, err = transport.connect(settings)

    if link == nil then
        return false, err
    end

    local done, reason, last = Module.talk(link, settings, letter, body)

    -- Прощание не влияет на исход: письмо либо принято, либо нет,
    -- и отказ на QUIT о нём уже ничего не говорит. Идёт оно по тому
    -- соединению, на котором кончился разговор: после STARTTLS прежнее
    -- негодно — QUIT в него ушёл бы мимо шифрования, а закрытие оставило
    -- бы защищённое с его SSL и SSL_CTX, которых не видит ни один
    -- счётчик Lua.
    pcall(say, last, 'QUIT')
    last.close()

    return done, reason
end

--- Весь разговор от приветствия до точки.
---
--- Вынесен отдельно, чтобы закрытие соединения не зависело от того,
--- на каком шаге всё пошло не так. Третьим значением отдаётся
--- соединение, на котором разговор кончился, — в любом исходе: после
--- STARTTLS это защищённое, и прощаться надо на нём.
---@param link table
---@param settings table
---@param letter table
---@param body string
---@return boolean ok
---@return string|nil err
---@return table last Соединение, на котором кончился разговор
function Module.talk(link, settings, letter, body)
    local extensions, greeting_error = greet(link, settings.helo or 'tarantool')

    if extensions == nil then
        return false, greeting_error, link
    end

    if settings.tls == 'starttls' then
        local raised, raise_error

        link, raised, raise_error = raise_tls(link, settings, extensions)

        if raised == nil then
            return false, tostring(raise_error), link
        end

        extensions = raised
    end

    local entered, auth_error = authenticate(link, settings, extensions)

    if not entered then
        return false, auth_error, link
    end

    local delivered, deliver_error = deliver(link, letter, body)

    return delivered, deliver_error, link
end

return Module
