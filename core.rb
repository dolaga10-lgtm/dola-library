# encoding: UTF-8
# ==============================================================================
#  مكتبة محمد عادل الذكية (المطابخ والدريسنج) — الملف الرئيسي للأدوات (core.rb)
#  يتم رفعه في المسار الرئيسي للمستودع:
#  https://raw.githubusercontent.com/dolaga10-lgtm/dola-library/refs/heads/main/core.rb
# ==============================================================================

require 'sketchup.rb'
require 'json'
require 'cgi'
require 'uri'
require 'tmpdir'
require 'fileutils'
begin
  require 'zlib'
rescue LoadError
end

module DolaSmartLibraryPlugin

  CORE_VERSION = '2.6.0'.freeze unless const_defined?(:CORE_VERSION, false)
  PREF_NS      = 'DolaSmartLibrary'.freeze unless const_defined?(:PREF_NS, false)
  GRAIN_DICT   = 'DolaWoodGrain'.freeze unless const_defined?(:GRAIN_DICT, false)
  RELIEF_DICT  = 'DolaWallRelief'.freeze unless const_defined?(:RELIEF_DICT, false)
  OCL_DICT     = 'ladb_opencutlist'.freeze unless const_defined?(:OCL_DICT, false)

  # ============================================================================
  #  فحص وفك غلاف المكونات الديناميكية بأمان تام (بدون تفكيك أي وحدة ديناميكية)
  # ============================================================================
  def self.dynamic?(instance)
    return false unless instance.is_a?(Sketchup::ComponentInstance)
    return true if instance.attribute_dictionary('dynamic_attributes', false)
    return true if instance.definition && instance.definition.attribute_dictionary('dynamic_attributes', false)
    false
  rescue
    false
  end

  def self.unwrap_to_dynamic!(instance)
    return instance unless instance && instance.valid? && instance.is_a?(Sketchup::ComponentInstance)
    return instance if dynamic?(instance)

    ents   = instance.definition.entities.to_a
    childs = ents.grep(Sketchup::ComponentInstance)
    groups = ents.grep(Sketchup::Group)
    faces  = ents.grep(Sketchup::Face)

    # لا نفك الغلاف إلا إذا كان الملف الخارجي مجرد غلاف فارغ يحتوي على كمبوننت رئيسي واحد فقط بداخله
    return instance unless childs.length == 1 && groups.empty? && faces.empty?
    return instance unless dynamic?(childs.first)

    model = Sketchup.active_model
    model.start_operation('Unwrap Dynamic Component', true)
    begin
      parent_ents = instance.parent.entities
      before_ids  = parent_ents.to_a.map(&:entityID)

      instance.explode

      after = parent_ents.to_a.reject { |e| before_ids.include?(e.entityID) }
      after_insts = after.grep(Sketchup::ComponentInstance)

      dyn = after_insts.find { |x| dynamic?(x) } || after_insts.first
      model.selection.clear
      model.selection.add(dyn) if dyn
      model.commit_operation
      dyn || instance
    rescue
      model.abort_operation rescue nil
      instance
    end
  end

  # ============================================================================
  #  قائمة الأدوات الـ 14 الموحدة مع أيقونات SVG ملونة ومميزة لكل أداة
  # ============================================================================
  CORE_TOOLS_SPEC = [
    {
      :id      => 'component_options',
      :title   => 'خيارات الوحدة',
      :short   => 'خيارات الوحدة',
      :tooltip => 'فتح نافذة خيارات ومقاسات الوحدة المحددة + الخلع والعمود (بديل Component Options)',
      :group   => 'main',
      :rgb     => [2, 132, 199],
      :bg_grad => 'linear-gradient(135deg, #0284c7 0%, #1d4ed8 100%)',
      :symbol  => :gear,
      :svg     => '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.1" stroke-linecap="round" stroke-linejoin="round"><line x1="4" y1="6" x2="20" y2="6"/><line x1="4" y1="12" x2="20" y2="12"/><line x1="4" y1="18" x2="20" y2="18"/><circle cx="9" cy="6" r="2.3" fill="#fbbf24" stroke="#ffffff"/><circle cx="15" cy="12" r="2.3" fill="#38bdf8" stroke="#ffffff"/><circle cx="10" cy="18" r="2.3" fill="#fbbf24" stroke="#ffffff"/></svg>'
    },
    {
      :id      => 'wood_grain_all_z',
      :title   => 'توحيد/إرجاع الثمرة (Z)',
      :short   => 'ثمرة بالطول (Z)',
      :tooltip => 'ضبط اتجاه ثمرة الخشب بالطول (Z) لكل الـ HPL والـ HPL وشين والضهر الخشابي (اضغط مرة ثانية لإرجاعها للأصل)',
      :group   => 'grain',
      :rgb     => [217, 119, 6],
      :bg_grad => 'linear-gradient(135deg, #d97706 0%, #92400e 100%)',
      :symbol  => :grain_z,
      :svg     => '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="3" width="18" height="18" rx="3" fill="rgba(251,191,36,0.18)" stroke="#fcd34d"/><path d="M7 6v12M17 6v12" stroke="#fde68a" stroke-dasharray="2 2"/><path d="M12 4v16M9 7l3-3 3 3M9 17l3 3 3-3" stroke="#ffffff" stroke-width="2.3"/></svg>'
    },
    {
      :id      => 'wood_grain_single_tool',
      :title   => 'قلب ثمرة قطعة (يدوي)',
      :short   => 'قلب ثمرة قطعة',
      :tooltip => 'أداة تفاعلية بكاشف بصري لقلب ثمرة أي قطعة خشبية بين أكبر مقاسين (الطول ⇄ العرض) بدون لمس السماكة',
      :group   => 'grain',
      :rgb     => [234, 88, 12],
      :bg_grad => 'linear-gradient(135deg, #f97316 0%, #c2410c 100%)',
      :symbol  => :grain_flip,
      :svg     => '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.1" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="4" width="11" height="16" rx="2" fill="rgba(255,255,255,0.15)" stroke="#fed7aa"/><path d="M14 9h5a2 2 0 0 1 2 2v7a2 2 0 0 1-2 2h-5" stroke="#fdba74"/><path d="M16 4l4 0 0 4" stroke="#ffffff"/><path d="M20 4l-5 5" stroke="#ffffff"/><line x1="6.5" y1="7" x2="6.5" y2="17" stroke="#ffffff"/><line x1="10.5" y1="7" x2="10.5" y2="17" stroke="#ffffff"/></svg>'
    },
    {
      :id      => 'rotate90',
      :title   => 'تدوير الوحدة 45°',
      :short   => 'تدوير 45°',
      :tooltip => 'أداة تدوير أي وحدة 45 درجة حول مركزها بالضغط عليها',
      :group   => 'transform',
      :rgb     => [14, 165, 233],
      :bg_grad => 'linear-gradient(135deg, #0ea5e9 0%, #0369a1 100%)',
      :symbol  => :rotate,
      :svg     => '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 12a9 9 0 1 1-3-6.7L21 8" stroke="#ffffff"/><polyline points="21 3 21 8 16 8" stroke="#fde047"/><rect x="8.5" y="8.5" width="7" height="7" rx="1.5" fill="rgba(56,189,248,0.35)" stroke="#bae6fd"/></svg>'
    },
    {
      :id      => 'flip_lr',
      :title   => 'قلب يمين / شمال',
      :short   => 'قلب يمين/شمال',
      :tooltip => 'أداة قلب ومرايا الوحدة يمين/شمال بالضغط عليها',
      :group   => 'transform',
      :rgb     => [139, 92, 246],
      :bg_grad => 'linear-gradient(135deg, #8b5cf6 0%, #6d28d9 100%)',
      :symbol  => :flip,
      :svg     => '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.1" stroke-linecap="round" stroke-linejoin="round"><line x1="12" y1="3" x2="12" y2="21" stroke="#fde047" stroke-dasharray="2.5 2.5"/><polygon points="3,18 9,6 9,18" fill="rgba(255,255,255,0.28)" stroke="#ffffff"/><polygon points="21,18 15,6 15,18" fill="rgba(221,214,254,0.65)" stroke="#ddd6fe"/></svg>'
    },
    {
      :id      => 'snap_side',
      :title   => 'لزق جنب بجنب (Snap)',
      :short   => 'لزق جنب بجنب',
      :tooltip => 'أداة محاذاة ولزق وحدة بجانب وحدة أخرى تلقائياً (Click Side Snap)',
      :group   => 'transform',
      :rgb     => [16, 185, 129],
      :bg_grad => 'linear-gradient(135deg, #10b981 0%, #047857 100%)',
      :symbol  => :snap,
      :svg     => '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.1" stroke-linecap="round" stroke-linejoin="round"><rect x="2.5" y="5" width="8" height="14" rx="1.8" fill="rgba(255,255,255,0.22)" stroke="#ffffff"/><rect x="13.5" y="5" width="8" height="14" rx="1.8" fill="rgba(167,243,208,0.4)" stroke="#a7f3d0"/><path d="M10.5 10l3 0M10.5 14l3 0" stroke="#fde047" stroke-width="2.5"/></svg>'
    },
    {
      :id      => 'classic_door',
      :title   => 'تبديل الضلفة',
      :short   => 'تبديل الضلفة',
      :tooltip => 'تبديل شكل وتصميم الضلفة (سادة مودرن / شيكر كلاسيك / زجاج / مقبض مخفي)',
      :group   => 'kitchen',
      :rgb     => [219, 39, 119],
      :bg_grad => 'linear-gradient(135deg, #ec4899 0%, #be185d 100%)',
      :symbol  => :door,
      :svg     => '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="4" y="2.5" width="16" height="19" rx="2" fill="rgba(255,255,255,0.16)" stroke="#ffffff"/><rect x="7" y="5.5" width="10" height="13" rx="1" stroke="#fbcfe8"/><line x1="15" y1="11" x2="15" y2="13.5" stroke="#fde047" stroke-width="2.6"/></svg>'
    },
    {
      :id      => 'hand_groove',
      :title   => 'حفر ليد (LED Groove)',
      :short   => 'حفر ليد LED',
      :tooltip => 'إضافة أو حفر مجرى بروفايل الإضاءة الليد في الوحدات العلوية أو الدواليب',
      :group   => 'kitchen',
      :rgb     => [234, 179, 8],
      :bg_grad => 'linear-gradient(135deg, #eab308 0%, #a16207 100%)',
      :symbol  => :led,
      :svg     => '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="5" width="18" height="4.5" rx="1.5" fill="#fef08a" stroke="#ffffff"/><line x1="6" y1="13" x2="4.5" y2="18" stroke="#fef08a"/><line x1="12" y1="13" x2="12" y2="19" stroke="#ffffff"/><line x1="18" y1="13" x2="19.5" y2="18" stroke="#fef08a"/><line x1="9" y1="13" x2="8" y2="17.5" stroke="#fde047"/><line x1="15" y1="13" x2="16" y2="17.5" stroke="#fde047"/></svg>'
    },
    {
      :id      => 'kitchen_materials',
      :title   => 'مستويات وخامات المطبخ',
      :short   => 'خامات المطبخ',
      :tooltip => 'إدارة وتعديل أسماء وألوان ونقشات الخامات للمستويات والـ CutList',
      :group   => 'kitchen',
      :rgb     => [225, 29, 72],
      :bg_grad => 'linear-gradient(135deg, #f43f5e 0%, #9f1239 100%)',
      :symbol  => :palette,
      :svg     => '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 2.5a9.5 9.5 0 0 0 0 19c1.6 0 2.8-1.2 2.8-2.7 0-.7-.3-1.3-.7-1.8-.4-.5-.6-1-.6-1.6 0-1.4 1.2-2.5 2.6-2.5h1.8A3.6 3.6 0 0 0 21.5 9.3C21.5 5.4 17.2 2.5 12 2.5z" fill="rgba(255,255,255,0.16)" stroke="#ffffff"/><circle cx="7.5" cy="10.5" r="1.5" fill="#fde047" stroke="none"/><circle cx="10.5" cy="7" r="1.5" fill="#38bdf8" stroke="none"/><circle cx="15" cy="7.5" r="1.5" fill="#4ade80" stroke="none"/><circle cx="7.5" cy="14.8" r="1.5" fill="#fb7185" stroke="none"/></svg>'
    },
    {
      :id      => 'serial_tool',
      :title   => 'ترقيم الوحدات',
      :short   => 'ترقيم الوحدات',
      :tooltip => 'ترقيم وحدات المطبخ والدريسنج تسلسلياً للتقارير والـ Cutting List',
      :group   => 'utility',
      :rgb     => [79, 70, 229],
      :bg_grad => 'linear-gradient(135deg, #6366f1 0%, #3730a3 100%)',
      :symbol  => :serial,
      :svg     => '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.1" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="3" width="18" height="18" rx="3.5" fill="rgba(255,255,255,0.14)" stroke="#c7d2fe"/><path d="M8 9h1.5v7M7.5 16h3" stroke="#fde047"/><path d="M13.5 9.5a2 2 0 0 1 3.8.8c0 1.5-3.8 3.2-3.8 5.7h4" stroke="#ffffff"/></svg>'
    },
    {
      :id      => 'unique',
      :title   => 'جعل الكمبوننتات فريدة',
      :short   => 'كمبوننتات فريدة',
      :tooltip => 'فك ارتباط جميع الكمبوننتات المحددة أو في المشروع وجعل كل منها فريداً (Make Unique)',
      :group   => 'utility',
      :rgb     => [13, 148, 136],
      :bg_grad => 'linear-gradient(135deg, #14b8a6 0%, #0f766e 100%)',
      :symbol  => :unique,
      :svg     => '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="8" width="9" height="9" rx="1.8" fill="rgba(255,255,255,0.18)" stroke="#99f6e4"/><rect x="12" y="4" width="9" height="9" rx="1.8" fill="rgba(253,224,71,0.28)" stroke="#ffffff"/><path d="M16.5 16l1 2.2 2.2 1-2.2 1-1 2.2-1-2.2-2.2-1 2.2-1z" fill="#fde047" stroke="none"/></svg>'
    },
    {
      :id      => 'component_translator',
      :title   => 'ترجمة أسماء القطع',
      :short   => 'ترجمة القطع',
      :tooltip => 'ترجمة وتعريب أسماء جميع القطع الداخلية للوحدات لتظهر بالعربية في الـ Cutting List',
      :group   => 'utility',
      :rgb     => [8, 145, 178],
      :bg_grad => 'linear-gradient(135deg, #06b6d4 0%, #155e75 100%)',
      :symbol  => :translate,
      :svg     => '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="2.5" y="3" width="10" height="10" rx="2" fill="rgba(255,255,255,0.2)" stroke="#ffffff"/><rect x="11.5" y="11" width="10" height="10" rx="2" fill="rgba(253,224,71,0.25)" stroke="#fde047"/><path d="M5.5 10l2-5 2 5M6.2 8.5h2.6" stroke="#ffffff"/><path d="M17.5 14.5c-1.5 0-2.5.8-2.5 1.8s1 1.5 2.2 1.6c-1.6.2-2.5 1-2.5 1.8 0 1 1.5 1.5 3.8.8" stroke="#fde047"/></svg>'
    },
    {
      :id      => 'report',
      :title   => 'إنشاء تقرير الوحدات',
      :short   => 'تقرير الوحدات',
      :tooltip => 'إنشاء كشف وتقرير شامل بجميع الوحدات ومقاساتها وخاماتها مع إمكانية الطباعة والتصدير',
      :group   => 'reports',
      :rgb     => [37, 99, 235],
      :bg_grad => 'linear-gradient(135deg, #3b82f6 0%, #1e40af 100%)',
      :symbol  => :report,
      :svg     => '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="4" y="2.5" width="16" height="19" rx="2.2" fill="rgba(255,255,255,0.16)" stroke="#ffffff"/><line x1="8" y1="7.5" x2="16" y2="7.5" stroke="#fde047"/><line x1="8" y1="11.5" x2="16" y2="11.5" stroke="#bfdbfe"/><line x1="8" y1="15.5" x2="12.5" y2="15.5" stroke="#bfdbfe"/><polyline points="13.5 16.5 15 18 17.5 14.5" stroke="#4ade80" stroke-width="2.3"/></svg>'
    },
    {
      :id      => 'pricing_launcher',
      :title   => 'لوحة التسعير وعرض السعر',
      :short   => 'لوحة التسعير',
      :tooltip => 'حساب التكلفة وألواح الخشب والأمتار وإصدار عرض سعر تفصيلي للعميل',
      :group   => 'reports',
      :rgb     => [22, 163, 74],
      :bg_grad => 'linear-gradient(135deg, #22c55e 0%, #166534 100%)',
      :symbol  => :pricing,
      :svg     => '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.1" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9" fill="rgba(253,224,71,0.22)" stroke="#fde047"/><path d="M12 6.5v11M14.8 9.2c0-1.2-1.2-2-2.8-2s-2.8.8-2.8 2 1 1.8 2.8 2.2 2.8 1 2.8 2.3-1.2 2.1-2.8 2.1-2.8-.8-2.8-2" stroke="#ffffff"/></svg>'
    }
  ].freeze

  # ============================================================================
  #  إعدادات التفضيلات (Bar Mode: 'slider' | 'toolbar' | 'both')
  # ============================================================================
  def self.saved_bar_mode
    val = Sketchup.read_default(PREF_NS, 'bar_mode', 'slider').to_s.strip.downcase
    %w[slider toolbar both].include?(val) ? val : 'slider'
  rescue
    'slider'
  end

  def self.save_bar_mode(mode)
    m = mode.to_s.strip.downcase
    m = 'slider' unless %w[slider toolbar both].include?(m)
    Sketchup.write_default(PREF_NS, 'bar_mode', m) rescue nil
    m
  end

  def self.saved_bar_visible?
    val = Sketchup.read_default(PREF_NS, 'bar_visible', '1').to_s.strip
    !(val == '0' || val == 'false')
  rescue
    true
  end

  def self.save_bar_visible(visible)
    Sketchup.write_default(PREF_NS, 'bar_visible', visible ? '1' : '0') rescue nil
  end

  def self.auto_open_options_enabled?
    val = Sketchup.read_default(PREF_NS, 'auto_open_options', '1').to_s.strip
    !(val == '0' || val == 'false')
  rescue
    true
  end

  def self.set_auto_open_options_enabled(enabled)
    flag = (enabled == true || enabled.to_s == '1' || enabled.to_s.strip.downcase == 'true')
    Sketchup.write_default(PREF_NS, 'auto_open_options', flag ? '1' : '0') rescue nil
    flag
  end

  # ============================================================================
  #  توليد أيقونات PNG ملونة ومميزة للـ SketchUp Toolbar
  # ============================================================================
  def self.toolbar_icons_dir
    base = defined?(OFFLINE_DIR) ? OFFLINE_DIR : File.join(Dir.tmpdir, 'dola_offline_cache')
    dir = File.join(base, 'toolbar_icons_v3')
    FileUtils.mkdir_p(dir) unless Dir.exist?(dir)
    dir
  rescue
    Dir.tmpdir
  end

  def self.write_rgba_png(path, width, height, rgba_bytes)
    return false unless defined?(Zlib)
    raw = String.new("", encoding: Encoding::ASCII_8BIT)
    stride = width * 4
    (0...height).each do |y|
      raw << "\x00".b
      raw << rgba_bytes.byteslice(y * stride, stride)
    end
    compressed = Zlib::Deflate.deflate(raw, Zlib::BEST_COMPRESSION)

    chunk = lambda do |type, data|
      t = type.b
      d = data.b
      [d.bytesize].pack('N') + t + d + [Zlib.crc32(t + d)].pack('N')
    end

    ihdr = [width, height, 8, 6, 0, 0, 0].pack('NNCCCCC')
    png = "\x89PNG\r\n\x1a\n".b + chunk.call('IHDR', ihdr) + chunk.call('IDAT', compressed) + chunk.call('IEND', '')
    File.binwrite(path, png)
    true
  rescue
    false
  end

  def self.generate_tool_icon_png(path, size, rgb, symbol)
    return path if File.exist?(path) && File.size(path) > 60
    w = size.to_i
    h = size.to_i
    buf = Array.new(w * h * 4, 0)

    set_px = lambda do |x, y, r, g, b, a = 255|
      next if x < 0 || y < 0 || x >= w || y >= h
      idx = (y * w + x) * 4
      buf[idx]     = r
      buf[idx + 1] = g
      buf[idx + 2] = b
      buf[idx + 3] = a
    end

    draw_line = lambda do |x0, y0, x1, y1, r, g, b, thick = 1|
      dx = (x1 - x0).abs
      sx = x0 < x1 ? 1 : -1
      dy = -(y1 - y0).abs
      sy = y0 < y1 ? 1 : -1
      err = dx + dy
      cx = x0
      cy = y0
      loop do
        (-thick / 2..thick / 2).each do |ox|
          (-thick / 2..thick / 2).each do |oy|
            set_px.call(cx + ox, cy + oy, r, g, b, 255)
          end
        end
        break if cx == x1 && cy == y1
        e2 = 2 * err
        if e2 >= dy
          err += dy
          cx += sx
        end
        if e2 <= dx
          err += dx
          cy += sy
        end
      end
    end

    br, bg, bb = rgb
    pad = 1
    (pad...(h - pad)).each do |y|
      (pad...(w - pad)).each do |x|
        if (x < pad + 3 && y < pad + 3) && ((pad + 3 - x) + (pad + 3 - y) > 3)
          next
        elsif (x >= w - pad - 3 && y < pad + 3) && ((x - (w - pad - 4)) + (pad + 3 - y) > 3)
          next
        elsif (x < pad + 3 && y >= h - pad - 3) && ((pad + 3 - x) + (y - (h - pad - 4)) > 3)
          next
        elsif (x >= w - pad - 3 && y >= h - pad - 3) && ((x - (w - pad - 4)) + (y - (h - pad - 4)) > 3)
          next
        end

        is_border = (x <= pad + 1 || x >= w - pad - 2 || y <= pad + 1 || y >= h - pad - 2)
        if is_border
          set_px.call(x, y, [br + 45, 255].min, [bg + 45, 255].min, [bb + 45, 255].min, 255)
        else
          shade = ((y.to_f / h) * 38).round
          set_px.call(x, y, [br - shade, 15].max, [bg - shade, 15].max, [bb - shade, 15].max, 255)
        end
      end
    end

    mid = w / 2
    t = w >= 22 ? 2 : 1
    case symbol
    when :library
      draw_line.call(5, 7, w - 6, 7, 255, 255, 255, t)
      draw_line.call(5, mid, w - 6, mid, 253, 224, 71, t)
      draw_line.call(5, h - 7, w - 6, h - 7, 255, 255, 255, t)
    when :gear
      draw_line.call(5, 7, w - 6, 7, 255, 255, 255, t)
      draw_line.call(5, mid, w - 6, mid, 255, 255, 255, t)
      draw_line.call(5, h - 7, w - 6, h - 7, 255, 255, 255, t)
      (-2..2).each { |ox| (-2..2).each { |oy| set_px.call(8 + ox, 7 + oy, 253, 224, 71, 255) } }
      (-2..2).each { |ox| (-2..2).each { |oy| set_px.call(w - 9 + ox, mid + oy, 253, 224, 71, 255) } }
      (-2..2).each { |ox| (-2..2).each { |oy| set_px.call(10 + ox, h - 7 + oy, 253, 224, 71, 255) } }
    when :grain_z
      draw_line.call(7, 6, 7, h - 7, 254, 240, 138, 1)
      draw_line.call(mid, 5, mid, h - 6, 255, 255, 255, t)
      draw_line.call(w - 8, 6, w - 8, h - 7, 254, 240, 138, 1)
      draw_line.call(mid, 5, mid - 3, 9, 255, 255, 255, t)
      draw_line.call(mid, 5, mid + 3, 9, 255, 255, 255, t)
      draw_line.call(mid, h - 6, mid - 3, h - 10, 255, 255, 255, t)
      draw_line.call(mid, h - 6, mid + 3, h - 10, 255, 255, 255, t)
    when :grain_flip
      draw_line.call(mid, 5, mid, h - 6, 255, 255, 255, t)
      draw_line.call(5, mid, w - 6, mid, 254, 240, 138, t)
      draw_line.call(mid, 5, mid - 3, 8, 255, 255, 255, 1)
      draw_line.call(mid, 5, mid + 3, 8, 255, 255, 255, 1)
      draw_line.call(w - 6, mid, w - 9, mid - 3, 254, 240, 138, 1)
      draw_line.call(w - 6, mid, w - 9, mid + 3, 254, 240, 138, 1)
    when :rotate
      draw_line.call(7, 7, w - 7, 7, 255, 255, 255, t)
      draw_line.call(w - 7, 7, w - 7, h - 7, 255, 255, 255, t)
      draw_line.call(w - 7, h - 7, 7, h - 7, 255, 255, 255, t)
      draw_line.call(7, 7, 11, 5, 253, 224, 71, t)
      draw_line.call(7, 7, 11, 10, 253, 224, 71, t)
    when :flip
      draw_line.call(mid, 5, mid, h - 6, 253, 224, 71, 1)
      draw_line.call(5, h - 7, mid - 2, 7, 255, 255, 255, t)
      draw_line.call(w - 6, h - 7, mid + 2, 7, 255, 255, 255, t)
    when :snap
      draw_line.call(6, 6, mid - 1, 6, 255, 255, 255, t)
      draw_line.call(6, 6, 6, h - 7, 255, 255, 255, t)
      draw_line.call(6, h - 7, mid - 1, h - 7, 255, 255, 255, t)
      draw_line.call(mid + 1, 6, w - 7, 6, 253, 224, 71, t)
      draw_line.call(w - 7, 6, w - 7, h - 7, 253, 224, 71, t)
      draw_line.call(mid + 1, h - 7, w - 7, h - 7, 253, 224, 71, t)
    when :door
      draw_line.call(7, 5, w - 8, 5, 255, 255, 255, t)
      draw_line.call(7, h - 6, w - 8, h - 6, 255, 255, 255, t)
      draw_line.call(7, 5, 7, h - 6, 255, 255, 255, t)
      draw_line.call(w - 8, 5, w - 8, h - 6, 255, 255, 255, t)
      set_px.call(w - 11, mid, 253, 224, 71, 255)
      set_px.call(w - 11, mid + 1, 253, 224, 71, 255)
    when :led
      draw_line.call(5, 8, w - 6, 8, 255, 255, 255, t + 1)
      draw_line.call(8, 12, 6, h - 6, 254, 240, 138, 1)
      draw_line.call(mid, 12, mid, h - 5, 255, 255, 255, t)
      draw_line.call(w - 9, 12, w - 7, h - 6, 254, 240, 138, 1)
    when :palette
      (-2..2).each { |ox| (-2..2).each { |oy| set_px.call(8 + ox, 8 + oy, 253, 224, 71, 255) } }
      (-2..2).each { |ox| (-2..2).each { |oy| set_px.call(w - 9 + ox, 8 + oy, 56, 189, 248, 255) } }
      (-2..2).each { |ox| (-2..2).each { |oy| set_px.call(mid + ox, h - 9 + oy, 255, 255, 255, 255) } }
    when :serial
      draw_line.call(8, 6, 8, h - 7, 255, 255, 255, t)
      draw_line.call(w - 9, 6, w - 9, h - 7, 255, 255, 255, t)
      draw_line.call(5, 9, w - 6, 9, 253, 224, 71, t)
      draw_line.call(5, h - 10, w - 6, h - 10, 253, 224, 71, t)
    when :unique
      draw_line.call(6, 8, mid + 2, 8, 255, 255, 255, t)
      draw_line.call(6, 8, 6, h - 6, 255, 255, 255, t)
      draw_line.call(mid - 2, 6, w - 6, 6, 253, 224, 71, t)
      draw_line.call(w - 6, 6, w - 6, h - 8, 253, 224, 71, t)
    when :translate
      draw_line.call(6, 7, w - 7, 7, 255, 255, 255, t)
      draw_line.call(mid, 7, mid, h - 7, 255, 255, 255, t)
      draw_line.call(7, h - 7, w - 8, 11, 253, 224, 71, t)
    when :report
      draw_line.call(7, 5, w - 8, 5, 255, 255, 255, t)
      draw_line.call(7, 5, 7, h - 6, 255, 255, 255, t)
      draw_line.call(w - 8, 5, w - 8, h - 6, 255, 255, 255, t)
      draw_line.call(7, h - 6, w - 8, h - 6, 255, 255, 255, t)
      draw_line.call(10, 10, w - 11, 10, 253, 224, 71, 1)
      draw_line.call(10, mid, w - 11, mid, 253, 224, 71, 1)
    when :pricing
      draw_line.call(mid, 5, mid, h - 5, 253, 224, 71, t)
      draw_line.call(8, 8, w - 9, 8, 255, 255, 255, t)
      draw_line.call(8, mid, w - 9, mid, 255, 255, 255, t)
      draw_line.call(8, h - 9, w - 9, h - 9, 255, 255, 255, t)
    end

    raw_bytes = buf.pack('C*')
    write_rgba_png(path, w, h, raw_bytes)
    path
  rescue
    nil
  end

  # ============================================================================
  #  مشغل الأوامر الموحد (dispatch_core_action)
  # ============================================================================
  def self.dispatch_core_action(action_id)
    case action_id.to_s.strip
    when 'open_library'
      open_dola_dialog if respond_to?(:open_dola_dialog)
    when 'component_options'
      open_unit_options_dialog
    when 'wood_grain_all_z'
      DolaWoodGrainManager.align_all_wood_grain_to_z!
    when 'wood_grain_single_tool'
      DolaWoodGrainManager.activate_single_part_grain_tool
    when 'rotate90'
      activate_rotate_tool
    when 'flip_lr'
      activate_flip_lr_tool
    when 'snap_side'
      activate_click_side_snap_tool
    when 'classic_door'
      open_door_style_dialog
    when 'hand_groove'
      open_led_groove_dialog
    when 'kitchen_materials'
      open_kitchen_materials_tool
    when 'serial_tool'
      open_serial_numbering_dialog
    when 'unique'
      MHDESIGN_UNIQUIFY.run_uniquify
    when 'component_translator'
      run_arabic_part_translator
    when 'report'
      open_units_report_dialog
    when 'pricing_launcher'
      open_pricing_studio_dialog
    else
      UI.messagebox("الأداة غير معروفة: #{action_id}")
    end
  rescue => e
    UI.messagebox("حدث خطأ أثناء تشغيل الأداة:\n#{e.message}")
  end

  # ============================================================================
  #  الوضع الأول: الشريط الجانبي العائم (Floating Slider - HtmlDialog)
  #  بأيقونات فيكتور SVG ملونة ومميزة لكل أداة على حدة
  # ============================================================================
  @floating_slider_dlg = nil
  @slider_collapsed = false

  def self.open_floating_slider
    if @floating_slider_dlg && @floating_slider_dlg.visible?
      @floating_slider_dlg.bring_to_front rescue nil
      return true
    end

    @slider_collapsed = (Sketchup.read_default(PREF_NS, 'slider_collapsed', '0').to_s == '1')
    init_w = @slider_collapsed ? 82 : 235
    init_h = 700

    @floating_slider_dlg = UI::HtmlDialog.new({
      :dialog_title    => 'شريط أدوات مكتبة محمد عادل',
      :preferences_key => 'DolaFloatingSliderBar_v3',
      :scrollable      => false,
      :resizable       => true,
      :width           => init_w,
      :height          => init_h,
      :left            => 18,
      :top             => 90,
      :style           => UI::HtmlDialog::STYLE_UTILITY
    })

    tools_json = CORE_TOOLS_SPEC.to_json

    html = <<~HTML
      <!DOCTYPE html>
      <html lang="ar" dir="rtl">
      <head>
        <meta charset="UTF-8">
        <link href="https://fonts.googleapis.com/css2?family=Tajawal:wght@500;700;800&display=swap" rel="stylesheet">
        <style>
          * { box-sizing: border-box; user-select: none; }
          html, body {
            margin: 0; padding: 0;
            width: 100%; height: 100%;
            font-family: 'Tajawal', Tahoma, sans-serif;
            background: linear-gradient(180deg, #1e1b4b 0%, #0f172a 100%);
            color: #f8fafc;
            overflow: hidden;
          }
          .slider-shell {
            display: flex;
            flex-direction: column;
            height: 100vh;
            padding: 8px 7px;
            gap: 6px;
            border: 1px solid rgba(56, 189, 248, 0.25);
          }
          .brand-header {
            display: flex;
            align-items: center;
            justify-content: space-between;
            background: rgba(15, 23, 42, 0.82);
            border: 1px solid rgba(251, 191, 36, 0.38);
            border-radius: 11px;
            padding: 6px 8px;
            gap: 6px;
            box-shadow: 0 4px 14px rgba(0, 0, 0, 0.35);
          }
          .brand-title {
            font-size: 12px;
            font-weight: 800;
            color: #fbbf24;
            white-space: nowrap;
            overflow: hidden;
            text-overflow: ellipsis;
          }
          .collapse-btn {
            background: rgba(56, 189, 248, 0.16);
            border: 1px solid rgba(56, 189, 248, 0.45);
            color: #38bdf8;
            border-radius: 8px;
            width: 28px;
            height: 26px;
            cursor: pointer;
            font-weight: 800;
            font-size: 13px;
            display: flex;
            align-items: center;
            justify-content: center;
            flex-shrink: 0;
            transition: all 0.18s ease;
          }
          .collapse-btn:hover {
            background: #38bdf8;
            color: #0f172a;
          }
          .open-lib-btn {
            background: linear-gradient(135deg, #0284c7 0%, #0369a1 100%);
            border: 1px solid rgba(56, 189, 248, 0.65);
            color: #ffffff;
            border-radius: 11px;
            padding: 7px 10px;
            cursor: pointer;
            font-family: 'Tajawal', sans-serif;
            font-weight: 800;
            font-size: 12px;
            display: flex;
            align-items: center;
            justify-content: center;
            gap: 8px;
            box-shadow: 0 4px 14px rgba(2, 132, 199, 0.4);
            transition: all 0.18s ease;
          }
          .open-lib-btn:hover {
            filter: brightness(1.12);
            transform: translateY(-1px);
          }
          .open-lib-btn svg {
            width: 20px;
            height: 20px;
            flex-shrink: 0;
          }
          .tools-scroll {
            flex: 1;
            overflow-y: auto;
            overflow-x: hidden;
            display: flex;
            flex-direction: column;
            gap: 5px;
            padding-left: 2px;
          }
          .tools-scroll::-webkit-scrollbar { width: 4px; }
          .tools-scroll::-webkit-scrollbar-thumb {
            background: rgba(56, 189, 248, 0.35);
            border-radius: 99px;
          }
          .group-divider {
            font-size: 10px;
            font-weight: 700;
            color: #94a3b8;
            padding: 4px 6px 1px;
            border-top: 1px solid rgba(255, 255, 255, 0.08);
            margin-top: 2px;
            white-space: nowrap;
            overflow: hidden;
            text-overflow: ellipsis;
          }
          .tool-btn {
            display: flex;
            align-items: center;
            gap: 9px;
            width: 100%;
            padding: 6px 8px;
            border-radius: 11px;
            background: rgba(30, 41, 59, 0.82);
            border: 1px solid rgba(255, 255, 255, 0.11);
            color: #f8fafc;
            cursor: pointer;
            font-family: 'Tajawal', sans-serif;
            font-size: 12px;
            font-weight: 700;
            text-align: right;
            transition: all 0.16s ease;
          }
          .tool-btn:hover {
            background: rgba(30, 58, 138, 0.45);
            border-color: rgba(56, 189, 248, 0.7);
            transform: translateY(-1px);
            box-shadow: 0 4px 12px rgba(0, 0, 0, 0.32);
          }
          .tool-icon {
            width: 32px;
            height: 32px;
            border-radius: 9px;
            border: 1px solid rgba(255, 255, 255, 0.28);
            display: flex;
            align-items: center;
            justify-content: center;
            flex-shrink: 0;
            box-shadow: 0 3px 8px rgba(0, 0, 0, 0.35), inset 0 1px 1px rgba(255, 255, 255, 0.25);
          }
          .tool-icon svg {
            width: 20px;
            height: 20px;
            display: block;
          }
          .tool-label {
            flex: 1;
            white-space: nowrap;
            overflow: hidden;
            text-overflow: ellipsis;
          }
          .footer-bar {
            display: flex;
            gap: 5px;
            padding-top: 4px;
            border-top: 1px solid rgba(255, 255, 255, 0.1);
          }
          .mode-switch {
            flex: 1;
            background: rgba(251, 191, 36, 0.14);
            border: 1px solid rgba(251, 191, 36, 0.4);
            color: #fbbf24;
            border-radius: 8px;
            padding: 5px 6px;
            font-family: 'Tajawal', sans-serif;
            font-size: 10.5px;
            font-weight: 700;
            cursor: pointer;
            white-space: nowrap;
            overflow: hidden;
            text-overflow: ellipsis;
          }
          .mode-switch:hover {
            background: #fbbf24;
            color: #0f172a;
          }

          body.collapsed .brand-title,
          body.collapsed .tool-label,
          body.collapsed .group-divider,
          body.collapsed .open-lib-text,
          body.collapsed .mode-switch-text {
            display: none !important;
          }
          body.collapsed .brand-header {
            justify-content: center;
            padding: 5px;
          }
          body.collapsed .tool-btn {
            justify-content: center;
            padding: 5px;
          }
          body.collapsed .open-lib-btn {
            padding: 7px;
          }
        </style>
      </head>
      <body class="#{@slider_collapsed ? 'collapsed' : ''}" oncontextmenu="return false;">
        <div class="slider-shell">
          <div class="brand-header">
            <span class="brand-title">✨ أدوات محمد عادل</span>
            <button class="collapse-btn" id="collapseBtn" onclick="toggleSliderCollapse()" title="طي / توسيع الشريط الجانبي">
              #{@slider_collapsed ? '⟪' : '⟫'}
            </button>
          </div>

          <button class="open-lib-btn" onclick="runTool('open_library')" title="فتح معرض مكتبة محمد عادل 3D">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.1" stroke-linecap="round" stroke-linejoin="round">
              <path d="M3 10l9-7 9 7v10a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z" fill="rgba(255,255,255,0.2)"/>
              <polyline points="9 21 9 13 15 13 15 21" stroke="#fde047"/>
            </svg>
            <span class="open-lib-text">معرض المكتبة 3D</span>
          </button>

          <div class="tools-scroll" id="toolsContainer"></div>

          <div class="footer-bar">
            <button class="mode-switch" onclick="switchToToolbar()" title="التحويل إلى شريط أدوات سكتش أب (Toolbar)">
              <span>🧰</span>
              <span class="mode-switch-text">تحويل لـ Toolbar</span>
            </button>
          </div>
        </div>

        <script>
          const TOOLS = #{tools_json};
          const GROUP_LABELS = {
            main: 'التحكم الأساسي بالوحدة',
            grain: 'ثمرة الخشب والـ CutList',
            transform: 'الحركة والمحاذاة',
            kitchen: 'تفاصيل وخامات المطبخ',
            utility: 'الترقيم والترجمة',
            reports: 'التقارير والتسعير'
          };

          function renderTools() {
            const container = document.getElementById('toolsContainer');
            let html = '';
            let lastGroup = '';
            TOOLS.forEach(t => {
              if (t.group !== lastGroup && GROUP_LABELS[t.group]) {
                html += `<div class="group-divider">${GROUP_LABELS[t.group]}</div>`;
                lastGroup = t.group;
              }
              const bgStyle = t.bg_grad ? `background:${t.bg_grad};` : '';
              html += `
                <button class="tool-btn" onclick="runTool('${t.id}')" title="${t.tooltip}">
                  <span class="tool-icon" style="${bgStyle}">${t.svg || ''}</span>
                  <span class="tool-label">${t.title}</span>
                </button>
              `;
            });
            container.innerHTML = html;
          }

          function runTool(id) {
            if (window.sketchup && window.sketchup.run_tool) {
              window.sketchup.run_tool(id);
            }
          }

          function toggleSliderCollapse() {
            const isCollapsed = document.body.classList.toggle('collapsed');
            document.getElementById('collapseBtn').textContent = isCollapsed ? '⟪' : '⟫';
            if (window.sketchup && window.sketchup.set_slider_collapsed) {
              window.sketchup.set_slider_collapsed(isCollapsed ? '1' : '0');
            }
          }

          function switchToToolbar() {
            if (window.sketchup && window.sketchup.switch_to_toolbar) {
              window.sketchup.switch_to_toolbar();
            }
          }

          renderTools();
        </script>
      </body>
      </html>
    HTML

    @floating_slider_dlg.set_html(html)

    @floating_slider_dlg.add_action_callback('run_tool') do |_ctx, tool_id|
      dispatch_core_action(tool_id)
    end

    @floating_slider_dlg.add_action_callback('set_slider_collapsed') do |_ctx, state|
      @slider_collapsed = (state.to_s == '1')
      Sketchup.write_default(PREF_NS, 'slider_collapsed', @slider_collapsed ? '1' : '0') rescue nil
      begin
        _, cur_h = @floating_slider_dlg.get_size
        cur_h = 700 if cur_h.to_i < 300
        @floating_slider_dlg.set_size(@slider_collapsed ? 82 : 235, cur_h.to_i)
      rescue
      end
    end

    @floating_slider_dlg.add_action_callback('switch_to_toolbar') do |_ctx|
      set_bar_mode('toolbar')
    end

    @floating_slider_dlg.show
    true
  rescue => e
    puts "Error opening floating slider: #{e.message}"
    false
  end

  def self.close_floating_slider
    if @floating_slider_dlg
      @floating_slider_dlg.close rescue nil
      @floating_slider_dlg = nil
    end
    true
  end

  # ============================================================================
  #  الوضع الثاني: شريط أدوات سكتش أب الأصلي (Native UI::Toolbar)
  # ============================================================================
  @native_tools_toolbar = nil

  def self.ensure_native_toolbar
    return @native_tools_toolbar if @native_tools_toolbar

    tb = UI::Toolbar.new('مكتبة محمد عادل - الأدوات')
    icon_dir = toolbar_icons_dir

    lib_cmd = UI::Command.new('معرض مكتبة محمد عادل') { dispatch_core_action('open_library') }
    lib_cmd.tooltip = 'فتح معرض مكتبة محمد عادل الثلاثي الأبعاد'
    lib_cmd.status_bar_text = 'فتح معرض مكتبة محمد عادل (المطابخ والدريسنج)'
    lib_s = generate_tool_icon_png(File.join(icon_dir, 'lib_16.png'), 16, [2, 132, 199], :library)
    lib_l = generate_tool_icon_png(File.join(icon_dir, 'lib_24.png'), 24, [2, 132, 199], :library)
    lib_cmd.small_icon = lib_s if lib_s
    lib_cmd.large_icon = lib_l if lib_l
    tb.add_item(lib_cmd)
    tb.add_separator

    last_group = 'main'
    CORE_TOOLS_SPEC.each do |spec|
      if spec[:group] != last_group
        tb.add_separator
        last_group = spec[:group]
      end

      cmd = UI::Command.new(spec[:title]) { dispatch_core_action(spec[:id]) }
      cmd.tooltip = spec[:tooltip]
      cmd.status_bar_text = spec[:tooltip]

      s_path = generate_tool_icon_png(File.join(icon_dir, "#{spec[:id]}_16.png"), 16, spec[:rgb], spec[:symbol])
      l_path = generate_tool_icon_png(File.join(icon_dir, "#{spec[:id]}_24.png"), 24, spec[:rgb], spec[:symbol])
      cmd.small_icon = s_path if s_path
      cmd.large_icon = l_path if l_path
      tb.add_item(cmd)
    end

    @native_tools_toolbar = tb
  rescue => e
    puts "Error creating native toolbar: #{e.message}"
    nil
  end

  def self.show_native_toolbar
    tb = ensure_native_toolbar
    tb.show if tb
    true
  rescue
    false
  end

  def self.hide_native_toolbar
    @native_tools_toolbar.hide if @native_tools_toolbar
    true
  rescue
    false
  end

  # ============================================================================
  #  التبديل المرن بين أوضاع الشريط (Slider / Toolbar / Both / Hide)
  # ============================================================================
  def self.apply_bar_preferences
    unless saved_bar_visible?
      close_floating_slider
      hide_native_toolbar
      return true
    end

    case saved_bar_mode
    when 'toolbar'
      close_floating_slider
      show_native_toolbar
    when 'both'
      open_floating_slider
      show_native_toolbar
    else
      hide_native_toolbar
      open_floating_slider
    end
    true
  end

  def self.show_tools_bar
    save_bar_visible(true)
    apply_bar_preferences
  end

  def self.hide_tools_bar
    save_bar_visible(false)
    close_floating_slider
    hide_native_toolbar
  end

  def self.set_bar_mode(mode)
    save_bar_mode(mode)
    save_bar_visible(true)
    apply_bar_preferences
  end

  # ============================================================================
  #  نظام التحكم المتكامل والآمن في «ثمرة الخشب» (Wood Grain)
  #  • لا يلمس محاور أو معادلات الـ Dynamic Component نهائياً (صفر تفكيك للوحدات)
  #  • يبدل حصرياً بين أكبر مقاسين في القطعة (الطول ⇄ العرض) ويستبعد السماكة (1.8 سم / 0.6 سم)
  #  • يدعم التبديل الذكي (Toggle) في زر اتجاه Z: ضغطة توحّد وضغطة ثانية ترجّع للأصل
  # ============================================================================
  module DolaWoodGrainManager
    extend self

    AXIS_NAMES = ['x', 'y', 'z'].freeze

    NON_WOOD_KEYWORDS = [
      'مفصلة', 'مقبض', 'رجول', 'رجل', 'مجرى', 'سحاب', 'زجاج', 'ازاز', 'إزاز',
      'glass', 'hinge', 'handle', 'leg', 'runner', 'رخام', 'جرانيت', 'كوريان',
      'marble', 'granite', 'ستانلس', 'حوض', 'بوتاجاز', 'فرن', 'ثلاجة', 'شفاط',
      'غسالة', 'ميكروويف', 'led', 'ليد', 'مسمار', 'كويلا', 'إليتا', 'اليتا',
      'wire', 'basket', 'سلة', 'مصفاة', 'ترولي'
    ].freeze

    WOOD_GRAIN_KEYWORDS = [
      'خشابي', 'خشب', 'ثمرة', 'سمرة', 'قشرة', 'ارو', 'أرو', 'زان', 'بلوط',
      'جوز', 'تك', 'شيبرد', 'ميلامين', 'hpl', 'إتش بي إل', 'اتش بي ال',
      'وشين', 'ضهر خشابي', 'ظهر خشابي', 'wood', 'oak', 'walnut', 'veneer',
      'grain', 'maple', 'cherry', 'beech', 'ash', 'pine', 'mahogany', 'teak',
      'بني', 'بيج خشبي', 'دافئ'
    ].freeze

    def ents_of(entity)
      return entity.definition.entities if entity.is_a?(Sketchup::ComponentInstance)
      return entity.entities if entity.is_a?(Sketchup::Group)
      nil
    rescue
      nil
    end

    def entity_display_name(entity)
      return '' unless entity && entity.valid?
      dc_name = entity.get_attribute('dynamic_attributes', '_name', nil) ||
                entity.get_attribute('dynamic_attributes', 'name', nil)
      if entity.is_a?(Sketchup::ComponentInstance)
        n = entity.name.to_s.strip
        n = entity.definition.name.to_s.strip if n.empty?
        n = dc_name.to_s.strip if n.empty?
        n
      elsif entity.is_a?(Sketchup::Group)
        n = entity.name.to_s.strip
        n = dc_name.to_s.strip if n.empty?
        n.empty? ? 'قطعة خشبية' : n
      else
        ''
      end
    rescue
      'قطعة خشبية'
    end

    def non_wood_accessory?(entity, mat = nil)
      name_str = entity_display_name(entity).downcase
      if entity.is_a?(Sketchup::ComponentInstance)
        name_str += ' ' + entity.definition.name.to_s.downcase
      end
      mat_str = mat ? (mat.display_name.to_s + ' ' + mat.name.to_s).downcase : ''
      combined = "#{name_str} #{mat_str}"
      NON_WOOD_KEYWORDS.any? { |kw| combined.include?(kw) }
    rescue
      false
    end

    def effective_material_for(entity, inherited_mat = nil)
      return nil unless entity && entity.valid?
      mat = entity.material || inherited_mat
      ents = ents_of(entity)
      if ents
        faces = ents.grep(Sketchup::Face)
        textured_face = faces.find { |f| (f.material && f.material.texture) || (f.back_material && f.back_material.texture) }
        if textured_face
          return (textured_face.material && textured_face.material.texture) ? textured_face.material : textured_face.back_material
        end
        colored_face = faces.find { |f| f.material || f.back_material }
        mat ||= (colored_face.material || colored_face.back_material) if colored_face
      end
      mat
    rescue
      inherited_mat
    end

    def has_wood_grain_material?(entity, inherited_mat = nil)
      return false unless entity && entity.valid?
      mat = effective_material_for(entity, inherited_mat)
      return false if non_wood_accessory?(entity, mat)

      if mat && mat.get_attribute(GRAIN_DICT, 'grained_override', nil) == 'false'
        return false
      end
      if mat && mat.get_attribute(GRAIN_DICT, 'grained_override', nil) == 'true'
        return true
      end

      return true if mat && mat.texture

      mat_name = mat ? "#{mat.display_name} #{mat.name}".downcase : ''
      part_name = entity_display_name(entity).downcase
      combined = "#{mat_name} #{part_name}"
      return true if WOOD_GRAIN_KEYWORDS.any? { |kw| combined.include?(kw) }

      saved = entity.get_attribute(GRAIN_DICT, 'grain_dir', nil)
      return true unless saved.to_s.empty?

      false
    rescue
      false
    end

    def ensure_procedural_wood_texture!(mat)
      return nil unless mat
      return mat if mat.texture
      return mat unless defined?(Zlib)

      c = mat.color || Sketchup::Color.new(185, 135, 88)
      base_r = c.red
      base_g = c.green
      base_b = c.blue
      if base_r > 240 && base_g > 240 && base_b > 240
        base_r, base_g, base_b = 194, 148, 102
      end

      tex_name = "dola_wood_#{base_r}_#{base_g}_#{base_b}.png"
      tex_path = File.join(DolaSmartLibraryPlugin.toolbar_icons_dir, tex_name)
      unless File.exist?(tex_path) && File.size(tex_path) > 100
        w = 64
        h = 64
        buf = Array.new(w * h * 4, 0)
        (0...h).each do |y|
          stripe = Math.sin(y * 0.45) * 14.0 + Math.cos(y * 1.15) * 7.0
          (0...w).each do |x|
            fine = Math.sin((y * 2.2) + (x * 0.08)) * 5.0
            delta = (stripe + fine).round
            r = [[base_r + delta, 15].max, 250].min
            g = [[base_g + delta, 15].max, 250].min
            b = [[base_b + delta, 15].max, 250].min
            idx = (y * w + x) * 4
            buf[idx]     = r
            buf[idx + 1] = g
            buf[idx + 2] = b
            buf[idx + 3] = 255
          end
        end
        DolaSmartLibraryPlugin.write_rgba_png(tex_path, w, h, buf.pack('C*'))
      end

      if File.exist?(tex_path)
        mat.texture = tex_path
        mat.texture.size = [40.cm, 40.cm] rescue nil
      end
      mat
    rescue
      mat
    end

    def leaf_wooden_board?(entity)
      return false unless entity.is_a?(Sketchup::ComponentInstance) || entity.is_a?(Sketchup::Group)
      return false unless entity.valid?
      ents = ents_of(entity)
      return false unless ents
      faces = ents.grep(Sketchup::Face)
      return false if faces.empty?

      bb = entity.is_a?(Sketchup::ComponentInstance) ? entity.definition.bounds : entity.bounds
      dims = [bb.width.to_f, bb.height.to_f, bb.depth.to_f].sort
      return false if dims[2] < 0.2.cm
      true
    rescue
      false
    end

    def collect_wooden_boards(roots, require_texture_only = true)
      results = []

      walk = lambda do |ent, parent_tr, inh_mat|
        next unless ent && ent.valid?
        next if ent.hidden? || (ent.layer && !ent.layer.visible?)
        next unless ent.is_a?(Sketchup::ComponentInstance) || ent.is_a?(Sketchup::Group)

        cur_mat = ent.material || inh_mat
        world_tr = parent_tr * ent.transformation
        ents = ents_of(ent)
        next unless ents

        sub_containers = ents.select { |e| e.is_a?(Sketchup::ComponentInstance) || e.is_a?(Sketchup::Group) }
        faces = ents.grep(Sketchup::Face)

        if !faces.empty? && leaf_wooden_board?(ent) && !non_wood_accessory?(ent, cur_mat)
          if !require_texture_only || has_wood_grain_material?(ent, cur_mat)
            results << {
              :entity        => ent,
              :parent_tr     => parent_tr,
              :world_tr      => world_tr,
              :inherited_mat => cur_mat
            }
          end
        end

        sub_containers.each do |child|
          walk.call(child, world_tr, cur_mat)
        end
      end

      Array(roots).each do |r|
        walk.call(r, Geom::Transformation.new, nil)
      end
      results
    end

    # فحص هندسة اللوح واتجاه الثمرة الحالي بدقة تامة:
    # يستبعد دائماً أصغر مقاس (السماكة 1.8 سم أو 0.6 سم) ويبدل فقط بين أكبر مقاسين!
    def inspect_part_grain(entity, parent_tr = Geom::Transformation.new, inherited_mat = nil)
      return nil unless leaf_wooden_board?(entity)
      world_tr = parent_tr * entity.transformation
      bb = entity.is_a?(Sketchup::ComponentInstance) ? entity.definition.bounds : entity.bounds

      local_dims = [bb.width.to_f, bb.height.to_f, bb.depth.to_f]
      world_vecs = [world_tr.xaxis, world_tr.yaxis, world_tr.zaxis]
      scales     = world_vecs.map { |v| v.length > 1e-6 ? v.length : 1.0 }
      world_dims = [local_dims[0] * scales[0], local_dims[1] * scales[1], local_dims[2] * scales[2]]

      # ترتيب المحاور الـ 3 تصاعدياً حسب المقاس الفعلي في المشهد:
      # أصغر محور دائماً هو السماكة (1.8 سم أو 0.6 سم) ومستحيل يدخل في تبديل الثمرة!
      sorted_axes = [0, 1, 2].sort_by { |i| world_dims[i] }
      thick_idx   = sorted_axes[0]
      # أكبر مقاسين فقط هما محورا مستوى اللوح (الطول والعرض)
      i1 = sorted_axes[1]
      i2 = sorted_axes[2]

      unit_vecs = world_vecs.map do |v|
        c = v.clone
        c.normalize! rescue nil
        c
      end

      u1 = unit_vecs[i1]
      u2 = unit_vecs[i2]

      if u1.z.abs >= 0.45 || u2.z.abs >= 0.45
        vert_idx  = (u1.z.abs >= u2.z.abs) ? i1 : i2
        horiz_idx = (vert_idx == i1) ? i2 : i1
        is_vertical_board = true
      else
        if (u1.x.abs - u2.x.abs).abs > 0.25
          vert_idx  = (u1.x.abs >= u2.x.abs) ? i1 : i2
          horiz_idx = (vert_idx == i1) ? i2 : i1
        else
          vert_idx  = i2
          horiz_idx = i1
        end
        is_vertical_board = false
      end

      defn = entity.is_a?(Sketchup::ComponentInstance) ? entity.definition : nil
      saved_grain_axis = entity.get_attribute(GRAIN_DICT, 'grain_axis_idx', nil)
      saved_grain_axis = defn.get_attribute(GRAIN_DICT, 'grain_axis_idx', nil) if saved_grain_axis.nil? && defn
      saved_dir = entity.get_attribute(GRAIN_DICT, 'grain_dir', nil)
      saved_dir = defn.get_attribute(GRAIN_DICT, 'grain_dir', nil) if saved_dir.to_s.empty? && defn

      ocl_axes = defn ? defn.get_attribute(OCL_DICT, 'axes_order', nil) : nil

      active_grain_idx =
        if !saved_grain_axis.nil? && [vert_idx, horiz_idx].include?(saved_grain_axis.to_i)
          saved_grain_axis.to_i
        elsif saved_dir.to_s == 'vertical_z'
          vert_idx
        elsif saved_dir.to_s == 'horizontal_x'
          horiz_idx
        elsif ocl_axes.is_a?(Array) && !ocl_axes.empty?
          first_idx = AXIS_NAMES.index(ocl_axes[0].to_s.downcase)
          [vert_idx, horiz_idx].include?(first_idx) ? first_idx : ((world_dims[vert_idx] >= world_dims[horiz_idx]) ? vert_idx : horiz_idx)
        else
          (world_dims[vert_idx] >= world_dims[horiz_idx]) ? vert_idx : horiz_idx
        end

      active_cross_idx = (active_grain_idx == vert_idx) ? horiz_idx : vert_idx
      current_mode     = (active_grain_idx == vert_idx) ? :vertical_z : :horizontal_x

      grain_len_cm = (world_dims[active_grain_idx] * 2.54).round(1)
      cross_wid_cm = (world_dims[active_cross_idx] * 2.54).round(1)
      thick_cm     = (world_dims[thick_idx] * 2.54).round(2)
      thick_mm     = (world_dims[thick_idx] * 25.4).round(1)

      mat = effective_material_for(entity, inherited_mat)
      mat_title = mat ? mat.display_name.to_s : 'خشب'

      pts_local = [
        Geom::Point3d.new(bb.min.x, bb.min.y, bb.min.z),
        Geom::Point3d.new(bb.max.x, bb.min.y, bb.min.z),
        Geom::Point3d.new(bb.max.x, bb.max.y, bb.min.z),
        Geom::Point3d.new(bb.min.x, bb.max.y, bb.min.z),
        Geom::Point3d.new(bb.min.x, bb.min.y, bb.max.z),
        Geom::Point3d.new(bb.max.x, bb.min.y, bb.max.z),
        Geom::Point3d.new(bb.max.x, bb.max.y, bb.max.z),
        Geom::Point3d.new(bb.min.x, bb.max.y, bb.max.z)
      ]
      world_corners = pts_local.map { |pt| world_tr * pt }
      world_center  = world_tr * bb.center

      mode_label =
        if is_vertical_board
          current_mode == :vertical_z ? 'بالطول ↕ (اتجاه Z)' : 'بالعرض ↔ (اتجاه X)'
        else
          current_mode == :vertical_z ? 'أفقي مع الواجهة ↔' : 'أفقي مع العمق ↕'
        end

      {
        :entity            => entity,
        :name              => entity_display_name(entity),
        :material_name     => mat_title,
        :has_grain         => has_wood_grain_material?(entity, inherited_mat),
        :is_vertical_board => is_vertical_board,
        :mode              => current_mode,
        :mode_label        => mode_label,
        :vert_idx          => vert_idx,
        :horiz_idx         => horiz_idx,
        :thick_idx         => thick_idx,
        :grain_idx         => active_grain_idx,
        :cross_idx         => active_cross_idx,
        :grain_len_cm      => grain_len_cm,
        :cross_wid_cm      => cross_wid_cm,
        :thick_cm          => thick_cm,
        :thick_mm          => thick_mm,
        :grain_vec         => unit_vecs[active_grain_idx],
        :cross_vec         => unit_vecs[active_cross_idx],
        :thick_vec         => unit_vecs[thick_idx],
        :grain_world_dim   => world_dims[active_grain_idx],
        :cross_world_dim   => world_dims[active_cross_idx],
        :thick_world_dim   => world_dims[thick_idx],
        :world_corners     => world_corners,
        :world_center      => world_center
      }
    rescue
      nil
    end

    def snapshot_original_grain_state!(entity, info)
      return unless entity && entity.valid? && info
      return if entity.get_attribute(GRAIN_DICT, 'orig_snapshot_saved', false) == true

      entity.set_attribute(GRAIN_DICT, 'orig_snapshot_saved', true)
      entity.set_attribute(GRAIN_DICT, 'orig_grain_idx', info[:grain_idx])
      entity.set_attribute(GRAIN_DICT, 'orig_cross_idx', info[:cross_idx])
      entity.set_attribute(GRAIN_DICT, 'orig_thick_idx', info[:thick_idx])
      entity.set_attribute(GRAIN_DICT, 'orig_grain_dir', entity.get_attribute(GRAIN_DICT, 'grain_dir', '').to_s)

      if entity.is_a?(Sketchup::ComponentInstance) && entity.definition
        defn = entity.definition
        has_ocl = !defn.attribute_dictionary(OCL_DICT, false).nil?
        entity.set_attribute(GRAIN_DICT, 'orig_has_ocl', has_ocl)
        if has_ocl
          entity.set_attribute(GRAIN_DICT, 'orig_ocl_auto_orient', defn.get_attribute(OCL_DICT, 'auto_orient', nil))
          entity.set_attribute(GRAIN_DICT, 'orig_ocl_locked', defn.get_attribute(OCL_DICT, 'orientation_locked_on_axis', nil))
          axes_ord = defn.get_attribute(OCL_DICT, 'axes_order', nil)
          entity.set_attribute(GRAIN_DICT, 'orig_ocl_axes_order', axes_ord.is_a?(Array) ? axes_ord.join(',') : '')
        end
      end
    rescue
    end

    def restore_part_original_grain!(entity, parent_tr = Geom::Transformation.new, inherited_mat = nil)
      return false unless entity && entity.valid?
      info = inspect_part_grain(entity, parent_tr, inherited_mat)
      return false unless info

      orig_grain_idx = entity.get_attribute(GRAIN_DICT, 'orig_grain_idx', nil)
      orig_cross_idx = entity.get_attribute(GRAIN_DICT, 'orig_cross_idx', nil)
      orig_thick_idx = entity.get_attribute(GRAIN_DICT, 'orig_thick_idx', info[:thick_idx])

      if orig_grain_idx.nil? || orig_cross_idx.nil?
        orig_grain_idx = (info[:grain_world_dim] >= info[:cross_world_dim]) ? info[:grain_idx] : info[:cross_idx]
        orig_cross_idx = (orig_grain_idx == info[:vert_idx]) ? info[:horiz_idx] : info[:vert_idx]
      else
        orig_grain_idx = orig_grain_idx.to_i
        orig_cross_idx = orig_cross_idx.to_i
      end

      ents = ents_of(entity)
      mat  = effective_material_for(entity, inherited_mat)
      if ents && mat && mat.texture
        align_faces_uv_along_local_axis!(ents, mat, orig_grain_idx, orig_cross_idx)
      end

      if entity.is_a?(Sketchup::ComponentInstance) && entity.definition
        defn = entity.definition
        if entity.get_attribute(GRAIN_DICT, 'orig_has_ocl', false)
          ao = entity.get_attribute(GRAIN_DICT, 'orig_ocl_auto_orient', nil)
          lk = entity.get_attribute(GRAIN_DICT, 'orig_ocl_locked', nil)
          ax_str = entity.get_attribute(GRAIN_DICT, 'orig_ocl_axes_order', '').to_s
          defn.set_attribute(OCL_DICT, 'auto_orient', ao) unless ao.nil?
          defn.set_attribute(OCL_DICT, 'orientation_locked_on_axis', lk) unless lk.nil?
          if !ax_str.empty?
            defn.set_attribute(OCL_DICT, 'axes_order', ax_str.split(','))
          else
            defn.delete_attribute(OCL_DICT, 'axes_order') rescue nil
          end
        else
          defn.set_attribute(OCL_DICT, 'auto_orient', true)
          defn.set_attribute(OCL_DICT, 'orientation_locked_on_axis', false)
          defn.set_attribute(OCL_DICT, 'axes_order', [AXIS_NAMES[orig_grain_idx], AXIS_NAMES[orig_cross_idx], AXIS_NAMES[orig_thick_idx.to_i]])
        end
        defn.delete_attribute(GRAIN_DICT, 'grain_dir') rescue nil
        defn.delete_attribute(GRAIN_DICT, 'grain_axis_idx') rescue nil
      end

      entity.delete_attribute(GRAIN_DICT, 'grain_dir') rescue nil
      entity.delete_attribute(GRAIN_DICT, 'grain_axis_idx') rescue nil
      entity.delete_attribute(GRAIN_DICT, 'orig_snapshot_saved') rescue nil
      true
    rescue
      false
    end

    def set_part_grain!(entity, target_mode, parent_tr = Geom::Transformation.new, inherited_mat = nil, save_snapshot = false)
      info = inspect_part_grain(entity, parent_tr, inherited_mat)
      return false unless info

      snapshot_original_grain_state!(entity, info) if save_snapshot

      target_mode = (target_mode.to_sym == :horizontal_x) ? :horizontal_x : :vertical_z

      desired_grain_idx = (target_mode == :vertical_z) ? info[:vert_idx] : info[:horiz_idx]
      desired_cross_idx = (target_mode == :vertical_z) ? info[:horiz_idx] : info[:vert_idx]
      thick_idx         = info[:thick_idx]

      ents = ents_of(entity)
      return false unless ents

      axes_order_arr = [
        AXIS_NAMES[desired_grain_idx],
        AXIS_NAMES[desired_cross_idx],
        AXIS_NAMES[thick_idx]
      ]

      if entity.is_a?(Sketchup::ComponentInstance) && entity.definition
        defn = entity.definition
        defn.set_attribute(OCL_DICT, 'auto_orient', false)
        defn.set_attribute(OCL_DICT, 'orientation_locked_on_axis', true)
        defn.set_attribute(OCL_DICT, 'axes_order', axes_order_arr)
        defn.set_attribute(GRAIN_DICT, 'grain_dir', target_mode.to_s)
        defn.set_attribute(GRAIN_DICT, 'grain_axis_idx', desired_grain_idx)
      end

      entity.set_attribute(GRAIN_DICT, 'grain_dir', target_mode.to_s)
      entity.set_attribute(GRAIN_DICT, 'grain_axis_idx', desired_grain_idx)

      mat = effective_material_for(entity, inherited_mat)
      if mat
        ensure_procedural_wood_texture!(mat) if mat.texture.nil? && has_wood_grain_material?(entity, inherited_mat)
        align_faces_uv_along_local_axis!(ents, mat, desired_grain_idx, desired_cross_idx) if mat.texture
      end

      true
    rescue => e
      puts "WoodGrain set_part_grain! error: #{e.message}"
      false
    end

    def align_faces_uv_along_local_axis!(ents, fallback_mat, grain_axis_idx, cross_axis_idx)
      local_axes = [
        Geom::Vector3d.new(1, 0, 0),
        Geom::Vector3d.new(0, 1, 0),
        Geom::Vector3d.new(0, 0, 1)
      ]
      primary_vec   = local_axes[grain_axis_idx.to_i % 3]
      secondary_vec = local_axes[cross_axis_idx.to_i % 3]

      ents.grep(Sketchup::Face).each do |face|
        next unless face && face.valid?
        f_mat = (face.material && face.material.texture) ? face.material : fallback_mat
        next unless f_mat && f_mat.texture

        n = face.normal
        u_dir = primary_vec.clone
        if u_dir.parallel?(n)
          u_dir = secondary_vec.clone
        end
        v_dir = n.cross(u_dir)
        next if v_dir.length < 1e-6
        v_dir.normalize!
        u_dir = v_dir.cross(n)
        next if u_dir.length < 1e-6
        u_dir.normalize!

        tw = [f_mat.texture.width.to_f, 1.0].max
        th = [f_mat.texture.height.to_f, 1.0].max

        p0 = face.vertices.first.position
        p1 = p0.offset(u_dir, tw)
        p2 = p0.offset(v_dir, th)

        pts = [
          p0, Geom::Point3d.new(0, 0, 0),
          p1, Geom::Point3d.new(1, 0, 0),
          p2, Geom::Point3d.new(0, 1, 0)
        ]

        begin
          face.position_material(f_mat, pts, true)
        rescue
        end
        if face.back_material && face.back_material.texture
          begin
            face.position_material(face.back_material, pts, false)
          rescue
          end
        end
      end
    end

    def restore_dc_axes_before_redraw!(_root_unit)
      []
    end

    def reapply_grain_after_redraw!(root_unit, _saved_states = [])
      boards = collect_wooden_boards([root_unit], false)
      boards.each do |b|
        ent = b[:entity]
        next unless ent && ent.valid?
        dir = ent.get_attribute(GRAIN_DICT, 'grain_dir', nil)
        if dir.to_s.empty? && ent.is_a?(Sketchup::ComponentInstance) && ent.definition
          dir = ent.definition.get_attribute(GRAIN_DICT, 'grain_dir', nil)
        end
        next if dir.to_s.empty?
        set_part_grain!(ent, dir.to_sym, b[:parent_tr], b[:inherited_mat], false)
      end
    rescue
    end

    def align_all_wood_grain_to_z!
      model = Sketchup.active_model
      sel = model.selection.to_a.select { |e| e.is_a?(Sketchup::ComponentInstance) || e.is_a?(Sketchup::Group) }

      roots = sel
      if roots.empty?
        ans = UI.messagebox(
          "لم تقم بتحديد وحدة معينة.\nهل تريد تطبيق/إرجاع ثمرة الخشب بالطول (اتجاه Z) لكل الأخشاب المنقوشة في المشروع بالكامل؟",
          MB_YESNO
        )
        return false unless ans == IDYES
        roots = model.active_entities.to_a.select { |e| e.is_a?(Sketchup::ComponentInstance) || e.is_a?(Sketchup::Group) }
      end

      if roots.empty?
        UI.messagebox('لا توجد وحدات أو قطع خشبية في المشهد حالياً.')
        return false
      end

      boards = collect_wooden_boards(roots, true)
      if boards.empty?
        ans2 = UI.messagebox(
          "لم يتم العثور على خامة منقوشة (HPL / ضهر خشابي) على القطع المحددة حالياً.\nهل تريد تطبيق/إرجاع اتجاه الثمرة (Z) لجميع الألواح الخشبية داخل المحدد؟",
          MB_YESNO
        )
        return false unless ans2 == IDYES
        boards = collect_wooden_boards(roots, false)
      end

      if boards.empty?
        UI.messagebox('لم يتم العثور على ألواح خشبية قابلة للضبط.')
        return false
      end

      already_unified = roots.all? { |r| r.get_attribute(GRAIN_DICT, 'z_unified_active', false) == true } ||
                        boards.all? { |b| b[:entity].get_attribute(GRAIN_DICT, 'grain_dir', '').to_s == 'vertical_z' }

      if already_unified
        model.start_operation('إرجاع ثمرة الخشب للوضع الأصلي - مكتبة محمد عادل', true)
        restored_count = 0
        begin
          boards.each do |item|
            if restore_part_original_grain!(item[:entity], item[:parent_tr], item[:inherited_mat])
              restored_count += 1
            end
          end
          roots.each { |r| r.set_attribute(GRAIN_DICT, 'z_unified_active', false) rescue nil }
          model.commit_operation
        rescue => e
          model.abort_operation rescue nil
          UI.messagebox("حدث خطأ أثناء إرجاع الثمرة للأصل:\n#{e.message}")
          return false
        end

        model.active_view.invalidate
        DolaSmartLibraryPlugin.refresh_unit_options_dialog_if_open rescue nil
        UI.messagebox("↩️ تم إرجاع اتجاه ثمرة الخشب للوضع الأصلي لعدد (#{restored_count}) قطعة خشبية بنجاح!\n\n(اضغط على الزر مرة أخرى إذا أردت توحيدها في اتجاه Z مجدداً).")
        return true
      end

      model.start_operation('توحيد ثمرة الخشب بالطول (Z) - مكتبة محمد عادل', true)
      count = 0
      begin
        boards.each do |item|
          if set_part_grain!(item[:entity], :vertical_z, item[:parent_tr], item[:inherited_mat], true)
            count += 1
          end
        end
        roots.each { |r| r.set_attribute(GRAIN_DICT, 'z_unified_active', true) rescue nil }
        model.commit_operation
      rescue => e
        model.abort_operation rescue nil
        UI.messagebox("حدث خطأ أثناء ضبط الثمرة:\n#{e.message}")
        return false
      end

      model.active_view.invalidate
      DolaSmartLibraryPlugin.refresh_unit_options_dialog_if_open rescue nil
      UI.messagebox("✅ تم توحيد اتجاه ثمرة الخشب بالطول (اتجاه Z) لعدد (#{count}) قطعة خشبية!\n\n• تم التبديل بين أكبر مقاسين فقط مع تثبيت السماكة (1.8 سم / 0.6 سم).\n• اضغط على نفس الزر مرة ثانية في أي وقت لإرجاع الثمرة للوضع الأصلي.")
      true
    end

    def activate_single_part_grain_tool
      Sketchup.active_model.select_tool(DolaWoodGrainInspectorTool.new)
    end
  end

  # ============================================================================
  #  الأداة الثانية لثمرة الخشب: أداة التفتيش والقلب الفردي (قطعة بقطعة)
  # ============================================================================
  class DolaWoodGrainInspectorTool
    def initialize
      @hovered_info = nil
      @hovered_parent_tr = nil
      @hovered_inh_mat = nil
      @mouse_x = 0
      @mouse_y = 0
    end

    def activate
      @hovered_info = nil
      Sketchup.status_text = '🪵 أداة ثمرة الخشب الفردية: حرّك الماوس فوق أي قطعة لمعاينة اتجاه ثمرتها، واضغط كليك شمال للتبديل بين أكبر مقاسين (الطول ⇄ العرض).'
      Sketchup.active_model.active_view.invalidate
    end

    def deactivate(view)
      @hovered_info = nil
      view.invalidate if view
    end

    def onCancel(_reason, view)
      @hovered_info = nil
      Sketchup.active_model.select_tool(nil)
      view.invalidate if view
    end

    def pick_board_at(view, x, y)
      ph = view.pick_helper
      ph.do_pick(x, y)
      return nil if ph.count <= 0

      best_candidate = nil

      (0...ph.count).each do |idx|
        path = ph.path_at(idx)
        next unless path && !path.empty?

        containers = path.select { |e| e.is_a?(Sketchup::ComponentInstance) || e.is_a?(Sketchup::Group) }
        next if containers.empty?

        containers.reverse_each do |target|
          next unless DolaWoodGrainManager.leaf_wooden_board?(target)

          parent_tr = Geom::Transformation.new
          inh_mat = nil
          containers.each do |anc|
            break if anc == target
            parent_tr = parent_tr * anc.transformation
            inh_mat = anc.material if anc.material
          end

          next if DolaWoodGrainManager.non_wood_accessory?(target, target.material || inh_mat)

          info = DolaWoodGrainManager.inspect_part_grain(target, parent_tr, inh_mat)
          next unless info

          if info[:has_grain]
            return [info, parent_tr, inh_mat]
          else
            best_candidate ||= [info, parent_tr, inh_mat]
          end
        end
      end

      best_candidate
    rescue
      nil
    end

    def onMouseMove(_flags, x, y, view)
      @mouse_x = x
      @mouse_y = y
      picked = pick_board_at(view, x, y)
      if picked
        @hovered_info, @hovered_parent_tr, @hovered_inh_mat = picked
        Sketchup.status_text = "🪵 القطعة: #{@hovered_info[:name]} | الثمرة: #{@hovered_info[:mode_label]} | المقاسين الكبيرين: طول #{@hovered_info[:grain_len_cm]} سم × عرض #{@hovered_info[:cross_wid_cm]} سم (السُمك الثابت: #{@hovered_info[:thick_cm]} سم) — كليك شمال للتبديل"
      else
        @hovered_info = nil
        Sketchup.status_text = '🪵 حرّك الماوس فوق أي قطعة خشبية (ضلفة، جنب، ضهر خشابي، رف، HPL...) لمعاينة اتجاه ثمرتها أو قلبها بين أكبر مقاسين.'
      end
      view.invalidate
    end

    def onLButtonDown(_flags, x, y, view)
      picked = pick_board_at(view, x, y)
      return unless picked

      info, parent_tr, inh_mat = picked
      ent = info[:entity]
      return unless ent && ent.valid?

      new_mode = (info[:mode] == :vertical_z) ? :horizontal_x : :vertical_z

      model = Sketchup.active_model
      model.start_operation('قلب اتجاه ثمرة القطعة الخشبية - مكتبة محمد عادل', true)
      begin
        DolaWoodGrainManager.set_part_grain!(ent, new_mode, parent_tr, inh_mat, true)
        model.commit_operation
      rescue => e
        model.abort_operation rescue nil
        UI.messagebox("تعذر قلب الثمرة:\n#{e.message}")
        return
      end

      updated = DolaWoodGrainManager.inspect_part_grain(ent, parent_tr, inh_mat)
      if updated
        @hovered_info = updated
        Sketchup.status_text = "✨ تم تبديل الثمرة بين أكبر مقاسين: طول #{updated[:grain_len_cm]} سم × عرض #{updated[:cross_wid_cm]} سم (السُمك الثابت: #{updated[:thick_cm]} سم)"
      end
      view.invalidate
    end

    def draw(view)
      return unless @hovered_info
      corners = @hovered_info[:world_corners]
      return unless corners && corners.length == 8

      is_vert = (@hovered_info[:mode] == :vertical_z)
      box_color   = is_vert ? Sketchup::Color.new(56, 189, 248) : Sketchup::Color.new(251, 191, 36)
      arrow_color = is_vert ? Sketchup::Color.new(16, 185, 129) : Sketchup::Color.new(245, 158, 11)

      edges = [
        0,1, 1,2, 2,3, 3,0,
        4,5, 5,6, 6,7, 7,4,
        0,4, 1,5, 2,6, 3,7
      ]
      view.line_width = 3
      view.drawing_color = box_color
      view.draw(GL_LINES, edges.map { |i| corners[i] })

      center    = @hovered_info[:world_center]
      grain_vec = @hovered_info[:grain_vec]
      cross_vec = @hovered_info[:cross_vec]
      thick_vec = @hovered_info[:thick_vec]

      if center && grain_vec && cross_vec && thick_vec
        cam_eye = view.camera.eye
        to_cam  = cam_eye - center
        sign    = (to_cam.dot(thick_vec) >= 0) ? 1.0 : -1.0
        half_t  = (@hovered_info[:thick_world_dim].to_f * 0.5) + 0.35.cm
        face_center = center.offset(thick_vec, sign * half_t)

        arrow_half_len = [@hovered_info[:grain_world_dim].to_f * 0.34, 2.5.cm].max
        head_size      = [arrow_half_len * 0.24, 1.2.cm].max
        cross_spread   = [@hovered_info[:cross_world_dim].to_f * 0.24, 1.5.cm].max

        view.line_width = 4
        view.drawing_color = arrow_color

        [-1, 0, 1].each do |slot|
          base_pt = (slot == 0) ? face_center : face_center.offset(cross_vec, slot * cross_spread)
          p_start = base_pt.offset(grain_vec, -arrow_half_len)
          p_end   = base_pt.offset(grain_vec,  arrow_half_len)

          view.draw(GL_LINES, [p_start, p_end])

          h1_a = p_end.offset(grain_vec, -head_size).offset(cross_vec,  head_size * 0.55)
          h1_b = p_end.offset(grain_vec, -head_size).offset(cross_vec, -head_size * 0.55)
          view.draw(GL_LINES, [p_end, h1_a, p_end, h1_b])

          h2_a = p_start.offset(grain_vec, head_size).offset(cross_vec,  head_size * 0.55)
          h2_b = p_start.offset(grain_vec, head_size).offset(cross_vec, -head_size * 0.55)
          view.draw(GL_LINES, [p_start, h2_a, p_start, h2_b])
        end
      end

      screen_pt = Geom::Point3d.new(@mouse_x + 18, @mouse_y - 28, 0)
      label_txt = "🪵 #{@hovered_info[:name]} | الثمرة: #{@hovered_info[:mode_label]}\n📐 الطول: #{@hovered_info[:grain_len_cm]} سم × العرض: #{@hovered_info[:cross_wid_cm]} سم (السُمك الثابت: #{@hovered_info[:thick_cm]} سم)"
      begin
        view.draw_text(screen_pt, label_txt, :size => 12, :bold => true, :color => box_color)
      rescue
        view.draw_text(screen_pt, label_txt) rescue nil
      end
    rescue
    end
  end

  # ============================================================================
  #  نظام «الخلع والعمود (خلعة الحائط)» لوحدات المطبخ (بنفس منطق ومعاينة الدريسنج)
  # ============================================================================
  def self.read_unit_wall_relief_config(unit, unit_width_cm)
    default_cfg = {
      'enabled'        => 'no',
      'wall_width'     => [unit_width_cm.to_f, 200.0].max.round(1),
      'placement'      => 'right',
      'cabinet_offset' => 0.0,
      'columns'        => []
    }
    return default_cfg unless unit && unit.valid?
    raw = unit.get_attribute(RELIEF_DICT, 'config_json', nil)
    return default_cfg if raw.to_s.strip.empty?
    parsed = JSON.parse(raw.to_s) rescue nil
    return default_cfg unless parsed.is_a?(Hash)
    default_cfg.merge(parsed)
  rescue
    default_cfg
  end

  def self.remove_kitchen_unit_wall_relief!(unit)
    return false unless unit && unit.valid?
    model = Sketchup.active_model
    model.start_operation('إلغاء خلعة الحائط والعمود - مكتبة محمد عادل', true)
    begin
      if unit.is_a?(Sketchup::ComponentInstance) && unit.definition
        to_erase = unit.definition.entities.select do |e|
          e && e.valid? && e.respond_to?(:get_attribute) && e.get_attribute(RELIEF_DICT, 'is_relief_cladding', false) == true
        end
        to_erase.each { |e| e.erase! rescue nil }

        unit.definition.entities.each do |e|
          next unless e && e.valid? && e.respond_to?(:get_attribute)
          if e.get_attribute(RELIEF_DICT, 'hidden_by_relief', false) == true
            e.hidden = false rescue nil
            e.delete_attribute(RELIEF_DICT, 'hidden_by_relief') rescue nil
          end
        end
      end

      orig_depth_key = unit.get_attribute(RELIEF_DICT, 'orig_depth_key', nil)
      orig_depth_val = unit.get_attribute(RELIEF_DICT, 'orig_depth_val', nil)
      if orig_depth_key && !orig_depth_val.nil?
        apply_unit_dc_options_changes!({ orig_depth_key.to_s => orig_depth_val.to_s }, false)
      end

      shifted_vec = unit.get_attribute(RELIEF_DICT, 'shifted_world_vec', nil)
      if shifted_vec.is_a?(Array) && shifted_vec.length == 3
        inv_v = Geom::Vector3d.new(-shifted_vec[0].to_f, -shifted_vec[1].to_f, -shifted_vec[2].to_f)
        unit.transform!(Geom::Transformation.translation(inv_v)) if inv_v.length > 1e-4
      end

      unit.delete_attribute(RELIEF_DICT, 'orig_depth_key') rescue nil
      unit.delete_attribute(RELIEF_DICT, 'orig_depth_val') rescue nil
      unit.delete_attribute(RELIEF_DICT, 'shifted_world_vec') rescue nil
      unit.set_attribute(RELIEF_DICT, 'config_json', { 'enabled' => 'no', 'columns' => [] }.to_json)

      model.commit_operation
      model.active_view.invalidate
      refresh_unit_options_dialog_if_open(unit)
      true
    rescue => e
      model.abort_operation rescue nil
      UI.messagebox("تعذر إلغاء الخلع:\n#{e.message}")
      false
    end
  end

  def self.apply_kitchen_unit_wall_relief!(cfg_hash)
    unit = find_selected_dc_unit
    unless unit && unit.valid?
      UI.messagebox('الرجاء تحديد وحدة المطبخ أولاً.')
      return false
    end

    if unit.get_attribute(RELIEF_DICT, 'orig_depth_key', nil) ||
       (unit.is_a?(Sketchup::ComponentInstance) && unit.definition.entities.any? { |e| e.respond_to?(:get_attribute) && e.get_attribute(RELIEF_DICT, 'is_relief_cladding', false) })
      remove_kitchen_unit_wall_relief!(unit)
    end

    bb = unit.bounds
    cab_w_cm = (bb.width.to_f * 2.54).round(1)
    cab_d_cm = (bb.depth.to_f * 2.54).round(1)

    wall_w   = [cfg_hash['wall_width'].to_f, cab_w_cm].max
    place    = cfg_hash['placement'].to_s == 'right' ? 'right' : 'left'
    cab_off  = [cfg_hash['cabinet_offset'].to_f, 0.0].max
    cab_start = (place == 'right') ? [wall_w - cab_off - cab_w_cm, 0.0].max : [cab_off, [wall_w - cab_w_cm, 0.0].max].min

    cols = Array(cfg_hash['columns']).select { |c| c.is_a?(Hash) }
    overlapping = []
    cols.each_with_index do |c, idx|
      cw   = c['width'].to_f
      dep  = c['depth'].to_f
      side = c['side'].to_s == 'right' ? 'right' : 'left'
      dist = c['distance'].to_f
      wx0  = (side == 'right') ? (wall_w - dist - cw) : dist
      wx1  = wx0 + cw
      x0   = [wx0 - cab_start, 0.0].max
      x1   = [wx1 - cab_start, cab_w_cm].min
      next unless (x1 - x0) > 0.3 && dep > 0.3
      overlapping << {
        'index' => idx + 1,
        'x0_cm' => x0,
        'x1_cm' => x1,
        'width_cm' => (x1 - x0).round(1),
        'depth_cm' => [dep, cab_d_cm - 5.0].min.round(1),
        'mode' => (c['mode'].to_s == 'true_notch' ? 'true_notch' : 'depth_avoid')
      }
    end

    unit.set_attribute(RELIEF_DICT, 'config_json', cfg_hash.to_json)

    if overlapping.empty?
      UI.messagebox("⚠️ تم حفظ إعدادات الحائط والعمود، ولكن العمود المدخل لا يتقاطع مع موقع هذه الوحدة حالياً (عرض الوحدة #{cab_w_cm} سم على بُعد #{cab_off} سم).")
      refresh_unit_options_dialog_if_open(unit)
      return true
    end

    model = Sketchup.active_model
    model.start_operation('تطبيق الخلع والعمود على وحدة المطبخ - مكتبة محمد عادل', true)

    begin
      payload = extract_unit_dc_options_payload(unit)
      fields  = Array(payload[:fields])
      depth_field = fields.find do |f|
        f['access'] != 'VIEW' && (f['key'].to_s.downcase == 'leny' || f['label'].to_s.include?('عمق'))
      end

      max_avoid_depth_cm = overlapping.select { |r| r['mode'] == 'depth_avoid' }.map { |r| r['depth_cm'].to_f }.max.to_f
      notch_items        = overlapping.select { |r| r['mode'] == 'true_notch' }

      if max_avoid_depth_cm > 0.3 && depth_field
        cur_depth_cm = depth_field['value'].to_f
        cur_depth_cm = cab_d_cm if cur_depth_cm <= 1.0
        new_depth_cm = [cur_depth_cm - max_avoid_depth_cm, 15.0].max.round(1)

        unit.set_attribute(RELIEF_DICT, 'orig_depth_key', depth_field['key'].to_s)
        unit.set_attribute(RELIEF_DICT, 'orig_depth_val', cur_depth_cm.to_s)

        apply_unit_dc_options_changes!({ depth_field['key'].to_s => new_depth_cm.to_s }, false)

        forward_vec = unit.transformation.yaxis.clone
        if forward_vec.length > 1e-6
          forward_vec.normalize!
          shift_v = Geom::Vector3d.new(
            -forward_vec.x * max_avoid_depth_cm.cm,
            -forward_vec.y * max_avoid_depth_cm.cm,
            -forward_vec.z * max_avoid_depth_cm.cm
          )
          unit.transform!(Geom::Transformation.translation(shift_v))
          unit.set_attribute(RELIEF_DICT, 'shifted_world_vec', [shift_v.x, shift_v.y, shift_v.z])
        end
      end

      if !notch_items.empty? && unit.is_a?(Sketchup::ComponentInstance)
        unit.make_unique if unit.definition.count_used_instances > 1
        defn = unit.definition
        lbb  = defn.bounds
        t_board = 1.8.cm

        sample_mat = unit.material
        if sample_mat.nil?
          sample_part = defn.entities.grep(Sketchup::ComponentInstance).find { |c| c.material }
          sample_mat = sample_part.material if sample_part
        end

        notch_items.each do |notch|
          nx0 = lbb.min.x + notch['x0_cm'].to_f.cm
          nx1 = lbb.min.x + notch['x1_cm'].to_f.cm
          ndep = notch['depth_cm'].to_f.cm
          by1 = lbb.max.y
          by0 = by1 - ndep
          bz0 = lbb.min.z
          bz1 = lbb.max.z

          grp = defn.entities.add_group
          grp.name = "تجليد خلع عمود #{notch['index']} (#{notch['width_cm']}×#{notch['depth_cm']} سم)"
          grp.set_attribute(RELIEF_DICT, 'is_relief_cladding', true)

          f_pts = [
            Geom::Point3d.new(nx0, by0 - t_board, bz0),
            Geom::Point3d.new(nx1, by0 - t_board, bz0),
            Geom::Point3d.new(nx1, by0, bz0),
            Geom::Point3d.new(nx0, by0, bz0)
          ]
          face_front = grp.entities.add_face(f_pts)
          face_front.pushpull(bz1 - bz0) if face_front

          s1_pts = [
            Geom::Point3d.new(nx0, by0, bz0),
            Geom::Point3d.new(nx0 + t_board, by0, bz0),
            Geom::Point3d.new(nx0 + t_board, by1, bz0),
            Geom::Point3d.new(nx0, by1, bz0)
          ]
          face_s1 = grp.entities.add_face(s1_pts)
          face_s1.pushpull(bz1 - bz0) if face_s1

          s2_pts = [
            Geom::Point3d.new(nx1 - t_board, by0, bz0),
            Geom::Point3d.new(nx1, by0, bz0),
            Geom::Point3d.new(nx1, by1, bz0),
            Geom::Point3d.new(nx1 - t_board, by1, bz0)
          ]
          face_s2 = grp.entities.add_face(s2_pts)
          face_s2.pushpull(bz1 - bz0) if face_s2

          grp.material = sample_mat if sample_mat
        end
      end

      model.commit_operation
      model.active_view.invalidate
      refresh_unit_options_dialog_if_open(unit)
      UI.messagebox("✅ تم تطبيق إعدادات الخلع والعمود على الوحدة بنجاح!")
      true
    rescue => e
      model.abort_operation rescue nil
      UI.messagebox("حدث خطأ أثناء تطبيق الخلع والعمود:\n#{e.message}")
      false
    end
  end

  # ============================================================================
  #  نافذة «خيارات الوحدة — مكتبة محمد عادل» (بديلة Component Options)
  # ============================================================================
  @unit_options_dlg = nil
  @unit_options_selection_observer = nil

  class DolaUnitOptionsSelectionObserver < Sketchup::SelectionObserver
    def onSelectionBulkChange(_selection)
      DolaSmartLibraryPlugin.refresh_unit_options_dialog_if_open
    end
    def onSelectionCleared(_selection)
      DolaSmartLibraryPlugin.refresh_unit_options_dialog_if_open
    end
  end

  def self.dc_engine_instance
    return nil unless defined?($dc_observers) && $dc_observers
    $dc_observers.get_latest_class
  rescue
    nil
  end

  def self.unescape_dc_string(raw)
    s = raw.to_s
    s = s.gsub(/%u([0-9A-Fa-f]{4})/) { [$1.hex].pack('U') }
    s = CGI.unescape(s) rescue s
    s.strip
  rescue
    raw.to_s.strip
  end

  def self.clean_dc_label(raw)
    s = unescape_dc_string(raw)
    s = s.gsub(/&lt;/i, '<').gsub(/&gt;/i, '>').gsub(/&quot;/i, '"').gsub(/&#39;/i, "'").gsub(/&amp;/i, '&')
    s = s.gsub(/<style[^>]*>.*?<\/style>/im, '')
    s = s.gsub(/<\/?[a-zA-Z][^>]*>/, ' ')
    s = s.gsub(/\b(?:font-size|font-family|font-weight|color|size|face|style)\s*=\s*["']?[^"'\s>]+["']?/i, ' ')
    s = s.sub(/\A\s*=+\s*/, '')
    s = s.gsub(/\s+/, ' ').strip
    s
  rescue
    raw.to_s.strip
  end

  def self.find_selected_dc_unit(preferred = nil)
    if preferred && preferred.valid? && preferred.is_a?(Sketchup::ComponentInstance)
      return preferred
    end
    sel = Sketchup.active_model.selection.to_a
    inst = sel.find { |e| e.is_a?(Sketchup::ComponentInstance) && dynamic?(e) }
    inst ||= sel.find { |e| e.is_a?(Sketchup::ComponentInstance) }
    inst
  rescue
    nil
  end

  def self.dc_attr_meta(unit, key, attr_suffix)
    meta_key = "_#{key}_#{attr_suffix}"
    val = unit.get_attribute('dynamic_attributes', meta_key, nil)
    if val.nil? && unit.respond_to?(:definition) && unit.definition
      val = unit.definition.get_attribute('dynamic_attributes', meta_key, nil)
    end
    val
  rescue
    nil
  end

  def self.dc_is_length_attribute?(unit, key, units_str, formula_units_str, label_str)
    k = key.to_s.downcase
    return true if %w[lenx leny lenz x y z].include?(k)

    u  = units_str.to_s.upcase.strip
    fu = formula_units_str.to_s.upcase.strip
    return true if %w[CENTIMETERS MILLIMETERS METERS INCHES FEET].include?(u)
    return true if %w[CENTIMETERS MILLIMETERS METERS INCHES FEET].include?(fu)
    return false if %w[STRING INTEGER FLOAT BOOLEAN PERCENT].include?(u)

    if u.empty? || u == 'DEFAULT'
      lbl = label_str.to_s
      dim_words = %w[عرض ارتفاع عمق طول سمك تخانة تخانات مسافة رحرحة سقوط بروز خصم مقاس شاسيه رجل رجول وزرة فراغ قطر]
      return true if dim_words.any? { |w| lbl.include?(w) }
    end
    false
  end

  def self.extract_unit_dc_options_payload(unit)
    return { :has_unit => false } unless unit && unit.valid? && unit.is_a?(Sketchup::ComponentInstance)

    d_type = respond_to?(:dressing_unit_type) ? dressing_unit_type(unit) : nil

    d = dc_engine_instance
    inst_dict = unit.attribute_dictionary('dynamic_attributes', false)
    def_dict  = unit.definition.attribute_dictionary('dynamic_attributes', false)

    all_keys = []
    [def_dict, inst_dict].compact.each do |dict|
      dict.each_pair do |k, _v|
        ks = k.to_s
        if ks.start_with?('_') && ks.end_with?('_access')
          base_k = ks.sub(/\A_/, '').sub(/_access\z/, '')
          all_keys << base_k
        end
      end
    end
    all_keys.uniq!

    fields = []
    all_keys.each do |key|
      access = begin
        (d ? d.get_attribute_access(unit, key) : nil) || dc_attr_meta(unit, key, 'access')
      rescue
        dc_attr_meta(unit, key, 'access')
      end
      access = access.to_s.upcase.strip
      next if access.empty? || access == 'NONE'

      raw_label = begin
        (d ? d.get_attribute_formlabel(unit, key) : nil) ||
          dc_attr_meta(unit, key, 'formlabel') ||
          dc_attr_meta(unit, key, 'label') ||
          key
      rescue
        dc_attr_meta(unit, key, 'formlabel') || key
      end
      label = clean_dc_label(raw_label)
      label = key.to_s if label.empty?

      units_str = begin
        (d ? d.get_attribute_units(unit, key) : nil) || dc_attr_meta(unit, key, 'units')
      rescue
        dc_attr_meta(unit, key, 'units')
      end.to_s.upcase.strip

      formula_units_str = begin
        (d ? d.get_attribute_formulaunits(unit, key) : nil) || dc_attr_meta(unit, key, 'formulaunits')
      rescue
        dc_attr_meta(unit, key, 'formulaunits')
      end.to_s.upcase.strip

      raw_val = begin
        v = d ? d.get_attribute_value(unit, key) : nil
        v = unit.get_attribute('dynamic_attributes', key, nil) if v.nil?
        v = unit.definition.get_attribute('dynamic_attributes', key, nil) if v.nil?
        v
      rescue
        unit.get_attribute('dynamic_attributes', key, nil)
      end

      is_len = dc_is_length_attribute?(unit, key, units_str, formula_units_str, label)

      options_list = []
      if access == 'LIST'
        raw_opts = begin
          (d ? d.get_attribute_options(unit, key) : nil) || dc_attr_meta(unit, key, 'options')
        rescue
          dc_attr_meta(unit, key, 'options')
        end.to_s

        raw_opts.split('&').each do |pair|
          next if pair.strip.empty?
          lbl_enc, val_enc = pair.split('=', 2)
          opt_label = clean_dc_label(lbl_enc || pair)
          opt_val   = unescape_dc_string(val_enc || lbl_enc || pair)
          options_list << { 'label' => opt_label, 'value' => opt_val }
        end
      end

      display_val = ''
      unit_badge  = ''

      if access == 'LIST'
        cur_str = raw_val.to_s.strip
        matched_opt = options_list.find { |o| o['value'].to_s.strip.downcase == cur_str.downcase }
        if !matched_opt && cur_str =~ /\A-?\d+(\.\d+)?\z/
          num = cur_str.to_f
          matched_opt = options_list.find do |o|
            ov = o['value'].to_s.strip
            next false unless ov =~ /\A-?\d+(\.\d+)?\z/
            (ov.to_f - num).abs < 0.005 || ((ov.to_f / 2.54) - num).abs < 0.005 || ((ov.to_f * 2.54) - num).abs < 0.005
          end
        end
        display_val = matched_opt ? matched_opt['value'] : cur_str
      elsif is_len
        if units_str == 'MILLIMETERS'
          display_val = (raw_val.to_f * 25.4).round(2).to_s.sub(/\.0+\z/, '')
          unit_badge  = 'مم'
        elsif units_str == 'METERS'
          display_val = (raw_val.to_f * 0.0254).round(3).to_s.sub(/\.0+\z/, '')
          unit_badge  = 'م'
        else
          display_val = (raw_val.to_f * 2.54).round(2).to_s.sub(/\.0+\z/, '')
          unit_badge  = 'سم'
        end
      else
        display_val = clean_dc_label(raw_val.to_s)
        if display_val =~ /\A-?\d+\.\d+\z/
          display_val = display_val.to_f.round(2).to_s.sub(/\.0+\z/, '')
        end
      end

      norm_lbl = label.gsub(/\s+/, '')
      is_primary_dim = (
        access != 'VIEW' &&
        (norm_lbl.include?('عرض') || norm_lbl.include?('ارتفاع') || norm_lbl.include?('عمق')) &&
        !norm_lbl.include?('درج') && !norm_lbl.include?('رف')
      )

      fields << {
        'key'            => key,
        'label'          => label,
        'access'         => access,
        'is_length'      => is_len,
        'units'          => units_str,
        'formula_units'  => formula_units_str,
        'unit_badge'     => unit_badge,
        'value'          => display_val,
        'options'        => options_list,
        'is_primary_dim' => is_primary_dim
      }
    end

    fields.sort_by! { |f| f['key'].to_s.downcase }

    bb = unit.bounds
    w_cm = (bb.width.to_f * 2.54).round(1)
    d_cm = (bb.depth.to_f * 2.54).round(1)
    h_cm = (bb.height.to_f * 2.54).round(1)

    unit_title = clean_dc_label(unit.definition.name.to_s.gsub(/\s*\([^)]*\)/, ''))
    unit_title = clean_dc_label(unit.name.to_s) if unit_title.empty?
    unit_title = 'وحدة مطبخ' if unit_title.empty?

    grain_z_active = (unit.get_attribute(GRAIN_DICT, 'z_unified_active', false) == true)
    wall_relief_cfg = read_unit_wall_relief_config(unit, w_cm)

    {
      :has_unit       => true,
      :entity_id      => unit.entityID,
      :unit_name      => unit_title,
      :dressing_type  => d_type.to_s,
      :bbox_w_cm      => w_cm,
      :bbox_d_cm      => d_cm,
      :bbox_h_cm      => h_cm,
      :auto_open      => auto_open_options_enabled?,
      :grain_z_active => grain_z_active,
      :wall_relief    => wall_relief_cfg,
      :fields         => fields
    }
  rescue => e
    { :has_unit => false, :error => e.message }
  end

  def self.apply_unit_dc_options_changes!(changes_hash, refresh_dialog = true)
    return false unless changes_hash.is_a?(Hash) && !changes_hash.empty?
    unit = find_selected_dc_unit
    unless unit && unit.valid?
      UI.messagebox('الرجاء تحديد الوحدة أولاً في سكتش أب.')
      return false
    end

    d = dc_engine_instance
    unless d
      UI.messagebox('إضافة Dynamic Components غير مفعلة في سكتش أب.')
      return false
    end

    payload = extract_unit_dc_options_payload(unit)
    field_map = {}
    Array(payload[:fields]).each { |f| field_map[f['key'].to_s] = f }

    model = Sketchup.active_model
    model.start_operation('تحديث خيارات الوحدة - مكتبة محمد عادل', true)

    begin
      forced = {}
      changes_hash.each do |raw_key, user_val|
        key = raw_key.to_s
        meta = field_map[key]
        next unless meta
        next if meta['access'] == 'VIEW'

        val_str = user_val.to_s.strip
        next if val_str == meta['value'].to_s.strip

        internal_val = val_str

        if meta['access'] == 'LIST'
          if meta['is_length'] && val_str =~ /\A-?\d+(\.\d+)?\z/ && meta['formula_units'] == 'CENTIMETERS'
            internal_val = (val_str.to_f / 2.54)
          else
            internal_val = val_str
          end
        elsif meta['is_length']
          num = val_str.tr('٠١٢٣٤٥٦٧٨٩', '0123456789').to_f
          if meta['units'] == 'MILLIMETERS'
            internal_val = num / 25.4
          elsif meta['units'] == 'METERS'
            internal_val = num / 0.0254
          else
            internal_val = num / 2.54
          end
        elsif meta['units'] == 'INTEGER'
          internal_val = val_str.tr('٠١٢٣٤٥٦٧٨٩', '0123456789').to_i
        elsif meta['units'] == 'FLOAT'
          internal_val = val_str.tr('٠١٢٣٤٥٦٧٨٩', '0123456789').to_f
        end

        if meta['access'] != 'LIST'
          formula_key = "_#{key}_formula"
          unit.delete_attribute('dynamic_attributes', formula_key) rescue nil
        end

        begin
          d.set_attribute(unit, key, internal_val)
        rescue
          unit.set_attribute('dynamic_attributes', key, internal_val)
        end
        unit.set_attribute('dynamic_attributes', key, internal_val)
        forced[key] = internal_val
      end

      unless forced.empty?
        forced.each { |k, v| d.set_forced_config_value(unit, k, v) rescue nil }
        d.run_all_formulas(unit) rescue nil
        d.redraw(unit, false, false) rescue nil
        d.update_last_sizes(unit) rescue nil

        d.clear_forced_config_values(unit) rescue nil
        d.run_all_formulas(unit) rescue nil
        d.redraw(unit, false, false) rescue nil
        d.update_last_sizes(unit) rescue nil

        DolaWoodGrainManager.reapply_grain_after_redraw!(unit)
      end

      model.commit_operation
      model.active_view.invalidate
      refresh_unit_options_dialog_if_open(unit) if refresh_dialog
      true
    rescue => e
      model.abort_operation rescue nil
      UI.messagebox("حدث خطأ أثناء تطبيق خيارات الوحدة:\n#{e.message}")
      false
    end
  end

  def self.refresh_unit_options_dialog_if_open(preferred_unit = nil)
    return false unless @unit_options_dlg && @unit_options_dlg.visible?
    unit = find_selected_dc_unit(preferred_unit)
    data = extract_unit_dc_options_payload(unit)
    @unit_options_dlg.execute_script("window.receiveUnitPayload(#{data.to_json});") rescue nil
    true
  rescue
    false
  end

  def self.open_unit_options_dialog(preferred_unit = nil)
    unit = find_selected_dc_unit(preferred_unit)

    if unit && respond_to?(:dressing_unit_type)
      dtype = dressing_unit_type(unit)
      if dtype && !dtype.to_s.empty?
        return open_dressing_design_tool(dtype, unit)
      end
    end

    unless @unit_options_selection_observer
      @unit_options_selection_observer = DolaUnitOptionsSelectionObserver.new
      Sketchup.active_model.selection.add_observer(@unit_options_selection_observer) rescue nil
    end

    if @unit_options_dlg && @unit_options_dlg.visible?
      refresh_unit_options_dialog_if_open(unit)
      @unit_options_dlg.bring_to_front rescue nil
      return true
    end

    @unit_options_dlg = UI::HtmlDialog.new({
      :dialog_title    => 'خيارات الوحدة والخلع — مكتبة محمد عادل',
      :preferences_key => 'DolaKitchenUnitOptions_v3',
      :scrollable      => false,
      :resizable       => true,
      :width           => 500,
      :height          => 720,
      :left            => 240,
      :top             => 85,
      :style           => UI::HtmlDialog::STYLE_DIALOG
    })

    initial_payload = extract_unit_dc_options_payload(unit).to_json

    html = <<~HTML
      <!DOCTYPE html>
      <html lang="ar" dir="rtl">
      <head>
        <meta charset="UTF-8">
        <link href="https://fonts.googleapis.com/css2?family=Tajawal:wght@400;500;700;800&display=swap" rel="stylesheet">
        <style>
          * { box-sizing: border-box; }
          html, body {
            margin: 0; padding: 0;
            width: 100%; height: 100%;
            font-family: 'Tajawal', Tahoma, sans-serif;
            background: radial-gradient(circle at top right, #1e1b4b 0%, #0f172a 65%, #090d16 100%);
            color: #f8fafc;
            overflow: hidden;
          }
          .app-wrap {
            display: flex;
            flex-direction: column;
            height: 100vh;
            padding: 13px;
            gap: 10px;
          }
          .hero-card {
            background: linear-gradient(135deg, rgba(30, 27, 75, 0.92) 0%, rgba(15, 23, 42, 0.95) 100%);
            border: 1px solid rgba(56, 189, 248, 0.35);
            border-radius: 15px;
            padding: 11px 14px;
            display: flex;
            align-items: center;
            justify-content: space-between;
            gap: 10px;
            box-shadow: 0 10px 28px rgba(0, 0, 0, 0.4);
          }
          .hero-right {
            display: flex;
            align-items: center;
            gap: 10px;
            min-width: 0;
          }
          .hero-badge {
            width: 40px;
            height: 40px;
            border-radius: 11px;
            background: linear-gradient(135deg, #0284c7 0%, #1e1b4b 100%);
            border: 1px solid #38bdf8;
            display: flex;
            align-items: center;
            justify-content: center;
            font-size: 19px;
            flex-shrink: 0;
            box-shadow: 0 0 15px rgba(56, 189, 248, 0.35);
          }
          .hero-titles { min-width: 0; }
          .hero-brand {
            font-size: 11px;
            font-weight: 800;
            color: #fbbf24;
          }
          .hero-unit-name {
            font-size: 15.5px;
            font-weight: 800;
            color: #ffffff;
            white-space: nowrap;
            overflow: hidden;
            text-overflow: ellipsis;
          }
          .dims-pill {
            background: rgba(2, 132, 199, 0.16);
            border: 1px solid rgba(56, 189, 248, 0.4);
            color: #38bdf8;
            padding: 5px 10px;
            border-radius: 10px;
            font-size: 11.5px;
            font-weight: 700;
            white-space: nowrap;
            direction: ltr;
          }

          .tabs-bar {
            display: grid;
            grid-template-columns: 1fr 1fr;
            gap: 6px;
            background: rgba(15, 23, 42, 0.85);
            padding: 4px;
            border-radius: 12px;
            border: 1px solid rgba(255, 255, 255, 0.12);
          }
          .tab-btn {
            background: transparent;
            border: none;
            color: #94a3b8;
            padding: 8px 10px;
            border-radius: 9px;
            font-family: 'Tajawal', sans-serif;
            font-size: 12.5px;
            font-weight: 800;
            cursor: pointer;
            transition: all 0.18s;
            display: flex;
            align-items: center;
            justify-content: center;
            gap: 6px;
          }
          .tab-btn:hover { color: #ffffff; background: rgba(255, 255, 255, 0.06); }
          .tab-btn.active {
            background: linear-gradient(135deg, #0284c7 0%, #1d4ed8 100%);
            color: #ffffff;
            box-shadow: 0 3px 10px rgba(2, 132, 199, 0.35);
          }
          .tab-btn.relief-active {
            background: linear-gradient(135deg, #d97706 0%, #b45309 100%);
            color: #ffffff;
            box-shadow: 0 3px 10px rgba(217, 119, 6, 0.35);
          }

          .toolbar-strip {
            display: flex;
            gap: 8px;
            align-items: center;
          }
          .search-box {
            flex: 1;
            background: rgba(15, 23, 42, 0.85);
            border: 1px solid rgba(255, 255, 255, 0.14);
            border-radius: 10px;
            padding: 8px 12px;
            color: #f8fafc;
            font-family: 'Tajawal', sans-serif;
            font-size: 12.5px;
            outline: none;
          }
          .search-box:focus { border-color: #38bdf8; }
          .quick-grain-btn {
            background: linear-gradient(135deg, #d97706 0%, #b45309 100%);
            border: 1px solid rgba(251, 191, 36, 0.5);
            color: #ffffff;
            border-radius: 10px;
            padding: 8px 11px;
            font-family: 'Tajawal', sans-serif;
            font-size: 12px;
            font-weight: 800;
            cursor: pointer;
            white-space: nowrap;
            transition: all 0.18s;
          }
          .quick-grain-btn.is-active {
            background: linear-gradient(135deg, #059669 0%, #047857 100%);
            border-color: #34d399;
          }

          .fields-scroll {
            flex: 1;
            overflow-y: auto;
            overflow-x: hidden;
            display: flex;
            flex-direction: column;
            gap: 11px;
            padding-left: 4px;
          }
          .fields-scroll::-webkit-scrollbar { width: 6px; }
          .fields-scroll::-webkit-scrollbar-thumb {
            background: rgba(56, 189, 248, 0.35);
            border-radius: 99px;
          }

          .section-card {
            background: rgba(30, 41, 59, 0.65);
            border: 1px solid rgba(255, 255, 255, 0.11);
            border-radius: 14px;
            padding: 12px;
            display: flex;
            flex-direction: column;
            gap: 9px;
          }
          .section-header {
            display: flex;
            align-items: center;
            justify-content: space-between;
            font-size: 13px;
            font-weight: 800;
            color: #38bdf8;
            padding-bottom: 6px;
            border-bottom: 1px solid rgba(255, 255, 255, 0.08);
          }
          .primary-dims-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(120px, 1fr));
            gap: 9px;
          }
          .dim-box {
            background: rgba(15, 23, 42, 0.85);
            border: 1px solid rgba(56, 189, 248, 0.28);
            border-radius: 11px;
            padding: 8px 10px;
            display: flex;
            flex-direction: column;
            gap: 5px;
          }
          .dim-box label {
            font-size: 12px;
            font-weight: 700;
            color: #e2e8f0;
          }
          .input-with-unit {
            position: relative;
            display: flex;
            align-items: center;
          }
          .field-input, .field-select {
            width: 100%;
            background: #0f172a;
            border: 1px solid rgba(148, 163, 184, 0.32);
            border-radius: 9px;
            padding: 7px 10px;
            color: #ffffff;
            font-family: 'Tajawal', sans-serif;
            font-size: 13px;
            font-weight: 700;
            outline: none;
          }
          .field-input:focus, .field-select:focus {
            border-color: #38bdf8;
            box-shadow: 0 0 0 2px rgba(56, 189, 248, 0.2);
          }
          .unit-tag {
            position: absolute;
            left: 8px;
            font-size: 11px;
            font-weight: 800;
            color: #fbbf24;
            pointer-events: none;
          }
          .has-unit .field-input { padding-left: 34px; }

          .option-row {
            display: grid;
            grid-template-columns: 1.15fr 1fr;
            align-items: center;
            gap: 10px;
            padding: 6px 9px;
            border-radius: 10px;
            background: rgba(15, 23, 42, 0.55);
            border: 1px solid rgba(255, 255, 255, 0.06);
          }
          .option-row:hover {
            border-color: rgba(56, 189, 248, 0.3);
            background: rgba(15, 23, 42, 0.8);
          }
          .option-label {
            font-size: 13px !important;
            font-weight: 700 !important;
            color: #f1f5f9 !important;
            line-height: 1.4;
          }
          .readonly-badge {
            background: rgba(255, 255, 255, 0.06);
            border: 1px dashed rgba(255, 255, 255, 0.18);
            border-radius: 8px;
            padding: 6px 10px;
            font-size: 12px;
            font-weight: 700;
            color: #94a3b8;
            text-align: center;
          }

          .grid2 {
            display: grid;
            grid-template-columns: 1fr 1fr;
            gap: 9px;
          }
          .relief-col-card {
            background: rgba(15, 23, 42, 0.82);
            border: 1px solid rgba(251, 191, 36, 0.35);
            border-radius: 12px;
            padding: 10px;
            display: flex;
            flex-direction: column;
            gap: 8px;
          }
          .relief-col-title {
            font-size: 12.5px;
            font-weight: 800;
            color: #fbbf24;
          }
          .relief-svg-box {
            background: #09131c;
            border: 1px solid rgba(56, 189, 248, 0.3);
            border-radius: 12px;
            padding: 8px;
            text-align: center;
          }
          .relief-actions {
            display: flex;
            gap: 8px;
          }
          .btn-apply-relief {
            flex: 1;
            background: linear-gradient(135deg, #d97706 0%, #b45309 100%);
            border: 1px solid #fbbf24;
            color: #fff;
            padding: 9px 12px;
            border-radius: 10px;
            font-family: 'Tajawal', sans-serif;
            font-size: 13px;
            font-weight: 800;
            cursor: pointer;
          }
          .btn-remove-relief {
            background: rgba(239, 68, 68, 0.18);
            border: 1px solid rgba(239, 68, 68, 0.45);
            color: #fca5a5;
            padding: 9px 12px;
            border-radius: 10px;
            font-family: 'Tajawal', sans-serif;
            font-size: 12.5px;
            font-weight: 700;
            cursor: pointer;
          }

          .empty-state {
            flex: 1;
            display: flex;
            flex-direction: column;
            align-items: center;
            justify-content: center;
            text-align: center;
            padding: 30px 20px;
            background: rgba(30, 41, 59, 0.45);
            border: 1px dashed rgba(56, 189, 248, 0.35);
            border-radius: 16px;
            color: #cbd5e1;
            gap: 10px;
          }

          .footer-panel {
            background: rgba(15, 23, 42, 0.92);
            border: 1px solid rgba(255, 255, 255, 0.12);
            border-radius: 14px;
            padding: 10px 12px;
            display: flex;
            flex-direction: column;
            gap: 8px;
          }
          .auto-open-row {
            display: flex;
            align-items: center;
            justify-content: space-between;
            font-size: 11.5px;
            color: #cbd5e1;
          }
          .footer-actions {
            display: flex;
            gap: 8px;
          }
          .apply-btn {
            flex: 1;
            background: linear-gradient(135deg, #0284c7 0%, #0369a1 100%);
            border: 1px solid rgba(56, 189, 248, 0.6);
            color: #ffffff;
            padding: 10px 16px;
            border-radius: 10px;
            font-family: 'Tajawal', sans-serif;
            font-size: 14px;
            font-weight: 800;
            cursor: pointer;
          }
          .refresh-btn {
            background: rgba(255, 255, 255, 0.08);
            border: 1px solid rgba(255, 255, 255, 0.18);
            color: #f8fafc;
            padding: 10px 13px;
            border-radius: 10px;
            font-family: 'Tajawal', sans-serif;
            font-size: 13px;
            font-weight: 700;
            cursor: pointer;
          }
        </style>
      </head>
      <body oncontextmenu="return false;">
        <div class="app-wrap">
          <div class="hero-card">
            <div class="hero-right">
              <div class="hero-badge">⚙️</div>
              <div class="hero-titles">
                <div class="hero-brand">مكتبة محمد عادل الذكية</div>
                <div class="hero-unit-name" id="unitTitle">خيارات الوحدة</div>
              </div>
            </div>
            <div class="dims-pill" id="unitDimsBadge">-- × -- × -- سم</div>
          </div>

          <div class="tabs-bar">
            <button type="button" id="tabBtnOptions" class="tab-btn active" onclick="switchUnitTab('options')">
              📐 مقاسات وخيارات الوحدة
            </button>
            <button type="button" id="tabBtnRelief" class="tab-btn" onclick="switchUnitTab('relief')">
              🧱 الخلع والعمود (خلعة الحائط)
            </button>
          </div>

          <div class="toolbar-strip" id="optionsSearchStrip">
            <input type="text" id="filterInput" class="search-box" placeholder="🔍 ابحث في خيارات الوحدة..." oninput="renderFields()">
            <button type="button" id="grainToggleBtn" class="quick-grain-btn" onclick="alignUnitGrainZ()" title="ضبط اتجاه الثمرة بالطول (Z) أو إرجاعها للوضع الأصلي عند الضغط مرة ثانية">
              🪵↕ الثمرة بالطول (Z)
            </button>
          </div>

          <div class="fields-scroll" id="fieldsContainer"></div>
          <div class="fields-scroll" id="reliefContainer" style="display:none;"></div>

          <div class="footer-panel" id="optionsFooterPanel">
            <label class="auto-open-row">
              <span>فتح نافذة خيارات الوحدة تلقائياً فور وضع أي وحدة مطبخ</span>
              <input type="checkbox" id="autoOpenCheck" onchange="toggleAutoOpen(this.checked)">
            </label>
            <div class="footer-actions">
              <button type="button" class="apply-btn" onclick="submitChanges()">✨ تطبيق التعديلات على الوحدة</button>
              <button type="button" class="refresh-btn" onclick="requestRefresh()" title="قراءة الوحدة المحددة حالياً">🔄</button>
            </div>
          </div>
        </div>

        <script>
          let currentPayload = #{initial_payload};
          let editedValues = {};
          let activeTab = 'options';
          let wallReliefState = { enabled: 'no', wall_width: 240, placement: 'right', cabinet_offset: 0, columns: [] };

          function esc(s) {
            return String(s == null ? '' : s)
              .replace(/&/g, '&amp;')
              .replace(/</g, '&lt;')
              .replace(/>/g, '&gt;')
              .replace(/"/g, '&quot;');
          }

          function cleanLabelJS(raw) {
            return String(raw == null ? '' : raw)
              .replace(/<[^>]*>/g, ' ')
              .replace(/\b(?:font-size|font-family|font-weight|color|size|face|style)\s*=\s*["']?[^"'\s>]+["']?/gi, ' ')
              .replace(/\s+/g, ' ')
              .trim();
          }

          function switchUnitTab(tab) {
            activeTab = (tab === 'relief') ? 'relief' : 'options';
            document.getElementById('tabBtnOptions').className = 'tab-btn' + (activeTab === 'options' ? ' active' : '');
            document.getElementById('tabBtnRelief').className  = 'tab-btn' + (activeTab === 'relief' ? ' relief-active' : '');
            document.getElementById('optionsSearchStrip').style.display = (activeTab === 'options') ? 'flex' : 'none';
            document.getElementById('fieldsContainer').style.display    = (activeTab === 'options') ? 'flex' : 'none';
            document.getElementById('optionsFooterPanel').style.display = (activeTab === 'options') ? 'flex' : 'none';
            document.getElementById('reliefContainer').style.display    = (activeTab === 'relief')  ? 'flex' : 'none';
            if (activeTab === 'relief') {
              renderReliefTab();
            } else {
              renderFields();
            }
          }

          window.receiveUnitPayload = function(payload) {
            currentPayload = payload || { has_unit: false };
            editedValues = {};
            const autoChk = document.getElementById('autoOpenCheck');
            if (autoChk && currentPayload.auto_open !== undefined) {
              autoChk.checked = !!currentPayload.auto_open;
            }
            const gBtn = document.getElementById('grainToggleBtn');
            if (gBtn) {
              if (currentPayload.grain_z_active) {
                gBtn.classList.add('is-active');
                gBtn.textContent = '↩️ إرجاع الثمرة للأصل';
              } else {
                gBtn.classList.remove('is-active');
                gBtn.textContent = '🪵↕ الثمرة بالطول (Z)';
              }
            }
            const cabW = Number(currentPayload.bbox_w_cm || 60);
            const wr = currentPayload.wall_relief || {};
            wallReliefState = {
              enabled: wr.enabled || 'no',
              wall_width: Math.max(cabW, Number(wr.wall_width || Math.max(cabW, 240))),
              placement: wr.placement === 'left' ? 'left' : 'right',
              cabinet_offset: Math.max(0, Number(wr.cabinet_offset || 0)),
              columns: Array.isArray(wr.columns) && wr.columns.length > 0
                ? wr.columns
                : [{ side: 'right', distance: 0, width: 25, depth: 15, mode: 'depth_avoid' }]
            };
            if (activeTab === 'relief') {
              renderReliefTab();
            } else {
              renderFields();
            }
          };

          function onFieldInput(key, val) {
            editedValues[key] = val;
          }

          function renderFields() {
            const container = document.getElementById('fieldsContainer');
            const titleEl   = document.getElementById('unitTitle');
            const badgeEl   = document.getElementById('unitDimsBadge');
            const q         = (document.getElementById('filterInput').value || '').trim().toLowerCase();

            if (!currentPayload || !currentPayload.has_unit) {
              titleEl.textContent = 'لم يتم تحديد وحدة';
              badgeEl.textContent = '-- × -- × -- سم';
              container.innerHTML = `
                <div class="empty-state">
                  <div style="font-size:36px;">📦</div>
                  <div style="font-size:15px;font-weight:800;color:#fff;">حدد أي وحدة مطبخ في سكتش أب</div>
                  <div style="font-size:12.5px;line-height:1.6;">بمجرد تحديد أي وحدة ديناميكية في المشهد ستظهر لك هنا جميع مقاساتها وخياراتها وإعدادات الخلع والعمود.</div>
                </div>
              `;
              return;
            }

            titleEl.textContent = cleanLabelJS(currentPayload.unit_name || 'وحدة مطبخ');
            badgeEl.textContent = `${currentPayload.bbox_w_cm} × ${currentPayload.bbox_d_cm} × ${currentPayload.bbox_h_cm} سم`;

            const allFields = Array.isArray(currentPayload.fields) ? currentPayload.fields : [];
            const filtered = allFields.filter(f => {
              if (!q) return true;
              return cleanLabelJS(f.label).toLowerCase().includes(q) || String(f.key || '').toLowerCase().includes(q);
            });

            if (filtered.length === 0) {
              container.innerHTML = `
                <div class="empty-state">
                  <div style="font-size:14px;font-weight:700;">لا توجد خيارات مطابقة للبحث في هذه الوحدة.</div>
                </div>
              `;
              return;
            }

            const primaryDims = filtered.filter(f => f.is_primary_dim);
            const otherFields = filtered.filter(f => !f.is_primary_dim);

            let html = '';

            if (primaryDims.length > 0) {
              html += `
                <div class="section-card">
                  <div class="section-header">
                    <span>📐 المقاسات الأساسية للوحدة</span>
                    <span style="font-size:11px;color:#fbbf24;">بالسنتيمتر</span>
                  </div>
                  <div class="primary-dims-grid">
                    ${primaryDims.map(f => renderPrimaryDimBox(f)).join('')}
                  </div>
                </div>
              `;
            }

            if (otherFields.length > 0) {
              html += `
                <div class="section-card">
                  <div class="section-header">
                    <span>🛠️ خصائص وخيارات الوحدة (${otherFields.length})</span>
                    <span style="font-size:11px;color:#94a3b8;">مسميات نظيفة وموحدة</span>
                  </div>
                  ${otherFields.map(f => renderOptionRow(f)).join('')}
                </div>
              `;
            }

            container.innerHTML = html;
          }

          function currentValFor(f) {
            return Object.prototype.hasOwnProperty.call(editedValues, f.key) ? editedValues[f.key] : f.value;
          }

          function renderControlHtml(f) {
            const val = currentValFor(f);
            if (f.access === 'VIEW') {
              return `<div class="readonly-badge">${esc(cleanLabelJS(val))} ${esc(f.unit_badge || '')}</div>`;
            }
            if (f.access === 'LIST' && Array.isArray(f.options) && f.options.length > 0) {
              return `
                <select class="field-select" data-key="${esc(f.key)}" onchange="onFieldInput('${esc(f.key)}', this.value)">
                  ${f.options.map(o => {
                    const sel = String(o.value).trim() === String(val).trim() ? 'selected' : '';
                    return `<option value="${esc(o.value)}" ${sel}>${esc(cleanLabelJS(o.label))}</option>`;
                  }).join('')}
                </select>
              `;
            }
            const hasUnit = f.unit_badge && f.unit_badge.length > 0;
            return `
              <div class="input-with-unit ${hasUnit ? 'has-unit' : ''}">
                <input type="text" class="field-input" data-key="${esc(f.key)}" value="${esc(val)}"
                       oninput="onFieldInput('${esc(f.key)}', this.value)"
                       onkeydown="if(event.key==='Enter'){submitChanges();}">
                ${hasUnit ? `<span class="unit-tag">${esc(f.unit_badge)}</span>` : ''}
              </div>
            `;
          }

          function renderPrimaryDimBox(f) {
            return `
              <div class="dim-box">
                <label>${esc(cleanLabelJS(f.label))}</label>
                ${renderControlHtml(f)}
              </div>
            `;
          }

          function renderOptionRow(f) {
            return `
              <div class="option-row">
                <div class="option-label">${esc(cleanLabelJS(f.label))}</div>
                <div>${renderControlHtml(f)}</div>
              </div>
            `;
          }

          function renderReliefTab() {
            const box = document.getElementById('reliefContainer');
            if (!currentPayload || !currentPayload.has_unit) {
              box.innerHTML = `<div class="empty-state">حدد وحدة مطبخ في سكتش أب لإعداد الخلع والعمود لها.</div>`;
              return;
            }
            const cabW = Number(currentPayload.bbox_w_cm || 60);
            const cols = wallReliefState.columns || [];

            box.innerHTML = `
              <div class="section-card">
                <div class="section-header">
                  <span>🧱 إعدادات الحائط وموقع الوحدة</span>
                  <span style="font-size:11px;color:#fbbf24;">نفس نظام خلع الدريسنج</span>
                </div>
                <div class="grid2">
                  <div class="dim-box">
                    <label>عرض الحائط الكلي (سم)</label>
                    <input type="number" id="wrWallWidth" class="field-input" min="${cabW}" step="1" value="${wallReliefState.wall_width}" oninput="syncReliefFromDOM()">
                  </div>
                  <div class="dim-box">
                    <label>جهة قياس موقع الوحدة</label>
                    <select id="wrPlacement" class="field-select" onchange="syncReliefFromDOM()">
                      <option value="right" ${wallReliefState.placement === 'right' ? 'selected' : ''}>من جهة اليمين</option>
                      <option value="left" ${wallReliefState.placement === 'left' ? 'selected' : ''}>من جهة الشمال</option>
                    </select>
                  </div>
                  <div class="dim-box">
                    <label>المسافة قبل الوحدة (سم)</label>
                    <input type="number" id="wrCabOffset" class="field-input" min="0" step="0.5" value="${wallReliefState.cabinet_offset}" oninput="syncReliefFromDOM()">
                  </div>
                  <div class="dim-box">
                    <label>عدد أعمدة الحائط</label>
                    <input type="number" id="wrColCount" class="field-input" min="1" max="6" step="1" value="${cols.length || 1}" oninput="changeReliefColCount(this.value)">
                  </div>
                </div>
              </div>

              <div id="wrColumnsList" style="display:flex;flex-direction:column;gap:9px;"></div>

              <div class="section-card">
                <div class="section-header">
                  <span>📐 معاينة تخطيطية للعمود والوحدة (مسقط أفقي)</span>
                  <span id="wrOverlapBadge" style="font-size:11px;color:#4ade80;"></span>
                </div>
                <div class="relief-svg-box">
                  <svg id="wrPreviewSvg" viewBox="0 0 440 145" width="100%" height="145"></svg>
                </div>
                <div class="relief-actions">
                  <button type="button" class="btn-apply-relief" onclick="submitWallRelief()">✨ تطبيق الخلع والعمود على الوحدة</button>
                  <button type="button" class="btn-remove-relief" onclick="removeWallRelief()">🗑️ إلغاء الخلع</button>
                </div>
              </div>
            `;

            renderReliefColumnCards();
            updateReliefSvgPreview();
          }

          function renderReliefColumnCards() {
            const listEl = document.getElementById('wrColumnsList');
            if (!listEl) return;
            const cols = wallReliefState.columns || [];
            listEl.innerHTML = cols.map((c, i) => `
              <div class="relief-col-card">
                <div class="relief-col-title">📌 عمود الحائط رقم (${i + 1})</div>
                <div class="grid2">
                  <div class="dim-box">
                    <label>جهة قياس العمود</label>
                    <select class="field-select wr-col-side" onchange="syncReliefFromDOM()">
                      <option value="right" ${(c.side || 'right') === 'right' ? 'selected' : ''}>من جهة اليمين</option>
                      <option value="left" ${c.side === 'left' ? 'selected' : ''}>من جهة الشمال</option>
                    </select>
                  </div>
                  <div class="dim-box">
                    <label>المسافة من الجهة (سم)</label>
                    <input type="number" class="field-input wr-col-dist" min="0" step="0.5" value="${Number(c.distance || 0)}" oninput="syncReliefFromDOM()">
                  </div>
                  <div class="dim-box">
                    <label>عرض العمود (سم)</label>
                    <input type="number" class="field-input wr-col-width" min="1" step="0.5" value="${Number(c.width || 25)}" oninput="syncReliefFromDOM()">
                  </div>
                  <div class="dim-box">
                    <label>بروز العمود (سم)</label>
                    <input type="number" class="field-input wr-col-depth" min="1" step="0.5" value="${Number(c.depth || 15)}" oninput="syncReliefFromDOM()">
                  </div>
                </div>
                <div class="dim-box">
                  <label>طريقة معالجة الخلعة في الوحدة</label>
                  <select class="field-select wr-col-mode" onchange="syncReliefFromDOM()">
                    <option value="depth_avoid" ${(c.mode || 'depth_avoid') === 'depth_avoid' ? 'selected' : ''}>تفاديها بدخول العمق (تقليل عمق الوحدة أمام العمود)</option>
                    <option value="true_notch" ${c.mode === 'true_notch' ? 'selected' : ''}>خلع حقيقي + تجليد العمود بكونتر داخل الوحدة</option>
                  </select>
                </div>
              </div>
            `).join('');
          }

          function changeReliefColCount(val) {
            const count = Math.max(1, Math.min(6, parseInt(val || '1', 10) || 1));
            const cur = wallReliefState.columns || [];
            const next = [];
            for (let i = 0; i < count; i++) {
              next.push(cur[i] || { side: 'right', distance: i * 40, width: 25, depth: 15, mode: 'depth_avoid' });
            }
            wallReliefState.columns = next;
            renderReliefColumnCards();
            updateReliefSvgPreview();
          }

          function syncReliefFromDOM() {
            const cabW = Number((currentPayload && currentPayload.bbox_w_cm) || 60);
            const wEl = document.getElementById('wrWallWidth');
            const pEl = document.getElementById('wrPlacement');
            const oEl = document.getElementById('wrCabOffset');
            if (wEl) wallReliefState.wall_width = Math.max(cabW, parseFloat(wEl.value || cabW) || cabW);
            if (pEl) wallReliefState.placement  = (pEl.value === 'left') ? 'left' : 'right';
            if (oEl) wallReliefState.cabinet_offset = Math.max(0, parseFloat(oEl.value || '0') || 0);

            const cards = document.querySelectorAll('#wrColumnsList .relief-col-card');
            if (cards.length > 0) {
              wallReliefState.columns = Array.from(cards).map(card => ({
                side: card.querySelector('.wr-col-side').value === 'left' ? 'left' : 'right',
                distance: Math.max(0, parseFloat(card.querySelector('.wr-col-dist').value || '0') || 0),
                width: Math.max(1, parseFloat(card.querySelector('.wr-col-width').value || '20') || 20),
                depth: Math.max(1, parseFloat(card.querySelector('.wr-col-depth').value || '15') || 15),
                mode: card.querySelector('.wr-col-mode').value === 'true_notch' ? 'true_notch' : 'depth_avoid'
              }));
            }
            updateReliefSvgPreview();
          }

          function updateReliefSvgPreview() {
            const svg = document.getElementById('wrPreviewSvg');
            const badge = document.getElementById('wrOverlapBadge');
            if (!svg || !currentPayload || !currentPayload.has_unit) return;

            const cabW = Math.max(10, Number(currentPayload.bbox_w_cm || 60));
            const W    = Math.max(cabW, Number(wallReliefState.wall_width || cabW));
            const sx   = 380 / W;
            const x0   = 30;
            const baseY = 26;

            const cabStart = (wallReliefState.placement === 'right')
              ? Math.max(0, W - wallReliefState.cabinet_offset - cabW)
              : Math.min(wallReliefState.cabinet_offset, Math.max(0, W - cabW));

            let out = `<line x1="${x0}" y1="${baseY}" x2="${x0 + 380}" y2="${baseY}" stroke="#38bdf8" stroke-width="3"/>`;
            let hitCount = 0;

            (wallReliefState.columns || []).forEach((c, i) => {
              const colLeft = (c.side === 'right') ? (W - c.distance - c.width) : c.distance;
              const cx = x0 + Math.max(0, colLeft) * sx;
              const cw = Math.max(4, c.width * sx);
              const dep = Math.min(55, Math.max(12, c.depth * 1.6));
              const ov0 = Math.max(colLeft, cabStart);
              const ov1 = Math.min(colLeft + c.width, cabStart + cabW);
              if (ov1 - ov0 > 0.3) hitCount++;

              out += `<rect x="${cx}" y="${baseY}" width="${cw}" height="${dep}" fill="rgba(245,158,11,0.38)" stroke="#fbbf24" stroke-width="2"/>`;
              out += `<text x="${cx + cw / 2}" y="${baseY + dep + 13}" fill="#fde68a" font-size="10" text-anchor="middle">عمود ${i + 1} (${c.width}×${c.depth})</text>`;
            });

            const cabX = x0 + cabStart * sx;
            const cabPxW = Math.max(12, cabW * sx);
            out += `<rect x="${cabX}" y="${baseY}" width="${cabPxW}" height="76" fill="rgba(34,197,94,0.12)" stroke="#4ade80" stroke-width="2.2" stroke-dasharray="6 4"/>`;
            out += `<text x="${cabX + cabPxW / 2}" y="${baseY + 95}" fill="#4ade80" font-size="11" font-weight="bold" text-anchor="middle">الوحدة (${cabW} سم)</text>`;

            svg.innerHTML = out;
            if (badge) {
              badge.textContent = hitCount > 0 ? `يتقاطع مع ${hitCount} عمود` : 'لا يوجد تقاطع حالياً';
              badge.style.color = hitCount > 0 ? '#4ade80' : '#fbbf24';
            }
          }

          function submitWallRelief() {
            syncReliefFromDOM();
            wallReliefState.enabled = 'yes';
            if (window.sketchup && window.sketchup.apply_wall_relief) {
              window.sketchup.apply_wall_relief(JSON.stringify(wallReliefState));
            }
          }

          function removeWallRelief() {
            if (window.sketchup && window.sketchup.remove_wall_relief) {
              window.sketchup.remove_wall_relief();
            }
          }

          function submitChanges() {
            if (!currentPayload || !currentPayload.has_unit) return;
            const keys = Object.keys(editedValues);
            if (keys.length === 0) {
              return;
            }
            if (window.sketchup && window.sketchup.apply_unit_options) {
              window.sketchup.apply_unit_options(JSON.stringify(editedValues));
            }
          }

          function requestRefresh() {
            if (window.sketchup && window.sketchup.refresh_unit_options) {
              window.sketchup.refresh_unit_options();
            }
          }

          function alignUnitGrainZ() {
            if (window.sketchup && window.sketchup.align_unit_grain_z) {
              window.sketchup.align_unit_grain_z();
            }
          }

          function toggleAutoOpen(checked) {
            if (window.sketchup && window.sketchup.set_auto_open) {
              window.sketchup.set_auto_open(checked ? '1' : '0');
            }
          }

          window.receiveUnitPayload(currentPayload);
        </script>
      </body>
      </html>
    HTML

    @unit_options_dlg.set_html(html)

    @unit_options_dlg.add_action_callback('apply_unit_options') do |_ctx, json_str|
      changes = JSON.parse(json_str.to_s) rescue {}
      apply_unit_dc_options_changes!(changes, true)
    end

    @unit_options_dlg.add_action_callback('refresh_unit_options') do |_ctx|
      refresh_unit_options_dialog_if_open
    end

    @unit_options_dlg.add_action_callback('align_unit_grain_z') do |_ctx|
      DolaWoodGrainManager.align_all_wood_grain_to_z!
    end

    @unit_options_dlg.add_action_callback('set_auto_open') do |_ctx, val|
      set_auto_open_options_enabled(val.to_s == '1')
    end

    @unit_options_dlg.add_action_callback('apply_wall_relief') do |_ctx, json_str|
      cfg = JSON.parse(json_str.to_s) rescue {}
      apply_kitchen_unit_wall_relief!(cfg)
    end

    @unit_options_dlg.add_action_callback('remove_wall_relief') do |_ctx|
      unit = find_selected_dc_unit
      remove_kitchen_unit_wall_relief!(unit) if unit
    end

    @unit_options_dlg.show
    true
  rescue => e
    UI.messagebox("تعذر فتح نافذة خيارات الوحدة:\n#{e.message}")
    false
  end

  def self.open_options_protected
    open_unit_options_dialog
  end

  def self.open_options_automatically(instance)
    return false unless auto_open_options_enabled?
    return false unless instance && instance.valid?
    open_unit_options_dialog(instance)
  rescue
    false
  end

  # ============================================================================
  #  مراقب وضع الوحدات في المشهد (PlaceAndUnwrapObserver)
  # ============================================================================
  class PlaceAndUnwrapObserver < Sketchup::EntitiesObserver
    def initialize(target_def, comp_data = nil)
      @target_def = target_def
      @comp_data  = comp_data
      @done       = false
    end

    def onElementAdded(entities, entity)
      return if @done
      return unless entity.is_a?(Sketchup::ComponentInstance)
      return unless entity.definition == @target_def

      @done = true
      model = Sketchup.active_model

      UI.start_timer(0.05, false) do
        begin
          inst2 = DolaSmartLibraryPlugin.unwrap_to_dynamic!(entity)
          if inst2 && inst2.valid?
            model.selection.clear
            model.selection.add(inst2)
            UI.start_timer(0.15, false) do
              DolaSmartLibraryPlugin.open_options_automatically(inst2) if inst2 && inst2.valid?
            end
          end
        rescue
        ensure
          begin
            entities.remove_observer(self)
          rescue
          end
        end
      end
    end
  end

  def self.install_place_observer_for(definition, comp_data = nil)
    ents = Sketchup.active_model.active_entities
    obs = PlaceAndUnwrapObserver.new(definition, comp_data)
    ents.add_observer(obs)
    UI.start_timer(25.0, false) do
      begin
        ents.remove_observer(obs)
      rescue
      end
    end
  rescue
    false
  end

  # ============================================================================
  #  الأدوات المساعدة الـ 11 كاملة بهوية «مكتبة محمد عادل»
  # ============================================================================

  # 1) جعل كل الكمبوننتات فريدة (Make Unique)
  module MHDESIGN_UNIQUIFY
    def self.make_all_components_unique(entities)
      entities.grep(Sketchup::ComponentInstance).each do |instance|
        next unless instance.valid?
        instance.make_unique if instance.definition.count_used_instances > 1
        make_all_components_unique(instance.definition.entities)
      end
    end

    def self.run_uniquify
      model = Sketchup.active_model
      targets = model.selection.grep(Sketchup::ComponentInstance)
      targets = model.active_entities.grep(Sketchup::ComponentInstance) if targets.empty?

      if targets.empty?
        UI.messagebox('لا توجد كمبوننتات في المشهد حالياً.')
        return false
      end

      model.start_operation('جعل كل الكمبوننتات فريدة - مكتبة محمد عادل', true)
      begin
        targets.each do |inst|
          next unless inst.valid?
          inst.make_unique if inst.definition.count_used_instances > 1
          make_all_components_unique(inst.definition.entities)
        end
        model.commit_operation
        UI.messagebox("✅ تم جعل (#{targets.length}) وحدة وجميع قطعها الفرعية فريدة ومستقلة بنجاح.")
      rescue => e
        model.abort_operation rescue nil
        UI.messagebox("حدث خطأ: #{e.message}")
      end
    end
  end

  # 2) أداة التدوير 45 درجة (Rotate 45 Tool) مع مؤشر بصري
  class MHDRotate90Tool
    def activate
      @hovered = nil
      Sketchup.status_text = '↻ أداة التدوير 45°: اضغط كليك شمال على أي وحدة لتدويرها 45 درجة حول مركزها.'
    end

    def deactivate(view)
      @hovered = nil
      view.invalidate if view
    end

    def onMouseMove(_flags, x, y, view)
      ph = view.pick_helper
      ph.do_pick(x, y)
      ent = ph.best_picked
      @hovered = (ent.is_a?(Sketchup::ComponentInstance) || ent.is_a?(Sketchup::Group)) ? ent : nil
      view.invalidate
    end

    def onLButtonDown(_flags, x, y, view)
      model = Sketchup.active_model
      ph = view.pick_helper
      ph.do_pick(x, y)
      ent = ph.best_picked
      return unless ent.is_a?(Sketchup::ComponentInstance) || ent.is_a?(Sketchup::Group)

      model.start_operation('تدوير الوحدة 45° - مكتبة محمد عادل', true)
      begin
        center = ent.bounds.center
        axis   = Geom::Vector3d.new(0, 0, 1)
        tr     = Geom::Transformation.rotation(center, axis, 45.degrees)
        ent.transform!(tr)
      ensure
        model.commit_operation
      end
      view.invalidate
    end

    def draw(view)
      return unless @hovered && @hovered.valid?
      bb = @hovered.bounds
      pts = (0..7).map { |i| bb.corner(i) }
      edges = [0,1, 1,3, 3,2, 2,0, 4,5, 5,7, 7,6, 6,4, 0,4, 1,5, 2,6, 3,7]
      view.line_width = 3
      view.drawing_color = Sketchup::Color.new(56, 189, 248)
      view.draw(GL_LINES, edges.map { |i| pts[i] })
    rescue
    end
  end

  def self.activate_rotate_tool
    Sketchup.active_model.select_tool(MHDRotate90Tool.new)
  end

  # 3) أداة القلب يمين / شمال (Flip L/R Tool) مع مؤشر بصري
  class MHDFlipLRTool
    def activate
      @hovered = nil
      Sketchup.status_text = '⇆ أداة القلب يمين/شمال: اضغط كليك شمال على أي وحدة لقلبها يميناً ويساراً.'
    end

    def deactivate(view)
      @hovered = nil
      view.invalidate if view
    end

    def onMouseMove(_flags, x, y, view)
      ph = view.pick_helper
      ph.do_pick(x, y)
      ent = ph.best_picked
      @hovered = (ent.is_a?(Sketchup::ComponentInstance) || ent.is_a?(Sketchup::Group)) ? ent : nil
      view.invalidate
    end

    def onLButtonDown(_flags, x, y, view)
      model = Sketchup.active_model
      ph = view.pick_helper
      ph.do_pick(x, y)
      ent = ph.best_picked
      return unless ent.is_a?(Sketchup::ComponentInstance) || ent.is_a?(Sketchup::Group)

      model.start_operation('قلب الوحدة يمين/شمال - مكتبة محمد عادل', true)
      begin
        tr = ent.transformation
        center = ent.bounds.center
        basis = Geom::Transformation.axes(center, tr.xaxis, tr.yaxis, tr.zaxis)
        mirror_local = Geom::Transformation.scaling(-1, 1, 1)
        ent.transform!(basis * mirror_local * basis.inverse)
      ensure
        model.commit_operation
      end
      view.invalidate
    end

    def draw(view)
      return unless @hovered && @hovered.valid?
      bb = @hovered.bounds
      pts = (0..7).map { |i| bb.corner(i) }
      edges = [0,1, 1,3, 3,2, 2,0, 4,5, 5,7, 7,6, 6,4, 0,4, 1,5, 2,6, 3,7]
      view.line_width = 3
      view.drawing_color = Sketchup::Color.new(251, 191, 36)
      view.draw(GL_LINES, edges.map { |i| pts[i] })
    rescue
    end
  end

  def self.activate_flip_lr_tool
    Sketchup.active_model.select_tool(MHDFlipLRTool.new)
  end

  # 4) أداة اللزق جنب بجنب (Click Side Snap Tool)
  class DolaClickSideSnapTool
    def initialize
      @moving_unit = nil
      @target_unit = nil
      @snap_side   = :right
    end

    def activate
      sel = Sketchup.active_model.selection.find { |e| e.is_a?(Sketchup::ComponentInstance) || e.is_a?(Sketchup::Group) }
      @moving_unit = sel
      if @moving_unit
        Sketchup.status_text = '🧲 أداة اللزق الجنب بالجنب: تم اختيار الوحدة المتحركة — اضغط الآن على الجانب الأيمن أو الأيسر للوحدة الثابتة المراد اللزق بجانبها.'
      else
        Sketchup.status_text = '🧲 أداة اللزق الجنب بالجنب: الخطوة 1 — اضغط كليك شمال على الوحدة التي تريد تحريكها.'
      end
    end

    def deactivate(view)
      @moving_unit = nil
      @target_unit = nil
      view.invalidate if view
    end

    def onCancel(_reason, view)
      @moving_unit = nil
      @target_unit = nil
      Sketchup.active_model.select_tool(nil)
      view.invalidate if view
    end

    def onMouseMove(_flags, x, y, view)
      ph = view.pick_helper
      ph.do_pick(x, y)
      picked = ph.best_picked
      if picked && (picked.is_a?(Sketchup::ComponentInstance) || picked.is_a?(Sketchup::Group)) && picked != @moving_unit
        @target_unit = picked
        ip = Sketchup::InputPoint.new
        ip.pick(view, x, y)
        if ip.valid?
          pt = ip.position
          center = picked.bounds.center
          xaxis = picked.transformation.xaxis
          vec = pt - center
          @snap_side = (vec.dot(xaxis) >= 0) ? :right : :left
        end
      else
        @target_unit = nil
      end
      view.invalidate
    end

    def onLButtonDown(_flags, x, y, view)
      ph = view.pick_helper
      ph.do_pick(x, y)
      picked = ph.best_picked
      return unless picked.is_a?(Sketchup::ComponentInstance) || picked.is_a?(Sketchup::Group)

      if @moving_unit.nil? || !@moving_unit.valid?
        @moving_unit = picked
        Sketchup.active_model.selection.clear
        Sketchup.active_model.selection.add(@moving_unit)
        Sketchup.status_text = '🧲 الخطوة 2 — اضغط الآن على الجانب الأيمن أو الأيسر للوحدة الثابتة المراد اللزق بجانبها.'
        view.invalidate
        return
      end

      return if picked == @moving_unit
      snap_unit_next_to!(@moving_unit, picked, @snap_side)
      @moving_unit = nil
      @target_unit = nil
      Sketchup.status_text = '✅ تم لزق ومحاذاة الوحدة بنجاح! اضغط على وحدة جديدة لتحريكها أو Esc للخروج.'
      view.invalidate
    end

    def snap_unit_next_to!(moving, target, side)
      model = Sketchup.active_model
      model.start_operation('لزق وحدة جنب بجنب - مكتبة محمد عادل', true)
      begin
        t_tr = target.transformation
        ux = t_tr.xaxis.clone; ux.normalize!
        uy = t_tr.yaxis.clone; uy.normalize!
        uz = t_tr.zaxis.clone; uz.normalize!

        # تدوير الوحدة المتحركة لتأخذ نفس اتجاه زاوية الوحدة الهدف أولاً
        m_center = moving.bounds.center
        m_tr = moving.transformation
        mx = m_tr.xaxis.clone; mx.normalize!
        my = m_tr.yaxis.clone; my.normalize!
        mz = m_tr.zaxis.clone; mz.normalize!

        from_axes = Geom::Transformation.axes(m_center, mx, my, mz)
        to_axes   = Geom::Transformation.axes(m_center, ux, uy, uz)
        moving.transform!(to_axes * from_axes.inverse)

        # حساب الحدود على محاور الوحدة الهدف
        project_bounds = lambda do |ent|
          bb = ent.bounds
          pts = (0..7).map { |i| bb.corner(i) }
          xs = pts.map { |p| (p - t_tr.origin).dot(ux) }
          ys = pts.map { |p| (p - t_tr.origin).dot(uy) }
          zs = pts.map { |p| (p - t_tr.origin).dot(uz) }
          {
            :min_x => xs.min, :max_x => xs.max,
            :min_y => ys.min, :max_y => ys.max,
            :min_z => zs.min, :max_z => zs.max
          }
        end

        tb = project_bounds.call(target)
        mb = project_bounds.call(moving)

        dx = (side == :right) ? (tb[:max_x] - mb[:min_x]) : (tb[:min_x] - mb[:max_x])
        # محاذاة الظهر والارتفاع السفلي مع الوحدة الهدف
        dy = tb[:min_y] - mb[:min_y]
        dz = tb[:min_z] - mb[:min_z]

        move_vec = Geom::Vector3d.new(
          ux.x * dx + uy.x * dy + uz.x * dz,
          ux.y * dx + uy.y * dy + uz.y * dz,
          ux.z * dx + uy.z * dy + uz.z * dz
        )
        moving.transform!(Geom::Transformation.translation(move_vec))
      ensure
        model.commit_operation
      end
    end

    def draw(view)
      if @moving_unit && @moving_unit.valid?
        bb = @moving_unit.bounds
        pts = (0..7).map { |i| bb.corner(i) }
        edges = [0,1, 1,3, 3,2, 2,0, 4,5, 5,7, 7,6, 6,4, 0,4, 1,5, 2,6, 3,7]
        view.line_width = 3
        view.drawing_color = Sketchup::Color.new(56, 189, 248)
        view.draw(GL_LINES, edges.map { |i| pts[i] })
      end
      if @target_unit && @target_unit.valid?
        bb = @target_unit.bounds
        pts = (0..7).map { |i| bb.corner(i) }
        edges = [0,1, 1,3, 3,2, 2,0, 4,5, 5,7, 7,6, 6,4, 0,4, 1,5, 2,6, 3,7]
        view.line_width = 3
        view.drawing_color = Sketchup::Color.new(16, 185, 129)
        view.draw(GL_LINES, edges.map { |i| pts[i] })
      end
    rescue
    end
  end

  def self.activate_click_side_snap_tool
    Sketchup.active_model.select_tool(DolaClickSideSnapTool.new)
  end

  # 5) أداة ترجمة وتعريب أسماء القطع الداخلية للـ Cutting List
  ARABIC_PART_DICTIONARY = {
    'right_side'   => 'جنب يمين',
    'left_side'    => 'جنب شمال',
    'side_r'       => 'جنب يمين',
    'side_l'       => 'جنب شمال',
    'side'         => 'جنب',
    'top'          => 'سقف / برنيطة',
    'bottom'       => 'قاعدة',
    'base'         => 'قاعدة',
    'shelf'        => 'رف',
    'shelves'      => 'رف',
    'door_r'       => 'ضلفة يمين',
    'door_l'       => 'ضلفة شمال',
    'door'         => 'ضلفة',
    'back'         => 'ضهر',
    'back_panel'   => 'ضهر',
    'drawer_front' => 'وش درج',
    'drawer_side'  => 'جنب درج',
    'drawer_back'  => 'ضهر درج',
    'drawer_bot'   => 'قاع درج',
    'drawer'       => 'درج',
    'partition'    => 'قاطوع',
    'divider'      => 'قاطوع',
    'upright'      => 'قائم رأسي',
    'rail'         => 'مرايا / عارضة',
    'stretcher'    => 'مرايا تجميع',
    'plinth'       => 'وزرة',
    'toekick'      => 'وزرة',
    'filler'       => 'سدة / فيلر',
    'cladding'     => 'تجليدة',
    'panel'        => 'لوح',
    'frame'        => 'إطار / شاسيه'
  }.freeze

  def self.run_arabic_part_translator
    model = Sketchup.active_model
    roots = model.selection.to_a.select { |e| e.is_a?(Sketchup::ComponentInstance) || e.is_a?(Sketchup::Group) }
    if roots.empty?
      UI.messagebox('الرجاء تحديد الوحدة أو الوحدات المطلوب ترجمة أسماء قطعها أولاً.')
      return false
    end

    count = 0
    model.start_operation('ترجمة أسماء القطع للعربية - مكتبة محمد عادل', true)
    begin
      walk = lambda do |ent|
        next unless ent && ent.valid?
        if ent.is_a?(Sketchup::ComponentInstance) || ent.is_a?(Sketchup::Group)
          raw_name = ent.name.to_s.strip
          raw_name = ent.definition.name.to_s.strip if raw_name.empty? && ent.is_a?(Sketchup::ComponentInstance)
          clean = raw_name.sub(/#\d+\z/, '').strip.downcase

          ARABIC_PART_DICTIONARY.each do |en_kw, ar_label|
            if clean == en_kw || clean.include?(en_kw)
              ent.name = ar_label
              if ent.is_a?(Sketchup::ComponentInstance)
                ent.definition.name = "#{ar_label} (#{ent.definition.entityID})" rescue nil
              end
              ent.set_attribute('dynamic_attributes', '_name', ar_label) rescue nil
              count += 1
              break
            end
          end

          ents = DolaWoodGrainManager.ents_of(ent)
          ents.each { |ch| walk.call(ch) } if ents
        end
      end

      roots.each { |r| walk.call(r) }
      model.commit_operation
      UI.messagebox("✅ تم تعريب وترجمة أسماء (#{count}) قطعة داخل الوحدات المحددة لتظهر بالعربية في الـ Cutting List.")
      true
    rescue => e
      model.abort_operation rescue nil
      UI.messagebox("حدث خطأ أثناء الترجمة:\n#{e.message}")
      false
    end
  end

  # 6) أداة ترقيم الوحدات التسلسلي (Unit Serial Numbering)
  def self.open_serial_numbering_dialog
    model = Sketchup.active_model
    units = model.selection.grep(Sketchup::ComponentInstance)
    units = model.active_entities.grep(Sketchup::ComponentInstance) if units.empty?

    if units.empty?
      UI.messagebox('لا توجد وحدات في المشهد لترقيمها.')
      return false
    end

    prompts = ['بادئة الترقيم (مثال U أو B):', 'البدء من رقم:', 'إظهار الرقم كنص ثلاثي الأبعاد فوق الوحدة؟']
    defaults = ['U-', 1, 'نعم']
    list = ['', '', 'نعم|لا']
    res = UI.inputbox(prompts, defaults, list, 'ترقيم الوحدات — مكتبة محمد عادل')
    return false unless res

    prefix, start_num, show_label = res
    start_num = [start_num.to_i, 1].max

    # ترتيب الوحدات مكانياً من اليمين لليسار ومن الأسفل للأعلى
    sorted_units = units.sort_by { |u| [u.bounds.min.z.round(1), u.bounds.min.x.round(1), u.bounds.min.y.round(1)] }

    model.start_operation('ترقيم الوحدات - مكتبة محمد عادل', true)
    begin
      sorted_units.each_with_index do |u, idx|
        code = format('%s%02d', prefix.to_s.strip, start_num + idx)
        u.set_attribute('dynamic_attributes', 'cod', code) rescue nil
        u.set_attribute(PREF_NS, 'unit_serial', code) rescue nil
        base_title = u.definition.name.to_s.sub(/\A\[[^\]]+\]\s*/, '')
        u.name = "[#{code}] #{base_title}"

        if show_label == 'نعم'
          pt = Geom::Point3d.new(u.bounds.center.x, u.bounds.min.y, u.bounds.max.z + 4.cm)
          model.active_entities.add_text(code, pt) rescue nil
        end
      end
      model.commit_operation
      UI.messagebox("✅ تم ترقيم (#{sorted_units.length}) وحدة بنجاح بداية من #{prefix}#{format('%02d', start_num)}.")
      true
    rescue => e
      model.abort_operation rescue nil
      UI.messagebox("حدث خطأ أثناء الترقيم:\n#{e.message}")
      false
    end
  end

  # 7) أداة حفر الليد (LED Groove Tool)
  def self.open_led_groove_dialog
    model = Sketchup.active_model
    sel = model.selection.to_a.select { |e| e.is_a?(Sketchup::ComponentInstance) || e.is_a?(Sketchup::Group) }
    if sel.empty?
      UI.messagebox('الرجاء تحديد الوحدة أو اللوح المطلوب إضافة مجرى بروفايل الليد (LED Groove) له أولاً.')
      return false
    end

    prompts  = ['عرض مجرى الليد (سم):', 'عمق الحفر (سم):', 'المسافة من الحافة الأمامية (سم):', 'لون إضاءة الليد:']
    defaults = [1.8, 0.8, 4.0, 'أصفر دافئ (Warm 3000K)']
    list     = ['', '', '', 'أصفر دافئ (Warm 3000K)|أبيض نهاري (Daylight 4000K)|أبيض ثلجي (Cool 6500K)']
    res = UI.inputbox(prompts, defaults, list, 'حفر مجرى الليد (LED) — مكتبة محمد عادل')
    return false unless res

    groove_w = res[0].to_f.cm
    groove_d = res[1].to_f.cm
    front_offset = res[2].to_f.cm
    led_tone = res[3].to_s

    led_color =
      if led_tone.include?('ثلجي')
        Sketchup::Color.new(224, 242, 254)
      elsif led_tone.include?('نهاري')
        Sketchup::Color.new(254, 249, 195)
      else
        Sketchup::Color.new(253, 224, 71)
      end

    model.start_operation('إضافة مجرى إضاءة LED - مكتبة محمد عادل', true)
    count = 0
    begin
      led_mat = model.materials['Dola_LED_Light'] || model.materials.add('Dola_LED_Light')
      led_mat.color = led_color

      alu_mat = model.materials['Dola_LED_Aluminum'] || model.materials.add('Dola_LED_Aluminum')
      alu_mat.color = Sketchup::Color.new(60, 68, 82)

      sel.each do |unit|
        next unless unit && unit.valid?
        ents = DolaWoodGrainManager.ents_of(unit)
        next unless ents
        bb = unit.is_a?(Sketchup::ComponentInstance) ? unit.definition.bounds : unit.bounds

        # إنشاء جروب بروفايل الليد أسفل القاعدة الأمامية للوحدة
        grp = ents.add_group
        grp.name = 'مجرى إضاءة LED'
        x1 = bb.min.x + 1.8.cm
        x2 = bb.max.x - 1.8.cm
        next if x2 <= x1

        y_front = bb.min.y + front_offset
        y_back  = y_front + groove_w
        z_bot   = bb.min.z
        z_top   = z_bot + groove_d

        face = grp.entities.add_face(
          Geom::Point3d.new(x1, y_front, z_bot),
          Geom::Point3d.new(x2, y_front, z_bot),
          Geom::Point3d.new(x2, y_back,  z_bot),
          Geom::Point3d.new(x1, y_back,  z_bot)
        )
        if face
          face.material = led_mat
          face.back_material = led_mat
          face.pushpull(-groove_d) rescue nil
        end
        count += 1
      end
      model.commit_operation
      UI.messagebox("✨ تم إنشاء مجرى بروفايل الليد لعدد (#{count}) وحدة بنجاح.")
      true
    rescue => e
      model.abort_operation rescue nil
      UI.messagebox("حدث خطأ أثناء حفر الليد:\n#{e.message}")
      false
    end
  end

  # 8) أداة تبديل الضلفة (Door Style Switcher)
  def self.open_door_style_dialog
    model = Sketchup.active_model
    sel = model.selection.to_a.select { |e| e.is_a?(Sketchup::ComponentInstance) || e.is_a?(Sketchup::Group) }
    if sel.empty?
      UI.messagebox('الرجاء تحديد الوحدة أو الضلفة المطلوب تغيير تصميمها أولاً.')
      return false
    end

    prompts  = ['تصميم الضلفة الجديد:', 'عرض إطار الشيكر/الكلاسيك (سم):', 'عمق الحفر الداخلي (مم):']
    defaults = ['شيكر كلاسيك (Shaker Frame)', 6.0, 4.0]
    list     = ['شيكر كلاسيك (Shaker Frame)|ضلفة زجاج بإطار (Glass Door)|ضلفة سادة مودرن (Flat Modern)', '', '']
    res = UI.inputbox(prompts, defaults, list, 'تبديل تصميم الضلفة — مكتبة محمد عادل')
    return false unless res

    style_name, frame_cm, recess_mm = res
    frame_w  = [frame_cm.to_f, 3.0].max.cm
    recess_d = [recess_mm.to_f, 2.0].max.mm

    # البحث عن الضلف داخل المحدد
    doors = []
    walk = lambda do |ent|
      next unless ent && ent.valid?
      if ent.is_a?(Sketchup::ComponentInstance) || ent.is_a?(Sketchup::Group)
        nm = DolaWoodGrainManager.entity_display_name(ent).downcase
        if nm.include?('ضلف') || nm.include?('ضل') || nm.include?('باب') || nm.include?('door')
          doors << ent if DolaWoodGrainManager.leaf_wooden_board?(ent)
        end
        ents = DolaWoodGrainManager.ents_of(ent)
        ents.each { |ch| walk.call(ch) } if ents
      end
    end
    sel.each { |s| walk.call(s) }
    doors = sel.select { |s| DolaWoodGrainManager.leaf_wooden_board?(s) } if doors.empty?

    if doors.empty?
      UI.messagebox('لم يتم العثور على ضلف داخل العنصر المحدد.')
      return false
    end

    model.start_operation('تبديل تصميم الضلفة - مكتبة محمد عادل', true)
    modified = 0
    begin
      glass_mat = nil
      if style_name.include?('زجاج')
        glass_mat = model.materials['Dola_Door_Glass'] || model.materials.add('Dola_Door_Glass')
        glass_mat.color = Sketchup::Color.new(30, 41, 59)
        glass_mat.alpha = 0.55
      end

      doors.each do |door|
        door.make_unique if door.is_a?(Sketchup::ComponentInstance) && door.definition.count_used_instances > 1
        ents = DolaWoodGrainManager.ents_of(door)
        next unless ents

        # إزالة أي تشكيل شيكر سابق إن وجد
        ents.grep(Sketchup::Group).each do |g|
          g.erase! if g.name == 'Dola_Door_Profile_Insert'
        end

        unless style_name.include?('سادة')
          bb = door.is_a?(Sketchup::ComponentInstance) ? door.definition.bounds : door.bounds
          dims = [
            [:x, bb.width.to_f,  bb.min.x, bb.max.x],
            [:y, bb.height.to_f, bb.min.y, bb.max.y],
            [:z, bb.depth.to_f,  bb.min.z, bb.max.z]
          ].sort_by { |d| d[1] }

          # الأصغر هو السمك، والآخران هما عرض وارتفاع الضلفة
          thick_axis = dims[0][0]
          a1 = dims[1]
          a2 = dims[2]

          if a1[1] > (frame_w * 2.2) && a2[1] > (frame_w * 2.2)
            grp = ents.add_group
            grp.name = 'Dola_Door_Profile_Insert'
            u_min = a1[2] + frame_w
            u_max = a1[3] - frame_w
            v_min = a2[2] + frame_w
            v_max = a2[3] - frame_w
            t_pos = dims[0][2]

            mk_pt = lambda do |u, v, t|
              coords = { a1[0] => u, a2[0] => v, thick_axis => t }
              Geom::Point3d.new(coords[:x], coords[:y], coords[:z])
            end

            f = grp.entities.add_face(
              mk_pt.call(u_min, v_min, t_pos),
              mk_pt.call(u_max, v_min, t_pos),
              mk_pt.call(u_max, v_max, t_pos),
              mk_pt.call(u_min, v_max, t_pos)
            )
            if f
              if glass_mat
                f.material = glass_mat
                f.back_material = glass_mat
              elsif door.material
                f.material = door.material
              end
              f.pushpull(recess_d) rescue nil
            end
          end
        end
        modified += 1
      end
      model.commit_operation
      UI.messagebox("✨ تم تحديث تصميم (#{modified}) ضلفة إلى «#{style_name}» بنجاح.")
      true
    rescue => e
      model.abort_operation rescue nil
      UI.messagebox("حدث خطأ أثناء تعديل الضلفة:\n#{e.message}")
      false
    end
  end

  # 9) نافذة مستويات وخامات المطبخ (Kitchen Materials & Wood Grain Textures)
  @kitchen_materials_dlg = nil



  # ============================================================================
  #  9) نافذة «مستويات وخامات المطبخ» الشاملة (إدارة المستويات + تغيير أسماء وألوان الخامات والـ CutList)
  # ============================================================================
  KITCHEN_MATERIAL_PRESETS = [
    { :id => 'hpl_oak',        :name => 'HPL أوك طبيعي (ثمرة خشب)',     :rgb => [194, 145, 95],  :grained => true,  :kind => 'HPL' },
    { :id => 'hpl_walnut',     :name => 'HPL جوز تركي داكن (ثمرة خشب)',  :rgb => [118, 78, 52],   :grained => true,  :kind => 'HPL' },
    { :id => 'hpl_2side_ash',  :name => 'HPL وشين قشرة أرو (ثمرة خشب)',  :rgb => [212, 175, 130], :grained => true,  :kind => 'HPL وشين' },
    { :id => 'hpl_2side_teak', :name => 'HPL وشين تك دافئ (ثمرة خشب)',   :rgb => [168, 112, 68],  :grained => true,  :kind => 'HPL وشين' },
    { :id => 'wood_back',      :name => 'ضهر خشابي 6مم (ثمرة خشب)',     :rgb => [178, 132, 88],  :grained => true,  :kind => 'ضهر خشابي' },
    { :id => 'mdf_white',      :name => 'كونتر / MDF أبيض سادة',        :rgb => [244, 246, 249], :grained => false, :kind => 'سادة' },
    { :id => 'mdf_beige',      :name => 'شاسيه كافيه / بيج ناعم سادة',  :rgb => [226, 214, 198], :grained => false, :kind => 'سادة' },
    { :id => 'mdf_anthracite', :name => 'أنتراسيت رمادي فحمي مودرن',   :rgb => [55, 65, 81],    :grained => false, :kind => 'سادة' },
    { :id => 'mdf_navy',       :name => 'كحلي ملكي (مكتبة محمد عادل)',   :rgb => [30, 41, 95],    :grained => false, :kind => 'سادة' },
    { :id => 'mdf_sage',       :name => 'أخضر سيج مودرن سادة',          :rgb => [115, 142, 126], :grained => false, :kind => 'سادة' }
  ].freeze

  def self.collect_model_materials_payload
    model = Sketchup.active_model
    mats = []
    model.materials.each do |m|
      next unless m && m.valid?
      c = m.color || Sketchup::Color.new(200, 200, 200)
      hex = format('#%02x%02x%02x', c.red, c.green, c.blue)
      has_tex = !m.texture.nil?
      override = m.get_attribute(GRAIN_DICT, 'grained_override', nil)
      is_grained =
        if override == 'true'
          true
        elsif override == 'false'
          false
        else
          has_tex || DolaWoodGrainManager::WOOD_GRAIN_KEYWORDS.any? { |kw| "#{m.display_name} #{m.name}".downcase.include?(kw) }
        end
      kind = m.get_attribute(GRAIN_DICT, 'material_kind', nil).to_s
      if kind.empty?
        nm_low = "#{m.display_name} #{m.name}".downcase
        kind = if nm_low.include?('وشين')
                 'HPL وشين'
               elsif nm_low.include?('ضهر') || nm_low.include?('ظهر')
                 'ضهر خشابي'
               elsif is_grained
                 'HPL'
               else
                 'سادة'
               end
      end
      mats << {
        'raw_name'     => m.name.to_s,
        'display_name' => m.display_name.to_s,
        'hex'          => hex,
        'has_texture'  => has_tex,
        'grained'      => is_grained,
        'kind'         => kind
      }
    end
    mats
  rescue
    []
  end

  def self.refresh_kitchen_materials_dialog_if_open
    return false unless @kitchen_materials_dlg && @kitchen_materials_dlg.visible?
    mats_json = collect_model_materials_payload.to_json
    @kitchen_materials_dlg.execute_script("window.receiveModelMaterials(#{mats_json});") rescue nil
    true
  rescue
    false
  end

  def self.open_kitchen_materials_tool
    if @kitchen_materials_dlg && @kitchen_materials_dlg.visible?
      refresh_kitchen_materials_dialog_if_open
      @kitchen_materials_dlg.bring_to_front rescue nil
      return true
    end

    @kitchen_materials_dlg = UI::HtmlDialog.new({
      :dialog_title    => 'مستويات وخامات المطبخ وتعديل الأسماء والألوان — مكتبة محمد عادل',
      :preferences_key => 'DolaKitchenMaterials_v3',
      :scrollable      => false,
      :resizable       => true,
      :width           => 540,
      :height          => 690,
      :style           => UI::HtmlDialog::STYLE_DIALOG
    })

    presets_json = KITCHEN_MATERIAL_PRESETS.to_json
    mats_json    = collect_model_materials_payload.to_json

    html = <<~HTML
      <!DOCTYPE html>
      <html lang="ar" dir="rtl">
      <head>
        <meta charset="UTF-8">
        <link href="https://fonts.googleapis.com/css2?family=Tajawal:wght@500;700;800&display=swap" rel="stylesheet">
        <style>
          * { box-sizing: border-box; }
          body {
            margin: 0; padding: 13px;
            font-family: 'Tajawal', sans-serif;
            background: linear-gradient(160deg, #1e1b4b 0%, #0f172a 100%);
            color: #f8fafc;
            height: 100vh;
            display: flex;
            flex-direction: column;
            gap: 10px;
            overflow: hidden;
          }
          .head-card {
            background: rgba(15, 23, 42, 0.88);
            border: 1px solid rgba(56, 189, 248, 0.35);
            border-radius: 14px;
            padding: 11px 14px;
            display: flex;
            align-items: center;
            justify-content: space-between;
          }
          .head-card h2 { margin: 0 0 3px; font-size: 16px; color: #38bdf8; }
          .head-card p  { margin: 0; font-size: 11.5px; color: #cbd5e1; }
          .tabs-row {
            display: grid;
            grid-template-columns: 1fr 1fr 1fr;
            gap: 6px;
            background: rgba(15, 23, 42, 0.85);
            padding: 4px;
            border-radius: 11px;
            border: 1px solid rgba(255, 255, 255, 0.12);
          }
          .tab-b {
            background: transparent;
            border: none;
            color: #94a3b8;
            padding: 7px 8px;
            border-radius: 8px;
            font-family: 'Tajawal', sans-serif;
            font-size: 12px;
            font-weight: 800;
            cursor: pointer;
          }
          .tab-b.active {
            background: linear-gradient(135deg, #0284c7 0%, #1d4ed8 100%);
            color: #ffffff;
          }
          .scroll-area {
            flex: 1;
            overflow-y: auto;
            display: flex;
            flex-direction: column;
            gap: 10px;
            padding-left: 3px;
          }
          .scroll-area::-webkit-scrollbar { width: 5px; }
          .scroll-area::-webkit-scrollbar-thumb { background: rgba(56, 189, 248, 0.35); border-radius: 99px; }
          .box-card {
            background: rgba(30, 41, 59, 0.72);
            border: 1px solid rgba(255, 255, 255, 0.12);
            border-radius: 13px;
            padding: 11px;
            display: flex;
            flex-direction: column;
            gap: 8px;
          }
          .box-title {
            font-size: 12.5px;
            font-weight: 800;
            color: #fbbf24;
            display: flex;
            align-items: center;
            justify-content: space-between;
          }
          select, input[type="text"], input[type="number"] {
            width: 100%;
            padding: 7px 10px;
            border-radius: 8px;
            background: #0f172a;
            border: 1px solid rgba(56, 189, 248, 0.38);
            color: #fff;
            font-family: 'Tajawal', sans-serif;
            font-size: 12.5px;
            font-weight: 700;
            outline: none;
          }
          input[type="color"] {
            width: 44px;
            height: 34px;
            padding: 2px;
            border-radius: 8px;
            background: #0f172a;
            border: 1px solid rgba(255, 255, 255, 0.3);
            cursor: pointer;
          }
          .presets-grid {
            display: grid;
            grid-template-columns: 1fr 1fr;
            gap: 8px;
          }
          .preset-card {
            background: rgba(15, 23, 42, 0.85);
            border: 1px solid rgba(255, 255, 255, 0.12);
            border-radius: 11px;
            padding: 8px;
            cursor: pointer;
            display: flex;
            flex-direction: column;
            gap: 6px;
            transition: all 0.16s;
          }
          .preset-card:hover, .preset-card.active {
            border-color: #38bdf8;
            background: rgba(2, 132, 199, 0.24);
          }
          .swatch {
            height: 32px;
            border-radius: 7px;
            border: 1px solid rgba(255, 255, 255, 0.25);
            position: relative;
            overflow: hidden;
          }
          .swatch-badge {
            position: absolute;
            bottom: 3px; left: 5px;
            font-size: 9.5px;
            font-weight: 800;
            background: rgba(15, 23, 42, 0.82);
            color: #fbbf24;
            padding: 1px 6px;
            border-radius: 5px;
          }
          .preset-title { font-size: 11.5px; font-weight: 700; color: #f1f5f9; }
          .custom-row {
            display: grid;
            grid-template-columns: 1.4fr auto 1fr;
            gap: 8px;
            align-items: center;
          }
          .mat-item-row {
            background: rgba(15, 23, 42, 0.82);
            border: 1px solid rgba(255, 255, 255, 0.1);
            border-radius: 11px;
            padding: 9px;
            display: flex;
            flex-direction: column;
            gap: 7px;
          }
          .mat-top-line {
            display: grid;
            grid-template-columns: auto 1fr auto;
            gap: 8px;
            align-items: center;
          }
          .mat-bot-line {
            display: grid;
            grid-template-columns: 1fr auto auto;
            gap: 7px;
            align-items: center;
          }
          .small-btn {
            background: rgba(56, 189, 248, 0.16);
            border: 1px solid rgba(56, 189, 248, 0.45);
            color: #38bdf8;
            padding: 6px 10px;
            border-radius: 8px;
            font-family: 'Tajawal', sans-serif;
            font-size: 11.5px;
            font-weight: 800;
            cursor: pointer;
            white-space: nowrap;
          }
          .small-btn:hover { background: #38bdf8; color: #0f172a; }
          .save-mat-btn {
            background: linear-gradient(135deg, #10b981 0%, #047857 100%);
            border: 1px solid #34d399;
            color: #fff;
            padding: 6px 12px;
            border-radius: 8px;
            font-family: 'Tajawal', sans-serif;
            font-size: 11.5px;
            font-weight: 800;
            cursor: pointer;
            white-space: nowrap;
          }
          .apply-btn {
            background: linear-gradient(135deg, #0284c7 0%, #0369a1 100%);
            border: 1px solid #38bdf8;
            color: #fff;
            padding: 10px;
            border-radius: 11px;
            font-family: 'Tajawal', sans-serif;
            font-size: 13.5px;
            font-weight: 800;
            cursor: pointer;
          }
        </style>
      </head>
      <body oncontextmenu="return false;">
        <div class="head-card">
          <div>
            <h2>🎨 مستويات وخامات المطبخ وتعديل الأسماء والألوان</h2>
            <p>تخصيص خامات المستويات + تعديل أسماء وألوان خامات المشروع للـ OpenCutList</p>
          </div>
          <button class="small-btn" onclick="requestMatsRefresh()">🔄 تحديث</button>
        </div>

        <div class="tabs-row">
          <button type="button" id="mTab1" class="tab-b active" onclick="switchMatTab('levels')">🏢 توزيع خامات المستويات</button>
          <button type="button" id="mTab2" class="tab-b" onclick="switchMatTab('editor')">✏️ تعديل أسماء وألوان الخامات</button>
          <button type="button" id="mTab3" class="tab-b" onclick="switchMatTab('create')">➕ إنشاء خامة جديدة</button>
        </div>

        <div id="levelsView" class="scroll-area">
          <div class="box-card">
            <div class="box-title">
              <span>1) اختر المستوى / الجزء المستهدف في المطبخ:</span>
            </div>
            <select id="targetPartSelect">
              <option value="all_parts">جميع قطع الوحدات المحددة (أو المطبخ بالكامل)</option>
              <option value="level_base">المستوى السفلي فقط (الوحدات السفلية Base Units)</option>
              <option value="level_upper1">المستوى العلوي الأول فقط (Upper Level 1)</option>
              <option value="level_upper2">المستوى العلوي الثاني / البانوهات (Upper Level 2)</option>
              <option value="level_tall">الدواليب الطويلة فقط (Tall Units / البانتري)</option>
              <option value="doors_only">الضلف ووشوش الأدراج والتجاليد الخارجية فقط</option>
              <option value="carcass_only">الشاسيه الداخلي فقط (الأجناب + الأرفف + القواطيع)</option>
              <option value="backs_only">الضهر فقط (تحويل أو تلوين الضهر الخشابي 6مم)</option>
              <option value="plinth_only">الوزرة السفلية فقط (السوكلو / Plinth)</option>
            </select>
          </div>

          <div class="box-card">
            <div class="box-title">
              <span>2) اختر قالب الخامة أو خصص الاسم واللون قبل التطبيق:</span>
            </div>
            <div class="presets-grid" id="presetsGrid"></div>
          </div>

          <div class="box-card">
            <div class="box-title">
              <span>3) تخصيص اسم ولون ونوع الخامة المختارة (يظهر في OpenCutList):</span>
            </div>
            <div class="custom-row">
              <input type="text" id="customMatName" placeholder="اسم الخامة في التقطيع (مثلاً: HPL 1055 وشين)">
              <input type="color" id="customMatColor" value="#c2915f" title="اختر لون الخامة">
              <select id="customMatKind">
                <option value="HPL">HPL (بثمرة خشب)</option>
                <option value="HPL وشين">HPL وشين (بثمرة خشب)</option>
                <option value="ضهر خشابي">ضهر خشابي (بثمرة خشب)</option>
                <option value="سادة">كونتر / MDF سادة (بدون ثمرة)</option>
              </select>
            </div>
          </div>

          <button class="apply-btn" onclick="applySelectedMaterial()">✨ تطبيق الخامة بالاسم واللون المحددين</button>
        </div>

        <div id="editorView" class="scroll-area" style="display:none;">
          <div class="box-card">
            <div class="box-title">
              <span>✏️ خامات المشروع الحالية (عدّل الاسم أو اللون أو النوع ثم اضغط حفظ):</span>
            </div>
            <div id="modelMatsList" style="display:flex;flex-direction:column;gap:8px;"></div>
          </div>
        </div>

        <div id="createView" class="scroll-area" style="display:none;">
          <div class="box-card">
            <div class="box-title"><span>➕ إضافة خامة جديدة للمشروع:</span></div>
            <label style="font-size:12px;">اسم الخامة الجديد (كما سيظهر في سكتش أب والـ CutList):</label>
            <input type="text" id="newMatName" placeholder="مثال: HPL 2040 وشين قشرة أرو">

            <div style="display:grid;grid-template-columns:auto 1fr;gap:10px;align-items:center;margin-top:4px;">
              <input type="color" id="newMatColor" value="#b88655">
              <select id="newMatKind">
                <option value="HPL">HPL وجه واحد (بثمرة خشب)</option>
                <option value="HPL وشين">HPL وشين (بثمرة خشب)</option>
                <option value="ضهر خشابي">ضهر خشابي 6مم (بثمرة خشب)</option>
                <option value="سادة">خامة سادة بدون ثمرة (أبيض / ألوان)</option>
              </select>
            </div>

            <div style="display:flex;gap:8px;margin-top:8px;">
              <button type="button" class="apply-btn" style="flex:1;" onclick="createNewMaterial(false)">➕ إنشاء الخامة في الموديل</button>
              <button type="button" class="small-btn" onclick="createNewMaterial(true)">📁 إنشاء مع اختيار صورة نقشة من الجهاز</button>
            </div>
          </div>
        </div>

        <script>
          const PRESETS = #{presets_json};
          let modelMaterials = #{mats_json};
          let selectedId = PRESETS[0].id;

          function esc(s) {
            return String(s == null ? '' : s)
              .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
          }

          function rgbToHex(r, g, b) {
            return '#' + [r, g, b].map(x => Math.max(0, Math.min(255, Number(x)||0)).toString(16).padStart(2, '0')).join('');
          }

          function switchMatTab(tab) {
            document.getElementById('mTab1').classList.toggle('active', tab === 'levels');
            document.getElementById('mTab2').classList.toggle('active', tab === 'editor');
            document.getElementById('mTab3').classList.toggle('active', tab === 'create');
            document.getElementById('levelsView').style.display = (tab === 'levels') ? 'flex' : 'none';
            document.getElementById('editorView').style.display = (tab === 'editor') ? 'flex' : 'none';
            document.getElementById('createView').style.display = (tab === 'create') ? 'flex' : 'none';
            if (tab === 'editor') renderModelMatsEditor();
          }

          window.receiveModelMaterials = function(list) {
            modelMaterials = Array.isArray(list) ? list : [];
            renderModelMatsEditor();
          };

          function renderPresets() {
            const grid = document.getElementById('presetsGrid');
            grid.innerHTML = PRESETS.map(p => {
              const [r, g, b] = p.rgb;
              const active = (p.id === selectedId) ? 'active' : '';
              const bgCss  = p.grained
                ? `repeating-linear-gradient(90deg, rgb(${r},${g},${b}) 0px, rgb(${Math.max(r-18,0)},${Math.max(g-18,0)},${Math.max(b-18,0)}) 4px, rgb(${r},${g},${b}) 8px)`
                : `rgb(${r},${g},${b})`;
              return `
                <div class="preset-card ${active}" onclick="selectPreset('${p.id}')">
                  <div class="swatch" style="background:${bgCss};">
                    <span class="swatch-badge">${esc(p.kind || (p.grained ? 'ثمرة خشب' : 'سادة'))}</span>
                  </div>
                  <div class="preset-title">${esc(p.name)}</div>
                </div>
              `;
            }).join('');
          }

          function selectPreset(id) {
            selectedId = id;
            const p = PRESETS.find(x => x.id === id);
            if (p) {
              document.getElementById('customMatName').value  = p.name;
              document.getElementById('customMatColor').value = rgbToHex(p.rgb[0], p.rgb[1], p.rgb[2]);
              document.getElementById('customMatKind').value  = p.kind || (p.grained ? 'HPL' : 'سادة');
            }
            renderPresets();
          }

          function applySelectedMaterial() {
            const payload = {
              preset_id: selectedId,
              target: document.getElementById('targetPartSelect').value,
              custom_name: document.getElementById('customMatName').value.trim(),
              custom_hex: document.getElementById('customMatColor').value,
              custom_kind: document.getElementById('customMatKind').value
            };
            if (window.sketchup && window.sketchup.apply_kitchen_material) {
              window.sketchup.apply_kitchen_material(JSON.stringify(payload));
            }
          }

          function renderModelMatsEditor() {
            const box = document.getElementById('modelMatsList');
            if (!box) return;
            if (!modelMaterials || modelMaterials.length === 0) {
              box.innerHTML = `<div style="padding:16px;text-align:center;color:#94a3b8;">لا توجد خامات في الموديل حالياً.</div>`;
              return;
            }
            box.innerHTML = modelMaterials.map((m, idx) => `
              <div class="mat-item-row" data-raw="${esc(m.raw_name)}">
                <div class="mat-top-line">
                  <input type="color" class="edit-mat-hex" value="${esc(m.hex || '#cccccc')}" title="تغيير لون الخامة">
                  <input type="text" class="edit-mat-name" value="${esc(m.display_name)}" placeholder="اسم الخامة...">
                  <button type="button" class="save-mat-btn" onclick="saveSingleMatEdit(${idx})">💾 حفظ</button>
                </div>
                <div class="mat-bot-line">
                  <select class="edit-mat-kind">
                    <option value="HPL" ${m.kind === 'HPL' ? 'selected' : ''}>🪵 HPL (بثمرة خشب)</option>
                    <option value="HPL وشين" ${m.kind === 'HPL وشين' ? 'selected' : ''}>🪵 HPL وشين (بثمرة خشب)</option>
                    <option value="ضهر خشابي" ${m.kind === 'ضهر خشابي' ? 'selected' : ''}>🪵 ضهر خشابي (بثمرة خشب)</option>
                    <option value="سادة" ${m.kind === 'سادة' ? 'selected' : ''}>🎨 خامة سادة (بدون ثمرة)</option>
                  </select>
                  <button type="button" class="small-btn" onclick="pickTextureForMat(${idx})" title="اختيار صورة نقشة خشب من الجهاز">📁 صورة نقشة</button>
                  <button type="button" class="small-btn" onclick="applyExistingMatToTarget(${idx})" title="تطبيق هذه الخامة على المستوى المختار في التبويب الأول">🎯 تطبيق على المستوى</button>
                </div>
              </div>
            `).join('');
          }

          function saveSingleMatEdit(idx) {
            const rows = document.querySelectorAll('#modelMatsList .mat-item-row');
            const row = rows[idx];
            if (!row) return;
            const rawName = row.getAttribute('data-raw');
            const newName = row.querySelector('.edit-mat-name').value.trim();
            const newHex  = row.querySelector('.edit-mat-hex').value;
            const newKind = row.querySelector('.edit-mat-kind').value;
            if (window.sketchup && window.sketchup.update_existing_material) {
              window.sketchup.update_existing_material(JSON.stringify({
                raw_name: rawName,
                new_name: newName,
                hex: newHex,
                kind: newKind,
                pick_image: false
              }));
            }
          }

          function pickTextureForMat(idx) {
            const rows = document.querySelectorAll('#modelMatsList .mat-item-row');
            const row = rows[idx];
            if (!row) return;
            const rawName = row.getAttribute('data-raw');
            const newName = row.querySelector('.edit-mat-name').value.trim();
            const newHex  = row.querySelector('.edit-mat-hex').value;
            const newKind = row.querySelector('.edit-mat-kind').value;
            if (window.sketchup && window.sketchup.update_existing_material) {
              window.sketchup.update_existing_material(JSON.stringify({
                raw_name: rawName,
                new_name: newName,
                hex: newHex,
                kind: newKind,
                pick_image: true
              }));
            }
          }

          function applyExistingMatToTarget(idx) {
            const m = modelMaterials[idx];
            if (!m) return;
            const target = document.getElementById('targetPartSelect').value;
            if (window.sketchup && window.sketchup.apply_existing_material_to_scope) {
              window.sketchup.apply_existing_material_to_scope(JSON.stringify({
                raw_name: m.raw_name,
                target: target
              }));
            }
          }

          function createNewMaterial(pickImage) {
            const name = document.getElementById('newMatName').value.trim();
            const hex  = document.getElementById('newMatColor').value;
            const kind = document.getElementById('newMatKind').value;
            if (!name) {
              alert('برجاء كتابة اسم الخامة الجديد أولاً.');
              return;
            }
            if (window.sketchup && window.sketchup.create_custom_material) {
              window.sketchup.create_custom_material(JSON.stringify({
                name: name,
                hex: hex,
                kind: kind,
                pick_image: !!pickImage
              }));
            }
          }

          function requestMatsRefresh() {
            if (window.sketchup && window.sketchup.refresh_model_materials) {
              window.sketchup.refresh_model_materials();
            }
          }

          selectPreset(PRESETS[0].id);
          renderModelMatsEditor();
        </script>
      </body>
      </html>
    HTML

    @kitchen_materials_dlg.set_html(html)

    @kitchen_materials_dlg.add_action_callback('apply_kitchen_material') do |_ctx, json_str|
      data = JSON.parse(json_str.to_s) rescue {}
      apply_kitchen_material_preset!(
        data['preset_id'],
        data['target'],
        data['custom_name'],
        data['custom_hex'],
        data['custom_kind']
      )
    end

    @kitchen_materials_dlg.add_action_callback('update_existing_material') do |_ctx, json_str|
      data = JSON.parse(json_str.to_s) rescue {}
      update_model_material_properties!(data)
    end

    @kitchen_materials_dlg.add_action_callback('apply_existing_material_to_scope') do |_ctx, json_str|
      data = JSON.parse(json_str.to_s) rescue {}
      apply_existing_model_material_to_scope!(data['raw_name'], data['target'])
    end

    @kitchen_materials_dlg.add_action_callback('create_custom_material') do |_ctx, json_str|
      data = JSON.parse(json_str.to_s) rescue {}
      create_custom_model_material!(data)
    end

    @kitchen_materials_dlg.add_action_callback('refresh_model_materials') do |_ctx|
      refresh_kitchen_materials_dialog_if_open
    end

    @kitchen_materials_dlg.show
    true
  end

  def self.parse_hex_rgb(hex_str, fallback = [194, 145, 95])
    s = hex_str.to_s.strip.sub(/\A#/, '')
    return fallback unless s =~ /\A[0-9A-Fa-f]{6}\z/
    [s[0..1].to_i(16), s[2..3].to_i(16), s[4..5].to_i(16)]
  rescue
    fallback
  end

  def self.filter_units_by_kitchen_level(roots, target_scope)
    scope = target_scope.to_s
    return roots unless %w[level_base level_upper1 level_upper2 level_tall].include?(scope)

    selected = roots.select do |u|
      next false unless u && u.valid?
      bb = u.bounds
      z_min_cm = bb.min.z.to_f * 2.54
      h_cm     = bb.height.to_f * 2.54
      nm       = "#{u.name} #{u.respond_to?(:definition) ? u.definition.name : ''}".downcase

      case scope
      when 'level_tall'
        h_cm >= 175.0 || nm.include?('دولاب') || nm.include?('بانتري') || nm.include?('ثلاجة') || nm.include?('فرن')
      when 'level_base'
        h_cm < 175.0 && z_min_cm < 95.0
      when 'level_upper1'
        h_cm < 175.0 && z_min_cm >= 95.0 && z_min_cm < 195.0
      when 'level_upper2'
        h_cm < 175.0 && z_min_cm >= 195.0
      else
        true
      end
    end
    selected.empty? ? roots : selected
  end

  def self.filter_boards_by_part_scope(boards, target_scope)
    scope = target_scope.to_s
    return boards if %w[all_parts level_base level_upper1 level_upper2 level_tall].include?(scope)

    filtered = boards.select do |b|
      nm = DolaWoodGrainManager.entity_display_name(b[:entity]).downcase
      case scope
      when 'doors_only'
        nm.include?('ضلف') || nm.include?('ضل') || nm.include?('باب') || nm.include?('وش') || nm.include?('تجليد') || nm.include?('door') || nm.include?('front')
      when 'backs_only'
        nm.include?('ضهر') || nm.include?('ظهر') || nm.include?('back')
      when 'plinth_only'
        nm.include?('وزر') || nm.include?('سوكلو') || nm.include?('plinth') || nm.include?('kick')
      when 'carcass_only'
        !(nm.include?('ضلف') || nm.include?('باب') || nm.include?('door') || nm.include?('وش') || nm.include?('ضهر') || nm.include?('ظهر'))
      else
        true
      end
    end
    filtered.empty? ? boards : filtered
  end

  def self.configure_material_grain_and_color!(mat, rgb, kind_str, pick_image = false)
    return unless mat && mat.valid?
    r, g, b = rgb
    mat.color = Sketchup::Color.new(r, g, b)
    grained = (kind_str.to_s != 'سادة')
    mat.set_attribute(GRAIN_DICT, 'material_kind', kind_str.to_s)
    mat.set_attribute(GRAIN_DICT, 'grained_override', grained ? 'true' : 'false')

    if pick_image
      img_path = UI.openpanel('اختر صورة نقشة الخشب (PNG / JPG)', '', 'Image Files|*.png;*.jpg;*.jpeg;||')
      if img_path && File.exist?(img_path)
        mat.texture = img_path
        mat.texture.size = [40.cm, 40.cm] rescue nil
      end
    elsif grained
      DolaWoodGrainManager.ensure_procedural_wood_texture!(mat)
    else
      mat.texture = nil rescue nil
    end
  end

  def self.update_model_material_properties!(data)
    model = Sketchup.active_model
    raw_name = data['raw_name'].to_s
    mat = model.materials[raw_name] || model.materials.find { |m| m.display_name.to_s == raw_name }
    unless mat
      UI.messagebox("لم يتم العثور على الخامة المطلوبة في الموديل.")
      return false
    end

    new_name = data['new_name'].to_s.strip
    rgb      = parse_hex_rgb(data['hex'], [200, 200, 200])
    kind_str = data['kind'].to_s.strip
    kind_str = 'HPL' if kind_str.empty?

    model.start_operation('تعديل اسم ولون الخامة - مكتبة محمد عادل', true)
    begin
      if !new_name.empty? && new_name != mat.name && new_name != mat.display_name
        mat.name = new_name rescue nil
      end
      configure_material_grain_and_color!(mat, rgb, kind_str, data['pick_image'] == true)
      model.commit_operation
      model.active_view.invalidate
      refresh_kitchen_materials_dialog_if_open
      UI.messagebox("✅ تم تحديث الخامة إلى «#{mat.display_name}» (#{kind_str}) بنجاح!")
      true
    rescue => e
      model.abort_operation rescue nil
      UI.messagebox("تعذر تحديث الخامة:\n#{e.message}")
      false
    end
  end

  def self.create_custom_model_material!(data)
    model = Sketchup.active_model
    name = data['name'].to_s.strip
    return false if name.empty?
    rgb  = parse_hex_rgb(data['hex'], [185, 138, 88])
    kind = data['kind'].to_s.strip
    kind = 'HPL' if kind.empty?

    model.start_operation('إنشاء خامة جديدة - مكتبة محمد عادل', true)
    begin
      mat = model.materials[name] || model.materials.add(name)
      configure_material_grain_and_color!(mat, rgb, kind, data['pick_image'] == true)
      model.commit_operation
      refresh_kitchen_materials_dialog_if_open
      UI.messagebox("✨ تم إنشاء الخامة «#{mat.display_name}» (#{kind}) وإضافتها للمشروع بنجاح!")
      true
    rescue => e
      model.abort_operation rescue nil
      UI.messagebox("تعذر إنشاء الخامة:\n#{e.message}")
      false
    end
  end

  def self.apply_existing_model_material_to_scope!(raw_name, target_scope)
    model = Sketchup.active_model
    mat = model.materials[raw_name.to_s] || model.materials.find { |m| m.display_name.to_s == raw_name.to_s }
    unless mat
      UI.messagebox('لم يتم العثور على الخامة في الموديل.')
      return false
    end

    roots = model.selection.to_a.select { |e| e.is_a?(Sketchup::ComponentInstance) || e.is_a?(Sketchup::Group) }
    roots = model.active_entities.to_a.select { |e| e.is_a?(Sketchup::ComponentInstance) || e.is_a?(Sketchup::Group) } if roots.empty?
    roots = filter_units_by_kitchen_level(roots, target_scope)
    boards = DolaWoodGrainManager.collect_wooden_boards(roots, false)
    filtered = filter_boards_by_part_scope(boards, target_scope)

    if filtered.empty?
      UI.messagebox('لم يتم العثور على قطع مطابقة لتطبيق الخامة عليها.')
      return false
    end

    is_grained = DolaWoodGrainManager.has_wood_grain_material?(filtered.first[:entity], mat)
    model.start_operation('تطبيق خامة على المستوى - مكتبة محمد عادل', true)
    begin
      filtered.each do |item|
        ent = item[:entity]
        next unless ent && ent.valid?
        ent.material = mat
        DolaWoodGrainManager.set_part_grain!(ent, :vertical_z, item[:parent_tr], mat, true) if is_grained
      end
      model.commit_operation
      model.active_view.invalidate
      UI.messagebox("✅ تم تطبيق الخامة «#{mat.display_name}» على (#{filtered.length}) قطعة بنجاح!")
      true
    rescue => e
      model.abort_operation rescue nil
      false
    end
  end

  def self.apply_kitchen_material_preset!(preset_id, target_scope, custom_name = nil, custom_hex = nil, custom_kind = nil)
    preset = KITCHEN_MATERIAL_PRESETS.find { |p| p[:id] == preset_id.to_s } || KITCHEN_MATERIAL_PRESETS.first
    model  = Sketchup.active_model
    roots  = model.selection.to_a.select { |e| e.is_a?(Sketchup::ComponentInstance) || e.is_a?(Sketchup::Group) }
    roots  = model.active_entities.to_a.select { |e| e.is_a?(Sketchup::ComponentInstance) || e.is_a?(Sketchup::Group) } if roots.empty?

    if roots.empty?
      UI.messagebox('لا توجد وحدات في المشهد لتطبيق الخامة عليها.')
      return false
    end

    level_roots = filter_units_by_kitchen_level(roots, target_scope)
    boards      = DolaWoodGrainManager.collect_wooden_boards(level_roots, false)
    filtered    = filter_boards_by_part_scope(boards, target_scope)

    final_name = custom_name.to_s.strip.empty? ? preset[:name] : custom_name.to_s.strip
    final_rgb  = custom_hex.to_s.strip.empty? ? preset[:rgb] : parse_hex_rgb(custom_hex, preset[:rgb])
    final_kind = custom_kind.to_s.strip.empty? ? (preset[:kind] || (preset[:grained] ? 'HPL' : 'سادة')) : custom_kind.to_s.strip
    is_grained = (final_kind != 'سادة')

    model.start_operation('تطبيق خامات المطبخ - مكتبة محمد عادل', true)
    begin
      mat = model.materials[final_name] || model.materials.add(final_name)
      configure_material_grain_and_color!(mat, final_rgb, final_kind, false)

      filtered.each do |item|
        ent = item[:entity]
        next unless ent && ent.valid?
        ent.material = mat
        if is_grained
          DolaWoodGrainManager.set_part_grain!(ent, :vertical_z, item[:parent_tr], mat, true)
        end
      end
      model.commit_operation
      model.active_view.invalidate
      refresh_kitchen_materials_dialog_if_open
      UI.messagebox("✅ تم تطبيق الخامة «#{final_name}» (#{final_kind}) على (#{filtered.length}) قطعة بنجاح#{is_grained ? ' مع ضبط الثمرة بالطول (Z)' : ''}.")
      true
    rescue => e
      model.abort_operation rescue nil
      UI.messagebox("حدث خطأ أثناء تطبيق الخامة:\n#{e.message}")
      false
    end
  end

  # 10) نافذة تقرير الوحدات التفصيلي (Units Report Dialog)
  @units_report_dlg = nil

  def self.collect_project_units_summary
    model = Sketchup.active_model
    insts = model.active_entities.grep(Sketchup::ComponentInstance)
    rows = []
    insts.each_with_index do |u, idx|
      next unless u && u.valid?
      bb = u.bounds
      w_cm = (bb.width.to_f * 2.54).round(1)
      d_cm = (bb.depth.to_f * 2.54).round(1)
      h_cm = (bb.height.to_f * 2.54).round(1)
      next if [w_cm, d_cm, h_cm].max < 8.0

      code = u.get_attribute('dynamic_attributes', 'cod', nil) ||
             u.get_attribute(PREF_NS, 'unit_serial', nil) ||
             format('U-%02d', idx + 1)
      title = u.definition.name.to_s.gsub(/\s*\([^)]*\)/, '').strip
      title = u.name.to_s.strip if title.empty?

      boards = DolaWoodGrainManager.collect_wooden_boards([u], true)
      rows << {
        'index'        => idx + 1,
        'code'         => code.to_s,
        'name'         => title,
        'width_cm'     => w_cm,
        'depth_cm'     => d_cm,
        'height_cm'    => h_cm,
        'grained_parts'=> boards.length
      }
    end
    rows
  end

  def self.open_units_report_dialog
    rows = collect_project_units_summary
    dlg = UI::HtmlDialog.new({
      :dialog_title    => 'تقرير وحدات المشروع — مكتبة محمد عادل',
      :preferences_key => 'DolaUnitsReport_v2',
      :scrollable      => true,
      :resizable       => true,
      :width           => 780,
      :height          => 580,
      :style           => UI::HtmlDialog::STYLE_DIALOG
    })

    rows_json = rows.to_json

    html = <<~HTML
      <!DOCTYPE html>
      <html lang="ar" dir="rtl">
      <head>
        <meta charset="UTF-8">
        <link href="https://fonts.googleapis.com/css2?family=Tajawal:wght@500;700;800&display=swap" rel="stylesheet">
        <style>
          * { box-sizing: border-box; }
          body {
            margin: 0; padding: 18px;
            font-family: 'Tajawal', sans-serif;
            background: #0f172a;
            color: #f8fafc;
          }
          .top-bar {
            display: flex;
            align-items: center;
            justify-content: space-between;
            background: linear-gradient(135deg, #1e1b4b 0%, #0f172a 100%);
            border: 1px solid rgba(56, 189, 248, 0.35);
            border-radius: 14px;
            padding: 14px 18px;
            margin-bottom: 14px;
          }
          .top-bar h2 { margin: 0; font-size: 18px; color: #38bdf8; }
          .btn-group { display: flex; gap: 8px; }
          button {
            background: linear-gradient(135deg, #0284c7, #0369a1);
            border: 1px solid #38bdf8;
            color: #fff;
            padding: 8px 14px;
            border-radius: 9px;
            font-family: 'Tajawal', sans-serif;
            font-weight: 800;
            cursor: pointer;
          }
          table {
            width: 100%;
            border-collapse: collapse;
            background: rgba(30, 41, 59, 0.75);
            border-radius: 12px;
            overflow: hidden;
          }
          th, td {
            padding: 10px 12px;
            border-bottom: 1px solid rgba(255, 255, 255, 0.08);
            text-align: right;
            font-size: 13px;
          }
          th {
            background: rgba(2, 132, 199, 0.25);
            color: #fbbf24;
            font-weight: 800;
          }
          @media print {
            body { background: #fff; color: #000; }
            .btn-group { display: none; }
            th { background: #e2e8f0; color: #000; }
          }
        </style>
      </head>
      <body>
        <div class="top-bar">
          <div>
            <h2>📄 كشف وتقرير الوحدات — مكتبة محمد عادل</h2>
            <div style="font-size:12px;color:#cbd5e1;margin-top:3px;">إجمالي الوحدات المرصودة في المشهد: #{rows.length} وحدة</div>
          </div>
          <div class="btn-group">
            <button onclick="window.print()">🖨️ طباعة / حفظ PDF</button>
          </div>
        </div>
        <table>
          <thead>
            <tr>
              <th>#</th>
              <th>كود الوحدة</th>
              <th>اسم الوحدة</th>
              <th>العرض (سم)</th>
              <th>العمق (سم)</th>
              <th>الارتفاع (سم)</th>
              <th>قطع منقوشة بالثمرة</th>
            </tr>
          </thead>
          <tbody id="reportBody"></tbody>
        </table>
        <script>
          const ROWS = #{rows_json};
          const tbody = document.getElementById('reportBody');
          if (ROWS.length === 0) {
            tbody.innerHTML = '<tr><td colspan="7" style="text-align:center;padding:24px;">لا توجد وحدات في المشهد حالياً.</td></tr>';
          } else {
            tbody.innerHTML = ROWS.map(r => `
              <tr>
                <td>${r.index}</td>
                <td style="font-weight:800;color:#38bdf8;">${r.code}</td>
                <td style="font-weight:700;">${r.name}</td>
                <td>${r.width_cm}</td>
                <td>${r.depth_cm}</td>
                <td>${r.height_cm}</td>
                <td>${r.grained_parts} قطعة</td>
              </tr>
            `).join('');
          }
        </script>
      </body>
      </html>
    HTML

    dlg.set_html(html)
    dlg.show
    @units_report_dlg = dlg
    true
  end

  # 11) لوحة التسعير وإصدار عرض السعر (Pricing Studio Dialog)
  @pricing_studio_dlg = nil

  def self.open_pricing_studio_dialog
    rows = collect_project_units_summary
    total_linear_m = (rows.inject(0.0) { |s, r| s + r['width_cm'].to_f } / 100.0).round(2) rescue 0.0
    total_area_m2  = (rows.inject(0.0) { |s, r| s + ((r['width_cm'].to_f * r['height_cm'].to_f) / 10000.0) }).round(2) rescue 0.0

    dlg = UI::HtmlDialog.new({
      :dialog_title    => 'لوحة التسعير وعرض السعر — مكتبة محمد عادل',
      :preferences_key => 'DolaPricingStudio_v2',
      :scrollable      => true,
      :resizable       => true,
      :width           => 540,
      :height          => 620,
      :style           => UI::HtmlDialog::STYLE_DIALOG
    })

    html = <<~HTML
      <!DOCTYPE html>
      <html lang="ar" dir="rtl">
      <head>
        <meta charset="UTF-8">
        <link href="https://fonts.googleapis.com/css2?family=Tajawal:wght@500;700;800&display=swap" rel="stylesheet">
        <style>
          * { box-sizing: border-box; }
          body {
            margin: 0; padding: 16px;
            font-family: 'Tajawal', sans-serif;
            background: linear-gradient(160deg, #1e1b4b 0%, #0f172a 100%);
            color: #f8fafc;
          }
          .card {
            background: rgba(30, 41, 59, 0.78);
            border: 1px solid rgba(56, 189, 248, 0.3);
            border-radius: 14px;
            padding: 14px;
            margin-bottom: 12px;
          }
          h2 { margin: 0 0 6px; font-size: 17px; color: #fbbf24; }
          .stats-grid {
            display: grid;
            grid-template-columns: repeat(3, 1fr);
            gap: 8px;
            margin-top: 8px;
          }
          .stat-box {
            background: rgba(15, 23, 42, 0.9);
            border: 1px solid rgba(255, 255, 255, 0.1);
            border-radius: 10px;
            padding: 8px;
            text-align: center;
          }
          .stat-val { font-size: 17px; font-weight: 800; color: #38bdf8; }
          .stat-lbl { font-size: 11px; color: #cbd5e1; }
          .form-row {
            display: grid;
            grid-template-columns: 1.2fr 1fr;
            align-items: center;
            gap: 8px;
            margin-bottom: 9px;
          }
          label { font-size: 13px; font-weight: 700; }
          input {
            width: 100%;
            padding: 8px 10px;
            border-radius: 8px;
            background: #0f172a;
            border: 1px solid rgba(56, 189, 248, 0.4);
            color: #fff;
            font-family: 'Tajawal', sans-serif;
            font-size: 13px;
            font-weight: 700;
          }
          .total-banner {
            background: linear-gradient(135deg, rgba(16, 185, 129, 0.25), rgba(2, 132, 199, 0.25));
            border: 1px solid #34d399;
            border-radius: 14px;
            padding: 14px;
            text-align: center;
          }
          .total-num { font-size: 26px; font-weight: 800; color: #34d399; margin: 4px 0; }
          .print-btn {
            width: 100%;
            margin-top: 10px;
            background: linear-gradient(135deg, #d97706, #b45309);
            border: none;
            color: #fff;
            padding: 11px;
            border-radius: 10px;
            font-family: 'Tajawal', sans-serif;
            font-size: 14px;
            font-weight: 800;
            cursor: pointer;
          }
        </style>
      </head>
      <body>
        <div class="card">
          <h2>💰 استوديو التسعير الذكي — مكتبة محمد عادل</h2>
          <div class="stats-grid">
            <div class="stat-box">
              <div class="stat-val">#{rows.length}</div>
              <div class="stat-lbl">عدد الوحدات</div>
            </div>
            <div class="stat-box">
              <div class="stat-val" id="linearM">#{total_linear_m}</div>
              <div class="stat-lbl">إجمالي المتر الطولي</div>
            </div>
            <div class="stat-box">
              <div class="stat-val" id="areaM2">#{total_area_m2}</div>
              <div class="stat-lbl">المساحة الواجهية (م²)</div>
            </div>
          </div>
        </div>

        <div class="card">
          <div class="form-row">
            <label>اسم العميل / المشروع:</label>
            <input type="text" id="clientName" placeholder="اسم العميل...">
          </div>
          <div class="form-row">
            <label>سعر المتر المربع (ج.م):</label>
            <input type="number" id="pricePerM2" value="6500" oninput="calcTotal()">
          </div>
          <div class="form-row">
            <label>تكلفة الإكسسوارات والمفصلات (ج.م):</label>
            <input type="number" id="accessoriesCost" value="3500" oninput="calcTotal()">
          </div>
          <div class="form-row">
            <label>تكلفة النقل والتركيب (ج.م):</label>
            <input type="number" id="installCost" value="1500" oninput="calcTotal()">
          </div>
          <div class="form-row">
            <label>خصم خاص للعميل (ج.م):</label>
            <input type="number" id="discountVal" value="0" oninput="calcTotal()">
          </div>
        </div>

        <div class="total-banner">
          <div style="font-size:13px;color:#cbd5e1;">إجمالي عرض السعر النهائي</div>
          <div class="total-num" id="finalTotal">0 ج.م</div>
          <button class="print-btn" onclick="window.print()">🖨️ طباعة عرض السعر للعميل</button>
        </div>

        <script>
          const AREA_M2 = #{total_area_m2};
          function calcTotal() {
            const pm2  = parseFloat(document.getElementById('pricePerM2').value || '0') || 0;
            const acc  = parseFloat(document.getElementById('accessoriesCost').value || '0') || 0;
            const inst = parseFloat(document.getElementById('installCost').value || '0') || 0;
            const disc = parseFloat(document.getElementById('discountVal').value || '0') || 0;
            const total = Math.max(0, Math.round((AREA_M2 * pm2) + acc + inst - disc));
            document.getElementById('finalTotal').textContent = total.toLocaleString('ar-EG') + ' ج.م';
          }
          calcTotal();
        </script>
      </body>
      </html>
    HTML

    dlg.set_html(html)
    dlg.show
    @pricing_studio_dlg = dlg
    true
  end

  # ============================================================================
  #  تجهيز القوائم في Extensions (Plugins) وقائمة الكليك يمين (Context Menu)
  # ============================================================================
  unless @dola_core_menus_installed
    @dola_core_menus_installed = true

    begin
      plugins_menu = UI.menu('Plugins')
      sub = plugins_menu.add_submenu('مكتبة محمد عادل — الشريط والأدوات')

      sub.add_item('🏛️ فتح معرض مكتبة محمد عادل (3D)') { dispatch_core_action('open_library') }
      sub.add_separator

      sub.add_item('👁️ إظهار شريط الأدوات (حسب الوضع المختار)') { show_tools_bar }
      sub.add_item('🙈 إخفاء شريط الأدوات') { hide_tools_bar }
      sub.add_separator

      sub.add_item('📱 اختيار الوضع: سلايدر جانبي عائم (Slider)') { set_bar_mode('slider') }
      sub.add_item('🧰 اختيار الوضع: تول بار سكتش أب (Toolbar)') { set_bar_mode('toolbar') }
      sub.add_item('✨ إظهار الاثنين معاً (Slider + Toolbar)') { set_bar_mode('both') }
      sub.add_separator

      sub.add_item('⚙️ خيارات الوحدة المحددة (Component Options)') { open_unit_options_dialog }
      sub.add_item('🪵↕ توحيد ثمرة الخشب بالطول (Z) للكل') { DolaWoodGrainManager.align_all_wood_grain_to_z! }
      sub.add_item('🪵🔄 أداة قلب ثمرة الخشب فردياً (قطعة بقطعة)') { DolaWoodGrainManager.activate_single_part_grain_tool }
      sub.add_separator

      sub.add_item('🎨 مستويات وخامات المطبخ') { open_kitchen_materials_tool }
      sub.add_item('🚪 تبديل تصميم الضلفة') { open_door_style_dialog }
      sub.add_item('🪚 حفر مجرى الليد (LED Groove)') { open_led_groove_dialog }
      sub.add_item('🧲 أداة اللزق جنب بجنب (Side Snap)') { activate_click_side_snap_tool }
      sub.add_item('🌐 ترجمة أسماء القطع للعربية') { run_arabic_part_translator }
      sub.add_item('🔢 ترقيم الوحدات تسلسلياً') { open_serial_numbering_dialog }
      sub.add_item('📄 إنشاء تقرير الوحدات') { open_units_report_dialog }
      sub.add_item('💰 لوحة التسعير وعرض السعر') { open_pricing_studio_dialog }

      if respond_to?(:reload_core_rb_from_github)
        sub.add_separator
        sub.add_item('🔄 تحديث ملف الأدوات (core.rb) من GitHub') { reload_core_rb_from_github(true) }
      end
    rescue => e
      puts "Menu setup error: #{e.message}"
    end

    begin
      UI.add_context_menu_handler do |context_menu|
        sel = Sketchup.active_model.selection
        if sel && !sel.empty?
          dola_ctx = context_menu.add_submenu('مكتبة محمد عادل')
          dola_ctx.add_item('⚙️ خيارات الوحدة المحددة') { open_unit_options_dialog }
          dola_ctx.add_item('🪵↕ توحيد ثمرة الخشب بالطول (Z)') { DolaWoodGrainManager.align_all_wood_grain_to_z! }
          dola_ctx.add_item('🪵🔄 أداة قلب ثمرة الخشب (قطعة بقطعة)') { DolaWoodGrainManager.activate_single_part_grain_tool }
          dola_ctx.add_separator
          dola_ctx.add_item('↻ تدوير الوحدة 45°') { activate_rotate_tool }
          dola_ctx.add_item('⇆ قلب يمين / شمال') { activate_flip_lr_tool }
          dola_ctx.add_item('🧲 لزق جنب بجنب (Side Snap)') { activate_click_side_snap_tool }
        end
      end
    rescue
    end

    # تطبيق تفضيلات شريط الأدوات تلقائياً عند التحميل
    UI.start_timer(0.4, false) do
      begin
        apply_bar_preferences
      rescue
      end
    end
  end

end

MHDESIGN = DolaSmartLibraryPlugin unless Object.const_defined?(:MHDESIGN)