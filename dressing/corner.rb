# encoding: UTF-8

require 'sketchup.rb'
require 'json'
require 'securerandom'
require 'cgi'
require 'net/http'
require 'uri'
require 'tmpdir'
require 'fileutils'
require 'base64'
require 'digest'
require 'openssl'
require 'tempfile'

# توافق بين إصدارات SketchUp:
# Sketchup::Entities يدعم length/count لكنه لا يدعم empty? في بعض الإصدارات.
# إضافة empty? هنا آمنة وتمنع الخطأ حتى لو كان Method قديم ما زال محملاً
# من نسخة سابقة أثناء إعادة تحميل الأداة داخل نفس جلسة SketchUp.
unless Sketchup::Entities.method_defined?(:empty?)
  class Sketchup::Entities
    def empty?
      length == 0
    end
  end
end

module MHDESIGN
  module DressingCornerDesigner
    extend self

    # أوقف أي مؤقت متابعة باقٍ من نسخة سابقة عند إعادة تحميل الملف؛ كان
    # يسبب Redraw متكررًا ورسائل SketchUp المتراكمة.
    if instance_variable_defined?(:@drawer_slide_monitor_timer) && @drawer_slide_monitor_timer
      UI.stop_timer(@drawer_slide_monitor_timer) rescue nil
      @drawer_slide_monitor_timer = nil
    end

    if instance_variable_defined?(:@hinge_motion_monitor_timer) && @hinge_motion_monitor_timer
      UI.stop_timer(@hinge_motion_monitor_timer) rescue nil
      @hinge_motion_monitor_timer = nil
    end

    TITLE = 'مكتبة محمد عادل - تصميم دريسنج زاوية'.freeze
    PREF_KEY = 'MHDESIGN_DRESSING_DESIGNER_V2'.freeze
    VERSION = '10.56.54'.freeze
    LOGO_URL = ''.freeze # تم إيقاف الصورة بناءً على طلبك
    PART_SUFFIX = 'BASE_UNIT_1'.freeze
    BADGE_ARABIC = {
      'MAIN_CARCASS'=>'الشاسيه الرئيسي','PARTITION'=>'قاطع','SHELF'=>'رف',
      'DRAWER_CHASSIS'=>'شاسيه الأدراج','DRAWER_SIDE'=>'جنب درج','DRAWER_BOX'=>'صندوق درج',
      'DRAWER_BOTTOM'=>'قاعدة درج','DRAWER_FRONT'=>'وش درج','BACK_PANEL'=>'ضهر',
      'DOOR_PANEL'=>'ضلفة','SIDE_FILLER'=>'سدّة','FILLER_RETURN'=>'فيلر جانبي','JOINERY_PART'=>'قطعة تجميع',
      'BACK_GROOVE'=>'مفحار ضهر','DRAWER_BOTTOM_GROOVE'=>'مفحار قاعدة درج','WOOD_PLINTH'=>'سوكلو خشب','TOP_CORNICE'=>'كورنيشة علوية','FRONT'=>'أمامي',
      'BACK'=>'خلفي','HARDWARE'=>'إكسسوار','ACCESSORY'=>'إكسسوار',
      'BUTTERFLY_CORNER'=>'زاوية فراشة','SHELF_SUPPORT'=>'حامل رف',
      'ELITA_MINIFIX'=>'إليتا','HINGE'=>'مفصلة','CLOTH_HOLDER'=>'ماسورة شماعة',
      'PUSH_UP_LIFT'=>'باكم ضلفة قلاب',
      'DRAWER_SLIDE_PAIR'=>'طقم مجرى درج جانبي',
      'DRAWER_ORGANIZER'=>'تقسيمات درج',
      'WALL_RELIEF'=>'خلعة حائط','REDUCED_DEPTH'=>'عمق مخفّض','FORWARD_BACK'=>'ضهر متقدم'
    }.freeze
    INTERIOR_MARK = 'MHD_DRESSING_INTERIORS'.freeze
    DRESSING_SYSTEM = 'MHDESIGN_DRESSING'.freeze
    CORNER_UNIT_TYPE = 'corner'.freeze
    CORNER_UNIT_SIGNATURE = 'MHD_DRESSING_CORNER_V1'.freeze
    DRESSING_SKP_BASE_URL = 'https://mhdesign-eg.com/SKETCHUP022/skp/dressing'.freeze
    BUTTERFLY_SKP_URL = "#{DRESSING_SKP_BASE_URL}/Corner%20Brace%20Butterfly.skp".freeze
    SHELF_SUPPORT_SKP_URL = "#{DRESSING_SKP_BASE_URL}/Shelf%20support.skp".freeze
    ELITA_SKP_URL = "#{DRESSING_SKP_BASE_URL}/minifix.skp".freeze
    CLOTH_HOLDER_SKP_URL = "#{DRESSING_SKP_BASE_URL}/cloth%20holder.skp".freeze
    PUSH_UP_LIFT_SKP_URL = "#{DRESSING_SKP_BASE_URL}/push%20up%20lift.skp".freeze
    DRAWER_SLIDE_RIGHT_SKP_URL = "#{DRESSING_SKP_BASE_URL}/Drawer%20slides%20right.skp".freeze
    DRAWER_SLIDE_LEFT_SKP_URL = "#{DRESSING_SKP_BASE_URL}/Drawer%20slides%20lift.skp".freeze
    HINGE_SKP_FILES = {
      ['left', 'half'] => 'LIFT HING HAVE.skp',
      ['left', 'straight'] => 'LIFT HING STRET.skp',
      ['right', 'half'] => 'RIGHT HING HAVE.skp',
      ['right', 'straight'] => 'RIGHT HING STRET.skp'
    }.freeze
    HINGE_180_SKP_FILES = {
      'left' => 'LIFT HING 180.skp',
      'right' => 'RIGHT HING 180.skp'
    }.freeze
    CORNER_HINGE_180_SKP_FILES = {
      'left' => 'LIFT HING 180 co.skp',
      'right' => 'RIGHT HING 180 co.skp'
    }.freeze
    HINGE_KNEE_SKP_FILES = {
      'left' => 'LIFT HING total.skp',
      'right' => 'RIGHT HING total.skp'
    }.freeze

    class HingeDoorMotionObserver < Sketchup::EntityObserver
      def onChangeEntity(entity)
        UI.start_timer(0, false) do
          MHDESIGN::DressingCornerDesigner.sync_hinge_accessories(entity) if entity && entity.valid?
        end
      rescue
        nil
      end
    end

    class DrawerSlideMotionObserver < Sketchup::EntityObserver
      def onChangeEntity(entity)
        UI.start_timer(0, false) do
          MHDESIGN::DressingCornerDesigner.sync_drawer_slide(entity) if entity && entity.valid?
        end
      rescue
        nil
      end
    end

    class BoardLimitError < StandardError
      attr_reader :violations

      def initialize(violations)
        @violations = violations
        super('توجد قطع تتجاوز مقاسات الألواح المحددة.')
      end
    end

    def corner_unit_signed?(item)
      return false unless item && item.valid?
      owners = [item, item.definition].compact
      system = owners.map { |o| o.get_attribute('MHD_DRESSING', 'SYSTEM', nil) }.compact.first
      unit_type = owners.map { |o| o.get_attribute('MHD_DRESSING', 'UNIT_TYPE', nil) }.compact.first
      signature = owners.map { |o| o.get_attribute('MHD_DRESSING', 'UNIT_SIGNATURE', nil) }.compact.first
      system.to_s == DRESSING_SYSTEM &&
        unit_type.to_s == CORNER_UNIT_TYPE &&
        signature.to_s == CORNER_UNIT_SIGNATURE
    rescue
      false
    end

    def sign_corner_unit!(item)
      return false unless item && item.valid?
      [item, item.definition].compact.each do |owner|
        owner.set_attribute('MHD_DRESSING', 'SYSTEM', DRESSING_SYSTEM)
        owner.set_attribute('MHD_DRESSING', 'UNIT_TYPE', CORNER_UNIT_TYPE)
        owner.set_attribute('MHD_DRESSING', 'UNIT_SIGNATURE', CORNER_UNIT_SIGNATURE)
        owner.set_attribute('MHD_DRESSING', 'FUNCTION_ROLE', 'wardrobe_root')
      end
      true
    rescue
      false
    end

    def selected_wardrobe
      Sketchup.active_model.selection.grep(Sketchup::ComponentInstance).find { |item| corner_unit_signed?(item) }
    end

    def dc_value(item, key, fallback)
      value = item.get_attribute('dynamic_attributes', key)
      value = item.definition.get_attribute('dynamic_attributes', key) if value.nil?
      value.nil? ? fallback : value
    end

    def dc_engine
      return nil unless defined?($dc_observers) && $dc_observers
      $dc_observers.get_latest_class
    rescue
      nil
    end

    # ============================================================
    # كاش إكسسوارات الدريسنج — مكتبة محمد عادل
    # ============================================================
    DRESSING_UNITS_CACHE_ROOT_DIR = 'A9A6D99_5957844_88980'.freeze
    DRESSING_CACHE_SECRET_SALT = 'MHDESIGN_REMOTE_CACHE_V1'.freeze
    DRESSING_CACHE_HMAC_SALT   = 'MHDESIGN_REMOTE_CACHE_HMAC_V1'.freeze
    DRESSING_ASSET_ALLOWED_HOSTS = ['mhdesign-eg.com', 'www.mhdesign-eg.com'].freeze

    def dressing_units_cache_root_dir
      dir = File.join(Dir.tmpdir, DRESSING_UNITS_CACHE_ROOT_DIR)
      FileUtils.mkdir_p(dir) unless File.directory?(dir)
      dir
    rescue
      File.join(Dir.tmpdir, DRESSING_UNITS_CACHE_ROOT_DIR)
    end

    def dressing_cache_device_id
      id = Sketchup.read_default('MHDESIGN', 'device_id').to_s.strip
      if id.empty?
        id = SecureRandom.uuid
        Sketchup.write_default('MHDESIGN', 'device_id', id)
      end
      id
    rescue
      ''
    end

    def dressing_cache_binding_seed
      [
        'MHDESIGN',
        dressing_cache_device_id.to_s,
        (Sketchup.read_default('MHDESIGN', 'email') || '').to_s.strip.downcase,
        (Sketchup.read_default('MHDESIGN', 'license') || '').to_s,
        DRESSING_CACHE_SECRET_SALT
      ].join('|')
    rescue
      "MHDESIGN|#{DRESSING_CACHE_SECRET_SALT}"
    end

    def dressing_cache_crypto_key
      Digest::SHA256.digest(dressing_cache_binding_seed)
    rescue
      Digest::SHA256.digest("MHDESIGN|#{DRESSING_CACHE_SECRET_SALT}")
    end

    def dressing_cache_hmac_key
      Digest::SHA256.digest("#{dressing_cache_binding_seed}|#{DRESSING_CACHE_HMAC_SALT}")
    rescue
      Digest::SHA256.digest("MHDESIGN|#{DRESSING_CACHE_HMAC_SALT}")
    end

    def dressing_cache_hmac_for(version, iv_b64, data_b64)
      OpenSSL::HMAC.hexdigest(
        'SHA256', dressing_cache_hmac_key,
        [version.to_i, iv_b64.to_s, data_b64.to_s].join('|')
      )
    rescue
      ''
    end

    def encrypt_dressing_cache_bytes(raw_bytes)
      cipher = OpenSSL::Cipher.new('AES-256-CBC')
      cipher.encrypt
      cipher.key = dressing_cache_crypto_key
      iv = cipher.random_iv
      cipher.iv = iv
      encrypted = cipher.update(raw_bytes.to_s.b) + cipher.final

      iv_b64 = Base64.strict_encode64(iv)
      data_b64 = Base64.strict_encode64(encrypted)
      version = 1
      JSON.generate(
        'v'=>version,
        'iv'=>iv_b64,
        'data'=>data_b64,
        'sig'=>dressing_cache_hmac_for(version, iv_b64, data_b64)
      )
    end

    def decrypt_dressing_cache_bytes(encoded_text)
      parsed = JSON.parse(encoded_text.to_s) rescue nil
      raise 'Encrypted cache is invalid' unless parsed.is_a?(Hash)

      version = parsed['v'].to_i
      iv_b64 = parsed['iv'].to_s
      data_b64 = parsed['data'].to_s
      sig = parsed['sig'].to_s
      raise 'Encrypted cache is invalid' if version <= 0 || iv_b64.empty? || data_b64.empty? || sig.empty?

      expected = dressing_cache_hmac_for(version, iv_b64, data_b64)
      raise 'Cache signature mismatch' if expected.empty? || sig != expected

      iv = Base64.decode64(iv_b64)
      encrypted = Base64.decode64(data_b64)
      raise 'Encrypted cache is invalid' if iv.bytesize != 16 || encrypted.empty?

      cipher = OpenSSL::Cipher.new('AES-256-CBC')
      cipher.decrypt
      cipher.key = dressing_cache_crypto_key
      cipher.iv = iv
      (cipher.update(encrypted) + cipher.final).b
    end

    def normalize_dressing_asset_url(url)
      uri = URI.parse(url.to_s.strip)
      raise 'رابط الإكسسوار غير صالح.' unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)
      host = uri.host.to_s.downcase
      raise 'مصدر الإكسسوار غير مسموح.' unless DRESSING_ASSET_ALLOWED_HOSTS.include?(host)
      uri.fragment = nil
      uri
    end

    def dressing_asset_cache_file_for_url(url)
      uri = normalize_dressing_asset_url(url)
      hash = Digest::SHA256.hexdigest(uri.to_s)
      File.join(dressing_units_cache_root_dir, "skp_#{hash}.cache")
    end

    def write_dressing_asset_cache(url, raw_bytes)
      return nil if raw_bytes.nil? || raw_bytes.bytesize <= 100
      path = dressing_asset_cache_file_for_url(url)
      tmp = "#{path}.tmp_#{Process.pid}_#{rand(1_000_000)}"
      File.binwrite(tmp, encrypt_dressing_cache_bytes(raw_bytes))
      File.delete(path) if File.file?(path)
      File.rename(tmp, path)
      path
    rescue
      begin
        File.delete(tmp) if defined?(tmp) && tmp && File.file?(tmp)
      rescue
      end
      nil
    end

    def read_dressing_asset_cache(url)
      path = dressing_asset_cache_file_for_url(url)
      return nil unless File.file?(path) && File.size(path) > 0
      raw = decrypt_dressing_cache_bytes(File.binread(path))
      return nil unless raw && raw.bytesize > 100
      raw
    rescue
      begin
        File.delete(path) if defined?(path) && path && File.file?(path)
      rescue
      end
      nil
    end

    def fetch_dressing_asset_remote(url, filename)
      uri = normalize_dressing_asset_url(url)
      response = nil

      4.times do
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == 'https'
        http.open_timeout = 8
        http.read_timeout = 20
        response = http.get(uri.request_uri, {'User-Agent'=>'MohamedAdelLibrary-Dressing'})

        if response.is_a?(Net::HTTPRedirection)
          location = response['location'].to_s
          raise "تحويل غير صالح أثناء تحميل #{filename}" if location.empty?
          next_uri = URI.join(uri.to_s, location)
          uri = normalize_dressing_asset_url(next_uri.to_s)
          next
        end
        break
      end

      raise "تعذر تحميل ملف الإكسسوار: #{filename}" unless response.is_a?(Net::HTTPSuccess)
      body = response.body.to_s.b
      raise "ملف الإكسسوار فارغ: #{filename}" if body.bytesize <= 100
      body
    end

    def dressing_asset_bytes(url, filename, bundled_path = nil)
      cached = read_dressing_asset_cache(url)
      return cached if cached && cached.bytesize > 100

      if bundled_path && File.file?(bundled_path) && File.size(bundled_path) > 100
        raw = File.binread(bundled_path).b
        write_dressing_asset_cache(url, raw)
        return raw
      end

      raw = fetch_dressing_asset_remote(url, filename)
      write_dressing_asset_cache(url, raw)
      raw
    rescue => error
      fallback = read_dressing_asset_cache(url) rescue nil
      return fallback if fallback && fallback.bytesize > 100
      raise "تعذر تجهيز ملف الإكسسوار: #{filename} — #{error.message}"
    end

    def load_dressing_asset_definition(model, url, filename, bundled_path = nil)
      raw = dressing_asset_bytes(url, filename, bundled_path)
      tempfile = Tempfile.new(['mhdesign_dressing_asset', '.skp'])
      tempfile.binmode
      tempfile.write(raw)
      tempfile.flush
      tempfile.close
      definition = model.definitions.load(tempfile.path)
      raise "تعذر قراءة موديل الإكسسوار: #{filename}" unless definition
      definition
    ensure
      begin
        tempfile.close! if tempfile
      rescue
        begin
          File.delete(tempfile.path) if tempfile && File.file?(tempfile.path)
        rescue
        end
      end
    end

    def download_dressing_asset(url, filename, bundled_path = nil)
      raw = dressing_asset_bytes(url, filename, bundled_path)
      tempfile = Tempfile.new(['mhdesign_dressing_asset_compat', '.skp'])
      tempfile.binmode
      tempfile.write(raw)
      tempfile.flush
      tempfile.close
      path = tempfile.path
      @dressing_compat_tempfiles ||= []
      @dressing_compat_tempfiles << tempfile
      UI.start_timer(3.0, false) do
        begin
          tempfile.close! rescue nil
          @dressing_compat_tempfiles.delete(tempfile) if @dressing_compat_tempfiles
        rescue
        end
      end
      path
    end

    def butterfly_definition(model)
      cached = @butterfly_definitions && @butterfly_definitions[model.object_id]
      return cached if cached && cached.valid?
      bundled = File.join(File.dirname(__FILE__), 'Corner Brace Butterfly.skp')
      definition = load_dressing_asset_definition(model, BUTTERFLY_SKP_URL, 'Corner Brace Butterfly.skp', bundled)
      raise 'تعذر قراءة موديل زاوية الفراشة.' unless definition
      @butterfly_definitions ||= {}
      @butterfly_definitions[model.object_id] = definition
      definition
    end

    def shelf_support_definition(model)
      cached = @shelf_support_definitions && @shelf_support_definitions[model.object_id]
      return cached if cached && cached.valid?
      bundled = File.join(File.dirname(__FILE__), 'Shelf support.skp')
      definition = load_dressing_asset_definition(model, SHELF_SUPPORT_SKP_URL, 'Shelf support.skp', bundled)
      raise 'تعذر قراءة موديل حامل الرف.' unless definition
      @shelf_support_definitions ||= {}
      @shelf_support_definitions[model.object_id] = definition
      definition
    end

    def elita_definition(model)
      cached = @elita_definitions && @elita_definitions[model.object_id]
      return cached if cached && cached.valid?
      bundled = File.join(File.dirname(__FILE__), 'minifix.skp')
      definition = load_dressing_asset_definition(model, ELITA_SKP_URL, 'minifix.skp', bundled)
      raise 'تعذر قراءة موديل الأليتا.' unless definition
      @elita_definitions ||= {}
      @elita_definitions[model.object_id] = definition
      definition
    end

    def cloth_holder_definition(model)
      cached = @cloth_holder_definitions && @cloth_holder_definitions[model.object_id]
      return cached if cached && cached.valid?
      filename = 'cloth holder.skp'
      bundled = File.join(File.dirname(__FILE__), filename)
      definition = load_dressing_asset_definition(model, CLOTH_HOLDER_SKP_URL, filename, bundled)
      raise 'تعذر قراءة موديل ماسورة الشماعة.' unless definition
      claim_clean_definition_name(definition, 'إكسسوار ماسورة شماعة')
      definition.set_attribute('MHD_DRESSING', 'SOURCE_DEFINITION_NAME', 'إكسسوار ماسورة شماعة')
      set_part_badges(definition, ['HARDWARE','ACCESSORY','CLOTH_HOLDER'])
      definition.set_attribute('ladb_opencutlist', 'cumulable', 2)
      @cloth_holder_definitions ||= {}
      @cloth_holder_definitions[model.object_id] = definition
      definition
    end

    def push_up_lift_definition(model)
      cached = @push_up_lift_definitions && @push_up_lift_definitions[model.object_id]
      return cached if cached && cached.valid?

      filename = 'push up lift.skp'
      bundled = File.join(File.dirname(__FILE__), filename)
      source = load_dressing_asset_definition(model, PUSH_UP_LIFT_SKP_URL, filename, bundled)
      raise 'تعذر قراءة موديل باكم الضلفة القلاب.' unless source

      internal_name = '__MHD_PUSH_UP_LIFT_BAKED_V1'
      baked = model.definitions[internal_name] || model.definitions.add(internal_name)

      if baked.entities.length == 0
        placed = baked.entities.add_instance(source, Geom::Transformation.new)
        placed.explode
        flatten_accessory_entities(baked.entities)
      end

      clean_name = 'باكم ضلفة قلاب'
      claim_clean_definition_name(baked, clean_name)
      baked.set_attribute('MHD_DRESSING', 'SOURCE_DEFINITION_NAME', clean_name)
      set_part_badges(baked, ['HARDWARE','ACCESSORY','PUSH_UP_LIFT'])
      baked.set_attribute('ladb_opencutlist', 'cumulable', 2)

      @push_up_lift_definitions ||= {}
      @push_up_lift_definitions[model.object_id] = baked
      baked
    end

    def drawer_slide_right_definition(model)
      cached = @drawer_slide_right_definitions && @drawer_slide_right_definitions[model.object_id]
      return cached if cached && cached.valid?
      filename = 'Drawer slides right.skp'
      bundled = File.join(File.dirname(__FILE__), filename)
      definition = load_dressing_asset_definition(model, DRAWER_SLIDE_RIGHT_SKP_URL, filename, bundled)
      raise 'تعذر قراءة موديل مجرى الدرج الجانبي.' unless definition
      @drawer_slide_right_definitions ||= {}
      @drawer_slide_right_definitions[model.object_id] = definition
      definition
    end

    def drawer_slide_left_definition(model)
      cached = @drawer_slide_left_definitions && @drawer_slide_left_definitions[model.object_id]
      return cached if cached && cached.valid?
      filename = 'Drawer slides lift.skp'
      bundled = File.join(File.dirname(__FILE__), filename)
      definition = load_dressing_asset_definition(model, DRAWER_SLIDE_LEFT_SKP_URL, filename, bundled)
      raise 'تعذر قراءة موديل مجرى الدرج الشمال.' unless definition
      claim_clean_definition_name(definition, 'مجرى درج جانبي شمال')
      definition.set_attribute('MHD_DRESSING', 'SOURCE_DEFINITION_NAME', 'مجرى درج جانبي شمال')
      set_part_badges(definition, ['HARDWARE','ACCESSORY','DRAWER_SLIDE_LEFT'])
      definition.set_attribute('ladb_opencutlist', 'cumulable', 2)
      definition.set_attribute('ladb_opencutlist', 'instance_count_by_part', 1)
      @drawer_slide_left_definitions ||= {}
      @drawer_slide_left_definitions[model.object_id] = definition
      definition
    end

    def hinge_accessory_definition(model, direction, overlay)
      key = [direction.to_s, overlay.to_s]
      filename = HINGE_SKP_FILES[key]
      raise "نوع مفصلة غير معروف: #{key.join(' / ')}" unless filename
      cache_key = [model.object_id, key]
      cached = @hinge_accessory_definitions && @hinge_accessory_definitions[cache_key]
      return cached if cached && cached[0] && cached[0].valid?

      mirrored = false
      bundled = File.join(File.dirname(__FILE__), filename)
      url = "#{DRESSING_SKP_BASE_URL}/#{filename.gsub(' ', '%20')}"
      begin
        definition = load_dressing_asset_definition(model, url, filename, bundled)
      rescue
        raise unless key == ['right', 'half']
        fallback_name = HINGE_SKP_FILES[['left', 'half']]
        fallback_bundled = File.join(File.dirname(__FILE__), fallback_name)
        fallback_url = "#{DRESSING_SKP_BASE_URL}/#{fallback_name.gsub(' ', '%20')}"
        definition = load_dressing_asset_definition(model, fallback_url, fallback_name, fallback_bundled)
        mirrored = true
      end
      raise "تعذر قراءة موديل المفصلة: #{filename}" unless definition
      @hinge_accessory_definitions ||= {}
      @hinge_accessory_definitions[cache_key] = [definition, mirrored]
    end

    def hinge_180_accessory_definition(model, direction)
      side = direction.to_s == 'right' ? 'right' : 'left'
      filename = HINGE_180_SKP_FILES[side]
      raise "ملف مفصلة العقرب 180 غير معروف للاتجاه: #{side}" unless filename

      cache_key = [model.object_id, side]
      cached = @hinge_180_accessory_definitions && @hinge_180_accessory_definitions[cache_key]
      return cached if cached && cached.valid?

      bundled = File.join(File.dirname(__FILE__), filename)
      url = "#{DRESSING_SKP_BASE_URL}/#{filename.gsub(' ', '%20')}"
      definition = load_dressing_asset_definition(model, url, filename, bundled)
      raise "تعذر قراءة موديل مفصلة العقرب 180: #{filename}" unless definition

      clean_name = side == 'right' ? 'مفصلة عقرب 180 يمين' : 'مفصلة عقرب 180 شمال'
      claim_clean_definition_name(definition, clean_name)
      definition.set_attribute('MHD_DRESSING', 'SOURCE_DEFINITION_NAME', clean_name)
      set_part_badges(definition, ['HARDWARE','ACCESSORY','HINGE'])
      definition.set_attribute('ladb_opencutlist', 'cumulable', 2)

      @hinge_180_accessory_definitions ||= {}
      @hinge_180_accessory_definitions[cache_key] = definition
      definition
    end

    def corner_hinge_180_accessory_definition(model, direction)
      side = direction.to_s == 'right' ? 'right' : 'left'
      filename = CORNER_HINGE_180_SKP_FILES[side]
      raise "ملف مفصلة الركنة 180 غير معروف للاتجاه: #{side}" unless filename

      cache_key = [model.object_id, side]
      cached = @corner_hinge_180_accessory_definitions && @corner_hinge_180_accessory_definitions[cache_key]
      return cached if cached && cached.valid?

      bundled = File.join(File.dirname(__FILE__), filename)
      url = "#{DRESSING_SKP_BASE_URL}/#{filename.gsub(' ', '%20')}"
      definition = load_dressing_asset_definition(model, url, filename, bundled)
      raise "تعذر قراءة موديل مفصلة الركنة 180: #{filename}" unless definition

      clean_name = side == 'right' ? 'مفصلة عقرب 180 ركنة يمين' : 'مفصلة عقرب 180 ركنة شمال'
      claim_clean_definition_name(definition, clean_name)
      definition.set_attribute('MHD_DRESSING', 'SOURCE_DEFINITION_NAME', clean_name)
      definition.set_attribute('MHD_DRESSING', 'CORNER_HINGE', true)
      set_part_badges(definition, ['HARDWARE','ACCESSORY','HINGE'])
      definition.set_attribute('ladb_opencutlist', 'cumulable', 2)

      @corner_hinge_180_accessory_definitions ||= {}
      @corner_hinge_180_accessory_definitions[cache_key] = definition
      definition
    end

    def hinge_knee_accessory_definition(model, direction)
      side = direction.to_s == 'right' ? 'right' : 'left'
      filename = HINGE_KNEE_SKP_FILES[side]
      raise "ملف مفصلة الركبة غير معروف للاتجاه: #{side}" unless filename

      cache_key = [model.object_id, side]
      cached = @hinge_knee_accessory_definitions && @hinge_knee_accessory_definitions[cache_key]
      return cached if cached && cached.valid?

      bundled = File.join(File.dirname(__FILE__), filename)
      url = "#{DRESSING_SKP_BASE_URL}/#{filename.gsub(' ', '%20')}"
      definition = load_dressing_asset_definition(model, url, filename, bundled)
      raise "تعذر قراءة موديل مفصلة الركبة: #{filename}" unless definition

      clean_name = side == 'right' ? 'مفصلة ركبة يمين' : 'مفصلة ركبة شمال'
      claim_clean_definition_name(definition, clean_name)
      definition.set_attribute('MHD_DRESSING', 'SOURCE_DEFINITION_NAME', clean_name)
      set_part_badges(definition, ['HARDWARE','ACCESSORY','HINGE'])
      definition.set_attribute('ladb_opencutlist', 'cumulable', 2)

      @hinge_knee_accessory_definitions ||= {}
      @hinge_knee_accessory_definitions[cache_key] = definition
      definition
    end

    def parse_dc_list_options(raw)
      return [] if raw.to_s.strip.empty? || raw.to_s.strip == '&'
      raw.to_s.split('&').reject { |part| part.strip.empty? }.map do |part|
        decoded = CGI.unescape(part.to_s.gsub(/%u([0-9A-Fa-f]{4})/) { [$1.hex].pack('U') }) rescue part.to_s
        label, value = decoded.split('=', 2)
        {'label' => (label || decoded).to_s.strip, 'value' => (value || label || decoded).to_s.strip}
      end
    end

    def dc_list_options(item, key, fallback)
      raw = begin
        engine = dc_engine
        engine ? engine.get_attribute_options(item, key).to_s : ''
      rescue
        ''
      end
      if raw.empty?
        raw = item.get_attribute('dynamic_attributes', "_#{key}_options", '').to_s
        raw = item.definition.get_attribute('dynamic_attributes', "_#{key}_options", '').to_s if raw.empty?
      end
      options = parse_dc_list_options(raw)
      options.empty? ? fallback : options
    end

    def dc_list_current_value(item, key, fallback)
      formula_key = "_#{key}_formula"
      formula = item.get_attribute('dynamic_attributes', formula_key, nil)
      formula = item.definition.get_attribute('dynamic_attributes', formula_key, nil) if formula.to_s.strip.empty?
      formula = formula.to_s.strip
      return "=#{formula}" if !formula.empty? && !formula.start_with?('"')
      dc_value(item, key, fallback).to_s
    rescue
      dc_value(item, key, fallback).to_s
    end

    def apply_dc_list_value(item, key, value)
      text = value.to_s.strip
      engine = dc_engine
      formula_key = "_#{key}_formula"
      formula = if text.start_with?('=')
                  text.sub(/\A=/, '')
                else
                  escaped = text.gsub('\\', '\\\\').gsub('"', '\\"')
                  "\"#{escaped}\""
                end
      if engine && engine.respond_to?(:set_attribute_formula)
        engine.set_attribute_formula(item, key, formula)
      else
        item.set_attribute('dynamic_attributes', formula_key, formula)
      end
      item.set_attribute('dynamic_attributes', key, text) unless text.start_with?('=')
    rescue
      item.set_attribute('dynamic_attributes', formula_key, formula) if defined?(formula)
    end

    def dc_effective_value(item, key, fallback)
      engine = dc_engine
      value = engine.get_attribute_value(item, key).to_s if engine
      value = dc_value(item, key, fallback).to_s if value.to_s.empty?
      value
    rescue
      dc_value(item, key, fallback).to_s
    end

    def inches_to_cm(value)
      (value.to_f * 2.54).round(2)
    end

    def detected_corner_door_style(root)
      return nil unless root && root.valid?
      found = nil
      visited = {}
      scan = lambda do |entities|
        entities.each do |entity|
          next unless entity.is_a?(Sketchup::ComponentInstance) || entity.is_a?(Sketchup::Group)
          next unless entity.valid?
          generated = entity.get_attribute('MHD_DRESSING', 'GENERATED_COLUMN_DOOR')
          badges = joinery_badges(entity) rescue []
          is_corner = badges.include?('CORNER_DOOR') ||
                      entity.get_attribute('MHD_DRESSING', 'CORNER_DOOR_AXIS') ||
                      %w[corner_left corner_right].include?(entity.get_attribute('MHD_DRESSING','HINGE_DIRECTION').to_s)
          if generated && is_corner
            style = entity.get_attribute('MHD_DRESSING', 'DOOR_STYLE').to_s
            style = 'glass' if badges.include?('GLASS_DOOR')
            style = 'wood' if style.empty?
            found = (style == 'glass' ? 'glass' : 'wood')
            return
          end
          definition = entity.definition
          next if visited[definition.object_id]
          visited[definition.object_id] = true
          scan.call(definition.entities)
          return if found
        end
      end
      scan.call(root.definition.entities)
      found
    rescue
      nil
    end

    def wardrobe_data(item)
      stored = item.get_attribute('MHD_DRESSING', 'DATA_JSON').to_s
      unless stored.empty?
        saved = JSON.parse(stored)
        actual_corner_style = detected_corner_door_style(item)
        saved['corner_door_style'] = actual_corner_style if actual_corner_style
        saved['cabinet_shape'] = 'corner'
        saved['sloped_enabled'] = 'no'

        saved['back_joint_mode'] = 'back_side'
        saved['corner_side_thickness'] = saved['thickness'].to_f if saved['corner_side_thickness'].nil?
        if saved['version'].to_s != VERSION || saved['elita_screw_after_thread'].nil?
          saved['elita_screw_drill_diameter'] = 0.8
          saved['elita_dowel_diameter'] = 0.8
          saved['elita_dowel_depth'] = 1.05
          saved['elita_cam_diameter'] = 1.5
          saved['elita_cam_depth'] = 1.2
          saved['elita_screw_after_thread'] = 3.2
          saved.delete('elita_cam_edge_distance')
          saved.delete('elita_screw_length')
        end
        saved['butterfly_support_rules'] = [{'threshold'=>65.0,'count'=>1}] unless saved['butterfly_support_rules'].is_a?(Array) && !saved['butterfly_support_rules'].empty?
        saved['elita_support_rules'] = [{'threshold'=>65.0,'count'=>1}] unless saved['elita_support_rules'].is_a?(Array) && !saved['elita_support_rules'].empty?
        saved
      else
        get_defaults
      end
    rescue
      get_defaults
    end

  end
end
