--- Тесты разговора по SMTP: приветствие, вход, конверт, тело, отказы.

local digest = require('digest')
local t = require('luatest')

--- HMAC-MD5 встроенного crypto: в описании типов Tarantool поля hmac нет.
---@param key string
---@param text string
---@return string
local function hmac_md5(key, text)
    ---@diagnostic disable-next-line: undefined-field
    return require('crypto').hmac.md5_hex(key, text)
end

local g = t.group('tnt.mail.smtp')

local helper = dofile('test/helper.lua')

---@type any
local smtp

--- Обычное начало разговора: приветствие и список расширений.
local GREETING = { '220 сервер готов', '250-сервер приветствует', '250 SIZE 10240' }

g.before_each(function()
    smtp = helper.load('tnt.mail.smtp')
end)

g.after_each(function()
    helper.unload()
end)

--- Сшивает ответы сервера на всё письмо целиком.
---@param extra string[]|nil Что отвечает сервер после EHLO
---@return string[]
local function script(extra)
    local lines = {}

    for _, line in ipairs(GREETING) do
        table.insert(lines, line)
    end

    for _, line in
        ipairs(extra or {
            '250 отправитель принят',
            '250 получатель принят',
            '354 давайте письмо',
            '250 письмо принято',
        })
    do
        table.insert(lines, line)
    end

    return lines
end

--- Проводит разговор с заранее написанными ответами сервера.
---@param answers string[]
---@param settings table|nil
---@param letter table|nil
---@return boolean ok
---@return string|nil err
---@return table said
local function talk(answers, settings, letter)
    local link, said = helper.link_of(answers)
    local ok, err = smtp.talk(
        link,
        settings or { helo = 'storage-001-a' },
        letter or { from = 'a@example.org', to = 'b@example.org' },
        'Subject: тема\r\n\r\nтело'
    )

    return ok, err, said
end

g.test_letter_goes_through_the_whole_conversation = function()
    local ok, err, said = talk(script())

    t.assert_equals(ok, true)
    t.assert_equals(err, nil)
    t.assert_equals(said[1], 'EHLO storage-001-a')
    t.assert_equals(said[2], 'MAIL FROM:<a@example.org>')
    t.assert_equals(said[3], 'RCPT TO:<b@example.org>')
    t.assert_equals(said[4], 'DATA')
    t.assert_str_contains(said[5], 'Subject: тема')
    t.assert_str_contains(said[5], '\r\n.')
end

g.test_multiline_greeting_is_read_to_the_end = function()
    -- Ответ сервера бывает многострочным: кто читает одну строку,
    -- тот на втором письме прочитает хвост первого.
    local ok, _, said = talk(script())

    t.assert_equals(ok, true)
    t.assert_equals(said[2], 'MAIL FROM:<a@example.org>', 'разговор не сбился')
end

g.test_old_server_without_ehlo_is_greeted_by_helo = function()
    -- Древний сервер не знает EHLO и отвечает отказом: тогда HELO,
    -- но без расширений, то есть без входа с паролем.
    local ok, _, said = talk({
        '220 сервер готов',
        '500 не знаю такой команды',
        '250 здравствуйте',
        '250 отправитель принят',
        '250 получатель принят',
        '354 давайте письмо',
        '250 письмо принято',
    })

    t.assert_equals(ok, true)
    t.assert_equals(said[1], 'EHLO storage-001-a')
    t.assert_equals(said[2], 'HELO storage-001-a')
end

g.test_server_that_does_not_greet_stops_the_letter = function()
    local ok, err = talk({ '421 занят, приходите позже' })

    t.assert_equals(ok, false)
    t.assert_str_contains(err, 'приветствие')
    t.assert_str_contains(err, '421')
end

g.test_silent_server_is_reported = function()
    local ok, err = talk({})

    t.assert_equals(ok, false)
    t.assert_str_contains(err, 'сервер молчит')
end

g.test_gibberish_instead_of_a_code_is_reported = function()
    -- Не всякий, кто слушает порт 25, говорит по SMTP.
    local ok, err = talk({ 'здравствуйте, это не почтовый сервер' })

    t.assert_equals(ok, false)
    t.assert_str_contains(err, 'непонятный ответ')
end

g.test_refused_recipient_names_the_address = function()
    -- Отказ по одному получателю — самая частая беда, и по сообщению
    -- должно быть видно, по какому именно.
    local ok, err = talk(script({ '250 отправитель принят', '550 нет такого ящика' }))

    t.assert_equals(ok, false)
    t.assert_str_contains(err, 'b@example.org')
    t.assert_str_contains(err, '550')
end

g.test_letter_without_recipients_is_refused_before_the_server = function()
    local ok, err = talk(script(), nil, { from = 'a@example.org' })

    t.assert_equals(ok, false)
    t.assert_str_contains(err, 'получателей нет')
end

g.test_refused_letter_is_reported = function()
    local ok, err = talk(script({
        '250 отправитель принят',
        '250 получатель принят',
        '354 давайте письмо',
        '552 письмо слишком велико',
    }))

    t.assert_equals(ok, false)
    t.assert_str_contains(err, '552')
end

g.test_broken_link_stops_the_conversation = function()
    local ok, err = smtp.talk(
        helper.broken_link(),
        { helo = 'storage-001-a' },
        { from = 'a@b', to = 'c@d' },
        'тело'
    )

    t.assert_equals(ok, false)
    t.assert_str_contains(err, 'сеть пропала')
end

-- ── Вход с паролем ───────────────────────────────────────────────────

g.test_plain_login_is_used_when_offered = function()
    local answers = {
        '220 сервер готов',
        '250-сервер приветствует',
        '250 AUTH PLAIN LOGIN',
        '235 вход выполнен',
        '250 отправитель принят',
        '250 получатель принят',
        '354 давайте письмо',
        '250 письмо принято',
    }

    local ok, _, said = talk(answers, { helo = 'узел', username = 'dev', password = 'secret' })

    t.assert_equals(ok, true)
    t.assert_str_contains(said[2], 'AUTH PLAIN ')

    -- Пароль уходит закодированным, а не зашифрованным: base64 —
    -- способ уложить байты в семь бит, и только.
    local secret = said[2]:match('AUTH PLAIN (.+)$')

    t.assert_equals(require('digest').base64_decode(secret), '\0dev\0secret')
end

g.test_login_by_steps_is_used_when_plain_is_not_offered = function()
    local ok, _, said = talk({
        '220 сервер готов',
        '250-сервер приветствует',
        '250 AUTH LOGIN',
        '334 имя',
        '334 пароль',
        '235 вход выполнен',
        '250 отправитель принят',
        '250 получатель принят',
        '354 давайте письмо',
        '250 письмо принято',
    }, { helo = 'узел', username = 'dev', password = 'secret' })

    t.assert_equals(ok, true)
    t.assert_equals(said[2], 'AUTH LOGIN')
    t.assert_equals(require('digest').base64_decode(said[3]), 'dev')
    t.assert_equals(require('digest').base64_decode(said[4]), 'secret')
end

g.test_wrong_password_is_reported = function()
    local ok, err = talk({
        '220 сервер готов',
        '250 AUTH PLAIN',
        '535 не тот пароль',
    }, { helo = 'узел', username = 'dev', password = 'secret' })

    t.assert_equals(ok, false)
    t.assert_str_contains(err, 'вход')
    t.assert_str_contains(err, '535')
end

g.test_server_without_auth_is_named_as_the_reason = function()
    -- Сервер не предлагает ни одного знакомого способа, а нас просили
    -- войти: отправлять от чужого имени без входа — не то, чего хотели.
    local ok, err = talk(script(), { helo = 'узел', username = 'dev', password = 'secret' })

    t.assert_equals(ok, false)
    t.assert_equals(err, 'сервер не предлагает ни AUTH CRAM-MD5, ни AUTH PLAIN, ни AUTH LOGIN')
end

-- ── CRAM-MD5 ─────────────────────────────────────────────────────────

--- Разговор по CRAM-MD5 с вызовом из RFC 2195.
---@param settings table
---@param final string|nil Чем сервер отвечает на отзыв
---@return boolean ok
---@return string|nil err
---@return table said
local function cram(settings, final)
    return talk({
        '220 сервер готов',
        '250 AUTH CRAM-MD5 PLAIN LOGIN',
        '334 ' .. digest.base64_encode('<1896.697170952@postoffice.reston.mci.net>', { nowrap = true }),
        final or '235 вход выполнен',
        '250 отправитель принят',
        '250 получатель принят',
        '354 давайте письмо',
        '250 письмо принято',
    }, settings)
end

g.test_cram_md5_is_preferred_when_offered = function()
    -- CRAM-MD5 единственный не отдаёт пароль: сервер шлёт вызов, мы —
    -- HMAC-MD5 от него. Ответ сверен с примером из RFC 2195 дословно.
    local ok, err, said = cram({ helo = 'узел', username = 'tim', password = 'tanstaaftanstaaf' })

    t.assert_equals(err, nil)
    t.assert_equals(ok, true)
    t.assert_equals(said[2], 'AUTH CRAM-MD5')
    t.assert_equals(digest.base64_decode(said[3]), 'tim b913a602c7eda7a495b4e6e7334d3890')
    t.assert_equals(said[4], 'MAIL FROM:<a@example.org>')
end

g.test_cram_md5_reply_goes_in_one_line = function()
    local long = string.rep('д', 40)
    local _, _, said = cram({ helo = 'узел', username = long, password = long })

    t.assert_equals(said[3]:find('\n'), nil, 'отзыв уехал одной строкой')
end

g.test_cram_md5_without_a_password_signs_an_empty_key = function()
    -- Пароля нет — ключ пустой, а не исключение посреди разговора:
    -- отказать должен сервер, и его отказ будет назван.
    local ok, err, said = cram({ helo = 'узел', username = 'tim' })

    t.assert_equals(err, nil)
    t.assert_equals(ok, true)
    t.assert_equals(digest.base64_decode(said[3]), 'tim ' .. hmac_md5('', '<1896.697170952@postoffice.reston.mci.net>'))
end

g.test_refused_cram_md5_reply_is_reported = function()
    local ok, err =
        cram({ helo = 'узел', username = 'tim', password = 'не тот' }, '535 отзыв не сошёлся')

    t.assert_equals(ok, false)
    t.assert_str_contains(err, 'вход: отзыв')
    t.assert_str_contains(err, '535')
end

g.test_refused_start_of_cram_md5_is_reported = function()
    local ok, err = talk({
        '220 сервер готов',
        '250 AUTH CRAM-MD5',
        '503 сейчас нельзя',
    }, { helo = 'узел', username = 'tim', password = 'secret' })

    t.assert_equals(ok, false)
    t.assert_equals(err, 'вход: сервер ответил 503 — 503 сейчас нельзя')
end

g.test_cram_md5_without_a_challenge_is_refused = function()
    -- Сервер согласился, а вызова не прислал: подписывать нечего,
    -- и отзыв на пустой вызов был бы отзывом ни на что.
    local ok, err, said = talk({
        '220 сервер готов',
        '250 AUTH CRAM-MD5',
        '334',
    }, { helo = 'узел', username = 'tim', password = 'secret' })

    t.assert_equals(ok, false)
    t.assert_equals(err, 'вход: сервер не прислал вызов CRAM-MD5')
    t.assert_equals(#said, 2, 'после пустого вызова ничего не сказано')
end

g.test_challenge_is_read_after_the_code_and_one_space = function()
    -- Вызов читается после кода и пробела; ответ с несколькими пробелами
    -- тоже разбирается — сервер вправе их поставить.
    local challenge = digest.base64_encode('<вызов@сервер>', { nowrap = true })
    local ok, err, said = talk({
        '220 сервер готов',
        '250 AUTH CRAM-MD5',
        '334   ' .. challenge,
        '235 вход выполнен',
        '250 отправитель принят',
        '250 получатель принят',
        '354 давайте письмо',
        '250 письмо принято',
    }, { helo = 'узел', username = 'tim', password = 'secret' })

    t.assert_equals(err, nil)
    t.assert_equals(ok, true)
    t.assert_equals(digest.base64_decode(said[3]), 'tim ' .. hmac_md5('secret', '<вызов@сервер>'))
end

-- ── Заданный способ ──────────────────────────────────────────────────

g.test_named_method_is_the_only_one_tried = function()
    -- Сервер предлагает и CRAM-MD5, и PLAIN, а настройка называет PLAIN:
    -- разговор идёт по PLAIN, а не по тому, что выбрал бы сам.
    local ok, err, said = talk({
        '220 сервер готов',
        '250 AUTH CRAM-MD5 PLAIN LOGIN',
        '235 вход выполнен',
        '250 отправитель принят',
        '250 получатель принят',
        '354 давайте письмо',
        '250 письмо принято',
    }, { helo = 'узел', username = 'dev', password = 'secret', auth = 'plain' })

    t.assert_equals(err, nil)
    t.assert_equals(ok, true)
    t.assert_str_contains(said[2], 'AUTH PLAIN ')
end

g.test_named_method_the_server_lacks_is_a_refusal_not_a_fallback = function()
    -- Просили CRAM-MD5, сервер предлагает PLAIN: перейти на PLAIN значит
    -- отдать открытым текстом пароль, который обещали не отдавать.
    local ok, err, said = talk({
        '220 сервер готов',
        '250 AUTH PLAIN LOGIN',
    }, { helo = 'узел', username = 'dev', password = 'secret', auth = 'cram-md5' })

    t.assert_equals(ok, false)
    t.assert_equals(err, 'сервер не предлагает AUTH CRAM-MD5')
    t.assert_equals(#said, 1, 'после отказа ничего не сказано')
end

g.test_named_login_is_honoured = function()
    local ok, err, said = talk({
        '220 сервер готов',
        '250 AUTH PLAIN LOGIN',
        '334 имя',
        '334 пароль',
        '235 вход выполнен',
        '250 отправитель принят',
        '250 получатель принят',
        '354 давайте письмо',
        '250 письмо принято',
    }, { helo = 'узел', username = 'dev', password = 'secret', auth = 'login' })

    t.assert_equals(err, nil)
    t.assert_equals(ok, true)
    t.assert_equals(said[2], 'AUTH LOGIN')
end

g.test_unknown_method_is_a_programmer_error = function()
    -- Опечатка в настройке — ошибка того, кто настраивал, а не сервера:
    -- исключение с местом в коде, и дословно о настройке.
    local ok, err = pcall(talk, {
        '220 сервер готов',
        '250 AUTH PLAIN',
    }, { helo = 'узел', username = 'dev', password = 'secret', auth = 'digest-md5' })

    t.assert_equals(ok, false)
    t.assert_str_contains(err, 'smtp.lua:')
    t.assert_str_contains(err, ': неизвестный способ входа: digest-md5')
end

g.test_unusual_spelling_of_the_offer_is_understood = function()
    -- `250-AUTH=CRAM-MD5 PLAIN` — старая запись, и smtp4dev пишет так
    -- до сих пор: знак равенства — не часть первого способа. Регистр
    -- сервер тоже выбирает сам: `cram-md5` — тот же CRAM-MD5.
    t.assert_equals(smtp.extensions('250 AUTH=CRAM-MD5 PLAIN').AUTH, '=CRAM-MD5 PLAIN')

    for _, offer in ipairs({ '250 AUTH=CRAM-MD5', '250 auth cram-md5' }) do
        local ok, err, said = talk({
            '220 сервер готов',
            offer,
            '334 ' .. digest.base64_encode('<вызов>', { nowrap = true }),
            '235 вход выполнен',
            '250 отправитель принят',
            '250 получатель принят',
            '354 давайте письмо',
            '250 письмо принято',
        }, { helo = 'узел', username = 'dev', password = 'secret' })

        t.assert_equals(err, nil, offer)
        t.assert_equals(ok, true, offer)
        t.assert_equals(said[2], 'AUTH CRAM-MD5', offer)
    end
end

-- ── XOAUTH2 ──────────────────────────────────────────────────────────

--- Разговор по XOAUTH2: токен в `password`.
---@param answers string[] Что отвечает сервер после EHLO
---@return boolean ok
---@return string|nil err
---@return table said
local function oauth(answers)
    local lines = { '220 сервер готов', '250 AUTH PLAIN XOAUTH2' }

    for _, line in ipairs(answers) do
        table.insert(lines, line)
    end

    return talk(
        lines,
        { helo = 'узел', username = 'dev@gmail.com', password = 'ya29.токен', auth = 'xoauth2' }
    )
end

g.test_xoauth2_sends_the_token_in_the_first_command = function()
    -- Имя и токен уходят сразу в команде, как описывает Google:
    -- `user=…\1auth=Bearer …\1\1`. Настройка обязательна: сам собой
    -- XOAUTH2 не выбирается — в `password` при нём лежит токен.
    local ok, err, said = oauth({
        '235 вход выполнен',
        '250 отправитель принят',
        '250 получатель принят',
        '354 давайте письмо',
        '250 письмо принято',
    })

    t.assert_equals(err, nil)
    t.assert_equals(ok, true)
    t.assert_equals(
        digest.base64_decode(said[2]:match('^AUTH XOAUTH2 (.+)$')),
        'user=dev@gmail.com\1auth=Bearer ya29.токен\1\1'
    )
    t.assert_equals(said[2]:find('\n'), nil, 'токен уехал одной строкой')
    t.assert_equals(said[3], 'MAIL FROM:<a@example.org>')
end

g.test_xoauth2_is_never_chosen_by_itself = function()
    -- Сервер предлагает только XOAUTH2, настройки нет: отказ, а не
    -- попытка выдать пароль за токен.
    local ok, err = talk({
        '220 сервер готов',
        '250 AUTH XOAUTH2',
    }, { helo = 'узел', username = 'dev', password = 'secret' })

    t.assert_equals(ok, false)
    t.assert_str_contains(err, 'не предлагает')
end

g.test_xoauth2_refusal_is_finished_and_explained = function()
    -- Отказ Google приходит в два шага: `334` с причиной в base64
    -- и `535` после пустой строки от нас. Оба видны в причине, и пустая
    -- строка сказана — иначе `535` прочитался бы ответом на MAIL FROM.
    local reason = '{"status":"401","schemes":"bearer","scope":"https://mail.google.com/"}'
    local ok, err, said = oauth({
        '334 ' .. digest.base64_encode(reason, { nowrap = true }),
        '535-5.7.8 Username and Password not accepted',
        '535 5.7.8 https://support.google.com/mail/?p=BadCredentials',
    })

    t.assert_equals(ok, false)
    t.assert_equals(
        err,
        'вход: сервер ответил 535 — 535-5.7.8 Username and Password not accepted\n'
            .. '535 5.7.8 https://support.google.com/mail/?p=BadCredentials; причина: '
            .. reason
    )
    t.assert_equals(said[3], '', 'пустая строка сказана')
    t.assert_equals(#said, 3)
end

g.test_xoauth2_refusal_without_an_ending_names_the_silence = function()
    -- Сервер объяснил отказ и замолчал: причина всё равно называется.
    local ok, err = oauth({
        '334 ' .. digest.base64_encode('{"status":"400"}', { nowrap = true }),
    })

    t.assert_equals(ok, false)
    t.assert_equals(err, 'вход: сервер молчит; причина: {"status":"400"}')
end

g.test_xoauth2_accepted_after_the_continuation_is_a_success = function()
    -- Сервер, который после `334` всё же ответил `235` на пустую строку,
    -- впустил: разговор идёт дальше, а не объявляется отказом.
    local ok, err, said = oauth({
        '334 ' .. digest.base64_encode('{"status":"200"}', { nowrap = true }),
        '235 вход выполнен',
        '250 отправитель принят',
        '250 получатель принят',
        '354 давайте письмо',
        '250 письмо принято',
    })

    t.assert_equals(err, nil)
    t.assert_equals(ok, true)
    t.assert_equals(said[3], '', 'пустая строка сказана')
    t.assert_equals(said[4], 'MAIL FROM:<a@example.org>')
end

g.test_xoauth2_flat_refusal_is_reported = function()
    local ok, err = oauth({ '535 не тот токен' })

    t.assert_equals(ok, false)
    t.assert_equals(err, 'вход: сервер ответил 535 — 535 не тот токен')
end

g.test_xoauth2_over_a_broken_link_is_reported = function()
    -- Сеть пропала на самой команде AUTH: приветствие прошло, и отказ
    -- обязан говорить о входе, а не о представлении.
    local link = helper.link_of({ '220 сервер готов', '250 AUTH XOAUTH2' })
    local write = link.write

    link.write = function(text)
        if text:match('^AUTH') then
            return false, 'сеть пропала'
        end

        return write(text)
    end

    local ok, err = smtp.talk(
        link,
        { helo = 'узел', username = 'dev', password = 'токен', auth = 'xoauth2' },
        { from = 'a@b', to = 'c@d' },
        'тело'
    )

    t.assert_equals(ok, false)
    t.assert_equals(err, 'вход: сеть пропала')
end

g.test_xoauth2_silent_server_is_reported = function()
    local ok, err = oauth({})

    t.assert_equals(ok, false)
    t.assert_equals(err, 'вход: сервер молчит')
end

g.test_xoauth2_without_a_token_sends_an_empty_bearer = function()
    local ok, _, said = talk({
        '220 сервер готов',
        '250 AUTH XOAUTH2',
        '235 вход выполнен',
        '250 отправитель принят',
        '250 получатель принят',
        '354 давайте письмо',
        '250 письмо принято',
    }, { helo = 'узел', username = 'dev', auth = 'xoauth2' })

    t.assert_equals(ok, true)
    t.assert_equals(digest.base64_decode(said[2]:match('^AUTH XOAUTH2 (.+)$')), 'user=dev\1auth=Bearer \1\1')
end

g.test_methods_are_listed_for_the_facade = function()
    -- Фасад проверяет настройку по этому списку при настройке, а не
    -- посреди отправки: имена в нём — те, что пишут в `auth`.
    t.assert_equals(smtp.METHODS, { ['cram-md5'] = 'CRAM-MD5', plain = 'PLAIN', login = 'LOGIN', xoauth2 = 'XOAUTH2' })
end

g.test_broken_login_steps_are_reported = function()
    local ok, err = talk({
        '220 сервер готов',
        '250 AUTH LOGIN',
        '334 имя',
        '535 имя не годится',
    }, { helo = 'узел', username = 'dev', password = 'secret' })

    t.assert_equals(ok, false)
    t.assert_str_contains(err, 'вход: имя')
end

g.test_refused_start_of_login_is_reported = function()
    local ok, err = talk({
        '220 сервер готов',
        '250 AUTH LOGIN',
        '503 сейчас нельзя',
    }, { helo = 'узел', username = 'dev', password = 'secret' })

    t.assert_equals(ok, false)
    t.assert_str_contains(err, '503')
end

-- ── Точка в начале строки ────────────────────────────────────────────

g.test_leading_dot_is_doubled = function()
    -- Одинокая точка на строке означает конец письма: без удвоения
    -- письмо обрывается посередине, а остаток уходит серверу как
    -- набор команд.
    t.assert_equals(smtp.stuff('первая\r\n.\r\nвторая'), 'первая\r\n..\r\nвторая')
    t.assert_equals(smtp.stuff('.начало'), '..начало')
    t.assert_equals(smtp.stuff('без точек'), 'без точек')
end

g.test_line_endings_are_brought_to_the_protocol = function()
    -- Сервер, читающий строки по CRLF, на одиноком переводе строки
    -- ждёт продолжения до самого срока.
    t.assert_equals(smtp.stuff('первая\nвторая'), 'первая\r\nвторая')
end

g.test_refused_sender_stops_the_letter = function()
    -- Сервер отвергает самого отправителя: так бывает, когда узел шлёт
    -- от имени домена, за который сервер не отвечает.
    local ok, err = talk(script({ '550 не принимаю письма от этого адреса' }))

    t.assert_equals(ok, false)
    t.assert_str_contains(err, 'отправитель')
    t.assert_str_contains(err, '550')
end

g.test_server_that_refuses_data_stops_the_letter = function()
    -- Сервер принял конверт и отказался принимать само письмо: так он
    -- отвечает, когда ящик переполнен или письмо слишком велико.
    local ok, err = talk(script({
        '250 отправитель принят',
        '250 получатель принят',
        '452 не хватает места',
    }))

    t.assert_equals(ok, false)
    t.assert_str_contains(err, 'начало письма')
    t.assert_str_contains(err, '452')
end

g.test_extensions_are_read_from_every_line = function()
    -- Список расширений приходит многострочным ответом, и важны все
    -- строки: AUTH сервер обычно называет в середине, а не в конце.
    local extensions = smtp.extensions(table.concat({
        '250-сервер приветствует',
        '250-SIZE 10240000',
        '250-AUTH PLAIN LOGIN',
        '250-8BITMIME',
        '250 HELP',
    }, '\n'))

    t.assert_equals(extensions.SIZE, '10240000')
    t.assert_equals(extensions.AUTH, 'PLAIN LOGIN')
    t.assert_equals(
        extensions['8BITMIME'],
        '',
        'расширение без хвоста — тоже расширение'
    )
    t.assert_equals(extensions.HELP, '')
end

g.test_lines_without_a_name_are_not_extensions = function()
    -- Строка без имени расширения — это текст приветствия, а не
    -- расширение с пустым именем.
    local extensions = smtp.extensions('250-\n250 HELP')

    t.assert_equals(extensions[''], nil)
    t.assert_equals(extensions.HELP, '')
end

g.test_login_is_taken_from_a_middle_line_of_the_greeting = function()
    -- AUTH объявлен строкой с дефисом, то есть не последней: вход
    -- обязан состояться так же, как если бы он был последним.
    local ok, err, said = talk({
        '220 сервер готов',
        '250-AUTH PLAIN',
        '250 SIZE 10240',
        '235 вход выполнен',
        '250 отправитель принят',
        '250 получатель принят',
        '354 давайте письмо',
        '250 письмо принято',
    }, { helo = 'узел', username = 'дежурный', password = 'секрет' })

    t.assert_equals(ok, true)
    t.assert_equals(err, nil)
    t.assert_str_contains(said[2], 'AUTH PLAIN ')
end

g.test_unknown_authentication_is_not_mistaken_for_a_known_one = function()
    -- `XPLAIN` и `PLAIN-CLIENTTOKEN` — не PLAIN: способ входа ищется
    -- словом целиком, иначе разговор пойдёт не тем языком.
    local ok, err = talk({
        '220 сервер готов',
        '250 AUTH XPLAIN PLAIN-CLIENTTOKEN XLOGIN',
    }, { helo = 'узел', username = 'дежурный', password = 'секрет' })

    t.assert_equals(ok, false)
    t.assert_str_contains(err, 'не предлагает')
end

g.test_offered_methods_are_split_by_any_whitespace = function()
    -- Способы разделяет любой пробельный промежуток, а не ровно один
    -- пробел: при делении по пробелу `LOGIN<TAB>PLAIN` стал бы одним
    -- незнакомым словом, и вход не нашёл бы ни одного способа.
    local ok, err, said = talk({
        '220 сервер готов',
        '250 AUTH LOGIN\tPLAIN  XOAUTH2 ',
        '235 вход выполнен',
        '250 отправитель принят',
        '250 получатель принят',
        '354 давайте письмо',
        '250 письмо принято',
    }, { helo = 'узел', username = 'дежурный', password = 'секрет' })

    local secret = digest.base64_encode('\0дежурный\0секрет', { nowrap = true })

    t.assert_equals(err, nil)
    t.assert_equals(ok, true)
    t.assert_equals(said[2], 'AUTH PLAIN ' .. secret)
end

g.test_long_secret_goes_in_one_line = function()
    -- Base64 длиннее семидесяти шести знаков нельзя разбивать на строки:
    -- перевод строки посреди команды AUTH — конец команды для сервера.
    local long = string.rep('д', 40)

    local _, _, said = talk({
        '220 сервер готов',
        '250 AUTH PLAIN',
        '235 вход выполнен',
        '250 отправитель принят',
        '250 получатель принят',
        '354 давайте письмо',
        '250 письмо принято',
    }, { helo = 'узел', username = long, password = long })

    t.assert_str_contains(said[2], 'AUTH PLAIN ')
    t.assert_equals(said[2]:find('\n'), nil, 'секрет уехал одной строкой')
end

g.test_long_secret_of_the_login_method_goes_in_one_line = function()
    local long = string.rep('д', 40)

    local _, _, said = talk({
        '220 сервер готов',
        '250 AUTH LOGIN',
        '334 имя',
        '334 пароль',
        '235 вход выполнен',
        '250 отправитель принят',
        '250 получатель принят',
        '354 давайте письмо',
        '250 письмо принято',
    }, { helo = 'узел', username = long, password = long })

    t.assert_equals(said[3]:find('\n'), nil, 'имя уехало одной строкой')
    t.assert_equals(said[4]:find('\n'), nil, 'пароль уехал одной строкой')
end

g.test_sent_letter_is_reported_as_sent = function()
    -- Отправка целиком: соединение, разговор, прощание. Отдать `nil`
    -- вместо ответа значит объявить неудачей письмо, которое дошло.
    local sent, err = helper.through({
        '220 сервер готов',
        '250 сервер приветствует',
        '250 отправитель принят',
        '250 получатель принят',
        '354 давайте письмо',
        '250 письмо принято',
        '221 до свидания',
    }, function()
        return smtp.send(
            { host = 'почтовик', port = 25, helo = 'узел' },
            { from = 'a@example.org', to = 'b@example.org' },
            'Subject: тема\r\n\r\nтело'
        )
    end)

    t.assert_equals(sent, true)
    t.assert_equals(err, nil)
end

g.test_extension_name_may_carry_a_dash = function()
    -- Имена с дефисом придумывают почтовые серверы покрупнее: `X-EXPS`
    -- у Exchange — самое известное из них.
    local extensions = smtp.extensions('250-X-EXPS GSSAPI NTLM\n250 HELP')

    t.assert_equals(extensions['X-EXPS'], 'GSSAPI NTLM')
end

g.test_refused_password_of_the_login_method_is_reported = function()
    -- Вход в два шага: имя сервер принял, а пароль отверг. Сказать
    -- об этом надо причиной, иначе письмо молча не уйдёт.
    local ok, err = talk({
        '220 сервер готов',
        '250 AUTH LOGIN',
        '334 имя',
        '334 пароль',
        '535 неверный пароль',
    }, { helo = 'узел', username = 'дежурный', password = 'не тот' })

    t.assert_equals(ok, false)
    t.assert_str_contains(err, 'вход: пароль')
    t.assert_str_contains(err, '535')
end

--- Разговор с переходом на шифрование: письмо уходит уже под ним.
---@param before string[] Что отвечает сервер до перехода
---@param after string[]|nil Что отвечает он же после
---@return boolean ok
---@return string|nil err
---@return table said Что сказано открытым текстом
---@return table secret Что сказано под шифрованием
local function talk_with_tls(before, after)
    local plain, said, secret = helper.tls_stage(before, after)

    local ok, err = smtp.talk(
        plain,
        { helo = 'узел', tls = 'starttls', username = 'дежурный', password = 'секрет' },
        { from = 'a@example.org', to = 'b@example.org' },
        'Subject: тема\r\n\r\nтело'
    )

    return ok, err, said, secret
end

g.test_conversation_moves_under_encryption = function()
    -- Поздороваться заново после перехода обязательно: список расширений
    -- до и после шифрования разный, и AUTH сервер объявляет как раз после.
    local ok, err, said, secret = talk_with_tls({
        '220 сервер готов',
        '250-сервер приветствует',
        '250 STARTTLS',
        '220 переходим на шифрование',
    }, {
        '250-сервер приветствует снова',
        '250 AUTH PLAIN',
        '235 вход выполнен',
        '250 отправитель принят',
        '250 получатель принят',
        '354 давайте письмо',
        '250 письмо принято',
    })

    t.assert_equals(err, nil)
    t.assert_equals(ok, true)
    t.assert_equals(
        said,
        { 'EHLO узел', 'STARTTLS' },
        'открытым текстом — только приветствие и просьба'
    )
    t.assert_equals(secret[1], 'EHLO узел', 'после перехода здороваемся заново')
    t.assert_str_contains(secret[2], 'AUTH PLAIN ')
    t.assert_equals(secret[3], 'MAIL FROM:<a@example.org>')
end

g.test_server_without_starttls_is_refused = function()
    -- Сервер не объявил расширение: просить переход значит получить отказ
    -- и отправить пароль открытым текстом следом.
    local ok, err = talk_with_tls({
        '220 сервер готов',
        '250 сервер приветствует',
    })

    t.assert_equals(ok, false)
    t.assert_str_contains(err, 'не предлагает STARTTLS')
end

g.test_refused_transition_stops_the_conversation = function()
    local ok, err = talk_with_tls({
        '220 сервер готов',
        '250 STARTTLS',
        '454 сегодня без шифрования',
    })

    t.assert_equals(ok, false)
    t.assert_str_contains(err, 'переход на шифрование')
    t.assert_str_contains(err, '454')
end

g.test_failed_handshake_stops_the_conversation = function()
    -- Сервер согласился, а рукопожатие не удалось: письмо не уходит вовсе.
    -- Продолжать открытым текстом нельзя — пароль уже был бы виден.
    local ok, err = talk_with_tls({
        '220 сервер готов',
        '250 STARTTLS',
        '220 переходим на шифрование',
    }, nil)

    t.assert_equals(ok, false)
    t.assert_str_contains(err, 'сертификат не принят')
end

g.test_greeting_after_encryption_must_pass = function()
    local ok, err = talk_with_tls({
        '220 сервер готов',
        '250 STARTTLS',
        '220 переходим на шифрование',
    }, {
        '550 после шифрования вы мне не нравитесь',
    })

    t.assert_equals(ok, false)
    t.assert_str_contains(err, 'представление после шифрования')
end

--- Отправка с переходом на шифрование: соединение заводит сам транспорт.
---@param after string[] Что сервер отвечает под шифрованием
---@return boolean ok
---@return string|nil err
---@return table said Что сказано открытым текстом
---@return table secret Что сказано под шифрованием
local function send_with_tls(after)
    local ok, err, said, secret = helper.through_tls(
        {
            '220 сервер готов',
            '250 STARTTLS',
            '220 переходим на шифрование',
        },
        after,
        function()
            return smtp.send({
                host = 'почтовик',
                port = 587,
                helo = 'узел',
                tls = 'starttls',
                username = 'дежурный',
                password = 'секрет',
            }, { from = 'a@example.org', to = 'b@example.org' }, 'Subject: тема\r\n\r\nтело')
        end
    )

    return ok, err, said, secret
end

g.test_goodbye_goes_under_encryption = function()
    -- После перехода прежнее соединение негодно: QUIT, сказанный в него,
    -- уходит мимо шифрования, а незакрытое защищённое держит SSL и SSL_CTX,
    -- которых не видит ни один счётчик Lua. Так в любом исходе — и когда
    -- письмо принято, и когда разговор оборвался уже под шифрованием.
    local cases = {
        {
            name = 'письмо принято',
            after = {
                '250 AUTH PLAIN',
                '235 вход выполнен',
                '250 отправитель принят',
                '250 получатель принят',
                '354 давайте письмо',
                '250 письмо принято',
                '221 до свидания',
            },
        },
        {
            name = 'вход отвергнут',
            after = { '250 AUTH PLAIN', '535 неверный пароль', '221 до свидания' },
            err = '535',
        },
        {
            name = 'представиться под шифрованием не дали',
            after = {
                '550 после шифрования вы мне не нравитесь',
                '221 до свидания',
            },
            err = 'представление после шифрования',
        },
    }

    for _, case in ipairs(cases) do
        local ok, err, said, secret = send_with_tls(case.after)

        t.assert_equals(ok, case.err == nil, case.name)

        if case.err == nil then
            t.assert_equals(err, nil, case.name)
        else
            t.assert_str_contains(err, case.err, false, case.name)
        end

        t.assert_equals(
            said,
            { 'EHLO узел', 'STARTTLS' },
            case.name .. ': открытым текстом прощания нет'
        )
        t.assert_equals(secret[#secret], 'QUIT', case.name .. ': прощание под шифрованием')
        t.assert_equals(secret.closed, true, case.name .. ': защищённое соединение закрыто')
    end
end

g.test_refused_transition_says_goodbye_in_the_open = function()
    -- Сервер отказал в переходе: разговор так и остался открытым,
    -- и прощаться, и закрывать надо его.
    local ok, err, said, secret = helper.through_tls({
        '220 сервер готов',
        '250 STARTTLS',
        '454 сегодня без шифрования',
        '221 до свидания',
    }, {}, function()
        return smtp.send(
            { host = 'почтовик', port = 587, helo = 'узел', tls = 'starttls' },
            { from = 'a@example.org', to = 'b@example.org' },
            'Subject: тема\r\n\r\nтело'
        )
    end)

    t.assert_equals(ok, false)
    t.assert_str_contains(err, '454')
    t.assert_equals(said[#said], 'QUIT')
    t.assert_equals(said.closed, true)
    t.assert_equals(secret, {}, 'под шифрованием не сказано ничего')
end

-- ── Пароль-поставщик ──────────────────────────────────────────────────

g.test_the_provider_gives_the_token_for_each_letter = function()
    -- Токен живёт час: поставщик зовётся перед каждым письмом и сам
    -- решает, отдать прежний или взять новый.
    local transport = helper.module('tnt.mail.transport')
    local tokens = { 'ya29.первый', 'ya29.второй' }
    local heard = {}

    transport._set_source({
        connect = function()
            local socket, said = helper.socket_of({
                '220 сервер готов',
                '250 AUTH XOAUTH2',
                '235 вход выполнен',
                '250 отправитель принят',
                '250 получатель принят',
                '354 давайте письмо',
                '250 письмо принято',
                '221 до свидания',
            })

            table.insert(heard, said)

            return socket
        end,
    })

    local settings = {
        host = 'smtp.gmail.com',
        helo = 'узел',
        username = 'dev@gmail.com',
        auth = 'xoauth2',
        password = function()
            return table.remove(tokens, 1)
        end,
    }

    for _ = 1, 2 do
        t.assert_equals({ smtp.send(settings, { from = 'dev@gmail.com', to = 'b@example.org' }, 'тело') }, { true })
    end

    transport._set_source(nil)

    local records = {}

    for index, said in ipairs(heard) do
        records[index] = digest.base64_decode(said[2]:match('^AUTH XOAUTH2 (%S+)'))
    end

    t.assert_equals(records, {
        'user=dev@gmail.com\1auth=Bearer ya29.первый\1\1',
        'user=dev@gmail.com\1auth=Bearer ya29.второй\1\1',
    })
end

g.test_a_letter_without_a_token_does_not_connect = function()
    local sent, err = helper.through(nil, function()
        return smtp.send({
            host = 'smtp.gmail.com',
            username = 'dev@gmail.com',
            auth = 'xoauth2',
            password = function()
                return nil, 'служба OAuth 2.0 не ответила'
            end,
        }, { from = 'dev@gmail.com', to = 'b@example.org' }, 'тело')
    end)

    t.assert_equals(
        { sent, err },
        { false, 'пароль не получен: служба OAuth 2.0 не ответила' }
    )
end
