--- Проверки рядов метрик почты: итог отправки словом и длительность
--- разговора с сервером.
---
--- Разговор SMTP подменяется целиком: ряды считает фасад по тому, чем
--- разговор кончился, а сам разговор проверен своими проверками. Ряды
--- читаются из реестра встроенного `metrics` так же, как их видит
--- сборщик; исходники рядов грузятся заново каждой проверкой, и счёт
--- у каждой свой, с нуля.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = t.group('tnt.mail.series')

---@type any
local mail

---@type any
local series

--- Чем кончится очередной разговор с сервером: `{ ok, err }` по порядку.
---@type table[]
local answers

--- Сколько раз фасад заговорил с сервером.
---@type integer
local conversations

g.before_each(function()
    mail = helper.load('tnt.mail')
    series = helper.module('tnt.mail.series')
    answers = {}
    conversations = 0

    mail.smtp.send = function()
        conversations = conversations + 1

        return unpack(table.remove(answers, 1))
    end

    mail.configure({ from = 'tarantool@example.org', smtp = { host = 'почтовик' } })
end)

g.after_each(function()
    series._set_source(nil)
    helper.unload()
end)

--- Итоги отправок по словам: пусто — таких не было.
---@return table<string, number|nil>
local function outcomes()
    local found = {}

    for _, outcome in ipairs({ 'sent', 'deferred', 'rejected', 'failed', 'invalid' }) do
        found[outcome] = helper.value('mail_sent_total', { transport = 'smtp', outcome = outcome })
    end

    return found
end

--- Письмо дежурному.
local LETTER = { to = 'duty@example.org', subject = 'Реплика отстала', text = 'Подробности' }

-- Итог разговора — слово: отправлено либо род отказа по коду ответа,
-- тот же, по которому очередь писем решает повтор.
g.test_sends_are_counted_by_how_the_server_answered = function()
    answers = {
        { true },
        { true },
        { false, 'письмо: сервер ответил 451 — 451 4.2.2 mailbox full' },
        {
            false,
            'получатель nobody@example.org: сервер ответил 550 — 550 5.1.1 mailbox unavailable',
        },
        { false, 'соединение не установлено: Connection refused' },
    }

    t.assert_equals(mail.send(LETTER), true)
    t.assert_equals(mail.send(LETTER), true)

    for _ = 1, 3 do
        t.assert_equals(mail.send(LETTER), false)
    end

    t.assert_equals(outcomes(), { sent = 2, deferred = 1, rejected = 1, failed = 1 })
    t.assert_equals(helper.value('mail_send_duration_seconds_count', { transport = 'smtp' }), 5)
end

-- До сервера письмо не дошло — отказ тоже считается: настройки — `failed`,
-- негодное письмо — `invalid`; длительности у него нет, разговора не было.
g.test_refusals_before_the_server_are_counted_without_a_duration = function()
    mail.configure({ smtp = { host = 'почтовик' } })
    t.assert_equals(
        { mail.send({ to = 'duty@example.org' }) },
        { false, 'отправитель не задан: сервер не примет письмо без него' }
    )

    mail.configure({ from = 'tarantool@example.org', smtp = { host = 'почтовик' } })
    t.assert_equals(
        { mail.send({ subject = 'Никому' }) },
        { false, 'получателей нет: письмо некому отдать' }
    )

    mail.configure({
        from = 'tarantool@example.org',
        smtp = { host = 'почтовик', username = 'dev', password = 'x' },
    })
    t.assert_equals(mail.send(LETTER), false)

    mail.configure(nil)
    t.assert_equals(
        { mail.send(LETTER) },
        { false, 'отправлять некуда: адрес сервера SMTP не задан' }
    )

    t.assert_equals(conversations, 0)
    t.assert_equals(outcomes(), { invalid = 2, failed = 2 })
    t.assert_equals(helper.value('mail_send_duration_seconds_count', { transport = 'smtp' }), nil)
end

-- Длительность — разговор с сервером по монотонным часам, у отказа тоже;
-- корзины — от 10 мс до минуты.
g.test_the_duration_is_the_conversation_with_the_server = function()
    local moments = { 100, 100.03, 200, 207.5, 300, 390 }

    series._set_source({
        monotonic = function()
            return table.remove(moments, 1)
        end,
    })
    answers = { { true }, { false, 'сервер ответил 421 — 421 закрываюсь' }, { true } }

    mail.send(LETTER)
    mail.send(LETTER)
    mail.send(LETTER)

    local labels = { transport = 'smtp' }

    local function bucket(le)
        return helper.value('mail_send_duration_seconds_bucket', { transport = 'smtp', le = le })
    end

    t.assert_equals(#moments, 0, 'часы спрошены дважды на разговор')
    t.assert_equals(helper.value('mail_send_duration_seconds_count', labels), 3)
    t.assert_almost_equals(helper.value('mail_send_duration_seconds_sum', labels), 97.53, 1e-9)
    t.assert_equals(bucket(0.01), 0)
    t.assert_equals(bucket(0.05), 1)
    t.assert_equals(bucket(5), 1)
    t.assert_equals(bucket(10), 2)
    t.assert_equals(bucket(60), 2)
    t.assert_equals(bucket(math.huge), 3)
    t.assert_equals(outcomes(), { sent = 2, deferred = 1 })
    t.assert_equals(series.BUCKETS, { 0.01, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30, 60 })
    t.assert_equals({ series.SMTP, series.SENT, series.TRANSPORTS }, { 'smtp', 'sent', 10 })
end

-- Письма объявлениями с почтой по умолчанию уходят той же отправкой
-- и ложатся в те же ряды.
g.test_letters_through_the_mail_are_counted_too = function()
    local letters = mail.letters({ mailer = mail })

    answers = {
        { true },
        {
            false,
            'получатель nobody@example.org: сервер ответил 550 — 550 5.1.1 no such user',
        },
    }

    t.assert_equals(letters:deliver({ body = { mail = LETTER } }), true)

    local sent, err = letters:deliver({ body = { mail = LETTER } })

    t.assert_equals(sent, nil)
    t.assert_equals(err.kind, 'rejected')
    t.assert_equals(outcomes(), { sent = 1, rejected = 1 })
end
