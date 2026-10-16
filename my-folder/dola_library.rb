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
  GLB_DIR      = File.join(OFFLINE_DIR, 'glb')
  DRESSING_DIR = File.join(OFFLINE_DIR, 'dressing')
  GITHUB_BASE_URL = 'https://raw.githubusercontent.com/dolaga10-lgtm/dola-library/refs/heads/main'
  CORE_RB_URL     = "#{GITHUB_BASE_URL}/core.rb"
  DRESSING_STRAIGHT_URL = "#{GITHUB_BASE_URL}/dressing/straight.rb"
  DRESSING_CORNER_URL   = "#{GITHUB_BASE_URL}/dressing/corner.rb"
  DRESSING_UNIT_URLS = {
    'straight' => "#{GITHUB_BASE_URL}/dressing/straight.skp",
    'corner'   => "#{GITHUB_BASE_URL}/dressing/corner.skp"
  }.freeze

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
    menu.add_item('مكتبة محمد عادل') { open_dola_dialog }
    menu.add_item('مكتبة محمد عادل - تعديل وحدة الدريسنج المحددة') {
      selected_dressing = selected_signed_dressing_unit
      if selected_dressing
        open_dressing_design_tool(selected_dressing[1], selected_dressing[0])
      else
        UI.messagebox('حدد وحدة دريسنج (مستقيم أو زاوية) أولاً لتعديلها.')
      end
    }
    
    # أمر مخصص للـ Shortcut لتبديل العرض بين Fullscreen و Bubble
    toggle_cmd = UI::Command.new("مكتبة محمد عادل - تكبير/تصغير") {
      toggle_window_mode
    }
    toggle_cmd.tooltip = "تبديل نافذة مكتبة محمد عادل بين الشاشة الكاملة والفقاعة العائمة"
    menu.add_item(toggle_cmd)

    UI.add_context_menu_handler do |context_menu|
      selected_dressing = selected_signed_dressing_unit
      if selected_dressing
        context_menu.add_item("مكتبة محمد عادل - تعديل وحدة الدريسنج") do
          open_dressing_design_tool(selected_dressing[1], selected_dressing[0])
        end
      end
    end

    toolbar = UI::Toolbar.new("مكتبة محمد عادل")
    cmd = UI::Command.new("مكتبة محمد عادل") { open_dola_dialog }
    
    cmd.tooltip = "فتح مكتبة محمد عادل"
    cmd.status_bar_text = "اضغط لفتح واجهة مكتبة محمد عادل (المطابخ والدريسنج)"
    
    icon_dir = File.join(CURRENT_DIR, 'UI', 'icons')
    cmd.small_icon = File.join(icon_dir, 'icon_16.png') if File.exist?(File.join(icon_dir, 'icon_16.png'))
    cmd.large_icon = File.join(icon_dir, 'icon_24.png') if File.exist?(File.join(icon_dir, 'icon_24.png'))
    
    toolbar.add_item(cmd)
    toolbar.restore

    UI.start_timer(0.2, false) do
      begin
        load_core_rb_engine(false)
      rescue => e
        puts "Startup core.rb load error: #{e.message}"
      end
    end

    file_loaded(__FILE__)
  end

  def self.ensure_directories
    return if @dirs_created
    begin
      Dir.mkdir(OFFLINE_DIR) unless Dir.exist?(OFFLINE_DIR)
      Dir.mkdir(GLB_DIR) unless Dir.exist?(GLB_DIR)
      Dir.mkdir(DRESSING_DIR) unless Dir.exist?(DRESSING_DIR)
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

    if clean_url.downcase.include?('/dressing/')
      File.join(DRESSING_DIR, safe_filename(decoded_filename))
    elsif clean_url.downcase.include?('/glb/') || decoded_filename.downcase.end_with?('.glb') || decoded_filename.downcase.end_with?('.png', '.jpg')
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
    selected_dressing = selected_signed_dressing_unit
    return open_dressing_design_tool(selected_dressing[1], selected_dressing[0]) if selected_dressing

    @dlg.close if @dlg && @dlg.visible? rescue nil

    dialog_options = {
      :dialog_title => "مكتبة محمد عادل",
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

    # Callbacks الخاصة بقسم الدريسنج
    @dlg.add_action_callback("setLibraryMode") { |_context, mode|
      value = mode.to_s == 'dressing' ? 'dressing' : 'kitchens'
      Sketchup.write_default("DolaSmartLibrary", "library_mode", value) rescue nil
    }

    @dlg.add_action_callback("selectDressingType") { |_context, type|
      prepare_dressing_unit(type.to_s, @dlg)
    }

    @dlg.add_action_callback("toggle_tools_bar") { |_context|
      load_core_rb_engine(false)
      show_tools_bar if respond_to?(:show_tools_bar)
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
        if definition
          lib_unit_title = clean_library_unit_name(url)
          lib_unit_title = clean_library_unit_name(target_to_use) if lib_unit_title.empty?
          definition.set_attribute(LIBRARY_META_DICT, 'unit_display_name', lib_unit_title) unless lib_unit_title.empty?
          load_core_rb_engine(false)
          install_place_observer_for(definition, { :url => url, :name => lib_unit_title }) if respond_to?(:install_place_observer_for)
          model.place_component(definition)
        end
      rescue => e
        if target_to_use == local_path
          File.delete(local_path) rescue nil
          manifest_forget(local_path)
          save_manifest
          temp_retry = File.join(Sketchup.temp_dir, "dola_retry_#{Time.now.to_i}.skp")
          if download_and_save_file_direct(url, temp_retry)
            begin
              retry_def = model.definitions.load(temp_retry)
              if retry_def
                load_core_rb_engine(false)
                install_place_observer_for(retry_def, { :url => url }) if respond_to?(:install_place_observer_for)
                model.place_component(retry_def)
              end
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
    [OFFLINE_DIR, GLB_DIR, DRESSING_DIR].each do |dir|
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

    # إضافة ملف الأدوات الرئيسي core.rb وملفات الدريسنج من المستودع لتحميلها وتحديثها أوفلاين
    targets << { 'name' => 'core.rb',                'url' => CORE_RB_URL }
    targets << { 'name' => 'dressing/straight.rb',  'url' => DRESSING_STRAIGHT_URL }
    targets << { 'name' => 'dressing/corner.rb',    'url' => DRESSING_CORNER_URL }
    targets << { 'name' => 'dressing/straight.skp', 'url' => DRESSING_UNIT_URLS['straight'] }
    targets << { 'name' => 'dressing/corner.skp',   'url' => DRESSING_UNIT_URLS['corner'] }

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


  # ======================================================================
  #  نظام الدريسنج (مستقيم / زاوية) — مكتبة محمد عادل
  # ======================================================================
  DRESSING_DICT = 'MHD_DRESSING' unless const_defined?(:DRESSING_DICT, false)
  DRESSING_SYSTEM = 'MHDESIGN_DRESSING' unless const_defined?(:DRESSING_SYSTEM, false)
  DRESSING_SIGNATURES = {
    'straight' => 'MHD_DRESSING_STRAIGHT_V1',
    'corner'   => 'MHD_DRESSING_CORNER_V1'
  }.freeze unless const_defined?(:DRESSING_SIGNATURES, false)

  DRESSING_TOOL_CONSTANTS = {
    'straight' => %w[DolaSmartLibraryPlugin::DressingDesigner MHDESIGN::Dressing::Straight MHDESIGN::DressingStraight MHDESIGN::StraightDressing MHDESIGN::StraightDesigner MHDESIGN::DressingDesigner DressingDesigner],
    'corner'   => %w[DolaSmartLibraryPlugin::DressingCornerDesigner MHDESIGN::Dressing::Corner MHDESIGN::DressingCorner MHDESIGN::CornerDressing MHDESIGN::CornerDesigner MHDESIGN::DressingCornerDesigner CornerDesigner]
  }.freeze unless const_defined?(:DRESSING_TOOL_CONSTANTS, false)

  DRESSING_ENTRY_METHODS = %i[open_for_selection open_for_component open_for_unit show_dialog open_dialog show_ui activate_tool open_selector show open launch run].freeze unless const_defined?(:DRESSING_ENTRY_METHODS, false)

  def self.dressing_attribute(entity, key)
    return nil unless entity && entity.respond_to?(:get_attribute)
    value = entity.get_attribute(DRESSING_DICT, key, nil)
    if (value.nil? || value.to_s.empty?) && entity.respond_to?(:definition) && entity.definition
      value = entity.definition.get_attribute(DRESSING_DICT, key, nil)
    end
    value
  rescue
    nil
  end

  def self.dressing_unit_type(entity)
    return nil unless entity && entity.valid?
    type = dressing_attribute(entity, 'UNIT_TYPE').to_s
    return nil unless DRESSING_UNIT_URLS.key?(type)
    return nil unless dressing_attribute(entity, 'SYSTEM').to_s == DRESSING_SYSTEM
    return nil unless dressing_attribute(entity, 'UNIT_SIGNATURE').to_s == DRESSING_SIGNATURES[type]
    type
  rescue
    nil
  end

  def self.selected_signed_dressing_unit
    Sketchup.active_model.selection.to_a.each do |entity|
      next unless entity.is_a?(Sketchup::ComponentInstance) || entity.is_a?(Sketchup::Group)
      type = dressing_unit_type(entity)
      return [entity, type] if type
    end
    nil
  rescue
    nil
  end

  def self.sign_dressing_unit!(entity, type)
    return false unless entity && entity.valid? && DRESSING_SIGNATURES.key?(type.to_s)
    owners = [entity]
    owners << entity.definition if entity.respond_to?(:definition) && entity.definition
    owners.each do |owner|
      owner.set_attribute(DRESSING_DICT, 'SYSTEM', DRESSING_SYSTEM)
      owner.set_attribute(DRESSING_DICT, 'UNIT_TYPE', type.to_s)
      owner.set_attribute(DRESSING_DICT, 'UNIT_SIGNATURE', DRESSING_SIGNATURES.fetch(type.to_s))
      owner.set_attribute(DRESSING_DICT, 'SIGNATURE_VERSION', 1)
      owner.set_attribute(DRESSING_DICT, 'FUNCTION_ROLE', 'wardrobe_root')
    end
    true
  end

  def self.load_dressing_engine(type)
    type = type.to_s
    return false unless DRESSING_UNIT_URLS.key?(type)
    return true if @loaded_dressing_engines && @loaded_dressing_engines[type]

    ensure_directories
    url = type == 'straight' ? DRESSING_STRAIGHT_URL : DRESSING_CORNER_URL
    local_cache_rb = getLocalFilePath(url)

    # فحص وجود نسخة محلية بجانب الإضافة أو داخل فولدر dressing المحلي
    bundled_candidates = [
      File.join(CURRENT_DIR, 'dressing', "#{type}.rb"),
      File.join(CURRENT_DIR, "#{type}.rb"),
      local_cache_rb
    ].compact

    have_local = local_cache_rb && local_file_ok?(local_cache_rb)
    unless @sync_running && have_local
      sync_file(url, local_cache_rb, have_local ? QUICK_CHECK : {})
    end

    target_rb = bundled_candidates.find { |p| File.exist?(p) && File.size(p) > 0 }
    unless target_rb
      UI.messagebox("❌ تعذر العثور على ملف أداة الدريسنج (#{type}.rb) أونلاين أو أوفلاين.\nتأكد من رفع الملف في فولدر dressing على GitHub.")
      return false
    end

    code = File.read(target_rb, :encoding => 'UTF-8')
    eval(code, TOPLEVEL_BINDING, "(dola_dressing_#{type})", 1)

    @loaded_dressing_engines ||= {}
    @loaded_dressing_engines[type] = true
    true
  rescue => error
    UI.messagebox("❌ تعذر تحميل أداة الدريسنج:\n#{error.message}")
    false
  end

  def self.dressing_constant_from_path(path)
    path.to_s.split('::').reject(&:empty?).inject(Object) do |parent, name|
      return nil unless parent.const_defined?(name, false)
      parent.const_get(name, false)
    end
  rescue NameError
    nil
  end

  def self.open_dressing_design_tool(type, selected_unit = nil)
    type = type.to_s
    return false unless DRESSING_UNIT_URLS.key?(type)
    if selected_unit && dressing_unit_type(selected_unit) != type
      UI.messagebox('⛔ الوحدة المحددة غير موقعة لنوع أداة الدريسنج المطلوبة.')
      return false
    end
    return false unless load_dressing_engine(type)

    candidates = DRESSING_TOOL_CONSTANTS.fetch(type).filter_map { |name| dressing_constant_from_path(name) }
    [self, (Object.const_get(:MHDESIGN) rescue nil)].compact.uniq.each do |mod|
      matcher = type == 'corner' ? /corner|زاوي/i : /straight|designer|مستقيم/i
      mod.constants.each do |constant_name|
        next unless constant_name.to_s.match?(matcher)
        candidate = mod.const_get(constant_name)
        candidates << candidate if candidate.is_a?(Module)
      rescue NameError, LoadError
        next
      end
    end

    candidates.uniq.each do |candidate|
      DRESSING_ENTRY_METHODS.each do |method_name|
        next unless candidate.respond_to?(method_name)
        entry = candidate.method(method_name)
        if entry.arity == 0
          entry.call
        elsif entry.arity == 1 || entry.arity < 0
          entry.call(selected_unit)
        else
          next
        end
        return true
      end
    end

    UI.messagebox("⚠️ تم تحميل أداة الدريسنج لكن لم أجد دالة تشغيل للنوع #{type}.")
    false
  rescue => error
    UI.messagebox("❌ تعذر فتح أداة الدريسنج:\n#{error.message}")
    false
  end

  def self.prepare_dressing_unit(type, library_dialog = nil)
    type = type.to_s
    return false unless DRESSING_UNIT_URLS.key?(type)
    return false if @dressing_unit_loading
    @dressing_unit_loading = true

    library_dialog.execute_script("window.updateEmbeddedLoading(12, 'جاري تجهيز أداة الدريسنج...');") rescue nil if library_dialog
    unless load_dressing_engine(type)
      library_dialog.execute_script("window.hideEmbeddedLoading();") rescue nil if library_dialog
      @dressing_unit_loading = false
      return false
    end

    library_dialog.execute_script("window.updateEmbeddedLoading(40, 'تم تجهيز الأداة، جاري تحميل وحدة الدريسنج...');") rescue nil if library_dialog

    skp_url = DRESSING_UNIT_URLS.fetch(type)
    local_skp = getLocalFilePath(skp_url)
    bundled_skp_candidates = [
      File.join(CURRENT_DIR, 'dressing', "#{type}.skp"),
      File.join(CURRENT_DIR, "#{type}.skp"),
      local_skp
    ].compact

    UI.start_timer(0.05, false) do
      begin
        have_local = local_skp && local_file_ok?(local_skp, skp_url)
        unless @sync_running && have_local
          status, _reason = sync_file(skp_url, local_skp, have_local ? QUICK_CHECK : {})
          save_manifest if status == :updated || status == :downloaded
        end

        target_skp = bundled_skp_candidates.find { |p| local_file_ok?(p, skp_url) }
        unless target_skp
          library_dialog.execute_script("window.hideEmbeddedLoading();") rescue nil if library_dialog
          UI.messagebox("عفواً، تعذر تحميل ملف الوحدة (#{type}.skp) من فولدر dressing على GitHub وهو غير مخزن أوفلاين.")
          next
        end

        library_dialog.execute_script("window.updateEmbeddedLoading(92, 'جاري تجهيز الوحدة للإدراج...');") rescue nil if library_dialog
        model = Sketchup.active_model
        definition = model.definitions.load(target_skp)
        unless definition
          library_dialog.execute_script("window.hideEmbeddedLoading();") rescue nil if library_dialog
          UI.messagebox("تعذر قراءة ملف وحدة الدريسنج (#{type}.skp).")
          next
        end

        component = {
          url: skp_url,
          name: type == 'straight' ? 'وحدة دريسنج مستقيم' : 'وحدة دريسنج زاوية',
          dressing_type: type
        }

        library_dialog.execute_script("window.updateEmbeddedLoading(100, 'اكتمل التجهيز');") rescue nil if library_dialog
        library_dialog.execute_script("window.hideEmbeddedLoading();") rescue nil if library_dialog
        set_collapsed_state(true)

        activate_smart_unit_placement(definition, component)
      rescue => error
        library_dialog.execute_script("window.hideEmbeddedLoading();") rescue nil if library_dialog
        UI.messagebox("❌ تعذر تجهيز وحدة الدريسنج:\n#{error.message}")
      ensure
        @dressing_unit_loading = false
      end
    end
    true
  rescue => error
    @dressing_unit_loading = false
    library_dialog.execute_script("window.hideEmbeddedLoading();") rescue nil if library_dialog
    UI.messagebox("❌ تعذر تحميل وحدة الدريسنج:\n#{error.message}")
    false
  end

  LIBRARY_META_DICT = 'DolaLibraryMeta'.freeze unless const_defined?(:LIBRARY_META_DICT, false)

  def self.clean_library_unit_name(raw_str)
    return '' if raw_str.nil?
    s = raw_str.to_s.split('?').first.to_s.strip
    s = s.split('/').last.to_s if s.include?('/')
    s = s.split('\\').last.to_s if s.include?('\\')
    begin
      s = URI.decode_www_form_component(s)
    rescue
      s = URI::DEFAULT_PARSER.unescape(s).gsub('+', ' ') rescue s
    end
    s = s.sub(/\.(skp|glb)\z/i, '')
    s = s.gsub(/\s*\([^)]*\)/, '')
    s = s.sub(/#\d+\z/, '').strip
    generic = ['base_unit', 'wall_unit', 'tall_unit', 'corner_unit', 'component', 'المكون الرئيسي', 'مكون رئيسي']
    return '' if generic.include?(s.downcase)
    s
  rescue
    ''
  end

  def self.write_source_metadata(instance, comp_data)
    return false unless instance && instance.valid?
    raw_name = ''
    if comp_data.is_a?(Hash)
      raw_name = (comp_data[:name] || comp_data['name'] || comp_data[:url] || comp_data['url']).to_s
    elsif comp_data.is_a?(String)
      raw_name = comp_data
    end
    clean_name = clean_library_unit_name(raw_name)
    if clean_name.empty? && instance.respond_to?(:definition) && instance.definition
      clean_name = clean_library_unit_name(instance.definition.get_attribute(LIBRARY_META_DICT, 'unit_display_name', nil))
      clean_name = clean_library_unit_name(instance.definition.path) if clean_name.empty?
      clean_name = clean_library_unit_name(instance.definition.name) if clean_name.empty?
    end
    unless clean_name.empty?
      instance.set_attribute(LIBRARY_META_DICT, 'unit_display_name', clean_name) rescue nil
      instance.name = clean_name rescue nil
      if instance.respond_to?(:definition) && instance.definition
        instance.definition.set_attribute(LIBRARY_META_DICT, 'unit_display_name', clean_name) rescue nil
      end
    end
    true
  rescue
    false
  end

  def self.options_protected_module
    self
  end

  # ======================================================================
  #  محمّل ملف الأدوات الرئيسي (core.rb) من GitHub أو الكاش المحلي
  # ======================================================================
  def self.load_core_rb_engine(force_remote = false)
    return true if @core_rb_loaded && !force_remote

    ensure_directories
    local_cache_core = File.join(OFFLINE_DIR, 'core.rb')
    bundled_core     = File.join(CURRENT_DIR, 'core.rb')

    if force_remote
      status, _reason = sync_file(CORE_RB_URL, local_cache_core, {})
      save_manifest if status == :updated || status == :downloaded
    elsif !local_file_ok?(bundled_core) && !local_file_ok?(local_cache_core)
      status, _reason = sync_file(CORE_RB_URL, local_cache_core, QUICK_CHECK)
      save_manifest if status == :updated || status == :downloaded
    end

    # إذا تم تحديث النسخة في الكاش من GitHub نفضّلها، وإلا نأخذ المرفقة بجانب الإضافة
    target_core =
      if force_remote && local_file_ok?(local_cache_core)
        local_cache_core
      elsif local_file_ok?(bundled_core)
        bundled_core
      elsif local_file_ok?(local_cache_core)
        local_cache_core
      else
        nil
      end

    return false unless target_core && File.exist?(target_core)

    code = File.read(target_core, :encoding => 'UTF-8')
    eval(code, TOPLEVEL_BINDING, '(dola_core_rb)', 1)
    @core_rb_loaded = true

    # فحص صامت في الخلفية لتحديث نسخة الكاش من GitHub دون تعطيل الواجهة
    if !force_remote && !@core_bg_checked
      @core_bg_checked = true
      Thread.new do
        begin
          st, _r = sync_file(CORE_RB_URL, local_cache_core, QUICK_CHECK)
          save_manifest if st == :updated || st == :downloaded
        rescue
        end
      end
    end

    true
  rescue => e
    puts "Error loading core.rb: #{e.message}"
    false
  end

  def self.reload_core_rb_from_github(show_message = true)
    ok = load_core_rb_engine(true)
    if show_message
      if ok
        UI.messagebox('✨ تم تحديث وإعادة تحميل ملف الأدوات (core.rb) من GitHub بنجاح!')
      else
        UI.messagebox('⚠️ تعذر تحديث core.rb من GitHub، تم الاستمرار بالنسخة المحلية.')
      end
    end
    ok
  end

  unless respond_to?(:open_options_automatically)
    def self.open_options_automatically(instance)
      load_core_rb_engine(false)
      return open_unit_options_dialog(instance) if respond_to?(:open_unit_options_dialog)
      false
    rescue
      false
    end
  end

  def self.restore_library_after_placement
    true
  end

  # ==================== Dynamic helpers ====================
  def self.dynamic?(instance)
    return false unless instance.is_a?(Sketchup::ComponentInstance)
    return true if instance.attribute_dictionary("dynamic_attributes", false)
    return true if instance.definition && instance.definition.attribute_dictionary("dynamic_attributes", false)
    false
  rescue
    false
  end

  def self.unwrap_to_dynamic!(instance)
    return instance unless instance && instance.valid? && instance.is_a?(Sketchup::ComponentInstance)

    saved_lib_name = clean_library_unit_name(instance.get_attribute(LIBRARY_META_DICT, 'unit_display_name', nil))
    if saved_lib_name.empty? && instance.definition
      saved_lib_name = clean_library_unit_name(instance.definition.get_attribute(LIBRARY_META_DICT, 'unit_display_name', nil))
      saved_lib_name = clean_library_unit_name(instance.definition.path) if saved_lib_name.empty?
      saved_lib_name = clean_library_unit_name(instance.definition.name) if saved_lib_name.empty?
    end

    if dynamic?(instance)
      unless saved_lib_name.empty?
        instance.set_attribute(LIBRARY_META_DICT, 'unit_display_name', saved_lib_name) rescue nil
        instance.name = saved_lib_name rescue nil
      end
      return instance
    end

    ents = instance.definition.entities.to_a
    childs = ents.grep(Sketchup::ComponentInstance)
    groups = ents.grep(Sketchup::Group)
    faces  = ents.grep(Sketchup::Face)

    # لا نفك الغلاف إلا إذا كان الملف الخارجي مجرد غلاف فارغ يحتوي على كمبوننت رئيسي واحد فقط بداخله
    return instance unless childs.length == 1 && groups.empty? && faces.empty?
    return instance unless dynamic?(childs.first)

    model = Sketchup.active_model
    model.start_operation("Unwrap Dynamic Component", true)
    begin
      parent_ents = instance.parent.entities
      before_ids = parent_ents.to_a.map(&:entityID)

      instance.explode

      after = parent_ents.to_a.reject { |e| before_ids.include?(e.entityID) }
      after_insts = after.grep(Sketchup::ComponentInstance)

      dyn = after_insts.find { |x| dynamic?(x) } || after_insts.first
      if dyn && dyn.valid? && !saved_lib_name.empty?
        dyn.set_attribute(LIBRARY_META_DICT, 'unit_display_name', saved_lib_name) rescue nil
        dyn.definition.set_attribute(LIBRARY_META_DICT, 'unit_display_name', saved_lib_name) rescue nil
        dyn.name = saved_lib_name rescue nil
      end
      model.selection.clear
      model.selection.add(dyn) if dyn
      model.commit_operation
      dyn || instance
    rescue
      model.abort_operation rescue nil
      instance
    end
  end


  # ==================== Library Temporary Visibility ====================
  @library_dialog = nil
  @library_dialog_hidden_for_placement = false
  @library_dialog_restore_position = nil

  def self.register_library_dialog(dialog)
    @library_dialog = dialog
    @library_dialog_hidden_for_placement = false
    dialog
  rescue
    dialog
  end

  # HtmlDialog لا يوفّر Hide ثابتاً في كل إصدارات SketchUp،
  # لذلك ننقل النافذة مؤقتاً خارج الشاشة ونرجعها بعد التثبيت أو الإلغاء.
  def self.hide_library_for_placement
    dlg = @library_dialog
    return false unless dlg

    begin
      return true if @library_dialog_hidden_for_placement

      pos = dlg.get_position rescue nil
      @library_dialog_restore_position =
        if pos.is_a?(Array) && pos.length >= 2
          [pos[0].to_i, pos[1].to_i]
        else
          [DEFAULT_DIALOG_LEFT, DEFAULT_DIALOG_TOP]
        end

      dlg.set_position(-30000, -30000)
      @library_dialog_hidden_for_placement = true
      true
    rescue
      begin
        dlg.minimize
        @library_dialog_hidden_for_placement = true
        true
      rescue
        false
      end
    end
  end

  def self.restore_library_after_placement
    dlg = @library_dialog
    return false unless dlg
    return true unless @library_dialog_hidden_for_placement

    begin
      pos = @library_dialog_restore_position || [DEFAULT_DIALOG_LEFT, DEFAULT_DIALOG_TOP]
      dlg.set_position(pos[0].to_i, pos[1].to_i) rescue nil
      dlg.show rescue nil
      dlg.bring_to_front if dlg.respond_to?(:bring_to_front)
      @library_dialog_hidden_for_placement = false
      true
    rescue
      @library_dialog_hidden_for_placement = false
      false
    end
  end

  # ==================== Smart Unit Placement ====================
  SMART_SNAP_DISTANCE = 20.cm unless const_defined?(:SMART_SNAP_DISTANCE, false)

  class SmartUnitPlacementTool
    def initialize(definition, comp_data = nil)
      @definition = definition
      @comp_data = comp_data
      @instance = nil
      @target = nil
      @mode = :free
      @placed = false
      @movement_plane_z = 0.0
      @ctrl_down = false
      @last_mouse_x = nil
      @last_mouse_y = nil
      @last_view = nil
    end

    def activate
      model = Sketchup.active_model
      @instance = model.active_entities.add_instance(@definition, Geom::Transformation.new)
      @movement_plane_z = @instance.bounds.min.z.to_f
      model.selection.clear
      model.selection.add(@instance)
      Sketchup.status_text = 'حرّك الوحدة للسناب يمين أو شمال. اضغط Ctrl لإيقاف السناب واختيار الوحدة تحت الماوس للاستبدال.'
    rescue => e
      UI.messagebox("❌ تعذر بدء الإدراج الذكي:\n#{e.message}")
      model.select_tool(nil) rescue nil
    end

    def deactivate(view)
      erase_preview unless @placed
      DolaSmartLibraryPlugin.restore_library_after_placement
      view.invalidate if view
    end

    def onCancel(reason, view)
      erase_preview
      DolaSmartLibraryPlugin.restore_library_after_placement
      Sketchup.active_model.select_tool(nil)
      view.invalidate
    end

    def onKeyDown(key, repeat, flags, view)
      if key.to_i == 17 # Ctrl
        @ctrl_down = true
        refresh_from_last_mouse(view)
      end
    end

    def onKeyUp(key, repeat, flags, view)
      if key.to_i == 17 # Ctrl
        @ctrl_down = false
        refresh_from_last_mouse(view)
      end
    end

    def refresh_from_last_mouse(view = nil)
      active_view = view || @last_view
      return unless active_view && !@last_mouse_x.nil? && !@last_mouse_y.nil?
      onMouseMove(0, @last_mouse_x, @last_mouse_y, active_view)
    rescue
      active_view.invalidate if active_view
    end

    def onMouseMove(flags, x, y, view)
      return unless valid_instance?

      @last_mouse_x = x
      @last_mouse_y = y
      @last_view = view

      point = point_on_movement_plane(view, x, y)
      return unless point

      @target, @mode, tr = calculate_placement(point, @ctrl_down, view, x, y)
      @instance.transformation = tr if tr

      Sketchup.status_text =
        case @mode
        when :replace
          'وضع الاستبدال: السناب متوقف والوحدة تحت الماوس محددة — اضغط للتأكيد.'
        when :snap_x_min, :snap_x_max
          'تم اختيار الجانب الفارغ تلقائيًا — اضغط لتثبيت الوحدة.'
        when :snap_wall
          'تم جذب الوحدة للحائط وتوجيه ضهرها إليه — اضغط لتثبيت الوحدة.'
        else
          'حرّك الوحدة للسناب يمين أو شمال. اضغط Ctrl لإيقاف السناب واختيار الوحدة تحت الماوس للاستبدال.'
        end

      view.invalidate
    rescue => e
      puts "DolaSmartLibraryPlugin smart placement mouse error: #{e.message}"
    end

    def onLButtonDown(flags, x, y, view)
      return unless valid_instance?

      model = Sketchup.active_model
      replacement_target = (@ctrl_down && @mode == :replace && valid_target?(@target)) ? @target : nil
      final_instance = @instance

      begin
        # نفك الغلاف أولاً حتى نطبّق المقاسات على الـ Dynamic Component الحقيقي.
        final_instance = DolaSmartLibraryPlugin.unwrap_to_dynamic!(final_instance)

        if replacement_target
          replace_without_scale!(final_instance, replacement_target)
        end

        DolaSmartLibraryPlugin.write_source_metadata(final_instance, @comp_data) if final_instance && final_instance.valid?
        model.selection.clear
        model.selection.add(final_instance) if final_instance && final_instance.valid?
        @placed = true

        dressing_type = @comp_data.is_a?(Hash) ? (@comp_data[:dressing_type] || @comp_data['dressing_type']).to_s : ''
        if !dressing_type.empty? && final_instance && final_instance.valid?
          DolaSmartLibraryPlugin.sign_dressing_unit!(final_instance, dressing_type)
          UI.start_timer(0.05, false) do
            DolaSmartLibraryPlugin.open_dressing_design_tool(dressing_type, final_instance) if final_instance.valid?
          end
        else
          UI.start_timer(0.20, false) do
            DolaSmartLibraryPlugin.open_options_automatically(final_instance) if final_instance && final_instance.valid?
          end
        end
      rescue => e
        UI.messagebox("❌ خطأ أثناء إنهاء إدراج الوحدة:\n#{e.message}")
      end

      DolaSmartLibraryPlugin.restore_library_after_placement
      model.select_tool(nil)
      view.invalidate
    end

    def draw(view)
      return unless valid_target?(@target)
      points = entity_world_corners(@target)
      return if points.length != 8

      edges = [
        0,1, 1,3, 3,2, 2,0,
        4,5, 5,7, 7,6, 6,4,
        0,4, 1,5, 2,6, 3,7
      ]
      view.line_width = 3
      view.drawing_color = (@mode == :replace ? 'red' : 'lime')
      view.draw(GL_LINES, edges.map { |i| points[i] })
    rescue
    end

    private

    def valid_instance?
      @instance && @instance.valid?
    end

    LIBRARY_UNIT_DEFINITION_PREFIXES = %w[BASE_UNIT WALL_UNIT TALL_UNIT].freeze
    ROOM_BUILDER_DICT = 'MHD_ROOM_BUILDER'.freeze

    def library_unit_component?(entity)
      return false unless entity.is_a?(Sketchup::ComponentInstance)
      return false unless entity.valid? && entity.visible?

      name = entity.definition.name.to_s.strip.upcase
      return false if name.empty?

      LIBRARY_UNIT_DEFINITION_PREFIXES.any? do |prefix|
        name == prefix || name.start_with?("#{prefix}#") || name.start_with?("#{prefix}_")
      end
    rescue
      false
    end

    def valid_target?(entity)
      entity && entity != @instance && library_unit_component?(entity)
    end

    def erase_preview
      @instance.erase! if valid_instance?
    rescue
    ensure
      @instance = nil
    end

    def point_on_movement_plane(view, x, y)
      ray = view.pickray(x, y)
      plane_origin = Geom::Point3d.new(0, 0, @movement_plane_z || 0.0)
      Geom.intersect_line_plane(ray, [plane_origin, Z_AXIS])
    rescue
      nil
    end

    def candidate_entities
      model = Sketchup.active_model
      model.active_entities.to_a.select do |entity|
        next false if entity == @instance
        library_unit_component?(entity)
      end
    rescue
      []
    end

    def normalized_axis(vector)
      v = vector.clone
      return nil if v.length <= 0.000001
      v.normalize!
      v
    rescue
      nil
    end

    def unit_axes(entity)
      tr = entity.transformation
      [
        tr.origin,
        normalized_axis(tr.xaxis) || X_AXIS,
        normalized_axis(tr.yaxis) || Y_AXIS,
        normalized_axis(tr.zaxis) || Z_AXIS
      ]
    rescue
      [ORIGIN, X_AXIS, Y_AXIS, Z_AXIS]
    end

    def local_bounds(entity)
      entity.definition.bounds
    rescue
      entity.bounds
    end

    def entity_world_corners(entity)
      bounds_corners(local_bounds(entity)).map { |p| p.transform(entity.transformation) }
    rescue
      []
    end

    def bounds_corners(bounds)
      min = bounds.min
      max = bounds.max
      [
        Geom::Point3d.new(min.x, min.y, min.z),
        Geom::Point3d.new(max.x, min.y, min.z),
        Geom::Point3d.new(min.x, max.y, min.z),
        Geom::Point3d.new(max.x, max.y, min.z),
        Geom::Point3d.new(min.x, min.y, max.z),
        Geom::Point3d.new(max.x, min.y, max.z),
        Geom::Point3d.new(min.x, max.y, max.z),
        Geom::Point3d.new(max.x, max.y, max.z)
      ]
    end

    def coordinates_in_axes(point, origin, axes)
      v = origin.vector_to(point)
      [v.dot(axes[0]), v.dot(axes[1]), v.dot(axes[2])]
    end

    def extents_in_axes(entity, origin, axes)
      coords = entity_world_corners(entity).map { |p| coordinates_in_axes(p, origin, axes) }
      [
        coords.map { |a| a[0] }.min, coords.map { |a| a[0] }.max,
        coords.map { |a| a[1] }.min, coords.map { |a| a[1] }.max,
        coords.map { |a| a[2] }.min, coords.map { |a| a[2] }.max
      ]
    end

    def target_under_mouse(view, x, y)
      return nil unless view && !x.nil? && !y.nil?

      helper = view.pick_helper
      helper.do_pick(x, y, 12)

      # نفحص كل مسارات الالتقاط؛ نختار أول Component/Group علوي
      # موجود مباشرة داخل active_entities حتى لا نمسك قطعة داخلية من الوحدة.
      active_entities = Sketchup.active_model.active_entities
      count = helper.count.to_i

      (0...count).each do |index|
        path = helper.path_at(index) rescue nil
        next unless path.is_a?(Array)

        path.reverse_each do |entity|
          next if entity == @instance
          next unless entity && entity.valid? && entity.visible?
          next unless library_unit_component?(entity)

          parent_entities = entity.parent.respond_to?(:entities) ? entity.parent.entities : nil
          return entity if parent_entities == active_entities
        end
      end

      picked = helper.best_picked rescue nil
      while picked && picked.respond_to?(:parent)
        return picked if candidate_entities.include?(picked)
        parent = picked.parent
        break unless parent.respond_to?(:instances) || parent.respond_to?(:entities)
        picked = nil
      end

      nil
    rescue
      nil
    end

    # ===== سناب حوائط MHD Room Builder أثناء معاينة الإدراج =====

    def room_builder_wall?(entity)
      return false unless entity.respond_to?(:get_attribute)
      entity.get_attribute(ROOM_BUILDER_DICT, 'النوع').to_s == 'حائط'
    rescue
      false
    end

    def parse_room_builder_point(value)
      values = value.to_s.split('|').map(&:to_f)
      return nil unless values.length == 3
      Geom::Point3d.new(values[0], values[1], values[2])
    rescue
      nil
    end

    # يرجع الحائط الموجود تحت الماوس مع التحويل المتراكم من جروب الغرفة
    # إلى إحداثيات العالم. لا يدخل هذا المسار في اختيار وحدات المكتبة.
    def wall_under_mouse(view, x, y)
      return nil unless view && !x.nil? && !y.nil?

      helper = view.pick_helper
      helper.do_pick(x, y, 12)
      count = helper.count.to_i

      (0...count).each do |index|
        path = helper.path_at(index) rescue nil
        next unless path.is_a?(Array)

        world_tr = Geom::Transformation.new
        path.each do |entity|
          next unless entity.is_a?(Sketchup::ComponentInstance) || entity.is_a?(Sketchup::Group)
          world_tr = world_tr * entity.transformation
          return [entity, world_tr] if room_builder_wall?(entity)
        end
      end

      nil
    rescue
      nil
    end

    def wall_snap_data(wall, world_tr)
      p1 = parse_room_builder_point(wall.get_attribute(ROOM_BUILDER_DICT, 'P1'))
      p2 = parse_room_builder_point(wall.get_attribute(ROOM_BUILDER_DICT, 'P2'))
      return nil unless p1 && p2

      a = p1.transform(world_tr)
      b = p2.transform(world_tr)
      tangent = a.vector_to(b)
      return nil if tangent.length < 0.1.mm
      tangent.normalize!

      # نظام بناء الحوائط يحفظ حدود الأرضية عكس عقارب الساعة؛ داخل الغرفة
      # يكون يسار P1 -> P2، بينما سُمك الحائط يكون في الاتجاه المقابل.
      inward = Z_AXIS.cross(tangent)
      inward.normalize!
      [a, b, tangent, inward]
    rescue
      nil
    end

    def closest_point_on_wall_segment(point, a, b, side_margin = 0.0)
      segment = a.vector_to(b)
      length = segment.length
      return a if length < 0.000001

      tangent = segment.clone
      tangent.normalize!
      distance = a.vector_to(point).dot(tangent)

      margin = [[side_margin.to_f, 0.0].max, length * 0.5].min
      distance = [[distance, margin].max, length - margin].min
      a.offset(tangent, distance)
    rescue
      a
    end

    def wall_snapped_transform(wall, wall_world_tr, mouse_point)
      data = wall_snap_data(wall, wall_world_tr)
      return nil unless data
      a, b, tangent, inward = data

      lxmin, lxmax, lymin, lymax, lzmin, _lzmax = definition_bounds_values
      local_center_x = (lxmin + lxmax) * 0.5
      half_width = (lxmax - lxmin).abs * 0.5

      # +Y في وحدات المكتبة هو اتجاه الضهر. نوجهه خارج الغرفة ناحية الحائط.
      yaxis = Geom::Vector3d.new(-inward.x, -inward.y, 0)
      yaxis.normalize!

      # نحسب X من Y و Z للحفاظ على نظام محاور يميني ومنع الـ Mirror.
      zaxis = Z_AXIS.clone
      xaxis = yaxis.cross(zaxis)
      xaxis.normalize!

      anchor = closest_point_on_wall_segment(mouse_point, a, b, half_width)
      back_bottom_center = Geom::Point3d.new(anchor.x, anchor.y, @movement_plane_z.to_f)

      # نضع مركز الحافة الخلفية (local Y max) على خط الوجه الداخلي للحائط.
      new_origin = back_bottom_center
        .offset(xaxis, -local_center_x)
        .offset(yaxis, -lymax)
        .offset(zaxis, -lzmin)

      Geom::Transformation.axes(new_origin, xaxis, yaxis, zaxis)
    rescue
      nil
    end

    def calculate_placement(point, ctrl_down = false, view = nil, mouse_x = nil, mouse_y = nil)
      # عند الضغط على Ctrl يتم إلغاء السناب بالكامل.
      # نستخدم PickHelper لاختيار الوحدة الموجودة فعلياً تحت مؤشر الماوس،
      # بدل الاعتماد على حساسية المسافة أو المنطقة الوسطى فقط.
      if ctrl_down
        picked = target_under_mouse(view, mouse_x, mouse_y)
        if valid_target?(picked)
          origin, xaxis, yaxis, zaxis = unit_axes(picked)
          axes = [xaxis, yaxis, zaxis]
          ext = extents_in_axes(picked, origin, axes)
          if ext && ext.all?
            return [picked, :replace, replacement_preview_transform(origin, axes, ext)]
          end
        end

        # Ctrl مضغوط ولا توجد وحدة تحت المؤشر: حركة حرة فقط بلا أي سناب.
        return [nil, :free, free_transform(point)]
      end

      # سناب الحائط مسار مستقل. لا يعمل مع Ctrl، ولا يغيّر أي سطر من
      # حسابات السناب الحالية بين وحدات BASE/WALL/TALL.
      wall_pick = wall_under_mouse(view, mouse_x, mouse_y)
      if wall_pick
        wall, wall_world_tr = wall_pick
        wall_tr = wall_snapped_transform(wall, wall_world_tr, point)
        return [wall, :snap_wall, wall_tr] if wall_tr
      end

      best = nil
      best_score = nil

      # الأولوية للوحدة الموجودة فعلياً تحت الماوس، مهما كان منسوب Z الخاص بها.
      # بعد ذلك نقارن القرب على مستوى العرض/العمق فقط، لأن فرق الارتفاع
      # لا يجب أن يمنع السناب مع WALL_UNIT أو TALL_UNIT.
      picked_target = target_under_mouse(view, mouse_x, mouse_y)

      candidate_entities.each do |entity|
        origin, xaxis, yaxis, zaxis = unit_axes(entity)
        axes = [xaxis, yaxis, zaxis]
        ext = extents_in_axes(entity, origin, axes)
        next unless ext.all?

        px, py, pz = coordinates_in_axes(point, origin, axes)
        xmin, xmax, ymin, ymax, zmin, zmax = ext

        dx = px < xmin ? xmin - px : (px > xmax ? px - xmax : 0.0)
        dy = py < ymin ? ymin - py : (py > ymax ? py - ymax : 0.0)

        # لا ندخل فرق Z في المسافة؛ snapped_transform سيأخذ zmin من الهدف.
        score = Math.sqrt(dx * dx + dy * dy)

        # الوحدة تحت الماوس لها أولوية قوية حتى لو توجد وحدة أخرى بنفس إسقاط XY.
        score -= SMART_SNAP_DISTANCE * 10.0 if entity == picked_target

        next if entity != picked_target && score > SMART_SNAP_DISTANCE

        if best_score.nil? || score < best_score
          best = [entity, origin, axes, ext, [px, py, pz]]
          best_score = score
        end
      end

      return [nil, :free, free_transform(point)] unless best

      entity, origin, axes, ext, coords = best
      xmin, xmax, ymin, ymax, zmin, zmax = ext
      px, py, pz = coords
      width = [xmax - xmin, 0.001].max
      depth = [ymax - ymin, 0.001].max

      central_x = px >= xmin + width * 0.25 && px <= xmax - width * 0.25
      central_y = py >= ymin + depth * 0.25 && py <= ymax - depth * 0.25
      inside_z = pz >= zmin - SMART_SNAP_DISTANCE && pz <= zmax + SMART_SNAP_DISTANCE

      # السناب على جانبي العرض فقط، مع فحص الجانب المشغول.
      left_distance  = (px - xmin).abs
      right_distance = (px - xmax).abs
      preferred = left_distance <= right_distance ? :snap_x_min : :snap_x_max
      alternate = preferred == :snap_x_min ? :snap_x_max : :snap_x_min

      preferred_occupied = snap_side_occupied?(entity, preferred, origin, axes, ext)
      alternate_occupied = snap_side_occupied?(entity, alternate, origin, axes, ext)

      mode = if !preferred_occupied
        preferred
      elsif !alternate_occupied
        alternate
      else
        # لو الجانبان مشغولان لا نفرض سناب فوق وحدة موجودة.
        return [nil, :free, free_transform(point)]
      end

      [entity, mode, snapped_transform(origin, axes, ext, mode)]
    rescue
      [nil, :free, free_transform(point)]
    end

    def ranges_overlap_amount(a_min, a_max, b_min, b_max)
      [a_max, b_max].min - [a_min, b_min].max
    end

    def snap_side_occupied?(target, mode, target_origin, axes, target_ext)
      txmin, txmax, tymin, tymax, tzmin, tzmax = target_ext
      target_depth = [tymax - tymin, 0.001].max
      target_height = [tzmax - tzmin, 0.001].max
      touch_tolerance = 3.cm.to_f

      candidate_entities.any? do |other|
        next false if other == target || other == @instance

        other_ext = extents_in_axes(other, target_origin, axes)
        next false unless other_ext && other_ext.all?

        oxmin, oxmax, oymin, oymax, ozmin, ozmax = other_ext
        y_overlap = ranges_overlap_amount(tymin, tymax, oymin, oymax)
        z_overlap = ranges_overlap_amount(tzmin, tzmax, ozmin, ozmax)

        # لا نعتبر الوحدة جارًا إلا لو تشترك فعليًا في أغلب العمق والارتفاع.
        next false if y_overlap < target_depth * 0.35
        next false if z_overlap < target_height * 0.35

        gap = if mode == :snap_x_min
          (txmin - oxmax).abs
        else
          (oxmin - txmax).abs
        end

        gap <= touch_tolerance
      end
    rescue
      false
    end

    def definition_bounds_values
      b = @definition.bounds
      [b.min.x, b.max.x, b.min.y, b.max.y, b.min.z, b.max.z]
    end

    def axes_transform(origin, axes)
      Geom::Transformation.axes(origin, axes[0], axes[1], axes[2])
    end

    def origin_from_local_min(world_corner, axes, local_x, local_y, local_z)
      world_corner.offset(axes[0], -local_x).offset(axes[1], -local_y).offset(axes[2], -local_z)
    end

    def free_transform(point)
      Geom::Transformation.translation(point)
    end

    def snapped_transform(target_origin, axes, ext, mode)
      xmin, xmax, ymin, _ymax, zmin, _zmax = ext
      lxmin, lxmax, lymin, _lymax, lzmin, _lzmax = definition_bounds_values

      wx = mode == :snap_x_min ? xmin : xmax
      local_x = mode == :snap_x_min ? lxmax : lxmin

      corner = target_origin.offset(axes[0], wx).offset(axes[1], ymin).offset(axes[2], zmin)
      new_origin = origin_from_local_min(corner, axes, local_x, lymin, lzmin)
      axes_transform(new_origin, axes)
    end

    def replacement_preview_transform(target_origin, axes, ext)
      xmin, xmax, ymin, ymax, zmin, _zmax = ext
      lxmin, lxmax, lymin, lymax, lzmin, _lzmax = definition_bounds_values

      target_cx = (xmin + xmax) * 0.5
      target_cy = (ymin + ymax) * 0.5
      local_cx = (lxmin + lxmax) * 0.5
      local_cy = (lymin + lymax) * 0.5

      desired = target_origin.offset(axes[0], target_cx).offset(axes[1], target_cy).offset(axes[2], zmin)
      new_origin = desired.offset(axes[0], -local_cx).offset(axes[1], -local_cy).offset(axes[2], -lzmin)
      axes_transform(new_origin, axes)
    end

    # ===== منطق الاستبدال بدون Scale أو Stretch =====

    def dc_engine
      return nil unless defined?($dc_observers) && $dc_observers
      $dc_observers.get_latest_class
    rescue
      nil
    end

    def normalize_ar(text)
      s = text.to_s.gsub(/<[^>]*>/, '').strip
      s = s.tr('أإآٱ', 'اااا')
      s = s.tr('ةى', 'هي')
      s = s.gsub(/[ًٌٍَُِّْـ]/, '')
      s.gsub(/\s+/, '').downcase
    end

    def dc_keys_from_definition(ent)
      dict = ent.definition.attribute_dictionary('dynamic_attributes', false)
      return [] unless dict

      keys = []
      dict.each_pair do |key, _value|
        key = key.to_s
        next unless key.start_with?('_') && key.end_with?('_access')
        keys << key.sub(/^_/, '').sub(/_access$/, '')
      end
      keys.uniq
    rescue
      []
    end

    def dimension_attr(ent, dimension, d)
      dc_keys_from_definition(ent).each do |key|
        label = begin
          d.get_attribute_formlabel(ent, key).to_s
        rescue
          key.to_s
        end

        n = normalize_ar(label)
        next if n.include?('درج')
        chassis = n.include?('شاسي') || n.include?('شاسه')
        next unless chassis

        matched =
          case dimension
          when :width
            n.include?('عرض')
          when :depth
            n.include?('عمق')
          when :height
            n.include?('ارتفاع') && !n.include?('رجل') && !n.include?('رجول') && !n.include?('ارجل')
          else
            false
          end

        return { key: key } if matched
      end
      nil
    rescue
      nil
    end

    def dimension_attrs(ent, d)
      {
        width: dimension_attr(ent, :width, d),
        depth: dimension_attr(ent, :depth, d),
        height: dimension_attr(ent, :height, d)
      }
    end

    def read_dc_value(d, ent, attr)
      d.get_attribute_value(ent, attr[:key].to_s).to_f
    rescue
      ent.get_attribute('dynamic_attributes', attr[:key].to_s, 0.0).to_f
    end

    def apply_dc_value(d, ent, key, value)
      formula_key = "_#{key}_formula"
      begin
        ent.delete_attribute('dynamic_attributes', formula_key)
      rescue
      end

      begin
        d.set_attribute(ent, key, value)
      rescue
        ent.set_attribute('dynamic_attributes', key, value)
      end
    end

    def rigid_slot_snapshot(ent)
      tr = ent.transformation
      xaxis = normalized_axis(tr.xaxis)
      yaxis = normalized_axis(tr.yaxis)
      zaxis = normalized_axis(tr.zaxis)
      return nil unless xaxis && yaxis && zaxis

      { origin: tr.origin.clone, xaxis: xaxis, yaxis: yaxis, zaxis: zaxis }
    rescue
      nil
    end

    def place_in_rigid_slot(ent, slot)
      current = rigid_slot_snapshot(ent)
      return false unless current && slot

      current_rigid = Geom::Transformation.axes(
        current[:origin], current[:xaxis], current[:yaxis], current[:zaxis]
      )
      target_rigid = Geom::Transformation.axes(
        slot[:origin], slot[:xaxis], slot[:yaxis], slot[:zaxis]
      )

      ent.transform!(target_rigid * current_rigid.inverse)
      true
    rescue
      false
    end

    def replace_without_scale!(new_unit, old_unit)
      raise 'الوحدة الجديدة غير صالحة.' unless new_unit && new_unit.valid?
      raise 'الوحدة القديمة غير صالحة.' unless old_unit && old_unit.valid?
      raise 'الاستبدال يحتاج وحدات Component.' unless old_unit.is_a?(Sketchup::ComponentInstance)

      d = dc_engine
      raise 'Dynamic Components غير محمل.' unless d

      old_attrs = dimension_attrs(old_unit, d)
      new_attrs = dimension_attrs(new_unit, d)
      dimensions = [:width, :depth, :height]

      missing = dimensions.select { |dim| old_attrs[dim].nil? || new_attrs[dim].nil? }
      unless missing.empty?
        names = { width: 'العرض', depth: 'العمق', height: 'الارتفاع' }
        raise "تعذر العثور على خصائص المقاسات: #{missing.map { |x| names[x] }.join('، ')}"
      end

      values = {}
      dimensions.each do |dim|
        values[dim] = read_dc_value(d, old_unit, old_attrs[dim])
      end

      slot = rigid_slot_snapshot(old_unit)
      raise 'تعذر قراءة مكان أو اتجاه الوحدة القديمة.' unless slot

      model = Sketchup.active_model
      model.start_operation('مكتبة محمد عادل - استبدال وحدة', true)

      forced = {}
      dimensions.each do |dim|
        key = new_attrs[dim][:key].to_s
        value = values[dim]
        forced[key] = value
        apply_dc_value(d, new_unit, key, value)
      end

      # نفس دورة التبديل المستقرة: Forced Config -> Formulas -> Redraw -> Last Sizes.
      forced.each { |key, value| d.set_forced_config_value(new_unit, key, value) }
      d.run_all_formulas(new_unit)
      d.redraw(new_unit, false, false)
      d.update_last_sizes(new_unit)

      d.clear_forced_config_values(new_unit)
      d.run_all_formulas(new_unit)
      d.redraw(new_unit, false, false)
      d.update_last_sizes(new_unit)

      # بعد آخر Redraw ننقل الوحدة حركة صلبة فقط إلى Slot القديمة.
      raise 'تعذر وضع الوحدة الجديدة في مكان القديمة.' unless place_in_rigid_slot(new_unit, slot)

      old_unit.erase!

      begin
        d.refresh_dialogs
        d.refresh_configure_dialog
      rescue
      end

      model.commit_operation
      model.active_view.invalidate
      true
    rescue => e
      begin
        d.clear_forced_config_values(new_unit) if d && new_unit
      rescue
      end
      begin
        model.abort_operation if model
      rescue
      end
      raise e
    end
  end

  # ==================== Placement Window Focus ====================
  # نافذة الأوبشن HtmlDialog قد تظل صاحبة الـ Keyboard Focus بعد إدراج الوحدة.
  # قبل بدء إدراج جديد نقفل نافذة الأوبشن الحالية ونرجع التركيز لنافذة SketchUp،
  # ثم تُفتح نافذة الأوبشن من جديد تلقائياً بعد تثبيت الوحدة الجديدة.
  def self.close_options_dialog_before_placement
    mod = options_protected_module
    return true unless mod

    begin
      dlg = mod.instance_variable_get(:@dlg)
      if dlg
        dlg.close rescue nil
        mod.instance_variable_set(:@dlg, nil) rescue nil
      end
    rescue
    end

    # دعم أي نسخة من أداة الأوبشن توفر دالة إغلاق عامة.
    [:close, :hide, :close_dialog, :hide_dialog].each do |method_name|
      begin
        mod.send(method_name) if mod.respond_to?(method_name)
      rescue
      end
    end

    true
  rescue
    true
  end

  def self.focus_sketchup_for_placement
    begin
      Sketchup.focus if Sketchup.respond_to?(:focus)
    rescue
    end

    # نكرر التركيز بعد دورة واجهة قصيرة، لأن إغلاق HtmlDialog قد يؤخر
    # إعادة الـFocus لجزء الرسم في بعض إصدارات SketchUp/CEF.
    UI.start_timer(0.01, false) do
      begin
        Sketchup.focus if Sketchup.respond_to?(:focus)
      rescue
      end
    end

    true
  rescue
    true
  end

  def self.activate_smart_unit_placement(definition, comp_data = nil)
    close_options_dialog_before_placement
    focus_sketchup_for_placement

    Sketchup.active_model.select_tool(SmartUnitPlacementTool.new(definition, comp_data))

    # ضمان أن أداة الرسم نفسها هي المستقبلة للكيبورد بعد تفعيلها.
    UI.start_timer(0.02, false) { focus_sketchup_for_placement }
    true
  rescue => e
    restore_library_after_placement
    UI.messagebox("❌ فشل تشغيل الإدراج الذكي:\n#{e.message}")
    false
  end

end

# توافق كامل مع ملفات الدريسنج المستقيمة والزاوية
MHDESIGN = DolaSmartLibraryPlugin unless Object.const_defined?(:MHDESIGN)