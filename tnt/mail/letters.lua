--- Письма приложения объявлениями: тема, получатели, вид и данные.
---
--- Письмо, собранное склейкой строк по месту, — это тело, которое правят
--- в каждом обработчике по-своему, текст, который расходится с разметкой,
--- и отправка, которая держит запрос на сроке почтовика и теряет письмо
--- с первым его отказом. Объявление собирает письмо в одном месте:
---
---     letters:declare('confirm', {
---         subject = 'Подтвердите почту',
---         to = function(data) return data.email end,
---         view = 'mail.confirm',
---         example = { email = 'maria@example.org', link = 'https://example.org/confirm/1' },
---     })
---
---     letters:queue('confirm', { email = user.email, link = link })
---
--- Разметку рисует движок `tnt-template`, пришедший аргументом `views`,
--- а простой текст выводится из неё же (`tnt.mail.text`): один вид — обе
--- части, и ссылка в тексте не отстанет от ссылки в разметке. Свой текст
--- там, где выведенный не годится, — `text_view`, и рисуется он простым
--- текстом, без экранирования HTML.
---
--- Отправка очередью — `queue`: письмо собирается и проверяется сборкой
--- в файбере вызывающего, и в очередь уходит готовым, простыми данными.
--- Ошибка в шаблоне и негодный адрес падают у того, кто отправлял,
--- а не зарытым сообщением через час. Опознаватель и дата письма ставятся
--- здесь же и едут в очереди: повтор после обрыва уходит тем же письмом,
--- и получатель узнаёт его по `Message-ID`, а не получает второе.
---
--- Очередь — любая, у которой есть `send(body, opts)`, например
--- `tnt-queue`; её обработчик — `letters:handler()`, и итог его — по
--- договору очереди: отказ 5xx зарывает письмо сразу, прочие отказы
--- очередь повторяет со своим отступом (`tnt.mail.refusal`).
---
--- Почта, шаблоны и очередь приходят аргументами: пакет знает их договор,
--- а не их самих.

local must = require('tnt.must')

--- Бросок без места: собирает письмо объявление, и текст называет
--- письмо — строка вызова пакета тут ничего не скажет.
local fail = require('tnt.must.fail').raise

local parse = require('tnt.mail.parse')
local preview = require('tnt.mail.preview')
local refusal = require('tnt.mail.refusal')
local text = require('tnt.mail.text')

local Module = {}

--- Настройки писем. Незнакомый ключ — исключение.
local OPTIONS = { mailer = '?table', views = '?table', queue = '?table', from = '?string|table' }

--- Объявление письма. Всё, кроме видов, — значение либо функция
--- от данных письма.
local DECLARATION = {
    subject = 'string|callable',
    view = '?not_empty',
    text_view = '?not_empty',
    from = '?string|table|callable',
    to = '?string|table|callable',
    cc = '?string|table|callable',
    bcc = '?string|table|callable',
    headers = '?table|callable',
    attachments = '?table|callable',
    example = '?table|callable',
}

--- Поля письма, которые берутся из объявления как есть либо функцией.
local FIELDS = { 'from', 'to', 'cc', 'bcc', 'headers', 'attachments' }

--- Почта писем: договор фасада `tnt.mail`.
---@class TntMailMailer
---@field send fun(letter: table): boolean, any Отправка: `true` либо `false, err`
---@field render fun(letter: table): string|nil, string|nil Сухой прогон: письмо целиком либо `nil, err`

---@class TntMailLetters Письма приложения
---@field mailer TntMailMailer
---@field views table|nil Движок шаблонов: `render(name, data)` и `render_text(name, data)`
---@field outgoing table|nil Очередь писем: у неё спрашивается `send(body, opts)`
---@field from any Отправитель поверх настроек почты
---@field declared table<string, table> Объявления по имени
local Letters = {}
Letters.__index = Letters

--- Значение поля объявления: функцию зовут с данными письма.
---@param value any
---@param data table
---@return any
local function valued(value, data)
    if must.explain.kind(value, nil, 'callable') == nil then
        return value(data)
    end

    return value
end

--- Объявляет письмо.
---
--- Ошибка объявления — исключение на строке вызывающего: письмо без
--- вида, вид без движка шаблонов и имя, объявленное дважды, должны
--- падать при загрузке, а не на первом письме посреди ночи.
---@param name string
---@param declaration table
---@return TntMailLetters
function Letters:declare(name, declaration)
    local caller = must.at(2)
    local where = ('письмо %s'):format(tostring(name))

    caller.not_empty(name, 'имя письма')
    caller.options(declaration, where, DECLARATION)

    if self.declared[name] ~= nil then
        error(('%s уже объявлено'):format(where), 2)
    end

    if declaration.view == nil and declaration.text_view == nil then
        error(('%s: вида нет — дайте view либо text_view'):format(where), 2)
    end

    if self.views == nil then
        error(('%s рисуется шаблоном, а views письмам не дали'):format(where), 2)
    end

    self.declared[name] = declaration

    return self
end

--- Имена объявленных писем по алфавиту.
---@return string[]
function Letters:names()
    local names = {}

    for name in pairs(self.declared) do
        table.insert(names, name)
    end

    table.sort(names)

    return names
end

--- Собирает письмо таблицей: получатели, тема, текст и разметка.
---
--- Негодное объявление или вид — исключение без места с именем письма:
--- так пишет программист, а не получатель.
---@param name string
---@param data table|nil Данные письма: их видят шаблоны и функции объявления
---@return table letter
function Letters:build(name, data)
    local declaration = self.declared[name]
    local given = data or {}

    if declaration == nil then
        fail(
            ('письма %s нет; объявлены: %s'):format(tostring(name), table.concat(self:names(), ', '))
        )
    end

    local complaint = must.explain.kind(given, ('письмо %s: данные'):format(name), 'table')

    if complaint ~= nil then
        fail(complaint)
    end

    local letter = { subject = valued(declaration.subject, given) }

    for _, field in ipairs(FIELDS) do
        letter[field] = valued(declaration[field], given)
    end

    letter.from = letter.from or self.from

    if type(letter.subject) ~= 'string' then
        fail(('письмо %s: тема — строка, а не %s'):format(name, type(letter.subject)))
    end

    -- Движок есть: объявление без него не проходит.
    local views = self.views --[[@as table]]

    if declaration.view ~= nil then
        letter.html = views:render(declaration.view, given)
    end

    if declaration.text_view ~= nil then
        letter.text = views:render_text(declaration.text_view, given)
    else
        letter.text = text.of(letter.html)
    end

    return letter
end

--- Письмо таблицей и оно же собранным целиком.
---
--- Собирает почта — так же, как соберёт отправка, — и негодное письмо
--- (вложение, управляющий знак в адресе из формы) даёт отказ `invalid`
--- ещё до сервера.
---@param self TntMailLetters
---@param name string
---@param data table|nil
---@return table|nil letter
---@return string|nil raw Письмо целиком
---@return TntMailRefusal|nil err
local function assembled(self, name, data)
    local letter = self:build(name, data)
    local raw, err = self.mailer.render(letter)

    if raw == nil then
        return nil, nil, refusal.invalid(('письмо %s: %s'):format(name, tostring(err)))
    end

    return letter, raw
end

--- Собирает письмо целиком, не отправляя: текст либо `nil, err`.
---@param name string
---@param data table|nil
---@return string|nil raw
---@return TntMailRefusal|nil err
function Letters:render(name, data)
    local _, raw, err = assembled(self, name, data)

    return raw, err
end

--- Отправляет письмо сразу, в файбере вызывающего.
---@param name string
---@param data table|nil
---@return true|nil sent
---@return TntMailRefusal|nil err
function Letters:send(name, data)
    local letter, _, refused = assembled(self, name, data)

    if letter == nil then
        return nil, refused
    end

    local sent, err = self.mailer.send(letter)

    if sent then
        return true
    end

    return nil, refusal.of(err)
end

--- Ставит письмо в очередь: `id` сообщения либо `nil, err`.
---
--- Письмо собирается целиком ещё здесь — так же, как соберёт его
--- отправка, — и негодное (вложение, управляющий знак в адресе из формы)
--- в очередь не идёт: отказ `invalid`. Опознаватель и дата сборки
--- остаются в письме и уходят с ним при каждом повторе.
---@param name string
---@param data table|nil
---@param opts table|nil Настройки отправки очереди: `delay`, `ttl`, `key`…
---@return any id
---@return any err
function Letters:queue(name, data, opts)
    if self.outgoing == nil then
        error('письма в очередь: queue письмам не дали', 2)
    end

    local letter, raw, refused = assembled(self, name, data)

    if letter == nil then
        return nil, refused
    end

    -- Опознаватель и дату читает разбор пакета — тот же, что разбирает
    -- чужие письма, — а не образец по месту.
    local parsed = parse.of(raw --[[@as string]])

    letter.message_id = parsed.message_id
    letter.date = parsed.date

    return self.outgoing:send({ letter = name, mail = letter }, opts)
end

--- Отправляет письмо из сообщения очереди.
---
--- Итог — по договору очереди: `true` подтверждает, отказ `rejected`
--- и `invalid` (`retriable == false`) зарывает сразу, прочие — повтор.
--- Сообщение без письма — вход из очереди недоверенный, его могла
--- положить прежняя сборка, — `invalid`.
---@param message { body: any }
---@return true|nil sent
---@return TntMailRefusal|nil err
function Letters:deliver(message)
    local body = message.body

    if type(body) ~= 'table' or type(body.mail) ~= 'table' then
        return nil, refusal.invalid('в сообщении очереди нет письма')
    end

    local sent, err = self.mailer.send(body.mail)

    if sent then
        return true
    end

    return nil, refusal.of(err)
end

--- Обработчик для `queue:consume`.
---@return fun(message: table): true|nil, TntMailRefusal|nil
function Letters:handler()
    return function(message)
        return self:deliver(message)
    end
end

--- Кладёт письма в каталог для просмотра без отправки.
---
--- Каждое письмо собирается с данными из `example` объявления — таблицей
--- либо функцией без аргументов — и ложится тремя файлами: разметка,
--- текст и письмо целиком (`tnt.mail.preview`). Список по умолчанию —
--- все объявленные.
---@param directory string
---@param names string[]|nil
---@return TntMailPreview|nil files Оглавление и файлы каждого письма
---@return string|nil err
function Letters:preview(directory, names)
    local built = {}

    for _, name in ipairs(names or self:names()) do
        local declaration = self.declared[name] or {}
        local letter, raw, refused = assembled(self, name, valued(declaration.example, {}))

        if letter == nil then
            return nil, tostring(refused)
        end

        table.insert(built, { name = name, letter = letter, raw = raw })
    end

    return preview.write(directory, built)
end

--- Заводит письма.
---
--- Почта по умолчанию — фасад `tnt.mail` с его настройками; своя
--- приходит полем `mailer` с `send` и `render` того же договора.
---@param opts { mailer: table|nil, views: table|nil, queue: table|nil, from: any }|nil
---@return TntMailLetters
function Module.new(opts)
    local caller = must.at(2)
    local given = opts or {}

    caller.options(given, 'настройки писем', OPTIONS)

    local mailer = given.mailer or require('tnt.mail')

    caller.callable(mailer.send, 'настройки писем.mailer.send')
    caller.callable(mailer.render, 'настройки писем.mailer.render')

    if given.views ~= nil then
        caller.callable(given.views.render, 'настройки писем.views.render')
        caller.callable(given.views.render_text, 'настройки писем.views.render_text')
    end

    if given.queue ~= nil then
        caller.callable(given.queue.send, 'настройки писем.queue.send')
    end

    return setmetatable({
        mailer = mailer,
        views = given.views,
        outgoing = given.queue,
        from = given.from,
        declared = {},
    }, Letters)
end

return Module
