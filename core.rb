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

  CORE_VERSION = '2.5.0'.freeze unless const_defined?(:CORE_VERSION, false)
  PREF_NS      = 'DolaSmartLibrary'.freeze unless const_defined?(:PREF_NS, false)
  GRAIN_DICT   = 'DolaWoodGrain'.freeze unless const_defined?(:GRAIN_DICT, false)
  OCL_DICT     = 'ladb_opencutlist'.freeze unless const_defined?(:OCL_DICT, false)

  # قائمة الأدوات الـ 14 الموحدة في كل من الـ Slider العائم والـ Toolbar الأصلي
  CORE_TOOLS_SPEC = [
    {
      :id      => 'component_options',
      :title   => 'خيارات الوحدة',
      :short   => 'خيارات الوحدة',
      :tooltip => 'فتح نافذة خيارات ومقاسات الوحدة المحددة (بديل Component Options)',
      :icon    => '⚙️',
      :group   => 'main',
      :rgb     => [2, 132, 199],
      :symbol  => :gear
    },
    {
      :id      => 'wood_grain_all_z',
      :title   => 'توحيد الثمرة بالطول (Z)',
      :short   => 'ثمرة بالطول (Z)',
      :tooltip => 'ضبط اتجاه ثمرة الخشب بالطول (في اتجاه Z) لكل الأخشاب المنقوشة في الرسم والـ Cutting List',
      :icon    => '🪵↕',
      :group   => 'grain',
      :rgb     => [217, 119, 6],
      :symbol  => :grain_z
    },
    {
      :id      => 'wood_grain_single_tool',
      :title   => 'قلب ثمرة قطعة (يدوي)',
      :short   => 'قلب ثمرة قطعة',
      :tooltip => 'أداة تفاعلية بكاشف بصري لمعرفة وقلب اتجاه ثمرة أي قطعة خشبية منقوشة بين الطول والعرض',
      :icon    => '🪵🔄',
      :group   => 'grain',
      :rgb     => [245, 158, 11],
      :symbol  => :grain_flip
    },
    {
      :id      => 'rotate90',
      :title   => 'تدوير الوحدة 45°',
      :short   => 'تدوير 45°',
      :tooltip => 'أداة تدوير أي وحدة 45 درجة حول مركزها بالضغط عليها',
      :icon    => '↻',
      :group   => 'transform',
      :rgb     => [14, 165, 233],
      :symbol  => :rotate
    },
    {
      :id      => 'flip_lr',
      :title   => 'قلب يمين / شمال',
      :short   => 'قلب يمين/شمال',
      :tooltip => 'أداة قلب ومرايا الوحدة يمين/شمال بالضغط عليها',
      :icon    => '⇆',
      :group   => 'transform',
      :rgb     => [56, 189, 248],
      :symbol  => :flip
    },
    {
      :id      => 'snap_side',
      :title   => 'لزق جنب بجنب (Snap)',
      :short   => 'لزق جنب بجنب',
      :tooltip => 'أداة محاذاة ولزق وحدة بجانب وحدة أخرى تلقائياً (Click Side Snap)',
      :icon    => '🧲',
      :group   => 'transform',
      :rgb     => [16, 185, 129],
      :symbol  => :snap
    },
    {
      :id      => 'classic_door',
      :title   => 'تبديل الضلفة',
      :short   => 'تبديل الضلفة',
      :tooltip => 'تبديل شكل وتصميم الضلفة (سادة مودرن / شيكر كلاسيك / زجاج / مقبض مخفي)',
      :icon    => '🚪',
      :group   => 'kitchen',
      :rgb     => [139, 92, 246],
      :symbol  => :door
    },
    {
      :id      => 'hand_groove',
      :title   => 'حفر ليد (LED Groove)',
      :short   => 'حفر ليد LED',
      :tooltip => 'إضافة أو حفر مجرى بروفايل الإضاءة الليد في الوحدات العلوية أو الدواليب',
      :icon    => '🪚',
      :group   => 'kitchen',
      :rgb     => [234, 179, 8],
      :symbol  => :led
    },
    {
      :id      => 'kitchen_materials',
      :title   => 'مستويات وخامات المطبخ',
      :short   => 'خامات المطبخ',
      :tooltip => 'إدارة وتطبيق خامات ونقشات الخشب والـ HPL والضهر الخشابي والشاسيهات للمطبخ',
      :icon    => '🎨',
      :group   => 'kitchen',
      :rgb     => [236, 72, 153],
      :symbol  => :palette
    },
    {
      :id      => 'serial_tool',
      :title   => 'ترقيم الوحدات',
      :short   => 'ترقيم الوحدات',
      :tooltip => 'ترقيم وحدات المطبخ والدريسنج تسلسلياً للتقارير والـ Cutting List',
      :icon    => '🔢',
      :group   => 'utility',
      :rgb     => [99, 102, 241],
      :symbol  => :serial
    },
    {
      :id      => 'unique',
      :title   => 'جعل الكمبوننتات فريدة',
      :short   => 'كمبوننتات فريدة',
      :tooltip => 'فك ارتباط جميع الكمبوننتات المحددة أو في المشروع وجعل كل منها فريداً (Make Unique)',
      :icon    => '🔁',
      :group   => 'utility',
      :rgb     => [20, 184, 166],
      :symbol  => :unique
    },
    {
      :id      => 'component_translator',
      :title   => 'ترجمة أسماء القطع',
      :short   => 'ترجمة القطع',
      :tooltip => 'ترجمة وتعريب أسماء جميع القطع الداخلية للوحدات لتظهر بالعربية في الـ Cutting List',
      :icon    => '🌐',
      :group   => 'utility',
      :rgb     => [6, 182, 212],
      :symbol  => :translate
    },
    {
      :id      => 'report',
      :title   => 'إنشاء تقرير الوحدات',
      :short   => 'تقرير الوحدات',
      :tooltip => 'إنشاء كشف وتقرير شامل بجميع الوحدات ومقاساتها وخاماتها مع إمكانية الطباعة والتصدير',
      :icon    => '📄',
      :group   => 'reports',
      :rgb     => [59, 130, 246],
      :symbol  => :report
    },
    {
      :id      => 'pricing_launcher',
      :title   => 'لوحة التسعير وعرض السعر',
      :short   => 'لوحة التسعير',
      :tooltip => 'حساب التكلفة وألواح الخشب والأمتار وإصدار عرض سعر تفصيلي للعميل',
      :icon    => '💰',
      :group   => 'reports',
      :rgb     => [34, 197, 94],
      :symbol  => :pricing
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
    val = mode.to_s.strip.downcase
    val = 'slider' unless %w[slider toolbar both].include?(val)
    Sketchup.write_default(PREF_NS, 'bar_mode', val) rescue nil
    val
  end

  def self.saved_bar_visible?
    val = Sketchup.read_default(PREF_NS, 'bar_visible', '1').to_s.strip.downcase
    !(val == '0' || val == 'false')
  rescue
    true
  end

  def self.save_bar_visible(visible)
    Sketchup.write_default(PREF_NS, 'bar_visible', visible ? '1' : '0') rescue nil
  end

  def self.auto_open_options_enabled?
    val = Sketchup.read_default(PREF_NS, 'auto_open_options', '1').to_s.strip.downcase
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
  #  توليد أيقونات PNG حقيقية للـ SketchUp Toolbar بدون مكتبات خارجية
  # ============================================================================
  def self.toolbar_icons_dir
    base = defined?(OFFLINE_DIR) ? OFFLINE_DIR : File.join(Dir.tmpdir, 'dola_offline_cache')
    dir = File.join(base, 'toolbar_icons_v2')
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

    # رسم خلفية دائرية الحواف باللون الكحلي الداكن مع إطار بلون الأداة
    br, bg, bb = rgb
    pad = 1
    (pad...(h - pad)).each do |y|
      (pad...(w - pad)).each do |x|
        # تقليم الأركان الأربعة
        corner_dist = 0
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
          set_px.call(x, y, br, bg, bb, 255)
        else
          set_px.call(x, y, 22, 27, 64, 255)
        end
      end
    end

    mid = w / 2
    t = w >= 22 ? 2 : 1
    case symbol
    when :library
      draw_line.call(5, 7, w - 6, 7, 56, 189, 248, t)
      draw_line.call(5, mid, w - 6, mid, 251, 191, 36, t)
      draw_line.call(5, h - 7, w - 6, h - 7, 56, 189, 248, t)
    when :gear
      draw_line.call(mid, 5, mid, h - 6, 56, 189, 248, t)
      draw_line.call(5, mid, w - 6, mid, 56, 189, 248, t)
      draw_line.call(7, 7, w - 8, h - 8, 56, 189, 248, 1)
      draw_line.call(w - 8, 7, 7, h - 8, 56, 189, 248, 1)
      (-2..2).each { |ox| (-2..2).each { |oy| set_px.call(mid + ox, mid + oy, 251, 191, 36, 255) } }
    when :grain_z
      # خطوط ثمرة رأسية + سهم رأسي
      draw_line.call(7, 6, 7, h - 7, 251, 191, 36, 1)
      draw_line.call(mid, 5, mid, h - 6, 255, 255, 255, t)
      draw_line.call(w - 8, 6, w - 8, h - 7, 251, 191, 36, 1)
      draw_line.call(mid, 5, mid - 3, 9, 255, 255, 255, t)
      draw_line.call(mid, 5, mid + 3, 9, 255, 255, 255, t)
      draw_line.call(mid, h - 6, mid - 3, h - 10, 255, 255, 255, t)
      draw_line.call(mid, h - 6, mid + 3, h - 10, 255, 255, 255, t)
    when :grain_flip
      # سهم رأسي وسهم أفقي متقاطعان
      draw_line.call(mid, 5, mid, h - 6, 56, 189, 248, t)
      draw_line.call(5, mid, w - 6, mid, 251, 191, 36, t)
      draw_line.call(mid, 5, mid - 3, 8, 56, 189, 248, 1)
      draw_line.call(mid, 5, mid + 3, 8, 56, 189, 248, 1)
      draw_line.call(w - 6, mid, w - 9, mid - 3, 251, 191, 36, 1)
      draw_line.call(w - 6, mid, w - 9, mid + 3, 251, 191, 36, 1)
    when :rotate
      draw_line.call(7, 7, w - 7, 7, 56, 189, 248, t)
      draw_line.call(w - 7, 7, w - 7, h - 7, 56, 189, 248, t)
      draw_line.call(w - 7, h - 7, 7, h - 7, 56, 189, 248, t)
      draw_line.call(7, 7, 11, 5, 251, 191, 36, t)
      draw_line.call(7, 7, 11, 10, 251, 191, 36, t)
    when :flip
      draw_line.call(5, mid, w - 6, mid, 56, 189, 248, t)
      draw_line.call(5, mid, 9, mid - 4, 56, 189, 248, t)
      draw_line.call(5, mid, 9, mid + 4, 56, 189, 248, t)
      draw_line.call(w - 6, mid, w - 10, mid - 4, 251, 191, 36, t)
      draw_line.call(w - 6, mid, w - 10, mid + 4, 251, 191, 36, t)
    when :snap
      draw_line.call(6, 6, mid - 1, 6, 16, 185, 129, t)
      draw_line.call(6, 6, 6, h - 7, 16, 185, 129, t)
      draw_line.call(6, h - 7, mid - 1, h - 7, 16, 185, 129, t)
      draw_line.call(mid + 1, 6, w - 7, 6, 251, 191, 36, t)
      draw_line.call(w - 7, 6, w - 7, h - 7, 251, 191, 36, t)
      draw_line.call(mid + 1, h - 7, w - 7, h - 7, 251, 191, 36, t)
    when :door
      draw_line.call(7, 5, w - 8, 5, 196, 181, 253, t)
      draw_line.call(7, h - 6, w - 8, h - 6, 196, 181, 253, t)
      draw_line.call(7, 5, 7, h - 6, 196, 181, 253, t)
      draw_line.call(w - 8, 5, w - 8, h - 6, 196, 181, 253, t)
      set_px.call(w - 11, mid, 251, 191, 36, 255)
      set_px.call(w - 11, mid + 1, 251, 191, 36, 255)
    when :led
      draw_line.call(5, mid, w - 6, mid, 253, 224, 71, t + 1)
      draw_line.call(8, mid - 4, 8, mid - 6, 253, 224, 71, 1)
      draw_line.call(mid, mid - 4, mid, mid - 7, 253, 224, 71, 1)
      draw_line.call(w - 9, mid - 4, w - 9, mid - 6, 253, 224, 71, 1)
    when :palette
      (-3..3).each { |ox| (-3..3).each { |oy| set_px.call(8 + ox, 8 + oy, 244, 114, 182, 255) } }
      (-3..3).each { |ox| (-3..3).each { |oy| set_px.call(w - 9 + ox, 8 + oy, 56, 189, 248, 255) } }
      (-3..3).each { |ox| (-3..3).each { |oy| set_px.call(mid + ox, h - 9 + oy, 251, 191, 36, 255) } }
    when :serial
      draw_line.call(8, 6, 8, h - 7, 165, 180, 252, t)
      draw_line.call(w - 9, 6, w - 9, h - 7, 165, 180, 252, t)
      draw_line.call(5, 9, w - 6, 9, 251, 191, 36, t)
      draw_line.call(5, h - 10, w - 6, h - 10, 251, 191, 36, t)
    when :unique
      draw_line.call(6, 8, mid + 2, 8, 45, 212, 191, t)
      draw_line.call(6, 8, 6, h - 6, 45, 212, 191, t)
      draw_line.call(mid - 2, 6, w - 6, 6, 251, 191, 36, t)
      draw_line.call(w - 6, 6, w - 6, h - 8, 251, 191, 36, t)
    when :translate
      draw_line.call(6, 7, w - 7, 7, 34, 211, 238, t)
      draw_line.call(mid, 7, mid, h - 7, 34, 211, 238, t)
      draw_line.call(7, h - 7, w - 8, 11, 251, 191, 36, 1)
    when :report
      draw_line.call(7, 5, w - 8, 5, 147, 197, 253, t)
      draw_line.call(7, 5, 7, h - 6, 147, 197, 253, t)
      draw_line.call(w - 8, 5, w - 8, h - 6, 147, 197, 253, t)
      draw_line.call(7, h - 6, w - 8, h - 6, 147, 197, 253, t)
      draw_line.call(10, 10, w - 11, 10, 251, 191, 36, 1)
      draw_line.call(10, mid, w - 11, mid, 251, 191, 36, 1)
    when :pricing
      draw_line.call(mid, 5, mid, h - 5, 74, 222, 128, t)
      draw_line.call(8, 8, w - 9, 8, 251, 191, 36, t)
      draw_line.call(8, mid, w - 9, mid, 251, 191, 36, t)
      draw_line.call(8, h - 9, w - 9, h - 9, 251, 191, 36, t)
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
  #  بتصميم وهوية «مكتبة محمد عادل» (الكحلي الداكن الزجاجي + الأزرق السماوي + الذهبي)
  # ============================================================================
  @floating_slider_dlg = nil
  @slider_collapsed = false

  def self.open_floating_slider
    if @floating_slider_dlg && @floating_slider_dlg.visible?
      @floating_slider_dlg.bring_to_front rescue nil
      return true
    end

    @slider_collapsed = (Sketchup.read_default(PREF_NS, 'slider_collapsed', '0').to_s == '1')
    init_w = @slider_collapsed ? 78 : 225
    init_h = 690

    @floating_slider_dlg = UI::HtmlDialog.new({
      :dialog_title    => 'شريط أدوات مكتبة محمد عادل',
      :preferences_key => 'DolaFloatingSliderBar_v2',
      :scrollable      => false,
      :resizable       => true,
      :width           => init_w,
      :height          => init_h,
      :left            => 18,
      :top             => 95,
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
            background: rgba(15, 23, 42, 0.78);
            border: 1px solid rgba(251, 191, 36, 0.35);
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
            border: 1px solid rgba(56, 189, 248, 0.5);
            color: #ffffff;
            border-radius: 10px;
            padding: 7px 10px;
            cursor: pointer;
            font-family: 'Tajawal', sans-serif;
            font-weight: 800;
            font-size: 12px;
            display: flex;
            align-items: center;
            justify-content: center;
            gap: 7px;
            box-shadow: 0 4px 12px rgba(2, 132, 199, 0.35);
            transition: all 0.18s ease;
          }
          .open-lib-btn:hover {
            filter: brightness(1.12);
            transform: translateY(-1px);
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
            padding: 7px 9px;
            border-radius: 10px;
            background: rgba(30, 41, 59, 0.78);
            border: 1px solid rgba(255, 255, 255, 0.1);
            color: #f1f5f9;
            cursor: pointer;
            font-family: 'Tajawal', sans-serif;
            font-size: 12px;
            font-weight: 700;
            text-align: right;
            transition: all 0.16s ease;
          }
          .tool-btn:hover {
            background: rgba(2, 132, 199, 0.28);
            border-color: rgba(56, 189, 248, 0.65);
            transform: translateY(-1px);
            box-shadow: 0 4px 12px rgba(0, 0, 0, 0.28);
          }
          .tool-btn.grain-highlight {
            background: linear-gradient(135deg, rgba(217, 119, 6, 0.24) 0%, rgba(180, 83, 9, 0.18) 100%);
            border-color: rgba(251, 191, 36, 0.45);
          }
          .tool-btn.grain-highlight:hover {
            background: linear-gradient(135deg, rgba(217, 119, 6, 0.45) 0%, rgba(180, 83, 9, 0.35) 100%);
            border-color: #fbbf24;
          }
          .tool-btn.options-highlight {
            background: linear-gradient(135deg, rgba(2, 132, 199, 0.32) 0%, rgba(30, 27, 75, 0.85) 100%);
            border-color: rgba(56, 189, 248, 0.55);
          }
          .tool-icon {
            width: 28px;
            height: 28px;
            border-radius: 8px;
            background: rgba(15, 23, 42, 0.85);
            border: 1px solid rgba(255, 255, 255, 0.12);
            display: flex;
            align-items: center;
            justify-content: center;
            font-size: 14px;
            flex-shrink: 0;
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

          /* وضع الأيقونات المصغر (Collapsed) */
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
            padding: 6px;
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
            <span>🏛️</span>
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
              let extraCls = '';
              if (t.group === 'grain') extraCls = 'grain-highlight';
              if (t.id === 'component_options') extraCls = 'options-highlight';
              html += `
                <button class="tool-btn ${extraCls}" onclick="runTool('${t.id}')" title="${t.tooltip}">
                  <span class="tool-icon">${t.icon}</span>
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
        cur_h = 690 if cur_h.to_i < 300
        @floating_slider_dlg.set_size(@slider_collapsed ? 78 : 225, cur_h.to_i)
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
  #  الوضع الثاني: شريط أدوات سكتش أب الرسمي (SketchUp Native UI::Toolbar)
  # ============================================================================
  @native_tools_toolbar = nil

  def self.ensure_native_toolbar
    return @native_tools_toolbar if @native_tools_toolbar

    tb = UI::Toolbar.new('أدوات مكتبة محمد عادل')
    icons_folder = toolbar_icons_dir

    # زر فتح المعرض الرئيسي
    lib_cmd = UI::Command.new('معرض مكتبة محمد عادل 3D') { dispatch_core_action('open_library') }
    lib_cmd.tooltip = 'فتح معرض مكتبة محمد عادل (المطابخ والدريسنج)'
    lib_cmd.status_bar_text = 'فتح معرض مكتبة محمد عادل الثلاثي الأبعاد'
    s16 = generate_tool_icon_png(File.join(icons_folder, 'lib_16.png'), 16, [2, 132, 199], :library)
    s24 = generate_tool_icon_png(File.join(icons_folder, 'lib_24.png'), 24, [2, 132, 199], :library)
    lib_cmd.small_icon = s16 if s16 && File.exist?(s16)
    lib_cmd.large_icon = s24 if s24 && File.exist?(s24)
    tb.add_item(lib_cmd)
    tb.add_separator

    last_group = nil
    CORE_TOOLS_SPEC.each do |spec|
      if last_group && last_group != spec[:group]
        tb.add_separator
      end
      last_group = spec[:group]

      cmd = UI::Command.new(spec[:title]) { dispatch_core_action(spec[:id]) }
      cmd.tooltip = spec[:title]
      cmd.status_bar_text = spec[:tooltip]

      ic16 = generate_tool_icon_png(File.join(icons_folder, "#{spec[:id]}_16.png"), 16, spec[:rgb], spec[:symbol])
      ic24 = generate_tool_icon_png(File.join(icons_folder, "#{spec[:id]}_24.png"), 24, spec[:rgb], spec[:symbol])
      cmd.small_icon = ic16 if ic16 && File.exist?(ic16)
      cmd.large_icon = ic24 if ic24 && File.exist?(ic24)

      tb.add_item(cmd)
    end

    @native_tools_toolbar = tb
    tb
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
  #  التحكم الموحد في إظهار / إخفاء / تبديل وضع الشريط (Slider vs Toolbar)
  # ============================================================================
  def self.apply_bar_preferences
    unless saved_bar_visible?
      close_floating_slider
      hide_native_toolbar
      return
    end

    case saved_bar_mode
    when 'slider'
      hide_native_toolbar
      open_floating_slider
    when 'toolbar'
      close_floating_slider
      show_native_toolbar
    when 'both'
      show_native_toolbar
      open_floating_slider
    end
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
  #  نظام التحكم المتكامل في «ثمرة الخشب» (Wood Grain) لكل الأخشاب المنقوشة
  #  (ضهر خشابي، HPL، HPL وشين، ضلف، أجناب، أرفف، قواطيع، تجاليد...)
  #  يضبط كلاً من:
  #   1) الـ Texture ثلاثي الأبعاد في المشهد
  #   2) محاور القطعة وقفل orientation_locked_on_axis في OpenCutList (Cutting List)
  # ============================================================================
  module DolaWoodGrainManager
    extend self

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

      # 1) إذا كانت الخامة تحتوي على Texture صورة فعلية (نقشة خشبية)
      return true if mat && mat.texture

      # 2) إذا كان اسم الخامة أو اسم القطعة يشير إلى خشابي / HPL / HPL وشين / ضهر خشابي
      mat_name = mat ? "#{mat.display_name} #{mat.name}".downcase : ''
      part_name = entity_display_name(entity).downcase
      combined = "#{mat_name} #{part_name}"
      return true if WOOD_GRAIN_KEYWORDS.any? { |kw| combined.include?(kw) }

      # 3) إذا كان قد تم تعيين اتجاه ثمرة سابقاً على القطعة
      saved = entity.get_attribute(GRAIN_DICT, 'grain_dir', nil)
      return true unless saved.to_s.empty?

      false
    rescue
      false
    end

    # توليد خامة خشبية منقوشة افتراضية إن كانت الخامة تحمل اسم خشابي/HPL بدون صورة Texture
    def ensure_procedural_wood_texture!(mat)
      return nil unless mat
      return mat if mat.texture
      return mat unless defined?(Zlib)

      tex_path = File.join(DolaSmartLibraryPlugin.toolbar_icons_dir, 'dola_wood_grain_tex.png')
      unless File.exist?(tex_path) && File.size(tex_path) > 100
        w = 64
        h = 64
        c = mat.color || Sketchup::Color.new(185, 135, 88)
        base_r = c.red
        base_g = c.green
        base_b = c.blue
        # إذا كان اللون أبيض تماماً نستخدم درجة بيج خشبي دافئ للنقشة
        if base_r > 240 && base_g > 240 && base_b > 240
          base_r, base_g, base_b = 194, 148, 102
        end
        buf = Array.new(w * h * 4, 0)
        (0...h).each do |y|
          # تمويج ألياف الخشب في اتجاه X (العرض الأفقي للصورة = محور U)
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

      # التأكد من أن لها أبعاد لوح حقيقية وليست نقطة صفرية
      bb = entity.is_a?(Sketchup::ComponentInstance) ? entity.definition.bounds : entity.bounds
      dims = [bb.width.to_f, bb.height.to_f, bb.depth.to_f].sort
      return false if dims[2] < 0.2.cm
      true
    rescue
      false
    end

    # جمع كل القطع اللوحية داخل الكيان (مع تحويل العالم والخامة الموروثة)
    def collect_wooden_boards(roots, require_texture_only = true)
      results = []
      visited = {}

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
              :entity       => ent,
              :parent_tr    => parent_tr,
              :world_tr     => world_tr,
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

    # فحص هندسة اللوح واتجاه الثمرة الحالي بدقة
    def inspect_part_grain(entity, parent_tr = Geom::Transformation.new, inherited_mat = nil)
      return nil unless leaf_wooden_board?(entity)
      world_tr = parent_tr * entity.transformation
      bb = entity.is_a?(Sketchup::ComponentInstance) ? entity.definition.bounds : entity.bounds

      local_dims = [bb.width.to_f, bb.height.to_f, bb.depth.to_f]
      world_vecs = [world_tr.xaxis, world_tr.yaxis, world_tr.zaxis]
      scales = world_vecs.map { |v| v.length > 1e-6 ? v.length : 1.0 }
      world_dims = [local_dims[0] * scales[0], local_dims[1] * scales[1], local_dims[2] * scales[2]]

      unit_vecs = world_vecs.map do |v|
        c = v.clone
        c.normalize! rescue nil
        c
      end

      # المحور الأصغر هو التخانة (Thickness)
      thick_idx = [0, 1, 2].min_by { |i| world_dims[i] }
      plane_indices = [0, 1, 2] - [thick_idx]
      i1, i2 = plane_indices
      u1 = unit_vecs[i1]
      u2 = unit_vecs[i2]

      # تحديد أي المحورين في مستوى اللوح هو محور الطول الرأسي (Z) وأيهما محور العرض الأفقي
      if u1.z.abs >= 0.45 || u2.z.abs >= 0.45
        vert_idx  = (u1.z.abs >= u2.z.abs) ? i1 : i2
        horiz_idx = (vert_idx == i1) ? i2 : i1
        is_vertical_board = true
      else
        # لوح أفقي (مثل الرف أو القاعدة أو البرنيطة): الطول مع عرض الوحدة (X) والعرض مع العمق (Y)
        vert_idx  = (u1.x.abs >= u2.x.abs) ? i1 : i2
        horiz_idx = (vert_idx == i1) ? i2 : i1
        is_vertical_board = false
      end

      # معرفة الاتجاه الفعلي الحالي للثمرة في الرسم والـ OpenCutList
      defn = entity.is_a?(Sketchup::ComponentInstance) ? entity.definition : nil
      saved_dir = entity.get_attribute(GRAIN_DICT, 'grain_dir', nil)
      saved_dir = defn.get_attribute(GRAIN_DICT, 'grain_dir', nil) if saved_dir.to_s.empty? && defn
      ocl_locked = defn ? (defn.get_attribute(OCL_DICT, 'orientation_locked_on_axis', false) == true) : false

      current_mode =
        if saved_dir.to_s == 'vertical_z'
          :vertical_z
        elsif saved_dir.to_s == 'horizontal_x'
          :horizontal_x
        elsif ocl_locked
          # عندما يكون مقفولاً على المحور في OpenCutList فإن المحور المحلي X (رقم 0) هو محور الطول (الثمرة)
          (vert_idx == 0) ? :vertical_z : :horizontal_x
        else
          # الوضع الافتراضي في OpenCutList بدون قفل هو أخذ البعد الأكبر كطول
          (world_dims[vert_idx] >= world_dims[horiz_idx]) ? :vertical_z : :horizontal_x
        end

      active_grain_idx = (current_mode == :vertical_z) ? vert_idx : horiz_idx
      active_cross_idx = (current_mode == :vertical_z) ? horiz_idx : vert_idx

      grain_len_cm = (world_dims[active_grain_idx] * 2.54).round(1)
      cross_wid_cm = (world_dims[active_cross_idx] * 2.54).round(1)
      thick_mm     = (world_dims[thick_idx] * 25.4).round(1)

      mat = effective_material_for(entity, inherited_mat)
      mat_title = mat ? mat.display_name.to_s : 'خشب'

      # حساب أركان الـ BoundingBox في إحداثيات العالم للرسم البصري
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

      {
        :entity            => entity,
        :name              => entity_display_name(entity),
        :material_name     => mat_title,
        :has_grain         => has_wood_grain_material?(entity, inherited_mat),
        :is_vertical_board => is_vertical_board,
        :mode              => current_mode,
        :mode_label        => (current_mode == :vertical_z ? 'بالطول ↕ (اتجاه Z)' : 'بالعرض ↔ (اتجاه X)'),
        :vert_idx          => vert_idx,
        :horiz_idx         => horiz_idx,
        :thick_idx         => thick_idx,
        :grain_idx         => active_grain_idx,
        :cross_idx         => active_cross_idx,
        :grain_len_cm      => grain_len_cm,
        :cross_wid_cm      => cross_wid_cm,
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

    # تطبيق اتجاه الثمرة (:vertical_z أو :horizontal_x) على قطعة خشبية واحدة
    # بدون تحريك أي نقطة في الفراغ، مع تدوير الـ UV Texture وقفل محور OpenCutList
    def set_part_grain!(entity, target_mode, parent_tr = Geom::Transformation.new, inherited_mat = nil)
      info = inspect_part_grain(entity, parent_tr, inherited_mat)
      return false unless info

      target_mode = (target_mode.to_sym == :horizontal_x) ? :horizontal_x : :vertical_z

      # إذا كان Group نحوله أو نعدل الـ UV وخصائصه، وإذا كان ComponentInstance نجعله فريداً أولاً
      if entity.is_a?(Sketchup::ComponentInstance) && entity.definition.count_used_instances > 1
        entity.make_unique
        info = inspect_part_grain(entity, parent_tr, inherited_mat)
      end

      desired_grain_idx = (target_mode == :vertical_z) ? info[:vert_idx] : info[:horiz_idx]
      desired_cross_idx = (target_mode == :vertical_z) ? info[:horiz_idx] : info[:vert_idx]

      local_basis = [
        Geom::Vector3d.new(1, 0, 0),
        Geom::Vector3d.new(0, 1, 0),
        Geom::Vector3d.new(0, 0, 1)
      ]

      ents = ents_of(entity)
      return false unless ents

      # 1) إعادة توجيه المحاور المحلية للـ Component/Group بحيث:
      #    Local X = اتجاه الثمرة (الطول في الـ Cutting List)
      #    Local Y = العرض العمودي على الثمرة (العرض في الـ Cutting List)
      #    Local Z = التخانة (السمك في الـ Cutting List)
      if desired_grain_idx != 0 || desired_cross_idx != 1
        new_x = local_basis[desired_grain_idx]
        new_y = local_basis[desired_cross_idx]
        new_z = new_x.cross(new_y)

        bb = entity.is_a?(Sketchup::ComponentInstance) ? entity.definition.bounds : entity.bounds
        c = bb.center
        tr_to_origin   = Geom::Transformation.translation(Geom::Vector3d.new(-c.x, -c.y, -c.z))
        tr_axes_at_c   = Geom::Transformation.axes(c, new_x, new_y, new_z)
        tr_local_remap = tr_axes_at_c * tr_to_origin

        ents.transform_entities(tr_local_remap.inverse, ents.to_a)
        entity.transform!(entity.transformation * tr_local_remap * entity.transformation.inverse) rescue (entity.transformation = entity.transformation * tr_local_remap)

        # حفظ مصفوفة التحويل المحلي لاستعادتها عند الحاجة قبل أي DC Redraw
        prev_arr = entity.get_attribute(GRAIN_DICT, 'applied_local_tr', nil)
        prev_tr = (prev_arr.is_a?(Array) && prev_arr.length == 16) ? Geom::Transformation.new(prev_arr) : Geom::Transformation.new
        combined_tr = prev_tr * tr_local_remap
        entity.set_attribute(GRAIN_DICT, 'applied_local_tr', combined_tr.to_a)
      end

      # 2) قفل اتجاه المحور في OpenCutList حتى يلتزم الكاتينج ليست باتجاه الثمرة (Local X = الطول)
      if entity.is_a?(Sketchup::ComponentInstance)
        defn = entity.definition
        defn.set_attribute(OCL_DICT, 'auto_orient', false)
        defn.set_attribute(OCL_DICT, 'orientation_locked_on_axis', true)
        defn.set_attribute(GRAIN_DICT, 'grain_dir', target_mode.to_s)
      end
      entity.set_attribute(GRAIN_DICT, 'grain_dir', target_mode.to_s)

      # 3) توجيه نقشة الخشب (UV Texture) على أوجه القطعة لتوازي المحور المحلي X (اتجاه الثمرة)
      mat = effective_material_for(entity, inherited_mat)
      if mat
        ensure_procedural_wood_texture!(mat) if mat.texture.nil? && has_wood_grain_material?(entity, inherited_mat)
        align_faces_uv_along_local_x!(ents, mat) if mat.texture
      end

      true
    rescue => e
      puts "WoodGrain set_part_grain! error: #{e.message}"
      false
    end

    # تدوير وضبط الـ UV Texture لكل وجه داخل القطعة ليوازي المحور المحلي X (الذي يمثل اتجاه الثمرة)
    def align_faces_uv_along_local_x!(ents, fallback_mat)
      local_x = Geom::Vector3d.new(1, 0, 0)
      local_y = Geom::Vector3d.new(0, 1, 0)

      ents.grep(Sketchup::Face).each do |face|
        next unless face && face.valid?
        f_mat = (face.material && face.material.texture) ? face.material : fallback_mat
        next unless f_mat && f_mat.texture

        n = face.normal
        u_dir = local_x.clone
        if u_dir.parallel?(n)
          u_dir = local_y.clone
        end
        v_dir = n.cross(u_dir)
        next if v_dir.length < 1e-6
        v_dir.normalize!
        u_dir = v_dir.cross(n)
        u_dir.normalize!

        tw = f_mat.texture.width.to_f
        th = f_mat.texture.height.to_f
        tw = 16.0 if tw <= 0.01
        th = 16.0 if th <= 0.01

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

    # استعادة المحاور الأصلية للقطع الفرعية قبل عمل Redraw للـ Dynamic Component ثم إعادة تطبيق الثمرة بعدها
    def restore_dc_axes_before_redraw!(root_unit)
      saved_states = []
      boards = collect_wooden_boards([root_unit], false)
      boards.each do |b|
        ent = b[:entity]
        next unless ent && ent.valid?
        saved_dir = ent.get_attribute(GRAIN_DICT, 'grain_dir', nil)
        arr = ent.get_attribute(GRAIN_DICT, 'applied_local_tr', nil)
        if arr.is_a?(Array) && arr.length == 16
          begin
            tr_applied = Geom::Transformation.new(arr)
            e_list = ents_of(ent)
            if e_list
              e_list.transform_entities(tr_applied, e_list.to_a)
              ent.transformation = ent.transformation * tr_applied.inverse
              ent.delete_attribute(GRAIN_DICT, 'applied_local_tr')
            end
          rescue
          end
        end
        unless saved_dir.to_s.empty?
          saved_states << { :entity => ent, :grain_dir => saved_dir.to_sym }
        end
      end
      saved_states
    rescue
      []
    end

    def reapply_grain_after_redraw!(root_unit, saved_states = [])
      # إعادة تطبيق أي اتجاه ثمرة محفوظ على القطع بعد انتهاء Redraw
      boards = collect_wooden_boards([root_unit], false)
      by_ent = {}
      saved_states.each { |s| by_ent[s[:entity]] = s[:grain_dir] if s[:entity] && s[:entity].valid? }

      boards.each do |b|
        ent = b[:entity]
        dir = by_ent[ent] || ent.get_attribute(GRAIN_DICT, 'grain_dir', nil)
        next if dir.to_s.empty?
        set_part_grain!(ent, dir.to_sym, b[:parent_tr], b[:inherited_mat])
      end
    rescue
    end

    # الزرار الأول: توحيد ثمرة الخشب بالطول (في اتجاه Z) لكل الأخشاب المنقوشة
    def align_all_wood_grain_to_z!
      model = Sketchup.active_model
      sel = model.selection.to_a.select { |e| e.is_a?(Sketchup::ComponentInstance) || e.is_a?(Sketchup::Group) }

      roots = sel
      if roots.empty?
        ans = UI.messagebox(
          "لم تقم بتحديد وحدة معينة.\nهل تريد توحيد ثمرة الخشب بالطول (اتجاه Z) لكل الأخشاب المنقوشة في المشروع بالكامل؟",
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
        # إذا لم تكن هناك خامة بصورة Texture بعد، نعرض خيار ضبط كل الألواح الخشبية في المحدد
        ans2 = UI.messagebox(
          "لم يتم العثور على خامة منقوشة (Texture) على القطع المحددة حالياً.\nهل تريد ضبط اتجاه الثمرة والـ Cutting List بالطول (Z) لجميع الألواح الخشبية داخل المحدد؟",
          MB_YESNO
        )
        return false unless ans2 == IDYES
        boards = collect_wooden_boards(roots, false)
      end

      if boards.empty?
        UI.messagebox('لم يتم العثور على ألواح خشبية قابلة للضبط.')
        return false
      end

      model.start_operation('توحيد ثمرة الخشب بالطول (Z) - مكتبة محمد عادل', true)
      count = 0
      begin
        boards.each do |item|
          if set_part_grain!(item[:entity], :vertical_z, item[:parent_tr], item[:inherited_mat])
            count += 1
          end
        end
        model.commit_operation
      rescue => e
        model.abort_operation rescue nil
        UI.messagebox("حدث خطأ أثناء ضبط الثمرة:\n#{e.message}")
        return false
      end

      model.active_view.invalidate
      UI.messagebox("✅ تم توحيد اتجاه ثمرة الخشب بالطول (اتجاه Z) لعدد (#{count}) قطعة خشبية!\n\n• تم ضبط اتجاه النقشة الخشبية في المشهد 3D.\n• تم قفل المحور الطولي (orientation_locked_on_axis) ليقرأها الـ Cutting List (OpenCutList) بالطول.")
      true
    end

    def activate_single_part_grain_tool
      Sketchup.active_model.select_tool(DolaWoodGrainInspectorTool.new)
    end
  end

  # ============================================================================
  #  الأداة الثانية لثمرة الخشب: أداة التفتيش والقلب الفردي (قطعة بقطعة)
  #  مع مؤشر بصري ثلاثي الأبعاد + أسهم اتجاه الثمرة + بطاقة مقاس الـ Cutting List
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
      Sketchup.status_text = '🪵 أداة ثمرة الخشب الفردية: حرّك الماوس فوق أي قطعة خشبية لمعاينة اتجاه ثمرتها في الموديل والـ Cutting List، واضغط كليك شمال لقلبها بين الطول (Z) والعرض (X).'
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

        # نبحث من أعمق قطعة لوحية (Leaf Board) إلى الأعلى
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

          # الأولوية للقطع التي عليها نقشة خشبية، وإن لم توجد نقبل أي لوح خشبي يقف عليه المستخدم
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
        Sketchup.status_text = "🪵 القطعة: #{@hovered_info[:name]} (#{@hovered_info[:material_name]}) | الثمرة الحالية: #{@hovered_info[:mode_label]} | التقطيع: طول #{@hovered_info[:grain_len_cm]} سم × عرض #{@hovered_info[:cross_wid_cm]} سم — اضغط كليك شمال لقلب الثمرة 90°"
      else
        @hovered_info = nil
        Sketchup.status_text = '🪵 حرّك الماوس فوق أي قطعة خشبية (ضلفة، جنب، ضهر خشابي، رف، HPL...) لمعاينة اتجاه ثمرتها أو قلبها.'
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
        DolaWoodGrainManager.set_part_grain!(ent, new_mode, parent_tr, inh_mat)
        model.commit_operation
      rescue => e
        model.abort_operation rescue nil
        UI.messagebox("تعذر قلب الثمرة:\n#{e.message}")
        return
      end

      # تحديث المؤشر البصري فوراً بعد القلب
      updated = DolaWoodGrainManager.inspect_part_grain(ent, parent_tr, inh_mat)
      if updated
        @hovered_info = updated
        Sketchup.status_text = "✨ تم قلب الثمرة إلى: #{updated[:mode_label]} | المقاس الجديد في الـ Cutting List: طول #{updated[:grain_len_cm]} سم × عرض #{updated[:cross_wid_cm]} سم"
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

      # 1) رسم الإطار المضيء ثلاثي الأبعاد حول القطعة
      edges = [
        0,1, 1,2, 2,3, 3,0,
        4,5, 5,6, 6,7, 7,4,
        0,4, 1,5, 2,6, 3,7
      ]
      view.line_width = 3
      view.drawing_color = box_color
      view.draw(GL_LINES, edges.map { |i| corners[i] })

      # 2) رسم أسهم اتجاه الثمرة على وجه القطعة مباشرة
      center    = @hovered_info[:world_center]
      grain_vec = @hovered_info[:grain_vec]
      cross_vec = @hovered_info[:cross_vec]
      thick_vec = @hovered_info[:thick_vec]

      if center && grain_vec && cross_vec && thick_vec
        # نرفع الأسهم قليلاً خارج سمك اللوح باتجاه الكاميرا حتى لا تختفي داخل الوجه
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

          # خط السهم الرئيسي
          view.draw(GL_LINES, [p_start, p_end])

          # رأس السهم الأول (عند p_end)
          h1_a = p_end.offset(grain_vec, -head_size).offset(cross_vec,  head_size * 0.55)
          h1_b = p_end.offset(grain_vec, -head_size).offset(cross_vec, -head_size * 0.55)
          view.draw(GL_LINES, [p_end, h1_a, p_end, h1_b])

          # رأس السهم الثاني (عند p_start)
          h2_a = p_start.offset(grain_vec, head_size).offset(cross_vec,  head_size * 0.55)
          h2_b = p_start.offset(grain_vec, head_size).offset(cross_vec, -head_size * 0.55)
          view.draw(GL_LINES, [p_start, h2_a, p_start, h2_b])
        end
      end

      # 3) رسم بطاقة معلومات ثنائية الأبعاد واضحة بجوار الماوس
      screen_pt = Geom::Point3d.new(@mouse_x + 18, @mouse_y - 28, 0)
      label_txt = "🪵 #{@hovered_info[:name]} | الثمرة: #{@hovered_info[:mode_label]}\n📐 الطول (مع الثمرة): #{@hovered_info[:grain_len_cm]} سم × العرض: #{@hovered_info[:cross_wid_cm]} سم (كليك للقلب)"
      begin
        view.draw_text(screen_pt, label_txt, :size => 12, :bold => true, :color => box_color)
      rescue
        view.draw_text(screen_pt, label_txt) rescue nil
      end
    rescue
    end
  end

  # ============================================================================
  #  نافذة «خيارات الوحدة — مكتبة محمد عادل» (بديلة Component Options)
  #  تقرأ وتعدّل خصائص الـ Dynamic Component الخاصة بالوحدة المحددة مباشرة
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

    # إذا كان الوصف يحتوي على كلمات أبعاد ومقاسات والوحدة DEFAULT
    if u.empty? || u == 'DEFAULT'
      lbl = label_str.to_s
      dim_words = %w[عرض ارتفاع عمق طول سمك تخانة تخانات مسافة رحرحة سقوط بروز خصم مقاس شاسيه رجل رجول وزرة فراغ قطر]
      return true if dim_words.any? { |w| lbl.include?(w) }
    end
    false
  end

  def self.extract_unit_dc_options_payload(unit)
    return { :has_unit => false } unless unit && unit.valid? && unit.is_a?(Sketchup::ComponentInstance)

    # لو كانت وحدة دريسنج موقعة ننبّه الواجهة لإمكانية فتح مصمم الدريسنج أيضاً
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
      label = unescape_dc_string(raw_label)
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
          opt_label = unescape_dc_string(lbl_enc || pair)
          opt_val   = unescape_dc_string(val_enc || lbl_enc || pair)
          # إذا كانت القيمة المخزنة في الـ LIST بالبوصة أو السنتيمتر نحفظها كما هي في الخيار
          options_list << { 'label' => opt_label, 'value' => opt_val }
        end
      end

      # تجهيز القيمة المعروضة للمستخدم
      display_val = ''
      unit_badge  = ''

      if access == 'LIST'
        cur_str = raw_val.to_s.strip
        # مطابقة القيمة الحالية مع أحد الخيارات (حتى لو كان هناك فرق تقريب عشري بسيط أو تحويل 2.54)
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
        display_val = raw_val.to_s
        if display_val =~ /\A-?\d+\.\d+\z/
          display_val = display_val.to_f.round(2).to_s.sub(/\.0+\z/, '')
        end
      end

      # تصنيف الحقل: هل هو من المقاسات الرئيسية للوحدة؟
      norm_lbl = label.gsub(/\s+/, '')
      is_primary_dim = (
        access != 'VIEW' &&
        (norm_lbl.include?('عرض') || norm_lbl.include?('ارتفاع') || norm_lbl.include?('عمق')) &&
        !norm_lbl.include?('درج') && !norm_lbl.include?('رف')
      )

      fields << {
        'key'            => key,
        'label'          => label,
        'access'         => access, # TEXTBOX, LIST, VIEW
        'is_length'      => is_len,
        'units'          => units_str,
        'formula_units'  => formula_units_str,
        'unit_badge'     => unit_badge,
        'value'          => display_val,
        'options'        => options_list,
        'is_primary_dim' => is_primary_dim
      }
    end

    # ترتيب الحقول بنفس ترتيب الـ Component Options الأبجدي للمفاتيح
    fields.sort_by! { |f| f['key'].to_s.downcase }

    bb = unit.bounds
    unit_title = unit.definition.name.to_s.gsub(/\s*\([^)]*\)/, '').strip
    unit_title = unit.name.to_s.strip if unit_title.empty?
    unit_title = 'وحدة مطبخ' if unit_title.empty?

    {
      :has_unit      => true,
      :entity_id     => unit.entityID,
      :unit_name     => unit_title,
      :dressing_type => d_type.to_s,
      :bbox_w_cm     => (bb.width.to_f * 2.54).round(1),
      :bbox_d_cm     => (bb.depth.to_f * 2.54).round(1),
      :bbox_h_cm     => (bb.height.to_f * 2.54).round(1),
      :auto_open     => auto_open_options_enabled?,
      :fields        => fields
    }
  rescue => e
    { :has_unit => false, :error => e.message }
  end

  def self.apply_unit_dc_options_changes!(changes_hash)
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
      # 1) استعادة أي محاور ثمرة معدلة مؤقتاً قبل عمل Redraw للـ Dynamic Component
      saved_grain_states = DolaWoodGrainManager.restore_dc_axes_before_redraw!(unit)

      forced = {}
      changes_hash.each do |raw_key, user_val|
        key = raw_key.to_s
        meta = field_map[key]
        next unless meta
        next if meta['access'] == 'VIEW'

        val_str = user_val.to_s.strip
        internal_val = val_str

        if meta['access'] == 'LIST'
          # في قوائم الاختيار، إذا كانت القيمة رقمية وكان الحقل طولياً بالـ CM في الفورمولا نحولها للبوصة عند اللزوم
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

        formula_key = "_#{key}_formula"
        begin
          unit.delete_attribute('dynamic_attributes', formula_key)
        rescue
        end

        begin
          d.set_attribute(unit, key, internal_val)
        rescue
          unit.set_attribute('dynamic_attributes', key, internal_val)
        end
        unit.set_attribute('dynamic_attributes', key, internal_val)
        forced[key] = internal_val
      end

      # دورة التحديث الكاملة لضمان استجابة كل المعادلات الداخلية للوحدة
      forced.each { |k, v| d.set_forced_config_value(unit, k, v) rescue nil }
      d.run_all_formulas(unit) rescue nil
      d.redraw(unit, false, false) rescue nil
      d.update_last_sizes(unit) rescue nil

      d.clear_forced_config_values(unit) rescue nil
      d.run_all_formulas(unit) rescue nil
      d.redraw(unit, false, false) rescue nil
      d.update_last_sizes(unit) rescue nil

      # 2) إعادة تطبيق اتجاه ثمرة الخشب المحفوظ على القطع بعد انتهاء Redraw
      DolaWoodGrainManager.reapply_grain_after_redraw!(unit, saved_grain_states)

      model.commit_operation
      model.active_view.invalidate
      refresh_unit_options_dialog_if_open(unit)
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

    # لو كانت الوحدة المحددة هي وحدة دريسنج موقعة وليس بها حقول مطبخ عادية، نفتح مصمم الدريسنج
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
      :dialog_title    => 'خيارات الوحدة — مكتبة محمد عادل',
      :preferences_key => 'DolaKitchenUnitOptions_v2',
      :scrollable      => false,
      :resizable       => true,
      :width           => 460,
      :height          => 680,
      :left            => 260,
      :top             => 95,
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
            padding: 14px;
            gap: 11px;
          }
          /* الهيدر العلوي بطابع مكتبة محمد عادل */
          .hero-card {
            background: linear-gradient(135deg, rgba(30, 27, 75, 0.92) 0%, rgba(15, 23, 42, 0.95) 100%);
            border: 1px solid rgba(56, 189, 248, 0.35);
            border-radius: 16px;
            padding: 12px 15px;
            display: flex;
            align-items: center;
            justify-content: space-between;
            gap: 10px;
            box-shadow: 0 10px 28px rgba(0, 0, 0, 0.4);
          }
          .hero-right {
            display: flex;
            align-items: center;
            gap: 11px;
            min-width: 0;
          }
          .hero-badge {
            width: 42px;
            height: 42px;
            border-radius: 12px;
            background: linear-gradient(135deg, #0284c7 0%, #1e1b4b 100%);
            border: 1px solid #38bdf8;
            display: flex;
            align-items: center;
            justify-content: center;
            font-size: 20px;
            flex-shrink: 0;
            box-shadow: 0 0 15px rgba(56, 189, 248, 0.35);
          }
          .hero-titles {
            min-width: 0;
          }
          .hero-brand {
            font-size: 11px;
            font-weight: 800;
            color: #fbbf24;
            letter-spacing: 0.3px;
          }
          .hero-unit-name {
            font-size: 16px;
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

          /* شريط البحث السريع وأداة الثمرة السريعة */
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
            transition: border-color 0.2s;
          }
          .search-box:focus {
            border-color: #38bdf8;
          }
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
            box-shadow: 0 4px 12px rgba(217, 119, 6, 0.3);
            transition: all 0.18s;
          }
          .quick-grain-btn:hover {
            filter: brightness(1.12);
            transform: translateY(-1px);
          }

          /* منطقة الحقول القابلة للتمرير */
          .fields-scroll {
            flex: 1;
            overflow-y: auto;
            overflow-x: hidden;
            display: flex;
            flex-direction: column;
            gap: 12px;
            padding-left: 4px;
          }
          .fields-scroll::-webkit-scrollbar { width: 6px; }
          .fields-scroll::-webkit-scrollbar-thumb {
            background: rgba(56, 189, 248, 0.35);
            border-radius: 99px;
          }

          .section-card {
            background: rgba(30, 41, 59, 0.62);
            border: 1px solid rgba(255, 255, 255, 0.11);
            border-radius: 14px;
            padding: 12px;
            display: flex;
            flex-direction: column;
            gap: 10px;
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
            font-size: 11.5px;
            font-weight: 700;
            color: #cbd5e1;
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
            transition: border-color 0.18s, box-shadow 0.18s;
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
          .has-unit .field-input {
            padding-left: 34px;
          }

          .option-row {
            display: grid;
            grid-template-columns: 1.15fr 1fr;
            align-items: center;
            gap: 10px;
            padding: 6px 8px;
            border-radius: 10px;
            background: rgba(15, 23, 42, 0.55);
            border: 1px solid rgba(255, 255, 255, 0.06);
          }
          .option-row:hover {
            border-color: rgba(56, 189, 248, 0.3);
            background: rgba(15, 23, 42, 0.8);
          }
          .option-label {
            font-size: 12.5px;
            font-weight: 700;
            color: #e2e8f0;
            line-height: 1.35;
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
          .empty-state-icon {
            font-size: 38px;
          }

          /* الفوتر السفلي وأزرار التطبيق */
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
            box-shadow: 0 4px 16px rgba(2, 132, 199, 0.35);
            transition: all 0.18s;
          }
          .apply-btn:hover {
            filter: brightness(1.12);
            transform: translateY(-1px);
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
          .refresh-btn:hover {
            background: rgba(255, 255, 255, 0.15);
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

          <div class="toolbar-strip">
            <input type="text" id="filterInput" class="search-box" placeholder="🔍 ابحث في خيارات الوحدة..." oninput="renderFields()">
            <button type="button" class="quick-grain-btn" onclick="alignUnitGrainZ()" title="ضبط ثمرة كل الأخشاب المنقوشة في هذه الوحدة بالطول (Z)">
              🪵↕ الثمرة بالطول (Z)
            </button>
          </div>

          <div class="fields-scroll" id="fieldsContainer"></div>

          <div class="footer-panel">
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

          function esc(s) {
            return String(s == null ? '' : s)
              .replace(/&/g, '&amp;')
              .replace(/</g, '&lt;')
              .replace(/>/g, '&gt;')
              .replace(/"/g, '&quot;');
          }

          window.receiveUnitPayload = function(payload) {
            currentPayload = payload || { has_unit: false };
            editedValues = {};
            const autoChk = document.getElementById('autoOpenCheck');
            if (autoChk && currentPayload.auto_open !== undefined) {
              autoChk.checked = !!currentPayload.auto_open;
            }
            renderFields();
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
                  <div class="empty-state-icon">📦</div>
                  <div style="font-size:15px;font-weight:800;color:#fff;">حدد أي وحدة مطبخ في سكتش أب</div>
                  <div style="font-size:12.5px;line-height:1.6;">بمجرد تحديد أي وحدة ديناميكية في المشهد ستظهر لك هنا جميع مقاساتها وخيارات الـ Component Options الخاصة بها فوراً.</div>
                </div>
              `;
              return;
            }

            titleEl.textContent = currentPayload.unit_name || 'وحدة مطبخ';
            badgeEl.textContent = `${currentPayload.bbox_w_cm} × ${currentPayload.bbox_d_cm} × ${currentPayload.bbox_h_cm} سم`;

            const allFields = Array.isArray(currentPayload.fields) ? currentPayload.fields : [];
            const filtered = allFields.filter(f => {
              if (!q) return true;
              return String(f.label || '').toLowerCase().includes(q) || String(f.key || '').toLowerCase().includes(q);
            });

            if (filtered.length === 0) {
              container.innerHTML = `
                <div class="empty-state">
                  <div class="empty-state-icon">ℹ️</div>
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
                    <span style="font-size:11px;color:#94a3b8;">Component Options</span>
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
              return `<div class="readonly-badge">${esc(val)} ${esc(f.unit_badge || '')}</div>`;
            }
            if (f.access === 'LIST' && Array.isArray(f.options) && f.options.length > 0) {
              return `
                <select class="field-select" data-key="${esc(f.key)}" onchange="onFieldInput('${esc(f.key)}', this.value)">
                  ${f.options.map(o => {
                    const sel = String(o.value).trim() === String(val).trim() ? 'selected' : '';
                    return `<option value="${esc(o.value)}" ${sel}>${esc(o.label)}</option>`;
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
                <label>${esc(f.label)}</label>
                ${renderControlHtml(f)}
              </div>
            `;
          }

          function renderOptionRow(f) {
            return `
              <div class="option-row">
                <div class="option-label">${esc(f.label)}</div>
                <div>${renderControlHtml(f)}</div>
              </div>
            `;
          }

          function submitChanges() {
            if (!currentPayload || !currentPayload.has_unit) return;
            const payloadToSave = {};
            const allFields = Array.isArray(currentPayload.fields) ? currentPayload.fields : [];
            allFields.forEach(f => {
              if (f.access !== 'VIEW') {
                payloadToSave[f.key] = currentValFor(f);
              }
            });
            if (window.sketchup && window.sketchup.apply_unit_options) {
              window.sketchup.apply_unit_options(JSON.stringify(payloadToSave));
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
      apply_unit_dc_options_changes!(changes)
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
  #  لفتح نافذة خيارات الوحدة تلقائياً بمجرد تثبيت الوحدة في سكتش أب
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

  KITCHEN_MATERIAL_PRESETS = [
    { :id => 'hpl_oak',      :name => 'HPL أوك طبيعي (ثمرة خشب)',    :rgb => [194, 145, 95],  :grained => true },
    { :id => 'hpl_walnut',   :name => 'HPL جوز تركي داكن (ثمرة خشب)', :rgb => [118, 78, 52],   :grained => true },
    { :id => 'hpl_2side_ash',:name => 'HPL وشين قشرة أرو (ثمرة خشب)', :rgb => [212, 175, 130], :grained => true },
    { :id => 'wood_back',    :name => 'ضهر خشابي منقوش (ثمرة خشب)',  :rgb => [178, 132, 88],  :grained => true },
    { :id => 'mdf_white',    :name => 'شاسيه كونتر / MDF أبيض سادة', :rgb => [244, 246, 249], :grained => false },
    { :id => 'mdf_beige',    :name => 'شاسيه كافيه / بيج ناعم سادة', :rgb => [226, 214, 198], :grained => false },
    { :id => 'mdf_anthracite',:name => 'أنتراسيت رمادي فحمي مودرن',  :rgb => [55, 65, 81],    :grained => false },
    { :id => 'mdf_navy',     :name => 'كحلي ملكي (مكتبة محمد عادل)',  :rgb => [30, 41, 95],    :grained => false }
  ].freeze

  def self.open_kitchen_materials_tool
    if @kitchen_materials_dlg && @kitchen_materials_dlg.visible?
      @kitchen_materials_dlg.bring_to_front rescue nil
      return true
    end

    @kitchen_materials_dlg = UI::HtmlDialog.new({
      :dialog_title    => 'مستويات وخامات المطبخ — مكتبة محمد عادل',
      :preferences_key => 'DolaKitchenMaterials_v2',
      :scrollable      => false,
      :resizable       => true,
      :width           => 450,
      :height          => 590,
      :style           => UI::HtmlDialog::STYLE_DIALOG
    })

    presets_json = KITCHEN_MATERIAL_PRESETS.to_json

    html = <<~HTML
      <!DOCTYPE html>
      <html lang="ar" dir="rtl">
      <head>
        <meta charset="UTF-8">
        <link href="https://fonts.googleapis.com/css2?family=Tajawal:wght@500;700;800&display=swap" rel="stylesheet">
        <style>
          * { box-sizing: border-box; }
          body {
            margin: 0; padding: 14px;
            font-family: 'Tajawal', sans-serif;
            background: linear-gradient(160deg, #1e1b4b 0%, #0f172a 100%);
            color: #f8fafc;
            height: 100vh;
            display: flex;
            flex-direction: column;
            gap: 12px;
            overflow: hidden;
          }
          .head-card {
            background: rgba(15, 23, 42, 0.85);
            border: 1px solid rgba(56, 189, 248, 0.35);
            border-radius: 14px;
            padding: 12px 14px;
          }
          .head-card h2 { margin: 0 0 4px; font-size: 16px; color: #38bdf8; }
          .head-card p  { margin: 0; font-size: 12px; color: #cbd5e1; }
          .target-group {
            background: rgba(30, 41, 59, 0.7);
            border: 1px solid rgba(255, 255, 255, 0.12);
            border-radius: 12px;
            padding: 10px 12px;
            display: flex;
            flex-direction: column;
            gap: 7px;
          }
          .target-group label { font-size: 12.5px; font-weight: 800; color: #fbbf24; }
          select {
            width: 100%;
            padding: 8px 10px;
            border-radius: 9px;
            background: #0f172a;
            border: 1px solid rgba(56, 189, 248, 0.4);
            color: #fff;
            font-family: 'Tajawal', sans-serif;
            font-size: 13px;
            font-weight: 700;
          }
          .presets-grid {
            flex: 1;
            overflow-y: auto;
            display: grid;
            grid-template-columns: 1fr 1fr;
            gap: 9px;
            padding-left: 3px;
          }
          .preset-card {
            background: rgba(15, 23, 42, 0.82);
            border: 1px solid rgba(255, 255, 255, 0.12);
            border-radius: 12px;
            padding: 10px;
            cursor: pointer;
            display: flex;
            flex-direction: column;
            gap: 7px;
            transition: all 0.18s;
          }
          .preset-card:hover, .preset-card.active {
            border-color: #38bdf8;
            background: rgba(2, 132, 199, 0.22);
            transform: translateY(-2px);
          }
          .swatch {
            height: 38px;
            border-radius: 8px;
            border: 1px solid rgba(255, 255, 255, 0.25);
            position: relative;
            overflow: hidden;
          }
          .swatch.grained::after {
            content: "🪵 نقشة ثمرة خشب";
            position: absolute;
            bottom: 3px; left: 6px;
            font-size: 9.5px;
            font-weight: 800;
            background: rgba(15, 23, 42, 0.78);
            color: #fbbf24;
            padding: 1px 6px;
            border-radius: 6px;
          }
          .preset-title { font-size: 12px; font-weight: 700; color: #f1f5f9; }
          .apply-btn {
            background: linear-gradient(135deg, #0284c7 0%, #0369a1 100%);
            border: 1px solid #38bdf8;
            color: #fff;
            padding: 11px;
            border-radius: 11px;
            font-family: 'Tajawal', sans-serif;
            font-size: 14px;
            font-weight: 800;
            cursor: pointer;
          }
        </style>
      </head>
      <body oncontextmenu="return false;">
        <div class="head-card">
          <h2>🎨 مستويات وخامات المطبخ</h2>
          <p>اختر الجزء المستهدف والخامة (سادة أو بخشب منقوش HPL / ضهر خشابي مع ضبط الثمرة تلقائياً بالطول Z)</p>
        </div>

        <div class="target-group">
          <label>تطبيق الخامة على:</label>
          <select id="targetPartSelect">
            <option value="all_parts">جميع قطع الوحدات المحددة (أو المطبخ بالكامل)</option>
            <option value="doors_only">الضلف ووشوش الأدراج والتجاليد فقط</option>
            <option value="backs_only">الضهر فقط (تحويل إلى ضهر خشابي منقوش)</option>
            <option value="carcass_only">الشاسيه الداخلي فقط (أجناب + أرفف + قواطيع)</option>
          </select>
        </div>

        <div class="presets-grid" id="presetsGrid"></div>

        <button class="apply-btn" onclick="applySelectedMaterial()">✨ تطبيق الخامة وضبط الثمرة بالطول (Z)</button>

        <script>
          const PRESETS = #{presets_json};
          let selectedId = PRESETS[0].id;

          function renderPresets() {
            const grid = document.getElementById('presetsGrid');
            grid.innerHTML = PRESETS.map(p => {
              const [r, g, b] = p.rgb;
              const active = (p.id === selectedId) ? 'active' : '';
              const grCls  = p.grained ? 'grained' : '';
              const bgCss  = p.grained
                ? `repeating-linear-gradient(90deg, rgb(${r},${g},${b}) 0px, rgb(${Math.max(r-16,0)},${Math.max(g-16,0)},${Math.max(b-16,0)}) 4px, rgb(${r},${g},${b}) 8px)`
                : `rgb(${r},${g},${b})`;
              return `
                <div class="preset-card ${active}" onclick="selectPreset('${p.id}')">
                  <div class="swatch ${grCls}" style="background:${bgCss};"></div>
                  <div class="preset-title">${p.name}</div>
                </div>
              `;
            }).join('');
          }

          function selectPreset(id) {
            selectedId = id;
            renderPresets();
          }

          function applySelectedMaterial() {
            const target = document.getElementById('targetPartSelect').value;
            if (window.sketchup && window.sketchup.apply_kitchen_material) {
              window.sketchup.apply_kitchen_material(JSON.stringify({ preset_id: selectedId, target: target }));
            }
          }

          renderPresets();
        </script>
      </body>
      </html>
    HTML

    @kitchen_materials_dlg.set_html(html)
    @kitchen_materials_dlg.add_action_callback('apply_kitchen_material') do |_ctx, json_str|
      data = JSON.parse(json_str.to_s) rescue {}
      apply_kitchen_material_preset!(data['preset_id'], data['target'])
    end
    @kitchen_materials_dlg.show
    true
  end

  def self.apply_kitchen_material_preset!(preset_id, target_scope)
    preset = KITCHEN_MATERIAL_PRESETS.find { |p| p[:id] == preset_id.to_s } || KITCHEN_MATERIAL_PRESETS.first
    model  = Sketchup.active_model
    roots  = model.selection.to_a.select { |e| e.is_a?(Sketchup::ComponentInstance) || e.is_a?(Sketchup::Group) }
    roots  = model.active_entities.to_a.select { |e| e.is_a?(Sketchup::ComponentInstance) || e.is_a?(Sketchup::Group) } if roots.empty?

    if roots.empty?
      UI.messagebox('لا توجد وحدات في المشهد لتطبيق الخامة عليها.')
      return false
    end

    boards = DolaWoodGrainManager.collect_wooden_boards(roots, false)
    filtered = boards.select do |b|
      nm = DolaWoodGrainManager.entity_display_name(b[:entity]).downcase
      case target_scope.to_s
      when 'doors_only'
        nm.include?('ضلف') || nm.include?('ضل') || nm.include?('باب') || nm.include?('وش') || nm.include?('تجليد') || nm.include?('door') || nm.include?('front')
      when 'backs_only'
        nm.include?('ضهر') || nm.include?('ظهر') || nm.include?('back')
      when 'carcass_only'
        !(nm.include?('ضلف') || nm.include?('باب') || nm.include?('door') || nm.include?('وش'))
      else
        true
      end
    end
    filtered = boards if filtered.empty?

    model.start_operation('تطبيق خامات المطبخ - مكتبة محمد عادل', true)
    begin
      mat_name = "Dola_#{preset[:name]}"
      mat = model.materials[mat_name] || model.materials.add(mat_name)
      r, g, b = preset[:rgb]
      mat.color = Sketchup::Color.new(r, g, b)
      DolaWoodGrainManager.ensure_procedural_wood_texture!(mat) if preset[:grained]

      filtered.each do |item|
        ent = item[:entity]
        next unless ent && ent.valid?
        ent.material = mat
        if preset[:grained]
          DolaWoodGrainManager.set_part_grain!(ent, :vertical_z, item[:parent_tr], mat)
        end
      end
      model.commit_operation
      UI.messagebox("✅ تم تطبيق الخامة «#{preset[:name]}» على (#{filtered.length}) قطعة بنجاح#{preset[:grained] ? ' مع ضبط الثمرة بالطول (Z)' : ''}.")
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