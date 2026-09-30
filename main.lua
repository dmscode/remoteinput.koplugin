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
local jsonutil        = require("jsonutil")

local current_plugin_dir = string.match(debug.getinfo(1).source, "^@(.*/)")
local cert_path = joinPath(current_plugin_dir, "cert.pem")
local key_path = joinPath(current_plugin_dir, "key.pem")

-- 单个请求体的上限，防止异常客户端把内存吃爆
local MAX_BODY_SIZE = 2 * 1024 * 1024

local STATUS_TEXT = { [200] = "OK", [400] = "Bad Request", [404] = "Not Found" }

local function get_local_ip()
  local ok, udp = pcall(socket.udp)
  if not ok or not udp then
    return nil
  end
  -- 连接一个外部地址只是为了拿到出口路由对应的本机 IP，不会真正发包
  local ok_peer = udp:setpeername("8.8.8.8", 53)
  local ip
  if ok_peer then
    ip = udp:getsockname()
  end
  udp:close()
  if not ip or ip == "" or ip == "0.0.0.0" then
    return nil
  end
  return ip
end

local function generateCerts(callback)
  local certgen_path = joinPath(current_plugin_dir, "bin/certgen")
  if not util.pathExists(certgen_path) then
    UIManager:show(InfoMessage:new {
      text = T(_("Error: TLS certificate generator binary (%1) not found."), certgen_path),
    })
    callback(false)
    return
  end
  local msg = InfoMessage:new {
    text = _("Generating TLS certificates"),
    dismissable = false,
  }
  UIManager:show(msg)
  UIManager:nextTick(function ()
    -- 路径加引号，避免含空格的安装路径导致命令失败
    local cmd = string.format("cd '%s' && ./bin/certgen", current_plugin_dir)
    logger.dbg("RemoteInput: Running command: " .. cmd)
    os.execute(cmd)
    UIManager:close(msg)
    -- 以证书文件是否生成为准，规避 os.execute 返回值的平台差异
    local success = util.pathExists(cert_path) and util.pathExists(key_path)
    if not success then
      logger.err("RemoteInput: TLS certificate generation failed")
      UIManager:show(InfoMessage:new {
        text = _("TLS certificate generation failed."),
      })
    end
    callback(success)
  end)
end

local function ensureCerts(callback)
  if util.pathExists(cert_path) and util.pathExists(key_path) then
    callback(true)
  else
    generateCerts(callback)
  end
end

-- ==================== Kindle 防火墙 ====================
local function addFirewallRules(port)
  if not Device:isKindle() or not port then return end
  -- 先用 -C 查重再 -A，避免规则重复累积
  os.execute(string.format(
    "iptables -C INPUT -p tcp --dport %d -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT 2>/dev/null || " ..
    "iptables -A INPUT -p tcp --dport %d -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT", port, port))
  os.execute(string.format(
    "iptables -C OUTPUT -p tcp --sport %d -m conntrack --ctstate ESTABLISHED -j ACCEPT 2>/dev/null || " ..
    "iptables -A OUTPUT -p tcp --sport %d -m conntrack --ctstate ESTABLISHED -j ACCEPT", port, port))
end

local function removeFirewallRules(port)
  if not Device:isKindle() or not port then return end
  os.execute(string.format(
    "iptables -D INPUT -p tcp --dport %d -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT 2>/dev/null", port))
  os.execute(string.format(
    "iptables -D OUTPUT -p tcp --sport %d -m conntrack --ctstate ESTABLISHED -j ACCEPT 2>/dev/null", port))
end

-- ==================== HTTP 工具 ====================
local function readRequestBody(client, headers)
  local content_length = tonumber(headers:lower():match("content%-length: (%d+)"))
  if not content_length then
    return nil, "Content-Length missing"
  end
  if content_length > MAX_BODY_SIZE then
    return nil, "body too large"
  end
  local body, err = client:receive(content_length)
  return body, err
end

local function httpRespond(client, status, content_type, body, extra_headers)
  status = status or 200
  local head = "HTTP/1.0 " .. tostring(status) .. " " .. (STATUS_TEXT[status] or "OK") ..
    "\r\nContent-Type: " .. content_type ..
    "\r\nContent-Length: " .. tostring(#body) ..
    (extra_headers or "") .. "\r\n\r\n" .. body
  client:send(head)
  client:close()
end

local function sendJsonResponse(client, data, status)
  httpRespond(client, status or 200, "application/json", jsonutil.encode(data),
    "\r\nAccess-Control-Allow-Origin: *")
end

local function sendHtmlResponse(client, html, status)
  httpRespond(client, status or 200, "text/html; charset=utf-8", html)
end

local function sendEmptyResponse(client, status)
  httpRespond(client, status or 200, "text/plain", "")
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
  self.auto_switch = G_reader_settings:readSetting("remoteinput_autoswitch") ~= false
  local idle_minutes = G_reader_settings:readSetting("remoteinput_idle_minutes")
  self.idle_minutes = idle_minutes == nil and 15 or idle_minutes
  self.dialog_font_face = Font:getFace("infofont")
  -- 持久会话状态
  self.session_gen = 0
  self.context_version = 0
  self.session_active = false
  self.last_known_remote_text = ""
  self.server_dirty = false
  self.last_activity = 0
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

  -- 文档关闭时结束会话：不删除任何批注，已输入的内容随文档正常保存。
  -- 没有这一步，换书/关书后旧实例会继续持有服务器，甚至把远程文本写进新书。
  if self.ui.onClose then
    local ui_onClose = self.ui.onClose
    self.ui.onClose = function(ui_self, ...)
      self:abortSession()
      return ui_onClose(ui_self, ...)
    end
  end

  if InputDialog.init and not InputDialog._remoteinput_hooked then
    local old_init = InputDialog.init
    InputDialog.init = function(dialog, ...)
      local inject = self.inject_remote_input
        and not dialog._remoteinput_skip
        and dialog.inputtext_class == InputText
      local remote_input_button_table
      if inject then
        remote_input_button_table = {
          text = _("Remote input"),
          id = "remote_input",
          keep_menu_open = true,
          callback = function()
            NetworkMgr:runWhenConnected(function()
              self:openRemoteSession("input", { input_dialog = dialog })
            end)
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
        end
      end
      -- 自动跟随：会话活跃时，任何新输入框获得键盘焦点即静默切换远程上下文。
      -- 钩子在 old_init 之前挂上（覆盖 init 期间就弹出键盘的对话框），
      -- 切换本身用 nextTick 延迟，避免在对话框构造过程中重入 UI 流程，
      -- 也给笔记弹窗留出设置 no_autoswitch 标志的机会。
      local follow = self.session_active and self.auto_switch and self.context_type
        and not dialog._remoteinput_skip
        and dialog.inputtext_class == InputText
        and not dialog._remoteinput_osk_patched
      if follow then
        local old_osk = dialog.onShowKeyboard
        dialog._remoteinput_osk_patched = true
        dialog.onShowKeyboard = function(dlg, ...)
          if old_osk then old_osk(dlg, ...) end
          UIManager:nextTick(function()
            self:autoSwitchToInputDialog(dialog)
          end)
        end
      end
      local ret = old_init(dialog, ...)
      if inject and not self.render_inline_button then
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
      end
      return ret
    end
    InputDialog._remoteinput_hooked = true
  end
end

-- ==================== 服务器生命周期 ====================
function RemoteInput:CloseServer()
  if self.server then
    logger.info("RemoteInput: Closing server")
    removeFirewallRules(self.server_port or self.port)
    UIManager:removeZMQ(self.server)
    self.server:stop()
    self.server = nil
  end
  self.session_active = false
end

function RemoteInput:startServer(callback)
  if self.https_enabled then
    ensureCerts(function(success)
      if not success then
        return
      end
      local server = SecureTCPServer:new {
        host = "*",
        port = self.server_port,
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
      -- SSL 上下文创建失败时拒绝启动，绝不静默降级为明文服务
      if not server.ssl_ctx then
        logger.err("RemoteInput: SSL context creation failed, aborting server start")
        UIManager:show(InfoMessage:new {
          text = _("Failed to initialize TLS. HTTPS is unavailable."),
        })
        return
      end
      self.server = server
      callback()
    end)
  else
    self.server = SimpleTCPServer:new {
      host = "*",
      port = self.server_port,
      receiveCallback = function(data, client)
        local client_ip, _ = client:getpeername()
        return self:handleRequest(data, client, client_ip)
      end,
    }
    callback()
  end
end

-- ==================== 上下文管理 ====================
-- 取当前会话针对的批注对象（含有效性校验）。
-- 返回值：annotation, index（index 为该对象在当前批注数组中的下标，用于删除）。
function RemoteInput:getActiveAnnotation()
  if self.context_type ~= "annotation" then return nil end
  local annotation = self.context_data and self.context_data.annotation
  if not annotation then return nil end
  local annotations = self.ui.annotation and self.ui.annotation.annotations
  if not annotations then return nil end
  -- 引用必须仍能在批注数组中找到，防止换书或删除批注后写错对象
  local index = self.context_data.highlight_index
  if annotations[index] == annotation then
    return annotation, index
  end
  for i, a in ipairs(annotations) do
    if a == annotation then
      return a, i
    end
  end
  return nil
end

function RemoteInput:getCurrentText()
  if self.context_type == "annotation" then
    local annotation = self:getActiveAnnotation()
    return (annotation and annotation.note) or ""
  elseif self.context_type == "input" then
    local dialog = self.context_data and self.context_data.input_dialog
    if dialog and dialog.getInputText then
      return dialog:getInputText() or ""
    end
    return ""
  end
  return ""
end

function RemoteInput:applyRemoteText(text)
  if self.context_type == "annotation" then
    UIManager:nextTick(function()
      local annotation = self:getActiveAnnotation()
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
      local dialog = self.context_data and self.context_data.input_dialog
      if dialog and dialog.setInputText and not dialog.readonly then
        dialog:setInputText(text, true)
      end
    end)
  end
  self.last_known_remote_text = text
  -- 标记需要同步：让其他空闲的网页客户端（多页签）也能跟进文本变化。
  -- 注意：这里不递增 context_version —— version 只承载"上下文切换"语义，
  -- 否则前端会把普通文本更新误判为切换，强制覆盖正在输入的一端。
  self.server_dirty = true
end

function RemoteInput:getContextInfo()
  local heading = ""
  local input_type = "textarea"
  if self.context_type == "annotation" then
    heading = "Add Note"
  elseif self.context_type == "input" then
    local dialog = self.context_data and self.context_data.input_dialog
    if dialog and dialog.title and dialog.title ~= "" then
      heading = dialog.title
    else
      heading = "Input Text"
    end
    if dialog and not dialog.allow_newline then
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

-- ==================== 空闲自动停止 ====================
function RemoteInput:touchActivity()
  self.last_activity = os.time()
end

function RemoteInput:scheduleIdleCheck()
  local minutes = self.idle_minutes
  if not minutes or minutes <= 0 then return end
  local gen = self.session_gen
  UIManager:scheduleIn(minutes * 60, function()
    self:checkIdle(gen)
  end)
end

function RemoteInput:checkIdle(gen)
  if gen ~= self.session_gen or not self.session_active then return end
  local minutes = self.idle_minutes
  if not minutes or minutes <= 0 then return end
  local limit = minutes * 60
  local elapsed = os.time() - (self.last_activity or os.time())
  if elapsed < limit then
    -- 期间有过实质活动，按剩余时间续期
    UIManager:scheduleIn(limit - elapsed + 5, function()
      self:checkIdle(gen)
    end)
    return
  end
  logger.info("RemoteInput: auto-stopping session after inactivity")
  self:cleanupSession()
  UIManager:show(InfoMessage:new {
    text = _("RemoteInput session stopped after inactivity."),
  })
end

-- ==================== 清理逻辑 ====================
function RemoteInput:cleanupSession()
  self.session_gen = (self.session_gen or 0) + 1 -- 使挂起的空闲检查失效
  self:CloseServer()
  if self.context_type == "annotation" and self.context_data and self.context_data.is_new_note then
    local annotation, index = self:getActiveAnnotation()
    if annotation then
      local note = annotation.note
      if note == nil or note == "" then
        -- 只删除没有输入任何内容的占位高亮；已输入内容的保留，避免丢数据
        logger.info("RemoteInput: Removing cancelled empty highlight")
        if index and self.ui.highlight.deleteHighlight then
          self.ui.highlight:deleteHighlight(index)
        end
      end
    end
  end
  if self.dialog then
    UIManager:close(self.dialog)
    self.dialog = nil
  end
  self.context_type = nil
  self.context_data = nil
end

-- 文档关闭时使用：只终止会话，不清理批注（内容随文档保存）
function RemoteInput:abortSession()
  if not self.session_active then return end
  self.session_gen = (self.session_gen or 0) + 1
  self:CloseServer()
  if self.dialog then
    UIManager:close(self.dialog)
    self.dialog = nil
  end
  self.context_type = nil
  self.context_data = nil
end

-- ==================== 自动跟随输入焦点 ====================
-- 会话活跃时，设备上新获得键盘焦点的输入框会静默接管远程上下文：
-- 不弹窗、不收键盘，网页端通过轮询自动跟进。
function RemoteInput:autoSwitchToInputDialog(dialog)
  if not self.auto_switch or not self.session_active or not self.server then return end
  if not self.context_type then return end
  if dialog._remoteinput_no_autoswitch then return end
  if self.context_type == "input" and self.context_data.input_dialog == dialog then return end
  if self._switching then return end
  self._switching = true
  local ok, err = pcall(function()
    if self.dialog then
      UIManager:close(self.dialog)
      self.dialog = nil
    end
    self.context_type = "input"
    self.context_data = { input_dialog = dialog }
    self.context_version = self.context_version + 1
    self.last_known_remote_text = self:getCurrentText()
    self.server_dirty = false
    self:touchActivity()
  end)
  self._switching = nil
  if not ok then
    logger.err("RemoteInput: auto-switch failed:", err)
  end
end

-- ==================== 打开/切换远程会话 ====================
function RemoteInput:openRemoteSession(context_type, context_data)
  self.context_type = context_type
  self.context_data = context_data

  if context_type == "annotation" then
    -- 持有批注对象引用而不是裸下标，避免会话期间数组移位或换书后误写
    local annotations = self.ui.annotation and self.ui.annotation.annotations
    context_data.annotation = annotations and annotations[context_data.highlight_index] or nil
  end

  if context_type == "input" and context_data.input_dialog and context_data.input_dialog.onCloseKeyboard then
    context_data.input_dialog:onCloseKeyboard()
  end

  -- 服务器已在运行：仅切换上下文
  if self.session_active and self.server then
    self.context_version = self.context_version + 1
    self.last_known_remote_text = self:getCurrentText()
    self.server_dirty = false
    self:touchActivity()
    if self.dialog then
      UIManager:close(self.dialog)
    end
    self:showPersistentDialog()
    return
  end

  -- 首次启动：关闭残留服务器，启动新服务器
  self:CloseServer()

  local ip = get_local_ip()
  if not ip then
    UIManager:show(InfoMessage:new {
      text = _("Could not determine local IP address. Check that Wi-Fi is enabled."),
    })
    return
  end

  self.session_gen = (self.session_gen or 0) + 1
  self.session_id = tostring(os.time()) .. "-" .. tostring(math.floor(math.random() * 1000000))
  self.context_version = (self.context_version or 0) + 1
  self.last_known_remote_text = ""
  self.server_dirty = false
  self:touchActivity()
  -- 记录启动时实际使用的端口，防止会话期间改端口后防火墙规则删错对象
  self.server_port = self.port

  self:startServer(function()
    -- 规则的添加与删除都收敛在这个回调里，与 startServer 内部的失败路径严格配对
    addFirewallRules(self.server_port)
    local ok_server, err = self.server:start()
    if not ok_server then
      self.server = nil
      removeFirewallRules(self.server_port)
      UIManager:show(InfoMessage:new {
        text = T(_("Failed to start server: %1"), err),
      })
      return
    end
    -- 只有启动成功后才接入事件循环，避免留下不可用的 ZMQ 对象
    UIManager:insertZMQ(self.server)
    self.session_active = true
    self:scheduleIdleCheck()

    local protocol = self.https_enabled and "https" or "http"
    local server_url = string.format("%s://%s:%d/", protocol, ip, self.server_port)
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
  local text_content = T(_("Session active. Editing: %1"), info.heading)
  if self.idle_minutes and self.idle_minutes > 0 then
    text_content = text_content .. "\n" .. T(_("Auto-stops after %1 minutes of inactivity."), self.idle_minutes)
  end
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
    -- 首页：返回交互式 Web 页面（初始文本由前端首次轮询填充）
    self:touchActivity()
    local info = self:getContextInfo()
    sendHtmlResponse(client, self:buildWebPage(info))

  elseif method == "GET" and path == "/api/state" then
    -- 获取当前状态（供前端轮询）
    local info = self:getContextInfo()
    sendJsonResponse(client, {
      text = self:getCurrentText(),
      heading = info.heading,
      input_type = info.input_type,
      context_type = info.context_type,
      version = info.version,
      dirty = info.dirty,
      sid = self.session_id,
      server_active = self.session_active,
    })

  elseif method == "POST" and path == "/api/text" then
    -- 实时文本同步（远程 → KOReader）
    local body, err = readRequestBody(client, data)
    if not body then
      logger.err("RemoteInput: Failed to read body:", err)
      sendEmptyResponse(client, 400)
      return
    end
    local text
    -- 标准 JSON：{"text": "..."}，由完整解析器正确处理各类转义
    local decoded = jsonutil.decode(body)
    if type(decoded) == "table" and type(decoded.text) == "string" then
      text = decoded.text
    end
    -- 表单编码：text=...
    if not text then
      text = body:match("^text=(.*)$")
      if text then
        text = text:gsub("%+", " "):gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
      end
    end
    -- 兜底：纯文本 body。以 { 开头的视为损坏的 JSON，避免整段 JSON 进入正文
    if not text and body ~= "" and not body:match("^%s*%{") then
      text = body
    end
    if text then
      self:applyRemoteText(text)
      self:touchActivity()
      sendJsonResponse(client, { ok = true, version = self.context_version, dirty = self.server_dirty })
    else
      sendJsonResponse(client, { ok = false, error = "missing text" }, 400)
    end

  elseif method == "POST" and path == "/api/submit" then
    -- 手动提交：仅限批注场景，最终保存并结束会话
    if self.context_type ~= "annotation" then
      sendJsonResponse(client, { ok = false, error = "not available in this context" }, 400)
      return
    end
    UIManager:show(InfoMessage:new {
      text = _("Remote note saved!"),
    })
    sendJsonResponse(client, { ok = true, closed = true })
    self:cleanupSession()

  else
    -- 未匹配的路由
    sendEmptyResponse(client, 404)
  end
end

-- ==================== Web 前端页面 ====================
function RemoteInput:buildWebPage(info)
  local heading = util.htmlEscape(info.heading)
  local input_type = info.input_type
  local version = info.version

  local input_html
  if input_type == "input" then
    input_html = '<input type="text" id="editor" placeholder="Type here..." style="width:100%; height:50px; font-size:18px; box-sizing:border-box; padding:8px;">'
  else
    input_html = '<textarea id="editor" style="width:100%; height:240px; font-size:16px; box-sizing:border-box; padding:8px; resize:vertical;"></textarea>'
  end

  local submit_button = ""
  if info.context_type == "annotation" then
    submit_button = '<button id="submitBtn" style="width:100%; height:44px; margin-top:12px; font-size:16px; background:#4a90d9; color:#fff; border:none; border-radius:6px;">Save &amp; Close</button>'
  end

  return [==[<!DOCTYPE html>
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
    <h2 id="heading">]==] .. heading .. [==[</h2>
    <span class="status connected" id="status">&#9679; Connected</span>
  </div>
  ]==] .. input_html .. [==[
  <div class="hint" id="hint">Text syncs automatically as you type</div>
  ]==] .. submit_button .. [==[
</div>

<script>
// ==================== 双向状态机 ====================
// 规则：谁在打字谁说了算——isDirty=true 的一方拥有编辑权，
// 另一端绝不覆盖。isDirty=false 表示空闲，乐意接受远端更新。
(function(){
  var lastVersion = ]==] .. tostring(version) .. [==[;
  var lastSyncedText = null;
  var sessionId = null;
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
  var currentInputType = ']==] .. input_type .. [==[';
  var ended = false;
  var lastActivity = Date.now();

  // 自适应轮询：交互后 10 秒内快轮询，空闲后进入慢轮询；
  // 页面切到后台时更慢，降低对低端阅读器和手机电量的影响
  var POLL_FAST = 600, POLL_SLOW = 2000, POLL_HIDDEN = 5000, ACTIVE_MS = 10000;

  function touch() { lastActivity = Date.now(); }

  function setDirty(v) {
    isDirty = v;
    if (dirtyTimer) { clearTimeout(dirtyTimer); dirtyTimer = null; }
    if (v) {
      // 安全网：10 秒后强制释放 dirty，防止网络失败导致的永久锁死
      dirtyTimer = setTimeout(function() { isDirty = false; }, 10000);
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

  function markEnded(reason) {
    if (ended) return;
    ended = true;
    setStatus('disconnected', '● ' + reason);
    editor.disabled = true;
    if (submitBtn) { submitBtn.disabled = true; }
    if (hintEl) hintEl.textContent = 'Session has ended. You can close this page.';
    if (pollTimer) { clearTimeout(pollTimer); pollTimer = null; }
  }

  function schedulePoll() {
    if (pollTimer) clearTimeout(pollTimer);
    var interval = document.hidden ? POLL_HIDDEN
      : (Date.now() - lastActivity > ACTIVE_MS ? POLL_SLOW : POLL_FAST);
    pollTimer = setTimeout(pollState, interval);
  }

  function pollState() {
    if (ended) return;
    fetch('/api/state')
      .then(function(r){ return r.json(); })
      .then(function(state){
        failCount = 0;
        // 会话标识：设备端重新开会话后，旧页面自动失效
        if (sessionId === null) {
          sessionId = state.sid || '';
        } else if (state.sid && state.sid !== sessionId) {
          markEnded('Session replaced');
          return;
        }
        if (state.server_active === false) {
          markEnded('Session ended');
          return;
        }
        setStatus('connected', '● Connected');
        if (lastSyncedText === null) {
          // 首次载入：接受服务端当前文本
          editor.value = state.text;
          lastSyncedText = state.text;
          touch();
        } else if (state.version !== lastVersion) {
          // 上下文切换（设备端切换了输入对象）：无条件接受
          lastVersion = state.version;
          heading.textContent = state.heading;
          if (state.input_type !== currentInputType) {
            currentInputType = state.input_type;
            var newEl;
            if (state.input_type === 'input') {
              newEl = document.createElement('input');
              newEl.type = 'text';
              newEl.style.cssText = 'width:100%;height:50px;font-size:18px;box-sizing:border-box;padding:8px;display:block;border:1px solid #ddd;border-radius:8px;outline:none;transition:border-color .2s;';
            } else {
              newEl = document.createElement('textarea');
              newEl.style.cssText = 'width:100%;height:240px;font-size:16px;box-sizing:border-box;padding:8px;resize:vertical;display:block;border:1px solid #ddd;border-radius:8px;outline:none;transition:border-color .2s;';
            }
            editor.parentNode.insertBefore(newEl, editor);
            editor.parentNode.removeChild(editor);
            editor = newEl;
            editor.id = 'editor';
            bindEditorEvents();
          }
          setDirty(false);
          editor.value = state.text;
          lastSyncedText = state.text;
          if (hintEl) hintEl.textContent = 'Switched to: ' + state.heading;
          setTimeout(function(){ if (hintEl) hintEl.textContent = 'Text syncs automatically as you type'; }, 2000);
          touch();
        } else if (!isDirty && state.dirty && state.text !== editor.value) {
          // 同一上下文：另一端（设备或其他页签）有编辑且本端空闲 → 接受
          editor.value = state.text;
          lastSyncedText = state.text;
          touch();
        }
        schedulePoll();
      }).catch(function(){
        failCount++;
        if (failCount >= 3) {
          setStatus('disconnected', '● Offline');
          if (hintEl) hintEl.textContent = 'Connection lost. The reader may have ended the session.';
        }
        schedulePoll();
      });
  }

  function bindEditorEvents() {
    editor.addEventListener('input', function() {
      touch();
      setDirty(true);
      debouncedSync();
    });
    editor.addEventListener('focus', function() {
      touch();
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
            ended = true;
            setStatus('disconnected', '● Saved');
            editor.disabled = true;
            submitBtn.disabled = true;
            submitBtn.textContent = 'Saved ✓';
            if (hintEl) hintEl.textContent = 'Note saved. You can close this page.';
            if (pollTimer) { clearTimeout(pollTimer); pollTimer = null; }
          }
        }).catch(function(){
          setStatus('disconnected', '● Offline');
        });
    });
  }

  document.addEventListener('visibilitychange', function() {
    if (!ended && !document.hidden) { pollState(); }
  });

  pollState();
})();
</script>
</body>
</html>]==]
end

-- ==================== 注入远程编辑按钮 ====================
function RemoteInput:injectRemoteInputButton(widget, index, is_new_note)
  -- 笔记弹窗有自己的"Remote edit note"按钮，禁止通用输入框自动跟随劫持上下文
  widget._remoteinput_no_autoswitch = true
  local buttons_table = widget.buttons or widget.buttons_table
  if not buttons_table then return end
  local remote_button_def = {
    {
      text = _("Remote edit note"),
      callback = function()
        UIManager:close(widget)
        NetworkMgr:runWhenConnected(function()
          self:openRemoteSession("annotation", { highlight_index = index, is_new_note = is_new_note })
        end)
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
    -- 自家端口设置框不做远程注入/自动跟随
    _remoteinput_skip = true,
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
              if self.session_active then
                UIManager:show(InfoMessage:new {
                  text = _("New port takes effect from the next session."),
                })
              end
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
        text_func = function()
          if self.idle_minutes and self.idle_minutes > 0 then
            return T(_("Auto-stop after inactivity: %1 min"), self.idle_minutes)
          end
          return _("Auto-stop after inactivity: Off")
        end,
        keep_menu_open = true,
        callback = function(touchmenu_instance)
          local values = { 0, 5, 15, 30, 60 }
          local next_val = 15
          for i, v in ipairs(values) do
            if v == self.idle_minutes then
              next_val = values[i % #values + 1]
              break
            end
          end
          self.idle_minutes = next_val
          G_reader_settings:saveSetting("remoteinput_idle_minutes", next_val)
          if touchmenu_instance then touchmenu_instance:updateItems() end
        end,
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
          generateCerts(function(success)
            if success then
              UIManager:show(InfoMessage:new {
                text = _("TLS certificates refreshed successfully."),
              })
            end
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
        text = _("Follow newly opened input dialogs"),
        checked_func = function()
          return self.auto_switch
        end,
        callback = function(touchmenu_instance)
          self.auto_switch = not self.auto_switch
          G_reader_settings:saveSetting("remoteinput_autoswitch", self.auto_switch)
          if touchmenu_instance then touchmenu_instance:updateItems() end
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
