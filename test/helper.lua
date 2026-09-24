--- Общие средства тестов пакета почты.
---
--- Исходники читаются с диска, а не через `require`: у Tarantool свой
--- загрузчик `.rocks`, он идёт раньше `package.path` и подсунул бы
--- установленную копию пакета, если она есть. Проверки тогда шли бы
--- против вчерашнего кода, а покрытие считалось бы по нему. Зависимости
--- пакета — `tnt.must`, `tnt.id`, `tnt.log`, `tnt.str`, `tnt.tls`,
--- `tnt.fs`, `tnt.metrics`, `tnt.clock`, `tnt.external` — берутся
--- из `.rocks` обычным `require`: проверяется этот пакет, а не они.
--- Исключение — опознаватели и ряды метрик: их установленные файлы
--- грузятся заново вместе с пакетом (ниже). Ловушка журнала ставится
--- на установленный `tnt.log` — тот же экземпляр, которым пишет пакет.
--- Шаблоны и очередь письмам приходят аргументами, и `make deps` ставит
--- их в `.rocks` рядом с зависимостями: проверки писем рисуют настоящим
--- `tnt-template` и повторяют настоящей `tnt-queue`.
---
--- Оснастка в `test/testing/` — загрузчик исходников, ловушка журнала,
--- двойники разговора и сокета, запись файлов и временный узел — грузится
--- так же, файлами, и один раз на процесс: второй экземпляр загрузчика
--- не знал бы, что вытеснил первый, и не вернул бы вытесненное на место.
---
--- Проверки берут всё через помощник, а не из оснастки напрямую: помощник —
--- единственное, чем файл проверок отличается от того же файла в наборе,
--- где пакет живёт рядом со своими зависимостями.

local fio = require('fio')
local t = require('luatest')

--- Реестр встроенного metrics: его методов в аннотациях ядра нет.
---@type any
local registry = require('metrics')

--- Модули оснастки в порядке зависимостей: ловушка журнала берёт
--- загрузчик, узел — загрузчик и запись файлов.
local TESTING = {
    { name = 'tnt.testing.sources', path = 'test/testing/sources.lua' },
    { name = 'tnt.testing.journal', path = 'test/testing/journal.lua' },
    { name = 'tnt.testing.protocol', path = 'test/testing/protocol.lua' },
    { name = 'tnt.testing.files', path = 'test/testing/files.lua' },
    { name = 'tnt.testing.node', path = 'test/testing/node.lua' },
}

for _, module in ipairs(TESTING) do
    if package.loaded[module.name] == nil then
        local chunk, failure = loadfile(fio.abspath(module.path))

        if chunk == nil then
            error(('оснастка %s не читается: %s'):format(module.name, tostring(failure)))
        end

        package.loaded[module.name] = chunk()
    end
end

--- Оснастка проверок под теми именами, что зовёт помощник.
local testing = {
    load_sources = package.loaded['tnt.testing.sources'].load,
    unload_sources = package.loaded['tnt.testing.sources'].unload,
    module = package.loaded['tnt.testing.sources'].module,
    capture_log = package.loaded['tnt.testing.journal'].capture,
    conversation = package.loaded['tnt.testing.protocol'].conversation,
    socket = package.loaded['tnt.testing.protocol'].socket,
    start_node = package.loaded['tnt.testing.node'].start,
    stop_node = package.loaded['tnt.testing.node'].stop,
}

local helper = {}

--- Модули в порядке зависимостей: ряды метрик, опознаватели, затем сам
--- пакет.
helper.MODULES = {}

-- Ряды метрик — установленные модули `tnt-metrics` — грузятся заново
-- на каждую проверку, как и сам пакет. Ряд — состояние процесса: реестр
-- объявленных живёт в модуле, и с одним экземпляром на процесс отправки
-- прошлой проверки и соседних файлов копились бы в тех же рядах. Новый
-- экземпляр объявляет ряды заново и снимает из реестра прежние, так что
-- счёт у каждой проверки свой, с нуля.
--
-- Опознаватели — установленные модули `tnt-id` — грузятся заново по той же
-- причине: общий генератор помнит выданное и запас случайности,
-- и проверка, подменившая часы и случайность, получила бы продолжение
-- последовательности соседней проверки, а не ULID своего мига.
--
-- Файлы — установленной копии, путь называет сам Tarantool: проверяется
-- этот пакет, а не его зависимости.
for _, name in ipairs({
    'tnt.metrics.series.labels',
    'tnt.metrics.series.collector',
    'tnt.metrics.series',
    'tnt.id.octets',
    'tnt.id.quote',
    'tnt.id.crockford',
    'tnt.id.entropy',
    'tnt.id.sequence',
    'tnt.id.uuid7',
    'tnt.id.ulid',
    'tnt.id',
}) do
    local path = package.search(name)

    if path == nil then
        error(('модуль %s не установлен: make deps'):format(name))
    end

    table.insert(helper.MODULES, { name = name, path = path })
end

for _, module in ipairs({
    { name = 'tnt.mail.encode', path = 'tnt/mail/encode.lua' },
    { name = 'tnt.mail.message', path = 'tnt/mail/message.lua' },
    { name = 'tnt.mail.parse', path = 'tnt/mail/parse.lua' },
    { name = 'tnt.mail.text', path = 'tnt/mail/text.lua' },
    { name = 'tnt.mail.refusal', path = 'tnt/mail/refusal.lua' },
    { name = 'tnt.mail.series', path = 'tnt/mail/series.lua' },
    { name = 'tnt.mail.preview', path = 'tnt/mail/preview.lua' },
    { name = 'tnt.mail.letters', path = 'tnt/mail/letters.lua' },
    { name = 'tnt.mail.transport', path = 'tnt/mail/transport.lua' },
    { name = 'tnt.mail.smtp', path = 'tnt/mail/smtp.lua' },
    { name = 'tnt.mail.pop3', path = 'tnt/mail/pop3.lua' },
    { name = 'tnt.mail.imap', path = 'tnt/mail/imap.lua' },
    { name = 'tnt.mail', path = 'tnt/mail.lua' },
}) do
    table.insert(helper.MODULES, module)
end

--- Модули проверок писем-объявлений — те же исходники пакета: шаблоны
--- берутся из `.rocks`, как и зависимости.
helper.LETTER_MODULES = helper.MODULES

--- Модули временного узла — те же исходники: шаблоны и очередь узел
--- берёт из `.rocks`.
---
--- Очередь на узле нужна потому, что повтор и зарывание держатся
--- на спейсах `box`: двойник спейса доказал бы лишь, что мы правильно
--- разговариваем сами с собой.
helper.NODE_MODULES = helper.MODULES

--- Каталог видов-образцов.
helper.VIEWS = 'test/views'

--- Файл двойника почты: узел берёт его по пути, замыкание проверки туда
--- не уезжает.
helper.MAILER = 'test/fixtures/mailer.lua'

--- Модуль писем-образцов: его берут проверки и `make mail-preview`.
helper.LETTERS = 'test.fixtures.letters'

--- Двойник почты: сухой прогон фасада, отправка по списку ответов.
helper.mailer_of = dofile(helper.MAILER) --[[@as fun(mail: table): table]]

--- Сверяет, что каждый вызов бросает названный отказ и винит строку
--- вызова в файле проверок, а не внутри пакета.
---
--- Вызов стоит в замыкании первой строкой тела, то есть строкой ниже
--- слова `function`: место броска сверяется с ней целиком — файлом,
--- строкой и текстом.
---@param cases table[] Пары: замыкание с вызовом и текст броска
function helper.assert_blamed(cases)
    for _, case in ipairs(cases) do
        local _, err = pcall(case[1])
        local info = debug.getinfo(case[1], 'S') --[[@as { short_src: string, linedefined: integer }]]

        t.assert_equals(err, ('%s:%d: %s'):format(info.short_src, info.linedefined + 1, case[2]))
    end
end

--- Поднимает временный узел с исходниками пакета; шаблоны и очередь
--- на нём — из `.rocks`. Узел проверка обязана остановить сама — `stop_node`.
---@return table server
function helper.start_node()
    return testing.start_node({ modules = helper.NODE_MODULES })
end

--- Останавливает узел и убирает его каталог.
helper.stop_node = testing.stop_node

--- Уже загруженный модуль: пакета либо его зависимости.
helper.module = testing.module

--- Совпадают ли метки: одинаковый набор имён с одинаковыми значениями.
---@param left table
---@param right table
---@return boolean
local function same_labels(left, right)
    for name, value in pairs(left) do
        if right[name] ~= value then
            return false
        end
    end

    for name in pairs(right) do
        if left[name] == nil then
            return false
        end
    end

    return true
end

--- Число ряда с ровно такими метками — как его прочтёт сборщик. Ряды
--- приходят заново с каждой загрузкой пакета, и отправки прошлой
--- проверки в счёт не попадают.
---
--- Реестр читается после обработчиков сбора, как его видит выкладка узла.
---@param name string
---@param labels table|nil
---@return number|nil
function helper.value(name, labels)
    for _, observation in ipairs(registry.collect({ invoke_callbacks = true })) do
        if observation.metric_name == name and same_labels(observation.label_pairs, labels or {}) then
            return observation.value
        end
    end

    return nil
end

--- Ловушка журнала: записи пакета видны проверке, а не только в выводе.
---@type fun(): TntTestingJournal
helper.capture_log = testing.capture_log

--- Загружает пакет из исходников и возвращает названный модуль.
---
--- Заново на каждую проверку: настройки, подменённый транспорт и крюки
--- живут в модулях, и оставленные соседней проверкой сделали бы порядок
--- проверок частью их смысла.
---@param name string Какой модуль отдать: tnt.mail, tnt.mail.smtp…
---@return any
function helper.load(name)
    return testing.load_sources(helper.MODULES, name)
end

--- Убирает исходники и возвращает то, что они вытеснили.
function helper.unload()
    testing.unload_sources(helper.MODULES)
end

--- Загружает почту для писем и отдаёт названный модуль.
---
--- Шаблоны — установленная копия: проверки писем рисуют настоящим
--- `tnt-template`, и он должен быть загружен раньше, чем проверка
--- попросит его у помощника.
---@param name string
---@return any
function helper.load_letters(name)
    require('tnt.template')

    return testing.load_sources(helper.LETTER_MODULES, name)
end

--- Убирает исходники почты.
function helper.unload_letters()
    testing.unload_sources(helper.LETTER_MODULES)
end

--- Письмо под указанным номером; его отсутствие — ошибка самой проверки.
---@param letters any
---@param index integer
---@return any
function helper.at(letters, index)
    return (assert((letters or {})[index], ('письма №%d нет'):format(index)))
end

--- Где стоит Mailpit стенда: те же адреса, что поднимает `test/stand/mail.sh`.
helper.MAILPIT = { host = '127.0.0.1', smtp = 1025, pop3 = 1110, api = 8025 }

--- Адрес, которого нет ни у одной другой проверки: письма ищутся по нему.
---
--- Ящик Mailpit один на машину, и живые проверки идут разом из нескольких
--- рабочих копий дерева: чистка ящика стирала бы письма соседа посреди
--- его проверки, а «единственное письмо в ящике» могло бы оказаться чужим.
---@param name string Начало адреса: по нему письмо видно в ящике глазами
---@return string
function helper.unique_address(name)
    return ('%s-%s@example.org'):format(name, require('uuid').str():sub(1, 8))
end

--- Письмо, которое Mailpit принял на этот адрес, — его собственным API.
---@param address string
---@return table message Со всеми частями: `Text`, `HTML`, `Attachments`…
function helper.received(address)
    local json = require('json')
    local http = require('http.client').new()
    local api = ('http://%s:%d/api/v1'):format(helper.MAILPIT.host, helper.MAILPIT.api)
    ---@type table
    local found

    t.helpers.retrying({ timeout = 5 }, function()
        local query = require('uri').escape(('to:"%s"'):format(address), require('uri').FORM_URLENCODED)
        local listed = json.decode(assert(http:get(api .. '/search?query=' .. query, { timeout = 2 }).body))

        found = assert(listed.messages[1], 'письма ещё нет')
    end)

    return json.decode(assert(http:get(api .. '/message/' .. found.ID, { timeout = 2 }).body))
end

--- Двойник соединения: сервер отвечает заранее написанными строками.
---
--- Протоколы почты — это разговор, и проверять их надо разговором:
--- двойник из оснастки помнит, что сказали мы, и отдаёт то, что должен
--- был бы ответить сервер; кончившиеся реплики — молчание, а не ошибка
--- проверки: замолчавший сервер — обычный сценарий почты.
---@type fun(replies: string[]): TntTestingConversation, table
helper.link_of = testing.conversation

--- Двойник сокета: то, что отдаёт `socket.tcp_connect`.
---
--- Нужен там, где проверяется не разговор, а сам транспорт: он оборачивает
--- сокет, и подменять надо именно сокет, а не готовое соединение.
---@type fun(replies: string[]): TntTestingSocket, table
helper.socket_of = testing.socket

--- Ведущий разговор по названному протоколу.
---
--- Модуль берётся по имени при каждом вызове, а не ссылкой при заведении:
--- перед каждой проверкой исходники грузятся заново, и ссылка, взятая
--- однажды, вела бы в модуль от прошлой проверки.
---@param name string Имя модуля протокола
---@param where table Настройки ящика
---@return fun(answers: string[], opts: table|nil): table[]|nil, string|nil, table
function helper.taker(name, where)
    return function(answers, opts)
        local link, said = helper.link_of(answers)
        local letters, err = testing.module(name).take(link, where, opts or {})

        return letters, err, said
    end
end

--- Разговор через подменённый транспорт.
---
--- Часть проверок смотрит не на сам разговор, а на дорогу к нему: список
--- папок ходит своим соединением, а отсутствие сервера видно только
--- на попытке соединиться. Подменять здесь надо сокет — соединение
--- транспорт заводит сам из того, что ему дали.
---@param answers string[]|nil Что отвечает сервер; `nil` — сервера нет
---@param act fun(): any, any Что сделать, пока транспорт подменён
---@return any
---@return any
function helper.through(answers, act)
    local transport = testing.module('tnt.mail.transport')

    transport._set_source({
        connect = function()
            if answers == nil then
                return nil
            end

            return (helper.socket_of(answers))
        end,
    })

    local first, second = act()

    transport._set_source(nil)

    return first, second
end

--- Разговор, посреди которого поднимается шифрование.
---
--- Настоящего шифрования здесь нет: подменяется сам переход, и дальше
--- разговор идёт по второму двойнику. Проверяется то, ради чего STARTTLS
--- и делают, — что пароль не сказан открытым текстом: всё сказанное
--- до перехода видно в первой таблице, всё сказанное после — во второй.
---@param before string[] Что отвечает сервер открытым текстом
---@param after string[]|nil Что он же отвечает под шифрованием; nil — рукопожатие не удалось
---@param refusal string|nil Причина, по которой рукопожатие не удалось
---@return table plain Соединение до перехода
---@return table said Что сказано открытым текстом
---@return table secret Что сказано под шифрованием
function helper.tls_stage(before, after, refusal)
    local plain, said = helper.link_of(before)
    local secured, secret = helper.link_of(after or {})

    testing.module('tnt.mail.transport').secure = function()
        if after == nil then
            return nil,
                refusal or 'рукопожатие TLS не удалось: сертификат не принят'
        end

        return secured
    end

    return plain, said, secret
end

--- Отправка или ход за письмами, посреди которых поднимается шифрование.
---
--- Соединение транспорт заводит сам из подменённого сокета, а переход
--- подменяется целиком, как в `tls_stage`. Нужен там, где проверяется
--- не сам разговор, а то, что после него: прощание и закрытие обязаны
--- идти по защищённому соединению — прежнее после перехода негодно.
---@param before string[] Что отвечает сервер открытым текстом
---@param after string[] Что он же отвечает под шифрованием
---@param act fun(): any, any Что сделать, пока транспорт подменён
---@return any first
---@return any second
---@return table said Что сказано открытым текстом; `said.closed` — закрыт ли сокет
---@return table secret Что сказано под шифрованием; `secret.closed` — закрыто ли соединение
function helper.through_tls(before, after, act)
    local transport = testing.module('tnt.mail.transport')
    local socket, said = helper.socket_of(before)
    local secured, secret = helper.link_of(after)

    transport._set_source({
        connect = function()
            return socket
        end,
    })

    transport.secure = function()
        return secured
    end

    local first, second = act()

    transport._set_source(nil)

    return first, second, said, secret
end

--- Сверяет ход за письмами, посреди которого поднялось шифрование.
---
--- У POP3 и IMAP проверка одна: удачный ход отдаёт одно письмо, отказ —
--- причину с шагом разговора, и в любом исходе открытым текстом сказана
--- только просьба о переходе, а прощание и закрытие достались
--- защищённому соединению — прежнее после перехода негодно.
---@param case { name: string, err: string|nil } Случай: имя и ожидаемая часть причины
---@param outcome { letters: any, err: any, said: table, secret: table } Что вернул `through_tls`
---@param opening string[] Что сказано открытым текстом
---@param farewell string Чем протокол прощается
function helper.ended_under_tls(case, outcome, opening, farewell)
    if case.err == nil then
        t.assert_equals(outcome.err, nil, case.name)
        t.assert_equals(#outcome.letters, 1, case.name)
    else
        t.assert_equals(outcome.letters, nil, case.name)
        t.assert_str_contains(outcome.err, case.err, false, case.name)
    end

    t.assert_equals(outcome.said, opening, case.name .. ': открытым текстом прощания нет')
    t.assert_equals(
        outcome.secret[#outcome.secret],
        farewell,
        case.name .. ': прощание под шифрованием'
    )
    t.assert_equals(
        outcome.secret.closed,
        true,
        case.name .. ': защищённое соединение закрыто'
    )
end

--- Ведущий разговор, посреди которого поднимается шифрование.
---
--- Модуль берётся по имени при каждом вызове: перед каждой проверкой
--- исходники грузятся заново.
---@param name string Имя модуля протокола
---@param where table Настройки ящика
---@param refusal string|nil Причина, по которой рукопожатие не удалось
---@return fun(before: string[], after: string[]|nil): table[]|nil, string|nil, table, table
function helper.tls_taker(name, where, refusal)
    return function(before, after)
        local plain, said, secret = helper.tls_stage(before, after, refusal)
        local letters, err = testing.module(name).take(plain, where, {})

        return letters, err, said, secret
    end
end

--- Соединение, которое отказывает на записи.
---
--- Приветствие задаётся аргументом: у каждого протокола оно своё,
--- и разговор обязан дойти до первой команды — иначе проверяется
--- не отказ записи, а непонятое приветствие.
---@param greeting string|nil
---@return table
function helper.broken_link(greeting)
    return {
        read_line = function()
            return greeting or '220 сервер готов'
        end,

        read_chunk = function()
            return nil, 'сервер молчит'
        end,

        write = function()
            return false, 'сеть пропала'
        end,

        close = function() end,
    }
end

return helper
