--- Тесты разговора по POP3: вход, счёт писем, чтение, удаление.

local t = require('luatest')

local g = t.group('tnt.mail.pop3')

local helper = dofile('test/helper.lua')

---@type any
local pop3

--- Настройки ящика.
local WHERE = { username = 'dev', password = 'secret' }

g.before_each(function()
    pop3 = helper.load('tnt.mail.pop3')
end)

g.after_each(function()
    helper.unload()
end)

--- Ведёт разговор с заранее написанными ответами сервера.
local take = helper.taker('tnt.mail.pop3', WHERE)

g.test_letters_are_taken_newest_first = function()
    -- Номера здесь идут по приходу, как у Dovecot и GreenMail: свежие
    -- письма — с конца нумерации, а нужны обычно последние.
    local letters, err, said = take({
        '+OK почтовый ящик готов',
        '+OK',
        '+OK вход выполнен',
        '+OK 2 2048',
        '+OK список опознавателей',
        '1 первый',
        '2 второй',
        '.',
        '+OK письмо',
        'Subject: второе',
        '',
        'тело второго',
        '.',
        '+OK письмо',
        'Subject: первое',
        '',
        'тело первого',
        '.',
    }, { limit = 2 })

    t.assert_equals(err, nil)
    t.assert_equals(#letters, 2)
    t.assert_equals(helper.at(letters, 1).number, 2)
    t.assert_equals(helper.at(letters, 1).id, 'второй')
    t.assert_str_contains(helper.at(letters, 1).raw, 'тело второго')
    t.assert_equals(helper.at(letters, 2).number, 1)
    t.assert_equals(said[1], 'USER dev')
    t.assert_equals(said[2], 'PASS secret')
    t.assert_equals(said[3], 'STAT')
end

g.test_order_follows_numbers_not_the_date_header = function()
    -- Порядок держится на номерах: `Date` пишет отправитель, и письмо
    -- с датой из будущего иначе встало бы первым и у сервера, который
    -- нумерует по приходу.
    local letters, err = take({
        '+OK ящик',
        '+OK',
        '+OK вход',
        '+OK 2 400',
        '-ERR UIDL не поддержан',
        '+OK второе по номеру',
        'Date: Mon, 1 Jan 2001 00:00:00 +0000',
        '',
        'давнее',
        '.',
        '+OK первое по номеру',
        'Date: Fri, 1 Jan 2100 00:00:00 +0000',
        '',
        'из будущего',
        '.',
    }, { limit = 2 })

    t.assert_equals(err, nil)
    t.assert_equals(helper.at(letters, 1).number, 2)
    t.assert_str_contains(helper.at(letters, 1).raw, 'давнее')
    t.assert_equals(helper.at(letters, 2).number, 1)
    t.assert_str_contains(helper.at(letters, 2).raw, 'из будущего')
end

g.test_limit_keeps_the_mailbox_from_arriving_whole = function()
    -- Ящик, в который месяц не заглядывали, иначе приедет на узел
    -- целиком.
    local letters = take({
        '+OK готов',
        '+OK',
        '+OK вход',
        '+OK 5 5000',
        '+OK опознаватели',
        '.',
        '+OK письмо',
        'пятое',
        '.',
    }, { limit = 1 })

    t.assert_equals(#letters, 1)
    t.assert_equals(helper.at(letters, 1).number, 5)
end

g.test_doubled_dot_comes_back_as_one = function()
    -- Точка в начале строки удвоена протоколом: вернуть её обратно —
    -- дело читающего, иначе письмо приезжает испорченным.
    local letters = take({
        '+OK готов',
        '+OK',
        '+OK вход',
        '+OK 1 100',
        '+OK опознаватели',
        '1 первый',
        '.',
        '+OK письмо',
        '..начало строки с точкой',
        '.',
    })

    t.assert_equals(helper.at(letters, 1).raw, '.начало строки с точкой')
end

g.test_empty_mailbox_gives_nothing_and_no_error = function()
    local letters, err = take({
        '+OK готов',
        '+OK',
        '+OK вход',
        '+OK 0 0',
    })

    t.assert_equals(err, nil)
    t.assert_equals(letters, {})
end

g.test_wrong_password_is_reported = function()
    local letters, err = take({ '+OK готов', '+OK', '-ERR неверный пароль' })

    t.assert_equals(letters, nil)
    t.assert_str_contains(err, 'пароль')
    t.assert_str_contains(err, 'неверный пароль')
end

g.test_unknown_user_is_reported = function()
    local letters, err = take({ '+OK готов', '-ERR нет такого ящика' })

    t.assert_equals(letters, nil)
    t.assert_str_contains(err, 'имя')
end

g.test_server_that_does_not_greet_is_reported = function()
    local letters, err = take({ '-ERR ящик заблокирован' })

    t.assert_equals(letters, nil)
    t.assert_str_contains(err, 'приветствие')
end

g.test_unreadable_mailbox_state_is_reported = function()
    local letters, err = take({ '+OK готов', '+OK', '+OK вход', '+OK непонятно' })

    t.assert_equals(letters, nil)
    t.assert_str_contains(err, 'состояние ящика не разобрано')
end

g.test_refused_state_is_reported = function()
    local letters, err = take({ '+OK готов', '+OK', '+OK вход', '-ERR ящик занят' })

    t.assert_equals(letters, nil)
    t.assert_str_contains(err, 'состояние ящика')
end

g.test_refused_letter_names_its_number = function()
    local letters, err = take({
        '+OK готов',
        '+OK',
        '+OK вход',
        '+OK 1 100',
        '+OK опознаватели',
        '.',
        '-ERR письмо удалено',
    })

    t.assert_equals(letters, nil)
    t.assert_str_contains(err, 'письмо 1')
end

g.test_torn_letter_is_reported = function()
    -- Сервер оборвал соединение посреди письма: отдать половину
    -- как целое нельзя.
    local letters, err = take({
        '+OK готов',
        '+OK',
        '+OK вход',
        '+OK 1 100',
        '+OK опознаватели',
        '.',
        '+OK письмо',
        'первая строка',
    })

    t.assert_equals(letters, nil)
    t.assert_str_contains(err, 'письмо 1')
end

g.test_mailbox_without_identifiers_still_works = function()
    -- UIDL поддерживают не все серверы: без него письма забираются
    -- по номерам, просто без устойчивых имён.
    local letters = take({
        '+OK готов',
        '+OK',
        '+OK вход',
        '+OK 1 100',
        '-ERR не умею UIDL',
        '+OK письмо',
        'тело',
        '.',
    })

    t.assert_equals(#letters, 1)
    t.assert_equals(helper.at(letters, 1).id, nil)
end

g.test_deletion_is_asked_for_every_letter = function()
    local _, _, said = take({
        '+OK готов',
        '+OK',
        '+OK вход',
        '+OK 1 100',
        '+OK опознаватели',
        '1 первый',
        '.',
        '+OK письмо',
        'тело',
        '.',
        '+OK помечено',
    }, { delete = true })

    t.assert_equals(said[#said], 'DELE 1')
end

g.test_broken_link_stops_the_conversation = function()
    local letters, err = pop3.take(helper.broken_link('+OK готов'), WHERE, {})

    t.assert_equals(letters, nil)
    t.assert_str_contains(err, 'сеть пропала')
    t.assert_str_contains(err, 'имя', 'разговор оборвался на первой же команде')
end

g.test_control_character_is_refused_before_the_greeting = function()
    -- `USER` и `PASS` идут без кавычек: перевод строки в имени или
    -- пароле — вторая команда серверу, `DELE 1`, которой никто не писал.
    -- Отказ до разговора: серверу не сказано ни слова, даже приветствие
    -- не прочитано. Пароль в причине не показан: она идёт в журнал.
    local cases = {
        {
            where = { username = 'dev\r\nDELE 1', password = 'secret' },
            err = 'имя: управляющий знак в «dev..DELE 1»',
        },
        {
            where = { username = 'dev', password = 'secret\r\nDELE 1' },
            err = 'пароль: управляющий знак',
        },
    }

    for index, case in ipairs(cases) do
        local link, said =
            helper.link_of({ '+OK готов', '+OK имя принято', '+OK вход выполнен' })
        local letters, err, last = pop3.take(link, case.where, {})

        t.assert_equals({ letters, err }, { nil, case.err }, index)
        t.assert_equals(said, {}, ('%d: серверу не сказано ничего'):format(index))
        t.assert_is(last, link, ('%d: прощаться на том же соединении'):format(index))
        t.assert_equals(
            link.read_line(),
            '+OK готов',
            ('%d: приветствие не прочитано'):format(index)
        )
    end
end

g.test_fetch_refuses_a_control_character_before_connecting = function()
    -- Сервера здесь нет: дойди ход до соединения, причиной был бы он.
    -- Токен поставщика сверяется так же, как строка из настроек.
    local cases = {
        { host = 'ящик', username = 'dev', password = 'secret\n' },
        {
            host = 'ящик',
            username = 'dev@gmail.com',
            auth = 'xoauth2',
            password = function()
                return 'ya29.\r\nDELE 1'
            end,
        },
    }

    for index, case in ipairs(cases) do
        local letters, err = helper.through(nil, function()
            return pop3.fetch(case)
        end)

        t.assert_equals({ letters, err }, { nil, 'пароль: управляющий знак' }, index)
    end
end

g.test_missing_server_is_reported = function()
    -- Соединение не установилось: ящик недоступен целиком, и сказать
    -- об этом надо причиной, а не пустым списком писем.
    local letters, err = helper.through(nil, function()
        return pop3.fetch({ host = 'ящик', port = 110 }, {})
    end)

    t.assert_equals(letters, nil)
    t.assert_str_contains(err, 'ящик')
end

g.test_silent_server_is_reported_at_the_greeting = function()
    -- Сервер не сказал даже приветствия: разговор кончился, не начавшись.
    local letters, err = take({})

    t.assert_equals(letters, nil)
    t.assert_str_contains(err, 'приветствие')
    t.assert_str_contains(err, 'молчит')
end

g.test_state_of_the_mailbox_without_a_number_is_reported = function()
    -- `+OK` без числа — не пустой ящик, а неразобранный ответ: считать
    -- такое нулём писем значит молча ничего не забрать.
    local letters, err = take({
        '+OK почтовый ящик готов',
        '+OK имя принято',
        '+OK вход выполнен',
        '+OK ящик в порядке',
    })

    t.assert_equals(letters, nil)
    t.assert_str_contains(err, 'не разобрано')
end

g.test_empty_mailbox_is_not_asked_for_identifiers = function()
    -- В пустом ящике спрашивать UIDL нечего, и лишняя команда здесь
    -- не безобидна: сервер вправе ответить на неё отказом.
    local letters, err, said = take({
        '+OK почтовый ящик готов',
        '+OK имя принято',
        '+OK вход выполнен',
        '+OK 0 0',
        '+OK до свидания',
    })

    t.assert_equals(err, nil)
    t.assert_equals(letters, {})
    t.assert_equals(said, { 'USER dev', 'PASS secret', 'STAT' })
end

g.test_identifiers_are_read_only_from_proper_lines = function()
    -- Строка UIDL — номер, пробел, имя. Всё остальное — не опознаватель:
    -- письмо лучше отдать без устойчивого имени, чем с чужим.
    local letters, err = take({
        '+OK почтовый ящик готов',
        '+OK имя принято',
        '+OK вход выполнен',
        '+OK 2 800',
        '+OK опознаватели',
        '1abc',
        '1 ',
        ' сирота',
        '2 настоящий',
        '.',
        '+OK письмо',
        'Subject: второе',
        '',
        'тело',
        '.',
        '+OK письмо',
        'Subject: первое',
        '',
        'тело',
        '.',
        '+OK до свидания',
    })

    t.assert_equals(err, nil)
    t.assert_equals(helper.at(letters, 1).id, 'настоящий')
    t.assert_equals(helper.at(letters, 2).id, nil, 'у первого письма опознавателя нет')
end

g.test_ten_letters_are_taken_when_no_limit_is_asked = function()
    -- Предел по умолчанию: ящик, в который месяц не заглядывали,
    -- иначе приедет на узел целиком.
    local answers = {
        '+OK почтовый ящик готов',
        '+OK имя принято',
        '+OK вход выполнен',
        '+OK 12 9000',
        '+OK опознаватели',
        '.',
    }

    for _ = 1, 12 do
        table.insert(answers, '+OK письмо')
        table.insert(answers, 'Subject: тема')
        table.insert(answers, '')
        table.insert(answers, 'тело')
        table.insert(answers, '.')
    end

    local letters, err = take(answers)

    t.assert_equals(err, nil)
    t.assert_equals(#letters, 10)
    t.assert_equals(helper.at(letters, 1).number, 12)
    t.assert_equals(helper.at(letters, 10).number, 3)
end

g.test_torn_multiline_answer_names_the_silence = function()
    -- Письмо оборвалось посреди многострочного ответа: причина обязана
    -- назвать молчание сервера, а не просто номер письма.
    local letters, err = take({
        '+OK почтовый ящик готов',
        '+OK имя принято',
        '+OK вход выполнен',
        '+OK 1 400',
        '+OK опознаватели',
        '.',
        '+OK письмо',
        'Subject: начало',
    })

    t.assert_equals(letters, nil)
    t.assert_str_contains(err, 'письмо 1')
    t.assert_str_contains(err, 'молчит')
end

--- Разговор с переходом на шифрование: вход идёт уже под ним.
local take_with_tls = helper.tls_taker('tnt.mail.pop3', {
    username = 'dev',
    password = 'secret',
    tls = 'starttls',
})

g.test_login_waits_for_encryption = function()
    -- Имя и пароль идут отдельными командами, и отправить их открытым
    -- текстом «пока договариваемся» значит отдать их целиком.
    local letters, err, said, secret = take_with_tls({
        '+OK почтовый ящик готов',
        '+OK переходим на шифрование',
    }, {
        '+OK имя принято',
        '+OK вход выполнен',
        '+OK 0 0',
        '+OK до свидания',
    })

    t.assert_equals(err, nil)
    t.assert_equals(letters, {})
    t.assert_equals(said, { 'STLS' }, 'открытым текстом сказано только STLS')
    t.assert_equals(secret, { 'USER dev', 'PASS secret', 'STAT' })
end

g.test_refused_stls_stops_before_the_password = function()
    local letters, err, said = take_with_tls({
        '+OK почтовый ящик готов',
        '-ERR сегодня без шифрования',
    })

    t.assert_equals(letters, nil)
    t.assert_str_contains(err, 'переход на шифрование')
    t.assert_equals(said, { 'STLS' }, 'пароль не сказан вовсе')
end

g.test_failed_handshake_stops_before_the_password = function()
    local letters, err = take_with_tls({
        '+OK почтовый ящик готов',
        '+OK переходим на шифрование',
    }, nil)

    t.assert_equals(letters, nil)
    t.assert_str_contains(err, 'сертификат не принят')
end

g.test_goodbye_goes_under_encryption = function()
    -- После STLS прежнее соединение негодно: QUIT, сказанный в него,
    -- уходит мимо шифрования, а незакрытое защищённое держит SSL и SSL_CTX,
    -- которых не видит ни один счётчик Lua. Так в любом исходе — и когда
    -- письма забраны, и когда разговор оборвался уже под шифрованием.
    local cases = {
        {
            name = 'письмо забрано',
            after = {
                '+OK имя принято',
                '+OK вход выполнен',
                '+OK 1 400',
                '-ERR без опознавателей',
                '+OK письмо',
                'Subject: тема',
                '',
                'тело',
                '.',
                '+OK до свидания',
            },
        },
        { name = 'имя отвергнуто', after = { '-ERR нет такого ящика' }, err = 'имя' },
        {
            name = 'пароль отвергнут',
            after = { '+OK имя принято', '-ERR неверный пароль' },
            err = 'пароль',
        },
        {
            name = 'состояние ящика не отдано',
            after = { '+OK имя принято', '+OK вход выполнен', '-ERR ящик занят' },
            err = 'состояние ящика',
        },
        {
            name = 'письмо не отдано',
            after = {
                '+OK имя принято',
                '+OK вход выполнен',
                '+OK 1 400',
                '-ERR без опознавателей',
                '-ERR нет письма',
            },
            err = 'письмо 1',
        },
        {
            name = 'письмо оборвалось',
            after = {
                '+OK имя принято',
                '+OK вход выполнен',
                '+OK 1 400',
                '-ERR без опознавателей',
                '+OK письмо',
            },
            err = 'письмо 1',
        },
    }

    for _, case in ipairs(cases) do
        local letters, err, said, secret = helper.through_tls(
            {
                '+OK почтовый ящик готов',
                '+OK переходим на шифрование',
            },
            case.after,
            function()
                return pop3.fetch({
                    host = 'ящик',
                    port = 110,
                    username = 'dev',
                    password = 'secret',
                    tls = 'starttls',
                }, { limit = 1 })
            end
        )

        helper.ended_under_tls(case, { letters = letters, err = err, said = said, secret = secret }, { 'STLS' }, 'QUIT')
    end
end

g.test_refused_stls_says_goodbye_in_the_open = function()
    -- Сервер отказал в переходе: разговор так и остался открытым,
    -- и прощаться, и закрывать надо его.
    local letters, err, said, secret = helper.through_tls({
        '+OK почтовый ящик готов',
        '-ERR сегодня без шифрования',
    }, {}, function()
        return pop3.fetch({ host = 'ящик', port = 110, username = 'dev', password = 'secret', tls = 'starttls' })
    end)

    t.assert_equals(letters, nil)
    t.assert_str_contains(err, 'переход на шифрование')
    t.assert_equals(said[#said], 'QUIT')
    t.assert_equals(said.closed, true)
    t.assert_equals(secret, {}, 'под шифрованием не сказано ничего')
end

-- ── XOAUTH2 ──────────────────────────────────────────────────────────

--- Ящик Gmail: вход по токену OAuth 2.0.
local OAUTH = { username = 'dev@gmail.com', password = 'ya29.токен', auth = 'xoauth2' }

--- Разговор со входом XOAUTH2.
local take_oauth = helper.taker('tnt.mail.pop3', OAUTH)

--- Начальный ответ XOAUTH2, каким он уходит серверу.
local RECORD = require('digest').base64_encode('user=dev@gmail.com\1auth=Bearer ya29.токен\1\1', { nowrap = true })

g.test_xoauth2_sends_the_record_after_the_continuation = function()
    -- Команда POP3 не длиннее 255 байт, а токен — килобайт: начальный
    -- ответ идёт своей строкой после продолжения.
    local letters, err, said = take_oauth({
        '+OK готов',
        '+ ',
        '+OK вход выполнен',
        '+OK 0 0',
    })

    t.assert_equals(err, nil)
    t.assert_equals(letters, {})
    t.assert_equals({ said[1], said[2], said[3] }, { 'AUTH XOAUTH2', RECORD, 'STAT' })
end

g.test_xoauth2_bare_continuation_is_understood = function()
    local _, err, said = take_oauth({ '+OK готов', '+', '+OK вход', '+OK 0 0' })

    t.assert_equals(err, nil)
    t.assert_equals(said[2], RECORD)
end

g.test_xoauth2_refusal_is_finished_and_explained = function()
    -- Отказ сервер отдаёт продолжением с причиной в base64 и ждёт пустой
    -- строки, чтобы ответить окончательным -ERR.
    local reason = '{"status":"400","schemes":"Bearer","scope":"https://mail.google.com/"}'
    local letters, err, said = take_oauth({
        '+OK готов',
        '+ ',
        '+ ' .. require('digest').base64_encode(reason, { nowrap = true }),
        '-ERR [AUTH] Invalid credentials',
    })

    t.assert_equals(letters, nil)
    t.assert_equals(err, ('вход: -ERR [AUTH] Invalid credentials; причина: %s'):format(reason))
    t.assert_equals(said[3], '', 'пустая строка завершает отказ')
end

g.test_xoauth2_not_offered_is_reported = function()
    local letters, err, said = take_oauth({ '+OK готов', '-ERR unknown AUTH mechanism' })

    t.assert_equals(letters, nil)
    t.assert_equals(err, 'вход: -ERR unknown AUTH mechanism')
    t.assert_equals(#said, 1, 'токен неумеющему серверу не отдан')
end

g.test_xoauth2_flat_refusal_is_reported = function()
    local _, err = take_oauth({ '+OK готов', '+ ', '-ERR token expired' })

    t.assert_equals(err, 'вход: -ERR token expired')
end

g.test_xoauth2_silence_is_reported = function()
    local _, err = take_oauth({ '+OK готов' })

    t.assert_equals(err, 'вход: сервер молчит')
end
