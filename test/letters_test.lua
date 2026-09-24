--- Письма объявлениями: объявление, сборка из вида, отправка сразу
--- и очередью, итог обработчика и предпросмотр в файлах.
---
--- Почта и очередь здесь — двойники договора: письма знают их по `send`
--- и `render`, а не по устройству. Шаблоны — настоящие `tnt-template`:
--- рисовать вид двойником значило бы проверить договор с самим собой.

local t = require('luatest')
local utf8 = require('utf8')

local helper = dofile('test/helper.lua')

local assert_blamed = helper.assert_blamed

local g = t.group('tnt.mail.letters')

---@type any
local mail

---@type any
local template

local mailer_of = helper.mailer_of

--- Двойник очереди: помнит тело и настройки отправки.
---@param refusal any Чем отказать; пусто — принять
---@return table queue
local function queue_of(refusal)
    local queue = { sent = {} }

    function queue.send(self, body, opts)
        if refusal ~= nil then
            return nil, refusal
        end

        table.insert(self.sent, { body = body, opts = opts })

        return 'm-' .. #self.sent
    end

    return queue
end

--- Письма на видах-образцах с двойником почты.
---@param opts table|nil Сверх почты и видов
---@return table letters
---@return table mailer
local function letters_of(opts)
    local given = { views = template.new({ path = helper.VIEWS }), mailer = mailer_of(mail) }

    for key, value in pairs(opts or {}) do
        given[key] = value
    end

    return mail.letters(given), given.mailer
end

--- Данные подтверждения.
local CONFIRM = { name = 'Мария', email = 'maria@example.org', link = 'https://example.org/c?a=1&b=2' }

--- Подтверждение почты: одно объявление на все проверки сборки.
---@param letters table
---@return table
local function with_confirm(letters)
    return letters:declare('confirm', {
        subject = 'Подтвердите почту',
        to = function(data)
            return data.email
        end,
        view = 'mail.confirm',
        example = CONFIRM,
    })
end

g.before_each(function()
    mail = helper.load_letters('tnt.mail')
    template = helper.module('tnt.template')
    mail.configure({ from = 'noreply@example.org', smtp = { host = 'почтовик' } })
end)

g.after_each(function()
    helper.unload_letters()
    package.loaded[helper.LETTERS] = nil
end)

g.test_letters_send_through_this_mail_by_default = function()
    local letters = mail.letters()

    t.assert_is(letters.mailer, mail)
    t.assert_equals(letters:names(), {})
end

g.test_wrong_settings_are_refused_at_the_line_of_the_caller = function()
    assert_blamed({
        {
            function()
                mail.letters({ view = template.new() })
            end,
            'настройки писем: ключа «view» нет, есть from, mailer, queue, views',
        },
        {
            function()
                mail.letters({ mailer = { send = function() end } })
            end,
            'настройки писем.mailer.render — функция или вызываемая таблица, а не nil',
        },
        {
            function()
                mail.letters({ mailer = { render = function() end } })
            end,
            'настройки писем.mailer.send — функция или вызываемая таблица, а не nil',
        },
        {
            function()
                mail.letters({ views = { render = function() end } })
            end,
            'настройки писем.views.render_text — функция или вызываемая таблица, а не nil',
        },
        {
            function()
                mail.letters({ views = { render_text = function() end } })
            end,
            'настройки писем.views.render — функция или вызываемая таблица, а не nil',
        },
        {
            function()
                mail.letters({ queue = {} })
            end,
            'настройки писем.queue.send — функция или вызываемая таблица, а не nil',
        },
    })
end

g.test_declaration_chains_and_names_come_sorted = function()
    local letters = letters_of()

    t.assert_is(with_confirm(letters), letters)
    letters:declare('alarm', { subject = 'Тревога', view = 'mail.confirm' })

    t.assert_equals(letters:names(), { 'alarm', 'confirm' })
end

g.test_wrong_declaration_is_refused_at_the_line_of_the_caller = function()
    local letters = with_confirm(letters_of())
    local bare = mail.letters()

    assert_blamed({
        {
            function()
                letters:declare('confirm', { subject = 'x', view = 'mail.confirm' })
            end,
            'письмо confirm уже объявлено',
        },
        {
            function()
                letters:declare('empty', { subject = 'x' })
            end,
            'письмо empty: вида нет — дайте view либо text_view',
        },
        {
            function()
                bare:declare('confirm', { subject = 'x', view = 'mail.confirm' })
            end,
            'письмо confirm рисуется шаблоном, а views письмам не дали',
        },
        {
            function()
                letters:declare('', { subject = 'x', view = 'mail.confirm' })
            end,
            'имя письма — непустая строка, а не пустая',
        },
        {
            function()
                letters:declare('typo', { subject = 'x', veiw = 'mail.confirm' })
            end,
            'письмо typo: ключа «veiw» нет, есть attachments, bcc, cc, example, from, headers, subject, '
                .. 'text_view, to, view',
        },
        {
            function()
                letters:declare('number', { subject = 7, view = 'mail.confirm' })
            end,
            'письмо number.subject — строка или функция или вызываемая таблица, а не 7',
        },
    })
end

g.test_one_view_gives_both_parts = function()
    local letters = with_confirm(letters_of())
    local letter = letters:build('confirm', CONFIRM)

    t.assert_equals(letter.subject, 'Подтвердите почту')
    t.assert_equals(letter.to, 'maria@example.org')
    t.assert_equals(letter.from, nil, 'отправитель — из настроек почты')
    t.assert_str_contains(letter.html, '<a href="https://example.org/c?a=1&amp;b=2">подтвердить</a>')
    t.assert_equals(
        letter.text,
        'Мария, подтвердите почту: подтвердить (https://example.org/c?a=1&b=2).\n\n'
            .. 'Ссылка действует сутки.\n\n-- \nКоманда примера'
    )
end

g.test_fields_come_as_values_or_functions_of_the_data = function()
    local letters = letters_of({ from = 'letters@example.org' })

    letters:declare('report', {
        subject = function(data)
            return 'Отчёт ' .. data.day
        end,
        from = function(data)
            return data.sender
        end,
        to = { 'a@example.org', 'b@example.org' },
        cc = function()
            return 'c@example.org'
        end,
        bcc = 'd@example.org',
        headers = { ['X-Report'] = 'daily' },
        attachments = function(data)
            return { { name = 'report.csv', content = data.csv } }
        end,
        view = 'mail.confirm',
    })

    local letter = letters:build('report', { day = '26.09', sender = 'audit@example.org', csv = 'a,b', name = 'x' })

    t.assert_equals(letter.subject, 'Отчёт 26.09')
    t.assert_equals(letter.from, 'audit@example.org')
    t.assert_equals(letter.to, { 'a@example.org', 'b@example.org' })
    t.assert_equals(letter.cc, 'c@example.org')
    t.assert_equals(letter.bcc, 'd@example.org')
    t.assert_equals(letter.headers, { ['X-Report'] = 'daily' })
    t.assert_equals(letter.attachments, { { name = 'report.csv', content = 'a,b' } })
    t.assert_equals(letters:build('report', { day = '1', csv = '' }).from, 'letters@example.org')
end

g.test_own_text_view_is_drawn_as_plain_text = function()
    -- Простой текст — не HTML: имя с апострофом и угловыми скобками
    -- в тексте письма должно остаться собой.
    local letters = letters_of()

    letters:declare('replied', { subject = 'Ответ', view = 'mail.replied', text_view = 'mail.replied_text' })
    letters:declare('plain', { subject = 'Только текст', text_view = 'mail.replied_text' })

    local data = { name = "O'Brien", thread = 'a < b', reply = 'ok', link = 'https://example.org/t/1' }
    local replied = letters:build('replied', data)
    local plain = letters:build('plain', data)

    t.assert_equals(
        replied.text,
        "O'Brien, в теме «a < b» новый ответ:\n\nok\n\nhttps://example.org/t/1\n"
    )
    t.assert_str_contains(replied.html, 'O&#39;Brien, в теме «a &lt; b»')
    t.assert_equals(plain.text, replied.text)
    t.assert_equals(plain.html, nil)
end

g.test_wrong_letter_is_refused_with_its_name = function()
    local letters = with_confirm(letters_of())

    letters:declare('numbered', {
        subject = function()
            return 7
        end,
        view = 'mail.confirm',
    })

    t.assert_error_msg_equals(
        'письма missing нет; объявлены: confirm, numbered',
        letters.build,
        letters,
        'missing'
    )
    t.assert_error_msg_equals(
        'письмо numbered: тема — строка, а не number',
        letters.build,
        letters,
        'numbered',
        CONFIRM
    )
    t.assert_error_msg_equals(
        'письмо confirm: данные — таблица, а не строка',
        letters.build,
        letters,
        'confirm',
        'maria@example.org'
    )
end

g.test_render_gives_the_whole_letter_or_an_invalid_refusal = function()
    local letters = with_confirm(letters_of())

    letters:declare('broken', {
        subject = 'x',
        to = 'a@b',
        view = 'mail.confirm',
        attachments = function()
            return 'report.csv'
        end,
    })

    local raw = letters:render('confirm', CONFIRM)
    local parsed = mail.parse.of(raw)

    t.assert_equals(parsed.subject, 'Подтвердите почту')
    t.assert_equals(parsed.from, 'noreply@example.org')
    t.assert_equals(parsed.text, letters:build('confirm', CONFIRM).text)
    t.assert_equals(parsed.html, letters:build('confirm', CONFIRM).html)

    local nothing, err = letters:render('broken', CONFIRM)

    t.assert_equals(nothing, nil)
    t.assert_equals(err.kind, 'invalid')
    t.assert_equals(err.retriable, false)
    t.assert_equals(
        tostring(err),
        'письмо broken: вложения должны быть списком, а не string'
    )
end

g.test_send_goes_now_and_reads_the_refusal = function()
    local letters, mailer = letters_of()

    with_confirm(letters)
    mailer.answers = {
        { true },
        { false, 'получатель maria@example.org: сервер ответил 550 — 550 5.1.1 no such user' },
    }

    t.assert_equals(letters:send('confirm', CONFIRM), true)
    t.assert_equals(helper.at(mailer.sent, 1).to, 'maria@example.org')

    local sent, err = letters:send('confirm', CONFIRM)

    t.assert_equals(sent, nil)
    t.assert_equals(
        { err.kind, err.retriable, err.status, err.recipient },
        { 'rejected', false, '5.1.1', 'maria@example.org' }
    )
end

g.test_invalid_letter_does_not_reach_the_mail = function()
    local letters, mailer = letters_of()

    letters:declare('tainted', {
        subject = 'x',
        to = function(data)
            return data.email
        end,
        view = 'mail.confirm',
    })

    local sent, err = letters:send('tainted', { email = 'a@b\r\nRCPT TO:<evil@example.org>' })

    t.assert_equals(sent, nil)
    t.assert_equals(err.kind, 'invalid')
    t.assert_equals(
        tostring(err),
        'письмо tainted: адрес в поле to: управляющий знак в «a@b..RCPT TO:<evil@example.org>»'
    )
    t.assert_equals(mailer.sent, {})
end

g.test_queue_carries_the_ready_letter_with_its_identity = function()
    -- Опознаватель и дата ставятся при постановке: повтор после обрыва
    -- уходит тем же письмом, и получатель узнаёт его по Message-ID.
    local queue = queue_of()
    local letters = with_confirm(letters_of({ queue = queue }))

    t.assert_equals(letters:queue('confirm', CONFIRM, { delay = 5, key = 'maria' }), 'm-1')

    local sent = helper.at(queue.sent, 1)
    local letter = sent.body.mail

    t.assert_equals(sent.body.letter, 'confirm')
    t.assert_equals(sent.opts, { delay = 5, key = 'maria' })
    t.assert_equals(letter.subject, 'Подтвердите почту')
    t.assert_str_matches(letter.message_id, '<%w+@tarantool>')
    t.assert_str_matches(letter.date, '%a%a%a, %d%d %a%a%a %d%d%d%d %d%d:%d%d:%d%d %+0000')

    local raw = mail.render(letter)

    t.assert_str_contains(raw, '\r\nMessage-ID: ' .. letter.message_id .. '\r\n')
    t.assert_str_contains(raw, '\r\nDate: ' .. letter.date .. '\r\n')
end

g.test_invalid_letter_does_not_go_to_the_queue = function()
    local queue = queue_of()
    local letters = letters_of({ queue = queue })

    letters:declare('broken', { subject = 'x', to = 'a@b', view = 'mail.confirm', attachments = { 'report.csv' } })

    local id, err = letters:queue('broken', CONFIRM)

    t.assert_equals(id, nil)
    t.assert_equals(
        tostring(err),
        'письмо broken: вложение №1 должно быть таблицей, а не string'
    )
    t.assert_equals(queue.sent, {})
end

g.test_queue_refusal_comes_back_as_is = function()
    local refusal = { kind = 'unreachable', retriable = true }
    local letters = with_confirm(letters_of({ queue = queue_of(refusal) }))

    local id, err = letters:queue('confirm', CONFIRM)

    t.assert_equals(id, nil)
    t.assert_is(err, refusal)
end

g.test_queue_needs_a_queue = function()
    local letters = with_confirm(letters_of())

    assert_blamed({
        {
            function()
                letters:queue('confirm', CONFIRM)
            end,
            'письма в очередь: queue письмам не дали',
        },
    })
end

g.test_handler_sends_the_letter_and_answers_by_the_queue_contract = function()
    local letters, mailer = letters_of({ queue = queue_of() })
    local handler = letters:handler()
    local message = { id = '01K', body = { letter = 'confirm', mail = { to = 'a@b', subject = 'x', text = 't' } } }

    mailer.answers = {
        { true },
        { false, 'получатель a@b: сервер ответил 451 — 451 4.2.2 mailbox full' },
        { false, 'Connection refused' },
    }

    t.assert_equals(handler(message), true)
    t.assert_equals(helper.at(mailer.sent, 1), message.body.mail)

    local _, deferred = handler(message)
    local _, failed = handler(message)

    t.assert_equals({ deferred.kind, deferred.retriable, deferred.status }, { 'deferred', true, '4.2.2' })
    t.assert_equals({ failed.kind, failed.retriable }, { 'failed', true })
end

g.test_message_without_a_letter_is_buried = function()
    local letters, mailer = letters_of()

    for _, body in ipairs({ 'письмо', { letter = 'confirm' }, { mail = 'x' } }) do
        local sent, err = letters:deliver({ body = body })

        t.assert_equals(sent, nil)
        t.assert_equals(
            { err.kind, err.retriable, err.message },
            { 'invalid', false, 'в сообщении очереди нет письма' }
        )
    end

    t.assert_equals(mailer.sent, {})
end

--- Содержимое файла.
---@param path string
---@return string
local function read(path)
    return (assert(helper.module('tnt.fs').read(path)))
end

g.test_preview_lays_the_letters_out_for_a_browser = function()
    local letters = require(helper.LETTERS)

    helper.module('tnt.fs').with_temp_dir(function(directory)
        local files = assert(letters:preview(directory))
        local confirm, replied = helper.at(files.letters, 1), helper.at(files.letters, 2)
        local sent = mail.parse.of(read(confirm.eml))
        local bom = utf8.char(0xFEFF)

        t.assert_equals(files.index, directory .. '/index.html')
        t.assert_equals(confirm.name, 'confirm')
        t.assert_equals(confirm.subject, 'Подтвердите почту')
        t.assert_equals(confirm.to, 'Мария <maria@example.org>')
        t.assert_equals(confirm.html, directory .. '/confirm.html')
        t.assert_equals(read(assert(confirm.html)), bom .. sent.html)
        t.assert_equals(read(confirm.text), bom .. sent.text)
        t.assert_str_contains(sent.html, 'href="https://example.org/confirm?token=a1&amp;user=7"')
        t.assert_equals(replied.subject, 'Ответ в теме «Отставание реплики»')
        t.assert_str_contains(read(replied.text), "Перезапустили узел <storage-001-b> — O'Brien")

        t.assert_equals(
            read(files.index),
            table.concat({
                '<!DOCTYPE html>',
                '<html lang="ru"><head><meta charset="utf-8"><title>Письма</title></head><body>',
                '<table><tr><th>Письмо</th><th>Тема</th><th>Кому</th><th>Файлы</th></tr>',
                '<tr><td>confirm</td><td>Подтвердите почту</td><td>Мария &lt;maria@example.org&gt;</td>'
                    .. '<td><a href="confirm.html">разметка</a> <a href="confirm.txt">текст</a> '
                    .. '<a href="confirm.eml">письмо</a></td></tr>',
                '<tr><td>replied</td><td>Ответ в теме «Отставание реплики»</td><td>maria@example.org</td>'
                    .. '<td><a href="replied.html">разметка</a> <a href="replied.txt">текст</a> '
                    .. '<a href="replied.eml">письмо</a></td></tr>',
                '</table></body></html>',
                '',
            }, '\n')
        )
    end)
end

g.test_preview_takes_named_letters_and_letters_without_example = function()
    local letters = letters_of()

    letters:declare('plain', { subject = 'Текст & <тема>', to = 'a@b', text_view = 'mail.replied_text' })
    letters:declare('odd/name-1+2', { subject = 'x', to = 'a@b', view = 'mail.confirm' })

    helper.module('tnt.fs').with_temp_dir(function(directory)
        local files = assert(letters:preview(directory .. '/deep/er', { 'plain' }))
        local plain = helper.at(files.letters, 1)

        t.assert_equals(#files.letters, 1)
        t.assert_equals(plain.html, nil)
        t.assert_equals(plain.text, directory .. '/deep/er/plain.txt')
        t.assert_equals(read(plain.text), utf8.char(0xFEFF) .. ', в теме «» новый ответ:\n\n\n\n\n')
        t.assert_str_contains(read(files.index), '<td>Текст &amp; &lt;тема&gt;</td>')
        t.assert_str_contains(
            read(files.index),
            '<td><a href="plain.txt">текст</a> <a href="plain.eml">письмо</a></td>'
        )

        local odd = assert(letters:preview(directory, { 'odd/name-1+2' }))

        t.assert_equals(helper.at(odd.letters, 1).eml, directory .. '/odd_name-1_2.eml')
        t.assert_str_contains(read(odd.index), '<a href="odd_name-1_2.html">разметка</a>')
    end)
end

g.test_preview_refuses_a_letter_that_does_not_assemble = function()
    local letters = letters_of()

    letters:declare('broken', {
        subject = 'x',
        to = 'a@b',
        view = 'mail.confirm',
        attachments = function()
            return 'x'
        end,
        example = { name = 'a' },
    })

    helper.module('tnt.fs').with_temp_dir(function(directory)
        local files, err = letters:preview(directory)

        t.assert_equals(files, nil)
        t.assert_equals(
            err,
            'письмо broken: вложения должны быть списком, а не string'
        )
    end)
end

g.test_preview_refuses_a_directory_it_cannot_write = function()
    local letters = with_confirm(letters_of())

    helper.module('tnt.fs').with_temp_dir(function(directory)
        local fs = helper.module('tnt.fs')

        fs.write(directory .. '/file', 'x')

        local files, err = letters:preview(directory .. '/file/inside')

        t.assert_equals(files, nil)
        t.assert_str_contains(err, directory .. '/file/inside')

        fs.make_tree(directory .. '/busy/confirm.eml')

        local busy, busy_err = letters:preview(directory .. '/busy')

        t.assert_equals(busy, nil)
        t.assert_str_contains(busy_err, directory .. '/busy/confirm.eml')

        fs.make_tree(directory .. '/index/index.html')

        local indexed, index_err = letters:preview(directory .. '/index')

        t.assert_equals(indexed, nil)
        t.assert_str_contains(index_err, directory .. '/index/index.html')
    end)
end

g.test_preview_refuses_each_of_the_three_files = function()
    local letters = with_confirm(letters_of())

    helper.module('tnt.fs').with_temp_dir(function(directory)
        local fs = helper.module('tnt.fs')

        for _, name in ipairs({ 'confirm.txt', 'confirm.html' }) do
            local place = ('%s/%s'):format(directory, name:gsub('%.', '_'))

            fs.make_tree(place .. '/' .. name)

            local files, err = letters:preview(place)

            t.assert_equals(files, nil)
            t.assert_str_contains(err, place .. '/' .. name)
        end
    end)
end
