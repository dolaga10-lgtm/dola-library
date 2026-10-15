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
require 'tempfile'
require 'digest'
require 'openssl'

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
  module DressingDesigner
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

    TITLE = 'مكتبة محمد عادل - تصميم الدريسنج'.freeze
    PREF_KEY = 'MHDESIGN_DRESSING_DESIGNER_V2'.freeze
    VERSION = '10.53.67'.freeze
    LOGO_URL = 'https://mhdesign-eg.com/SKETCHUP/components/logo3.png'.freeze
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

    # توقيع ثابت لنوع وحدة الدريسنج. لا يعتمد على اسم الـDefinition.
    DRESSING_DICT = 'MHD_DRESSING'.freeze
    DRESSING_SYSTEM = 'MHDESIGN_DRESSING'.freeze
    DRESSING_TYPE = 'straight'.freeze
    DRESSING_SIGNATURE = 'MHD_DRESSING_STRAIGHT_V1'.freeze
    DRESSING_SIGNATURE_VERSION = 1
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
    HINGE_KNEE_SKP_FILES = {
      'left' => 'LIFT HING total.skp',
      'right' => 'RIGHT HING total.skp'
    }.freeze

    class HingeDoorMotionObserver < Sketchup::EntityObserver
      def onChangeEntity(entity)
        UI.start_timer(0, false) do
          MHDESIGN::DressingDesigner.sync_hinge_accessories(entity) if entity && entity.valid?
        end
      rescue
        nil
      end
    end

    class DrawerSlideMotionObserver < Sketchup::EntityObserver
      def onChangeEntity(entity)
        UI.start_timer(0, false) do
          MHDESIGN::DressingDesigner.sync_drawer_slide(entity) if entity && entity.valid?
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

    def dressing_attribute(entity, key, fallback = '')
      return fallback unless entity && entity.respond_to?(:get_attribute)
      value = entity.get_attribute(DRESSING_DICT, key, nil)
      if (value.nil? || value.to_s.empty?) && entity.respond_to?(:definition) && entity.definition
        value = entity.definition.get_attribute(DRESSING_DICT, key, nil)
      end
      value.nil? ? fallback : value
    rescue
      fallback
    end

    def signed_straight_wardrobe?(item)
      return false unless item && item.valid? && item.is_a?(Sketchup::ComponentInstance)
      system = dressing_attribute(item, 'SYSTEM', '').to_s
      type = dressing_attribute(item, 'UNIT_TYPE', '').to_s
      signature = dressing_attribute(item, 'UNIT_SIGNATURE', '').to_s
      system == DRESSING_SYSTEM && type == DRESSING_TYPE && signature == DRESSING_SIGNATURE
    end

    def legacy_straight_wardrobe?(item)
      return false unless item && item.valid? && item.is_a?(Sketchup::ComponentInstance)
      # ترقية وحدات المستقيم القديمة فقط: الأداة المستقرة كانت تحفظ DATA_JSON
      # قبل إضافة نظام التوقيع. وجود توقيع نوع آخر يمنع الترقية تمامًا.
      existing_type = dressing_attribute(item, 'UNIT_TYPE', '').to_s
      existing_signature = dressing_attribute(item, 'UNIT_SIGNATURE', '').to_s
      return false unless existing_type.empty? && existing_signature.empty?
      stored = dressing_attribute(item, 'DATA_JSON', '').to_s
      !stored.empty?
    rescue
      false
    end

    def sign_straight_wardrobe!(item)
      return false unless item && item.valid? && item.is_a?(Sketchup::ComponentInstance)
      [item, item.definition].each do |owner|
        owner.set_attribute(DRESSING_DICT, 'SYSTEM', DRESSING_SYSTEM)
        owner.set_attribute(DRESSING_DICT, 'UNIT_TYPE', DRESSING_TYPE)
        owner.set_attribute(DRESSING_DICT, 'UNIT_SIGNATURE', DRESSING_SIGNATURE)
        owner.set_attribute(DRESSING_DICT, 'SIGNATURE_VERSION', DRESSING_SIGNATURE_VERSION)
        owner.set_attribute(DRESSING_DICT, 'FUNCTION_ROLE', 'wardrobe_root')
      end
      true
    end

    def selected_wardrobe(preferred = nil)
      candidates = []
      candidates << preferred if preferred
      candidates.concat(Sketchup.active_model.selection.grep(Sketchup::ComponentInstance))
      candidates.compact.uniq.each do |item|
        next unless item.valid?
        if signed_straight_wardrobe?(item)
          return item
        elsif legacy_straight_wardrobe?(item)
          sign_straight_wardrobe!(item)
          return item
        end
      end
      nil
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
    # كاش إكسسوارات الدريسنج — نفس كاش الوحدات المحمي في مكتبة MHDESIGN.
    #
    # - نفس مجلد كاش الوحدات: A9A6D99_5957844_88980
    # - اسم الملف مشتق من SHA256 للرابط ولا يكشف اسم الإكسسوار.
    # - المحتوى مشفر AES-256-CBC.
    # - HMAC-SHA256 يمنع قبول ملف كاش تم تعديله أو استبداله.
    # - المفتاح مربوط بالجهاز + البريد + الترخيص، بنفس منطق كاش المكتبة.
    # - لا نترك نسخة SKP مفكوكة بشكل دائم؛ يتم فكها إلى Tempfile فقط وقت
    #   model.definitions.load ثم حذف الملف فورًا.
    # - Cache-first: لو النسخة المشفرة سليمة لا يوجد اتصال بالسيرفر أصلًا.
    # ============================================================
    DRESSING_UNITS_CACHE_ROOT_DIR = 'A9A6D99_5957844_88980'.freeze
    DRESSING_CACHE_SECRET_SALT = 'MHDESIGN_REMOTE_CACHE_V1'.freeze
    DRESSING_CACHE_HMAC_SALT   = 'MHDESIGN_REMOTE_CACHE_HMAC_V1'.freeze
    GITHUB_DRESSING_BASE_URL = 'https://raw.githubusercontent.com/dolaga10-lgtm/dola-library/refs/heads/main/dressing'.freeze
    DRESSING_ASSET_ALLOWED_HOSTS = ['raw.githubusercontent.com', 'github.com', 'objects.githubusercontent.com', 'mhdesign-eg.com', 'www.mhdesign-eg.com'].freeze

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
      # الكاش التالف/القديم لا يوقف الأداة؛ نحذفه ليعاد تكوينه بصورة سليمة.
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
        response = http.get(uri.request_uri, {'User-Agent'=>'MHDESIGN-Dressing'})

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
      # 1) نفس منطق الوحدات: الكاش المشفر أولاً — بدون أي اتصال إن كان صالحًا.
      cached = read_dressing_asset_cache(url)
      return cached if cached && cached.bytesize > 100

      # 2) لو الملف مرفق محليًا مع الإضافة أو في كاش مكتبة محمد عادل نستخدمه فورًا.
      local_candidates = [
        bundled_path,
        (defined?(DolaSmartLibraryPlugin::DRESSING_DIR) ? File.join(DolaSmartLibraryPlugin::DRESSING_DIR, filename.to_s) : nil),
        (defined?(DolaSmartLibraryPlugin::OFFLINE_DIR) ? File.join(DolaSmartLibraryPlugin::OFFLINE_DIR, filename.to_s) : nil)
      ].compact
      found_local = local_candidates.find { |p| File.file?(p) && File.size(p) > 100 }
      if found_local
        raw = File.binread(found_local).b
        write_dressing_asset_cache(url, raw)
        return raw
      end

      # 3) محاولة التحميل من فولدر dressing في مستودع GitHub أولاً ثم الرابط الاحتياطي.
      github_url = "#{GITHUB_DRESSING_BASE_URL}/#{URI.encode_www_form_component(filename.to_s).gsub('+', '%20')}"
      raw = begin
        fetch_dressing_asset_remote(github_url, filename)
      rescue
        fetch_dressing_asset_remote(url, filename)
      end
      write_dressing_asset_cache(url, raw)
      raw
    rescue => error
      # محاولة أخيرة للكاش في حالة خطأ شبكة لحظي بين الفحص والتحميل.
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

    # توافق مع أي استدعاء قديم خارجي للدالة. المسار الناتج مؤقت فقط؛
    # كل استدعاءات هذه النسخة الداخلية تستخدم load_dressing_asset_definition
    # حتى لا يبقى SKP مفكوكًا على القرص.
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

      # مهم جدًا:
      # لا نستخدم Definition ملف الـSKP نفسه مباشرة داخل الدولاب.
      # في أول إنشاء يكون شكله صحيح، لكن بعد تعديل الدولاب root.make_unique
      # ثم مراحل التسمية/الـDC قد تعيد التعامل مع الـDefinition المشتركة
      # ومكوناتها الداخلية، فيتغير شكل/موضع الباكم في الإنشاء التالي.
      #
      # نعمل نسخة "مخبوزة" Raw Geometry مرة واحدة، بنفس الأكسات والـOrigin
      # التي جهزها المصمم في push up lift.skp. بعدها لا يوجد DC داخلي أو
      # Child Definitions يمكن أن تتأثر بإعادة إنشاء الدولاب.
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
        # ملف نص ركبة يمين لم يصل ضمن الملفات الحالية؛ نستخدم مؤقتًا
        # نص ركبة شمال مع انعكاس أفقي حتى يتوفر ملف اليمين الأصلي.
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

    def wardrobe_data(item)
      stored = item.get_attribute('MHD_DRESSING', 'DATA_JSON').to_s
      unless stored.empty?
        saved = JSON.parse(stored)
        # مقاسات الإليتا محفوظة ومقروءة بالسنتيمتر فقط. عند فتح وحدة قديمة
        # نثبت المقاسات القياسية الجديدة، ونلغي منطق طول المسمار/بعد الوش القديم.
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
        saved['top_cornice_joinery'] = 'screw' if saved['top_cornice_joinery'].to_s.empty?
        saved['top_cornice_joinery_offset'] = 5.0 if saved['top_cornice_joinery_offset'].nil?
        saved['top_cornice_joinery_rules'] = [{'threshold'=>65.0,'count'=>1}] unless saved['top_cornice_joinery_rules'].is_a?(Array) && !saved['top_cornice_joinery_rules'].empty?
        saved['leg_height'] = inches_to_cm(dc_value(item, 'base_unit_1_a', 10.0 / 2.54)) if saved['leg_height'].nil?
        saved['wood_plinth_joinery'] = 'screw' if saved['wood_plinth_joinery'].to_s.empty?
        saved['wood_plinth_joinery_offset'] = 5.0 if saved['wood_plinth_joinery_offset'].nil?
        saved['wood_plinth_joinery_rules'] = [{'threshold'=>65.0,'count'=>1}] unless saved['wood_plinth_joinery_rules'].is_a?(Array) && !saved['wood_plinth_joinery_rules'].empty?
        saved['elita_coil_count'] = 1 if saved['elita_coil_count'].nil?
        saved['elita_coil_drill_diameter'] = 0.8 if saved['elita_coil_drill_diameter'].nil?
        saved['elita_coil_length'] = 4.0 if saved['elita_coil_length'].nil?
        saved['elita_coil_face_depth'] = 2.0 if saved['elita_coil_face_depth'].nil?
        saved['elita_coil_center_distance'] = 2.5 if saved['elita_coil_center_distance'].nil?
        saved['hinge_cup_diameter'] = 3.5 if saved['hinge_cup_diameter'].nil?
        saved['hinge_cup_depth'] = 1.3 if saved['hinge_cup_depth'].nil?
        saved['hinge_cup_edge_center'] = 2.25 if saved['hinge_cup_edge_center'].nil?
        saved['hinge_count'] = 4 if saved['hinge_count'].nil?
        saved['hinge_end_offset'] = 10.0 if saved['hinge_end_offset'].nil?
        saved['hinge_collision_offset'] = 5.0 if saved['hinge_collision_offset'].nil?
        return saved
      end
      width = inches_to_cm(dc_value(item, 'a1', item.bounds.width))
      height = inches_to_cm(dc_value(item, 'a3', item.bounds.height))
      depth = inches_to_cm(dc_value(item, 'a2', item.bounds.depth))
      thickness = inches_to_cm(dc_value(item, 'base_unit_1_d', 1.8 / 2.54))
      clear = [(width - thickness * 3) / 2.0, 10].max.round(1)
      source_definition_name = item.definition.name.to_s
      source_unit_name = source_definition_name[/\(([^()]*)\)\s*(?:#\d+)?\z/, 1].to_s.strip
      source_unit_name = source_definition_name.strip if source_unit_name.empty?
      source_unit_name = 'دولاب دريسنج' if source_unit_name.empty?
      {
        'unit_name' => source_unit_name,
        'height' => height, 'depth' => depth, 'width' => width, 'thickness' => thickness,
        'back_thickness' => inches_to_cm(dc_value(item, 'base_unit_1_a3', 0.6 / 2.54)),
        'back_inset' => inches_to_cm(dc_value(item, 'base_unit_1_a2', 1.8 / 2.54)),
        'back_groove_depth' => 0.6,
        'back_joint_mode' => 'grooved_partition',
        'shelf_front_cut' => inches_to_cm(dc_value(item, 'base_unit_1_c1', 0)),
        'cut_full_partitions' => 'no',
        'fixed_top_shelf' => 'no',
        'fixed_top_clear_height' => 40.0,
        'sloped_enabled' => 'no',
        'sloped_left_height' => height,
        'sloped_right_height' => height,
        'base_type' => 'legs',
        # Dynamic Component attribute BASE_UNIT_1_A = ارتفاع الرجول.
        'leg_height' => inches_to_cm(dc_value(item, 'base_unit_1_a', 10.0 / 2.54)),
        'wood_plinth_height' => 10.0,
        'wood_plinth_supports' => 1,
        'wood_plinth_rear_inset' => 0.0,
        'wood_plinth_front_inset' => 1.8,
        'wood_plinth_joinery' => 'screw',
        'wood_plinth_joinery_offset' => 5.0,
        'wood_plinth_joinery_rules' => [{'threshold'=>65.0,'count'=>1}],
        'top_cornice_type' => 'none',
        'top_cornice_height' => 10.0,
        'top_cornice_joinery' => 'screw',
        'top_cornice_joinery_offset' => 5.0,
        'top_cornice_joinery_rules' => [{'threshold'=>65.0,'count'=>1}],
        'side_extension' => 0.0,
        'wall_relief' => {
          'enabled' => 'no', 'wall_width' => width,
          'placement' => 'left', 'cabinet_offset' => 0.0, 'columns' => []
        },
        'carcass_board_width' => 240.0,
        'carcass_board_length' => 280.0,
        'door_board_width' => 240.0,
        'door_board_length' => 280.0,
        'back_board_width' => 120.0,
        'back_board_length' => 240.0,
        'edge_band_pattern' => 'visible_only',
        'naming_dictionary' => {'shelf'=>'رف','column'=>'عمود','partition'=>'قاطع','drawer'=>'درج','drawer_front'=>'وش درج','back'=>'ضهر','door'=>'ضلفة','filler'=>'سدّة'},
        'assembly' => dc_value(item, 'base_unit_1_a1', '1').to_s == '2' ? 'full' : 'on_base',
        'top_type' => 'between_sides',
        'joinery_system' => 'screw',
        'hinge_system' => 'current',
        'hinge_cup_diameter' => 3.5,
        'hinge_cup_depth' => 1.3,
        'hinge_cup_edge_center' => 2.25,
        'hinge_count' => 4,
        'hinge_end_offset' => 10.0,
        'hinge_collision_offset' => 5.0,
        'accessory_catalogs' => {},
        'butterfly_edge_offset' => 5.0,
        'butterfly_apply_drawers' => 'no',
        'butterfly_support_rules' => [
          {'threshold'=>65.0, 'count'=>1}
        ],
        'elita_edge_offset' => 5.0,
        'elita_support_rules' => [
          {'threshold'=>65.0, 'count'=>1}
        ],
        'elita_screw_drill_diameter' => 0.8,
        'elita_dowel_diameter' => 0.8,
        'elita_dowel_depth' => 1.05,
        'elita_cam_diameter' => 1.5,
        'elita_cam_depth' => 1.2,
        'elita_screw_after_thread' => 3.2,
        'elita_coil_count' => 1,
        'elita_coil_drill_diameter' => 0.8,
        'elita_coil_length' => 4.0,
        'elita_coil_face_depth' => 2.0,
        'elita_coil_center_distance' => 2.5,
        'material' => dc_list_current_value(item, 'base_unit_1_j', 'كونتر ابيض'),
        'door_material' => dc_list_current_value(item, 'base_unit_1_f', 'HPL'),
        'back_material' => dc_list_current_value(item, 'base_unit_1_h', 'ضهر ابيض'),
        'door_type' => dc_value(item, 'base_unit_1_e', '1').to_s,
        'door_system' => 'none',
        'door_clearance' => inches_to_cm(dc_value(item, 'base_unit_1_g', 0.1 / 2.54)),
        'sliding_first_column' => 0,
        'sliding_second_column' => 1,
        'sliding_leaf_count' => 2,
        'sliding_style' => 'wood',
        'sliding_front_leaf' => 'left',
        'sliding_track_gap' => 1.0,
        'sliding_front_setback' => 0.0,
        'sliding_width_extra' => 0.0,
        'sliding_vertical_clearance' => 3.0,
        'sliding_partition_cut' => 5.0,
        'bays' => [
          {'width'=>clear,'shelves'=>3,'preset'=>'shelves','drawers'=>3,'drawer_height'=>70},
          {'width'=>clear,'shelves'=>3,'preset'=>'hanging','drawers'=>3,'drawer_height'=>65}
        ]
      }
    end

    # يحول وصف الحائط الذي أدخله المصمم إلى خلعات داخل إحداثيات الدولاب.
    # العميل يقيس من الجهة التي تناسبه (يمين/شمال)، لكن منطق الخلع الداخلي
    # يظل كما هو: نحول كل القياسات أولًا إلى إحداثي موحّد من شمال الحائط.
    def manual_wall_reliefs(data, total, depth, height)
      config = data['wall_relief']
      return [] unless config.is_a?(Hash) && config['enabled'].to_s == 'yes'
      wall_width = [config['wall_width'].to_f.cm, total].max
      placement = config['placement'].to_s == 'right' ? 'right' : 'left'
      cabinet_offset = [config['cabinet_offset'].to_f.cm, 0].max
      cabinet_start = if placement == 'right'
        wall_width - cabinet_offset - total
      else
        cabinet_offset
      end
      cabinet_start = [[cabinet_start, 0].max, [wall_width-total, 0].max].min
      # بعض الوحدات القديمة/حالات إلغاء نافذة الخلع قد تترك عنصر nil داخل columns.
      # الواجهة تستطيع عرض قيمة افتراضية بدل nil، لكن Ruby كان يصل إليه أثناء الإنشاء
      # فيعطي undefined method `[]' for nil:NilClass. نتجاهل فقط الصفوف التالفة؛
      # منطق الخلع نفسه لا يتغير.
      columns = config['columns'].is_a?(Array) ? config['columns'].select { |item| item.is_a?(Hash) } : []
      columns.filter_map do |column|
        column_width = column['width'].to_f.cm
        side = column['side'].to_s == 'right' ? 'right' : 'left'
        distance_cm = if column.key?('distance')
          column['distance'].to_f.cm
        else
          # توافق مع الوحدات القديمة التي كانت تحفظ left فقط.
          column['left'].to_f.cm
        end
        wall_x0 = if column.key?('distance') && side == 'right'
          wall_width - distance_cm - column_width
        elsif column.key?('distance')
          distance_cm
        else
          column['left'].to_f.cm
        end
        wall_x1 = wall_x0 + column_width
        x0 = [wall_x0-cabinet_start, 0].max
        x1 = [wall_x1-cabinet_start, total].min
        intrusion = [column['depth'].to_f.cm, depth-0.5.cm].min
        next unless x1-x0 > 0.5.cm && intrusion > 0.5.cm
        mode = column['mode'].to_s
        mode = 'depth_avoid' unless %w[depth_avoid true_notch].include?(mode)
        {'x0'=>x0, 'x1'=>x1, 'depth'=>intrusion, 'z0'=>0, 'z1'=>height, 'mode'=>mode}
      end.sort_by { |item| item['x0'] }
    end

    def reliefs_for_part(x, z, width, height, source = nil)
      source ||= @wall_reliefs
      return [] unless source.is_a?(Array)
      source.filter_map do |relief|
        next unless relief['z1'] > z + 0.1.cm && relief['z0'] < z + height - 0.1.cm
        x0 = [relief['x0'] - x, 0].max
        x1 = [relief['x1'] - x, width].min
        next unless x1 - x0 > 0.1.cm
        {'x0'=>x0, 'x1'=>x1, 'depth'=>relief['depth']}
      end
    end

    # إذا وقع عمود الحائط بالكامل داخل فتحة واحدة، يكون الحل الصناعي الأنظف
    # تقديم ضهر الفتحة كلها وتقليل عمق أرففها، مع بقاء خلعة القاعدة والقرصة
    # على عرض عمود الحائط الحقيقي فقط.
    def expand_reliefs_to_bays(reliefs, layout_tree, total, thickness)
      return reliefs.map(&:dup) unless layout_tree.is_a?(Hash)
      columns = collect_column_regions(layout_tree, thickness, total-thickness*2, thickness)
      reliefs.flat_map do |relief|
        if relief['mode'].to_s == 'depth_avoid'
          affected = columns.select do |column|
            relief['x1'] > column['x']+0.1.cm && relief['x0'] < column['x']+column['width']-0.1.cm
          end
          affected = [columns.min_by { |column| ((column['x']+column['width']/2.0)-(relief['x0']+relief['x1'])/2.0).abs }].compact if affected.empty?
          affected.map do |bay|
            relief.merge('x0'=>bay['x'], 'x1'=>bay['x']+bay['width'], 'proposal'=>'bay_depth',
                         'wall_x0'=>relief['x0'], 'wall_x1'=>relief['x1'], 'wall_depth'=>relief['depth'])
          end
        else
          # عندما يمر عمود الحائط على قاطوع نغلفه بكونتر: العرض يزيد
          # تخانة يمين وشمال، والخلع يصل أمام وش التجليدة: العمق الصافي D-P-T.
          [relief.merge(
            'x0'=>[relief['x0']-thickness,0].max,
            'x1'=>[relief['x1']+thickness,total].min,
            'depth'=>relief['depth']+thickness,
            'proposal'=>'cladded_partition',
            'wall_x0'=>relief['x0'], 'wall_x1'=>relief['x1'], 'wall_depth'=>relief['depth']
          )]
        end
      end
    end

    def add_box_without_wall_relief(*args)
      previous = @wall_relief_bypass
      @wall_relief_bypass = true
      add_box(*args)
    ensure
      @wall_relief_bypass = previous
    end

    def merge_relief_spans(spans, depth)
      result = []
      spans.sort_by { |item| item['x0'] }.each do |item|
        cut_depth = [[item['depth'].to_f, 0].max, depth-0.1.cm].min
        next if cut_depth <= 0
        if !result.empty? && item['x0'] <= result[-1]['x1'] + 0.1.cm
          result[-1]['x1'] = [result[-1]['x1'], item['x1']].max
          result[-1]['depth'] = [result[-1]['depth'], cut_depth].max
        else
          result << {'x0'=>item['x0'], 'x1'=>item['x1'], 'depth'=>cut_depth}
        end
      end
      result
    end

    def relief_profile_points(width, depth, spans)
      points = [[0,0],[width,0],[width,depth]]
      spans.reverse_each do |span|
        rear = depth - span['depth']
        points << [span['x1'], depth] unless points.last == [span['x1'], depth]
        points.concat([[span['x1'],rear],[span['x0'],rear],[span['x0'],depth]])
      end
      points << [0,depth]
      # الخلعة الملامسة لأقصى اليمين أو الشمال يمكن أن تضيف نفس ركنة
      # اللوح مرتين. SketchUp يرفض add_face وقتها برسالة Duplicate points.
      tolerance = 0.0001.cm
      clean = []
      points.each do |point|
        previous = clean[-1]
        next if previous && (previous[0]-point[0]).abs <= tolerance && (previous[1]-point[1]).abs <= tolerance
        clean << point
      end
      if clean.length > 1 &&
         (clean[0][0]-clean[-1][0]).abs <= tolerance &&
         (clean[0][1]-clean[-1][1]).abs <= tolerance
        clean.pop
      end
      clean
    end

    def set_dc_cm(item, key, cm_value)
      item.set_attribute('dynamic_attributes', key, (cm_value.to_f / 2.54).to_s)
    end

    def redraw_dc(item)
      return unless defined?($dc_observers) && $dc_observers
      klass = $dc_observers.get_latest_class
      klass.redraw_with_undo(item) if klass
    rescue
      nil
    end

    def redraw_dc_live(item)
      return unless defined?($dc_observers) && $dc_observers
      klass = $dc_observers.get_latest_class
      return unless klass
      if klass.respond_to?(:redraw)
        klass.redraw(item)
      else
        klass.redraw_with_undo(item)
      end
    rescue
      nil
    end

    def mat(model, name, color)
      found = model.materials[name]
      return found if found
      raise "الخامة #{name} غير موجودة داخل الموديل. اختر خامة موجودة بنفس الاسم." 
    end

    def unique_name(model, wanted)
      return wanted unless model.definitions[wanted]
      index = 2
      index += 1 while model.definitions["#{wanted} (#{index})"]
      "#{wanted} (#{index})"
    end

    # Definition names are global across the whole SketchUp model. A stale or
    # internal definition in another component can reserve a perfectly unique
    # manufacturing name and force SketchUp to append #1. Move that conflicting
    # definition aside before assigning the clean name to the current part.
    def claim_clean_definition_name(definition, wanted)
      model = Sketchup.active_model
      conflict = model.definitions[wanted]
      if conflict && conflict != definition
        internal_name = "__MHD_NAME_HOLDER_#{conflict.object_id}"
        suffix = 1
        while (holder = model.definitions[internal_name]) && holder != conflict
          suffix += 1
          internal_name = "__MHD_NAME_HOLDER_#{conflict.object_id}_#{suffix}"
        end
        conflict.name = internal_name
      end
      definition.name = wanted
      definition.name
    end

    def check_board_limit(name, width, depth, height, material, badges)
      return unless @board_limits && material
      tags = Array(badges).map(&:to_s)
      kind = if tags.include?('BACK_PANEL')
        'back'
      elsif tags.include?('DRAWER_FRONT') || tags.include?('DOOR_PANEL')
        'door'
      elsif tags.include?('HARDWARE') || tags.include?('DRAWER_BOTTOM')
        nil
      elsif material.name.to_s == @board_limits['carcass_material'].to_s
        'carcass'
      end
      return unless kind
      limit_w = @board_limits["#{kind}_width"].to_f
      limit_l = @board_limits["#{kind}_length"].to_f
      return unless limit_w > 0 && limit_l > 0
      dimensions = [width, depth, height].map { |value| value.to_f / 1.cm.to_f }.sort.reverse
      part_a, part_b = dimensions[0], dimensions[1]
      fits = (part_a <= limit_w && part_b <= limit_l) || (part_a <= limit_l && part_b <= limit_w)
      return if fits
      label = {'door'=>'لوح الضلفة', 'back'=>'لوح الضهر', 'carcass'=>'لوح الشاسيه'}[kind]
      @board_violations << {
        'name' => name.to_s,
        'part_width' => part_a.round(1),
        'part_length' => part_b.round(1),
        'board_label' => label,
        'board_width' => limit_w.round(1),
        'board_length' => limit_l.round(1)
      }
    end

    def raise_board_violations!
      issues = Array(@board_violations).uniq { |item| [item['name'], item['part_width'], item['part_length'], item['board_label']] }
      return if issues.empty?
      raise BoardLimitError.new(issues)
    end

    def clean_part_name(name)
      value = name.to_s.strip
      value = value.sub(/\s*#{Regexp.escape(PART_SUFFIX)}\s*\z/i, '')
      # A generated part can pass through more than one finishing stage.
      # Strip every repeated trailing unit suffix, then qualified_part_name
      # appends the active unit exactly once.
      value = value.sub(/(?:\s*\([^()]*\)\s*(?:#\d+)?)+\s*\z/, '')
      value = value.sub(/\s*#\d+\s*\z/, '')
      value.strip.empty? ? 'قطعة دريسنج' : value.strip
    end

    def active_unit_name
      value = @active_unit_name.to_s.strip.gsub(/[\r\n\t]+/, ' ').gsub(/\s+/, ' ')
      value.empty? ? 'دولاب دريسنج' : value
    end

    def qualified_part_name(name)
      "#{clean_part_name(name)} (#{active_unit_name})"
    end

    def naming_term(key, fallback)
      value = @naming_dictionary.is_a?(Hash) ? @naming_dictionary[key.to_s].to_s.strip : ''
      value.empty? ? fallback : value.gsub(/[()]/, '').strip
    end

    def column_number_for_part(x, width = 0)
      return 1 unless @naming_columns.is_a?(Array) && !@naming_columns.empty?
      center = x.to_f + width.to_f / 2.0
      index = @naming_columns.index { |column| center >= column['x'].to_f-0.2.cm && center <= column['x'].to_f+column['width'].to_f+0.2.cm }
      (index || 0) + 1
    end

    def human_part_name(name, x, width = 0)
      value = clean_part_name(name)
      column = column_number_for_part(x, width)
      if value.match?(/\Aرف\s+[\d.]+(?:\s+\d+)?/)
        @part_name_counters ||= Hash.new(0)
        @part_name_counters[[:shelf,column]] += 1
        value = "#{naming_term('shelf','رف')} #{@part_name_counters[[:shelf,column]]} #{naming_term('column','عمود')} #{column}"
      elsif value.match?(/\Aقاطع\s+[\d.]+/)
        @part_name_counters ||= Hash.new(0)
        @part_name_counters[[:partition,column]] += 1
        value = "#{naming_term('partition','قاطع')} #{@part_name_counters[[:partition,column]]} #{naming_term('column','عمود')} #{column}"
      else
        value = value.gsub(/فتحة\s+[\d.]+/, "#{naming_term('column','عمود')} #{column}")
        value = value.sub(/\Aوش درج/, naming_term('drawer_front','وش درج'))
        value = value.sub(/\Aدرج/, naming_term('drawer','درج'))
        value = value.sub(/\Aضهر/, naming_term('back','ضهر'))
        value = value.sub(/\Aضلفة/, naming_term('door','ضلفة'))
        value = value.sub(/\Aسدّة/, naming_term('filler','سدّة'))
      end
      value
    end

    def localized_badges(badges)
      Array(badges).map { |badge| BADGE_ARABIC[badge.to_s] || badge.to_s }.uniq
    end

    def set_part_badges(definition, badges)
      definition.set_attribute('MHD_DRESSING', 'INTERNAL_BADGES', Array(badges).map(&:to_s))
      definition.set_attribute('ladb_opencutlist', 'tags', localized_badges(badges))
    end

    # يحدد حواف الشريط من أبعاد اللوح الحقيقية. أصغر محور هو التخانة، لذلك
    # وجهاه الكبيران لا يدخلان في الشريط، وتبقى أوجه الحواف الأربعة فقط.
    #
    # قاعدة ثابتة:
    # الضلفة ووش الدرج شريط الحرف لهما داير دائمًا، بغض النظر عن اختيار
    # نمط شريط الشاسيه (ظاهر فقط / داير / بدون).
    def edge_band_faces(width, depth, height, name, badges)
      return [] if badges.include?('HARDWARE') || badges.include?('BACK_PANEL')

      dimensions = { x: width.to_f.abs, y: depth.to_f.abs, z: height.to_f.abs }
      thin_axis = dimensions.min_by { |_axis, value| value }.first
      candidates = [:x_min, :x_max, :y_min, :y_max, :z_min, :z_max].reject do |edge|
        edge.to_s.start_with?(thin_axis.to_s)
      end

      text = name.to_s
      front_piece = badges.include?('DOOR_PANEL') || badges.include?('DRAWER_FRONT') ||
                    text.include?('ضلفة') || text.include?('وش درج')

      # القطع الأمامية الخشب: شريط داير دائمًا.
      # الزجاج مستبعد قبل الوصول هنا داخل apply_edge_banding.
      return candidates if front_piece

      # الكورنيشة الأمامية شريطها داير دائمًا.
      # كورنيشة اليمين والشمال في وضع "ظاهر فقط" يكون الشريط على
      # الحرفين الطوليين فقط (أعلى وأسفل في رسم الـCutList) مثل المرجع.
      if badges.include?('TOP_CORNICE')
        return candidates if badges.include?('FRONT')
        pattern = @edge_band_pattern.to_s
        return [] unless %w[all_around visible_only].include?(pattern)
        return candidates if pattern == 'all_around'
        return candidates.select { |edge| edge == :z_min || edge == :z_max }
      end

      # تقسيمات إكسسوار الدرج: شريط داير دائمًا، بغض النظر عن
      # اختيار شريط الشاسيه العام.
      return candidates if badges.include?('DRAWER_ORGANIZER')

      pattern = @edge_band_pattern.to_s
      return [] unless %w[all_around visible_only].include?(pattern)
      return candidates if pattern == 'all_around'
      # قاعدة الدرج الرفيعة فقط لا تدخل في شريط الحرف.
      return [] if badges.include?('DRAWER_BOTTOM')

      # السوكلو الخشب:
      # الجوانب والدعامات الداخلية بدون أي شريط نهائيًا.
      # الواجهة الأمامية والخلفية تظل على منطقها الحالي كما هي.
      if badges.include?('WOOD_PLINTH')
        return [] if badges.include?('SIDE') || badges.include?('SUPPORT')
      end

      # داعم مفصلات السدّة: الشريط على الناحيتين الطوال فقط
      # (أعلى وأسفل القطعة في رسم الـCutList).
      if badges.include?('HINGE_SUPPORT')
        return candidates.select { |edge| edge == :z_min || edge == :z_max }
      end

      # شاسيه الدرج الداخلي (الجنبين + وش الشاسيه + الضهر):
      # في اختيار "ظاهر فقط" الشريط يكون على الحرفين الطوليين فقط،
      # أي أعلى وأسفل اللوح في رسم OpenCutList (مثل الصورة المرجعية).
      # لذلك نثبت الشريط على Z min / Z max بصرف النظر عن اتجاه تخانة القطعة.
      if badges.include?('DRAWER_SIDE') || badges.include?('DRAWER_BOX')
        return candidates.select { |edge| edge == :z_min || edge == :z_max }
      end

      # باقي الشاسيه الخارجي والدعامات يظل بمنطق الواجهة الظاهرة الحالي.
      if thin_axis == :y
        candidates.select { |edge| edge == :x_min || edge == :x_max }
      else
        candidates.select { |edge| edge == :y_min || edge == :y_max }
      end
    end

    def same_material_finish?(first, second)
      return false unless first && second
      first.name.to_s.strip.downcase == second.name.to_s.strip.downcase
    end

    # نفس مزامنة خامات الشريط في نافذة الأوبشن: الاسم يظل اسم خامة الشريط،
    # لكن اللون والشفافية والتكستشر ومقاسها يتبعون خامة اللوح المختارة.
    def copy_band_material_appearance(source, target)
      return target unless source && target
      target.color = source.color rescue nil
      target.alpha = source.alpha rescue nil
      if source.texture
        texture_file = source.texture.filename.to_s
        unless texture_file.empty?
          begin
            target.texture = texture_file
            target.texture.size = [source.texture.width, source.texture.height] if target.texture
          rescue
          end
        end
      else
        target.texture = nil rescue nil
      end
      target
    end

    def prepare_edge_band_materials(model, carcass_material, door_material)
      shared = same_material_finish?(carcass_material, door_material)
      if shared
        material = model.materials['شريط حرف'] || model.materials.add('شريط حرف')
        copy_band_material_appearance(carcass_material, material)
        { chassis: material, door: material }
      else
        chassis_band = model.materials['شريط حرف الشاسيه'] || model.materials.add('شريط حرف الشاسيه')
        door_band = model.materials['شريط حرف الضلف'] || model.materials.add('شريط حرف الضلف')
        copy_band_material_appearance(carcass_material, chassis_band)
        copy_band_material_appearance(door_material, door_band)
        { chassis: chassis_band, door: door_band }
      end
    end

    def door_or_front_part?(name, badges)
      badges.include?('DOOR_PANEL') || badges.include?('DRAWER_FRONT') ||
        name.to_s.include?('ضلفة') || name.to_s.include?('وش درج')
    end

    def edge_band_material(model, source_material, badges, name = '')
      type = door_or_front_part?(name, badges) ? :door : :chassis
      (@edge_band_materials && @edge_band_materials[type]) || source_material
    end

    def edge_key_for_normal(normal)
      values = { x: normal.x.abs, y: normal.y.abs, z: normal.z.abs }
      axis = values.max_by { |_key, value| value }.first
      sign = normal.public_send(axis) < 0 ? 'min' : 'max'
      "#{axis}_#{sign}".to_sym
    end

    # يطبق خامة شريط الحرف داخل هندسة الضلفة المركبة أيضًا.
    # الضلف المنسوخة من Dynamic Components قد لا تحتوي Faces مباشرة في
    # تعريفها الأعلى، بل تكون الخشبة الفعلية داخل Component/Group فرعي.
    def paint_door_edge_faces_recursive(entities, band_material, selected, transform = Geom::Transformation.new)
      entities.each do |entity|
        if entity.is_a?(Sketchup::Face)
          normal = entity.normal.transform(transform)
          edge = edge_key_for_normal(normal)
          next unless selected.include?(edge)
          entity.material = band_material
          entity.back_material = band_material
          entity.set_attribute('MHD_EDGE_BAND', 'edge', edge.to_s)
        elsif entity.is_a?(Sketchup::ComponentInstance) || entity.is_a?(Sketchup::Group)
          begin
            entity.make_unique if entity.respond_to?(:make_unique)
          rescue
          end
          paint_door_edge_faces_recursive(
            entity.definition.entities,
            band_material,
            selected,
            transform * entity.transformation
          )
        end
      end
    end

    def apply_edge_banding(instance, model, name, source_material, badges, width, depth, height)
      # الضلفة الزجاج Component مركب (إطار + زجاج + أجزاء داخلية).
      # ممنوع تطبيق شريط الحرف عليها أو النزول داخلها Recursive لأن ذلك
      # يطلي الزجاج نفسه بخامة شريط الضلف فيظهر كأنه لوح خشب فوق الزجاج.
      return if Array(badges).map(&:to_s).include?('GLASS_DOOR')

      selected = edge_band_faces(width, depth, height, name, badges)
      definition = instance.definition
      labels = {
        x_min: 'يسار', x_max: 'يمين', y_min: 'أمام', y_max: 'خلف',
        z_min: 'أسفل', z_max: 'أعلى'
      }
      definition.set_attribute('MHD_EDGE_BAND', 'pattern', @edge_band_pattern.to_s)
      definition.set_attribute('MHD_EDGE_BAND', 'edges', selected.map { |edge| labels[edge] }.join(','))
      band_material = edge_band_material(model, source_material, badges, name)
      definition.set_attribute('MHD_EDGE_BAND', 'material', band_material.name.to_s)
      labels.each_key do |edge|
        definition.set_attribute('MHD_EDGE_BAND', edge.to_s, selected.include?(edge) ? '1' : '0')
      end
      return if selected.empty?
      direct_faces = definition.entities.grep(Sketchup::Face)
      direct_faces.each do |face|
        next unless selected.include?(edge_key_for_normal(face.normal))
        face.material = band_material
        face.back_material = band_material
        face.set_attribute('MHD_EDGE_BAND', 'edge', labels[edge_key_for_normal(face.normal)])
      end

      # وش الدرج هندسته مباشرة ولذلك كان يعمل بالفعل.
      # الضلفة الـDC غالبًا هندستها داخل Child Component، فنطبق الشريط
      # على الحواف الفعلية داخلها أيضًا.
      if door_or_front_part?(name, badges) && direct_faces.empty?
        paint_door_edge_faces_recursive(definition.entities, band_material, selected)
      end
    end

    # يثبت اتجاه عروق أي خامة Textured على محور تصنيع واضح بدل الاعتماد
    # على الإسقاط الافتراضي لـSketchUp. وإذا كان المحور عموديًا على وجه
    # ضيق (مثل حرف جانبي) نستخدم أطول ضلع داخل مستوى الوجه.
    def position_texture_along_axis(face, material, desired_axis, front = true)
      return unless material && material.texture
      normal = face.normal
      dot = desired_axis.dot(normal)
      grain = Geom::Vector3d.new(
        desired_axis.x - normal.x * dot,
        desired_axis.y - normal.y * dot,
        desired_axis.z - normal.z * dot
      )
      if grain.length < 0.001
        edge = face.edges.max_by { |item| item.length.to_f }
        return unless edge
        grain = edge.end.position - edge.start.position
      end
      grain.normalize!
      across = normal * grain
      return if across.length < 0.001
      across.normalize!
      origin = face.vertices.first.position
      texture_width = [material.texture.width.to_f, 0.001].max
      texture_height = [material.texture.height.to_f, 0.001].max
      mapping = [
        origin, Geom::Point3d.new(0, 0, 1),
        origin.offset(grain, texture_height), Geom::Point3d.new(0, 1, 1),
        origin.offset(across, texture_width), Geom::Point3d.new(1, 0, 1)
      ]
      face.clear_texture_position(front) if face.respond_to?(:clear_texture_position)
      face.position_material(material, mapping, front)
    rescue
      nil
    end

    # تقسيمات الدرج تحتاج اتجاه التكتشر بالعرض:
    # نعتبر أطول حرف على كل Face هو الاتجاه الأصلي، ثم نستخدم الاتجاه
    # العمودي عليه داخل نفس الـFace، أي Rotation 90° حقيقي للتكتشر.
    def orient_definition_textures_rotated_90(definition)
      definition.entities.grep(Sketchup::Face).each do |face|
        edge = face.edges.max_by { |item| item.length.to_f }
        next unless edge
        long_axis = edge.end.position - edge.start.position
        next if long_axis.length < 0.001
        long_axis.normalize!

        normal = face.normal
        across = normal * long_axis
        next if across.length < 0.001
        across.normalize!

        [true, false].each do |front|
          material = front ? face.material : face.back_material
          next unless material && material.texture

          origin = face.vertices.first.position
          texture_width = [material.texture.width.to_f, 0.001].max
          texture_height = [material.texture.height.to_f, 0.001].max

          # grain على across بدل long_axis = تدوير 90 درجة.
          second = normal * across
          next if second.length < 0.001
          second.normalize!

          mapping = [
            origin, Geom::Point3d.new(0, 0, 1),
            origin.offset(across, texture_height), Geom::Point3d.new(0, 1, 1),
            origin.offset(second, texture_width), Geom::Point3d.new(1, 0, 1)
          ]
          face.clear_texture_position(front) if face.respond_to?(:clear_texture_position)
          face.position_material(material, mapping, front)
        end
      end
    rescue
      nil
    end

    def orient_definition_textures(definition, desired_axis)
      definition.entities.grep(Sketchup::Face).each do |face|
        position_texture_along_axis(face, face.material, desired_axis, true)
        position_texture_along_axis(face, face.back_material, desired_axis, false)
      end
    end

    def grain_axis_for_part(name, badges, width, depth, height)
      text = name.to_s
      return X_AXIS if badges.include?('DRAWER_FRONT') || badges.include?('DRAWER_BOTTOM')
      return X_AXIS if text.include?('رف') || text.include?('قاعدة') || text.include?('قرصة')
      return X_AXIS if badges.include?('WOOD_PLINTH') && (badges.include?('FRONT') || badges.include?('BACK'))
      return Z_AXIS if badges.include?('BACK_PANEL') || badges.include?('DOOR_PANEL')
      return Z_AXIS if text.include?('جنب') || text.include?('قاطع') || text.include?('ضلفة')
      dimensions = { x: width.to_f.abs, y: depth.to_f.abs, z: height.to_f.abs }
      { x: X_AXIS, y: Y_AXIS, z: Z_AXIS }[dimensions.max_by { |_axis, value| value }.first]
    end

    def orient_part_textures(instance, name, badges, width, depth, height)
      orient_definition_textures(instance.definition, grain_axis_for_part(name, badges, width, depth, height))
    end

    # يوحّد أسماء كل Definitions داخل الدولاب، بما فيها قطع الشاسيه الأصلية
    # والقطع المركبة داخل الضلف الزجاج، مع الحفاظ على هيكل الـDC كما هو.
    def band_material_reference?(material)
      return false unless material
      name = material.name.to_s.strip
      name.start_with?('شريط حرف')
    end

    def replace_band_material_on_entity(entity, type)
      return unless type && @edge_band_materials && @edge_band_materials[type]
      target = @edge_band_materials[type]
      if entity.respond_to?(:material) && band_material_reference?(entity.material)
        entity.material = target
      end
      if entity.is_a?(Sketchup::Face)
        entity.material = target if band_material_reference?(entity.material)
        entity.back_material = target if band_material_reference?(entity.back_material)
      end
    end

    def naming_entity_hidden?(entity, parent_hidden = false)
      return true if parent_hidden
      return true if entity.respond_to?(:hidden?) && entity.hidden?
      layer = entity.respond_to?(:layer) ? entity.layer : nil
      return true if layer && layer.respond_to?(:visible?) && !layer.visible?
      hidden_value = entity.respond_to?(:get_attribute) ? entity.get_attribute('dynamic_attributes', 'hidden', nil) : nil
      return true if %w[1 true yes].include?(hidden_value.to_s.downcase)
      hidden_formula = entity.respond_to?(:get_attribute) ? entity.get_attribute('dynamic_attributes', '_hidden_formula', nil) : nil
      %w[true 1 yes].include?(hidden_formula.to_s.strip.downcase)
    end

    def door_source_identity_names(entity)
      definition = entity.definition
      [
        entity.get_attribute('MHD_DRESSING', 'SOURCE_DEFINITION_NAME', nil),
        definition.get_attribute('MHD_DRESSING', 'SOURCE_DEFINITION_NAME', nil),
        entity.name, definition.name,
        entity.get_attribute('dynamic_attributes', '_name', nil),
        entity.get_attribute('dynamic_attributes', 'name', nil),
        definition.get_attribute('dynamic_attributes', '_name', nil),
        definition.get_attribute('dynamic_attributes', 'name', nil)
      ].compact.map { |value| normalized_definition_name(value) }.reject(&:empty?)
    end

    def entity_function_role(entity)
      role = entity.get_attribute('MHD_DRESSING', 'FUNCTION_ROLE', '').to_s
      role = entity.definition.get_attribute('MHD_DRESSING', 'FUNCTION_ROLE', '').to_s if role.empty?
      role
    end

    def set_entity_function_role(entity, role)
      entity.set_attribute('MHD_DRESSING', 'FUNCTION_ROLE', role)
      entity.definition.set_attribute('MHD_DRESSING', 'FUNCTION_ROLE', role)
      role
    end

    def door_source_role(entity)
      existing = entity_function_role(entity)
      return existing if existing.start_with?('door_source:')
      names = door_source_identity_names(entity)
      DOOR_SOURCE_NAMES.each do |key, wanted|
        next unless names.any? { |name| name.include?(wanted) }
        role = "door_source:#{key[0]}:#{key[1]}"
        return set_entity_function_role(entity, role)
      end
      ''
    end

    def door_source_template_entity?(entity)
      return false if entity.get_attribute('MHD_DRESSING', 'GENERATED_COLUMN_DOOR')
      door_source_role(entity).start_with?('door_source:')
    end

    # SketchUp reserves definition names even when their only instances are
    # hidden. Move hidden-only definitions out of the manufacturing namespace
    # before visible parts are qualified, so the visible definition always
    # keeps the clean name without an automatic #1 suffix.
    def release_names_held_by_hidden_definitions(entities)
      usage = {}
      visited = {}
      scan = lambda do |collection, parent_hidden|
        collection.each do |entity|
          next unless entity.is_a?(Sketchup::ComponentInstance) || entity.is_a?(Sketchup::Group)
          hidden = naming_entity_hidden?(entity, parent_hidden)
          definition = entity.definition
          record = (usage[definition.object_id] ||= {'definition'=>definition, 'visible'=>false, 'hidden'=>false, 'door_source'=>false})
          record['door_source'] = true if door_source_template_entity?(entity)
          if hidden
            record['hidden'] = true
          else
            record['visible'] = true
          end
          visit_key = [definition.object_id, hidden]
          next if visited[visit_key]
          visited[visit_key] = true
          scan.call(definition.entities, hidden)
        end
      end
      scan.call(entities, false)
      hidden_index = 0
      usage.each_value do |record|
        next unless record['hidden'] && !record['visible'] && !record['door_source']
        hidden_index += 1
        record['definition'].name = "__MHD_HIDDEN_#{hidden_index}_#{record['definition'].object_id}"
      end
    end

    # Last naming pass, deliberately called after joinery and accessories are
    # complete. SketchUp/DC may append #1 while definitions are being copied or
    # redrawn even when no real duplicate remains. At this point the model is
    # stable, so remove that technical suffix from the definition and from any
    # mirrored dynamic name fields as the final operation.
    def sanitize_final_part_names(entities, visited = {})
      entities.each do |entity|
        next unless entity.is_a?(Sketchup::ComponentInstance) || entity.is_a?(Sketchup::Group)
        definition = entity.definition
        unless visited[definition.object_id]
          visited[definition.object_id] = true
          next if door_source_template_entity?(entity)
          current_name = definition.name.to_s
          clean_name = current_name.gsub(/\s*#\d+/, '').strip
          claim_clean_definition_name(definition, clean_name) unless clean_name.empty?
          # Dynamic _name/name fields may be functional API identifiers in old
          # library components. Never rewrite them during visual name cleanup.
          entity.name = '' unless entity.get_attribute('MHD_DRESSING', 'GENERATED_COLUMN_DOOR')
          sanitize_final_part_names(definition.entities, visited)
        end
      end
    end

    def qualify_component_tree(entities, visited = {}, inherited_band_type = nil)
      entities.each do |entity|
        band_type = if entity.respond_to?(:get_attribute) && entity.get_attribute('MHD_DRESSING', 'GENERATED_COLUMN_DOOR')
          :door
        else
          inherited_band_type
        end
        replace_band_material_on_entity(entity, band_type)
        if entity.is_a?(Sketchup::ComponentInstance)
          # Hidden source doors are functional Dynamic Component templates.
          # Their fixed definition names are API keys used when a new wood or
          # glass door is requested, so manufacturing naming must never touch
          # them. Generated door copies carry GENERATED_COLUMN_DOOR and continue
          # through the normal naming path.
          next if door_source_template_entity?(entity)
          # Never call make_unique while finalizing names. SketchUp creates a
          # second definition immediately and gives it a #1 suffix before our
          # clean name is assigned. Parts that truly need an independent
          # definition are already made unique at their creation/copy stage.
          definition = entity.definition
          unless definition.get_attribute('MHD_DRESSING', 'SOURCE_DEFINITION_NAME', nil)
            definition.set_attribute('MHD_DRESSING', 'SOURCE_DEFINITION_NAME', definition.name.to_s)
          end
          base_name = definition.name.to_s.empty? ? entity.name.to_s : definition.name.to_s
          full_name = qualified_part_name(base_name)
          claim_clean_definition_name(definition, full_name)
          entity.name = ''
          internal_badges = definition.get_attribute('MHD_DRESSING', 'INTERNAL_BADGES', nil)
          internal_badges ||= definition.get_attribute('ladb_opencutlist', 'tags', [])
          set_part_badges(definition, internal_badges)
          next if visited[definition.object_id]
          visited[definition.object_id] = true
          qualify_component_tree(definition.entities, visited, band_type)
        elsif entity.is_a?(Sketchup::Group)
          qualify_component_tree(entity.entities, visited, band_type)
        end
      end
    end

    def joinery_badges(entity)
      value = entity.definition.get_attribute('MHD_DRESSING', 'INTERNAL_BADGES', nil) rescue nil
      value ||= entity.definition.get_attribute('ladb_opencutlist', 'tags', []) rescue []
      value.is_a?(Array) ? value.map(&:to_s) : value.to_s.split(/[;,]/).map(&:strip)
    end

    def butterfly_board_records(entities, include_drawers = false, result = [], parent_tr = Geom::Transformation.new)
      entities.each do |entity|
        next unless entity.valid?
        if entity.is_a?(Sketchup::ComponentInstance)
          next if entity.respond_to?(:hidden?) && entity.hidden?
          badges = joinery_badges(entity)
          accessory = badges.include?('HARDWARE') || badges.include?('ACCESSORY') || entity.get_attribute('MHD_DRESSING', 'JOINERY_ACCESSORY')
          # DRAWER_CHASSIS هو الشاسيه الخارجي الثابت ويُجمع منفصلًا دائمًا.
          # الخيار نعم/لا يخص صندوق الدرج المتحرك فقط.
          drawer_part = badges.any? { |tag| %w[DRAWER_SIDE DRAWER_BOX DRAWER_BOTTOM].include?(tag) }
          part_name = "#{entity.name} #{entity.definition.name}"
          wood_joinery_part = badges.any? { |tag| %w[MAIN_CARCASS PARTITION SHELF DRAWER_SIDE DRAWER_BOX DRAWER_BOTTOM DRAWER_CHASSIS SIDE_FILLER JOINERY_PART TOP_CORNICE WOOD_PLINTH].include?(tag) } ||
                              part_name.match?(/سدّة|جنب.*شاسيه|قاطع|رف|قاعدة.*شاسيه|قرصة|شاسيه.*درج|جنب.*درج|قاعدة.*درج/)
          if !accessory && wood_joinery_part && (include_drawers || !drawer_part)
            tr = parent_tr * entity.transformation
            points = (0..7).map { |i| entity.definition.bounds.corner(i).transform(tr) }
            min_x,max_x = points.map(&:x).minmax; min_y,max_y = points.map(&:y).minmax; min_z,max_z = points.map(&:z).minmax
            dx,dy,dz = max_x-min_x,max_y-min_y,max_z-min_z
            kind = if badges.include?('TOP_CORNICE') && badges.include?('FRONT')
                     :top_cornice_front
                   elsif badges.include?('TOP_CORNICE') && badges.include?('SIDE')
                     :top_cornice_side
                   elsif badges.include?('WOOD_PLINTH') && (badges.include?('FRONT') || badges.include?('BACK'))
                     :wood_plinth_rail
                   elsif badges.include?('WOOD_PLINTH') && badges.include?('SIDE')
                     :wood_plinth_side
                   elsif badges.include?('WOOD_PLINTH') && badges.include?('SUPPORT')
                     :wood_plinth_support
                   elsif badges.include?('SIDE_FILLER')
                     # السدّة لوح رأسي أمامي: مستواها X/Z وتخانتها على Y.
                     # نحتفظ بها كسجل مستقل حتى نعالج وصلاتها مع الجنب
                     # والقرصة والقاعدة بدون خلطها بالقواطع الرأسية X-thin.
                     :side_filler
                   elsif badges.include?('HINGE_SUPPORT')
                     # داعم مفصلات السدّة غالبًا 1.8 × 5 × ارتفاع،
                     # ولذلك اختبار النسبة العام كان لا يعتبره :vertical
                     # (1.8 أكبر قليلًا من 35% من 5 سم) فيختفي من سجلات
                     # التجميع تمامًا. نثبته كنوع مستقل قبل اختبار الأبعاد.
                     :hinge_support
                   elsif badges.include?('FILLER_RETURN')
                     # الفيلر الخارجي/الجانبي نفس الحالة الهندسية:
                     # تخانة صغيرة X + بروز قصير Y + ارتفاع كبير Z.
                     # لازم يدخل سجلات التجميع صراحةً.
                     :filler_return
                   elsif badges.include?('DRAWER_CHASSIS') && part_name.match?(/دعامة/)
                     :drawer_chassis_tie
                   elsif badges.include?('DRAWER_CHASSIS') && part_name.match?(/جنب.*شاسيه.*الأدراج/)
                     :drawer_chassis_side
                   elsif dz <= [dx,dy].min * 0.35
                     :horizontal
                   elsif dx <= [dy,dz].min * 0.35
                     :vertical
                   end
            result << {entity:entity,kind:kind,tr:tr,x0:min_x,x1:max_x,y0:min_y,y1:max_y,z0:min_z,z1:max_z,
                       name:part_name,badges:badges} if kind
          end
          # صندوق الدرج Component مركب؛ لا ندخله إلا عند تفعيل الخيار.
          if include_drawers && entity.get_attribute('MHD_DRESSING', 'TYPE').to_s == 'B.Cajon'
            butterfly_board_records(entity.definition.entities, true, result, parent_tr * entity.transformation)
          end
        elsif entity.is_a?(Sketchup::Group)
          butterfly_board_records(entity.entities, include_drawers, result, parent_tr * entity.transformation)
        end
      end
      result
    end

    # كاش خفيف لسجلات قطع التجميع خلال دورة إنشاء واحدة.
    # التخريمات تغيّر الهندسة الداخلية فقط ولا تغيّر Bounds الألواح، لذلك
    # الفراشة والإليتا والكورنيشة/السوكلو يمكنهم مشاركة نفس الـScan بأمان.
    def joinery_board_records_cached(scan_entities, include_drawers = false)
      @joinery_records_cache ||= {}
      key = [scan_entities.object_id, include_drawers ? 1 : 0]
      cached = @joinery_records_cache[key]
      return cached if cached
      records = butterfly_board_records(scan_entities, include_drawers)
      @joinery_records_cache[key] = records
      records
    end

    def clear_joinery_records_cache
      @joinery_records_cache = nil
      true
    end

    def add_butterfly_instance(parent, model, definition, point, rotation_z, above_board, vertical_on_left, label)
      source_bounds = definition.bounds
      rotate = Geom::Transformation.rotation(ORIGIN, Z_AXIS, rotation_z)
      # عند القاعدة فقط نعكسه لأعلى؛ الرف والقرصة يحتفظان بأكسات الموديل الأصلية.
      vertical_side = above_board ? Geom::Transformation.scaling(1.0, 1.0, -1.0) : Geom::Transformation.new
      orientation = rotate * vertical_side
      oriented_points = (0..7).map { |i| source_bounds.corner(i).transform(orientation) }
      min_x,max_x = oriented_points.map(&:x).minmax
      min_y,max_y = oriented_points.map(&:y).minmax
      min_z,max_z = oriented_points.map(&:z).minmax
      # بعد ربع اللفة لا نعتمد على Origin الموديل؛ نلصق الحد الخارجي الفعلي بوجه الجنب.
      tx = vertical_on_left ? point.x-min_x : point.x-max_x
      ty = point.y-(min_y+max_y)/2.0
      tz = above_board ? point.z-min_z : point.z-max_z
      place = Geom::Transformation.translation([tx,ty,tz])
      instance = parent.add_instance(definition, place * orientation)
      instance.name = ''
      instance.set_attribute('MHD_DRESSING', 'JOINERY_ACCESSORY', true)
      instance.set_attribute('MHD_DRESSING', 'TYPE', 'BUTTERFLY_CORNER')
      set_part_badges(definition, ['HARDWARE','ACCESSORY','BUTTERFLY_CORNER'])
      definition.set_attribute('ladb_opencutlist', 'cumulable', 2)
      instance
    end

    def add_shelf_support_instance(parent, definition, point, vertical_on_left, label)
      bounds = definition.bounds
      # نفس خط توزيع زاوية الفراشة، لكن الحامل يظل قائمًا وتكون قمته
      # ملاصقة لأسفل الرف وظهره ملاصقًا لوجه الجنب الداخلي.
      rotate = Geom::Transformation.rotation(ORIGIN, Z_AXIS, vertical_on_left ? (Math::PI / 2.0) : (-Math::PI / 2.0))
      points = (0..7).map { |i| bounds.corner(i).transform(rotate) }
      min_x,max_x = points.map(&:x).minmax
      min_y,max_y = points.map(&:y).minmax
      min_z,max_z = points.map(&:z).minmax
      tx = vertical_on_left ? point.x-min_x : point.x-max_x
      ty = point.y-(min_y+max_y)/2.0
      tz = point.z-max_z
      instance = parent.add_instance(definition, Geom::Transformation.translation([tx,ty,tz]) * rotate)
      instance.name = ''
      instance.set_attribute('MHD_DRESSING', 'JOINERY_ACCESSORY', true)
      instance.set_attribute('MHD_DRESSING', 'TYPE', 'SHELF_SUPPORT')
      set_part_badges(definition, ['HARDWARE','ACCESSORY','SHELF_SUPPORT'])
      definition.set_attribute('ladb_opencutlist', 'cumulable', 2)
      instance
    end

    def add_butterfly_vertical_instance(parent, definition, point, vertical_on_left, front_tie, label)
      bounds = definition.bounds
      # اتجاه اليمين/الشمال فقط حول المحور الأزرق؛ الخلفي اليمين = 180 درجة.
      rotate_z = Geom::Transformation.rotation(ORIGIN, Z_AXIS, vertical_on_left ? 0.0 : -Math::PI)
      # الرجوع الحرفي للاتجاه المستقر المؤكد بالاختبار:
      # خلفي يمين وأمامي شمال يظلان كما كانا، بلا Mirror أو إعادة بناء.
      rotate_y = Geom::Transformation.rotation(
        ORIGIN,
        Y_AXIS,
        vertical_on_left ? (-Math::PI / 2.0) : (Math::PI / 2.0)
      )
      orientation = rotate_y * rotate_z

      # تعديل منفرد فقط للزاوية الخلفية الشمال حسب الاختبار اليدوي:
      # لف 90 درجة موجب حول المحور الأزرق Z، من دون لمس باقي الحالات.
      if !vertical_on_left && !front_tie
        rear_left_quarter_turn = Geom::Transformation.rotation(ORIGIN, Z_AXIS, Math::PI / 2.0)
        orientation = rear_left_quarter_turn * orientation
      end

      # تعديل منفرد فقط للزاوية الأمامية اليمين الفعلية:
      # لف 90 درجة موجب حول المحور الأزرق Z مثل الدوران اليدوي في الصورة.
      if vertical_on_left && front_tie
        front_right_quarter_turn = Geom::Transformation.rotation(ORIGIN, Z_AXIS, Math::PI / 2.0)
        orientation = front_right_quarter_turn * orientation
      end
      points = (0..7).map { |i| bounds.corner(i).transform(orientation) }
      min_x,max_x = points.map(&:x).minmax
      min_y,max_y = points.map(&:y).minmax
      min_z,max_z = points.map(&:z).minmax
      tx = vertical_on_left ? point.x-min_x : point.x-max_x
      ty = front_tie ? point.y-min_y : point.y-max_y
      tz = point.z-(min_z+max_z)/2.0
      instance = parent.add_instance(definition, Geom::Transformation.translation([tx,ty,tz]) * orientation)
      instance.name = ''
      instance.set_attribute('MHD_DRESSING', 'JOINERY_ACCESSORY', true)
      instance.set_attribute('MHD_DRESSING', 'TYPE', 'BUTTERFLY_DRAWER_CHASSIS')
      instance
    end


    # زاوية فراشة بين السدّة الأمامية والقرصة/القاعدة.
    # السدّة لوح رأسي مستواه X/Z، لذلك وجهها الداخلي عمودي على Y.
    # هذا هو النظير الهندسي لـ add_butterfly_instance التي تتعامل مع جنب X-thin.
    def add_butterfly_filler_horizontal_instance(parent, definition, point,
                                                  interior_toward_positive_y,
                                                  above_board, label)
      bounds = definition.bounds

      # موديل الفراشة الأصلي يناسب وجهًا رأسيًا على Y بدون ربع لفة.
      # لو داخل الدولاب في اتجاه -Y نعكسه 180° حول Z.
      rotate = Geom::Transformation.rotation(
        ORIGIN, Z_AXIS,
        interior_toward_positive_y ? 0.0 : Math::PI
      )

      # القاعدة تحمل الزاوية فوقها، والقرصة تحملها من أسفل.
      vertical_flip = above_board ?
        Geom::Transformation.scaling(1.0, 1.0, -1.0) :
        Geom::Transformation.new

      orientation = rotate * vertical_flip

      points = (0..7).map { |i| bounds.corner(i).transform(orientation) }
      min_x,max_x = points.map(&:x).minmax
      min_y,max_y = points.map(&:y).minmax
      min_z,max_z = points.map(&:z).minmax

      # نثبت مركز الزاوية على X، ونلصق حدها الفعلي بوجه السدّة الداخلي.
      tx = point.x - (min_x + max_x) / 2.0
      ty = interior_toward_positive_y ? point.y - min_y : point.y - max_y
      tz = above_board ? point.z - min_z : point.z - max_z

      place = Geom::Transformation.translation([tx, ty, tz])
      final_transform = place * orientation

      # زاوية الفراشة بين السدّة والقرصة/القاعدة فقط:
      # Rotate 180° حول مركز الإكسسوار نفسه، من غير أي ترحيل.
      # نستخدم محور Z المحلي بعد التوجيه حتى يظل الدوران "حوالين نفسه".
      source_center = bounds.center
      world_center = source_center.transform(final_transform)
      local_z_axis = Z_AXIS.transform(orientation)
      local_z_axis.normalize!
      self_rotate_180 = Geom::Transformation.rotation(
        world_center,
        local_z_axis,
        Math::PI
      )
      final_transform = self_rotate_180 * final_transform

      instance = parent.add_instance(definition, final_transform)
      instance.name = ''
      instance.set_attribute('MHD_DRESSING', 'JOINERY_ACCESSORY', true)
      instance.set_attribute('MHD_DRESSING', 'TYPE', 'BUTTERFLY_CORNER')
      instance.set_attribute('MHD_DRESSING', 'SIDE_FILLER_JOINT', true)
      set_part_badges(definition, ['HARDWARE','ACCESSORY','BUTTERFLY_CORNER'])
      definition.set_attribute('ladb_opencutlist', 'cumulable', 2)
      instance
    end

    # يختار قاعدة التدعيم الأعلى التي تنطبق على طول خط الالتقاء.
    # القواعد لا تتجمع: 65=>1 و150=>2 يعني 180 سم = زاويتان إضافيتان فقط.
    def butterfly_extra_count_for_span(span)
      span_cm = span.to_f / 1.cm.to_f
      rules = Array(@butterfly_support_rules).filter_map do |rule|
        next unless rule.is_a?(Hash)
        threshold = rule['threshold'].to_f
        count = [[rule['count'].to_i, 1].max, 3].min
        next unless threshold > 0
        [threshold, count]
      end
      matched = rules.select { |threshold, _count| span_cm > threshold }.max_by(&:first)
      matched ? matched[1] : 0
    end

    def butterfly_position_blocked?(position, forbidden_positions, clearance)
      Array(forbidden_positions).any? { |blocked| (position - blocked).abs < clearance }
    end

    # يحرك الزاوية الإضافية لأقرب مكان آمن لو صادفت نقطة التقاء جسم آخر.
    def butterfly_nearest_safe_position(wanted, min_pos, max_pos, forbidden_positions, clearance)
      return wanted unless butterfly_position_blocked?(wanted, forbidden_positions, clearance)
      step = 1.cm
      max_steps = [(((max_pos-min_pos).abs/step).ceil rescue 0), 1].max
      1.upto(max_steps) do |i|
        delta = i * step
        [wanted-delta, wanted+delta].each do |candidate|
          next if candidate < min_pos || candidate > max_pos
          return candidate unless butterfly_position_blocked?(candidate, forbidden_positions, clearance)
        end
      end
      nil
    end

    # زاويتان أساسيتان عند الطرفين، ثم عدد إضافي حسب قواعد العميل.
    # الزوايا الإضافية فقط هي التي تتحرك لتفادي نقاط الالتقاء.
    def butterfly_distribution_points(start_pos, end_pos, offset, forbidden_positions = [])
      span = end_pos - start_pos
      return [] if span <= 0

      if span <= offset*2 + 0.5.cm
        midpoint = (start_pos+end_pos)/2.0
        safe = butterfly_nearest_safe_position(midpoint, start_pos, end_pos, forbidden_positions, 3.cm)
        return safe ? [safe] : []
      end

      first = start_pos + offset
      last = end_pos - offset
      points = [first, last]

      extra_count = butterfly_extra_count_for_span(span)
      if extra_count > 0 && last > first
        clearance = [offset, 3.cm].max
        extra_count.times do |index|
          wanted = first + (last-first)*(index+1).to_f/(extra_count+1).to_f
          safe = butterfly_nearest_safe_position(
            wanted,
            first + 0.5.cm,
            last - 0.5.cm,
            forbidden_positions,
            clearance
          )
          points << safe if safe
        end
      end
      points.compact.uniq.sort
    end

    # نقاط Z الممنوعة على خط رأسي: أي لوح أفقي يقطع نفس X/Y.
    def butterfly_forbidden_z_positions(records, x, y, exclude_entities = [])
      excluded = Array(exclude_entities).compact.map(&:object_id)
      Array(records).filter_map do |record|
        next if excluded.include?(record[:entity].object_id)
        next unless record[:kind] == :horizontal
        next unless x >= record[:x0]-0.2.cm && x <= record[:x1]+0.2.cm
        next unless y >= record[:y0]-0.2.cm && y <= record[:y1]+0.2.cm
        (record[:z0]+record[:z1])/2.0
      end
    end

    # نقاط X الممنوعة على خط أفقي: أي لوح رأسي يقطع نفس Y/Z.
    def butterfly_forbidden_x_positions(records, y, z, exclude_entities = [])
      excluded = Array(exclude_entities).compact.map(&:object_id)
      Array(records).filter_map do |record|
        next if excluded.include?(record[:entity].object_id)
        next unless [:vertical, :side_filler, :drawer_chassis_side].include?(record[:kind])
        next unless y >= record[:y0]-0.2.cm && y <= record[:y1]+0.2.cm
        next unless z >= record[:z0]-0.2.cm && z <= record[:z1]+0.2.cm
        (record[:x0]+record[:x1])/2.0
      end
    end


    def build_butterfly_joinery(scan_entities, target_entities, model, data)
      offset = [data['butterfly_edge_offset'].to_f, 0.5].max.cm
      @butterfly_support_rules = Array(data['butterfly_support_rules'])
      @butterfly_support_rules = [{'threshold'=>65.0,'count'=>1}] if @butterfly_support_rules.empty?
      include_drawers = %w[yes true 1].include?(data['butterfly_apply_drawers'].to_s.downcase)
      records = joinery_board_records_cached(scan_entities, include_drawers)
      horizontals = records.select { |r| r[:kind] == :horizontal }
      # حامل الرف تخصيص للرف المحدد فقط. لا نعتمد على الاسم أو اتجاه القطعة
      # حتى لا تدخل القواطيع أو الأجناب أو بقية الأرفف في هذا المنطق.
      butterfly_enabled = data['joinery_system'].to_s == 'butterfly'
      shelf_support_mode = lambda do |record|
        role = record[:entity].get_attribute('MHD_DRESSING', 'SHELF_ROLE').to_s
        override = record[:entity].get_attribute('MHD_DRESSING', 'SHELF_SUPPORT_TYPE').to_s
        actual_shelf = role == 'actual'
        if actual_shelf && (override.empty? || override == 'default' || override == 'pin')
          :shelf_support
        elsif actual_shelf && override == 'butterfly'
          :butterfly
        elsif butterfly_enabled
          :butterfly
        end
      end
      support_shelves = horizontals.select { |record| shelf_support_mode.call(record) == :shelf_support }
      butterfly_shelves = horizontals.select { |record| shelf_support_mode.call(record) == :butterfly }
      return if support_shelves.empty? && butterfly_shelves.empty?
      definition = butterfly_shelves.empty? ? nil : butterfly_definition(model)
      definition.name = qualified_part_name('زاوية فراشة') if definition
      support_definition = support_shelves.empty? ? nil : shelf_support_definition(model)
      support_definition.name = qualified_part_name('حامل رف') if support_definition
      drawer_sides = records.select { |r| r[:kind] == :drawer_chassis_side }
      verticals = records.select { |r| r[:kind] == :vertical }
      drawer_ties = records.select { |r| r[:kind] == :drawer_chassis_tie }
      side_fillers = records.select { |r| r[:kind] == :side_filler }
      used = {}
      number = 0
      horizontals.each do |horizontal|
        joinery_mode = shelf_support_mode.call(horizontal)
        next unless joinery_mode
        custom_shelf_support = joinery_mode == :shelf_support
        # القاعدة وقواعد الأدراج تحمل الزاوية فوقها؛ باقي الألواح والقرصة تحملها من أسفل.
        above_board = horizontal[:name].to_s.match?(/قاعدة/) || horizontal[:badges].include?('DRAWER_BOTTOM')
        horizontal_is_drawer_chassis = horizontal[:badges].include?('DRAWER_CHASSIS')
        matching_verticals = if horizontal_is_drawer_chassis
          # قرصة شاسيه الأدراج تتجمع أصلًا مع جنبي الشاسيه الداخليين.
          # لا نربطها بجنبي الدولاب الخارجيين. نضيف فقط القاطوع الحقيقي
          # عند الحد المشترك إذا كانت فتحة الأدراج بجوار فراغ آخر.
          left_boundary = horizontal[:entity].get_attribute('MHD_DRESSING', 'DRAWER_TOP_LEFT_BOUNDARY').to_s
          right_boundary = horizontal[:entity].get_attribute('MHD_DRESSING', 'DRAWER_TOP_RIGHT_BOUNDARY').to_s
          bay_x0 = horizontal[:entity].get_attribute('MHD_DRESSING', 'DRAWER_TOP_BAY_X0').to_f.cm
          bay_x1 = horizontal[:entity].get_attribute('MHD_DRESSING', 'DRAWER_TOP_BAY_X1').to_f.cm
          extension_side = horizontal[:entity].get_attribute('MHD_DRESSING', 'DRAWER_TOP_EXTENSION_SIDE').to_s
          partition_edges = verticals.select do |vertical|
            next false unless vertical[:badges].include?('PARTITION')
            on_left = left_boundary == 'partition' && (vertical[:x1] - bay_x0).abs <= 0.2.cm
            on_right = right_boundary == 'partition' && (vertical[:x0] - bay_x1).abs <= 0.2.cm
            on_left || on_right
          end
          # لو القرصة ممتدة فوق فراغ مجاور، تربط أيضًا بالطرف المقابل
          # للقطاع، بينما يظل صندوق الأدراج نفسه داخل فتحته الأصلية.
          far_edge = verticals.select do |vertical|
            next false if vertical[:badges].include?('DRAWER_CHASSIS')
            at_left = extension_side == 'left' && (vertical[:x1] - horizontal[:x0]).abs <= 0.2.cm
            at_right = extension_side == 'right' && (vertical[:x0] - horizontal[:x1]).abs <= 0.2.cm
            at_left || at_right
          end
          drawer_sides + partition_edges + far_edge
        else
          verticals
        end
        matching_verticals.each do |vertical|
          x_touch = vertical[:x1] >= horizontal[:x0]-0.15.cm && vertical[:x0] <= horizontal[:x1]+0.15.cm
          z_touch = vertical[:z1] >= horizontal[:z0]-0.15.cm && vertical[:z0] <= horizontal[:z1]+0.15.cm
          y0 = [horizontal[:y0], vertical[:y0]].max
          y1 = [horizontal[:y1], vertical[:y1]].min
          next unless x_touch && z_touch && y1-y0 > offset*2+0.5.cm
          vertical_on_left = (vertical[:x0]+vertical[:x1])/2.0 <= (horizontal[:x0]+horizontal[:x1])/2.0
          # نركب على وجه الجنب الداخلي لا في منتصف تخانته.
          x = vertical_on_left ? vertical[:x1] : vertical[:x0]
          z = above_board ? horizontal[:z1] : horizontal[:z0]
          # أكسات موديل الفراشة تحتاج ربع لفة حتى يصبح وجهها العمودي ملاصقًا للجنب.
          rotation = vertical_on_left ? (Math::PI / 2.0) : (-Math::PI / 2.0)
          y_points = if custom_shelf_support
                       # حامل الرف يظل بمنطقه الحالي: نقطتان فقط.
                       [y0+offset, y1-offset]
                     else
                       butterfly_distribution_points(y0, y1, offset)
                     end
          y_points.each do |y|
            key = [custom_shelf_support ? :shelf_support : :butterfly,(x/0.1.cm).round,(y/0.1.cm).round,(z/0.1.cm).round]
            next if used[key]
            used[key] = true
            number += 1
            if custom_shelf_support
              add_shelf_support_instance(target_entities, support_definition, Geom::Point3d.new(x,y,horizontal[:z0]), vertical_on_left, "حامل رف #{number}")
            else
              add_butterfly_instance(target_entities, model, definition, Geom::Point3d.new(x,y,z), rotation, above_board, vertical_on_left, "زاوية فراشة #{number}")
            end
          end
        end
      end

      # ============================================================
      # زاوية الفراشة للسدّة
      #
      # عند اختيار "زاوية فراشة" كنظام التجميع نضيف الفراشة في نقاط
      # التقاء السدّة مع:
      #   1) الجنب الخارجي.
      #   2) القرصة.
      #   3) القاعدة.
      #
      # لا نغيّر أي منطق للأرفف أو شاسيه الأدراج.
      # ============================================================
      if butterfly_enabled && definition
        side_fillers.each do |filler|
          filler_side = filler[:entity].get_attribute('MHD_DRESSING', 'SIDE_FILLER').to_s
          next unless %w[left right].include?(filler_side)

          # الجنب الخارجي الأقرب لنفس ناحية السدّة.
          carcass_sides = verticals.select do |record|
            record[:badges].include?('MAIN_CARCASS') &&
              !record[:badges].include?('PARTITION')
          end
          side_record = if filler_side == 'left'
                          carcass_sides.min_by { |record| record[:x0] }
                        else
                          carcass_sides.max_by { |record| record[:x1] }
                        end

          # القرصة والقاعدة الرئيسيتان فقط.
          carcass_horizontals = horizontals.select do |record|
            record[:badges].include?('MAIN_CARCASS') &&
              !record[:badges].include?('DRAWER_CHASSIS')
          end
          top_record = carcass_horizontals.select { |record|
            record[:name].to_s.match?(/قرصة|سقف/)
          }.max_by { |record| record[:z1] }
          base_record = carcass_horizontals.select { |record|
            record[:name].to_s.match?(/قاعدة/)
          }.min_by { |record| record[:z0] }

          # وجه السدّة الذي ينظر إلى داخل الدولاب يُحدد هندسيًا من مركز
          # الشاسيه، بدل افتراض اتجاه Y ثابت.
          filler_center_y = (filler[:y0] + filler[:y1]) / 2.0
          reference_y = if side_record
                          (side_record[:y0] + side_record[:y1]) / 2.0
                        elsif top_record
                          (top_record[:y0] + top_record[:y1]) / 2.0
                        else
                          filler_center_y
                        end
          interior_toward_positive_y = reference_y >= filler_center_y
          filler_inner_y = interior_toward_positive_y ? filler[:y1] : filler[:y0]

          # ---------- السدّة × الجنب ----------
          # نفس منطق الدعامات الرأسية: زاويتان قرب أعلى وأسفل خط الالتقاء.
          if side_record
            z0 = [filler[:z0], side_record[:z0]].max
            z1 = [filler[:z1], side_record[:z1]].min
            if z1 - z0 > offset * 2 + 0.5.cm
              side_center_x = (side_record[:x0] + side_record[:x1]) / 2.0
              filler_center_x = (filler[:x0] + filler[:x1]) / 2.0
              vertical_on_left = side_center_x <= filler_center_x

              # نضع الزاوية على الوجه الداخلي الحقيقي للجنب.
              x = vertical_on_left ? side_record[:x1] : side_record[:x0]
              front_tie = filler_center_y < (side_record[:y0] + side_record[:y1]) / 2.0

              forbidden_z = butterfly_forbidden_z_positions(
                records, x, filler_inner_y, [filler[:entity], side_record[:entity]]
              )
              butterfly_distribution_points(z0, z1, offset, forbidden_z).each do |z|
                key = [:filler_side_butterfly,
                       (x/0.1.cm).round,
                       (filler_inner_y/0.1.cm).round,
                       (z/0.1.cm).round]
                next if used[key]
                used[key] = true
                number += 1

                add_butterfly_vertical_instance(
                  target_entities, definition,
                  Geom::Point3d.new(x, filler_inner_y, z),
                  vertical_on_left, front_tie,
                  "زاوية فراشة سدّة مع جنب #{number}"
                )
              end
            end
          end

          # نقاط X داخل عرض السدّة للقرصة والقاعدة.
          # لو عرض السدّة يسمح نستخدم نقطتين، ولو ضيق نستخدم نقطة في المنتصف.
          overlap_x0 = filler[:x0]
          overlap_x1 = filler[:x1]
          # ---------- السدّة × القرصة ----------
          if top_record
            z = top_record[:z0]
            forbidden_x = butterfly_forbidden_x_positions(
              records, filler_inner_y, z, [filler[:entity], top_record[:entity]]
            )
            filler_x_points = butterfly_distribution_points(
              overlap_x0, overlap_x1, offset, forbidden_x
            )
            filler_x_points.each do |x|
              key = [:filler_top_butterfly,
                     (x/0.1.cm).round,
                     (filler_inner_y/0.1.cm).round,
                     (z/0.1.cm).round]
              next if used[key]
              used[key] = true
              number += 1

              add_butterfly_filler_horizontal_instance(
                target_entities, definition,
                Geom::Point3d.new(x, filler_inner_y, z),
                interior_toward_positive_y,
                false,
                "زاوية فراشة سدّة مع قرصة #{number}"
              )
            end
          end

          # ---------- السدّة × القاعدة ----------
          if base_record
            z = base_record[:z1]
            forbidden_x = butterfly_forbidden_x_positions(
              records, filler_inner_y, z, [filler[:entity], base_record[:entity]]
            )
            filler_x_points = butterfly_distribution_points(
              overlap_x0, overlap_x1, offset, forbidden_x
            )
            filler_x_points.each do |x|
              key = [:filler_base_butterfly,
                     (x/0.1.cm).round,
                     (filler_inner_y/0.1.cm).round,
                     (z/0.1.cm).round]
              next if used[key]
              used[key] = true
              number += 1

              add_butterfly_filler_horizontal_instance(
                target_entities, definition,
                Geom::Point3d.new(x, filler_inner_y, z),
                interior_toward_positive_y,
                true,
                "زاوية فراشة سدّة مع قاعدة #{number}"
              )
            end
          end
        end
      end

      # الشاسيه الخارجي للأدراج وحدة مستقلة: الأربع دعامات الأمامية والخلفية
      # تتجمع مع جنبيه، بزاويتين قرب أول وآخر ارتفاع لكل دعامة.
      drawer_ties.each do |tie|
        next unless butterfly_enabled
        drawer_sides.each do |side|
          x_touch = side[:x1] >= tie[:x0]-0.15.cm && side[:x0] <= tie[:x1]+0.15.cm
          z0 = [side[:z0], tie[:z0]].max
          z1 = [side[:z1], tie[:z1]].min
          next unless x_touch && z1-z0 > offset*2+0.5.cm
          vertical_on_left = (side[:x0]+side[:x1])/2.0 <= (tie[:x0]+tie[:x1])/2.0
          x = vertical_on_left ? side[:x1] : side[:x0]
          front_tie = tie[:name].to_s.include?('أمامية')
          y = front_tie ? tie[:y1] : tie[:y0]
          forbidden_z = butterfly_forbidden_z_positions(
            records, x, y, [side[:entity], tie[:entity]]
          )
          butterfly_distribution_points(z0, z1, offset, forbidden_z).each do |z|
            key = [:drawer,(x/0.1.cm).round,(y/0.1.cm).round,(z/0.1.cm).round]
            next if used[key]
            used[key] = true
            number += 1
            add_butterfly_vertical_instance(target_entities, definition, Geom::Point3d.new(x,y,z), vertical_on_left, front_tie, "زاوية فراشة شاسيه أدراج #{number}")
          end
        end
      end
    end

    # يرسم دائرة على وجه اللوح نفسه ثم يدفعها إلى الداخل. في SketchUp
    # ينتج عن ذلك ثقب هندسي حقيقي في Definition القطعة، وليس علامة أو
    # إكسسوارًا موضوعًا فوقها.
    def drill_round_hole(instance, world_tr, world_start, world_direction, depth, diameter, drill_type, number)
      return false unless instance && instance.valid? && depth.to_f > 0 && diameter.to_f > 0
      # حماية نهائية لتجميعة شاسيه الأدراج السميك، مستقلة عن مسار اكتشاف
      # الالتقاء: الدعامة تستقبل الفيشر فقط، والجنب يستقبل المسمار ووش الربط.
      part_name = "#{instance.name} #{instance.definition.name}"
      badges = joinery_badges(instance)
      drawer_chassis_part = badges.include?('DRAWER_CHASSIS')
      drawer_chassis_tie = drawer_chassis_part && part_name.match?(/دعامة.*شاسيه.*الأدراج/)
      drawer_chassis_side = drawer_chassis_part && part_name.match?(/جنب.*شاسيه.*الأدراج/)
      return false if drawer_chassis_tie && !%w[DOWEL COIL].include?(drill_type.to_s)
      return false if drawer_chassis_side && drill_type.to_s == 'DOWEL'

      definition = instance.definition
      tr = world_tr || instance.transformation
      inverse = tr.inverse
      world_normal = world_direction.clone
      return false if world_normal.length <= 0.0001
      world_normal.normalize!
      local_start = world_start.transform(inverse)
      world_end = world_start.offset(world_normal, depth)
      local_end = world_end.transform(inverse)
      local_direction = local_start.vector_to(local_end)
      local_depth = local_direction.length
      return false if local_depth <= 0.01.mm
      local_direction.normalize!

      radius_world = diameter.to_f / 2.0
      # لا نستخدم add_circle بنصف قطر محلي واحد؛ لأن الـDynamic Component
      # قد يكون ممدودًا بنسب مختلفة على محوري الضلفة، فتظهر الدائرة بيضاوية.
      # نبني نقاط المحيط كدائرة في إحداثيات التجميعة أولًا، ثم نحوّل كل نقطة
      # منفردة إلى Definition القطعة، فتظل النتيجة النهائية دائرة حقيقية.
      reference = world_normal.parallel?(Z_AXIS) ? X_AXIS : Z_AXIS
      axis_u = world_normal * reference
      if axis_u.length <= 0.0001
        reference = Y_AXIS
        axis_u = world_normal * reference
      end
      axis_u.normalize!
      axis_v = world_normal * axis_u
      axis_v.normalize!

      segments = 16
      local_points = segments.times.map do |index|
        angle = 2.0 * Math::PI * index / segments
        cos_radius = Math.cos(angle) * radius_world
        sin_radius = Math.sin(angle) * radius_world
        offset = Geom::Vector3d.new(
          axis_u.x * cos_radius + axis_v.x * sin_radius,
          axis_u.y * cos_radius + axis_v.y * sin_radius,
          axis_u.z * cos_radius + axis_v.z * sin_radius
        )
        world_start.offset(offset).transform(inverse)
      end
      # المسار السريع: add_face ينشئ حدود الحلقة بنفسه، فلا نضيف 16 Edge
      # يدويًا ثم نبحث في Faces الناتجة. في أغلب ألواح الدريسنج هذا يرجع
      # وجه دائرة التخريم مباشرة ويوفر عددًا كبيرًا من أوامر Entities.
      face = definition.entities.add_face(local_points)

      # Fallback محافظ للحالات الهندسية النادرة التي يكون فيها الوجه موجودًا
      # مسبقًا أو يرفض SketchUp إرجاع Face مباشرة. لا نستخدمه إلا عند الحاجة،
      # وبالتالي نحافظ على نفس موثوقية المسار القديم بدون تكلفته في كل ثقب.
      unless face && face.valid?
        edges = local_points.each_with_index.map do |point, index|
          definition.entities.add_line(point, local_points[(index + 1) % segments])
        end.compact
        candidates = edges.flat_map(&:faces).uniq.select(&:valid?)
        face = candidates.min_by(&:area)
      end
      return false unless face && face.valid?
      push = face.normal.dot(local_direction) >= 0 ? local_depth : -local_depth
      face.pushpull(push)

      holes = instance.get_attribute('MHD_DRESSING', 'ELITA_REAL_HOLES', [])
      holes = [] unless holes.is_a?(Array)
      holes << {
        'number' => number, 'type' => drill_type,
        'diameter_cm' => (diameter.to_f / 1.cm.to_f).round(3),
        'depth_cm' => (depth.to_f / 1.cm.to_f).round(3),
        'x_cm' => (world_start.x / 1.cm.to_f).round(3),
        'y_cm' => (world_start.y / 1.cm.to_f).round(3),
        'z_cm' => (world_start.z / 1.cm.to_f).round(3)
      }
      instance.set_attribute('MHD_DRESSING', 'ELITA_REAL_HOLES', holes)
      definition.set_attribute('MHD_DRESSING', 'HAS_ELITA_REAL_DRILLING', true)

      # اتجاه الـCutList تم تثبيته وقت إنشاء القطعة نفسها. هنا نسجل فقط
      # أن القطعة أخذت CAM لأغراض التشخيص، من دون Queue أو إعادة تدوير لاحقة.
      if drill_type.to_s == 'CAM'
        instance.set_attribute('MHD_DRESSING', 'OCL_ELITA_HAS_FACE_DRILLING', true)
        definition.set_attribute('MHD_DRESSING', 'OCL_ELITA_HAS_FACE_DRILLING', true)
      end
      true
    rescue => error
      raise "تعذر تنفيذ تخريم #{drill_type} في #{instance.name}: #{error.message}"
    end

    # يركب ملف minifix.skp على نفس خط التخريم الحقيقي. نكتشف المحور
    # الأطول في الموديل تلقائيًا ونوجهه من نهاية الفيشر نحو وش الربط؛
    # وبذلك يعمل نفس الملف في الالتقاء الأفقي والرأسي من دون موضع تقريبي.
    # يركّب موديل الإليتا على التخريم الحقيقي فقط.
    #
    # المرجع الهندسي المؤكد من ملف minifix.skp الأصلي:
    # - محور المسمار/الفيشر المحلي = Y.
    # - جسم الإكسسوار يمتد ناحية الفيشر في اتجاه -Y.
    # - محور وش الربط المحلي = X.
    # - مركز وش الربط المرجعي داخل الموديل ≈ (0.75, 0.0, 0.75) سم.
    #
    # لذلك لا نغيّر أي تخريم إطلاقًا. نأخذ:
    #   screw_direction من تخريم المسمار،
    #   cam_direction   من تخريم وش الربط،
    #   cam_center      من مركز تخريم وش الربط الفعلي،
    # ونبني Transform للإكسسوار فوقهم فقط.
    #
    # معاملات اللفات القديمة باقية في التوقيع للتوافق مع الاستدعاءات
    # التاريخية، لكنها لم تعد تغيّر موضع/اتجاه الإكسسوار.
    def add_elita_accessory(parent, definition, joint, screw_direction, cam_direction,
                            dowel_depth, number, data, cam_center = nil,
                            flip_vertical_left_face = false,
                            flip_vertical_lower_joint = false,
                            flip_drawer_chassis_top_xz = false,
                            rotate_drawer_support_xy_90 = false,
                            flip_selected_drawer_support_x_180 = false,
                            rotate_other_drawer_support_y_90 = false)
      return nil unless definition && parent

      screw_axis = screw_direction.clone
      screw_axis.normalize!

      cam_axis = cam_direction.clone
      cam_axis.normalize!

      # يجب أن يكون محور وش الربط عموديًا على محور المسمار.
      # لو حدث خطأ عددي صغير نزيل مركبته على محور المسمار فقط؛
      # هذا لا يغيّر التخريم، بل ينظف Basis الإكسسوار.
      dot = cam_axis.dot(screw_axis)
      cam_axis = Geom::Vector3d.new(
        cam_axis.x - screw_axis.x * dot,
        cam_axis.y - screw_axis.y * dot,
        cam_axis.z - screw_axis.z * dot
      )
      raise 'اتجاه وش ربط الإليتا موازي لمحور المسمار.' if cam_axis.length < 0.001
      cam_axis.normalize!

      # من تركيب الموديل الأصلي:
      # local +Y = اتجاه المسمار إلى داخل قطعة المسمار.
      # local -Y = من وش الربط ناحية نقطة الالتقاء ثم الفيشر.
      # local +X = عكس اتجاه حفر وش الربط إلى الداخل.
      local_x_world = cam_axis.reverse
      local_y_world = screw_axis
      local_z_world = local_x_world * local_y_world
      raise 'تعذر تكوين محاور إكسسوار الإليتا.' if local_z_world.length < 0.001
      local_z_world.normalize!

      # مركز وش الربط الحقيقي المستخدم في التخريم.
      # كل الاستدعاءات الجديدة تمرره صراحةً؛ fallback فقط للوحدات القديمة.
      actual_cam_center = cam_center || joint.offset(
        screw_axis,
        [data['elita_screw_after_thread'].to_f, 0.01].max.cm
      )

      # مركز الكامة في ملف minifix.skp طبقًا لتقرير الموديل الأصلي.
      source_cam_center = Geom::Point3d.new(0.75.cm, 0.0, 0.75.cm)

      axes = Geom::Transformation.axes(
        ORIGIN,
        local_x_world,
        local_y_world,
        local_z_world
      )

      transformed_source_center = source_cam_center.transform(axes)
      translation = Geom::Transformation.translation(
        transformed_source_center.vector_to(actual_cam_center)
      )

      accessory_transform = translation * axes

      # لا نغيّر أي تخريم. فقط نمنع موديل الإليتا من الدخول في
      # الخشبة جهة الفيشر أكثر من عمق تخريم الفيشر الفعلي.
      #
      # joint = سطح التقاء القطعتين.
      # اتجاه -screw_axis هو جهة الفيشر.
      # نحسب أبعد نقطة فعلية من Bounds الإكسسوار بعد الـTransform،
      # ولو دخلت أكثر من dowel_depth نرجّع الإكسسوار ناحية قطعة المسمار
      # بمقدار الزيادة فقط. الدوران والتمركز العرضي يظلان كما هما.
      transformed_points = (0..7).map do |i|
        definition.bounds.corner(i).transform(accessory_transform)
      end

      dowel_penetrations = transformed_points.map do |point|
        v = joint.vector_to(point)
        -v.dot(screw_axis)
      end

      actual_penetration = dowel_penetrations.max.to_f
      allowed_penetration = [dowel_depth.to_f, 0.0].max

      if actual_penetration > allowed_penetration + 0.01.mm
        correction = actual_penetration - allowed_penetration
        accessory_transform = Geom::Transformation.translation(
          screw_axis.clone.tap { |axis| axis.length = correction }
        ) * accessory_transform
      end

      instance = parent.add_instance(definition, accessory_transform)
      instance.name = ''
      instance.set_attribute('MHD_DRESSING', 'JOINERY_ACCESSORY', true)
      instance.set_attribute('MHD_DRESSING', 'TYPE', 'ELITA_MINIFIX')
      instance.set_attribute('MHD_DRESSING', 'MATCHED_REAL_DRILLING', true)
      instance.set_attribute('MHD_DRESSING', 'ACCESSORY_PLACEMENT_MODE', 'DRILLING_REFERENCE_V2_DOWEL_DEPTH_CLAMP')
      instance.set_attribute('MHD_DRESSING', 'MAX_DOWEL_PENETRATION_CM', dowel_depth.to_f / 1.cm.to_f)
      instance.set_attribute('MHD_DRESSING', 'SOURCE_SCREW_AXIS', 'LOCAL_Y')
      instance.set_attribute('MHD_DRESSING', 'SOURCE_DOWEL_DIRECTION', 'LOCAL_-Y')
      instance.set_attribute('MHD_DRESSING', 'SOURCE_CAM_AXIS', 'LOCAL_X')
      instance.set_attribute('MHD_DRESSING', 'SOURCE_CAM_CENTER_CM', '0.75,0.0,0.75')
      instance.set_attribute('MHD_DRESSING', 'SCREW_DIAMETER_CM', data['elita_screw_drill_diameter'].to_f)
      instance.set_attribute('MHD_DRESSING', 'SCREW_AFTER_THREAD_CM', data['elita_screw_after_thread'].to_f)
      instance.set_attribute('MHD_DRESSING', 'DOWEL_DIAMETER_CM', data['elita_dowel_diameter'].to_f)
      instance.set_attribute('MHD_DRESSING', 'DOWEL_DEPTH_CM', data['elita_dowel_depth'].to_f)
      instance.set_attribute('MHD_DRESSING', 'CAM_DIAMETER_CM', data['elita_cam_diameter'].to_f)
      instance.set_attribute('MHD_DRESSING', 'CAM_DEPTH_CM', data['elita_cam_depth'].to_f)

      # معلومات تشخيصية فقط؛ لا تُستخدم لتغيير التخريم.
      instance.set_attribute('MHD_DRESSING', 'DRILL_JOINT_X_CM', joint.x.to_f / 1.cm.to_f)
      instance.set_attribute('MHD_DRESSING', 'DRILL_JOINT_Y_CM', joint.y.to_f / 1.cm.to_f)
      instance.set_attribute('MHD_DRESSING', 'DRILL_JOINT_Z_CM', joint.z.to_f / 1.cm.to_f)
      instance.set_attribute('MHD_DRESSING', 'CAM_CENTER_X_CM', actual_cam_center.x.to_f / 1.cm.to_f)
      instance.set_attribute('MHD_DRESSING', 'CAM_CENTER_Y_CM', actual_cam_center.y.to_f / 1.cm.to_f)
      instance.set_attribute('MHD_DRESSING', 'CAM_CENTER_Z_CM', actual_cam_center.z.to_f / 1.cm.to_f)

      set_part_badges(definition, ['HARDWARE','ACCESSORY','ELITA_MINIFIX'])
      definition.set_attribute('ladb_opencutlist', 'cumulable', 2)
      instance
    end

    def elita_extra_count_for_span(span)
      span_cm = span.to_f / 1.cm.to_f
      rules = Array(@elita_support_rules).filter_map do |rule|
        next unless rule.is_a?(Hash)
        threshold = rule['threshold'].to_f
        count = [[rule['count'].to_i, 1].max, 3].min
        next unless threshold > 0
        [threshold, count]
      end
      matched = rules.select { |threshold, _count| span_cm > threshold }.max_by(&:first)
      matched ? matched[1] : 0
    end

    def elita_distribution_centers(start_pos, end_pos, first_center, last_center,
                                   forbidden_positions = [], clearance = 3.cm)
      return [] if end_pos <= start_pos
      points = [first_center, last_center].compact
      extra_count = elita_extra_count_for_span(end_pos-start_pos)
      return points.uniq.sort if extra_count <= 0 || last_center <= first_center

      extra_count.times do |index|
        wanted = first_center + (last_center-first_center)*(index+1).to_f/(extra_count+1).to_f
        safe = butterfly_nearest_safe_position(
          wanted, first_center+0.5.cm, last_center-0.5.cm,
          forbidden_positions, clearance
        )
        points << safe if safe
      end
      points.compact.uniq.sort
    end

    def elita_forbidden_y_positions(records, x, z, exclude_entities = [])
      excluded = Array(exclude_entities).compact.map(&:object_id)
      Array(records).filter_map do |record|
        next if excluded.include?(record[:entity].object_id)
        next unless x >= record[:x0]-0.2.cm && x <= record[:x1]+0.2.cm
        next unless z >= record[:z0]-0.2.cm && z <= record[:z1]+0.2.cm
        (record[:y0]+record[:y1])/2.0
      end
    end

    def elita_extra_joint_spec(center, axis_key, center_distance, coil_count, mid_pos)
      inward_sign = center <= mid_pos ? 1.0 : -1.0
      coil_key = axis_key == :y ? :coil_ys : :coil_zs
      coils = if coil_count == 2
                [center-center_distance, center+center_distance]
              else
                [center+inward_sign*center_distance]
              end
      {axis_key => center, coil_key => coils}
    end

    def local_joinery_extra_count(span, rules)
      span_cm = span.to_f / 1.cm.to_f
      parsed = Array(rules).filter_map do |rule|
        next unless rule.is_a?(Hash)
        threshold = rule['threshold'].to_f
        count = [[rule['count'].to_i, 1].max, 3].min
        next unless threshold > 0
        [threshold, count]
      end
      matched = parsed.select { |threshold, _| span_cm > threshold }.max_by(&:first)
      matched ? matched[1] : 0
    end

    def local_joinery_points(start_pos, end_pos, offset, rules, forbidden = [], clearance = 3.cm)
      span = end_pos - start_pos
      return [] if span <= 0
      if span <= offset * 2 + 0.5.cm
        midpoint = (start_pos + end_pos) / 2.0
        safe = butterfly_nearest_safe_position(midpoint, start_pos, end_pos, forbidden, clearance)
        return safe ? [safe] : []
      end
      first = start_pos + offset
      last = end_pos - offset
      points = [first, last]
      extra = local_joinery_extra_count(span, rules)
      extra.times do |index|
        wanted = first + (last - first) * (index + 1).to_f / (extra + 1).to_f
        safe = butterfly_nearest_safe_position(
          wanted, first + 0.5.cm, last - 0.5.cm, forbidden, clearance
        )
        points << safe if safe
      end
      points.compact.uniq.sort
    end

    def build_cornice_plinth_joinery(scan_entities, target_entities, model, data)
      records = joinery_board_records_cached(scan_entities, false)
      return if records.empty?

      carcass_h = records.select do |record|
        record[:kind] == :horizontal &&
          record[:badges].include?('MAIN_CARCASS') &&
          !record[:badges].include?('DRAWER_CHASSIS')
      end
      cornice_fronts = records.select { |r| r[:kind] == :top_cornice_front }
      plinth_rails = records.select { |r| r[:kind] == :wood_plinth_rail }
      plinth_sides = records.select { |r| r[:kind] == :wood_plinth_side }
      plinth_supports = records.select { |r| r[:kind] == :wood_plinth_support }

      screw_diameter = [data['elita_screw_drill_diameter'].to_f, 0.01].max.cm
      dowel_diameter = [data['elita_dowel_diameter'].to_f, 0.01].max.cm
      requested_dowel_depth = [data['elita_dowel_depth'].to_f, 0.01].max.cm
      cam_diameter = [data['elita_cam_diameter'].to_f, 0.01].max.cm
      requested_cam_depth = [data['elita_cam_depth'].to_f, 0.01].max.cm
      screw_reach = [data['elita_screw_after_thread'].to_f, 0.01].max.cm
      coil_count = data['elita_coil_count'].to_i == 2 ? 2 : 1
      coil_diameter = [data['elita_coil_drill_diameter'].to_f, 0.01].max.cm
      coil_length_cm = [data['elita_coil_length'].to_f, 0.02].max
      coil_face_cm = [[data['elita_coil_face_depth'].to_f, 0.01].max, coil_length_cm - 0.01].min
      coil_face_depth = coil_face_cm.cm
      coil_thickness_depth = (coil_length_cm - coil_face_cm).cm
      coil_distance = [data['elita_coil_center_distance'].to_f, 0.01].max.cm

      butterfly_def = nil
      elita_def = nil
      used = {}

      join_front = lambda do |trim, horizontal, system, offset, rules, above_horizontal, forbidden_x, label|
        next unless trim && horizontal
        x0 = [trim[:x0], horizontal[:x0]].max
        x1 = [trim[:x1], horizontal[:x1]].min
        next if x1 - x0 <= 1.cm

        trim_center_y = (trim[:y0] + trim[:y1]) / 2.0
        horizontal_center_y = (horizontal[:y0] + horizontal[:y1]) / 2.0
        interior_positive_y = horizontal_center_y >= trim_center_y
        trim_face_y = interior_positive_y ? trim[:y1] : trim[:y0]

        points = local_joinery_points(
          x0, x1, offset, rules, forbidden_x,
          [3.cm, cam_diameter / 2.0, coil_distance].max
        )

        if system == 'butterfly'
          butterfly_def ||= butterfly_definition(model)
          butterfly_def.name = qualified_part_name('زاوية فراشة')
          z = above_horizontal ? horizontal[:z1] : horizontal[:z0]
          points.each_with_index do |x, index|
            key = [:trim_butterfly, label, (x / 0.1.cm).round]
            next if used[key]
            used[key] = true
            add_butterfly_filler_horizontal_instance(
              target_entities, butterfly_def,
              Geom::Point3d.new(x, trim_face_y, z),
              interior_positive_y, above_horizontal,
              "زاوية فراشة #{label} #{index + 1}"
            )
          end
          next
        end

        next unless system == 'elita'
        elita_def ||= elita_definition(model)
        elita_def.name = qualified_part_name('إليتا')

        joint_z = above_horizontal ? horizontal[:z1] : horizontal[:z0]
        screw_direction = above_horizontal ? Z_AXIS : Z_AXIS.reverse
        dowel_direction = screw_direction.reverse
        available_screw_depth = horizontal[:z1] - horizontal[:z0]
        screw_depth = [screw_reach, available_screw_depth - 0.1.mm].min
        trim_z_depth = trim[:z1] - trim[:z0]
        actual_dowel_depth = [requested_dowel_depth, trim_z_depth - 0.1.mm].min
        next if screw_depth <= 0.1.mm || actual_dowel_depth <= 0.1.mm

        cam_direction = interior_positive_y ? Y_AXIS.reverse : Y_AXIS
        cam_y = interior_positive_y ? horizontal[:y1] : horizontal[:y0]
        cam_depth = [requested_cam_depth, horizontal[:y1] - horizontal[:y0] - 0.1.mm].min
        next if cam_depth <= 0.1.mm

        points.each_with_index do |x, index|
          joint = Geom::Point3d.new(x, trim_face_y, joint_z)
          key = [:trim_elita, label, (x / 0.1.cm).round]
          next if used[key]
          used[key] = true

          drill_round_hole(
            horizontal[:entity], horizontal[:tr], joint,
            screw_direction, screw_depth, screw_diameter, 'SCREW', "#{label}-#{index + 1}"
          )
          drill_round_hole(
            trim[:entity], trim[:tr], joint,
            dowel_direction, actual_dowel_depth, dowel_diameter, 'DOWEL', "#{label}-#{index + 1}"
          )

          cam_center = joint.offset(screw_direction, [screw_depth, 0.2.cm].max)
          cam_start = Geom::Point3d.new(x, cam_y, cam_center.z)
          drill_round_hole(
            horizontal[:entity], horizontal[:tr], cam_start,
            cam_direction, cam_depth, cam_diameter, 'CAM', "#{label}-#{index + 1}"
          )

          inward_sign = x <= (x0 + x1) / 2.0 ? 1.0 : -1.0
          coil_xs = if coil_count == 2
                      [x + inward_sign * coil_distance,
                       x + inward_sign * coil_distance * 2.0]
                    else
                      [x + inward_sign * coil_distance]
                    end
          coil_xs.each_with_index do |coil_x, coil_index|
            next if coil_x <= x0 + 0.2.cm || coil_x >= x1 - 0.2.cm
            coil_point = Geom::Point3d.new(coil_x, trim_face_y, joint_z)
            drill_round_hole(
              horizontal[:entity], horizontal[:tr], coil_point,
              screw_direction, [coil_thickness_depth, available_screw_depth - 0.1.mm].min,
              coil_diameter, 'COIL', "#{label}-#{index + 1}-#{coil_index + 1}"
            )
            drill_round_hole(
              trim[:entity], trim[:tr], coil_point,
              dowel_direction, [coil_face_depth, trim_z_depth - 0.1.mm].min,
              coil_diameter, 'COIL', "#{label}-#{index + 1}-#{coil_index + 1}"
            )
          end

          add_elita_accessory(
            target_entities, elita_def, joint,
            screw_direction, cam_direction,
            actual_dowel_depth, "#{label}-#{index + 1}",
            data, cam_center
          )
        end
      end

      cornice_system = data['top_cornice_joinery'].to_s
      if cornice_system == 'butterfly' && !cornice_fronts.empty?
        offset = [data['top_cornice_joinery_offset'].to_f, 0.5].max.cm
        rules = Array(data['top_cornice_joinery_rules'])
        rules = [{'threshold'=>65.0,'count'=>1}] if rules.empty?
        top_board = carcass_h.max_by { |r| r[:z1] }

        butterfly_def ||= butterfly_definition(model)
        butterfly_def.name = qualified_part_name('زاوية فراشة')

        # كورنيشة يمين/شمال.
        cornice_sides = records.select { |r| r[:kind] == :top_cornice_side }

        all_cornice_parts = cornice_fronts + cornice_sides
        cornice_min_x = all_cornice_parts.map { |r| r[:x0] }.min
        cornice_max_x = all_cornice_parts.map { |r| r[:x1] }.max
        cornice_center_x = (cornice_min_x + cornice_max_x) / 2.0

        if top_board
          # ==========================================================
          # 1) وش الكورنيشة ↔ القرصة من تحت
          #
          # نفس منطق السوكلو لكن معكوس رأسيًا:
          # الزاوية تقع أسفل القرصة ومن داخل الكورنيشة.
          # ==========================================================
          side_forbidden_x = cornice_sides.map { |side| (side[:x0] + side[:x1]) / 2.0 }

          cornice_fronts.each do |front|
            x0 = [front[:x0], top_board[:x0]].max
            x1 = [front[:x1], top_board[:x1]].min
            next if x1 - x0 <= 1.cm

            x_points = local_joinery_points(
              x0, x1, offset, rules, side_forbidden_x, 3.cm
            )

            # الوش الأمامي: الوجه الداخلي هو الخلفي منه.
            front_inner_y = front[:y1]

            x_points.each_with_index do |x, index|
              key = [:cornice_front_top_b, front[:entity].object_id, (x / 0.1.cm).round]
              next if used[key]
              used[key] = true

              # "من تحت" هنا تخص موضع/منطق الربط، وليس قلب الإكسسوار.
              # نحافظ على اتجاه الفراشة الأصلي المستقر للكورنيشة.
              add_butterfly_filler_horizontal_instance(
                target_entities, butterfly_def,
                Geom::Point3d.new(x, front_inner_y, top_board[:z1]),
                true, true,
                "زاوية فراشة وش الكورنيشة مع القرصة #{index + 1}"
              )
            end
          end

          # ==========================================================
          # 2) جنبا الكورنيشة ↔ القرصة
          #
          # لكل جنب زاويتان بالضبط مع القرصة:
          # واحدة على بعد 5 سم تقريبًا من أول الجنب،
          # وواحدة على بعد 5 سم تقريبًا من آخره.
          # المسافة هنا مرتبطة بخانة مسافة الكورنيشة (افتراضي 5 سم).
          # ==========================================================
          front_record = cornice_fronts.first

          cornice_sides.each_with_index do |side, side_index|
            side_center_x = (side[:x0] + side[:x1]) / 2.0
            inside_face_right = side_center_x <= cornice_center_x
            point_x = inside_face_right ? side[:x1] : side[:x0]
            rotation = inside_face_right ? (Math::PI / 2.0) : (-Math::PI / 2.0)

            y0 = [side[:y0], top_board[:y0]].max
            y1 = [side[:y1], top_board[:y1]].min
            next if y1 - y0 <= 0.5.cm

            # زاويتان فقط. لو العمق صغير جدًا لا يسمح بالمسافتين،
            # نستخدم نقطة واحدة في المنتصف بدل تراكب زاويتين.
            side_top_points =
              if y1 - y0 > offset * 2 + 0.5.cm
                [y0 + offset, y1 - offset]
              else
                [(y0 + y1) / 2.0]
              end

            side_top_points.each_with_index do |y, angle_index|
              key = [:cornice_side_top_b, side[:entity].object_id, (y / 0.1.cm).round]
              next if used[key]
              used[key] = true

              # اتجاه الإكسسوار نفسه يظل كما هو؛ التعديل فقط في عدد ومكان الزوايا.
              add_butterfly_instance(
                target_entities, model, butterfly_def,
                Geom::Point3d.new(point_x, y, top_board[:z1]),
                rotation, true, inside_face_right,
                "زاوية فراشة جنب الكورنيشة مع القرصة #{side_index + 1}-#{angle_index + 1}"
              )
            end
          end
        end

        # ============================================================
        # 3) من تحت فقط: الجنبان ↔ وش الكورنيشة
        #
        # لا يوجد ربط علوي بين الجنب والوش. زاوية واحدة سفلية عند كل
        # التقاء جنب بالوش، كما طلبت.
        # ============================================================
        front_record = cornice_fronts.first
        if front_record
          cornice_sides.each_with_index do |side, side_index|
            side_center_x = (side[:x0] + side[:x1]) / 2.0
            inside_face_right = side_center_x <= cornice_center_x
            point_x = inside_face_right ? side[:x1] : side[:x0]

            # الوش أمامي، والوجه الداخلي هو Y الأعلى.
            joint_y = front_record[:y1]
            next unless joint_y >= side[:y0] - 0.2.cm &&
                        joint_y <= side[:y1] + 0.2.cm

            z0 = [side[:z0], front_record[:z0]].max
            z1 = [side[:z1], front_record[:z1]].min
            next if z1 - z0 <= 0.5.cm

            # زاوية ربط الجنب مع الوش تكون من فوق:
            # على بعد قيمة مسافة الكورنيشة من أعلى خط الالتقاء (افتراضي 5 سم).
            top_z = z1 - [offset, (z1 - z0) / 2.0].min

            key = [:cornice_side_front_top_b, side[:entity].object_id]
            next if used[key]
            used[key] = true

            add_butterfly_vertical_instance(
              target_entities, butterfly_def,
              Geom::Point3d.new(point_x, joint_y, top_z),
              inside_face_right, true,
              "زاوية فراشة علوية جنب الكورنيشة مع الوش #{side_index + 1}"
            )
          end
        end
      end

      plinth_system = data['wood_plinth_joinery'].to_s
      if plinth_system == 'butterfly' && !plinth_rails.empty?
        offset = [data['wood_plinth_joinery_offset'].to_f, 0.5].max.cm
        rules = Array(data['wood_plinth_joinery_rules'])
        rules = [{'threshold'=>65.0,'count'=>1}] if rules.empty?
        base_board = carcass_h.min_by { |r| r[:z0] }

        butterfly_def ||= butterfly_definition(model)
        butterfly_def.name = qualified_part_name('زاوية فراشة')

        # الأعضاء الرأسية للسوكلو = الجنبان + كل الدعامات الداخلية.
        frame_members = plinth_sides + plinth_supports
        all_plinth_parts = plinth_rails + frame_members
        plinth_min_x = all_plinth_parts.map { |r| r[:x0] }.min
        plinth_max_x = all_plinth_parts.map { |r| r[:x1] }.max
        plinth_center_x = (plinth_min_x + plinth_max_x) / 2.0

        # ============================================================
        # 1) وش السوكلو + ضهر السوكلو ↔ قاعدة الشاسيه
        #
        # الزوايا تتوزع على طول الوش/الضهر بالاحتمالات.
        # ممنوع وضع زاوية فوق جنب أو دعامة.
        # ============================================================
        if base_board
          forbidden_x = frame_members.map { |member| (member[:x0] + member[:x1]) / 2.0 }

          plinth_rails.each do |rail|
            front_rail = rail[:badges].include?('FRONT')
            back_rail = rail[:badges].include?('BACK')
            next unless front_rail || back_rail

            x0 = [rail[:x0], base_board[:x0]].max
            x1 = [rail[:x1], base_board[:x1]].min
            next if x1 - x0 <= 1.cm

            x_points = local_joinery_points(
              x0, x1, offset, rules, forbidden_x, 3.cm
            )

            # الزاوية داخل السوكلو وتحت القاعدة.
            rail_inner_y = front_rail ? rail[:y1] : rail[:y0]
            interior_positive_y = front_rail

            x_points.each_with_index do |x, index|
              key = [:plinth_rail_base_b, rail[:entity].object_id, (x / 0.1.cm).round]
              next if used[key]
              used[key] = true
              add_butterfly_filler_horizontal_instance(
                target_entities, butterfly_def,
                Geom::Point3d.new(x, rail_inner_y, base_board[:z0]),
                interior_positive_y, false,
                "زاوية فراشة #{front_rail ? 'وش' : 'ضهر'} السوكلو مع القاعدة #{index + 1}"
              )
            end
          end

          # ==========================================================
          # 2) الجنبان + الدعامات ↔ قاعدة الشاسيه من فوق
          #
          # لكل جنب زاوية واحدة، ولكل دعامة زاوية واحدة.
          # مكانها في الجزء العلوي من العضو، تحت القاعدة مباشرة.
          # ==========================================================
          front_rail = plinth_rails.find { |r| r[:badges].include?('FRONT') }
          back_rail  = plinth_rails.find { |r| r[:badges].include?('BACK') }

          frame_members.each_with_index do |member, member_index|
            member_center_x = (member[:x0] + member[:x1]) / 2.0
            inside_face_right = member_center_x <= plinth_center_x
            point_x = inside_face_right ? member[:x1] : member[:x0]
            rotation = inside_face_right ? (Math::PI / 2.0) : (-Math::PI / 2.0)

            # المساحة الصافية بين الوش والضهر؛ لا نحط زاوية فوق نقطة
            # التقاء الوش أو الضهر مع العضو.
            clear_y0 = member[:y0]
            clear_y1 = member[:y1]
            clear_y0 = [clear_y0, front_rail[:y1] + 0.3.cm].max if front_rail
            clear_y1 = [clear_y1, back_rail[:y0] - 0.3.cm].min if back_rail
            next if clear_y1 - clear_y0 <= 0.5.cm

            top_y = (clear_y0 + clear_y1) / 2.0
            key = [:plinth_member_base_b, member[:entity].object_id]
            unless used[key]
              used[key] = true
              add_butterfly_instance(
                target_entities, model, butterfly_def,
                Geom::Point3d.new(point_x, top_y, base_board[:z0]),
                rotation, false, inside_face_right,
                "زاوية فراشة #{member[:badges].include?('SUPPORT') ? 'دعامة' : 'جنب'} السوكلو مع القاعدة #{member_index + 1}"
              )
            end
          end
        end

        # ============================================================
        # 3) من تحت: الجنبان + الدعامات ↔ وش السوكلو + ضهر السوكلو
        #
        # لكل عضو:
        # - زاوية سفلية مع الوش.
        # - زاوية سفلية مع الضهر.
        #
        # يعني الجنبين نفس منطق الدعامات تمامًا.
        # ============================================================
        frame_members.each_with_index do |member, member_index|
          member_center_x = (member[:x0] + member[:x1]) / 2.0
          inside_face_right = member_center_x <= plinth_center_x
          point_x = inside_face_right ? member[:x1] : member[:x0]

          # نرفع مركز الزاوية السفلية قليلًا عن أسفل السوكلو حتى يظل
          # الإكسسوار كله داخل ارتفاع السوكلو ولا يخرج أسفل القطعة.
          bottom_z = member[:z0] + [1.8.cm, (member[:z1] - member[:z0]) / 3.0].min

          plinth_rails.each do |rail|
            front_rail = rail[:badges].include?('FRONT')
            back_rail = rail[:badges].include?('BACK')
            next unless front_rail || back_rail

            # العضو لازم يكون متقاطع فعليًا مع الوش/الضهر على X.
            next unless member_center_x >= rail[:x0] - 0.15.cm &&
                        member_center_x <= rail[:x1] + 0.15.cm

            joint_y = front_rail ? rail[:y1] : rail[:y0]
            next unless joint_y >= member[:y0] - 0.2.cm &&
                        joint_y <= member[:y1] + 0.2.cm

            key = [:plinth_member_rail_bottom_b, member[:entity].object_id,
                   rail[:entity].object_id]
            next if used[key]
            used[key] = true

            add_butterfly_vertical_instance(
              target_entities, butterfly_def,
              Geom::Point3d.new(point_x, joint_y, bottom_z),
              inside_face_right, front_rail,
              "زاوية فراشة سفلية #{member[:badges].include?('SUPPORT') ? 'دعامة' : 'جنب'} مع #{front_rail ? 'وش' : 'ضهر'} السوكلو #{member_index + 1}"
            )
          end
        end
      end

    end

    def build_elita_joinery(scan_entities, target_entities, model, data)
      elita_enabled = data['joinery_system'].to_s == 'elita'
      records = joinery_board_records_cached(scan_entities, false)
      horizontals = records.select { |record| record[:kind] == :horizontal }
      verticals = records.select { |record| record[:kind] == :vertical }
      drawer_sides = records.select { |record| record[:kind] == :drawer_chassis_side }
      drawer_ties = records.select { |record| record[:kind] == :drawer_chassis_tie }
      side_fillers = records.select { |record| record[:kind] == :side_filler }
      hinge_supports = records.select do |record|
        record[:kind] == :hinge_support || record[:badges].include?('HINGE_SUPPORT')
      end
      filler_returns = records.select do |record|
        record[:kind] == :filler_return || record[:badges].include?('FILLER_RETURN')
      end
      targets = horizontals.select do |record|
        role = record[:entity].get_attribute('MHD_DRESSING', 'SHELF_ROLE').to_s
        override = record[:entity].get_attribute('MHD_DRESSING', 'SHELF_SUPPORT_TYPE').to_s
        actual_shelf = role == 'actual'
        actual_shelf ? override == 'elita' : elita_enabled
      end
      return if targets.empty?

      accessory_definition = elita_definition(model)
      accessory_definition.name = qualified_part_name('إليتا')

      offset = [data['elita_edge_offset'].to_f, 0.5].max.cm
      @elita_support_rules = Array(data['elita_support_rules'])
      @elita_support_rules = [{'threshold'=>65.0,'count'=>1}] if @elita_support_rules.empty?
      # كل مقاسات الإليتا بالسنتيمتر. مقاس المسمار بعد البورمة هو المسافة
      # من نقطة الالتقاء إلى مركز وش الربط؛ لذلك ينتهي مجرى المسمار عند
      # مركز تخريم وش الربط مهما اختلف وضع أو تخانة القطعتين.
      screw_diameter = [data['elita_screw_drill_diameter'].to_f, 0.01].max.cm
      dowel_diameter = [data['elita_dowel_diameter'].to_f, 0.01].max.cm
      requested_dowel_depth = [data['elita_dowel_depth'].to_f, 0.01].max.cm
      cam_diameter = [data['elita_cam_diameter'].to_f, 0.01].max.cm
      requested_cam_depth = [data['elita_cam_depth'].to_f, 0.01].max.cm
      requested_connector_reach = [data['elita_screw_after_thread'].to_f, 0.01].max.cm
      coil_count = data['elita_coil_count'].to_i == 2 ? 2 : 1
      coil_diameter = [data['elita_coil_drill_diameter'].to_f, 0.01].max.cm
      coil_length_cm = [data['elita_coil_length'].to_f, 0.02].max
      coil_face_depth_cm = [[data['elita_coil_face_depth'].to_f, 0.01].max, coil_length_cm-0.01].min
      coil_face_depth = coil_face_depth_cm.cm
      coil_thickness_depth = (coil_length_cm - coil_face_depth_cm).cm
      coil_center_distance = [data['elita_coil_center_distance'].to_f, 0.01].max.cm
      used = {}
      coil_used = {}
      vertical_cam_face = {}
      number = 0
      drill_coil_pair = lambda do |first_record, second_record, coil_point, first_direction, second_direction, label|
        coil_key = [first_record[:entity].object_id, second_record[:entity].object_id,
                    (coil_point.x/0.1.cm).round, (coil_point.y/0.1.cm).round,
                    (coil_point.z/0.1.cm).round]
        next if coil_used[coil_key]
        coil_used[coil_key] = true
        # first_record هو جهة التخانة/المسمار، وsecond_record جهة الفيشر.
        # العمقان مكملان لبعضهما ومجموعهما يساوي طول الكويلة الكامل.
        drill_round_hole(first_record[:entity], first_record[:tr], coil_point, first_direction,
                         coil_thickness_depth, coil_diameter, 'COIL', label)
        drill_round_hole(second_record[:entity], second_record[:tr], coil_point, second_direction,
                         coil_face_depth, coil_diameter, 'COIL', label)
      end

      targets.each do |horizontal|
        horizontal_is_drawer_chassis = horizontal[:badges].include?('DRAWER_CHASSIS')
        matching_verticals = if horizontal_is_drawer_chassis
          left_boundary = horizontal[:entity].get_attribute('MHD_DRESSING', 'DRAWER_TOP_LEFT_BOUNDARY').to_s
          right_boundary = horizontal[:entity].get_attribute('MHD_DRESSING', 'DRAWER_TOP_RIGHT_BOUNDARY').to_s
          bay_x0 = horizontal[:entity].get_attribute('MHD_DRESSING', 'DRAWER_TOP_BAY_X0').to_f.cm
          bay_x1 = horizontal[:entity].get_attribute('MHD_DRESSING', 'DRAWER_TOP_BAY_X1').to_f.cm
          extension_side = horizontal[:entity].get_attribute('MHD_DRESSING', 'DRAWER_TOP_EXTENSION_SIDE').to_s
          partition_edges = verticals.select do |vertical|
            next false unless vertical[:badges].include?('PARTITION')
            on_left = left_boundary == 'partition' && (vertical[:x1] - bay_x0).abs <= 0.2.cm
            on_right = right_boundary == 'partition' && (vertical[:x0] - bay_x1).abs <= 0.2.cm
            on_left || on_right
          end
          # قاطع واقف فوق قرصة شاسيه الأدراج: تجميعة إليتا رأسية،
          # والقرصة تُعامل كقاعدة في اتجاه الإكسسوار.
          partitions_on_drawer_top = verticals.select do |vertical|
            vertical[:badges].include?('PARTITION') &&
              (vertical[:z0] - horizontal[:z1]).abs <= 0.2.cm &&
              vertical[:x1] >= horizontal[:x0] - 0.15.cm &&
              vertical[:x0] <= horizontal[:x1] + 0.15.cm
          end
          far_edge = verticals.select do |vertical|
            next false if vertical[:badges].include?('DRAWER_CHASSIS')
            at_left = extension_side == 'left' && (vertical[:x1] - horizontal[:x0]).abs <= 0.2.cm
            at_right = extension_side == 'right' && (vertical[:x0] - horizontal[:x1]).abs <= 0.2.cm
            at_left || at_right
          end
          (drawer_sides + partition_edges + partitions_on_drawer_top + far_edge).uniq
        else
          verticals
        end

        matching_verticals.each do |vertical|
          x_touch = vertical[:x1] >= horizontal[:x0]-0.15.cm && vertical[:x0] <= horizontal[:x1]+0.15.cm
          z_touch = vertical[:z1] >= horizontal[:z0]-0.15.cm && vertical[:z0] <= horizontal[:z1]+0.15.cm
          y0 = [horizontal[:y0], vertical[:y0]].max
          y1 = [horizontal[:y1], vertical[:y1]].min
          coil_span = coil_count == 2 ? coil_center_distance * 2.0 : coil_center_distance
          next unless x_touch && z_touch && y1-y0 > (offset + coil_span)*2 + 0.5.cm

          vertical_on_left = (vertical[:x0]+vertical[:x1])/2.0 <= (horizontal[:x0]+horizontal[:x1])/2.0
          edge_left_gap = (vertical[:x1]-horizontal[:x0]).abs
          edge_right_gap = (vertical[:x0]-horizontal[:x1]).abs
          edge_joint = [edge_left_gap, edge_right_gap].min <= 0.2.cm
          horizontal_above = (vertical[:z1]-horizontal[:z0]).abs <= 0.2.cm
          horizontal_below = (vertical[:z0]-horizontal[:z1]).abs <= 0.2.cm
          stacked_joint = !edge_joint && (horizontal_above || horizontal_below)
          next unless edge_joint || stacked_joint

          base_joint_specs = [[y0+offset, 1.0], [y1-offset, -1.0]].map do |outer_y, inward_sign|
            if coil_count == 2
              { y: outer_y + inward_sign*coil_center_distance,
                coil_ys: [outer_y, outer_y + inward_sign*coil_center_distance*2.0] }
            else
              { y: outer_y,
                coil_ys: [outer_y + inward_sign*coil_center_distance] }
            end
          end

          probe_x = edge_joint ? (edge_left_gap <= edge_right_gap ? vertical[:x1] : vertical[:x0]) : ((vertical[:x0]+vertical[:x1])/2.0)
          probe_z = edge_joint ? ((horizontal[:z0]+horizontal[:z1])/2.0) : (horizontal_above ? vertical[:z1] : vertical[:z0])
          forbidden_y = elita_forbidden_y_positions(records, probe_x, probe_z, [horizontal[:entity], vertical[:entity]])
          clearance = [coil_center_distance*(coil_count == 2 ? 1.2 : 0.8), cam_diameter/2.0, 3.cm].max
          centers = elita_distribution_centers(y0, y1, base_joint_specs.first[:y], base_joint_specs.last[:y], forbidden_y, clearance)
          base_keys = base_joint_specs.map { |spec| (spec[:y]/0.01.cm).round }
          joint_specs = centers.map do |center|
            i = base_keys.index((center/0.01.cm).round)
            i ? base_joint_specs[i] : elita_extra_joint_spec(center, :y, coil_center_distance, coil_count, (y0+y1)/2.0)
          end

          joint_specs.each do |joint_spec|
            y = joint_spec[:y]
            if edge_joint
              # لو القرصة/القاعدة بين الجنبين: التخريم أفقي، ومحوره في
              # منتصف تخانة اللوح الأفقي نفسه.
              x = edge_left_gap <= edge_right_gap ? vertical[:x1] : vertical[:x0]
              z = (horizontal[:z0] + horizontal[:z1]) / 2.0
              screw_direction = x == vertical[:x1] ? X_AXIS : X_AXIS.reverse
              dowel_direction = screw_direction.reverse
              available_screw_depth = screw_direction.samedirection?(X_AXIS) ? horizontal[:x1]-x : x-horizontal[:x0]
              screw_depth = [requested_connector_reach, available_screw_depth-0.1.mm].min
              cam_radius = cam_diameter / 2.0
              cam_distance = [screw_depth, available_screw_depth-cam_radius-0.1.mm].min
              next if screw_depth <= 0.1.mm || cam_distance <= cam_radius
              joint = Geom::Point3d.new(x,y,z)
              key = [:elita_edge,(x/0.1.cm).round,(y/0.1.cm).round,(z/0.1.cm).round]
            else
              # لو القرصة كاملة فوق الجنب أو القاعدة أسفل الجنب: محور
              # التخريم رأسي وفي منتصف تخانة الجنب الفعلية.
              x = (vertical[:x0] + vertical[:x1]) / 2.0
              z = horizontal_above ? vertical[:z1] : vertical[:z0]
              screw_direction = horizontal_above ? Z_AXIS.reverse : Z_AXIS
              dowel_direction = screw_direction.reverse
              available_screw_depth = vertical[:z1]-vertical[:z0]
              screw_depth = [requested_connector_reach, available_screw_depth-0.1.mm].min
              cam_radius = cam_diameter / 2.0
              cam_distance = [screw_depth, available_screw_depth-cam_radius-0.1.mm].min
              next if screw_depth <= 0.1.mm || cam_distance <= cam_radius
              joint = Geom::Point3d.new(x,y,z)
              key = [:elita_stack,(x/0.1.cm).round,(y/0.1.cm).round,(z/0.1.cm).round]
            end
            next if used[key]
            used[key] = true
            number += 1

            if edge_joint
              # مجرى المسمار في حرف القرصة، والفيشر في الجنب المقابل.
              drill_round_hole(horizontal[:entity], horizontal[:tr], joint, screw_direction,
                               screw_depth, screw_diameter, 'SCREW', number)
              vertical_depth = vertical[:x1]-vertical[:x0]
              actual_dowel_depth = [requested_dowel_depth, vertical_depth-0.1.mm].min
              drill_round_hole(vertical[:entity], vertical[:tr], joint, dowel_direction,
                               actual_dowel_depth, dowel_diameter, 'DOWEL', number)
              cam_center = joint.offset(screw_direction, cam_distance)
              base_or_bottom = horizontal[:name].to_s.match?(/قاعدة/) || horizontal[:badges].include?('DRAWER_BOTTOM')
              cam_start_z = base_or_bottom ? horizontal[:z1] : horizontal[:z0]
              cam_direction = base_or_bottom ? Z_AXIS.reverse : Z_AXIS
              cam_start = Geom::Point3d.new(cam_center.x, y, cam_start_z)
              cam_depth = [requested_cam_depth, horizontal[:z1]-horizontal[:z0]-0.1.mm].min
              drill_round_hole(horizontal[:entity], horizontal[:tr], cam_start, cam_direction,
                               cam_depth, cam_diameter, 'CAM', number)
              joint_spec[:coil_ys].each_with_index do |coil_y, coil_index|
                coil_point = Geom::Point3d.new(x, coil_y, z)
                drill_coil_pair.call(horizontal, vertical, coil_point,
                                     screw_direction, dowel_direction, "#{number}-#{coil_index+1}")
              end
            else
              # في القرصة الكاملة ينتقل مجرى المسمار ووش الربط للجنب،
              # بينما الفيشر يكون في القرصة المقابلة وعلى المحور نفسه.
              drill_round_hole(vertical[:entity], vertical[:tr], joint, screw_direction,
                               screw_depth, screw_diameter, 'SCREW', number)
              horizontal_depth = horizontal[:z1]-horizontal[:z0]
              actual_dowel_depth = [requested_dowel_depth, horizontal_depth-0.1.mm].min
              drill_round_hole(horizontal[:entity], horizontal[:tr], joint, dowel_direction,
                               actual_dowel_depth, dowel_diameter, 'DOWEL', number)
              cam_center = joint.offset(screw_direction, cam_distance)
              # نثبت وجه وش الربط لكل قطعة رأسية من أول التقاء لها؛ بعدها
              # كل فتحات نفس الجنب/القاطع تظل على الوجه نفسه حتى لا تنقسم
              # القطعة إلى تشغيل يمين وتشغيل شمال في الـ Cut List.
              preferred_cam_face = vertical[:entity].get_attribute('MHD_DRESSING', 'PREFERRED_CAM_FACE').to_s
              preferred_cam_face = vertical[:entity].definition.get_attribute('MHD_DRESSING', 'PREFERRED_CAM_FACE').to_s if preferred_cam_face.empty?
              preferred_cam_face = %w[left right].include?(preferred_cam_face) ? preferred_cam_face.to_sym : nil
              cam_face = vertical_cam_face[vertical[:entity]] ||= (preferred_cam_face || (vertical_on_left ? :right : :left))
              cam_start_x = cam_face == :right ? vertical[:x1] : vertical[:x0]
              cam_direction = cam_face == :right ? X_AXIS.reverse : X_AXIS
              cam_start = Geom::Point3d.new(cam_start_x, y, cam_center.z)
              cam_depth = [requested_cam_depth, vertical[:x1]-vertical[:x0]-0.1.mm].min
              drill_round_hole(vertical[:entity], vertical[:tr], cam_start, cam_direction,
                               cam_depth, cam_diameter, 'CAM', number)
              joint_spec[:coil_ys].each_with_index do |coil_y, coil_index|
                coil_point = Geom::Point3d.new(x, coil_y, z)
                drill_coil_pair.call(vertical, horizontal, coil_point,
                                     screw_direction, dowel_direction, "#{number}-#{coil_index+1}")
              end
            end
            flip_vertical_left_face = stacked_joint && cam_direction.samedirection?(X_AXIS)
            drawer_top_as_base = horizontal_is_drawer_chassis && stacked_joint
            flip_vertical_lower_joint = stacked_joint && (horizontal_below || drawer_top_as_base)
            # Keep the already-correct drawer-chassis-side orientation exactly
            # as before. Add the same final X+Z correction only to a partition
            # meeting the drawer chassis top; this is the visually inverted
            # case and must not alter any drawer side accessory.
            flip_drawer_chassis_top_xz = horizontal_is_drawer_chassis &&
                                         (vertical[:kind] == :drawer_chassis_side ||
                                          vertical[:badges].include?('PARTITION'))
            add_elita_accessory(target_entities, accessory_definition, joint,
                                screw_direction, cam_direction, actual_dowel_depth, number, data,
                                cam_center,
                                flip_vertical_left_face, flip_vertical_lower_joint,
                                flip_drawer_chassis_top_xz)
          end
        end
      end

      # ============================================================
      # إليتا السدّة الأمامية
      #
      # السدّة موجودة على وش الدولاب، لذلك القطع التي تقابلها (الجنب،
      # القرصة، القاعدة) تصل إليها بحرفها الأمامي. منطق النجارة هنا:
      #
      #   القطعة المقابلة للسدّة = جهة التخانة:
      #     مسمار + وش ربط + كويلة.
      #
      #   السدّة = الجهة المقابلة:
      #     فيشر + النصف المقابل من الكويلة.
      #
      # وبذلك تكون كل نقاط الالتقاء الثلاثة مخدومة فعليًا:
      # الجنب + القرصة + القاعدة.
      # ============================================================
      side_fillers.each do |filler|
        filler_side = filler[:entity].get_attribute('MHD_DRESSING', 'SIDE_FILLER').to_s
        next unless %w[left right].include?(filler_side)

        # أقرب جنب شاسيه خارجي لنفس ناحية السدّة.
        carcass_sides = verticals.select do |record|
          record[:badges].include?('MAIN_CARCASS') &&
            !record[:badges].include?('PARTITION')
        end
        side_record = if filler_side == 'left'
                        carcass_sides.min_by { |record| record[:x0] }
                      else
                        carcass_sides.max_by { |record| record[:x1] }
                      end

        # القرصة والقاعدة الفعليتان للشاسيه فقط.
        carcass_horizontals = horizontals.select do |record|
          record[:badges].include?('MAIN_CARCASS') &&
            !record[:badges].include?('DRAWER_CHASSIS')
        end
        top_record = carcass_horizontals.select { |record|
          record[:name].to_s.match?(/قرصة|سقف/)
        }.max_by { |record| record[:z1] }
        base_record = carcass_horizontals.select { |record|
          record[:name].to_s.match?(/قاعدة/)
        }.min_by { |record| record[:z0] }

        # دالة داخلية تعمل وصلة "حرف القطعة -> وجه السدّة" على محور Y.
        # screw_board هو الجنب/القرصة/القاعدة، والفيلر يستقبل الفيشر.
        drill_filler_front_joint = lambda do |screw_board, point, cam_axis, cam_face_value, label|
          next unless screw_board

          # نقطة الالتقاء تقع عند أول حرف أمامي للقطعة المقابلة.
          joint_y = screw_board[:y0]
          joint = Geom::Point3d.new(point.x, joint_y, point.z)
          screw_direction = Y_AXIS
          dowel_direction = Y_AXIS.reverse

          available_screw_depth = screw_board[:y1] - joint_y
          screw_depth = [requested_connector_reach, available_screw_depth - 0.1.mm].min
          cam_radius = cam_diameter / 2.0
          cam_distance = [screw_depth, available_screw_depth - cam_radius - 0.1.mm].min
          filler_depth = filler[:y1] - filler[:y0]
          actual_dowel_depth = [requested_dowel_depth, filler_depth - 0.1.mm].min
          next if screw_depth <= 0.1.mm || cam_distance <= cam_radius || actual_dowel_depth <= 0.1.mm

          key = [:elita_side_filler, label,
                 (joint.x/0.1.cm).round, (joint.y/0.1.cm).round, (joint.z/0.1.cm).round]
          next if used[key]
          used[key] = true
          number += 1

          # المسمار في حرف الجنب/القرصة/القاعدة، والفيشر في وجه السدّة.
          drill_round_hole(
            screw_board[:entity], screw_board[:tr], joint,
            screw_direction, screw_depth, screw_diameter, 'SCREW', number
          )
          drill_round_hole(
            filler[:entity], filler[:tr], joint,
            dowel_direction, actual_dowel_depth, dowel_diameter, 'DOWEL', number
          )

          cam_center = joint.offset(screw_direction, cam_distance)
          cam_direction = nil
          cam_start = nil
          cam_depth = nil

          if cam_axis == :x
            # الجنب: وش الربط من الوجه الداخلي للجنب.
            cam_direction = cam_face_value == :right ? X_AXIS.reverse : X_AXIS
            cam_x = cam_face_value == :right ? screw_board[:x1] : screw_board[:x0]
            cam_start = Geom::Point3d.new(cam_x, cam_center.y, joint.z)
            cam_depth = [requested_cam_depth, screw_board[:x1]-screw_board[:x0]-0.1.mm].min
          else
            # القرصة من أسفل، والقاعدة من أعلى.
            cam_direction = cam_face_value == :top ? Z_AXIS.reverse : Z_AXIS
            cam_z = cam_face_value == :top ? screw_board[:z1] : screw_board[:z0]
            cam_start = Geom::Point3d.new(joint.x, cam_center.y, cam_z)
            cam_depth = [requested_cam_depth, screw_board[:z1]-screw_board[:z0]-0.1.mm].min
          end

          drill_round_hole(
            screw_board[:entity], screw_board[:tr], cam_start,
            cam_direction, cam_depth, cam_diameter, 'CAM', number
          )

          # الكويلة بنفس المنطق العام؛ مكانها يبعد عن نقطة الإليتا
          # في اتجاه داخل القطعة حتى لا تتعارض مع وش الربط.
          coil_points = if cam_axis == :x
                          inward_z = point.z <= (filler[:z0]+filler[:z1])/2.0 ? 1.0 : -1.0
                          if coil_count == 2
                            [
                              joint.offset(Z_AXIS, inward_z * coil_center_distance),
                              joint.offset(Z_AXIS, inward_z * coil_center_distance * 2.0)
                            ]
                          else
                            [joint.offset(Z_AXIS, inward_z * coil_center_distance)]
                          end
                        else
                          filler_center_x = (filler[:x0] + filler[:x1]) / 2.0
                          inward_x = point.x <= filler_center_x ? 1.0 : -1.0
                          if coil_count == 2
                            [
                              joint.offset(X_AXIS, inward_x * coil_center_distance),
                              joint.offset(X_AXIS, inward_x * coil_center_distance * 2.0)
                            ]
                          else
                            [joint.offset(X_AXIS, inward_x * coil_center_distance)]
                          end
                        end

          coil_points.each_with_index do |coil_point, coil_index|
            drill_coil_pair.call(
              screw_board, filler, coil_point,
              screw_direction, dowel_direction,
              "F#{number}-#{coil_index+1}"
            )
          end

          # نفس إكسسوار الإليتا العام؛ لا نغير موديله أو مقاساته.
          add_elita_accessory(
            target_entities, accessory_definition, joint,
            screw_direction, cam_direction, actual_dowel_depth,
            number, data, cam_center
          )
        end

        # ---------- التقاء السدّة مع الجنب ----------
        if side_record
          z0 = [filler[:z0], side_record[:z0]].max
          z1 = [filler[:z1], side_record[:z1]].min
          if z1-z0 > offset*2 + 1.cm
            side_x = (side_record[:x0] + side_record[:x1]) / 2.0
            cam_face = filler_side == 'left' ? :right : :left
            forbidden_z = butterfly_forbidden_z_positions(records, side_x, side_record[:y0], [filler[:entity], side_record[:entity]])
            z_points = elita_distribution_centers(
              z0, z1, z0+offset, z1-offset, forbidden_z,
              [coil_center_distance, cam_diameter/2.0, 3.cm].max
            )
            z_points.each_with_index do |z, index|
              drill_filler_front_joint.call(
                side_record,
                Geom::Point3d.new(side_x, side_record[:y0], z),
                :x, cam_face, "SIDE-#{index+1}"
              )
            end
          end
        end

        filler_x_points = lambda do |target_record, z|
          span = filler[:x1]-filler[:x0]
          if span <= offset*2 + coil_center_distance*2 + 1.cm
            [(filler[:x0]+filler[:x1])/2.0]
          else
            forbidden_x = butterfly_forbidden_x_positions(records, target_record[:y0], z, [filler[:entity], target_record[:entity]])
            elita_distribution_centers(
              filler[:x0], filler[:x1], filler[:x0]+offset, filler[:x1]-offset,
              forbidden_x, [coil_center_distance, cam_diameter/2.0, 3.cm].max
            )
          end
        end

        # ---------- التقاء السدّة مع القرصة ----------
        if top_record
          z = (top_record[:z0] + top_record[:z1]) / 2.0
          filler_x_points.call(top_record, z).each_with_index do |x, index|
            drill_filler_front_joint.call(
              top_record,
              Geom::Point3d.new(x, top_record[:y0], z),
              :z, :bottom, "TOP-#{index+1}"
            )
          end
        end

        # ---------- التقاء السدّة مع القاعدة ----------
        if base_record
          z = (base_record[:z0] + base_record[:z1]) / 2.0
          filler_x_points.call(base_record, z).each_with_index do |x, index|
            drill_filler_front_joint.call(
              base_record,
              Geom::Point3d.new(x, base_record[:y0], z),
              :z, :top, "BASE-#{index+1}"
            )
          end
        end
      end

      # ============================================================
      # إليتا السدّة مع القطع الخاصة بها — على النظام العام فقط:
      #
      # 1) داعم المفصلات ↔ السدّة.
      # 2) الفيلر الخارجي/الجانبي (FILLER_RETURN) ↔ السدّة.
      #
      # هذه الوصلات تستخدم كل إعدادات الإليتا العامة الحالية، بما فيها
      # احتمالات التدعيم حسب الطول، ولا تغيّر أي منطق لشاسيه الدرج الداخلي.
      # ============================================================
      if elita_enabled
        # دالة عامة لوصلة لوح رأسي ممتد على Y مع السدّة الرقيقة على وش الدولاب.
        # تحدد تلقائيًا أي نهاية Y هي التي تلامس السدّة، وبالتالي لا نفترض
        # أن القطعة أمام السدّة أو خلفها.
        drill_special_filler_vertical_joint = lambda do |board, filler, label_prefix|
          next unless board && filler

          # لازم القطعتان تتقاطعان على X ويكون لهما ارتفاع مشترك.
          x0 = [board[:x0], filler[:x0]].max
          x1 = [board[:x1], filler[:x1]].min
          z0 = [board[:z0], filler[:z0]].max
          z1 = [board[:z1], filler[:z1]].min
          next if x1 - x0 <= 0.1.cm || z1 - z0 <= 1.cm

          # نحدد أقرب زوج من حواف Y بين القطعتين.
          y_pairs = [
            [board[:y0], filler[:y0], :board_min],
            [board[:y0], filler[:y1], :board_min],
            [board[:y1], filler[:y0], :board_max],
            [board[:y1], filler[:y1], :board_max]
          ]
          board_y, filler_y, board_face = y_pairs.min_by { |a, b, _face| (a - b).abs }
          next if (board_y - filler_y).abs > 0.35.cm

          # المسمار يدخل داخل القطعة الخشبية، والفيشر يدخل في السدّة.
          screw_direction = board_face == :board_min ? Y_AXIS : Y_AXIS.reverse
          dowel_direction = screw_direction.reverse

          available_screw_depth =
            board_face == :board_min ? board[:y1] - board_y : board_y - board[:y0]
          screw_depth = [requested_connector_reach, available_screw_depth - 0.1.mm].min

          cam_radius = cam_diameter / 2.0
          cam_distance = [screw_depth, available_screw_depth - cam_radius - 0.1.mm].min

          # تخانة السدّة على Y هي أقصى عمق مسموح للفيشر.
          filler_depth = filler[:y1] - filler[:y0]
          actual_dowel_depth = [requested_dowel_depth, filler_depth - 0.1.mm].min

          next if screw_depth <= 0.1.mm ||
                  cam_distance <= cam_radius ||
                  actual_dowel_depth <= 0.1.mm

          # وش الربط في وجه القطعة المواجه للداخل حسب ناحية السدّة.
          filler_side = filler[:entity].get_attribute('MHD_DRESSING', 'SIDE_FILLER').to_s
          # داعم المفصلة والفيلر الخارجي فقط:
          # وش الربط مطلوب على الناحية العكسية من اللوح.
          cam_face = filler_side == 'left' ? :left : :right
          cam_direction = cam_face == :right ? X_AXIS.reverse : X_AXIS
          cam_x = cam_face == :right ? board[:x1] : board[:x0]
          cam_depth = [requested_cam_depth, board[:x1] - board[:x0] - 0.1.mm].min
          next if cam_depth <= 0.1.mm

          # X في منتصف منطقة التداخل بين القطعتين.
          x = (x0 + x1) / 2.0

          # نقطتا الطرف الأساسيتان + احتمالات الإليتا العامة،
          # مع تجنب الأرفف/القواطيع/القرصة/القاعدة التي تقطع نفس الخط.
          forbidden_z = butterfly_forbidden_z_positions(
            records, x, board_y, [board[:entity], filler[:entity]]
          )
          z_points = elita_distribution_centers(
            z0, z1,
            z0 + offset, z1 - offset,
            forbidden_z,
            [coil_center_distance, cam_diameter / 2.0, 3.cm].max
          )

          z_points.each_with_index do |z, index|
            joint = Geom::Point3d.new(x, board_y, z)
            key = [
              :elita_special_filler, label_prefix,
              board[:entity].object_id, filler[:entity].object_id,
              (x / 0.1.cm).round, (board_y / 0.1.cm).round, (z / 0.1.cm).round
            ]
            next if used[key]
            used[key] = true
            number += 1

            # المسمار في داعم المفصلة/الفيلر الخارجي.
            drill_round_hole(
              board[:entity], board[:tr], joint,
              screw_direction, screw_depth,
              screw_diameter, 'SCREW', "#{label_prefix}-#{number}"
            )

            # الفيشر في السدّة نفسها.
            drill_round_hole(
              filler[:entity], filler[:tr], joint,
              dowel_direction, actual_dowel_depth,
              dowel_diameter, 'DOWEL', "#{label_prefix}-#{number}"
            )

            cam_center = joint.offset(screw_direction, cam_distance)
            cam_start = Geom::Point3d.new(cam_x, cam_center.y, z)

            drill_round_hole(
              board[:entity], board[:tr], cam_start,
              cam_direction, cam_depth,
              cam_diameter, 'CAM', "#{label_prefix}-#{number}"
            )

            # الكويلة بنفس إعدادات النظام العام.
            inward_z = z <= (z0 + z1) / 2.0 ? 1.0 : -1.0
            coil_points = if coil_count == 2
                            [
                              joint.offset(Z_AXIS, inward_z * coil_center_distance),
                              joint.offset(Z_AXIS, inward_z * coil_center_distance * 2.0)
                            ]
                          else
                            [joint.offset(Z_AXIS, inward_z * coil_center_distance)]
                          end

            coil_points.each_with_index do |coil_point, coil_index|
              # لا نضع كويلة خارج طول التقاء القطعتين.
              next if coil_point.z <= z0 + 0.2.cm || coil_point.z >= z1 - 0.2.cm
              drill_coil_pair.call(
                board, filler, coil_point,
                screw_direction, dowel_direction,
                "#{label_prefix}-#{number}-#{coil_index + 1}"
              )
            end

            # إكسسوار الإليتا يُركب من التخريم الفعلي فقط.
            add_elita_accessory(
              target_entities, accessory_definition, joint,
              screw_direction, cam_direction,
              actual_dowel_depth, "#{label_prefix}-#{number}",
              data, cam_center
            )
          end
        end

        side_fillers.each do |filler|
          filler_side = filler[:entity].get_attribute('MHD_DRESSING', 'SIDE_FILLER').to_s
          next unless %w[left right].include?(filler_side)

          # نفس العمود/الناحية قدر الإمكان؛ ولو Attribute غير موجود نرجع
          # للاختبار الهندسي للتلامس داخل الدالة.
          column_path = filler[:entity].get_attribute('MHD_DRESSING', 'COLUMN_PATH').to_s

          matching_supports = hinge_supports.select do |support|
            support_path = support[:entity].get_attribute('MHD_DRESSING', 'COLUMN_PATH').to_s
            support_side = support[:entity].get_attribute('MHD_DRESSING', 'HINGE_SUPPORT_SIDE').to_s
            path_ok = column_path.empty? || support_path.empty? || support_path == column_path
            path_ok && support_side == filler_side
          end

          matching_returns = filler_returns.select do |return_part|
            return_side = return_part[:entity].get_attribute('MHD_DRESSING', 'FILLER_RETURN_SIDE').to_s
            return_side == filler_side
          end

          matching_supports.each do |support|
            drill_special_filler_vertical_joint.call(
              support, filler, 'HINGE-SUPPORT'
            )
          end

          matching_returns.each do |return_part|
            drill_special_filler_vertical_joint.call(
              return_part, filler, 'FILLER-RETURN'
            )
          end
        end
      end

      # شاسيه الأدراج السميك: نفس نقاط زوايا الفراشة على الأربع دعامات.
      # تخانة الجنب هي الملتقية بالدعامة؛ لذلك المسمار ووش الربط في الجنب،
      # والفيشر في الدعامة. نراجع التخريم أولًا من دون تركيب الإكسسوار.
      drawer_ties.each do |tie|
        drawer_sides.each do |side|
          x_touch = side[:x1] >= tie[:x0]-0.15.cm && side[:x0] <= tie[:x1]+0.15.cm
          z0 = [side[:z0], tie[:z0]].max
          z1 = [side[:z1], tie[:z1]].min
          coil_span = coil_count == 2 ? coil_center_distance * 2.0 : coil_center_distance
          next unless x_touch && z1-z0 > (offset + coil_span)*2 + 0.5.cm

          side_center_x = (side[:x0] + side[:x1]) / 2.0
          tie_center_x = (tie[:x0] + tie[:x1]) / 2.0
          side_center_y = (side[:y0] + side[:y1]) / 2.0
          tie_center_y = (tie[:y0] + tie[:y1]) / 2.0

          # تحديد هندسي خالص من أماكن القطع، من دون أي اعتماد على الأسماء:
          # في الدعامة الشمال يقع الجنب بعد مركز الدعامة على X، وفي اليمين
          # يقع قبل مركزها. والدعامة الأمامية قبل مركز الجنب على Y.
          left_side = side_center_x > tie_center_x
          right_side = side_center_x < tie_center_x
          front_tie = tie_center_y < side_center_y
          side_on_left = right_side
          flip_selected_support_x = (front_tie && right_side) || (!front_tie && left_side)
          rotate_other_support_y = (front_tie && left_side) || (!front_tie && right_side)
          x = (side[:x0] + side[:x1]) / 2.0
          y = front_tie ? tie[:y1] : tie[:y0]
          screw_direction = front_tie ? Y_AXIS : Y_AXIS.reverse
          dowel_direction = screw_direction.reverse
          available_screw_depth = screw_direction.samedirection?(Y_AXIS) ? side[:y1]-y : y-side[:y0]
          screw_depth = [requested_connector_reach, available_screw_depth-0.1.mm].min
          cam_radius = cam_diameter / 2.0
          cam_distance = [screw_depth, available_screw_depth-cam_radius-0.1.mm].min
          tie_depth = tie[:y1]-tie[:y0]
          actual_dowel_depth = [requested_dowel_depth, tie_depth-0.1.mm].min
          next if screw_depth <= 0.1.mm || cam_distance <= cam_radius || actual_dowel_depth <= 0.1.mm

          cam_face = vertical_cam_face[side[:entity]] ||= (side_on_left ? :right : :left)
          cam_start_x = cam_face == :right ? side[:x1] : side[:x0]
          cam_direction = cam_face == :right ? X_AXIS.reverse : X_AXIS
          cam_depth = [requested_cam_depth, side[:x1]-side[:x0]-0.1.mm].min

          base_drawer_specs = [[z0+offset, 1.0], [z1-offset, -1.0]].map do |outer_z, inward_sign|
            if coil_count == 2
              { z: outer_z + inward_sign*coil_center_distance,
                coil_zs: [outer_z, outer_z + inward_sign*coil_center_distance*2.0] }
            else
              { z: outer_z,
                coil_zs: [outer_z + inward_sign*coil_center_distance] }
            end
          end
          forbidden_z = butterfly_forbidden_z_positions(records, x, y, [side[:entity], tie[:entity]])
          centers = elita_distribution_centers(
            z0, z1, base_drawer_specs.first[:z], base_drawer_specs.last[:z],
            forbidden_z, [coil_center_distance, cam_diameter/2.0, 3.cm].max
          )
          base_keys = base_drawer_specs.map { |spec| (spec[:z]/0.01.cm).round }
          drawer_joint_specs = centers.map do |center|
            i = base_keys.index((center/0.01.cm).round)
            i ? base_drawer_specs[i] : elita_extra_joint_spec(center, :z, coil_center_distance, coil_count, (z0+z1)/2.0)
          end
          drawer_joint_specs.each do |joint_spec|
            z = joint_spec[:z]
            joint = Geom::Point3d.new(x, y, z)
            key = [:elita_drawer_chassis,(x/0.1.cm).round,(y/0.1.cm).round,(z/0.1.cm).round]
            next if used[key]
            used[key] = true
            number += 1

            drill_round_hole(side[:entity], side[:tr], joint, screw_direction,
                             screw_depth, screw_diameter, 'SCREW', number)
            drill_round_hole(tie[:entity], tie[:tr], joint, dowel_direction,
                             actual_dowel_depth, dowel_diameter, 'DOWEL', number)
            cam_center = joint.offset(screw_direction, cam_distance)
            cam_start = Geom::Point3d.new(cam_start_x, cam_center.y, z)
            drill_round_hole(side[:entity], side[:tr], cam_start, cam_direction,
                             cam_depth, cam_diameter, 'CAM', number)
            joint_spec[:coil_zs].each_with_index do |coil_z, coil_index|
              coil_point = Geom::Point3d.new(x, y, coil_z)
              drill_coil_pair.call(side, tie, coil_point,
                                   screw_direction, dowel_direction, "#{number}-#{coil_index+1}")
            end
            add_elita_accessory(target_entities, accessory_definition, joint,
                                screw_direction, cam_direction, actual_dowel_depth, number, data,
                                cam_center,
                                false, false, false, true,
                                flip_selected_support_x, rotate_other_support_y)
          end
        end
      end
    end


    # يجمع كل Groups الأدراج المتحركة B.Cajon بدون خلطها بالشاسيه الخارجي.
    def each_inner_drawer_group(entities, &block)
      entities.each do |entity|
        next unless entity.valid?
        if entity.is_a?(Sketchup::Group)
          if entity.get_attribute('MHD_DRESSING', 'TYPE').to_s == 'B.Cajon'
            yield entity
          else
            each_inner_drawer_group(entity.entities, &block)
          end
        elsif entity.is_a?(Sketchup::ComponentInstance)
          # لا ننزل داخل Definitions القطع الخشبية حتى لا نكرر نفس الدرج
          # عبر Definitions مشتركة. Groups الأدراج موجودة مباشرة في الشجرة.
          next
        end
      end
    end

    # سجل قطع شاسيه درج واحد في إحداثيات Group الدرج المحلية.
    # side = الجنبان، tie = الوش والضهر.
    def inner_drawer_joinery_records(drawer_group)
      result = []
      drawer_group.entities.each do |entity|
        next unless entity.is_a?(Sketchup::ComponentInstance) && entity.valid?
        badges = joinery_badges(entity)
        kind = if badges.include?('DRAWER_SIDE')
                 :side
               elsif badges.include?('DRAWER_BOX')
                 :tie
               end
        next unless kind

        tr = entity.transformation
        points = (0..7).map { |i| entity.definition.bounds.corner(i).transform(tr) }
        xs = points.map(&:x); ys = points.map(&:y); zs = points.map(&:z)
        result << {
          entity: entity, tr: tr, kind: kind,
          x0: xs.min, x1: xs.max,
          y0: ys.min, y1: ys.max,
          z0: zs.min, z1: zs.max,
          name: "#{entity.name} #{entity.definition.name}",
          badges: badges
        }
      end
      result
    end

    def inner_drawer_elita_data(drawer_group)
      read = lambda do |suffix, fallback|
        value = drawer_group.get_attribute('MHD_DRESSING', "INNER_ELITA_#{suffix}")
        value = fallback if value.nil? || value.to_s.empty?
        value
      end
      {
        'elita_edge_offset' => read.call('EDGE_OFFSET', 5.0),
        'elita_screw_drill_diameter' => read.call('SCREW_DRILL_DIAMETER', 0.8),
        'elita_dowel_diameter' => read.call('DOWEL_DIAMETER', 0.8),
        'elita_dowel_depth' => read.call('DOWEL_DEPTH', 1.05),
        'elita_cam_diameter' => read.call('CAM_DIAMETER', 1.5),
        'elita_cam_depth' => read.call('CAM_DEPTH', 1.2),
        'elita_screw_after_thread' => read.call('SCREW_AFTER_THREAD', 3.2),
        'elita_coil_count' => read.call('COIL_COUNT', 1),
        'elita_coil_drill_diameter' => read.call('COIL_DRILL_DIAMETER', 0.8),
        'elita_coil_length' => read.call('COIL_LENGTH', 4.0),
        'elita_coil_face_depth' => read.call('COIL_FACE_DEPTH', 2.0),
        'elita_coil_center_distance' => read.call('COIL_CENTER_DISTANCE', 2.5)
      }
    end

    # نقط التجميع الأساسية فقط، بلا احتمالات:
    # لو الارتفاع يسمح بنقطتين نستخدم أول/آخر، ولو شاسيه الدرج قصير
    # نستخدم نقطة واحدة في المنتصف بدل إلغاء التخريم بالكامل.
    def inner_drawer_elita_specs(z0, z1, offset, coil_count, coil_distance)
      span = z1 - z0
      coil_span = coil_count == 2 ? coil_distance : coil_distance
      safe_two = span > (offset + coil_span) * 2 + 0.5.cm

      centers = if safe_two
                  [[z0 + offset, 1.0], [z1 - offset, -1.0]]
                else
                  [[(z0 + z1) / 2.0, 1.0]]
                end

      centers.map do |center, inward_sign|
        if coil_count == 2
          # في حالة نقطة المنتصف: كويلة قبل وبعد المسمار.
          {
            z: center,
            coil_zs: [center - coil_distance, center + coil_distance]
          }
        else
          # مع النقطتين: الكويلة تتجه للداخل.
          # مع نقطة المنتصف: نضعها أعلى المركز افتراضيًا.
          sign = centers.length == 1 ? 1.0 : inward_sign
          {
            z: center,
            coil_zs: [center + sign * coil_distance]
          }
        end
      end
    end

    def build_inner_drawer_elita_joinery(scan_entities, model)
      accessory_definition = nil
      number = 0

      # أثناء إنشاء الدرج نستدعي الدالة مباشرة على Group الدرج قبل تحويله
      # إلى Dynamic Component. هذا يمنع Redraw متكرر من محرك الـDC أثناء
      # حفر الثقوب، وهو سبب التوقف عند 88% في النسخة السابقة.
      drawer_groups = []
      if scan_entities.is_a?(Sketchup::Group)
        drawer_groups << scan_entities
      else
        each_inner_drawer_group(scan_entities) { |group| drawer_groups << group }
      end

      drawer_groups.each do |drawer_group|
        next unless drawer_group.get_attribute('MHD_DRESSING', 'INNER_DRAWER_JOINERY').to_s == 'elita'

        records = inner_drawer_joinery_records(drawer_group)
        sides = records.select { |r| r[:kind] == :side }
        ties  = records.select { |r| r[:kind] == :tie }
        next if sides.empty? || ties.empty?

        data = inner_drawer_elita_data(drawer_group)
        accessory_definition ||= elita_definition(model)
        accessory_definition.name = qualified_part_name('إليتا')

        offset = [data['elita_edge_offset'].to_f, 0.5].max.cm
        screw_diameter = [data['elita_screw_drill_diameter'].to_f, 0.01].max.cm
        dowel_diameter = [data['elita_dowel_diameter'].to_f, 0.01].max.cm
        requested_dowel_depth = [data['elita_dowel_depth'].to_f, 0.01].max.cm
        cam_diameter = [data['elita_cam_diameter'].to_f, 0.01].max.cm
        requested_cam_depth = [data['elita_cam_depth'].to_f, 0.01].max.cm
        requested_connector_reach = [data['elita_screw_after_thread'].to_f, 0.01].max.cm
        coil_count = data['elita_coil_count'].to_i == 2 ? 2 : 1
        coil_diameter = [data['elita_coil_drill_diameter'].to_f, 0.01].max.cm
        coil_length_cm = [data['elita_coil_length'].to_f, 0.02].max
        coil_face_cm = [[data['elita_coil_face_depth'].to_f, 0.01].max, coil_length_cm - 0.01].min
        coil_face_depth = coil_face_cm.cm
        coil_thickness_depth = (coil_length_cm - coil_face_cm).cm
        coil_center_distance = [data['elita_coil_center_distance'].to_f, 0.01].max.cm

        used = {}
        cam_face_for_side = {}

        ties.each do |tie|
          sides.each do |side|
            # وش/ضهر الشاسيه بعرض الشاسيه كامل، والجنبان بينهما؛
            # نلتقط فقط ركنة الالتقاء الحقيقية عند حافة الوش أو الضهر.
            x_touch = side[:x1] >= tie[:x0] - 0.15.cm &&
                      side[:x0] <= tie[:x1] + 0.15.cm
            y_touch = side[:y1] >= tie[:y0] - 0.15.cm &&
                      side[:y0] <= tie[:y1] + 0.15.cm
            z0 = [side[:z0], tie[:z0]].max
            z1 = [side[:z1], tie[:z1]].min
            next unless x_touch && y_touch && z1 - z0 > 1.cm

            side_center_x = (side[:x0] + side[:x1]) / 2.0
            tie_center_x  = (tie[:x0] + tie[:x1]) / 2.0
            side_center_y = (side[:y0] + side[:y1]) / 2.0
            tie_center_y  = (tie[:y0] + tie[:y1]) / 2.0

            # نفس مبدأ الشاسيه الخارجي المستقر:
            # المسمار + وش الربط في جنب شاسيه الدرج،
            # والفيشر في وش/ضهر شاسيه الدرج.
            left_side  = side_center_x > tie_center_x
            right_side = side_center_x < tie_center_x
            front_tie  = tie_center_y < side_center_y
            side_on_left = right_side

            flip_selected_support_x =
              (front_tie && right_side) || (!front_tie && left_side)
            rotate_other_support_y =
              (front_tie && left_side) || (!front_tie && right_side)

            x = (side[:x0] + side[:x1]) / 2.0
            y = front_tie ? tie[:y1] : tie[:y0]

            screw_direction = front_tie ? Y_AXIS : Y_AXIS.reverse
            dowel_direction = screw_direction.reverse

            available_screw_depth =
              screw_direction.samedirection?(Y_AXIS) ? side[:y1] - y : y - side[:y0]
            screw_depth = [requested_connector_reach, available_screw_depth - 0.1.mm].min
            cam_radius = cam_diameter / 2.0
            cam_distance = [screw_depth, available_screw_depth - cam_radius - 0.1.mm].min

            tie_depth = tie[:y1] - tie[:y0]
            actual_dowel_depth = [requested_dowel_depth, tie_depth - 0.1.mm].min
            next if screw_depth <= 0.1.mm ||
                    cam_distance <= cam_radius ||
                    actual_dowel_depth <= 0.1.mm

            cam_face = cam_face_for_side[side[:entity]] ||= (side_on_left ? :right : :left)
            cam_start_x = cam_face == :right ? side[:x1] : side[:x0]
            cam_direction = cam_face == :right ? X_AXIS.reverse : X_AXIS
            cam_depth = [requested_cam_depth, side[:x1] - side[:x0] - 0.1.mm].min
            next if cam_depth <= 0.1.mm

            specs = inner_drawer_elita_specs(
              z0, z1, offset, coil_count, coil_center_distance
            )

            specs.each do |spec|
              z = spec[:z]

              # لو الكويلة خرجت عن ارتفاع الشاسيه، نزحزحها للداخل فقط.
              valid_coils = spec[:coil_zs].map do |coil_z|
                [[coil_z, z0 + 0.3.cm].max, z1 - 0.3.cm].min
              end.uniq

              joint = Geom::Point3d.new(x, y, z)
              key = [
                side[:entity].object_id, tie[:entity].object_id,
                (x / 0.1.cm).round, (y / 0.1.cm).round, (z / 0.1.cm).round
              ]
              next if used[key]
              used[key] = true
              number += 1

              drill_round_hole(
                side[:entity], side[:tr], joint, screw_direction,
                screw_depth, screw_diameter, 'SCREW', "INNER-#{number}"
              )
              drill_round_hole(
                tie[:entity], tie[:tr], joint, dowel_direction,
                actual_dowel_depth, dowel_diameter, 'DOWEL', "INNER-#{number}"
              )

              cam_center = joint.offset(screw_direction, cam_distance)
              cam_start = Geom::Point3d.new(cam_start_x, cam_center.y, z)
              drill_round_hole(
                side[:entity], side[:tr], cam_start, cam_direction,
                cam_depth, cam_diameter, 'CAM', "INNER-#{number}"
              )

              valid_coils.each_with_index do |coil_z, coil_index|
                coil_point = Geom::Point3d.new(x, y, coil_z)
                drill_round_hole(
                  side[:entity], side[:tr], coil_point, screw_direction,
                  [coil_thickness_depth, available_screw_depth - 0.1.mm].min,
                  coil_diameter, 'COIL', "INNER-#{number}-#{coil_index + 1}"
                )
                drill_round_hole(
                  tie[:entity], tie[:tr], coil_point, dowel_direction,
                  [coil_face_depth, tie_depth - 0.1.mm].min,
                  coil_diameter, 'COIL', "INNER-#{number}-#{coil_index + 1}"
                )
              end

              # الإكسسوار داخل Group الدرج نفسه، فيتحرك مع الدرج تلقائيًا.
              add_elita_accessory(
                drawer_group.entities, accessory_definition, joint,
                screw_direction, cam_direction, actual_dowel_depth,
                "INNER-#{number}", data, cam_center,
                false, false, false, true,
                flip_selected_support_x, rotate_other_support_y
              )
            end
          end
        end
      end
    end

    # ============================================================
    # Manufacturing-first OpenCutList orientation
    # ============================================================
    # الفكرة: القطعة تتولد من البداية بوجه تصنيع ثابت ومتوقع للـCutList،
    # قبل إضافة أي تخريم. بهذا لا نحتاج لإعادة تدوير Definition بعد أن
    # تصبح مليئة بفتحات الإليتا، وهي العملية التي كانت تسبب الوقفة عند 94%.
    #
    # لا نغيّر مكان القطعة ولا أبعادها ولا منطق النجارة. كل ما نفعله هنا
    # هو اختيار الوجه الصناعي أثناء إنشاء القطعة وهي ما زالت هندسة بسيطة.
    # شاسيه الأدراج مستبعد لأنه يملك توجيهاته المستقرة الخاصة به لاحقًا.
    def prepare_manufacturing_face_at_creation(instance, name, badges, width, depth, height)
      return instance unless instance && instance.valid?
      tags = Array(badges).map(&:to_s)
      text = name.to_s

      # هذه القطع لها منطق Front/Back خاص ومختبر بالفعل.
      return instance if tags.any? { |tag| %w[DRAWER_CHASSIS DRAWER_SIDE DRAWER_BOX DRAWER_BOTTOM].include?(tag) }
      return instance if tags.include?('HARDWARE') || tags.include?('ACCESSORY') || tags.include?('BACK_PANEL') || tags.include?('DOOR_PANEL')

      shelf_like = tags.include?('SHELF') || (text.include?('رف') && !text.include?('حامل رف'))
      partition_like = tags.include?('PARTITION') || text.include?('قاطع')

      if shelf_like
        # قاعدة/أرضية: وش التشغيل العلوي (+Z) هو الوجه الصناعي.
        # باقي الأرفف/الرفوف الفاصلة: وش التشغيل السفلي (-Z) هو الوجه الصناعي،
        # وهو نفس الوجه الذي يستقبل CAM في منطق الإليتا الحالي.
        base_like = text.match?(/قاعدة|أرضية/) || tags.include?('DRAWER_BOTTOM')
        preferred = base_like ? 'top' : 'bottom'
        [instance, instance.definition].each do |owner|
          owner.set_attribute('MHD_DRESSING', 'PREFERRED_CAM_FACE', preferred)
          owner.set_attribute('MHD_DRESSING', 'OCL_FACE_PREPARED_AT_CREATION', true)
        end

        # الشكل الافتراضي للوح Z-thin يعرض +Z. الرف العادي يحتاج -Z فقط؛
        # نعمل القلب الآن والقطعة 6 أوجه تقريبًا، قبل أي تخريم أو تعقيد هندسي.
        ocl_swap_front_back(instance, width, depth, height) unless base_like
      elsif partition_like
        # القاطع الرأسي يظل على وجه +X الافتراضي في OpenCutList.
        # ونثبت نفس الوجه للإليتا لاحقًا بدل أن تختار الدالة وجهًا آخر ثم
        # تضطر الأداة لإعادة تدوير القاطع بعد التخريم.
        [instance, instance.definition].each do |owner|
          owner.set_attribute('MHD_DRESSING', 'PREFERRED_CAM_FACE', 'right')
          owner.set_attribute('MHD_DRESSING', 'OCL_FACE_PREPARED_AT_CREATION', true)
        end
      end
      instance
    rescue => error
      puts "MHDESIGN manufacturing face prep skipped: #{error.message}"
      instance
    end

    def add_box(parent, model, name, x, y, z, width, depth, height, material, badges = [])
      name = qualified_part_name(human_part_name(name, x, width))
      raise "مقاس غير صحيح في القطعة: #{name}" if [width, depth, height].any? { |v| v <= 0 }
      unless @wall_relief_bypass
        back_relief_part = badges.include?('BACK_PANEL') || name.include?('ضهر العمود')
        horizontal_relief_part = badges.include?('SHELF') || badges.include?('MAIN_CARCASS') || name.match?(/رف|قاعدة شاسيه|قرصة/)
        vertical_relief_part = badges.include?('PARTITION') || badges.include?('MAIN_CARCASS') || name.match?(/قاطع|جنب شاسيه/)
        shelf_relief_part = name.match?(/رف/) && !name.match?(/قرصة/)
        # قرصة شاسيه الأدراج تتعامل نجاريًا مع الخلع مثل الرف تمامًا:
        # في الخلع الحقيقي تأخذ نفس بروفايل الخلعة، وفي تفادي العمود
        # ترجع بكامل عمق الفتحة مثل الرفوف والقواطيع الداخلية.
        drawer_chassis_top_relief_part = badges.include?('DRAWER_CHASSIS') && name.match?(/قرصة شاسيه الأدراج/)
        # باقي شاسيه الأدراج يمكن أن يكون عمقه محسوبًا مسبقًا على مستوى الفتحة
        # حتى يرجع الشاسيه كله كوحدة واحدة، فلا نعيد تطبيق الخلعة على قطعة منفردة.
        drawer_relief_precalculated = badges.include?('DRAWER_RELIEF_PRECALCULATED')
        # القاطع الصغير داخل الفتحة يتبع نفس عمق الرف في نوعي الخلع:
        # - تفادي العمود بدخول العمق: يرجع مع عمق الفتحة بالكامل.
        # - خلع حقيقي + تجليد: يدخل بالعمق بنفس حساب الرف (بروز العمود
        #   بعد خصم دخول الضهر وتخانة الضهر المحسوبين في @shelf_reliefs).
        # القواطيع الرئيسية بين الأعمدة لا تحمل هذا الـBadge وتظل على منطقها القديم.
        bay_internal_partition = badges.include?('BAY_INTERNAL_PARTITION')
        source = if shelf_relief_part || drawer_chassis_top_relief_part || bay_internal_partition
          @shelf_reliefs || @bay_depth_reliefs
        elsif back_relief_part
          @bay_depth_reliefs
        else
          @carcass_reliefs || @wall_reliefs
        end
        spans = drawer_relief_precalculated ? [] : merge_relief_spans(reliefs_for_part(x, z, width, height, source), depth)
        depth_avoid_rectangular_part = shelf_relief_part || bay_internal_partition || drawer_chassis_top_relief_part
        if !spans.empty? && depth_avoid_rectangular_part && spans.any? { |span| span['x0'] <= 0.1.cm && span['x1'] >= width-0.1.cm }
          # الرف والقاطع الداخلي الصغير أمام عمود الحائط يظلان ألواحًا مستطيلة
          # صحيحة للـCutList: نقلل LenY نفسه بنفس قيمة رجوع الفتحة.
          reduced_depth = depth - spans.map { |span| span['depth'].to_f }.max
          raise "الخلعة تستهلك عمق القطعة: #{name}" if reduced_depth <= 1.cm
          return add_box_without_wall_relief(parent, model, name, x, y, z, width, reduced_depth, height, material, badges + ['WALL_RELIEF','REDUCED_DEPTH'])
        elsif !spans.empty? && back_relief_part
          cursor = 0
          pieces = []
          previous_bypass = @wall_relief_bypass
          @wall_relief_bypass = true
          begin
            spans.each do |span|
              if span['x0'] > cursor + 0.1.cm
                pieces << add_box(parent, model, "#{name} - جزء", x+cursor, y, z, span['x0']-cursor, depth, height, material, badges + ['WALL_RELIEF'])
              end
              # الضهر المقابل للعمود لا يُلغى؛ يتحرك للأمام بقيمة البروز.
              pieces << add_box(parent, model, "ضهر خلعة #{name}", x+span['x0'], y-span['depth'], z, span['x1']-span['x0'], depth, height, material, badges + ['WALL_RELIEF','FORWARD_BACK'])
              cursor = [cursor, span['x1']].max
            end
            pieces << add_box(parent, model, "#{name} - جزء", x+cursor, y, z, width-cursor, depth, height, material, badges + ['WALL_RELIEF']) if width-cursor > 0.1.cm
          ensure
            @wall_relief_bypass = previous_bypass
          end
          return pieces.first
        elsif !spans.empty? && horizontal_relief_part && height <= [width, depth].min + 0.1.cm
          return add_xy_profile(parent, model, name, relief_profile_points(width, depth, spans), x, y, z, width, depth, height, material, badges + ['WALL_RELIEF'])
        elsif !spans.empty? && vertical_relief_part
          center = width / 2.0
          covering = spans.select { |span| span['x0'] <= center && span['x1'] >= center }
          unless covering.empty?
            depth -= covering.map { |span| span['depth'] }.max
            raise "الخلعة تستهلك عمق القطعة: #{name}" if depth <= 1.cm
          end
        end
      end
      check_board_limit(name, width, depth, height, material, badges)
      group = parent.add_group
      face = group.entities.add_face([0, 0, 0], [width, 0, 0], [width, depth, 0], [0, depth, 0])
      raise "تعذر رسم القطعة: #{name}" unless face
      face.reverse! if face.normal.z < 0
      face.pushpull(height)
      group.entities.grep(Sketchup::Face).each do |item|
        item.material = material
        item.back_material = material
      end
      instance = group.to_component
      instance.definition.name = unique_name(model, name)
      instance.name = name
      instance.material = material
      instance.transform!(Geom::Transformation.translation([x, y, z]))
      [instance, instance.definition].each do |owner|
        owner.set_attribute('dynamic_attributes', '_name', name)
        owner.set_attribute('dynamic_attributes', 'name', name)
        owner.set_attribute('dynamic_attributes', 'material', material.name)
        owner.set_attribute('dynamic_attributes', 'lenx', width.to_f)
        owner.set_attribute('dynamic_attributes', 'leny', depth.to_f)
        owner.set_attribute('dynamic_attributes', 'lenz', height.to_f)
      end
      definition = instance.definition
      definition.set_attribute('ladb_opencutlist', 'cumulable', 0)
      definition.set_attribute('ladb_opencutlist', 'ignore_grain_direction', false)
      definition.set_attribute('ladb_opencutlist', 'instance_count_by_part', 1)
      definition.set_attribute('ladb_opencutlist', 'length_increase', '0')
      definition.set_attribute('ladb_opencutlist', 'numbers', '{}')
      definition.set_attribute('ladb_opencutlist', 'orientation_locked_on_axis', false)
      definition.set_attribute('ladb_opencutlist', 'symmetrical', false)
      set_part_badges(definition, badges)
      definition.set_attribute('ladb_opencutlist', 'thickness_increase', '0')
      definition.set_attribute('ladb_opencutlist', 'thickness_layer_count', 1)
      definition.set_attribute('ladb_opencutlist', 'uuid', SecureRandom.uuid)
      definition.set_attribute('ladb_opencutlist', 'width_increase', '0')
      apply_edge_banding(instance, model, name, material, badges, width, depth, height)
      orient_part_textures(instance, name, badges, width, depth, height)
      prepare_manufacturing_face_at_creation(instance, name, badges, width, depth, height)
      instance
    end

    def add_xy_profile(parent, model, name, points_xy, x, y, z, width, depth, height, material, badges = [])
      name = human_part_name(name, x, width)
      full_name = qualified_part_name(name)
      check_board_limit(full_name, width, depth, height, material, badges)
      group = parent.add_group
      cleaned = points_xy.each_with_object([]) { |point, list| list << point unless list.last == point }
      cleaned.pop if cleaned.length > 2 && cleaned.first == cleaned.last
      points = cleaned.map { |px, py| [px, py, 0] }
      face = group.entities.add_face(points)
      raise "تعذر رسم قطاع المفحار: #{full_name}" unless face
      face.reverse! if face.normal.z < 0
      face.pushpull(height)
      instance = group.to_component
      instance.transform!(Geom::Transformation.translation([x, y, z]))
      finish_generated_part(instance, model, name, material, badges)
      [instance, instance.definition].each do |owner|
        owner.set_attribute('dynamic_attributes', 'lenx', width.to_f)
        owner.set_attribute('dynamic_attributes', 'leny', depth.to_f)
        owner.set_attribute('dynamic_attributes', 'lenz', height.to_f)
      end
      apply_edge_banding(instance, model, name, material, badges, width, depth, height)
      orient_part_textures(instance, name, badges, width, depth, height)
      prepare_manufacturing_face_at_creation(instance, name, badges, width, depth, height)
      instance
    end

    def add_yz_profile(parent, model, name, points_yz, x, y, z, width, depth, height, material, badges = [])
      name = human_part_name(name, x, width)
      full_name = qualified_part_name(name)
      check_board_limit(full_name, width, depth, height, material, badges)
      group = parent.add_group
      cleaned = points_yz.each_with_object([]) { |point, list| list << point unless list.last == point }
      cleaned.pop if cleaned.length > 2 && cleaned.first == cleaned.last
      points = cleaned.map { |py, pz| [0, py, pz] }
      face = group.entities.add_face(points)
      raise "تعذر رسم قطاع المفحار: #{full_name}" unless face
      face.reverse! if face.normal.x < 0
      face.pushpull(width)
      instance = group.to_component
      instance.transform!(Geom::Transformation.translation([x, y, z]))
      finish_generated_part(instance, model, name, material, badges)
      [instance, instance.definition].each do |owner|
        owner.set_attribute('dynamic_attributes', 'lenx', width.to_f)
        owner.set_attribute('dynamic_attributes', 'leny', depth.to_f)
        owner.set_attribute('dynamic_attributes', 'lenz', height.to_f)
      end
      apply_edge_banding(instance, model, name, material, badges, width, depth, height)
      orient_part_textures(instance, name, badges, width, depth, height)
      prepare_manufacturing_face_at_creation(instance, name, badges, width, depth, height)
      instance
    end

    # يكرر بالضبط منطق Smart Axes > Swap Front/Backside في OpenCutList:
    # يرتب X/Y/Z إلى طول/عرض/تخانة، يعكس محور التخانة، ويحافظ على نظام
    # محاور يميني. تتحرك المحاور فقط بينما تظل الهندسة في مكانها بالموديل.
    def rotate_face_texture_90(face)
      return unless face.respond_to?(:clear_texture_position)
      return unless face.material && face.material.texture
      face.clear_texture_position(true)
      angle = Math::PI / 2.0
      angle = Math::PI - angle if face.normal.samedirection?(Z_AXIS.reverse)
      edge = face.edges.first
      return unless edge
      points = [edge.start.position, edge.end.position]
      uv_helper = face.get_UVHelper(true, false)
      rotation = Geom::Transformation.rotation(ORIGIN, face.normal, angle)
      mapping = []
      points.each do |point|
        mapping << point.transform(rotation)
        mapping << uv_helper.get_front_UVQ(point)
      end
      face.position_material(face.material, mapping, true)
    rescue
      nil
    end

    # يجعل وجه الإليتا الحقيقي (وجه تخريم CAM) هو الوجه الأمامي في OpenCutList.
    # يتم التنفيذ بعد انتهاء كل عمليات التخريم، لذلك لا يغيّر أي نقطة نجارة
    # أو موضع إكسسوار داخل الموديل؛ الذي يتغير فقط هو محاور Definition/Instance.
    def ocl_align_front_to_local_normal(instance, normal_values)
      return instance unless instance && instance.valid?
      return instance if instance.get_attribute('MHD_DRESSING', 'OCL_ELITA_DRILLED_FACE_ALIGNED', false)
      values = Array(normal_values).map(&:to_f)
      return instance unless values.length >= 3

      desired_z = Geom::Vector3d.new(values[0], values[1], values[2])
      return instance if desired_z.length <= 0.0001
      desired_z.normalize!

      # محور X الصناعي نختاره من أطول محور متعامد مع وجه التشغيل. بهذا يظل
      # طول/عرض اللوح منطقيين سواء كانت القطعة رفاً أفقياً أو قاطعاً رأسياً.
      bounds = instance.definition.bounds
      candidates = [
        [X_AXIS, bounds.width.to_f, 2],
        [Y_AXIS, bounds.depth.to_f, 1],
        [Z_AXIS, bounds.height.to_f, 0]
      ].select { |axis, _size, _order| axis.dot(desired_z).abs < 0.5 }
      return instance if candidates.empty?

      desired_x = candidates.max_by { |_axis, size, order| [size, order] }[0].clone
      # أزل أي مركبة عددية صغيرة في اتجاه Z ثم كوّن Basis يميني.
      dot = desired_x.dot(desired_z)
      desired_x = Geom::Vector3d.new(
        desired_x.x - desired_z.x * dot,
        desired_x.y - desired_z.y * dot,
        desired_x.z - desired_z.z * dot
      )
      return instance if desired_x.length <= 0.0001
      desired_x.normalize!
      desired_y = desired_z * desired_x
      return instance if desired_y.length <= 0.0001
      desired_y.normalize!

      axes_transform = Geom::Transformation.axes(ORIGIN, desired_x, desired_y, desired_z)
      definition = instance.definition

      # Fast path مهم جدًا: أغلب الأرفف/القواطيع تكون محاور تصنيعها صحيحة أصلًا.
      # النسخة السابقة كانت تعمل transform_entities حتى لو التحويل Identity فعليًا،
      # وده كان سبب الوقفة الطويلة عند 94%. لا نلمس الهندسة إطلاقًا إلا لو
      # وجه CAM يحتاج تغيير محاور حقيقي.
      matrix = axes_transform.to_a
      identity = Geom::Transformation.new.to_a
      needs_axis_change = matrix.each_with_index.any? { |value, index| (value.to_f - identity[index].to_f).abs > 1.0e-8 }

      if needs_axis_change
        geometry = definition.entities.to_a
        definition.entities.transform_entities(axes_transform.inverse, geometry) unless geometry.empty?

        # مهم للأداء مع Dynamic Components:
        # assignment عبر instance.transformation= يطلق إشعارات تغيير للـEntity
        # وقد يجعل محرك الـDC يعمل redraw لكل قطعة مخَرَّمة على حدة. نستخدم
        # move! لتعويض تغيير محاور الـDefinition بدون تسجيل حركة DC/Undo؛
        # النتيجة البصرية والموقع النهائي نفسهما، لكن من دون سلسلة redraws.
        target_transformation = instance.transformation * axes_transform
        if instance.respond_to?(:move!)
          instance.move!(target_transformation)
        else
          instance.transformation = target_transformation
        end

        # إعادة إسقاط الخامة مكلفة جدًا ولا تفيد إلا مع Texture فعلية.
        # الألوان السادة لا تحتاج إزالة/إعادة خامة بعد تغيير المحاور.
        definition.entities.grep(Sketchup::Face).each do |face|
          front_material = face.material
          back_material = face.back_material
          front_textured = front_material && front_material.texture
          back_textured = back_material && back_material.texture
          next unless front_textured || back_textured
          face.material = nil if front_textured
          face.back_material = nil if back_textured
          face.material = front_material if front_textured
          face.back_material = back_material if back_textured
        end
      end

      definition.set_attribute('ladb_opencutlist', 'orientation_locked_on_axis', true)
      definition.set_attribute('MHD_DRESSING', 'OCL_ELITA_DRILLED_FACE', true)
      instance.set_attribute('MHD_DRESSING', 'OCL_ELITA_DRILLED_FACE_ALIGNED', true)
      instance
    rescue => error
      puts "MHDESIGN OCL Elita face alignment skipped: #{error.message}"
      instance
    end

    # يمر على كل القطع الخشبية بعد انتهاء الإليتا ويُظهر في الـCutList
    # الوجه الذي يحتوي تخريم وش الربط. يشمل الرف العادي، الرف الفاصل، القاطع،
    # القرصة، القاعدة وأي قطعة خشبية عامة. شاسيه الأدراج له توجيه مستقل مستقر
    # في النسخة الحالية، لذلك نتركه كما هو حتى لا نرجع المشكلة السابقة.
    def orient_elita_drilled_faces_for_ocl(_entities = nil, _visited = {})
      queued = @ocl_elita_drilled_instances
      return true unless queued.is_a?(Hash) && !queued.empty?

      queued.each_value do |entity|
        next unless entity && entity.valid? && entity.is_a?(Sketchup::ComponentInstance)
        badges = joinery_badges(entity)
        drawer_specific = badges.any? { |tag| %w[DRAWER_CHASSIS DRAWER_SIDE DRAWER_BOX DRAWER_BOTTOM].include?(tag) }
        next if drawer_specific
        normal = entity.get_attribute('MHD_DRESSING', 'OCL_ELITA_FRONT_NORMAL_LOCAL', nil)
        ocl_align_front_to_local_normal(entity, normal) if normal
      end
      true
    ensure
      @ocl_elita_drilled_instances = {}
    end

    def ocl_swap_front_back(instance, width, depth, height, rotate_texture = false)
      ordered = [
        { value: width.to_f.abs, axis: X_AXIS, order: 2 },
        { value: depth.to_f.abs, axis: Y_AXIS, order: 1 },
        { value: height.to_f.abs, axis: Z_AXIS, order: 0 }
      ].sort_by { |item| [item[:value], item[:order]] }
      x_axis = ordered[2][:axis]
      y_axis = ordered[1][:axis]
      z_axis = ordered[0][:axis].reverse
      y_axis = y_axis.reverse unless (x_axis * y_axis).samedirection?(z_axis)
      axes_transform = Geom::Transformation.axes(ORIGIN, x_axis, y_axis, z_axis)
      definition = instance.definition
      definition.entities.transform_entities(axes_transform.inverse, definition.entities.to_a)
      target_transformation = instance.transformation * axes_transform
      if instance.respond_to?(:move!)
        instance.move!(target_transformation)
      else
        instance.transformation = target_transformation
      end
      # تحويل المحاور يحافظ على الهندسة لكنه ينقل UV القديمة معها، فيظهر
      # عرق الخشب بالعرض. إزالة الخامة وإعادتها تعيد إسقاط التكستشر على
      # المحاور الجديدة؛ وبما أن الـInstance أخذ التحويل العكسي يظهر العرق
      # في الموديل بنفس اتجاهه الصناعي الصحيح.
      definition.entities.grep(Sketchup::Face).each do |face|
        front_material = face.material
        back_material = face.back_material
        face.material = nil
        face.back_material = nil
        face.material = front_material if front_material
        face.back_material = back_material if back_material
      end
      parent_axis = rotate_texture ? Z_AXIS : X_AXIS
      local_axis = parent_axis.transform(instance.transformation.inverse)
      orient_definition_textures(definition, local_axis)
      definition.set_attribute('ladb_opencutlist', 'orientation_locked_on_axis', true)
      definition.set_attribute('MHD_DRESSING', 'OCL_FRONT_BACK_SWAPPED', true)
      instance
    end

    def grooved_mode?
      @back_groove_context && @back_groove_context['enabled']
    end

    # مكان مفحار الضهر على وجه محدد من القاطوع/الجنب. عندما يقع عمود
    # الحائط بالكامل داخل فتحة، ينتقل ضهر هذه الفتحة للأمام بقيمة البروز؛
    # لذلك ينتقل مفحاره وحده، بينما يظل مفحار الفتحة المجاورة في مكانه.
    def vertical_back_groove_interval(x, width, y, depth, face_side)
      y0 = @back_groove_context['y0'].to_f
      y1 = @back_groove_context['y1'].to_f
      boundary_x = face_side == :left ? x : x + width
      shifted_bay = Array(@bay_depth_reliefs).find do |relief|
        next false unless relief['proposal'].to_s == 'bay_depth'
        bay_boundary = face_side == :left ? relief['x1'].to_f : relief['x0'].to_f
        (bay_boundary - boundary_x).abs <= 0.15.cm
      end
      if shifted_bay
        shift = shifted_bay['depth'].to_f
        y0 -= shift
        y1 -= shift
      end
      gy0 = [[y0 - y, 0].max, depth].min
      gy1 = [[y1 - y, gy0].max, depth].min
      [gy0, gy1]
    end

    # ينشئ قطعة رأسية من footprint في X/Y مع شطر أسفل/أعلى القطعة
    # حسب خط الميل. بهذا أي قطعة تلتقي بخط الميل لا تنتهي بحرف أفقي،
    # بل تأخذ نفس زاوية الميل على كامل تخانتها.
    def add_xy_profile_between_z_planes(parent, model, name, points_xy, x, y,
                                        bottom_z_proc, top_z_proc,
                                        width, depth, nominal_height,
                                        material, badges = [])
      name = human_part_name(name, x, width)
      full_name = qualified_part_name(name)
      check_board_limit(full_name, width, depth, nominal_height, material, badges)

      cleaned = points_xy.each_with_object([]) { |point, list| list << point unless list.last == point }
      cleaned.pop if cleaned.length > 2 && cleaned.first == cleaned.last
      raise "قطاع غير صالح للقطعة المائلة: #{full_name}" if cleaned.length < 3

      group = parent.add_group
      ents = group.entities

      bottom_pts = cleaned.map do |px, py|
        [px, py, bottom_z_proc.call(px)]
      end
      top_pts = cleaned.map do |px, py|
        [px, py, top_z_proc.call(px)]
      end

      bottom_face = ents.add_face(bottom_pts)
      raise "تعذر رسم أسفل القطعة المشطوفة: #{full_name}" unless bottom_face
      bottom_face.reverse! if bottom_face.normal.z > 0

      top_face = ents.add_face(top_pts)
      raise "تعذر رسم أعلى القطعة المشطوفة: #{full_name}" unless top_face
      top_face.reverse! if top_face.normal.z < 0

      cleaned.length.times do |i|
        j = (i + 1) % cleaned.length
        face = ents.add_face(bottom_pts[i], bottom_pts[j], top_pts[j], top_pts[i])
        raise "تعذر رسم جنب القطعة المشطوفة: #{full_name}" unless face
      end

      ents.grep(Sketchup::Face).each do |face|
        face.material = material
        face.back_material = material
      end

      instance = group.to_component
      instance.transform!(Geom::Transformation.translation([x, y, 0]))
      finish_generated_part(instance, model, name, material, badges + ['SLOPE_MITER'])

      min_z = (bottom_pts + top_pts).map { |p| p[2].to_f }.min
      max_z = (bottom_pts + top_pts).map { |p| p[2].to_f }.max
      manufacturing_height = max_z - min_z

      [instance, instance.definition].each do |owner|
        owner.set_attribute('dynamic_attributes', 'lenx', width.to_f)
        owner.set_attribute('dynamic_attributes', 'leny', depth.to_f)
        owner.set_attribute('dynamic_attributes', 'lenz', manufacturing_height.to_f)
      end
      instance.definition.set_attribute('MHD_DRESSING', 'SLOPE_MITER', true)
      apply_edge_banding(instance, model, name, material, badges, width, depth, manufacturing_height)
      orient_part_textures(instance, name, badges, width, depth, manufacturing_height)
      prepare_manufacturing_face_at_creation(instance, name, badges, width, depth, manufacturing_height)
      instance
    end

    def vertical_panel_meets_slope?(x, z, width, height)
      return false unless @slope_context
      center_x = x.to_f + width.to_f / 2.0
      slope_z = slope_height_at(center_x)
      return false unless slope_z
      requested_top = z.to_f + height.to_f
      tolerance = [width.to_f * 2.0, 2.5.cm].max
      (requested_top - slope_z).abs <= tolerance
    end

    # قطاع رأسي حقيقي في مستوى X/Y. side=:left يعني المفحار من وجه X=0،
    # side=:right من وجه X=width، و :both للقاطع ذي المفحارين.
    def add_vertical_panel(parent, model, name, x, y, z, width, depth, height, material, badges = [], side = nil)
      slope_miter = vertical_panel_meets_slope?(x, z, width, height)

      unless grooved_mode? && side
        if slope_miter
          center_x = x.to_f + width.to_f / 2.0
          requested_top = z.to_f + height.to_f
          slope_offset = requested_top - slope_height_at(center_x)
          points = [[0,0],[width,0],[width,depth],[0,depth]]
          return add_xy_profile_between_z_planes(
            parent, model, name, points, x, y,
            ->(_px) { z.to_f },
            ->(px) { slope_height_at(x.to_f + px.to_f) + slope_offset },
            width, depth, height, material, badges
          )
        end
        return add_box(parent, model, name, x, y, z, width, depth, height, material, badges)
      end

      spans = merge_relief_spans(reliefs_for_part(x, z, width, height, @carcass_reliefs || @wall_reliefs), depth)
      center = width / 2.0
      covering = spans.select { |span| span['x0'] <= center && span['x1'] >= center }
      depth -= covering.map { |span| span['depth'] }.max unless covering.empty?
      raise "الخلعة تستهلك عمق القطعة: #{name}" if depth <= 1.cm
      groove = [@back_groove_context['depth'].to_f, width / 2.0 - 0.01.cm].min
      left = side == :left || side == :both
      right = side == :right || side == :both
      left_y0, left_y1 = vertical_back_groove_interval(x, width, y, depth, :left)
      right_y0, right_y1 = vertical_back_groove_interval(x, width, y, depth, :right)
      left = false if left_y1 <= left_y0
      right = false if right_y1 <= right_y0
      return add_box_without_wall_relief(parent, model, name, x, y, z, width, depth, height, material, badges) if groove <= 0 || (!left && !right)
      points = [[0, 0], [width, 0]]
      if right
        points.concat([[width, right_y0], [width-groove, right_y0], [width-groove, right_y1], [width, right_y1]])
      end
      points << [width, depth]
      points << [0, depth]
      if left
        points.concat([[0, left_y1], [groove, left_y1], [groove, left_y0], [0, left_y0]])
      end
      if slope_miter
        center_x = x.to_f + width.to_f / 2.0
        requested_top = z.to_f + height.to_f
        slope_offset = requested_top - slope_height_at(center_x)
        add_xy_profile_between_z_planes(
          parent, model, name, points, x, y,
          ->(_px) { z.to_f },
          ->(px) { slope_height_at(x.to_f + px.to_f) + slope_offset },
          width, depth, height, material, badges + ['BACK_GROOVE']
        )
      else
        add_xy_profile(parent, model, name, points, x, y, z, width, depth, height, material, badges + ['BACK_GROOVE'])
      end
    end

    def build_horizontal_back_grooves(regions, total, depth, thickness, back_thickness, back_inset, data)
      groove = [data['back_groove_depth'].to_f, 0].max.cm
      connected = data['back_joint_mode'].to_s == 'connected_back'
      runs = Array(regions).each_with_index.map do |region, index|
        clear_x = region['x'].to_f
        clear_width = region['width'].to_f
        bay_relief = Array(@bay_depth_reliefs).find do |relief|
          relief['proposal'].to_s == 'bay_depth' &&
            (relief['x0'].to_f-clear_x).abs <= 0.15.cm &&
            (relief['x1'].to_f-(clear_x+clear_width)).abs <= 0.15.cm
        end
        left_allowance = index.zero? ? groove : (connected ? thickness/2.0 : groove)
        right_allowance = index == regions.length-1 ? groove : (connected ? thickness/2.0 : groove)
        back_y = depth-back_inset-back_thickness-(bay_relief ? bay_relief['depth'].to_f : 0)
        {
          'x0' => [clear_x-left_allowance, 0].max,
          'x1' => [clear_x+clear_width+right_allowance, total].min,
          'y0' => back_y,
          'y1' => back_y+back_thickness
        }
      end
      # ضهران متجاوران على نفس مستوى Y ينتجان مسارين متداخلين عند
      # القاطوع. حفرهما منفصلين قد يعيد إنشاء Face يغلق المجرى الثاني؛
      # لذلك ندمجهما أولًا في مسار واحد غير متداخل.
      merged = []
      runs.sort_by { |run| [run['y0'],run['x0']] }.each do |run|
        previous = merged[-1]
        same_level = previous &&
          (previous['y0']-run['y0']).abs <= 0.01.cm &&
          (previous['y1']-run['y1']).abs <= 0.01.cm
        if same_level && run['x0'] <= previous['x1']+0.01.cm
          previous['x1'] = [previous['x1'],run['x1']].max
        else
          merged << run.dup
        end
      end
      merged
    end

    def split_groove_run_around_reliefs(run, reliefs, panel_depth)
      segments = [[run['x0'], run['x1']]]
      Array(reliefs).each do |relief|
        # لا نقص مسار المفحار إلا إذا كانت الخلعة قد أزالت الخشب فعلًا
        # من مستوى Y الذي يقع فيه هذا المفحار.
        next unless run['y1'] > panel_depth-relief['depth'].to_f+0.01.cm
        segments = segments.flat_map do |a, b|
          cut0 = [relief['x0'].to_f, a].max
          cut1 = [relief['x1'].to_f, b].min
          if cut1 <= cut0+0.01.cm
            [[a,b]]
          else
            result = []
            result << [a,cut0] if cut0-a > 0.05.cm
            result << [cut1,b] if b-cut1 > 0.05.cm
            result
          end
        end
      end
      segments
    end

    def add_horizontal_relief_grooved_panel(parent, model, name, x, y, z, width, depth, height, material, badges, face_side, spans)
      full_name = qualified_part_name(name)
      check_board_limit(full_name, width, depth, height, material, badges)
      group = parent.add_group
      outline = relief_profile_points(width, depth, spans)
      face = group.entities.add_face(outline.map { |px,py| [px,py,0] })
      raise "تعذر رسم الخلعة في القطعة: #{full_name}" unless face
      face.reverse! if face.normal.z < 0
      face.pushpull(height)
      groove_depth = [@back_groove_context['depth'].to_f, height-0.01.cm].min
      carved_rectangles = []
      if groove_depth > 0
        Array(@horizontal_back_grooves).each do |run|
          local_run = {
            'x0' => [run['x0'].to_f-x, 0].max,
            'x1' => [run['x1'].to_f-x, width].min,
            'y0' => [run['y0'].to_f-y, 0].max,
            'y1' => [run['y1'].to_f-y, depth].min
          }
          next if local_run['x1']-local_run['x0'] <= 0.05.cm || local_run['y1']-local_run['y0'] <= 0.01.cm
          split_groove_run_around_reliefs(local_run, spans, depth).each do |gx0,gx1|
            plane_z = face_side == :top ? height : 0
            groove_face = group.entities.add_face(
              [gx0,local_run['y0'],plane_z], [gx1,local_run['y0'],plane_z],
              [gx1,local_run['y1'],plane_z], [gx0,local_run['y1'],plane_z]
            )
            next unless groove_face
            expected = face_side == :top ? Z_AXIS : Z_AXIS.reverse
            groove_face.reverse! unless groove_face.normal.samedirection?(expected)
            groove_face.pushpull(-groove_depth)
            carved_rectangles << [gx0, gx1, local_run['y0'], local_run['y1'], plane_z]
          end
        end
        # بعد اكتمال كل الخلعات احذف أي غطاء متبقٍ على مستوى سطح القرصة/القاعدة.
        # هذا مهم خصوصًا عند تقسيم المفحار حول الخلعة؛ وإلا يراه CutList كمجرى مقفول جزئيًا.
        tolerance = 0.002.cm
        caps = group.entities.grep(Sketchup::Face).select do |candidate|
          carved_rectangles.any? do |gx0,gx1,gy0,gy1,plane_z|
            candidate.vertices.length >= 3 && candidate.vertices.all? do |vertex|
              point = vertex.position
              (point.z-plane_z).abs <= tolerance &&
                point.x >= gx0-tolerance && point.x <= gx1+tolerance &&
                point.y >= gy0-tolerance && point.y <= gy1+tolerance
            end
          end
        end
        group.entities.erase_entities(caps) unless caps.empty?
      end
      instance = group.to_component
      instance.transform!(Geom::Transformation.translation([x,y,z]))
      finish_generated_part(instance, model, name, material, badges + ['WALL_RELIEF','BACK_GROOVE'])
      [instance,instance.definition].each do |owner|
        owner.set_attribute('dynamic_attributes','lenx',width.to_f)
        owner.set_attribute('dynamic_attributes','leny',depth.to_f)
        owner.set_attribute('dynamic_attributes','lenz',height.to_f)
      end
      apply_edge_banding(instance, model, name, material, badges, width, depth, height)
      orient_part_textures(instance, name, badges, width, depth, height)
      instance
    end

    def add_horizontal_grooved_panel(parent, model, name, x, y, z, width, depth, height, material, badges = [], face_side = :top)
      spans = merge_relief_spans(reliefs_for_part(x, z, width, height, @carcass_reliefs || @wall_reliefs), depth)
      unless spans.empty?
        return add_horizontal_relief_grooved_panel(parent, model, name, x, y, z, width, depth, height, material, badges, face_side, spans)
      end
      return add_box(parent, model, name, x, y, z, width, depth, height, material, badges) unless grooved_mode?
      groove = [@back_groove_context['depth'].to_f, height - 0.01.cm].min
      gy0 = [[@back_groove_context['y0'].to_f - y, 0].max, depth].min
      gy1 = [[@back_groove_context['y1'].to_f - y, gy0].max, depth].min
      return add_box(parent, model, name, x, y, z, width, depth, height, material, badges) if groove <= 0 || gy1 <= gy0
      points = if face_side == :top
        [[0,0],[depth,0],[depth,height],[gy1,height],[gy1,height-groove],[gy0,height-groove],[gy0,height],[0,height]]
      else
        [[0,0],[gy0,0],[gy0,groove],[gy1,groove],[gy1,0],[depth,0],[depth,height],[0,height]]
      end
      add_yz_profile(parent, model, name, points, x, y, z, width, depth, height, material, badges + ['BACK_GROOVE'])
    end

    def finish_generated_part(instance, model, name, material, badges = [], preserve_face_materials = false)
      name = qualified_part_name(name)
      instance.definition.name = unique_name(model, name)
      instance.name = ''
      instance.material = material
      unless preserve_face_materials
        instance.definition.entities.grep(Sketchup::Face).each do |face|
          face.material = material
          face.back_material = material
        end
      end
      [instance, instance.definition].each do |owner|
        owner.set_attribute('dynamic_attributes', '_name', name)
        owner.set_attribute('dynamic_attributes', 'name', name)
        owner.set_attribute('dynamic_attributes', 'material', material.name)
      end
      set_part_badges(instance.definition, badges)
      instance.definition.set_attribute('ladb_opencutlist', 'uuid', SecureRandom.uuid)
      instance
    end

    # يرسم قطاعًا رباعيًّا في مستوى X/Z ثم يمنحه عمقًا على محور Y.
    # يُستخدم للقرصة والضهر والضلف المائلة من دون Scale.
    def add_xz_prism(parent, model, name, points_xz, y, depth, material, badges = [])
      raise "عمق غير صحيح في القطعة: #{name}" unless depth.to_f > 0
      group = parent.add_group
      points = points_xz.map { |x, z| [x, 0, z] }
      face = group.entities.add_face(points)
      raise "تعذر رسم القطعة المائلة: #{name}" unless face
      face.reverse! if face.normal.y < 0
      face.pushpull(depth)
      instance = group.to_component
      instance.transform!(Geom::Transformation.translation([0, y, 0]))
      finish_generated_part(instance, model, name, material, badges)
      xs = points_xz.map { |point| point[0].to_f }
      zs = points_xz.map { |point| point[1].to_f }
      orient_part_textures(instance, name, badges, xs.max-xs.min, depth, zs.max-zs.min)
      instance
    end

    # القرصة تُبنى داخل Definition بمحاور تصنيع صحيحة:
    # X على خط الميل، Y للعمق، Z للتخانة. بذلك يقرأ OpenCutList التخانة
    # الحقيقية بدل اعتبار فرق ارتفاع الميل عرضًا للقطعة.
    def add_sloped_relief_top(parent, model, name, total, depth, thickness, material, spans)
      left_height = slope_height_at(0)
      right_height = slope_height_at(total)
      rise = right_height-left_height
      slope_length = Math.sqrt(total*total+rise*rise)
      raise "طول القرصة المائلة غير صحيح: #{name}" if slope_length <= 0
      cosine = total/slope_length
      local_spans = Array(spans).map do |span|
        {
          'x0'=>span['x0'].to_f/cosine,
          'x1'=>span['x1'].to_f/cosine,
          'depth'=>span['depth'].to_f
        }
      end
      outline = relief_profile_points(slope_length, depth, local_spans)
      raise "تعذر رسم خلعة القطعة المائلة: #{name}" if outline.length < 3
      group = parent.add_group
      ents = group.entities

      sine = rise/slope_length
      x_axis = Geom::Vector3d.new(cosine,0,sine)
      y_axis = Geom::Vector3d.new(0,1,0)
      z_axis = Geom::Vector3d.new(-sine,0,cosine)

      # الشطر الحقيقي لطرفي القرصة:
      # القرصة تظل سماكتها الحقيقية عمودية على الميل، لكن نهايتيها
      # يمين/شمال يتم قصهما على مستويين رأسيين X=0 و X=عرض الدولاب.
      #
      # في الإحداثيات المحلية للوح، الوجه السفلي لازم يتحرك عكس اتجاه X
      # بقيمة thickness*tan(angle). بعد تدوير الـInstance، هذا التعويض
      # يلغي الإزاحة الأفقية الناتجة من السمك ويجعل طرفي اللوح رأسيين
      # ومقفولين تمامًا مع الجنبين — نفس الشطر اليدوي في الصورة المرجعية.
      bottom_x_shift = -(thickness * sine / cosine)

      top_points = outline.map { |px,py| Geom::Point3d.new(px, py, 0) }
      bottom_points = outline.map { |px,py| Geom::Point3d.new(px + bottom_x_shift, py, -thickness) }

      top_face = ents.add_face(top_points)
      raise "تعذر رسم الوجه العلوي للقرصة المائلة: #{name}" unless top_face
      top_face.reverse! if top_face.normal.z < 0

      bottom_face = ents.add_face(bottom_points.reverse)
      raise "تعذر رسم الوجه السفلي للقرصة المائلة: #{name}" unless bottom_face
      bottom_face.reverse! if bottom_face.normal.z > 0

      top_points.length.times do |i|
        j = (i + 1) % top_points.length
        side_face = ents.add_face(
          top_points[i], top_points[j],
          bottom_points[j], bottom_points[i]
        )
        raise "تعذر رسم شطر طرف القرصة المائلة: #{name}" unless side_face
      end

      instance = group.to_component
      origin = Geom::Point3d.new(0,0,left_height)
      instance.transform!(Geom::Transformation.axes(origin,x_axis,y_axis,z_axis))
      badges = ['MAIN_CARCASS','SLOPED']
      badges << 'WALL_RELIEF' unless Array(spans).empty?
      finish_generated_part(instance, model, name, material, badges)
      [instance,instance.definition].each do |owner|
        owner.set_attribute('dynamic_attributes','lenx',slope_length.to_f)
        owner.set_attribute('dynamic_attributes','leny',depth.to_f)
        owner.set_attribute('dynamic_attributes','lenz',thickness.to_f)
      end
      # هندسة القرصة مرسومة داخل الـDefinition كلوح تصنيع مستوٍ:
      # X = طول الميل، Y = عمق الدولاب، Z = تخانة اللوح. بعد ذلك فقط
      # نميل الـInstance في الموديل. منع OpenCutList من Auto Orientation
      # ضروري، وإلا يعيد القياس على محاور الموديل ويحسب فرق ارتفاع الميل
      # كعرض للوح (ويظهر Thickness undefined).
      definition = instance.definition
      definition.set_attribute('ladb_opencutlist','orientation_locked_on_axis',true)
      definition.set_attribute('ladb_opencutlist','ignore_grain_direction',false)
      definition.set_attribute('MHD_DRESSING','MANUFACTURING_LENX',slope_length.to_f)
      definition.set_attribute('MHD_DRESSING','MANUFACTURING_LENY',depth.to_f)
      definition.set_attribute('MHD_DRESSING','MANUFACTURING_LENZ',thickness.to_f)
      definition.set_attribute('MHD_DRESSING','SLOPE_INSTANCE_ONLY',true)
      check_board_limit(name, slope_length, depth, thickness, material, badges)
      apply_edge_banding(instance, model, name, material, badges, slope_length, depth, thickness)
      orient_part_textures(instance, name, badges, slope_length, depth, thickness)
      instance
    end

    def slope_enabled?(data)
      %w[yes true 1].include?(data['sloped_enabled'].to_s.downcase)
    end

    def side_extension_for(data)
      return 0 unless data['assembly'].to_s == 'full'
      [data['side_extension'].to_f, 0].max.cm
    end

    def slope_height_at(x, data = nil)
      context = data || @slope_context
      return nil unless context
      total = context['width'].to_f
      return context['left'].to_f if total <= 0
      ratio = [[x.to_f / total, 0.0].max, 1.0].min
      context['left'].to_f + (context['right'].to_f - context['left'].to_f) * ratio
    end

    DC_HIDDEN_KEYS = %w[hidden _hidden_formula _inst__hidden_formula].freeze

    def dynamic_attribute_snapshot(owner)
      dictionary = owner.attribute_dictionary('dynamic_attributes', false)
      DC_HIDDEN_KEYS.each_with_object({}) do |key, result|
        exists = dictionary && dictionary.keys.include?(key)
        result[key] = { 'exists' => !!exists, 'value' => exists ? dictionary[key] : nil }
      end
    end

    def restore_dynamic_attribute_snapshot(owner, snapshot)
      return unless snapshot.is_a?(Hash)
      snapshot.each do |key, state|
        if state.is_a?(Hash) && state['exists']
          owner.set_attribute('dynamic_attributes', key, state['value'])
        else
          owner.delete_attribute('dynamic_attributes', key)
        end
      end
    end

    # hidden=true وحده يضيع بعد Move/Redraw للـDynamic Component.
    # لذلك نحفظ حالة الـDC الأصلية ونفرض TRUE على الـHidden Formula نفسها.
    def force_dynamic_hidden(entity, hidden, marker_key)
      marker = entity.get_attribute('MHD_DRESSING', marker_key, nil)
      legacy_key = marker_key.sub(/_V2\z/, '')
      legacy = entity.get_attribute('MHD_DRESSING', legacy_key, nil)
      if !hidden && marker.nil? && !legacy.nil?
        entity.hidden = legacy.to_s == '1'
        entity.delete_attribute('MHD_DRESSING', legacy_key)
        return
      end
      if hidden
        unless marker
          state = {
            'entity_hidden' => legacy.nil? ? (entity.hidden? ? '1' : '0') : legacy.to_s,
            'instance' => dynamic_attribute_snapshot(entity),
            'definition' => dynamic_attribute_snapshot(entity.definition)
          }
          entity.set_attribute('MHD_DRESSING', marker_key, JSON.generate(state))
          entity.delete_attribute('MHD_DRESSING', legacy_key) unless legacy.nil?
        end
        [entity, entity.definition].each do |owner|
          owner.set_attribute('dynamic_attributes', 'hidden', '1')
          owner.set_attribute('dynamic_attributes', '_hidden_formula', 'TRUE')
          owner.set_attribute('dynamic_attributes', '_inst__hidden_formula', 'TRUE')
        end
        entity.hidden = true
      elsif marker
        state = JSON.parse(marker.to_s) rescue {}
        restore_dynamic_attribute_snapshot(entity, state['instance'])
        restore_dynamic_attribute_snapshot(entity.definition, state['definition'])
        entity.hidden = state['entity_hidden'].to_s == '1'
        entity.delete_attribute('MHD_DRESSING', marker_key)
      end
    end

    def set_original_shell_hidden(root, hidden)
      root.definition.entities.each do |entity|
        next unless entity.is_a?(Sketchup::ComponentInstance) || entity.is_a?(Sketchup::Group)
        next if entity.get_attribute('MHD_DRESSING', 'TYPE') == INTERIOR_MARK
        next if entity.get_attribute('MHD_DRESSING', 'GENERATED_COLUMN_DOOR')
        next if base_hardware_entity?(entity)
        force_dynamic_hidden(entity, hidden, 'SLOPE_ORIGINAL_STATE_V2')
      end
    end

    def base_hardware_entity?(entity)
      return true if entity_function_role(entity) == 'base_hardware'
      names = door_source_identity_names(entity).join(' ')
      normalized = names.to_s.gsub(/\s+/, ' ')
      matched = normalized.include?('رجل بلاستيك') || normalized.match?(/(?:^|\s)وزره\s+BASE_UNIT_1/i)
      set_entity_function_role(entity, 'base_hardware') if matched
      !!matched
    rescue
      false
    end

    def set_base_hardware_hidden(root, hidden)
      root.definition.entities.each do |entity|
        next unless entity.is_a?(Sketchup::ComponentInstance) || entity.is_a?(Sketchup::Group)
        next unless base_hardware_entity?(entity)
        force_dynamic_hidden(entity, hidden, 'WOOD_PLINTH_ORIGINAL_STATE_V2')
      end
    end

    def original_back_entity?(entity)
      return true if entity_function_role(entity) == 'original_back'
      names = door_source_identity_names(entity).join(' ')
      normalized = names.to_s.gsub(/\s+/, ' ')
      matched = (normalized.include?('ضهر') || normalized.match?(/\bback\b/i)) &&
                !normalized.include?('درج') && !normalized.match?(/drawer/i)
      set_entity_function_role(entity, 'original_back') if matched
      !!matched
    rescue
      false
    end

    def set_original_back_hidden(root, hidden)
      root.definition.entities.each do |entity|
        next unless entity.is_a?(Sketchup::ComponentInstance) || entity.is_a?(Sketchup::Group)
        next unless original_back_entity?(entity)
        force_dynamic_hidden(entity, hidden, 'BACK_ORIGINAL_STATE_V2')
      end
    end

    def build_wood_plinth(entities, model, total, depth, thickness, material, data)
      height = [data['wood_plinth_height'].to_f, 1.0].max.cm
      supports = [[data['wood_plinth_supports'].to_i, 0].max, 20].min
      z = -height
      side_extension = side_extension_for(data)
      extended_full_side = side_extension > 0 && data['assembly'].to_s == 'full'
      side_inset = side_extension > 0 ? thickness : 0
      plinth_x = side_inset
      plinth_width = total - side_inset * 2
      rear_inset = [data['wood_plinth_rear_inset'].to_f, 0].max.cm
      effective_depth = depth - rear_inset
      inner_depth = effective_depth - thickness * 2
      raise 'دخول السوكلو من الخلف أكبر من عمق الدولاب.' if effective_depth <= thickness * 2
      raise 'عمق أو عرض الدولاب لا يكفي لتكوين السوكلو الخشب.' if inner_depth <= 0 || plinth_width <= thickness * 2
      # السوكلو يتعامل مع مقاس عمود الحائط الحقيقي في المنطقين، وليس مع
      # عرض الفتحة المقترحة أو عرض التجليدة الموسع بتخانة الكونتر.
      physical_reliefs = Array(@wall_reliefs).filter_map do |relief|
        rx0 = [[relief['x0'].to_f, plinth_x].max, plinth_x+plinth_width].min
        rx1 = [[relief['x1'].to_f, plinth_x].max, plinth_x+plinth_width].min
        intrusion = [[relief['depth'].to_f, 0].max, inner_depth-0.1.cm].min
        next unless rx1-rx0 > 0.1.cm && intrusion > 0
        {'x0'=>rx0, 'x1'=>rx1, 'depth'=>intrusion}
      end.sort_by { |relief| relief['x0'] }
      merged_reliefs = []
      physical_reliefs.each do |relief|
        previous = merged_reliefs[-1]
        if previous && relief['x0'] <= previous['x1']+0.1.cm
          previous['x1'] = [previous['x1'], relief['x1']].max
          previous['depth'] = [previous['depth'], relief['depth']].max
        else
          merged_reliefs << relief.dup
        end
      end
      front_inset = if extended_full_side
                       [data['wood_plinth_front_inset'].to_f, 0].max.cm
                     else
                       0.0
                     end
      max_front_inset = [effective_depth - thickness * 2, 0].max
      front_inset = [front_inset, max_front_inset].min
      front_y = front_inset
      add_box_without_wall_relief(entities, model, "واجهة سوكلو خشب #{PART_SUFFIX}", plinth_x, front_y, z, plinth_width, thickness, height, material, ['WOOD_PLINTH','FRONT'])
      # ضهر السوكلو لا يتخلع كقطعة ذات بواقي: يتقسم فعليًا يمين وشمال
      # كل عمود حائط، حتى يخرج كل جزء كمقاس مستطيل صحيح في الـCutList.
      back_segments = []
      cursor = plinth_x
      merged_reliefs.each do |relief|
        back_segments << [cursor, relief['x0']] if relief['x0']-cursor > 0.1.cm
        cursor = [cursor, relief['x1']].max
      end
      back_segments << [cursor, plinth_x+plinth_width] if plinth_x+plinth_width-cursor > 0.1.cm
      if merged_reliefs.empty?
        back_segments = [[plinth_x, plinth_x+plinth_width]]
      end
      back_segments.each_with_index do |(bx0,bx1),index|
        part_name = back_segments.length > 1 ? "خلف سوكلو خشب جزء #{index+1} #{PART_SUFFIX}" : "خلف سوكلو خشب #{PART_SUFFIX}"
        add_box_without_wall_relief(entities, model, part_name, bx0, effective_depth-thickness, z,
                                    bx1-bx0, thickness, height, material, ['WOOD_PLINTH','BACK','WALL_RELIEF'])
      end
      unless extended_full_side
        left_cut = merged_reliefs.select { |relief| relief['x0'] <= plinth_x+0.1.cm }.map { |relief| relief['depth'] }.max.to_f
        right_edge = plinth_x+plinth_width
        right_cut = merged_reliefs.select { |relief| relief['x1'] >= right_edge-0.1.cm }.map { |relief| relief['depth'] }.max.to_f
        left_depth = inner_depth-left_cut
        right_depth = inner_depth-right_cut
        raise 'خلعة الحائط تستهلك عمق جنب السوكلو.' if left_depth <= 0.1.cm || right_depth <= 0.1.cm
        add_box_without_wall_relief(entities, model, "جنب شمال سوكلو خشب #{PART_SUFFIX}", plinth_x, thickness, z,
                                    thickness, left_depth, height, material, ['WOOD_PLINTH','SIDE','WALL_RELIEF'])
        add_box_without_wall_relief(entities, model, "جنب يمين سوكلو خشب #{PART_SUFFIX}", plinth_x+plinth_width-thickness, thickness, z,
                                    thickness, right_depth, height, material, ['WOOD_PLINTH','SIDE','WALL_RELIEF'])
      end
      support_y = extended_full_side ? front_y + thickness : thickness
      support_depth = extended_full_side ? effective_depth - support_y - thickness : inner_depth
      raise 'عمق الدولاب لا يكفي للدعامات بعد ترحيل وش السوكلو.' if support_depth <= 0
      supports.times do |index|
        center_x = plinth_x + plinth_width * (index + 1).to_f / (supports + 1).to_f
        support_x = [[center_x - thickness / 2.0, plinth_x+thickness].max, plinth_x+plinth_width-thickness*2].min
        support_cut = merged_reliefs.select do |relief|
          relief['x1'] > support_x+0.01.cm && relief['x0'] < support_x+thickness-0.01.cm
        end.map { |relief| relief['depth'] }.max.to_f
        actual_support_depth = support_depth-support_cut
        raise "خلعة الحائط تستهلك عمق دعامة السوكلو رقم #{index+1}." if actual_support_depth <= 0.1.cm
        add_box_without_wall_relief(entities, model, "دعامة سوكلو خشب #{index + 1} #{PART_SUFFIX}",
                                    support_x, support_y, z, thickness, actual_support_depth, height,
                                    material, ['WOOD_PLINTH','SUPPORT','WALL_RELIEF'])
      end
    end

    # جنب كامل مع سوكلو داخل من الخلف:
    # الجزء العلوي يظل بعمق الدولاب كامل، والجزء السفلي فقط (بارتفاع السوكلو)
    # يُخلع من الخلف بقيمة الدخول.
    def add_full_side_with_plinth_rear_notch(parent, model, name, x, y, z, width, depth, height, material, badges, rear_inset, notch_height, side)
      rear_inset = [[rear_inset.to_f, 0].max, depth - 1.cm].min
      notch_height = [[notch_height.to_f, 0].max, height].min
      return add_vertical_panel(parent, model, name, x, y, z, width, depth, height, material, badges, side) if rear_inset <= 0 || notch_height <= 0

      reduced_depth = depth - rear_inset
      raise "دخول السوكلو من الخلف يستهلك عمق الجنب: #{name}" if reduced_depth <= 1.cm

      # قطاع Y/Z: من الأمام كامل، ثم أعلى الجنب كامل العمق،
      # بينما أسفل الجنب ينتهي قبل الخلف بقيمة rear_inset.
      points = [
        [0, 0],
        [reduced_depth, 0],
        [reduced_depth, notch_height],
        [depth, notch_height],
        [depth, height],
        [0, height]
      ]
      add_yz_profile(
        parent, model, name, points,
        x, y, z, width, depth, height, material,
        badges + ['WOOD_PLINTH','REAR_BOTTOM_NOTCH']
      )
    end

    # كورنيشة أمامية مائلة بمحاور تصنيع صحيحة للـOpenCutList.
    # بدل رسم متوازي أضلاع على X/Z فيعتبر الـCutList فرق الارتفاع عرضًا،
    # نرسم اللوح مستطيلاً داخل الـDefinition:
    # X = طول الميل الحقيقي، Y = ارتفاع الكورنيشة، Z = التخانة.
    # ثم نميل الـInstance فقط داخل الموديل.
    def add_sloped_front_cornice(parent, model, name, total, left_height, right_height, cornice_height, thickness, material)
      rise = right_height - left_height
      slope_length = Math.sqrt(total * total + rise * rise)
      raise "طول الكورنيشة المائلة غير صحيح: #{name}" if slope_length <= 0

      group = parent.add_group
      face = group.entities.add_face(
        [0, 0, 0],
        [slope_length, 0, 0],
        [slope_length, cornice_height, 0],
        [0, cornice_height, 0]
      )
      raise "تعذر رسم الكورنيشة المائلة: #{name}" unless face
      face.reverse! if face.normal.z < 0
      face.pushpull(-thickness)

      instance = group.to_component

      cosine = total / slope_length
      sine = rise / slope_length

      # X المحلي على خط الميل.
      x_axis = Geom::Vector3d.new(cosine, 0, sine)
      # مهم: ارتفاع الكورنيشة يظل رأسيًا في الموديل، وليس عموديًا على خط الميل.
      # بذلك نهايتا الكورنيشة يمين/شمال تكونان رأسيتين مثل المرجع،
      # بينما يظل الـDefinition مستطيلاً صحيحًا للـCutList.
      y_axis = Z_AXIS
      # التخانة تدخل داخل الدولاب على Y.
      z_axis = Geom::Vector3d.new(0, -1, 0)

      origin = Geom::Point3d.new(0, 0, left_height)
      instance.transform!(Geom::Transformation.axes(origin, x_axis, y_axis, z_axis))

      badges = ['TOP_CORNICE', 'FRONT', 'SLOPED']
      finish_generated_part(instance, model, name, material, badges)

      [instance, instance.definition].each do |owner|
        owner.set_attribute('dynamic_attributes', 'lenx', slope_length.to_f)
        owner.set_attribute('dynamic_attributes', 'leny', cornice_height.to_f)
        owner.set_attribute('dynamic_attributes', 'lenz', thickness.to_f)
      end

      definition = instance.definition
      definition.set_attribute('ladb_opencutlist', 'orientation_locked_on_axis', true)
      definition.set_attribute('ladb_opencutlist', 'ignore_grain_direction', false)
      definition.set_attribute('MHD_DRESSING', 'MANUFACTURING_LENX', slope_length.to_f)
      definition.set_attribute('MHD_DRESSING', 'MANUFACTURING_LENY', cornice_height.to_f)
      definition.set_attribute('MHD_DRESSING', 'MANUFACTURING_LENZ', thickness.to_f)
      definition.set_attribute('MHD_DRESSING', 'SLOPE_INSTANCE_ONLY', true)

      check_board_limit(name, slope_length, cornice_height, thickness, material, badges)
      apply_edge_banding(
        instance, model, name, material, badges,
        slope_length, cornice_height, thickness
      )
      orient_part_textures(
        instance, name, badges,
        slope_length, cornice_height, thickness
      )
      instance
    end

    def build_top_cornice(entities, model, total, depth, cabinet_height, thickness, material, data)
      type = data['top_cornice_type'].to_s
      return if type.empty? || type == 'none'

      cornice_height = [data['top_cornice_height'].to_f, 1.0].max.cm
      include_left  = %w[front_left front_both].include?(type)
      include_right = %w[front_right front_both].include?(type)
      sloped = slope_enabled?(data)

      if sloped
        # في الوضع المائل: الكورنيشة الأمامية تتبع نفس خط ميل القرصة،
        # مع ارتفاع ثابت رأسيًا فوق الخط بالكامل.
        left_h = data['sloped_left_height'].to_f.cm
        right_h = data['sloped_right_height'].to_f.cm

        front = add_sloped_front_cornice(
          entities, model, "كورنيشة أمام مائلة #{PART_SUFFIX}",
          total, left_h, right_h,
          cornice_height, thickness, material
        )

        side_y = thickness
        side_depth = depth - thickness
        return if side_depth <= 0.1.cm

        # كورنيشة الشمال تبدأ من منسوب الطرف الشمال للميل.
        if include_left
          left = add_box_without_wall_relief(
            entities, model, "كورنيشة شمال مائلة #{PART_SUFFIX}",
            0, side_y, left_h,
            thickness, side_depth, cornice_height,
            material, ['TOP_CORNICE','SIDE','SLOPED']
          )
        end

        # كورنيشة اليمين تبدأ من منسوب الطرف اليمين للميل.
        if include_right
          right = add_box_without_wall_relief(
            entities, model, "كورنيشة يمين مائلة #{PART_SUFFIX}",
            total - thickness, side_y, right_h,
            thickness, side_depth, cornice_height,
            material, ['TOP_CORNICE','SIDE','SLOPED']
          )
          ocl_swap_front_back(right, thickness, side_depth, cornice_height, true) if right
        end
        return
      end

      z = cabinet_height
      add_box_without_wall_relief(
        entities, model, "كورنيشة أمام #{PART_SUFFIX}",
        0, 0, z, total, thickness, cornice_height,
        material, ['TOP_CORNICE','FRONT']
      )

      side_y = thickness
      side_depth = depth - thickness
      return if side_depth <= 0.1.cm

      if include_left
        add_box_without_wall_relief(
          entities, model, "كورنيشة شمال #{PART_SUFFIX}",
          0, side_y, z, thickness, side_depth, cornice_height,
          material, ['TOP_CORNICE','SIDE']
        )
      end

      if include_right
        right = add_box_without_wall_relief(
          entities, model, "كورنيشة يمين #{PART_SUFFIX}",
          total - thickness, side_y, z, thickness, side_depth, cornice_height,
          material, ['TOP_CORNICE','SIDE']
        )
        ocl_swap_front_back(right, thickness, side_depth, cornice_height, true) if right
      end
    end

    def build_straight_grooved_shell(entities, model, total, depth, height, thickness, material, data)
      extension = side_extension_for(data)
      on_base = data['assembly'].to_s == 'on_base' && extension <= 0
      full_top = data['top_type'].to_s == 'full_top'
      side_z = extension > 0 ? -extension : (on_base ? thickness : 0)
      side_height = extension > 0 ? height + extension : (on_base ? height - thickness : height)
      # في القرصة الكاملة تنتهي الأجناب أسفل القرصة بقيمة التخانة، مع
      # الاحتفاظ بنفس منطق القاعدة وتطويل الجنب من أسفل.
      side_height -= thickness if full_top
      raise 'نوع القرصة الكاملة لا يترك ارتفاعًا صالحًا للجنبين.' if side_height <= thickness
      shell_badges = ['MAIN_CARCASS']
      shell_badges << 'BACK_GROOVE' if grooved_mode?
      plinth_rear_inset = data['base_type'].to_s == 'wood_plinth' ? [data['wood_plinth_rear_inset'].to_f, 0].max.cm : 0
      plinth_notch_height = data['base_type'].to_s == 'wood_plinth' ? [data['wood_plinth_height'].to_f, 0].max.cm : 0
      full_side_plinth_notch = data['assembly'].to_s == 'full' && extension > 0 && plinth_rear_inset > 0

      if full_side_plinth_notch
        # الخلعة تخص فقط الجزء الممتد أسفل قاعدة الشاسيه.
        actual_notch_height = [plinth_notch_height, extension].min
        add_full_side_with_plinth_rear_notch(
          entities, model, "جنب شمال شاسيه #{PART_SUFFIX}",
          0, 0, side_z, thickness, depth, side_height, material,
          shell_badges, plinth_rear_inset, actual_notch_height, :right
        )
        right_side = add_full_side_with_plinth_rear_notch(
          entities, model, "جنب يمين شاسيه #{PART_SUFFIX}",
          total-thickness, 0, side_z, thickness, depth, side_height, material,
          shell_badges, plinth_rear_inset, actual_notch_height, :left
        )
      else
        add_vertical_panel(entities, model, "جنب شمال شاسيه #{PART_SUFFIX}", 0, 0, side_z, thickness, depth, side_height, material, shell_badges, :right)
        right_side = add_vertical_panel(entities, model, "جنب يمين شاسيه #{PART_SUFFIX}", total-thickness, 0, side_z, thickness, depth, side_height, material, shell_badges, :left)
      end
      ocl_swap_front_back(right_side, thickness, depth, side_height, true)
      clear_width = total - thickness * 2
      base_x = on_base ? 0 : thickness
      base_width = on_base ? total : clear_width
      add_horizontal_grooved_panel(entities, model, "قاعدة شاسيه #{PART_SUFFIX}", base_x, 0, 0, base_width, depth, thickness, material, shell_badges, :top)
      top_x = full_top ? 0 : thickness
      top_width = full_top ? total : clear_width
      top_panel = add_horizontal_grooved_panel(entities, model, "قرصة علوية شاسيه #{PART_SUFFIX}", top_x, 0, height-thickness, top_width, depth, thickness, material, shell_badges, :bottom)
      ocl_swap_front_back(top_panel, top_width, depth, thickness)
    end

    def build_sloped_shell(entities, model, total, depth, thickness, back_thickness, back_inset, material, back_material, data)
      left_h = data['sloped_left_height'].to_f.cm
      right_h = data['sloped_right_height'].to_f.cm
      extension = side_extension_for(data)
      on_base = data['assembly'].to_s == 'on_base' && extension <= 0
      side_z = extension > 0 ? -extension : (on_base ? thickness : 0)

      # الجنبان يجب أن يُشطرا مع أسفل القرصة المائلة، لا أن يصلا لوجهها العلوي.
      # سمك القرصة يتحرك عموديًا على الميل؛ لذلك الهبوط الرأسي لوجهها السفلي
      # يساوي thickness / cos(angle).
      rise = right_h - left_h
      slope_length = Math.sqrt(total * total + rise * rise)
      cosine = total / slope_length
      underside_drop = thickness / cosine

      left_center_x = thickness / 2.0
      right_center_x = total - thickness / 2.0
      left_target_top = slope_height_at(left_center_x) - underside_drop
      right_target_top = slope_height_at(right_center_x) - underside_drop

      left_side_h = left_target_top - side_z
      right_side_h = right_target_top - side_z
      raise 'الميل لا يترك ارتفاعًا صالحًا للجنبين.' if left_side_h <= thickness || right_side_h <= thickness

      add_vertical_panel(
        entities, model, "جنب شمال مائل #{PART_SUFFIX}",
        0, 0, side_z, thickness, depth, left_side_h,
        material, ['MAIN_CARCASS'], :right
      )
      right_side = add_vertical_panel(
        entities, model, "جنب يمين مائل #{PART_SUFFIX}",
        total - thickness, 0, side_z, thickness, depth, right_side_h,
        material, ['MAIN_CARCASS'], :left
      )
      ocl_swap_front_back(right_side, thickness, depth, right_side_h, true)
      base_x = on_base ? 0 : thickness
      base_width = on_base ? total : total - thickness * 2
      add_horizontal_grooved_panel(entities, model, "قاعدة شاسيه مائل #{PART_SUFFIX}", base_x, 0, 0, base_width, depth, thickness, material, ['MAIN_CARCASS'], :top)
      top_spans = merge_relief_spans(reliefs_for_part(0, 0, total, [left_h,right_h].max, @carcass_reliefs || @wall_reliefs), depth)
      add_sloped_relief_top(entities, model, "قرصة علوية مائلة #{PART_SUFFIX}", total, depth, thickness, material, top_spans)
    end

    def build_column_backs(entities, model, regions, total, depth, height, thickness, back_thickness, back_inset, back_material, data)
      groove = [data['back_groove_depth'].to_f, 0].max.cm
      connected = data['back_joint_mode'].to_s == 'connected_back'
      raise 'سقوط مفحار الضهر لا يمكن أن يكون أكبر من تخانة الشاسيه.' if groove > thickness
      y = depth - back_inset - back_thickness
      raise 'بداية الضهر وتخانته أكبر من عمق الدولاب.' if y < 0
      bottom = thickness - groove
      sloped = slope_enabled?(data)
      regions.each_with_index do |region, index|
        clear_x = region['x'].to_f
        clear_width = region['width'].to_f
        bay_relief = Array(@bay_depth_reliefs).find do |relief|
          relief['proposal'].to_s == 'bay_depth' &&
            (relief['x0'].to_f - clear_x).abs <= 0.15.cm &&
            (relief['x1'].to_f - (clear_x + clear_width)).abs <= 0.15.cm
        end
        # الضهر بالكامل، بما فيه سقوط المفحار يمينًا وشمالًا، يتحرك للأمام
        # مع الفتحة القصيرة؛ لا نترك شريطي المفحار في مستوى الضهر الأصلي.
        back_y = y - (bay_relief ? bay_relief['depth'].to_f : 0)
        left_allowance = index.zero? ? groove : (connected ? thickness / 2.0 : groove)
        right_allowance = index == regions.length - 1 ? groove : (connected ? thickness / 2.0 : groove)
        back_x = [clear_x - left_allowance, 0].max
        back_right = [clear_x + clear_width + right_allowance, total].min
        back_width = back_right - back_x
        raise "عرض ضهر العمود #{index + 1} غير صحيح." if back_width <= 0
        back_segments = [[back_x,back_right]]
        Array(@bay_depth_reliefs).select { |item| item['proposal'].to_s == 'cladded_partition' }.each do |cladding|
          back_segments = back_segments.flat_map do |sx0,sx1|
            cx0, cx1 = cladding['x0'].to_f, cladding['x1'].to_f
            next [[sx0,sx1]] if cx1 <= sx0+0.01.cm || cx0 >= sx1-0.01.cm
            parts = []
            # يدخل الضهر داخل جنب التجليدة بقيمة سقوط المفحار.
            parts << [sx0,[cx0+groove,sx1].min] if cx0+groove-sx0 > 0.1.cm
            parts << [[cx1-groove,sx0].max,sx1] if sx1-(cx1-groove) > 0.1.cm
            parts
          end
        end
        name = "ضهر العمود #{index + 1} #{PART_SUFFIX}"
        if sloped
          back_segments.each_with_index do |(sx0,sx1),segment_index|
            left_top = slope_height_at(sx0)-thickness+groove
            right_top = slope_height_at(sx1)-thickness+groove
            next if [left_top,right_top].max <= bottom
            left_top = [left_top,bottom].max
            right_top = [right_top,bottom].max
            add_xz_prism(entities, model, "#{name} جزء #{segment_index+1}",
                         [[sx0,bottom],[sx1,bottom],[sx1,right_top],[sx0,left_top]],
                         back_y, back_thickness, back_material, ['BACK_PANEL','COLUMN_BACK','SLOPED'])
          end
        else
          back_height = height - thickness * 2 + groove * 2
          back_segments.each_with_index do |(sx0,sx1),segment_index|
            next if sx1-sx0 <= 0.1.cm
            part_name = back_segments.length > 1 ? "#{name} جزء #{segment_index+1}" : name
            add_box_without_wall_relief(entities, model, part_name, sx0, back_y, bottom, sx1-sx0, back_thickness, back_height, back_material, ['BACK_PANEL','COLUMN_BACK'])
          end
        end
      end
    end

    def build_wall_column_claddings(entities, model, total, depth, height, thickness, material)
      claddings = Array(@bay_depth_reliefs).select { |item| item['proposal'].to_s == 'cladded_partition' }
      return if claddings.empty?
      saved_reliefs = @carcass_reliefs
      @carcass_reliefs = []
      begin
        claddings.each_with_index do |item,index|
          x0, x1 = item['x0'].to_f, item['x1'].to_f
          wall_depth = item['wall_depth'].to_f
          side_depth = wall_depth
          side_y = depth-side_depth
          front_y = side_y-thickness
          clear_height = if @slope_context
            [slope_height_at(x0), slope_height_at(x1)].max
          else
            height
          end
          at_left_edge = item['wall_x0'].to_f <= 0.1.cm
          at_right_edge = item['wall_x1'].to_f >= total-0.1.cm
          next if x1-x0 <= thickness*2 || clear_height <= 0 || front_y < 0 || side_depth <= 0
          # وش التجليدة أمام طرفي الجنبين، والجنبان ينتهيان خلفًا عند Y=عمق الشاسيه.
          if @slope_context
            left_top = slope_height_at(x0)
            right_top = slope_height_at(x1)
            add_xz_prism(entities, model, "وش تجليدة عمود حائط #{index+1} #{PART_SUFFIX}",
                         [[x0,0],[x1,0],[x1,right_top],[x0,left_top]],
                         front_y, thickness, material,
                         ['WALL_COLUMN_CLADDING','CLADDING_FRONT','SLOPED'])
          else
            add_box_without_wall_relief(entities, model, "وش تجليدة عمود حائط #{index+1} #{PART_SUFFIX}",
                                        x0, front_y, 0, x1-x0, thickness, clear_height,
                                        material, ['WALL_COLUMN_CLADDING','CLADDING_FRONT'])
          end
          unless at_left_edge
            left_side_height = @slope_context ? [slope_height_at(x0),slope_height_at(x0+thickness)].min : clear_height
            add_vertical_panel(entities, model, "جنب شمال تجليدة عمود حائط #{index+1} #{PART_SUFFIX}",
                               x0, side_y, 0, thickness, side_depth, left_side_height,
                               material, ['WALL_COLUMN_CLADDING','CLADDING_SIDE','BACK_GROOVE'], :left)
          end
          unless at_right_edge
            right_side_height = @slope_context ? [slope_height_at(x1-thickness),slope_height_at(x1)].min : clear_height
            add_vertical_panel(entities, model, "جنب يمين تجليدة عمود حائط #{index+1} #{PART_SUFFIX}",
                               x1-thickness, side_y, 0, thickness, side_depth, right_side_height,
                               material, ['WALL_COLUMN_CLADDING','CLADDING_SIDE','BACK_GROOVE'], :right)
          end
        end
      ensure
        @carcass_reliefs = saved_reliefs
      end
    end

    def partition_depth_for_back(clear_depth, data)
      return clear_depth if data['back_joint_mode'].to_s == 'connected_back'
      clear_depth + data['back_thickness'].to_f.cm + data['back_inset'].to_f.cm
    end

    def full_height_back_partition?(z1, z2)
      span = @full_height_partition_span
      return false unless span.is_a?(Array) && span.length == 2
      (z1.to_f - span[0].to_f).abs <= 0.15.cm &&
        (z2.to_f - span[1].to_f).abs <= 0.15.cm
    end

    def add_drawer_front(parent, model, name, x, y, z, width, depth, height, front_material, back_material)
      instance = add_box(parent, model, name, x, y, z, width, depth, height, front_material, ['DRAWER_FRONT'])
      instance.definition.entities.grep(Sketchup::Face).each do |face|
        next unless face.normal.y > 0.9
        face.material = back_material
        face.back_material = back_material
      end
      instance
    end

    def configure_dynamic_drawer(drawer, clickable_front, closed_y, drawer_depth)
      drawer_dc_name = ensure_persistent_dc_name(drawer, 'MHD_DRAWER')
      closed_cm = closed_y.to_f / 1.cm.to_f
      depth_cm = drawer_depth.to_f / 1.cm.to_f
      y_formula = format('%.6f+u00animdesp', closed_cm)
      [drawer, drawer.definition].each do |owner|
        owner.set_attribute('dynamic_attributes', '_name', drawer_dc_name)
        owner.set_attribute('dynamic_attributes', 'u00animate', '0')
        owner.set_attribute('dynamic_attributes', '_u00animate_label', 'u00animate')
        owner.set_attribute('dynamic_attributes', '_u00animate_units', 'STRING')
        owner.set_attribute('dynamic_attributes', 'u00closedy', (closed_cm / 2.54).to_s)
        owner.set_attribute('dynamic_attributes', '_u00closedy_label', 'u00closedy')
        owner.set_attribute('dynamic_attributes', '_u00closedy_units', 'DEFAULT')
        owner.set_attribute('dynamic_attributes', 'u00animdesp', '0')
        owner.set_attribute('dynamic_attributes', '_u00animdesp_access', 'NONE')
        owner.set_attribute('dynamic_attributes', '_u00animdesp_label', 'u00animdesp')
        owner.set_attribute('dynamic_attributes', '_u00animdesp_formula', format('u00animate*(-%.6f)', depth_cm))
        owner.set_attribute('dynamic_attributes', '_u00animdesp_formulaunits', 'CENTIMETERS')
        owner.set_attribute('dynamic_attributes', 'leny', (depth_cm / 2.54).to_s)
        owner.set_attribute('dynamic_attributes', '_leny_label', 'LenY')
        owner.set_attribute('dynamic_attributes', '_leny_units', 'DEFAULT')
        owner.set_attribute('dynamic_attributes', 'y', (closed_cm / 2.54).to_s)
        owner.set_attribute('dynamic_attributes', '_y_formula', y_formula)
        owner.set_attribute('dynamic_attributes', '_inst__y_formula', y_formula)
        owner.set_attribute('dynamic_attributes', '_y_formulaunits', 'CENTIMETERS')
        owner.set_attribute('dynamic_attributes', '_onclick_state1', 0)
        owner.set_attribute('dynamic_attributes', '_hasbehaviors', 1.0)
        owner.set_attribute('dynamic_attributes', '_has_movetool_behaviors', 1.0)
      end
      [clickable_front, clickable_front.definition].each do |owner|
        owner.set_attribute('dynamic_attributes', '_name', 'Caj.Animate')
        owner.set_attribute('dynamic_attributes', 'onclick', 'ANIMATE("parent!u00animate",0,1)')
        owner.set_attribute('dynamic_attributes', '_onclick_label', 'onClick')
        owner.set_attribute('dynamic_attributes', '_onclick_state1', 0)
        owner.set_attribute('dynamic_attributes', '_hasbehaviors', 1.0)
      end
    end

    def each_configured_layout_door(node, &block)
      return unless node.is_a?(Hash)
      %w[column_door opening_door].each do |key|
        door = node[key]
        block.call(door, key) if door.is_a?(Hash) && door['enabled'].to_s == 'yes'
      end
      children = node['children'].is_a?(Array) ? node['children'] : []
      children.each { |child| each_configured_layout_door(child, &block) }
    end

    def prepare_sliding_context(data, layout_tree, x, inner_width, height, thickness, layout_z, layout_height)
      return nil unless data['door_system'].to_s == 'sliding'
      raise 'الضلفة الجرار تحتاج تقسيمة أعمدة صالحة.' unless layout_tree.is_a?(Hash)
      raise 'لا يمكن تنفيذ الضلفة الجرار على الجزء المائل حاليًا.' if slope_enabled?(data)
      columns = collect_column_regions(layout_tree, x, inner_width, thickness)
      leaf_count = data['sliding_leaf_count'].to_i == 3 ? 3 : 2
      raise "الضلفة الجرار تحتاج #{leaf_count} أعمدة على الأقل." if columns.length < leaf_count
      first = data['sliding_first_column'].to_i
      second = first + leaf_count - 1
      raise "اختر #{leaf_count} أعمدة صحيحة للضلفة الجرار." if first < 0 || second >= columns.length
      left_column = columns[first]
      right_column = columns[second]
      # الجرار يعمل داخل صافي الشاسيه، وليس بمنطق تغطية المفصلة.
      # لذلك مساحة العمودين = صافي الأول + القاطوع الأوسط + صافي الثاني.
      coverage_x = left_column['x'].to_f
      coverage_right = right_column['x'].to_f+right_column['width'].to_f
      coverage_width = coverage_right-coverage_x
      front_setback = [data['sliding_front_setback'].to_f,0].max.cm
      track_gap = [data['sliding_track_gap'].to_f,0].max.cm
      door_depth = 1.8.cm
      raise 'المسافة الأمامية والمسافة بين الضلفتين أكبر من عمق الشاسيه.' if front_setback + door_depth*2 + track_gap > data['depth'].to_f.cm
      vertical_clearance = [data['sliding_vertical_clearance'].to_f,0].max.cm
      target_z = layout_z+vertical_clearance
      target_height = layout_height-vertical_clearance*2
      raise 'خلوص الضلف الجرار أكبر من الارتفاع الصافي.' if target_height <= 1.cm
      {
        'first'=>first, 'second'=>second, 'leaf_count'=>leaf_count,
        'style'=>data['sliding_style'].to_s == 'glass' ? 'glass' : 'wood',
        'columns'=>columns,
        'coverage_x'=>coverage_x, 'coverage_width'=>coverage_width,
        'divider_xs'=>(first...second).map { |index| columns[index]['x'].to_f+columns[index]['width'].to_f },
        'target_z'=>target_z, 'target_height'=>target_height,
        'track_gap'=>track_gap,
        'front_setback'=>front_setback,
        'width_extra'=>[data['sliding_width_extra'].to_f,0].max.cm,
        'front_leaf'=>data['sliding_front_leaf'].to_s == 'right' ? 'right' : 'left',
        'partition_cut'=>[data['sliding_partition_cut'].to_f,0].max.cm
      }
    end

    def validate_sloped_door_rules(data)
      return unless slope_enabled?(data)
      return unless data['door_system'].to_s == 'hinged'
      layout_tree = data['layout_tree']
      return unless layout_tree.is_a?(Hash)
      thickness = data['thickness'].to_f
      clearance = data['door_clearance'].to_f
      total_width = data['width'].to_f
      return if total_width <= thickness * 2
      left_height = data['sloped_left_height'].to_f
      right_height = data['sloped_right_height'].to_f
      cabinet_height = [left_height, right_height].max
      layout_height = cabinet_height - thickness * 2
      if %w[yes true 1].include?(data['fixed_top_shelf'].to_s.downcase)
        clear_top = [data['fixed_top_clear_height'].to_f, 1.0].max
        fixed_shelf_z = cabinet_height - thickness * 2 - clear_top
        layout_height = fixed_shelf_z - thickness
      end
      inner_width = total_width - thickness * 2
      slope_height = lambda do |x|
        ratio = [[x.to_f / total_width, 0.0].max, 1.0].min
        left_height + (right_height - left_height) * ratio
      end
      enters_slope = lambda do |x1, x2, door_top|
        available_top = [slope_height.call(x1), slope_height.call(x2)].min - clearance
        door_top > available_top + 0.01
      end
      has_glass = false
      has_flip_up = false

      columns = collect_column_regions(layout_tree, thickness, inner_width, thickness)
      columns.each_with_index do |column, index|
        door = column['node'].is_a?(Hash) ? column['node']['column_door'] : nil
        next unless door.is_a?(Hash) && door['enabled'].to_s == 'yes'
        drawer_top = overlay_drawer_top(column['node'], thickness, layout_height, thickness)
        base_bottom = drawer_top ? drawer_top + thickness / 2.0 + clearance : clearance
        free_span = opening_door_free_span(column['node'], column['x'], thickness, column['width'], layout_height, thickness, base_bottom, cabinet_height - clearance, clearance)
        next unless free_span
        left_overlay = index.zero? ? thickness : thickness / 2.0
        right_overlay = index == columns.length - 1 ? thickness : thickness / 2.0
        x1 = column['x'] - left_overlay + clearance
        x2 = column['x'] + column['width'] + right_overlay - clearance
        next unless enters_slope.call(x1, x2, free_span[1])
        has_glass ||= door['style'].to_s == 'glass'
      end

      regions = collect_leaf_regions(layout_tree, thickness, thickness, inner_width, layout_height, thickness)
      regions.each do |region|
        region_node = region['node'].is_a?(Hash) ? region['node'] : nil
        # «على وش الضلفة» هو نفسه واجهة الفراغ؛ لذلك لا يجوز تركيب ضلفة فراغ فوقه.
        next if region_node && region_node['type'].to_s == 'drawers' && %w[overlay_front flush_carcass].include?(region_node['drawer_pattern'].to_s)
        door = region_node ? region_node['opening_door'] : nil
        next unless door.is_a?(Hash) && door['enabled'].to_s == 'yes'
        left_overlay = region['left'] == :outer ? thickness : thickness / 2.0
        right_overlay = region['right'] == :outer ? thickness : thickness / 2.0
        top_overlay = region['top'] == :outer ? thickness : thickness / 2.0
        x1 = region['x'] - left_overlay + clearance
        x2 = region['x'] + region['width'] + right_overlay - clearance
        door_top = region['z'] + region['height'] + top_overlay - clearance
        next unless enters_slope.call(x1, x2, door_top)
        has_glass ||= door['style'].to_s == 'glass'
        has_flip_up ||= door['direction'].to_s == 'flip_up'
      end
      return unless has_glass || has_flip_up
      conflicts = []
      conflicts << 'الضلف الزجاج' if has_glass
      conflicts << 'الضلف القلاب' if has_flip_up
      raise "لا يمكن تنفيذ #{conflicts.join(' أو ')} لأنها داخلة في الجزء المائل وتحتاج قصًا مائلًا. انقلها بالكامل أسفل خط الميل أو استخدم ضلفة خشب مفصلية."
    end

    def validate(data)
      height = data['height'].to_f
      depth = data['depth'].to_f
      thickness = data['thickness'].to_f
      back_t = data['back_thickness'].to_f
      back_inset = data['back_inset'].to_f
      back_groove = data['back_groove_depth'].to_f
      data['side_extension'] = 0.0 unless data['assembly'].to_s == 'full'
      side_extension = data['side_extension'].to_f
      front_cut = data['shelf_front_cut'].to_f
      bays = data['bays'].is_a?(Array) ? data['bays'] : []
      raise 'ارتفاع الشاسيه غير صحيح.' unless height > 0
      raise 'عمق الشاسيه غير صحيح.' unless depth > 0
      raise 'تخانة الشاسيه غير صحيحة.' unless thickness > 0
      raise 'تخانة الضهر غير صحيحة.' unless back_t > 0
      raise 'سقوط مفحار الضهر لا يمكن أن يكون سالبًا.' if back_groove < 0
      raise 'سقوط مفحار الضهر لا يمكن أن يكون أكبر من تخانة الشاسيه.' if back_groove > thickness
      raise 'تطويل الجنب لا يمكن أن يكون سالبًا.' if side_extension < 0
      raise 'أضف فتحة واحدة على الأقل.' if bays.empty?
      raise 'عرض إحدى الفتحات غير صحيح.' unless bays.all? { |b| b['width'].to_f > 0 }
      raise 'عدد الأرفف لا يمكن أن يكون سالبًا.' unless bays.all? { |b| b['shelves'].to_i >= 0 }
      raise 'ارتفاع الشاسيه صغير بالنسبة للتخانة.' unless height > thickness * 2
      raise 'عمق الرف أصبح صفرًا أو سالبًا.' unless depth - back_inset - back_t - front_cut > 0
      validate_sloped_door_rules(data)
      true
    end

    def add_shelves(entities, model, bay_x, bay_width, depth, height, thickness, count, front_cut, material, bay_number, z_min = 0, z_max = nil)
      return if count.to_i <= 0
      z_max ||= height
      shelf_depth = depth
      count.to_i.times do |index|
        z = z_min + (z_max - z_min) * (index + 1).to_f / (count.to_i + 1).to_f
        sx, sw = slope_clip_shelf_span(bay_x, bay_width, z + thickness)
        next if sw <= 1.cm
        add_box(entities, model, "رف #{index + 1} فتحة #{bay_number} #{PART_SUFFIX}", sx, front_cut, z, sw, shelf_depth, thickness, material)
      end
    end

    def add_shelves_at_levels(entities, model, bay_x, bay_width, depth, thickness, levels_text, front_cut, material, bay_number, max_height)
      levels = levels_text.to_s.tr('،;', ',,').split(',').map { |v| v.to_f }.select { |v| v > 0 && v < max_height.to_f / 1.cm.to_f }
      levels.each_with_index do |level, index|
        sx, sw = slope_clip_shelf_span(bay_x, bay_width, level.cm + thickness)
        next if sw <= 1.cm
        add_box(entities, model, "رف #{index + 1} فتحة #{bay_number} #{PART_SUFFIX}", sx, front_cut, level.cm, sw, depth, thickness, material)
      end
      !levels.empty?
    end

    def slope_clip_shelf_span(x, width, required_z)
      return [x, width] unless @slope_context
      left_top = slope_height_at(x) - @slope_context['thickness'].to_f
      right_top = slope_height_at(x + width) - @slope_context['thickness'].to_f
      return [x, width] if required_z <= left_top && required_z <= right_top
      delta = @slope_context['right'].to_f - @slope_context['left'].to_f
      return [x, 0] if delta.abs < 0.001
      crossing = (required_z + @slope_context['thickness'].to_f - @slope_context['left'].to_f) * @slope_context['width'].to_f / delta
      if delta > 0
        new_x = [x, crossing].max
        [new_x, [x + width - new_x, 0].max]
      else
        [x, [[crossing - x, width].min, 0].max]
      end
    end

    def add_rod(entities, model, bay_x, bay_width, depth, z, thickness, material, bay_number, rod_number = 1)
      if @slope_context
        local_top = [slope_height_at(bay_x), slope_height_at(bay_x + bay_width)].min - thickness
        return nil if z + thickness > local_top
      end
      target_width = [bay_width, 1.cm].max
      y = [depth * 0.48, 5.cm].max
      definition = cloth_holder_definition(model)
      bounds = definition.bounds
      sizes = [bounds.width, bounds.depth, bounds.height]
      source_axis = sizes.each_with_index.max[1]
      source_length = [sizes[source_axis].to_f, 0.1.mm].max

      # ملف الإكسسوار قد يكون مرسومًا بطوله على X أو Y أو Z. نكتشف المحور
      # الأطول ونوجهه تلقائيًا على عرض الفتحة، ثم نضبط طوله لصافي العرض.
      align = case source_axis
              when 1
                Geom::Transformation.rotation(ORIGIN, Z_AXIS, -Math::PI / 2.0)
              when 2
                Geom::Transformation.rotation(ORIGIN, Y_AXIS, Math::PI / 2.0)
              else
                Geom::Transformation.new
              end
      stretch = Geom::Transformation.scaling(ORIGIN, target_width / source_length, 1.0, 1.0)
      orientation = stretch * align
      oriented = (0..7).map { |index| bounds.corner(index).transform(orientation) }
      min_x,max_x = oriented.map(&:x).minmax
      min_y,max_y = oriented.map(&:y).minmax
      min_z,max_z = oriented.map(&:z).minmax
      place = Geom::Transformation.translation([
        bay_x - min_x,
        y - (min_y + max_y) / 2.0,
        z - (min_z + max_z) / 2.0
      ])
      instance = entities.add_instance(definition, place * orientation)
      instance.name = ''
      instance.set_attribute('MHD_DRESSING', 'JOINERY_ACCESSORY', true)
      instance.set_attribute('MHD_DRESSING', 'TYPE', 'CLOTH_HOLDER')
      instance.set_attribute('MHD_DRESSING', 'ROD_BAY', bay_number.to_s)
      instance.set_attribute('MHD_DRESSING', 'ROD_NUMBER', rod_number.to_i)
      instance
    end

    def flatten_accessory_entities(entities)
      20.times do
        nested = entities.grep(Sketchup::ComponentInstance) + entities.grep(Sketchup::Group)
        break if nested.empty?
        changed = false
        nested.each do |item|
          next unless item.valid?
          begin
            item.explode
            changed = true
          rescue
          end
        end
        break unless changed
      end
    end

    # Definition وسيط للمجرى اليمين فقط. نوجّه المحور الأطول في الملف
    # الأصلي إلى Y مرة واحدة داخل التعريف، ثم تصبح أبعاده: سمك X وطول Y.
    def right_drawer_slide_aligned_definition(model)
      cached = @right_drawer_slide_aligned_definitions && @right_drawer_slide_aligned_definitions[model.object_id]
      return cached if cached && cached.valid?

      source = drawer_slide_right_definition(model)
      bounds = source.bounds
      sizes = [bounds.width, bounds.depth, bounds.height]
      source_axis = sizes.each_with_index.max[1]
      align = case source_axis
              when 0
                Geom::Transformation.rotation(ORIGIN, Z_AXIS, Math::PI / 2.0)
              when 2
                Geom::Transformation.rotation(ORIGIN, X_AXIS, -Math::PI / 2.0)
              else
                Geom::Transformation.new
              end
      internal_name = '__MHD_DRAWER_SLIDE_RIGHT_ALIGNED_Y_V4_BAKED'
      definition = model.definitions[internal_name] || model.definitions.add(internal_name)
      if definition.entities.length == 0
        # Explode واحد فقط يخبز اتجاه المصدر على Y ويمنع الـDynamic
        # Component الأصلي من إعادة المجرى للوضع الرأسي. لا نفك المكونات
        # الداخلية للمجرى حتى لا تتكرر أجزاؤه أو تظهر نسخة إضافية.
        placed_source = definition.entities.add_instance(source, align)
        placed_source.explode
        aligned_bounds = definition.bounds
        normalize = Geom::Transformation.translation([
          -aligned_bounds.min.x,
          -aligned_bounds.min.y,
          -aligned_bounds.min.z
        ])
        definition.entities.transform_entities(normalize, definition.entities.to_a)
      end
      clean_name = 'مجرى درج جانبي يمين'
      claim_clean_definition_name(definition, clean_name)
      definition.set_attribute('MHD_DRESSING', 'SOURCE_DEFINITION_NAME', clean_name)
      set_part_badges(definition, ['HARDWARE','ACCESSORY','DRAWER_SLIDE_RIGHT'])
      definition.set_attribute('ladb_opencutlist', 'cumulable', 2)
      @right_drawer_slide_aligned_definitions ||= {}
      @right_drawer_slide_aligned_definitions[model.object_id] = definition
      definition
    end

    # الإكسسوار عنصر مستقل بجوار الدرج، وليس Child داخل B.Cajon.
    # مقاسه المغلق يطابق خشبة المجرى القديمة: X=الخلوص، Y=عمق الدرج، Z=4 سم.
    def add_right_drawer_slide(entities, model, x, y, z, width_x, closed_length_y, drawer_number, column_number)
      # الملف Dynamic Component جاهز ومحاوره مضبوطة: X سمك، Y عمق، Z ارتفاع.
      # ندرجه كما هو؛ ممنوع Scale أو Rotation أو Wrapper أو Explode.
      definition = drawer_slide_right_definition(model)
      pair_name = qualified_part_name('طقم مجرى درج جانبي')
      definition.set_attribute('dynamic_attributes', '_name', pair_name)
      definition.set_attribute('dynamic_attributes', 'name', pair_name)
      definition.set_attribute('ladb_opencutlist', 'uuid', 'MHD-DRAWER-SLIDE-SIDE-PAIR')
      definition.set_attribute('ladb_opencutlist', 'instance_count_by_part', 2)
      definition.set_attribute('ladb_opencutlist', 'cumulable', 2)
      definition.set_attribute('ladb_opencutlist', 'symmetrical', true)
      set_part_badges(definition, ['HARDWARE','ACCESSORY','DRAWER_SLIDE_PAIR'])
      instance = entities.add_instance(definition, Geom::Transformation.translation([x, y, z]))
      instance.name = ''
      instance.set_attribute('dynamic_attributes', '_name', pair_name)
      instance.set_attribute('dynamic_attributes', 'name', pair_name)
      instance.set_attribute('MHD_DRESSING', 'JOINERY_ACCESSORY', true)
      instance.set_attribute('MHD_DRESSING', 'TYPE', 'DRAWER_SLIDE_RIGHT')
      instance.set_attribute('MHD_DRESSING', 'DRAWER_NUMBER', drawer_number.to_i)
      instance.set_attribute('MHD_DRESSING', 'COLUMN_NUMBER', column_number.to_i)
      # معادلات رقمية بسيطة على الـInstance فقط لتغلب مقاسات المصدر، من
      # غير لمس Definition ومن غير أي مراجع أسماء قد تسبب parse errors.
      set_door_dc_value(instance, 'lenx', width_x.to_f / 1.cm.to_f)
      set_door_dc_value(instance, 'leny', closed_length_y.to_f / 1.cm.to_f)
      set_door_dc_value(instance, 'lenz', 4.0)
      redraw_dc_live(instance)
      wanted_origin = Geom::Point3d.new(x, y, z)
      correction = wanted_origin - instance.transformation.origin
      instance.transformation = Geom::Transformation.translation(correction.to_a) * instance.transformation
      instance
    end

    # نفس منطق المجرى اليمين حرفيًا، لكن باستخدام ملف الشمال الجاهز فقط.
    # الملف معمول له Flip مسبقًا؛ لذلك لا نضيف Rotation أو Mirror هنا.
    def add_left_drawer_slide(entities, model, x, y, z, width_x, closed_length_y, drawer_number, column_number)
      definition = drawer_slide_left_definition(model)
      pair_name = qualified_part_name('طقم مجرى درج جانبي')
      definition.set_attribute('dynamic_attributes', '_name', pair_name)
      definition.set_attribute('dynamic_attributes', 'name', pair_name)
      definition.set_attribute('ladb_opencutlist', 'uuid', 'MHD-DRAWER-SLIDE-SIDE-PAIR')
      definition.set_attribute('ladb_opencutlist', 'instance_count_by_part', 2)
      definition.set_attribute('ladb_opencutlist', 'cumulable', 2)
      definition.set_attribute('ladb_opencutlist', 'symmetrical', true)
      set_part_badges(definition, ['HARDWARE','ACCESSORY','DRAWER_SLIDE_PAIR'])
      instance = entities.add_instance(definition, Geom::Transformation.translation([x, y, z]))
      instance.name = ''
      instance.set_attribute('dynamic_attributes', '_name', pair_name)
      instance.set_attribute('dynamic_attributes', 'name', pair_name)
      instance.set_attribute('MHD_DRESSING', 'JOINERY_ACCESSORY', true)
      instance.set_attribute('MHD_DRESSING', 'TYPE', 'DRAWER_SLIDE_LEFT')
      instance.set_attribute('MHD_DRESSING', 'DRAWER_NUMBER', drawer_number.to_i)
      instance.set_attribute('MHD_DRESSING', 'COLUMN_NUMBER', column_number.to_i)
      set_door_dc_value(instance, 'lenx', width_x.to_f / 1.cm.to_f)
      set_door_dc_value(instance, 'leny', closed_length_y.to_f / 1.cm.to_f)
      set_door_dc_value(instance, 'lenz', 4.0)
      redraw_dc_live(instance)
      wanted_origin = Geom::Point3d.new(x, y, z)
      correction = wanted_origin - instance.transformation.origin
      instance.transformation = Geom::Transformation.translation(correction.to_a) * instance.transformation
      instance
    end

    # ============================================================
    # استرجاع روابط حركة الإكسسوارات بعد حفظ/إغلاق/فتح ملف SketchUp
    #
    # EntityObserver والـHashes الموجودة في Ruby RAM لا يتم حفظها داخل SKP.
    # لذلك نخزن Link ID وبيانات وضع الغلق كـAttributes داخل العناصر نفسها،
    # ثم نعيد تركيب الـObservers تلقائيًا عند فتح الموديل.
    # ============================================================
    def new_motion_link_id(prefix, entity = nil)
      pid = entity && entity.respond_to?(:persistent_id) ? entity.persistent_id : 0
      "#{prefix}-#{pid}-#{(Time.now.to_f * 1000).to_i}-#{rand(1_000_000)}"
    end

    def motion_json_read(entity, key, fallback = nil)
      raw = entity.get_attribute('MHD_DRESSING', key, nil)
      return fallback if raw.nil? || raw.to_s.empty?
      JSON.parse(raw.to_s)
    rescue
      fallback
    end

    def motion_json_write(entity, key, value)
      entity.set_attribute('MHD_DRESSING', key, JSON.generate(value))
    rescue
      nil
    end

    def motion_entities_in(entities, result = [])
      entities.each do |entity|
        next unless entity && entity.valid?
        if entity.is_a?(Sketchup::ComponentInstance) || entity.is_a?(Sketchup::Group)
          result << entity
          # Groups لها Entities خاصة بها وغير موجودة كـDefinition مستقلة.
          motion_entities_in(entity.entities, result) if entity.is_a?(Sketchup::Group)
        end
      end
      result
    end

    # Migration للملفات التي اتعملت قبل إضافة Motion Link IDs.
    # نربط العناصر القديمة داخل نفس Definition بالقطعة الأقرب هندسيًا،
    # وبعدها نخزن Metadata دائمة حتى لا نحتاج التخمين مرة أخرى.
    def migrate_legacy_motion_links_in_definition(definition)
      entities = motion_entities_in(definition.entities, [])
      doors = entities.select do |e|
        e.is_a?(Sketchup::ComponentInstance) &&
          e.get_attribute('MHD_DRESSING', 'GENERATED_COLUMN_DOOR')
      end

      # ---------- المفصلات + دراع الباكم ----------
      motion_accessories = entities.select do |e|
        type = e.get_attribute('MHD_DRESSING', 'TYPE').to_s
        %w[HINGE_ACCESSORY PUSH_UP_LIFT].include?(type) &&
          e.get_attribute('MHD_DRESSING', 'MOTION_LINK_ID').to_s.empty?
      end

      motion_accessories.each do |accessory|
        type = accessory.get_attribute('MHD_DRESSING', 'TYPE').to_s
        wanted_direction = accessory.get_attribute('MHD_DRESSING', 'HINGE_DIRECTION').to_s
        candidates = doors.select do |door|
          dir = door.get_attribute('MHD_DRESSING', 'HINGE_DIRECTION').to_s
          if type == 'PUSH_UP_LIFT'
            dir == 'flip_up'
          elsif wanted_direction.empty?
            true
          else
            dir == wanted_direction
          end
        end
        next if candidates.empty?

        ao = accessory.transformation.origin
        door = candidates.min_by do |candidate|
          co = candidate.transformation.origin
          (co.x - ao.x).abs + (co.y - ao.y).abs + (co.z - ao.z).abs
        end
        next unless door

        link_id = door.get_attribute('MHD_DRESSING', 'MOTION_LINK_ID').to_s
        if link_id.empty?
          link_id = new_motion_link_id('HINGE', door)
          door.set_attribute('MHD_DRESSING', 'MOTION_LINK_ID', link_id)
          xaxis = door.transformation.xaxis
          zaxis = door.transformation.zaxis
          xaxis.normalize! if xaxis.length > 0.0001
          zaxis.normalize! if zaxis.length > 0.0001
          motion_json_write(door, 'MOTION_CLOSED_XAXIS', [xaxis.x, xaxis.y, xaxis.z])
          motion_json_write(door, 'MOTION_CLOSED_ZAXIS', [zaxis.x, zaxis.y, zaxis.z])
        end

        accessory.set_attribute('MHD_DRESSING', 'MOTION_LINK_ID', link_id)
        accessory.set_attribute('MHD_DRESSING', 'MOTION_KIND', 'HINGE_ACCESSORY')
        shift_cm = type == 'PUSH_UP_LIFT' ? 13.0 : 6.1
        accessory.set_attribute('MHD_DRESSING', 'MOTION_OPEN_Y_SHIFT_CM', shift_cm)
        motion_json_write(accessory, 'MOTION_CLOSED_TRANSFORM', accessory.transformation.to_a)
      end

      # ---------- مجاري الأدراج ----------
      drawers = entities.select do |e|
        e.is_a?(Sketchup::ComponentInstance) &&
          e.get_attribute('MHD_DRESSING', 'TYPE').to_s == 'B.Cajon'
      end
      slides = entities.select do |e|
        type = e.get_attribute('MHD_DRESSING', 'TYPE').to_s
        %w[DRAWER_SLIDE_PAIR DRAWER_SLIDE_RIGHT DRAWER_SLIDE_LEFT].include?(type) &&
          e.get_attribute('MHD_DRESSING', 'MOTION_LINK_ID').to_s.empty?
      end

      slides.each do |slide|
        next if drawers.empty?
        so = slide.transformation.origin
        drawer = drawers.min_by do |candidate|
          co = candidate.transformation.origin
          # Z أهم عامل لتحديد الدرج الصحيح، ثم X/Y.
          (co.z - so.z).abs * 5.0 + (co.x - so.x).abs + (co.y - so.y).abs
        end
        next unless drawer

        link_id = drawer.get_attribute('MHD_DRESSING', 'DRAWER_MOTION_LINK_ID').to_s
        if link_id.empty?
          link_id = new_motion_link_id('DRAWER', drawer)
          drawer.set_attribute('MHD_DRESSING', 'DRAWER_MOTION_LINK_ID', link_id)
          motion_json_write(drawer, 'DRAWER_CLOSED_TRANSFORM', drawer.transformation.to_a)
        end

        slide.set_attribute('MHD_DRESSING', 'MOTION_LINK_ID', link_id)
        slide.set_attribute('MHD_DRESSING', 'MOTION_KIND', 'DRAWER_SLIDE')

        closed_cm = begin
          value = slide.get_attribute('dynamic_attributes', 'leny').to_f
          value > 0 ? value * 2.54 : 0.0
        rescue
          0.0
        end
        closed_cm = 40.0 if closed_cm <= 0
        slide.set_attribute('MHD_DRESSING', 'SLIDE_CLOSED_DEPTH_CM', closed_cm)
        motion_json_write(slide, 'SLIDE_CLOSED_PAIR_ORIGIN', slide.transformation.origin.to_a)
      end
    rescue
      nil
    end

    def restore_motion_links(model = Sketchup.active_model)
      return unless model

      @hinge_motion_links ||= {}
      @hinge_motion_observers ||= {}
      @drawer_slide_links ||= {}
      @drawer_slide_observers ||= {}

      # نظف أي Runtime Links تخص موديل قديم أو Entities لم تعد صالحة.
      @hinge_motion_links.delete_if do |_key, link|
        door = link && link[:door]
        !(door && door.valid? && door.model == model)
      end
      @drawer_slide_links.delete_if do |_key, link|
        drawer = link && link[:drawer]
        !(drawer && drawer.valid? && drawer.model == model)
      end

      model.definitions.each do |definition|
        next unless definition && definition.valid?
        migrate_legacy_motion_links_in_definition(definition)

        entities = motion_entities_in(definition.entities, [])

        # ---------- Restore hinges / push-up lifts ----------
        doors_by_link = {}
        entities.each do |entity|
          next unless entity.is_a?(Sketchup::ComponentInstance)
          link_id = entity.get_attribute('MHD_DRESSING', 'MOTION_LINK_ID').to_s
          next if link_id.empty?
          next unless entity.get_attribute('MHD_DRESSING', 'GENERATED_COLUMN_DOOR')
          doors_by_link[link_id] = entity
        end

        accessories_by_link = Hash.new { |h, k| h[k] = [] }
        entities.each do |entity|
          link_id = entity.get_attribute('MHD_DRESSING', 'MOTION_LINK_ID').to_s
          next if link_id.empty?
          next unless entity.get_attribute('MHD_DRESSING', 'MOTION_KIND').to_s == 'HINGE_ACCESSORY'
          accessories_by_link[link_id] << entity
        end

        doors_by_link.each do |link_id, door|
          accessories = accessories_by_link[link_id]
          next if accessories.empty?

          xaxis = motion_json_read(door, 'MOTION_CLOSED_XAXIS', nil)
          zaxis = motion_json_read(door, 'MOTION_CLOSED_ZAXIS', nil)
          unless xaxis.is_a?(Array) && xaxis.length == 3
            axis = door.transformation.xaxis
            axis.normalize! if axis.length > 0.0001
            xaxis = [axis.x, axis.y, axis.z]
            motion_json_write(door, 'MOTION_CLOSED_XAXIS', xaxis)
          end
          unless zaxis.is_a?(Array) && zaxis.length == 3
            axis = door.transformation.zaxis
            axis.normalize! if axis.length > 0.0001
            zaxis = [axis.x, axis.y, axis.z]
            motion_json_write(door, 'MOTION_CLOSED_ZAXIS', zaxis)
          end

          link = @hinge_motion_links[door.object_id]
          unless link
            observer = HingeDoorMotionObserver.new
            door.add_observer(observer)
            @hinge_motion_observers[door.object_id] = observer
            link = {
              door: door,
              closed_xaxis: xaxis,
              closed_zaxis: zaxis,
              accessories: []
            }
            @hinge_motion_links[door.object_id] = link
          end

          existing_ids = Array(link[:accessories]).map { |r| r[:instance]&.object_id }.compact
          accessories.each do |accessory|
            next if existing_ids.include?(accessory.object_id)
            closed_transform = motion_json_read(accessory, 'MOTION_CLOSED_TRANSFORM', accessory.transformation.to_a)
            shift_cm = accessory.get_attribute('MHD_DRESSING', 'MOTION_OPEN_Y_SHIFT_CM').to_f
            shift_cm = 6.1 if shift_cm <= 0
            link[:accessories] << {
              instance: accessory,
              closed_transform: closed_transform,
              open_y_shift: shift_cm.cm.to_f
            }
          end

          ensure_hinge_motion_monitor if door.get_attribute('MHD_DRESSING', 'HINGE_DIRECTION').to_s == 'flip_up'
          # أجبر أول Sync بعد الاسترجاع حتى لو الملف محفوظ والضلفة مفتوحة.
          link.delete(:last_open_state)
          sync_hinge_accessories(door)
        end

        # ---------- Restore drawer slides ----------
        drawers_by_link = {}
        entities.each do |entity|
          next unless entity.is_a?(Sketchup::ComponentInstance)
          link_id = entity.get_attribute('MHD_DRESSING', 'DRAWER_MOTION_LINK_ID').to_s
          next if link_id.empty?
          drawers_by_link[link_id] = entity
        end

        entities.each do |slide|
          next unless slide.get_attribute('MHD_DRESSING', 'MOTION_KIND').to_s == 'DRAWER_SLIDE'
          link_id = slide.get_attribute('MHD_DRESSING', 'MOTION_LINK_ID').to_s
          next if link_id.empty?
          drawer = drawers_by_link[link_id]
          next unless drawer && drawer.valid?
          next if @drawer_slide_links.key?(drawer.object_id)

          observer = DrawerSlideMotionObserver.new
          drawer.add_observer(observer)
          @drawer_slide_observers[drawer.object_id] = observer

          closed_drawer_transform = motion_json_read(
            drawer, 'DRAWER_CLOSED_TRANSFORM', drawer.transformation.to_a
          )
          closed_pair_origin = motion_json_read(
            slide, 'SLIDE_CLOSED_PAIR_ORIGIN', slide.transformation.origin.to_a
          )
          closed_depth_cm = slide.get_attribute('MHD_DRESSING', 'SLIDE_CLOSED_DEPTH_CM').to_f
          closed_depth_cm = 40.0 if closed_depth_cm <= 0

          @drawer_slide_links[drawer.object_id] = {
            drawer: drawer,
            slide_pair: slide,
            right_side: nil,
            closed_drawer_transform: closed_drawer_transform,
            closed_pair_origin: closed_pair_origin,
            drawer_depth: closed_depth_cm.cm.to_f,
            chassis_depth: closed_depth_cm.cm.to_f,
            current_length: closed_depth_cm.cm.to_f
          }
          sync_drawer_slide(drawer)
        end
      end
      true
    rescue => error
      puts "MHD motion restore error: #{error.message}" rescue nil
      false
    end

    class DressingMotionAppObserver < Sketchup::AppObserver
      def onOpenModel(model)
        UI.start_timer(0.8, false) do
          MHDESIGN::DressingDesigner.restore_motion_links(model)
        end
      rescue
        nil
      end

      def onNewModel(model)
        UI.start_timer(0.8, false) do
          MHDESIGN::DressingDesigner.restore_motion_links(model)
        end
      rescue
        nil
      end
    end

    def sync_drawer_slide(drawer)
      return if @syncing_drawer_slide
      link = @drawer_slide_links && @drawer_slide_links[drawer.object_id]
      return unless link && drawer.valid?

      pair = link[:slide_pair]
      return unless pair && pair.valid?

      @syncing_drawer_slide = true
      closed_drawer = Geom::Transformation.new(link[:closed_drawer_transform])
      delta = drawer.transformation.origin - closed_drawer.origin

      # الدرج يفتح على -Y. المجرى يبدأ دائمًا من مقدمة الدرج الحالية،
      # وطوله = عمق شاسيه الدرج + مسافة الفتح الفعلية.
      opening_distance = delta.y.abs
      closed_depth = [link[:chassis_depth].to_f, 0.1.mm].max
      current_length = closed_depth + opening_distance
      ratio = current_length / closed_depth

      base_origin = Geom::Point3d.new(link[:closed_pair_origin])
      current_origin = Geom::Point3d.new(
        base_origin.x,
        base_origin.y + delta.y,
        base_origin.z
      )

      # لأن هندسة الطقم مطبّعة من Y=0 إلى +Y، تحريك الأصل مع الدرج ثم
      # تكبير Y يجعل نهاية المجرى الخلفية ثابتة عند ظهر شاسيه الدرج.
      scale = Geom::Transformation.scaling(ORIGIN, 1.0, ratio, 1.0)
      place = Geom::Transformation.translation(current_origin.to_a)
      pair.transformation = place * scale

      current_cm = current_length.to_f / 1.cm.to_f
      pair.set_attribute('dynamic_attributes', 'leny', (current_cm / 2.54).to_s)
      pair.set_attribute('dynamic_attributes', '_leny_label', 'LenY')
      pair.set_attribute('dynamic_attributes', '_leny_units', 'DEFAULT')
      link[:current_length] = current_length
    ensure
      @syncing_drawer_slide = false
    end

    def register_drawer_slide_motion(drawer, slide_pair, right_side, drawer_depth, chassis_depth)
      # الحركة الأساسية محفوظة داخل الـDynamic Component نفسه.
      configure_persistent_drawer_slide_dc(drawer, slide_pair, chassis_depth)

      # Observer يظل Fallback فقط أثناء الجلسة الحالية.
      @drawer_slide_links ||= {}

      link_id = drawer.get_attribute('MHD_DRESSING', 'DRAWER_MOTION_LINK_ID').to_s
      if link_id.empty?
        link_id = new_motion_link_id('DRAWER', drawer)
        drawer.set_attribute('MHD_DRESSING', 'DRAWER_MOTION_LINK_ID', link_id)
      end

      closed_drawer_transform = drawer.transformation.to_a
      closed_pair_origin = slide_pair.transformation.origin.to_a
      closed_depth = [chassis_depth.to_f, 0.1.mm].max

      motion_json_write(drawer, 'DRAWER_CLOSED_TRANSFORM', closed_drawer_transform)
      slide_pair.set_attribute('MHD_DRESSING', 'MOTION_LINK_ID', link_id)
      slide_pair.set_attribute('MHD_DRESSING', 'MOTION_KIND', 'DRAWER_SLIDE')
      slide_pair.set_attribute('MHD_DRESSING', 'SLIDE_CLOSED_DEPTH_CM', closed_depth / 1.cm.to_f)
      motion_json_write(slide_pair, 'SLIDE_CLOSED_PAIR_ORIGIN', closed_pair_origin)

      observer = DrawerSlideMotionObserver.new
      drawer.add_observer(observer)
      @drawer_slide_observers ||= {}
      @drawer_slide_observers[drawer.object_id] = observer

      @drawer_slide_links[drawer.object_id] = {
        drawer: drawer,
        slide_pair: slide_pair,
        right_side: right_side,
        closed_drawer_transform: closed_drawer_transform,
        closed_pair_origin: closed_pair_origin,
        drawer_depth: drawer_depth.to_f,
        chassis_depth: closed_depth,
        current_length: closed_depth
      }
      slide_pair
    end

    # يبني Definition واحدًا يحتوي المجرى اليمين والمجرى الشمال المعكوس.
    # نُحوّل الموديلين إلى هندسة داخل نفس التعريف حتى يقرأ CutList الطقم
    # Instance واحدًا لكل درج، لا قطعتين منفصلتين.
    def drawer_slide_pair_definition(model, clear_width, runner_clearance, runner_depth)
      cache_key = [model.object_id,
                   (clear_width.to_f / 0.1.mm).round,
                   (runner_clearance.to_f / 0.1.mm).round,
                   (runner_depth.to_f / 0.1.mm).round,
                   'RIGHT_NATIVE_X_NEGATIVE_Y_V4']
      cached = @drawer_slide_pair_definitions && @drawer_slide_pair_definitions[cache_key]
      return cached if cached && cached.valid?

      source = drawer_slide_right_definition(model)
      bounds = source.bounds
      sizes = [bounds.width, bounds.depth, bounds.height]
      source_axis = sizes.each_with_index.max[1]
      source_length = [sizes[source_axis].to_f, 0.1.mm].max
      align = case source_axis
              when 0
                Geom::Transformation.rotation(ORIGIN, Z_AXIS, Math::PI / 2.0)
              when 2
                Geom::Transformation.rotation(ORIGIN, X_AXIS, -Math::PI / 2.0)
              else
                Geom::Transformation.new
              end
      stretch = Geom::Transformation.scaling(ORIGIN, 1.0, runner_depth.to_f / source_length, 1.0)
      right_orientation = stretch * align
      right_points = (0..7).map { |index| bounds.corner(index).transform(right_orientation) }
      right_center_x = (right_points.map(&:x).min + right_points.map(&:x).max) / 2.0
      right_min_y = right_points.map(&:y).min
      right_center_z = (right_points.map(&:z).min + right_points.map(&:z).max) / 2.0
      target_right_x = clear_width - runner_clearance / 2.0
      right_place = Geom::Transformation.translation([
        target_right_x - right_center_x, -right_min_y, -right_center_z
      ])

      mirror = Geom::Transformation.scaling(ORIGIN, -1.0, 1.0, 1.0)
      left_orientation = mirror * right_orientation
      left_points = (0..7).map { |index| bounds.corner(index).transform(left_orientation) }
      left_center_x = (left_points.map(&:x).min + left_points.map(&:x).max) / 2.0
      left_min_y = left_points.map(&:y).min
      left_center_z = (left_points.map(&:z).min + left_points.map(&:z).max) / 2.0
      target_left_x = runner_clearance / 2.0
      left_place = Geom::Transformation.translation([
        target_left_x - left_center_x, -left_min_y, -left_center_z
      ])

      length_cm = (runner_depth.to_f / 1.cm.to_f).round(1)
      internal_name = "__MHD_DRAWER_SLIDE_PAIR_RIGHT_NATIVE_X_NEGY_V4_#{cache_key[1]}_#{cache_key[2]}_#{cache_key[3]}"
      pair = model.definitions[internal_name] || model.definitions.add(internal_name)
      pair.entities.add_instance(source, right_place * right_orientation)
      pair.entities.add_instance(source, left_place * left_orientation)
      flatten_accessory_entities(pair.entities)
      # المجرى اليمين يحتفظ باتجاه X الأصلي المطابق لاتجاه X لجنب
      # شاسيه الدرج اليمين. المجرى الشمال وحده تم عمل Mirror X له أعلاه.
      # هنا نقلب Y فقط حتى يبدأ الطول من المقدمة Y=0 ويمتد للخلف إلى -Y.
      length_to_negative_y = Geom::Transformation.scaling(ORIGIN, 1.0, -1.0, 1.0)
      pair.entities.transform_entities(length_to_negative_y, pair.entities.to_a)
      pair_bounds = pair.bounds
      normalize = Geom::Transformation.translation([
        -pair_bounds.min.x,
        -pair_bounds.max.y,
        -(pair_bounds.min.z + pair_bounds.max.z) / 2.0
      ])
      pair.entities.transform_entities(normalize, pair.entities.to_a)
      clean_name = "طقم مجرى درج جانبي #{length_cm} سم"
      claim_clean_definition_name(pair, clean_name)
      pair.set_attribute('MHD_DRESSING', 'SOURCE_DEFINITION_NAME', clean_name)
      pair.set_attribute('MHD_DRESSING', 'TYPE', 'DRAWER_SLIDE_PAIR')
      set_part_badges(pair, ['HARDWARE','ACCESSORY','DRAWER_SLIDE_PAIR'])
      pair.set_attribute('ladb_opencutlist', 'cumulable', 2)
      pair.set_attribute('ladb_opencutlist', 'instance_count_by_part', 1)
      @drawer_slide_pair_definitions ||= {}
      @drawer_slide_pair_definitions[cache_key] = pair
      pair
    end

    # مجاري الأدراج الجديدة:
    # كل مجرى يظل Component مستقل داخل مجموعة/Component الدرج نفسه، لذلك:
    # - يتحرك مع الدرج تلقائيًا من غير Observer أو Stretch أثناء الفتح.
    # - لا يندمج هندسيًا مع جنب الشاسيه، وبالتالي لا يزيد سمك الجنب في CutList.
    # - اليمين يلامس الوجه الخارجي لجنب الشاسيه اليمين، والشمال يلامس الوجه
    #   الخارجي لجنب الشاسيه الشمال.
    # - مركز ارتفاع المجرى يساوي مركز ارتفاع جنب شاسيه الدرج.
    # - LenY يثبت مرة واحدة على عمق شاسيه الدرج ولا يتغير بعد ذلك.
    def add_drawer_slide_outside_chassis(entities, model, side, outer_face_x, front_y, center_z, chassis_depth, drawer_number, column_number)
      side = side.to_s == 'left' ? 'left' : 'right'
      definition = side == 'right' ? drawer_slide_right_definition(model) : drawer_slide_left_definition(model)

      pair_name = qualified_part_name('طقم مجرى درج جانبي')
      definition.set_attribute('dynamic_attributes', '_name', pair_name)
      definition.set_attribute('dynamic_attributes', 'name', pair_name)
      definition.set_attribute('ladb_opencutlist', 'uuid', 'MHD-DRAWER-SLIDE-SIDE-PAIR')
      definition.set_attribute('ladb_opencutlist', 'instance_count_by_part', 2)
      definition.set_attribute('ladb_opencutlist', 'cumulable', 2)
      definition.set_attribute('ladb_opencutlist', 'symmetrical', true)
      set_part_badges(definition, ['HARDWARE','ACCESSORY','DRAWER_SLIDE_PAIR'])

      instance = entities.add_instance(definition, Geom::Transformation.new)
      instance.name = ''
      instance.set_attribute('dynamic_attributes', '_name', pair_name)
      instance.set_attribute('dynamic_attributes', 'name', pair_name)
      instance.set_attribute('MHD_DRESSING', 'JOINERY_ACCESSORY', true)
      instance.set_attribute('MHD_DRESSING', 'TYPE', side == 'right' ? 'DRAWER_SLIDE_RIGHT' : 'DRAWER_SLIDE_LEFT')
      instance.set_attribute('MHD_DRESSING', 'DRAWER_NUMBER', drawer_number.to_i)
      instance.set_attribute('MHD_DRESSING', 'COLUMN_NUMBER', column_number.to_i)
      instance.set_attribute('MHD_DRESSING', 'SLIDE_FIXED_WITH_DRAWER', true)

      # لا نغير سمك المجرى ولا ارتفاعه. فقط عمقه يساوي عمق شاسيه الدرج.
      set_door_dc_value(instance, 'leny', chassis_depth.to_f / 1.cm.to_f)
      redraw_dc_live(instance)

      # نعتمد على Bounds الفعلية بعد الـRedraw بدل افتراض Origin أو محاور ملف SKP.
      # هذا يجعل تعديل ملف المجرى داخليًا (وجود Group مثلًا) آمنًا طالما اتجاه
      # اليمين/الشمال نفسه صحيح في الملفين الجاهزين.
      bounds = instance.bounds
      # خارج الشاسيه: اليمين يمتد ناحية +X لذلك نلصق min.x بوجه الجنب الخارجي،
      # والشمال يمتد ناحية -X لذلك نلصق max.x بوجه الجنب الخارجي.
      touch_x = side == 'right' ? bounds.min.x : bounds.max.x
      slide_center_z = (bounds.min.z + bounds.max.z) / 2.0
      dx = outer_face_x.to_f - touch_x.to_f
      dy = front_y.to_f - bounds.min.y.to_f
      dz = center_z.to_f - slide_center_z.to_f
      instance.transform!(Geom::Transformation.translation([dx, dy, dz]))

      # لا Motion Link ولا Dynamic Formula للحركة: لأنه Child داخل الدرج،
      # فالفتح/الغلق يحركه طبيعيًا مع B.Cajon ويحافظ على عمقه ثابتًا.
      instance.delete_attribute('MHD_DRESSING', 'MOTION_LINK_ID') rescue nil
      instance.delete_attribute('MHD_DRESSING', 'MOTION_KIND') rescue nil
      instance.delete_attribute('MHD_DRESSING', 'SLIDE_CLOSED_PAIR_ORIGIN') rescue nil
      instance.delete_attribute('MHD_DRESSING', 'SLIDE_CLOSED_DEPTH_CM') rescue nil
      instance
    end

    # يرسم لوحًا في مستوى X/Z ثم يسحبه على Y.
    # نستخدمه لجنب صندوق الدرج حتى يكون مفحار القاعدة هندسة حقيقية.
    def add_xz_profile(parent, model, name, points_xz, x, y, z, width, depth, height, material, badges = [])
      name = qualified_part_name(human_part_name(name, x, width))
      check_board_limit(name, width, depth, height, material, badges)
      group = parent.add_group
      points = points_xz.map { |px, pz| [px, 0, pz] }
      face = group.entities.add_face(points)
      raise "تعذر رسم قطاع مفحار قاعدة الدرج: #{name}" unless face
      face.reverse! if face.normal.y < 0
      face.pushpull(depth)
      group.entities.grep(Sketchup::Face).each do |f|
        f.material = material
        f.back_material = material
      end
      instance = group.to_component
      instance.transform!(Geom::Transformation.translation([x, y, z]))
      finish_generated_part(instance, model, name, material, badges)
      [instance, instance.definition].each do |owner|
        owner.set_attribute('dynamic_attributes', 'lenx', width.to_f)
        owner.set_attribute('dynamic_attributes', 'leny', depth.to_f)
        owner.set_attribute('dynamic_attributes', 'lenz', height.to_f)
      end
      apply_edge_banding(instance, model, name, material, badges, width, depth, height)
      orient_part_textures(instance, name, badges, width, depth, height)
      instance
    end

    def add_drawer_side_with_bottom_groove(parent, model, name, x, y, z, width, depth, height, material, badges, groove_depth, groove_z, groove_height, inner_side)
      groove_depth = [[groove_depth.to_f, 0].max, width - 0.05.cm].min
      groove_z0 = [[groove_z.to_f, 0].max, height].min
      groove_z1 = [[groove_z0 + groove_height.to_f, groove_z0].max, height].min
      return add_box(parent, model, name, x, y, z, width, depth, height, material, badges) if groove_depth <= 0 || groove_z1-groove_z0 <= 0.01.cm

      points = if inner_side == :max_x
        [[0,0],[width,0],[width,groove_z0],[width-groove_depth,groove_z0],
         [width-groove_depth,groove_z1],[width,groove_z1],[width,height],[0,height]]
      else
        [[0,0],[width,0],[width,height],[0,height],[0,groove_z1],
         [groove_depth,groove_z1],[groove_depth,groove_z0],[0,groove_z0]]
      end
      instance = add_xz_profile(
        parent, model, name, points, x, y, z, width, depth, height,
        material, badges + ['DRAWER_BOTTOM_GROOVE']
      )
      instance.definition.set_attribute('MHD_DRESSING', 'DRAWER_BOTTOM_GROOVE_DEPTH_CM', groove_depth.to_f / 1.cm.to_f)
      instance.definition.set_attribute('MHD_DRESSING', 'DRAWER_BOTTOM_GROOVE_Z_CM', groove_z0.to_f / 1.cm.to_f)

      # نفس منطق أجناب الشاسيه الرئيسي:
      # - جنب شمال الدرج: المفحار على الوجه الداخلي +X => هو الوجه الأمامي
      #   في OpenCutList افتراضيًا، فلا نعمل Swap.
      # - جنب يمين الدرج: المفحار على الوجه الداخلي -X => نعمل Swap
      #   Front/Back حتى يظهر المفحار على وجه القطعة في الـCutList.
      if inner_side == :min_x
        ocl_swap_front_back(instance, width, depth, height, true)
      end
      instance.definition.set_attribute('MHD_DRESSING', 'OCL_DRAWER_BOTTOM_GROOVE_AXES', true)
      instance.definition.set_attribute('MHD_DRESSING', 'OCL_GROOVE_FACE', inner_side.to_s)
      instance
    end

    def add_drawer_cross_with_bottom_groove(parent, model, name, x, y, z, width, depth, height, material, badges, groove_depth, groove_z, groove_height, inner_side)
      groove_depth = [[groove_depth.to_f, 0].max, depth - 0.05.cm].min
      groove_z0 = [[groove_z.to_f, 0].max, height].min
      groove_z1 = [[groove_z0 + groove_height.to_f, groove_z0].max, height].min
      return add_box(parent, model, name, x, y, z, width, depth, height, material, badges) if groove_depth <= 0 || groove_z1-groove_z0 <= 0.01.cm

      points = if inner_side == :max_y
        [[0,0],[depth,0],[depth,groove_z0],[depth-groove_depth,groove_z0],
         [depth-groove_depth,groove_z1],[depth,groove_z1],[depth,height],[0,height]]
      else
        [[0,0],[depth,0],[depth,height],[0,height],[0,groove_z1],
         [groove_depth,groove_z1],[groove_depth,groove_z0],[0,groove_z0]]
      end
      instance = add_yz_profile(
        parent, model, name, points, x, y, z, width, depth, height,
        material, badges + ['DRAWER_BOTTOM_GROOVE']
      )
      instance.definition.set_attribute('MHD_DRESSING', 'DRAWER_BOTTOM_GROOVE_DEPTH_CM', groove_depth.to_f / 1.cm.to_f)
      instance.definition.set_attribute('MHD_DRESSING', 'DRAWER_BOTTOM_GROOVE_Z_CM', groove_z0.to_f / 1.cm.to_f)

      # نفس منطق القاعدة/القرصة في الشاسيه الرئيسي:
      # - وش شاسيه الدرج: المفحار على الوجه الداخلي +Y => بدون Swap.
      # - ضهر شاسيه الدرج: المفحار على الوجه الداخلي -Y => Swap Front/Back.
      # الهدف أن OpenCutList يعرض دائمًا الوجه الذي عليه المفحار.
      if inner_side == :min_y
        ocl_swap_front_back(instance, width, depth, height, false)
      end
      instance.definition.set_attribute('MHD_DRESSING', 'OCL_DRAWER_BOTTOM_GROOVE_AXES', true)
      instance.definition.set_attribute('MHD_DRESSING', 'OCL_GROOVE_FACE', inner_side.to_s)
      instance
    end

    # يرسم صندوق خام داخل Group بدون إنشاء Component مستقل.
    # يُستخدم لتكوين قطعة واحدة ذات خلعات متداخلة.
    def add_raw_box_geometry(entities, x, y, z, width, depth, height, material)
      return if width <= 0 || depth <= 0 || height <= 0
      face = entities.add_face(
        [x, y, z],
        [x + width, y, z],
        [x + width, y + depth, z],
        [x, y + depth, z]
      )
      return unless face
      face.reverse! if face.normal.z < 0
      face.pushpull(height)
      entities.grep(Sketchup::Face).each do |f|
        f.material = material
        f.back_material = material
      end
    end

    # يرجع القطاعات بين الخلعات على محور واحد.
    def organizer_segments(start_pos, finish_pos, centers, slot_width)
      cursor = start_pos
      result = []
      half = slot_width / 2.0
      centers.each do |center|
        a = [center - half, start_pos].max
        b = [center + half, finish_pos].min
        result << [cursor, a] if a - cursor > 0.05.cm
        cursor = [cursor, b].max
      end
      result << [cursor, finish_pos] if finish_pos - cursor > 0.05.cm
      result
    end

    # قطعة تقسيم واحدة بخلوص نصف ارتفاع:
    # axis=:y => قطعة طولية، خلعاتها من أعلى.
    # axis=:x => قطعة عرضية، خلعاتها من أسفل.
    def add_drawer_organizer_divider(parent, model, name, axis, fixed_pos,
                                     start_pos, finish_pos, z0, thickness,
                                     divider_height, crossing_centers, material)
      return nil if finish_pos - start_pos <= 1.cm || divider_height <= 1.cm
      slot_width = thickness + 0.1.cm
      half_h = divider_height / 2.0

      group = parent.add_group
      ge = group.entities

      if axis == :y
        # النصف السفلي مستمر، والنصف العلوي متقطع عند نقاط التقاطع.
        add_raw_box_geometry(
          ge, fixed_pos - thickness / 2.0, start_pos, z0,
          thickness, finish_pos - start_pos, half_h, material
        )
        organizer_segments(start_pos, finish_pos, crossing_centers, slot_width).each do |a, b|
          add_raw_box_geometry(
            ge, fixed_pos - thickness / 2.0, a, z0 + half_h,
            thickness, b - a, divider_height - half_h, material
          )
        end
      else
        # العكس للقطعة العرضية: النصف العلوي مستمر، والسفلي متقطع.
        add_raw_box_geometry(
          ge, start_pos, fixed_pos - thickness / 2.0, z0 + half_h,
          finish_pos - start_pos, thickness, divider_height - half_h, material
        )
        organizer_segments(start_pos, finish_pos, crossing_centers, slot_width).each do |a, b|
          add_raw_box_geometry(
            ge, a, fixed_pos - thickness / 2.0, z0,
            b - a, thickness, half_h, material
          )
        end
      end

      instance = group.to_component
      badges = ['DRAWER_ORGANIZER','JOINERY_PART']
      finish_generated_part(instance, model, name, material, badges)

      # التكتشر لكل التقسيمات Rotated 90° بحيث اتجاه العروق يبقى بالعرض.
      orient_definition_textures_rotated_90(instance.definition)

      # شريط داير دائمًا على التقسيمات كلها.
      part_width = axis == :y ? thickness : (finish_pos - start_pos)
      part_depth = axis == :y ? (finish_pos - start_pos) : thickness
      apply_edge_banding(
        instance, model, name, material, badges,
        part_width, part_depth, divider_height
      )

      instance.set_attribute('MHD_DRESSING', 'DRAWER_ORGANIZER_AXIS', axis.to_s)
      instance.set_attribute('MHD_DRESSING', 'DRAWER_ORGANIZER_NOTCH', 'half_lap')
      instance.set_attribute('MHD_DRESSING', 'TEXTURE_ROTATION', 90)
      instance
    end

    # شبكة تقسيمات داخل درج بعينه.
    # العدد المختار يطبق على الاتجاهين، فتتكون شبكة متداخلة.
    def add_drawer_organizer(parent, model, drawer_number, column_number,
                             inner_x0, inner_x1, inner_y0, inner_y1,
                             z0, divider_height, divider_thickness,
                             division_count, material)
      count = [[division_count.to_i, 1].max, 8].min
      return if inner_x1 - inner_x0 <= divider_thickness * 3
      return if inner_y1 - inner_y0 <= divider_thickness * 3
      return if divider_height <= 1.cm

      xs = count.times.map { |i| inner_x0 + (inner_x1 - inner_x0) * (i + 1).to_f / (count + 1).to_f }
      ys = count.times.map { |i| inner_y0 + (inner_y1 - inner_y0) * (i + 1).to_f / (count + 1).to_f }

      xs.each_with_index do |x, i|
        add_drawer_organizer_divider(
          parent, model,
          "تقسيم طولي درج #{drawer_number} عمود #{column_number} - #{i + 1}",
          :y, x, inner_y0, inner_y1, z0,
          divider_thickness, divider_height, ys, material
        )
      end

      ys.each_with_index do |y, i|
        add_drawer_organizer_divider(
          parent, model,
          "تقسيم عرضي درج #{drawer_number} عمود #{column_number} - #{i + 1}",
          :x, y, inner_x0, inner_x1, z0,
          divider_thickness, divider_height, xs, material
        )
      end
    end

    # ============================================================
    # Drawer Template Cache
    # ============================================================
    # الأدراج المتطابقة هندسيًا داخل نفس الـstack لا تحتاج إعادة بناء كل
    # وجه/مفحار/إليتا من الصفر. نبني أول شكل مرة واحدة، ثم ننسخ الـDefinition
    # ونفصل فقط تعريفات قطع التصنيع داخل النسخة لكي تحتفظ أسماء كل درج برقمه.
    # الإكسسوارات تظل Definitions مشتركة ولا تدخل في سمك خشب الجنب بالـCutList.
    def drawer_template_signature(values)
      Array(values).map do |value|
        if value.is_a?(Float)
          (value / 0.01.mm).round
        else
          value.to_s
        end
      end.join('|')
    end

    def drawer_hardware_instance?(instance)
      return false unless instance && instance.valid? && instance.respond_to?(:definition)
      badges = instance.definition.get_attribute('MHD_DRESSING', 'INTERNAL_BADGES', []) rescue []
      badges = Array(badges).map(&:to_s)
      type = instance.get_attribute('MHD_DRESSING', 'TYPE', '').to_s rescue ''
      badges.include?('HARDWARE') || badges.include?('ACCESSORY') ||
        type.start_with?('DRAWER_SLIDE') || type == 'ELITA_MINIFIX'
    rescue
      false
    end

    def rename_cloned_drawer_tree!(entities, model, old_number, new_number, old_column_number, column_number, drawer_label, column_label)
      front_piece = nil
      entities.grep(Sketchup::ComponentInstance).each do |instance|
        next unless instance.valid?

        # كل الإكسسوارات تظل مستقلة ومشتركة؛ نحدث فقط Metadata رقم الدرج.
        if drawer_hardware_instance?(instance)
          instance.set_attribute('MHD_DRESSING', 'DRAWER_NUMBER', new_number.to_i) rescue nil
          next
        end

        begin
          instance.make_unique
        rescue
        end

        definition = instance.definition
        badges = Array((definition.get_attribute('MHD_DRESSING', 'INTERNAL_BADGES', []) rescue [])).map(&:to_s)
        front_piece ||= instance if badges.include?('DRAWER_FRONT')

        old_token = " #{old_number} #{column_label} #{old_column_number}"
        new_token = " #{new_number} #{column_label} #{column_number}"

        current_definition_name = definition.name.to_s
        current_instance_name = instance.name.to_s
        renamed_definition = current_definition_name.gsub(old_token, new_token)
        renamed_instance = current_instance_name.gsub(old_token, new_token)

        if renamed_definition != current_definition_name
          definition.name = unique_name(model, renamed_definition)
          definition.set_attribute('MHD_DRESSING', 'SOURCE_DEFINITION_NAME', definition.name.to_s) rescue nil
        end
        instance.name = renamed_instance if renamed_instance != current_instance_name
        instance.set_attribute('MHD_DRESSING', 'DRAWER_NUMBER', new_number.to_i) rescue nil

        nested_front = rename_cloned_drawer_tree!(
          definition.entities, model, old_number, new_number, old_column_number, column_number,
          drawer_label, column_label
        )
        front_piece ||= nested_front
      end
      front_piece
    rescue => error
      puts "MHD drawer template rename error: #{error.message}" rescue nil
      front_piece
    end

    def clone_drawer_template(entities, model, template, base_z, target_x, number, column_number, drawer_label, column_label)
      source = template[:drawer]
      return nil unless source && source.valid?

      clone = entities.add_instance(source.definition, source.transformation)
      clone.make_unique
      x_delta = target_x.to_f - source.transformation.origin.x.to_f
      z_delta = base_z.to_f - template[:base_z].to_f
      if x_delta.abs > 0.00001 || z_delta.abs > 0.00001
        clone.transform!(Geom::Transformation.translation([x_delta, 0, z_delta]))
      end

      front_piece = rename_cloned_drawer_tree!(
        clone.definition.entities, model,
        template[:number].to_i, number.to_i, template[:column_number].to_i, column_number.to_i,
        drawer_label, column_label
      )

      clone.name = qualified_part_name("#{drawer_label} #{number} #{column_label} #{column_number}")
      clone.definition.name = unique_name(model, clone.name)
      clone.set_attribute('MHD_DRESSING', 'TYPE', 'B.Cajon')
      clone.set_attribute('MHD_DRESSING', 'DRAWER_TEMPLATE_CLONE', true)
      clone.set_attribute('MHD_DRESSING', 'DRAWER_NUMBER', number.to_i)
      [clone, front_piece]
    rescue => error
      puts "MHD drawer template clone error: #{error.message}" rescue nil
      nil
    end

    def add_drawer_stack(entities, model, bay_x, bay_width, depth, thickness, count, stack_height, carcass, back_material, front_material, bay_number, config = {})
      count = [[count.to_i, 1].max, 6].min
      # Defaults and construction are taken from the inspected B.Cajon component:
      # 3 mm front gap, 13 mm telescopic runner each side, 18 mm box,
      # 3 mm grooved bottom and an automatic runner depth in 5 cm steps.
      clearance = (config['front_clearance'].to_f > 0 ? config['front_clearance'].to_f : 0.3).cm
      runner_clearance = (config['runner_clearance'].to_f > 0 ? config['runner_clearance'].to_f : 1.3).cm
      front_thickness = (config['front_thickness'].to_f > 0 ? config['front_thickness'].to_f : 1.8).cm
      # Drawer chassis is part of the carcass construction and must always use
      # the selected carcass/counter thickness. Ignore legacy per-drawer values
      # (some saved layouts contain 2.0 cm) so every chassis stays consistent.
      box_thickness = thickness
      bottom_thickness = (config['bottom_thickness'].to_f > 0 ? config['bottom_thickness'].to_f : 0.6).cm
      # بداية حفر/تركيب قاعدة الدرج محسوبة من أسفل شاسيه الدرج الداخلي نفسه.
      # مثال: 1.5 سم = نترك 1.5 سم من أسفل الجنب/الوش/الضهر ثم يبدأ مفحار القاعدة.
      bottom_drop = (config['bottom_drop'].to_f > 0 ? config['bottom_drop'].to_f : 1.8).cm
      bottom_groove_depth = (config['bottom_groove_depth'].to_f > 0 ? config['bottom_groove_depth'].to_f : 0.6).cm
      drawer_pattern = config['drawer_pattern'].to_s
      overlay_front = drawer_pattern == 'overlay_front'
      flush_carcass = drawer_pattern == 'flush_carcass'
      overlay_like = overlay_front || flush_carcass

      # حماية إضافية على مستوى الإنشاء نفسه: لو شاسيه الأدراج واقع داخل نطاق
      # الجرار، نأخذ قص الجرار مباشرة من السياق بدل الاعتماد فقط على القيمة
      # القادمة من شجرة التقسيم. هذا يضمن رجوع شاسيه «جنب سميك» بالكامل
      # حتى داخل التقسيمات المتداخلة. و«على وش الضلفة» يتحول لسميك مع الجرار.
      sliding_drawer_cut = 0.0
      if @sliding_context
        sliding_left = @sliding_context['coverage_x'].to_f
        sliding_right = sliding_left + @sliding_context['coverage_width'].to_f
        drawer_left = bay_x.to_f
        drawer_right = drawer_left + bay_width.to_f
        if drawer_right > sliding_left + 0.1.cm && drawer_left < sliding_right - 0.1.cm
          sliding_drawer_cut = @sliding_context['partition_cut'].to_f
          if overlay_like
            overlay_front = false
            flush_carcass = false
            overlay_like = false
          end
        end
      end

      configured_front_cut = [config['drawer_front_cut'].to_f, 0].max.cm
      front_cut = overlay_like ? configured_front_cut : [configured_front_cut, sliding_drawer_cut].max
      # قرصة شاسيه الأدراج تتبع قص الأرفف والقواطيع، وبالجرار يجب أن ترجع
      # بنفس قيمة القص أيضًا.
      top_front_cut = [[config['_top_front_cut'].to_f, 0].max.cm, sliding_drawer_cut].max
      touches_base = config['_touches_base'] == true || %w[yes true 1].include?(config['_touches_base'].to_s.downcase)
      top_front_shared = config['_top_front_shared'] == true || %w[yes true 1].include?(config['_top_front_shared'].to_s.downcase)

      # مشاركة وش «مساوي للشاسيه» مع القواطيع/الأرفف:
      # لا تحدث إلا إذا كان قص اللوح من الأمام = تخانة وش الدرج.
      share_tolerance = 0.05.cm
      partition_cut_for_face = config['_partition_front_cut_cm'].to_f.cm
      shelf_cut_for_face = config['_shelf_front_cut_cm'].to_f.cm
      left_is_cut  = config['_left_cut'] == true || %w[yes true 1].include?(config['_left_cut'].to_s.downcase)
      right_is_cut = config['_right_cut'] == true || %w[yes true 1].include?(config['_right_cut'].to_s.downcase)
      partition_cut_matches = (partition_cut_for_face.to_f - front_thickness.to_f).abs <= share_tolerance
      shelf_cut_matches = (shelf_cut_for_face.to_f - front_thickness.to_f).abs <= share_tolerance

      flush_share_left = flush_carcass &&
                         config['_left_boundary'].to_s == 'partition' &&
                         left_is_cut && partition_cut_matches
      flush_share_right = flush_carcass &&
                          config['_right_boundary'].to_s == 'partition' &&
                          right_is_cut && partition_cut_matches
      flush_share_bottom = flush_carcass &&
                           config['_bottom_boundary'].to_s == 'shelf' &&
                           shelf_cut_matches
      flush_share_top = flush_carcass &&
                        config['_top_boundary'].to_s == 'shelf' &&
                        shelf_cut_matches

      left_overlay = [config['_left_overlay'].to_f, 0].max.cm
      right_overlay = [config['_right_overlay'].to_f, 0].max.cm
      chassis_height_setting = config['chassis_height'].to_f.cm
      front_gap = clearance
      side_front_margin = 0.2.cm
      top_front_margin = -0.2.cm
      bottom_front_margin = -0.2.cm
      front_height = (stack_height - front_gap * (count - 1) + top_front_margin + bottom_front_margin) / count.to_f
      back_inset = config['_back_inset'].to_f.cm
      back_thickness = config['_back_thickness'].to_f.cm

      # ============================================================
      # Wall relief for drawer chassis (bay-level, once only)
      # ============================================================
      # لو فتحة الأدراج تقابل عمود حائط، يرجع شاسيه الأدراج كله كوحدة واحدة:
      # - true_notch : بروز العمود + تخانة التجليدة (القيمة الموسعة الجاهزة).
      # - depth_avoid: نفس رجوع الفتحة المستخدم للأرفف والقواطيع.
      # القرصة لا تدخل في هذا الخصم؛ هي تُرسم لاحقًا بمنطق الرف نفسه لكي
      # تأخذ خلعة حقيقية أو رجوعًا مستطيلاً حسب نوع المعالجة.
      drawer_wall_depth_reduction = 0.0
      Array(@bay_depth_reliefs).each do |relief|
        next unless relief.is_a?(Hash)
        rx0 = relief['x0'].to_f
        rx1 = relief['x1'].to_f
        next unless rx1 > bay_x + 0.1.cm && rx0 < bay_x + bay_width - 0.1.cm
        reduction = if relief['proposal'].to_s == 'cladded_partition'
                      # expand_reliefs_to_bays خزّن هنا P + T بالفعل.
                      relief['depth'].to_f
                    elsif relief['proposal'].to_s == 'bay_depth'
                      # نفس قيمة رجوع الرف في وضع تفادي العمود.
                      relief['depth'].to_f
                    else
                      0.0
                    end
        drawer_wall_depth_reduction = [drawer_wall_depth_reduction, reduction].max
      end

      chassis_depth_limit = depth - back_inset - back_thickness - front_cut - drawer_wall_depth_reduction
      raise 'دخول الضهر وتخانته أكبر من عمق وحدة الأدراج.' if chassis_depth_limit <= thickness * 3
      inner_drawer_depth = chassis_depth_limit - thickness
      requested_runner = config['runner_length'].to_f
      auto_runner_cm = [[(inner_drawer_depth.to_f / 1.cm.to_f / 5.0).floor * 5.0, 25.0].max, 60.0].min
      # طول صندوق الدرج/المجرى لا يجوز أن يتخطى العمق المتاح بعد خلعة الحائط.
      # لو العميل مختار طولًا ثابتًا أكبر من المتاح، نقلله تلقائيًا لأكبر طول مناسب.
      runner_cm = requested_runner > 0 ? [requested_runner, auto_runner_cm].min : auto_runner_cm
      box_depth = runner_cm.cm
      # «مساوي للشاسيه»: وش الدرج أصبح داخل الفتحة وعلى مستوى وش الشاسيه،
      # لذلك الشاسيه الداخلي نفسه يبدأ خلف الوش. نحافظ على نهايته الخلفية
      # في مكانها: نقلل العمق بمقدار تخانة الوش ثم نرجعه للخلف بنفس المقدار.
      box_depth = [box_depth - front_thickness, 5.cm].max if flush_carcass
      # Exact EstructuraCajon layout from the supplied report:
      # root 964 -> inner CTA 844 = 60 mm structure zone on each side;
      # root depth 561 -> inner CTA depth 543 = one board thickness setback;
      # root height 891 -> inner CTA height 873 = one top-board thickness.
      side_zone = 6.cm
      side_zone = [(bay_width - 20.cm) / 2.0, side_zone].min
      chassis_x = bay_x
      custom_base_z = config['_base_z'].to_f
      chassis_z = custom_base_z > 0 ? custom_base_z.cm : thickness
      chassis_height = stack_height
      chassis_depth = chassis_depth_limit

      # المجرى نفسه لا يصل حتى نهاية شاسيه الأدراج الخلفية.
      # نخصم منه دخول الضهر + تخانة الضهر حتى لا يبرز خلف الضهر.
      # مثال: دخول 2.0 سم + ضهر 0.6 سم => خصم 2.6 سم من LenY.
      slide_back_deduction = back_inset + back_thickness
      slide_closed_depth = [chassis_depth - slide_back_deduction, 5.cm].max

      clear_x = overlay_like ? 0 : side_zone
      clear_width = overlay_like ? bay_width : bay_width - side_zone * 2
      raise 'عرض الفتحة لا يكفي شاسيه الأدراج.' if clear_width <= thickness * 2

      unless overlay_like
        side_depth = chassis_depth - thickness * 2
        top_x_cm = (config['_top_x'] || 0).to_f
        top_width_cm = (config['_top_width'] || 0).to_f
        top_x = top_width_cm > 0 ? top_x_cm.cm : chassis_x
        top_width = top_width_cm > 0 ? top_width_cm.cm : bay_width
        # القرصة تتبع قص الأرفف والقواطيع: تبدأ من top_front_cut،
        # ويظل حدها الخلفي ثابتًا عند نفس خط الضهر بغض النظر عن drawer_front_cut.
        chassis_top_depth = depth - back_inset - back_thickness - top_front_cut
        raise 'قص الأرفف والقواطيع أكبر من عمق قرصة شاسيه الأدراج.' if chassis_top_depth <= thickness
        chassis_top = add_box(entities, model, "قرصة شاسيه الأدراج فتحة #{bay_number}", top_x, top_front_cut, chassis_z + chassis_height, top_width, chassis_top_depth, thickness, carcass, ['DRAWER_CHASSIS'])
        # OpenCutList: الإليتا في قرصة شاسيه الأدراج تُحفر من الوجه السفلي،
        # لذلك نجعل هذا الوجه هو Front الصناعي حتى تظهر فتحات المسمار/الكامة
        # في بطاقة الـCutList بدل أن تكون مخفية على Back. التحويل يحافظ على
        # مكان القطعة الحقيقي في الموديل ولا يغيّر هندسة التجميع.
        ocl_swap_front_back(chassis_top, top_width, chassis_top_depth, thickness)
        chassis_top.set_attribute('MHD_DRESSING', 'DRAWER_TOP_LEFT_BOUNDARY', config['_left_boundary'].to_s)
        chassis_top.set_attribute('MHD_DRESSING', 'DRAWER_TOP_RIGHT_BOUNDARY', config['_right_boundary'].to_s)
        chassis_top.set_attribute('MHD_DRESSING', 'DRAWER_TOP_BAY_X0', chassis_x.to_f / 1.cm.to_f)
        chassis_top.set_attribute('MHD_DRESSING', 'DRAWER_TOP_BAY_X1', (chassis_x + bay_width).to_f / 1.cm.to_f)
        extension_side = if top_x < chassis_x - 0.1.cm
                           'left'
                         elsif top_x + top_width > chassis_x + bay_width + 0.1.cm
                           'right'
                         else
                           ''
                         end
        chassis_top.set_attribute('MHD_DRESSING', 'DRAWER_TOP_EXTENSION_SIDE', extension_side)
        # Type-5 side construction from the source report (b11=60 mm): the
        # 18 mm full-depth sides occupy 42..60 mm from each outer edge. The
        # 60 mm front/rear ties remain on the outside and wrap those sides.
        left_side_x = chassis_x + side_zone - thickness
        right_side_x = chassis_x + bay_width - side_zone
        left_chassis_side = add_box(entities, model, "جنب شاسيه الأدراج فتحة #{bay_number} شمال", left_side_x, front_cut + thickness, chassis_z, thickness, side_depth, chassis_height, carcass, ['DRAWER_CHASSIS','DRAWER_RELIEF_PRECALCULATED'])
        right_chassis_side = add_box(entities, model, "جنب شاسيه الأدراج فتحة #{bay_number} يمين", right_side_x, front_cut + thickness, chassis_z, thickness, side_depth, chassis_height, carcass, ['DRAWER_CHASSIS','DRAWER_RELIEF_PRECALCULATED'])
        # نفس قاعدة الأجناب الرئيسية: الجنب اليمين يحتاج قلب Front/Back في
        # OpenCutList لأن وش ربط الإليتا يقع على وجهه الداخلي (-X). الجنب
        # الشمال يظل كما هو لأن وجهه الداخلي (+X) هو الـFront الافتراضي.
        ocl_swap_front_back(right_chassis_side, thickness, side_depth, chassis_height, true)

        left_tie_x = chassis_x
        right_tie_x = chassis_x + bay_width - side_zone
        front_left_tie = add_box(entities, model, "دعامة أمامية شاسيه الأدراج فتحة #{bay_number} شمال", left_tie_x, front_cut, chassis_z, side_zone, thickness, chassis_height, carcass, ['DRAWER_CHASSIS','DRAWER_RELIEF_PRECALCULATED'])
        rear_left_tie = add_box(entities, model, "دعامة خلفية شاسيه الأدراج فتحة #{bay_number} شمال", left_tie_x, front_cut + chassis_depth - thickness, chassis_z, side_zone, thickness, chassis_height, carcass, ['DRAWER_CHASSIS','DRAWER_RELIEF_PRECALCULATED'])
        front_right_tie = add_box(entities, model, "دعامة أمامية شاسيه الأدراج فتحة #{bay_number} يمين", right_tie_x, front_cut, chassis_z, side_zone, thickness, chassis_height, carcass, ['DRAWER_CHASSIS','DRAWER_RELIEF_PRECALCULATED'])
        rear_right_tie = add_box(entities, model, "دعامة خلفية شاسيه الأدراج فتحة #{bay_number} يمين", right_tie_x, front_cut + chassis_depth - thickness, chassis_z, side_zone, thickness, chassis_height, carcass, ['DRAWER_CHASSIS','DRAWER_RELIEF_PRECALCULATED'])
        # الدعامتان الخلفيتان تستقبلان الفيشر من وجه -Y؛ هذا الوجه يكون Back
        # افتراضيًا في OpenCutList. نقلب المحاور فقط للدعامتين الخلفيتين كي
        # تظهر دوائر الفيشر في بطاقة القطعة. الدعامتان الأماميتان لا تحتاجان قلبًا.
        ocl_swap_front_back(rear_left_tie, side_zone, thickness, chassis_height)
        ocl_swap_front_back(rear_right_tie, side_zone, thickness, chassis_height)
      end

      drawer_outer_width = clear_width - runner_clearance * 2
      return if drawer_outer_width <= box_thickness * 2
      drawer_label = naming_term('drawer', 'درج')
      drawer_front_label = naming_term('drawer_front', 'وش درج')
      column_label = naming_term('column', 'عمود')
      # bay_number can be a nested layout path such as 1.2.2.2.  Names must
      # use the top-level column shown in the preview, resolved from the
      # drawer stack's absolute X position instead of that nested path.
      column_number = column_number_for_part(bay_x, bay_width)
      accessory_items = config['accessory_items'].is_a?(Hash) ? config['accessory_items'] : {}
      # Session-wide cache for the current build. This deliberately survives between
      # columns/stacks, so identical drawer geometry in different columns is built once.
      # The signature below contains geometry/construction/material choices, NOT drawer
      # or column numbers; those are renamed cheaply after cloning.
      @drawer_template_cache ||= {}
      drawer_template_cache = @drawer_template_cache

      count.times do |index|
        number = index + 1
        # أرقام الأدراج في المعاينة تبدأ من أعلى، بينما الإنشاء يبدأ من أسفل.
        # نقرأ اختيار نفس الدرج المرئي بعد عكس الرقم فقط.
        preview_number = count - index
        drawer_accessory = accessory_items["drawer:#{preview_number}"]
        drawer_accessory = {} unless drawer_accessory.is_a?(Hash)
        runner_type = drawer_accessory['runner_type'].to_s
        runner_type = 'side' unless %w[side under].include?(runner_type)
        organizer_type = drawer_accessory['organizer_type'].to_s
        organizer_count = [[drawer_accessory['organizer_count'].to_i, 1].max, 8].min

        # تخليع صرف خاص بالدرج المحدد فقط.
        drain_relief = %w[overlay_front flush_carcass].include?(config['drawer_pattern'].to_s) &&
                       %w[yes true 1].include?(drawer_accessory['drain_relief'].to_s.downcase)
        drain_cut_width = (drawer_accessory['drain_cut_width'].to_f > 0 ? drawer_accessory['drain_cut_width'].to_f : 17.0).cm
        drain_cut_depth = (drawer_accessory['drain_cut_depth'].to_f > 0 ? drawer_accessory['drain_cut_depth'].to_f : 25.0).cm

        base_z = chassis_z - bottom_front_margin + index * (front_height + front_gap)
        face_height = [front_height, 4.cm].max
        box_height = chassis_height_setting > 0 ? [chassis_height_setting, face_height - 1.cm].min : [13.cm, face_height - 1.cm].min
        box_z = base_z + 1.cm
        # في نظام «على وش الضلفة» وش الدرج يظل في موضعه الأصلي خارج الشاسيه
        # ولا نرجعه للداخل حتى يلمس الصندوق. المطلوب العكس: شاسيه الدرج الداخلي
        # نفسه (الجوانب + الوش + الضهر + القاعدة + المجرى/التقسيمات) يتقدم ناحية
        # وش الدرج بمقدار تخانة الوش فقط. drawer_front_cut يظل كخلوص/رجوع مقصود
        # للصندوق ولا يتم إلغاؤه.
        # "على وش الضلفة": الوش خارج مستوى الشاسيه مثل الضلفة.
        # "مساوي للشاسيه": نفس تكوين على وش الضلفة بالكامل، لكن الوش يدخل
        # بين الجنب/القاطع ويبدأ من مستوى وش الشاسيه نفسه (Y=0 عالميًا).
        face_y = if overlay_front
                   -(front_thickness * 2) - front_cut
                 elsif flush_carcass
                   -thickness - front_cut
                 else
                   -front_thickness
                 end
        inner_chassis_y_shift = if overlay_front
                                  front_thickness
                                elsif flush_carcass
                                  0.0
                                else
                                  0.0
                                end

        # مفتاح القالب يعتمد على الشكل الحقيقي فقط، وليس منسوب Z أو رقم الدرج.
        # لذلك الأدراج المتطابقة يعاد استخدامها، وأي اختلاف في المجرى/التقسيم/
        # وش الدرج/الإليتا ينشئ قالبًا مستقلًا تلقائيًا.
        inner_joinery = config['inner_drawer_joinery'].to_s
        inner_joinery = 'screw' unless %w[screw elita].include?(inner_joinery)
        # في وضع «على وش الضلفة» أول وآخر وش فقط يمتدان خارج حدود Stack الأدراج.
        # front_height القديم يترك 2 مم هامشًا أعلى وأسفل المجموعة؛ لذلك نضيف هذا
        # الهامش إلى مقدار التغطية حتى يصل الحرف النهائي فعليًا إلى:
        #   القاعدة/القاطع - الخلوص
        # بدل أن يبقى 2 مم زيادة عن الخلوص المطلوب.
        bottom_overlay_for_signature = if overlay_front && touches_base && index.zero?
                                         [thickness - clearance - bottom_front_margin, 0].max
                                       elsif flush_carcass && flush_share_bottom && index.zero?
                                         [thickness / 2.0 - clearance - bottom_front_margin, 0].max
                                       else
                                         0
                                       end
        # أعلى مجموعة الأدراج على وش الضلفة يغطي القاطع الأفقي كاملًا إذا كان
        # الجزء الأعلى مفتوحًا، أو نصف القاطع إذا كانت هناك واجهة (ضلفة/قلاب)
        # تشاركه من أعلى. التمدد لأعلى فقط ولا يغير الفاصل مع الدرج الذي تحته.
        top_overlay_for_signature = if overlay_front && index == count - 1
                                      target = top_front_shared ? thickness / 2.0 : thickness
                                      [target - clearance - top_front_margin, 0].max
                                    elsif flush_carcass && flush_share_top && index == count - 1
                                      [thickness / 2.0 - clearance - top_front_margin, 0].max
                                    else
                                      0
                                    end
        template_signature = drawer_template_signature([
          clear_width, box_depth, box_thickness, bottom_thickness, bottom_drop,
          bottom_groove_depth, box_height,
          front_width = if overlay_front
                          clear_width + left_overlay + right_overlay - clearance * 2
                        elsif flush_carcass
                          clear_width +
                          (flush_share_left ? thickness / 2.0 : 0) +
                          (flush_share_right ? thickness / 2.0 : 0) -
                          clearance * 2
                        else
                          clear_width - side_front_margin * 2
                        end,
          front_thickness, face_height + bottom_overlay_for_signature + top_overlay_for_signature,
          # مهم: قد يتساوى إجمالي الزيادة للوش العلوي والسفلي، لكن موضعها مختلف.
          # بدون الفصل بين القيمتين كان Cache الأدراج يعيد استخدام قالب الوش العلوي
          # للسفلي (أو العكس)، فيظهر العلوي داخل الدرج الذي تحته ولا ينزل الأخير
          # لتغطية القاعدة. إدخال القيمتين منفصلتين يجعل لكل حالة قالبها الصحيح.
          bottom_overlay_for_signature, top_overlay_for_signature,
          front_x = if overlay_front
                      -left_overlay + clearance
                    elsif flush_carcass
                      -(flush_share_left ? thickness / 2.0 : 0) + clearance
                    else
                      side_front_margin
                    end,
          face_y, drawer_pattern,
          flush_share_left, flush_share_right, flush_share_bottom, flush_share_top,
          runner_clearance, runner_type, organizer_type, organizer_count,
          drain_relief, drain_cut_width, drain_cut_depth,
          inner_joinery,
          config['inner_elita_edge_offset'], config['inner_elita_screw_drill_diameter'],
          config['inner_elita_dowel_diameter'], config['inner_elita_dowel_depth'],
          config['inner_elita_cam_diameter'], config['inner_elita_cam_depth'],
          config['inner_elita_screw_after_thread'], config['inner_elita_coil_count'],
          config['inner_elita_coil_drill_diameter'], config['inner_elita_coil_length'],
          config['inner_elita_coil_face_depth'], config['inner_elita_coil_center_distance'],
          carcass && carcass.name.to_s, back_material && back_material.name.to_s,
          front_material && front_material.name.to_s
        ])

        if (template = drawer_template_cache[template_signature])
          cloned = clone_drawer_template(
            entities, model, template, base_z, bay_x + clear_x, number, column_number,
            drawer_label, column_label
          )
          if cloned
            drawer, front_piece = cloned
            drawer_closed_y = thickness + front_cut
            configure_dynamic_drawer(drawer, front_piece, drawer_closed_y, box_depth) if front_piece
            next
          end
        end

        drawer_group = entities.add_group
        drawer_group.name = "درج #{number} فتحة #{bay_number}"
        drawer_group.set_attribute('dynamic_attributes', '_name', 'B.Cajon')
        drawer_group.set_attribute('MHD_DRESSING', 'TYPE', 'B.Cajon')

        # نظام مستقل تمامًا لشاسيه الدرج الداخلي:
        # جنب شاسيه الدرج يمين/شمال + وش الشاسيه + ضهر الشاسيه فقط.
        drawer_group.set_attribute('MHD_DRESSING', 'INNER_DRAWER_JOINERY', inner_joinery)
        {
          'EDGE_OFFSET' => ['inner_elita_edge_offset', 5.0],
          'SCREW_DRILL_DIAMETER' => ['inner_elita_screw_drill_diameter', 0.8],
          'DOWEL_DIAMETER' => ['inner_elita_dowel_diameter', 0.8],
          'DOWEL_DEPTH' => ['inner_elita_dowel_depth', 1.05],
          'CAM_DIAMETER' => ['inner_elita_cam_diameter', 1.5],
          'CAM_DEPTH' => ['inner_elita_cam_depth', 1.2],
          'SCREW_AFTER_THREAD' => ['inner_elita_screw_after_thread', 3.2],
          'COIL_COUNT' => ['inner_elita_coil_count', 1],
          'COIL_DRILL_DIAMETER' => ['inner_elita_coil_drill_diameter', 0.8],
          'COIL_LENGTH' => ['inner_elita_coil_length', 4.0],
          'COIL_FACE_DEPTH' => ['inner_elita_coil_face_depth', 2.0],
          'COIL_CENTER_DISTANCE' => ['inner_elita_coil_center_distance', 2.5]
        }.each do |suffix, (key, fallback)|
          value = config[key]
          value = fallback if value.nil? || value.to_s.empty?
          drawer_group.set_attribute('MHD_DRESSING', "INNER_ELITA_#{suffix}", value)
        end
        de = drawer_group.entities

        # Each front must use its own stack level. Previously every front was
        # created at Z=clearance, so all copies coincided and looked like one.
        front_x = if overlay_front
                    -left_overlay + clearance
                  elsif flush_carcass
                    # لو القاطع الجانبي مقصوص بنفس تخانة الوش، يمتد الوش
                    # حتى منتصف القاطع فقط ثم نخصم الخلوص.
                    -(flush_share_left ? thickness / 2.0 : 0) + clearance
                  else
                    side_front_margin
                  end
        front_width = if overlay_front
                        clear_width + left_overlay + right_overlay - clearance * 2
                      elsif flush_carcass
                        clear_width +
                        (flush_share_left ? thickness / 2.0 : 0) +
                        (flush_share_right ? thickness / 2.0 : 0) -
                        clearance * 2
                      else
                        clear_width - side_front_margin * 2
                      end
        raise 'خلوص وش الدرج أكبر من العرض المتاح.' if front_width <= 0
        bottom_overlay = if overlay_front && touches_base && index.zero?
                           [thickness - clearance - bottom_front_margin, 0].max
                         elsif flush_carcass && flush_share_bottom && index.zero?
                           [thickness / 2.0 - clearance - bottom_front_margin, 0].max
                         else
                           0
                         end
        top_overlay = if overlay_front && index == count - 1
                        target = top_front_shared ? thickness / 2.0 : thickness
                        [target - clearance - top_front_margin, 0].max
                      elsif flush_carcass && flush_share_top && index == count - 1
                        [thickness / 2.0 - clearance - top_front_margin, 0].max
                      else
                        0
                      end
        front_z = base_z - bottom_overlay
        visible_front_height = face_height + bottom_overlay + top_overlay
        front_piece = add_drawer_front(de, model, "#{drawer_front_label} #{number} #{column_label} #{column_number}", front_x, face_y, front_z, front_width, front_thickness, visible_front_height, front_material, carcass)

        # مفحار قاعدة الدرج الحقيقي:
        # بداية حفر القاعدة تقاس من أسفل شاسيه الدرج الداخلي نفسه،
        # وتطبق على الجنبين + وش الشاسيه + الضهر. بعدها تبدأ القاعدة ومفحارها
        # على نفس المنسوب، بينما عمق دخول القاعدة داخل الخشب يظل bottom_groove_depth.
        groove_depth = [bottom_groove_depth, box_thickness - 0.1.cm].min
        groove_z_local = bottom_drop
        raise 'منسوب مفحار قاعدة الدرج خارج ارتفاع الشاسيه.' if groove_z_local < 0 || groove_z_local + bottom_thickness > box_height

        # تركيب شاسيه الدرج الداخلي:
        # الوش والضهر بعرض الشاسيه الخارجي كامل، والجنبان بينهما.
        # لذلك يبدأ كل جنب بعد تخانة الوش وينتهي قبل تخانة الضهر.
        inner_side_depth = box_depth - box_thickness * 2
        raise 'عمق شاسيه الدرج لا يكفي لتركيب الجنبين بين الوش والضهر.' if inner_side_depth <= 0

        add_drawer_side_with_bottom_groove(
          de, model, "جنب شمال #{drawer_label} #{number} #{column_label} #{column_number}",
          runner_clearance, box_thickness - inner_chassis_y_shift, box_z,
          box_thickness, inner_side_depth, box_height,
          carcass, ['DRAWER_SIDE'], groove_depth, groove_z_local, bottom_thickness, :max_x
        )
        right_drawer_side = add_drawer_side_with_bottom_groove(
          de, model, "جنب يمين #{drawer_label} #{number} #{column_label} #{column_number}",
          clear_width - runner_clearance - box_thickness, box_thickness - inner_chassis_y_shift, box_z,
          box_thickness, inner_side_depth, box_height,
          carcass, ['DRAWER_SIDE'], groove_depth, groove_z_local, bottom_thickness, :min_x
        )

        cross_width = drawer_outer_width
        add_drawer_cross_with_bottom_groove(
          de, model, "وش شاسيه #{drawer_label} #{number} #{column_label} #{column_number}",
          runner_clearance, -inner_chassis_y_shift, box_z,
          cross_width, box_thickness, box_height,
          carcass, ['DRAWER_BOX'], groove_depth, groove_z_local, bottom_thickness, :max_y
        )
        if drain_relief
          # ضهر شاسيه الدرج يتقسم يمين/شمال ويترك فراغًا في المنتصف
          # مطابقًا لعرض تخليع الصرف في القاعدة.
          usable_gap = [[drain_cut_width, 2.cm].max, cross_width - 2.cm].min
          rear_piece_width = (cross_width - usable_gap) / 2.0
          raise 'عرض تخليع الصرف أكبر من عرض ضهر شاسيه الدرج.' if rear_piece_width <= 0.5.cm

          # ضهر الصرف يأخذ نفس ارتفاع شاسيه الدرج الحالي بدون اختيار منفصل.
          rear_h = box_height

          add_drawer_cross_with_bottom_groove(
            de, model, "ضهر شاسيه #{drawer_label} #{number} #{column_label} #{column_number} شمال",
            runner_clearance, box_depth - box_thickness - inner_chassis_y_shift, box_z,
            rear_piece_width, box_thickness, rear_h,
            carcass, ['DRAWER_BOX','DRAIN_RELIEF'], groove_depth, groove_z_local, bottom_thickness, :min_y
          )
          add_drawer_cross_with_bottom_groove(
            de, model, "ضهر شاسيه #{drawer_label} #{number} #{column_label} #{column_number} يمين",
            runner_clearance + rear_piece_width + usable_gap,
            box_depth - box_thickness - inner_chassis_y_shift, box_z,
            rear_piece_width, box_thickness, rear_h,
            carcass, ['DRAWER_BOX','DRAIN_RELIEF'], groove_depth, groove_z_local, bottom_thickness, :min_y
          )
        else
          add_drawer_cross_with_bottom_groove(
            de, model, "ضهر شاسيه #{drawer_label} #{number} #{column_label} #{column_number}",
            runner_clearance, box_depth - box_thickness - inner_chassis_y_shift, box_z,
            cross_width, box_thickness, box_height,
            carcass, ['DRAWER_BOX'], groove_depth, groove_z_local, bottom_thickness, :min_y
          )
        end

        bottom_x = runner_clearance + box_thickness - groove_depth
        bottom_w = drawer_outer_width - 2 * box_thickness + 2 * groove_depth
        bottom_y = box_thickness - groove_depth - inner_chassis_y_shift
        bottom_d = box_depth - 2 * box_thickness + 2 * groove_depth

        if drain_relief
          raise 'طول تخليع الصرف أكبر من عمق قاعدة الدرج.' if drain_cut_depth >= bottom_d - 0.5.cm
          raise 'عرض تخليع الصرف أكبر من عرض قاعدة الدرج.' if drain_cut_width >= bottom_w - 1.cm
          add_drawer_bottom_with_drain_u(
            de, model, "قاعدة #{drawer_label} #{number} #{column_label} #{column_number}",
            bottom_x, bottom_y, box_z + bottom_drop,
            bottom_w, bottom_d, bottom_thickness,
            back_material, drain_cut_width, drain_cut_depth, ['DRAWER_BOTTOM']
          )
        else
          add_box(
            de, model, "قاعدة #{drawer_label} #{number} #{column_label} #{column_number}",
            bottom_x, bottom_y, box_z + bottom_drop,
            bottom_w, bottom_d, bottom_thickness,
            back_material, ['DRAWER_BOTTOM']
          )
        end

        # إكسسوار تقسيمات للدرج المحدد فقط — مستقل تمامًا عن نوع المجرى.
        if organizer_type == 'grid'
          organizer_z = box_z + bottom_drop + bottom_thickness
          organizer_top = box_z + box_height - 0.5.cm
          organizer_height = organizer_top - organizer_z

          inner_x0 = runner_clearance + box_thickness
          inner_x1 = clear_width - runner_clearance - box_thickness
          inner_y0 = box_thickness - inner_chassis_y_shift
          inner_y1 = box_depth - box_thickness - inner_chassis_y_shift

          add_drawer_organizer(
            de, model, number, column_number,
            inner_x0, inner_x1, inner_y0, inner_y1,
            organizer_z, organizer_height, box_thickness,
            organizer_count, carcass
          )
        end

        # نفذ تجميع الإليتا للشاسيه الداخلي الآن، قبل تحويل Group الدرج
        # إلى Dynamic Component. التخريم والإكسسوار يتمان داخل الدرج نفسه
        # ثم يتحول كله كوحدة واحدة، فيتحرك الإكسسوار مع فتح/غلق الدرج
        # بدون تشغيل Redraw متكرر أثناء الحفر.
        build_inner_drawer_elita_joinery(drawer_group, model) if inner_joinery == 'elita'

        # المجرى الجانبي أصبح Child مستقل داخل الدرج نفسه. بهذه الطريقة يتحرك
        # مع الدرج تلقائيًا، من غير Stretch أو Motion Link، ومن غير دمجه مع
        # خشبة الجنب فيؤثر على سمكها في CutList.
        if runner_type == 'side'
          left_outer_face_x  = runner_clearance
          right_outer_face_x = clear_width - runner_clearance
          side_center_z = box_z + box_height / 2.0

          add_drawer_slide_outside_chassis(
            de, model, 'right',
            right_outer_face_x, -inner_chassis_y_shift, side_center_z, box_depth,
            number, column_number
          )
          add_drawer_slide_outside_chassis(
            de, model, 'left',
            left_outer_face_x, -inner_chassis_y_shift, side_center_z, box_depth,
            number, column_number
          )
        end

        drawer = drawer_group.to_component
        drawer.definition.name = unique_name(model, qualified_part_name("#{drawer_label} #{number} #{column_label} #{column_number}"))
        drawer.name = qualified_part_name("#{drawer_label} #{number} #{column_label} #{column_number}")
        drawer_closed_y = thickness + front_cut
        drawer.transform!(Geom::Transformation.translation([bay_x + clear_x, drawer_closed_y, 0]))
        configure_dynamic_drawer(drawer, front_piece, drawer_closed_y, box_depth)
        drawer_template_cache[template_signature] ||= { drawer: drawer, base_z: base_z, number: number, column_number: column_number }
      end
    end


    # قاعدة درج بتخليع صرف حرف U مفتوح من جهة الضهر.
    # المقاسات كلها SketchUp Lengths، والتخليع يتمركز تلقائيًا في عرض القاعدة.
    def add_drawer_bottom_with_drain_u(parent, model, name, x, y, z, width, depth, height,
                                       material, notch_width, notch_depth, badges = ['DRAWER_BOTTOM'])
      notch_width = [[notch_width.to_f, 2.cm].max, width.to_f - 2.cm].min
      notch_depth = [[notch_depth.to_f, 2.cm].max, depth.to_f - 1.cm].min
      radius = notch_width / 2.0
      center_x = width / 2.0
      center_y = depth - notch_depth + radius

      # لو العمق صغير جدًا بالنسبة لنصف الدائرة نقلل نصف القطر هندسيًا فقط
      # مع الحفاظ على أكبر عرض ممكن للتخليع.
      max_radius_for_depth = [depth - 1.cm, 1.cm].max
      radius = [radius, max_radius_for_depth].min
      notch_width = radius * 2.0
      center_y = depth - notch_depth + radius

      right_x = center_x + radius
      left_x  = center_x - radius

      points = [
        [0, 0],
        [width, 0],
        [width, depth],
        [right_x, depth],
        [right_x, center_y]
      ]

      # نصف دائرة قاع الـU: من اليمين إلى الشمال مرورًا باتجاه مقدمة الدرج.
      12.times do |i|
        angle = -Math::PI * (i + 1).to_f / 12.0
        points << [
          center_x + radius * Math.cos(angle),
          center_y + radius * Math.sin(angle)
        ]
      end

      points << [left_x, depth]
      points << [0, depth]

      part = add_xy_profile(
        parent, model, name, points,
        x, y, z, width, depth, height, material,
        Array(badges) + ['DRAIN_U_CUT']
      )
      if part
        [part, part.definition].each do |owner|
          owner.set_attribute('MHD_DRESSING', 'DRAIN_U_CUT', true)
          owner.set_attribute('MHD_DRESSING', 'DRAIN_U_WIDTH_CM', notch_width.to_f / 1.cm.to_f)
          owner.set_attribute('MHD_DRESSING', 'DRAIN_U_DEPTH_CM', notch_depth.to_f / 1.cm.to_f)
        end
      end
      part
    end

    def template_shelf(entities, model, x, width, z, depth, thickness, material, label, front_cut = 0, support_type = nil, shelf_role = 'actual')
      sliding_cut = 0
      if @sliding_context
        shelf_left = x.to_f
        shelf_right = shelf_left + width.to_f
        sliding_left = @sliding_context['coverage_x'].to_f
        sliding_right = sliding_left + @sliding_context['coverage_width'].to_f
        if shelf_right > sliding_left + 0.1.cm && shelf_left < sliding_right - 0.1.cm
          sliding_cut = @sliding_context['partition_cut'].to_f
        end
      end
      cut = [front_cut.to_f, sliding_cut, 0].max
      shelf_depth = depth - cut
      raise 'قص الرف من الأمام أكبر من عمق الرف المتاح.' if shelf_depth <= 0
      x, width = slope_clip_shelf_span(x, width, z + thickness)
      return nil if width <= 1.cm
      shelf = add_box(entities, model, "رف #{label} #{PART_SUFFIX}", x, cut, z, width, shelf_depth, thickness, material, ['SHELF'])
      shelf.set_attribute('MHD_DRESSING', 'SHELF_ROLE', shelf_role.to_s)
      shelf.set_attribute('MHD_DRESSING', 'SHELF_SUPPORT_TYPE', support_type.to_s) unless support_type.to_s.empty? || support_type.to_s == 'default'
      shelf
    end

    def template_shelves(entities, model, x, width, z1, z2, count, depth, thickness, material, label, front_cut = 0, accessory_items = nil)
      count.to_i.times do |index|
        z = z1 + (z2 - z1) * (index + 1).to_f / (count.to_i + 1).to_f
        # المعاينة ترقّم الأرفف من أعلى لأسفل، بينما الإنشاء الهندسي
        # يبدأ من أسفل لأعلى؛ نعكس رقم الاختيار فقط حتى يطابق الرف نفسه.
        preview_index = count.to_i - index
        shelf_options = accessory_items.is_a?(Hash) ? accessory_items["shelf:#{preview_index}"] : nil
        support_type = shelf_options.is_a?(Hash) ? shelf_options['support_type'] : nil
        template_shelf(entities, model, x, width, z, depth, thickness, material, "#{label} #{index + 1}", front_cut, support_type)
      end
    end

    def template_partition(entities, model, x, z1, z2, depth, thickness, material, label, front_cut = 0, back_partition = false)
      # أي قاطع داخلي يقع داخل نطاق الجرار يتبع نفس قص الجرار من الأمام،
      # حتى لو كان قاطعًا صغيرًا داخل تقسيم فرعي (Nested partition).
      sliding_cut = 0.0
      if @sliding_context && !back_partition
        sliding_left = @sliding_context['coverage_x'].to_f
        sliding_right = sliding_left + @sliding_context['coverage_width'].to_f
        partition_center = x.to_f + thickness.to_f * 0.5
        if partition_center > sliding_left + 0.1.cm && partition_center < sliding_right - 0.1.cm
          sliding_cut = @sliding_context['partition_cut'].to_f
        end
      end
      cut = [front_cut.to_f, sliding_cut, 0].max
      partition_depth = depth - cut
      raise 'قص القاطع من الأمام أكبر من العمق المتاح.' if partition_depth <= 0
      z2 = [z2, slope_height_at(x + thickness * 0.5) - thickness].min if @slope_context
      return nil if z2 - z1 <= 1.cm
      groove_side = back_partition ? :both : nil
      badges = ['PARTITION']
      # القاطع الذي لا يمتد بطول العمود الكامل هو قاطع داخلي للفتحة. نعلّمه
      # صراحةً كي يتبع نفس معالجة عمق الرف في depth_avoid وفي الخلع الحقيقي،
      # من غير لمس القاطع الرئيسي بين الأعمدة.
      badges << 'BAY_INTERNAL_PARTITION' unless back_partition
      badges << 'BACK_GROOVE' if back_partition && grooved_mode?
      add_vertical_panel(entities, model, "قاطع #{label} #{PART_SUFFIX}", x, cut, z1,
                         thickness, partition_depth, z2 - z1, material, badges, groove_side)
    end

    # وجود أدراج «جنب سميك» داخل الجزء السفلي يجعل قرصة شاسيه الأدراج
    # هي الفاصل الإنشائي؛ لذلك لا نولد رفًا ثانيًا كاملًا فوقها.
    def subtree_has_thick_drawers?(node)
      return false unless node.is_a?(Hash)
      children = node['children'].is_a?(Array) ? node['children'] : []
      if children.empty?
        return node['type'].to_s == 'drawers' && !%w[overlay_front flush_carcass].include?(node['drawer_pattern'].to_s)
      end
      children.any? { |child| subtree_has_thick_drawers?(child) }
    end

    def subtree_has_drawers?(node)
      return false unless node.is_a?(Hash)
      children = node['children'].is_a?(Array) ? node['children'] : []
      return node['type'].to_s == 'drawers' if children.empty?
      children.any? { |child| subtree_has_drawers?(child) }
    end

    # واجهة فعلية على وش الدولاب داخل أي جزء من الشجرة.
    # تستخدم فقط لحساب تقاسم القاطع الأفقي مع وشوش الأدراج بنمط «على وش الضلفة».
    # الضلفة العادية والقلاب كلاهما واجهة، وكذلك مجموعة أدراج Overlay أخرى.
    def subtree_has_front_face?(node)
      return false unless node.is_a?(Hash)
      opening = node['opening_door']
      return true if opening.is_a?(Hash) && opening['enabled'].to_s == 'yes'

      children = node['children'].is_a?(Array) ? node['children'] : []
      if children.empty?
        return node['type'].to_s == 'drawers' && node['drawer_pattern'].to_s == 'overlay_front'
      end
      children.any? { |child| subtree_has_front_face?(child) }
    end

    def subtree_thick_drawer_count(node)
      return 0 unless node.is_a?(Hash)
      children = node['children'].is_a?(Array) ? node['children'] : []
      if children.empty?
        return (node['type'].to_s == 'drawers' && !%w[overlay_front flush_carcass].include?(node['drawer_pattern'].to_s)) ? 1 : 0
      end
      children.sum { |child| subtree_thick_drawer_count(child) }
    end

    def partition_front_cut(data, z1, z2)
      cut = [data['shelf_front_cut'].to_f, 0].max.cm
      return 0 if cut <= 0
      thickness = data['thickness'].to_f.cm
      full_bottom = thickness
      full_top = data['height'].to_f.cm - thickness
      tolerance = 0.2.cm
      full_height = z1 <= full_bottom + tolerance && z2 >= full_top - tolerance
      cut_full = %w[yes true 1].include?(data['cut_full_partitions'].to_s.downcase)
      (!full_height || cut_full) ? cut : 0
    end

    def collect_column_regions(node, x, width, thickness, path = [], result = [])
      if node.is_a?(Hash) && node['dir'].to_s == 'v' && node['external']
        children = node['children'].is_a?(Array) ? node['children'] : []
        return result if children.length < 2
        first_width = (width - thickness) * [[node['ratio'].to_f, 0.08].max, 0.92].min
        collect_column_regions(children[0], x, first_width, thickness, path + [0], result)
        collect_column_regions(children[1], x + first_width + thickness, width - first_width - thickness, thickness, path + [1], result)
      else
        saved_width = node.is_a?(Hash) ? node['column_width'].to_f.cm : 0
        result << {
          'node' => node,
          'x' => x,
          'width' => width,
          'door_width' => saved_width > 0 ? saved_width : width,
          'path' => path
        }
      end
      result
    end

    def collect_leaf_regions(node, x, z, width, height, thickness, path = [], result = [], left_boundary = :outer, right_boundary = :outer, bottom_boundary = :outer, top_boundary = :outer, inherited_column_front = false)
      return result unless node.is_a?(Hash)

      # ضلفة العمود محفوظة على جذر العمود، بينما collect_leaf_regions ينزل حتى
      # أصغر فراغ. نحمل معلومة وجود واجهة العمود معنا أثناء النزول حتى يستطيع
      # اكتشاف الجار عند القاطع العرضي رؤية الواجهة الفعلية ولا يعتمد فقط على
      # opening_door الموجودة على الورقة النهائية. لا يغيّر هذا أي تقسيم أو مقاس.
      column_door = node['column_door']
      column_front = inherited_column_front ||
                     (column_door.is_a?(Hash) && column_door['enabled'].to_s == 'yes')

      direction = node['dir'].to_s
      children = node['children'].is_a?(Array) ? node['children'] : []
      if %w[v h].include?(direction) && children.length >= 2
        ratio = [[node['ratio'].to_f, 0.08].max, 0.92].min
        if direction == 'v'
          first_width = (width - thickness) * ratio
          collect_leaf_regions(children[0], x, z, first_width, height, thickness, path + [0], result, left_boundary, :partition, bottom_boundary, top_boundary, column_front)
          collect_leaf_regions(children[1], x + first_width + thickness, z, width - first_width - thickness, height, thickness, path + [1], result, :partition, right_boundary, bottom_boundary, top_boundary, column_front)
        else
          top_height = (height - thickness) * ratio
          bottom_height = height - thickness - top_height
          collect_leaf_regions(children[0], x, z + bottom_height + thickness, width, top_height, thickness, path + [0], result, left_boundary, right_boundary, :shelf, top_boundary, column_front)
          collect_leaf_regions(children[1], x, z, width, bottom_height, thickness, path + [1], result, left_boundary, right_boundary, bottom_boundary, :shelf, column_front)
        end
      else
        result << {
          'node' => node, 'x' => x, 'z' => z, 'width' => width, 'height' => height,
          'path' => path, 'left' => left_boundary, 'right' => right_boundary,
          'bottom' => bottom_boundary, 'top' => top_boundary,
          'column_front' => column_front
        }
      end
      result
    end

    # هل يوجد على الناحية المقابلة من نفس القاطع الأفقي واجهة فعلية؟
    # إذا نعم يتقاسم الواجهتان القاطع Half/Half. إذا لا، الواجهة الوحيدة
    # تغطي سماكة القاطع كاملة - الخلوص. ينطبق على ضلف الفراغ ووشوش
    # الأدراج بنمط «على وش الضلفة».
    def adjacent_horizontal_front_face?(region, regions, side, thickness)
      return false unless region.is_a?(Hash) && regions.is_a?(Array)
      rx1 = region['x'].to_f
      rx2 = rx1 + region['width'].to_f
      tolerance = 0.15.cm

      regions.any? do |other|
        next false if other.equal?(region)
        ox1 = other['x'].to_f
        ox2 = ox1 + other['width'].to_f
        overlap = [rx2, ox2].min - [rx1, ox1].max
        next false unless overlap > tolerance

        touching = if side == :bottom
          ((other['z'].to_f + other['height'].to_f) - (region['z'].to_f - thickness)).abs <= tolerance
        else
          (other['z'].to_f - (region['z'].to_f + region['height'].to_f + thickness)).abs <= tolerance
        end
        # الواجهة المقابلة قد تكون ضلفة فراغ (مفصلي/قلاب، خشب/زجاج)،
        # وش درج Overlay، أو ضلفة عمود موروثة من جذر العمود.
        touching && (subtree_has_front_face?(other['node']) || other['column_front'] == true)
      end
    end

    DOOR_SOURCE_NAMES = {
      ['wood', 'right'] => 'ضلفه يمين',
      ['wood', 'left']  => 'ضلفه شمال',
      ['glass', 'right'] => 'ضلفه زجاج يمين',
      ['glass', 'left']  => 'ضلفه زجاج شمال'
    }.freeze

    def clear_generated_column_doors(root)
      root.definition.entities.grep(Sketchup::ComponentInstance).each do |item|
        generated_door = item.get_attribute('MHD_DRESSING', 'GENERATED_COLUMN_DOOR')
        generated_lift = item.get_attribute('MHD_DRESSING', 'GENERATED_FLIP_UP_LIFT')
        item.erase! if generated_door || generated_lift
      end
    end

    def normalized_definition_name(name)
      name.to_s.sub(/\s*\(\d+\)\s*\z/, '').strip.gsub(/\s+/, ' ')
    end

    def nested_component_records(entities, parent_transform = Geom::Transformation.new, ancestry = [], records = [], depth = 0)
      entities.each do |item|
        next unless item.is_a?(Sketchup::ComponentInstance) || item.is_a?(Sketchup::Group)
        next if item.get_attribute('MHD_DRESSING', 'GENERATED_COLUMN_DOOR')
        next if item.get_attribute('MHD_DRESSING', 'GENERATED_FLIP_UP_LIFT')
        transform = parent_transform * item.transformation
        records << {'instance' => item, 'transform' => transform, 'depth' => depth}
        definition = item.definition
        next if ancestry.include?(definition.object_id)
        nested_component_records(definition.entities, transform, ancestry + [definition.object_id], records, depth + 1)
      end
      records
    end

    def wardrobe_door_source(root, wanted_name, style)
      wanted_entry = DOOR_SOURCE_NAMES.find { |_key, value| value == wanted_name }
      wanted_role = wanted_entry ? "door_source:#{wanted_entry[0][0]}:#{wanted_entry[0][1]}" : ''
      candidates = nested_component_records(root.definition.entities).select do |record|
        item = record['instance']
        next false if item.get_attribute('MHD_DRESSING', 'GENERATED_COLUMN_DOOR')
        role = door_source_role(item)
        next true if !wanted_role.empty? && role == wanted_role
        identity_names = door_source_identity_names(item)
        next false unless identity_names.any? { |name| name.include?(wanted_name) }
        style == 'glass' ? identity_names.any? { |name| name.include?('زجاج') } : identity_names.none? { |name| name.include?('زجاج') }
      end
      # A compound glass-right definition contains a complete glass-left
      # component inside it.  Always choose the shallowest matching parent,
      # never that nested construction component.  Preserve the original
      # first-match behavior for the already-correct wooden doors.
      selected = style == 'glass' ? candidates.min_by { |record| record['depth'].to_i } : candidates.first
      # Repair models saved by 10.34: the source definition may already have
      # been renamed, while its original DC _name is still intact.
      if selected
        set_entity_function_role(selected['instance'], wanted_role) unless wanted_role.empty?
        claim_clean_definition_name(selected['instance'].definition, wanted_name)
      end
      selected
    end

    def copy_instance_attributes(source, target)
      dictionaries = source.attribute_dictionaries
      return target unless dictionaries
      dictionaries.each do |dictionary|
        dictionary.each_pair { |key, value| target.set_attribute(dictionary.name, key, value) }
      end
      target
    end

    def set_door_dc_value(owner, key, cm_value)
      value_cm = cm_value.to_f.round(4)
      owner.set_attribute('dynamic_attributes', key, (value_cm / 2.54).to_s)
      owner.set_attribute('dynamic_attributes', "_#{key}_formula", value_cm.to_s)
      owner.set_attribute('dynamic_attributes', "_#{key}_formulaunits", 'CENTIMETERS')
      # Dynamic Components may retain an instanced formula copied from the
      # source definition.  Override it for dimensions as well as positions;
      # otherwise redraw restores the old half-wardrobe size and offset.
      owner.set_attribute('dynamic_attributes', "_inst__#{key}_formula", value_cm.to_s)
      owner.set_attribute('dynamic_attributes', "_inst_#{key}", (value_cm / 2.54).to_s)
    end

    def reset_door_animation(instance)
      definition = instance.definition
      onclick = instance.get_attribute('dynamic_attributes', 'onclick').to_s
      onclick = definition.get_attribute('dynamic_attributes', 'onclick').to_s if onclick.empty?
      match = onclick.match(/ANIMATE\(\s*["']([^"']+)["']\s*,\s*(-?\d+(?:\.\d+)?)/i)
      if match
        attribute_name = match[1]
        closed_value = match[2]
        instance.set_attribute('dynamic_attributes', attribute_name, closed_value)
        definition.set_attribute('dynamic_attributes', attribute_name, closed_value)
      end
      instance.set_attribute('dynamic_attributes', 'rotz', '0')
      definition.set_attribute('dynamic_attributes', 'rotz', '0')
    end

    # الضلفة الخشب فقط تُبنى كلوح تصنيع مستقل حتى يقرأ OpenCutList
    # شريط الحرف على الأربع حواف فعلًا. الضلفة الزجاج لا تمر من هنا نهائيًا.
    def copy_dynamic_door(root, source_record, name, target_x, target_z, target_width, target_height, direction, style, column_path)
      model = Sketchup.active_model
      source_transform = source_record['transform']
      y_position = source_transform.origin.y
      door_depth = 1.8.cm
      material = @current_door_material
      material ||= source_record['instance'].material rescue nil
      raise "تعذر تحديد خامة الضلفة الخشب: #{name}" unless material

      group = root.definition.entities.add_group
      ge = group.entities

      # محور الضلفة عند المفصلة: اليمين يمتد ناحية -X والشمال ناحية +X.
      x0 = direction.to_s == 'right' ? -target_width : 0
      x1 = direction.to_s == 'right' ? 0 : target_width

      face = ge.add_face(
        [x0, 0, 0],
        [x1, 0, 0],
        [x1, door_depth, 0],
        [x0, door_depth, 0]
      )
      raise "تعذر رسم الضلفة الخشب: #{name}" unless face
      face.reverse! if face.normal.z < 0
      face.pushpull(target_height)

      instance = group.to_component
      instance.transform!(Geom::Transformation.translation([target_x, y_position, target_z]))
      finish_generated_part(instance, model, name, material, ['DOOR_PANEL'])

      instance.set_attribute('MHD_DRESSING', 'GENERATED_COLUMN_DOOR', true)
      set_entity_function_role(instance, 'generated_door')
      instance.set_attribute('MHD_DRESSING', 'COLUMN_PATH', column_path)
      instance.set_attribute('MHD_DRESSING', 'HINGE_DIRECTION', direction)
      instance.set_attribute('MHD_DRESSING', 'DOOR_STYLE', 'wood')

      rotation_formula = direction.to_s == 'right' ? 'open' : '-open'
      [instance, instance.definition].each do |owner|
        owner.set_attribute('dynamic_attributes', 'open', '0')
        owner.set_attribute('dynamic_attributes', '_open_label', 'فتح الضلفة')
        owner.set_attribute('dynamic_attributes', '_open_formulaunits', 'DEGREES')
        owner.set_attribute('dynamic_attributes', 'onclick', 'ANIMATE("open",0,90)')
        owner.set_attribute('dynamic_attributes', '_rotz_formula', rotation_formula)
        owner.set_attribute('dynamic_attributes', 'rotz', '0')
        owner.set_attribute('dynamic_attributes', '_onclick_state1', 0)
        owner.set_attribute('dynamic_attributes', '_hasbehaviors', 1.0)
        owner.set_attribute('dynamic_attributes', '_has_movetool_behaviors', 1.0)
      end

      ensure_persistent_dc_name(instance, 'MHD_DOOR')

      # قاعدة ثابتة للخشب: الشريط داير دائمًا.
      apply_edge_banding(
        instance, model, name, material,
        ['DOOR_PANEL'], target_width, door_depth, target_height
      )
      orient_part_textures(instance, name, ['DOOR_PANEL'], target_width, door_depth, target_height)
      instance
    end

    # Glass doors are compound Dynamic Components (frame sides, rails, glass,
    # trim and their own formulas).  Clone the complete source definition at
    # the local origin and only override the parent DC attributes.  The source
    # translation must not be inherited because X/Y/Z below are authoritative;
    # inheriting both makes one of the leaves receive its position twice.
    # Never rebuild, scale or touch any of its nested entities.
    def copy_dynamic_glass_door(root, source_record, name, target_x, target_z, target_width, target_height, direction, column_path)
      source = source_record['instance']
      source_transform = source_record['transform']
      instance = root.definition.entities.add_instance(source.definition, Geom::Transformation.new)
      copy_instance_attributes(source, instance)
      instance.make_unique
      name = qualified_part_name(name)
      instance.definition.name = unique_name(Sketchup.active_model, name)
      # The black/glass finish of the left source is assigned to the source
      # ComponentInstance itself (not to its definition or DC dictionary).
      # add_instance copies geometry only, so preserve that instance material
      # explicitly before the Dynamic Component redraw.
      instance.material = source.material if source.respond_to?(:material) && source.material
      instance.hidden = false
      instance.name = name
      instance.set_attribute('MHD_DRESSING', 'GENERATED_COLUMN_DOOR', true)
      set_entity_function_role(instance, 'generated_door')
      instance.set_attribute('MHD_DRESSING', 'COLUMN_PATH', column_path)
      instance.set_attribute('MHD_DRESSING', 'HINGE_DIRECTION', direction)
      instance.set_attribute('MHD_DRESSING', 'DOOR_STYLE', 'glass')

      values = {
        'x' => target_x.to_f / 1.cm.to_f,
        'y' => source_transform.origin.y.to_f / 1.cm.to_f,
        'z' => target_z.to_f / 1.cm.to_f,
        'lenx' => target_width.to_f / 1.cm.to_f,
        'lenz' => target_height.to_f / 1.cm.to_f
      }
      values.each do |key, value|
        set_door_dc_value(instance, key, value)
        set_door_dc_value(instance.definition, key, value)
      end
      if direction == 'right'
        # The original compound right-glass door is a parent whose visible
        # construction is a complete left-glass door nested inside it.  Its
        # source translation equals the old source width, so changing only the
        # parent LenX leaves the visible frame behind.  Keep the parent origin
        # at the right hinge and move that complete nested construction left by
        # the new leaf width using Dynamic Component attributes only.
        inner_leaf = instance.definition.entities.grep(Sketchup::ComponentInstance).find do |child|
          role = door_source_role(child)
          role == 'door_source:glass:left' || door_source_identity_names(child).any? { |name| name.include?('ضلفه زجاج شمال') }
        end
        if inner_leaf
          inner_leaf.make_unique
          set_door_dc_value(inner_leaf, 'x', -values['lenx'])
          set_door_dc_value(inner_leaf.definition, 'x', -values['lenx'])
        end
      end
      [instance, instance.definition].each do |owner|
        owner.set_attribute('dynamic_attributes', 'hidden', '0')
        owner.set_attribute('dynamic_attributes', '_hidden_formula', 'FALSE')
        owner.set_attribute('dynamic_attributes', '_inst__hidden_formula', 'FALSE')
      end
      reset_door_animation(instance)
      redraw_dc(instance)
      # الزجاج يظل كما هو تمامًا؛ لا شريط حرف ولا تغيير لخامات أجزائه الداخلية.
      instance
    end

    def overlay_drawer_top(node, z, height, thickness)
      return nil unless node.is_a?(Hash)
      direction = node['dir'].to_s
      children = node['children'].is_a?(Array) ? node['children'] : []
      if direction == 'v' && children.length >= 2
        return children.map { |child| overlay_drawer_top(child, z, height, thickness) }.compact.max
      elsif direction == 'h' && children.length >= 2
        ratio = [[node['ratio'].to_f, 0.08].max, 0.92].min
        top_height = (height - thickness) * ratio
        bottom_height = height - thickness - top_height
        divider_z = z + bottom_height
        values = [
          overlay_drawer_top(children[0], divider_z + thickness, top_height, thickness),
          overlay_drawer_top(children[1], z, bottom_height, thickness)
        ]
        return values.compact.max
      end
      pattern = node['drawer_pattern'].to_s
      node['type'].to_s == 'drawers' && %w[overlay_front flush_carcass].include?(pattern) ? z + height : nil
    end

    # ضلف الفراغات لها الأولوية على ضلفة العمود. نحسب المساحات الرأسية
    # المحجوزة لكل ضلفة فراغ (خشب أو زجاج أو قلاب)، ثم نختار أكبر مساحة
    # متصلة متبقية لضلفة العمود حتى لا تتولد ضلفتان فوق بعض.
    def opening_door_free_span(node, x, z, width, height, thickness, base_bottom, base_top, clearance = 0)
      regions = collect_leaf_regions(node, x, z, width, height, thickness)
      blocked = regions.filter_map do |region|
        opening_door = region['node'].is_a?(Hash) ? region['node']['opening_door'] : nil
        next unless opening_door.is_a?(Hash)
        next unless opening_door['enabled'].to_s == 'yes'
        bottom_overlay = region['bottom'] == :outer ? thickness : thickness / 2.0
        top_overlay = region['top'] == :outer ? thickness : thickness / 2.0

        # قاعدة عامة لمشاركة القاطع العرضي بين واجهتين:
        # ضلفة الفراغ نفسها تصل إلى نصف القاطع - الخلوص. وإذا كانت ضلفة
        # العمود ستكمل فوقها/تحتها، يجب أن يبدأ فراغ ضلفة العمود من النصف
        # المقابل + الخلوص، لا من مركز القاطع نفسه. بذلك الواجهتان تتقاسمان
        # القاطع Half/Half ولا تغطي ضلفة العمود الضلفة المقابلة.
        bottom_share_clearance = region['bottom'] == :outer ? 0 : clearance.to_f
        top_share_clearance = region['top'] == :outer ? 0 : clearance.to_f
        blocked_bottom = [region['z'] - bottom_overlay - bottom_share_clearance, base_bottom].max
        blocked_top = [region['z'] + region['height'] + top_overlay + top_share_clearance, base_top].min
        blocked_top > blocked_bottom ? [blocked_bottom, blocked_top] : nil
      end
      return [base_bottom, base_top] if blocked.empty?

      merged = []
      blocked.sort_by(&:first).each do |interval|
        if merged.empty? || interval[0] > merged[-1][1]
          merged << interval.dup
        else
          merged[-1][1] = [merged[-1][1], interval[1]].max
        end
      end
      gaps = []
      cursor = base_bottom
      merged.each do |interval|
        gaps << [cursor, interval[0]] if interval[0] > cursor
        cursor = [cursor, interval[1]].max
      end
      gaps << [cursor, base_top] if base_top > cursor
      gaps.max_by { |span| span[1] - span[0] }
    end

    def add_sloped_door_prism(entities, points_xz, depth, material)
      face = entities.add_face(points_xz.map { |x, z| [x, 0, z] })
      return unless face
      face.reverse! if face.normal.y < 0
      face.pushpull(depth)
      entities.grep(Sketchup::Face).each do |item|
        next if item.material
        item.material = material
        item.back_material = material
      end
    end

    def create_sloped_dynamic_door(root, name, hinge_x, target_z, leaf_width, top_at_left, top_at_right, direction, style, material, column_path, y_position)
      model = Sketchup.active_model
      group = root.definition.entities.add_group
      local_left = direction == 'right' ? -leaf_width : 0
      local_right = direction == 'right' ? 0 : leaf_width
      global_left = direction == 'right' ? hinge_x - leaf_width : hinge_x
      left_top = top_at_left - target_z
      right_top = top_at_right - target_z
      depth = 1.8.cm
      if style == 'glass'
        frame = 5.cm
        glass = mat(model, 'زجاج شفاف', Sketchup::Color.new(175, 210, 220))
        glass.alpha = 0.35 if glass.respond_to?(:alpha=)
        left_inner_top = left_top + (right_top-left_top) * frame / leaf_width
        right_inner_top = right_top - (right_top-left_top) * frame / leaf_width
        add_sloped_door_prism(group.entities, [[local_left,0],[local_left+frame,0],[local_left+frame,left_inner_top],[local_left,left_top]], depth, material)
        add_sloped_door_prism(group.entities, [[local_right-frame,0],[local_right,0],[local_right,right_top],[local_right-frame,right_inner_top]], depth, material)
        add_sloped_door_prism(group.entities, [[local_left,0],[local_right,0],[local_right,frame],[local_left,frame]], depth, material)
        add_sloped_door_prism(group.entities, [[local_left,left_top-frame],[local_right,right_top-frame],[local_right,right_top],[local_left,left_top]], depth, material)
        inner_left = local_left + frame
        inner_right = local_right - frame
        if inner_right > inner_left && [left_top,right_top].min > frame * 2
          add_sloped_door_prism(group.entities, [[inner_left,frame],[inner_right,frame],[inner_right,right_top-frame],[inner_left,left_top-frame]], 0.6.cm, glass)
        end
      else
        add_sloped_door_prism(group.entities, [[local_left,0],[local_right,0],[local_right,right_top],[local_left,left_top]], depth, material)
      end
      instance = group.to_component
      instance.transform!(Geom::Transformation.translation([hinge_x, y_position, target_z]))
      finish_generated_part(instance, model, name, material, [style == 'glass' ? 'GLASS_DOOR' : 'DOOR_PANEL','SLOPED'], style == 'glass')
      instance.set_attribute('MHD_DRESSING', 'GENERATED_COLUMN_DOOR', true)
      set_entity_function_role(instance, 'generated_door')
      instance.set_attribute('MHD_DRESSING', 'COLUMN_PATH', column_path)
      instance.set_attribute('MHD_DRESSING', 'HINGE_DIRECTION', direction)
      instance.set_attribute('MHD_DRESSING', 'DOOR_STYLE', style)

      # نحفظ منسوب أعلى الضلفة الحقيقي عند خط المفصلة نفسه.
      # في الضلفة المائلة لا يجوز الاعتماد على Bounds.z1 لأنه يمثل أعلى
      # نقطة في الضلفة كلها، وقد تكون بعيدة عن ناحية المفصلة.
      hinge_top_z = direction == 'right' ? top_at_right : top_at_left
      instance.set_attribute('MHD_DRESSING', 'SLOPED_HINGE_TOP_Z', hinge_top_z.to_f)
      instance.set_attribute('MHD_DRESSING', 'SLOPED_DOOR', true)

      # محور Y في وحدات المكتبة يجعل الإشارة المعتادة تفتح للداخل؛
      # نعكسها هنا حتى تفتح الضلفة المائلة إلى خارج واجهة الدولاب.
      rotation_formula = direction == 'right' ? 'open' : '-open'
      [instance, instance.definition].each do |owner|
        owner.set_attribute('dynamic_attributes', 'open', '0')
        owner.set_attribute('dynamic_attributes', '_open_formulaunits', 'DEGREES')
        owner.set_attribute('dynamic_attributes', 'onclick', 'ANIMATE("open",0,90)')
        owner.set_attribute('dynamic_attributes', '_rotz_formula', rotation_formula)
        owner.set_attribute('dynamic_attributes', 'rotz', '0')
      end
      apply_edge_banding(instance, model, name, material, ['DOOR_PANEL','SLOPED'], leaf_width, depth, [left_top, right_top].max)
      instance
    end

    # القلاب الزجاج يجب أن يظل نسخة كاملة من الـDynamic Component الأصلي؛
    # لا نعيد بناء الإطار أو الزجاج حتى لا نفقد خاماته وقطعه الداخلية.
    # نضع النسخة داخل حامل محوره عند الحافة العليا، والحامل وحده هو الذي يدور.
    def create_dynamic_glass_flip_up_door(root, source_record, name, target_x, target_z, width, height, opening_path)
      model = Sketchup.active_model
      source = source_record['instance']
      source_transform = source_record['transform']
      group = root.definition.entities.add_group
      glass_leaf = group.entities.add_instance(source.definition, Geom::Transformation.new)
      copy_instance_attributes(source, glass_leaf)
      glass_leaf.make_unique
      child_name = qualified_part_name("#{name} - تكوين الزجاج")
      glass_leaf.definition.name = unique_name(model, child_name)
      glass_leaf.name = child_name
      glass_leaf.material = source.material if source.respond_to?(:material) && source.material
      glass_leaf.hidden = false

      values = {
        'x' => 0.0,
        'y' => 0.0,
        'z' => -(height.to_f / 1.cm.to_f),
        'lenx' => width.to_f / 1.cm.to_f,
        'lenz' => height.to_f / 1.cm.to_f
      }
      values.each do |key, value|
        set_door_dc_value(glass_leaf, key, value)
        set_door_dc_value(glass_leaf.definition, key, value)
      end
      [glass_leaf, glass_leaf.definition].each do |owner|
        owner.set_attribute('dynamic_attributes', 'hidden', '0')
        owner.set_attribute('dynamic_attributes', '_hidden_formula', 'FALSE')
        owner.set_attribute('dynamic_attributes', '_inst__hidden_formula', 'FALSE')
        owner.set_attribute('dynamic_attributes', 'onclick', '')
        owner.set_attribute('dynamic_attributes', '_rotz_formula', '0')
        owner.set_attribute('dynamic_attributes', 'rotz', '0')
      end
      redraw_dc(glass_leaf)

      wrapper = group.to_component
      wrapper_name = qualified_part_name(name)
      wrapper.definition.name = unique_name(model, wrapper_name)
      wrapper.name = wrapper_name
      wrapper.transform!(Geom::Transformation.translation([target_x, source_transform.origin.y, target_z + height]))
      wrapper.set_attribute('MHD_DRESSING', 'GENERATED_COLUMN_DOOR', true)
      set_entity_function_role(wrapper, 'generated_door')
      wrapper.set_attribute('MHD_DRESSING', 'OPENING_PATH', opening_path)
      wrapper.set_attribute('MHD_DRESSING', 'HINGE_DIRECTION', 'flip_up')
      wrapper.set_attribute('MHD_DRESSING', 'DOOR_STYLE', 'glass')

      # نحفظ أبعاد/موضع القلاب الزجاج صراحةً.
      # الـDynamic Component الداخلي قد يغيّر Bounds بعد redraw، لذلك لا
      # نعتمد على Bounds لتحديد أماكن المفصلات الزجاجية.
      wrapper.set_attribute('MHD_DRESSING', 'FLIP_UP_X0', target_x.to_f)
      wrapper.set_attribute('MHD_DRESSING', 'FLIP_UP_X1', target_x.to_f + width.to_f)
      wrapper.set_attribute('MHD_DRESSING', 'FLIP_UP_Z0', target_z.to_f)
      wrapper.set_attribute('MHD_DRESSING', 'FLIP_UP_Z1', target_z.to_f + height.to_f)
      wrapper.set_attribute('MHD_DRESSING', 'FLIP_UP_Y', source_transform.origin.y.to_f)

      [wrapper, wrapper.definition].each do |owner|
        owner.set_attribute('dynamic_attributes', 'open', '0')
        owner.set_attribute('dynamic_attributes', '_open_formulaunits', 'DEGREES')
        owner.set_attribute('dynamic_attributes', 'onclick', 'ANIMATE("open",0,-80)')
        owner.set_attribute('dynamic_attributes', '_rotx_formula', 'open')
        owner.set_attribute('dynamic_attributes', 'rotx', '0')
        owner.set_attribute('dynamic_attributes', '_onclick_state1', 0)
        owner.set_attribute('dynamic_attributes', '_hasbehaviors', 1.0)
      end
      ensure_persistent_dc_name(wrapper, 'MHD_DOOR')
      # الضلفة الزجاج القلاب أيضًا تظل بتركيبها وخاماتها الأصلية بلا Edge Band.
      wrapper
    end

    def create_flip_up_door(root, name, target_x, target_z, width, height, style, material, opening_path, y_position)
      model = Sketchup.active_model
      depth = 1.8.cm
      group = root.definition.entities.add_group
      if style == 'glass'
        frame = [[5.cm, width * 0.22, height * 0.22].min, 1.5.cm].max
        glass = mat(model, 'زجاج شفاف', Sketchup::Color.new(175, 210, 220))
        glass.alpha = 0.35 if glass.respond_to?(:alpha=)
        add_sloped_door_prism(group.entities, [[0,-height],[frame,-height],[frame,0],[0,0]], depth, material)
        add_sloped_door_prism(group.entities, [[width-frame,-height],[width,-height],[width,0],[width-frame,0]], depth, material)
        add_sloped_door_prism(group.entities, [[frame,-height],[width-frame,-height],[width-frame,-height+frame],[frame,-height+frame]], depth, material)
        add_sloped_door_prism(group.entities, [[frame,-frame],[width-frame,-frame],[width-frame,0],[frame,0]], depth, material)
        if width > frame * 2 && height > frame * 2
          add_sloped_door_prism(group.entities, [[frame,-height+frame],[width-frame,-height+frame],[width-frame,-frame],[frame,-frame]], 0.6.cm, glass)
        end
      else
        add_sloped_door_prism(group.entities, [[0,-height],[width,-height],[width,0],[0,0]], depth, material)
      end
      instance = group.to_component
      instance.transform!(Geom::Transformation.translation([target_x, y_position, target_z + height]))
      finish_generated_part(instance, model, name, material, [style == 'glass' ? 'GLASS_DOOR' : 'DOOR_PANEL','FLIP_UP'], style == 'glass')
      instance.set_attribute('MHD_DRESSING', 'GENERATED_COLUMN_DOOR', true)
      set_entity_function_role(instance, 'generated_door')
      instance.set_attribute('MHD_DRESSING', 'OPENING_PATH', opening_path)
      instance.set_attribute('MHD_DRESSING', 'HINGE_DIRECTION', 'flip_up')
      instance.set_attribute('MHD_DRESSING', 'DOOR_STYLE', style)
      [instance, instance.definition].each do |owner|
        owner.set_attribute('dynamic_attributes', 'open', '0')
        owner.set_attribute('dynamic_attributes', '_open_formulaunits', 'DEGREES')
        owner.set_attribute('dynamic_attributes', 'onclick', 'ANIMATE("open",0,-80)')
        owner.set_attribute('dynamic_attributes', '_rotx_formula', 'open')
        owner.set_attribute('dynamic_attributes', 'rotx', '0')
        owner.set_attribute('dynamic_attributes', '_onclick_state1', 0)
        owner.set_attribute('dynamic_attributes', '_hasbehaviors', 1.0)
      end
      ensure_persistent_dc_name(instance, 'MHD_DOOR')
      apply_edge_banding(instance, model, name, material, ['DOOR_PANEL','FLIP_UP'], width, depth, height) unless style == 'glass'
      orient_definition_textures(instance.definition, X_AXIS)
      instance
    end

    # ============================================================
    # حركة الجرار
    #
    # إصلاح خاص للضلفة الشمال:
    # Dynamic Components كان يعيد تقييم نفس Component عند نهاية ANIMATE،
    # ومع الحركة الموجبة للشمال كان LenX يتضخم بصريًا عند الوصول لليمين.
    # لذلك الشمال فقط أصبح له Wrapper حركة مستقل:
    # - جسم الضلفة الداخلي ثابت المقاس والمكان النسبي تمامًا.
    # - الـWrapper وحده يتحرك على X.
    # - الضغط على جسم الضلفة يشغّل parent!slide_move.
    #
    # اليمين والوسط يظلان على المنطق القديم المستقر بدون أي تغيير.
    # ============================================================
    def configure_sliding_animation(instance, x, y, z, width, height, side, travel, front_leaf)
      instance.set_attribute('MHD_DRESSING', 'GENERATED_COLUMN_DOOR', true)
      set_entity_function_role(instance, 'generated_door')
      instance.set_attribute('MHD_DRESSING', 'SLIDING_LEAF', side)
      instance.set_attribute('MHD_DRESSING', 'SLIDING_FRONT', front_leaf)
      closed_x_cm = x.to_f / 1.cm.to_f
      travel_cm = travel.to_f / 1.cm.to_f

      [instance, instance.definition].each do |owner|
        set_door_dc_value(owner, 'y', y.to_f / 1.cm.to_f)
        set_door_dc_value(owner, 'z', z.to_f / 1.cm.to_f)
        set_door_dc_value(owner, 'lenx', width.to_f / 1.cm.to_f)
        set_door_dc_value(owner, 'lenz', height.to_f / 1.cm.to_f)

        if side.to_s == 'left'
          # الشمال: الجسم نفسه لا يتحرك ولا يتغير مقاسه أثناء الأنيميشن.
          # موضعه المغلق يظل قيمة ثابتة؛ الحركة ستتم على Wrapper خارجي.
          set_door_dc_value(owner, 'x', closed_x_cm)
          owner.delete_attribute('dynamic_attributes', 'slide') rescue nil
          owner.delete_attribute('dynamic_attributes', '_slide_label') rescue nil
          owner.delete_attribute('dynamic_attributes', '_slide_units') rescue nil
          owner.set_attribute('dynamic_attributes', 'onclick', '')
          owner.set_attribute('dynamic_attributes', '_onclick_label', 'onClick')
          owner.set_attribute('dynamic_attributes', '_onclick_state1', 0)
        else
          # اليمين/الوسط: نفس المنطق القديم المستقر حرفيًا.
          owner.set_attribute('dynamic_attributes', 'x', (closed_x_cm / 2.54).to_s)
          owner.set_attribute('dynamic_attributes', 'slide', '0')
          owner.set_attribute('dynamic_attributes', '_slide_label', 'حركة الجرار')
          owner.set_attribute('dynamic_attributes', '_slide_units', 'CENTIMETERS')
          owner.set_attribute('dynamic_attributes', '_x_formula', format('%.6f+slide', closed_x_cm))
          owner.set_attribute('dynamic_attributes', '_inst__x_formula', format('%.6f+slide', closed_x_cm))
          owner.set_attribute('dynamic_attributes', '_x_formulaunits', 'CENTIMETERS')
          owner.set_attribute('dynamic_attributes', 'onclick', format('ANIMATE("slide",0,%.6f)', travel_cm))
          owner.set_attribute('dynamic_attributes', '_onclick_label', 'onClick')
          owner.set_attribute('dynamic_attributes', '_onclick_state1', 0)
        end

        owner.set_attribute('dynamic_attributes', '_hasbehaviors', 1.0)
        owner.set_attribute('dynamic_attributes', '_has_movetool_behaviors', 1.0)
        owner.set_attribute('dynamic_attributes', '_rotz_formula', '0')
        owner.set_attribute('dynamic_attributes', 'rotz', '0')
        owner.set_attribute('dynamic_attributes', 'hidden', '0')
        owner.set_attribute('dynamic_attributes', '_hidden_formula', 'FALSE')
        owner.set_attribute('dynamic_attributes', '_inst__hidden_formula', 'FALSE')
        owner.set_attribute('dynamic_attributes', '_inst_hidden', '0')
      end
      instance.hidden = false
      instance
    end

    # يضع الضلفة الشمال المولدة داخل Dynamic Wrapper للحركة فقط.
    # لا ننسخ/نعدل هندسة الضلفة؛ نعيد استخدام Definition الفريدة التي تم
    # تجهيزها بالفعل، وبالتالي الخامات والـOpenCutList وتركيب الزجاج تظل كما هي.
    def wrap_left_sliding_leaf(root, instance, travel, front_leaf)
      return instance unless instance && instance.valid?

      parent_entities = root.definition.entities
      original_definition = instance.definition
      original_transform = instance.transformation
      original_material = instance.material rescue nil
      original_name = instance.name.to_s
      travel_cm = travel.to_f / 1.cm.to_f

      motion_group = parent_entities.add_group
      leaf = motion_group.entities.add_instance(original_definition, original_transform)
      copy_instance_attributes(instance, leaf)
      leaf.material = original_material if original_material
      leaf.hidden = false
      leaf.name = original_name unless original_name.empty?

      # جسم الضلفة نفسه ثابت؛ النقر عليه يحرك الأب فقط.
      [leaf, leaf.definition].each do |owner|
        owner.set_attribute('dynamic_attributes', 'onclick', format('ANIMATE("parent!slide_move",0,%.6f)', travel_cm))
        owner.set_attribute('dynamic_attributes', '_onclick_label', 'onClick')
        owner.set_attribute('dynamic_attributes', '_onclick_state1', 0)
        owner.set_attribute('dynamic_attributes', '_hasbehaviors', 1.0)
        owner.set_attribute('dynamic_attributes', '_has_movetool_behaviors', 1.0)
      end

      instance.erase! if instance.valid?

      wrapper = motion_group.to_component
      wrapper.name = "__MHD_SLIDING_LEFT_MOTION_#{wrapper.entityID}"
      wrapper.definition.name = unique_name(Sketchup.active_model, '__MHD_SLIDING_LEFT_MOTION')
      wrapper.set_attribute('MHD_DRESSING', 'GENERATED_COLUMN_DOOR', true)
      wrapper.set_attribute('MHD_DRESSING', 'FUNCTION_ROLE', 'sliding_motion_wrapper')
      wrapper.set_attribute('MHD_DRESSING', 'SLIDING_LEAF', 'left')
      wrapper.set_attribute('MHD_DRESSING', 'SLIDING_FRONT', front_leaf)

      [wrapper, wrapper.definition].each do |owner|
        owner.set_attribute('dynamic_attributes', 'slide_move', '0')
        owner.set_attribute('dynamic_attributes', '_slide_move_label', 'حركة الجرار')
        owner.set_attribute('dynamic_attributes', '_slide_move_units', 'CENTIMETERS')
        owner.set_attribute('dynamic_attributes', 'x', '0')
        owner.set_attribute('dynamic_attributes', '_x_formula', 'slide_move')
        owner.set_attribute('dynamic_attributes', '_inst__x_formula', 'slide_move')
        owner.set_attribute('dynamic_attributes', '_x_formulaunits', 'CENTIMETERS')
        owner.set_attribute('dynamic_attributes', 'onclick', format('ANIMATE("slide_move",0,%.6f)', travel_cm))
        owner.set_attribute('dynamic_attributes', '_onclick_label', 'onClick')
        owner.set_attribute('dynamic_attributes', '_onclick_state1', 0)
        owner.set_attribute('dynamic_attributes', '_hasbehaviors', 1.0)
        owner.set_attribute('dynamic_attributes', '_has_movetool_behaviors', 1.0)
      end

      ensure_persistent_dc_name(wrapper, 'MHD_SLIDING_LEFT_MOTION')
      wrapper
    end

    # بعض ضلف الزجاج المصدر تحمل قيمة Hidden على مستوى الـInstance بجانب
    # المعادلة العادية. الـDC يعيد تطبيقها بعد redraw فتختفي النسخة الجديدة.
    # نثبت ظهور الأب المولد فقط، من غير تغيير أي قطعة أو Formula داخل الزجاج.
    def reveal_generated_sliding_door(instance)
      [instance, instance.definition].each do |owner|
        owner.set_attribute('dynamic_attributes', 'hidden', '0')
        owner.set_attribute('dynamic_attributes', '_hidden_formula', 'FALSE')
        owner.set_attribute('dynamic_attributes', '_inst__hidden_formula', 'FALSE')
        owner.set_attribute('dynamic_attributes', '_inst_hidden', '0')
      end
      instance.hidden = false
      instance
    end

    # ضلفة الجرار الخشب تُنشأ كـDynamic Component مستقل بمحور X ثابت.
    def create_sliding_door(root, name, x, y, z, width, height, material, side, travel, front_leaf)
      model = Sketchup.active_model
      door_thickness = 1.8.cm
      instance = add_box_without_wall_relief(root.definition.entities, model, name,
                                             x, y, z, width, door_thickness, height,
                                             material, ['DOOR_PANEL','SLIDING_DOOR'])
      configure_sliding_animation(instance, x, y, z, width, height, side, travel, front_leaf)
      side.to_s == 'left' ? wrap_left_sliding_leaf(root, instance, travel, front_leaf) : instance
    end

    # الزجاج يظل نسخة كاملة من ضلفة الزجاج الأصلية.
    # للشمال فقط نضع النسخة الكاملة داخل Wrapper الحركة بعد تثبيت مقاسها.
    def create_sliding_glass_door(root, source_record, name, x, y, z, width, height, side, travel, front_leaf)
      instance = copy_dynamic_glass_door(root, source_record, name, x, z, width, height,
                                         'left', "sliding.#{side}")
      instance.set_attribute('MHD_DRESSING', 'DOOR_STYLE', 'glass')
      configure_sliding_animation(instance, x, y, z, width, height, side, travel, front_leaf)
      redraw_dc(instance)
      reveal_generated_sliding_door(instance)
      side.to_s == 'left' ? wrap_left_sliding_leaf(root, instance, travel, front_leaf) : instance
    end

    def build_sliding_doors(root, material, sources)
      context = @sliding_context
      return unless context
      leaf_count = context['leaf_count'].to_i == 3 ? 3 : 2
      style = context['style'].to_s == 'glass' ? 'glass' : 'wood'
      base_leaf_width = context['coverage_width'].to_f / leaf_count.to_f
      leaf_width = base_leaf_width + context['width_extra'].to_f
      leaf_height = context['target_height'].to_f
      raise 'عرض أو ارتفاع الضلفة الجرار غير صحيح.' if leaf_width <= 1.cm || leaf_height <= 1.cm
      raise 'زيادة عرض الضلفة الجرار أكبر من المساحة المتاحة.' if leaf_width >= context['coverage_width'].to_f - 1.cm
      gap = context['track_gap'].to_f
      door_thickness = 1.8.cm
      # محور Y الموجب داخل عمق الدولاب: صفر يعني أن وجه الضلفة الأمامية
      # على وش الشاسيه تمامًا، وكل Setback يدخلها أكثر إلى الداخل.
      front_y = context['front_setback'].to_f
      rear_y = front_y + door_thickness + gap
      x0 = context['coverage_x'].to_f
      z0 = context['target_z'].to_f
      glass_source = sources[['glass', 'left']]
      raise 'لم أجد ضلفة زجاج مصدر لإنشاء الجرار.' if style == 'glass' && !glass_source
      make_leaf = lambda do |name, leaf_x, leaf_y, side, travel, is_front|
        tags = ['DOOR_PANEL', 'SLIDING_DOOR']
        tags << 'GLASS_DOOR' if style == 'glass'
        check_board_limit(name, leaf_width, door_thickness, leaf_height, material, tags)
        if style == 'glass'
          create_sliding_glass_door(root, glass_source, name, leaf_x, leaf_y, z0,
                                    leaf_width, leaf_height, side, travel, is_front)
        else
          create_sliding_door(root, name, leaf_x, leaf_y, z0,
                              leaf_width, leaf_height, material, side, travel, is_front)
        end
      end

      if leaf_count == 3
        # الضلفة الوسطى في المجرى الأمامي، واليمين والشمال في المجرى الخلفي.
        left_x = x0
        middle_x = x0 + (context['coverage_width'].to_f - leaf_width) / 2.0
        right_x = x0 + context['coverage_width'].to_f - leaf_width
        make_leaf.call('ضلفة جرار شمال', left_x, rear_y, 'left', middle_x - left_x, false)
        make_leaf.call('ضلفة جرار وسط', middle_x, front_y, 'middle', left_x - middle_x, true)
        make_leaf.call('ضلفة جرار يمين', right_x, rear_y, 'right', middle_x - right_x, false)
      else
        left_is_front = context['front_leaf'].to_s == 'left'
        travel = context['coverage_width'].to_f - leaf_width
        make_leaf.call('ضلفة جرار شمال', x0,
                       left_is_front ? front_y : rear_y, 'left', travel, left_is_front)
        make_leaf.call('ضلفة جرار يمين', x0 + context['coverage_width'].to_f - leaf_width,
                       left_is_front ? rear_y : front_y, 'right', -travel, !left_is_front)
      end
    end

    def set_door_hinge_overlay(door, overlay)
      return door unless door && door.valid?
      door.set_attribute('MHD_DRESSING', 'HINGE_OVERLAY', overlay.to_s)
      door
    end

    def set_door_hinge_count(door, count, fallback = 4)
      return door unless door && door.valid?
      value = count.to_i
      value = fallback.to_i if value <= 0
      value = [[value, 1].max, 12].min
      door.set_attribute('MHD_DRESSING', 'HINGE_COUNT', value)
      door
    end

    def door_visually_open?(door, closed_xaxis)
      current_xaxis = door.transformation.xaxis
      return false if current_xaxis.length <= 0.0001
      current_xaxis.normalize!
      reference = Geom::Vector3d.new(*closed_xaxis)
      return false if reference.length <= 0.0001
      reference.normalize!
      current_xaxis.dot(reference).abs < 0.98
    rescue
      false
    end

    def flip_up_door_visually_open?(door, closed_zaxis)
      current_zaxis = door.transformation.zaxis
      return false if current_zaxis.length <= 0.0001
      current_zaxis.normalize!
      reference = Geom::Vector3d.new(*closed_zaxis)
      return false if reference.length <= 0.0001
      reference.normalize!
      current_zaxis.dot(reference).abs < 0.98
    rescue
      false
    end

    def sync_hinge_accessories(door)
      return if @syncing_hinge_motion
      links = @hinge_motion_links && @hinge_motion_links[door.object_id]
      return unless links && door.valid?

      direction = door.get_attribute('MHD_DRESSING', 'HINGE_DIRECTION').to_s
      open = if direction == 'flip_up'
               dc_open = dc_effective_value(door, 'open', '0').to_f.abs
               dc_open > 1.0 || flip_up_door_visually_open?(door, links[:closed_zaxis])
             else
               door_visually_open?(door, links[:closed_xaxis])
             end

      # أهم تحسين للأداء:
      # لا نعيد Transformation للإكسسوارات كل 0.12 ثانية وهي ثابتة.
      # نتحرك فقط لحظة تغير الحالة من مقفول إلى مفتوح أو العكس.
      return if links.key?(:last_open_state) && links[:last_open_state] == open

      @syncing_hinge_motion = true
      links[:accessories].each do |record|
        instance = record[:instance]
        next unless instance && instance.valid?
        closed_transform = Geom::Transformation.new(record[:closed_transform])
        shift = record[:open_y_shift].to_f
        shift = 6.1.cm if shift <= 0
        y_shift = open ? -shift : 0.0
        instance.transformation = Geom::Transformation.translation([0, y_shift, 0]) * closed_transform
      end
      links[:last_open_state] = open
    ensure
      @syncing_hinge_motion = false
    end

    def ensure_hinge_motion_monitor
      return if @hinge_motion_monitor_timer

      # الـTimer مطلوب للقلاب فقط لأن بعض Redraws للـDC لا تطلق EntityObserver.
      # الضلف اليمين/الشمال تظل على الـObserver الطبيعي بدون Polling مستمر.
      @hinge_motion_monitor_timer = UI.start_timer(0.25, true) do
        links = @hinge_motion_links
        next unless links.is_a?(Hash) && !links.empty?

        active_flip_links = links.values.select do |link|
          door = link[:door]
          door && door.valid? &&
            door.get_attribute('MHD_DRESSING', 'HINGE_DIRECTION').to_s == 'flip_up'
        end

        active_flip_links.each { |link| sync_hinge_accessories(link[:door]) }
      end
    rescue
      @hinge_motion_monitor_timer = nil
    end

    # اسم DC فريد وثابت داخل الملف، صالح للاستخدام في معادلات
    # ComponentName!attribute بين العناصر الموجودة في نفس الـParent.
    def ensure_persistent_dc_name(entity, prefix)
      current = entity.get_attribute('MHD_DRESSING', 'PERSISTENT_DC_NAME').to_s
      return current unless current.empty?

      pid = entity.respond_to?(:persistent_id) ? entity.persistent_id.to_i : 0
      pid = entity.object_id if pid <= 0
      name = "#{prefix}_#{pid}".gsub(/[^A-Za-z0-9_]/, '_')

      entity.set_attribute('MHD_DRESSING', 'PERSISTENT_DC_NAME', name)
      [entity, entity.definition].each do |owner|
        owner.set_attribute('dynamic_attributes', '_name', name)
        owner.set_attribute('dynamic_attributes', '_hasbehaviors', 1.0)
        owner.set_attribute('dynamic_attributes', '_has_movetool_behaviors', 1.0)
      end
      name
    rescue
      "#{prefix}_#{entity.object_id}"
    end

    # المفصلة/الباكم يصبح Dynamic Component مستقلًا يقرأ قيمة open
    # مباشرة من الضلفة الشقيقة. هكذا تظل الحركة محفوظة داخل SKP نفسه.
    def configure_persistent_hinge_accessory_dc(door, accessory, open_y_shift = 6.1.cm)
      return accessory unless door && accessory && door.valid? && accessory.valid?

      door_name = ensure_persistent_dc_name(door, 'MHD_DOOR')
      direction = door.get_attribute('MHD_DRESSING', 'HINGE_DIRECTION').to_s
      max_angle = direction == 'flip_up' ? 80.0 : 90.0

      closed_y_cm = accessory.transformation.origin.y.to_f / 1.cm.to_f
      shift_cm = open_y_shift.to_f / 1.cm.to_f

      # open قد يكون سالبًا في القلاب، لذلك ABS.
      y_formula = format(
        '%.6f-(ABS(%s!open)/%.6f)*%.6f',
        closed_y_cm, door_name, max_angle, shift_cm
      )

      [accessory, accessory.definition].each do |owner|
        owner.set_attribute('dynamic_attributes', 'y', (closed_y_cm / 2.54).to_s)
        owner.set_attribute('dynamic_attributes', '_y_formula', y_formula)
        owner.set_attribute('dynamic_attributes', '_inst__y_formula', y_formula)
        owner.set_attribute('dynamic_attributes', '_y_formulaunits', 'CENTIMETERS')
        owner.set_attribute('dynamic_attributes', '_hasbehaviors', 1.0)
        owner.set_attribute('dynamic_attributes', '_has_movetool_behaviors', 1.0)
      end
      accessory.set_attribute('MHD_DRESSING', 'PERSISTENT_MOTION_MODE', 'DC_FORMULA')
      accessory
    rescue => error
      puts "MHD persistent hinge DC error: #{error.message}" rescue nil
      accessory
    end

    # المجرى يقرأ حركة الدرج نفسها:
    # Y يتقدم مع الدرج.
    # LenY يزيد بنفس مسافة الفتح، لذلك يظل آخر المجرى ثابتًا عند الخلف.
    def configure_persistent_drawer_slide_dc(drawer, slide_pair, chassis_depth)
      return slide_pair unless drawer && slide_pair && drawer.valid? && slide_pair.valid?

      drawer_name = ensure_persistent_dc_name(drawer, 'MHD_DRAWER')
      closed_y_cm = slide_pair.transformation.origin.y.to_f / 1.cm.to_f
      closed_depth_cm = [chassis_depth.to_f / 1.cm.to_f, 0.01].max

      y_formula = format('%.6f+%s!u00animdesp', closed_y_cm, drawer_name)
      leny_formula = format('%.6f-%s!u00animdesp', closed_depth_cm, drawer_name)

      [slide_pair, slide_pair.definition].each do |owner|
        owner.set_attribute('dynamic_attributes', '_name', "MHD_SLIDE_#{slide_pair.persistent_id rescue slide_pair.object_id}")
        owner.set_attribute('dynamic_attributes', 'y', (closed_y_cm / 2.54).to_s)
        owner.set_attribute('dynamic_attributes', '_y_formula', y_formula)
        owner.set_attribute('dynamic_attributes', '_inst__y_formula', y_formula)
        owner.set_attribute('dynamic_attributes', '_y_formulaunits', 'CENTIMETERS')

        owner.set_attribute('dynamic_attributes', 'leny', (closed_depth_cm / 2.54).to_s)
        owner.set_attribute('dynamic_attributes', '_leny_formula', leny_formula)
        owner.set_attribute('dynamic_attributes', '_inst__leny_formula', leny_formula)
        owner.set_attribute('dynamic_attributes', '_leny_formulaunits', 'CENTIMETERS')

        owner.set_attribute('dynamic_attributes', '_hasbehaviors', 1.0)
        owner.set_attribute('dynamic_attributes', '_has_movetool_behaviors', 1.0)
      end

      slide_pair.set_attribute('MHD_DRESSING', 'PERSISTENT_MOTION_MODE', 'DC_FORMULA')
      slide_pair
    rescue => error
      puts "MHD persistent drawer slide DC error: #{error.message}" rescue nil
      slide_pair
    end

    def register_hinge_motion(door, accessory, open_y_shift = 6.1.cm)
      # أولًا: الحركة الدائمة المخزنة في الملف نفسه.
      configure_persistent_hinge_accessory_dc(door, accessory, open_y_shift)

      # Observer يظل فقط كـFallback أثناء جلسة Ruby الحالية.
      @hinge_motion_links ||= {}

      link_id = door.get_attribute('MHD_DRESSING', 'MOTION_LINK_ID').to_s
      if link_id.empty?
        link_id = new_motion_link_id('HINGE', door)
        door.set_attribute('MHD_DRESSING', 'MOTION_LINK_ID', link_id)
      end

      link = @hinge_motion_links[door.object_id]
      unless link
        xaxis = door.transformation.xaxis
        xaxis.normalize! if xaxis.length > 0.0001
        zaxis = door.transformation.zaxis
        zaxis.normalize! if zaxis.length > 0.0001
        closed_xaxis = [xaxis.x, xaxis.y, xaxis.z]
        closed_zaxis = [zaxis.x, zaxis.y, zaxis.z]
        motion_json_write(door, 'MOTION_CLOSED_XAXIS', closed_xaxis)
        motion_json_write(door, 'MOTION_CLOSED_ZAXIS', closed_zaxis)

        observer = HingeDoorMotionObserver.new
        door.add_observer(observer)
        @hinge_motion_observers ||= {}
        @hinge_motion_observers[door.object_id] = observer
        link = {
          door: door,
          closed_xaxis: closed_xaxis,
          closed_zaxis: closed_zaxis,
          accessories: []
        }
        @hinge_motion_links[door.object_id] = link
      end

      closed_transform = accessory.transformation.to_a
      accessory.set_attribute('MHD_DRESSING', 'MOTION_LINK_ID', link_id)
      accessory.set_attribute('MHD_DRESSING', 'MOTION_KIND', 'HINGE_ACCESSORY')
      accessory.set_attribute(
        'MHD_DRESSING', 'MOTION_OPEN_Y_SHIFT_CM',
        open_y_shift.to_f / 1.cm.to_f
      )
      motion_json_write(accessory, 'MOTION_CLOSED_TRANSFORM', closed_transform)

      link[:accessories] << {
        instance: accessory,
        closed_transform: closed_transform,
        open_y_shift: open_y_shift.to_f
      }

      # افتح الـPolling فقط للقلاب. الضلف الجانبية لا تحتاجه.
      if door.get_attribute('MHD_DRESSING', 'HINGE_DIRECTION').to_s == 'flip_up'
        ensure_hinge_motion_monitor
      end
      accessory
    end

    def add_hinge_accessory(parent, door, definition, point, direction, overlay, number, mirrored = false)
      # اتجاه مفصلات الضلف يظل كما كان؛ الـMirror الإضافي يُستخدم فقط
      # عند الاعتماد على موديل الجهة المقابلة كبديل، وليس كفليب عام.
      orientation = mirrored ? Geom::Transformation.scaling(ORIGIN, -1.0, 1.0, 1.0) : Geom::Transformation.new
      # المفصلة عنصر مستقل لا يدور ولا يتغير مقاسه مع الضلفة. موضع الغلق
      # هو المرجع، والمراقب يحركها فقط -6.1 سم على Y عند فتح الضلفة.
      x_offset = direction.to_s == 'right' ? 1.7.cm : -1.7.cm

      # مفصلة العقرب 180 فقط تحتاج تصحيح إضافي على محور X:
      # سدّة يمين  => حرّك المفصلة شمال 2.4 سم.
      # سدّة شمال => حرّك المفصلة يمين 2.4 سم.
      scorpion_x_correction = if overlay.to_s == 'scorpion_180'
        direction.to_s == 'right' ? -2.4.cm : 2.4.cm
      else
        0.0
      end

      closed_point = Geom::Point3d.new(
        point.x + x_offset + scorpion_x_correction,
        point.y,
        point.z - 3.2.cm
      )
      transform = Geom::Transformation.translation(closed_point.to_a) * orientation
      instance = parent.add_instance(definition, transform)
      side_ar = direction.to_s == 'right' ? 'يمين' : 'شمال'
      overlay_ar = case overlay.to_s
                   when 'half' then 'نص ركبة'
                   when 'knee' then 'ركبة'
                   when 'scorpion_180' then 'عقرب 180'
                   else 'عدلة'
                   end
      instance.name = qualified_part_name("مفصلة #{overlay_ar} #{side_ar} #{number}")
      instance.set_attribute('MHD_DRESSING', 'JOINERY_ACCESSORY', true)
      instance.set_attribute('MHD_DRESSING', 'TYPE', 'HINGE_ACCESSORY')
      instance.set_attribute('MHD_DRESSING', 'HINGE_DIRECTION', direction.to_s)
      instance.set_attribute('MHD_DRESSING', 'HINGE_OVERLAY', overlay.to_s)
      set_part_badges(definition, ['HARDWARE','ACCESSORY','HINGE'])
      definition.set_attribute('ladb_opencutlist', 'cumulable', 2)
      register_hinge_motion(door, instance)
    end

    # إكسسوار مفصلة القلاب الخشب:
    # نستخدم مفصلة عدلة نفسها، لكن نلفها 90 درجة داخل مستوى الضلفة
    # حتى يصبح اتجاهها ناحية القرصة العلوية بدل الجنب.
    def add_flip_up_hinge_accessory(parent, door, definition, point, number, mirrored = false)
      mirror = mirrored ? Geom::Transformation.scaling(ORIGIN, -1.0, 1.0, 1.0) : Geom::Transformation.new
      rotate = Geom::Transformation.rotation(ORIGIN, Y_AXIS, Math::PI / 2.0)
      orientation = rotate * mirror

      # نفس أبعاد إزاحة المفصلة العادية بعد تدويرها:
      # 3.2 سم على اتجاه عرض المفصلة، و1.7 سم ناحية القرصة العلوية.
      closed_point = Geom::Point3d.new(
        point.x - 3.2.cm,
        point.y,
        point.z + 1.7.cm
      )

      transform = Geom::Transformation.translation(closed_point.to_a) * orientation
      instance = parent.add_instance(definition, transform)
      instance.name = qualified_part_name("مفصلة عدلة قلاب #{number}")
      instance.set_attribute('MHD_DRESSING', 'JOINERY_ACCESSORY', true)
      instance.set_attribute('MHD_DRESSING', 'TYPE', 'HINGE_ACCESSORY')
      instance.set_attribute('MHD_DRESSING', 'HINGE_DIRECTION', 'flip_up')
      instance.set_attribute('MHD_DRESSING', 'HINGE_OVERLAY', 'straight')
      set_part_badges(definition, ['HARDWARE','ACCESSORY','HINGE'])
      definition.set_attribute('ladb_opencutlist', 'cumulable', 2)

      # القلاب يدور حول X، لذلك register_hinge_motion يخزن أيضًا Z-axis
      # ويستخدمه لاكتشاف الفتح. بعد الفتح تتحرك المفصلة لقدام -6.1 سم
      # مثل مفصلات الضلف اليمين/الشمال.
      register_hinge_motion(door, instance)
    end

    # باكم القلاب - النسخة الأولى: دراع واحد أقصى شمال الفراغ.
    # موديل المصدر يُستخدم بدون Scale. نلفه 90° حول Z ليعمل على مستوى Y/Z
    # بجانب الجنب الشمال. في الغلق يكون مرجعه 13 سم من وش الشاسيه الخلفي،
    # وعند الفتح يتحرك لقدام إلى 27.3 سم، أي 14.3 سم.
    def add_flip_up_push_lift_left(root, door, opening_x, opening_top_z, cabinet_depth, data, number = 1)
      return nil unless root && door && door.valid?
      model = Sketchup.active_model
      definition = push_up_lift_definition(model)

      # ملف الباكم أنت مجهزه على الأكسات والـOrigin الصحيحين.
      # لذلك نستخدم الـOrigin نفسه كنقطة تركيب، بدون Bounds correction
      # وبدون Rotation / Flip / Mirror.
      #
      # وضع الغلق:
      # X = أقصى شمال الفراغ.
      # Y = وش الشاسيه (0).
      # Z = 27.3 سم تحت القرصة العلوية.
      tx = opening_x.to_f
      ty = 0.0
      # نزّل دراع الباكم 1.7 سم إضافية على محور Z.
      tz = opening_top_z.to_f - 27.3.cm - 1.7.cm

      instance = root.definition.entities.add_instance(
        definition,
        Geom::Transformation.translation([tx, ty, tz])
      )
      instance.name = qualified_part_name("باكم ضلفة قلاب شمال #{number}")
      instance.set_attribute('MHD_DRESSING', 'JOINERY_ACCESSORY', true)
      instance.set_attribute('MHD_DRESSING', 'TYPE', 'PUSH_UP_LIFT')
      instance.set_attribute('MHD_DRESSING', 'GENERATED_FLIP_UP_LIFT', true)
      instance.set_attribute('MHD_DRESSING', 'LIFT_SIDE', 'left')
      instance.set_attribute('MHD_DRESSING', 'LIFT_CLOSED_Y_CM', 0.0)
      instance.set_attribute('MHD_DRESSING', 'LIFT_OPEN_Y_CM', -13.0)
      instance.set_attribute('MHD_DRESSING', 'LIFT_TOP_Z_OFFSET_CM', 27.3)
      set_part_badges(definition, ['HARDWARE','ACCESSORY','PUSH_UP_LIFT'])
      definition.set_attribute('ladb_opencutlist', 'cumulable', 2)

      # الحركة مع القلاب: من وش الشاسيه إلى الأمام 13 سم على محور Y.
      register_hinge_motion(door, instance, 13.0.cm)
      instance
    end

    # باكم القلاب - الدراع اليمين:
    # نفس موديل الشمال لكن Flip على محور X، ويتم وضعه أقصى يمين الفراغ.
    def add_flip_up_push_lift_right(root, door, opening_x, opening_width, opening_top_z, cabinet_depth, data, number = 2)
      return nil unless root && door && door.valid?
      model = Sketchup.active_model
      definition = push_up_lift_definition(model)

      # Flip X حول Origin الموديل نفسه، بدون أي Rotation إضافي.
      flip_x = Geom::Transformation.scaling(ORIGIN, -1.0, 1.0, 1.0)

      # الـOrigin في ملف الباكم هو نقطة التركيب المرجعية.
      # بعد Flip X نضعه عند أقصى يمين الفراغ، وعلى نفس Y/Z للشمال.
      tx = opening_x.to_f + opening_width.to_f
      ty = 0.0
      tz = opening_top_z.to_f - 27.3.cm - 1.7.cm

      instance = root.definition.entities.add_instance(
        definition,
        Geom::Transformation.translation([tx, ty, tz]) * flip_x
      )
      instance.name = qualified_part_name("باكم ضلفة قلاب يمين #{number}")
      instance.set_attribute('MHD_DRESSING', 'JOINERY_ACCESSORY', true)
      instance.set_attribute('MHD_DRESSING', 'TYPE', 'PUSH_UP_LIFT')
      instance.set_attribute('MHD_DRESSING', 'GENERATED_FLIP_UP_LIFT', true)
      instance.set_attribute('MHD_DRESSING', 'LIFT_SIDE', 'right')
      instance.set_attribute('MHD_DRESSING', 'LIFT_CLOSED_Y_CM', 0.0)
      instance.set_attribute('MHD_DRESSING', 'LIFT_OPEN_Y_CM', -13.0)
      instance.set_attribute('MHD_DRESSING', 'LIFT_TOP_Z_OFFSET_CM', 27.3)
      set_part_badges(definition, ['HARDWARE','ACCESSORY','PUSH_UP_LIFT'])
      definition.set_attribute('ladb_opencutlist', 'cumulable', 2)

      register_hinge_motion(door, instance, 13.0.cm)
      instance
    end

    def clear_hinge_accessory_containers(entities)
      # النسخة الجديدة تحفظ المفصلات مباشرة بجوار الضلف في نفس Parent
      # حتى تعمل معادلات MHD_DOOR_x!open بعد إعادة فتح الملف.
      entities.grep(Sketchup::ComponentInstance).to_a.each do |instance|
        next unless instance.valid?
        next unless instance.get_attribute('MHD_DRESSING', 'TYPE').to_s == 'HINGE_ACCESSORY'
        instance.erase!
      end

      # تنظيف الحاويات القديمة للملفات السابقة فقط.
      entities.grep(Sketchup::Group).to_a.each do |group|
        next unless group.valid?
        type = group.get_attribute('MHD_DRESSING', 'TYPE').to_s
        if type == 'MHD_HINGE_ACCESSORIES'
          group.erase!
        elsif type == INTERIOR_MARK
          clear_hinge_accessory_containers(group.entities)
        end
      end
    end

    def hinge_accessory_entities(root)
      # لازم المفصلة والضلفة يكونوا Siblings في نفس Parent حتى تعمل
      # معادلة Dynamic Component: MHD_DOOR_x!open بدون أي Ruby.
      root.definition.entities
    end

    def build_hinge_cup_drilling(root, data)
      # مهم في الحالة المختلطة: نظام الجرار قد يغطي بعض الأعمدة فقط، بينما
      # الأعمدة خارج نطاق الجرار تظل ضلفاً مفصلية عادية. لذلك لا نوقف مرحلة
      # المفصلات لمجرد أن door_system العام = sliding؛ السجل بالأسفل يلتقط
      # فقط الضلف المولدة ذات HINGE_DIRECTION = left/right/flip_up، وبالتالي
      # ضلف الجرار نفسها لا تدخل في التخريم أو إكسسوار المفصلات.
      return unless %w[hinged sliding].include?(data['door_system'].to_s)

      # مهم جدًا:
      # الباكم يتسجل في @hinge_motion_links وقت إنشاء الضلفة القلاب.
      # كان الكود هنا يمسح الـHash بالكامل قبل إضافة المفصلات، فيضيع رابط
      # حركة الباكم؛ لذلك المفصلة تتحرك والباكم يظل ثابتًا.
      #
      # نحافظ على روابط الإكسسوارات السليمة (خصوصًا PUSH_UP_LIFT)، ونحذف
      # فقط الروابط القديمة/الممسوحة من دورة إنشاء سابقة.
      @hinge_motion_links ||= {}
      @hinge_motion_observers ||= {}
      @hinge_motion_links.delete_if do |_door_id, link|
        door = link && link[:door]
        invalid_door = !(door && door.valid?)
        unless invalid_door
          link[:accessories] = Array(link[:accessories]).select do |record|
            inst = record && record[:instance]
            inst && inst.valid?
          end
        end
        invalid_door
      end

      clear_hinge_accessory_containers(root.definition.entities)

      # بعد مسح حاوية المفصلات القديمة، نظف أي Records أصبحت invalid،
      # لكن اترك الباكم لأنه مستقل عن حاوية المفصلات.
      @hinge_motion_links.each_value do |link|
        link[:accessories] = Array(link[:accessories]).select do |record|
          inst = record && record[:instance]
          inst && inst.valid?
        end
      end

      pending_accessories = []
      diameter = [data['hinge_cup_diameter'].to_f, 0.1].max.cm
      radius = diameter / 2.0
      requested_depth = [data['hinge_cup_depth'].to_f, 0.1].max.cm
      edge_center = [data['hinge_cup_edge_center'].to_f, 0.1].max.cm
      default_hinge_count = [[data['hinge_count'].to_i, 1].max, 12].min
      end_offset = [data['hinge_end_offset'].to_f, 0.1].max.cm
      collision_offset = [data['hinge_collision_offset'].to_f, 0.0].max.cm

      records = root.definition.entities.grep(Sketchup::ComponentInstance).filter_map do |door|
        next unless door.get_attribute('MHD_DRESSING', 'GENERATED_COLUMN_DOOR')
        style = door.get_attribute('MHD_DRESSING', 'DOOR_STYLE').to_s
        next unless %w[wood glass].include?(style)
        direction = door.get_attribute('MHD_DRESSING', 'HINGE_DIRECTION').to_s
        # المفصلي العادي: left / right.
        # القلاب الخشب: flip_up، ونفس أرقام تخريم المفصلة لكن التوزيع أفقي
        # على الحافة العلوية ناحية القرصة.
        next unless %w[left right flip_up].include?(direction)
        # القلاب الزجاج يدخل نفس مسار الإكسسوار، لكن بدون تخريم.
        # سابقًا كان مستبعدًا بالكامل هنا، لذلك ظهر الباكم فقط.
        if direction == 'flip_up' && style == 'glass' &&
           !door.get_attribute('MHD_DRESSING', 'FLIP_UP_X0').nil?
          # القلاب الزجاج: استخدم القيم التي حفظناها وقت الإنشاء.
          # هذا يمنع Bounds الخاص بالـDC الزجاجي من إرسال المفصلات لمكان خاطئ.
          x0 = door.get_attribute('MHD_DRESSING', 'FLIP_UP_X0').to_f
          x1 = door.get_attribute('MHD_DRESSING', 'FLIP_UP_X1').to_f
          z0 = door.get_attribute('MHD_DRESSING', 'FLIP_UP_Z0').to_f
          z1 = door.get_attribute('MHD_DRESSING', 'FLIP_UP_Z1').to_f
          hinge_y = door.get_attribute('MHD_DRESSING', 'FLIP_UP_Y').to_f

          # نعطي سمكًا افتراضيًا فقط للحسابات العامة؛ لا يوجد تخريم زجاج.
          y0 = hinge_y - 1.8.cm
          y1 = hinge_y
        else
          points = (0..7).map { |i| door.definition.bounds.corner(i).transform(door.transformation) }
          x0,x1 = points.map(&:x).minmax
          y0,y1 = points.map(&:y).minmax
          z0,z1 = points.map(&:z).minmax
        end
        next if x1-x0 <= diameter || z1-z0 <= diameter
        saved_hinge_count = door.get_attribute('MHD_DRESSING', 'HINGE_COUNT').to_i
        {
          door: door, direction: direction, style: style,
          hinge_count: saved_hinge_count > 0 ? [[saved_hinge_count, 1].max, 12].min : default_hinge_count,
          overlay: door.get_attribute('MHD_DRESSING', 'HINGE_OVERLAY').to_s == 'half' ? 'half' : 'straight',
          filler_hinge_type: door.get_attribute('MHD_DRESSING', 'FILLER_HINGE_TYPE').to_s,
          x0: x0, x1: x1, y0: y0, y1: y1, z0: z0, z1: z1,
          hinge_x: direction == 'right' ? x1 : (direction == 'left' ? x0 : nil),
          center_x: (x0+x1)/2.0,
          sloped_hinge_top_z: door.get_attribute('MHD_DRESSING', 'SLOPED_HINGE_TOP_Z')
        }
      end

      # لا ننشئ حاوية مفصلات ولا ندخل مرحلة التخريم إذا لم توجد ضلفة
      # مفصلية مولدة فعلًا داخل الدولاب.
      return if records.empty?

      records.each do |record|
        hinge_count = record[:hinge_count] > 0 ? record[:hinge_count] : default_hinge_count

        if record[:direction] == 'flip_up'
          # القلاب الخشب: نفس قطر/عمق/بعد وش المفصلة ونفس عدد المفصلات.
          # الاختلاف الوحيد أن خط المفصلات عند أعلى الضلفة ناحية القرصة،
          # والمراكز تتوزع جنب بعض أفقيًا على محور X.
          width = record[:x1] - record[:x0]
          safe_margin = [[end_offset, radius+0.1.cm].max, width/2.0].min
          x_positions = if hinge_count == 1
            [(record[:x0] + record[:x1]) / 2.0]
          else
            usable = [width - safe_margin * 2.0, 0.0].max
            step = usable / (hinge_count - 1).to_f
            hinge_count.times.map { |index| record[:x0] + safe_margin + step * index }
          end

          # مركز وش المفصلة يبعد عن الحافة العلوية بنفس hinge_cup_edge_center
          # المستخدم في الضلفة اليمين/الشمال.
          z = record[:z1] - edge_center
          y = record[:y1]
          actual_depth = [requested_depth, record[:y1] - record[:y0] - 0.1.mm].min
          next if record[:style] == 'wood' && actual_depth <= 0.1.mm

          # القلاب يستخدم مفصلة عدلة فقط، ونقلب اتجاه الإكسسوار 90 درجة.
          hinge_definition, mirrored = hinge_accessory_definition(
            Sketchup.active_model, 'left', 'straight'
          )

          accessory_count = 0
          cup_count = 0
          x_positions.uniq.each_with_index do |x, index|
            point = Geom::Point3d.new(x, y, z)

            ready_for_accessory = if record[:style] == 'wood'
              drilled = drill_round_hole(
                record[:door], record[:door].transformation, point, Y_AXIS.reverse,
                actual_depth, diameter, 'HINGE_CUP', index + 1
              )
              cup_count += 1 if drilled
              drilled
            else
              # زجاج: إكسسوار فقط بدون أي حفر في الضلفة.
              true
            end

            if ready_for_accessory
              pending_accessories << [
                record[:door], hinge_definition, point,
                'flip_up', 'straight', index + 1, mirrored
              ]
              accessory_count += 1
            end
          end
          record[:door].set_attribute('MHD_DRESSING', 'HINGE_CUP_COUNT', record[:style] == 'wood' ? cup_count : 0)
          record[:door].set_attribute('MHD_DRESSING', 'HINGE_ACCESSORY_COUNT', accessory_count)
          record[:door].set_attribute('MHD_DRESSING', 'HINGE_STAGGERED_DOWN', false)
          next
        end

        # التعارض يحدث عندما تتقابل ضلفة يمين وضلفة شمال على نفس القاطع
        # وفي نفس مدى الارتفاع. نزيح الضلفة الواقعة يمين القاطع إلى أسفل.
        shared = records.select do |other|
          # منطق تعارض المفصلات يخص الضلف اليمين/الشمال فقط.
          # القلاب له خط مفصلات أفقي أعلى الضلفة ولا يملك hinge_x،
          # لذلك يجب استبعاده من المقارنة حتى لا يحدث nil - value.
          next false unless %w[left right].include?(other[:direction])
          next false unless %w[left right].include?(record[:direction])
          next false if other.equal?(record) || other[:direction] == record[:direction]
          next false if other[:hinge_x].nil? || record[:hinge_x].nil?
          same_hinge_line = (other[:hinge_x] - record[:hinge_x]).abs <= 0.6.cm
          vertical_overlap = [other[:z1],record[:z1]].min - [other[:z0],record[:z0]].max > diameter
          same_hinge_line && vertical_overlap
        end
        stagger_down = shared.any? { |other| record[:center_x] > other[:center_x] }

        height = record[:z1] - record[:z0]
        safe_margin = [[end_offset, radius+0.1.cm].max, height/2.0].min

        # في النظام المائل: أول مفصلة من أعلى تتحسب من خط الميل عند
        # ناحية المفصلة نفسها، وليس من أعلى Bounding Box للضلفة.
        #
        # مثال end_offset = 10 سم:
        # maximum_z = منسوب القرصة/أعلى الضلفة عند X المفصلة - 10 سم.
        # بذلك لا يمكن للمفصلة أو التخريم أن يخرج خارج الجزء المائل.
        saved_sloped_top = record[:sloped_hinge_top_z]
        sloped_top_z = saved_sloped_top.nil? ? nil : saved_sloped_top.to_f
        top_limit = if sloped_top_z && sloped_top_z > record[:z0] + radius
                      sloped_top_z
                    else
                      record[:z1]
                    end

        minimum_z = record[:z0] + safe_margin
        maximum_z = top_limit - safe_margin
        maximum_z = minimum_z if maximum_z < minimum_z

        z_positions = if hinge_count == 1
          [(minimum_z + maximum_z) / 2.0]
        else
          usable = [maximum_z - minimum_z, 0.0].max
          step = usable / (hinge_count - 1).to_f
          hinge_count.times.map { |index| minimum_z + step * index }
        end

        if stagger_down
          # نزول منع التعارض يظل داخل الحد السفلي والحد المائل العلوي.
          z_positions = z_positions.map do |z|
            [[z-collision_offset, minimum_z].max, maximum_z].min
          end
        end

        x = record[:direction] == 'right' ? record[:x1]-edge_center : record[:x0]+edge_center
        y = record[:y1]
        actual_depth = [requested_depth, record[:y1]-record[:y0]-0.1.mm].min
        next if record[:style] == 'wood' && actual_depth <= 0.1.mm
        case record[:filler_hinge_type].to_s
        when 'scorpion_180'
          hinge_definition = hinge_180_accessory_definition(Sketchup.active_model, record[:direction])
          mirrored = false
          accessory_overlay = 'scorpion_180'
        when 'knee'
          # مفصلة الركبة: نفس التخريم والموضع والحركة تمامًا مثل العدلة،
          # الاختلاف الوحيد هو موديل الإكسسوار المستخدم.
          hinge_definition = hinge_knee_accessory_definition(Sketchup.active_model, record[:direction])
          mirrored = false
          accessory_overlay = 'knee'
        else
          hinge_definition, mirrored = hinge_accessory_definition(Sketchup.active_model, record[:direction], record[:overlay])
          accessory_overlay = record[:overlay]
        end
        z_positions.uniq.each_with_index do |z, index|
          point = Geom::Point3d.new(x, y, z)
          ready_for_accessory = if record[:style] == 'wood'
            drill_round_hole(record[:door], record[:door].transformation, point, Y_AXIS.reverse,
                             actual_depth, diameter, 'HINGE_CUP', index+1)
          else
            true
          end
          if ready_for_accessory
            pending_accessories << [record[:door], hinge_definition, point,
                                    record[:direction], accessory_overlay, index+1, mirrored]
          end
        end
        record[:door].set_attribute('MHD_DRESSING', 'HINGE_CUP_COUNT', record[:style] == 'wood' ? z_positions.uniq.length : 0)
        record[:door].set_attribute('MHD_DRESSING', 'HINGE_ACCESSORY_COUNT', z_positions.uniq.length)
        record[:door].set_attribute('MHD_DRESSING', 'HINGE_STAGGERED_DOWN', stagger_down)
      end

      # نحصل على Entities الحاوية بعد انتهاء كل عمليات التخريم؛ لأن تعديل
      # هندسة Dynamic Components قد يبطل أي مرجع Entities تم التقاطه قبلها.
      hinge_parent = hinge_accessory_entities(root)
      pending_accessories.each do |door, definition, point, direction, overlay, number, mirrored|
        next unless door && door.valid?
        if direction.to_s == 'flip_up'
          add_flip_up_hinge_accessory(
            hinge_parent, door, definition, point, number, mirrored
          )
        else
          add_hinge_accessory(
            hinge_parent, door, definition, point,
            direction, overlay, number, mirrored
          )
        end
      end
    end

    # داعم مفصلات السدّة:
    # قطعة من خامة الشاسيه خلف حرف السدّة من ناحية المفصلة.
    # X = تخانة الشاسيه، Y = قيمة قص عمق الأرفف/شاسيه الأدراج،
    # Z = صافي الفراغ بين القاعدة والقرصة.
    def add_filler_hinge_support(entities, model, column, index, side, filler_inner_x,
                                 cabinet_height, carcass_thickness, carcass_material, config, data)
      support_depth_cm = [config['filler_internal_cut'].to_f, 0].max
      return nil if support_depth_cm <= 0

      support_depth = support_depth_cm.cm
      support_depth = [support_depth, data['depth'].to_f.cm].min if data && data['depth'].to_f > 0
      return nil if support_depth <= 0.1.cm

      base_z = carcass_thickness
      top_z = cabinet_height - carcass_thickness

      # في الوضع المائل، أعلى الداعم يتبع أسفل القرصة عند مكان الداعم.
      if data && slope_enabled?(data)
        sample_x = side == 'left' ? filler_inner_x + carcass_thickness / 2.0 :
                                    filler_inner_x - carcass_thickness / 2.0
        slope_top = slope_height_at(sample_x)
        if slope_top
          rise = data['sloped_right_height'].to_f.cm - data['sloped_left_height'].to_f.cm
          total = data['width'].to_f.cm
          slope_length = Math.sqrt(total * total + rise * rise)
          cosine = total > 0 && slope_length > 0 ? total / slope_length : 1.0
          underside_drop = carcass_thickness / [cosine, 0.001].max
          top_z = slope_top - underside_drop
        end
      end

      support_height = top_z - base_z
      return nil if support_height <= 1.cm

      # تعديل موضع الداعم على محور X فقط:
      # السدّة شمال => الداعم يتحرك شمال داخل عرض السدّة بقيمة تخانته.
      # السدّة يمين => الداعم يتحرك يمين داخل عرض السدّة بقيمة تخانته.
      support_x = side == 'left' ? filler_inner_x - carcass_thickness : filler_inner_x
      side_ar = side == 'left' ? 'شمال' : 'يمين'
      name = "داعم مفصلات سدّة عمود #{index + 1} #{side_ar} #{PART_SUFFIX}"

      support = add_vertical_panel(
        entities, model, name,
        support_x, 0, base_z,
        carcass_thickness, support_depth, support_height,
        carcass_material,
        ['HINGE_SUPPORT','JOINERY_PART'],
        side == 'left' ? :right : :left
      )
      support.set_attribute('MHD_DRESSING', 'HINGE_SUPPORT_SIDE', side)
      support.set_attribute('MHD_DRESSING', 'COLUMN_PATH', column['path'].join('.'))
      support.set_attribute('MHD_DRESSING', 'SUPPORT_DEPTH_CM', support_depth_cm)
      support
    end

    # فيلر جانبي خلف السدّة:
    # - عمق الفيلر = المسافة على محور X بين أول جنب الشاسيه والفيلر.
    # - بروز الفيلر = عرض/امتداد الفيلر على محور Y.
    # - التخانة = تخانة الشاسيه على محور X.
    # - الخامة = خامة الشاسيه.
    # - الارتفاع = ارتفاع الدولاب كاملًا حتى أسفل السوكلو أو الرجول.
    def add_side_filler_return(entities, model, root, side, filler_x, filler_width, filler_y,
                               cabinet_height, carcass_thickness, carcass_material,
                               config, data, index)
      return nil unless root && root.valid?

      offset_cm = [config['filler_return_depth'].to_f, 0].max
      projection_cm = [config['filler_projection'].to_f, 0].max
      return nil if projection_cm <= 0

      x_offset = offset_cm.cm
      projection = projection_cm.cm
      return nil if projection <= 0.1.cm

      # الفيلر الجانبي يكون خارج وش السدّة ناحية الأمام.
      # بما أن +Y داخل عمق الدولاب، فالاتجاه للخارج/لقدام هو -Y.
      # لذلك نحرك بداية الفيلر للخارج بقيمة عرضه/بروزه على Y،
      # بحيث ينتهي آخره بالضبط عند وش السدّة.
      #
      # مثال: بروز الفيلر 5 سم
      # => يبدأ قبل وش السدّة بـ 5 سم وينتهي عند وش السدّة.
      start_y = filler_y.to_f - projection

      # السوكلو المولد يبدأ أسفل الشاسيه بقيمته.
      # مع الرجول نحافظ على أقل Z فعلي موجود في الوحدة الأصلية.
      bottom_z = if data && data['base_type'].to_s == 'wood_plinth'
                   -[data['wood_plinth_height'].to_f, 0].max.cm
                 else
                   begin
                     root.definition.bounds.min.z.to_f
                   rescue
                     0.0
                   end
                 end
      total_height = cabinet_height - bottom_z
      return nil if total_height <= 1.cm

      # موضع X يتحسب من أول جنب الشاسيه في اتجاه السدّة، لكن للداخل:
      # سدّة شمال: نبدأ من أول الشاسيه شمال وندخل يمين بقيمة عمق الفيلر.
      # سدّة يمين: نبدأ من أول الشاسيه يمين وندخل شمال بقيمة عمق الفيلر.
      cabinet_left_x  = 0.0
      cabinet_right_x = data && data['width'].to_f > 0 ? data['width'].to_f.cm : (filler_x + filler_width)

      support_x = if side == 'left'
                    cabinet_left_x + x_offset
                  else
                    cabinet_right_x - x_offset - carcass_thickness
                  end

      side_ar = side == 'left' ? 'شمال' : 'يمين'
      name = "فيلر جانبي سدّة عمود #{index + 1} #{side_ar} #{PART_SUFFIX}"

      part = add_vertical_panel(
        entities, model, name,
        support_x, start_y, bottom_z,
        carcass_thickness, projection, total_height,
        carcass_material,
        ['FILLER_RETURN','JOINERY_PART'],
        side == 'left' ? :right : :left
      )
      part.set_attribute('MHD_DRESSING', 'FILLER_RETURN_SIDE', side)
      part.set_attribute('MHD_DRESSING', 'FILLER_RETURN_DEPTH_CM', offset_cm)
      part.set_attribute('MHD_DRESSING', 'FILLER_PROJECTION_CM', projection_cm)
      part
    end

    def build_column_side_fillers(entities, model, root, columns, cabinet_depth, cabinet_height, carcass_thickness, door_material, sources, data, carcass_material)
      source = sources[['wood', 'right']] || sources[['wood', 'left']]
      source_y0 = nil
      door_thickness = if source && source['instance'] && source['instance'].valid?
        source_points = (0..7).map { |i| source['instance'].definition.bounds.corner(i).transform(source['transform']) }
        source_y0, source_y1 = source_points.map(&:y).minmax
        [source_y1-source_y0, 0.1.cm].max
      else
        1.8.cm
      end
      @column_filler_thickness_by_path = {}
      columns.each_with_index do |column, index|
        config = column['node'].is_a?(Hash) ? column['node']['column_door'] : nil
        next unless config.is_a?(Hash)
        side = config['filler_side'].to_s
        next unless %w[left right].include?(side)
        # The customer-facing "filler depth" is the visible strip width.
        # A filler is a fixed door-like panel on the cabinet face, not a side
        # panel running into the cabinet depth: X = strip width, Y = door
        # thickness, Z = full cabinet height.
        filler_width = [config['filler_depth'].to_f, 0.1].max.cm
        left_overlay = index.zero? ? carcass_thickness : carcass_thickness / 2.0
        right_overlay = index == columns.length - 1 ? carcass_thickness : carcass_thickness / 2.0
        coverage_x = column['x'] - left_overlay
        coverage_width = column['width'] + left_overlay + right_overlay
        filler_width = [filler_width, coverage_width - 0.1.cm].min
        x = side == 'right' ? coverage_x + coverage_width - filler_width : coverage_x
        # Match the actual closed-door slab plane, including source models
        # whose local depth grows toward negative Y.
        y = source_y0 || (cabinet_depth - door_thickness)
        side_ar = side == 'right' ? 'يمين' : 'شمال'
        name = "سدّة عمود #{index + 1} #{side_ar} #{PART_SUFFIX}"
        check_board_limit(name, filler_width, door_thickness, cabinet_height, door_material, ['DOOR_PANEL','SIDE_FILLER'])
        previous_pattern = @edge_band_pattern
        @edge_band_pattern = 'all_around'
        filler = add_box_without_wall_relief(entities, model, name, x, y, 0,
                                             filler_width, door_thickness, cabinet_height,
                                             door_material, ['DOOR_PANEL','SIDE_FILLER','JOINERY_PART'])
        @edge_band_pattern = previous_pattern
        filler.set_attribute('MHD_DRESSING', 'SIDE_FILLER', side)
        filler.set_attribute('MHD_DRESSING', 'COLUMN_PATH', column['path'].join('.'))
        @column_filler_thickness_by_path[column['path'].join('.')] = filler_width

        add_side_filler_return(
          entities, model, root, side, x, filler_width, y,
          cabinet_height, carcass_thickness, carcass_material,
          config, data, index
        )

        # حرف السدّة الداخلي هو نفسه ناحية المفصلة:
        # شمال => الحرف اليمين للسدّة، يمين => الحرف الشمال للسدّة.
        filler_inner_x = side == 'left' ? x + filler_width : x
        # مفصلة العقرب 180 فقط لا تحتاج داعم.
        # العدلة والركبة يستخدمان نفس داعم مفصلات السدّة.
        unless config['filler_hinge_type'].to_s == 'scorpion_180'
          add_filler_hinge_support(
            entities, model, column, index, side, filler_inner_x,
            cabinet_height, carcass_thickness, carcass_material, config, data
          )
        end
      end
    ensure
      @edge_band_pattern = previous_pattern if defined?(previous_pattern) && previous_pattern
    end

    def build_column_doors(root, layout_tree, x, inner_width, height, thickness, clearance, door_material, door_system, layout_z = nil, layout_height = nil, data = nil, interior_entities = nil, cabinet_depth = nil, carcass_material = nil)
      clear_generated_column_doors(root)
      sources = {}
      DOOR_SOURCE_NAMES.each do |key, definition_name|
        source_record = wardrobe_door_source(root, definition_name, key[0])
        sources[key] = source_record if source_record
        force_dynamic_hidden(source_record['instance'], true, 'DOOR_SOURCE_STATE_V2') if source_record
      end
      return unless %w[hinged sliding].include?(door_system.to_s)
      columns = collect_column_regions(layout_tree, x, inner_width, thickness)
      layout_z ||= thickness
      layout_height ||= height - thickness * 2
      model = Sketchup.active_model

      build_column_side_fillers(interior_entities, model, root, columns, cabinet_depth, height, thickness,
                                door_material, sources, data, carcass_material) if interior_entities && cabinet_depth

      build_sliding_doors(root, door_material, sources) if door_system.to_s == 'sliding'

      # خريطة مشاركة المفصلات على قواطع الأعمدة الرئيسية.
      # القاعدة: ضلفة العمود الرئيسية تظل بمنطق اتجاه المفصلة الحالي كما هي.
      # لكن إذا وُجدت أي ضلفة/قلاب داخل أي فراغ، أو أدراج بنمط «على وش الضلفة»،
      # نعتبر العمود كله "عليه واجهة" بالنسبة للقواطع الرئيسية يمينًا وشمالًا.
      # بذلك العمود المجاور يعامل القاطع المشترك كنص ركبة حتى لو كانت ضلفة
      # العمود المقابل موجودة في فراغ جزئي فقط وليست column_door كاملة.
      # القلاب يدخل في هذا الشرط كإشارة أن العمود عليه ضلفة؛ مفصلته نفسها تظل أفقية وبمنطقها الحالي.
      #
      # ملاحظة مهمة: منطق السدّة لا يدخل في هذه الخريطة إطلاقًا، وكذلك شرط
      # المنطقة الجرار الموجود أصلًا يظل كما هو بدون أي تغيير.
      opening_hinged_door_present = lambda do |node|
        next false unless node.is_a?(Hash)

        # وشوش الأدراج بنمط «على وش الضلفة» واجهة فعلية للعمود.
        # لذلك تجعل العمود مشاركًا على القاطعين الرئيسيين يمينًا وشمالًا
        # تمامًا مثل وجود ضلفة/قلاب داخل فراغ. هذا الشرط لا ينطبق على
        # الأدراج الداخلية بنمط الشاسيه السميك.
        if node['type'].to_s == 'drawers' && node['drawer_pattern'].to_s == 'overlay_front'
          next true
        end

        opening = node['opening_door']
        if opening.is_a?(Hash) && opening['enabled'].to_s == 'yes'
          opening_direction = opening['direction'].to_s
          next true if %w[left right double flip_up].include?(opening_direction)
        end
        children = node['children']
        next false unless children.is_a?(Array)
        children.any? { |child| opening_hinged_door_present.call(child) }
      end

      column_hinge_sides = columns.each_with_index.map do |col, col_index|
        node = col['node'].is_a?(Hash) ? col['node'] : nil
        cfg = node ? node['column_door'] : nil
        in_sliding_zone = @sliding_context &&
                          col_index >= @sliding_context['first'].to_i &&
                          col_index <= @sliding_context['second'].to_i

        if in_sliding_zone
          { 'left' => false, 'right' => false, 'filler' => false }
        else
          has_opening_hinged_door = opening_hinged_door_present.call(node)

          if !cfg.is_a?(Hash) || cfg['enabled'].to_s != 'yes'
            # أي ضلفة داخل فراغ، بما فيها القلاب، تجعل العمود مشاركًا على القاطعين
            # الرئيسيين، تمامًا كأنه عليه ضلفة عمود بالنسبة للعمودين المجاورين.
            {
              'left' => has_opening_hinged_door,
              'right' => has_opening_hinged_door,
              'filler' => false
            }
          else
            filler = %w[left right].include?(cfg['filler_side'].to_s)
            dir = %w[left right double].include?(cfg['direction'].to_s) ? cfg['direction'].to_s : 'right'
            # السدّة لها منطقها المستقل بالكامل؛ لا نعيد تصنيف مفصلتها هنا.
            if filler
              { 'left' => false, 'right' => false, 'filler' => true }
            else
              {
                'left' => has_opening_hinged_door || %w[left double].include?(dir),
                'right' => has_opening_hinged_door || %w[right double].include?(dir),
                'filler' => false
              }
            end
          end
        end
      end

      shared_hinge_boundary = lambda do |left_column_index|
        return false if left_column_index < 0 || left_column_index >= columns.length - 1
        left_info = column_hinge_sides[left_column_index]
        right_info = column_hinge_sides[left_column_index + 1]
        left_info && right_info && left_info['right'] && right_info['left']
      end

      # خريطة مستقلة لحساب تغطية الضلف على القواطع الرئيسية.
      # مهم: نوع المفصلة يتحدد من جهة المفصلة نفسها، لكن الحافة الحرة للضلفة
      # يجب أن تتقاسم القاطع مع ضلفة العمود المجاور حتى لو كانت مفصلتا الضلفتين
      # على الجنبين الخارجيين. لذلك أي عمودين متجاورين عليهما ضلف مفصلية
      # يعتبر القاطع بينهما نصف تغطية لكل ضلفة، منعًا لتداخل الضلف عند الغلق.
      # وجود ضلفة داخل أي فراغ (ومنها القلاب) أو وش درج بنمط «على وش الضلفة»
      # يجعل العمود "عليه واجهة" للحساب. السدّة والجرار مستبعدان ويظلان بمنطقهما القديم.
      column_door_presence = columns.each_with_index.map do |col, col_index|
        node = col['node'].is_a?(Hash) ? col['node'] : nil
        cfg = node ? node['column_door'] : nil
        in_sliding_zone = @sliding_context &&
                          col_index >= @sliding_context['first'].to_i &&
                          col_index <= @sliding_context['second'].to_i

        if in_sliding_zone
          false
        else
          opening_present = opening_hinged_door_present.call(node)
          main_present = cfg.is_a?(Hash) &&
                         cfg['enabled'].to_s == 'yes' &&
                         !%w[left right].include?(cfg['filler_side'].to_s)
          main_present || opening_present
        end
      end

      shared_door_coverage_boundary = lambda do |left_column_index|
        return false if left_column_index < 0 || left_column_index >= columns.length - 1
        !!column_door_presence[left_column_index] && !!column_door_presence[left_column_index + 1]
      end

      columns.each_with_index do |column, index|
        if @sliding_context && index >= @sliding_context['first'].to_i && index <= @sliding_context['second'].to_i
          next
        end
        door = column['node'].is_a?(Hash) ? column['node']['column_door'] : nil
        next unless door.is_a?(Hash) && door['enabled'].to_s == 'yes'
        style = door['style'].to_s == 'glass' ? 'glass' : 'wood'
        direction = %w[left right double].include?(door['direction'].to_s) ? door['direction'].to_s : 'right'
        filler_side = door['filler_side'].to_s
        direction = filler_side if %w[left right].include?(filler_side)
        drawer_top = overlay_drawer_top(column['node'], layout_z, layout_height, thickness)
        # لو ضلفة العمود توقفت فوق أدراج «على وش الضلفة»، فالضلفة ووش الدرج
        # يتقاسمان القاطع العرضي: كل واحد يقف عند نصف التخانة مع الخلوص.
        # overlay_drawer_top يعيد بداية القاطع؛ لذلك نضيف نصف التخانة + الخلوص
        # لبداية ضلفة العمود بدل أن نجعلها تغطي القاطع كاملًا.
        base_bottom = drawer_top ? drawer_top + thickness / 2.0 + clearance : clearance
        base_top = height - clearance
        free_span = opening_door_free_span(column['node'], column['x'], layout_z, column['width'], layout_height, thickness, base_bottom, base_top, clearance)
        raise "ضلف الفراغات تغطي العمود #{index + 1} بالكامل؛ ألغِ ضلفة العمود أو إحدى ضلف الفراغات." unless free_span
        target_z, target_top = free_span
        target_height = target_top - target_z
        raise "لا توجد مساحة كافية لضلفة العمود #{index + 1} بعد تخصيص ضلف الفراغات." if target_height <= 0
        # Door coverage follows cabinet-making hinge logic:
        # outer carcass side = full overlay, shared hinged partition = half overlay.
        # The boundary beside an inset sliding-door zone is not shared by two
        # hinged leaves, so the adjacent hinged leaf uses a full-overlay hinge
        # and covers that partition exactly like an exposed carcass side.
        beside_sliding_on_left = @sliding_context && index == @sliding_context['second'].to_i + 1
        beside_sliding_on_right = @sliding_context && index == @sliding_context['first'].to_i - 1

        # السدّة تظل بمنطقها القديم كما هو بلا أي تغيير.
        # أما الضلفة العادية فحساب العرض مستقل عن نوع المفصلة:
        # إذا كان العمود المجاور عليه أي ضلفة، يتقاسم الاثنان القاطع بينهما
        # (نصف التخانة لكل ضلفة - ثم يطبق الخلوص المعتاد). هذا صحيح حتى لو
        # كانت مفصلتا الضلفتين على الجنبين الخارجيين وكلتاهما عدلة.
        if %w[left right].include?(filler_side)
          left_overlay = (index.zero? || beside_sliding_on_left) ? thickness : thickness / 2.0
          right_overlay = (index == columns.length - 1 || beside_sliding_on_right) ? thickness : thickness / 2.0
        else
          left_shared_coverage = !index.zero? && shared_door_coverage_boundary.call(index - 1)
          right_shared_coverage = index < columns.length - 1 && shared_door_coverage_boundary.call(index)
          left_overlay = (index.zero? || beside_sliding_on_left || !left_shared_coverage) ? thickness : thickness / 2.0
          right_overlay = (index == columns.length - 1 || beside_sliding_on_right || !right_shared_coverage) ? thickness : thickness / 2.0
        end
        coverage_x = column['x'] - left_overlay
        coverage_width = column['width'] + left_overlay + right_overlay
        filler_thickness = (@column_filler_thickness_by_path || {})[column['path'].join('.')].to_f
        if filler_side == 'left'
          coverage_x += filler_thickness
          coverage_width -= filler_thickness
        elsif filler_side == 'right'
          coverage_width -= filler_thickness
        end
        leaf_width = direction == 'double' ? coverage_width / 2.0 - clearance * 2 : coverage_width - clearance * 2
        raise "خلوص الضلفة أكبر من عرض العمود #{index + 1}." if leaf_width <= 0
        leaf_count = direction == 'double' ? 2 : 1
        leaf_count.times { |leaf| check_board_limit("ضلفة العمود #{index + 1} - #{leaf + 1}", leaf_width, thickness, target_height, door_material, ['DOOR_PANEL']) }
        directions = direction == 'double' ? %w[left right] : [direction]
        directions.each do |leaf_direction|
          source_name = DOOR_SOURCE_NAMES[[style, leaf_direction]]
          source_record = sources[[style, leaf_direction]]
          raise "لم أجد ضلفة المصدر بالـ Definition: #{source_name}" unless source_record
          hinge_x = if leaf_direction == 'right'
            coverage_x + coverage_width - clearance
          else
            coverage_x + clearance
          end
          side_ar = leaf_direction == 'right' ? 'يمين' : 'شمال'
          needs_sloped_cut = false
          if data && slope_enabled?(data)
            leaf_left = leaf_direction == 'right' ? hinge_x - leaf_width : hinge_x
            leaf_right = leaf_direction == 'right' ? hinge_x : hinge_x + leaf_width
            top_left = slope_height_at(leaf_left) - clearance
            top_right = slope_height_at(leaf_right) - clearance
            needs_sloped_cut = [top_left, top_right].min < target_z + target_height - 0.01.cm
          end
          if needs_sloped_cut
            min_height = [top_left, top_right].min - target_z
            raise "الميل لا يترك ارتفاعًا كافيًا لضلفة العمود #{index + 1}." if min_height <= 10.cm
            y_position = source_record['transform'].origin.y
            generated_door = create_sloped_dynamic_door(root, "ضلفة #{style == 'glass' ? 'زجاج ' : ''}مائلة عمود #{index + 1} - #{side_ar}", hinge_x, target_z, leaf_width, top_left, top_right, leaf_direction, style, door_material, column['path'].join('.'), y_position)
          elsif style == 'glass'
            # الضلفة الزجاج تظل Dynamic Component الأصلية كما هي تمامًا.
            generated_door = copy_dynamic_glass_door(root, source_record, "ضلفة زجاج عمود #{index + 1} - #{side_ar}", hinge_x, target_z, leaf_width, target_height, leaf_direction, column['path'].join('.'))
          else
            # هذا المسار للخشب فقط.
            generated_door = copy_dynamic_door(root, source_record, "ضلفة عمود #{index + 1} - #{side_ar}", hinge_x, target_z, leaf_width, target_height, leaf_direction, 'wood', column['path'].join('.'))
          end
          hinge_overlay = if leaf_direction == 'right'
            right_overlay >= thickness * 0.75 ? 'straight' : 'half'
          else
            left_overlay >= thickness * 0.75 ? 'straight' : 'half'
          end
          set_door_hinge_overlay(generated_door, hinge_overlay)
          if %w[left right].include?(filler_side)
            filler_hinge_type = case door['filler_hinge_type'].to_s
                                when 'scorpion_180' then 'scorpion_180'
                                when 'knee' then 'knee'
                                else 'straight'
                                end
            generated_door.set_attribute('MHD_DRESSING', 'FILLER_HINGE_TYPE', filler_hinge_type)
          end
          set_door_hinge_count(generated_door, door['hinge_count'], data ? data['hinge_count'] : 4)
        end
      end


      leaf_regions = collect_leaf_regions(layout_tree, x, layout_z, inner_width, layout_height, thickness)
      leaf_regions.each_with_index do |region, index|
        if @sliding_context
          region_left = region['x'].to_f
          region_right = region_left + region['width'].to_f
          slide_left = @sliding_context['coverage_x'].to_f
          slide_right = slide_left + @sliding_context['coverage_width'].to_f
          next if region_right > slide_left + 0.1.cm && region_left < slide_right - 0.1.cm
        end
        door = region['node'].is_a?(Hash) ? region['node']['opening_door'] : nil
        next unless door.is_a?(Hash) && door['enabled'].to_s == 'yes'
        style = door['style'].to_s == 'glass' ? 'glass' : 'wood'
        direction = %w[left right double flip_up].include?(door['direction'].to_s) ? door['direction'].to_s : 'right'
        left_overlay = region['left'] == :outer ? thickness : thickness / 2.0
        right_overlay = region['right'] == :outer ? thickness : thickness / 2.0
        # القاطع العرضي يتحدد حسب وجود واجهة على الناحية المقابلة:
        # واجهتان => نصف التخانة لكل واحدة. واجهة واحدة => التخانة كاملة.
        bottom_overlay = if region['bottom'] == :outer
                           thickness
                         elsif adjacent_horizontal_front_face?(region, leaf_regions, :bottom, thickness)
                           thickness / 2.0
                         else
                           thickness
                         end
        top_overlay = if region['top'] == :outer
                        thickness
                      elsif adjacent_horizontal_front_face?(region, leaf_regions, :top, thickness)
                        thickness / 2.0
                      else
                        thickness
                      end
        coverage_x = region['x'] - left_overlay
        coverage_z = region['z'] - bottom_overlay
        coverage_width = region['width'] + left_overlay + right_overlay
        coverage_height = region['height'] + bottom_overlay + top_overlay
        target_z = coverage_z + clearance
        target_height = coverage_height - clearance * 2
        raise "خلوص الضلفة أكبر من ارتفاع الفراغ #{index + 1}." if target_height <= 0
        path = region['path'].join('.')

        if direction == 'flip_up'
          leaf_width = coverage_width - clearance * 2
          raise "خلوص الضلفة أكبر من عرض الفراغ #{index + 1}." if leaf_width <= 0
          check_board_limit("ضلفة قلاب فراغ #{index + 1}", leaf_width, thickness, target_height, door_material, ['DOOR_PANEL'])

          generated_door = if style == 'glass'
            source_record = sources[['glass', 'left']]
            raise "لم أجد ضلفة الزجاج المصدر اللازمة لإنشاء القلاب." unless source_record
            create_dynamic_glass_flip_up_door(
              root, source_record,
              "ضلفة زجاج قلاب فراغ #{index + 1}",
              coverage_x + clearance, target_z,
              leaf_width, target_height, path
            )
          else
            source_record = sources[['wood', 'left']] || sources.values.first
            y_position = source_record ? source_record['transform'].origin.y : -1.8.cm
            create_flip_up_door(
              root,
              "ضلفة قلاب فراغ #{index + 1}",
              coverage_x + clearance, target_z,
              leaf_width, target_height,
              style, door_material, path, y_position
            )
          end

          # مهم: القلاب كان بيتكوّن ثم نخرج بـ next قبل حفظ عدد المفصلات
          # المختار من الواجهة، لذلك التخريم كان يرجع دائمًا للـ fallback = 4.
          set_door_hinge_count(
            generated_door,
            door['hinge_count'],
            data ? data['hinge_count'] : 4
          ) if generated_door

          # عدد الباكم محفوظ لكل قلاب. في هذه النسخة ننفذ الشمال فقط؛
          # اختيار 2 محفوظ للخطوة التالية عندما نضيف النسخة اليمين Flip.
          lift_count = [[door['lift_count'].to_i, 1].max, 2].min
          if generated_door && cabinet_depth
            add_flip_up_push_lift_left(
              root,
              generated_door,
              region['x'],
              target_z + target_height,
              cabinet_depth,
              data,
              1
            )

            if lift_count == 2
              add_flip_up_push_lift_right(
                root,
                generated_door,
                region['x'],
                region['width'],
                target_z + target_height,
                cabinet_depth,
                data,
                2
              )
            end
          end

          next
        end

        leaf_width = direction == 'double' ? coverage_width / 2.0 - clearance * 2 : coverage_width - clearance * 2
        raise "خلوص الضلفة أكبر من عرض الفراغ #{index + 1}." if leaf_width <= 0
        directions = direction == 'double' ? %w[left right] : [direction]
        directions.each do |leaf_direction|
          source_name = DOOR_SOURCE_NAMES[[style, leaf_direction]]
          source_record = sources[[style, leaf_direction]]
          raise "لم أجد ضلفة المصدر بالـ Definition: #{source_name}" unless source_record
          hinge_x = leaf_direction == 'right' ? coverage_x + coverage_width - clearance : coverage_x + clearance
          side_ar = leaf_direction == 'right' ? 'يمين' : 'شمال'
          check_board_limit("ضلفة فراغ #{index + 1} - #{side_ar}", leaf_width, thickness, target_height, door_material, ['DOOR_PANEL'])
          needs_sloped_cut = false
          if data && slope_enabled?(data)
            leaf_left = leaf_direction == 'right' ? hinge_x - leaf_width : hinge_x
            leaf_right = leaf_direction == 'right' ? hinge_x : hinge_x + leaf_width
            top_left = slope_height_at(leaf_left) - clearance
            top_right = slope_height_at(leaf_right) - clearance
            needs_sloped_cut = [top_left, top_right].min < target_z + target_height - 0.01.cm
          end
          if needs_sloped_cut
            min_height = [top_left, top_right].min - target_z
            raise "الميل لا يترك ارتفاعًا كافيًا لضلفة الفراغ #{index + 1}." if min_height <= 10.cm
            y_position = source_record['transform'].origin.y
            generated_door = create_sloped_dynamic_door(root, "ضلفة #{style == 'glass' ? 'زجاج ' : ''}مائلة فراغ #{index + 1} - #{side_ar}", hinge_x, target_z, leaf_width, top_left, top_right, leaf_direction, style, door_material, path, y_position)
          elsif style == 'glass'
            # الضلفة الزجاج تظل Dynamic Component الأصلية كما هي تمامًا.
            generated_door = copy_dynamic_glass_door(root, source_record, "ضلفة زجاج فراغ #{index + 1} - #{side_ar}", hinge_x, target_z, leaf_width, target_height, leaf_direction, path)
          else
            # هذا المسار للخشب فقط.
            generated_door = copy_dynamic_door(root, source_record, "ضلفة فراغ #{index + 1} - #{side_ar}", hinge_x, target_z, leaf_width, target_height, leaf_direction, 'wood', path)
          end
          hinge_overlay = if leaf_direction == 'right'
            region['right'] == :outer ? 'straight' : 'half'
          else
            region['left'] == :outer ? 'straight' : 'half'
          end
          set_door_hinge_overlay(generated_door, hinge_overlay)
          set_door_hinge_count(generated_door, door['hinge_count'], data ? data['hinge_count'] : 4)
        end
      end
    end

    def template_rod(entities, model, x, width, z, depth, thickness, material, label)
      add_rod(entities, model, x, width, depth, z, thickness, material, label)
    end

    def build_easy_template(id, entities, model, x, width, depth, height, thickness, carcass, back_material, front_material, data)
      bottom = thickness
      top = height - thickness
      usable = top - bottom
      z75 = bottom + usable * 0.75
      z55 = bottom + usable * 0.55
      z35 = bottom + usable * 0.35
      mid_x = x + (width - thickness) * 0.5
      left_w = mid_x - x
      right_x = mid_x + thickness
      right_w = x + width - right_x
      default_shelf_cut = [data['shelf_front_cut'].to_f, 0].max.cm
      # قواطع التقسيمات الجاهزة داخل العمود ليست قواطع أعمدة رئيسية؛
      # لذلك تقف قبل الضهر ولا يدخل فيها مفحار الضهر.
      divider_depth = depth
      shelf = lambda { |z, sx = x, sw = width, name = id| template_shelf(entities, model, sx, sw, z, depth, thickness, carcass, name, default_shelf_cut) }
      shelves = lambda { |sx, sw, z1, z2, n, name| template_shelves(entities, model, sx, sw, z1, z2, n, depth, thickness, carcass, name, default_shelf_cut) }
      rod = lambda { |sx, sw, z, name| template_rod(entities, model, sx, sw, z, depth, thickness, carcass, name) }
      split = lambda { |z1, z2, ratio = 0.5, name = id|
        px = x + (width - thickness) * ratio
        template_partition(entities, model, px, z1, z2, divider_depth, thickness, carcass, name, partition_front_cut(data, z1, z2))
        [px, px + thickness]
      }
      drawer = lambda { |sx, sw, count, stack_cm, name|
        cfg = {'runner_clearance'=>1.3,'chassis_height'=>13,'drawer_thickness'=>data['thickness'],'bottom_thickness' => 0.6,'bottom_drop'=>1.8,'bottom_groove_depth' => 0.6,'front_clearance'=>0.3,'front_thickness'=>1.8,'_back_inset'=>data['back_inset'],'_back_thickness'=>data['back_thickness']}
        add_drawer_stack(entities, model, sx, sw, data['depth'].to_f.cm, thickness, count, stack_cm.cm, carcass, back_material, front_material, name, cfg)
      }

      case id.to_s
      when '1'
        shelf.call(z75); shelf.call(z55); px, rx = split.call(bottom, z55, 0.5); shelves.call(x, px-x, bottom, z55, 4, '1L'); rod.call(rx, x+width-rx, z55-8.cm, '1R')
      when '2'
        shelf.call(z75); shelf.call(z55); shelf.call(z35); px, rx = split.call(z35, z55, 0.52); shelves.call(x, px-x, z35, z55, 1, '2L'); shelves.call(rx, x+width-rx, z35, z55, 3, '2R'); rod.call(x, width, z35-5.cm, '2B')
      when '3'
        shelf.call(z75); shelf.call(z55); rod.call(x, width, z55-8.cm, '3'); shelves.call(x, width, bottom, z35, 4, '3B')
      when '4'
        shelf.call(z75); shelf.call(z55); px, rx = split.call(bottom, z55, 0.5); rod.call(x, px-x, z55-8.cm, '4LT'); rod.call(x, px-x, z35-5.cm, '4LB'); shelves.call(rx, x+width-rx, bottom, z55, 2, '4R')
      when '5', '6'
        shelf.call(z75); shelf.call(z55); px, rx = split.call(bottom, z55, 0.5); rod.call(x, px-x, z55-8.cm, '5L'); rod.call(rx, x+width-rx, z55-8.cm, '5R'); shelf.call(z35)
      when '7'
        shelves.call(x, width, bottom, top, 7, '7')
      when '8'
        shelf.call(z75); shelf.call(z55); rod.call(x, width, z55-8.cm, '8T'); px, rx = split.call(bottom, z35, 0.5); drawer.call(x, px-x, 4, (usable*0.34/1.cm.to_f), '8D'); shelves.call(rx, x+width-rx, bottom, z35, 4, '8R')
      when '9'
        shelf.call(z75); shelf.call(z55); px, rx = split.call(bottom, z55, 0.5); shelves.call(x, px-x, bottom, z55, 3, '9L'); shelves.call(rx, x+width-rx, bottom, z55, 2, '9R')
      when '10', '11'
        shelf.call(z75); shelf.call(z55); rod.call(x, width, z55-8.cm, '10T'); shelf.call(z35); rod.call(x, width, z35-6.cm, '10B'); drawer.call(x, width, id.to_s == '10' ? 1 : 1, 18, id)
      when '12'
        shelf.call(z75); shelf.call(z55); rod.call(x, width, z55-8.cm, '12'); shelf.call(z35); drawer.call(x, width, 2, 34, '12D')
      when '13'
        shelf.call(z75); shelf.call(z55); rod.call(x, width, z55-8.cm, '13T'); shelf.call(z35); rod.call(x, width, z35-6.cm, '13B')
      when '14'
        shelf.call(z75); shelf.call(z55); rod.call(x, width, z55-8.cm, '14T'); shelf.call(z35); px, rx = split.call(bottom, z35, 0.52); rod.call(x, px-x, z35-7.cm, '14L'); shelves.call(rx, x+width-rx, bottom, z35, 3, '14R')
      when '15'
        shelf.call(z75); shelf.call(z55); rod.call(x, width, z55-8.cm, '15')
      when '16'
        shelves.call(x, width, z35, top, 4, '16T'); px, rx = split.call(bottom, z35, 0.5); shelves.call(x, px-x, bottom, z35, 1, '16L'); shelves.call(rx, x+width-rx, bottom, z35, 3, '16R')
      when '17'
        shelf.call(z75); shelf.call(z55); shelf.call(z35); p1 = x + width/3.0; p2 = x + width*2/3.0; template_partition(entities, model, p1, z35, z55, divider_depth, thickness, carcass, '17A', partition_front_cut(data, z35, z55)); template_partition(entities, model, p2, z35, z55, divider_depth, thickness, carcass, '17B', partition_front_cut(data, z35, z55)); drawer.call(x, width, 4, (usable*0.34/1.cm.to_f), '17D')
      when '18', '19'
        shelf.call(z75); shelf.call(z55); px, rx = split.call(z35, z55, 0.5); shelves.call(x, px-x, z35, z55, 1, '18L'); drawer.call(x, width, 4, (usable*0.34/1.cm.to_f), '18D')
      when '20'
        shelf.call(z75); shelf.call(z55); rod.call(x, width, z55-8.cm, '20'); shelf.call(z35); drawer.call(x, width, 4, (usable*0.34/1.cm.to_f), '20D')
      else
        shelves.call(x, width, bottom, top, 4, 'DEFAULT')
      end
    end

    def build_layout_tree(node, entities, model, x, z, width, height, depth, thickness, carcass, back_material, front_material, data, label = '1', left_boundary = :outer, right_boundary = :outer, left_cut = false, right_cut = false, support_x = nil, support_width = nil, filler_front_cut = 0, filler_opening_x = nil, filler_opening_width = nil, top_front_shared = false, column_main_face = nil, bottom_boundary = :outer, top_boundary = :outer)
      return unless node.is_a?(Hash) && width > thickness && height > thickness
      column_door = node['column_door']

      # ضلفة العمود الرئيسية قد تُقصَّر تلقائيًا عندما يوجد داخل نفس العمود
      # أدراج بنمط «على وش الضلفة». في هذه الحالة تظل الضلفة هي الواجهة
      # الموجودة مباشرة فوق أعلى مجموعة الأدراج، ولذلك يجب أن تتقاسم هي ووش
      # الدرج العلوي القاطع الأفقي بينهما: نصف التخانة لكل واجهة - الخلوص.
      #
      # نحتفظ بهذه المعلومة أثناء النزول داخل التقسيمات الأفقية للعمود. وإذا
      # دخلنا عقدة لها column_door خاص بها (عمود جديد بعد تقسيم رأسي) نعيد
      # حسابها لتخص ذلك العمود فقط. السدّة والجرار مستبعدان من هذا المنطق.
      if column_door.is_a?(Hash)
        column_main_face = data['door_system'].to_s == 'hinged' &&
                           column_door['enabled'].to_s == 'yes' &&
                           !%w[left right].include?(column_door['filler_side'].to_s)
      elsif column_main_face.nil?
        column_main_face = false
      end
      if column_door.is_a?(Hash) && %w[left right].include?(column_door['filler_side'].to_s)
        filler_front_cut = [column_door.fetch('filler_internal_cut', 5).to_f, 0].max.cm
        filler_width = [column_door['filler_depth'].to_f.cm, width - 0.1.cm].min
        filler_opening_x = column_door['filler_side'].to_s == 'left' ? x + filler_width : x
        filler_opening_width = width - filler_width
      end
      direction = node['dir'].to_s
      if direction == 'v' || direction == 'h'
        children = node['children'].is_a?(Array) ? node['children'] : []
        return if children.length < 2
        ratio = [[node['ratio'].to_f, 0.08].max, 0.92].min
        if direction == 'v'
          # In side-filler layouts the drawer chassis already provides its
          # own vertical sides. Do not generate a redundant carcass divider
          # beside a drawer subtree, and do not reserve its thickness as an
          # empty gap in the layout.
          omit_drawer_divider = filler_opening_width && children.any? { |child| subtree_has_thick_drawers?(child) }
          divider_space = omit_drawer_divider ? 0 : thickness
          first_width = (width - divider_space) * ratio
          divider_x = x + first_width
          sliding_cut = if @sliding_context && Array(@sliding_context['divider_xs']).any? { |value|
                           (divider_x - value.to_f).abs <= 0.15.cm
                         }
                          @sliding_context['partition_cut'].to_f
                        else
                          0
                        end
          # لا يُقص أي قاطوع خارجي بجوار ضلفة مفصلية؛ القص للحد الفاصل
          # بين عمودي الجرار المختارين فقط.
          divider_cut = [partition_front_cut(data, z, z + height), sliding_cut].max
          main_back_partition = full_height_back_partition?(z, z + height)
          divider_depth = main_back_partition ? partition_depth_for_back(depth, data) : depth
          template_partition(entities, model, divider_x, z, z + height, divider_depth,
                             thickness, carcass, "#{label}V", divider_cut,
                             main_back_partition) unless omit_drawer_divider
          divider_is_cut = !omit_drawer_divider && divider_cut > 0
          build_layout_tree(children[0], entities, model, x, z, first_width, height, depth, thickness, carcass, back_material, front_material, data, "#{label}.1", left_boundary, :partition, left_cut, divider_is_cut, support_x, support_width, filler_front_cut, filler_opening_x, filler_opening_width, top_front_shared, column_main_face, bottom_boundary, top_boundary)
          build_layout_tree(children[1], entities, model, divider_x + divider_space, z, width - first_width - divider_space, height, depth, thickness, carcass, back_material, front_material, data, "#{label}.2", :partition, right_boundary, divider_is_cut, right_cut, support_x, support_width, filler_front_cut, filler_opening_x, filler_opening_width, top_front_shared, column_main_face, bottom_boundary, top_boundary)
        else
          top_height = (height - thickness) * ratio
          bottom_height = height - thickness - top_height
          divider_z = z + bottom_height
          # إذا كان الجزء السفلي يحتوي شاسيه أدراج بسماكة فلا نرسم رفًا
          # يعبر الأدراج والفراغ المجاور؛ قرصة كل شاسيه تؤدي هذا الدور.
          unless subtree_has_thick_drawers?(children[1])
            template_shelf(entities, model, x, width, divider_z, depth, thickness, carcass, "#{label}H", [[data['shelf_front_cut'].to_f, 0].max.cm, filler_front_cut].max, nil, 'structural_divider')
          end
          build_layout_tree(children[0], entities, model, x, divider_z + thickness, width, top_height, depth, thickness, carcass, back_material, front_material, data, "#{label}.1", left_boundary, right_boundary, left_cut, right_cut, nil, nil, filler_front_cut, filler_opening_x, filler_opening_width, top_front_shared, column_main_face, :shelf, top_boundary)
          drawer_support = subtree_thick_drawer_count(children[1]) == 1
          effective_support_x = drawer_support ? (support_x || x) : nil
          effective_support_width = drawer_support ? (support_width || width) : nil
          build_layout_tree(children[1], entities, model, x, z, width, bottom_height, depth, thickness, carcass, back_material, front_material, data, "#{label}.2", left_boundary, right_boundary, left_cut, right_cut, effective_support_x, effective_support_width, filler_front_cut, filler_opening_x, filler_opening_width, (subtree_has_front_face?(children[0]) || column_main_face), column_main_face, bottom_boundary, :shelf)
        end
        return
      end

      type = node['type'].to_s
      count = [[node['count'].to_i, 0].max, 10].min
      shelf_front_cut = [[data['shelf_front_cut'].to_f, 0].max.cm, filler_front_cut].max
      case type
      when 'shelves'
        template_shelves(entities, model, x, width, z, z + height, count > 0 ? count : 3, depth, thickness, carcass, label, shelf_front_cut, node['accessory_items'])
      when 'hanging'
        template_rod(entities, model, x, width, z + height - [8.cm, height * 0.18].min, depth, thickness, carcass, label)
      when 'double_hang'
        template_rod(entities, model, x, width, z + height * 0.78, depth, thickness, carcass, "#{label}A")
        template_rod(entities, model, x, width, z + height * 0.40, depth, thickness, carcass, "#{label}B")
      when 'drawers'
        drawer_count = count > 0 ? count : 4
        stack_height_cm = height.to_f / 1.cm.to_f
        if @slope_context
          local_top = [slope_height_at(x), slope_height_at(x + width)].min - thickness
          visible_height = [local_top - z, 0].max
          one_drawer_height = height / drawer_count.to_f
          visible_count = [[(visible_height / one_drawer_height).floor, drawer_count].min, 0].max
          return if visible_count <= 0
          drawer_count = visible_count
          stack_height_cm = (one_drawer_height * visible_count).to_f / 1.cm.to_f
        end
        drawer_pattern = node['drawer_pattern'].to_s.empty? ? 'thick_side' : node['drawer_pattern'].to_s

        # الأدراج الواقعة خلف مساحة الجرار لا يمكن أن تعمل بنمط «على وش الضلفة».
        # عند اختيار الجرار نحولها تلقائيًا إلى «جنب سميك»، ثم نرجع شاسيه
        # الأدراج وصناديقها بنفس قيمة قص القواطيع والأرفف من الأمام.
        sliding_drawer_cut = 0.0
        if @sliding_context
          sliding_left = @sliding_context['coverage_x'].to_f
          sliding_right = sliding_left + @sliding_context['coverage_width'].to_f
          drawer_left = x.to_f
          drawer_right = x.to_f + width.to_f
          if drawer_right > sliding_left + 0.1.cm && drawer_left < sliding_right - 0.1.cm
            sliding_drawer_cut = @sliding_context['partition_cut'].to_f
            drawer_pattern = 'thick_side' if %w[overlay_front flush_carcass].include?(drawer_pattern)
          end
        end

        drawer_front_thickness_cm = node['front_thickness'].to_f > 0 ? node['front_thickness'].to_f : 1.8
        surrounding_partition_cut = partition_front_cut(data, z, z + height)
        cut_matches_front = (surrounding_partition_cut.to_f - drawer_front_thickness_cm.cm.to_f).abs <= 0.05.cm

        # «على وش الضلفة» يظل على منطق الحماية القديم.
        if drawer_pattern == 'overlay_front' && (left_cut || right_cut)
          raise 'لا يمكن استخدام نمط «على وش الضلفة» لأن أحد القواطيع المحيطة بالأدراج مقصوص من الأمام. ألغِ قص القاطع أو اختر نمط «جنب سميك».'
        end

        # «مساوي للشاسيه» يسمح بالقاطع المقصوص فقط عندما قيمة القص تساوي
        # تخانة وش الدرج. وقتها الوش يشارك القاطع حتى منتصف تخانته - الخلوص.
        if drawer_pattern == 'flush_carcass'
          bad_left  = left_cut  && !cut_matches_front
          bad_right = right_cut && !cut_matches_front
          if bad_left || bad_right
            raise 'في نمط «مساوي للشاسيه» قص القاطع المحيط بالأدراج يجب أن يساوي تخانة وش الدرج حتى تتم مشاركة القاطع. غيّر القص لنفس تخانة الوش أو ألغِ القص.'
          end
        end

        sliding_drawer_cut_cm = sliding_drawer_cut.to_f / 1.cm.to_f
        drawer_front_cut = if %w[overlay_front flush_carcass].include?(drawer_pattern)
                             [filler_front_cut.to_f / 1.cm.to_f, 0].max
                           else
                             [node['drawer_front_cut'].to_f, filler_front_cut.to_f / 1.cm.to_f, sliding_drawer_cut_cm, 0].max
                           end
        drawer_x = filler_opening_x || x
        drawer_width = filler_opening_width || width
        raise 'عمق السدّة أكبر من عرض عمود الأدراج.' if drawer_width <= thickness * 2
        cfg = {'drawer_pattern'=>drawer_pattern,'runner_clearance'=>node['runner_clearance'] || 1.3,'runner_length'=>node['runner_length'] || 0,'chassis_height'=>node['chassis_height'] || 13,'drawer_thickness'=>data['thickness'],'bottom_thickness'=>node['bottom_thickness'] || 0.6,'bottom_drop'=>node['bottom_drop'] || 1.8,'bottom_groove_depth'=>node['bottom_groove_depth'] || 0.6,'front_clearance'=>node['front_gap'] || 0.3,'front_thickness'=>node['front_thickness'] || 1.8,'drawer_front_cut'=>drawer_front_cut,'_top_front_cut'=>([shelf_front_cut.to_f, sliding_drawer_cut].max.to_f / 1.cm.to_f),'accessory_items'=>node['accessory_items'],
          'inner_drawer_joinery'=>node['inner_drawer_joinery'] || 'screw',
          'inner_elita_edge_offset'=>node['inner_elita_edge_offset'] || data['elita_edge_offset'] || 5,
          'inner_elita_screw_drill_diameter'=>node['inner_elita_screw_drill_diameter'] || data['elita_screw_drill_diameter'] || 0.8,
          'inner_elita_dowel_diameter'=>node['inner_elita_dowel_diameter'] || data['elita_dowel_diameter'] || 0.8,
          'inner_elita_dowel_depth'=>node['inner_elita_dowel_depth'] || data['elita_dowel_depth'] || 1.05,
          'inner_elita_cam_diameter'=>node['inner_elita_cam_diameter'] || data['elita_cam_diameter'] || 1.5,
          'inner_elita_cam_depth'=>node['inner_elita_cam_depth'] || data['elita_cam_depth'] || 1.2,
          'inner_elita_screw_after_thread'=>node['inner_elita_screw_after_thread'] || data['elita_screw_after_thread'] || 3.2,
          'inner_elita_coil_count'=>node['inner_elita_coil_count'] || data['elita_coil_count'] || 1,
          'inner_elita_coil_drill_diameter'=>node['inner_elita_coil_drill_diameter'] || data['elita_coil_drill_diameter'] || 0.8,
          'inner_elita_coil_length'=>node['inner_elita_coil_length'] || data['elita_coil_length'] || 4.0,
          'inner_elita_coil_face_depth'=>node['inner_elita_coil_face_depth'] || data['elita_coil_face_depth'] || 2.0,
          'inner_elita_coil_center_distance'=>node['inner_elita_coil_center_distance'] || data['elita_coil_center_distance'] || 2.5,
          '_back_inset'=>data['back_inset'],'_back_thickness'=>data['back_thickness'],'_base_z'=>z.to_f / 1.cm.to_f,'_touches_base'=>(z <= thickness + 0.2.cm),'_left_overlay'=>(left_boundary == :outer ? thickness : thickness / 2.0).to_f / 1.cm.to_f,'_right_overlay'=>(right_boundary == :outer ? thickness : thickness / 2.0).to_f / 1.cm.to_f,'_left_boundary'=>left_boundary.to_s,'_right_boundary'=>right_boundary.to_s,'_left_cut'=>left_cut,'_right_cut'=>right_cut,'_partition_front_cut_cm'=>surrounding_partition_cut.to_f / 1.cm.to_f,'_bottom_boundary'=>bottom_boundary.to_s,'_top_boundary'=>top_boundary.to_s,'_shelf_front_cut_cm'=>shelf_front_cut.to_f / 1.cm.to_f,'_top_x'=>(support_x ? support_x.to_f / 1.cm.to_f : nil),'_top_width'=>(support_width ? support_width.to_f / 1.cm.to_f : nil),'_top_front_shared'=>top_front_shared}
        add_drawer_stack(entities, model, drawer_x, drawer_width, data['depth'].to_f.cm, thickness, drawer_count, stack_height_cm.cm, carcass, back_material, front_material, label, cfg)
      when 'shelves_hang'
        template_shelves(entities, model, x, width, z + height * 0.55, z + height, count > 0 ? count : 2, depth, thickness, carcass, label, shelf_front_cut, node['accessory_items'])
        template_rod(entities, model, x, width, z + height * 0.48, depth, thickness, carcass, label)
      end
    end

    def update_creation_progress(percent, message)
      return unless @dialog
      @dialog.execute_script("updateCreationProgress(#{percent.to_i}, #{JSON.generate(message.to_s)})")
    rescue
      nil
    end

    # يجمع أسماء/أرقام وحدات الدريسنج الرئيسية فقط من المستوى الأعلى للموديل.
    # لا ننزل داخل Definitions أو القطع الداخلية حتى يظل الفحص لحظيًا مهما كان
    # عدد الأرفف/الأدراج داخل كل دولاب.
    def used_dressing_unit_names(model, except_root = nil)
      used = {}
      model.entities.grep(Sketchup::ComponentInstance).each do |instance|
        next unless instance && instance.valid?
        next if except_root && instance == except_root

        raw = instance.get_attribute(DRESSING_DICT, 'DATA_JSON', nil)
        raw = instance.definition.get_attribute(DRESSING_DICT, 'DATA_JSON', nil) if raw.to_s.strip.empty?
        next if raw.to_s.strip.empty?

        begin
          saved = JSON.parse(raw.to_s)
        rescue
          next
        end
        name = saved['unit_name'].to_s.strip.gsub(/[\r\n\t]+/, ' ').gsub(/\s+/, ' ')
        next if name.empty?
        used[name.downcase] = true
      end
      used
    end

    # يضمن أن اسم/رقم الوحدة لن يصطدم بوحدة دريسنج أخرى قبل إنشاء أي قطعة.
    # الرقم المكرر ينزل تلقائيًا لأول رقم فاضي (28 -> 27 -> 26 ...)،
    # أما الاسم النصي المكرر فنوقف الإنشاء ونطلب اسمًا مختلفًا بدل توليد #1/#2.
    def ensure_unique_dressing_unit_name!(data, model, current_root)
      requested = data['unit_name'].to_s.strip.gsub(/[\r\n\t]+/, ' ').gsub(/\s+/, ' ')
      raise 'اكتب اسم أو رقم الوحدة أولًا.' if requested.empty?

      used = used_dressing_unit_names(model, current_root)
      return requested unless used[requested.downcase]

      if requested.match?(/\A\d+\z/)
        original_number = requested.to_i
        candidate = original_number - 1
        candidate += 1 while candidate >= 1 && used[candidate.to_s.downcase]

        # لو كل الأرقام الأصغر مستخدمة أو الرقم 1، نبحث لأعلى بدل إنتاج اسم مكرر.
        if candidate < 1
          candidate = original_number + 1
          candidate += 1 while used[candidate.to_s.downcase]
        end

        replacement = candidate.to_s
        data['unit_name'] = replacement
        UI.messagebox("رقم الوحدة #{requested} مستخدم بالفعل في دولاب آخر.\nسيتم استخدام الرقم #{replacement} بدلًا منه حتى تظل كل الوحدات والقطع Unique بدون #.")
        replacement
      else
        raise "اسم الوحدة «#{requested}» مستخدم بالفعل في دولاب آخر. اختر اسمًا مختلفًا حتى لا تظهر # في أسماء القطع."
      end
    end

    # === 10.53.33: Detached build for straight wardrobes ==================
    # نفس المعمارية التي نجحت في الركنة: نعمل Redraw للجذر الحقيقي أولًا،
    # ثم نبني كل الـGeometry على Instance مؤقت عند الـOrigin، وفي النهاية
    # نستبدل الجذر مع الحفاظ على نفس Transformation الخارجي بالضبط.
    def copy_all_entity_attributes_straight(source, target)
      dicts = source.attribute_dictionaries rescue nil
      return target unless dicts
      dicts.each do |dict|
        dict.each_pair do |key, value|
          begin
            target.set_attribute(dict.name, key, value)
          rescue
            nil
          end
        end
      end
      target
    end

    def parent_entities_for_straight(entity)
      parent = entity.parent rescue nil
      return parent.entities if parent && parent.respond_to?(:entities)
      Sketchup.active_model.entities
    end

    def make_detached_straight_work_root(source_root)
      parent_entities = parent_entities_for_straight(source_root)
      work = parent_entities.add_instance(source_root.definition, Geom::Transformation.new)
      copy_all_entity_attributes_straight(source_root, work)
      begin work.name = "__MHD_STRAIGHT_WORK__#{source_root.persistent_id}" rescue nil end
      begin work.layer = source_root.layer rescue nil end
      begin work.material = source_root.material rescue nil end
      begin work.make_unique rescue nil end
      begin work.hidden = true rescue nil end
      sign_straight_wardrobe!(work)
      work
    end

    def replace_straight_root_from_work!(display_root, work_root)
      parent_entities = parent_entities_for_straight(display_root)
      original_tr = display_root.transformation
      original_name = (display_root.name rescue '')
      original_layer = (display_root.layer rescue nil)
      original_material = (display_root.material rescue nil)
      original_hidden = (display_root.hidden? rescue false)
      original_locked = (display_root.locked? rescue false)

      final_root = parent_entities.add_instance(work_root.definition, original_tr)
      copy_all_entity_attributes_straight(work_root, final_root)
      begin final_root.name = original_name rescue nil end
      begin final_root.layer = original_layer if original_layer rescue nil end
      begin final_root.material = original_material if original_material rescue nil end
      begin final_root.hidden = original_hidden rescue nil end
      begin final_root.locked = original_locked rescue nil end
      sign_straight_wardrobe!(final_root)

      begin display_root.erase! if display_root.valid? rescue nil end
      begin work_root.erase! if work_root.valid? rescue nil end
      final_root
    end
    # ======================================================================

    def create_dressing(data)
      @drawer_template_cache = {}
      validate(data)
      model = Sketchup.active_model
      root = @current_wardrobe
      raise 'حدد دولاب المكتبة ثم افتح الأداة من جديد.' unless root && root.valid?
      raise 'هذه الوحدة ليست دريسنج مستقيم ولا يمكن تعديلها بهذه الأداة.' unless signed_straight_wardrobe?(root) || legacy_straight_wardrobe?(root)
      sign_straight_wardrobe!(root)
      display_root = root
      detached_work_root = nil
      # فحص سريع مرة واحدة على وحدات الدريسنج الرئيسية فقط، قبل start_operation
      # وقبل إنشاء أي هندسة، لمنع أي تعارض أسماء من الأصل.
      unique_unit_name = ensure_unique_dressing_unit_name!(data, model, root)
      @active_unit_name = unique_unit_name.to_s
      @naming_dictionary = data['naming_dictionary'].is_a?(Hash) ? data['naming_dictionary'] : {}
      @part_name_counters = Hash.new(0)

      # روابط الحركة Runtime تخص كل الدولايب الموجودة في الموديل، وليست دورة
      # الإنشاء الحالية فقط. تصفير الـHashes هنا كان يقطع حركة مفصلات/مجاري
      # الدولاب القديم فور إنشاء دولاب ثانٍ. نحافظ على الروابط المسجلة، ونترك
      # restore_motion_links ينظف فقط المراجع التي أصبحت غير صالحة بعد إعادة البناء.
      @drawer_slide_links ||= {}
      @drawer_slide_observers ||= {}
      @hinge_motion_links ||= {}
      @hinge_motion_observers ||= {}
      @syncing_hinge_motion = false
      @ocl_elita_drilled_instances = {}
      # كاشات دورة الإنشاء الحالية فقط؛ تُصفّر عند كل إنشاء حتى لا تحمل
      # أي مراجع من دولاب سابق أو من هندسة تم تعديلها.
      clear_joinery_records_cache
      @ocl_elita_drilled_instances = {}

      raise 'اكتب اسم أو رقم الوحدة أولًا.' if @active_unit_name.empty?
      requested_band = data['edge_band_pattern'].to_s
      @edge_band_pattern = case requested_band
      when 'all_around', 'pattern_1' then 'all_around'
      else 'visible_only'
      end
      data['edge_band_pattern'] = @edge_band_pattern
      model.start_operation('تعديل دريسنج - مكتبة محمد عادل', true)
      update_creation_progress(8, 'جاري تجهيز الشاسيه والمقاسات...')
      perf_measure('root.make_unique') { root.make_unique }

      h = data['height'].to_f.cm
      d = data['depth'].to_f.cm
      t = data['thickness'].to_f.cm
      bt = data['back_thickness'].to_f.cm
      bi = data['back_inset'].to_f.cm
      cut = data['shelf_front_cut'].to_f.cm
      bays = data['bays']
      easy_template = data['easy_template'].to_s
      layout_tree = data['layout_tree']
      sloped = slope_enabled?(data)
      wood_plinth = data['base_type'].to_s == 'wood_plinth'
      grooved_back = data['back_joint_mode'].to_s == 'grooved_partition'
      full_top = data['top_type'].to_s == 'full_top'
      side_extension = side_extension_for(data)
      # نولد الشاسيه في نمطي الضهر معًا. الرجوع إلى جسم الـDynamic Component
      # الأصلي في وضع «ضهر موصول» كان يغيّر اتجاه التكستشر وخامة شريط الأجناب.
      # الاختلاف بين النمطين يبقى في نجارة الضهر والقواطع فقط.
      generated_shell = true
      if sloped
        left_h = data['sloped_left_height'].to_f.cm
        right_h = data['sloped_right_height'].to_f.cm
        raise 'ارتفاع اليمين أو الشمال في الدولاب المائل صغير جدًا.' if [left_h, right_h].min <= t * 2
        h = [left_h, right_h].max
        data['height'] = h.to_f / 1.cm.to_f
      end
      if layout_tree.is_a?(Hash) || !easy_template.empty?
        total = data['width'].to_f.cm
        total = @current_wardrobe.bounds.width if total <= t * 2
        widths = [total - t * 2]
      elsif easy_template.empty?
        widths = bays.map { |bay| bay['width'].to_f.cm }
        total = widths.inject(0, :+) + t * (widths.length + 1)
      end
      @wall_reliefs = manual_wall_reliefs(data, total, d, h)
      @bay_depth_reliefs = expand_reliefs_to_bays(@wall_reliefs, layout_tree, total, t)
      @carcass_reliefs = @bay_depth_reliefs.map do |relief|
        if relief['proposal'].to_s == 'bay_depth'
          relief.merge('x0'=>relief['wall_x0'], 'x1'=>relief['wall_x1'],
                       'depth'=>relief['wall_depth'])
        else
          relief.dup
        end
      end
      @shelf_reliefs = @bay_depth_reliefs.map do |relief|
        if relief['proposal'].to_s == 'cladded_partition'
          relief.merge('depth'=>[relief['depth'].to_f-bi-bt,0.1.cm].max)
        else
          relief.dup
        end
      end
      generated_shell ||= !@wall_reliefs.empty?
      data['applied_wall_reliefs'] = @wall_reliefs.map do |relief|
        relief.transform_values { |value| (value.to_f / 1.cm.to_f).round(3) }
      end
      data['wall_relief_proposals'] = @bay_depth_reliefs.map do |relief|
        {
          'x0'=>(relief['x0'].to_f/1.cm.to_f).round(3),
          'x1'=>(relief['x1'].to_f/1.cm.to_f).round(3),
          'depth'=>(relief['depth'].to_f/1.cm.to_f).round(3),
          'mode'=>relief['proposal']
        }
      end

      set_original_shell_hidden(root, false)
      set_dc_cm(root, 'a1', total.to_f / 1.cm.to_f)
      set_dc_cm(root, 'a2', data['depth'])
      set_dc_cm(root, 'a3', data['height'])
      set_dc_cm(root, 'base_unit_1_d', data['thickness'])
      set_dc_cm(root, 'base_unit_1_g', data['door_clearance'] || 0.1)
      # ارتفاع الرجول في الـ Dynamic Component الأصلي (BASE_UNIT_1_A).
      # نحدّثه دائمًا حتى تظل الرجول نفسها جزءًا من الوحدة الأصلية وتتحرك بالـ DC.
      set_dc_cm(root, 'base_unit_1_a', [data['leg_height'].to_f, 0].max)
      root.set_attribute('dynamic_attributes', 'base_unit_1_a1', data['assembly'].to_s == 'full' ? '2' : '1')
      # لا نغيّر نوع الضلفة الأصلي؛ تغيير base_unit_1_e يجعل الـDC نفسه
      # يبدّل بين الخشب والزجاج قبل أن ننسخ مصادر الضلف.
      apply_dc_list_value(root, 'base_unit_1_j', data['material'])
      apply_dc_list_value(root, 'base_unit_1_f', data['door_material'])
      apply_dc_list_value(root, 'base_unit_1_h', data['back_material'])
      root.set_attribute('dynamic_attributes', 'base_unit_1_c', '0')

      # لازم نعمل Redraw واحد للجذر بعد تحديث المقاسات والخامات.
      # إلغاء هذا الـRedraw يترك الـDynamic Component على أبعاده القديمة،
      # فيظهر Bounding Box ضخم ويتزحزح الشاسيه/الأجزاء عن مكانها.
      # سنعالج البطء في مراحل الإنشاء الداخلية بدل كسر تحديث الجذر.
      redraw_dc(root)
      update_creation_progress(22, 'جاري تحديث الشاسيه الأساسي...')
      set_original_back_hidden(root, true)

      @back_groove_context = if grooved_back
        {
          'enabled' => true,
          'y0' => d - bi - bt,
          'y1' => d - bi,
          'depth' => data['back_groove_depth'].to_f.cm
        }
      end

      if sloped
        @slope_context = {
          'width' => total,
          'left' => data['sloped_left_height'].to_f.cm,
          'right' => data['sloped_right_height'].to_f.cm,
          'thickness' => t
        }
      else
        @slope_context = nil
      end
      @sliding_context = nil
      @full_height_partition_span = nil
      # في نمط المفحار نعيد توليد جسم الشاسيه بقطاع حقيقي؛ إخفاء الجسم
      # الأصلي هنا لا يشمل الأرجل أو الإكسسوارات.
      set_original_shell_hidden(root, sloped || generated_shell)
      set_base_hardware_hidden(root, wood_plinth)

      # بعد الـRedraw أصبحت قيم الـDC الفعلية جاهزة، فنقرأها مباشرة.
      carcass_name = dc_effective_value(root, 'base_unit_1_j', 'كونتر ابيض')
      door_name = dc_effective_value(root, 'base_unit_1_f', 'HPL')
      back_name = dc_effective_value(root, 'base_unit_1_h', 'ضهر ابيض')
      carcass = mat(model, carcass_name.empty? ? 'كونتر ابيض' : carcass_name, Sketchup::Color.new(235, 235, 225))
      back_mat = mat(model, back_name.empty? ? 'ضهر ابيض' : back_name, Sketchup::Color.new(248, 248, 248))
      door_mat = mat(model, door_name.empty? ? 'HPL' : door_name, Sketchup::Color.new(235, 235, 225))
      @current_door_material = door_mat
      @edge_band_materials = prepare_edge_band_materials(model, carcass, door_mat)
      @board_violations = []
      @board_limits = {
        'carcass_material' => carcass.name.to_s,
        'carcass_width' => data['carcass_board_width'].to_f,
        'carcass_length' => data['carcass_board_length'].to_f,
        'door_width' => data['door_board_width'].to_f,
        'door_length' => data['door_board_length'].to_f,
        'back_width' => data['back_board_width'].to_f,
        'back_length' => data['back_board_length'].to_f
      }
      # The original wardrobe carcass is a Dynamic Component and is not
      # generated through add_box, so its principal panels must be checked
      # explicitly against the selected carcass sheet.
      unless sloped || generated_shell
        check_board_limit('جنب الشاسيه الأيمن', t, d, h, carcass, ['MAIN_CARCASS'])
        check_board_limit('جنب الشاسيه الأيسر', t, d, h, carcass, ['MAIN_CARCASS'])
        check_board_limit('قاعدة الشاسيه', total, d, t, carcass, ['MAIN_CARCASS'])
        check_board_limit('قرصة الشاسيه العلوية', total, d, t, carcass, ['MAIN_CARCASS'])
      end
      # من هنا تبدأ تعديلات الـGeometry الفعلية. نبنيها على Root مؤقت
      # منفصل عن الـInstance الذي قد يكون المستخدم حرّكه داخل الرسم.
      update_creation_progress(30, 'جاري تجهيز نسخة بناء محلية سريعة...')
      detached_work_root = make_detached_straight_work_root(display_root)
      root = detached_work_root
      @current_wardrobe = root

      root.definition.entities.grep(Sketchup::Group).each do |group|
        group.erase! if group.get_attribute('MHD_DRESSING', 'TYPE') == INTERIOR_MARK
      end
      interior = root.definition.entities.add_group
      interior.name = INTERIOR_MARK
      interior.set_attribute('MHD_DRESSING', 'TYPE', INTERIOR_MARK)
      entities = interior.entities
      update_creation_progress(35, 'جاري إنشاء التقسيمات الداخلية...')
      back_regions = nil
      if layout_tree.is_a?(Hash)
        preview_inner_width = total-t*2
        back_regions = collect_column_regions(layout_tree, t, preview_inner_width, t)
        @horizontal_back_grooves = build_horizontal_back_grooves(back_regions, total, d, t, bt, bi, data)
      else
        @horizontal_back_grooves = []
      end
      if sloped
        build_sloped_shell(entities, model, total, d, t, bt, bi, carcass, back_mat, data)
      elsif generated_shell
        build_straight_grooved_shell(entities, model, total, d, h, t, carcass, data)
      end
      build_top_cornice(entities, model, total, d, h, t, carcass, data)
      build_wood_plinth(entities, model, total, d, t, carcass, data) if wood_plinth
      build_wall_column_claddings(entities, model, total, d, h, t, carcass)

      if layout_tree.is_a?(Hash)
        inner_width = total - t * 2
        available_depth = d - bi - bt
        layout_height = h - t * 2
        back_regions ||= collect_column_regions(layout_tree, t, inner_width, t)
        @naming_columns = back_regions
        build_column_backs(entities, model, back_regions, total, d, h, t, bt, bi, back_mat, data)
        fixed_shelf_z = nil
        if %w[yes true 1].include?(data['fixed_top_shelf'].to_s.downcase)
          clear_top = [data['fixed_top_clear_height'].to_f, 1.0].max.cm
          fixed_shelf_z = h - t * 2 - clear_top
          raise 'ارتفاع الفراغ العلوي الثابت أكبر من المساحة الداخلية للدولاب.' if fixed_shelf_z <= t
          layout_height = fixed_shelf_z - t
        end
        @sliding_context = prepare_sliding_context(data, layout_tree, t, inner_width,
                                                   h, t, t, layout_height)
        @full_height_partition_span = [t, t + layout_height]
        template_shelf(entities, model, t, inner_width, fixed_shelf_z, available_depth, t, carcass, 'ثابت علوي', cut) if fixed_shelf_z
        build_layout_tree(layout_tree, entities, model, t, t, inner_width, layout_height, available_depth, t, carcass, back_mat, door_mat, data)
        update_creation_progress(58, 'جاري تركيب الأرفف والأدراج...')
        build_column_doors(root, layout_tree, t, inner_width, h, t, data['door_clearance'].to_f.cm, door_mat, data['door_system'], t, layout_height, data, entities, d, carcass)
        update_creation_progress(72, 'جاري تجهيز الضلف والمفصلات...')
        build_hinge_cup_drilling(root, data)
        update_creation_progress(77, 'تم تجهيز المفصلات — جاري مراجعة المقاسات...')
        raise_board_violations!
        # purge_unused ثقيل جدًا مع الـDynamic Components ويجبر SketchUp
        # على تحليل Definitions المكتبة كلها. تنظيف الموديل ليس شرطًا للإنشاء.
        update_creation_progress(80, 'جاري تثبيت أسماء وتعريفات القطع...')
        release_names_held_by_hidden_definitions(root.definition.entities)
        qualify_component_tree(root.definition.entities)
        clear_joinery_records_cache
        update_creation_progress(85, 'جاري تجهيز سجل قطع التجميع...')
        # أول استدعاء يبني Scan واحد؛ باقي مراحل التجميع تستخدم نفس السجل.
        build_butterfly_joinery(root.definition.entities, entities, model, data)
        update_creation_progress(88, 'جاري تنفيذ الإليتا والتخريمات...')
        build_elita_joinery(root.definition.entities, entities, model, data)
        update_creation_progress(91, 'جاري إنهاء تجميع الكورنيشة والسوكلو...')
        build_cornice_plinth_joinery(root.definition.entities, entities, model, data)
        clear_joinery_records_cache
        update_creation_progress(94, 'تم تجهيز أوجه التصنيع من البداية...')
        update_creation_progress(96, 'جاري تثبيت المسميات وبيانات الوحدة...')
        sanitize_final_part_names(root.definition.entities)
        stored = data.merge('version' => VERSION, 'dressing_unit_type' => DRESSING_TYPE, 'unit_signature' => DRESSING_SIGNATURE, 'total_width' => (total.to_f / 1.cm.to_f).round(3))
        sign_straight_wardrobe!(root)
        [root, root.definition].each { |owner| owner.set_attribute('MHD_DRESSING', 'DATA_JSON', JSON.generate(stored)) }
        if detached_work_root && display_root && display_root.valid?
          root = replace_straight_root_from_work!(display_root, detached_work_root)
          detached_work_root = nil
          display_root = root
          @current_wardrobe = root
        end
        model.selection.clear
        model.selection.add(root)
        update_creation_progress(98, 'جاري إنهاء الدولاب وتحديده...')
        model.commit_operation
        @slope_context = nil
        @sliding_context = nil
        @full_height_partition_span = nil
        @back_groove_context = nil
        @edge_band_pattern = nil
        @edge_band_materials = nil
        @current_door_material = nil
        @wall_reliefs = nil
        @bay_depth_reliefs = nil
        @horizontal_back_grooves = nil
        @carcass_reliefs = nil
        @shelf_reliefs = nil
        @joinery_records_cache = nil
        @ocl_elita_drilled_instances = nil
        model.active_view.zoom(root)
        return root
      elsif !easy_template.empty?
        inner_width = total - t * 2
        available_depth = d - bi - bt
        template_height = h
        build_column_backs(entities, model, [{'x'=>t, 'width'=>inner_width}], total, d, h, t, bt, bi, back_mat, data)
        if %w[yes true 1].include?(data['fixed_top_shelf'].to_s.downcase)
          clear_top = [data['fixed_top_clear_height'].to_f, 1.0].max.cm
          fixed_shelf_z = h - t * 2 - clear_top
          raise 'ارتفاع الفراغ العلوي الثابت أكبر من المساحة الداخلية للدولاب.' if fixed_shelf_z <= t
          template_shelf(entities, model, t, inner_width, fixed_shelf_z, available_depth, t, carcass, 'ثابت علوي', cut)
          template_height = fixed_shelf_z + t
        end
        build_easy_template(easy_template, entities, model, t, inner_width, available_depth, template_height, t, carcass, back_mat, door_mat, data)
        update_creation_progress(62, 'جاري إنشاء التقسيمة المختارة...')
        raise_board_violations!
        update_creation_progress(78, 'جاري تثبيت أسماء وتعريفات القطع...')
        release_names_held_by_hidden_definitions(root.definition.entities)
        qualify_component_tree(root.definition.entities)
        clear_joinery_records_cache
        update_creation_progress(85, 'جاري تجهيز سجل قطع التجميع...')
        # أول استدعاء يبني Scan واحد؛ باقي مراحل التجميع تستخدم نفس السجل.
        build_butterfly_joinery(root.definition.entities, entities, model, data)
        update_creation_progress(88, 'جاري تنفيذ الإليتا والتخريمات...')
        build_elita_joinery(root.definition.entities, entities, model, data)
        update_creation_progress(91, 'جاري إنهاء تجميع الكورنيشة والسوكلو...')
        build_cornice_plinth_joinery(root.definition.entities, entities, model, data)
        clear_joinery_records_cache
        update_creation_progress(94, 'تم تجهيز أوجه التصنيع من البداية...')
        update_creation_progress(96, 'جاري تثبيت المسميات وبيانات الوحدة...')
        sanitize_final_part_names(root.definition.entities)
        stored = data.merge('version' => VERSION, 'dressing_unit_type' => DRESSING_TYPE, 'unit_signature' => DRESSING_SIGNATURE, 'total_width' => (total.to_f / 1.cm.to_f).round(3))
        sign_straight_wardrobe!(root)
        [root, root.definition].each { |owner| owner.set_attribute('MHD_DRESSING', 'DATA_JSON', JSON.generate(stored)) }
        if detached_work_root && display_root && display_root.valid?
          root = replace_straight_root_from_work!(display_root, detached_work_root)
          detached_work_root = nil
          display_root = root
          @current_wardrobe = root
        end
        model.selection.clear
        model.selection.add(root)
        update_creation_progress(98, 'جاري إنهاء الدولاب وتحديده...')
        model.commit_operation
        @slope_context = nil
        @full_height_partition_span = nil
        @back_groove_context = nil
        @edge_band_pattern = nil
        @edge_band_materials = nil
        @current_door_material = nil
        @wall_reliefs = nil
        @bay_depth_reliefs = nil
        @horizontal_back_grooves = nil
        @carcass_reliefs = nil
        @shelf_reliefs = nil
        @joinery_records_cache = nil
        @ocl_elita_drilled_instances = nil
        model.active_view.zoom(root)
        return root
      end

      current_x = t
      legacy_back_regions = []
      back_cursor = t
      widths.each_with_index do |bay_width, bay_index|
        back_cursor += t if bay_index > 0
        legacy_back_regions << {'x'=>back_cursor, 'width'=>bay_width}
        back_cursor += bay_width
      end
      build_column_backs(entities, model, legacy_back_regions, total, d, h, t, bt, bi, back_mat, data)
      update_creation_progress(50, 'جاري إنشاء التقسيمات الداخلية...')
      full_partition_cut = partition_front_cut(data, t, h - t)
      legacy_partition_depth = partition_depth_for_back(d - bi - bt, data)
      widths.each_with_index do |bay_width, bay_index|
        if bay_index > 0
          add_vertical_panel(entities, model, "جنب قاطع #{bay_index} #{PART_SUFFIX}", current_x, full_partition_cut, t, t, legacy_partition_depth - full_partition_cut, h - t * 2, carcass, ['PARTITION'], :both)
          current_x += t
        end
        bay = bays[bay_index]
        count = bay['shelves'].to_i
        preset = bay['preset'].to_s
        preset = 'shelves' if preset.empty?
        bay_cut = [bay['shelf_front_cut'].to_f.cm, 0].max
        bay_cut = cut if bay_cut <= 0 && cut > 0
        shelf_depth = d - bi - bt - bay_cut
        raise "قص الرف من الأمام أكبر من العمق المتاح في الفتحة #{bay_index + 1}." if shelf_depth <= 0
        bay_number = bay_index + 1
        case preset
        when 'hanging'
          add_box(entities, model, "رف علوي فتحة #{bay_number} #{PART_SUFFIX}", current_x, bay_cut, h * 0.78, bay_width, shelf_depth, t, carcass)
          add_rod(entities, model, current_x, bay_width, shelf_depth, h * 0.70, t, carcass, bay_number)
        when 'double_hang'
          add_box(entities, model, "رف فاصل فتحة #{bay_number} #{PART_SUFFIX}", current_x, bay_cut, h * 0.50, bay_width, shelf_depth, t, carcass)
          add_rod(entities, model, current_x, bay_width, shelf_depth, h * 0.42, t, carcass, bay_number, 1)
          add_rod(entities, model, current_x, bay_width, shelf_depth, h * 0.88, t, carcass, bay_number, 2)
        when 'drawers'
          stack = [bay['drawer_height'].to_f, 75.0].reject { |v| v <= 0 }.first.cm
          drawer_config = bay.merge(
            '_back_inset' => data['back_inset'], '_back_thickness' => data['back_thickness'],
            'inner_drawer_joinery' => (bay['inner_drawer_joinery'] || 'screw'),
            'inner_elita_edge_offset' => (bay['inner_elita_edge_offset'] || data['elita_edge_offset'] || 5),
            'inner_elita_screw_drill_diameter' => (bay['inner_elita_screw_drill_diameter'] || data['elita_screw_drill_diameter'] || 0.8),
            'inner_elita_dowel_diameter' => (bay['inner_elita_dowel_diameter'] || data['elita_dowel_diameter'] || 0.8),
            'inner_elita_dowel_depth' => (bay['inner_elita_dowel_depth'] || data['elita_dowel_depth'] || 1.05),
            'inner_elita_cam_diameter' => (bay['inner_elita_cam_diameter'] || data['elita_cam_diameter'] || 1.5),
            'inner_elita_cam_depth' => (bay['inner_elita_cam_depth'] || data['elita_cam_depth'] || 1.2),
            'inner_elita_screw_after_thread' => (bay['inner_elita_screw_after_thread'] || data['elita_screw_after_thread'] || 3.2),
            'inner_elita_coil_count' => (bay['inner_elita_coil_count'] || data['elita_coil_count'] || 1),
            'inner_elita_coil_drill_diameter' => (bay['inner_elita_coil_drill_diameter'] || data['elita_coil_drill_diameter'] || 0.8),
            'inner_elita_coil_length' => (bay['inner_elita_coil_length'] || data['elita_coil_length'] || 4.0),
            'inner_elita_coil_face_depth' => (bay['inner_elita_coil_face_depth'] || data['elita_coil_face_depth'] || 2.0),
            'inner_elita_coil_center_distance' => (bay['inner_elita_coil_center_distance'] || data['elita_coil_center_distance'] || 2.5)
          )
          add_drawer_stack(entities, model, current_x, bay_width, d, t, bay['drawers'].to_i, stack, carcass, back_mat, door_mat, bay_number, drawer_config)
          add_shelves(entities, model, current_x, bay_width, shelf_depth, h, t, count, bay_cut, carcass, bay_number, t + stack, h - t)
        when 'drawers_hang'
          stack = [bay['drawer_height'].to_f, 65.0].reject { |v| v <= 0 }.first.cm
          drawer_config = bay.merge(
            '_back_inset' => data['back_inset'], '_back_thickness' => data['back_thickness'],
            'inner_drawer_joinery' => (bay['inner_drawer_joinery'] || 'screw'),
            'inner_elita_edge_offset' => (bay['inner_elita_edge_offset'] || data['elita_edge_offset'] || 5),
            'inner_elita_screw_drill_diameter' => (bay['inner_elita_screw_drill_diameter'] || data['elita_screw_drill_diameter'] || 0.8),
            'inner_elita_dowel_diameter' => (bay['inner_elita_dowel_diameter'] || data['elita_dowel_diameter'] || 0.8),
            'inner_elita_dowel_depth' => (bay['inner_elita_dowel_depth'] || data['elita_dowel_depth'] || 1.05),
            'inner_elita_cam_diameter' => (bay['inner_elita_cam_diameter'] || data['elita_cam_diameter'] || 1.5),
            'inner_elita_cam_depth' => (bay['inner_elita_cam_depth'] || data['elita_cam_depth'] || 1.2),
            'inner_elita_screw_after_thread' => (bay['inner_elita_screw_after_thread'] || data['elita_screw_after_thread'] || 3.2),
            'inner_elita_coil_count' => (bay['inner_elita_coil_count'] || data['elita_coil_count'] || 1),
            'inner_elita_coil_drill_diameter' => (bay['inner_elita_coil_drill_diameter'] || data['elita_coil_drill_diameter'] || 0.8),
            'inner_elita_coil_length' => (bay['inner_elita_coil_length'] || data['elita_coil_length'] || 4.0),
            'inner_elita_coil_face_depth' => (bay['inner_elita_coil_face_depth'] || data['elita_coil_face_depth'] || 2.0),
            'inner_elita_coil_center_distance' => (bay['inner_elita_coil_center_distance'] || data['elita_coil_center_distance'] || 2.5)
          )
          add_drawer_stack(entities, model, current_x, bay_width, d, t, bay['drawers'].to_i, stack, carcass, back_mat, door_mat, bay_number, drawer_config)
          add_box(entities, model, "رف فوق الأدراج فتحة #{bay_number} #{PART_SUFFIX}", current_x, bay_cut, t + stack, bay_width, shelf_depth, t, carcass)
          add_rod(entities, model, current_x, bay_width, shelf_depth, h * 0.82, t, carcass, bay_number)
        when 'split_mix'
          half = (bay_width - t) / 2.0
          add_vertical_panel(entities, model, "جنب قاطع داخلي فتحة #{bay_number} #{PART_SUFFIX}", current_x + half, full_partition_cut, t, t, legacy_partition_depth - full_partition_cut, h - t * 2, carcass, ['PARTITION'], :both)
          add_shelves(entities, model, current_x, half, shelf_depth, h, t, [count, 3].max, bay_cut, carcass, bay_number)
          add_rod(entities, model, current_x + half + t, half, shelf_depth, h * 0.78, t, carcass, bay_number)
        else
          custom = add_shelves_at_levels(entities, model, current_x, bay_width, shelf_depth, t, bay['shelf_levels'], bay_cut, carcass, bay_number, h)
          add_shelves(entities, model, current_x, bay_width, shelf_depth, h, t, count, bay_cut, carcass, bay_number) unless custom
        end
        current_x += bay_width
      end

      raise_board_violations!
      update_creation_progress(78, 'جاري تثبيت أسماء وتعريفات القطع...')
      release_names_held_by_hidden_definitions(root.definition.entities)
      qualify_component_tree(root.definition.entities)
      clear_joinery_records_cache
      update_creation_progress(85, 'جاري تجهيز سجل قطع التجميع...')
      build_butterfly_joinery(root.definition.entities, entities, model, data)
      update_creation_progress(88, 'جاري تنفيذ الإليتا والتخريمات...')
      build_elita_joinery(root.definition.entities, entities, model, data)
      update_creation_progress(91, 'جاري إنهاء تجميع الكورنيشة والسوكلو...')
      build_cornice_plinth_joinery(root.definition.entities, entities, model, data)
      clear_joinery_records_cache
      # إليتا شاسيه الدرج الداخلي تم تنفيذها أثناء إنشاء كل درج وقبل
      # تحويله إلى Dynamic Component، لذلك لا نعيد مسح الأدراج هنا.
      update_creation_progress(94, 'تم تجهيز أوجه التصنيع من البداية...')
      update_creation_progress(96, 'جاري تثبيت المسميات وبيانات الوحدة...')
      sanitize_final_part_names(root.definition.entities)
      stored = data.merge('version' => VERSION, 'dressing_unit_type' => DRESSING_TYPE, 'unit_signature' => DRESSING_SIGNATURE, 'total_width' => (total.to_f / 1.cm.to_f).round(3))
      sign_straight_wardrobe!(root)
      [root, root.definition].each do |owner|
        owner.set_attribute('MHD_DRESSING', 'DATA_JSON', JSON.generate(stored))
      end
      if detached_work_root && display_root && display_root.valid?
        root = replace_straight_root_from_work!(display_root, detached_work_root)
        detached_work_root = nil
        display_root = root
        @current_wardrobe = root
      end
      model.selection.clear
      model.selection.add(root)
      update_creation_progress(98, 'جاري إنهاء الدولاب وتحديده...')
      model.commit_operation
      @slope_context = nil
      @sliding_context = nil
      @full_height_partition_span = nil
      @back_groove_context = nil
      @edge_band_pattern = nil
      @edge_band_materials = nil
      @wall_reliefs = nil
      @bay_depth_reliefs = nil
      @horizontal_back_grooves = nil
      @carcass_reliefs = nil
      @shelf_reliefs = nil
      @joinery_records_cache = nil
      @ocl_elita_drilled_instances = nil
      model.active_view.zoom(root)
      root
    rescue => error
      @slope_context = nil
      @sliding_context = nil
      @full_height_partition_span = nil
      @back_groove_context = nil
      @edge_band_pattern = nil
      @edge_band_materials = nil
      @wall_reliefs = nil
      @bay_depth_reliefs = nil
      @horizontal_back_grooves = nil
      @carcass_reliefs = nil
      @shelf_reliefs = nil
      @joinery_records_cache = nil
      @ocl_elita_drilled_instances = nil
      @active_unit_name = nil
      begin
        detached_work_root.erase! if defined?(detached_work_root) && detached_work_root && detached_work_root.valid?
      rescue
        nil
      end
      model.abort_operation if defined?(model) && model
      @current_wardrobe = display_root if defined?(display_root) && display_root && display_root.valid?
      raise error
    end

    def html_escape(value)
      value.to_s.gsub('&', '&amp;').gsub('"', '&quot;').gsub('<', '&lt;').gsub('>', '&gt;')
    end

    def html_dc_options(options)
      options.map do |option|
        value = html_escape(option['value'])
        label = html_escape(option['label'])
        %(<option value="#{value}">#{label}</option>)
      end.join
    end

    def html(data)
      door_options = dc_list_options(@current_wardrobe, 'base_unit_1_f', [
        {'label'=>'HPL','value'=>'HPL'}, {'label'=>'POLYLACK','value'=>'POLYLACK'},
        {'label'=>'UVLACK','value'=>'UVLACK'}, {'label'=>'PVC','value'=>'PVC'},
        {'label'=>'MELAMIN','value'=>'MELAMIN'}
      ])
      carcass_options = dc_list_options(@current_wardrobe, 'base_unit_1_j', [
        {'label'=>'كونتر ابيض','value'=>'كونتر ابيض'},
        {'label'=>'كونتر خشابي','value'=>'كونتر خشابي'},
        {'label'=>'بنفس خامة الضلفة','value'=>'=BASE_UNIT_1!BASE_UNIT_1_f'}
      ])
      back_options = dc_list_options(@current_wardrobe, 'base_unit_1_h', [
        {'label'=>'ضهر ابيض','value'=>'ضهر ابيض'},
        {'label'=>'ضهر خشابي','value'=>'ضهر خشابي'},
        {'label'=>'ضهر ميلامين','value'=>'ضهر ميلامين'}
      ])
      door_material_options = html_dc_options(door_options)
      carcass_material_options = html_dc_options(carcass_options)
      back_material_options = html_dc_options(back_options)
      <<-HTML
<!DOCTYPE html><html lang="ar" dir="rtl"><head><meta charset="UTF-8"><title>#{TITLE}</title>
<style>
*{box-sizing:border-box}body{margin:0;background:#07131d;color:#eaf4f8;font-family:Tahoma,Arial,sans-serif;overflow:hidden}.app{height:100vh;display:flex;flex-direction:column}.head{height:70px;display:flex;align-items:center;padding:8px 14px;background:linear-gradient(135deg,#07131d,#0d2635);border-bottom:1px solid #203948}.logo{width:54px;height:54px;object-fit:contain;border:1px solid #203948;border-radius:9px;padding:4px}.title{flex:1;text-align:center;font-size:21px;font-weight:900}.sub{display:block;color:#8fa9b9;font-size:11px;margin-top:4px}.main{flex:1;min-height:0;display:flex;direction:ltr;gap:10px;padding:10px}.panel{direction:rtl;background:#0b1b27;border:1px solid #203948;border-radius:10px;overflow:hidden;min-height:0}.options{width:370px;min-width:330px}.preview{flex:1;min-width:420px}.panel-title{height:40px;padding:10px 12px;background:#0f2533;color:#4de37a;font-weight:900}.editor{height:calc(100% - 40px);overflow:auto;padding:10px 10px 25px}.section{border-bottom:1px solid #203948;padding-bottom:10px;margin-bottom:10px}.section-title{font-weight:900;color:#8ad8ff;margin-bottom:8px}.grid2{display:grid;grid-template-columns:1fr 1fr;gap:7px}.field{margin-bottom:7px}.field label{display:block;font-size:11px;font-weight:800;margin-bottom:4px;color:#bcd0db}.field input,.field select{width:100%;height:33px;background:#081720;color:#fff;border:1px solid #294557;border-radius:6px;padding:0 7px;outline:none}.field input:focus,.field select:focus{border-color:#4de37a}.presets{display:grid;grid-template-columns:repeat(3,1fr);gap:6px;margin-bottom:9px}.preset{height:58px;background:#102735;color:#fff;border:1px solid #294557;border-radius:7px;font-size:10px;font-weight:800;cursor:pointer}.preset span{display:block;color:#8ad8ff;font-size:18px;line-height:20px}.preset.active{border-color:#ffd54f;background:#3a3820}.template-section-locked{opacity:.38;filter:saturate(.35);pointer-events:none;user-select:none}.template-section-locked #templateTargetHint{color:#8fa9b9!important}.template-section-locked .template-card{cursor:not-allowed}.bay{display:grid;grid-template-columns:28px 1fr 1fr 30px;gap:5px;align-items:end;padding:7px;margin-bottom:6px;background:#0e2230;border:1px solid #203948;border-radius:8px;cursor:pointer}.bay.active{border-color:#ffd54f;background:#263023}.bay-num{align-self:center;width:25px;height:25px;border-radius:50%;background:#173648;display:flex;align-items:center;justify-content:center;font-weight:900}.bay label{font-size:10px;color:#9eb5c2}.bay input{width:100%;height:30px;background:#07131d;color:#fff;border:1px solid #294557;border-radius:5px;text-align:center}.del{height:30px;border:0;border-radius:5px;background:#7f3030;color:#fff;font-weight:900;cursor:pointer}.add{width:100%;height:36px;border:1px dashed #4de37a;border-radius:7px;background:#123326;color:#fff;font-weight:900;cursor:pointer}.canvas-wrap{height:calc(100% - 40px);padding:12px;display:flex;flex-direction:column}.canvas{width:100%;flex:1;min-height:350px;background:#06121b;border:1px solid #203948;border-radius:8px}.hint{text-align:center;color:#91aaba;font-size:11px;margin-top:7px}.foot{height:58px;border-top:1px solid #203948;padding:8px 12px;display:flex;gap:8px}.create{flex:2;background:#4de37a;color:#061d13;border:0;border-radius:9px;font-weight:900;font-size:15px;cursor:pointer}.cancel{flex:1;background:#102735;color:#fff;border:1px solid #294557;border-radius:9px;font-weight:900;cursor:pointer}.wood{fill:#b98b58;stroke:#f1d0a6;stroke-width:1.2}.inside{fill:#102735;stroke:#355365;stroke-width:1}.selected{fill:#3c3b20;stroke:#ffd54f;stroke-width:3}.shelf{stroke:#f1d0a6;stroke-width:3}.rod{stroke:#8ad8ff;stroke-width:5}.drawer{fill:#825c42;stroke:#f1d0a6;stroke-width:1}.dim{fill:#8ad8ff;font-size:12px;font-weight:bold}.label{fill:#fff;font-size:12px;font-weight:bold}::-webkit-scrollbar{width:8px}::-webkit-scrollbar-thumb{background:#294557;border-radius:8px}@media(max-width:800px){.main{overflow:auto}.options{min-width:320px}.preview{min-width:400px}}
.template-grid{display:grid;grid-template-columns:repeat(4,1fr);gap:7px;max-height:220px;overflow-y:auto;padding-left:5px;scrollbar-gutter:stable}.template-card{height:105px;background:#0e2230;border:1px solid #294557;border-radius:8px;color:#fff;cursor:pointer;padding:5px}.template-card:hover{border-color:#8ad8ff}.template-card.active{border:2px solid #ffd54f;background:#293022}.template-card svg{display:block;width:100%;height:74px;background:#07131d;border-radius:5px}.template-card small{display:block;text-align:center;margin-top:3px}.advanced-section{display:none}.advanced-on .advanced-section{display:block}.advanced-toggle{width:100%;height:36px;border:1px solid #42677c;border-radius:7px;background:#102735;color:#bfe5f7;font-weight:900;cursor:pointer;margin-top:9px}
.modal-overlay{display:none;position:fixed;inset:0;z-index:5000;background:rgba(2,10,16,.78);align-items:center;justify-content:center;backdrop-filter:blur(3px)}.modal-overlay.show{display:flex}.rules-modal{width:min(650px,88vw);max-height:88vh;overflow:auto;background:#0b1b27;border:1px solid #355365;border-radius:14px;box-shadow:0 18px 60px rgba(0,0,0,.55);direction:rtl}.rules-head{display:flex;align-items:center;padding:14px 16px;background:#0f2533;border-bottom:1px solid #294557}.rules-title{flex:1;color:#4de37a;font-size:18px;font-weight:900}.rules-close{width:34px;height:34px;border:0;border-radius:7px;background:#7f3030;color:#fff;font-size:18px;cursor:pointer}.rules-body{padding:14px}.rule-card{padding:11px;margin-bottom:10px;border:1px solid #294557;border-radius:9px;background:#0e2230}.rule-card h3{margin:0 0 9px;color:#8ad8ff;font-size:14px}.rules-note{color:#91aaba;font-size:11px;line-height:1.7}.rules-foot{display:flex;gap:8px;padding:12px 14px;border-top:1px solid #294557}.rules-save{flex:2;height:40px;border:0;border-radius:8px;background:#4de37a;color:#062113;font-weight:900;cursor:pointer}.rules-cancel{flex:1;height:40px;border:1px solid #42677c;border-radius:8px;background:#102735;color:#fff;font-weight:900;cursor:pointer}
.error-modal{width:min(760px,90vw)}.error-head{background:linear-gradient(135deg,#351719,#492023)}.error-head .rules-title{color:#ffb0a8}.error-summary{padding:11px 12px;margin-bottom:10px;border:1px solid #7f3030;border-radius:8px;background:#32191b;color:#ffd4cf;font-weight:800}.error-table-wrap{max-height:340px;overflow:auto;border:1px solid #294557;border-radius:8px}.error-table{width:100%;border-collapse:collapse;font-size:12px}.error-table th{position:sticky;top:0;background:#173648;color:#8ad8ff;padding:9px 7px}.error-table td{padding:9px 7px;border-top:1px solid #203948;text-align:center}.error-table td:first-child{text-align:right;font-weight:800}.error-table tr:nth-child(even){background:#0e2230}.edit-rules{background:#ffd54f;color:#231d05}
.option-tabs{position:sticky;top:-10px;z-index:20;display:grid;grid-template-columns:repeat(4,1fr);gap:5px;margin:-10px -10px 12px;padding:9px 10px;background:#0b1b27;border-bottom:1px solid #294557}.option-tab{height:38px;border:1px solid #355365;border-radius:8px;background:#102735;color:#bcd0db;font-weight:900;cursor:pointer;font-size:10px}.option-tab.active{background:#173f32;border-color:#4de37a;color:#4de37a;box-shadow:0 0 0 1px rgba(77,227,122,.18) inset}.option-tab-section{display:none}.editor.options-view-structure .tab-structure{display:block}.editor.options-view-layout .tab-layout:not(.advanced-section){display:block}.editor.options-view-accessories .tab-accessories{display:block}.editor.options-view-sloped .tab-sloped{display:block}.tab-intro{padding:10px;border:1px solid #294557;border-radius:8px;background:#0e2230;color:#91aaba;font-size:11px;line-height:1.7;text-align:center}.tab-intro strong{display:block;color:#8ad8ff;font-size:14px;margin-bottom:4px}.compact-note{color:#91aaba;font-size:10px;text-align:center;margin-top:5px}.editor .compact-note,.editor .tab-intro,.editor .empty-selection,.preview .hint{display:none!important}.part-hit{cursor:pointer}.part-hit:hover{filter:drop-shadow(0 0 4px #4de37a)}.part-selected{stroke:#ffd54f!important;stroke-width:6!important}.selection-card{border:1px solid #4de37a;border-radius:9px;background:#0d2a22;padding:10px;margin-bottom:9px}.selection-name{color:#ffd54f;font-weight:900;text-align:center;margin-bottom:4px}.empty-selection{padding:18px 10px;text-align:center;color:#91aaba;border:1px dashed #355365;border-radius:8px;line-height:1.8}
.tool-error-message{padding:18px;border:1px solid #7f3030;border-radius:10px;background:#32191b;color:#ffd4cf;font-size:14px;font-weight:800;line-height:1.9;text-align:center;white-space:pre-line}
.creation-loader{width:min(450px,82vw);padding:24px;background:#0b1b27;border:1px solid #355365;border-radius:15px;box-shadow:0 18px 60px rgba(0,0,0,.6);text-align:center;direction:rtl}.creation-loader-title{font-size:21px;font-weight:900;color:#fff;letter-spacing:.5px}.creation-loader-text{margin:18px 0;color:#d8e8ef;font-size:14px;font-weight:800}.creation-progress-track{height:10px;border:1px solid #355365;border-radius:20px;background:#07131d;overflow:hidden}.creation-progress-bar{width:4%;height:100%;border-radius:20px;background:linear-gradient(90deg,#25a94f,#4de37a);transition:width .28s ease}.creation-progress-value{margin-top:9px;color:#91aaba;font-size:12px}
.structure-group{margin:0 0 8px;border:1px solid #294557;border-radius:9px;background:#0a1a25;overflow:hidden}.structure-group summary{list-style:none;padding:10px 12px;background:#0e2230;color:#8ad8ff;font-size:13px;font-weight:900;cursor:pointer}.structure-group summary::-webkit-details-marker{display:none}.structure-group summary:before{content:'▼';display:inline-block;margin-left:7px;color:#4de37a;font-size:10px}.structure-group:not([open]) summary:before{content:'◀'}.structure-group-body{padding:9px}.global-settings-button{margin-top:8px}
</style></head><body><div class="app">
<div class="head"><img class="logo" src="#{LOGO_URL}"><div class="title">مكتبة محمد عادل - تصميم الدريسنج<span class="sub">كوّن الشاسيه والتقسيمات وشاهد النتيجة قبل الإنشاء</span></div></div>
<div class="main">
 <div class="panel options"><div class="panel-title">الاختيارات</div><div id="optionsEditor" class="editor options-view-structure">
  <div style="border:1px solid #4de37a;border-radius:8px;padding:9px;margin-bottom:10px;background:#0d2a22"><div class="field" style="margin:0"><label style="color:#4de37a;font-size:12px">اسم أو رقم الوحدة</label><input id="unitName" type="text" maxlength="80" value="#{html_escape(data['unit_name'] || 'دولاب دريسنج')}" placeholder="مثال: وحدة سفلية 4 درج"><div class="compact-note" style="margin-top:5px">سيُكتب هذا الاسم بين قوسين في Definition كل قطعة.</div></div><button class="add global-settings-button" onclick="openBoardRules()">▦ ضوابط مقاسات الألواح والشريط</button></div>
  <div class="option-tabs"><button id="tabBtnStructure" class="option-tab active" onclick="switchOptionsTab('structure')">▦ الهيكل</button><button id="tabBtnLayout" class="option-tab" onclick="switchOptionsTab('layout')">▤ التقسيمات</button><button id="tabBtnAccessories" class="option-tab" onclick="switchOptionsTab('accessories')">⚙ إكسسوار وتجميع</button><button id="tabBtnSloped" class="option-tab" onclick="switchOptionsTab('sloped')">◢ مائل</button></div>
  <div class="section option-tab-section tab-sloped"><div class="tab-intro"><strong>دولاب تحت سلم أو سقف مائل</strong>حدد ارتفاع الطرف الأيسر والطرف الأيمن، وستُقص القرصة والضهر والقواطيع والضلف على خط الميل.</div><div class="field" style="margin-top:10px"><label>تفعيل الدولاب المائل</label><select id="slopedEnabled"><option value="no">لا — دولاب عادي</option><option value="yes">نعم — تطبيق الميل</option></select></div><div class="grid2"><div class="field"><label>ارتفاع جهة الشمال سم</label><input id="slopedLeftHeight" type="number" min="20" step="0.1" value="#{data['sloped_left_height'] || data['height']}"></div><div class="field"><label>ارتفاع جهة اليمين سم</label><input id="slopedRightHeight" type="number" min="20" step="0.1" value="#{data['sloped_right_height'] || data['height']}"></div></div><div id="slopeSummary" class="compact-note"></div></div>
  <div class="section option-tab-section tab-structure">
   <details class="structure-group" open><summary>الشاسيه</summary><div class="structure-group-body"><div class="grid2"><div class="field"><label>عرض الشاسيه الكلي سم</label><input id="carcassWidth" type="number" min="20" value="#{data['width']}" step="0.1"></div><div class="field"><label>عدد الأعمدة</label><input id="columnCount" type="number" min="1" max="12" value="1" step="1"></div><div class="field"><label>الارتفاع سم</label><input id="height" type="number" value="#{data['height']}" step="0.1"></div><div class="field"><label>العمق سم</label><input id="depth" type="number" value="#{data['depth']}" step="0.1"></div><div class="field"><label>تخانة الشاسيه سم</label><input id="thickness" type="number" value="#{data['thickness']}" step="0.1"></div><div class="field"><label>طريقة التجميع</label><select id="assembly"><option value="on_base">جنب على القاعدة</option><option value="full">جنب كامل</option></select></div><div class="field"><label>نوع القرصة</label><select id="topType"><option value="between_sides">قرصة بين الجنبين</option><option value="full_top">قرصة كاملة</option></select></div><div class="field"><label>تطويل الجنب لأسفل سم</label><input id="sideExtension" type="number" min="0" value="#{data['side_extension'] || 0}" step="0.1"></div></div><div class="field"><label>خامة الشاسيه</label><select id="material">#{carcass_material_options}</select></div><div id="topTypeNote" class="compact-note"></div><div class="field"><label>خلعات الأعمدة الموجودة في الحائط</label><select id="autoWallRelief"><option value="yes">قراءة وتنفيذ تلقائي</option><option value="no">إيقاف قراءة الخلعات</option></select></div><div class="compact-note">ضع الدولاب في مكانه أمام حوائط المكتبة؛ عند الإنشاء ستُقرأ بروزات MHD_ROOM_BUILDER ويُخلع الشاسيه والضهر والأرفف تلقائيًا.</div><div class="compact-note">عند تطويل الجنب تصبح القاعدة والسوكلو الخشب بين الجنبين تلقائيًا.</div><div id="columnEqualSummary" class="compact-note"></div></div></details>
   <details id="doorStructureGroup" class="structure-group"><summary>الضلفة</summary><div class="structure-group-body"><div class="grid2"><div class="field"><label>نظام الضلف</label><select id="doorSystem"><option value="none">بدون ضلفة</option><option value="hinged">ضلفة مفصلية</option><option value="sliding">ضلفة جرار — لاحقًا</option></select></div><div class="field"><label>خلوص الضلفة سم</label><input id="doorClearance" type="number" value="#{data['door_clearance'] || 0.1}" step="0.1"></div></div><div class="field"><label>خامة الضلف ووشوش الأدراج</label><select id="doorMaterial">#{door_material_options}</select></div><div class="tab-intro" style="margin-top:8px"><strong>تخصيص الضلفة حسب التحديد</strong>حدد عمودًا من أعلى المعاينة لضلفة كاملة، أو اضغط على أي فراغ لضلفة مستقلة.</div><div id="columnDoorOptions" style="display:none;margin-top:9px"><div class="section-title">ضلفة العمود المحدد</div><div class="grid2"><div class="field"><label>السدّة الجانبية</label><select id="columnFillerSide" onchange="saveColumnDoor()"><option value="none">بدون سدّة</option><option value="right">سدّة يمين</option><option value="left">سدّة شمال</option></select></div><div class="field"><label>عمق السدّة سم</label><input id="columnFillerDepth" type="number" min="0.1" step="0.1" value="60" onchange="saveColumnDoor()"></div></div><div class="grid2"><div class="field"><label>عمق الفيلر سم</label><input id="columnFillerReturnDepth" type="number" min="0" step="0.1" value="0" onchange="saveColumnDoor()"></div><div class="field"><label>بروز الفيلر سم</label><input id="columnFillerProjection" type="number" min="0" step="0.1" value="0" onchange="saveColumnDoor()"></div></div><div class="grid2"><div class="field"><label>قص عمق الأرفف وشاسيه الأدراج من الوش للداخل سم</label><input id="columnFillerInternalCut" type="number" min="0" step="0.1" value="5" onchange="saveColumnDoor()"></div><div class="field"><label>نوع مفصلة السدّة</label><select id="columnFillerHingeType" onchange="saveColumnDoor()"><option value="straight">مفصلة عدلة — مع داعم</option><option value="knee">مفصلة ركبة — مع داعم</option><option value="scorpion_180">مفصلة عقرب 180° — بدون داعم</option></select></div></div><div class="grid2"><div class="field"><label>حالة العمود</label><select id="columnDoorEnabled" onchange="saveColumnDoor()"><option value="no">بدون ضلفة للعمود</option><option value="yes">إضافة ضلفة مفصلية</option></select></div><div class="field"><label>نوع الضلفة</label><select id="columnDoorStyle" onchange="saveColumnDoor()"><option value="wood">ضلفة خشب</option><option value="glass">ضلفة زجاج</option></select></div></div><div class="grid2"><div class="field"><label>اتجاه الفتح</label><select id="columnDoorDirection" onchange="saveColumnDoor()"><option value="right">يمين</option><option value="left">شمال</option><option value="double">يمين وشمال</option></select></div><div class="field"><label>عدد المفصلات لكل ضلفة</label><input id="columnHingeCount" type="number" min="1" max="12" step="1" value="4" onchange="saveColumnDoor()"></div></div><div id="columnDoorSize" style="text-align:center;color:#8ad8ff;font-size:11px"></div></div><div id="openingDoorOptions" style="display:none;margin-top:9px"><div class="section-title">ضلفة الفراغ المحدد</div><div class="grid2"><div class="field"><label>حالة الفراغ</label><select id="openingDoorEnabled" onchange="saveOpeningDoor()"><option value="no">بدون ضلفة للفراغ</option><option value="yes">إضافة ضلفة للفراغ</option></select></div><div class="field"><label>نوع الضلفة</label><select id="openingDoorStyle" onchange="saveOpeningDoor()"><option value="wood">ضلفة خشب</option><option value="glass">ضلفة زجاج</option></select></div></div><div class="grid2"><div class="field"><label>نظام واتجاه الفتح</label><select id="openingDoorDirection" onchange="saveOpeningDoor()"><option value="right">مفصلية يمين</option><option value="left">مفصلية شمال</option><option value="double">ضلفتان يمين وشمال</option><option value="flip_up">قلاب — تفتح لأعلى</option></select></div><div class="field"><label>عدد المفصلات لكل ضلفة</label><input id="openingHingeCount" type="number" min="1" max="12" step="1" value="4" onchange="saveOpeningDoor()"></div></div><div id="flipUpLiftOptions" class="field" style="display:none"><label>عدد أذرع الباكم</label><select id="openingLiftCount" onchange="saveOpeningDoor()"><option value="1">1 — شمال</option><option value="2">2 — شمال + يمين</option></select><div class="compact-note">حاليًا يتم ضبط الدراع الشمال أولًا، ثم نضيف فليب اليمين.</div></div><div id="openingDoorSize" style="text-align:center;color:#8ad8ff;font-size:11px"></div></div></div></details>
   <div id="slidingDoorOptions" class="structure-group-body" style="display:none;border:1px solid #31586b;border-radius:9px;margin:-3px 0 10px;padding:10px"><div class="section-title">تخصيص الضلفة الجرار</div><div class="compact-note">اختر بداية مساحة الجرار وعدد ضلفها. يمكن لباقي الأعمدة الاحتفاظ بضلفها المفصلية.</div><div class="grid2"><div class="field"><label>عدد ضلف الجرار</label><select id="slidingLeafCount"><option value="2">ضلفتان</option><option value="3">3 ضلف — الوسط أمامية</option></select></div><div class="field"><label>نوع ضلف الجرار</label><select id="slidingStyle"><option value="wood">خشب</option><option value="glass">زجاج</option></select></div><div class="field"><label>العمود الأول</label><select id="slidingFirstColumn"></select></div><div class="field"><label>آخر عمود</label><select id="slidingSecondColumn" disabled></select></div><div class="field"><label>الضلفة الأمامية (للضلفتين)</label><select id="slidingFrontLeaf"><option value="left">الشمال أمامية</option><option value="right">اليمين أمامية</option></select></div><div class="field"><label>المسافة بين مساري الضلف سم</label><input id="slidingTrackGap" type="number" min="0" step="0.1" value="#{data['sliding_track_gap'] || 1}"></div><div class="field"><label>الخلوص أعلى وأسفل سم</label><input id="slidingVerticalClearance" type="number" min="0" step="0.1" value="#{data['sliding_vertical_clearance'] || 3}"></div><div class="field"><label>قص القواطيع والأرفف من الأمام سم</label><input id="slidingPartitionCut" type="number" min="0" step="0.1" value="#{data['sliding_partition_cut'] || 5}"></div></div><div id="slidingDoorSize" style="text-align:center;color:#8ad8ff;font-size:11px"></div></div>
   <div id="slidingExtraOptions" class="structure-group-body" style="display:none;border:1px solid #31586b;border-radius:9px;margin:-7px 0 10px;padding:10px"><div class="grid2"><div class="field"><label>دخول الضلفة الأمامية عن وش الشاسيه سم</label><input id="slidingFrontSetback" type="number" min="0" step="0.1" value="#{data['sliding_front_setback'] || 0}"></div><div class="field"><label>زيادة عرض كل ضلفة سم</label><input id="slidingWidthExtra" type="number" min="0" step="0.1" value="#{data['sliding_width_extra'] || 0}"></div></div><div class="compact-note">صفر في الدخول = وش الضلفة الأمامية على وش الشاسيه. زيادة العرض تمتد للمنتصف فقط لتكوين التراكب، ولا تتجاوز حدود الدولاب.</div></div>
   <details class="structure-group" open><summary>الضهر</summary><div class="structure-group-body"><div class="field"><label>نمط التقاء الضهر مع القواطيع</label><select id="backJointMode"><option value="grooved_partition">قاطع مفحار — القاطع بعمق الشاسيه كامل</option><option value="connected_back">ضهر موصول — الضهران يلتقيان خلف القاطع</option></select></div><div class="grid2"><div class="field"><label>بداية الضهر من الخلف سم</label><input id="backInset" type="number" min="0" value="#{data['back_inset']}" step="0.1"></div><div class="field"><label>تخانة الضهر سم</label><input id="backThickness" type="number" min="0.1" value="#{data['back_thickness']}" step="0.1"></div><div class="field"><label>سقوط المفحار سم</label><input id="backGrooveDepth" type="number" min="0" value="#{data['back_groove_depth'] || 0.6}" step="0.1"></div><div class="field"><label>خامة الضهر</label><select id="backMaterial">#{back_material_options}</select></div></div><div id="backJointNote" class="compact-note"></div></div></details>
   <details class="structure-group"><summary>الأرفف والقواطيع</summary><div class="structure-group-body"><div class="grid2"><div class="field"><label>قص كل الأرفف من الأمام سم</label><input id="globalShelfFrontCut" type="number" min="0" value="#{data['shelf_front_cut'] || 0}" step="0.1"></div><div class="field"><label>قص القاطع الكامل</label><select id="cutFullPartitions"><option value="no">لا</option><option value="yes">نعم</option></select></div><div class="field"><label>رف ثابت بالأعلى</label><select id="fixedTopShelf"><option value="no">لا</option><option value="yes">نعم</option></select></div><div class="field"><label>ارتفاع الفراغ العلوي الصافي سم</label><input id="fixedTopClearHeight" type="number" min="1" value="#{data['fixed_top_clear_height'] || 40}" step="0.1"></div></div></div></details>
   <details class="structure-group"><summary>كورنيشة علوية</summary><div class="structure-group-body"><div class="grid2"><div class="field"><label>نوع الكورنيشة</label><select id="topCorniceType"><option value="none">بدون كورنيشة</option><option value="front">أمام</option><option value="front_right">أمام + يمين</option><option value="front_left">أمام + شمال</option><option value="front_both">أمام + يمين + شمال</option></select></div><div class="field"><label>ارتفاع الكورنيشة سم</label><input id="topCorniceHeight" type="number" min="1" step="0.1" value="#{data['top_cornice_height'] || 10}"></div></div><div class="field"><label>نظام تجميع الكورنيشة</label><select id="topCorniceJoinery" onchange="updateTrimJoineryOptions()"><option value="screw">مسمار — بدون إكسسوار إضافي</option><option value="butterfly">زاوية فراشة</option></select></div><div id="topCorniceJoineryOptions" style="display:none"><div class="field"><label>المسافة من أول وآخر القطعة سم</label><input id="topCorniceJoineryOffset" type="number" min="0.5" step="0.1" value="#{data['top_cornice_joinery_offset'] || 5}"></div><div class="field"><label>احتمالات التدعيم حسب الطول</label><div id="topCorniceJoineryRules"></div><button type="button" class="small-btn" onclick="addTrimRule('cornice')">＋ إضافة احتمال</button></div><div class="compact-note">التوزيع تلقائي ويتجنب نقاط التقاء الأجناب والقواطيع.</div></div><div id="topCorniceSummary" class="compact-note"></div></div></details>
<details class="structure-group"><summary>قاعدة الدولاب</summary><div class="structure-group-body"><div class="field"><label>نوع القاعدة</label><select id="baseType"><option value="legs">رجول — كما هي في الوحدة</option><option value="wood_plinth">سوكلو خشب</option></select></div><div id="legOptions"><div class="field"><label>ارتفاع الرجول سم</label><input id="legHeight" type="number" min="0" step="0.1" value="#{data['leg_height'] || 10}"></div><div class="compact-note">يتم تعديل خاصية «ارتفاع الرجول» الموجودة في الـ Dynamic Component الأصلي مباشرة.</div></div><div id="woodPlinthOptions"><div class="grid2"><div class="field"><label>ارتفاع السوكلو سم</label><input id="woodPlinthHeight" type="number" min="1" step="0.1" value="#{data['wood_plinth_height'] || 10}"></div><div class="field"><label>عدد الدعامات الداخلية</label><input id="woodPlinthSupports" type="number" min="0" max="20" step="1" value="#{data['wood_plinth_supports'] || 1}"></div><div class="field"><label>دخول السوكلو من الخلف سم</label><input id="woodPlinthRearInset" type="number" min="0" step="0.1" value="#{data['wood_plinth_rear_inset'] || 0}"></div><div id="woodPlinthFrontInsetField" class="field" style="display:none"><label>دخول السوكلو من الأمام سم</label><input id="woodPlinthFrontInset" type="number" min="0" step="0.1" value="#{data['wood_plinth_front_inset'] || data['thickness'] || 1.8}"></div></div><div class="field"><label>نظام تجميع السوكلو</label><select id="woodPlinthJoinery" onchange="updateTrimJoineryOptions()"><option value="screw">مسمار — بدون إكسسوار إضافي</option><option value="butterfly">زاوية فراشة</option></select></div><div id="woodPlinthJoineryOptions" style="display:none"><div class="field"><label>المسافة من أول وآخر القطعة سم</label><input id="woodPlinthJoineryOffset" type="number" min="0.5" step="0.1" value="#{data['wood_plinth_joinery_offset'] || 5}"></div><div class="field"><label>احتمالات التدعيم حسب الطول</label><div id="woodPlinthJoineryRules"></div><button type="button" class="small-btn" onclick="addTrimRule('plinth')">＋ إضافة احتمال</button></div><div class="compact-note">أي نقطة تقع على دعامة داخلية أو جنب سوكلو تتحرك تلقائيًا لأقرب مكان آمن.</div></div></div><div id="woodPlinthSummary" class="compact-note"></div></div></details>
   <div class="compact-note">قوائم الخامات مأخوذة من خيارات الـDynamic Attributes الأصلية للوحدة.</div>
  </div>
  <div class="section option-tab-section tab-layout" id="templateSection"><div class="section-title">اختار تقسيمة للعمود المحدد</div><div id="templateTargetHint" style="text-align:center;color:#ffd54f;font-size:11px;margin-bottom:7px"></div><div id="templateGrid" class="template-grid"></div></div>
  <div class="section option-tab-section tab-accessories"><div class="tab-intro"><strong>نظام الإكسسوارات والتجميع</strong>حدد قطعة من المعاينة: رف بعينه، درج بعينه، شماعة أو ضلفة. ستظهر الخيارات الخاصة بها هنا، وتُحفظ داخل تصميم الدولاب.</div></div>
  <div class="section option-tab-section tab-accessories"><details id="generalJoineryGroup" class="structure-group" open><summary>نظام التجميع</summary><div class="structure-group-body"><div class="field"><label>آلية تجميع الشاسيه</label><select id="joinerySystem"><option value="screw">مسمار — النظام الحالي</option><option value="butterfly">زاوية فراشة</option><option value="elita">إليتا</option><option value="qfix">كيو فيكس</option></select></div><div id="butterflyJoineryOptions" style="display:none"><div class="grid2"><div class="field"><label>المسافة من أول وآخر القطعة سم</label><input id="butterflyEdgeOffset" type="number" min="0.5" step="0.1" value="#{data['butterfly_edge_offset'] || 5}"></div><div class="field"><label>تطبيق على شاسيه الأدراج الداخلي</label><select id="butterflyApplyDrawers"><option value="no">لا</option><option value="yes">نعم</option></select></div></div><div class="field"><label>تدعيم إضافي حسب طول خط الالتقاء</label><div id="butterflySupportRules"></div><button type="button" class="small-btn" onclick="addButterflySupportRule()">＋ إضافة احتمال</button></div><div class="compact-note">زاويتان أساسيتان عند الطرفين. عند تجاوز طول معين تُضاف 1 أو 2 أو 3 زوايا موزعة تلقائيًا، والزوايا الإضافية تتحرك تلقائيًا لتجنب نقاط التقاء الأرفف والقواطيع أو أي جسم آخر.</div></div><div id="elitaJoineryOptions" style="display:none"><div class="grid2"><div class="field"><label>المسافة من أول وآخر القطعة سم</label><input id="elitaEdgeOffset" type="number" min="0.5" step="0.1" value="#{data['elita_edge_offset'] || 5}"></div><div class="field"><label>قطر بنطة المسمار سم</label><input id="elitaScrewDrillDiameter" type="number" min="0.1" step="0.05" value="#{data['elita_screw_drill_diameter'] || 0.8}"></div><div class="field"><label>قطر الفيشر سم</label><input id="elitaDowelDiameter" type="number" min="0.1" step="0.05" value="#{data['elita_dowel_diameter'] || 0.8}"></div><div class="field"><label>عمق الفيشر سم</label><input id="elitaDowelDepth" type="number" min="0.1" step="0.05" value="#{data['elita_dowel_depth'] || 1.05}"></div><div class="field"><label>قطر وش الربط سم</label><input id="elitaCamDiameter" type="number" min="0.1" step="0.05" value="#{data['elita_cam_diameter'] || 1.5}"></div><div class="field"><label>عمق وش الربط سم</label><input id="elitaCamDepth" type="number" min="0.1" step="0.05" value="#{data['elita_cam_depth'] || 1.2}"></div><div class="field"><label>مقاس المسمار بعد البورمة سم</label><input id="elitaScrewAfterThread" type="number" min="0.1" step="0.1" value="#{data['elita_screw_after_thread'] || 3.2}"></div></div><div class="field"><label>تدعيم إضافي للإليتا حسب طول خط الالتقاء</label><div id="elitaSupportRules"></div><button type="button" class="small-btn" onclick="addElitaSupportRule()">＋ إضافة احتمال</button></div><div class="compact-note">نقطتا الإليتا الأساسيتان تظلان كما هما. عند تجاوز طول معين تُضاف 1 أو 2 أو 3 تجميعات إليتا كاملة موزعة تلقائيًا، وتتحرك الإضافات لتجنب نقاط التقاء الأرفف والقواطيع أو أي جسم آخر.</div><div class="compact-note">المقاسات القياسية بالسنتيمتر: بنطة المسمار 0.8 سم، بنطة الفيشر 0.8 سم وعمقه 1.05 سم، وبنطة وش الربط 1.5 سم وعمقه 1.2 سم. مقاس المسمار بعد البورمة 3.2 سم، وهو موضع مركز وش الربط ونهاية مجرى المسمار. محور المسمار دائمًا في منتصف التخانة؛ تخانة 1.8 سم = محور 0.9 سم.</div></div><div id="joinerySystemNote" class="compact-note"></div></div></details>
  <details id="innerDrawerJoineryGroup" class="structure-group" open style="display:none"><summary>نظام تجميع شاسيه الدرج الداخلي</summary><div class="structure-group-body">
    <div class="field"><label>نظام تجميع شاسيه الدرج الداخلي</label><select id="innerDrawerJoinery"><option value="screw">مسمار — فاضي كما هو</option><option value="elita">إليتا</option></select></div>
    <div id="innerDrawerElitaOptions" style="display:none">
      <div class="grid2">
        <div class="field"><label>المسافة من أول وآخر القطعة سم</label><input id="innerElitaEdgeOffset" type="number" min="0.5" step="0.1" value="5"></div>
        <div class="field"><label>قطر بنطة المسمار سم</label><input id="innerElitaScrewDrillDiameter" type="number" min="0.1" step="0.05" value="0.8"></div>
        <div class="field"><label>قطر الفيشر سم</label><input id="innerElitaDowelDiameter" type="number" min="0.1" step="0.05" value="0.8"></div>
        <div class="field"><label>عمق الفيشر سم</label><input id="innerElitaDowelDepth" type="number" min="0.1" step="0.05" value="1.05"></div>
        <div class="field"><label>قطر وش الربط سم</label><input id="innerElitaCamDiameter" type="number" min="0.1" step="0.05" value="1.5"></div>
        <div class="field"><label>عمق وش الربط سم</label><input id="innerElitaCamDepth" type="number" min="0.1" step="0.05" value="1.2"></div>
        <div class="field"><label>مقاس المسمار بعد البورمة سم</label><input id="innerElitaScrewAfterThread" type="number" min="0.1" step="0.1" value="3.2"></div>
        <div class="field"><label>عدد الكويلة بجانب كل مسمار</label><select id="innerElitaCoilCount"><option value="1">1 — بعد المسمار</option><option value="2">2 — قبل وبعد المسمار</option></select></div>
        <div class="field"><label>قطر بنطة الكويلة سم</label><input id="innerElitaCoilDrillDiameter" type="number" min="0.1" step="0.05" value="0.8"></div>
        <div class="field"><label>طول الكويلة الكامل سم</label><input id="innerElitaCoilLength" type="number" min="0.2" step="0.1" value="4"></div>
        <div class="field"><label>عمق بنطة الكويلة في جهة الفيشر سم</label><input id="innerElitaCoilFaceDepth" type="number" min="0.1" step="0.1" value="2"></div>
        <div class="field"><label>المسافة بين مركز الكويلة ومركز المسمار سم</label><input id="innerElitaCoilCenterDistance" type="number" min="0.1" step="0.1" value="2.5"></div>
      </div>
      <div class="compact-note">هذا النظام يخص فقط: جنب شاسيه الدرج يمين وشمال + وش شاسيه الدرج + ضهر شاسيه الدرج. لا توجد احتمالات تدعيم إضافية هنا. الشاسيه الخارجي للأدراج يظل تابعًا لنظام التجميع العام.</div>
    </div>
  </div></details>
  <details id="elitaCoilOptions" class="structure-group" open style="display:none"><summary>كويلة الأليتا</summary><div class="structure-group-body"><div class="grid2"><div class="field"><label>عدد الكويلة بجانب كل مسمار</label><select id="elitaCoilCount"><option value="1">1 — بعد المسمار</option><option value="2">2 — قبل وبعد المسمار</option></select></div><div class="field"><label>قطر بنطة الكويلة سم</label><input id="elitaCoilDrillDiameter" type="number" min="0.1" step="0.05" value="#{data['elita_coil_drill_diameter'] || 0.8}"></div><div class="field"><label>طول الكويلة الكامل سم</label><input id="elitaCoilLength" type="number" min="0.2" step="0.1" value="#{data['elita_coil_length'] || 4.0}"></div><div class="field"><label>عمق بنطة الكويلة في جهة الفيشر سم</label><input id="elitaCoilFaceDepth" type="number" min="0.1" step="0.1" value="#{data['elita_coil_face_depth'] || 2.0}"></div><div class="field"><label>المسافة بين مركز الكويلة ومركز المسمار سم</label><input id="elitaCoilCenterDistance" type="number" min="0.1" step="0.1" value="#{data['elita_coil_center_distance'] || 2.5}"></div></div><div class="compact-note">عدد 1: المسمار ثم الكويلة للداخل. عدد 2: الكويلة الخارجية على مسافة أول/آخر القطعة، ثم المسمار، ثم الكويلة الداخلية. عمق جهة التخانة يُحسب تلقائيًا من طول الكويلة ناقص عمق جهة الفيشر.</div></div></details>
  <details class="structure-group" open><summary>تخريم مفصلات الضلف الخشب</summary><div class="structure-group-body"><div class="field"><label>نظام المفصلات الافتراضي</label><select id="hingeSystem"><option value="current">مفصلات المكتبة الحالية</option><option value="custom">مقاسات تخريم مخصصة</option></select></div><div class="grid2"><div class="field"><label>قطر بنطة كوباية المفصلة سم</label><input id="hingeCupDiameter" type="number" min="0.5" step="0.1" value="#{data['hinge_cup_diameter'] || 3.5}"></div><div class="field"><label>عمق الكوباية سم</label><input id="hingeCupDepth" type="number" min="0.1" step="0.1" value="#{data['hinge_cup_depth'] || 1.3}"></div><div class="field"><label>المسافة من حرف الضلفة إلى مركز الكوباية سم</label><input id="hingeCupEdgeCenter" type="number" min="0.1" step="0.05" value="#{data['hinge_cup_edge_center'] || 2.25}"></div><div class="field"><label>مسافة أول وآخر مفصلة من أعلى وأسفل سم</label><input id="hingeEndOffset" type="number" min="0.1" step="0.5" value="#{data['hinge_end_offset'] || 10}"></div><div class="field"><label>نزول منع تعارض المفصلتين سم</label><input id="hingeCollisionOffset" type="number" min="0" step="0.5" value="#{data['hinge_collision_offset'] || 5}"></div></div><div class="compact-note">عدد المفصلات يُحدد لكل ضلفة من جروب الضلفة. تُوزع المفصلات بالتساوي على ارتفاعها، وعند وجود ضلفتين على نفس القاطع تُزاح مفصلات الضلفة المقابلة إلى أسفل بالقيمة المحددة.</div></div></details>
  <details class="structure-group" open><summary>الإكسسوارات</summary><div class="structure-group-body"><div id="accessorySelectionCard" class="empty-selection">حدد عنصرًا من معاينة الدولاب.<br>يمكن تحديد رف منفرد، شماعة منفردة أو درج منفرد.</div><div id="accessoryDynamicOptions" style="display:none"><div class="selection-card"><div id="selectedPartName" class="selection-name"></div><div id="selectedPartMeta" class="compact-note"></div></div><div id="hangerAccessoryFields" style="display:none"><div class="field"><label>نوع إكسسوار الشماعة</label><select id="hangerAccessoryType"><option value="rod">شماعة ماسورة</option><option value="hydraulic">شماعة هيدروليك</option></select></div><div class="compact-note">مسار ملف الإكسسوار من السيرفر سيُضاف مع كتالوج كل نوع.</div></div><div id="drawerAccessoryFields" style="display:none"><div class="field"><label>نوع مجرى الدرج</label><select id="drawerRunnerType"><option value="side">مجرى جانبي</option><option value="under">مجرى سفلي</option></select></div><div class="field"><label>خلوص المجرى لكل جنب سم</label><input id="accessoryRunnerClearance" type="number" min="0" step="0.1" value="1.3"></div><div class="grid2" style="margin-top:8px"><div class="field"><label>درج إكسسوار</label><select id="drawerOrganizerType"><option value="none">بدون تقسيمات</option><option value="grid">تقسيمات متداخلة</option></select></div><div class="field"><label>عدد التقسيمات لكل اتجاه</label><input id="drawerOrganizerCount" type="number" min="1" max="8" step="1" value="3"></div></div><div id="drawerDrainWrap" style="margin-top:10px;padding-top:9px;border-top:1px solid #294656;display:none">
<div class="field"><label>تخليع صرف للدرج المحدد</label><select id="drawerDrainRelief"><option value="no">بدون تخليع صرف</option><option value="yes">تخليع صرف U</option></select></div>
<div id="drawerDrainFields" class="grid2" style="margin-top:8px;display:none">
<div class="field"><label>عرض فتحة الصرف سم</label><input id="drawerDrainWidth" type="number" min="5" step="0.5" value="17"></div>
<div class="field"><label>طول التخليع داخل القاعدة سم</label><input id="drawerDrainDepth" type="number" min="5" step="0.5" value="25"></div>
</div>
<div class="compact-note">عند التفعيل: ضهر شاسيه الدرج ينقسم يمين وشمال بفراغ في المنتصف، وقاعدة الدرج تتفرغ U من جهة الضهر. القيم الافتراضية للتخليع 17 × 25 سم، وارتفاع جزئي الضهر يساوي تلقائيًا ارتفاع شاسيه الدرج.</div>
</div><div class="compact-note">التقسيمات مستقلة عن المجرى. عند كل تقاطع يتم عمل خلعة نصف ارتفاع: القطعة الطولية من أعلى والعرضية من أسفل ليركبوا داخل بعض.</div></div><div id="shelfAccessoryFields" style="display:none"><div class="field"><label>نظام تثبيت الرف المحدد</label><select id="shelfSupportType"><option value="default">تلقائي — حامل رف</option><option value="pin">حامل رف</option><option value="butterfly">زاوية فراشة</option><option value="elita">إليتا</option><option value="concealed">حامل مخفي</option></select></div><div class="compact-note">الرف الفعلي يأخذ حامل رف تلقائيًا، ويمكن تغيير هذا الرف وحده إلى زاوية فراشة أو أليتا.</div></div><div id="doorAccessoryFields" style="display:none"><div class="compact-note">تخصيص مفصلة الضلفة المحددة سيكون هنا بعد إضافة كتالوج المفصلات.</div></div><button class="add" style="margin-top:8px" onclick="saveSelectedAccessory()">حفظ للعنصر المحدد</button></div></div></details></div>
  <div class="section option-tab-section tab-layout" id="openingEditor"><div class="section-title">تخصيص الفتحة المحددة</div><div class="grid2"><div class="field"><label>محتوى الفتحة</label><select id="leafType"><option value="empty">فراغ</option><option value="shelves">أرفف</option><option value="hanging">شماعة</option><option value="double_hang">شماعتان</option><option value="drawers">أدراج</option><option value="shelves_hang">أرفف + شماعة</option></select></div><div class="field"><label>العدد</label><input id="leafCount" type="number" min="0" max="10" value="3"></div></div><div class="field"><label>حجم الفتحة بالنسبة للمجاورة</label><input id="leafRatio" type="range" min="18" max="82" value="50"><div id="ratioText" style="text-align:center;color:#8ad8ff;font-size:11px">50%</div></div><div class="grid2"><button class="add" onclick="splitSelected('v')">تقسيم يمين / شمال</button><button class="add" onclick="splitSelected('h')">تقسيم أعلى / أسفل</button><button class="add" onclick="addOpening()">+ فتحة بجانبها</button><button class="del" onclick="removeSelected()">حذف / دمج</button></div><button class="advanced-toggle" onclick="mirrorLayout()">↔ عكس التقسيمة يمين / شمال</button></div>
  <div class="section option-tab-section tab-layout" id="openingDimensions"><div class="section-title">مقاس الفراغ المحدد</div><div class="grid2"><div class="field"><label>عرض الفراغ الصافي سم</label><input id="selectedOpeningWidth" type="number" step="0.1"></div><div class="field"><label>ارتفاع الفراغ الصافي سم</label><input id="selectedOpeningHeight" type="number" step="0.1"></div></div><div style="text-align:center;color:#91aaba;font-size:10px">يتغير المقاس بتحريك الشريط أو بكتابة العرض والارتفاع مباشرة</div></div>
  <div class="section option-tab-section tab-layout" id="leafDrawerOptions" style="display:none"><div class="section-title">خيارات أدراج الفتحة المحددة</div><div class="field"><label>نمط تكوين الأدراج</label><select id="nodeDrawerPattern"><option value="thick_side">جنب سميك</option><option value="overlay_front">على وش الضلفة</option><option value="flush_carcass">مساوي للشاسيه</option></select></div><div class="grid2"><div class="field"><label>قص صندوق وشاسيه الدرج من الأمام سم</label><input id="nodeDrawerFrontCut" type="number" min="0" value="0" step="0.1"></div><div class="field"><label>خلوص المجرى لكل جنب سم</label><input id="nodeRunnerClearance" type="number" value="1.3" step="0.1"></div><div class="field"><label>طول المجرى سم — صفر تلقائي</label><input id="nodeRunnerLength" type="number" value="0" step="5"></div><div class="field"><label>ارتفاع شاسيه الدرج سم</label><input id="nodeChassisHeight" type="number" value="13" step="0.1"></div><div class="field"><label>تخانة قاعدة الدرج سم</label><input id="nodeBottomThickness" type="number" value="0.6" step="0.1"></div><div class="field"><label>بداية حفر القاعدة سم</label><input id="nodeBottomDrop" type="number" min="0" value="1.8" step="0.1"></div><div class="field"><label>سقوط مفحار قاعدة الدرج سم</label><input id="nodeBottomGrooveDepth" type="number" min="0.1" value="0.6" step="0.1"></div><div class="field"><label>خلوص بين الوشوش سم</label><input id="nodeFrontGap" type="number" value="0.1" step="0.1"></div><div class="field"><label>تخانة وش الدرج سم</label><input id="nodeFrontThickness" type="number" value="1.8" step="0.1"></div></div><div id="drawerPatternNote" style="text-align:center;color:#91aaba;font-size:10px">جنب سميك: شاسيه خارجي كامل حول صناديق الأدراج.</div></div>
  <div class="section option-tab-section tab-layout"><div class="section-title">إضافة فتحة جديدة وتكبير الدولاب</div><div class="grid2"><div class="field"><label>عرض الفتحة الجديدة سم</label><input id="newOpeningWidth" type="number" min="20" value="60" step="0.1"></div><div class="field"><label>مكان الإضافة</label><select id="newOpeningSide"><option value="right">يمين الدولاب</option><option value="left">شمال الدولاب</option></select></div></div><button class="add" onclick="addExternalOpening()">+ إضافة فتحة مستقلة للدولاب</button><div id="cabinetWidthText" style="text-align:center;color:#8ad8ff;font-size:11px;margin-top:6px"></div></div>
  <div class="section advanced-section"><div class="section-title">شكل تقسيمة الفتحة المحددة</div><div id="presets" class="presets"></div></div>
  <div class="section advanced-section"><div class="section-title">التحكم الداخلي للفتحة</div><div id="shelfDetails"><div class="field"><label>مناسيب الأرفف من الأرض سم — افصل بفاصلة</label><input id="shelfLevels" type="text" placeholder="مثال: 35,70,110"></div><div class="field"><label>قص الرف من الأمام سم</label><input id="shelfFrontCut" type="number" min="0" value="0" step="0.1"></div></div><div id="drawerDetails"><div class="grid2"><div class="field"><label>نمط الدرج</label><select id="drawerPattern"><option value="external">بوش خارجي</option><option value="internal">درج داخلي خلف الضلفة</option><option value="wood_side">خشبي بمجرى جانبي</option><option value="wood_under">خشبي بمجرى سفلي</option></select></div><div class="field"><label>ارتفاع مجموعة الأدراج</label><input id="drawerHeight" type="number" step="0.1"></div><div class="field"><label>قص الأدراج من الأمام سم</label><input id="drawerFrontCut" type="number" min="0" step="0.1"></div><div class="field"><label>خلوص المجرى لكل جنب</label><input id="runnerClearance" type="number" step="0.1"></div><div class="field"><label>ارتفاع شاسيه الدرج</label><input id="chassisHeight" type="number" step="0.1"></div><div class="field" style="display:none"><label>تخانة شاسيه الدرج</label><input id="drawerThickness" type="number" step="0.1"></div><div class="field"><label>تخانة قاعدة الدرج</label><input id="bottomThickness" type="number" step="0.1"></div><div class="field"><label>بداية حفر القاعدة</label><input id="bottomDrop" type="number" min="0" step="0.1"></div><div class="field"><label>سقوط مفحار قاعدة الدرج</label><input id="bottomGrooveDepth" type="number" min="0.1" step="0.1"></div><div class="field"><label>الخلوص الخلفي</label><input id="rearClearance" type="number" step="0.1"></div><div class="field"><label>خلوص وش الدرج</label><input id="frontClearance" type="number" step="0.1"></div><div class="field"><label>تخانة وش الدرج</label><input id="frontThickness" type="number" step="0.1"></div></div></div></div>
  <div class="section advanced-section"><div class="section-title">الفتحات والتقسيمات</div><div id="bays"></div><button class="add" onclick="addBay()">+ إضافة فتحة</button></div>
 </div></div>
 <div class="panel preview"><div class="panel-title" style="display:flex;align-items:center;gap:8px"><span id="previewTitle" style="flex:1">معاينة الدولاب</span><button onclick="openWallRelief()" style="height:27px;padding:0 13px;border:1px solid #4de37a;border-radius:7px;background:#123326;color:#fff;font-weight:900;cursor:pointer">＋ إضافة خلعة</button></div><div class="canvas-wrap"><svg id="canvas" class="canvas" viewBox="0 0 760 520"></svg><div class="hint">اضغط على أي فتحة لتحديدها وتعديل عرضها أو عدد أرففها</div></div></div>
</div><div class="foot"><button class="create" onclick="createDressing()">إنشاء الدولاب داخل SketchUp</button><button class="cancel" onclick="sketchup.cancel()">إلغاء</button></div></div>
<div id="boardRulesModal" class="modal-overlay" onclick="if(event.target===this)closeBoardRules()"><div class="rules-modal"><div class="rules-head"><div class="rules-title">ضوابط مقاسات الألواح والشريط</div><button title="قاموس المسميات" onclick="openNamingDictionary()" style="width:34px;height:34px;margin-left:6px;border:1px solid #4de37a;border-radius:7px;background:#123326;color:#fff;cursor:pointer">⚙</button><button class="rules-close" onclick="closeBoardRules()">×</button></div><div class="rules-body">
 <div class="rule-card"><h3>مقاس لوح الشاسيه</h3><div class="field"><label>مقاس جاهز</label><select id="carcassBoardPreset" onchange="applyBoardPreset('carcass',this.value)"><option value="240x280">240 × 280 سم</option><option value="122x244">122 × 244 سم</option><option value="183x366">183 × 366 سم</option><option value="210x280">210 × 280 سم</option><option value="custom">مقاس مخصص</option></select></div><div class="grid2"><div class="field"><label>عرض اللوح سم</label><input id="carcassBoardWidth" type="number" min="1" step="0.1"></div><div class="field"><label>طول اللوح سم</label><input id="carcassBoardLength" type="number" min="1" step="0.1"></div></div></div>
 <div class="rule-card"><h3>مقاس لوح الضلفة</h3><div class="field"><label>مقاس جاهز</label><select id="doorBoardPreset" onchange="applyBoardPreset('door',this.value)"><option value="240x280">240 × 280 سم</option><option value="122x244">122 × 244 سم</option><option value="183x366">183 × 366 سم</option><option value="210x280">210 × 280 سم</option><option value="custom">مقاس مخصص</option></select></div><div class="grid2"><div class="field"><label>عرض اللوح سم</label><input id="doorBoardWidth" type="number" min="1" step="0.1"></div><div class="field"><label>طول اللوح سم</label><input id="doorBoardLength" type="number" min="1" step="0.1"></div></div></div>
 <div class="rule-card"><h3>مقاس لوح الضهر</h3><div class="field"><label>مقاس جاهز</label><select id="backBoardPreset" onchange="applyBoardPreset('back',this.value)"><option value="120x240">120 × 240 سم</option><option value="122x244">122 × 244 سم</option><option value="183x366">183 × 366 سم</option><option value="custom">مقاس مخصص</option></select></div><div class="grid2"><div class="field"><label>عرض اللوح سم</label><input id="backBoardWidth" type="number" min="1" step="0.1"></div><div class="field"><label>طول اللوح سم</label><input id="backBoardLength" type="number" min="1" step="0.1"></div></div></div>
 <div class="rule-card"><h3>نمط الشريط</h3><div class="field"><label>النمط المستخدم</label><select id="edgeBandPattern"><option value="all_around">شريط داير</option><option value="visible_only">شريط ظاهر فقط</option></select></div><div class="rules-note"><b>شريط داير:</b> الحواف الأربع لكل لوح. <b>ظاهر فقط:</b> الحرف الأمامي والخلفي، مع استبعاد الحواف المغطاة. لون الشريط يتبع خامة القطعة، ويُدمج شريط الشاسيه والضلف تلقائيًا إذا كانت خامتهما واحدة.</div></div>
 <div class="rules-note">يُسمح بتدوير القطعة داخل اللوح. عند تجاوز أي قطعة للمقاس المحدد، تتوقف عملية الإنشاء وتظهر أسماء القطع ومقاساتها.</div>
</div><div class="rules-foot"><button class="rules-cancel" onclick="closeBoardRules()">إلغاء</button><button class="rules-save" onclick="saveBoardRules()">حفظ الضوابط</button></div></div></div>

<div id="namingDictionaryModal" class="modal-overlay"><div class="rules-modal"><div class="rules-head"><div class="rules-title">⚙ قاموس المسميات</div><button class="rules-close" onclick="closeNamingDictionary()">×</button></div><div class="rules-body"><div class="rules-note" style="margin-bottom:8px">غيّر المصطلحات فقط؛ اسم الوحدة سيظل بين قوسين تلقائيًا في نهاية كل Definition.</div><div class="grid2"><div class="field"><label>الرف</label><input id="nameShelf" value="رف"></div><div class="field"><label>العمود</label><input id="nameColumn" value="عمود"></div><div class="field"><label>القاطع</label><input id="namePartition" value="قاطع"></div><div class="field"><label>الدرج</label><input id="nameDrawer" value="درج"></div><div class="field"><label>وش الدرج</label><input id="nameDrawerFront" value="وش درج"></div><div class="field"><label>الضهر</label><input id="nameBack" value="ضهر"></div><div class="field"><label>الضلفة</label><input id="nameDoor" value="ضلفة"></div><div class="field"><label>السدّة</label><input id="nameFiller" value="سدّة"></div></div></div><div class="rules-foot"><button class="rules-cancel" onclick="closeNamingDictionary()">إلغاء</button><button class="rules-save" onclick="saveNamingDictionary()">حفظ القاموس</button></div></div></div>
<div id="boardErrorModal" class="modal-overlay"><div class="rules-modal error-modal"><div class="rules-head error-head"><div class="rules-title">تنبيه مقاسات الألواح</div><button class="rules-close" onclick="closeBoardErrors()">×</button></div><div class="rules-body"><div id="boardErrorSummary" class="error-summary"></div><div class="error-table-wrap"><table class="error-table"><thead><tr><th>القطعة</th><th>مقاس القطعة</th><th>نوع اللوح</th><th>مقاس اللوح</th></tr></thead><tbody id="boardErrorRows"></tbody></table></div><div class="rules-note" style="margin-top:10px">يمكن تدوير القطعة داخل اللوح، لذلك لا تظهر هنا إلا القطع التي لا تدخل في الاتجاهين.</div></div><div class="rules-foot"><button class="rules-cancel" onclick="closeBoardErrors()">إغلاق</button><button class="rules-save edit-rules" onclick="editBoardRulesFromError()">تعديل ضوابط الألواح</button></div></div></div>
<div id="toolErrorModal" class="modal-overlay"><div class="rules-modal"><div class="rules-head error-head"><div id="toolErrorTitle" class="rules-title">تعذر إنشاء الدولاب</div><button class="rules-close" onclick="closeToolError()">×</button></div><div class="rules-body"><div id="toolErrorMessage" class="tool-error-message"></div></div><div class="rules-foot"><button class="rules-save" onclick="closeToolError()">حسنًا</button></div></div></div>
<div id="creationLoadingModal" class="modal-overlay"><div class="creation-loader"><div class="creation-loader-title">مكتبة محمد عادل</div><div id="creationLoadingText" class="creation-loader-text">جاري تجهيز إنشاء الدولاب...</div><div class="creation-progress-track"><div id="creationProgressBar" class="creation-progress-bar"></div></div><div id="creationProgressValue" class="creation-progress-value">4%</div></div></div>
<div id="wallReliefModal" class="modal-overlay"><div class="rules-modal" style="max-width:760px"><div class="rules-head"><div class="rules-title">مساعد خلعات الحائط</div><button class="rules-close" onclick="closeWallRelief()">×</button></div><div class="rules-body"><div class="grid2"><div class="field"><label>عرض الحائط الكلي سم</label><input id="reliefWallWidth" type="number" min="20" step="0.1"></div><div class="field"><label>جهة قياس بداية الدولاب</label><select id="reliefPlacement"><option value="right">من جهة اليمين</option><option value="left">من جهة الشمال</option></select></div><div class="field"><label>المسافة من طرف الحائط لبداية الدولاب سم</label><input id="reliefCabinetOffset" type="number" min="0" step="0.1" value="0"></div><div class="field"><label>عرض الدولاب الحالي</label><input id="reliefCabinetWidth" type="text" disabled></div><div class="field"><label>عدد أعمدة الحائط</label><input id="reliefColumnCount" type="number" min="0" max="8" step="1"></div></div><div class="rules-note" style="margin-bottom:8px">اختر جهة القياس واكتب المسافة كما تقيسها على الطبيعة. إذا كان عرض الحائط مساويًا لعرض الدولاب تكون المسافة 0 سم.</div><div id="reliefRows"></div><div style="margin-top:8px;border:1px solid #294557;border-radius:8px;background:#06121b;padding:8px"><svg id="reliefCanvas" viewBox="0 0 700 180" style="width:100%;height:180px"></svg></div><div class="rules-note" style="margin-top:8px">المعاينة من أعلى. المناطق البرتقالية هي الأعمدة، والإطار الأخضر هو مكان الدولاب على الحائط.</div></div><div class="rules-foot"><button class="rules-cancel" onclick="removeWallRelief()">إلغاء الخلعة</button><button class="rules-save" onclick="saveWallRelief()">موافق وعرض الاقتراح</button></div></div></div>
<script>
const INITIAL=#{JSON.generate(data)};const PRESETS={shelves:['أرفف','☰'],hanging:['شماعة','⌒'],double_hang:['شماعتان','⌒⌒'],drawers:['أدراج','▤'],drawers_hang:['أدراج + شماعة','▤⌒'],split_mix:['تقسيم مركب','▥']};let bays=INITIAL.bays,selected=0,easyTemplate=String(INITIAL.easy_template||'1'),advancedMode=false,layoutTree=null,selectedPath=[],selectionTarget='opening',selectedPart=null,activeOptionsTab='structure',cabinetWidth=Number(INITIAL.width||120);const $=id=>document.getElementById(id);const val=id=>parseFloat($(id).value||0);
let butterflySupportRules=Array.isArray(INITIAL.butterfly_support_rules)&&INITIAL.butterfly_support_rules.length?INITIAL.butterfly_support_rules.map(r=>({threshold:Number(r.threshold)||65,count:Math.max(1,Math.min(3,parseInt(r.count||1)))})):[{threshold:65,count:1}];
function renderButterflySupportRules(){const box=$('butterflySupportRules');if(!box)return;box.innerHTML='';butterflySupportRules.forEach((r,i)=>{const row=document.createElement('div');row.className='grid2';row.style.marginBottom='6px';row.innerHTML=`<div class="field"><label>إذا زاد الطول عن سم</label><input type="number" min="1" step="1" value="${r.threshold}" onchange="butterflySupportRules[${i}].threshold=Math.max(1,Number(this.value)||1)"></div><div class="field"><label>عدد الزوايا الإضافية</label><div style="display:flex;gap:6px;align-items:center"><select onchange="butterflySupportRules[${i}].count=parseInt(this.value)"><option value="1"${r.count===1?' selected':''}>1</option><option value="2"${r.count===2?' selected':''}>2</option><option value="3"${r.count===3?' selected':''}>3</option></select>${i>0?`<button type="button" class="small-btn" onclick="removeButterflySupportRule(${i})">حذف</button>`:''}</div></div>`;box.appendChild(row)})}
function addButterflySupportRule(){const last=butterflySupportRules[butterflySupportRules.length-1]||{threshold:65};butterflySupportRules.push({threshold:Math.max(1,Number(last.threshold)||65)+50,count:1});renderButterflySupportRules()}
function removeButterflySupportRule(i){if(i<=0)return;butterflySupportRules.splice(i,1);renderButterflySupportRules()}
let elitaSupportRules=Array.isArray(INITIAL.elita_support_rules)&&INITIAL.elita_support_rules.length?INITIAL.elita_support_rules.map(r=>({threshold:Number(r.threshold)||65,count:Math.max(1,Math.min(3,parseInt(r.count||1)))})):[{threshold:65,count:1}];
function renderElitaSupportRules(){const box=$('elitaSupportRules');if(!box)return;box.innerHTML='';elitaSupportRules.forEach((r,i)=>{const row=document.createElement('div');row.className='grid2';row.style.marginBottom='6px';row.innerHTML=`<div class="field"><label>إذا زاد الطول عن سم</label><input type="number" min="1" step="1" value="${r.threshold}" onchange="elitaSupportRules[${i}].threshold=Math.max(1,Number(this.value)||1)"></div><div class="field"><label>عدد تجميعات الإليتا الإضافية</label><div style="display:flex;gap:6px;align-items:center"><select onchange="elitaSupportRules[${i}].count=parseInt(this.value)"><option value="1"${r.count===1?' selected':''}>1</option><option value="2"${r.count===2?' selected':''}>2</option><option value="3"${r.count===3?' selected':''}>3</option></select>${i>0?`<button type="button" class="small-btn" onclick="removeElitaSupportRule(${i})">حذف</button>`:''}</div></div>`;box.appendChild(row)})}
function addElitaSupportRule(){const last=elitaSupportRules[elitaSupportRules.length-1]||{threshold:65};elitaSupportRules.push({threshold:Math.max(1,Number(last.threshold)||65)+50,count:1});renderElitaSupportRules()}
function removeElitaSupportRule(i){if(i<=0)return;elitaSupportRules.splice(i,1);renderElitaSupportRules()}
let topCorniceJoineryRules=Array.isArray(INITIAL.top_cornice_joinery_rules)&&INITIAL.top_cornice_joinery_rules.length?INITIAL.top_cornice_joinery_rules.map(r=>({threshold:Number(r.threshold)||65,count:Math.max(1,Math.min(3,parseInt(r.count||1)))})):[{threshold:65,count:1}];
let woodPlinthJoineryRules=Array.isArray(INITIAL.wood_plinth_joinery_rules)&&INITIAL.wood_plinth_joinery_rules.length?INITIAL.wood_plinth_joinery_rules.map(r=>({threshold:Number(r.threshold)||65,count:Math.max(1,Math.min(3,parseInt(r.count||1)))})):[{threshold:65,count:1}];
function trimRuleState(kind){return kind==='cornice'?topCorniceJoineryRules:woodPlinthJoineryRules}
function trimRuleBox(kind){return $(kind==='cornice'?'topCorniceJoineryRules':'woodPlinthJoineryRules')}
function renderTrimRules(kind){const arr=trimRuleState(kind),box=trimRuleBox(kind);if(!box)return;box.innerHTML='';arr.forEach((r,i)=>{const row=document.createElement('div');row.className='grid2';row.style.marginBottom='6px';row.innerHTML=`<div class="field"><label>إذا زاد الطول عن سم</label><input type="number" min="1" step="1" value="${r.threshold}" onchange="trimRuleState('${kind}')[${i}].threshold=Math.max(1,Number(this.value)||1)"></div><div class="field"><label>عدد الإضافات</label><div style="display:flex;gap:6px"><select onchange="trimRuleState('${kind}')[${i}].count=parseInt(this.value)"><option value="1"${r.count===1?' selected':''}>1</option><option value="2"${r.count===2?' selected':''}>2</option><option value="3"${r.count===3?' selected':''}>3</option></select>${i>0?`<button type="button" class="small-btn" onclick="removeTrimRule('${kind}',${i})">حذف</button>`:''}</div></div>`;box.appendChild(row)})}
function addTrimRule(kind){const arr=trimRuleState(kind),last=arr[arr.length-1]||{threshold:65};arr.push({threshold:Math.max(1,Number(last.threshold)||65)+50,count:1});renderTrimRules(kind)}
function removeTrimRule(kind,i){if(i<=0)return;trimRuleState(kind).splice(i,1);renderTrimRules(kind)}
function updateTrimJoineryOptions(){const c=$('topCorniceJoinery').value,p=$('woodPlinthJoinery').value;$('topCorniceJoineryOptions').style.display=(c==='butterfly')?'':'none';$('woodPlinthJoineryOptions').style.display=(p==='butterfly')?'':'none'}
let wallRelief=INITIAL.wall_relief||{enabled:'no',wall_width:cabinetWidth,placement:'left',cabinet_offset:0,columns:[]};if(!Array.isArray(wallRelief.columns))wallRelief.columns=[];else wallRelief.columns=wallRelief.columns.filter(c=>c&&typeof c==='object');
function reliefWallWidth(){return Math.max(cabinetWidth,Number(wallRelief.wall_width||cabinetWidth))}
function reliefCabinetStart(){const w=reliefWallWidth(),off=Math.max(0,Number(wallRelief.cabinet_offset||0)),side=wallRelief.placement==='right'?'right':'left';return side==='right'?Math.max(0,w-off-cabinetWidth):Math.min(off,Math.max(0,w-cabinetWidth))}
function reliefColumnLeft(c){const w=reliefWallWidth(),cw=Math.max(0,Number(c.width||0));if(c&&c.distance!==undefined){const d=Math.max(0,Number(c.distance||0));return c.side==='right'?w-d-cw:d}return Number(c.left||0)}
function activeReliefs(){if(wallRelief.enabled!=='yes')return[];const start=reliefCabinetStart();return (wallRelief.columns||[]).map((c,i)=>{const left=reliefColumnLeft(c);return{index:i,x0:Math.max(0,left-start),x1:Math.min(cabinetWidth,left+Number(c.width)-start),depth:Number(c.depth),strategy:c.mode||'depth_avoid'}}).filter(r=>r.x1>r.x0&&r.depth>0)}
function cabinetBayRegions(n,x,w,t,out=[]){if(n&&n.dir==='v'&&n.external&&Array.isArray(n.children)&&n.children.length>1){const ratio=Math.max(.08,Math.min(.92,Number(n.ratio||.5))),w1=(w-t)*ratio;cabinetBayRegions(n.children[0],x,w1,t,out);cabinetBayRegions(n.children[1],x+w1+t,w-w1-t,t,out)}else out.push({x0:x,x1:x+w});return out}
function suggestedReliefs(){const physical=activeReliefs(),t=Math.max(.1,val('thickness')),bays=layoutTree?cabinetBayRegions(layoutTree,t,Math.max(1,cabinetWidth-2*t),t,[]):[];return physical.flatMap(r=>{if(r.strategy==='true_notch')return[Object.assign({},r,{x0:Math.max(0,r.x0-t),x1:Math.min(cabinetWidth,r.x1+t),depth:r.depth+t,mode:'cladded_partition'})];let hit=bays.filter(b=>r.x1>b.x0+.1&&r.x0<b.x1-.1);if(!hit.length&&bays.length)hit=[bays.reduce((a,b)=>Math.abs((a.x0+a.x1-r.x0-r.x1)/2)<Math.abs((b.x0+b.x1-r.x0-r.x1)/2)?a:b)];return hit.map(b=>Object.assign({},r,{x0:b.x0,x1:b.x1,mode:'bay_depth'}))})}
function renderReliefRows(){const count=Math.max(0,Math.min(8,parseInt($('reliefColumnCount').value||0))),old=wallRelief.columns||[];$('reliefRows').innerHTML=Array.from({length:count},(_,i)=>{const c=old[i]||{side:'right',distance:100+i*100,width:60,depth:20,mode:'depth_avoid'},side=c.side==='right'?'right':'left',distance=c.distance!==undefined?Number(c.distance):Number(c.left||0);return`<div class="rule-card"><h3>عمود الحائط ${i+1}</h3><div class="grid2"><div class="field"><label>جهة قياس مسافة العمود</label><select class="relief-side"><option value="right" ${side==='right'?'selected':''}>من جهة اليمين</option><option value="left" ${side==='left'?'selected':''}>من جهة الشمال</option></select></div><div class="field"><label>المسافة من الجهة المختارة سم</label><input class="relief-distance" type="number" min="0" step="0.1" value="${distance}"></div><div class="field"><label>عرض العمود سم</label><input class="relief-width" type="number" min="1" step="0.1" value="${Number(c.width)}"></div><div class="field"><label>بروز العمود سم</label><input class="relief-depth" type="number" min="0.1" step="0.1" value="${Number(c.depth)}"></div><div class="field"><label>طريقة معالجة الخلعة</label><select class="relief-mode"><option value="depth_avoid" ${(c.mode||'depth_avoid')==='depth_avoid'?'selected':''}>تفاديها بدخول العمق</option><option value="true_notch" ${c.mode==='true_notch'?'selected':''}>خلع حقيقي + تجليد العمود</option></select></div></div></div>`}).join('');$('reliefRows').querySelectorAll('input,select').forEach(el=>el.addEventListener(el.tagName==='SELECT'?'change':'input',previewWallRelief));previewWallRelief()}
function readReliefForm(){const rows=Array.from($('reliefRows').children),W=Math.max(cabinetWidth,val('reliefWallWidth'));return{enabled:rows.length?'yes':'no',wall_width:W,placement:$('reliefPlacement').value==='right'?'right':'left',cabinet_offset:Math.max(0,val('reliefCabinetOffset')),columns:rows.map(row=>{const side=row.querySelector('.relief-side').value==='right'?'right':'left',distance=Math.max(0,parseFloat(row.querySelector('.relief-distance').value||0)),width=parseFloat(row.querySelector('.relief-width').value||0),left=side==='right'?W-distance-width:distance;return{side:side,distance:distance,left:left,width:width,depth:parseFloat(row.querySelector('.relief-depth').value||0),mode:row.querySelector('.relief-mode').value}})}}
function previewWallRelief(){const temp=wallRelief;wallRelief=readReliefForm();const W=Math.max(1,Number(wallRelief.wall_width)),sx=620/W,x=40,baseY=45,start=reliefCabinetStart(),cabW=cabinetWidth*sx,cabH=105;let out=`<path d="M ${x} ${baseY} H ${x+620}" fill="none" stroke="#8ad8ff" stroke-width="3"/>`;wallRelief.columns.forEach((c,i)=>{const left=reliefColumnLeft(c),cx=x+left*sx,cw=Number(c.width)*sx,dep=Math.min(55,Number(c.depth)*2),label=c.mode==='true_notch'?'خلع + تجليد':'دخول عمق',measure=c.side==='right'?`يمين ${Number(c.distance).toFixed(1)}`:`شمال ${Number(c.distance).toFixed(1)}`;out+=`<path d="M ${cx} ${baseY} V ${baseY+dep} H ${cx+cw} V ${baseY}" fill="rgba(216,166,111,.35)" stroke="#d8a66f" stroke-width="3"/><text x="${cx+cw/2}" y="${baseY+dep+16}" fill="#fff" font-size="10" text-anchor="middle">عمود ${i+1} — ${measure} — ${label}</text>`});const sideLabel=wallRelief.placement==='right'?'يمين':'شمال';out+=`<rect x="${x+start*sx}" y="${baseY}" width="${cabW}" height="${cabH}" fill="rgba(77,227,122,.035)" stroke="#4de37a" stroke-width="3" stroke-dasharray="7 5"/><text x="${x+start*sx+cabW/2}" y="${baseY+cabH+18}" fill="#4de37a" font-size="12" text-anchor="middle">الدولاب ${cabinetWidth.toFixed(1)} سم — من ${sideLabel} بعد ${Number(wallRelief.cabinet_offset||0).toFixed(1)} سم</text>`;$('reliefCanvas').innerHTML=out;wallRelief=temp}
function openWallRelief(){$('reliefWallWidth').value=Number(wallRelief.wall_width||cabinetWidth);const oldPlacement=wallRelief.placement==='right'?'right':'left';$('reliefPlacement').value=oldPlacement;$('reliefCabinetOffset').value=Number(wallRelief.cabinet_offset||0);$('reliefCabinetWidth').value=`${cabinetWidth.toFixed(1)} سم`;$('reliefColumnCount').value=(wallRelief.columns||[]).length||1;$('wallReliefModal').classList.add('show');renderReliefRows()}
function closeWallRelief(){$('wallReliefModal').classList.remove('show')}
function saveWallRelief(){const cfg=readReliefForm(),maxCabinetOffset=Math.max(0,cfg.wall_width-cabinetWidth);if(cfg.cabinet_offset>maxCabinetOffset+.001){alert(`المسافة بين طرف الحائط وبداية الدولاب لا يمكن أن تتجاوز ${maxCabinetOffset.toFixed(1)} سم`);return}if(cfg.columns.some(c=>c.left<-.001||c.width<=0||c.depth<=0||c.left+c.width>cfg.wall_width+.001)){alert('راجع جهة ومسافة وعرض وبروز أعمدة الحائط');return}wallRelief=cfg;closeWallRelief();updateWallReliefStatus();draw()}
function removeWallRelief(){wallRelief={enabled:'no',wall_width:cabinetWidth,placement:'left',cabinet_offset:0,columns:[]};closeWallRelief();updateWallReliefStatus();draw()}
function updateWallReliefStatus(){const el=$('wallReliefStatus');if(!el)return;const proposals=suggestedReliefs(),bayCount=proposals.filter(r=>r.mode==='bay_depth').length,claddingCount=proposals.filter(r=>r.mode==='cladded_partition').length;el.textContent=wallRelief.enabled==='yes'?`اقتراح المعالجة: ${bayCount} فتحة بعمق أقل${claddingCount?`، و${claddingCount} عمود حائط بتجليدة ومفحار`:''}. ستظهر المناطق المقترحة بالبرتقالي في المعاينة.`:'لم تتم إضافة خلعة حائط.'}
$('reliefColumnCount').addEventListener('input',renderReliefRows);$('reliefWallWidth').addEventListener('input',previewWallRelief);$('reliefPlacement').addEventListener('change',previewWallRelief);$('reliefCabinetOffset').addEventListener('input',previewWallRelief);if($('autoWallRelief')){const oldField=$('autoWallRelief').closest('.field');if(oldField){oldField.style.display='none';const note=oldField.nextElementSibling;if(note&&note.classList.contains('compact-note'))note.style.display='none';const status=document.createElement('div');status.id='wallReliefStatus';status.className='compact-note';oldField.parentNode.insertBefore(status,oldField.nextSibling)}}
function switchOptionsTab(name){if(name==='doors')name='structure';if(!['structure','layout','accessories','sloped'].includes(name))name='structure';const editor=$('optionsEditor'),savedTop=editor.scrollTop;activeOptionsTab=name;editor.classList.remove('options-view-structure','options-view-layout','options-view-doors','options-view-accessories','options-view-sloped');editor.classList.add('options-view-'+name);['Structure','Layout','Accessories','Sloped'].forEach(k=>$('tabBtn'+k).classList.toggle('active',k.toLowerCase()===name));editor.scrollTop=savedTop;requestAnimationFrame(()=>editor.scrollTop=savedTop);if(name==='accessories')updateAccessoryEditor();try{localStorage.setItem('mhdDressingOptionsTab',name)}catch(e){}}
function preserveEditorScroll(action){const editor=$('optionsEditor'),top=editor.scrollTop;action();editor.scrollTop=top;requestAnimationFrame(()=>editor.scrollTop=top);setTimeout(()=>editor.scrollTop=top,0)}
function updateJoineryOptions(){const system=$('joinerySystem').value,butterfly=system==='butterfly',elita=system==='elita';$('butterflyJoineryOptions').style.display=butterfly?'':'none';$('elitaJoineryOptions').style.display=elita?'':'none';$('elitaCoilOptions').style.display=elita?'':'none';$('joinerySystemNote').textContent=butterfly?'زاوية الفراشة ستُحمّل من السيرفر وتُركب تلقائيًا في الزوايا، بينما الأرفف الفعلية تأخذ حامل رف.':elita?'الأليتا ستُركب عند نقاط الالتقاء، ومحور المسمار ووش الربط في منتصف التخانة الفعلية وعلى خط واحد. الأرفف الفعلية تظل بحامل رف إلا عند تخصيص رف بعينه.':'الأرفف الفعلية تأخذ حامل رف تلقائيًا، ويمكن تغيير رف بعينه من قسم الإكسسوارات.'}
function updateSlopeSummary(){const enabled=$('slopedEnabled').value==='yes',left=Math.max(0,val('slopedLeftHeight')),right=Math.max(0,val('slopedRightHeight')),difference=Math.abs(right-left),angle=Math.atan2(difference,Math.max(1,cabinetWidth))*180/Math.PI;$('slopeSummary').textContent=enabled?`فرق الارتفاع: ${difference.toFixed(1)} سم — زاوية الميل التقريبية: ${angle.toFixed(1)}°`:'وضع الميل غير مفعّل؛ إنشاء الدولاب سيظل عاديًا.';}
function updateTopCorniceSummary(){const type=$('topCorniceType').value,h=Math.max(1,val('topCorniceHeight')),labels={none:'بدون كورنيشة',front:'أمام',front_right:'أمام + يمين',front_left:'أمام + شمال',front_both:'أمام + يمين + شمال'};$('topCorniceHeight').disabled=type==='none';$('topCorniceSummary').textContent=type==='none'?'لن يتم إنشاء كورنيشة علوية.':`${labels[type]||type} — ارتفاع ${h.toFixed(1)} سم — التخانة من تخانة الشاسيه.`;}
function updateBaseSummary(){const wood=$('baseType').value==='wood_plinth',count=Math.max(0,parseInt($('woodPlinthSupports').value||0)),inside=val('sideExtension')>0,width=inside?Math.max(0,cabinetWidth-2*val('thickness')):cabinetWidth,noSides=inside&&$('assembly').value==='full',showFront=wood&&inside&&$('assembly').value==='full',rear=Math.max(0,val('woodPlinthRearInset')),front=Math.max(0,val('woodPlinthFrontInset')),plinthDepth=Math.max(0,val('depth')-rear-front);if($('legOptions'))$('legOptions').style.display=wood?'none':'';$('woodPlinthOptions').style.display=wood?'grid':'none';if($('woodPlinthFrontInsetField'))$('woodPlinthFrontInsetField').style.display=showFront?'':'none';$('woodPlinthSummary').textContent=wood?`${inside?'سوكلو بين الجنبين':'إطار كامل'} ${width.toFixed(1)} × ${plinthDepth.toFixed(1)} سم${showFront?` — دخول أمامي ${front.toFixed(1)} سم`:''}${rear>0?`، ودخول خلفي ${rear.toFixed(1)} سم`:''}${noSides?' — وش وضهر ودعامات بدون جوانب':''}، بداخله ${count} ${count===1?'دعامة':'دعامات'} موزعة بالتساوي على العرض.`:`سيتم الاحتفاظ بالرجول والوزرة الأصلية الموجودة في الوحدة — ارتفاع الرجول ${Math.max(0,val('legHeight')).toFixed(1)} سم.`;}
function syncSideExtension(){const enabled=$('assembly').value==='full';$('sideExtension').disabled=!enabled;if(!enabled)$('sideExtension').value=0;}
function updateTopTypeNote(){if(!$('topTypeNote'))return;const full=$('topType').value==='full_top';$('topTypeNote').textContent=full?'قرصة كاملة: بعرض الدولاب كله، والجنبان ينتهيان أسفلها بقيمة تخانة الشاسيه.':'قرصة بين الجنبين: النظام الحالي، بعرض الصافي الداخلي بين الجنبين.';}
function updateBackJointNote(){const connected=$('backJointMode').value==='connected_back';$('backJointNote').textContent=connected?'ضهر موصول: الضهران يلتقيان عند منتصف القاطع بدون سقوط مفحار من جهته، والقاطع يقف قبل الضهر.':'قاطع مفحار: القاطع يرجع حتى آخر عمق الشاسيه كامل، ولا ينقص منه إلا قيمة القص من الأمام.';}
function esc(v){return String(v).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));}
let boardRulesSnapshot=null;
let namingDictionary=Object.assign({shelf:'رف',column:'عمود',partition:'قاطع',drawer:'درج',drawer_front:'وش درج',back:'ضهر',door:'ضلفة',filler:'سدّة'},INITIAL.naming_dictionary||{});
function openNamingDictionary(){const ids={shelf:'nameShelf',column:'nameColumn',partition:'namePartition',drawer:'nameDrawer',drawer_front:'nameDrawerFront',back:'nameBack',door:'nameDoor',filler:'nameFiller'};Object.keys(ids).forEach(k=>$(ids[k]).value=namingDictionary[k]||'');$('namingDictionaryModal').classList.add('show')}
function closeNamingDictionary(){$('namingDictionaryModal').classList.remove('show')}
function saveNamingDictionary(){const ids={shelf:'nameShelf',column:'nameColumn',partition:'namePartition',drawer:'nameDrawer',drawer_front:'nameDrawerFront',back:'nameBack',door:'nameDoor',filler:'nameFiller'};Object.keys(ids).forEach(k=>{const v=$(ids[k]).value.replace(/[()]/g,'').trim();if(v)namingDictionary[k]=v});closeNamingDictionary()}
function boardValues(){return{cw:val('carcassBoardWidth'),cl:val('carcassBoardLength'),dw:val('doorBoardWidth'),dl:val('doorBoardLength'),bw:val('backBoardWidth'),bl:val('backBoardLength'),edge:$('edgeBandPattern').value}}
function setBoardValues(v){$('carcassBoardWidth').value=v.cw;$('carcassBoardLength').value=v.cl;$('doorBoardWidth').value=v.dw;$('doorBoardLength').value=v.dl;$('backBoardWidth').value=v.bw;$('backBoardLength').value=v.bl;$('edgeBandPattern').value=v.edge||'none';syncBoardPreset('carcass');syncBoardPreset('door');syncBoardPreset('back')}
function syncBoardPreset(kind){const w=val(kind+'BoardWidth'),l=val(kind+'BoardLength'),key=`${w}x${l}`,select=$(kind+'BoardPreset');select.value=Array.from(select.options).some(o=>o.value===key)?key:'custom'}
function applyBoardPreset(kind,preset){if(preset==='custom')return;const p=preset.split('x').map(Number);$(kind+'BoardWidth').value=p[0];$(kind+'BoardLength').value=p[1]}
function openBoardRules(){boardRulesSnapshot=boardValues();syncBoardPreset('carcass');syncBoardPreset('door');syncBoardPreset('back');$('boardRulesModal').classList.add('show')}
function closeBoardRules(keep=false){if(!keep&&boardRulesSnapshot)setBoardValues(boardRulesSnapshot);boardRulesSnapshot=null;$('boardRulesModal').classList.remove('show')}
function saveBoardRules(){const v=boardValues();if(v.cw<=0||v.cl<=0||v.dw<=0||v.dl<=0||v.bw<=0||v.bl<=0){alert('راجع مقاسات ألواح الشاسيه والضلفة والضهر');return}closeBoardRules(true)}
function showBoardErrors(items){items=Array.isArray(items)?items:[];$('boardErrorSummary').textContent=`تعذر إنشاء الدولاب: يوجد ${items.length} قطعة تتجاوز مقاسات الألواح المحددة.`;$('boardErrorRows').innerHTML=items.map(v=>`<tr><td>${esc(v.name)}</td><td>${Number(v.part_width).toFixed(1)} × ${Number(v.part_length).toFixed(1)} سم</td><td>${esc(v.board_label)}</td><td>${Number(v.board_width).toFixed(1)} × ${Number(v.board_length).toFixed(1)} سم</td></tr>`).join('');$('boardErrorModal').classList.add('show')}
function closeBoardErrors(){$('boardErrorModal').classList.remove('show')}
function editBoardRulesFromError(){closeBoardErrors();openBoardRules()}
function showToolError(title,message){$('toolErrorTitle').textContent=title||'تعذر إنشاء الدولاب';$('toolErrorMessage').textContent=message||'حدث خطأ غير متوقع.';$('toolErrorModal').classList.add('show')}
function closeToolError(){$('toolErrorModal').classList.remove('show')}
function showCreationLoading(message='جاري تجهيز إنشاء الدولاب...'){updateCreationProgress(4,message);$('creationLoadingModal').classList.add('show')}
function updateCreationProgress(percent,message){const value=Math.max(0,Math.min(100,Number(percent)||0));$('creationProgressBar').style.width=`${value}%`;$('creationProgressValue').textContent=`${Math.round(value)}%`;if(message)$('creationLoadingText').textContent=message}
function hideCreationLoading(){$('creationLoadingModal').classList.remove('show')}
const TEMPLATE_NAMES=Array.from({length:20},(_,i)=>`تقسيمة ${i+1}`);
const L=(type='empty',count=0)=>({type,count});const V=(a,b,r=.5)=>({dir:'v',ratio:r,children:[a,b]});const H=(a,b,r=.5)=>({dir:'h',ratio:r,children:[a,b]});
function presetTree(id){id=Number(id);switch(id){
case 1:return H(L('shelves',2),V(L('shelves',4),L('hanging',1),.48),.46);
case 2:return H(L('shelves',2),H(V(L('shelves',1),L('shelves',3),.52),L('hanging',1),.48),.45);
case 3:return H(L('shelves',2),H(L('hanging',1),L('shelves',4),.48),.42);
case 4:return H(L('shelves',2),V(L('double_hang',2),L('shelves',3),.5),.45);
case 5:case 6:return H(L('shelves',2),V(L('hanging',1),L('hanging',1),.5),.43);
case 7:return L('shelves',7);
case 8:return H(H(L('shelves',2),L('hanging',1),.5),V(L('drawers',4),L('shelves',4),.5),.62);
case 9:return H(L('shelves',2),V(L('shelves',4),L('shelves',3),.5),.43);
case 10:case 11:return H(H(L('shelves',2),L('hanging',1),.48),L('drawers',id===10?1:1),.84);
case 12:return H(H(L('shelves',2),L('hanging',1),.48),L('drawers',2),.76);
case 13:return H(L('shelves',2),H(L('hanging',1),L('hanging',1),.5),.4);
case 14:return H(H(L('shelves',2),L('hanging',1),.5),V(L('hanging',1),L('shelves',3),.52),.62);
case 15:return H(L('shelves',2),L('hanging',1),.4);
case 16:return H(L('shelves',4),V(L('shelves',1),L('shelves',3),.5),.65);
case 17:return H(H(L('shelves',3),V(V(L('empty'),L('empty'),.5),L('empty'),.66),.68),L('drawers',4),.66);
case 18:return H(H(L('shelves',2),V(L('shelves',1),L('empty'),.5),.6),L('drawers',4),.65);
case 19:return H(H(L('shelves',2),V(L('shelves',2),L('shelves',2),.5),.58),L('drawers',4),.64);
case 20:return H(H(L('shelves',2),L('hanging',1),.48),L('drawers',4),.64);default:return L('shelves',4)}}
const FILLER_TEMPLATE_NAMES=['سدّة 1 — درجين','سدّة 2 — درج واحد','سدّة 3 — 4 أدراج','سدّة 4 — أرفف كاملة','سدّة 5 — شماعة','سدّة 6 — شماعة وأرفف','سدّة 7 — أرفف مركزة','سدّة 8 — شماعة ورف سفلي'];
const FILLER_PREVIEW_IDS=[12,10,20,7,15,3,9,3];
function fillerPresetTree(id){id=Number(id);const top=()=>H(L('shelves',2),L('hanging',1),.38),bottom=n=>V(L('drawers',n),L('empty'),.46);switch(id){case 1:return H(top(),bottom(2),.78);case 2:return H(top(),bottom(1),.86);case 3:return H(top(),bottom(4),.68);case 4:return L('shelves',7);case 5:return H(L('shelves',2),L('hanging',1),.4);case 6:return H(L('shelves',2),H(L('hanging',1),L('shelves',4),.5),.35);case 7:return H(L('shelves',2),L('shelves',5),.34);case 8:return H(L('shelves',2),H(L('hanging',1),L('shelves',1),.72),.34);default:return H(L('shelves',2),L('hanging',1),.4)}}
function flipTreeHorizontally(n){if(!n||!n.dir)return n;n.children.forEach(flipTreeHorizontally);if(n.dir==='v'){n.children.reverse();n.ratio=1-Number(n.ratio||.5)}return n}
function selectedFillerColumn(){const column=selectionTarget==='column'?selectedColumnInfo():null,door=column&&column.node?column.node.column_door:null;return door&&door.filler_side&&door.filler_side!=='none'?{column,door}:null}
function cloneTree(v){return JSON.parse(JSON.stringify(v));}
function nodeAt(path){let n=layoutTree;for(const i of path)n=n.children[i];return n;}
function parentInfo(path){if(!path.length)return null;const pp=path.slice(0,-1);return{parent:nodeAt(pp),index:path[path.length-1],path:pp};}
function rectAt(path){const t=val('thickness'),fixed=$('fixedTopShelf').value==='yes',reserved=fixed?Math.max(1,val('fixedTopClearHeight'))+t:0;let r={w:Math.max(1,cabinetWidth-2*t),h:Math.max(1,val('height')-2*t-reserved)},n=layoutTree;for(const idx of path){if(n.dir==='v'){const available=Math.max(1,r.w-t),first=available*n.ratio;r.w=idx===0?first:available-first}else if(n.dir==='h'){const available=Math.max(1,r.h-t),first=available*n.ratio;r.h=idx===0?first:available-first}n=n.children[idx]}return r;}
function leafBoundaries(path){let b={left:'outer',right:'outer',bottom:'outer',top:'outer'},n=layoutTree;for(const idx of path){if(n.dir==='v'){if(idx===0)b.right='partition';else b.left='partition'}else if(n.dir==='h'){if(idx===0)b.bottom='shelf';else b.top='shelf'}n=n.children[idx]}return b;}
function nearestAxis(path,dir){let n=layoutTree,last=null,p=[];for(const idx of path){if(n.dir===dir)last={node:n,index:idx,path:p.slice()};p.push(idx);n=n.children[idx]}return last;}
function resizeSelected(axis){const dir=axis==='w'?'v':'h',info=nearestAxis(selectedPath,dir);if(!info)return;const t=val('thickness'),parentRect=rectAt(info.path),available=Math.max(1,(axis==='w'?parentRect.w:parentRect.h)-t),field=axis==='w'?'selectedOpeningWidth':'selectedOpeningHeight',wanted=Math.max(5,Math.min(available-5,val(field)));info.node.ratio=info.index===0?wanted/available:1-wanted/available;info.node.ratio=Math.max(.08,Math.min(.92,info.node.ratio));updateOpeningEditor();draw();}
function setNode(path,node){if(!path.length){layoutTree=node;return}const p=parentInfo(path);p.parent.children[p.index]=node;}
function equalColumnsTree(count,clear,t){if(count<=1)return L('shelves',3);const region=count*clear+(count-1)*t,available=Math.max(.1,region-t);return{dir:'v',ratio:Math.max(.02,Math.min(.98,clear/available)),external:true,children:[L('shelves',3),equalColumnsTree(count-1,clear,t)]};}
function updateColumnSummary(){if(!$('columnEqualSummary'))return;const n=Math.max(1,parseInt($('columnCount').value||1)),t=Math.max(.1,val('thickness')),w=Math.max(0,cabinetWidth),clear=(w-(n+1)*t)/n;$('columnEqualSummary').textContent=clear>0?`الصافي المبدئي لكل عمود: ${clear.toFixed(1)} سم — الإجمالي شامل الجنبين والقواطيع: ${w.toFixed(1)} سم`:'المقاس لا يكفي للجنبين والقواطيع';}
function applyColumnCount(){const n=Math.max(1,Math.min(12,parseInt($('columnCount').value||1))),t=Math.max(.1,val('thickness')),w=Math.max(20,val('carcassWidth')),clear=(w-(n+1)*t)/n;if(clear<10){showToolError(`تعذر تقسيم الشاسيه إلى ${n} أعمدة.\nالصافي الناتج لكل عمود ${clear.toFixed(1)} سم فقط. كبّر عرض الشاسيه أو قلّل عدد الأعمدة.`);return}cabinetWidth=w;layoutTree=equalColumnsTree(n,clear,t);easyTemplate='';selectedPath=[];$('carcassWidth').value=cabinetWidth.toFixed(1);$('columnCount').value=n;
renderTemplates();updateOpeningEditor();updateColumnSummary();draw();}
function selectLayout(key){preserveEditorScroll(()=>{selectedPath=key?key.split('_').filter(Boolean).map(Number):[];selectionTarget='opening';selectedPart=null;updateOpeningEditor();updateAccessoryEditor();renderTemplates();draw()})}
const DRAWER_NODE_FIELDS=[['nodeDrawerFrontCut','drawer_front_cut',0],['nodeRunnerClearance','runner_clearance',1.3],['nodeRunnerLength','runner_length',0],['nodeChassisHeight','chassis_height',13],['nodeBottomThickness','bottom_thickness',.6],['nodeBottomDrop','bottom_drop',1.8],['nodeBottomGrooveDepth','bottom_groove_depth',.6],['nodeFrontGap','front_gap',.3],['nodeFrontThickness','front_thickness',1.8]];
const INNER_ELITA_FIELDS=[
 ['innerElitaEdgeOffset','inner_elita_edge_offset','elita_edge_offset',5],
 ['innerElitaScrewDrillDiameter','inner_elita_screw_drill_diameter','elita_screw_drill_diameter',.8],
 ['innerElitaDowelDiameter','inner_elita_dowel_diameter','elita_dowel_diameter',.8],
 ['innerElitaDowelDepth','inner_elita_dowel_depth','elita_dowel_depth',1.05],
 ['innerElitaCamDiameter','inner_elita_cam_diameter','elita_cam_diameter',1.5],
 ['innerElitaCamDepth','inner_elita_cam_depth','elita_cam_depth',1.2],
 ['innerElitaScrewAfterThread','inner_elita_screw_after_thread','elita_screw_after_thread',3.2],
 ['innerElitaCoilDrillDiameter','inner_elita_coil_drill_diameter','elita_coil_drill_diameter',.8],
 ['innerElitaCoilLength','inner_elita_coil_length','elita_coil_length',4],
 ['innerElitaCoilFaceDepth','inner_elita_coil_face_depth','elita_coil_face_depth',2],
 ['innerElitaCoilCenterDistance','inner_elita_coil_center_distance','elita_coil_center_distance',2.5]
];
function currentDrawerOpeningNode(){const n=nodeAt(selectedPath);return n&&!n.dir&&n.type==='drawers'?n:null}
function updateInnerDrawerJoineryUi(){
 const n=currentDrawerOpeningNode(),show=!!n;
 $('generalJoineryGroup').style.display=show?'none':'';
 $('innerDrawerJoineryGroup').style.display=show?'':'none';
 if(show)$('elitaCoilOptions').style.display='none';else updateJoineryOptions();
 if(!show)return;
 $('innerDrawerJoinery').value=n.inner_drawer_joinery||'screw';
 INNER_ELITA_FIELDS.forEach(f=>{$(f[0]).value=n[f[1]]===undefined?(INITIAL[f[2]]===undefined?f[3]:INITIAL[f[2]]):n[f[1]]});
 $('innerElitaCoilCount').value=String(n.inner_elita_coil_count===2?2:(INITIAL.elita_coil_count===2?2:1));
 $('innerDrawerElitaOptions').style.display=$('innerDrawerJoinery').value==='elita'?'':'none';
}
function saveInnerDrawerJoinery(){
 const n=currentDrawerOpeningNode();if(!n)return;
 n.inner_drawer_joinery=$('innerDrawerJoinery').value||'screw';
 INNER_ELITA_FIELDS.forEach(f=>n[f[1]]=Math.max(.01,parseFloat($(f[0]).value||f[3])));
 n.inner_elita_coil_count=parseInt($('innerElitaCoilCount').value||1)===2?2:1;
 $('innerDrawerElitaOptions').style.display=n.inner_drawer_joinery==='elita'?'':'none';
 draw();
}

function overlayDrawerTopJs(n,z,h,t){if(!n)return null;if(n.dir==='v'&&n.children){const vals=n.children.map(c=>overlayDrawerTopJs(c,z,h,t)).filter(v=>v!==null);return vals.length?Math.max(...vals):null}if(n.dir==='h'&&n.children){const top=(h-t)*Math.max(.18,Math.min(.82,Number(n.ratio||.5))),bottom=h-t-top,divider=z+bottom,vals=[overlayDrawerTopJs(n.children[0],divider+t,top,t),overlayDrawerTopJs(n.children[1],z,bottom,t)].filter(v=>v!==null);return vals.length?Math.max(...vals):null}return n.type==='drawers'&&['overlay_front','flush_carcass'].includes(n.drawer_pattern)?z+h:null}
function openingFlipUpLimitJs(n,z,h,t,bottomBoundary='outer'){if(!n)return null;if(n.dir==='v'&&n.children){const vals=n.children.map(c=>openingFlipUpLimitJs(c,z,h,t,bottomBoundary)).filter(v=>v!==null);return vals.length?Math.min(...vals):null}if(n.dir==='h'&&n.children){const top=(h-t)*Math.max(.18,Math.min(.82,Number(n.ratio||.5))),bottom=h-t-top,divider=z+bottom,vals=[openingFlipUpLimitJs(n.children[0],divider+t,top,t,'shelf'),openingFlipUpLimitJs(n.children[1],z,bottom,t,bottomBoundary)].filter(v=>v!==null);return vals.length?Math.min(...vals):null}if(n.type==='drawers'&&['overlay_front','flush_carcass'].includes(n.drawer_pattern||'thick_side'))return null;const door=n.opening_door;return door&&door.enabled==='yes'&&door.direction==='flip_up'?z-(bottomBoundary==='outer'?t:t/2):null}
function openingDoorIntervalsJs(n,z,h,t,bottomBoundary='outer',topBoundary='outer',out=[]){if(!n)return out;if(n.dir==='v'&&n.children){n.children.forEach(c=>openingDoorIntervalsJs(c,z,h,t,bottomBoundary,topBoundary,out));return out}if(n.dir==='h'&&n.children){const top=(h-t)*Math.max(.18,Math.min(.82,Number(n.ratio||.5))),bottom=h-t-top,divider=z+bottom;openingDoorIntervalsJs(n.children[0],divider+t,top,t,'shelf',topBoundary,out);openingDoorIntervalsJs(n.children[1],z,bottom,t,bottomBoundary,'shelf',out);return out}if(n.type==='drawers'&&['overlay_front','flush_carcass'].includes(n.drawer_pattern||'thick_side'))return out;const door=n.opening_door;if(door&&door.enabled==='yes')out.push([z-(bottomBoundary==='outer'?t:t/2),z+h+(topBoundary==='outer'?t:t/2)]);return out}
function openingDoorFreeSpanJs(n,z,h,t,baseBottom,baseTop){const blocked=openingDoorIntervalsJs(n,z,h,t).map(v=>[Math.max(baseBottom,v[0]),Math.min(baseTop,v[1])]).filter(v=>v[1]>v[0]).sort((a,b)=>a[0]-b[0]);if(!blocked.length)return[baseBottom,baseTop];const merged=[];blocked.forEach(v=>{if(!merged.length||v[0]>merged[merged.length-1][1])merged.push(v.slice());else merged[merged.length-1][1]=Math.max(merged[merged.length-1][1],v[1])});const gaps=[];let cursor=baseBottom;merged.forEach(v=>{if(v[0]>cursor)gaps.push([cursor,v[0]]);cursor=Math.max(cursor,v[1])});if(baseTop>cursor)gaps.push([cursor,baseTop]);return gaps.sort((a,b)=>(b[1]-b[0])-(a[1]-a[0]))[0]||null}
function updateOpeningEditor(){const n=nodeAt(selectedPath);const leaf=!n.dir;$('leafType').disabled=!leaf;$('leafCount').disabled=!leaf;if(leaf){$('leafType').value=n.type||'empty';$('leafCount').value=n.count||0}const dims=rectAt(selectedPath),vw=nearestAxis(selectedPath,'v'),vh=nearestAxis(selectedPath,'h');$('selectedOpeningWidth').value=dims.w.toFixed(1);$('selectedOpeningHeight').value=dims.h.toFixed(1);$('selectedOpeningWidth').disabled=!vw;$('selectedOpeningHeight').disabled=!vh;const isDrawer=leaf&&n.type==='drawers';$('leafDrawerOptions').style.display=isDrawer?'':'none';const isOverlayDrawer=isDrawer&&['overlay_front','flush_carcass'].includes(n.drawer_pattern||'thick_side');if(isDrawer){DRAWER_NODE_FIELDS.forEach(f=>$(f[0]).value=n[f[1]]===undefined?f[2]:n[f[1]]);$('nodeDrawerPattern').value=n.drawer_pattern||'thick_side';const pattern=$('nodeDrawerPattern').value;const frontMode=['overlay_front','flush_carcass'].includes(pattern);const cutField=$('nodeDrawerFrontCut').closest('.field');if(cutField)cutField.style.display=frontMode?'none':'';$('nodeDrawerFrontCut').disabled=frontMode;if(frontMode)$('nodeDrawerFrontCut').value=0;$('drawerPatternNote').textContent=pattern==='overlay_front'?'على وش الضلفة: بدون شاسيه خارجي، والوشوش تغطي الجنب والقاطع مثل الضلف — ولا يقبل قصًا أماميًا أو ضلفة إضافية لنفس الفراغ.':pattern==='flush_carcass'?'مساوي للشاسيه: نفس تكوين «على وش الضلفة» بالكامل، لكن وش الدرج يتحسب من جوه الجنب/القاطع ويكون داخل الفتحة ومساويًا لمستوى الشاسيه.':'جنب سميك: شاسيه خارجي كامل حول صناديق الأدراج.'}const column=selectedColumnInfo(),hinged=$('doorSystem').value==='hinged';$('columnDoorOptions').style.display=column&&hinged?'':'none';if(column&&hinged){const door=column.node.column_door||{enabled:'no',direction:'right',style:'wood'};$('columnDoorEnabled').value=door.enabled||'no';$('columnDoorDirection').value=door.direction||'right';$('columnDoorStyle').value=door.style||'wood';const disabled=$('columnDoorEnabled').value!=='yes';$('columnDoorDirection').disabled=disabled;$('columnDoorStyle').disabled=disabled;const clear=val('doorClearance'),t=val('thickness'),columns=collectColumns(layoutTree,0,Math.max(1,cabinetWidth-2*t)),columnIndex=columns.findIndex(c=>samePath(c.path,column.path)),size=rectAt(column.path),leftOverlay=columnIndex===0?t:t/2,rightOverlay=columnIndex===columns.length-1?t:t/2,coveredWidth=size.w+leftOverlay+rightOverlay,doubleDoor=$('columnDoorDirection').value==='double',doorWidth=doubleDoor?coveredWidth/2-clear*2:coveredWidth-clear*2,drawerTop=overlayDrawerTopJs(column.node,t,size.h,t),doorHeight=val('height')-(drawerTop===null?clear:drawerTop+clear)-clear;$('columnDoorSize').textContent=`صافي العمود: ${size.w.toFixed(1)} سم — التغطية: ${coveredWidth.toFixed(1)} سم — مقاس كل ضلفة: ${Math.max(0,doorWidth).toFixed(1)} × ${Math.max(0,doorHeight).toFixed(1)} سم`}$('openingDoorOptions').style.display=leaf&&hinged&&!isOverlayDrawer?'':'none';if(leaf&&hinged&&!isOverlayDrawer){const door=n.opening_door||{enabled:'no',direction:'right',style:'wood'},b=leafBoundaries(selectedPath),t=val('thickness'),clear=val('doorClearance'),coveredWidth=dims.w+(b.left==='outer'?t:t/2)+(b.right==='outer'?t:t/2),coveredHeight=dims.h+(b.bottom==='outer'?t:t/2)+(b.top==='outer'?t:t/2);$('openingDoorEnabled').value=door.enabled||'no';$('openingDoorDirection').value=door.direction||'right';$('openingDoorStyle').value=door.style||'wood';const disabled=$('openingDoorEnabled').value!=='yes';$('openingDoorDirection').disabled=disabled;$('openingDoorStyle').disabled=disabled;const doubleDoor=$('openingDoorDirection').value==='double',doorWidth=doubleDoor?coveredWidth/2-clear*2:coveredWidth-clear*2,doorHeight=coveredHeight-clear*2;$('openingDoorSize').textContent=`صافي الفراغ: ${dims.w.toFixed(1)} × ${dims.h.toFixed(1)} سم — مقاس ${$('openingDoorDirection').value==='flip_up'?'القلاب':'كل ضلفة'}: ${Math.max(0,doorWidth).toFixed(1)} × ${Math.max(0,doorHeight).toFixed(1)} سم`}const p=parentInfo(selectedPath);$('leafRatio').disabled=!p;if(p){let shown=p.index===0?p.parent.ratio:1-p.parent.ratio;$('leafRatio').value=Math.round(shown*100);$('ratioText').textContent=Math.round(shown*100)+'%'}else $('ratioText').textContent='الفتحة الرئيسية';updateInnerDrawerJoineryUi();}
const updateOpeningEditorCore=updateOpeningEditor;
updateOpeningEditor=function(){updateOpeningEditorCore();const hinged=$('doorSystem').value==='hinged',columnMode=selectionTarget==='column';if(columnMode){$('openingDoorOptions').style.display='none';const column=selectedColumnInfo();if(hinged&&column){const clear=val('doorClearance'),t=val('thickness'),columns=collectColumns(layoutTree,0,Math.max(1,cabinetWidth-2*t)),columnIndex=columns.findIndex(c=>samePath(c.path,column.path)),size=rectAt(column.path),leftOverlay=columnIndex===0?t:t/2,rightOverlay=columnIndex===columns.length-1?t:t/2,coveredWidth=size.w+leftOverlay+rightOverlay,doubleDoor=$('columnDoorDirection').value==='double',doorWidth=doubleDoor?coveredWidth/2-clear*2:coveredWidth-clear*2,drawerTop=overlayDrawerTopJs(column.node,t,size.h,t),doorBottom=drawerTop===null?clear:drawerTop+clear,freeSpan=openingDoorFreeSpanJs(column.node,t,size.h,t,doorBottom,val('height')-clear),doorHeight=freeSpan?Math.max(0,freeSpan[1]-freeSpan[0]):0;$('columnDoorSize').textContent=`صافي العمود: ${size.w.toFixed(1)} سم — التغطية: ${coveredWidth.toFixed(1)} سم — مقاس كل ضلفة: ${Math.max(0,doorWidth).toFixed(1)} × ${doorHeight.toFixed(1)} سم${freeSpan?'':' — لا توجد مساحة متبقية'}`}}else $('columnDoorOptions').style.display='none';const visible=hinged&&((columnMode&&$('columnDoorOptions').style.display!=='none')||(!columnMode&&$('openingDoorOptions').style.display!=='none'));if(visible&&activeOptionsTab==='structure')$('doorStructureGroup').open=true;}
const updateOpeningEditorBeforeSliding=updateOpeningEditor;
updateOpeningEditor=function(){updateOpeningEditorBeforeSliding();updateSlidingDoorOptions();if($('doorSystem').value!=='sliding'||selectionTarget!=='column')return;const column=selectedColumnInfo(),columns=collectColumns(layoutTree,0,Math.max(1,cabinetWidth-2*val('thickness'))),index=column?columns.findIndex(c=>samePath(c.path,column.path)):-1,first=parseInt($('slidingFirstColumn').value||0),last=parseInt($('slidingSecondColumn').value||1);$('openingDoorOptions').style.display='none';if(column&&(index<first||index>last)){$('columnDoorOptions').style.display='';const door=column.node.column_door||{enabled:'no',direction:'right',style:'wood'};$('columnDoorEnabled').value=door.enabled||'no';$('columnDoorDirection').value=door.direction||'right';$('columnDoorStyle').value=door.style||'wood';$('columnDoorEnabled').options[1].textContent='إضافة ضلفة مفصلية';const disabled=$('columnDoorEnabled').value!=='yes';$('columnDoorDirection').disabled=disabled;$('columnDoorStyle').disabled=disabled;$('columnDoorSize').textContent=`العمود ${index+1} خارج مساحة الجرار — يمكن إضافة ضلفة مفصلية له بشكل مستقل`;$('doorStructureGroup').open=true}else $('columnDoorOptions').style.display='none'}
const updateOpeningEditorBeforeHingeCount=updateOpeningEditor;
updateOpeningEditor=function(){updateOpeningEditorBeforeHingeCount();const fallback=Math.max(1,Math.min(12,parseInt(INITIAL.hinge_count||4)));const column=selectedColumnInfo(),node=nodeAt(selectedPath);if(column&&$('columnHingeCount')){const door=column.node.column_door||{},filler=door.filler_side||'none';$('columnHingeCount').value=door.hinge_count===undefined?fallback:door.hinge_count;$('columnFillerSide').value=filler;$('columnFillerDepth').value=door.filler_depth===undefined?Math.max(0.1,val('depth')):door.filler_depth;$('columnFillerDepth').disabled=filler==='none';$('columnFillerInternalCut').value=door.filler_internal_cut===undefined?5:door.filler_internal_cut;$('columnFillerInternalCut').disabled=filler==='none';if($('columnFillerReturnDepth')){$('columnFillerReturnDepth').value=door.filler_return_depth===undefined?0:door.filler_return_depth;$('columnFillerReturnDepth').disabled=filler==='none'}if($('columnFillerProjection')){$('columnFillerProjection').value=door.filler_projection===undefined?0:door.filler_projection;$('columnFillerProjection').disabled=filler==='none'}if($('columnFillerHingeType')){$('columnFillerHingeType').value=door.filler_hinge_type||'straight';$('columnFillerHingeType').disabled=filler==='none'}if(filler!=='none'){$('columnDoorDirection').value=filler;$('columnDoorDirection').disabled=true}else $('columnDoorDirection').disabled=$('columnDoorEnabled').value!=='yes';$('columnHingeCount').disabled=$('columnDoorEnabled').value!=='yes'}if(node&&!node.dir&&$('openingHingeCount')){const door=node.opening_door||{};$('openingHingeCount').value=door.hinge_count===undefined?fallback:door.hinge_count;$('openingHingeCount').disabled=$('openingDoorEnabled').value!=='yes';if($('openingLiftCount'))$('openingLiftCount').value=String(door.lift_count===undefined?1:Math.max(1,Math.min(2,parseInt(door.lift_count||1))));if($('flipUpLiftOptions'))$('flipUpLiftOptions').style.display=$('openingDoorEnabled').value==='yes'&&$('openingDoorDirection').value==='flip_up'?'':'none'}}
function splitSelected(dir){const old=cloneTree(nodeAt(selectedPath));setNode(selectedPath,{dir,ratio:.5,children:[old,L('empty')]});selectedPath=selectedPath.concat(0);updateOpeningEditor();
renderTemplates();draw();}
function addOpening(){splitSelected('v');}
function addExternalOpening(){const nw=Math.max(20,val('newOpeningWidth')),t=val('thickness'),oldInner=Math.max(1,cabinetWidth-2*t),denom=oldInner+nw,side=$('newOpeningSide').value,newLeaf=L('shelves',3),old=cloneTree(layoutTree);if(!old.external&&!old.column_width)old.column_width=cabinetWidth;newLeaf.column_width=nw;if(side==='left'){layoutTree={dir:'v',ratio:nw/denom,external:true,children:[newLeaf,old]};selectedPath=[0]}else{layoutTree={dir:'v',ratio:oldInner/denom,external:true,children:[old,newLeaf]};selectedPath=[1]}cabinetWidth=cabinetWidth+nw+t;$('carcassWidth').value=cabinetWidth.toFixed(1);$('columnCount').value=collectColumns(layoutTree,0,Math.max(1,cabinetWidth-2*t)).length;easyTemplate='';
renderTemplates();updateOpeningEditor();updateColumnSummary();draw();}
function removeSelected(){const p=parentInfo(selectedPath);if(!p){alert('لا يمكن حذف التقسيمة الرئيسية');return}if(p.path.length===0&&p.parent.external&&p.parent.dir==='v'){const t=val('thickness'),inner=cabinetWidth-2*t,available=Math.max(1,inner-t),removed=available*(p.index===0?p.parent.ratio:1-p.parent.ratio);cabinetWidth=Math.max(40,cabinetWidth-removed-t)}const sibling=cloneTree(p.parent.children[p.index===0?1:0]);setNode(p.path,sibling);selectedPath=p.path;$('carcassWidth').value=cabinetWidth.toFixed(1);$('columnCount').value=collectColumns(layoutTree,0,Math.max(1,cabinetWidth-2*val('thickness'))).length;updateOpeningEditor();
renderTemplates();updateColumnSummary();draw();}
function mirrorNode(n){if(n&&n.dir){n.children.forEach(mirrorNode);if(n.dir==='v')n.children.reverse()}}
function mirrorLayout(){mirrorNode(layoutTree);selectedPath=[];updateOpeningEditor();draw();}
function saveLeaf(){const n=nodeAt(selectedPath);if(n.dir)return;n.type=$('leafType').value;n.count=Math.max(0,parseInt($('leafCount').value||0));if(n.type==='drawers'){n.drawer_pattern=$('nodeDrawerPattern').value||'thick_side';DRAWER_NODE_FIELDS.forEach(f=>n[f[1]]=Math.max(0,parseFloat($(f[0]).value||f[2])));if(['overlay_front','flush_carcass'].includes(n.drawer_pattern)){n.drawer_front_cut=0;if(n.opening_door)n.opening_door.enabled='no'}if(!n.inner_drawer_joinery)n.inner_drawer_joinery='screw'}updateOpeningEditor();draw();}
function saveRatio(){const p=parentInfo(selectedPath);if(!p)return;let r=Math.max(.18,Math.min(.82,val('leafRatio')/100));p.parent.ratio=p.index===0?r:1-r;$('ratioText').textContent=Math.round(r*100)+'%';draw();}
function selectedPartKey(){return selectedPart?`${selectedPart.path}|${selectedPart.kind}|${selectedPart.index}`:''}
function partIsSelected(path,kind,index){return selectedPartKey()===`${path}|${kind}|${index}`}
function selectPart(event,path,kind,index,label){if(event){event.stopPropagation();event.preventDefault()}preserveEditorScroll(()=>{selectedPath=path?path.split('_').filter(Boolean).map(Number):[];selectionTarget='part';selectedPart={path:path,kind:kind,index:Number(index),label:label};switchOptionsTab('accessories');updateOpeningEditor();updateAccessoryEditor();draw()})}
function partConfig(){if(!selectedPart)return null;const n=nodeAt(selectedPart.path?selectedPart.path.split('_').filter(Boolean).map(Number):[]);if(!n||n.dir)return null;n.accessory_items=n.accessory_items||{};const key=`${selectedPart.kind}:${selectedPart.index}`;n.accessory_items[key]=n.accessory_items[key]||{};return n.accessory_items[key]}
function updateAccessoryEditor(){const empty=$('accessorySelectionCard'),box=$('accessoryDynamicOptions');if(!selectedPart){empty.style.display='';box.style.display='none';return}empty.style.display='none';box.style.display='';$('selectedPartName').textContent=selectedPart.label;$('selectedPartMeta').textContent=`العنصر ${selectedPart.index} داخل الفتحة المحددة — اضغط حفظ بعد اختيار الإكسسوار.`;['hangerAccessoryFields','drawerAccessoryFields','shelfAccessoryFields','doorAccessoryFields'].forEach(id=>$(id).style.display='none');const map={hanger:'hangerAccessoryFields',drawer:'drawerAccessoryFields',shelf:'shelfAccessoryFields',door:'doorAccessoryFields'};if(map[selectedPart.kind])$(map[selectedPart.kind]).style.display='';const cfg=partConfig()||{};if(selectedPart.kind==='hanger')$('hangerAccessoryType').value=cfg.accessory_type||'rod';if(selectedPart.kind==='drawer'){const drawerNode=nodeAt(selectedPart.path?selectedPart.path.split('_').filter(Boolean).map(Number):[]);const drainAllowed=drawerNode&&['overlay_front','flush_carcass'].includes(drawerNode.drawer_pattern||'thick_side');$('drawerRunnerType').value=cfg.runner_type||'side';$('accessoryRunnerClearance').value=cfg.runner_clearance===undefined?1.3:cfg.runner_clearance;$('drawerOrganizerType').value=cfg.organizer_type||'none';$('drawerOrganizerCount').value=cfg.organizer_count===undefined?3:cfg.organizer_count;$('drawerOrganizerCount').disabled=$('drawerOrganizerType').value==='none';$('drawerDrainWrap').style.display=drainAllowed?'':'none';if(!drainAllowed){cfg.drain_relief='no'}$('drawerDrainRelief').value=drainAllowed?(cfg.drain_relief||'no'):'no';$('drawerDrainWidth').value=cfg.drain_cut_width===undefined?17:cfg.drain_cut_width;$('drawerDrainDepth').value=cfg.drain_cut_depth===undefined?25:cfg.drain_cut_depth;$('drawerDrainFields').style.display=drainAllowed&&$('drawerDrainRelief').value==='yes'?'':'none'}if(selectedPart.kind==='shelf')$('shelfSupportType').value=cfg.support_type||'default'}
$('drawerOrganizerType').addEventListener('change',()=>{$('drawerOrganizerCount').disabled=$('drawerOrganizerType').value==='none'});
$('drawerDrainRelief').addEventListener('change',()=>{const n=selectedPart?nodeAt(selectedPart.path?selectedPart.path.split('_').filter(Boolean).map(Number):[]):null;const ok=n&&(n.drawer_pattern||'thick_side')==='overlay_front';$('drawerDrainFields').style.display=ok&&$('drawerDrainRelief').value==='yes'?'':'none'});
function saveSelectedAccessory(){const cfg=partConfig();if(!cfg)return;if(selectedPart.kind==='hanger')cfg.accessory_type=$('hangerAccessoryType').value;if(selectedPart.kind==='drawer'){const n=nodeAt(selectedPart.path?selectedPart.path.split('_').filter(Boolean).map(Number):[]);const drainAllowed=n&&['overlay_front','flush_carcass'].includes(n.drawer_pattern||'thick_side');cfg.runner_type=$('drawerRunnerType').value;cfg.runner_clearance=Math.max(0,val('accessoryRunnerClearance'));cfg.organizer_type=$('drawerOrganizerType').value;cfg.organizer_count=Math.max(1,Math.min(8,parseInt($('drawerOrganizerCount').value||3)));cfg.drain_relief=drainAllowed?$('drawerDrainRelief').value:'no';if(drainAllowed){cfg.drain_cut_width=Math.max(5,val('drawerDrainWidth')||17);cfg.drain_cut_depth=Math.max(5,val('drawerDrainDepth')||25)}}if(selectedPart.kind==='shelf')cfg.support_type=$('shelfSupportType').value;updateAccessoryEditor();draw()}
function renderTreeSvg(n,x,y,w,h,path=[]){if(!n)return'';const gap=5;if(n.dir==='v'){const w1=(w-gap)*n.ratio;return renderTreeSvg(n.children[0],x,y,w1,h,path.concat(0))+renderTreeSvg(n.children[1],x+w1+gap,y,w-w1-gap,h,path.concat(1))}if(n.dir==='h'){const h1=(h-gap)*n.ratio;return renderTreeSvg(n.children[0],x,y,w,h1,path.concat(0))+renderTreeSvg(n.children[1],x,y+h1+gap,w,h-h1-gap,path.concat(1))}const key=path.join('_'),active=key===selectedPath.join('_'),overlayDrawer=n.type==='drawers'&&['overlay_front','flush_carcass'].includes(n.drawer_pattern||'thick_side'),openingDoor=!overlayDrawer&&n.opening_door&&n.opening_door.enabled==='yes';let s=`<g onclick="selectLayout('${key}')"><rect x="${x}" y="${y}" width="${w}" height="${h}" rx="3" fill="${active?'#3a3820':'#102735'}" stroke="${active?'#ffd54f':openingDoor?'#4de37a':'#527083'}" stroke-width="${active?4:openingDoor?3:1.5}"/>`;const selectableLine=(yy,kind,index,label,c,sw)=>{const chosen=partIsSelected(key,kind,index),click=`selectPart(event,'${key}','${kind}',${index},'${label}')`;s+=`<line class="part-hit" onclick="${click}" x1="${x+4}" y1="${yy}" x2="${x+w-4}" y2="${yy}" stroke="transparent" stroke-width="16"/><line class="part-hit ${chosen?'part-selected':''}" onclick="${click}" x1="${x+4}" y1="${yy}" x2="${x+w-4}" y2="${yy}" stroke="${c}" stroke-width="${chosen?6:sw}"/>`};if(n.type==='shelves'||n.type==='shelves_hang'){const c=Math.max(1,n.count||3);for(let i=1;i<=c;i++)selectableLine(y+h*i/(c+1),'shelf',i,`رف ${i}`,'#f1d0a6',3)}if(n.type==='hanging'||n.type==='shelves_hang')selectableLine(y+h*.35,'hanger',1,'شماعة 1','#8ad8ff',5);if(n.type==='double_hang'){selectableLine(y+h*.32,'hanger',1,'شماعة 1','#8ad8ff',5);selectableLine(y+h*.72,'hanger',2,'شماعة 2','#8ad8ff',5)}if(n.type==='drawers'){const c=Math.max(1,n.count||4);for(let i=0;i<c;i++){const dy=y+h*i/c,dh=h/c,chosen=partIsSelected(key,'drawer',i+1);s+=`<rect class="part-hit ${chosen?'part-selected':''}" onclick="selectPart(event,'${key}','drawer',${i+1},'درج ${i+1}')" x="${x+3}" y="${dy+2}" width="${Math.max(1,w-6)}" height="${Math.max(1,dh-4)}" fill="rgba(130,92,66,.42)" stroke="#d8a66f" stroke-width="${chosen?5:1.5}"/>`}}if(openingDoor){const mark=n.opening_door.direction==='flip_up'?'قلاب ↑':n.opening_door.direction==='double'?'ضلفتان ↔':n.opening_door.direction==='left'?'ضلفة ←':'ضلفة →',chosen=partIsSelected(key,'door',1);s+=`<text class="part-hit ${chosen?'part-selected':''}" onclick="selectPart(event,'${key}','door',1,'ضلفة الفتحة')" x="${x+w/2}" y="${y+15}" fill="${chosen?'#ffd54f':'#4de37a'}" font-size="10" font-weight="bold" text-anchor="middle">${mark}</text>`}s+=`<text x="${x+w/2}" y="${y+h/2}" fill="#fff" font-size="12" text-anchor="middle" pointer-events="none">${({empty:'فراغ',shelves:'أرفف',hanging:'شماعة',double_hang:'شماعتان',drawers:'أدراج',shelves_hang:'أرفف + شماعة'})[n.type]||'فتحة'}</text></g>`;return s;}
function collectColumns(n,x,w,path=[],out=[]){const gap=5;if(n&&n.dir==='v'&&n.external){const w1=(w-gap)*n.ratio;collectColumns(n.children[0],x,w1,path.concat(0),out);collectColumns(n.children[1],x+w1+gap,w-w1-gap,path.concat(1),out)}else out.push({x,w,path:path.slice(),node:n});return out;}
function samePath(a,b){return a.length===b.length&&a.every((v,i)=>v===b[i])}
function selectedColumnInfo(){return collectColumns(layoutTree,0,Math.max(1,cabinetWidth-2*val('thickness'))).find(c=>samePath(c.path,selectedPath))||null}
function selectColumn(key){preserveEditorScroll(()=>{selectedPath=key?key.split('_').filter(Boolean).map(Number):[];selectionTarget='column';selectedPart=null;if(activeOptionsTab==='structure')$('doorStructureGroup').open=true;updateOpeningEditor();updateAccessoryEditor();renderTemplates();draw()})}
function saveColumnDoor(){const column=selectedColumnInfo();if(!column)return;const filler=$('columnFillerSide').value,direction=filler==='none'?$('columnDoorDirection').value:filler,enabled=filler==='none'?$('columnDoorEnabled').value:'yes';column.node.column_door={enabled:enabled,direction:direction,style:$('columnDoorStyle').value,hinge_count:Math.max(1,Math.min(12,parseInt($('columnHingeCount').value||4))),filler_side:filler,filler_depth:Math.max(.1,val('columnFillerDepth')),filler_return_depth:Math.max(0,val('columnFillerReturnDepth')),filler_projection:Math.max(0,val('columnFillerProjection')),filler_internal_cut:Math.max(0,val('columnFillerInternalCut')),filler_hinge_type:($('columnFillerHingeType')?$('columnFillerHingeType').value:'straight')};updateOpeningEditor();renderTemplates();draw()}
function saveOpeningDoor(){const n=nodeAt(selectedPath);if(!n||n.dir)return;if(n.type==='drawers'&&['overlay_front','flush_carcass'].includes(n.drawer_pattern||'thick_side')){n.opening_door={enabled:'no'};updateOpeningEditor();draw();return}n.opening_door={enabled:$('openingDoorEnabled').value,direction:$('openingDoorDirection').value,style:$('openingDoorStyle').value,hinge_count:Math.max(1,Math.min(12,parseInt($('openingHingeCount').value||4))),lift_count:Math.max(1,Math.min(2,parseInt(($('openingLiftCount')&&$('openingLiftCount').value)||1)))};updateOpeningEditor();draw()}
function renderColumnSelectors(x,y,w){const sliding=$('doorSystem')&&$('doorSystem').value==='sliding',sf=sliding&&$('slidingFirstColumn').options.length?parseInt($('slidingFirstColumn').value):0,count=sliding&&$('slidingLeafCount')&&parseInt($('slidingLeafCount').value||2)===3?3:2,sl=sf+count-1;return collectColumns(layoutTree,x,w).map((c,i)=>{const key=c.path.join('_'),active=key===selectedPath.join('_'),inSlide=sliding&&i>=sf&&i<=sl,door=c.node&&c.node.column_door,arrow=door&&door.direction==='left'?'←':door&&door.direction==='double'?'↔':'→',mark=inSlide?' — جرار':door&&door.enabled==='yes'?` ${door.style==='glass'?'زجاج':'خشب'} ${arrow}`:'';return `<g onclick="selectColumn('${key}')"><rect x="${c.x}" y="${y}" width="${c.w}" height="22" rx="5" fill="${active?'#ffd54f':inSlide?'#245f55':'#173648'}" stroke="${inSlide?'#4de37a':'#8ad8ff'}"/><text x="${c.x+c.w/2}" y="${y+15}" text-anchor="middle" font-size="11" font-weight="bold" fill="${active?'#07131d':'#fff'}">تحديد العمود ${i+1}${mark}</text></g>`}).join('');}
function layoutSvg(id,x=7,y=4,w=66,h=66){id=Number(id);let s=`<rect x="${x}" y="${y}" width="${w}" height="${h}" fill="#102735" stroke="#f1d0a6" stroke-width="2"/>`;const line=(x1,y1,x2,y2,c='#f1d0a6',sw=2)=>s+=`<line x1="${x1}" y1="${y1}" x2="${x2}" y2="${y2}" stroke="${c}" stroke-width="${sw}"/>`;line(x,y+h*.25,x+w,y+h*.25);line(x,y+h*.45,x+w,y+h*.45);const splitIds=[1,2,4,5,6,8,9,14,16,17,18,19];if(splitIds.includes(id))line(x+w*.5,y+h*.45,x+w*.5,y+h);const many=[3,7,8,9,14,16].includes(id);if(many){line(x,y+h*.62,x+w,y+h*.62);line(x,y+h*.76,x+w,y+h*.76);line(x,y+h*.88,x+w,y+h*.88)}const drawers=[8,10,11,12,17,18,19,20].includes(id);if(drawers){for(let k=0;k<4;k++){let yy=y+h*.72+k*h*.07;line(x+2,yy,x+w-2,yy,'#d8a66f',3)}}const rods=[1,3,4,5,6,8,10,11,12,13,14,15,20].includes(id);if(rods)line(x+7,y+h*.53,x+w-7,y+h*.53,'#8ad8ff',3);return s;}
function renderTemplates(){const filler=selectedFillerColumn(),columnMode=selectionTarget==='column',names=filler?FILLER_TEMPLATE_NAMES:TEMPLATE_NAMES,leftFlip=filler&&filler.door.filler_side==='left',section=$('templateSection');if(section)section.classList.toggle('template-section-locked',!columnMode);$('templateTargetHint').textContent=!columnMode?'حدد العمود من أعلى المعاينة لتفعيل التقسيمات':(filler?`تقسيمات السدّة ${filler.door.filler_side==='right'?'يمين':'شمال — معكوسة تلقائيًا'}`:'سيتم تطبيق التقسيمة على العمود المحدد فقط');$('templateGrid').innerHTML=names.map((n,i)=>{const preview=layoutSvg(filler?FILLER_PREVIEW_IDS[i]:i+1);return`<button class="template-card" ${columnMode?'':'disabled'} onclick="chooseTemplate(${i+1})"><svg viewBox="0 0 80 74">${leftFlip?`<g transform="translate(80 0) scale(-1 1)">${preview}</g>`:preview}</svg><small>${n}</small></button>`}).join('');}
function chooseTemplate(id){if(selectionTarget!=='column')return;const previous=nodeAt(selectedPath),savedDoor=previous&&previous.column_door?cloneTree(previous.column_door):null,savedOpeningDoor=previous&&previous.opening_door?cloneTree(previous.opening_door):null,savedAccessories=previous&&previous.accessory_items?cloneTree(previous.accessory_items):null,filler=savedDoor&&savedDoor.filler_side&&savedDoor.filler_side!=='none',tree=filler?fillerPresetTree(id):presetTree(id);if(filler&&savedDoor.filler_side==='left')flipTreeHorizontally(tree);if(savedDoor)tree.column_door=savedDoor;if(savedOpeningDoor)tree.opening_door=savedOpeningDoor;if(savedAccessories)tree.accessory_items=savedAccessories;if(selectedPath.length){setNode(selectedPath,tree);easyTemplate=''}else{layoutTree=tree;easyTemplate=filler?'':String(id);selectedPath=[]}selectedPart=null;advancedMode=false;document.body.classList.remove('advanced-on');
renderTemplates();updateOpeningEditor();draw();}
function toggleAdvanced(){advancedMode=!advancedMode;document.body.classList.toggle('advanced-on',advancedMode);if(advancedMode)easyTemplate='';else{easyTemplate='1';layoutTree=presetTree(1);selectedPath=[];updateOpeningEditor()}renderTemplates();draw();}
function ensureBay(b){Object.assign(b,{drawer_pattern:b.drawer_pattern||'external',drawer_height:Number(b.drawer_height||70),drawer_front_cut:Number(b.drawer_front_cut||0),runner_clearance:Number(b.runner_clearance||1.3),chassis_height:Number(b.chassis_height||13),drawer_thickness:Number(b.drawer_thickness||1.8),bottom_thickness:Number(b.bottom_thickness||.6),bottom_drop:Number(b.bottom_drop||1.8),bottom_groove_depth:Number(b.bottom_groove_depth||.6),rear_clearance:Number(b.rear_clearance||0),front_clearance:Number(b.front_clearance||.3),front_thickness:Number(b.front_thickness||1.8),shelf_front_cut:Number(b.shelf_front_cut||0),shelf_levels:b.shelf_levels||''});return b;}bays.forEach(ensureBay);
function renderPresets(){$('presets').innerHTML=Object.keys(PRESETS).map(k=>`<button class="preset ${bays[selected].preset===k?'active':''}" onclick="setPreset('${k}')"><span>${PRESETS[k][1]}</span>${PRESETS[k][0]}</button>`).join('');renderDetails();}
function renderDetails(){const b=ensureBay(bays[selected]),isDrawer=b.preset.includes('drawer');$('drawerDetails').style.display=isDrawer?'':'none';$('shelfDetails').style.display=isDrawer?'none':'';$('shelfLevels').value=b.shelf_levels;$('shelfFrontCut').value=b.shelf_front_cut;$('drawerPattern').value=b.drawer_pattern;[['drawerHeight','drawer_height'],['drawerFrontCut','drawer_front_cut'],['runnerClearance','runner_clearance'],['chassisHeight','chassis_height'],['drawerThickness','drawer_thickness'],['bottomThickness','bottom_thickness'],['bottomDrop','bottom_drop'],['bottomGrooveDepth','bottom_groove_depth'],['rearClearance','rear_clearance'],['frontClearance','front_clearance'],['frontThickness','front_thickness']].forEach(p=>$(p[0]).value=b[p[1]]);}
function saveDetails(){const b=bays[selected];b.shelf_levels=$('shelfLevels').value;b.shelf_front_cut=Math.max(0,parseFloat($('shelfFrontCut').value||0));b.drawer_pattern=$('drawerPattern').value;[['drawerHeight','drawer_height'],['drawerFrontCut','drawer_front_cut'],['runnerClearance','runner_clearance'],['chassisHeight','chassis_height'],['drawerThickness','drawer_thickness'],['bottomThickness','bottom_thickness'],['bottomDrop','bottom_drop'],['bottomGrooveDepth','bottom_groove_depth'],['rearClearance','rear_clearance'],['frontClearance','front_clearance'],['frontThickness','front_thickness']].forEach(p=>b[p[1]]=Math.max(0,parseFloat($(p[0]).value||0)));draw();}
function setPreset(key){bays[selected].preset=key;renderPresets();renderBays();draw();}
function renderBays(){$('bays').innerHTML=bays.map((b,i)=>`<div class="bay ${i===selected?'active':''}" onclick="selectBay(${i})"><div class="bay-num">${i+1}</div><div><label>عرض الفتحة سم</label><input type="number" min="1" step="0.1" value="${b.width}" oninput="changeBay(${i},'width',this.value)" onclick="event.stopPropagation()"></div><div><label>${b.preset.includes('drawer')?'عدد الأدراج':'عدد الأرفف'}</label><input type="number" min="0" step="1" value="${b.preset.includes('drawer')?b.drawers:b.shelves}" oninput="changeBay(${i},'${b.preset.includes('drawer')?'drawers':'shelves'}',this.value)" onclick="event.stopPropagation()"></div><button class="del" onclick="event.stopPropagation();deleteBay(${i})">×</button></div>`).join('');}
function selectBay(i){selected=i;renderPresets();renderBays();draw();}function changeBay(i,key,value){bays[i][key]=(key==='shelves'||key==='drawers')?Math.max(0,parseInt(value||0)):Math.max(0,parseFloat(value||0));selected=i;renderPresets();draw();}
function addBay(){bays.push(ensureBay({width:60,shelves:3,preset:'shelves',drawers:3,drawer_height:70}));selected=bays.length-1;renderPresets();renderBays();draw();}function deleteBay(i){if(bays.length===1){alert('يجب أن توجد فتحة واحدة على الأقل');return}bays.splice(i,1);selected=Math.min(selected,bays.length-1);renderPresets();renderBays();draw();}
function forceSlidingDrawerPatterns(){
 const on=$('doorSystem').value==='sliding';
 if(!on)return;
 const t=val('thickness'),columns=collectColumns(layoutTree,0,Math.max(1,cabinetWidth-2*t));
 const count=parseInt($('slidingLeafCount').value||2)===3?3:2;
 let first=parseInt($('slidingFirstColumn').value||INITIAL.sliding_first_column||0);
 first=Math.max(0,Math.min(Math.max(0,columns.length-count),isNaN(first)?0:first));
 const last=first+count-1;
 const forceNode=n=>{if(!n)return;if(n.dir&&n.children){n.children.forEach(forceNode);return}if(n.type==='drawers'&&['overlay_front','flush_carcass'].includes(n.drawer_pattern||'thick_side')){n.drawer_pattern='thick_side';n.drawer_front_cut=Number(n.drawer_front_cut||0)}};
 columns.forEach((c,i)=>{if(i>=first&&i<=last)forceNode(c.node)});
}
function updateSlidingDoorOptions(){const box=$('slidingDoorOptions'),extraBox=$('slidingExtraOptions'),on=$('doorSystem').value==='sliding';box.style.display=on?'':'none';extraBox.style.display=on?'':'none';const option=$('doorSystem').querySelector('option[value="sliding"]');if(option)option.textContent='ضلفة جرار';if(!on)return;const t=val('thickness'),columns=collectColumns(layoutTree,0,Math.max(1,cabinetWidth-2*t)),first=$('slidingFirstColumn'),last=$('slidingSecondColumn'),count=parseInt($('slidingLeafCount').value||2)===3?3:2;if(columns.length<count){first.innerHTML=`<option>لا يوجد ${count} أعمدة</option>`;last.innerHTML=`<option>لا يوجد ${count} أعمدة</option>`;$('slidingDoorSize').textContent=`أضف ${count} أعمدة على الأقل لتنفيذ الجرار`;return}let wantedFirst=first.options.length?parseInt(first.value):parseInt(INITIAL.sliding_first_column||0);wantedFirst=Math.max(0,Math.min(columns.length-count,isNaN(wantedFirst)?0:wantedFirst));const wantedLast=wantedFirst+count-1;first.innerHTML=columns.slice(0,columns.length-count+1).map((c,i)=>`<option value="${i}">العمود ${i+1}</option>`).join('');last.innerHTML=`<option value="${wantedLast}">العمود ${wantedLast+1}</option>`;first.value=String(wantedFirst);last.value=String(wantedLast);$('slidingFrontLeaf').disabled=count===3;const selected=columns.slice(wantedFirst,wantedLast+1),coverage=selected.reduce((sum,c)=>sum+c.w,0)+t*(count-1),widthExtra=Math.max(0,val('slidingWidthExtra')),leafWidth=coverage/count+widthExtra,clear=Math.max(0,val('slidingVerticalClearance')),fixed=$('fixedTopShelf').value==='yes'?(Math.max(1,val('fixedTopClearHeight'))+t):0,doorH=Math.max(0,val('height')-2*t-fixed-2*clear),style=$('slidingStyle').value==='glass'?'زجاج':'خشب',front=count===3?'الوسط أمامية، واليمين والشمال خلفية':($('slidingFrontLeaf').value==='left'?'الشمال أمامية':'اليمين أمامية');$('slidingDoorSize').textContent=`${count} ضلف ${style} — الأعمدة ${wantedFirst+1} إلى ${wantedLast+1} — ${front} — مقاس كل ضلفة: ${leafWidth.toFixed(1)} × ${doorH.toFixed(1)} سم`}
function slidingInputChanged(){let first=parseInt($('slidingFirstColumn').value||0),columns=collectColumns(layoutTree,0,Math.max(1,cabinetWidth-2*val('thickness'))),count=parseInt($('slidingLeafCount').value||2)===3?3:2;first=Math.max(0,Math.min(Math.max(0,columns.length-count),first));$('slidingSecondColumn').value=String(first+count-1);forceSlidingDrawerPatterns();updateSlidingDoorOptions();updateOpeningEditor();draw()}
function settings(){return{unit_name:$('unitName').value.trim(),naming_dictionary:namingDictionary,height:val('height'),depth:val('depth'),width:cabinetWidth,easy_template:easyTemplate,layout_tree:advancedMode?null:layoutTree,joinery_system:$('joinerySystem').value,butterfly_edge_offset:Math.max(.5,val('butterflyEdgeOffset')),butterfly_apply_drawers:$('butterflyApplyDrawers').value,butterfly_support_rules:butterflySupportRules.slice().sort((a,b)=>a.threshold-b.threshold).map(r=>({threshold:Math.max(1,Number(r.threshold)||1),count:Math.max(1,Math.min(3,parseInt(r.count||1)))})),elita_edge_offset:Math.max(.5,val('elitaEdgeOffset')),elita_support_rules:elitaSupportRules.slice().sort((a,b)=>a.threshold-b.threshold).map(r=>({threshold:Math.max(1,Number(r.threshold)||1),count:Math.max(1,Math.min(3,parseInt(r.count||1))) })),elita_screw_drill_diameter:Math.max(0.1,val('elitaScrewDrillDiameter')),elita_dowel_diameter:Math.max(0.1,val('elitaDowelDiameter')),elita_dowel_depth:Math.max(0.1,val('elitaDowelDepth')),elita_cam_diameter:Math.max(0.1,val('elitaCamDiameter')),elita_cam_depth:Math.max(0.1,val('elitaCamDepth')),elita_screw_after_thread:Math.max(0.1,val('elitaScrewAfterThread')),hinge_system:$('hingeSystem').value,accessory_catalogs:INITIAL.accessory_catalogs||{},thickness:val('thickness'),door_clearance:val('doorClearance'),door_system:$('doorSystem').value,door_type:INITIAL.door_type,door_material:$('doorMaterial').value,back_material:$('backMaterial').value,back_thickness:val('backThickness'),back_inset:val('backInset'),back_groove_depth:Math.max(0,val('backGrooveDepth')),back_joint_mode:$('backJointMode').value,shelf_front_cut:Math.max(0,val('globalShelfFrontCut')),cut_full_partitions:$('cutFullPartitions').value,fixed_top_shelf:$('fixedTopShelf').value,fixed_top_clear_height:Math.max(1,val('fixedTopClearHeight')),sloped_enabled:$('slopedEnabled').value,sloped_left_height:Math.max(20,val('slopedLeftHeight')),sloped_right_height:Math.max(20,val('slopedRightHeight')),base_type:$('baseType').value,leg_height:Math.max(0,val('legHeight')),wood_plinth_height:Math.max(1,val('woodPlinthHeight')),wood_plinth_supports:Math.max(0,parseInt($('woodPlinthSupports').value||0)),wood_plinth_rear_inset:Math.max(0,val('woodPlinthRearInset')),wood_plinth_front_inset:Math.max(0,val('woodPlinthFrontInset')),wood_plinth_joinery:$('woodPlinthJoinery').value,wood_plinth_joinery_offset:Math.max(.5,val('woodPlinthJoineryOffset')),wood_plinth_joinery_rules:woodPlinthJoineryRules.slice().sort((a,b)=>a.threshold-b.threshold).map(r=>({threshold:Math.max(1,Number(r.threshold)||1),count:Math.max(1,Math.min(3,parseInt(r.count||1)))})),top_cornice_type:$('topCorniceType').value,top_cornice_height:Math.max(1,val('topCorniceHeight')),top_cornice_joinery:$('topCorniceJoinery').value,top_cornice_joinery_offset:Math.max(.5,val('topCorniceJoineryOffset')),top_cornice_joinery_rules:topCorniceJoineryRules.slice().sort((a,b)=>a.threshold-b.threshold).map(r=>({threshold:Math.max(1,Number(r.threshold)||1),count:Math.max(1,Math.min(3,parseInt(r.count||1)))})),sliding_first_column:Math.max(0,parseInt($('slidingFirstColumn').value||0)),sliding_second_column:Math.max(1,parseInt($('slidingSecondColumn').value||1)),sliding_leaf_count:parseInt($('slidingLeafCount').value||2)===3?3:2,sliding_style:$('slidingStyle').value==='glass'?'glass':'wood',sliding_front_leaf:$('slidingFrontLeaf').value,sliding_track_gap:Math.max(0,val('slidingTrackGap')),sliding_front_setback:Math.max(0,val('slidingFrontSetback')),sliding_width_extra:Math.max(0,val('slidingWidthExtra')),sliding_vertical_clearance:Math.max(0,val('slidingVerticalClearance')),sliding_partition_cut:Math.max(0,val('slidingPartitionCut')),
hinge_cup_diameter:Math.max(0.5,val('hingeCupDiameter')),hinge_cup_depth:Math.max(0.1,val('hingeCupDepth')),hinge_cup_edge_center:Math.max(0.1,val('hingeCupEdgeCenter')),hinge_count:Math.max(1,Math.min(12,parseInt(INITIAL.hinge_count||4))),hinge_end_offset:Math.max(0.1,val('hingeEndOffset')),hinge_collision_offset:Math.max(0,val('hingeCollisionOffset')),
elita_coil_count:parseInt($('elitaCoilCount').value||1)===2?2:1,elita_coil_drill_diameter:Math.max(0.1,val('elitaCoilDrillDiameter')),elita_coil_length:Math.max(0.2,val('elitaCoilLength')),elita_coil_face_depth:Math.min(Math.max(0.1,val('elitaCoilFaceDepth')),Math.max(0.1,val('elitaCoilLength')-0.1)),elita_coil_center_distance:Math.max(0.1,val('elitaCoilCenterDistance')),
carcass_board_width:val('carcassBoardWidth'),carcass_board_length:val('carcassBoardLength'),door_board_width:val('doorBoardWidth'),door_board_length:val('doorBoardLength'),back_board_width:val('backBoardWidth'),back_board_length:val('backBoardLength'),edge_band_pattern:$('edgeBandPattern').value,assembly:$('assembly').value,top_type:$('topType').value==='full_top'?'full_top':'between_sides',side_extension:$('assembly').value==='full'?Math.max(0,val('sideExtension')):0,wall_relief:wallRelief,material:$('material').value,bays:bays.map(b=>Object.assign({},b,{width:Number(b.width),shelves:Number(b.shelves||0),drawers:Number(b.drawers||3)}))};}
function draw(){const s=settings();if($('cabinetWidthText'))$('cabinetWidthText').textContent=`عرض الدولاب الحالي: ${cabinetWidth.toFixed(1)} سم`;if(!advancedMode&&layoutTree){const W=s.width,slopeOn=s.sloped_enabled==='yes',woodBase=s.base_type==='wood_plinth',H=slopeOn?Math.max(s.sloped_left_height,s.sloped_right_height):s.height,scale=Math.min(520/W,380/H),w=W*scale,h=H*scale,x=(760-w)/2,y=72,fixed=s.fixed_top_shelf==='yes',reserved=fixed?Math.min(h*.8,(s.fixed_top_clear_height+s.thickness)*scale):0,treeY=y+reserved,treeH=Math.max(20,h-reserved),leftY=y+h-(slopeOn?s.sloped_left_height:H)*scale,rightY=y+h-(slopeOn?s.sloped_right_height:H)*scale,extension=Math.max(0,s.side_extension)*scale,sidePx=Math.max(3,s.thickness*scale),shellX=slopeOn?x:x-5,shellW=slopeOn?w:w+10;let out=renderColumnSelectors(x,36,w);if(slopeOn){const polygon=`${x},${y+h} ${x},${leftY} ${x+w},${rightY} ${x+w},${y+h}`;out+=`<defs><clipPath id="slopeClip"><polygon points="${polygon}"/></clipPath></defs><polygon class="wood" points="${polygon}"/>`}else out+=`<rect class="wood" x="${shellX}" y="${y-5}" width="${shellW}" height="${h+10}"/>`;if(fixed){const shelfY=treeY-s.thickness*scale;out+=`<rect class="inside" x="${x}" y="${y}" width="${w}" height="${reserved}"/><line class="shelf" x1="${x}" y1="${shelfY}" x2="${x+w}" y2="${shelfY}"/><text class="dim" x="${x+w/2}" y="${y+reserved/2}" text-anchor="middle">رف ثابت — ${s.fixed_top_clear_height.toFixed(1)} سم صافي</text>`}const treeSvg=renderTreeSvg(layoutTree,x,treeY,w,treeH,[]);out+=slopeOn?`<g clip-path="url(#slopeClip)">${treeSvg}</g>`:treeSvg;if(extension>0)out+=`<rect class="wood" x="${shellX}" y="${y+h}" width="${sidePx}" height="${extension}"/><rect class="wood" x="${shellX+shellW-sidePx}" y="${y+h}" width="${sidePx}" height="${extension}"/>`;
const baseH=woodBase?Math.max(5,s.wood_plinth_height*scale):0,baseY=y+h+(slopeOn?0:5),baseX=extension>0?shellX+sidePx:shellX,baseW=extension>0?shellW-sidePx*2:shellW;
if(woodBase){out+=`<rect class="drawer" x="${baseX}" y="${baseY}" width="${baseW}" height="${baseH}"/>`;for(let i=1;i<=s.wood_plinth_supports;i++){const sx=baseX+baseW*i/(s.wood_plinth_supports+1);out+=`<line class="shelf" x1="${sx}" y1="${baseY}" x2="${sx}" y2="${baseY+baseH}"/>`}}

const corniceOn=s.top_cornice_type&&s.top_cornice_type!=='none',corniceH=corniceOn?Math.max(4,s.top_cornice_height*scale):0;
if(corniceOn){
  if(slopeOn){
    // معاينة الكورنيشة الأمامية المائلة: نفس خط ميل القرصة، لكن ترتفع
    // فوقه بقيمة ارتفاع الكورنيشة المختارة.
    const dx=x+w-x,dy=rightY-leftY,len=Math.sqrt(dx*dx+dy*dy)||1;
    const nx=dy/len,ny=-dx/len;
    const offX=nx*corniceH,offY=ny*corniceH;
    const p1=`${x},${leftY}`,p2=`${x+w},${rightY}`;
    const p3=`${x+w+offX},${rightY+offY}`,p4=`${x+offX},${leftY+offY}`;
    out+=`<polygon class="drawer" points="${p1} ${p2} ${p3} ${p4}"/>`;

    // اليمين/الشمال في المعاينة يظهران كامتداد رأسي عند طرف الكورنيشة.
    // الهدف هنا توضيح الاختيار بصريًا في الواجهة، بينما الإنشاء الفعلي
    // يظل بمنطق الكورنيشة المائلة الموجود في Ruby.
    if(s.top_cornice_type==='front_left'||s.top_cornice_type==='front_both'){
      out+=`<line class="shelf" x1="${x}" y1="${leftY}" x2="${x+offX}" y2="${leftY+offY}"/>`;
    }
    if(s.top_cornice_type==='front_right'||s.top_cornice_type==='front_both'){
      out+=`<line class="shelf" x1="${x+w}" y1="${rightY}" x2="${x+w+offX}" y2="${rightY+offY}"/>`;
    }
  }else{
    out+=`<rect class="drawer" x="${shellX}" y="${y-5-corniceH}" width="${shellW}" height="${corniceH}"/>`;
  }
}
out+=`<text class="dim" x="380" y="${baseY+baseH+32}" text-anchor="middle">${easyTemplate?TEMPLATE_NAMES[Number(easyTemplate)-1]:'تقسيمة مخصصة'} — ${W.toFixed(1)} × ${H.toFixed(1)} سم${s.top_type==='full_top'?' — قرصة كاملة':''}${slopeOn?' — مائل':''}${woodBase?' — سوكلو خشب':''}${corniceOn?' — كورنيشة علوية':''}</text>`;$('canvas').innerHTML=out;$('previewTitle').textContent=slopeOn?'معاينة الدولاب المائل':'حدد العمود من الأعلى أو اضغط على فتحة داخله';return}const W=bays.reduce((a,b)=>a+Number(b.width||0),0)+s.thickness*(bays.length+1),H=s.height;if(W<=0||H<=0){$('canvas').innerHTML='';return}const pad=70,maxW=620,maxH=390,scale=Math.min(maxW/W,maxH/H),x0=(760-W*scale)/2,y0=45,w=W*scale,h=H*scale,t=Math.max(3,s.thickness*scale);let out=`<rect class="inside" x="${x0}" y="${y0}" width="${w}" height="${h}"/>`;
out+=`<rect class="wood" x="${x0}" y="${y0}" width="${w}" height="${t}"/><rect class="wood" x="${x0}" y="${y0+h-t}" width="${w}" height="${t}"/><rect class="wood" x="${x0}" y="${y0}" width="${t}" height="${h}"/><rect class="wood" x="${x0+w-t}" y="${y0}" width="${t}" height="${h}"/>`;let cursor=s.thickness;
bays.forEach((b,i)=>{const bx=x0+cursor*scale,bw=b.width*scale,top=y0+t,bottom=y0+h-t;out+=`<rect class="${i===selected?'selected':'inside'}" x="${bx}" y="${top}" width="${bw}" height="${h-2*t}" onclick="selectBay(${i})"/>`;const shelf=(ratio,x=bx,width=bw)=>{const sy=y0+h-H*ratio*scale;out+=`<line class="shelf" x1="${x}" y1="${sy}" x2="${x+width}" y2="${sy}"/>`;};const rod=(ratio,x=bx,width=bw)=>{const ry=y0+h-H*ratio*scale;out+=`<line class="rod" x1="${x+8}" y1="${ry}" x2="${x+width-8}" y2="${ry}"/>`;};
if(b.preset==='hanging'){shelf(.78);rod(.70);}else if(b.preset==='double_hang'){shelf(.50);rod(.42);rod(.88);}else if(b.preset==='drawers'||b.preset==='drawers_hang'){const dh=Math.min(Number(b.drawer_height||70),H*.55),dc=Math.max(1,Number(b.drawers||3));for(let k=0;k<dc;k++){const yy=bottom-dh*scale+(dh/dc*k)*scale;out+=`<rect class="drawer" x="${bx+2}" y="${yy+2}" width="${bw-4}" height="${dh/dc*scale-3}"/>`;}if(b.preset==='drawers_hang'){shelf((dh+s.thickness)/H);rod(.82);}else{for(let k=1;k<=b.shelves;k++)shelf((dh+(H-dh)*k/(b.shelves+1))/H);}}else if(b.preset==='split_mix'){const mid=bx+bw/2;out+=`<rect class="wood" x="${mid-t/2}" y="${top}" width="${t}" height="${bottom-top}"/>`;for(let k=1;k<=Math.max(3,b.shelves);k++)shelf(k/(Math.max(3,b.shelves)+1),bx,bw/2-t/2);rod(.78,mid+t/2,bw/2-t/2);}else{for(let k=1;k<=b.shelves;k++)shelf(k/(b.shelves+1));}
out+=`<text class="label" x="${bx+bw/2}" y="${y0+h/2}" text-anchor="middle">${esc(PRESETS[b.preset][0])}</text><text class="dim" x="${bx+bw/2}" y="${y0+h+22}" text-anchor="middle">${Number(b.width).toFixed(1)}</text>`;cursor+=b.width;if(i<bays.length-1){out+=`<rect class="wood" x="${x0+cursor*scale}" y="${y0}" width="${t}" height="${h}"/>`;cursor+=s.thickness;}});out+=`<text class="dim" x="380" y="${y0+h+48}" text-anchor="middle">العرض الكلي: ${W.toFixed(1)} سم</text><text class="dim" x="25" y="${y0+h/2}" transform="rotate(-90 25 ${y0+h/2})" text-anchor="middle">الارتفاع: ${H.toFixed(1)} سم</text>`;$('canvas').innerHTML=out;$('previewTitle').textContent=`معاينة الدولاب — ${W.toFixed(1)} × ${H.toFixed(1)} سم`;}
function renderReliefOverlayOnDressing(){const svg=$('canvas');if(!svg||svg.querySelector('#wallReliefOverlay')||wallRelief.enabled!=='yes')return;const rels=suggestedReliefs();if(!rels.length)return;const s=settings(),H=s.sloped_enabled==='yes'?Math.max(s.sloped_left_height,s.sloped_right_height):s.height,scale=Math.min(520/cabinetWidth,380/H),w=cabinetWidth*scale,h=H*scale,x=(760-w)/2,y=72;let marks=`<g id="wallReliefOverlay" pointer-events="none">`;rels.forEach((r,i)=>{const rx=x+r.x0*scale,rw=(r.x1-r.x0)*scale,label=r.mode==='bay_depth'?`تقديم ضهر الفتحة وتقليل عمق أرففها ${r.depth.toFixed(1)} سم`:`تجليدة عمود حائط — العمق الصافي ناقص البروز والتخانة`;marks+=`<rect x="${rx}" y="${y}" width="${rw}" height="${h}" fill="rgba(216,166,111,.16)" stroke="#ff9f43" stroke-width="2" stroke-dasharray="7 5"/><text x="${rx+rw/2}" y="${y+24}" fill="#ffb86b" font-size="11" font-weight="bold" text-anchor="middle">${label}</text>`});marks+='</g>';svg.insertAdjacentHTML('beforeend',marks)}
const wallReliefObserver=new MutationObserver(()=>renderReliefOverlayOnDressing());wallReliefObserver.observe($('canvas'),{childList:true});
function createDressing(){const s=settings();if(!s.unit_name){alert('اكتب اسم أو رقم الوحدة أولًا');$('unitName').focus();return}if(!s.height||!s.depth||!s.thickness||!s.carcass_board_width||!s.carcass_board_length||!s.door_board_width||!s.door_board_length||!s.back_board_width||!s.back_board_length||(!easyTemplate&&bays.some(b=>!b.width))){alert('راجع المقاسات المدخلة وضوابط الألواح');return}showCreationLoading();setTimeout(()=>sketchup.create_dressing(JSON.stringify(s)),40);}
layoutTree=INITIAL.layout_tree||presetTree(easyTemplate);$('joinerySystem').value=INITIAL.joinery_system||'screw';$('hingeSystem').value=INITIAL.hinge_system||'current';$('assembly').value=INITIAL.assembly;$('topType').value=INITIAL.top_type==='full_top'?'full_top':'between_sides';$('material').value=INITIAL.material;$('doorMaterial').value=INITIAL.door_material||'';$('backMaterial').value=INITIAL.back_material||'';$('doorSystem').value=INITIAL.door_system||'none';$('cutFullPartitions').value=INITIAL.cut_full_partitions||'no';$('fixedTopShelf').value=INITIAL.fixed_top_shelf||'no';$('fixedTopClearHeight').value=INITIAL.fixed_top_clear_height||40;
$('slidingLeafCount').value=String(INITIAL.sliding_leaf_count===3?3:2);$('slidingStyle').value=INITIAL.sliding_style==='glass'?'glass':'wood';$('slidingFrontLeaf').value=INITIAL.sliding_front_leaf||'left';$('slidingTrackGap').value=INITIAL.sliding_track_gap===undefined?1:INITIAL.sliding_track_gap;$('slidingFrontSetback').value=INITIAL.sliding_front_setback===undefined?0:INITIAL.sliding_front_setback;$('slidingWidthExtra').value=INITIAL.sliding_width_extra===undefined?0:INITIAL.sliding_width_extra;$('slidingVerticalClearance').value=INITIAL.sliding_vertical_clearance===undefined?3:INITIAL.sliding_vertical_clearance;$('slidingPartitionCut').value=INITIAL.sliding_partition_cut===undefined?5:INITIAL.sliding_partition_cut;
$('butterflyEdgeOffset').value=INITIAL.butterfly_edge_offset===undefined ? 5 : INITIAL.butterfly_edge_offset;
$('hingeCupDiameter').value=INITIAL.hinge_cup_diameter===undefined?3.5:INITIAL.hinge_cup_diameter;
$('hingeCupDepth').value=INITIAL.hinge_cup_depth===undefined?1.3:INITIAL.hinge_cup_depth;
$('hingeCupEdgeCenter').value=INITIAL.hinge_cup_edge_center===undefined?2.25:INITIAL.hinge_cup_edge_center;
$('hingeEndOffset').value=INITIAL.hinge_end_offset===undefined?10:INITIAL.hinge_end_offset;
$('hingeCollisionOffset').value=INITIAL.hinge_collision_offset===undefined?5:INITIAL.hinge_collision_offset;
$('butterflyApplyDrawers').value=INITIAL.butterfly_apply_drawers||'no';renderButterflySupportRules();renderElitaSupportRules();
$('elitaEdgeOffset').value=INITIAL.elita_edge_offset===undefined?5:INITIAL.elita_edge_offset;
$('elitaScrewDrillDiameter').value=INITIAL.elita_screw_drill_diameter===undefined?0.8:INITIAL.elita_screw_drill_diameter;
$('elitaDowelDiameter').value=INITIAL.elita_dowel_diameter===undefined?0.8:INITIAL.elita_dowel_diameter;
$('elitaDowelDepth').value=INITIAL.elita_dowel_depth===undefined?1.05:INITIAL.elita_dowel_depth;
$('elitaCamDiameter').value=INITIAL.elita_cam_diameter===undefined?1.5:INITIAL.elita_cam_diameter;
$('elitaCamDepth').value=INITIAL.elita_cam_depth===undefined?1.2:INITIAL.elita_cam_depth;
$('elitaScrewAfterThread').value=INITIAL.elita_screw_after_thread===undefined?3.2:INITIAL.elita_screw_after_thread;
$('elitaCoilCount').value=String(INITIAL.elita_coil_count===2?2:1);
$('elitaCoilDrillDiameter').value=INITIAL.elita_coil_drill_diameter===undefined?0.8:INITIAL.elita_coil_drill_diameter;
$('elitaCoilLength').value=INITIAL.elita_coil_length===undefined?4.0:INITIAL.elita_coil_length;
$('elitaCoilFaceDepth').value=INITIAL.elita_coil_face_depth===undefined?2.0:INITIAL.elita_coil_face_depth;
$('elitaCoilCenterDistance').value=INITIAL.elita_coil_center_distance===undefined?2.5:INITIAL.elita_coil_center_distance;
$('backGrooveDepth').value=INITIAL.back_groove_depth===undefined ? .6 : INITIAL.back_groove_depth;
$('backJointMode').value=INITIAL.back_joint_mode||'grooved_partition';
$('carcassWidth').value=cabinetWidth.toFixed(1);$('columnCount').value=collectColumns(layoutTree,0,Math.max(1,cabinetWidth-2*val('thickness'))).length;$('slopedEnabled').value=INITIAL.sloped_enabled||'no';$('slopedLeftHeight').value=INITIAL.sloped_left_height||INITIAL.height;$('slopedRightHeight').value=INITIAL.sloped_right_height||INITIAL.height;$('baseType').value=INITIAL.base_type||'legs';$('legHeight').value=INITIAL.leg_height===undefined?10:INITIAL.leg_height;$('woodPlinthHeight').value=INITIAL.wood_plinth_height||10;$('woodPlinthSupports').value=INITIAL.wood_plinth_supports===undefined?1:INITIAL.wood_plinth_supports;$('woodPlinthRearInset').value=INITIAL.wood_plinth_rear_inset||0;$('woodPlinthFrontInset').value=INITIAL.wood_plinth_front_inset===undefined?(INITIAL.thickness||1.8):INITIAL.wood_plinth_front_inset;$('woodPlinthJoinery').value=INITIAL.wood_plinth_joinery==='butterfly'?'butterfly':'screw';$('woodPlinthJoineryOffset').value=INITIAL.wood_plinth_joinery_offset||5;renderTrimRules('plinth');updateTrimJoineryOptions();$('topCorniceType').value=INITIAL.top_cornice_type||'none';$('topCorniceHeight').value=INITIAL.top_cornice_height||10;$('topCorniceJoinery').value=INITIAL.top_cornice_joinery==='butterfly'?'butterfly':'screw';$('topCorniceJoineryOffset').value=INITIAL.top_cornice_joinery_offset||5;renderTrimRules('cornice');$('sideExtension').value=INITIAL.assembly==='full'?(INITIAL.side_extension||0):0;syncSideExtension();
setBoardValues({cw:INITIAL.carcass_board_width||240,cl:INITIAL.carcass_board_length||280,dw:INITIAL.door_board_width||240,dl:INITIAL.door_board_length||280,bw:INITIAL.back_board_width||120,bl:INITIAL.back_board_length||240,edge:(INITIAL.edge_band_pattern==='all_around'||INITIAL.edge_band_pattern==='pattern_1')?'all_around':'visible_only'});
$('doorSystem').querySelector('option[value="sliding"]').textContent='ضلفة جرار';const slidingSystemHandler=e=>{e.stopImmediatePropagation();forceSlidingDrawerPatterns();updateColumnSummary();updateSlopeSummary();updateBaseSummary();updateSlidingDoorOptions();updateOpeningEditor();draw()};$('doorSystem').addEventListener('input',slidingSystemHandler,true);$('doorSystem').addEventListener('change',slidingSystemHandler,true);['slidingLeafCount','slidingStyle','slidingFirstColumn','slidingFrontLeaf','slidingTrackGap','slidingFrontSetback','slidingWidthExtra','slidingVerticalClearance','slidingPartitionCut'].forEach(id=>$(id).addEventListener('input',slidingInputChanged));updateSlidingDoorOptions();
['height','depth','thickness','doorClearance','backThickness','backInset','backGrooveDepth','globalShelfFrontCut','fixedTopClearHeight','assembly','topType','sideExtension','material','doorMaterial','backMaterial','doorSystem','slopedLeftHeight','slopedRightHeight','legHeight','woodPlinthHeight','woodPlinthSupports','woodPlinthRearInset','woodPlinthFrontInset','topCorniceHeight'].forEach(id=>$(id).addEventListener('input',()=>{if(id==='assembly')syncSideExtension();if(id==='topType')updateTopTypeNote();updateColumnSummary();updateSlopeSummary();updateBaseSummary();updateOpeningEditor();draw()}));$('assembly').addEventListener('change',()=>{syncSideExtension();updateBaseSummary();draw()});$('topType').addEventListener('change',()=>{updateTopTypeNote();draw()});$('backJointMode').addEventListener('change',()=>{updateBackJointNote();draw()});$('slopedEnabled').addEventListener('change',()=>{updateSlopeSummary();draw()});$('baseType').addEventListener('change',()=>{updateBaseSummary();draw()});$('topCorniceType').addEventListener('change',()=>{updateTopCorniceSummary();draw()});$('carcassWidth').addEventListener('input',()=>{cabinetWidth=Math.max(20,val('carcassWidth'));updateColumnSummary();updateSlopeSummary();updateBaseSummary();updateOpeningEditor();draw()});
let columnCountTimer=null;
$('columnCount').addEventListener('input',()=>{clearTimeout(columnCountTimer);columnCountTimer=setTimeout(()=>{if($('columnCount').value!=='')applyColumnCount()},250)});
['cutFullPartitions','fixedTopShelf'].forEach(id=>$(id).addEventListener('change',()=>{updateOpeningEditor();draw()}));['shelfLevels','shelfFrontCut','drawerPattern','drawerHeight','drawerFrontCut','runnerClearance','chassisHeight','drawerThickness','bottomThickness','bottomDrop','bottomGrooveDepth','rearClearance','frontClearance','frontThickness'].forEach(id=>$(id).addEventListener('input',saveDetails));$('leafType').addEventListener('change',saveLeaf);$('leafCount').addEventListener('input',saveLeaf);$('leafRatio').addEventListener('input',saveRatio);$('selectedOpeningWidth').addEventListener('change',()=>resizeSelected('w'));$('selectedOpeningHeight').addEventListener('change',()=>resizeSelected('h'));DRAWER_NODE_FIELDS.forEach(f=>$(f[0]).addEventListener('change',saveLeaf));$('nodeDrawerPattern').addEventListener('change',saveLeaf);
$('innerDrawerJoinery').addEventListener('change',saveInnerDrawerJoinery);
INNER_ELITA_FIELDS.forEach(f=>$(f[0]).addEventListener('change',saveInnerDrawerJoinery));
$('innerElitaCoilCount').addEventListener('change',saveInnerDrawerJoinery);document.addEventListener('contextmenu',e=>e.preventDefault());let savedOptionsTab='structure';try{savedOptionsTab=localStorage.getItem('mhdDressingOptionsTab')||'structure'}catch(e){}switchOptionsTab(savedOptionsTab);updateColumnSummary();updateSlopeSummary();updateBaseSummary();updateTopCorniceSummary();updateBackJointNote();
['joinerySystem','butterflyEdgeOffset','butterflyApplyDrawers','elitaEdgeOffset','elitaScrewDrillDiameter','elitaDowelDiameter','elitaDowelDepth','elitaCamDiameter','elitaCamDepth','elitaScrewAfterThread','elitaCoilCount','elitaCoilDrillDiameter','elitaCoilLength','elitaCoilFaceDepth','elitaCoilCenterDistance'].map($).filter(Boolean).forEach(field=>field.addEventListener('input',()=>{updateJoineryOptions();draw()}));
['hingeCupDiameter','hingeCupDepth','hingeCupEdgeCenter','hingeEndOffset','hingeCollisionOffset'].map($).filter(Boolean).forEach(field=>field.addEventListener('input',draw));
$('drawerRunnerType').addEventListener('change',saveSelectedAccessory);
$('accessoryRunnerClearance').addEventListener('change',saveSelectedAccessory);
updateJoineryOptions();updateTopTypeNote();updateAccessoryEditor();renderTemplates();renderPresets();renderBays();updateOpeningEditor();updateWallReliefStatus();draw();
</script></body></html>
      HTML
    end

    def show_dialog(preferred_unit = nil)
      if @dialog
        @dialog.bring_to_front rescue nil
        return true
      end
      restore_motion_links(Sketchup.active_model)
      @current_wardrobe = selected_wardrobe(preferred_unit)
      unless @current_wardrobe
        UI.messagebox('هذه الأداة مخصصة لوحدات الدريسنج المستقيم الموقعة فقط. حدد وحدة مستقيم صحيحة وافتح الدريسنج من المكتبة.')
        return false
      end
      sign_straight_wardrobe!(@current_wardrobe)
      @current_wardrobe.make_unique
      # make_unique ينشئ Definition جديدًا؛ نعيد تثبيت التوقيع على النسخة الجديدة.
      sign_straight_wardrobe!(@current_wardrobe)
      # make_unique ينسخ الـAttributes لكن ينشئ Entities جديدة،
      # لذلك نعيد ربط الـObservers بالنسخة الجديدة فورًا.
      restore_motion_links(Sketchup.active_model)
      data = wardrobe_data(@current_wardrobe)
      @dialog = UI::HtmlDialog.new(dialog_title: TITLE, preferences_key: PREF_KEY, scrollable: false, resizable: true, width: 1100, height: 760, style: UI::HtmlDialog::STYLE_DIALOG)
      @dialog.set_html(html(data))
      @dialog.add_action_callback('cancel') { @dialog.close if @dialog }
      @dialog.add_action_callback('open_doors') { open_doors }
      @dialog.add_action_callback('close_doors') { close_doors }
      @dialog.add_action_callback('create_dressing') do |_context, payload|
        begin
          data = JSON.parse(payload)
          root = create_dressing(data)
          update_creation_progress(100, 'تم إنشاء الدولاب بنجاح')
          @dialog.close if @dialog
        rescue => error
          if error.is_a?(BoardLimitError) && @dialog
            @dialog.execute_script("hideCreationLoading();showBoardErrors(#{JSON.generate(error.violations)})")
          elsif @dialog
            @dialog.execute_script("hideCreationLoading();showToolError('تعذر إنشاء الدولاب', #{JSON.generate(error.message.to_s)})")
          else
            UI.messagebox("تعذر إنشاء الدولاب:\n#{error.message}")
          end
        end
      end
      @dialog.set_on_closed { close_doors; @dialog = nil; @current_wardrobe = nil }
      @dialog.show
      true
    end

    # مداخل واضحة لللانشر؛ كلها تحترم توقيع نوع الوحدة.
    def open_for_selection(unit = nil)
      show_dialog(unit)
    end

    def open_for_component(unit = nil)
      show_dialog(unit)
    end

    def open_for_unit(unit = nil)
      show_dialog(unit)
    end

    def door_entities
      return [] unless @current_wardrobe && @current_wardrobe.valid?
      @current_wardrobe.definition.entities.grep(Sketchup::ComponentInstance).select do |item|
        generated = item.get_attribute('MHD_DRESSING', 'GENERATED_COLUMN_DOOR')
        direction = item.get_attribute('MHD_DRESSING', 'HINGE_DIRECTION', '').to_s
        legacy_name = [item.name, item.definition.name,
                       item.get_attribute('dynamic_attributes', '_name'),
                       item.definition.get_attribute('dynamic_attributes', '_name')].join(' ')
        (generated || !direction.empty? || legacy_name.include?('ضلف')) && !item.hidden?
      end
    end

    def open_doors
      @door_transforms ||= {}
      door_entities.each do |door|
        next if @door_transforms.key?(door.persistent_id)
        @door_transforms[door.persistent_id] = door.transformation
        direction = door.get_attribute('MHD_DRESSING', 'HINGE_DIRECTION', '').to_s
        right = direction == 'right' || (direction.empty? && [door.name, door.definition.name].join(' ').include?('يمين'))
        hinge_x = right ? @current_wardrobe.definition.bounds.max.x : @current_wardrobe.definition.bounds.min.x
        pivot = Geom::Point3d.new(hinge_x, door.bounds.min.y, door.bounds.min.z)
        angle = right ? -95.degrees : 95.degrees
        door.transform!(Geom::Transformation.rotation(pivot, Z_AXIS, angle))
      end
      Sketchup.active_model.active_view.invalidate
    end

    def close_doors
      return unless @door_transforms
      door_entities.each do |door|
        original = @door_transforms[door.persistent_id]
        door.transformation = original if original
      end
      @door_transforms = nil
      Sketchup.active_model.active_view.invalidate
    rescue
      @door_transforms = nil
    end


    # ============================================================
    # MHD STRAIGHT PERFORMANCE PROFILER
    # تشخيص فقط — لا يغيّر أي هندسة أو نجارة أو تخريم.
    # يطبع زمن الإنشاء الكلي وأهم مراحل المستقيم في Ruby Console.
    # ============================================================
    STRAIGHT_PERF_LABEL = '10.53.33 STRAIGHT DETACHED PERF'.freeze unless const_defined?(:STRAIGHT_PERF_LABEL)

    def perf_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    rescue
      Time.now.to_f
    end

    def perf_reset!
      @perf_stats = {}
      @perf_active = true
      @perf_create_started_at = perf_now
      root = @current_wardrobe
      if root && root.valid?
        tr = root.transformation
        origin = tr.origin
        puts
        puts "================ MHD STRAIGHT PERF #{STRAIGHT_PERF_LABEL} ================"
        puts format("[MHD ROOT] origin=(%.3f, %.3f, %.3f) in", origin.x.to_f, origin.y.to_f, origin.z.to_f)
        puts format("[MHD ROOT] xaxis_len=%.6f yaxis_len=%.6f zaxis_len=%.6f",
                    tr.xaxis.length.to_f, tr.yaxis.length.to_f, tr.zaxis.length.to_f)
      else
        puts
        puts "================ MHD STRAIGHT PERF #{STRAIGHT_PERF_LABEL} ================"
      end
    rescue
      @perf_stats = {}
      @perf_active = true
      @perf_create_started_at = Time.now.to_f
    end

    def perf_measure(label)
      return yield unless @perf_active
      started = perf_now
      begin
        yield
      ensure
        elapsed = perf_now - started
        @perf_stats ||= {}
        row = (@perf_stats[label.to_s] ||= {'total'=>0.0, 'calls'=>0, 'max'=>0.0})
        row['total'] += elapsed
        row['calls'] += 1
        row['max'] = elapsed if elapsed > row['max']
      end
    end

    def perf_report!
      total = perf_now - @perf_create_started_at.to_f
      stats = (@perf_stats || {}).sort_by { |_name, row| -row['total'].to_f }
      puts format("[MHD PERF] %-32s %10.3f s", 'TOTAL_CREATE', total)
      stats.each do |name, row|
        puts format("[MHD PERF] %-32s %10.3f s   calls=%-4d max=%8.3f s",
                    name, row['total'].to_f, row['calls'].to_i, row['max'].to_f)
      end
      puts "============================================================"
      puts
    rescue => error
      puts "[MHD PERF] report error: #{error.message}"
    ensure
      @perf_active = false
    end

    module StraightPerfWrapper
      def create_dressing(data)
        perf_reset!
        begin
          super
        ensure
          perf_report!
        end
      end

      PERF_METHODS = {
        :redraw_dc                         => 'redraw_dc',
        :build_straight_grooved_shell      => 'straight_shell',
        :build_sloped_shell                => 'sloped_shell',
        :build_layout_tree                 => 'layout_tree',
        :build_easy_template               => 'easy_template',
        :build_column_backs                => 'column_backs',
        :build_column_doors                => 'column_doors',
        :build_sliding_doors               => 'sliding_doors',
        :build_hinge_cup_drilling          => 'hinge_drilling',
        :build_horizontal_back_grooves     => 'horizontal_back_grooves',
        :build_wall_column_claddings       => 'wall_claddings',
        :build_top_cornice                 => 'top_cornice',
        :build_wood_plinth                 => 'wood_plinth',
        :release_names_held_by_hidden_definitions => 'release_hidden_names',
        :qualify_component_tree            => 'qualify_component_tree',
        :build_butterfly_joinery           => 'butterfly_joinery',
        :build_elita_joinery               => 'elita_joinery',
        :build_inner_drawer_elita_joinery  => 'inner_drawer_elita',
        :build_cornice_plinth_joinery      => 'cornice_plinth_joinery',
        :sanitize_final_part_names         => 'sanitize_part_names',
        :add_box                           => 'geom.add_box',
        :add_box_without_wall_relief       => 'geom.add_box_no_relief',
        :add_vertical_panel                => 'geom.add_vertical_panel',
        :add_horizontal_grooved_panel      => 'geom.add_horizontal_grooved_panel',
        :add_horizontal_relief_grooved_panel => 'geom.add_relief_grooved_panel',
        :apply_edge_banding                => 'geom.edge_banding',
        :orient_definition_textures        => 'geom.orient_textures',
        :orient_definition_textures_rotated_90 => 'geom.orient_textures_90',
        :orient_part_textures              => 'geom.orient_part_textures',
        :add_drawer_stack                  => 'drawer_stack',
        :add_drawer_front                  => 'drawer_front',
        :add_drawer_slide_pair             => 'drawer_slide_pair',
        :template_shelf                    => 'template_shelf',
        :template_shelves                  => 'template_shelves',
        :template_partition                => 'template_partition',
        :copy_dynamic_door                 => 'dynamic_door',
        :copy_dynamic_glass_door           => 'dynamic_glass_door',
        :create_sloped_dynamic_door        => 'sloped_dynamic_door'
      }.freeze

      PERF_METHODS.each do |method_name, label|
        define_method(method_name) do |*args, &block|
          perf_measure(label) { super(*args, &block) }
        end
      end
    end

    class << self
      prepend StraightPerfWrapper
    end

    unless file_loaded?(__FILE__)
      # لا نضيف أي عنصر إلى قائمة Extensions. التشغيل يتم من لانشر المكتبة فقط.
      @motion_app_observer ||= DressingMotionAppObserver.new
      Sketchup.add_observer(@motion_app_observer)

      # لو الإضافة اتحملت والموديل مفتوح بالفعل، رجع الحركة فورًا.
      UI.start_timer(0.8, false) do
        restore_motion_links(Sketchup.active_model)
      end

      file_loaded(__FILE__)
    end
  end
end