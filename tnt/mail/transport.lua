--- Соединение с почтовым сервером.
---
--- SMTP — текстовый протокол поверх TCP: строки, оканчивающиеся CRLF.
--- Всё, что знает этот модуль, — как соединиться, прочитать строку
--- и написать строку; разговором заняты модули протоколов.
---
--- Сроки обязательны на каждой операции. Почтовый сервер — чужая машина,
--- и повисшее соединение к нему останавливает не почту, а того, кто
--- её отправлял: обход диагностики, такт уведомителя, запрос оператора.
--- Сокет без срока ждёт вечно.
---
--- Шифрование поднимается двумя способами, и они не взаимозаменяемы.
--- На портах 465, 993 и 995 оно начинается с первого байта — это `direct`,
--- и тогда соединение сразу заводится через `tnt.tls`. В STARTTLS разговор
--- начинается открытым текстом, клиент просит сервер перейти на шифрование
--- и поднимает TLS поверх того же сокета — это `secure`, и зовёт его
--- не транспорт, а сессия: только она знает, в какой миг разговора сервер
--- согласился.
---
--- Открытый канал остаётся умолчанием: почтовый релей на том же хосте —
--- обычное дело, и требовать от него сертификат значило бы сделать пакет
--- бесполезным там, где он полезнее всего. Но пароль по такому каналу
--- запрещён, и разрешается он только явной настройкой — решается это
--- в `tnt.mail`, а не здесь.

local digest = require('digest')

local external = require('tnt.external')

local Module = {}

--- Чем оканчивается строка протокола.
---
--- Ровно CRLF, а не «перевод строки»: сервер, читающий строки по CRLF,
--- на одиноком LF ждёт продолжения до самого срока.
Module.CRLF = '\r\n'

--- Сколько ждать сервер, если не сказано иное.
local DEFAULT_TIMEOUT = 5

--- Внешние средства: сеть и шифрование.
local source = external.install(Module, {
    connect = function(host, port, timeout)
        return require('socket').tcp_connect(host, port, timeout)
    end,

    connect_secure = function(opts)
        return require('tnt.tls').connect(opts)
    end,

    upgrade = function(socket, opts)
        return require('tnt.tls').wrap(socket, opts)
    end,
})

---@class TntMailLink
---@field read_line fun(): string|nil, string|nil Строка ответа без CRLF
---@field read_chunk fun(size: integer): string|nil, string|nil Ровно столько байт
---@field write fun(text: string): boolean, string|nil Отправить как есть
---@field close fun() Закрыть соединение
---@field raw any Сам сокет: нужен, чтобы поднять поверх него TLS
---@field secured boolean Шифруется ли уже этот разговор

---@class TntMailWhere
---@field host string|nil Куда соединяться
---@field port integer|nil Порт
---@field timeout number|nil Срок каждой операции
---@field tls string|nil none, starttls либо direct
---@field verify boolean|nil Проверять ли сертификат
---@field ca_file string|nil Свой файл доверенных корней
---@field ca_path string|nil Свой каталог доверенных корней

--- Настройки шифрования для `tnt.tls`.
---
--- Имя узла обязательно и берётся из настроек соединения: сертификат
--- выписан на имя, а не на адрес, и сокет своего имени не помнит.
---@param opts table
---@return table
local function secrecy(opts)
    return {
        host = opts.host,
        port = opts.port,
        timeout = opts.timeout or DEFAULT_TIMEOUT,
        verify = opts.verify,
        ca_file = opts.ca_file,
        ca_path = opts.ca_path,
    }
end

--- Соединяется с сервером.
---
--- Отказ возвращается причиной, а не исключением: почта — не то дело,
--- ради которого стоит ронять узел, и всякий, кто её шлёт, обязан уметь
--- пережить молчащий сервер.
---@param opts TntMailWhere
---@return TntMailLink|nil link
---@return string|nil err
function Module.connect(opts)
    opts = opts or {}

    local timeout = opts.timeout or DEFAULT_TIMEOUT

    -- На портах 465, 993 и 995 шифрование начинается с первого байта:
    -- открытого приветствия там не будет вовсе, и соединяться надо сразу
    -- защищённо, иначе разговор не начнётся ничем.
    if opts.tls == 'direct' then
        local secured, secure_error = source().connect_secure(secrecy(opts))

        if secured == nil then
            return nil, tostring(secure_error)
        end

        return Module.over(secured, timeout, true)
    end

    local connected, link = pcall(source().connect, opts.host, opts.port, timeout)

    if not connected then
        return nil, tostring(link)
    end

    if link == nil then
        return nil,
            ('соединение с %s:%s не установлено'):format(
                tostring(opts.host),
                tostring(opts.port)
            )
    end

    return Module.over(link, timeout, opts.tls == 'direct')
end

--- Оборачивает сокет в соединение, каким его видит разговор.
---
--- Отдельно от `connect`, потому что зовётся дважды: при соединении
--- и ещё раз после STARTTLS, когда прежний сокет уже спрятан под TLS.
---@param link any Сокет либо защищённое соединение
---@param timeout number Срок каждой операции
---@param secured boolean Шифруется ли разговор
---@return TntMailLink
function Module.over(link, timeout, secured)
    return {
        raw = link,
        secured = secured,

        read_line = function()
            local line, err = link:read({ delimiter = Module.CRLF }, timeout)

            if line == nil or line == '' then
                return nil, tostring(err or 'сервер молчит')
            end

            -- Разделитель снимается здесь, а не у вызывающего: дальше
            -- строка сравнивается с кодами ответа, и хвост из двух
            -- невидимых символов однажды не даст ей совпасть.
            return (line:gsub(Module.CRLF .. '$', ''))
        end,

        read_chunk = function(size)
            -- IMAP отдаёт письмо литералом: строка кончается длиной
            -- в фигурных скобках, а следом идёт ровно столько байт.
            -- Читать их построчно нельзя — внутри письма есть и CRLF,
            -- и строки, похожие на команды.
            local chunk, err = link:read({ chunk = size }, timeout)

            if chunk == nil or #chunk < size then
                return nil, tostring(err or 'сервер отдал меньше, чем обещал')
            end

            return chunk
        end,

        write = function(text)
            local written, err = link:write(text)

            if not written then
                return false, tostring(err or 'запись не удалась')
            end

            return true
        end,

        close = function()
            pcall(link.close, link)
        end,
    }
end

--- Поднимает шифрование поверх начатого разговора.
---
--- Это вторая половина STARTTLS: сервер уже согласился, и с этого места
--- по тому же сокету идёт TLS. Зовёт её сессия, а не транспорт, — только
--- она знает, в какой миг разговора это случилось.
---
--- Прежнее соединение после этого негодно: читать из него нельзя, писать
--- тоже, и вызывающий обязан пользоваться возвращённым.
---@param link TntMailLink Начатый разговор
---@param opts TntMailWhere Настройки соединения
---@return TntMailLink|nil secured
---@return string|nil err
function Module.secure(link, opts)
    local raised, err = source().upgrade(link.raw, secrecy(opts))

    if raised == nil then
        return nil, tostring(err)
    end

    return Module.over(raised, opts.timeout or DEFAULT_TIMEOUT, true)
end

--- Настройки разговора с паролем на этот раз.
---
--- Пароль бывает функцией-поставщиком. У входа XOAUTH2 в нём токен
--- OAuth 2.0, а токен живёт час: взятый при настройке, к вечеру он мёртв.
--- Поставщик зовётся перед каждым соединением и сам решает, отдать
--- прежний токен или взять новый по сроку. Зовётся он до соединения —
--- не получив токена, незачем будить сервер — и только если вход будет:
--- без имени пароль не нужен вовсе.
---
--- Отказ поставщика — отказ разговора, а не исключение: почта не роняет
--- того, кто её шлёт, даже если сломан поставщик. Причина называет его
--- слово целиком — отказ `tnt-oauth2` строкой и есть его текст.
---@param settings table
---@return table|nil settings Копия с паролем строкой либо те же настройки
---@return string|nil err
function Module.credentials(settings)
    if type(settings.password) ~= 'function' or settings.username == nil then
        return settings
    end

    local called, secret, err = pcall(settings.password)

    if not called then
        return nil, ('пароль не получен: поставщик упал: %s'):format(tostring(secret))
    end

    if type(secret) ~= 'string' then
        return nil,
            ('пароль не получен: %s'):format(
                tostring(err or ('поставщик отдал ' .. type(secret)))
            )
    end

    local resolved = table.copy(settings)

    resolved.password = secret

    return resolved
end

--- Чем плохо значение, которое ляжет в строку команды как есть.
---
--- Имя, пароль и папка уходят серверу почти дословно: у IMAP в кавычках,
--- у POP3 — вовсе без них. Перевод строки внутри — вторая команда, которой
--- никто не писал: папка `INBOX"\r\na9 DELETE "Archive` выбирает ящик
--- и стирает архив. Кавычки от этого не спасают: CR и LF внутри них
--- RFC 3501 запрещает, и экранировать их нечем. Папка часто приходит
--- от человека, из формы, поэтому это отказ до разговора, а не починка:
--- исправленная папка — уже не та, что дали.
---
--- В причине управляющие знаки показаны точкой: она идёт в журнал,
--- и рвать его тем же переводом строки незачем. Пароль не показан вовсе:
--- журнал читает не только его хозяин.
---@param label string Что проверяется: имя, пароль, папка
---@param value any Значение; не строка сверяется своим `tostring`
---@param hidden boolean|nil Не показывать значение в причине
---@return string|nil refusal
function Module.tainted(label, value, hidden)
    local text = tostring(value)

    if text:find('%c') == nil then
        return nil
    end

    if hidden then
        return label .. ': управляющий знак'
    end

    return ('%s: управляющий знак в «%s»'):format(label, (text:gsub('%c', '.')))
end

--- Чем плохи имя и пароль для входа: причина либо `nil`.
---
--- Сверяются и тогда, когда вход идёт XOAUTH2: имя и токен там склеены
--- в одну запись знаком `\1`, и управляющий знак внутри них дописывает
--- в неё поле, которого никто не давал.
---@param settings table Настройки с паролем строкой
---@return string|nil refusal
function Module.unsafe(settings)
    return Module.tainted('имя', settings.username) or Module.tainted('пароль', settings.password, true)
end

--- Начальный ответ XOAUTH2: имя и токен одной строкой в base64.
---
--- Запись одна у трёх протоколов — `user=имя^Aauth=Bearer токен^A^A`,
--- как её описывает Google, — и в base64 без переносов: перенос посреди
--- ответа сервер читает концом строки.
---@param settings table Настройки с паролем строкой
---@return string
function Module.xoauth2(settings)
    local payload = ('user=%s\1auth=Bearer %s\1\1'):format(settings.username, settings.password or '')

    return digest.base64_encode(payload, { nowrap = true })
end

--- Ход за письмами: соединиться, поговорить, попрощаться, закрыть.
---
--- У POP3 и у IMAP этот ход один и тот же, и различаются они только
--- разговором и словом прощания — они и есть аргументы. Отдаётся готовая
--- функция: каждый протокол заводит свой ход один раз, при загрузке.
---
--- Прощание идёт через pcall, а закрытие — в любом исходе: на прощании
--- вступают в силу пометки, расставленные в разговоре, но разговор
--- к этому мигу уже кончен, и отказ на выходе не должен затенять то,
--- ради чего ходили.
--- Разговор вправе пересесть на другое соединение — так делает STARTTLS, —
--- и потому третьим значением возвращает то, на котором кончил, в любом
--- исходе, а не только в удачном. Прощаться и закрывать надо именно
--- на нём: прежнее после перехода негодно, «до свидания», сказанное в него,
--- уйдёт мимо шифрования, а защищённое, которое не закрыли, оставит висеть
--- SSL и SSL_CTX — их не видит ни один счётчик Lua.
---
--- То, что ляжет в команду как есть, сверяется до соединения: будить сервер
--- ради отказа незачем, а прощание, сказанное ему, — тоже команда.
---@param talk fun(link: table, settings: table, opts: table): table[]|nil, string|nil, table
---@param farewell fun(link: table) Как прощаться
---@param unsafe fun(settings: table, opts: table): string|nil Чем плохо сказанное дословно
---@return fun(settings: table, opts: table|nil): table[]|nil, string|nil
function Module.fetcher(talk, farewell, unsafe)
    return function(given, opts)
        opts = opts or {}

        local settings, refusal = Module.credentials(given)

        if settings == nil then
            return nil, refusal
        end

        -- Пароль сверяется уже полученный: токен поставщика ляжет
        -- в разговор так же, как строка из настроек.
        refusal = unsafe(settings, opts)

        if refusal ~= nil then
            return nil, refusal
        end

        local link, err = Module.connect(settings)

        if link == nil then
            return nil, err
        end

        local letters, reason, last = talk(link, settings, opts)

        pcall(farewell, last)
        last.close()

        return letters, reason
    end
end

return Module
