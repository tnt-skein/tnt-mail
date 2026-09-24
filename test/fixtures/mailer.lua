--- Двойник почты для писем: сухой прогон настоящий — фасад почты с его
--- настройками, — а отправка отвечает по списку и помнит отправленное.
---
--- Файлом, а не функцией помощника: его берут и проверки в процессе,
--- и узел, куда замыкание проверки не уезжает.
---@param mail table Фасад `tnt.mail`
---@return table mailer `send`, `render`, `sent` и `answers` — ответы `{ ok, err }` по очереди
return function(mail)
    local mailer = { sent = {}, answers = {} }

    function mailer.render(letter)
        return mail.render(letter)
    end

    function mailer.send(letter)
        table.insert(mailer.sent, letter)

        local answer = table.remove(mailer.answers, 1) or { true }

        return answer[1], answer[2]
    end

    return mailer
end
