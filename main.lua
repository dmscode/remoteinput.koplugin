local ButtonDialog    = require("ui/widget/buttondialog")
local InputDialog     = require("ui/widget/inputdialog")
local InputText       = require("ui/widget/inputtext")
local ButtonTable     = require("ui/widget/buttontable")
local Device          = require("device")
local InfoMessage     = require("ui/widget/infomessage")
local QRWidget        = require("ui/widget/qrwidget")
local SimpleTCPServer = require("ui/message/simpletcpserver")
local SecureTCPServer = require("securetcpserver")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local UIManager       = require("ui/uimanager")
local Event           = require("ui/event")
local VerticalGroup   = require("ui/widget/verticalgroup")
local NetworkMgr      = require("ui/network/manager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Size            = require("ui/size")
local socket          = require("socket")
local logger          = require("logger")
local _               = require("gettext")
local T               = require("ffi/util").template
local joinPath        = require("ffi/util").joinPath
local Font            = require("ui/font")
local util            = require("util")

local current_plugin_dir = string.match(debug.getinfo(1).source, "^@(.*/)")
local cert_path = joinPath(current_plugin_dir, "cert.pem")
local key_path = joinPath(current_plugin_dir, "key.pem")

local function get_local_ip()
  local udp = assert(socket.udp())
  udp:setpeername("8.8.8.8", 53)
  local ip, port = udp:getsockname()
  udp:close()
  return ip, port
end

local function generateCerts(callback)
  local certgen_path = joinPath(current_plugin_dir, "bin/certgen")
  if util.pathExists(certgen_path) then
    local cmd = string.format("cd %s && ./%s", current_plugin_dir, "bin/certgen")
    logger.dbg("RemoteInput: Running command: " .. cmd)
    local msg = InfoMessage:new {
      text = _("Generating TLS certificates"),
      dismissable = false,
    }
    UIManager:show(msg)
    UIManager:nextTick(function ()
      os.execute(cmd)
      UIManager:close(msg)
      callback()
    end)
  else
    UIManager:show(InfoMessage:new {
      text = T(_("Error: TLS certificate generator binary (%1) not found."), certgen_path),
    })
  end
end

local function ensureCerts(callback)
  if not (util.pathExists(cert_path) and util.pathExists(key_path)) then
    generateCerts(function()
      callback()
    end)
  else
    callback()
  end
end

-- ==================== JSON 编码器 ====================
-- 为 API 响应提供轻量 JSON 编码，无需外部依赖
local function jsonEncode(val)
  if type(val) == "string" then
    return '"' .. val:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t') .. '"'
  elseif type(val) == "number" then
    return tostring(val)
  elseif type(val) == "boolean" then
    return val and "true" or "false"
  elseif type(val) == "table" then
    local parts = {}
    for k, v in pairs(val) do
      table.insert(parts, jsonEncode(k) .. ':' .. jsonEncode(v))
    end
    return '{' .. table.concat(parts, ',') .. '}'
  end
  return 'null'
end

-- ==================== HTTP 工具 ====================
local function readRequestBody(client, headers)
  local content_length = tonumber(headers:lower():match("content%-length: (%d+)"))
  if not content_length then
    return nil, "Content-Length missing"
  end
  local body, err = client:receive(content_length)
  return body, err
end

local function sendJsonResponse(client, data, status)
  status = status or 200
  local body = jsonEncode(data)
  local resp = "HTTP/1.0 " .. tostring(status) .. " OK\r\nContent-Type: application/json\r\nContent-Length: " .. tostring(#body) .. "\r\nAccess-Control-Allow-Origin: *\r\n\r\n" .. body
  client:send(resp)
  client:close()
end

local function sendHtmlResponse(client, html, status)
  status = status or 200
  local resp = "HTTP/1.0 " .. tostring(status) .. " OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: " .. tostring(#html) .. "\r\n\r\n" .. html
  client:send(resp)
  client:close()
end

local function sendEmptyResponse(client, status)
  status = status or 200
  client:send(string.format("HTTP/1.0 %d OK\r\nContent-Length: 0\r\n\r\n", status))
  client:close()
end

-- ==================== 主体插件 ====================
local RemoteInput = WidgetContainer:extend {
  name = "remoteinput",
  is_doc_only = false,
}

function RemoteInput:init()
  self.port = G_reader_settings:readSetting("remoteinput_port") or 8089
  self.https_enabled = G_reader_settings:isTrue("remoteinput_https_enabled")
  self.render_inline_button = G_reader_settings:isTrue("remoteinput_render_inline_button")
  self.inject_remote_input = G_reader_settings:readSetting("remoteinput_inject_remote_input") ~= false
  self.dialog_font_face = Font:getFace("infofont")
  -- 持久会话状态
  self.context_version = 0
  self.session_active = false
  self.last_known_remote_text = ""
  self.server_dirty = false
  self.ui.menu:registerToMainMenu(self)
  if self.ui.highlight then
    self.ui.highlight:addToHighlightDialog("20_remoteinput", function(highlight_manager, index)
      return {
        text = _("Remote Input"),
        callback = function()
          local is_new_note = false
          if not index then
            index = highlight_manager:saveHighlight(true)
            is_new_note = true
          end
          local connect_callback = function()
            highlight_manager:onClose()
            if index then
              self:openRemoteSession("annotation", { highlight_index = index, is_new_note = is_new_note })
            end
          end
          NetworkMgr:runWhenConnected(connect_callback)
        end,
      }
    end)
    -- 注入 Remote Input 按钮到编辑笔记弹窗
    if self.ui.highlight.showHighlightNoteOrDialog then
      local old_showHighlightNoteOrDialog = self.ui.highlight.showHighlightNoteOrDialog
      self.ui.highlight.showHighlightNoteOrDialog = function(highlight_obj, index)
        local old_uiManagerShow = UIManager.show
        UIManager.show = function(uimgr, widget, ...)
          if widget.title == _("Note") then
            self:injectRemoteInputButton(widget, index)
          end
          return old_uiManagerShow(uimgr, widget, ...)
        end
        local ok, res = pcall(old_showHighlightNoteOrDialog, highlight_obj, index)
        UIManager.show = old_uiManagerShow
        if not ok then error(res) end
        return res
      end
    end
  end

  if InputDialog.init and not InputDialog._remoteinput_hooked then
    local old_init = InputDialog.init
    InputDialog.init = function(dialog, ...)
      if not self.inject_remote_input or dialog.inputtext_class ~= InputText then
        return old_init(dialog, ...)
      end
      local remote_input_button_table = {
        text = _("Remote input"),
        id = "remote_input",
        keep_menu_open = true,
        callback = function()
          local connect_callback = function()
            self:openRemoteSession("input", { input_dialog = dialog })
          end
          NetworkMgr:runWhenConnected(connect_callback)
        end,
      }
      if self.render_inline_button then
        local already_added = false
        if dialog.buttons then
          for _, row in ipairs(dialog.buttons) do
            for _, btn in ipairs(row) do
              if btn.id == "remote_input" then
                already_added = true
                break
              end
            end
          end
        else
          dialog.buttons = {{}}
        end
        if not already_added then
          if not dialog.buttons[1] then dialog.buttons[1] = {} end
          table.insert(dialog.buttons[1], 1, remote_input_button_table)
        end
        return old_init(dialog, ...)
      else
        local ret = old_init(dialog, ...)
        dialog.init = old_init
        if not dialog._remoteInputWidgetAdded then
          dialog._remoteInputWidgetAdded = true
          local btn_table = ButtonTable:new{
            id = "remote_input_table",
            width = dialog.width - 2*(dialog.button_padding or Size.padding.default),
            buttons = { { remote_input_button_table } },
            zero_sep = true,
            show_parent = dialog,
          }
          dialog:addWidget(btn_table)
        end
        return ret
      end
    end
    InputDialog._remoteinput_hooked = true
  end
end

-- ==================== 服务器生命周期 ====================
function RemoteInput:CloseServer()
  if self.server then
    logger.info("RemoteInput: Closing server")
    if Device:isKindle() then
      os.execute(string.format("%s %s %s",
        "iptables -D INPUT -p tcp --dport", self.port,
        "-m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT"))
      os.execute(string.format("%s %s %s",
        "iptables -D OUTPUT -p tcp --sport", self.port,
        "-m conntrack --ctstate ESTABLISHED -j ACCEPT"))
    end
    UIManager:removeZMQ(self.server)
    self.server:stop()
    self.server = nil
  end
  self.session_active = false
end

function RemoteInput:startServer(callback)
  if self.https_enabled then
    ensureCerts(function()
      self.server = SecureTCPServer:new {
        host = "*",
        port = self.port,
        ssl_params = {
          mode = "server",
          protocol = "any",
          key = key_path,
          certificate = cert_path,
          options = { "all", "no_sslv2", "no_sslv3" },
        },
        receiveCallback = function(data, client, client_ip, client_port)
          return self:handleRequest(data, client, client_ip)
        end,
      }
      callback()
    end)
  else
    self.server = SimpleTCPServer:new {
      host = "*",
      port = self.port,
      receiveCallback = function(data, client)
        local client_ip, _ = client:getpeername()
        return self:handleRequest(data, client, client_ip)
      end,
    }
    callback()
  end
end

-- ==================== 上下文管理 ====================
function RemoteInput:getCurrentText()
  if self.context_type == "annotation" then
    local annotation = self.ui.annotation.annotations[self.context_data.highlight_index]
    if annotation and annotation.note then
      return annotation.note
    end
    return ""
  elseif self.context_type == "input" then
    if self.context_data.input_dialog and self.context_data.input_dialog.getInputText then
      return self.context_data.input_dialog:getInputText() or ""
    end
    return ""
  end
  return ""
end

function RemoteInput:applyRemoteText(text)
  if self.context_type == "annotation" then
    UIManager:nextTick(function()
      local annotation = self.ui.annotation.annotations[self.context_data.highlight_index]
      if annotation then
        local old_note = annotation.note
        if old_note ~= text then
          annotation.note = text
          if self.ui.highlight.writePdfAnnotation then
            self.ui.highlight:writePdfAnnotation("content", annotation, text)
          end
          local type_before = self.ui.bookmark.getBookmarkType(annotation)
          if type_before == "highlight" then
            self.ui:handleEvent(Event:new("AnnotationsModified",
              { annotation, nb_highlights_added = -1, nb_notes_added = 1 }))
          else
            self.ui:handleEvent(Event:new("AnnotationsModified",
              { annotation, nb_highlights_added = 0, nb_notes_added = 0 }))
          end
        end
      end
    end)
  elseif self.context_type == "input" then
    UIManager:nextTick(function()
      if self.context_data.input_dialog and self.context_data.input_dialog.setInputText then
        if not self.context_data.input_dialog.readonly then
          self.context_data.input_dialog:setInputText(text, true)
        end
      end
    end)
  end
  self.last_known_remote_text = text
  self.server_dirty = false
  self.context_version = self.context_version + 1
end

function RemoteInput:getContextInfo()
  local heading = ""
  local input_type = "textarea"
  if self.context_type == "annotation" then
    heading = "Add Note"
  elseif self.context_type == "input" then
    heading = "Input Text"
    if self.context_data.input_dialog and not self.context_data.input_dialog.allow_newline then
      input_type = "input"
    end
  end
  -- 检测 KOReader 本地编辑：如果当前文本与上次同步文本不同，标记 server_dirty
  local current = self:getCurrentText()
  if current ~= self.last_known_remote_text then
    self.server_dirty = true
  end
  return {
    heading = heading,
    input_type = input_type,
    context_type = self.context_type,
    version = self.context_version,
    dirty = self.server_dirty,
  }
end

-- ==================== 清理逻辑 ====================
function RemoteInput:cleanupSession()
  self:CloseServer()
  if self.context_type == "annotation" and self.context_data.is_new_note and self.context_data.highlight_index then
    logger.info("RemoteInput: Removing cancelled highlight")
    self.ui.highlight:deleteHighlight(self.context_data.highlight_index)
  end
  if self.dialog then
    UIManager:close(self.dialog)
    self.dialog = nil
  end
end

-- ==================== 打开/切换远程会话 ====================
function RemoteInput:openRemoteSession(context_type, context_data)
  self.context_type = context_type
  self.context_data = context_data

  if context_type == "input" and context_data.input_dialog and context_data.input_dialog.onCloseKeyboard then
    context_data.input_dialog:onCloseKeyboard()
  end

  -- 如果服务器已经在运行，只需切换上下文
  if self.session_active and self.server then
    self.context_version = self.context_version + 1
    self.last_known_remote_text = self:getCurrentText()
    self.server_dirty = false
    -- 如果当前弹窗还在，更新它
    if self.dialog then
      UIManager:close(self.dialog)
    end
    self:showPersistentDialog()
    return
  end

  -- 首次启动：关闭旧服务器（如果有残留），启动新服务器
  self:CloseServer()

  local ip = get_local_ip()
  if not ip or ip == "" then
    UIManager:show(InfoMessage:new {
      text = _("Could not determine local IP address."),
    })
    return
  end

  if Device:isKindle() then
    os.execute(string.format("%s %s %s",
      "iptables -A INPUT -p tcp --dport", self.port,
      "-m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT"))
    os.execute(string.format("%s %s %s",
      "iptables -A OUTPUT -p tcp --sport", self.port,
      "-m conntrack --ctstate ESTABLISHED -j ACCEPT"))
  end

  self.context_version = 0
  self.last_known_remote_text = ""
  self.server_dirty = false

  self:startServer(function()
    UIManager:insertZMQ(self.server)
    local ok_server, err = self.server:start()
    if not ok_server then
      self.server = nil
      UIManager:show(InfoMessage:new {
        text = T(_("Failed to start server: %1"), err),
      })
      return
    end

    self.session_active = true

    local protocol = self.https_enabled and "https" or "http"
    local server_url = string.format("%s://%s:%d/", protocol, ip, self.port)
    local qr_size = Device.screen:scaleBySize(350)

    local ok_ui, dialog_or_err = pcall(function()
      local dialog = ButtonDialog:new {
        dismissable = false,
        buttons = { {
          {
            text = _("Hide"),
            callback = function()
              UIManager:close(self.dialog)
              self.dialog = nil
            end,
          },
          {
            text = _("Stop"),
            callback = function()
              self:cleanupSession()
            end,
          },
        } },
        tap_close_callback = function()
          UIManager:close(self.dialog)
          self.dialog = nil
        end
      }
      local available_width = dialog:getAddedWidgetAvailableWidth()
      local description_widget = TextBoxWidget:new {
        text = _("On another device, connect to the same network as your reader and open the link below:"),
        face = self.dialog_font_face,
        alignment = "left",
        width = available_width,
      }
      local qr_code = FrameContainer:new {
        padding = Size.padding.large,
        bordersize = 0,
        QRWidget:new {
          text = server_url,
          width = qr_size,
          height = qr_size,
        }
      }
      local url_widget = TextBoxWidget:new {
        text = server_url,
        face = self.dialog_font_face,
        alignment = "center",
        width = available_width,
      }
      local content = VerticalGroup:new {
        align = "center",
        description_widget,
        qr_code,
        url_widget,
      }
      dialog:addWidget(content)
      return dialog
    end)

    if not ok_ui then
      logger.err("RemoteInput: Error creating UI:", dialog_or_err)
      self:cleanupSession()
      UIManager:show(InfoMessage:new {
        text = T(_("Error starting RemoteInput: %1"), dialog_or_err),
      })
      return
    end

    self.dialog = dialog_or_err
    UIManager:show(self.dialog)
  end)
end

-- 持久会话弹窗（上下文切换时使用）
function RemoteInput:showPersistentDialog()
  local dialog = ButtonDialog:new {
    dismissable = false,
    buttons = { {
      {
        text = _("Hide"),
        callback = function()
          UIManager:close(self.dialog)
          self.dialog = nil
        end,
      },
      {
        text = _("Stop"),
        callback = function()
          self:cleanupSession()
        end,
      },
    } },
    tap_close_callback = function()
      UIManager:close(self.dialog)
      self.dialog = nil
    end
  }
  local available_width = dialog:getAddedWidgetAvailableWidth()
  local info = self:getContextInfo()
  local text_content = T(_("Session active. Editing: %1\nSwitch to another input to edit it without reconnecting."), info.heading)
  local text_widget = TextBoxWidget:new {
    text = text_content,
    face = self.dialog_font_face,
    alignment = "center",
    width = available_width,
  }
  dialog:addWidget(text_widget)
  self.dialog = dialog
  UIManager:show(self.dialog)
end

-- ==================== HTTP 请求处理 ====================
function RemoteInput:handleRequest(data, client, client_ip)
  local method, uri = data:match("^(%u+) ([^\n]*) HTTP/%d%.%d\r?\n.*")
  if not method or not uri then
    sendEmptyResponse(client, 400)
    return
  end

  -- 剥离查询参数
  local path = uri:match("^([^?]*)") or uri

  if method == "GET" and (path == "/" or path == "" or path == "/index.html") then
    -- 首页：返回交互式 Web 页面
    local info = self:getContextInfo()
    local current_text = util.htmlEscape(self:getCurrentText())
    local html = self:buildWebPage(info, current_text)
    sendHtmlResponse(client, html)

  elseif method == "GET" and path == "/api/state" then
    -- 获取当前状态（供前端轮询）
    local info = self:getContextInfo()
    local state = {
      text = self:getCurrentText(),
      heading = info.heading,
      input_type = info.input_type,
      context_type = info.context_type,
      version = info.version,
      server_active = self.session_active,
    }
    sendJsonResponse(client, state)

  elseif method == "POST" and path == "/api/text" then
    -- 实时文本同步（远程 → KOReader）
    local body, err = readRequestBody(client, data)
    if not body then
      logger.err("RemoteInput: Failed to read body:", err)
      sendEmptyResponse(client, 400)
      return
    end
    -- 支持 JSON 格式: {"text":"..."}
    local text
    if body:sub(1, 9) == '{"text":"' and body:sub(-2) == '"}' then
      text = body:sub(10, -3)
      text = text:gsub('\\"', '"'):gsub('\\n', '\n'):gsub('\\r', '\r'):gsub('\\t', '\t'):gsub('\\\\', '\\')
    end
    -- 支持 form-encoded: text=...
    if not text then
      text = body:match("^text=(.+)")
      if text then
        text = text:gsub("%+", " "):gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
      end
    end
    -- 兜底：纯文本 body
    if not text then
      text = body
    end
    if text and text ~= "" then
      self:applyRemoteText(text)
      sendJsonResponse(client, { ok = true, version = self.context_version, dirty = false })
    else
      sendJsonResponse(client, { ok = false, error = "empty text" }, 400)
    end

  elseif method == "POST" and path == "/api/submit" then
    -- 手动提交（用于 annotation 场景的最终保存确认）
    local info = self:getContextInfo()
    UIManager:show(InfoMessage:new {
      text = _("Remote note saved!"),
    })
    if self.dialog then
      UIManager:close(self.dialog)
      self.dialog = nil
    end
    self:CloseServer()
    sendJsonResponse(client, { ok = true, closed = true })

  else
    -- 未匹配的路由
    sendEmptyResponse(client, 404)
  end
end

-- ==================== Web 前端页面 ====================
function RemoteInput:buildWebPage(info, initial_text)
  local heading = info.heading
  local input_type = info.input_type
  local context_type = info.context_type
  local version = info.version

  local input_html
  if input_type == "input" then
    input_html = '<input type="text" id="editor" value="' .. initial_text .. '" placeholder="Type here..." style="width:100%; height:50px; font-size:18px; box-sizing:border-box; padding:8px;">'
  else
    input_html = '<textarea id="editor" style="width:100%; height:240px; font-size:16px; box-sizing:border-box; padding:8px; resize:vertical;">' .. initial_text .. '</textarea>'
  end

  local submit_button = ""
  if context_type == "annotation" then
    submit_button = '<button id="submitBtn" style="width:100%; height:44px; margin-top:12px; font-size:16px; background:#4a90d9; color:#fff; border:none; border-radius:6px;">Save &amp; Close</button>'
  end

  return [[<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
<title>RemoteInput</title>
<style>
*{margin:0;padding:0;box-sizing:border-box;}
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;background:#f5f5f5;color:#333;padding:16px;min-height:100vh;}
.container{max-width:600px;margin:0 auto;}
.header{display:flex;align-items:center;justify-content:space-between;margin-bottom:12px;}
.header h2{font-size:20px;font-weight:600;}
.status{font-size:13px;padding:4px 10px;border-radius:12px;font-weight:500;}
.status.connected{background:#d4edda;color:#155724;}
.status.disconnected{background:#f8d7da;color:#721c24;}
.status.syncing{background:#fff3cd;color:#856404;}
#editor{display:block;border:1px solid #ddd;border-radius:8px;outline:none;transition:border-color .2s;}
#editor:focus{border-color:#4a90d9;box-shadow:0 0 0 3px rgba(74,144,217,.15);}
.hint{font-size:12px;color:#999;margin-top:6px;text-align:center;}
</style>
</head>
<body>
<div class="container">
  <div class="header">
    <h2 id="heading">]] .. heading .. [[</h2>
    <span class="status connected" id="status">&#9679; Connected</span>
  </div>
  ]] .. input_html .. [[
  <div class="hint" id="hint">Text syncs automatically as you type</div>
  ]] .. submit_button .. [[
</div>

<script>
// ==================== 双向状态机 ====================
// 规则：谁在打字谁说了算——isDirty=true 的一方拥有编辑权，
// 另一端绝不覆盖。isDirty=false 表示空闲，乐意接受远端更新。
(function(){
  var lastVersion = ]] .. tostring(version) .. [[;
  var lastSyncedText = ]] .. jsonEncode(initial_text) .. [[;
  var editor = document.getElementById('editor');
  var heading = document.getElementById('heading');
  var statusEl = document.getElementById('status');
  var hintEl = document.getElementById('hint');
  var submitBtn = document.getElementById('submitBtn');
  var isDirty = false;
  var dirtyTimer = null;
  var syncTimer = null;
  var pollTimer = null;
  var failCount = 0;
  var currentInputType = ']] .. input_type .. [[';

  function setDirty(v) {
    isDirty = v;
    if (v) {
      // 安全网：10 秒后强制释放 dirty，防止网络失败导致的永久锁死
      if (dirtyTimer) clearTimeout(dirtyTimer);
      dirtyTimer = setTimeout(function() {
        isDirty = false;
      }, 10000);
    } else {
      if (dirtyTimer) clearTimeout(dirtyTimer);
    }
  }

  function setStatus(type, text) {
    statusEl.textContent = text;
    statusEl.className = 'status ' + type;
  }

  function debouncedSync() {
    if (syncTimer) clearTimeout(syncTimer);
    syncTimer = setTimeout(doSync, 250);
  }

  function doSync() {
    var text = editor.value;
    if (text === lastSyncedText) return;
    setStatus('syncing', '↻ Syncing...');
    fetch('/api/text', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({text: text})
    }).then(function(r){ return r.json(); })
      .then(function(data){
        if (data.ok) {
          lastSyncedText = text;
          lastVersion = data.version;
          setDirty(false);
          setStatus('connected', '● Connected');
          failCount = 0;
        }
      }).catch(function(){
        failCount++;
        setStatus('disconnected', '● Offline');
        if (failCount < 5) setTimeout(doSync, 2000);
      });
  }

  function pollState() {
    fetch('/api/state')
      .then(function(r){ return r.json(); })
      .then(function(state){
        failCount = 0;
        var serverDown = state.server_active === false;
        if (serverDown) {
          setStatus('disconnected', '● Session ended');
          editor.disabled = true;
          if (hintEl) hintEl.textContent = 'Session has ended. You can close this page.';
          if (pollTimer) clearInterval(pollTimer);
          return;
        }
        setStatus('connected', '● Connected');
        // 上下文切换（用户主动切换输入对象）：无条件接受
        if (state.version !== lastVersion) {
          lastVersion = state.version;
          heading.textContent = state.heading;
          if (state.input_type !== currentInputType) {
            currentInputType = state.input_type;
            var newEl;
            if (state.input_type === 'input') {
              newEl = document.createElement('input');
              newEl.type = 'text';
              newEl.style.cssText = 'width:100%;height:50px;font-size:18px;box-sizing:border-box;padding:8px;display:block;border:1px solid #ddd;border-radius:8px;outline:none;transition:border-color .2s;';
              editor.parentNode.insertBefore(newEl, editor);
              editor.parentNode.removeChild(editor);
              editor = newEl;
              editor.id = 'editor';
            } else {
              newEl = document.createElement('textarea');
              newEl.style.cssText = 'width:100%;height:240px;font-size:16px;box-sizing:border-box;padding:8px;resize:vertical;display:block;border:1px solid #ddd;border-radius:8px;outline:none;transition:border-color .2s;';
              editor.parentNode.insertBefore(newEl, editor);
              editor.parentNode.removeChild(editor);
              editor = newEl;
              editor.id = 'editor';
            }
            bindEditorEvents();
          }
          setDirty(false);
          editor.value = state.text;
          lastSyncedText = state.text;
          if (hintEl) hintEl.textContent = 'Switched to: ' + state.heading;
          setTimeout(function(){ if (hintEl) hintEl.textContent = 'Text syncs automatically as you type'; }, 2000);
        } else if (!isDirty && state.dirty && state.text !== editor.value) {
          // 同一上下文：KOReader 侧有本地编辑，且 web 空闲 → 接受
          editor.value = state.text;
          lastSyncedText = state.text;
        }
      }).catch(function(){
        failCount++;
        if (failCount >= 3) setStatus('disconnected', '● Offline');
      });
  }

  function bindEditorEvents() {
    editor.addEventListener('input', function() {
      setDirty(true);
      debouncedSync();
    });
    editor.addEventListener('focus', function() {
      setDirty(true);
    });
    editor.addEventListener('blur', function() {
      setDirty(false);
      doSync();
    });
  }

  bindEditorEvents();

  if (submitBtn) {
    submitBtn.addEventListener('click', function() {
      fetch('/api/submit', {method: 'POST'})
        .then(function(r){ return r.json(); })
        .then(function(data){
          if (data.closed) {
            setStatus('disconnected', '● Saved');
            editor.disabled = true;
            submitBtn.disabled = true;
            submitBtn.textContent = 'Saved ✓';
            if (hintEl) hintEl.textContent = 'Note saved. You can close this page.';
            if (pollTimer) clearInterval(pollTimer);
          }
        });
    });
  }

  pollTimer = setInterval(pollState, 600);
  pollState();
})();
</script>
</body>
</html>]]
end

-- ==================== 注入远程编辑按钮 ====================
function RemoteInput:injectRemoteInputButton(widget, index, is_new_note)
  local buttons_table = widget.buttons or widget.buttons_table
  if not buttons_table then return end
  local remote_button_def = {
    {
      text = _("Remote edit note"),
      callback = function()
        UIManager:close(widget)
        self:openRemoteSession("annotation", { highlight_index = index, is_new_note = is_new_note })
      end,
    }
  }
  local function add_button()
    for key, row in ipairs(buttons_table) do
      for key2, btn in ipairs(row) do
        if btn.text == _("Remote edit note") then return end
      end
    end
    table.insert(buttons_table, remote_button_def)
  end
  add_button()
  if widget._backupRestoreButtons and not widget._remoteinput_hooked then
    local old_backupRestoreButtons = widget._backupRestoreButtons
    widget._backupRestoreButtons = function(w)
      old_backupRestoreButtons(w)
      buttons_table = w.buttons or w.buttons_table
      add_button()
    end
    widget._remoteinput_hooked = true
  end
  if widget.onShowKeyboard then widget:onShowKeyboard(false) end
  if widget.reinit then widget:reinit() end
end

-- ==================== 设置菜单 ====================
function RemoteInput:show_port_dialog(touchmenu_instance)
  local port_dialog
  port_dialog = InputDialog:new {
    title = _("Remote Input Port"),
    input = tostring(self.port),
    input_type = "number",
    buttons = {
      {
        {
          text = _("Cancel"),
          id = "close",
          callback = function()
            UIManager:close(port_dialog)
          end,
        },
        {
          text = _("Save"),
          is_enter_default = true,
          callback = function()
            local value = tonumber(port_dialog:getInputText())
            if value and value > 0 and value < 65536 then
              self.port = value
              G_reader_settings:saveSetting("remoteinput_port", self.port)
              UIManager:close(port_dialog)
              if touchmenu_instance then touchmenu_instance:updateItems() end
            else
              UIManager:show(InfoMessage:new {
                text = _("Invalid port number"),
              })
            end
          end,
        },
      },
    },
  }
  UIManager:show(port_dialog)
  port_dialog:onShowKeyboard()
end

function RemoteInput:addToMainMenu(menu_items)
  menu_items.remoteinput = {
    text = _("Remote Input"),
    sorting_hint = "tools",
    sub_item_table = {
      {
        text_func = function()
          return T(_("Port: %1"), self.port)
        end,
        keep_menu_open = true,
        callback = function(touchmenu_instance)
          self:show_port_dialog(touchmenu_instance)
        end,
        separator = true,
      },
      {
        text = _("Enable HTTPS"),
        checked_func = function()
          return self.https_enabled
        end,
        callback = function(touchmenu_instance)
          self.https_enabled = not self.https_enabled
          G_reader_settings:saveSetting("remoteinput_https_enabled", self.https_enabled)
          if touchmenu_instance then touchmenu_instance:updateItems() end
          if self.https_enabled then
            ensureCerts(function() end)
          end
        end,
      },
      {
        text = _("Refresh TLS certificates"),
        enabled_func = function()
          return self.https_enabled
        end,
        callback = function()
          os.remove(cert_path)
          os.remove(key_path)
          generateCerts(function()
            UIManager:show(InfoMessage:new {
              text = _("TLS certificates refreshed successfully."),
            })
          end)
        end,
        separator = true,
      },
      {
        text = _("Allow remote input in all text input dialogs"),
        checked_func = function()
          return self.inject_remote_input
        end,
        callback = function(touchmenu_instance)
          self.inject_remote_input = not self.inject_remote_input
          G_reader_settings:saveSetting("remoteinput_inject_remote_input", self.inject_remote_input)
          if touchmenu_instance then touchmenu_instance:updateItems() end
          UIManager:show(InfoMessage:new {
            text = _("Restart KOReader for changes to take effect."),
          })
        end,
      },
      {
        text = _("Render inline 'Remote input' button"),
        enabled_func = function ()
          return self.inject_remote_input
        end,
        checked_func = function()
          return self.render_inline_button
        end,
        callback = function(touchmenu_instance)
          self.render_inline_button = not self.render_inline_button
          G_reader_settings:saveSetting("remoteinput_render_inline_button", self.render_inline_button)
          if touchmenu_instance then touchmenu_instance:updateItems() end
        end,
      },
    }
  }
end

return RemoteInput
