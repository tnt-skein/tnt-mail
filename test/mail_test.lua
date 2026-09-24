--- Тесты фасада: настройки, умолчания, запрет пароля без TLS, выбор
--- протокола и разбор забранного.

local t = require('luatest')
local utf8 = require('utf8')

local g = t.group('tnt.mail')

local helper = dofile('test/helper.lua')

---@type any
local mail

--- Что ушло на сервер и что он ответил.
---@type any
local outbox

g.before_each(function()
    mail = helper.load('tnt.mail')
    outbox = { sent = {}, answer = true }

    -- Протоколы подменяются целиком: фасад проверяется на том, что он
    -- решает, а не на том, как разговаривает — разговор проверен своими
    -- тестами.
    mail.smtp.send = function(settings, letter, body)
        table.insert(outbox.sent, { settings = settings, letter = letter, body = body })

        return outbox.answer, outbox.err
    end

    mail.pop3.fetch = function(settings, opts)
        table.insert(outbox.sent, { via = 'pop3', settings = settings, opts = opts })

        return outbox.letters, outbox.err
    end

    mail.imap.fetch = function(settings, opts)
        table.insert(outbox.sent, { via = 'imap', settings = settings, opts = opts })

        return outbox.letters, outbox.err
    end
end)

g.after_each(function()
    helper.unload()
end)

g.test_letter_takes_the_sender_from_the_settings = function()
    -- Отправителя задают один раз: писать его в каждом письме значит
    -- однажды забыть и получить отказ сервера вместо уведомления.
    mail.configure({
        from = 'tarantool@example.org',
        smtp = { host = '127.0.0.1', port = 1025 },
    })

    local ok, err = mail.send({ to = 'duty@example.org', subject = 'Тема', text = 'Тело' })

    t.assert_equals(ok, true)
    t.assert_equals(err, nil)
    t.assert_equals(outbox.sent[1].letter.from, 'tarantool@example.org')
    t.assert_str_contains(outbox.sent[1].body, 'Subject: ')
end

g.test_letter_without_a_sender_is_refused_before_the_server = function()
    mail.configure({ smtp = { host = '127.0.0.1' } })

    local ok, err = mail.send({ to = 'duty@example.org' })

    t.assert_equals(ok, false)
    t.assert_str_contains(err, 'отправитель не задан')
    t.assert_equals(outbox.sent, {})
end

g.test_letter_without_a_server_is_refused = function()
    mail.configure(nil)

    local ok, err = mail.send({ to = 'duty@example.org' })

    t.assert_equals(ok, false)
    t.assert_str_contains(err, 'адрес сервера SMTP не задан')
end

g.test_password_without_tls_needs_a_written_permission = function()
    -- Пароль по незашифрованному соединению виден всякому, кто смотрит
    -- на сеть. Запретить совсем — сделать пакет бесполезным там, где
    -- сервер стоит рядом; разрешить молча — обмануть того, кто про это
    -- не думал.
    mail.configure({
        from = 'a@b',
        smtp = { host = '127.0.0.1', username = 'dev', password = 'secret' },
    })

    local ok, err = mail.send({ to = 'c@d' })

    t.assert_equals(ok, false)
    t.assert_str_contains(err, 'allow_plaintext_auth')
    t.assert_equals(outbox.sent, {})
end

g.test_written_permission_lets_the_letter_through = function()
    mail.configure({
        from = 'a@b',
        smtp = {
            host = '127.0.0.1',
            username = 'dev',
            password = 'secret',
            allow_plaintext_auth = true,
        },
    })

    t.assert_equals(mail.send({ to = 'c@d' }), true)
end

g.test_tls_removes_the_question = function()
    -- С поднятым TLS пароль не виден никому, и признавать нечего.
    mail.configure({
        from = 'a@b',
        smtp = { host = '127.0.0.1', username = 'dev', password = 'secret', tls = 'direct' },
    })

    t.assert_equals(mail.send({ to = 'c@d' }), true)
end

g.test_cram_md5_needs_no_permission = function()
    -- CRAM-MD5 пароль не отдаёт: по проводу идёт отзыв на вызов сервера,
    -- и признавать нечего. Способ задан явно, значит, на другой отправка
    -- не перейдёт, и пароль открытым текстом не уедет.
    mail.configure({
        from = 'a@b',
        smtp = { host = '127.0.0.1', username = 'dev', password = 'secret', auth = 'CRAM-MD5' },
    })

    t.assert_equals(mail.send({ to = 'c@d' }), true)
    t.assert_equals(
        outbox.sent[1].settings.auth,
        'cram-md5',
        'имя приведено к нижнему регистру'
    )
end

g.test_named_plaintext_method_still_needs_the_permission = function()
    -- PLAIN, LOGIN и XOAUTH2 отдают секрет открытым текстом: токен
    -- OAuth 2.0 на час — тот же пароль, и признание нужно то же.
    for _, method in ipairs({ 'plain', 'login', 'xoauth2' }) do
        mail.configure({
            from = 'a@b',
            smtp = { host = '127.0.0.1', username = 'dev', password = 'secret', auth = method },
        })

        local ok, err = mail.send({ to = 'c@d' })

        t.assert_equals(ok, false, method)
        t.assert_str_contains(err, 'allow_plaintext_auth')
    end

    t.assert_equals(outbox.sent, {})
end

g.test_unknown_method_is_refused_at_configuration = function()
    -- Опечатка в настройке обязана обнаружиться при настройке, а не
    -- на первом письме: «cram-md-5» иначе стало бы отказом посреди ночи.
    local ok, err = pcall(mail.configure, { host = 'почтовик', smtp = { auth = 'cram-md-5' } })

    t.assert_equals(ok, false)
    t.assert_equals(err, 'неизвестный способ входа SMTP: cram-md-5')
end

g.test_pop3_and_imap_know_only_xoauth2 = function()
    -- У POP3 и IMAP сверх имени и пароля один способ — XOAUTH2. Настройка,
    -- которую они молча пропустили бы, обещала бы то, чего нет.
    for _, kind in ipairs({ 'pop3', 'imap' }) do
        local ok, err = pcall(mail.configure, { host = 'почтовик', [kind] = { auth = 'plain' } })

        t.assert_equals(ok, false)
        t.assert_equals(err, ('неизвестный способ входа %s: plain'):format(kind:upper()))

        mail.configure({ host = 'почтовик', [kind] = { auth = 'XOAUTH2' } })
        t.assert_equals(mail.status()[kind].auth, 'xoauth2')
    end
end

g.test_the_password_is_a_string_or_a_provider = function()
    local function provider()
        return 'ya29.токен'
    end

    mail.configure({ host = 'почтовик', password = provider, imap = { password = 'свой' } })
    t.assert_equals(
        mail.status().smtp.password,
        nil,
        'пароль в состоянии не показывается'
    )

    for _, kind in ipairs({ 'smtp', 'pop3', 'imap' }) do
        local ok, err = pcall(mail.configure, { host = 'почтовик', [kind] = { password = 42 } })

        t.assert_equals(ok, false)
        t.assert_equals(
            err,
            ('пароль %s — строка либо функция-поставщик, а не number'):format(
                kind:upper()
            )
        )
    end

    local ok, err = pcall(mail.configure, { password = { token = 'x' } })

    t.assert_equals(ok, false)
    t.assert_equals(err, 'пароль SMTP — строка либо функция-поставщик, а не table')
end

g.test_a_control_character_in_the_login_is_refused_at_configuration = function()
    -- Перевод строки в имени или пароле — вторая команда серверу, и тот,
    -- кто настраивал, узнаёт об этом сразу, а не на первом заборе писем.
    -- Общее имя достаётся всем трём протоколам, и первым его сверяет SMTP.
    -- Пароль в причине не показан: она идёт в журнал.
    local cases = {
        {
            { imap = { username = 'dev\r\nDELE 1' } },
            'имя IMAP: управляющий знак в «dev..DELE 1»',
        },
        { { pop3 = { password = 'secret\r\nDELE 1' } }, 'пароль POP3: управляющий знак' },
        { { username = 'dev\t' }, 'имя SMTP: управляющий знак в «dev.»' },
        { { username = 'dev', password = 'secret\0' }, 'пароль SMTP: управляющий знак' },
    }

    for index, case in ipairs(cases) do
        t.assert_equals({ pcall(mail.configure, case[1]) }, { false, case[2] }, index)
    end

    -- Поставщик пароля — функция, и управляющих знаков в ней нет: токен,
    -- который он отдаст, сверяет разговор перед входом.
    mail.configure({
        host = 'почтовик',
        username = 'dev',
        password = function()
            return 'ya29.токен'
        end,
    })
    t.assert_equals(mail.status().imap.username, 'dev')
end

g.test_the_provider_reaches_the_protocol_untouched = function()
    local function provider()
        return 'ya29.токен'
    end

    mail.configure({
        from = 'a@b',
        smtp = { host = '127.0.0.1', username = 'dev', password = provider, auth = 'xoauth2', tls = 'starttls' },
    })

    t.assert_equals(mail.send({ to = 'c@d' }), true)
    t.assert_is(
        outbox.sent[1].settings.password,
        provider,
        'поставщика зовёт протокол перед входом'
    )
end

g.test_method_is_not_taken_from_the_common_settings = function()
    -- Общие настройки годятся всем трём протоколам, а способ входа —
    -- только SMTP: общего у него нет, и отправка идёт как обычно.
    mail.configure({ from = 'a@b', host = '127.0.0.1', auth = 'xoauth2', allow_plaintext_auth = true })

    t.assert_equals(mail.send({ to = 'c@d' }), true)
    t.assert_equals(outbox.sent[1].settings.auth, nil)
    t.assert_equals(mail.status().smtp.auth, nil)
end

g.test_status_shows_the_method = function()
    mail.configure({ host = 'почтовик', smtp = { username = 'dev', password = 'x', auth = 'xoauth2' } })

    t.assert_equals(mail.status().smtp.auth, 'xoauth2')
    t.assert_equals(mail.status().pop3.auth, nil)
end

g.test_letter_without_a_password_needs_no_permission = function()
    mail.configure({ from = 'a@b', smtp = { host = '127.0.0.1' } })

    t.assert_equals(mail.send({ to = 'c@d' }), true)
end

g.test_refused_letter_is_passed_on_with_its_reason = function()
    mail.configure({ from = 'a@b', smtp = { host = '127.0.0.1' } })

    outbox.answer = false
    outbox.err = 'получатель: сервер ответил 550'

    local ok, err = mail.send({ to = 'c@d' })

    t.assert_equals(ok, false)
    t.assert_str_contains(err, '550')
end

g.test_ports_fall_back_to_the_ones_protocols_were_given = function()
    mail.configure({ host = '127.0.0.1' })

    local status = mail.status()

    t.assert_equals(status.smtp.port, 25)
    t.assert_equals(status.pop3.port, 110)
    t.assert_equals(status.imap.port, 143)
end

g.test_common_settings_reach_every_protocol = function()
    -- Один сервер на всё — обычный случай: почтовик на соседней машине
    -- отвечает и за отправку, и за ящик.
    mail.configure({ host = 'почтовик', username = 'dev', password = 'secret', timeout = 9 })

    local status = mail.status()

    for _, kind in ipairs({ 'smtp', 'pop3', 'imap' }) do
        t.assert_equals(status[kind].host, 'почтовик', kind)
        t.assert_equals(status[kind].username, 'dev', kind)
        t.assert_equals(status[kind].timeout, 9, kind)
    end
end

g.test_own_settings_win_over_the_common_ones = function()
    mail.configure({
        host = 'почтовик',
        imap = { host = 'ящик', port = 993, tls = 'direct' },
    })

    local status = mail.status()

    t.assert_equals(status.smtp.host, 'почтовик')
    t.assert_equals(status.imap.host, 'ящик')
    t.assert_equals(status.imap.port, 993)
end

g.test_certificate_settings_reach_the_connection = function()
    -- Релей в своём контуре часто подписан своим корнем: без него
    -- шифрованное соединение к такому серверу не поднимается вовсе.
    -- Общие настройки годятся всем протоколам, свои их перекрывают,
    -- и `verify = false` у протокола — решение, а не пропуск.
    mail.configure({
        from = 'tarantool@example.org',
        host = 'почтовик',
        tls = 'direct',
        ca_file = '/etc/ssl/own.pem',
        verify = true,
        imap = { verify = false, ca_path = '/etc/ssl/own' },
    })

    t.assert_equals(mail.send({ to = 'duty@example.org', subject = 'Тема' }), true)
    mail.fetch({ via = 'imap' })
    mail.fetch({ via = 'pop3' })

    local smtp = helper.at(outbox.sent, 1).settings
    local imap = helper.at(outbox.sent, 2).settings
    local pop3 = helper.at(outbox.sent, 3).settings

    t.assert_equals({ smtp.verify, smtp.ca_file, smtp.ca_path }, { true, '/etc/ssl/own.pem', nil })
    t.assert_equals({ imap.verify, imap.ca_file, imap.ca_path }, { false, '/etc/ssl/own.pem', '/etc/ssl/own' })
    t.assert_equals({ pop3.verify, pop3.ca_file, pop3.ca_path }, { true, '/etc/ssl/own.pem', nil })
end

g.test_status_keeps_the_password_to_itself = function()
    -- Состояние читают и журнал, и панель, и человек через плечо.
    mail.configure({ host = 'почтовик', username = 'dev', password = 'очень секретно' })

    t.assert_equals(require('json').encode(mail.status()):find('секретно'), nil)
end

g.test_letters_are_taken_by_imap_unless_asked_otherwise = function()
    -- IMAP смотрит письма, не отнимая их у человека, который читает
    -- тот же ящик, — поэтому он и по умолчанию.
    mail.configure({ imap = { host = 'ящик' }, pop3 = { host = 'ящик' } })

    outbox.letters = {}

    mail.fetch()
    mail.fetch({ via = 'pop3' })

    t.assert_equals(outbox.sent[1].via, 'imap')
    t.assert_equals(outbox.sent[2].via, 'pop3')
end

g.test_taken_letters_come_back_parsed = function()
    mail.configure({ imap = { host = 'ящик' } })

    outbox.letters = {
        {
            number = 3,
            id = '42',
            raw = table.concat({
                'Subject: =?UTF-8?B?0KLQtdC80LA=?=',
                'From: duty@example.org',
                '',
                'тело письма',
            }, '\r\n'),
        },
    }

    local letters = mail.fetch()

    t.assert_equals(#letters, 1)
    t.assert_equals(letters[1].subject, 'Тема')
    t.assert_equals(letters[1].from, 'duty@example.org')
    t.assert_equals(letters[1].text, 'тело письма')
    t.assert_equals(letters[1].number, 3)
    t.assert_equals(letters[1].id, '42')
end

g.test_letter_from_windows_comes_back_in_utf8 = function()
    -- Письмо из Windows: тема и тело в cp1251. Забранное, оно обязано
    -- читаться в UTF-8 — дальше его показывают панель и журнал, — а сырое
    -- письмо остаётся как пришло.
    mail.configure({ pop3 = { host = 'ящик' } })

    local raw = table.concat({
        'Subject: =?windows-1251?B?0OXv6+jq4CDu8vHy4Ovg?=',
        'Content-Type: text/plain; charset=windows-1251',
        '',
        '\210\229\235\238\32\239\232\241\252\236\224',
    }, '\r\n')

    outbox.letters = { { number = 1, raw = raw } }

    local letter = helper.at(mail.fetch({ via = 'pop3' }), 1)

    t.assert_equals(letter.subject, 'Реплика отстала')
    t.assert_equals(letter.text, 'Тело письма')
    t.assert_not_equals(utf8.len(letter.text), nil)
    t.assert_equals(letter.raw, raw)
end

g.test_unknown_way_to_fetch_is_named = function()
    mail.configure({ host = 'ящик' })

    local letters, err = mail.fetch({ via = 'голубиной почтой' })

    t.assert_equals(letters, nil)
    t.assert_str_contains(err, 'голубиной почтой')
end

g.test_fetching_without_a_server_is_refused = function()
    mail.configure(nil)

    local letters, err = mail.fetch()

    t.assert_equals(letters, nil)
    t.assert_str_contains(err, 'IMAP')
end

g.test_refused_fetch_is_passed_on = function()
    mail.configure({ imap = { host = 'ящик' } })

    outbox.letters = nil
    outbox.err = 'вход: неверный пароль'

    local letters, err = mail.fetch()

    t.assert_equals(letters, nil)
    t.assert_str_contains(err, 'неверный пароль')
end

g.test_dry_run_shows_the_letter_without_sending_it = function()
    -- Разработчику нужно видеть, что именно уедет, — а увидеть это
    -- иначе можно только отправив.
    mail.configure({ from = 'a@b' })

    local letter = mail.render({ to = 'c@d', subject = 'Тема', text = 'Тело' }, 1789041300)

    t.assert_str_contains(letter, 'From: a@b')
    t.assert_str_contains(letter, 'Date: Thu, 10 Sep 2026')
    t.assert_equals(outbox.sent, {})
end

g.test_dry_run_refuses_a_letter_without_a_sender_as_send_does = function()
    -- Сухой прогон обязан отказать там же, где отправка: письмо
    -- с `From: nil` сервер не примет, и показывать его годным незачем.
    mail.configure(nil)

    local letter, err = mail.render({ to = 'c@d', subject = 'Тема', text = 'Тело' })

    t.assert_equals(letter, nil)
    t.assert_equals(
        err,
        'отправитель не задан: сервер не примет письмо без него'
    )
    t.assert_str_contains(mail.render({ from = 'a@b', to = 'c@d' }), 'From: a@b')
end

g.test_letter_without_recipients_is_refused_before_the_server = function()
    -- Письмо некому отдать — отказ до соединения: сухой прогон не собирает
    -- `To: nil`, а отправка не будит сервер ради отказа.
    local journal = helper.capture_log()

    mail.configure({ from = 'a@b', smtp = { host = 'почтовик' } })

    local letter, err = mail.render({ subject = 'Некому' })

    t.assert_equals(letter, nil)
    t.assert_equals(err, 'получателей нет: письмо некому отдать')
    t.assert_equals(
        { mail.render({ to = {} }) },
        { nil, 'получателей нет: письмо некому отдать' }
    )
    t.assert_str_contains(mail.render({ bcc = 'hidden@example.org' }), 'From: a@b')
    t.assert_equals(
        { mail.send({ subject = 'Некому' }) },
        { false, 'получателей нет: письмо некому отдать' }
    )
    t.assert_equals(outbox.sent, {})
    t.assert_equals(journal.logged('письмо не отправлено'), true)
end

g.test_folders_need_an_imap_server = function()
    mail.configure(nil)

    local folders, err = mail.folders()

    t.assert_equals(folders, nil)
    t.assert_str_contains(err, 'IMAP')
end

g.test_folders_are_asked_from_imap = function()
    mail.configure({ imap = { host = 'ящик' } })

    mail.imap.folders = function(settings)
        return { 'INBOX', settings.host }
    end

    t.assert_equals(mail.folders(), { 'INBOX', 'ящик' })
end

g.test_fetching_with_a_password_needs_the_same_permission = function()
    -- Ящик читают тем же паролем, что и отправляют: правило одно на всё.
    mail.configure({ imap = { host = 'ящик', username = 'dev', password = 'secret' } })

    local letters, err = mail.fetch()

    t.assert_equals(letters, nil)
    t.assert_str_contains(err, 'allow_plaintext_auth')
end

g.test_timeout_falls_back_to_five_seconds = function()
    -- Срок по умолчанию виден в состоянии: сервер, думающий дольше
    -- пяти секунд, думает и минуту, а файбер ждёт всё это время.
    mail.configure({ host = 'почтовик' })

    local status = mail.status()

    t.assert_equals(status.smtp.timeout, 5)
    t.assert_equals(status.pop3.timeout, 5)
    t.assert_equals(status.imap.timeout, 5)
end

g.test_common_password_and_greeting_reach_the_server = function()
    -- Общие настройки — не украшение состояния: пароль, имя для EHLO
    -- и разрешение открытого входа доходят до самого разговора.
    mail.configure({
        from = 'tarantool@example.org',
        to = 'duty@example.org',
        host = 'почтовик',
        username = 'дежурный',
        password = 'секрет',
        helo = 'storage-001-a',
        allow_plaintext_auth = true,
    })

    t.assert_equals(mail.send({ subject = 'Тема' }), true)

    local where = helper.at(outbox.sent, 1).settings

    t.assert_equals(where.password, 'секрет')
    t.assert_equals(where.helo, 'storage-001-a')
    t.assert_equals(where.allow_plaintext_auth, true)
end

g.test_letter_may_be_left_out_entirely = function()
    -- Всё, что нужно письму, уже в настройках: вызов без письма —
    -- обычное «отправь то, о чём договорились».
    mail.configure({
        from = 'tarantool@example.org',
        to = 'duty@example.org',
        origin = 'storage-001-a',
        smtp = { host = 'почтовик' },
    })

    t.assert_equals(mail.send(), true)

    local letter = helper.at(outbox.sent, 1).letter

    t.assert_equals(letter.from, 'tarantool@example.org')
    t.assert_equals(letter.to, 'duty@example.org')
    t.assert_str_contains(mail.render(), '@storage-001-a>')
end

g.test_refusal_is_written_down_and_success_is_not = function()
    -- Отказ виден только записью: письмо, не дошедшее до дежурного,
    -- иначе исчезает бесследно. Удачная отправка в журнал не просится.
    local journal = helper.capture_log()

    mail.configure({ from = 'a@b', to = 'c@d', smtp = { host = 'почтовик' } })

    outbox.answer, outbox.err = false, 'сервер ответил 550'
    mail.send({ subject = 'Тема' })

    t.assert_equals(journal.logged('письмо не отправлено'), true)

    journal.forget()

    outbox.answer, outbox.err = true, nil
    mail.send({ subject = 'Тема' })

    t.assert_equals(journal.logged('письмо не отправлено'), false)
end

g.test_recipient_of_the_letter_wins_over_the_settings = function()
    -- Получатель по умолчанию — дежурный, но письмо вправе назвать
    -- своего: отчёт уходит не туда же, куда тревога.
    mail.configure({ from = 'tarantool@example.org', to = 'duty@example.org' })

    local letter = mail.render({ to = 'report@example.org', subject = 'Отчёт' })

    t.assert_str_contains(letter, 'report@example.org')
    t.assert_equals(letter:find('duty@example.org'), nil)
end

g.test_ports_follow_the_way_encryption_is_raised = function()
    -- У шифрования с первого байта отдельные порты: на обычном сервер ждёт
    -- открытого приветствия и на рукопожатие отвечает непониманием.
    mail.configure({ host = 'почтовик', tls = 'direct' })

    local direct = mail.status()

    t.assert_equals(direct.smtp.port, 465)
    t.assert_equals(direct.pop3.port, 995)
    t.assert_equals(direct.imap.port, 993)

    -- У STARTTLS порт тот же, что у открытого разговора, кроме отправки:
    -- 587 — порт сдачи письма, где шифрование и вход обязательны.
    mail.configure({ host = 'почтовик', tls = 'starttls' })

    local upgraded = mail.status()

    t.assert_equals(upgraded.smtp.port, 587)
    t.assert_equals(upgraded.pop3.port, 110)
    t.assert_equals(upgraded.imap.port, 143)

    -- Названный порт главнее умолчания: у почтовика в своём контуре
    -- он бывает любым.
    mail.configure({ host = 'почтовик', tls = 'direct', smtp = { port = 2465 } })

    t.assert_equals(mail.status().smtp.port, 2465)
end

g.test_unknown_way_to_encrypt_is_refused_at_once = function()
    -- Опечатка в настройке обязана обнаружиться при настройке, а не
    -- посреди отправки письма: «tsl» вместо «tls» иначе означало бы
    -- открытый канал там, где просили шифрование.
    local ok, err = pcall(mail.configure, { host = 'почтовик', tls = 'ssl' })

    -- Дословно: отказ настройки говорит о настройке, а не о строке
    -- внутри пакета, и приписка «mail.lua:NN:» была бы здесь шумом.
    t.assert_equals(ok, false)
    t.assert_equals(err, 'неизвестный способ шифрования: ssl')
end

g.test_password_needs_no_permission_under_encryption = function()
    -- Запрет пароля — про открытый канал. Под шифрованием он бессмыслен:
    -- ровно ради этого шифрование и поднимают.
    mail.configure({
        from = 'tarantool@example.org',
        to = 'duty@example.org',
        host = 'почтовик',
        username = 'дежурный',
        password = 'секрет',
        tls = 'starttls',
    })

    t.assert_equals(mail.send({ subject = 'Тема' }), true)

    local where = helper.at(outbox.sent, 1).settings

    t.assert_equals(where.tls, 'starttls')
    t.assert_equals(where.allow_plaintext_auth, false, 'разрешение не понадобилось')
end

g.test_letter_with_a_bad_attachment_is_not_sent_and_is_written_down = function()
    -- Негодное вложение — отказ до сервера: письмо без отчёта дежурному
    -- не нужно, а причина видна и в ответе, и в журнале, как у любого
    -- неотправленного письма.
    local journal = helper.capture_log()

    mail.configure({ from = 'a@b', to = 'c@d', smtp = { host = 'почтовик' } })

    local sent, err = mail.send({ subject = 'Отчёт', attachments = { { name = 'report.csv' } } })

    t.assert_equals(sent, false)
    t.assert_equals(
        err,
        'вложение №1: содержимое должно быть строкой, а не nil'
    )
    t.assert_equals(outbox.sent, {})
    t.assert_equals(journal.logged('письмо не отправлено'), true)

    journal.forget()

    local letter, render_err = mail.render({ attachments = 'report.csv' })

    t.assert_equals(letter, nil)
    t.assert_equals(render_err, 'вложения должны быть списком, а не string')
end

g.test_attachments_reach_the_server_inside_the_body = function()
    mail.configure({ from = 'a@b', to = 'c@d', smtp = { host = 'почтовик' } })

    t.assert_equals(
        mail.send({
            subject = 'Отчёт',
            text = 'во вложении',
            attachments = { { name = 'report.csv', type = 'text/csv', content = 'a,b' } },
        }),
        true
    )

    local body = helper.at(outbox.sent, 1).body

    t.assert_str_contains(body, 'Content-Type: multipart/mixed; boundary="tnt-')
    t.assert_str_contains(body, 'Content-Disposition: attachment; filename="report.csv"')
    t.assert_str_contains(body, 'YSxi')
end
