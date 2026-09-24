--- Разбор отказа доставки: род, повтор и то, что назвал сервер.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = t.group('tnt.mail.refusal')

---@type any
local refusal

g.before_all(function()
    refusal = helper.load('tnt.mail.refusal')
end)

g.after_all(function()
    helper.unload()
end)

--- Поля отказа без метатаблицы: сверка целиком.
---@param found table
---@return table
local function fields(found)
    return {
        kind = found.kind,
        message = found.message,
        retriable = found.retriable,
        code = found.code,
        status = found.status,
        recipient = found.recipient,
    }
end

g.test_permanent_refusal_is_not_retried_and_names_the_recipient = function()
    local reason =
        'получатель nobody@example.org: сервер ответил 550 — 550 5.1.1 mailbox unavailable'

    t.assert_equals(fields(refusal.of(reason)), {
        kind = 'rejected',
        message = reason,
        retriable = false,
        code = 550,
        status = '5.1.1',
        recipient = 'nobody@example.org',
    })
end

g.test_temporary_refusal_is_retried = function()
    local reason = 'письмо: сервер ответил 451 — 451 4.3.0 try again later'

    t.assert_equals(fields(refusal.of(reason)), {
        kind = 'deferred',
        message = reason,
        retriable = true,
        code = 451,
        status = '4.3.0',
    })
end

g.test_class_of_the_code_decides_at_its_edges = function()
    t.assert_equals(refusal.of('письмо: сервер ответил 500 — 500 unknown').kind, 'rejected')
    t.assert_equals(refusal.of('письмо: сервер ответил 599 — 599 x').kind, 'rejected')
    t.assert_equals(refusal.of('письмо: сервер ответил 400 — 400 x').kind, 'deferred')
    t.assert_equals(refusal.of('письмо: сервер ответил 499 — 499 x').kind, 'deferred')
end

g.test_unexpected_code_is_a_failure_that_is_retried = function()
    local found = refusal.of('начало письма: сервер ответил 250 — 250 ok')

    t.assert_equals(fields(found), {
        kind = 'failed',
        message = 'начало письма: сервер ответил 250 — 250 ok',
        retriable = true,
        code = 250,
    })
    t.assert_equals(refusal.of('письмо: сервер ответил 354 — 354 go on').kind, 'failed')
end

g.test_refusal_without_a_server_answer_is_retried = function()
    t.assert_equals(fields(refusal.of('Connection refused')), {
        kind = 'failed',
        message = 'Connection refused',
        retriable = true,
    })
    t.assert_equals(refusal.of(nil).message, 'nil')
end

g.test_code_is_read_only_from_the_words_of_the_package = function()
    -- Число в ответе сервера или в имени шага кодом ответа не становится:
    -- иначе «timeout 550» зарыл бы письмо, которое стоило повторить.
    local found = refusal.of('приветствие: timeout 550 5.1.1')

    t.assert_equals(found.kind, 'failed')
    t.assert_equals(found.code, nil)
    t.assert_equals(found.status, nil)
end

g.test_extended_status_is_found_in_multiline_and_login_answers = function()
    local multiline = refusal.of('письмо: сервер ответил 554 — 554-5.7.1 spam\n554 5.7.1 rejected')
    local login = refusal.of(
        'вход: сервер ответил 535 — 535 5.7.8 bad token; причина: {"status":"401"}'
    )

    t.assert_equals({ multiline.status, multiline.recipient }, { '5.7.1', nil })
    t.assert_equals({ login.kind, login.code, login.status }, { 'rejected', 535, '5.7.8' })
end

g.test_answer_without_extended_status_has_none = function()
    local found = refusal.of('получатель a@b: сервер ответил 550 — 550 mailbox unavailable')

    t.assert_equals(found.status, nil)
    t.assert_equals(found.recipient, 'a@b')
end

g.test_refusal_reads_as_its_message = function()
    t.assert_equals(tostring(refusal.of('Connection refused')), 'Connection refused')
end

g.test_invalid_letter_is_not_retried = function()
    local found = refusal.invalid('вложение №1: имя не задано')

    t.assert_equals(fields(found), {
        kind = 'invalid',
        message = 'вложение №1: имя не задано',
        retriable = false,
    })
    t.assert_equals(tostring(found), 'вложение №1: имя не задано')
    t.assert_equals(
        { refusal.REJECTED, refusal.DEFERRED, refusal.FAILED, refusal.INVALID },
        { 'rejected', 'deferred', 'failed', 'invalid' }
    )
end

g.test_extended_status_has_a_known_class_and_three_numbers = function()
    -- Класс расширенного кода — 2, 4 либо 5 (RFC 3463), и у каждой из двух
    -- частей после класса есть цифры: иначе это не код, а слова сервера.
    for _, text in ipairs({ '1.2.3 x', '5..1 x', '5.1. x', '5.1 x' }) do
        t.assert_equals(refusal.of('письмо: сервер ответил 550 — 550 ' .. text).status, nil, text)
    end

    t.assert_equals(refusal.of('письмо: сервер ответил 250 — 250 2.0.0 ok').status, '2.0.0')
    t.assert_equals(
        refusal.of('письмо: сервер ответил 550 — 550 5.7.26 unauthenticated').status,
        '5.7.26'
    )
end
