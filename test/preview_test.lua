--- Вход цели сборки `make mail-preview`: модуль писем — в каталог,
--- код выхода и строки вывода.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = t.group('tnt.mail.preview')

--- Модуль писем-образцов.
local LETTERS = helper.LETTERS

---@type any
local preview

--- Что цель сказала и на что пожаловалась.
---@type { said: string[], complaints: string[] }
local output

g.before_each(function()
    helper.load_letters('tnt.mail')
    preview = helper.module('tnt.mail.preview')
    output = { said = {}, complaints = {} }
    preview._set_source({
        say = function(line)
            table.insert(output.said, line)
        end,
        complain = function(line)
            table.insert(output.complaints, line)
        end,
    })
    helper.module('tnt.mail').configure({ smtp = { host = 'почтовик' } })
end)

g.after_each(function()
    preview._set_source(nil)
    helper.unload_letters()
    package.loaded[LETTERS] = nil
end)

g.test_letters_of_the_named_module_go_to_the_directory = function()
    helper.module('tnt.fs').with_temp_dir(function(directory)
        t.assert_equals(preview.main(LETTERS, directory), 0)
        t.assert_equals(output.said, {
            directory .. '/index.html',
            directory .. '/confirm.html',
            directory .. '/replied.html',
        })
        t.assert_equals(output.complaints, {})
    end)
end

g.test_directory_by_default_is_under_var = function()
    t.assert_equals(preview.DIRECTORY, 'var/mail-preview')

    helper.module('tnt.fs').with_temp_dir(function(directory)
        local fs = helper.module('tnt.fs')

        preview.DIRECTORY = directory .. '/default'

        t.assert_equals(preview.main(LETTERS), 0)
        t.assert_equals(fs.exists(directory .. '/default/confirm.eml'), true)
    end)
end

g.test_text_only_letter_is_named_by_its_text = function()
    local letters = require(LETTERS)

    letters:declare('plain', { subject = 'x', to = 'a@b', text_view = 'mail.replied_text' })

    helper.module('tnt.fs').with_temp_dir(function(directory)
        t.assert_equals(preview.main(LETTERS, directory), 0)
        t.assert_equals(output.said[3], directory .. '/plain.txt')
    end)
end

g.test_call_without_a_module_is_a_wrong_call = function()
    t.assert_equals(preview.main(nil), 2)
    t.assert_equals(preview.main(''), 2)
    t.assert_equals(output.complaints, {
        'назовите модуль писем: make mail-preview LETTERS=app.mail',
        'назовите модуль писем: make mail-preview LETTERS=app.mail',
    })
    t.assert_equals(output.said, {})
end

g.test_module_that_does_not_load_is_a_refusal = function()
    t.assert_equals(preview.main('app.missing_letters', 'var'), 1)
    t.assert_str_matches(
        helper.at(output.complaints, 1),
        "письма app%.missing_letters не собраны: .*module 'app%.missing_letters' not found.*"
    )
    t.assert_equals(output.said, {})
end

g.test_letter_that_does_not_assemble_is_a_refusal = function()
    -- Отправителя нет ни у писем, ни в настройках почты: письмо не
    -- собирается, и в каталог не ложится ничего.
    helper.module('tnt.mail').configure({})
    require(LETTERS).from = nil

    helper.module('tnt.fs').with_temp_dir(function(directory)
        t.assert_equals(preview.main(LETTERS, directory), 1)
        t.assert_equals(output.complaints, {
            ('письма %s не собраны: письмо confirm: отправитель не задан: сервер не примет письмо без него'):format(
                LETTERS
            ),
        })
        t.assert_equals(output.said, {})
    end)
end

g.test_output_goes_to_the_streams_of_the_process = function()
    -- Без подмены цель пишет в потоки процесса: пути — в вывод, жалобу —
    -- в поток ошибок, где их увидит тот, кто звал `make`.
    preview._set_source(nil)

    t.assert_equals(preview.main(''), 2)

    helper.module('tnt.fs').with_temp_dir(function(directory)
        t.assert_equals(preview.main(LETTERS, directory), 0)
    end)
end
