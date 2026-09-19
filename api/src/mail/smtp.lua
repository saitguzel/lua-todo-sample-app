-- SMTP gonderimi: lua-resty-mail sarmalayicisi
-- Reset e-postasi sablonu icerir.
local config = require("config")

local _M = {}

function _M.send(msg)
  local ok_mail, mail = pcall(require, "resty.mail")
  if not ok_mail then
    ngx.log(ngx.ERR, "resty.mail yuklenemedi: ", mail)
    return nil, "MAIL_FAILED"
  end
  local c = config.get() and config.get().smtp or {}
  local mailer, err = mail.new({
    host = c.host or "mailhog",
    port = c.port or 1025,
    starttls = c.tls or false,
    username = (c.user and c.user ~= "") and c.user or nil,
    password = (c.password and c.password ~= "") and c.password or nil,
    timeout_connect = 5000,
    timeout_send = 5000,
    timeout_read = 5000,
  })
  if not mailer then return nil, "MAIL_FAILED: " .. tostring(err) end
  local ok, serr = mailer:send({
    from = c.from or "no-reply@todoapp.local",
    to = { msg.to },
    subject = msg.subject,
    text = msg.text,
    html = msg.html,
  })
  if not ok then return nil, "MAIL_FAILED: " .. tostring(serr) end
  return true
end

local function escape_html(s)
  if not s then return "" end
  return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

-- PASSWORD_RESET_TTL (sn) → "1 saat" / "30 dakika"
local function human_ttl(ttl)
  if ttl % 3600 == 0 then return (ttl / 3600) .. " saat" end
  return math.ceil(ttl / 60) .. " dakika"
end

function _M.render_reset_mail(full_name, link, ttl)
  local name = full_name or "Kullanici"
  local validity = human_ttl(ttl or 3600)
  local subject = "Parola Sifirlama Talebi"
  local text = string.format(
    "Merhaba %s,\n\nParola sifirlama baglantiniz:\n%s\n\nBaglanti %s gecerlidir.\n", name, link, validity
  )
  local html = string.format(
    "<p>Merhaba %s,</p><p>Parola sifirlama baglantiniz:</p><p><a href=\"%s\">%s</a></p><p>Baglanti %s gecerlidir.</p>",
    escape_html(name), escape_html(link), escape_html(link), validity
  )
  return { subject = subject, text = text, html = html }
end

return _M
