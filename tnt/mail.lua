--- Почта узла: отправить письмо и прочитать ящик.
---
--- Узлу нужна почта по двум поводам, и оба скучные: сказать человеку,
--- что случилось, и прочитать ответ, если человек ответил командой.
--- Всё остальное — почтовый клиент, а не кластер.
---
--- Три протокола, и у каждого своя роль. SMTP отправляет. POP3 забирает
--- письма из ящика насовсем. IMAP смотрит письма, не отнимая их
--- у человека, который читает тот же ящик, — и только у него есть папки
--- и флаги.
---
--- Пароль уходит открытым текстом, если не поднят TLS. Это не оговорка
--- мелким шрифтом, а свойство, которое решает, куда такой клиент годится:
--- в доверенную сеть до релея — да, в чужой почтовый сервер через
--- интернет — нет. Поэтому вход с паролем без TLS требует явного
--- признания: настройка `allow_plaintext_auth`. Забыть её нельзя,
--- а прочитав, уже не скажешь, что не знал. Исключение одно —
--- `smtp.auth = 'cram-md5'`: там пароль по проводу не идёт.
---
--- Способ входа в SMTP сервер выбирает сам из тех, что объявил:
--- CRAM-MD5, PLAIN, LOGIN. Настройка `smtp.auth` называет ровно один;
--- `xoauth2` — вход по токену OAuth 2.0 у всех трёх протоколов, и тогда
--- в `password` лежит токен либо функция-поставщик: токен живёт час,
--- и поставщик отдаёт живой перед каждым входом.
---
--- Пользоваться так:
---
---     local mail = require('tnt.mail')
---
---     mail.configure({
---         from = 'tarantool@example.org',
---         smtp = { host = '127.0.0.1', port = 1025 },
---         imap = { host = '127.0.0.1', port = 143, username = 'dev', password = 'dev' },
---     })
---
---     mail.send({ to = 'duty@example.org', subject = 'Реплика отстала', text = '...' })
---
---     mail.send({
---         to = 'duty@example.org',
---         subject = 'Отчёт аудита',
---         text = 'Отчёт во вложении',
---         attachments = { { name = 'audit.csv', type = 'text/csv', content = csv } },
---     })
---
---     for _, letter in ipairs(mail.fetch({ via = 'imap', unseen = true })) do
---         print(letter.subject, letter.text)
---     end
---
--- Отправки видны рядами метрик: `mail_sent_total` по способу и итогу —
--- `sent` либо род отказа — и длительность разговора с сервером
--- (`tnt.mail.series`).
---
--- Письма приложения — объявлениями: тема, получатели, вид на шаблонах
--- и данные, отправка сразу или очередью, предпросмотр в файлах
--- (`tnt.mail.letters`):
---
---     local letters = mail.letters({ views = views, queue = queue.declare('mail') })
---
---     letters:declare('confirm', { subject = 'Подтвердите почту', to = to, view = 'mail.confirm' })
---     letters:queue('confirm', { email = 'maria@example.org', link = link })

local imap = require('tnt.mail.imap')
local declarations = require('tnt.mail.letters')
local message = require('tnt.mail.message')
local parse = require('tnt.mail.parse')
local pop3 = require('tnt.mail.pop3')
local refusals = require('tnt.mail.refusal')
local series = require('tnt.mail.series')
local smtp = require('tnt.mail.smtp')
local plain = require('tnt.mail.text')
local transport = require('tnt.mail.transport')

local log = require('tnt.log').new('tnt.mail')

--- Отказ настройки — словом, без места в коде.
local raise = require('tnt.must.fail').raise

local Module = {}

--- Части: доступны тем, кто собирает своё поведение.
Module.message = message
Module.parse = parse
Module.smtp = smtp
Module.pop3 = pop3
Module.imap = imap
Module.refusal = refusals
Module.text = plain

--- Письма приложения объявлениями (`tnt.mail.letters`). Почта по умолчанию —
--- этот же модуль с его настройками.
Module.letters = declarations.new

--- Порты по умолчанию: те, что назначены протоколам.
---
--- Зависят от способа шифрования, и это не прихоть: у шифрования
--- с первого байта отдельные порты, потому что на обычном сервер ждёт
--- открытого приветствия и на рукопожатие TLS отвечает непониманием.
--- У STARTTLS порт тот же, что у открытого разговора, кроме отправки:
--- 587 — это порт сдачи письма, где шифрование и вход обязательны,
--- а 25 — порт передачи между серверами, где их обычно нет.
local PORTS = {
    none = { smtp = 25, pop3 = 110, imap = 143 },
    starttls = { smtp = 587, pop3 = 110, imap = 143 },
    direct = { smtp = 465, pop3 = 995, imap = 993 },
}

--- Отказ письму без отправителя: и отправке, и сухому прогону.
local NO_SENDER = 'отправитель не задан: сервер не примет письмо без него'

--- Отказ письму без получателей — теми же словами, что у разговора SMTP.
local NO_RECIPIENTS = 'получателей нет: письмо некому отдать'

--- Сколько ждать сервер.
---
--- Пять секунд: почта не та работа, ради которой стоит держать файбер
--- дольше, а сервер, думающий дольше пяти секунд, думает и минуту.
local DEFAULT_TIMEOUT = 5

---@type any
local settings

--- Протоколы по имени настройки: у каждого свои способы входа.
---@type table<string, { METHODS: table<string, string> }>
local PROTOCOLS = { smtp = smtp, pop3 = pop3, imap = imap }

--- Способ входа, каким его понимает протокол.
---
--- У SMTP их четыре, у POP3 и IMAP сверх имени и пароля — один XOAUTH2:
--- настройка, которую протокол молча пропустил бы, обещала бы то, чего
--- нет. Имя приводится к нижнему регистру, как в `METHODS` протокола:
--- `CRAM-MD5` и `cram-md5` — один и тот же способ, а не два.
---@param kind string
---@param given any
---@return string|nil name
---@return string|nil refusal Чем настройка плоха
local function auth_of(kind, given)
    if given == nil then
        return nil
    end

    local name = tostring(given):lower()

    if PROTOCOLS[kind].METHODS[name] == nil then
        return nil, ('неизвестный способ входа %s: %s'):format(kind:upper(), tostring(given))
    end

    return name
end

--- Чем плох пароль: строка и функция-поставщик годятся, прочее — нет.
---@param kind string
---@param password any
---@return string|nil refusal
local function password_of(kind, password)
    local shape = type(password)

    if shape ~= 'nil' and shape ~= 'string' and shape ~= 'function' then
        return ('пароль %s — строка либо функция-поставщик, а не %s'):format(
            kind:upper(),
            shape
        )
    end
end

--- Чем плохи имя и пароль: управляющий знак в них — вторая команда серверу.
---
--- Та же сверка, что у разговора POP3 и IMAP перед входом, но здесь она
--- называет протокол и бросает: имя и пароль пишет тот, кто настраивал,
--- и опечатку с переводом строки он увидит сразу, а не на первом заборе
--- писем посреди ночи. Сверяется и у SMTP, хотя там имя и пароль уходят
--- в base64: общее имя достаётся всем трём протоколам, и годного для одного
--- и негодного для другого не бывает. Функция-поставщик управляющих знаков
--- не несёт; токен, который она отдаст, сверяют POP3 и IMAP перед входом.
---@param kind string
---@param username any
---@param password any
---@return string|nil refusal
local function credentials_of(kind, username, password)
    local whose = kind:upper()

    return transport.tainted('имя ' .. whose, username)
        or transport.tainted('пароль ' .. whose, password, true)
end

--- Своя настройка протокола, а без неё — общая.
---
--- Сравнение с nil, а не `or`: `verify = false` у протокола — решение,
--- и `or` молча подменил бы его общим значением.
---@param given table Свои настройки протокола
---@param common table Общие настройки
---@param key string
---@return any
local function own_or_common(given, common, key)
    if given[key] == nil then
        return common[key]
    end

    return given[key]
end

--- Настройки одного протокола, дополненные умолчаниями.
---
--- Негодная настройка — ошибка того, кто настраивал, и обнаруживается
--- здесь, а не на первом письме посреди ночи.
---@param kind string
---@param opts table|nil
---@param common table
---@return table
local function protocol_of(kind, opts, common)
    local given = opts or {}
    local secrecy = given.tls or common.tls or 'none'
    local ports = PORTS[secrecy]
    local username = given.username or common.username
    local password = given.password or common.password
    local auth, refusal = auth_of(kind, given.auth)

    refusal = refusal or password_of(kind, password) or credentials_of(kind, username, password)

    if ports == nil then
        refusal = ('неизвестный способ шифрования: %s'):format(tostring(secrecy))
    end

    if refusal ~= nil then
        raise(refusal)
    end

    return {
        host = given.host or common.host,
        port = given.port or ports[kind],
        username = username,
        password = password,
        timeout = given.timeout or common.timeout or DEFAULT_TIMEOUT,
        helo = given.helo or common.helo,
        tls = secrecy,

        -- Проверка сертификата и свои корни доверия: релей в своём
        -- контуре часто подписан своим корнем, и без них шифрованное
        -- соединение к нему не поднимается вовсе.
        verify = own_or_common(given, common, 'verify'),
        ca_file = own_or_common(given, common, 'ca_file'),
        ca_path = own_or_common(given, common, 'ca_path'),
        auth = auth,
        allow_plaintext_auth = given.allow_plaintext_auth or common.allow_plaintext_auth or false,
    }
end

---@class TntMailSettings
---@field from string|nil Отправитель по умолчанию
---@field origin string|nil Чем подписывать опознаватель письма; по умолчанию tarantool
---@field to any Получатели по умолчанию
---@field host string|nil Общий адрес сервера для всех протоколов
---@field username string|nil Общая учётная запись
---@field password? string|fun(): string|nil, any Общий пароль либо поставщик токена
---@field timeout number|nil Общий срок ожидания
---@field helo string|nil Каким именем представляться серверу SMTP; по умолчанию tarantool
---@field allow_plaintext_auth boolean|nil Разрешить вход с паролем без шифрования
---@field tls string|nil Общий способ шифрования: none, starttls либо direct
---@field verify boolean|nil Проверять ли сертификат сервера; по умолчанию да
---@field ca_file string|nil Свой файл доверенных корней
---@field ca_path string|nil Свой каталог доверенных корней
---@field smtp table|nil Настройки отправки
---@field pop3 table|nil Настройки POP3
---@field imap table|nil Настройки IMAP

--- Настраивает почту.
---@param opts TntMailSettings|nil
function Module.configure(opts)
    local common = opts or {}

    settings = {
        from = common.from,
        to = common.to,
        origin = common.origin,
        smtp = protocol_of('smtp', common.smtp, common),
        pop3 = protocol_of('pop3', common.pop3, common),
        imap = protocol_of('imap', common.imap, common),
    }
end

--- Собирает письмо, ничего не отправляя.
---
--- Сухой прогон: разработчику нужно видеть, что именно уедет, — а увидеть
--- это иначе можно только на живом сервере, то есть отправив. Отказывает
--- он там же, где отправка: письмо без отправителя или без получателей
--- сервер не примет, и сухой прогон, собравший его с `From: nil`
--- или `To: nil`, обещал бы то, чего нет. Отправка узнаёт об этом здесь
--- же, до соединения с сервером.
---@param letter table
---@param at number|nil
---@return string|nil
---@return string|nil err Почему письмо не собирается: негодное вложение
function Module.render(letter, at)
    local prepared = {}

    for key, value in pairs(letter or {}) do
        prepared[key] = value
    end

    prepared.from = prepared.from or settings.from
    prepared.to = prepared.to or settings.to
    prepared.origin = prepared.origin or settings.origin

    if prepared.from == nil then
        return nil, NO_SENDER
    end

    if #message.recipients(prepared) == 0 then
        return nil, NO_RECIPIENTS
    end

    return message.build(prepared, at)
end

--- Можно ли входить с паролем по этому соединению.
---
--- Пароль по незашифрованному соединению виден всякому, кто смотрит
--- на сеть. Запретить это совсем значит сделать пакет бесполезным там,
--- где сервер стоит рядом; разрешить молча — обмануть того, кто про это
--- не думал. Поэтому разрешение спрашивается явно.
---@param where table
---@return boolean ok
---@return string|nil err
local function allowed(where)
    if where.username == nil then
        return true
    end

    if where.tls ~= 'none' then
        return true
    end

    -- CRAM-MD5 пароль не отдаёт: по проводу идёт отзыв на вызов сервера,
    -- и признавать нечего. Заданный способ — единственный: на другой
    -- отправка не перейдёт, и пароль открытым текстом не уедет.
    if where.auth == 'cram-md5' then
        return true
    end

    if where.allow_plaintext_auth then
        return true
    end

    return false,
        'вход с паролем по незашифрованному соединению запрещён: '
            .. 'поднимите TLS или признайте это настройкой allow_plaintext_auth'
end

--- Отправляет письмо, не считая его: итог, причина и слово итога
--- для рядов метрик.
---
--- Слово — род отказа, как его понимает очередь писем: сервер не задан
--- и пароль без шифрования — `failed` (настройки чинятся без правки
--- письма), письмо без отправителя и несобранное — `invalid`, отказ
--- сервера — по его коду (`tnt.mail.refusal`).
---@param letter table
---@return boolean ok
---@return string|nil err
---@return string outcome `sent` либо род отказа
local function dispatched(letter)
    local where = settings.smtp

    if where.host == nil then
        return false,
            'отправлять некуда: адрес сервера SMTP не задан',
            refusals.FAILED
    end

    local permitted, refusal = allowed(where)

    if not permitted then
        return false, refusal, refusals.FAILED
    end

    local prepared = {}

    for key, value in pairs(letter or {}) do
        prepared[key] = value
    end

    prepared.from = prepared.from or settings.from
    prepared.to = prepared.to or settings.to

    if prepared.from == nil then
        return false, NO_SENDER, refusals.INVALID
    end

    -- Письмо, которое не собралось, — тоже неотправленное: запись
    -- в журнале одна на оба случая, иначе отчёт без вложения пропал бы
    -- тише, чем письмо без сервера.
    local body, err = Module.render(prepared)
    local sent, outcome = false, refusals.INVALID

    if body ~= nil then
        local started = series.started()

        sent, err = smtp.send(where, prepared, body)
        series.spoke(series.SMTP, started)
        outcome = sent and series.SENT or refusals.of(err).kind
    end

    if not sent then
        log.warn('письмо не отправлено', { to = message.addresses(prepared.to), err = err })
    end

    return sent, err, outcome
end

--- Отправляет письмо.
---
--- Каждая отправка ложится в ряды метрик: `mail_sent_total` по способу
--- и итогу, а разговор с сервером — длительностью (`tnt.mail.series`).
---@param letter table
---@return boolean ok
---@return string|nil err
function Module.send(letter)
    local sent, err, outcome = dispatched(letter)

    series.sent(series.SMTP, outcome)

    return sent, err
end

--- Забирает письма из ящика.
---
--- По умолчанию IMAP: он смотрит письма, не отнимая их. POP3 просят
--- явно — там, где ящик принадлежит узлу целиком.
---@class TntMailRequest
---@field via string|nil Чем забирать: imap (по умолчанию) или pop3
---@field limit integer|nil Сколько писем забрать
---@field unseen boolean|nil Только непрочитанные; понимает только IMAP
---@field folder string|nil Папка; понимает только IMAP
---@field mark_seen boolean|nil Пометить прочитанными; понимает только IMAP
---@field delete boolean|nil Удалить забранное

---@param opts TntMailRequest|nil
---@return table[]|nil letters Разобранные письма
---@return string|nil err
function Module.fetch(opts)
    opts = opts or {}

    local via = opts.via or 'imap'
    local where = settings[via]

    if where == nil then
        return nil, ('неизвестный способ забрать почту: %s'):format(tostring(via))
    end

    if where.host == nil then
        return nil,
            ('забирать неоткуда: адрес сервера %s не задан'):format(via:upper())
    end

    local permitted, refusal = allowed(where)

    if not permitted then
        return nil, refusal
    end

    local taken, err = (via == 'pop3' and pop3 or imap).fetch(where, opts)

    if taken == nil then
        return nil, err
    end

    local letters = {}

    for _, raw in ipairs(taken) do
        local letter = parse.of(raw.raw)

        letter.number = raw.number
        letter.id = raw.id
        letter.raw = raw.raw

        table.insert(letters, letter)
    end

    return letters
end

--- Какие папки есть в ящике. Только IMAP: у POP3 папок не бывает.
---@return string[]|nil
---@return string|nil err
function Module.folders()
    if settings.imap.host == nil then
        return nil, 'адрес сервера IMAP не задан'
    end

    return imap.folders(settings.imap)
end

--- Что настроено.
---
--- Паролей здесь нет и не будет: состояние читают и журнал, и панель,
--- и человек через плечо.
---@return table
function Module.status()
    local shown = {}

    for _, kind in ipairs({ 'smtp', 'pop3', 'imap' }) do
        local where = settings[kind]

        shown[kind] = {
            host = where.host,
            port = where.port,
            username = where.username,
            tls = where.tls,
            auth = where.auth,
            timeout = where.timeout,
        }
    end

    shown.from = settings.from

    return shown
end

Module.configure(nil)

return Module
