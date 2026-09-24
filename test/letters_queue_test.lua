--- Письма очередью на временном узле: настоящая `tnt-queue` повторяет
--- отказ «попробуйте позже» и зарывает отказ «не пробуйте больше».
---
--- Двойник очереди показал бы только, что письма правильно разговаривают
--- сами с собой. Здесь очередь настоящая — сообщение в спейсе, работник,
--- отступ и спейс зарытых, — а почта отвечает по списку: живой сервер
--- для отказа по заказу не нужен, он проверяется в `letters_live_test.lua`.

local fio = require('fio')
local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = t.group('tnt.mail.letters.queue')

g.before_all(function()
    g.server = helper.start_node()

    g.server:exec(function(views, double)
        local mail = require('tnt.mail')
        local queue = require('tnt.queue')
        local template = require('tnt.template')

        mail.configure({ from = 'noreply@example.org', smtp = { host = 'почтовик' } })

        -- Почта с ответами по списку: сборка настоящая, отправка — нет.
        local mailer = dofile(double)(mail)

        local tube = queue.declare('letters', { ttr = 5 })
        local letters = mail.letters({ views = template.new({ path = views }), queue = tube, mailer = mailer })

        letters:declare('confirm', {
            subject = 'Подтвердите почту',
            to = function(data)
                return data.email
            end,
            view = 'mail.confirm',
        })

        rawset(_G, 'post', { letters = letters, mailer = mailer, tube = tube })
        rawset(
            _G,
            'consumer',
            tube:consume(letters:handler(), { max_attempts = 3, backoff = { base = 0.05, max = 0.05 } })
        )
    end, { fio.abspath(helper.VIEWS), fio.abspath(helper.MAILER) })
end)

g.after_all(function()
    helper.stop_node(g.server)
end)

g.test_temporary_refusal_is_retried_by_the_queue = function()
    local seen = g.server:exec(function()
        local post = rawget(_G, 'post')

        post.mailer.sent = {}
        post.mailer.answers = {
            {
                false,
                'получатель maria@example.org: сервер ответил 451 — 451 4.2.2 mailbox full',
            },
            { true },
        }

        local id =
            assert(post.letters:queue('confirm', { name = 'Мария', email = 'maria@example.org', link = 'x' }))

        -- Ждётся событие, а срок только не даёт поломке повесить прогон:
        -- под нагрузкой соседних прогонов цикл событий узла встаёт надолго.
        require('luatest').helpers.retrying({ timeout = 15 }, function()
            assert(#post.mailer.sent == 2, 'второй попытки ещё нет')
            assert(post.tube:status().depth.ready == 0)
            -- Итог работник считает после движения в очереди, а движение
            -- ждёт записи журнала: отправка уже видна, а счёт ещё нет.
            -- Поэтому ждутся оба счёта, которые сверяет проверка.
            local counts = post.tube:status().counts

            assert(counts.retry == 1, 'возврата на выдачу ещё нет')
            assert(counts.ack == 1, 'подтверждения ещё нет')
        end)

        return {
            id = id,
            first = post.mailer.sent[1].message_id,
            second = post.mailer.sent[2].message_id,
            dead = box.space.letters_dead:count(),
            counts = post.tube:status().counts,
        }
    end)

    t.assert_equals(seen.first, seen.second, 'повтор уходит тем же письмом')
    t.assert_str_matches(seen.first, '<%w+@tarantool>')
    t.assert_equals(seen.dead, 0)
    t.assert_equals({ seen.counts.retry, seen.counts.ack }, { 1, 1 })
end

g.test_permanent_refusal_is_buried_at_once = function()
    local seen = g.server:exec(function()
        local post = rawget(_G, 'post')

        post.mailer.sent = {}
        post.mailer.answers = {
            {
                false,
                'получатель nobody@example.org: сервер ответил 550 — 550 5.1.1 no such user',
            },
        }

        local id = assert(post.letters:queue('confirm', { name = 'x', email = 'nobody@example.org', link = 'x' }))

        require('luatest').helpers.retrying({ timeout = 5 }, function()
            assert(box.space.letters_dead:get(id) ~= nil, 'письмо ещё не зарыто')
        end)

        local dead = assert(box.space.letters_dead:get(id))

        return { attempts = #post.mailer.sent, reason = dead.reason, attempt = dead.attempt }
    end)

    t.assert_equals(seen.attempts, 1, 'отказ 5xx не повторяется')
    t.assert_equals(seen.attempt, 1)
    t.assert_equals(
        seen.reason,
        'получатель nobody@example.org: сервер ответил 550 — 550 5.1.1 no such user'
    )
end
