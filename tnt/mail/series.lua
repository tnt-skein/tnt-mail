--- Ряды метрик почты: отправки по итогу и длительность разговора
--- с сервером.
---
--- `mail.send` отвечает тому, кто отправлял, а о неотправленном пишет
--- в журнал строку на письмо. Почтовик, который третий час отвечает
--- «попробуйте позже», в журнале — сотня одинаковых строк, а рядом —
--- доля, которую видно на графике и на которую ставится тревога.
---
--- Итог — слово, а не текст отказа: `sent` либо род отказа
--- из `tnt.mail.refusal` — `deferred`, `rejected`, `failed`, `invalid`.
--- Текст пишет чужой сервер и называет получателя, и меткой он был бы
--- без границы. Род тот же, по которому очередь писем решает повтор:
--- на графике видно ровно то, что она сделает с письмом.
---
--- Способ отправки — метка `transport` с потолком: `send` уходит
--- по SMTP, и ряд называет способ, чтобы письма другим способом легли
--- в него же, а не в новый ряд, который пришлось бы складывать с этим.
---
--- Длительность меряется вокруг разговора с сервером — соединение,
--- шифрование, вход и передача письма — монотонными часами: перевод
--- стенных её не сбивает. Письмо, отвергнутое до сервера, в ней не видно:
--- его время — проверка настроек и сборка, и сервер тут ни при чём.

local clock = require('tnt.clock')
local series = require('tnt.metrics.series')
local external = require('tnt.external')
local refusal = require('tnt.mail.refusal')

local Module = {}

--- Сколько разных способов отправки видно в рядах: способ выбирает код,
--- и больше десятка на узле — уже ошибка в коде.
Module.TRANSPORTS = 10

--- Способ отправки `mail.send`.
Module.SMTP = 'smtp'

--- Итог удачной отправки; неудачной — род отказа.
Module.SENT = 'sent'

--- Корзины длительности, секунды: от 10 мс до минуты — релей на том же
--- хосте отвечает за миллисекунды, сервер через интернет с шифрованием —
--- за доли секунды, а зависший держит каждую операцию до её срока.
Module.BUCKETS = { 0.01, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30, 60 }

--- Внешние средства: монотонные часы для длительности.
local source = external.install(Module, { monotonic = clock.monotonic })

local sends = series.counter('mail_sent_total', {
    help = 'Сколько писем отправлялось: по способу и итогу — отправлено либо род отказа',
    labels = {
        transport = Module.TRANSPORTS,
        outcome = { Module.SENT, refusal.DEFERRED, refusal.REJECTED, refusal.FAILED, refusal.INVALID },
    },
})

local durations = series.histogram('mail_send_duration_seconds', {
    help = 'Сколько шёл разговор с почтовым сервером: соединение, вход и передача письма',
    labels = { transport = Module.TRANSPORTS },
    buckets = Module.BUCKETS,
})

--- Отметка начала разговора.
---@return number
function Module.started()
    return source().monotonic()
end

--- Кладёт длительность разговора с сервером.
---@param transport string Способ отправки
---@param started number Отметка `started`
function Module.spoke(transport, started)
    durations:observe(source().monotonic() - started, { transport = transport })
end

--- Считает отправку по итогу.
---@param transport string Способ отправки
---@param outcome string `sent` либо род отказа
function Module.sent(transport, outcome)
    sends:inc(1, { transport = transport, outcome = outcome })
end

return Module
