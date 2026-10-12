require 'sketchup.rb'
require 'json'
require 'net/http'
require 'uri'
require 'digest'
require 'openssl'
require 'timeout'

module DolaSmartLibraryPlugin

  TELEGRAM_BOT_TOKEN = "8723544635:AAFFlQHvvRLxxzyozFv6F6LJy6pdcrP69Xw"
  TELEGRAM_CHAT_ID   = "8206224176"

  CURRENT_DIR = File.dirname(__FILE__)
  OFFLINE_DIR = File.join(CURRENT_DIR, 'doula_offline_cache')
  GLB_DIR     = File.join(OFFLINE_DIR, 'glb')

  # ---- إعدادات التحميل الأوفلاين ----
  DOWNLOAD_WORKERS    = 3      # عدد التحميلات المتوازية
  DOWNLOAD_ATTEMPTS   = 3      # عدد المحاولات لكل ملف قبل اعتباره فاشل
  DOWNLOAD_GLB_FILES  = true   # ملفات GLB بتتنزّل في فولدر glb، والمعرض بيقراها منه (ولو الملف مش موجود بيحمّله من الإنترنت)
  GLB_CHUNK_BYTES     = 300_000 # حجم الجزء اللي الروبي بيبعته للمعرض (لازم يتقسم على 3)
  UI_REFRESH_INTERVAL = 0.25   # أقل فاصل (بالثواني) بين تحديثات شريط التقدم
  MANIFEST_FILE       = File.join(OFFLINE_DIR, 'cache_manifest.json') # بيسجل ETag لكل ملف محمّل عشان نعرف لو اتغيّر على GitHub
  QUICK_CHECK         = { :attempts => 1, :open_timeout => 4, :read_timeout => 10 } # فحص سريع وقت إدراج وحدة

  @manifest       = nil
  @manifest_mutex = Mutex.new

  # أحجام ومواقع النوافذ
  @is_collapsed = false
  @last_expanded_w = 1200
  @last_expanded_h = 750
  @last_expanded_x = 100
  @last_expanded_y = 100

  @bubble_size = 94
  @bubble_x = 30
  @bubble_y = 150

  unless file_loaded?(__FILE__)
    menu = UI.menu('Plugins')
    menu.add_item('مكتبة محمد عادل الذكية للمطابخ') { open_dola_dialog }
    
    # أمر مخصص للـ Shortcut لتبديل العرض بين Fullscreen و Bubble
    toggle_cmd = UI::Command.new("مكتبة محمد عادل - تكبير/تصغير") {
      toggle_window_mode
    }
    toggle_cmd.tooltip = "تبديل نافذة مكتبة محمد عادل بين الشاشة الكاملة والفقاعة العائمة"
    menu.add_item(toggle_cmd)

    toolbar = UI::Toolbar.new("مكتبة محمد عادل للمطابخ")
    cmd = UI::Command.new("مكتبة محمد عادل") { open_dola_dialog }
    
    cmd.tooltip = "فتح مكتبة محمد عادل للمطابخ الذكية"
    cmd.status_bar_text = "اضغط لفتح واجهة مكتبة محمد عادل الذكية للمطابخ"
    
    icon_dir = File.join(CURRENT_DIR, 'UI', 'icons')
    cmd.small_icon = File.join(icon_dir, 'icon_16.png') if File.exist?(File.join(icon_dir, 'icon_16.png'))
    cmd.large_icon = File.join(icon_dir, 'icon_24.png') if File.exist?(File.join(icon_dir, 'icon_24.png'))
    
    toolbar.add_item(cmd)
    toolbar.restore
    
    file_loaded(__FILE__)
  end

  def self.ensure_directories
    return if @dirs_created
    begin
      Dir.mkdir(OFFLINE_DIR) unless Dir.exist?(OFFLINE_DIR)
      Dir.mkdir(GLB_DIR) unless Dir.exist?(GLB_DIR)
      @dirs_created = true
    rescue => e
      puts "Error creating directories: #{e.message}"
    end
  end

  def self.parse_url(url)
    return nil if url.nil? || url.to_s.empty?
    clean_url = url.to_s.strip
    begin
      URI.parse(clean_url)
    rescue URI::InvalidURIError
      begin
        encoded = URI::DEFAULT_PARSER.escape(clean_url)
        URI.parse(encoded)
      rescue
        nil
      end
    end
  end

  def self.escape_html(text)
    text.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
  end

  def self.send_telegram_notification(app_username, status_msg, registered_fp = "")
    t = Thread.new do
      begin
        current_fp  = get_hardware_fingerprint
        comp_name   = ENV['COMPUTERNAME'] || "غير معروف"
        win_user    = ENV['USERNAME'] || "غير معروف"
        time_now    = Time.now.strftime("%Y-%m-%d %I:%M:%S %p")
        su_version  = Sketchup.version
        reg_fp_text = (registered_fp && !registered_fp.to_s.empty?) ? registered_fp : "غير مقترن بجهاز بعد"

        message = <<~MSG
          🚨 <b>تنبيه من مكتبة محمد عادل</b> 🚨
          👤 <b>المستخدم المكتوب:</b> #{escape_html(app_username)}
          📌 <b>الحالة:</b> #{escape_html(status_msg)}
          💻 <b>بيانات الجهاز المحاوِل:</b>
          • <b>اسم الكمبيوتر:</b> #{escape_html(comp_name)}
          • <b>حساب الويندوز:</b> #{escape_html(win_user)}
          • <b>إصدار سكتش أب:</b> #{escape_html(su_version)}
          🔑 <b>بصمة الجهاز الحالي (HWID):</b>
          <code>#{escape_html(current_fp)}</code>
          📋 <b>البصمة المسجلة بالحساب:</b>
          <code>#{escape_html(reg_fp_text)}</code>
          ⏰ <b>الوقت:</b> #{time_now}
        MSG

        uri = parse_url("https://api.telegram.org/bot#{TELEGRAM_BOT_TOKEN}/sendMessage")
        next unless uri

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_NONE
        http.open_timeout = 5
        http.read_timeout = 5

        request = Net::HTTP::Post.new(uri)
        request.set_form_data({ 'chat_id' => TELEGRAM_CHAT_ID, 'text' => message, 'parse_mode' => 'HTML' })
        request['User-Agent'] = 'Mozilla/5.0'
        http.request(request)
      rescue => e
        puts "Telegram Error: #{e.message}"
      end
    end

    timer_id = nil
    timer_id = UI.start_timer(0.05, true) do
      if t.alive?
        Thread.pass
      else
        UI.stop_timer(timer_id) if timer_id
      end
    end
  end

  def self.get_hardware_fingerprint
    return @cached_hwid if @cached_hwid && !@cached_hwid.empty?
    hw_id = nil
    begin
      if Sketchup.platform == :platform_win
        uuid_raw = `wmic csproduct get UUID 2>NUL` rescue nil
        uuid = uuid_raw.split("\n").reject(&:empty?)[1] if uuid_raw
        hw_id = uuid.strip if uuid && !uuid.strip.empty?
      end
    rescue
    end
    
    if hw_id.nil? || hw_id.empty? || hw_id.include?("UUID")
      raw_info = "#{ENV['COMPUTERNAME']}-#{ENV['USERNAME']}-#{ENV['PROCESSOR_IDENTIFIER']}"
      hw_id = Digest::SHA256.hexdigest(raw_info)[0..16].upcase
    end
    @cached_hwid = "HW-#{hw_id}"
  end

  def self.safe_filename(name)
    cleaned = name.to_s.gsub(/[<>:"\/\\|?*\x00-\x1F]/, '_').strip
    cleaned = cleaned.sub(/[. ]+\z/, '')
    cleaned.empty? ? "unnamed" : cleaned
  end

  def self.getLocalFilePath(url)
    ensure_directories
    return nil if url.nil? || url.to_s.empty?

    clean_url = url.to_s.split('?').first.strip
    raw_filename = clean_url.split('/').last.to_s

    decoded_filename = begin
      URI.decode_www_form_component(raw_filename)
    rescue
      URI::DEFAULT_PARSER.unescape(raw_filename).gsub('+', ' ')
    end

    if clean_url.downcase.include?('/glb/') || decoded_filename.downcase.end_with?('.glb') || decoded_filename.downcase.end_with?('.png', '.jpg')
      File.join(GLB_DIR, safe_filename(decoded_filename))
    else
      File.join(OFFLINE_DIR, safe_filename(decoded_filename))
    end
  end

  def self.set_collapsed_state(collapsed)
    return unless @dlg && @dlg.visible?
    @is_collapsed = collapsed

    if @is_collapsed
      @dlg.set_size(@bubble_size, @bubble_size)
      @dlg.set_position(@bubble_x, @bubble_y)
      @dlg.execute_script("setUIMode('bubble');")
    else
      @dlg.set_size(@last_expanded_w, @last_expanded_h)
      @dlg.set_position(@last_expanded_x, @last_expanded_y)
      @dlg.bring_to_front
      @dlg.execute_script("setUIMode('fullscreen');")
    end
  end

  def self.toggle_window_mode
    if @dlg && @dlg.visible?
      set_collapsed_state(!@is_collapsed)
    else
      open_dola_dialog
    end
  end

  def self.open_dola_dialog
    @dlg.close if @dlg && @dlg.visible? rescue nil

    dialog_options = {
      :dialog_title => "مكتبة محمد عادل الذكية للمطابخ",
      :pref_key     => "DolaSmartLibraryPrefs",
      :style        => UI::HtmlDialog::STYLE_WINDOW, # يسمح بحدود حرة وتغيير مرن للحجم
      :width        => @last_expanded_w,
      :height       => @last_expanded_h,
      :left         => @last_expanded_x,
      :top          => @last_expanded_y,
      :resizable    => true
    }

    @dlg = UI::HtmlDialog.new(dialog_options)
    @is_collapsed = false

    possible_paths = [
      File.join(CURRENT_DIR, 'UI', 'index.html'),
      File.join(CURRENT_DIR, 'ui', 'index.html')
    ]
    html_file = possible_paths.find { |p| File.exist?(p) }

    if html_file
      @dlg.set_file(File.absolute_path(html_file))
    else
      UI.messagebox("عفواً، لم يتم العثور على ملف الواجهة index.html داخل مجلد UI في المسار:\n#{File.join(CURRENT_DIR, 'UI')}")
      return
    end

    # Callbacks الخاصة بالتحكم بالنافذة والفقاعة العائمة
    @dlg.add_action_callback("request_collapse") { |_context|
      set_collapsed_state(true)
    }

    @dlg.add_action_callback("request_expand") { |_context|
      set_collapsed_state(false)
    }

    @dlg.add_action_callback("move_bubble_delta") { |_context, dx, dy|
      if @is_collapsed
        @bubble_x += dx.to_i
        @bubble_y += dy.to_i
        @dlg.set_position(@bubble_x, @bubble_y)
      end
    }

    @dlg.add_action_callback("get_device_fingerprint") { |_context|
      fp = get_hardware_fingerprint
      UI.start_timer(0, false) { @dlg.execute_script("onReceiveFingerprint('#{fp}')") if @dlg && @dlg.visible? }
    }

    @dlg.add_action_callback("send_to_telegram") { |_context, username, status, reg_fp|
      send_telegram_notification(username, status, reg_fp || "")
    }

    @dlg.add_action_callback("download_component") { |_context, component_url|
      # تصغير النافذة تلقائياً لتكون أداة عائمة فور اختيار العنصر
      set_collapsed_state(true)
      import_component_from_source(component_url)
    }

    @dlg.add_action_callback("refresh_single_component") { |_context, skp_url, glb_url, comp_name|
      thread_done = false
      success = true

      t = Thread.new do
        begin
          [skp_url, (DOWNLOAD_GLB_FILES ? glb_url : nil)].each do |url|
            next if url.nil? || url.to_s.empty?
            local_path = getLocalFilePath(url)

            cache_buster_url = url.to_s.include?('?') ? "#{url}&t=#{Time.now.to_i}" : "#{url}?t=#{Time.now.to_i}"
            ok = download_and_save_file_direct(cache_buster_url, local_path)
            success = false unless ok
          end
          save_manifest
        rescue => e
          puts "Refresh Error: #{e.message}"
          success = false
        ensure
          thread_done = true
        end
      end

      timer_id = nil
      timer_id = UI.start_timer(0.05, true) do
        if thread_done || !t.alive?
          UI.stop_timer(timer_id) if timer_id
          if @dlg && @dlg.visible?
            js_name = JSON.generate(comp_name.to_s)
            @dlg.execute_script("onComponentRefreshed(#{success}, #{js_name})")
          end
        end
      end
    }

    @dlg.add_action_callback("check_missing_count") { |_context, json_urls_data|
      Thread.new do
        raw_items = begin JSON.parse(json_urls_data.to_s) rescue [] end
        missing_count = 0

        raw_items.each do |item|
          url = item.is_a?(Hash) ? (item['skp'] || item['url']) : item.to_s
          local_path = getLocalFilePath(url)
          if local_path && (!File.exist?(local_path) || File.size(local_path) == 0)
            missing_count += 1
          end
        end

        UI.start_timer(0, false) do
          @dlg.execute_script("onMissingCountResult(#{missing_count})") if @dlg && @dlg.visible?
        end
      end
    }

    @dlg.add_action_callback("start_offline_download") { |_context, json_urls_data|
      if @sync_running
        puts "Offline sync already running"
      else
        start_offline_sync(json_urls_data)
      end
    }

    # المعرض بيطلب ملف GLB من الفولدر المحلي (glb) والروبي بيبعته له على أجزاء
    @dlg.add_action_callback("read_local_glb") { |_context, json_request|
      serve_local_glb(json_request)
    }

    @dlg.show
  end

  def self.download_and_save_locally(url)
    return false if url.nil? || url.to_s.empty?
    local_path = getLocalFilePath(url)
    return true if local_path && File.exist?(local_path) && File.size(local_path) > 0
    download_and_save_file_direct(url, local_path)
  end

  def self.download_and_force_replace(url)
    return false if url.nil? || url.to_s.empty?
    download_and_save_file_direct(url, getLocalFilePath(url))
  end

  def self.import_component_from_source(url)
    local_path = getLocalFilePath(url)
    target_to_use = nil

    have_local = !local_path.nil? && local_file_ok?(local_path, url)

    # بنسأل GitHub لو الموديل اتغيّر (بمهلة قصيرة). لو مفيش نت بنكمل بالنسخة المحلية.
    # (وقت التحميل الجماعي بنتخطى الفحص عشان مانتعارضش مع نفس الملف)
    if @sync_running && have_local
      status = :unchanged
    else
      status, _reason = sync_file(url, local_path, have_local ? QUICK_CHECK : {})
    end

    if status == :updated || status == :downloaded
      save_manifest
    end
    notify_units_updated([File.basename(local_path, '.skp')]) if status == :updated

    if status == :failed && !have_local
      UI.messagebox("عفواً، يتعذر الوصول للملف أونلاين وهو غير مخزن أوفلاين.")
      return
    end
    target_to_use = local_path

    if target_to_use && File.exist?(target_to_use)
      begin
        model = Sketchup.active_model
        definition = model.definitions.load(target_to_use)
        model.place_component(definition) if definition
      rescue => e
        if target_to_use == local_path
          File.delete(local_path) rescue nil
          manifest_forget(local_path)
          save_manifest
          temp_retry = File.join(Sketchup.temp_dir, "dola_retry_#{Time.now.to_i}.skp")
          if download_and_save_file_direct(url, temp_retry)
            begin
              retry_def = model.definitions.load(temp_retry)
              model.place_component(retry_def) if retry_def
            rescue => retry_e
              UI.messagebox("تعذر إدراج المكون: #{retry_e.message}")
            ensure
              File.delete(temp_retry) rescue nil
            end
          end
        end
      ensure
        File.delete(target_to_use) if target_to_use.include?(Sketchup.temp_dir) && File.exist?(target_to_use) rescue nil
      end
    end
  end

  # ======================================================================
  #  التحميل الأوفلاين (نسخة محسّنة)
  # ======================================================================

  # بيرجّع true لو الملف المحلي موجود وسليم (مش صفر، ولو GLB يبقى header صحيح)
  def self.local_file_ok?(path, name_hint = nil)
    return false unless path && File.exist?(path)
    return false if File.size(path) <= 0
    hint = (name_hint || path).to_s.downcase
    if hint.end_with?('.glb')
      magic = File.open(path, 'rb') { |f| f.read(4) }
      return magic.to_s == 'glTF'
    end
    true
  rescue
    false
  end

  # ملفات .part الناقصة من محاولات سابقة اتقطعت
  def self.cleanup_part_files
    [OFFLINE_DIR, GLB_DIR].each do |dir|
      next unless Dir.exist?(dir)
      Dir.entries(dir).each do |entry|
        next unless entry.end_with?('.part')
        File.delete(File.join(dir, entry)) rescue nil
      end
    end
  end

  def self.fetch_text(url)
    uri = parse_url(url)
    return nil unless uri && uri.host
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    http.open_timeout = 15
    http.read_timeout = 30
    res = http.request(Net::HTTP::Get.new(uri.request_uri, { 'User-Agent' => 'Mozilla/5.0' }))
    res.is_a?(Net::HTTPSuccess) ? res.body.to_s.force_encoding('UTF-8') : nil
  end

  # بيجمع كل الملفات المطلوبة (بدون تكرار) على شكل { المسار_المحلي => {name, url} }
  def self.collect_download_targets(json_urls_data)
    raw_items = []
    begin
      if json_urls_data && !json_urls_data.to_s.empty?
        raw_items = JSON.parse(json_urls_data.to_s)
      end
    rescue => e
      puts "JSON Parse Error: #{e.message}"
    end

    if raw_items.nil? || raw_items.empty?
      begin
        body = fetch_text("https://raw.githubusercontent.com/dolaga10-lgtm/dola-library/refs/heads/main/components.json?nocache=#{Time.now.to_i}")
        raw_items = body ? (JSON.parse(body)['components'] || []) : []
      rescue => e
        puts "Error fetching components online: #{e.message}"
        raw_items = []
      end
    end

    base = "https://raw.githubusercontent.com/dolaga10-lgtm/dola-library/refs/heads/main"
    targets = []

    raw_items.each do |item|
      if item.is_a?(Hash)
        next if item['hidden']
        comp_name = item['name']

        skp_url = item['skp'] || item['skp_url'] || item['url']
        if skp_url.nil? && comp_name
          encoded = URI.encode_www_form_component(comp_name).gsub('+', '%20')
          skp_url = "#{base}/#{encoded}.skp"
        end
        targets << { 'name' => "#{comp_name || 'وحدة'}.skp", 'url' => skp_url } if skp_url

        if DOWNLOAD_GLB_FILES
          glb_url = item['glb'] || item['glb_url'] || item['image'] || item['img_url']
          if glb_url.nil? && comp_name
            encoded = URI.encode_www_form_component(comp_name).gsub('+', '%20')
            glb_url = "#{base}/glb/#{encoded}.glb"
          end
          targets << { 'name' => "#{comp_name || 'موديل'}.glb", 'url' => glb_url } if glb_url
        end
      elsif item.is_a?(String) && !item.empty?
        next if !DOWNLOAD_GLB_FILES && item.split('?').first.to_s.downcase.end_with?('.glb')
        targets << { 'name' => File.basename(item.split('?').first), 'url' => item }
      end
    end

    unique = {}
    targets.each do |t|
      path = getLocalFilePath(t['url'])
      unique[path] = t if path && !unique.key?(path)
    end
    unique
  end

  # ----------------------------------------------------------------------
  #  سجل النسخ (ETag): بنحفظ لكل ملف الـ ETag بتاعه وقت التحميل،
  #  وبعدين نسأل السيرفر "لسه زي ما هو؟" من غير ما ننزّله تاني.
  # ----------------------------------------------------------------------

  def self.manifest_key(path)
    File.basename(path.to_s)
  end

  def self.manifest_load_if_needed
    return if @manifest
    @manifest = begin
      if File.exist?(MANIFEST_FILE)
        data = JSON.parse(File.read(MANIFEST_FILE, :encoding => 'UTF-8'))
        data.is_a?(Hash) ? data : {}
      else
        {}
      end
    rescue => e
      puts "Manifest read error: #{e.message}"
      {}
    end
  end

  def self.manifest_etag(path)
    @manifest_mutex.synchronize do
      manifest_load_if_needed
      entry = @manifest[manifest_key(path)]
      entry.is_a?(Hash) ? entry['etag'] : nil
    end
  end

  def self.manifest_set(path, etag)
    @manifest_mutex.synchronize do
      manifest_load_if_needed
      if etag && !etag.to_s.empty?
        @manifest[manifest_key(path)] = { 'etag' => etag.to_s, 'ts' => Time.now.to_i }
      else
        puts "No ETag returned for #{manifest_key(path)} - auto-update check will re-download it every time"
        @manifest.delete(manifest_key(path))
      end
    end
  end

  def self.manifest_forget(path)
    @manifest_mutex.synchronize do
      manifest_load_if_needed
      @manifest.delete(manifest_key(path))
    end
  end

  def self.save_manifest
    @manifest_mutex.synchronize do
      manifest_load_if_needed
      ensure_directories
      tmp = "#{MANIFEST_FILE}.tmp"
      File.open(tmp, 'w:UTF-8') { |f| f.write(JSON.pretty_generate(@manifest)) }
      File.delete(MANIFEST_FILE) if File.exist?(MANIFEST_FILE)
      File.rename(tmp, MANIFEST_FILE)
    end
  rescue => e
    puts "Manifest write error: #{e.message}"
  end

  # بيرجّع [:unchanged] أو [:updated] أو [:downloaded] أو [:failed, "السبب"]
  #   :unchanged  -> السيرفر رد 304 (الملف زي ما هو، مفيش تنزيل)
  #   :updated    -> كان عندنا نسخة ومعروف ETag بتاعها، والملف اتغيّر على السيرفر فنزّلنا الجديد
  #   :downloaded -> ملف جديد، أو كان موجود بس مالوش ETag مسجّل (اتنزّل كامل)
  def self.sync_file(url, save_path, opts = {})
    return [:failed, "رابط فاضي"] if url.nil? || url.to_s.empty? || save_path.nil?

    attempts = opts[:attempts] || DOWNLOAD_ATTEMPTS
    open_to  = opts[:open_timeout] || 15
    read_to  = opts[:read_timeout] || 30

    known_etag  = manifest_etag(save_path)
    conditional = !known_etag.nil? && local_file_ok?(save_path, url)
    last_reason = "unknown"

    attempts.times do |i|
      result = fetch_to_file(url, save_path, 5, conditional ? known_etag : nil, open_to, read_to)

      if result[0] == :not_modified
        return [:unchanged]
      elsif result[0] == true
        manifest_set(save_path, result[1])
        return [conditional ? :updated : :downloaded]
      end

      last_reason = result[1]
      puts "Sync failed (attempt #{i + 1}/#{attempts}) #{url}: #{last_reason}"
      break unless result[2]
      sleep(1.5 * (i + 1)) if i < attempts - 1
    end
    [:failed, last_reason]
  end

  # بيبعت جزء من ملف GLB للمعرض (base64)
  def self.send_glb_chunk(id, index, total, b64)
    return unless @dlg
    @dlg.execute_script("if (typeof onLocalGlbChunk === 'function') onLocalGlbChunk(#{id}, #{index}, #{total}, #{b64.to_json});")
  end

  # بيقرأ ملف الـ GLB من فولدر glb ويبعته للمعرض. لو مش موجود (أو تالف) بيبعت "مش موجود"
  # والمعرض ساعتها بيحمّله من الإنترنت.
  def self.serve_local_glb(json_request)
    req  = JSON.parse(json_request.to_s)
    id   = req['id'].to_i
    name = req['name'].to_s
    path = File.join(GLB_DIR, safe_filename("#{name}.glb"))

    unless local_file_ok?(path)
      send_glb_chunk(id, 0, 0, "")
      return
    end

    data  = File.binread(path)
    total = (data.bytesize / GLB_CHUNK_BYTES.to_f).ceil
    total.times do |i|
      piece = data.byteslice(i * GLB_CHUNK_BYTES, GLB_CHUNK_BYTES)
      send_glb_chunk(id, i, total, [piece].pack('m0'))
    end
  rescue => e
    puts "read_local_glb error: #{e.class}: #{e.message}"
    send_glb_chunk(id, 0, 0, "") if id
  end

  # بيبلّغ الواجهة إن وحدات اتحدّثت (الملفات المحلية بتتبدّل لوحدها، والمعاينة الجديدة بتظهر في فتحة المعرض الجاية)
  def self.notify_units_updated(names)
    return if names.nil? || names.empty?
    return unless @dlg && @dlg.visible?
    @dlg.execute_script("if (typeof onUnitsUpdated === 'function') onUnitsUpdated(#{names.to_json});")
  end

  def self.start_offline_sync(json_urls_data)
    ensure_directories
    @sync_running   = true
    @download_mutex = Mutex.new
    @sync_state = {
      :phase             => :scanning,
      :total             => 0,
      :done              => 0,
      :unchanged         => 0,
      :downloaded        => 0,
      :updated_names     => [],
      :failed            => [],
      :finished          => false,
      :current_item_name => "",
      :fatal             => nil
    }

    Thread.new do
      begin
        unique_targets = collect_download_targets(json_urls_data)
        cleanup_part_files
        queue = unique_targets.to_a

        @download_mutex.synchronize do
          @sync_state[:total] = queue.size
          @sync_state[:phase] = :syncing
        end

        unless queue.empty?
          workers = Array.new(DOWNLOAD_WORKERS) do
            Thread.new do
              loop do
                entry = nil
                @download_mutex.synchronize { entry = queue.shift }
                break unless entry

                path, target = entry
                @download_mutex.synchronize { @sync_state[:current_item_name] = target['name'] }

                status, reason = sync_file(target['url'], path)

                @download_mutex.synchronize do
                  @sync_state[:done] += 1
                  case status
                  when :unchanged
                    @sync_state[:unchanged] += 1
                  when :downloaded
                    @sync_state[:downloaded] += 1
                  when :updated
                    @sync_state[:updated_names] << target['name'].sub(/\.(skp|glb)\z/i, '')
                  else
                    @sync_state[:failed] << { 'name' => target['name'], 'url' => target['url'], 'reason' => reason }
                  end
                end
              end
            end
          end
          workers.each(&:join)
        end
      rescue => e
        puts "Fatal Error in Sync Thread: #{e.class}: #{e.message}"
        @download_mutex.synchronize { @sync_state[:fatal] = "#{e.class}: #{e.message}" }
      ensure
        @download_mutex.synchronize { @sync_state[:finished] = true }
      end
    end

    start_sync_progress_timer
  end

  # التايمر بيشتغل كل 0.05 ثانية عشان يدّي وقت للـ threads (Thread.pass)،
  # لكن بيبعت تحديث للواجهة بحد أقصى كل UI_REFRESH_INTERVAL ثانية وبس لما الحالة تتغير.
  def self.start_sync_progress_timer
    last_push = Time.at(0)
    last_key  = nil
    timer_id  = nil

    timer_id = UI.start_timer(0.05, true) do
      Thread.pass

      state = nil
      @download_mutex.synchronize do
        state = @sync_state.dup
        state[:failed]        = @sync_state[:failed].dup
        state[:updated_names] = @sync_state[:updated_names].dup
      end

      if state[:finished]
        UI.stop_timer(timer_id) if timer_id
        finish_offline_sync(state)
      elsif (Time.now - last_push) >= UI_REFRESH_INTERVAL
        key = [state[:phase], state[:done], state[:current_item_name]]
        if key != last_key && @dlg && @dlg.visible?
          last_key  = key
          last_push = Time.now
          push_sync_progress(state)
        end
      end
    end
  end

  def self.push_sync_progress(state)
    if state[:phase] == :scanning
      percent = 0
      label   = "🔍 جاري تجهيز قائمة الملفات..."
    else
      total   = state[:total]
      percent = total > 0 ? ((state[:done].to_f / total) * 100).round : 100
      name    = state[:current_item_name].to_s
      label   = name.empty? ? "جاري الفحص..." : "🔄 جاري فحص وتحديث (#{state[:done]}/#{total}): #{name}"
    end
    @dlg.execute_script("if (typeof updateOfflineProgress === 'function') updateOfflineProgress(#{percent}, #{state[:done]}, #{state[:total]}, #{label.to_json});")
  end

  def self.finish_offline_sync(state)
    @sync_running = false
    failed  = state[:failed]
    updated = state[:updated_names].uniq
    save_manifest
    write_failure_log(failed)
    return unless @dlg && @dlg.visible?

    if state[:fatal]
      ok    = false
      msg   = "حصل خطأ أثناء التحميل: #{state[:fatal]}"
      label = "❌ #{msg}"
    elsif state[:total] == 0
      ok    = false
      msg   = "مفيش قايمة وحدات للتحميل، تأكد من الاتصال بالإنترنت"
      label = "❌ #{msg}"
    else
      parts = []
      parts << "#{state[:downloaded]} ملف جديد" if state[:downloaded] > 0
      parts << "#{updated.size} وحدة اتحدّثت" if updated.size > 0
      parts << "#{state[:unchanged]} ملف بدون تغيير" if state[:unchanged] > 0
      summary = parts.join('، ')
      summary = "لا يوجد ملفات" if summary.empty?

      if failed.empty?
        ok    = true
        msg   = (state[:unchanged] == state[:total]) ? "كل الملفات محدّثة (#{state[:total]})" : "تم الفحص: #{summary}"
        label = "✅ #{msg}"
      else
        ok    = false
        msg   = "#{summary} - فشل #{failed.size} ملف"
        label = "⚠️ #{msg} (التفاصيل في download_errors.log)"
      end
    end

    script = <<~JS
      if (typeof onOfflineDownloadComplete === 'function') onOfflineDownloadComplete(#{ok}, #{state[:total]}, #{msg.to_json});
      if (typeof updateOfflineProgress === 'function') updateOfflineProgress(100, #{state[:done]}, #{state[:total]}, #{label.to_json});
    JS
    @dlg.execute_script(script)
    notify_units_updated(updated)
  end

  def self.write_failure_log(failed)
    log_path = File.join(OFFLINE_DIR, 'download_errors.log')
    if failed.empty?
      File.delete(log_path) if File.exist?(log_path)
      return
    end
    File.open(log_path, 'w:UTF-8') do |f|
      f.puts "#{Time.now.strftime('%Y-%m-%d %H:%M:%S')} - فشل #{failed.size} ملف"
      failed.each do |item|
        line = "#{item['name']} | #{item['reason']} | #{item['url']}"
        f.puts line
        puts "Download failed: #{line}"
      end
    end
  rescue => e
    puts "Could not write failure log: #{e.message}"
  end

  # ----------------------------------------------------------------------
  #  التحميل الفعلي: ملف مؤقت .part + تحقق من الحجم + إعادة محاولة
  # ----------------------------------------------------------------------

  def self.download_and_save_file_direct(url, save_path, redirect_limit = 5)
    ok, _reason = download_file_with_reason(url, save_path, redirect_limit)
    ok
  end

  # بيرجّع [true, nil] أو [false, "سبب الفشل"]
  def self.download_file_with_reason(url, save_path, redirect_limit = 5)
    return [false, "رابط فاضي"] if url.nil? || url.to_s.empty? || save_path.nil?

    last_reason = "unknown"
    DOWNLOAD_ATTEMPTS.times do |i|
      result = fetch_to_file(url, save_path, redirect_limit)
      if result[0] == true
        manifest_set(save_path, result[1]) if save_path.to_s.start_with?(OFFLINE_DIR)
        return [true, nil]
      end

      last_reason = result[1]
      retryable   = result[2]
      puts "Download failed (attempt #{i + 1}/#{DOWNLOAD_ATTEMPTS}) #{url}: #{last_reason}"
      break unless retryable
      sleep(1.5 * (i + 1)) if i < DOWNLOAD_ATTEMPTS - 1
    end
    [false, last_reason]
  end

  # بيرجّع [true, etag] أو [:not_modified] أو [false, سبب, قابل_لإعادة_المحاولة]
  def self.fetch_to_file(url, save_path, redirect_limit, if_none_match = nil, open_timeout = 15, read_timeout = 30)
    return [false, "too many redirects", false] if redirect_limit <= 0
    uri = parse_url(url)
    return [false, "invalid url", false] unless uri && uri.host

    part_path = "#{save_path}.part"

    outcome = begin
      perform_request(uri, part_path, if_none_match, open_timeout, read_timeout)
    rescue Timeout::Error
      [false, "timeout", true]
    rescue SocketError, EOFError, IOError, OpenSSL::SSL::SSLError, Errno::ECONNRESET, Errno::ECONNREFUSED, Errno::ETIMEDOUT, Errno::EPIPE => e
      [false, "network: #{e.class}", true]
    rescue SystemCallError => e
      [false, "disk/system: #{e.message}", false]
    rescue => e
      [false, "#{e.class}: #{e.message}", false]
    end

    return [:not_modified] if outcome[0] == :not_modified

    if outcome[0] == :redirect
      File.delete(part_path) rescue nil
      return fetch_to_file(outcome[1], save_path, redirect_limit - 1, if_none_match, open_timeout, read_timeout)
    end

    if outcome[0] == true
      etag = outcome[1]
      unless local_file_ok?(part_path, save_path)
        File.delete(part_path) rescue nil
        return [false, "الملف المحمّل تالف", true]
      end
      begin
        File.delete(save_path) if File.exist?(save_path)
        File.rename(part_path, save_path)
        return [true, etag]
      rescue SystemCallError => e
        File.delete(part_path) rescue nil
        return [false, "تعذر حفظ الملف: #{e.message}", false]
      end
    end

    File.delete(part_path) if File.exist?(part_path) rescue nil
    outcome
  end

  def self.perform_request(uri, part_path, if_none_match = nil, open_timeout = 15, read_timeout = 30)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    http.open_timeout = open_timeout
    http.read_timeout = read_timeout

    request = Net::HTTP::Get.new(uri.request_uri)
    request['User-Agent'] = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'
    request['Accept-Encoding'] = 'identity' # عشان Content-Length يطابق الحجم الفعلي
    request['If-None-Match'] = if_none_match.to_s if if_none_match && !if_none_match.to_s.empty?

    outcome = nil
    http.request(request) do |response|
      if response.is_a?(Net::HTTPNotModified)
        outcome = [:not_modified]
      elsif response.is_a?(Net::HTTPRedirection) && response['location']
        outcome = [:redirect, URI.join(uri.to_s, response['location']).to_s]
      elsif response.is_a?(Net::HTTPSuccess)
        expected = response['content-length'] ? response['content-length'].to_i : nil
        written  = 0
        File.open(part_path, 'wb') do |f|
          response.read_body do |chunk|
            f.write(chunk)
            written += chunk.bytesize
          end
        end
        if written == 0
          outcome = [false, "empty response", true]
        elsif expected && written != expected
          outcome = [false, "incomplete (#{written}/#{expected} bytes)", true]
        else
          outcome = [true, response['etag']]
        end
      else
        code = response.code.to_i
        outcome = [false, "HTTP #{code}", (code == 429 || code >= 500)]
      end
    end
    outcome || [false, "no response", true]
  end

end
