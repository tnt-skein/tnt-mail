--- Почта против настоящих серверов.
---
--- Двойник показывает, что мы правильно разговариваем сами с собой.
--- Настоящий сервер показывает, что нас понимает кто-то ещё, — а это
--- разные утверждения: чужой сервер отвечает многострочно там, где
--- двойник отвечал строкой, называет расширения, которых мы не ждали,
--- и требует того, о чём в письме RFC написано мелким шрифтом.
---
--- Серверов три, потому что ни один не умеет всего: Mailpit принимает
--- почту и отдаёт её по POP3, GreenMail отдаёт по IMAP, smtp4dev требует
--- входа и предлагает CRAM-MD5 и XOAUTH2. Поднимаются они отдельно —
--- `test/stand/mail.sh`, — и если их нет, проверки честно пропускаются:
--- гейты не должны зависеть от докера.

local t = require('luatest')

local g = t.group('tnt.mail.live')

local helper = dofile('test/helper.lua')

---@type any
local mail

--- Где стоят серверы: те же адреса, что поднимает скрипт стенда.
local MAILPIT = helper.MAILPIT
local GREENMAIL = { host = '127.0.0.1', smtp = 3025, imap = 3143, pop3 = 3110 }
local SMTP4DEV = { host = '127.0.0.1', smtp = 2025, api = 2080 }

--- Отвечает ли кто-нибудь на этом порту.
---@param port integer
---@return boolean
local function listening(port)
    local socket = require('socket').tcp_connect(MAILPIT.host, port, 0.3)

    if socket == nil then
        return false
    end

    socket:close()

    return true
end

--- Пропускает проверку, если сервер не поднят.
---@param port integer
---@param name string
local function needs(port, name)
    t.skip_if(
        not listening(port),
        ('%s не отвечает: поднимите его — make mail-up'):format(name)
    )
end

--- Настраивает почту на Mailpit: отправка по SMTP, приём по POP3.
---
--- Пароль здесь тот же, что у ящика в стенде, и открытый вход разрешён
--- прямо в настройке: Mailpit поднят без шифрования, и запрет пароля
--- по открытому каналу иначе не пустил бы проверку дальше входа.
---@param from any Кем подписывать письма
---@param password string|nil Каким паролем входить
local function via_mailpit(from, password)
    mail.configure({
        from = from,
        smtp = { host = MAILPIT.host, port = MAILPIT.smtp },
        pop3 = {
            host = MAILPIT.host,
            port = MAILPIT.pop3,
            username = 'dev',
            password = password or 'dev',
            allow_plaintext_auth = true,
        },
    })
end

--- Настраивает почту на GreenMail: отправка по SMTP, приём по IMAP.
---
--- Ящик задаётся аргументом: GreenMail заводит его при первом входе,
--- и разным проверкам нужны разные — иначе прочитанное одной
--- проверкой перестаёт быть непрочитанным для другой.
---@param mailbox string Ящик, под которым входить
local function via_greenmail(mailbox)
    mail.configure({
        from = 'tarantool@example.org',
        smtp = { host = GREENMAIL.host, port = GREENMAIL.smtp },
        imap = {
            host = GREENMAIL.host,
            port = GREENMAIL.imap,
            username = mailbox,
            password = 'secret',
            allow_plaintext_auth = true,
        },
    })
end

--- Настраивает отправку через smtp4dev с заданным способом входа.
---
--- Открытый вход разрешён прямо в настройке: smtp4dev поднят без
--- шифрования, и способы, отдающие пароль, иначе не прошли бы запрет.
---@param auth string|nil Способ входа; nil — на выбор сервера
---@param password string|nil Пароль либо токен
local function via_smtp4dev(auth, password)
    mail.configure({
        from = 'tarantool@example.org',
        smtp = {
            host = SMTP4DEV.host,
            port = SMTP4DEV.smtp,
            username = 'dev',
            password = password or 'dev',
            auth = auth,
            allow_plaintext_auth = true,
        },
    })
end

--- Письма, которые видит smtp4dev, — его собственным API.
---@return table[]
local function smtp4dev_messages()
    local shown = require('http.client')
        .new()
        :get(('http://%s:%d/api/Messages'):format(SMTP4DEV.host, SMTP4DEV.api), { timeout = 2 })

    return require('json').decode(assert(shown.body)).results
end

--- Своё письмо из ящика Mailpit по POP3 — по адресу получателя.
---
--- В ящике Mailpit и письма соседних прогонов: письмо ищется по адресу,
--- пока не придёт. По POP3 Mailpit показывает только сто последних
--- писем и нумерует их от новых к старым, а `limit` берёт номера
--- с конца списка — самые старые из ста. Поэтому берутся все сто:
--- с меньшим пределом своё письмо, первое в списке, не видно, как только
--- соседи накопят в ящике больше писем, чем предел.
---
--- Чужое письмо в окне бывает любым, в том числе без заголовка `To`:
--- соседние прогоны, мутационные тоже, шлют и такие, а падение на чужом
--- письме стоило бы проверке своего. Поэтому получатель сверяется только
--- там, где он есть.
---@param address string Адрес, которого нет ни у одной другой проверки
---@return table letter
local function fetched(address)
    ---@type table
    local found

    t.helpers.retrying({ timeout = 5 }, function()
        local letters, err = mail.fetch({ via = 'pop3', limit = 100 })

        t.assert_equals(err, nil)

        for _, letter in ipairs(letters) do
            if (letter.to or ''):find(address, 1, true) ~= nil then
                found = letter

                return
            end
        end

        error('письма ещё нет')
    end)

    return found
end

g.before_each(function()
    mail = helper.load('tnt.mail')
end)

g.after_each(function()
    helper.unload()
end)

g.test_letter_reaches_a_real_server_and_comes_back_by_pop3 = function()
    needs(MAILPIT.smtp, 'Mailpit')

    via_mailpit({ name = 'Узел storage-001-a', address = 'tarantool@example.org' })

    local address = helper.unique_address('duty')

    -- Письмо нарочно с тем, что ломается молча: кириллица в теме
    -- и одинокая точка на строке в теле.
    local sent, err = mail.send({
        to = { { name = 'Дежурный', address = address } },
        subject = 'Реплика отстала',
        text = 'Первая строка\r\n.\r\nПоследняя строка',
    })

    t.assert_equals(err, nil)
    t.assert_equals(sent, true)

    local letter = fetched(address)

    t.assert_equals(letter.subject, 'Реплика отстала')
    t.assert_str_contains(letter.from, 'Узел storage-001-a')
    t.assert_str_contains(letter.to, 'Дежурный')
    t.assert_equals(letter.text, 'Первая строка\r\n.\r\nПоследняя строка')
    t.assert_not_equals(letter.id, nil, 'у письма есть устойчивый опознаватель')
end

g.test_html_letter_arrives_with_both_parts = function()
    needs(MAILPIT.smtp, 'Mailpit')

    via_mailpit('tarantool@example.org')

    local address = helper.unique_address('report')

    mail.send({
        to = address,
        subject = 'Отчёт',
        text = 'Простой текст',
        html = '<p>Разметка</p>',
    })

    local letter = fetched(address)

    t.assert_equals(letter.text, 'Простой текст')
    t.assert_equals(letter.html, '<p>Разметка</p>')
end

g.test_attachments_are_seen_by_a_real_server_and_come_back = function()
    -- Вложения проверяются чужим разборщиком, а не своим: Mailpit
    -- перечисляет их через API с именем и типом, и кириллица в имени,
    -- закодированная по RFC 2231, обязана вернуться именем, а не кодом.
    needs(MAILPIT.smtp, 'Mailpit')

    via_mailpit('tarantool@example.org')

    local address = helper.unique_address('attached')
    local attachments = {
        { name = 'report.csv', type = 'text/csv', content = 'a,b\r\n1,2\r\n' },
        { name = 'отчёт за день.bin', type = 'application/octet-stream', content = ('\0\255'):rep(5) },
    }

    local sent, err = mail.send({
        to = address,
        subject = 'Отчёт',
        text = 'см. вложение',
        html = '<p>см. вложение</p>',
        attachments = attachments,
    })

    t.assert_equals(err, nil)
    t.assert_equals(sent, true)

    local shown = helper.received(address)

    t.assert_equals(shown.Text, 'см. вложение')
    t.assert_equals(shown.HTML, '<p>см. вложение</p>')
    t.assert_equals(#shown.Attachments, 2)
    t.assert_equals(helper.at(shown.Attachments, 1).FileName, 'report.csv')
    t.assert_equals(helper.at(shown.Attachments, 1).ContentType, 'text/csv')
    t.assert_equals(helper.at(shown.Attachments, 2).FileName, 'отчёт за день.bin')
    t.assert_equals(helper.at(shown.Attachments, 2).Size, 10)
    t.assert_equals(fetched(address).attachments, attachments)
end

g.test_real_server_refuses_a_letter_without_recipients = function()
    needs(MAILPIT.smtp, 'Mailpit')

    mail.configure({
        from = 'tarantool@example.org',
        smtp = { host = MAILPIT.host, port = MAILPIT.smtp },
    })

    local sent, err = mail.send({ subject = 'Некому' })

    t.assert_equals(sent, false)
    t.assert_str_contains(err, 'получателей нет')
end

g.test_missing_server_is_reported_not_raised = function()
    -- Порт, на котором заведомо никто не слушает: узел обязан пережить
    -- это записью в журнал, а не падением.
    mail.configure({ from = 'a@b', smtp = { host = '127.0.0.1', port = 1, timeout = 0.5 } })

    local sent, err = mail.send({ to = 'c@d' })

    t.assert_equals(sent, false)
    t.assert_not_equals(err, nil)
end

g.test_letter_comes_back_by_imap_with_folders_and_flags = function()
    needs(GREENMAIL.imap, 'GreenMail')

    -- Ящик свой у прогона: GreenMail один на машину, а проверки идут
    -- разом из нескольких рабочих копий дерева.
    local mailbox = helper.unique_address('dev')

    via_greenmail(mailbox)

    local subject = 'Проверка IMAP ' .. mailbox

    t.assert_equals(mail.send({ to = mailbox, subject = subject, text = 'Тело письма' }), true)

    require('fiber').sleep(1)

    local folders, folders_error = mail.folders()

    t.assert_equals(folders_error, nil)
    t.assert_not_equals(folders, nil)

    local letters, err = mail.fetch({ via = 'imap', limit = 5 })

    t.assert_equals(err, nil)
    t.assert_not_equals(#letters, 0)

    ---@type any
    local found

    for _, letter in ipairs(letters) do
        if letter.subject == subject then
            found = letter
        end
    end

    local letter = assert(found, 'письмо не нашлось в ящике')

    t.assert_equals(letter.text, 'Тело письма')
    t.assert_not_equals(letter.id, nil, 'у письма есть UID')
end

g.test_unseen_letters_can_be_asked_for_separately = function()
    needs(GREENMAIL.imap, 'GreenMail')

    -- Ящик свой у прогона: соседний прогон, прочитав общий ящик, пометил
    -- бы прочитанным и это письмо.
    local mailbox = helper.unique_address('unseen')

    via_greenmail(mailbox)

    local subject = 'Непрочитанное ' .. mailbox

    mail.send({ to = mailbox, subject = subject, text = 'Тело' })

    require('fiber').sleep(1)

    -- Читаем непрочитанное и сразу помечаем прочитанным: второй запрос
    -- того же самого обязан его уже не увидеть.
    local first = mail.fetch({ via = 'imap', unseen = true, mark_seen = true, limit = 10 })

    t.assert_not_equals(#first, 0)

    local again = mail.fetch({ via = 'imap', unseen = true, limit = 10 })

    for _, letter in ipairs(again) do
        t.assert_not_equals(letter.subject, subject, 'письмо осталось непрочитанным')
    end
end

g.test_wrong_password_is_reported_by_a_real_server = function()
    -- Проверяется на Mailpit, а не на GreenMail: второй поднят
    -- с выключенной проверкой пароля, чтобы ящики заводились сами,
    -- и принимает любой.
    needs(MAILPIT.pop3, 'Mailpit')

    via_mailpit('tarantool@example.org', 'не тот пароль')

    local letters, err = mail.fetch({ via = 'pop3' })

    t.assert_equals(letters, nil)
    t.assert_str_contains(err, 'пароль')
end

g.test_cram_md5_is_accepted_by_a_real_server = function()
    -- smtp4dev проверяет отзыв по паролю из списка учётных записей:
    -- сходится — письмо принято, и способ выбран сам, без настройки,
    -- потому что сервер его предлагает.
    needs(SMTP4DEV.smtp, 'smtp4dev')

    via_smtp4dev(nil)

    -- Тема своя у прогона: сервер один на машину, и письмо ищется по ней.
    local subject = 'CRAM-MD5 ' .. helper.unique_address('cram')
    local sent, err = mail.send({ to = 'duty@example.org', subject = subject, text = 'Тело' })

    t.assert_equals(err, nil)
    t.assert_equals(sent, true)

    require('fiber').sleep(0.3)

    ---@type any
    local found

    for _, letter in ipairs(smtp4dev_messages()) do
        if letter.subject == subject then
            found = letter
        end
    end

    t.assert_not_equals(found, nil, 'письмо не нашлось на сервере')
end

g.test_wrong_password_by_cram_md5_is_refused_by_a_real_server = function()
    -- Отзыв на чужом пароле не сходится: сервер обязан отказать,
    -- а мы — назвать шаг и код.
    needs(SMTP4DEV.smtp, 'smtp4dev')

    via_smtp4dev('cram-md5', 'не тот пароль')

    local sent, err = mail.send({ to = 'duty@example.org', subject = 'Не дойдёт' })

    t.assert_equals(sent, false)
    t.assert_str_contains(err, 'вход: отзыв')
    t.assert_str_contains(err, '535')
end

g.test_xoauth2_command_is_understood_by_a_real_server = function()
    -- Токен smtp4dev сверяет только с настоящим поставщиком OAuth 2.0,
    -- так что вход не пройдёт. Проверяется другое: команду сервер
    -- разобрал — на негодную форму он отвечает «Auth data in incorrect
    -- format», а на разобранную и отвергнутую — «Authentication failure».
    needs(SMTP4DEV.smtp, 'smtp4dev')

    via_smtp4dev('xoauth2', 'ya29.токен')

    local sent, err = mail.send({ to = 'duty@example.org', subject = 'Не дойдёт' })

    t.assert_equals(sent, false)
    t.assert_str_contains(err, '535')
    t.assert_str_contains(err, 'Authentication failure')
end

g.test_named_method_wins_over_the_choice_of_the_server = function()
    -- Сервер предлагает CRAM-MD5, а настройка называет PLAIN: письмо
    -- уходит по PLAIN и доходит — способ выбирает настройка.
    needs(SMTP4DEV.smtp, 'smtp4dev')

    via_smtp4dev('plain')

    local sent, err = mail.send({ to = 'duty@example.org', subject = 'PLAIN', text = 'Тело' })

    t.assert_equals(err, nil)
    t.assert_equals(sent, true)
end

g.test_xoauth2_refused_by_a_server_without_it_does_not_hang = function()
    -- GreenMail не знает XOAUTH2 ни по IMAP, ни по POP3. Проверяется, что
    -- отказ приходит сразу словами сервера, а разговор не ждёт
    -- продолжения до срока: у IMAP это тегованный NO на саму команду,
    -- у POP3 — -ERR. Токен берётся у поставщика, как в бою.
    needs(GREENMAIL.imap, 'GreenMail')

    local asked = 0

    local function provider()
        asked = asked + 1

        return 'ya29.токен'
    end

    mail.configure({
        host = GREENMAIL.host,
        username = 'oauth@example.org',
        password = provider,
        allow_plaintext_auth = true,
        timeout = 2,
        imap = { port = GREENMAIL.imap, auth = 'xoauth2' },
        pop3 = { port = GREENMAIL.pop3, auth = 'xoauth2' },
    })

    local started = require('clock').monotonic()
    local letters, err = mail.fetch({ via = 'imap' })

    t.assert_equals(letters, nil)
    t.assert_str_contains(err, "вход: a0001 NO AUTHENTICATE failed. Unsupported authentication mechanism 'XOAUTH2'")

    letters, err = mail.fetch({ via = 'pop3' })

    t.assert_equals(letters, nil)
    t.assert_str_contains(err, 'вход: -ERR')
    t.assert_lt(require('clock').monotonic() - started, 2, 'отказ сразу, а не по сроку')
    t.assert_equals(asked, 2, 'поставщик зовётся на каждый вход')
end
