--- Разбор отказа доставки: что сказал сервер и стоит ли пробовать снова.
---
--- Отправка отказывает строкой, и строка эта — договор пакета: шаг
--- разговора, код ответа и ответ сервера целиком, «получатель
--- nobody@example.org: сервер ответил 550 — 550 5.1.1 mailbox unavailable».
--- Очереди писем нужно не описание, а решение: повторить либо зарыть. Его
--- даёт код ответа SMTP (RFC 5321, 4.2.1):
---
--- | Отказ | Род | Повтор |
--- |---|---|---|
--- | 5xx — «не пробуйте больше»: адреса нет, отказано навсегда | `rejected` | нет |
--- | 4xx — «попробуйте позже»: сервер занят, ящик полон | `deferred` | да |
--- | без кода: сети нет, срок вышел, шифрование не поднялось, токена нет | `failed` | да |
--- | письмо негодно ещё до сервера: вложение, управляющий знак | `invalid` | нет |
---
--- Повторять 5xx значит слать один и тот же отказ до конца света, а зарыть
--- 4xx — потерять письмо, которое сервер просил принести позже. Отказ без
--- кода повторяется: и сеть, и настройки, и поставщик токена чинятся без
--- правки письма, а зарытое после исчерпанных попыток видно человеку.
---
--- Сверх рода отказ несёт то, что назвал сервер: код ответа, расширенный
--- код RFC 3463 (`5.1.1` — такого ящика нет, `4.2.2` — ящик полон) и адрес
--- получателя, которого сервер не принял. По ним приложение решает, что
--- делать с адресом, — например, перестать слать на ящик, которого нет.

local Module = {}

--- Сервер отказал навсегда: повтор получит тот же ответ.
Module.REJECTED = 'rejected'

--- Сервер просил попробовать позже.
Module.DEFERRED = 'deferred'

--- Ответа сервера нет: сеть, срок, шифрование, настройки, поставщик токена.
Module.FAILED = 'failed'

--- Письмо негодно ещё до сервера: его не собрать, и повтор ничего не даст.
Module.INVALID = 'invalid'

--- Отказ доставки.
---
--- Поля читает очередь писем: `retriable` решает повтор, `message` —
--- причина в зарытом и в журнале. Строкой отказ — та же причина.
---@class TntMailRefusal
---@field kind string Род: `rejected`, `deferred`, `failed` либо `invalid`
---@field message string Причина целиком, как её дала отправка
---@field retriable boolean Стоит ли пробовать снова
---@field code integer|nil Код ответа SMTP
---@field status string|nil Расширенный код RFC 3463: `5.1.1`
---@field recipient string|nil Получатель, которого сервер не принял
local Refusal = {}

Refusal.__index = Refusal

--- Отказ строкой — его причина.
---@return string
function Refusal:__tostring()
    return self.message
end

--- Род отказа по первой цифре кода: остальные коды — не отказ сервера,
--- а непонятый разговор, и он повторяется.
local KINDS = { ['4'] = Module.DEFERRED, ['5'] = Module.REJECTED }

--- Отказ из причины, которую отдала отправка.
---
--- Код ищется в словах, которые пишет сама отправка, а не где попало:
--- число в ответе сервера или в адресе кодом ответа не становится.
---@param reason any Причина отказа `mail.send`
---@return TntMailRefusal
function Module.of(reason)
    local message = tostring(reason)
    local class, rest = message:match('сервер ответил (%d)(%d%d)')
    local kind = KINDS[class] or Module.FAILED

    return setmetatable({
        kind = kind,
        message = message,
        retriable = kind ~= Module.REJECTED,
        code = tonumber((class or '') .. (rest or '')),
        status = message:match('сервер ответил %d%d%d — %d%d%d[ %-]([245]%.%d+%.%d+)'),
        recipient = message:match('^получатель (.-): сервер ответил'),
    }, Refusal)
end

--- Отказ письму, которое не собирается: повторять его незачем.
---@param reason any Почему письмо не собралось
---@return TntMailRefusal
function Module.invalid(reason)
    return setmetatable({ kind = Module.INVALID, message = tostring(reason), retriable = false }, Refusal)
end

return Module
