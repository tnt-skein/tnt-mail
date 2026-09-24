--- Простой текст из разметки: что увидит получатель, чья программа
--- показывает только текст.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = t.group('tnt.mail.text')

---@type any
local text

g.before_all(function()
    text = helper.load('tnt.mail.text')
end)

g.after_all(function()
    helper.unload()
end)

g.test_nothing_gives_an_empty_text = function()
    t.assert_equals(text.of(nil), '')
    t.assert_equals(text.of(''), '')
end

g.test_whitespace_collapses_as_a_browser_shows_it = function()
    t.assert_equals(text.of('  Мария,\n\t  вам   ответили  '), 'Мария, вам ответили')
end

g.test_paragraphs_are_separated_by_one_empty_line = function()
    local html = '<p>Первый</p>\n\n<p>Второй</p><h1>Заголовок</h1><h2>a</h2><h3>b</h3><h4>c</h4>'
        .. '<h5>d</h5><h6>e</h6><blockquote>цитата</blockquote><hr>после черты'

    t.assert_equals(
        text.of(html),
        'Первый\n\nВторой\n\nЗаголовок\n\na\n\nb\n\nc\n\nd\n\ne\n\nцитата\n\nпосле черты'
    )
end

g.test_lines_start_anew_without_an_empty_line = function()
    local html = 'а<br>б<br/>в<div>г</div><section>д</section><article>е</article><header>ж</header>'
        .. '<footer>з</footer><center>и</center><dl><dt>к</dt><dd>л</dd></dl>'

    t.assert_equals(text.of(html), 'а\nб\nв\nг\nд\nе\nж\nз\nи\nк\nл')
end

g.test_table_rows_are_lines_and_cells_are_words = function()
    local html = '<table><tr><td>узел</td> <td>отстал</td></tr><tr><td>a</td><td>b</td></tr></table>'

    t.assert_equals(text.of(html), 'узел отстал\nab')
end

g.test_hidden_parts_fall_out_with_their_content = function()
    local html = '<!DOCTYPE html><?xml version="1.0"?><html><head><meta charset="utf-8">'
        .. '<title>Тема</title><style>p { color: red }</style></head><body>'
        .. '<script>alert(1)</script><template>шаблон</template><!-- заметка > с угловой -->'
        .. '<p>Тело</p></body></html>'

    t.assert_equals(text.of(html), 'Тело')
end

g.test_hidden_part_ends_only_with_its_own_closing_tag = function()
    -- Закрывающий тег чужого элемента внутри скрытого не открывает вывод:
    -- заголовок страницы не должен просочиться в текст письма.
    t.assert_equals(text.of('<head><title>Тема</title> хвост </head>тело'), 'тело')
    t.assert_equals(text.of('<STYLE>p{}</STYLE>тело'), 'тело')
end

g.test_list_items_get_markers_and_nested_ones_an_indent = function()
    local html = '<ul><li>один</li><li>два<ol><li>первый</li><li>второй</li></ol></li></ul>'
        .. '<ol><li>снова</li></ol><li>сам по себе</li>'

    t.assert_equals(
        text.of(html),
        '- один\n- два\n  1. первый\n  2. второй\n\n1. снова\n\n- сам по себе'
    )
end

g.test_numbering_is_counted_per_list = function()
    local html = '<ol><li>a</li><li>b</li><li>c</li></ol><ol><li>d</li></ol>'

    t.assert_equals(text.of(html), '1. a\n2. b\n3. c\n\n1. d')
end

g.test_link_shows_its_address_after_the_text = function()
    local html =
        '<p>Подтвердите почту: <a href="https://example.org/confirm?a=1&amp;b=2">подтвердить</a>.</p>'

    t.assert_equals(
        text.of(html),
        'Подтвердите почту: подтвердить (https://example.org/confirm?a=1&b=2).'
    )
end

g.test_link_whose_text_is_its_address_is_shown_once = function()
    t.assert_equals(text.of('<a href="https://example.org">https://example.org</a>'), 'https://example.org')
    t.assert_equals(text.of('<a href="mailto:duty@example.org">duty@example.org</a>'), 'duty@example.org')
    t.assert_equals(text.of('<a href="https://example.org"> <b>https://example.org</b> </a>'), 'https://example.org')
end

g.test_link_without_text_shows_its_address = function()
    t.assert_equals(text.of('<a href="https://example.org"><img src="logo.png"></a>'), 'https://example.org')
end

g.test_link_inside_the_page_and_without_address_shows_only_text = function()
    t.assert_equals(
        text.of('<a href="#top">наверх</a> <a name="x">якорь</a> <a href="">пусто</a>'),
        'наверх якорь пусто'
    )
end

g.test_link_attributes_are_read_in_any_case_and_quoting = function()
    t.assert_equals(text.of("<A HREF='https://example.org/A'>тут</A>"), 'тут (https://example.org/A)')
    t.assert_equals(text.of('<a class="x" href = https://example.org/b>тут</a>'), 'тут (https://example.org/b)')
    t.assert_equals(text.of('<a data-href="https://x.org" title="t">тут</a>'), 'тут (https://x.org)')
end

g.test_image_shows_its_description = function()
    t.assert_equals(
        text.of('Логотип: <img src="a.png" alt="Пример &amp; сын"> и <img src="b.png">.'),
        'Логотип: Пример & сын и .'
    )
end

g.test_preformatted_text_keeps_its_spaces_and_lines = function()
    local html = '<p>Журнал:</p><pre>  узел   a\n\tb &lt;c&gt;\n</pre>после'

    t.assert_equals(text.of(html), 'Журнал:\n\n  узел   a\n\tb <c>\n\nпосле')
end

g.test_stray_closing_pre_does_not_keep_spaces = function()
    t.assert_equals(text.of('</pre>a   b<pre> c  d</pre>'), 'a b\n\n c  d')
end

g.test_named_characters_become_letters = function()
    local html = '&amp;&lt;&gt;&quot;&apos;&nbsp;&laquo;&raquo;&mdash;&ndash;&hellip;&copy;&reg;&trade;'
        .. '&euro;&bull;&middot;&times;&lsquo;&rsquo;&ldquo;&rdquo;&bdquo;'

    t.assert_equals(text.of(html), '&<>"\'\194\160«»—–…©®™€•·×‘’“”„')
end

g.test_unknown_names_stay_as_written = function()
    t.assert_equals(text.of('&unknown; &amp x &; &#;'), '&unknown; &amp x &; &#;')
end

g.test_numbered_characters_become_letters_within_unicode = function()
    t.assert_equals(
        text.of('&#32;a&#1046;&#x416;&#X416;&#xD7FF;&#xE000;&#x10FFFF;'),
        'aЖЖЖ\237\159\191\238\128\128\244\143\191\191'
    )
end

g.test_control_surrogate_and_out_of_range_numbers_stay_as_written = function()
    local html = '&#0;&#1;&#9;&#31;&#xD800;&#xDFFF;&#x110000;&#12a;&#xZZ;'

    t.assert_equals(text.of(html), html)
end

g.test_markers_of_the_converter_cannot_come_from_the_input = function()
    -- Знаки отступа и разрывов из входа выброшены: иначе они стали бы
    -- пробелом и переводом строки, которых в разметке не было.
    t.assert_equals(text.of('a\1b\2c\3d'), 'abcd')
end

g.test_signature_separator_keeps_its_trailing_space = function()
    -- Разделитель подписи — «-- » с пробелом (RFC 3676, 4.3): по нему
    -- программа получателя узнаёт подпись, а пробел в конце строки
    -- обрезка съела бы.
    t.assert_equals(
        text.of('<p>Спасибо</p><p>--<br>Команда</p>'),
        'Спасибо\n\n-- \nКоманда'
    )
    t.assert_equals(text.of('<p>-- <br>Команда</p>'), '-- \nКоманда')
    t.assert_equals(text.of('<p>---<br>x</p>'), '---\nx')
end

g.test_less_than_sign_that_starts_no_tag_stays_text = function()
    t.assert_equals(text.of('a < b и 3<4'), 'a < b и 3<4')
end

g.test_line_breaks_are_kept_and_empty_lines_do_not_pile_up = function()
    -- `br` — перевод строки, который пишет автор: два подряд — пустая
    -- строка, а больше одной пустой строки подряд не бывает.
    t.assert_equals(text.of('a<br><br>b<br><br><br><br>c'), 'a\n\nb\n\nc')
    t.assert_equals(text.of('<div>a<br></div><div>b</div>'), 'a\nb')
    t.assert_equals(text.of('<p>a</p><div><p>b</p></div>'), 'a\n\nb')
end

g.test_declarations_fall_out_and_a_greater_sign_is_text = function()
    t.assert_equals(text.of('a<!>b<?>c'), 'abc')
    t.assert_equals(text.of('<!x>a>b'), 'a>b')
    t.assert_equals(text.of('<b>a>b</b>'), 'a>b')
end

g.test_text_after_preformatted_block_collapses_again = function()
    t.assert_equals(text.of('<pre>a  b</pre>c   d'), 'a  b\n\nc d')
    -- Вложенный `pre` закрывается по одному: после внутреннего текст
    -- ещё внутри внешнего.
    t.assert_equals(text.of('<pre>x<pre>y</pre>  z  </pre>e   f'), 'x\n\ny\n\n  z  \n\ne f')
end

g.test_top_list_is_a_paragraph_and_nested_one_is_lines_of_its_item = function()
    t.assert_equals(text.of('до<ul><li>a</li></ul>после'), 'до\n\n- a\n\nпосле')
    t.assert_equals(text.of('<ul><li>a<ol><li>b</li></ol></li><li>c</li></ul>'), '- a\n  1. b\n- c')
end

g.test_empty_address_in_apostrophes_gives_no_address = function()
    t.assert_equals(text.of("<a href=''>текст</a>"), 'текст')
end

g.test_link_whose_text_is_its_address_after_other_text = function()
    t.assert_equals(text.of('<p>См. <a href="https://x.org">https://x.org</a></p>'), 'См. https://x.org')
end

g.test_two_author_breaks_next_to_a_line_make_an_empty_line = function()
    t.assert_equals(text.of('<div>a<br><br></div><div>b</div>'), 'a\n\nb')
    t.assert_equals(text.of('<div>a<br><br><br></div><div>b</div>'), 'a\n\nb')
end

g.test_decimal_number_is_read_only_in_digits = function()
    -- `1e5` — не номер знака: без основания `tonumber` прочёл бы его
    -- числом с порядком.
    t.assert_equals(text.of('&#1e5;&#x;'), '&#1e5;&#x;')
end
