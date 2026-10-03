require 'sketchup.rb'
require 'json'
require 'net/http'
require 'uri'
require 'digest'
require 'openssl'

module DolaSmartLibraryPlugin

  TELEGRAM_BOT_TOKEN = "8723544635:AAFFlQHvvRLxxzyozFv6F6LJy6pdcrP69Xw"
  TELEGRAM_CHAT_ID   = "8206224176"

  CURRENT_DIR = File.dirname(__FILE__)
  OFFLINE_DIR = File.join(CURRENT_DIR, 'doula_offline_cache')
  GLB_DIR     = File.join(OFFLINE_DIR, 'glb')

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
      File.join(GLB_DIR, decoded_filename)
    else
      File.join(OFFLINE_DIR, decoded_filename)
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
          [skp_url, glb_url].each do |url|
            next if url.nil? || url.to_s.empty?
            local_path = getLocalFilePath(url)
            File.delete(local_path) if local_path && File.exist?(local_path) rescue nil

            cache_buster_url = url.to_s.include?('?') ? "#{url}&t=#{Time.now.to_i}" : "#{url}?t=#{Time.now.to_i}"
            ok = download_and_save_file_direct(cache_buster_url, local_path)
            success = false unless ok
          end
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
      @download_mutex = Mutex.new
      
      @sync_state = { 
        :phase => :scanning,
        :scan_total => 0,
        :scan_current => 0,
        :dl_total => 0, 
        :dl_done => 0, 
        :failed => [], 
        :finished => false,
        :current_item_name => ""
      }

      Thread.new do
        begin
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
              json_url = URI("https://raw.githubusercontent.com/dolaga10-lgtm/dola-library/refs/heads/main/components.json?nocache=#{Time.now.to_i}")
              response = Net::HTTP.get(json_url)
              data = JSON.parse(response)
              raw_items = data['components'] || []
            rescue => e
              puts "Error fetching components online: #{e.message}"
            end
          end

          targets_to_check = []

          raw_items.each do |item|
            if item.is_a?(Hash)
              comp_name = item['name']
              
              skp_url = item['skp'] || item['skp_url'] || item['url']
              if skp_url.nil? && comp_name
                encoded = URI.encode_www_form_component(comp_name).gsub('+', '%20')
                skp_url = "https://raw.githubusercontent.com/dolaga10-lgtm/dola-library/refs/heads/main/#{encoded}.skp"
              end
              targets_to_check << { 'name' => "#{comp_name || 'وحدة'}.skp", 'url' => skp_url } if skp_url

              glb_url = item['glb'] || item['glb_url'] || item['image'] || item['img_url']
              if glb_url.nil? && comp_name
                encoded = URI.encode_www_form_component(comp_name).gsub('+', '%20')
                glb_url = "https://raw.githubusercontent.com/dolaga10-lgtm/dola-library/refs/heads/main/glb/#{encoded}.glb"
              end
              targets_to_check << { 'name' => "#{comp_name || 'موديل'}.glb", 'url' => glb_url } if glb_url
            elsif item.is_a?(String) && !item.empty?
              targets_to_check << { 'name' => File.basename(item.split('?').first), 'url' => item }
            end
          end

          unique_targets = {}
          targets_to_check.each do |target|
            path = getLocalFilePath(target['url'])
            if path && !unique_targets.key?(path)
              unique_targets[path] = target
            end
          end

          @download_mutex.synchronize do
            @sync_state[:phase] = :scanning
            @sync_state[:scan_total] = unique_targets.size
          end

          items_to_download = []
          scan_counter = 0

          unique_targets.each do |local_path, target|
            scan_counter += 1
            item_name = target['name']

            @download_mutex.synchronize do
              @sync_state[:scan_current] = scan_counter
              @sync_state[:current_item_name] = item_name
            end

            if !File.exist?(local_path) || File.size(local_path) == 0
              items_to_download << target
            end

            sleep(0.008)
          end

          @download_mutex.synchronize do
            @sync_state[:phase] = :downloading
            @sync_state[:dl_total] = items_to_download.size
            @sync_state[:current_item_name] = ""
          end

          if items_to_download.empty?
            @download_mutex.synchronize { @sync_state[:finished] = true }
          else
            workers = Array.new(3) do
              Thread.new do
                loop do
                  target = nil
                  @download_mutex.synchronize { target = items_to_download.pop }
                  break unless target

                  url = target['url']
                  item_name = target['name']

                  @download_mutex.synchronize { @sync_state[:current_item_name] = item_name }
                  
                  ok = download_and_force_replace(url)
                  
                  @download_mutex.synchronize do
                    @sync_state[:dl_done] += 1
                    @sync_state[:failed] << url unless ok
                  end
                end
              end
            end
            workers.each(&:join)
            @download_mutex.synchronize { @sync_state[:finished] = true }
          end
        rescue => e
          puts "Fatal Error in Sync Thread: #{e.message}"
          @download_mutex.synchronize { @sync_state[:finished] = true }
        end
      end

      last_scan_reported = -1
      last_dl_reported   = -1
      
      timer_id = UI.start_timer(0.05, true) do
        state = nil
        @download_mutex.synchronize { state = @sync_state.dup }

        if @dlg && @dlg.visible?
          if state[:phase] == :scanning
            if state[:scan_current] != last_scan_reported
              last_scan_reported = state[:scan_current]
              percent = state[:scan_total] > 0 ? ((state[:scan_current].to_f / state[:scan_total]) * 100).round : 0
              
              file_title = state[:current_item_name].to_s
              status_label = "🔍 جاري فحص: #{file_title}"

              js_title  = JSON.generate(file_title)
              js_label  = JSON.generate(status_label)

              script = <<~JS
                if (typeof onScanProgress === 'function') onScanProgress(#{state[:scan_current]}, #{state[:scan_total]}, #{percent}, #{js_title});
                if (typeof updateOfflineProgress === 'function') updateOfflineProgress(#{percent}, #{state[:scan_current]}, #{state[:scan_total]}, #{js_label});
              JS
              @dlg.execute_script(script)
            end

          elsif state[:phase] == :downloading
            if state[:dl_done] != last_dl_reported || state[:dl_total] > 0
              last_dl_reported = state[:dl_done]
              percent = state[:dl_total] > 0 ? ((state[:dl_done].to_f / state[:dl_total]) * 100).round : 100
              
              file_title = state[:current_item_name].to_s
              status_label = file_title.empty? ? "جاري التحديث..." : "⬇️ جاري تنزيل: #{file_title}"

              js_title  = JSON.generate(file_title)
              js_label  = JSON.generate(status_label)

              script = <<~JS
                if (typeof onDownloadProgress === 'function') onDownloadProgress(#{state[:dl_done]}, #{state[:dl_total]}, #{percent}, #{js_title});
                if (typeof updateOfflineProgress === 'function') updateOfflineProgress(#{percent}, #{state[:dl_done]}, #{state[:dl_total]}, #{js_label});
              JS
              @dlg.execute_script(script)
            end
          end
        end

        if state[:finished]
          UI.stop_timer(timer_id)
          if @dlg && @dlg.visible?
            failed_count = state[:failed].size
            if state[:dl_total] == 0
              script = <<~JS
                if (typeof updateOfflineProgress === 'function') updateOfflineProgress(100, 0, 0, '✅ جميع الملفات محملة ومحدثة بالكامل');
                if (typeof onDownloadComplete === 'function') onDownloadComplete(0);
                if (typeof onOfflineDownloadComplete === 'function') onOfflineDownloadComplete(true, 0, 'جميع الملفات محملة مسبقاً ومحدثة');
              JS
            else
              script = <<~JS
                if (typeof onDownloadComplete === 'function') onDownloadComplete(#{failed_count});
                if (typeof onOfflineDownloadComplete === 'function') onOfflineDownloadComplete(#{failed_count == 0}, #{state[:dl_total]}, 'تم التحديث بنجاح');
              JS
            end
            @dlg.execute_script(script)
          end
        end
      end
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
    local_path = getLocalFilePath(url)
    cache_buster_url = url.to_s.include?('?') ? "#{url}&t=#{Time.now.to_i}" : "#{url}?t=#{Time.now.to_i}"
    download_and_save_file_direct(cache_buster_url, local_path)
  end

  def self.import_component_from_source(url)
    local_path = getLocalFilePath(url)
    target_to_use = nil

    if local_path && File.exist?(local_path) && File.size(local_path) > 0
      target_to_use = local_path
    else
      temp_file = File.join(Sketchup.temp_dir, "dola_temp_model_#{Time.now.to_i}.skp")
      if download_and_save_file_direct(url, temp_file)
        target_to_use = temp_file
      else
        UI.messagebox("عفواً، يتعذر الوصول للملف أونلاين وهو غير مخزن أوفلاين.")
        return
      end
    end

    if target_to_use && File.exist?(target_to_use)
      begin
        model = Sketchup.active_model
        definition = model.definitions.load(target_to_use)
        model.place_component(definition) if definition
      rescue => e
        if target_to_use == local_path
          File.delete(local_path) rescue nil
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

  def self.download_and_save_file_direct(url, save_path, redirect_limit = 5)
    return false if redirect_limit <= 0 || url.nil? || url.to_s.empty? || save_path.nil?
    uri = parse_url(url)
    return false unless uri && uri.host

    begin
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == 'https')
      http.verify_mode = OpenSSL::SSL::VERIFY_NONE
      http.open_timeout = 10
      http.read_timeout = 10

      request = Net::HTTP::Get.new(uri.request_uri)
      request['User-Agent'] = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'
      request['Connection'] = 'keep-alive'

      http.request(request) do |response|
        if response.is_a?(Net::HTTPRedirection) && response['location']
          return download_and_save_file_direct(URI.join(uri.to_s, response['location']).to_s, save_path, redirect_limit - 1)
        end

        if response.is_a?(Net::HTTPSuccess)
          File.open(save_path, "wb") do |f|
            f.binmode
            response.read_body { |chunk| f.write(chunk) }
          end
          return File.exist?(save_path) && File.size(save_path) > 0
        end
      end
    rescue => e
      puts "Download Exception for #{url}: #{e.message}"
    end
    false
  end

end