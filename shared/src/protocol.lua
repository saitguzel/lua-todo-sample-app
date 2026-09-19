-- API protokol sözleşmesi: error kodları, HTTP status eşlemesi, yanıt zarfı yardımcıları.
local _M = {}

_M.API_PREFIX = "/api/v1"

-- 00-genel-bakis §5 ile birebir; yeni kod eklemek o dokümanın güncellenmesini gerektirir
_M.ERR = {
  VALIDATION_FAILED = "VALIDATION_FAILED",
  BAD_REQUEST = "BAD_REQUEST",
  UNAUTHORIZED = "UNAUTHORIZED",
  TOKEN_EXPIRED = "TOKEN_EXPIRED",
  TOKEN_REVOKED = "TOKEN_REVOKED",
  INVALID_CREDENTIALS = "INVALID_CREDENTIALS",
  ACCOUNT_DISABLED = "ACCOUNT_DISABLED",
  FORBIDDEN = "FORBIDDEN",
  NOT_FOUND = "NOT_FOUND",
  TODO_NOT_FOUND = "TODO_NOT_FOUND",
  USER_NOT_FOUND = "USER_NOT_FOUND",
  EMAIL_TAKEN = "EMAIL_TAKEN",
  CONFLICT = "CONFLICT",
  LAST_ADMIN = "LAST_ADMIN",
  SELF_ACTION_FORBIDDEN = "SELF_ACTION_FORBIDDEN",
  RESET_TOKEN_INVALID = "RESET_TOKEN_INVALID",
  RATE_LIMITED = "RATE_LIMITED",
  PAYLOAD_TOO_LARGE = "PAYLOAD_TOO_LARGE",
  INTERNAL_ERROR = "INTERNAL_ERROR",
  MAIL_FAILED = "MAIL_FAILED",
  DB_UNAVAILABLE = "DB_UNAVAILABLE",
}

_M.HTTP_STATUS = {
  VALIDATION_FAILED = 422, BAD_REQUEST = 400,
  UNAUTHORIZED = 401, TOKEN_EXPIRED = 401, TOKEN_REVOKED = 401, INVALID_CREDENTIALS = 401,
  ACCOUNT_DISABLED = 403, FORBIDDEN = 403,
  NOT_FOUND = 404, TODO_NOT_FOUND = 404, USER_NOT_FOUND = 404,
  EMAIL_TAKEN = 409, CONFLICT = 409, LAST_ADMIN = 409, SELF_ACTION_FORBIDDEN = 409,
  RESET_TOKEN_INVALID = 400, RATE_LIMITED = 429, PAYLOAD_TOO_LARGE = 413,
  INTERNAL_ERROR = 500, MAIL_FAILED = 502, DB_UNAVAILABLE = 503,
}

-- Sıralı kod listesi (00 §5 tablo sırası); OpenAPI Error.code enum'u ve spec testleri için
_M.CODE_LIST = {
  "VALIDATION_FAILED", "BAD_REQUEST",
  "UNAUTHORIZED", "TOKEN_EXPIRED", "TOKEN_REVOKED", "INVALID_CREDENTIALS",
  "ACCOUNT_DISABLED", "FORBIDDEN",
  "NOT_FOUND", "TODO_NOT_FOUND", "USER_NOT_FOUND",
  "EMAIL_TAKEN", "CONFLICT", "LAST_ADMIN", "SELF_ACTION_FORBIDDEN",
  "RESET_TOKEN_INVALID", "RATE_LIMITED", "PAYLOAD_TOO_LARGE",
  "INTERNAL_ERROR", "MAIL_FAILED", "DB_UNAVAILABLE",
}

-- Varsayılan Türkçe kullanıcı mesajları
_M.DEFAULT_MESSAGES = {
  VALIDATION_FAILED = "Girdi doğrulanamadı",
  BAD_REQUEST = "Geçersiz istek",
  UNAUTHORIZED = "Kimlik doğrulama gerekli",
  TOKEN_EXPIRED = "Oturum süresi doldu",
  TOKEN_REVOKED = "Token iptal edildi",
  INVALID_CREDENTIALS = "E-posta veya parola hatalı",
  ACCOUNT_DISABLED = "Hesabınız pasif durumda",
  FORBIDDEN = "Bu işlem için yetkiniz yok",
  NOT_FOUND = "Kaynak bulunamadı",
  TODO_NOT_FOUND = "Todo bulunamadı",
  USER_NOT_FOUND = "Kullanıcı bulunamadı",
  EMAIL_TAKEN = "Bu e-posta zaten kullanılıyor",
  CONFLICT = "Çakışma oluştu",
  LAST_ADMIN = "Sistemdeki son aktif admin değiştirilemez",
  SELF_ACTION_FORBIDDEN = "Kendi hesabınız üzerinde bu işlem yapılamaz",
  RESET_TOKEN_INVALID = "Geçersiz veya süresi dolmuş sıfırlama bağlantısı",
  RATE_LIMITED = "Çok fazla deneme, lütfen bekleyin",
  PAYLOAD_TOO_LARGE = "İstek gövdesi çok büyük",
  INTERNAL_ERROR = "Beklenmeyen bir hata oluştu",
  MAIL_FAILED = "E-posta gönderilemedi",
  DB_UNAVAILABLE = "Veritabanına ulaşılamıyor",
}

-- Bilinmeyen kod 500'e düşer (fail-safe)
function _M.http_status(code)
  return _M.HTTP_STATUS[code] or 500
end

-- Kod → Türkçe mesaj; bilinmeyen kod → "Beklenmeyen bir hata oluştu"
function _M.message(code)
  return _M.DEFAULT_MESSAGES[code] or "Beklenmeyen bir hata oluştu"
end

-- Hata nesnesi: { code, message, details }
function _M.new_error(code, message, details)
  return {
    code = code,
    message = message or _M.message(code),
    details = details,
  }
end

-- Yanıt gövdesi: { error = { code, message, details, req_id } }
function _M.error_body(err, req_id)
  return {
    error = {
      code = err.code,
      message = err.message or _M.message(err.code),
      details = err.details,
      req_id = req_id,
    }
  }
end

-- Frontend: yanıtın hata olup olmadığını ve kodunu çıkarır
function _M.parse_error(body)
  if type(body) == "table" and body.error and body.error.code then
    return body.error
  end
  return nil
end

-- Frontend: bu hata token yenilemeyi tetiklemeli mi?
function _M.is_refreshable(code)
  return code == _M.ERR.TOKEN_EXPIRED
end

return _M
