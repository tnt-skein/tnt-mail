--- Тесты соединения: строки, куски, сроки и отказы.
---
--- Сеть здесь настоящая только в одном тесте — том, где проверяется,
--- что модуль вообще умеет говорить с сокетом. Остальное разбирается
--- двойником: отказ соединения на настоящей сети воспроизводится
--- разве что выдёргиванием кабеля.

local t = require('luatest')

local g = t.group('tnt.mail.transport')

local helper = dofile('test/helper.lua')

---@type any
local transport

g.before_each(function()
    transport = helper.load('tnt.mail.transport')
end)

g.after_each(function()
    transport._set_source(nil)
    helper.unload()
end)

--- Соединение поверх двойника сокета.
---
--- Подменяется именно сокет: соединение транспорт заводит сам, и ровно
--- то, как он это делает, здесь и проверяется.
---@param answers string[] Что отвечает сервер
---@param port integer
---@return table link
local function linked(answers, port)
    transport._set_source({
        connect = function()
            return (helper.socket_of(answers))
        end,
    })

    return transport.connect({ host = '127.0.0.1', port = port })
end

g.test_lines_come_without_their_endings = function()
    -- Разделитель снимается здесь, а не у вызывающего: дальше строка
    -- сравнивается с кодами ответа, и хвост из двух невидимых символов
    -- однажды не даст ей совпасть.
    local link = linked({ '220 сервер готов' }, 25)

    t.assert_equals(link.read_line(), '220 сервер готов')
end

g.test_chunk_comes_exactly_as_asked = function()
    local link = linked({ 'ровно столько байт, сколько обещано' }, 143)

    -- Длина в байтах, а не в буквах: протокол меряет литералы байтами,
    -- и кириллица занимает по два.
    t.assert_equals(link.read_chunk(10), 'ровно')
end

g.test_short_chunk_is_a_refusal = function()
    -- Сервер обещал длину и оборвал соединение: половина литерала
    -- не литерал.
    local chunk, err = linked({ 'мало' }, 143).read_chunk(100)

    t.assert_equals(chunk, nil)
    t.assert_str_contains(err, 'меньше, чем обещал')
end

g.test_silence_is_a_refusal_not_an_empty_line = function()
    local line, err = linked({}, 25).read_line()

    t.assert_equals(line, nil)
    t.assert_str_contains(err, 'молчит')
end

g.test_refused_write_is_reported = function()
    transport._set_source({
        connect = function()
            return {
                write = function()
                    return false, 'сеть пропала'
                end,

                read = function()
                    return nil
                end,

                close = function() end,
            }
        end,
    })

    local link = transport.connect({ host = '127.0.0.1', port = 25 })
    local written, err = link.write('EHLO узел\r\n')

    t.assert_equals(written, false)
    t.assert_str_contains(err, 'сеть пропала')
end

g.test_missing_server_is_reported_not_raised = function()
    -- Почта — не то дело, ради которого стоит ронять узел.
    transport._set_source({
        connect = function()
            return nil
        end,
    })

    local link, err = transport.connect({ host = 'почтовик', port = 25 })

    t.assert_equals(link, nil)
    t.assert_str_contains(err, 'почтовик')
    t.assert_str_contains(err, 'не установлено')
end

g.test_broken_network_layer_is_reported_not_raised = function()
    transport._set_source({
        connect = function()
            error('сетевой слой рассыпался')
        end,
    })

    local link, err = transport.connect({ host = '127.0.0.1', port = 25 })

    t.assert_equals(link, nil)
    t.assert_str_contains(err, 'рассыпался')
end

--- Сокет, который молчит на чтение и не спорит с записью.
---@param close fun()|nil Что делает закрытие
---@return table
local function mute(close)
    return {
        read = function()
            return nil
        end,

        write = function()
            return true
        end,

        close = close or function() end,
    }
end

g.test_closing_a_broken_link_does_not_raise = function()
    -- Закрытие зовётся в любом исходе, в том числе на соединении,
    -- которое сервер уже закрыл сам.
    transport._set_source({
        connect = function()
            return mute(function()
                error('уже закрыто')
            end)
        end,
    })

    local link = transport.connect({ host = '127.0.0.1', port = 25 })

    link.close()
end

-- ── Настоящая сеть ───────────────────────────────────────────────────

g.test_real_socket_talks_to_a_real_server = function()
    -- Единственный тест, где сеть настоящая: сервер поднимается тут же,
    -- на случайном порту, и говорит две строки. Без него модуль может
    -- быть сколь угодно правильным — и не уметь соединяться.
    local socket = require('socket')
    local fiber = require('fiber')

    local server = socket.tcp_server('127.0.0.1', 0, function(client)
        client:write('220 проверочный сервер\r\n')

        local line = client:read({ delimiter = '\r\n' }, 1)

        client:write(('250 услышано: %s'):format(tostring(line):gsub('\r\n', '')) .. '\r\n')
        client:close()
    end)

    t.assert_not_equals(server, nil, 'сервер не поднялся')

    local port = server:name().port

    local link, err = transport.connect({ host = '127.0.0.1', port = port, timeout = 2 })

    t.assert_equals(err, nil)
    t.assert_equals(link.read_line(), '220 проверочный сервер')
    t.assert_equals(link.write('EHLO узел\r\n'), true)
    t.assert_str_contains(link.read_line(), 'услышано: EHLO узел')

    link.close()
    server:close()

    -- Файбер сервера завершится сам: проверка не оставляет за собой
    -- ни соединений, ни слушателей.
    fiber.sleep(0)
end

g.test_timeout_reaches_the_socket = function()
    -- Срок должен доехать и до соединения, и до каждого чтения: сокет
    -- без срока ждёт вечно, а вечно ждущий файбер не ждёт никого.
    local asked = {}

    transport._set_source({
        connect = function(host, port, timeout)
            table.insert(asked, { where = 'connect', host = host, port = port, timeout = timeout })

            return {
                read = function(_, _, timeout_of_read)
                    table.insert(asked, { where = 'read', timeout = timeout_of_read })

                    return '220 готов\r\n'
                end,

                write = function()
                    return true
                end,

                close = function() end,
            }
        end,
    })

    transport.connect({ host = 'почтовик', port = 25 }).read_line()

    t.assert_equals(helper.at(asked, 1), { where = 'connect', host = 'почтовик', port = 25, timeout = 5 })
    t.assert_equals(helper.at(asked, 2).timeout, 5)

    transport.connect({ host = 'почтовик', port = 25, timeout = 2 }).read_line()

    t.assert_equals(helper.at(asked, 3).timeout, 2)
    t.assert_equals(helper.at(asked, 4).timeout, 2)
end

g.test_silent_socket_without_a_reason_is_still_a_refusal = function()
    -- Сокет вправе вернуть пустоту и не сказать почему. Причину тогда
    -- придумываем мы: «ничего не произошло» — не то, что нужно читать
    -- в журнале в три часа ночи.
    transport._set_source({
        connect = function()
            return mute()
        end,
    })

    local link = transport.connect({ host = 'почтовик', port = 25 })
    local line, err = link.read_line()

    t.assert_equals(line, nil)
    t.assert_str_contains(err, 'молчит')

    local chunk, chunk_error = link.read_chunk(10)

    t.assert_equals(chunk, nil)
    t.assert_str_contains(chunk_error, 'меньше, чем обещал')
end

g.test_fetching_without_options_works = function()
    -- Аргумент с настройками необязателен: `fetch(settings)` — обычный вызов,
    -- и подставить вместо него пустоту обязан сам ход.
    local pop3 = helper.module('tnt.mail.pop3')

    transport._set_source({
        connect = function()
            return (
                helper.socket_of({
                    '+OK ящик готов',
                    '+OK имя принято',
                    '+OK вход выполнен',
                    '+OK 1 400',
                    '+OK опознаватели',
                    '1 первое',
                    '.',
                    '+OK письмо',
                    'Subject: тема',
                    '',
                    'тело',
                    '.',
                    '+OK до свидания',
                })
            )
        end,
    })

    local letters, err = pop3.fetch({ host = 'ящик', port = 110, username = 'dev', password = 'secret' })

    t.assert_equals(err, nil)
    t.assert_equals(#letters, 1)
    t.assert_equals(helper.at(letters, 1).id, 'первое')
end

g.test_direct_tls_connects_without_a_greeting = function()
    -- На портах 465, 993 и 995 шифрование начинается с первого байта:
    -- открытого приветствия там не будет, и соединяться надо сразу
    -- защищённо, иначе разговор не начнётся ничем.
    local asked

    transport._set_source({
        connect = function()
            error('открытым текстом соединяться не должны')
        end,

        connect_secure = function(opts)
            asked = opts

            return (helper.socket_of({ '220 сервер готов' }))
        end,
    })

    local link = transport.connect({
        host = 'почтовик',
        port = 465,
        tls = 'direct',
        timeout = 3,
        ca_file = '/etc/ssl/own.pem',
    })

    t.assert_equals(link.read_line(), '220 сервер готов')
    t.assert_equals(link.secured, true)
    t.assert_equals(asked, {
        host = 'почтовик',
        port = 465,
        timeout = 3,
        verify = nil,
        ca_file = '/etc/ssl/own.pem',
        ca_path = nil,
    })
end

g.test_refused_direct_tls_is_reported = function()
    transport._set_source({
        connect_secure = function()
            return nil, 'сертификат не принят: self-signed certificate'
        end,
    })

    local link, err = transport.connect({ host = 'почтовик', port = 465, tls = 'direct' })

    t.assert_equals(link, nil)
    t.assert_str_contains(err, 'сертификат не принят')
end

g.test_plain_link_can_be_raised_to_tls = function()
    -- Вторая половина STARTTLS: сокет тот же, но говорить с ним теперь
    -- надо через шифрование.
    -- Двойник заполняет её по ходу разговора, поэтому объявляется пустой.
    ---@type any
    local given = nil

    transport._set_source({
        connect = function()
            return (helper.socket_of({ '220 открытым текстом' }))
        end,

        upgrade = function(socket, opts)
            given = { socket = socket, host = opts.host }

            return (helper.socket_of({ '220 уже под шифрованием' }))
        end,
    })

    local link = transport.connect({ host = 'почтовик', port = 587 })

    t.assert_equals(link.secured, false)
    t.assert_equals(link.read_line(), '220 открытым текстом')

    local secured, err = transport.secure(link, { host = 'почтовик', port = 587 })

    t.assert_equals(err, nil)
    t.assert_equals(secured.secured, true)
    t.assert_equals(secured.read_line(), '220 уже под шифрованием')
    t.assert_equals(
        given.socket,
        link.raw,
        'шифрование поднято поверх того же сокета'
    )
    t.assert_equals(given.host, 'почтовик')
end

g.test_refused_upgrade_is_reported = function()
    transport._set_source({
        connect = function()
            return (helper.socket_of({ '220 готов' }))
        end,

        upgrade = function()
            return nil, 'рукопожатие TLS не удалось: IP address mismatch'
        end,
    })

    local link = transport.connect({ host = '127.0.0.1', port = 587 })
    local secured, err = transport.secure(link, { host = '127.0.0.1', port = 587 })

    t.assert_equals(secured, nil)
    t.assert_str_contains(err, 'IP address mismatch')
end

g.test_direct_tls_really_goes_to_the_tls_package = function()
    -- Внешняя зависимость по умолчанию ведёт в настоящий tnt.tls, и проверить это можно
    -- только настоящей попыткой: на порту, где никто не слушает, она
    -- кончится отказом — но отказом из tnt.tls, а не из подмены.
    transport._set_source(nil)

    local link, err = transport.connect({
        host = '127.0.0.1',
        port = 1,
        tls = 'direct',
        timeout = 0.3,
    })

    t.assert_equals(link, nil)
    t.assert_str_contains(err, '127.0.0.1')
end

g.test_upgrade_really_goes_to_the_tls_package = function()
    -- То же для STARTTLS: поднимаем настоящий сокет к настоящему серверу,
    -- который про шифрование ничего не знает, и ждём отказ рукопожатия.
    local socket = require('socket')

    local server = socket.tcp_server('127.0.0.1', 0, function(client)
        client:write('220 я не умею шифровать\r\n')
        client:read({ chunk = 1 }, 1)
        client:close()
    end)

    t.assert_not_equals(server, nil, 'сервер не поднялся')

    local port = server:name().port

    transport._set_source(nil)

    local link = transport.connect({ host = '127.0.0.1', port = port, timeout = 2 })

    t.assert_equals(link.read_line(), '220 я не умею шифровать')

    local secured, err = transport.secure(link, { host = '127.0.0.1', port = port, timeout = 2 })

    t.assert_equals(secured, nil)
    t.assert_str_contains(
        tostring(err),
        'TLS',
        'причина приходит из tnt.tls, а не выдумана транспортом'
    )

    link.close()
    server:close()
end

g.test_refused_conversation_still_closes_the_link = function()
    -- Разговор не состоялся — соединение всё равно закрывается. Иначе
    -- узел, у которого не подошёл пароль, за сутки набирает столько
    -- открытых сокетов, сколько было тактов уведомителя.
    local pop3 = helper.module('tnt.mail.pop3')
    local closed = false

    transport._set_source({
        connect = function()
            local socket = helper.socket_of({ '+OK ящик готов', '-ERR неверный пароль' })
            local closing = socket.close

            socket.close = function()
                closed = true

                return closing()
            end

            return socket
        end,
    })

    local letters, err = pop3.fetch({
        host = 'ящик',
        port = 110,
        username = 'dev',
        password = 'не тот',
    })

    t.assert_equals(letters, nil)
    t.assert_str_contains(err, 'имя')
    t.assert_equals(
        closed,
        true,
        'соединение закрыто, хотя разговор не состоялся'
    )
end

g.test_secured_link_keeps_the_default_timeout = function()
    -- Срок после перехода на шифрование не теряется: соединение без срока
    -- ждёт вечно, и повисшее рукопожатие останавливает того, кто отправлял
    -- письмо, а не почтовый сервер.
    local asked = {}

    transport._set_source({
        connect = function()
            return (helper.socket_of({ '220 готов' }))
        end,

        upgrade = function()
            return {
                read = function(_, _, timeout)
                    table.insert(asked, timeout)

                    return '220 под шифрованием\r\n'
                end,

                write = function()
                    return true
                end,

                close = function() end,
            }
        end,
    })

    local link = transport.connect({ host = 'почтовик', port = 587 })
    local secured = transport.secure(link, { host = 'почтовик', port = 587 })

    secured.read_line()

    t.assert_equals(helper.at(asked, 1), 5, 'срок по умолчанию — пять секунд')

    local timed = transport.secure(link, { host = 'почтовик', port = 587, timeout = 2 })

    timed.read_line()

    t.assert_equals(helper.at(asked, 2), 2, 'названный срок главнее умолчания')
end

-- ── Пароль-поставщик и запись XOAUTH2 ─────────────────────────────────

g.test_a_string_password_is_taken_as_is = function()
    local where = { username = 'dev', password = 'secret' }

    t.assert_is(transport.credentials(where), where)
end

g.test_a_provider_is_asked_only_when_a_login_will_happen = function()
    local asked = 0

    local function provider()
        asked = asked + 1

        return 'ya29.токен'
    end

    local anonymous = { password = provider }

    t.assert_is(transport.credentials(anonymous), anonymous)
    t.assert_equals(asked, 0, 'без имени входа нет, и токен не нужен')

    local where = { username = 'dev', password = provider, port = 993 }
    local resolved = transport.credentials(where)

    t.assert_equals(resolved, { username = 'dev', password = 'ya29.токен', port = 993 })
    t.assert_is(where.password, provider, 'настройки вызывающего целы')
    t.assert_equals(asked, 1)
end

g.test_a_provider_refusal_is_a_refusal = function()
    local cases = {
        {
            function()
                return nil,
                    setmetatable({}, {
                        __tostring = function()
                            return 'обновление токена: служба ответила 400 — invalid_grant'
                        end,
                    })
            end,
            'пароль не получен: обновление токена: служба ответила 400 — invalid_grant',
        },
        {
            function()
                return { access_token = 'x' }
            end,
            'пароль не получен: поставщик отдал table',
        },
        {
            function() end,
            'пароль не получен: поставщик отдал nil',
        },
        {
            function()
                error('сломан', 0)
            end,
            'пароль не получен: поставщик упал: сломан',
        },
    }

    for _, case in ipairs(cases) do
        local resolved, err = transport.credentials({ username = 'dev', password = case[1] })

        t.assert_equals({ resolved, err }, { nil, case[2] })
    end
end

g.test_the_xoauth2_record_is_one_line_of_base64 = function()
    local token = string.rep('t', 2000)
    local record = transport.xoauth2({ username = 'dev@example.org', password = token })

    t.assert_equals(record:find('[\r\n]'), nil)
    t.assert_equals(require('digest').base64_decode(record), ('user=dev@example.org\1auth=Bearer %s\1\1'):format(token))
    t.assert_equals(
        require('digest').base64_decode(transport.xoauth2({ username = 'dev' })),
        'user=dev\1auth=Bearer \1\1'
    )
end

g.test_fetching_asks_the_provider_before_connecting = function()
    local pop3 = helper.module('tnt.mail.pop3')
    local connected = false

    transport._set_source({
        connect = function()
            connected = true
        end,
    })

    local letters, err = pop3.fetch({
        host = 'ящик',
        username = 'dev',
        password = function()
            return nil, 'служба OAuth 2.0 не ответила'
        end,
    })

    t.assert_equals(
        { letters, err },
        { nil, 'пароль не получен: служба OAuth 2.0 не ответила' }
    )
    t.assert_equals(connected, false, 'без токена сервер не будят')
end

-- ── Сказанное дословно ────────────────────────────────────────────────

g.test_a_control_character_is_named_and_a_password_is_not_shown = function()
    -- Управляющий знак — любой: перевод строки, табуляция, нулевой байт,
    -- DEL. В причине он показан точкой, а пароль не показан вовсе:
    -- причина идёт в журнал.
    local cases = {
        { { 'папка', 'INBOX' }, nil },
        { { 'папка', 'Архив «2026»' }, nil },
        { { 'имя', nil }, nil },
        { { 'папка', 'a\r\nb' }, 'папка: управляющий знак в «a..b»' },
        { { 'папка', '\127' }, 'папка: управляющий знак в «.»' },
        { { 'пароль', 'a\0b', true }, 'пароль: управляющий знак' },
    }

    for index, case in ipairs(cases) do
        local label, value, hidden = unpack(case[1], 1, 3)

        t.assert_equals(transport.tainted(label, value, hidden), case[2], index)
    end
end

g.test_name_and_password_are_both_checked = function()
    t.assert_equals(transport.unsafe({ username = 'dev', password = 'secret' }), nil)
    t.assert_equals(transport.unsafe({}), nil, 'без имени и пароля отказывать не в чем')
    t.assert_equals(
        transport.unsafe({ username = 'dev\n', password = 'secret' }),
        'имя: управляющий знак в «dev.»'
    )
    t.assert_equals(
        transport.unsafe({ username = 'dev', password = 'secret\n' }),
        'пароль: управляющий знак'
    )
end
