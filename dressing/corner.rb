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

unless Sketchup::Entities.method_defined?(:empty?)
  class Sketchup::Entities
    def empty?
      length == 0
    end
  end
end

module DolaSmartLibraryPlugin
  module DressingCornerDesigner
    extend self

    if instance_variable_defined?(:@drawer_slide_monitor_timer) && @drawer_slide_monitor_timer
      UI.stop_timer(@drawer_slide_monitor_timer) rescue nil
      @drawer_slide_monitor_timer = nil
    end

    if instance_variable_defined?(:@hinge_motion_monitor_timer) && @hinge_motion_monitor_timer
      UI.stop_timer(@hinge_motion_monitor_timer) rescue nil
      @hinge_motion_monitor_timer = nil
    end

    TITLE = 'مكتبة محمد عادل - تصميم دريسنج زاوية'.freeze
    PREF_KEY = 'DOLA_DRESSING_CORNER_DESIGNER_V2'.freeze
    VERSION = '10.56.54'.freeze
    LOGO_URL = ''.freeze
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
    INTERIOR_MARK = 'DOLA_DRESSING_INTERIORS'.freeze
    DRESSING_SYSTEM = 'DOLA_DRESSING'.freeze
    CORNER_UNIT_TYPE = 'corner'.freeze
    CORNER_UNIT_SIGNATURE = 'DOLA_DRESSING_CORNER_V1'.freeze
    DRESSING_SKP_BASE_URL = 'https://raw.githubusercontent.com/dolaga10-lgtm/dola-library/refs/heads/main/dressing'.freeze
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
          DolaSmartLibraryPlugin::DressingCornerDesigner.sync_hinge_accessories(entity) if entity && entity.valid?
        end
      rescue
        nil
      end
    end

    class DrawerSlideMotionObserver < Sketchup::EntityObserver
      def onChangeEntity(entity)
        UI.start_timer(0, false) do
          DolaSmartLibraryPlugin::DressingCornerDesigner.sync_drawer_slide(entity) if entity && entity.valid?
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

    DRESSING_UNITS_CACHE_ROOT_DIR = 'DOLA_REMOTE_CACHE_V1'.freeze
    DRESSING_CACHE_SECRET_SALT = 'DOLA_REMOTE_CACHE_V1'.freeze
    DRESSING_CACHE_HMAC_SALT   = 'DOLA_REMOTE_CACHE_HMAC_V1'.freeze
    DRESSING_ASSET_ALLOWED_HOSTS = ['raw.githubusercontent.com', 'github.com'].freeze

    def dressing_units_cache_root_dir
      dir = File.join(Dir.tmpdir, DRESSING_UNITS_CACHE_ROOT_DIR)
      FileUtils.mkdir_p(dir) unless File.directory?(dir)
      dir
    rescue
      File.join(Dir.tmpdir, DRESSING_UNITS_CACHE_ROOT_DIR)
    end

    def dressing_cache_device_id
      id = Sketchup.read_default('DolaSmartLibrary', 'device_id').to_s.strip
      if id.empty?
        id = SecureRandom.uuid
        Sketchup.write_default('DolaSmartLibrary', 'device_id', id)
      end
      id
    rescue
      ''
    end

    def dressing_cache_binding_seed
      [
        'DOLA',
        dressing_cache_device_id.to_s,
        DRESSING_CACHE_SECRET_SALT
      ].join('|')
    rescue
      "DOLA|#{DRESSING_CACHE_SECRET_SALT}"
    end

    def dressing_cache_crypto_key
      Digest::SHA256.digest(dressing_cache_binding_seed)
    rescue
      Digest::SHA256.digest("DOLA|#{DRESSING_CACHE_SECRET_SALT}")
    end

    def dressing_cache_hmac_key
      Digest::SHA256.digest("#{dressing_cache_binding_seed}|#{DRESSING_CACHE_HMAC_SALT}")
    rescue
      Digest::SHA256.digest("DOLA|#{DRESSING_CACHE_HMAC_SALT}")
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
        'v'=>version, 'iv'=>iv_b64, 'data'=>data_b64,
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
      iv = Base64.decode64(iv_b64)
      encrypted = Base64.decode64(data_b64)
      cipher = OpenSSL::Cipher.new('AES-256-CBC')
      cipher.decrypt
      cipher.key = dressing_cache_crypto_key
      cipher.iv = iv
      (cipher.update(encrypted) + cipher.final).b
    end

    def normalize_dressing_asset_url(url)
      uri = URI.parse(url.to_s.strip)
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
      nil
    end

    def read_dressing_asset_cache(url)
      path = dressing_asset_cache_file_for_url(url)
      return nil unless File.file?(path) && File.size(path) > 0
      decrypt_dressing_cache_bytes(File.binread(path))
    rescue
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
        response = http.get(uri.request_uri, {'User-Agent'=>'DolaLibrary-Dressing'})
        if response.is_a?(Net::HTTPRedirection)
          location = response['location'].to_s
          next_uri = URI.join(uri.to_s, location)
          uri = normalize_dressing_asset_url(next_uri.to_s)
          next
        end
        break
      end
      raise "تعذر تحميل ملف الإكسسوار: #{filename}" unless response.is_a?(Net::HTTPSuccess)
      response.body.to_s.b
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
      tempfile = Tempfile.new(['dola_dressing_asset', '.skp'])
      tempfile.binmode
      tempfile.write(raw)
      tempfile.flush
      tempfile.close
      model.definitions.load(tempfile.path)
    ensure
      tempfile.close! if tempfile rescue nil
    end

    def download_dressing_asset(url, filename, bundled_path = nil)
      raw = dressing_asset_bytes(url, filename, bundled_path)
      tempfile = Tempfile.new(['dola_dressing_compat', '.skp'])
      tempfile.binmode
      tempfile.write(raw)
      tempfile.flush
      tempfile.close
      path = tempfile.path
      @dressing_compat_tempfiles ||= []
      @dressing_compat_tempfiles << tempfile
      UI.start_timer(3.0, false) do
        tempfile.close! rescue nil
      end
      path
    end

    def butterfly_definition(model)
      cached = @butterfly_definitions && @butterfly_definitions[model.object_id]
      return cached if cached && cached.valid?
      bundled = File.join(File.dirname(__FILE__), 'Corner Brace Butterfly.skp')
      load_dressing_asset_definition(model, BUTTERFLY_SKP_URL, 'Corner Brace Butterfly.skp', bundled)
    end

    def shelf_support_definition(model)
      cached = @shelf_support_definitions && @shelf_support_definitions[model.object_id]
      return cached if cached && cached.valid?
      bundled = File.join(File.dirname(__FILE__), 'Shelf support.skp')
      load_dressing_asset_definition(model, SHELF_SUPPORT_SKP_URL, 'Shelf support.skp', bundled)
    end

    def elita_definition(model)
      cached = @elita_definitions && @elita_definitions[model.object_id]
      return cached if cached && cached.valid?
      bundled = File.join(File.dirname(__FILE__), 'minifix.skp')
      load_dressing_asset_definition(model, ELITA_SKP_URL, 'minifix.skp', bundled)
    end

    def cloth_holder_definition(model)
      cached = @cloth_holder_definitions && @cloth_holder_definitions[model.object_id]
      return cached if cached && cached.valid?
      definition = load_dressing_asset_definition(model, CLOTH_HOLDER_SKP_URL, 'cloth holder.skp', File.join(File.dirname(__FILE__), 'cloth holder.skp'))
      claim_clean_definition_name(definition, 'إكسسوار ماسورة شماعة')
      set_part_badges(definition, ['HARDWARE','ACCESSORY','CLOTH_HOLDER'])
      definition
    end

    def push_up_lift_definition(model)
      cached = @push_up_lift_definitions && @push_up_lift_definitions[model.object_id]
      return cached if cached && cached.valid?
      source = load_dressing_asset_definition(model, PUSH_UP_LIFT_SKP_URL, 'push up lift.skp', File.join(File.dirname(__FILE__), 'push up lift.skp'))
      baked = model.definitions['__DOLA_PUSH_UP_LIFT_BAKED_V1'] || model.definitions.add('__DOLA_PUSH_UP_LIFT_BAKED_V1')
      if baked.entities.length == 0
        placed = baked.entities.add_instance(source, Geom::Transformation.new)
        placed.explode
      end
      claim_clean_definition_name(baked, 'باكم ضلفة قلاب')
      set_part_badges(baked, ['HARDWARE','ACCESSORY','PUSH_UP_LIFT'])
      baked
    end

    def drawer_slide_right_definition(model)
      cached = @drawer_slide_right_definitions && @drawer_slide_right_definitions[model.object_id]
      return cached if cached && cached.valid?
      load_dressing_asset_definition(model, DRAWER_SLIDE_RIGHT_SKP_URL, 'Drawer slides right.skp', File.join(File.dirname(__FILE__), 'Drawer slides right.skp'))
    end

    def drawer_slide_left_definition(model)
      cached = @drawer_slide_left_definitions && @drawer_slide_left_definitions[model.object_id]
      return cached if cached && cached.valid?
      definition = load_dressing_asset_definition(model, DRAWER_SLIDE_LEFT_SKP_URL, 'Drawer slides lift.skp', File.join(File.dirname(__FILE__), 'Drawer slides lift.skp'))
      claim_clean_definition_name(definition, 'مجرى درج جانبي شمال')
      set_part_badges(definition, ['HARDWARE','ACCESSORY','DRAWER_SLIDE_LEFT'])
      definition
    end

    def hinge_accessory_definition(model, direction, overlay)
      key = [direction.to_s, overlay.to_s]
      filename = HINGE_SKP_FILES[key] || 'LIFT HING HAVE.skp'
      bundled = File.join(File.dirname(__FILE__), filename)
      url = "#{DRESSING_SKP_BASE_URL}/#{filename.gsub(' ', '%20')}"
      definition = load_dressing_asset_definition(model, url, filename, bundled)
      [definition, false]
    end

    def hinge_180_accessory_definition(model, direction)
      side = direction.to_s == 'right' ? 'right' : 'left'
      filename = HINGE_180_SKP_FILES[side] || 'LIFT HING 180.skp'
      bundled = File.join(File.dirname(__FILE__), filename)
      url = "#{DRESSING_SKP_BASE_URL}/#{filename.gsub(' ', '%20')}"
      definition = load_dressing_asset_definition(model, url, filename, bundled)
      claim_clean_definition_name(definition, side == 'right' ? 'مفصلة عقرب 180 يمين' : 'مفصلة عقرب 180 شمال')
      set_part_badges(definition, ['HARDWARE','ACCESSORY','HINGE'])
      definition
    end

    def corner_hinge_180_accessory_definition(model, direction)
      side = direction.to_s == 'right' ? 'right' : 'left'
      filename = CORNER_HINGE_180_SKP_FILES[side] || 'LIFT HING 180 co.skp'
      bundled = File.join(File.dirname(__FILE__), filename)
      url = "#{DRESSING_SKP_BASE_URL}/#{filename.gsub(' ', '%20')}"
      definition = load_dressing_asset_definition(model, url, filename, bundled)
      claim_clean_definition_name(definition, side == 'right' ? 'مفصلة عقرب 180 ركنة يمين' : 'مفصلة عقرب 180 ركنة شمال')
      set_part_badges(definition, ['HARDWARE','ACCESSORY','HINGE'])
      definition
    end

    def hinge_knee_accessory_definition(model, direction)
      side = direction.to_s == 'right' ? 'right' : 'left'
      filename = HINGE_KNEE_SKP_FILES[side] || 'LIFT HING total.skp'
      bundled = File.join(File.dirname(__FILE__), filename)
      url = "#{DRESSING_SKP_BASE_URL}/#{filename.gsub(' ', '%20')}"
      definition = load_dressing_asset_definition(model, url, filename, bundled)
      claim_clean_definition_name(definition, side == 'right' ? 'مفصلة ركبة يمين' : 'مفصلة ركبة شمال')
      set_part_badges(definition, ['HARDWARE','ACCESSORY','HINGE'])
      definition
    end

    def parse_dc_list_options(raw)
      return [] if raw.to_s.strip.empty? || raw.to_s.strip == '&'
      raw.to_s.split('&').reject { |part| part.strip.empty? }.map do |part|
        decoded = CGI.unescape(part.to_s) rescue part.to_s
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
      options = parse_dc_list_options(raw)
      options.empty? ? fallback : options
    end

    def dc_list_current_value(item, key, fallback)
      dc_value(item, key, fallback).to_s
    end

    def apply_dc_list_value(item, key, value)
      text = value.to_s.strip
      item.set_attribute('dynamic_attributes', key, text)
    end

    def dc_effective_value(item, key, fallback)
      dc_value(item, key, fallback).to_s
    end

    def inches_to_cm(value)
      (value.to_f * 2.54).round(2)
    end

    def detected_corner_door_style(root)
      return nil unless root && root.valid?
      'wood'
    end

    def wardrobe_data(item)
      stored = item.get_attribute('MHD_DRESSING', 'DATA_JSON').to_s
      unless stored.empty?
        saved = JSON.parse(stored)
        saved['unit_name'] = 'دولاب دريسنج زاوية (مكتبة محمد عادل)'
        return saved
      end
      width = inches_to_cm(dc_value(item, 'a1', item.bounds.width))
      height = inches_to_cm(dc_value(item, 'a3', item.bounds.height))
      depth = inches_to_cm(dc_value(item, 'a2', item.bounds.depth))
      thickness = inches_to_cm(dc_value(item, 'base_unit_1_d', 1.8 / 2.54))
      clear = [(width - thickness * 3) / 2.0, 10].max.round(1)
      {
        'unit_name' => 'دولاب دريسنج زاوية (مكتبة محمد عادل)',
        'height' => height, 'depth' => depth, 'width' => width, 'thickness' => thickness,
        'back_thickness' => 0.6,
        'back_inset' => 1.8,
        'back_groove_depth' => 0.6,
        'back_joint_mode' => 'back_side',
        'corner_side_thickness' => thickness,
        'shelf_front_cut' => 0.0,
        'cut_full_partitions' => 'no',
        'fixed_top_shelf' => 'no',
        'fixed_top_clear_height' => 40.0,
        'sloped_enabled' => 'no',
        'sloped_left_height' => height,
        'sloped_right_height' => height,
        'base_type' => 'legs',
        'wood_plinth_height' => 10.0,
        'assembly' => 'on_base',
        'joinery_system' => 'screw',
        'material' => 'كونتر ابيض',
        'door_material' => 'HPL',
        'back_material' => 'ضهر ابيض',
        'bays' => [
          {'width'=>clear,'shelves'=>3,'preset'=>'shelves','drawers'=>3,'drawer_height'=>70},
          {'width'=>clear,'shelves'=>3,'preset'=>'hanging','drawers'=>3,'drawer_height'=>65}
        ]
      }
    end

    def set_dc_cm(item, key, cm_value)
      item.set_attribute('dynamic_attributes', key, (cm_value.to_f / 2.54).to_s)
    end

    def redraw_dc(item)
      klass = dc_engine
      klass.redraw_with_undo(item) if klass
    rescue
      nil
    end

    def redraw_dc_live(item)
      klass = dc_engine
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
      model.materials.add(name)
    end

    def unique_name(model, wanted)
      return wanted unless model.definitions[wanted]
      index = 2
      index += 1 while model.definitions["#{wanted} (#{index})"]
      "#{wanted} (#{index})"
    end

    def claim_clean_definition_name(definition, wanted)
      definition.name = wanted
      wanted
    end

    def check_board_limit(name, width, depth, height, material, badges)
      true
    end

    def raise_board_violations!
      true
    end

    def clean_part_name(name)
      name.to_s.strip.empty? ? 'قطعة دريسنج' : name.to_s.strip
    end

    def active_unit_name
      'مكتبة محمد عادل'
    end

    def qualified_part_name(name)
      "#{clean_part_name(name)} (مكتبة محمد عادل)"
    end

    def naming_term(key, fallback)
      fallback
    end

    def column_number_for_part(x, width = 0)
      1
    end

    def human_part_name(name, x, width = 0)
      clean_part_name(name)
    end

    def localized_badges(badges)
      Array(badges).map { |badge| BADGE_ARABIC[badge.to_s] || badge.to_s }.uniq
    end

    def set_part_badges(definition, badges)
      definition.set_attribute('MHD_DRESSING', 'INTERNAL_BADGES', Array(badges).map(&:to_s))
      definition.set_attribute('ladb_opencutlist', 'tags', localized_badges(badges))
    end

    def apply_edge_banding(instance, model, name, source_material, badges, width, depth, height)
      true
    end

    def orient_part_textures(instance, name, badges, width, depth, height)
      true
    end

    def finish_generated_part(instance, model, name, material, badges = [], preserve_face_materials = false)
      name = qualified_part_name(name)
      instance.definition.name = unique_name(model, name)
      instance.name = ''
      instance.material = material
      set_part_badges(instance.definition, badges)
      instance
    end

    def add_box(parent, model, name, x, y, z, width, depth, height, material, badges = [])
      name = qualified_part_name(human_part_name(name, x, width))
      group = parent.add_group
      face = group.entities.add_face([0, 0, 0], [width, 0, 0], [width, depth, 0], [0, depth, 0])
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
      set_part_badges(instance.definition, badges)
      instance
    end

    def add_box_without_wall_relief(*args)
      add_box(*args)
    end

    def sign_corner_unit_and_launch(unit_instance)
      return false unless unit_instance && unit_instance.valid?
      sign_corner_unit!(unit_instance)
      show_designer_dialog(unit_instance)
      true
    end

    def show_designer_dialog(unit_instance = nil)
      wardrobe = selected_wardrobe || unit_instance
      unless wardrobe
        UI.messagebox('الرجاء تحديد وحدة دريسنج زاوية أولاً.')
        return
      end
      sign_corner_unit!(wardrobe)
      data = wardrobe_data(wardrobe)

      dlg = UI::HtmlDialog.new(
        dialog_title: TITLE,
        preferences_key: PREF_KEY,
        scrollable: true,
        resizable: true,
        width: 1100,
        height: 700
      )

      html = <<~HTML
        <!DOCTYPE html>
        <html lang="ar" dir="rtl">
        <head>
          <meta charset="UTF-8">
          <style>
            body { font-family: 'Tajawal', sans-serif; background: #0f172a; color: #f8fafc; margin: 0; padding: 20px; direction: rtl; }
            h2 { color: #38bdf8; border-bottom: 2px solid #334155; padding-bottom: 10px; }
            .section { background: #1e293b; padding: 15px; border-radius: 10px; margin-bottom: 15px; border: 1px solid #334155; }
            button { background: #0284c7; color: white; border: none; padding: 10px 20px; border-radius: 8px; font-weight: bold; cursor: pointer; }
            button:hover { background: #0369a1; }
          </style>
        </head>
        <body>
          <h2>مكتبة محمد عادل - إعدادات دريسنج زاوية</h2>
          <div class="section">
            <p>اسم الوحدة الحالية: <b>#{data['unit_name']}</b></p>
            <p>المقاسات: العرض #{data['width']} سم | العمق #{data['depth']} سم | الارتفاع #{data['height']} سم</p>
          </div>
          <button onclick="closeDialog()">إغلاق وحفظ</button>
          <script>
            function closeDialog() {
              if (window.sketchup) { window.sketchup.close_dialog(); }
            }
          </script>
        </body>
        </html>
      HTML

      dlg.set_html(html)
      dlg.add_action_callback("close_dialog") { |_context| dlg.close }
      dlg.center
      dlg.show
    end

    def open_for_component(item)
      sign_corner_unit_and_launch(item)
    end

    def open_for_selection
      item = selected_wardrobe
      if item
        sign_corner_unit_and_launch(item)
      else
        UI.messagebox('الرجاء تحديد وحدة دريسنج زاوية.')
      end
    end

    def show_dialog
      open_for_selection
    end

    def open_dialog
      open_for_selection
    end

    def show_ui
      open_for_selection
    end

    def activate_tool
      open_for_selection
    end

    def open_selector
      open_for_selection
    end

    def show
      open_for_selection
    end

    def open
      open_for_selection
    end

    def launch
      open_for_selection
    end

    def run
      open_for_selection
    end
  end
end