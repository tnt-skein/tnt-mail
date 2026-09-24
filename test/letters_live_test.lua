--- Письма объявлениями против настоящего приёмника почты.
---
--- Mailpit принимает письмо и показывает его части своим API: так видно,
--- что письмо из одного вида дошло двумя частями, что очередь повторила
--- отказ, пока почтовика не было, и что предпросмотр кладёт в файл ту же
--- разметку, какую получил ящик. Без Mailpit проверки пропускаются:
--- гейты не должны зависеть от докера (`make mail-up`).

local fio = require('fio')
local t = require('luatest')
local utf8 = require('utf8')

local helper = dofile('test/helper.lua')

local g = t.group('tnt.mail.letters.live')

--- Где стоит Mailpit: те же адреса, что поднимает скрипт стенда.
local MAILPIT = helper.MAILPIT

--- Отвечает ли Mailpit.
---@return boolean
local function listening()
    local socket = require('socket').tcp_connect(MAILPIT.host, MAILPIT.smtp, 0.3)

    if socket == nil then
        return false
    end

    socket:close()

    return true
end

--- Пропускает проверку без Mailpit.
local function needs_mailpit()
    t.skip_if(not listening(), 'Mailpit не отвечает: поднимите его — make mail-up')
end

g.before_each(function()
    helper.load_letters('tnt.mail')
end)

g.after_each(function()
    helper.unload_letters()
    package.loaded[helper.LETTERS] = nil
end)

g.test_queued_letter_arrives_with_both_parts_after_a_retry = function()
    needs_mailpit()

    local address = helper.unique_address('letters')
    local server = helper.start_node()

    local seen = server:exec(function(views, email, mailpit)
        local mail = require('tnt.mail')
        local queue = require('tnt.queue')
        local retrying = require('luatest').helpers.retrying

        -- Первая попытка уходит на порт, где никого нет: отказ без ответа
        -- сервера, и очередь обязана его повторить.
        mail.configure({ from = 'noreply@example.org', smtp = { host = mailpit.host, port = 1, timeout = 1 } })

        local tube = queue.declare('live_letters', { ttr = 10 })
        local letters = mail.letters({ views = require('tnt.template').new({ path = views }), queue = tube })

        letters:declare('confirm', {
            subject = 'Подтвердите почту',
            to = function(data)
                return data.email
            end,
            view = 'mail.confirm',
        })

        local data = { name = 'Мария', email = email, link = 'https://example.org/confirm?token=a1&user=7' }
        local consumer = tube:consume(letters:handler(), { backoff = { base = 0.2, max = 0.2 } })

        assert(letters:queue('confirm', data))

        retrying({ timeout = 5 }, function()
            assert(tube:status().counts.retry >= 1, 'повтора ещё нет')
        end)

        mail.configure({ from = 'noreply@example.org', smtp = { host = mailpit.host, port = mailpit.smtp } })

        retrying({ timeout = 5 }, function()
            assert(tube:status().counts.ack == 1, 'письмо ещё не отправлено')
        end)

        consumer:stop()

        local built = letters:build('confirm', data)

        return { text = built.text, html = built.html, counts = tube:status().counts }
    end, { fio.abspath(helper.VIEWS), address, MAILPIT })

    helper.stop_node(server)

    local message = helper.received(address)

    t.assert_equals(seen.counts.ack, 1)
    t.assert_equals(message.Subject, 'Подтвердите почту')
    t.assert_equals(message.Text, seen.text)
    t.assert_equals(message.HTML, seen.html)
    t.assert_str_contains(message.Text, 'подтвердить (https://example.org/confirm?token=a1&user=7)')
end

g.test_preview_holds_the_markup_the_mailbox_receives = function()
    needs_mailpit()

    local mail = helper.module('tnt.mail')
    local letters = require(helper.LETTERS)
    local address = helper.unique_address('letters')
    local data = letters.declared.confirm.example

    mail.configure({ smtp = { host = MAILPIT.host, port = MAILPIT.smtp } })

    t.assert_equals(letters:send('confirm', { name = data.name, email = address, link = data.link }), true)

    local message = helper.received(address)

    helper.module('tnt.fs').with_temp_dir(function(directory)
        local files = assert(letters:preview(directory, { 'confirm' }))
        local html = assert(helper.module('tnt.fs').read(helper.at(files.letters, 1).html))

        t.assert_equals(html, utf8.char(0xFEFF) .. message.HTML)
    end)
end
